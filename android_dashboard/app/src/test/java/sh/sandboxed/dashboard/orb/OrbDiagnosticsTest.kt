package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbDiagnosticsTest {
    @Test
    fun readsCoreVersionFromHealth() {
        assertEquals("0.42.1", OrbDiagnostics.backendVersion(OrbJSON.parse("""{"status":"ok","version":"0.42.1"}""")))
        assertNull(OrbDiagnostics.backendVersion(OrbJSON.parse("""{"status":"ok"}""")))
        assertNull(OrbDiagnostics.backendVersion(OrbJSON.parse("""{"version":"  "}""")))
        assertNull(OrbDiagnostics.backendVersion(null))
    }

    @Test
    fun perfMonitorTracksFrameStallsAndRedactsSlowRequests() {
        OrbPerfMonitor.resetForTest()
        OrbPerfMonitor.recordFrameDurationMs(12L)
        OrbPerfMonitor.recordFrameDurationMs(48L)
        OrbPerfMonitor.recordSlowRequest(
            method = "GET",
            path = "/api/ai/usage/summary?window=7d&token=secret-value",
            durationMs = 2_400L,
            bytes = 2048,
            atEpochMs = 1_700_000_000_000L
        )
        // Fast requests stay out of the slow ring.
        OrbPerfMonitor.recordSlowRequest("GET", "/api/health", 120L, 64)

        val snap = OrbPerfMonitor.snapshot.value
        assertEquals(2L, snap.totalFrames)
        assertEquals(1L, snap.stalledFrames)
        assertEquals(48L, snap.worstFrameMs)
        assertEquals("1 / 2 (worst 48ms)", snap.stallsSummary())
        assertEquals(1, snap.slowRequests.size)
        assertEquals("/api/ai/usage/summary?window=7d&token=<redacted>", snap.slowRequests.single().path)

        val text = OrbDiagnostics.text(listOf("Version" to "1.38.0"), emptyList(), snap)
        assertTrue(text.contains("--- slow requests (oldest first) ---"))
        assertTrue(text.contains("token=<redacted>"))
        assertFalse(text.contains("secret-value"))
        OrbPerfMonitor.resetForTest()
    }

    @Test
    fun orbRowRevisionStampFastPathPreservesValueEquality() {
        val base = OrbRow(mapOf("id" to "m1", "status" to "running", "updated_at" to "2026-11-02T00:00:00Z", "title" to "Audit"))
        val identical = OrbRow(mapOf("id" to "m1", "status" to "running", "updated_at" to "2026-11-02T00:00:00Z", "title" to "Audit"))
        val updatedStatus = OrbRow(mapOf("id" to "m1", "status" to "completed", "updated_at" to "2026-11-02T00:00:05Z", "title" to "Audit"))
        val updatedNested = OrbRow(mapOf("id" to "m1", "status" to "running", "updated_at" to "2026-11-02T00:00:00Z", "title" to "Audit", "extra" to 1))

        assertEquals(base, identical)
        assertEquals(base.hashCode(), identical.hashCode())
        assertNotEquals(base, updatedStatus)
        assertNotEquals(base, updatedNested)
    }

    @Test
    fun inboxDigestClassifiesSettlingStatusesAsNonError() {
        assertTrue(OrbInboxDigestStore.isSettlingStatus(202))
        assertTrue(OrbInboxDigestStore.isSettlingStatus(409))
        assertTrue(OrbInboxDigestStore.isSettlingStatus(425))
        assertFalse(OrbInboxDigestStore.isSettlingStatus(500))
        assertFalse(OrbInboxDigestStore.isSettlingStatus(404))
    }
}
