package org.xtext.gradle.test

import org.junit.Test

class WhenUsingXtendForTestsOnly extends AbstractXtendIntegrationTest {

	override getImplementationScope() {
		'testImplementation'
	}

	@Test
	def theGeneratorShouldRunOnValidInput() {
		file('src/main/java/HelloWorld.java').content = '''
			public class HelloWorld {}
		'''

		file('src/test/java/HelloWorldTest.xtend').content = '''
			import org.junit.Test
			import static org.junit.Assert.*

			class HelloWorldTest {
				val helloWorld = new HelloWorld

				@Test
				def void canUseHelloWorld() {
					assertNotNull(helloWorld)
				}
			}
		'''

		build("build")

		file('build/xtend/test/HelloWorldTest.java').shouldExist
		file('build/xtend/test/.HelloWorldTest.java._trace').shouldExist
	}
}
