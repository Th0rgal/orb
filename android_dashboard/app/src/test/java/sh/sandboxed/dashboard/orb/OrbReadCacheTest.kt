package sh.sandboxed.dashboard.orb

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import kotlinx.coroutines.runBlocking

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

    @Test
    fun navigationReadsDiskOnlyAsynchronously() = runBlocking {
        val rows = listOf(mapOf("id" to "old-answer", "content" to "Saved answer"))
        OrbDisk.write(key, rows)
        assertTrue(OrbReadCache.readMemoryRows(key).isEmpty())
        assertEquals("old-answer", OrbReadCache.loadRowsAsync(key).single().id)
        assertEquals("old-answer", OrbReadCache.readMemoryRows(key).single().id)
    }

    @Test
    fun globalSubsetCannotReplaceCompleteProjectCacheAfterMemoryClear() {
        val projectKey = "project_missions_$key"
        val complete = (1..100).map { mapOf("id" to "mission-$it") }
        OrbDisk.write(projectKey, complete)
        OrbReadCache.clearMemory()
        OrbReadCache.seedProjectRows(key, listOf(OrbRow(mapOf("id" to "mission-100", "status" to "completed"))), fresh = true)
        assertEquals(100, OrbReadCache.loadRows(projectKey).size)
        assertEquals("mission-1", OrbReadCache.loadRows(projectKey).first().id)
        assertEquals("completed", OrbReadCache.loadRows(projectKey).last().str("status"))
    }

    @Test
    fun globalSubsetSeedsProjectWhenNoFullCacheExists() {
        OrbReadCache.seedProjectRows(key, listOf(OrbRow(mapOf("id" to "recent"))))
        assertEquals("recent", OrbReadCache.readMemoryRows("project_missions_$key").single().id)
    }
}
