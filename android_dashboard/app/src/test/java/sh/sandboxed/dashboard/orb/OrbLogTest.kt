package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbLogTest {
    @Test
    fun ringKeepsLastFiftyAndTryLogsFailures() {
        OrbLog.logcatEnabled = false
        OrbLog.clear()
        repeat(60) { OrbLog.e(OrbLog.Category.Network, "e$it") }
        assertEquals(OrbLog.RING_SIZE, OrbLog.ring.value.size)
        assertEquals("e10", OrbLog.ring.value.first().message)
        OrbLog.clear()
        val r = orbTry(OrbLog.Category.Cache, "read") { error("boom") }
        assertTrue(r.isFailure)
        assertEquals("read failed", OrbLog.latest()?.message)
        OrbLog.d(OrbLog.Category.Cache, "debug only")
        assertEquals(1, OrbLog.ring.value.size)
    }
}
