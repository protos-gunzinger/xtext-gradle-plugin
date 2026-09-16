# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## Project Overview

This repo builds the `org.xtext.builder` and `org.xtext.xtend` Gradle plugins, which run Xtext/Xtend code generators inside Gradle builds. It is a 3-module Gradle build:

- `xtext-gradle-protocol/` — plain-Java API shared across the plugin↔builder classloader boundary (no Xtext deps)
- `xtext-gradle-builder/` — Xtend wrapper around Xtext's `IncrementalBuilder`; all Xtext deps are `compileOnly`, jar is dependency-free and shipped as a resource inside the plugin jar
- `xtext-gradle-plugin/` — the published Gradle plugins, DSL, tasks, integration tests

Most source code is **Xtend** (`.xtend` files), not Java. Xtend compiles to Java via the bootstrap plugin (`org.xtext:xtext-gradle-plugin` from the Plugin Portal, see buildscript block in root `build.gradle`). Generated Java lands in `build/src/main/xtext-gen/` — never edit those files.

## Build & Verify Commands

```bash
./gradlew build                          # full verification (unit + 2 integration test matrices)
./gradlew test                           # unit tests only (fast)
./gradlew minimumIntegrationTest -PminTestJavaHome=$JAVA11_HOME   # oldest supported Gradle/Xtext combo
./gradlew latestIntegrationTest          # newest tested Gradle/Xtext combo
./gradlew pTML -PreleaseVersion=1.0.22-SNAPSHOT   # install locally
```

Notes:
- `-PreleaseVersion` is required for any task that needs the version (it maps to `project.version`); publishing without it produces version `null`.
- Integration tests execute real Gradle builds via TestKit; they are slow. When touching task/plugin logic, run at least `minimumIntegrationTest` for the files you changed.
- Integration tests run with `--warning-mode=fail`. Any deprecation warning they surface is a real bug — fix it, don't suppress it.
- Tested Gradle/Xtext matrix versions live in `gradle.properties` (`minimumGradleVersion`, `latestGradleVersion`, `minimumXtextVersion`, `latestXtextVersion`).
- The build runs on **JDK 17** (Gradle 9.7.1 requires Java 17+); artifacts stay Java 11 bytecode via `options.release`. The minimum matrix daemon needs a **JDK 11** (`-PminTestJavaHome`). See `UPGRADE_PLAN.md` for why JDK 21/25 daemons are not possible yet (Xtext 2.29 tooling ceiling).
- **Bootstrap self-hosting:** the buildscript applies `org.xtext:xtext-gradle-plugin` from mavenLocal (`5.0.0-gradle9-SNAPSHOT`) to compile the Xtend sources. When the bootstrap plugin's own sources change in an incompatible way, republish with the fallback: point the buildscript classpath back to the released `4.0.0`, run `pTML -PreleaseVersion=5.0.0-gradle9-SNAPSHOT`, then point it back to the mavenLocal version.

## Architecture Essentials (read before editing)

1. **Classloader isolation is the core design.** The builder runs in a `URLClassLoader` whose parent is `FilteringClassLoader` (whitelist: `org.gradle`, `org.slf4j`, `org.apache.log4j`, `org.xtext.gradle`). The user's Xtext tooling jars are loaded exclusively in the child loader. Consequence: the protocol module must stay free of Xtext types, and types crossing the boundary must be JDK, whitelisted, or protocol classes.
2. **`IncrementalXtextBuilderProvider`** (plugin side) caches the builder keyed on a checksum of setups + encoding + tooling classpath. It closes and recreates the classloader when the checksum changes.
3. **Version inference** (`LazyXtextVersion` in `XtextBuilderPlugin`): explicit `xtext.version` → regex detection from classpath jar names → `xtextLanguages` configuration. The hard minimum Xtext version is duplicated in `XtextBuilderPlugin` (string literal `"2.17.1"`) and `gradle.properties` (`minimumXtextVersion`) — update both together.
4. **Indexing**: `GradleResourceDescriptions` (extends Xtext's `ChunkedResourceDescriptions`) keeps chunks per container (`projectDir:sourceSet`) and per classpath entry. Whole-jar re-indexing on change is a known TODO; do not assume fine-grained jar incrementality.
5. **Java integration**: outlets with `producesJava` become extra `srcDirs` of `compileJava`, `builtBy(generateXtext)`; debug info is installed in a `doLast` on `compileJava`.

## Code Conventions

- Source files use **tabs** for indentation.
- New task/task-related code should use the lazy `Provider`/`Property` API and `tasks.register`. Never access `task.project` at execution time (deprecated, fails under `--warning-mode=fail`); inject `ProjectLayout`/`ObjectFactory` or capture values at configuration time instead.
- Do not add dependencies to `xtext-gradle-builder` that would end up on its runtime classpath; everything Xtext-related there is `compileOnly` by design.
- Keep the protocol DTOs free of anything not loadable by the `FilteringClassLoader` parent whitelist.
- No comments unless truly necessary; match the existing (sparse) commenting style.

## Testing Guidance

- Unit tests: `xtext-gradle-plugin/src/test` (JUnit 4 + `ProjectBuilder`). Extend `AbstractPluginTest`.
- Integration tests: `xtext-gradle-plugin/src/integTest`, extend `AbstractIntegrationTest` / `AbstractXtendIntegrationTest`; use `GradleBuildTester` for fixtures and assertions (`shouldBeUpToDate`, `file('...').exists`, etc.).
- When changing generator behavior, `OutputSnapshot` is the tool for asserting which files were regenerated.
- SMAP/debug-info changes are verified by parsing `.class` files with ASM (test dependency).

## Common Pitfalls

- Changing protocol classes requires both sides to stay binary-compatible: the plugin embeds the protocol classes AND the builder jar from the same build — they are replaced atomically at build time, but the daemon may keep an old cached builder around (checksum-gated).
- `configurations.protocol.singleFile` in the plugin `processResources` assumes exactly one artifact; keep the `protocol` configuration non-transitive.
- The Xtend compiler in the bootstrap build script is an older released version of this very plugin — syntax/API changes to the build scripts may be constrained by what that released version supports.
- Don't bump `minimumXtextVersion`/`minimumGradleVersion` casually: they are advertised compatibility promises of the released plugin (enforced at runtime in `LazyXtextVersion`).

## References

- Xtext docs: https://www.eclipse.org/Xtext/documentation/
- Plugin user docs: https://xtext.github.io/xtext-gradle-plugin/
- Planned upgrades (Gradle/JDK/dependencies): see [UPGRADE_PLAN.md](UPGRADE_PLAN.md)
