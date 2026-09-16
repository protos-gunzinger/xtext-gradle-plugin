package org.xtext.gradle.tasks.internal

import java.util.Map
import javax.inject.Inject
import org.gradle.api.model.ObjectFactory
import org.xtext.gradle.tasks.Outlet
import org.xtext.gradle.tasks.XtextExtension
import org.xtext.gradle.tasks.XtextSourceSetOutputs

class DefaultXtextSourceSetOutputs implements XtextSourceSetOutputs {
	val ObjectFactory objects
	val Map<Outlet, Object> dirs = newLinkedHashMap

	@Inject
	new(XtextExtension xtext, ObjectFactory objects) {
		this.objects = objects
		xtext.languages.all [
			generator.outlets.whenObjectRemoved [
				dirs.remove(it)
			]
		]
	}

	override getDirs() {
		objects.fileCollection().from(dirs.values)
	}

	override getDir(Outlet outlet) {
		val dir = dirs.get(outlet)
		if (dir === null) {
			return null
		}
		objects.fileCollection().from(dir).singleFile
	}

	override dir(Outlet outlet, Object path) {
		dirs.put(outlet, path)
	}
}
