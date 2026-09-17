package org.xtext.gradle.tasks.internal

import java.io.File
import java.net.URLClassLoader
import java.util.LinkedHashMap
import java.util.ServiceLoader
import java.util.Set
import org.xtext.gradle.protocol.IncrementalXtextBuilder
import org.xtext.gradle.protocol.IncrementalXtextBuilderFactory

class IncrementalXtextBuilderProvider {

	static val Object providerLock = new Object
	static val LinkedHashMap<Long, Entry> cache = new LinkedHashMap
	static val int idleCacheSize = Integer.getInteger("org.xtext.gradle.builder.idleCacheSize", 2)

	/**
	 * Runs the action against the builder for the given language setups, encoding and
	 * classpath. Builders are keyed by checksum; uses of the same builder are
	 * serialized and a builder's classloader is only closed once no action is
	 * running against it, so parallel tasks can never observe a closed classloader,
	 * a half-updated index, or flipped EMF global registrations.
	 */
	static def <T> T withBuilder(Set<String> languageSetups, String encoding, Set<File> xtextClasspath,
		(IncrementalXtextBuilder)=>T action) {
		val checksum = getCheckSum(languageSetups, encoding, xtextClasspath)
		val entry = synchronized (providerLock) {
			var existing = cache.get(checksum)
			if (existing === null) {
				existing = createEntry(languageSetups, encoding, xtextClasspath, checksum)
				cache.put(checksum, existing)
			}
			existing.leases++
			existing
		}
		try {
			val previousLoader = Thread.currentThread().getContextClassLoader
			Thread.currentThread().setContextClassLoader(entry.classLoader)
			try {
				synchronized (entry.useLock) {
					return action.apply(entry.builder)
				}
			} finally {
				Thread.currentThread().setContextClassLoader(previousLoader)
			}
		} finally {
			release(entry)
		}
	}

	private static def release(Entry entry) {
		val evicted = synchronized (providerLock) {
			entry.leases--
			entry.lastUsed = System.nanoTime
			evictIdleBuilders
		}
		evicted.forEach [
			try {
				classLoader.close
			} catch (Exception e) {
				// the entry is unreachable for new leases at this point, closing is best effort
			}
		]
	}

	private static def evictIdleBuilders() {
		val excess = cache.values.filter[leases == 0].size - idleCacheSize
		if (excess <= 0) {
			return emptyList
		}
		val evicted = cache.values.filter[leases == 0].sortBy[lastUsed].take(excess).toList
		evicted.forEach [
			cache.remove(checksum)
		]
		evicted
	}

	private static def Entry createEntry(Set<String> languageSetups, String encoding, Set<File> xtextClasspath,
		long checksum) {
		val classLoader = getBuilderClassLoader(xtextClasspath)
		try {
			val loader = ServiceLoader.load(IncrementalXtextBuilderFactory, classLoader)
			val providers = loader.iterator
			if (providers.hasNext()) {
				return new Entry(checksum, providers.next().get(languageSetups, encoding), classLoader)
			}
			throw new IllegalStateException('''No «IncrementalXtextBuilderFactory.name» found on the classpath''');
		} catch (Exception e) {
			try {
				classLoader.close
			} catch (Exception closeException) {
				// nothing we can do, the primary exception is propagated below
			}
			throw e
		}
	}

	private static def getBuilderClassLoader(Set<File> xtextClasspath) {
		val parent = IncrementalXtextBuilderProvider.classLoader
		val filtered = new FilteringClassLoader(parent,
			#["org.gradle", "org.apache.log4j", "org.slf4j", "org.xtext.gradle"])
		new URLClassLoader(xtextClasspath.map[toURI.toURL], filtered)
	}

	private static def long getCheckSum(Set<String> languageSetups, String encoding, Set<File> xtextClasspath) {
		var long hash = 0
		for (setup : languageSetups) {
			hash = setup.hashCode + hash * 31
		}
		hash = encoding.hashCode + hash * 31
		for (classpathEntry : xtextClasspath) {
			hash = classpathEntry.path.hashCode + classpathEntry.lastModified.hashCode + hash * 31
		}
		hash
	}

	private static class Entry {
		val long checksum
		val IncrementalXtextBuilder builder
		val URLClassLoader classLoader
		val Object useLock = new Object
		int leases
		long lastUsed

		new(long checksum, IncrementalXtextBuilder builder, URLClassLoader classLoader) {
			this.checksum = checksum
			this.builder = builder
			this.classLoader = classLoader
		}
	}
}
