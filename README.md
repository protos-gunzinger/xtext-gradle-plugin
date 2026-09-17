Xtext Gradle Plugin
===================

A set of [Gradle](https://gradle.org) plugins to build and use [Xtext](https://www.eclipse.org/Xtext/) languages and the [Xtend](https://www.eclipse.org/xtend/) programming language.

The user-facing documentation is hosted on the [project's website](https://xtext.github.io/xtext-gradle-plugin/).

- [Plugins](#plugins)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [How It Works](#how-it-works)
- [Configuration DSL Reference](#configuration-dsl-reference)
- [Building From Source](#building-from-source)
- [Testing](#testing)
- [Version Compatibility](#version-compatibility)
- [Releasing](#releasing)
- [License](#license)

Plugins
-------

This repository builds and publishes two Gradle plugins to the [Gradle Plugin Portal](https://plugins.gradle.org/):

| Plugin ID            | Implementation class          | Purpose                                                                 |
|----------------------|-------------------------------|-------------------------------------------------------------------------|
| `org.xtext.builder`  | `org.xtext.gradle.XtextBuilderPlugin` | Run Xtext code generators as part of any Gradle build (any DSL) |
| `org.xtext.xtend`    | `org.xtext.gradle.XtendLanguagePlugin` | First-class support for compiling Xtend sources |

`org.xtext.xtend` applies `org.xtext.builder` and pre-configures the Xtend language (setup class, Java-producing outlet, SMAP debugging support), so most of what is described here applies to both.

Quick Start
-----------

### Xtend

```groovy
plugins {
    id 'org.xtext.xtend' version '5.0.0'
}

repositories {
    mavenCentral()
}

dependencies {
    implementation 'org.eclipse.xtend:org.eclipse.xtend.lib:2.42.0'
}

// The Xtend compiler version used by the build
xtext {
    version = '2.42.0'
}
```

All `.xtend` files in the `java` and `resources` source sets are compiled to Java before `compileJava` runs, and the generated sources are placed under `build/xtend/main`.

Note that the version is configured on the `xtext` extension (there is no `version` element on `xtend`). It can be left out only if an `org.eclipse.xtext*` jar on the compile classpath or the `xtextLanguages` configuration allows the version to be inferred — the `org.eclipse.xtend.lib` dependency alone is not enough.

### A custom DSL

```groovy
plugins {
    id 'org.xtext.builder' version '5.0.0'
}

repositories {
    mavenCentral()
}

xtext {
    version = '2.42.0'
    languages {
        mydsl {
            setup = 'org.example.MyDslStandaloneSetup'
            fileExtensions = 'mydsl'        // defaults to the language name
            generator {
                outlet {
                    cleanAutomatically = true
                }
            }
        }
    }
}
```

Each Xtext source set gets a `generate<sourceSet>Xtext` task (e.g. `generateMainXtext`) that runs before `compileJava` whenever the language produces Java sources.

Project Structure
-----------------

The build is a small multi-project build (see `settings.gradle`):

| Module               | Language(s)      | Role |
|----------------------|------------------|------|
| `xtext-gradle-protocol` | Java          | The API contract (`IncrementalXtextBuilder`, request/response DTOs) shared between the plugin and the builder across a classloader boundary. Has no Xtext dependencies. |
| `xtext-gradle-builder`  | Xtend         | A small wrapper around Xtext's `IncrementalBuilder` implementing the protocol. Compiled against `compileOnly` Xtext dependencies, so the resulting jar has no dependencies of its own. |
| `xtext-gradle-plugin`   | Xtend         | The actual Gradle plugins, DSL extensions, tasks, and TestKit-based integration tests. This is the artifact published to the Gradle Plugin Portal. |

**Packaging:** the plugin jar embeds the protocol classes (unzipped into its own classes) and the builder jar as a resource (`xtext-gradle-builder.jar`). At runtime the builder jar is extracted to a temp file and loaded in an isolated `URLClassLoader` together with the Xtext "tooling" classpath resolved for each source set (see [How It Works](#how-it-works)).

How It Works
------------

1. **DSL registration** – `XtextBuilderPlugin` applies the `base` and `jvm-ecosystem` plugins and creates the `xtext` extension with `sourceSets` and `languages` containers. For every Xtext source set it registers a `generate<Name>Xtext` task (`XtextGenerate`) and a matching `clean*` task.
2. **Tooling classpath** – each source set gets an `xtextTooling<SourceSet>` configuration containing `org.eclipse.xtext` artifacts plus whatever the user adds to the `xtextLanguages` configuration. The Xtext version is aligned via a resolution strategy, inferred from (in order): the `xtext.version` property, jars on the compile classpath, or the `xtextLanguages` configuration. Versions below 2.38.0 are rejected.
3. **Classloader isolation** – the Xtext tooling jars and the embedded builder jar are loaded through a `URLClassLoader` whose parent is a `FilteringClassLoader`. That parent only exposes `org.gradle` (logging etc.), `org.slf4j`, `org.apache.log4j`, and the protocol packages from the plugin classloader, so the user's Xtext version is never polluted by classes from the Gradle daemon or the plugin itself. The builder implementation is discovered via `java.util.ServiceLoader` (`IncrementalXtextBuilderFactory`) and cached with a checksum so it is recreated only when setups, encoding, or the tooling classpath change.
4. **Incremental building** – `XtextGenerate` is a Gradle incremental task. Dirty/deleted files and changed classpath entries are forwarded in a `GradleBuildRequest`. The builder maintains a persisted index (`GradleResourceDescriptions`, chunks keyed by project/source set and classpath entry) and per-container source mappings, delegating the actual parsing, validation, linking, and generation to Xtext's `org.eclipse.xtext.build.IncrementalBuilder`. Validation issues are logged through the Gradle logger and failing validation fails the build.
5. **Java/Eclipse integration** – when the Java plugin is present, generated Java outlets are added as source dirs of `compileJava` (via `builtBy`), the generator runs before compilation, and debug info (SMAP or primary-source traces) is installed into the `.class` files after compilation. When the Eclipse plugin is present, an `xtextEclipseSettings` task writes `.settings/<language>.prefs` files and adds the Xtext nature/builder to the project.

Configuration DSL Reference
---------------------------

```groovy
xtext {
    version = '2.42.0'                   // optional; inferred otherwise

    sourceSets {
        // mirrors Gradle Java source sets; srcDirs, output, etc.
        main { }
    }

    languages {
        xtend {                            // name defaults fileExtensions and output dirs
            setup = 'org.eclipse.xtend.core.XtendStandaloneSetup'
            fileExtensions = 'xtend'
            generator {
                javaSourceLevel = '17'     // defaults to java.sourceCompatibility
                suppressWarningsAnnotation = true
                generatedAnnotation {
                    active = false
                    includeDate = false
                    comment = 'text'
                }
                outlets {
                    DEFAULT_OUTLET {       // every language gets one by default
                        producesJava = true
                        cleanAutomatically = true
                    }
                }
            }
            debugger {
                sourceInstaller = 'SMAP'   // NONE | SMAP | PRIMARY
                hideSyntheticVariables = true
            }
            validator {
                error 'MyErrorCode'        // override issue severities
                warning 'OtherCode'
                ignore 'YetAnotherCode'
            }
            preferences {                  // raw language preferences
                someKey = 'someValue'
            }
        }
    }
}

dependencies {
    xtextLanguages 'org.example:org.example.mydsl:1.0.0' // your language jar
}
```

Building From Source
--------------------

Requirements:

- **JDK 17 or 21** to run the build (Gradle 9.7.1 requires Java 17+; artifacts are compiled to Java 17 bytecode via `options.release`).
- No additional JDK is needed for the test matrices: both `minimumIntegrationTest` and `latestIntegrationTest` pin their daemons to JDK 17 via `javaLauncher`.
- Gradle: use the checked-in wrapper (`./gradlew`, currently Gradle 9.7.1).
- See [UPGRADE_PLAN.md](UPGRADE_PLAN.md) for the dependency upgrade history and remaining work.

```bash
# Build everything (compiles, runs unit + integration test matrices)
./gradlew build

# Build and install into the local Maven repository
./gradlew pTML -PreleaseVersion=5.0.0-SNAPSHOT

# Skip the (slow) integration tests
./gradlew build -x minimumIntegrationTest -x latestIntegrationTest
```

The build bootstraps itself: it uses the previously released `org.xtext:xtext-gradle-plugin` from the Plugin Portal (see `build.gradle` buildscript block) to compile its own Xtend sources.

Testing
-------

- **Unit tests** (`xtext-gradle-plugin/src/test`) use JUnit 4 with Gradle's `ProjectBuilder` test fixtures to verify plugin wiring without executing a build.
- **Integration tests** (`xtext-gradle-plugin/src/integTest`) use Gradle TestKit (`GradleRunner`) to run real builds of sample projects:
    - `minimumIntegrationTest` – the oldest supported Gradle/Xtext combination (defaults in `gradle.properties`)
    - `latestIntegrationTest` – the newest tested combination (runs on a JDK 17 launcher)
    - Integration builds run with `--warning-mode=fail`, so any Gradle deprecation warning fails the tests. Keep it that way.
- `GradleBuildTester` provides the fluent test harness (project fixtures under `build/gradle-test`, file assertions, task outcome assertions). `OutputSnapshot` verifies incremental builds regenerate only what changed; ASM is used to verify SMAP debug info in compiled classes.

Run only the tests:

```bash
./gradlew test                        # unit tests
./gradlew minimumIntegrationTest      # oldest supported matrix combo
./gradlew latestIntegrationTest      # newest tested matrix combo
```

Version Compatibility
---------------------

Current support matrix (see `gradle.properties` for the tested versions):

| Component | Supported range |
|-----------|-----------------|
| Gradle    | 8.0 – 9.7.1 (tested) |
| Xtext/Xtend | 2.38.0 (hard minimum) – 2.42.0 (tested) |
| Java      | artifacts are Java 17 bytecode; consumer daemons run on JDK 17–21 |

This support matrix ships as the **5.x release line**. A follow-up release — built on top of this one and released separately later — is planned to raise the JDK floor to 21, support JDK 25 consumer daemons and adopt the current Xtext versions (2.43+); it will be announced as its own major version bump.

An upgrade history is documented in [UPGRADE_PLAN.md](UPGRADE_PLAN.md).

Releasing
---------

Releases are published to the Gradle Plugin Portal automatically by the [Release workflow](.github/workflows/release.yml) when a GitHub release is published. It requires the `GRADLE_PUBLISH_KEY` and `GRADLE_PUBLISH_SECRET` repository secrets. The GitHub release tag determines the version (`-PreleaseVersion=<tag>`).

License
-------

The project is licensed under the [Eclipse Public License](LICENSE).
