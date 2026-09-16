# Upgrade Plan

*Researched 2026-09-16; executed on branch `gunzinger/dep-upgrades`. Current branch state: **Gradle 9.7.1** wrapper, **JDK 21** toolchain (artifacts Java 21 bytecode), build/test daemons on **JDK 21/25**, Xtext matrix 2.43.0 – 2.44.0.*

## Status: What Has Been Done

1. **Phase 0 — dependency bumps (commit 2):** bootstrap plugin 4.0.0, junit 4.13.2, ASM 9.10.1, Guava 33.4.8-jre, maven-artifact 3.9.16, OSGi framework 1.10.0; build-time Xtend compiler pinned via `xtext { version }` and aligned with the compile classpath (active annotation processing requires matching annotation class versions).
2. **Phase 1 — stepping stone Gradle 8.14.3 + JDK 17 (commit 3):** plugin-publish 2.2.1 (`pluginBundle` → `gradlePlugin` DSL), nebula.facet replaced by a hand-rolled `integTest` source set, lazy task registration, report providers.
3. **Phase 2 — Gradle 9.7.1 (commit 4):** `project.buildDir` → `layout.buildDirectory` provider, execution-time `Task.getProject()` removed from `XtextGenerate`/`XtextEclipseSettings` (injected `ProjectLayout`/`ObjectFactory` + captured configuration-time values), internal `FileOperations` → public `ObjectFactory.fileCollection()`, `Property.convention(value)` → `convention(provider)`, `gradleApi()`/`gradleTestKit()` declared explicitly (no longer implicit on Gradle 9), legacy `testReportDir`/`testResultsDir` properties removed, `@DisableCachingByDefault` + `@PathSensitive` for plugin validation, minimum tested Gradle raised 7.1 → 8.0 (Gradle 7.x cannot run its Groovy script compiler on the JDK 17 daemons a Gradle 9 build requires).
4. **Test matrix:** `minimumIntegrationTest` = Gradle 8.5 + Xtext 2.43.0 (daemon pinned to **JDK 21** via `javaLauncher`); `latestIntegrationTest` = Gradle 9.7.1 + Xtext 2.44.0 (daemon pinned to **JDK 25** via `javaLauncher`).
5. **Phase 3 — Xtext 2.44 + JDK 21/25 (commit 5):** `latestXtextVersion` 2.29.0 → 2.44.0 (build-time Xtend tooling and shipped `org.eclipse.xtend.lib` 2.44), `minimumXtextVersion` 2.17.1 → **2.43.0**, `options.release` 11 → **21** with toolchain 21 (javac refuses classpath classes newer than the release target, so the Java 21 bytecode of Xtext 2.44 forces artifact level 21), `minimumGradleVersion` 8.0 → **8.5** (first Gradle that can run a JDK 21 daemon), the JDK 11 min-matrix daemon (`-PminTestJavaHome`) was dropped, and a clear `GradleException` replaced the NPE when `javaSourceLevel` maps to no `JavaVersion` (Xtext 2.43+ dropped pre-Java-8 qualifiers).

## End-State Findings (empirical)

- **JDK 21/25 daemons are unblocked since Phase 3.** Resolved nuances that the original research (below) got wrong:
    - Xtext 2.38–2.42 is Java 17 bytecode, but **2.42 and older `JavaVersion` lacks JAVA25** — on JDK 25 daemons the default `sourceCompatibility=25` maps to a null `GeneratorConfig.javaSourceVersion` and the builder NPEs, so the newest usable Xtext for JDK 25 daemons is 2.43+.
    - Xtext **2.43+ is Java 21 bytecode** (not Java 17 as assumed), which cascades the consumer floor to **JDK 21 / Gradle 8.5** rather than keeping Java 17 consumers.
    - Xtext 2.43+ `JavaVersion.fromQualifier` no longer accepts pre-Java-8 qualifiers ("1.6"/"1.7"); JAVA5–8 all share the qualifiers `1.8`/`8`. Fixtures using obsolete levels were updated, and the builder now fails with a clear error instead of an NPE.
- The `eclipse` IDE task chain is deprecated in Gradle 9 (removed in Gradle 10); the plugin's own `xtextEclipseSettings`/`cleanXtextEclipseSettings` tasks still work and are what the tests exercise.

## Remaining (optional) Work

1. JUnit 4 → Jupiter migration (test-only, mechanical).
2. CI workflows (`.github/`) still reference the old build (JDK 11, actions v1/v2) and must be updated to: JDK 21 + 25, `gradle/actions/setup-gradle`, current action versions.


## Pre-Branch State (historical)

| Tool / Dependency | Current | Where |
|---|---|---|
| Gradle wrapper | **7.2** | `gradle/wrapper/gradle-wrapper.properties` |
| Java toolchain | **11** (17 launcher for `latestIntegrationTest`) | root `build.gradle`, plugin `build.gradle` |
| Bootstrap Xtend plugin (`org.xtext:xtext-gradle-plugin`) | 2.0.9 | root `build.gradle` buildscript |
| nebula-project-plugin (`nebula.facet`) | 8.2.0 | root `build.gradle` buildscript |
| plugin-publish-plugin | 0.15.0 | root `build.gradle` buildscript |
| Test matrix: Gradle | 7.1 – 8.0 | `gradle.properties` |
| Test matrix: Xtext | 2.17.1 – 2.29.0 | `gradle.properties` (+ hard-coded min in `XtextBuilderPlugin.LazyXtextVersion`) |
| Guava | 27.1-jre | protocol & plugin `build.gradle` |
| equinox preferences / common | 3.6.1 / 3.8.0 | plugin `build.gradle` |
| org.osgi.framework | 1.8.0 | plugin `build.gradle` |
| maven-artifact | 3.8.2 | plugin `build.gradle` |
| Xtend lib (plugin `implementation`) | 2.17.1 (`$minimumXtextVersion`) | plugin `build.gradle` |
| JUnit / ASM (tests) | 4.12 / 6.1.1 + 9.4 | root & plugin `build.gradle` |
| GitHub Actions | checkout@v2, setup-java@v1, eskatos/gradle-command-action@v1, upload-artifact@v2, battila7/get-version-action@v2 | `.github/workflows/*.yml` |

**Hard blocker today:** Gradle 7.2 cannot run on modern JDKs. On the locally installed JDK 25 the wrapper fails immediately with `Unsupported class file major version 69` while compiling `settings.gradle`. Gradle 9 requires JVM 17–26 to *run*; Java 25 runtime support was added in **Gradle 9.1.0**.

## Latest Versions (verified against Maven Central / Plugin Portal / actions marketplaces)

| Component | Latest | Notes |
|---|---|---|
| Gradle | **9.7.1** | Java 25 runtime OK (≥9.1.0), Java 26 OK (≥9.4.0); requires JVM ≥17 |
| JDK | **25** (LTS; local: OpenJDK 25.0.4) | compile target 11 → 17 (Gradle 9 daemons run on 17+) |
| Xtext / Xtend | **2.44.0** | verify Java requirement of each candidate release (newer Xtext lines require Java 17+) |
| `org.xtext:xtext-gradle-plugin` (bootstrap) | **4.0.0** | this project's own latest release; built for the Gradle 8 era — smoke-test on Gradle 9 |
| nebula-project-plugin | **11.0.0** | ⚠ plugin ids renamed at v10.0.1: `nebula.facet` → `com.netflix.nebula.facet` |
| plugin-publish-plugin | **2.2.1** | ⚠ `pluginBundle {}` DSL was removed in 1.0 → migrate to `gradlePlugin { website, vcsUrl, tags }` |
| Guava | **33.4.8-jre** | needs Java 8+ |
| equinox preferences / common | 3.11.400 / 3.20.100 | |
| org.osgi.framework | 1.10.0 | |
| maven-artifact | **3.9.16** | stay on 3.x; 4.0.0-rc-5 is not final |
| JUnit | 4.13.2 (drop-in) / 6.1.3 (migration) | JUnit 4 still fine for TestKit tests |
| ASM | **9.10.1** | test-only; reads current class-file versions |
| actions/checkout | v7.0.1 | |
| actions/setup-java | v6.0.1 | |
| actions/upload-artifact | v7.0.1 | |
| gradle/actions/setup-gradle | v6.3.0 | replaces deprecated `eskatos/gradle-command-action@v1` |

## Gradle 9 Code Changes Required (from codebase audit)

Integration tests already run `--warning-mode=fail`, so most deprecation fallout will be caught by `./gradlew build`. Known removals/replacements affecting this repo:

1. `Project.buildDir` → `Project.layout.buildDirectory` — used for default outlet dirs in `XtextBuilderPlugin.configureDefaults` (line ~109).
2. `project.tasks.create(...)` → `tasks.register(...)` — 3 sites in `XtextBuilderPlugin` (generator task, `clean*` task, `xtextEclipseSettings`).
3. Eager `tasks.getByName` / `getAt(...)` → `tasks.named(...)` — `compileJava` lookup, `eclipse`/`cleanEclipse` wiring.
4. `org.gradle.api.internal.file.FileOperations` (internal API) injected in `DefaultXtextSourceDirectorySet` / `DefaultXtextSourceSetOutputs` — replace with `Project.files(...)`/`ObjectFactory.fileCollection()` equivalents; internal APIs are not guaranteed across majors.
5. `reports.html.destination` / `reports.junitXml.destination` setters in plugin `build.gradle` → `reports.html.outputLocation.set(...)` providers.
6. `pluginBundle {}` block → `gradlePlugin { website = ...; vcsUrl = ...; tags = [...] }` (plugin-publish ≥1.0).
7. Root buildscript's `nebula.facet` apply → `com.netflix.nebula.facet` (or hand-roll the `integTest` source set — it is ~15 lines and removes a buildscript dependency that may lag Gradle 9).
8. `XtextGenerate` static initializer writes a temp jar via Guava `Files`/`Resources` — fine on Gradle 9, but replace deprecated `com.google.common.io.Files.asByteSink` usage when bumping Guava if desired.
9. TestKit: running old Gradle versions (7.x) from a Gradle 9 build requires an explicit `javaLauncher` with an old JDK on the test executor, because the forked daemon JVM must match what that Gradle version supports. Either keep per-matrix launchers (JDK 17 for min, JDK 25 for latest) or raise the minimum.

## Phased Plan (original research; phases 0–2 executed, see Status above)

Each phase leaves the build green. After every phase run at minimum `./gradlew test`; after task/plugin changes run `./gradlew minimumIntegrationTest`.

### Phase 0 — Baseline & safe dependency bumps (Gradle 7.2-compatible)
*Goal: refresh everything that doesn't require Gradle changes.*

- JUnit `4.12` → `4.13.2` (root `build.gradle`).
- ASM `6.1.1`/`9.4` → `9.10.1` (root + plugin `build.gradle`).
- Guava `27.1-jre` → `33.4.8-jre` (protocol + plugin `build.gradle`).
- equinox `3.6.1`/`3.8.0` → `3.11.400`/`3.20.100`; OSGi `1.8.0` → `1.10.0`; `maven-artifact` `3.8.2` → `3.9.16` (plugin `build.gradle`).
- Bootstrap plugin `2.0.9` → `4.0.0` (root buildscript; needed for Gradle 8 bootstrap support later).
- Verify: `./gradlew build` on JDK 11.

### Phase 1 — Gradle 7.2 → 8.14 (bridge)
*Goal: get onto a wrapper that modern JDKs can run, before the breaking 9.x jump.*

- Wrapper: `./gradlew wrapper --gradle-version 8.14` (last 8.x line).
- Migrate `pluginBundle {}` → `gradlePlugin {}` metadata; bump plugin-publish `0.15.0` → `1.x` compatible with Gradle 8.
- nebula: `8.2.0` → `9.6.3` keeping old plugin ids, **or** replace the facet with explicit `integTest` source set wiring (preferred — one less Gradle-9 risk).
- Fix all deprecation warnings surfaced by `--warning-mode=fail` (the Phase "Gradle 9 code changes" list above is the backlog; do 1–5 here).
- Raise `latestGradleVersion` in `gradle.properties` 8.0 → 9.x *after* Phase 2 only; here you may bump to 8.14.
- CI can move to JDK 17 now.

### Phase 2 — Gradle 8 → 9.7.1 + JDK 25 toolchain
*Goal: the headline upgrade.*

- Wrapper: `./gradlew wrapper --gradle-version 9.7.1`.
- Build/runtime toolchains: compile with `JavaLanguageVersion.of(17)` minimum (Gradle 9 consumers run Java 17+); CI matrix: 17 + 25.
- `minimumGradleVersion`: raise 7.1 → 8.0 (or 8.14) and document it as the new consumer-facing floor — keep in sync with any compat statement in `LazyXtextVersion`-style runtime checks (Gradle version is not enforced at runtime today; only the test matrix advertises it).
- `latestGradleVersion` → `9.7.1`; ensure `latestIntegrationTest` TestKit runs pass with a JDK 25 `javaLauncher` (Gradle ≥9.1 required for JDK 25).
- For `minimumIntegrationTest` (old Gradle + old Xtext): set an explicit `javaLauncher` on JDK 17 (Gradle 7/8 forks can't use JDK 25).
- Remaining removals from the code-change list (internal `FileOperations` if not done, `tasks.create` leftovers) — `--warning-mode=fail` + Gradle 9 upgrade report (`./gradlew build --upgrade`) will enumerate them.
- If nebula was kept: verify `com.netflix.nebula.facet` 9.6.3+ on Gradle 9, else use the hand-rolled source set.

### Phase 3 — Xtext test matrix & runtime deps
- `latestXtextVersion` 2.29.0 → **2.44.0**; check its Java requirement (Xtext releases in the 2.37+ era target Java 17 — adjust the integration-test launcher accordingly).
- Plugin `implementation "org.eclipse.xtend:org.eclipse.xtend.lib:$minimumXtextVersion"` — evaluate raising the *plugin's own compile-time* Xtend lib off the floor (e.g. a `libVersion` distinct from the supported minimum) so newer Xtext APIs can be used at compile time while the runtime floor stays 2.17.1. Keep the runtime minimum raise as a deliberate, documented major-version decision (it's a compatibility promise; string literal in `XtextBuilderPlugin` + `gradle.properties` must change together).
- `xtext-dev-bom` enforced platform follows the resolved version automatically.

### Phase 4 — CI modernization
- `actions/checkout@v2` → `@v7`, `actions/setup-java@v1` → `@v6` (use `distribution: temurin`, `java-version: '17'` + `25` matrix entries and toolchain auto-provisioning).
- `eskatos/gradle-command-action@v1` → `gradle/actions/setup-gradle@v6` (action wraps the build; add `gradle-version` or rely on wrapper).
- `actions/upload-artifact@v2` → `@v7`.
- `battila7/get-version-action@v2` → plain shell: `VERSION=${GITHUB_REF_NAME#v}` (or keep and switch to `mlugg/setup-get-version`).
- Update `release.yml` to publish with plugin-publish 2.2.1 (`publishPlugins` unchanged; key/secret env vars unchanged).

### Phase 5 — Optional polish
- JUnit 4 → JUnit 6 (`junit-jupiter` 6.1.3) with `useJUnitPlatform()`; TestKit tests migrate mechanically (`@Test` imports + `ExternalResource` → `@ExtendWith`). Low urgency.
- Replace `pTML` alias with `publishToMavenLocal` (works as-is today).
- Consider `DependencyVerification`/wrapping SHA for the new wrapper distribution (`gradle-wrapper.validation`/checksum pinning from the version API).

## Risk Register

| Risk | Mitigation |
|---|---|
| Bootstrap chicken-and-egg: build scripts are compiled by a released version of this very plugin | Phase the buildscript bumps; keep the released bootstrap on a version known to run on the wrapper being adopted (4.0.0 for Gradle 8; re-verify on 9 before committing) |
| Old matrix (`minimumIntegrationTest`) can't fork on modern JDKs | explicit `javaLauncher` per matrix (17 for min, 25 for latest), or raise minimum Gradle/Xtext |
| `FilteringClassLoader` whitelist vs new Gradle distribution modules | integration tests run real builds through the isolated classloader — keep `--warning-mode=fail` and full matrix runs before releasing |
| nebula facet lag on Gradle 9 | drop nebula; hand-roll the `integTest` source set (~15 lines) |
| Plugin consumers on Java 8–16 | publishing built on Gradle 9 implies consumers run Gradle 9 ⇒ Java 17+; announce minimum-version bump as a major release (5.0.0) |
| protocol/builder binary compatibility while bumping Guava on both sides | protocol and embedded builder ship atomically inside the plugin jar; still, run the full `build` matrix after Phase 0 |

## Verification Checklist (run after each phase)

```bash
./gradlew test
./gradlew minimumIntegrationTest
./gradlew latestIntegrationTest
./gradlew build          # everything, both matrices
```

Plus one manual TestKit smoke test against a consumer project using the newly published local plugin (`pTML -PreleaseVersion=<next>-SNAPSHOT`).
