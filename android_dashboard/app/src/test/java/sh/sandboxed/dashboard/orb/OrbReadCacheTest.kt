package sh.sandboxed.dashboard.orb

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** OrbReadCache has no TTL: entries live until replaced, cleared, or the account scope changes. */
class OrbReadCacheTest {
    private val key = "test_rows_${System.nanoTime()}"

    @Before
    fun setUp() {
        OrbDisk.setAccountScope("https://test.invalid", "token-${System.nanoTime()}")
        OrbReadCache.clearMemory()
    }

    @After
    fun tearDown() {
        OrbDisk.clearCurrentScope()
        OrbReadCache.clearMemory()
    }

    @Test
    fun memoryOnlyRowsAreGoneAfterClear() {
        OrbReadCache.saveRowsMemoryOnly(key, listOf(OrbRow(mapOf("id" to "a"))))
        assertTrue(OrbReadCache.hasRowsInMemory(key))
        assertEquals(listOf("a"), OrbReadCache.loadRows(key).map { it.id })
        OrbReadCache.clearMemory()
        assertFalse(OrbReadCache.hasRowsInMemory(key))
        assertTrue(OrbReadCache.loadRows(key).isEmpty())
    }

    @Test
    fun diskBackedRowsSurviveMemoryClear() {
        OrbDisk.write(key, listOf(mapOf("id" to "d1"), mapOf("id" to "d2")))
        assertEquals(listOf("d1", "d2"), OrbReadCache.loadRows(key).map { it.id })
        assertTrue(OrbReadCache.hasRowsInMemory(key))
    }

    @Test
    fun memoryWinsOverDiskUntilInvalidated() {
        OrbDisk.write(key, listOf(mapOf("id" to "disk")))
        OrbReadCache.saveRowsMemoryOnly(key, listOf(OrbRow(mapOf("id" to "mem"))))
        assertEquals("mem", OrbReadCache.loadRows(key).single().id)
        OrbReadCache.clearMemory()
        assertEquals("disk", OrbReadCache.loadRows(key).single().id)
    }

    @Test
    fun accountScopeIsolatesDiskEntries() {
        OrbDisk.write(key, mapOf("v" to 1))
        OrbDisk.setAccountScope("https://other.invalid", "other")
        assertNull(OrbReadCache.loadDict(key))
    }

    @Test
    fun clearCurrentScopeInvalidatesDisk() {
        OrbDisk.write(key, mapOf("v" to 1))
        OrbDisk.clearCurrentScope()
        assertNull(OrbDisk.read(key))
    }
}
