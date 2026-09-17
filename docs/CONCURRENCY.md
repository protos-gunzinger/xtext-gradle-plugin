# Concurrency Analysis: Xtext Builder Task Parallelism

*Trigger: etrice observed `org.xtext:xtext-gradle-plugin` 4.0.0 being parallel-unsafe on cold caches under Gradle 9 (`--parallel`): reproducible `NoClassDefFoundError`, only recoverable via `./gradlew --stop`; mitigated there by serializing all Xtext-project tasks through a shared `BuildService`.*

This document maps that symptom onto this repository's code and enumerates every concurrency surface exposed by the tasks the plugins export (`generateXtext`, `generate<Name>Xtext`, `clean<Name>Xtext`, `xtextEclipseSettings`, plus the `doLast` hook the plugin adds to `compileJava`).

## The concurrency model

- Gradle's `--parallel` runs tasks from **different projects concurrently** in one build. Tasks of a single project stay serialized, so *all* cross-project task pairs are candidates: two `generateXtext` tasks, `generateXtext` (A) vs `compileJava.doLast` (B), etc.
- All those tasks execute in the **same Gradle daemon JVM** and share the plugin's classes — therefore every `static` field in this repository is shared mutable state across projects.
- The core design deliberately concentrates that state into one process-wide singleton: `IncrementalXtextBuilderProvider` (xtext-gradle-plugin/src/main/java/org/xtext/gradle/tasks/internal/IncrementalXtextBuilderProvider.xtend). Its lock, checksum and lifecycle are where the etrice bug lives.

## Race 1 (critical — the etrice `NoClassDefFoundError`): classloader closed while in use

```xtend
static def IncrementalXtextBuilder getBuilder(...) {
    synchronized (lock) {
        if (incompatibleBuilderExists(...)) { closeBuilder }
        if (builder === null) { createBuilder(...) }
        return builder
    }
}
private static def closeBuilder() {
    (builder.class.classLoader as Closeable).close   // closes the URLClassLoader!
    builder = null
}
```

The `synchronized` block only covers **acquisition**. The caller then uses the returned builder **outside the lock** — `XtextGenerate.generate()` runs `builder.build(request)` and `compileJava.doLast` runs `builder.installDebugInfo(...)` in some other project's task thread. `closeBuilder()` closes the shared `URLClassLoader` whenever the checksum differs, **without knowing whether any other thread is mid-`build()` on that builder**.

Failure mechanics: any class that Xtext/EMF/Guice loads *lazily* during a build (and there are many — EMF registers reflectively, Guice injects on first use, Xtend loads compiler classes on demand) will be looked up in a closed `URLClassLoader` → `NoClassDefFoundError` (or "zip file closed"/`IOException` variants). The thread holding the stale `builder` reference keeps failing; even though `builder` was set to `null`, the *in-flight* task re-initializes via its own field (`XtextGenerate.builder`), and the next checksum flip can close the replacement again.

### Why cold caches specifically

The checksum is `hash(languageSetups, encoding, classpath.path + classpath.lastModified)`:

- On a **cold cache**, every project/source set resolves its `xtextTooling<SourceSet>` configuration independently; different projects have different resolved jar sets (and freshly downloaded artifacts differ in `lastModified`), so early concurrent tasks observe **several distinct checksums**. Every checksum flip triggers a `closeBuilder()` → the race window opens on essentially every task pair. Etice's heterogeneous multi-project workspace is the worst case.
- On a **warm cache**, all tasks converge on one checksum → no closes → the build usually passes, which is why the bug is intermittent and cache-state dependent.

## Race 2 (exists even on warm caches): shared index and mappings

`XtextGradleBuilder` is a singleton whose per-instance state two *concurrent* `build()` calls (two projects with identical setups/encoding/classpath ⇒ identical checksum ⇒ **same** builder) mutate and read without synchronization:

| State | Type | Hazard |
|---|---|---|
| `index` (`GradleResourceDescriptions` extends Xtext's `ChunkedResourceDescriptions`) | plain, non-concurrent map (`chunk2resourceDescriptions`) | `index.setContainer(...)` (XtextGradleBuilder.xtend:98, after each build) concurrent with another build's `getContainer(...)/createShallowCopyWith(...)` (lines 80, 158) → torn reads, lost chunks, `ConcurrentModificationException`, corrupted cross-project index. This index is the cross-project linking feature (`upStreamModelsCanBeReferenced`), so it is hit by every multi-project Xtend/Xtext build. |
| `generatedMappings` (`ConcurrentHashMap<String, Source2GeneratedMapping>`) | outer map concurrent, inner `Source2GeneratedMapping` is not | `.copy` on a mapping while its owning container is updated — low risk since container handles (`projectDir:sourceSet`) are project-unique, but nothing enforces it. |
| `dependencyHashes` (`ConcurrentHashMap`) | concurrent | Safe. |

## Race 3: EMF/Guice global registries inside the shared tooling classloader

`XtextGradleBuilder`'s constructor runs `ISetup.createInjectorAndDoEMFRegistration` per language, which writes **process-wide singletons in the tooling classloader**: `IResourceServiceProvider.Registry.INSTANCE`, the EMF `EPackage.Registry.INSTANCE`, platform-resource mappings, and `IEncodingProvider.Runtime.setDefaultEncoding(encoding)`.

- While one project's `build()` is executing (reading the registry on every resource lookup), another project with a different language/encoding can construct a different builder — `getBuilder()` is synchronized, so registrations don't interleave, but the *mid-build* consumer sees the registry flip underneath it: providers for its language can be replaced by another language's/Xtext version's → misvalidation, misgeneration, or linkage errors that surface far from the cause.
- `System.setProperty("org.eclipse.emf.common.util.ReferenceClearingQueue", "false")` (constructor, line 56) is JVM-global configuration written from task execution; benign today, but another example of shared-JVM state.

The shared `IncrementalBuilder` and `DebugInfoInstaller` singletons are request-scoped internally (fresh `XtextResourceSet` per request; debug info builds a fresh resource set per call), so they are safe *given* mutual exclusion of `build()`/`installDebugInfo()` — which today nothing provides.

## Non-issues (verified)

- `XtextGenerate.builderJar` static initializer: one temp jar per daemon, guarded by JVM class-init locking, read-only afterwards.
- Task-instance state (`generatedFiles`, `builder` field on `XtextGenerate`): one task instance per project; Gradle serializes within a project; `installDebugInfo` runs in `compileJava.doLast` of the *same* project, after `generateXtext`.
- `XtextEclipseSettings`: writes project-local `.settings/` files.
- `FilteringClassLoader`: stateless parent-delegation filter.
- Clean tasks / outlet dir maps (`DefaultXtextSourceSetOutputs`): per-project instances, only touched in that project's context.

## Fixes

### Immediate mitigation (what etrice did)

Gradle-native serialization via a shared `BuildService` with `maxParallelUsages = 1`, attached with `usesService(...)` to every task that touches the builder. Native/test/example projects stay parallel. Note that the `compileJava` `doLast(installDebugInfo)` hook means the plugin — not the consumer — must attach the service to `compileJava` too (see wiring below); a consumer adding `usesService` only to `generateXtext` leaves the debug-info race open.

### Durable cure in this repository (plugin 5.x)

1. **Register the service in `XtextBuilderPlugin.apply`**:
   ```xtend
   val builderServiceProvider = project.gradle.sharedServices.registerIfAbsent("xtextBuilder", XtextBuilderLock)
   ```
2. **Serialize at the right granularity**: acquire the permit for the whole `generate(InputChanges)` action and the whole `installDebugInfo` — not just builder construction. Races 2 and 3 require mutual exclusion of *execution*, not of `getBuilder()`.
3. **Wire the requirement** (this is what makes Gradle schedule correctly):
   - `tasks.register(name, XtextGenerate) { usesService(provider) }`
   - in `integrateWithJavaPlugin`: `javaCompile.configure { usesService(provider) }` for the debug-info `doLast`.
4. **Optionally** keep `IncrementalXtextBuilderProvider` as is (the service then guarantees single-threaded access), or add refcounting so an early mistake degrades to "no speedup" instead of corruption. Do **not** merely synchronize `build()` internally: the lock must be held across the whole task action via Gradle's scheduler, otherwise `compileJava.doLast`-vs-`generateXtext` deadlocks/self-serializes incorrectly.
5. Rejected alternative: per-project classloaders. They would isolate races 1–3, but they break the deliberate design where one shared `GradleResourceDescriptions` index enables cross-project model linking and multiply classloader memory per project.
6. **Test**: an integration test with `org.gradle.parallel=true`, 3+ subprojects with different Xtext classpaths, run against an empty testkit dir (cold cache), asserting repeated green builds — the missing regression test for etrice's finding.

## Summary table

| # | Surface | Where | Condition | Effect |
|---|---|---|---|---|
| 1 | `URLClassLoader` closed during in-flight `build()`/`installDebugInfo()` | `IncrementalXtextBuilderProvider.closeBuilder` | cold cache / heterogeneous checksums + `--parallel` | `NoClassDefFoundError`, poisoned daemon until `--stop` (etrice) |
| 2 | shared index/mutation | `XtextGradleBuilder.index`, `generatedMappings` | any concurrent builds sharing one checksum | lost/corrupt index chunks, CME, phantom rebuilds |
| 3 | EMF/Guice global registries | `createInjectorAndDoEMFRegistration`, `IEncodingProvider.Runtime` | concurrent builder creation with different languages/encodings | wrong providers/encodings mid-build, misgeneration |
| 4 | JVM-wide system property | `System.setProperty` in builder ctor | benign today | global side effect |
