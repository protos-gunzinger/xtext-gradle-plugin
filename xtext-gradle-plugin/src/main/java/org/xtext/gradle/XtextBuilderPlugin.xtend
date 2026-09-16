package org.xtext.gradle;

import java.io.File
import java.util.LinkedHashSet
import java.util.Set
import java.util.concurrent.Callable
import org.apache.maven.artifact.versioning.ComparableVersion
import org.gradle.api.Action
import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.Task
import org.gradle.api.artifacts.Configuration
import org.gradle.api.plugins.JavaBasePlugin
import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.tasks.TaskProvider
import org.gradle.api.tasks.compile.JavaCompile
import org.gradle.plugins.ide.eclipse.EclipsePlugin
import org.gradle.plugins.ide.eclipse.model.EclipseModel
import org.xtext.gradle.tasks.Outlet
import org.xtext.gradle.tasks.XtextEclipseSettings
import org.xtext.gradle.tasks.XtextExtension
import org.xtext.gradle.tasks.XtextGenerate
import org.xtext.gradle.tasks.XtextSourceDirectorySet
import org.xtext.gradle.protocol.GradleInstallDebugInfoRequest.SourceInstaller

class XtextBuilderPlugin implements Plugin<Project> {

	Project project
	XtextExtension xtext
	Configuration xtextLanguages

	override void apply(Project project) {
		this.project = project

		project.plugins.apply("base")
		project.plugins.apply("jvm-ecosystem")

		xtext = project.extensions.create("xtext", XtextExtension);
		xtextLanguages = project.configurations.create("xtextLanguages")
		createGeneratorTasks
		configureDefaults
		integrateWithJavaPlugin
		integrateWithEclipsePlugin
	}

	private def createGeneratorTasks() {
		xtext.sourceSets.all [ sourceSet |
			val generatorTask = project.tasks.register(sourceSet.generatorTaskName, XtextGenerate) [
				sources = sourceSet
				sourceSetOutputs = sourceSet.output
				languages = xtext.languages
				projectName = project.name
				projectDir = project.projectDir
				options.incremental.convention(project.providers.provider [true])
				options.encoding.convention(project.providers.provider ["UTF-8"])
			]
			setupXtextClasspath(sourceSet, generatorTask)
			project.tasks.register('clean' + sourceSet.generatorTaskName.toFirstUpper, Delete) [
				delete([
					xtext.languages.map[generator.outlets].flatten.filter[cleanAutomatically.get].map [
						sourceSet.output.getDir(it)
					].toSet
				] as Callable<Set<File>>)
			]
		]
	}

	private def setupXtextClasspath(XtextSourceDirectorySet sourceSet, TaskProvider<XtextGenerate> generatorTask) {
		val xtextTooling = project.configurations.create(sourceSet.qualifyConfigurationName("xtextTooling"))
		generatorTask.configure [
			xtextClasspath.from(xtextTooling)
		]
		xtextTooling.extendsFrom(xtextLanguages)
		#[
			'org.eclipse.xtext:org.eclipse.xtext',
			'org.eclipse.xtext:org.eclipse.xtext.smap',
			'org.eclipse.xtext:org.eclipse.xtext.xbase',
			'org.eclipse.xtext:org.eclipse.xtext.java'
		].forEach [
			project.dependencies.add(xtextTooling.name, it)
		]
		project.dependencies.add(xtextTooling.name,
			project.dependencies.enforcedPlatform('''org.eclipse.xtext:xtext-dev-bom'''))

		val xtextVersion = new LazyXtextVersion(xtext, xtextLanguages, generatorTask)
		xtextTooling.resolutionStrategy.eachDependency [
			val version = xtextVersion.getVersion
			if (version === null) {
				return
			}
			if (requested.group == "org.eclipse.xtext" || requested.group == "org.eclipse.xtend") {
				useVersion(version)
			}
		]
	}

	private def configureDefaults() {
		xtext.languages.all [ language |
			language.fileExtensions.convention(project.provider[#{language.name}])
			language.qualifiedName.convention(language.setup.map[it.replace("StandaloneSetup", "")])
			language.generator.outlets.create(Outlet.DEFAULT_OUTLET)
			language.generator.suppressWarningsAnnotation.convention(project.providers.provider [true])
			language.generator.generatedAnnotation.active.convention(project.providers.provider [false])
			language.generator.generatedAnnotation.includeDate.convention(project.providers.provider [false])
			language.debugger.sourceInstaller.convention(project.providers.provider [SourceInstaller.NONE.name])
			language.debugger.hideSyntheticVariables.convention(project.providers.provider [true])
			language.generator.outlets.all [ outlet |
				outlet.producesJava.convention(project.providers.provider [false])
				outlet.cleanAutomatically.convention(project.providers.provider [true])
			xtext.sourceSets.all [ sourceSet |
				val output = sourceSet.output
				output.dir(outlet, project.layout.buildDirectory.dir('''«language.name»«outlet.folderFragment»/«sourceSet.name»'''))
			]
			]
		]
	}

	private def integrateWithJavaPlugin() {
		project.plugins.withType(JavaBasePlugin) [
			project.apply[plugin(XtextJavaLanguagePlugin)]
			val java = project.extensions.getByType(JavaPluginExtension)
			xtext.languages.all [
				generator.javaSourceLevel.convention(project.provider[java.sourceCompatibility.majorVersion])
			]
			java.sourceSets.all [ javaSourceSet |
				val javaCompile = project.tasks.named(javaSourceSet.compileJavaTaskName, JavaCompile)
				xtext.sourceSets.maybeCreate(javaSourceSet.name) => [ xtextSourceSet |
					val generatorTask = project.tasks.named(xtextSourceSet.generatorTaskName, XtextGenerate)
					xtextSourceSet.srcDirs([javaSourceSet.java.srcDirs] as Callable<Set<File>>)
					xtextSourceSet.srcDirs([javaSourceSet.resources.srcDirs] as Callable<Set<File>>)
					javaSourceSet.allSource.srcDirs([
						val dslSources = new LinkedHashSet(xtextSourceSet.srcDirs)
						dslSources.removeAll(javaSourceSet.java.srcDirs)
						dslSources.removeAll(javaSourceSet.resources.srcDirs)
						dslSources
					] as Callable<Set<File>>)
					javaSourceSet.java.srcDirs([
						val javaProducingOutlets = xtext.languages.map[generator.outlets].flatten.filter[producesJava.get]
						project.files(javaProducingOutlets.map[xtextSourceSet.output.getDir(it)]).builtBy(generatorTask)
					] as Callable<Iterable<File>>)
					javaCompile.configure [
						dependsOn(generatorTask)
						doLast(new Action<Task>() {
							override void execute(Task it) {
								generatorTask.get().installDebugInfo(destinationDirectory.get.asFile)
							}
						})
					]
					generatorTask.configure [
						options.encoding.set(project.provider[javaCompile.get().options.encoding ?: "UTF-8"])
						classpath.from(project.provider[javaSourceSet.compileClasspath])
					]
				]
			]
		]
	}

	private def integrateWithEclipsePlugin() {
		project.plugins.withType(EclipsePlugin) [
			val settingsTask = project.tasks.register("xtextEclipseSettings", XtextEclipseSettings) [
				languages = xtext.languages
				sourceSets = xtext.sourceSets
			]
			project.tasks.named(EclipsePlugin.ECLIPSE_TASK_NAME).configure [
				dependsOn(settingsTask)
			]
			project.tasks.named("cleanEclipse").configure [
				dependsOn("cleanXtextEclipseSettings")
			]

			val eclipse = project.extensions.getByType(EclipseModel)
			eclipse.project.buildCommand("org.eclipse.xtext.ui.shared.xtextBuilder")
			eclipse.project.natures("org.eclipse.xtext.ui.shared.xtextNature")
			eclipse.synchronizationTasks(settingsTask)
		]
	}

	private static class LazyXtextVersion {
		val XtextExtension xtext
		val Configuration languages
		val TaskProvider<XtextGenerate> task
		var String version

		new(XtextExtension xtext, Configuration languages, TaskProvider<XtextGenerate> task) {
			this.xtext = xtext
			this.languages = languages
			this.task = task
		}

		def String getVersion() {
			if (version === null) {
				val generatorTask = task.get()
				version = xtext.getXtextVersion(generatorTask.classpath) ?: xtext.getXtextVersion(languages)
				if (version === null && !generatorTask.mainSources.empty) {
					throw new GradleException('''Could not infer Xtext classpath for «generatorTask», because xtext.version was not set and no xtext libraries were found in «generatorTask.classpath» or «languages»''')
				}
			}
			val minimumVersion = "2.38.0"
			if (version !== null && new ComparableVersion(version) < new ComparableVersion(minimumVersion)) {
				throw new GradleException('''Xtext «version» is no longer supported. The minimum version is «minimumVersion»''')

			}
			version
		}
	}
}
