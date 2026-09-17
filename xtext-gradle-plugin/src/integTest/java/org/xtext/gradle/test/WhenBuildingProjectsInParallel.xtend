package org.xtext.gradle.test

import org.junit.Test
import org.xtext.gradle.test.GradleBuildTester.ProjectUnderTest

class WhenBuildingProjectsInParallel extends AbstractXtendIntegrationTest {

	ProjectUnderTest projectA
	ProjectUnderTest projectB
	ProjectUnderTest projectC

	override protected applyXtendPlugin() {
		rootProject.buildFile << '''
			subprojects {
				«xtendPluginSnippet»
			}
		'''
	}

	override setup() {
		super.setup
		file('gradle.properties') << '''
			org.gradle.parallel=true
		'''
		projectA = rootProject.createSubProject("parallelA")
		projectB = rootProject.createSubProject("parallelB")
		projectC = rootProject.createSubProject("parallelC")
		projectA.createFile("src/main/java/HelloA.xtend", '''class HelloA {}''')
		projectB.createFile("src/main/java/HelloB.xtend", '''class HelloB {}''')
		projectC.createFile("src/main/java/HelloC.xtend", '''class HelloC {}''')
	}

	// the builder singleton is daemon-global and shared by checksum, so a unique
	// marker path on the tooling classpath guarantees that no daemon-warm builder
	// is reused and the cold-cache path runs under parallel execution
	private def useColdBuilderCache() {
		val marker = "tooling-marker-" + System.nanoTime
		rootProject.buildFile << '''
			subprojects {
				dependencies {
					xtextToolingMain files("«marker»")
				}
			}
		'''
	}

	@Test
	def void coldParallelBuildsOfEqualBuilderChecksumsAreSuccessful() {
		useColdBuilderCache
		build('build')
		projectA.file('build/xtend/main/HelloA.java').shouldExist
		projectB.file('build/xtend/main/HelloB.java').shouldExist
		projectC.file('build/xtend/main/HelloC.java').shouldExist
	}

	@Test
	def void coldParallelBuildsWithDifferentBuilderChecksumsAreSuccessful() {
		useColdBuilderCache
		// a different compiler encoding means a different builder checksum, so these
		// projects run against distinct builder classloaders at the same time and
		// trigger idle-cache eviction while the other builders may still be in use
		projectB.buildFile.append('''
			compileJava.options.encoding = 'ISO-8859-1'
		''')
		projectC.buildFile.append('''
			compileJava.options.encoding = 'US-ASCII'
		''')
		build('build')
		projectA.file('build/xtend/main/HelloA.java').shouldExist
		projectB.file('build/xtend/main/HelloB.java').shouldExist
		projectC.file('build/xtend/main/HelloC.java').shouldExist
	}

	@Test
	def void warmParallelRebuildsReuseTheBuilderIndex() {
		build('build')
		val secondResult = build('build')
		secondResult.getXtextTask(projectA).shouldBeUpToDate
		secondResult.getXtextTask(projectB).shouldBeUpToDate
		secondResult.getXtextTask(projectC).shouldBeUpToDate
	}
}
