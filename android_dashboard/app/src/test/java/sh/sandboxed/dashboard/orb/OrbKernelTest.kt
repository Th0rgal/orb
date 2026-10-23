package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbKernelTest {
    @Test
    fun nativeJniLoadedAndSteppersMatchFixtures() {
        assertTrue("OrbKernel JNI library should load on JVM", OrbKernel.nativeLoaded)
        assertEquals("now", OrbKernel.relativeTimeString(0))
        assertEquals("now", OrbKernel.relativeTimeString(44))
        assertEquals("1m", OrbKernel.relativeTimeString(45))
        assertEquals("2h", OrbKernel.relativeTimeString(7200))
        assertEquals("3d", OrbKernel.relativeTimeString(259200))
        assertEquals("2w", OrbKernel.relativeTimeString(1209600))

        assertNull(OrbKernel.usageLimitBadge("allowed", "five_hour", true, 50, false, 0))
        val warn = OrbKernel.usageLimitBadge("allowed_warning", "five_hour", true, 84, false, 0)
        assertEquals(UsageLimitStatus("warning", "Approaching limit · 5h 84%"), warn)
        val rej = OrbKernel.usageLimitBadge("rejected", "five_hour", false, 0, true, 1800)
        assertEquals(UsageLimitStatus("error", "Limit reached · resets in 30m"), rej)

        val wf = OrbKernel.workfoldStep(2, false, true, true, true, false)
        assertTrue(wf.foldItem)
        val tsRaw = OrbKernel.orbTurnSummaryStep(2, 1, 0, 1)
        assertEquals(0x2000102L, tsRaw)

        assertTrue(OrbKernel.gfmPipeRowAdmitted(0, 12, 12, 3, 3, false))
        assertTrue(OrbKernel.richTagAdmitted(0, 24, 5, 14, 24, 1))
        assertEquals(1.toByte(), OrbKernel.leansysSseFrameScan(0, 60, 64, 1, 10))
        val patchRaw = OrbKernel.orbTranscriptPatchStep(10, 10, 1, 128)
        assertEquals(128L, patchRaw and 0xFFFF_FFFFL)
        assertEquals(11L, (patchRaw ushr 32) and 0xFFFF_FFFFL)
    }
}
