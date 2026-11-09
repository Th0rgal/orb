package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbConnectionIssueTest {
    private val lanError = "Failed to connect to /192.168.1.5:8080"

    @Test fun privateAddresses() {
        listOf(
            "http://192.168.1.5:8080", "http://10.0.0.2", "http://172.20.1.1:3000", "http://127.0.0.1:8080",
            "http://localhost:8080", "http://mac.local:8080", "http://100.101.2.3", "http://[fd00::1]:80", "http://devbox:8080"
        ).forEach { assertTrue(it, OrbConnection.isPrivateAddress(it)) }
        listOf("https://agent-backend.thomas.md", "https://8.8.8.8", "http://172.32.0.1", "https://example.com")
            .forEach { assertFalse(it, OrbConnection.isPrivateAddress(it)) }
    }

    @Test fun unreachableDetection() {
        assertTrue(OrbConnection.isUnreachable(lanError))
        assertTrue(OrbConnection.isUnreachable("Unable to resolve host \"x.example\""))
        assertTrue(OrbConnection.isUnreachable("timeout"))
        assertFalse(OrbConnection.isUnreachable("HTTP 401 Unauthorized"))
        assertFalse(OrbConnection.isUnreachable(null))
    }

    @Test fun lanFailureWithDefaultOnlineRecommendsDefault() {
        val issue = OrbConnection.issue("http://192.168.1.5:8080/", lanError, defaultReachable = true)
        assertNotNull(issue); issue!!
        assertEquals("http://192.168.1.5:8080", issue.serverURL)
        assertTrue(issue.offerUseDefault)
        assertTrue(issue.recommendDefault)
        assertTrue(issue.message.contains("default Orb server is online"))
        assertFalse(issue.title.contains("/192.168"))
    }

    @Test fun lanFailureWhileProbePendingOrDefaultDown() {
        for (reach in listOf(null, false)) {
            val issue = OrbConnection.issue("http://192.168.1.5:8080", lanError, reach)!!
            assertTrue(issue.offerUseDefault)
            assertFalse(issue.recommendDefault)
        }
    }

    @Test fun defaultServerFailureOffersNoUseDefault() {
        val issue = OrbConnection.issue("https://agent-backend.thomas.md/", "timeout", defaultReachable = true)!!
        assertFalse(issue.offerUseDefault)
        assertFalse(issue.recommendDefault)
    }

    @Test fun publicCustomServerOffersDefaultWithoutRecommending() {
        val issue = OrbConnection.issue("https://orb.example.com", "Unable to resolve host", defaultReachable = true)!!
        assertTrue(issue.offerUseDefault)
        assertFalse(issue.recommendDefault)
    }

    @Test fun httpErrorsAreNotConnectionIssues() {
        assertNull(OrbConnection.issue("http://192.168.1.5:8080", "HTTP 500", true))
    }

    @Test fun probeOnlyWhenItCanChangeTheAdvice() {
        assertTrue(OrbConnection.shouldProbeDefault("http://192.168.1.5:8080", lanError))
        assertFalse(OrbConnection.shouldProbeDefault("https://agent-backend.thomas.md", lanError))
        assertFalse(OrbConnection.shouldProbeDefault("https://orb.example.com", lanError))
        assertFalse(OrbConnection.shouldProbeDefault("http://192.168.1.5:8080", "HTTP 401"))
    }

    @Test fun deadSystemProxyIsNamedInsteadOfBlamingTheServer() {
        val issue = OrbConnection.issue(
            "https://agent-backend.thomas.md", lanError, defaultReachable = null, proxy = "192.168.1.5:8080"
        )!!
        assertEquals("192.168.1.5:8080", issue.proxy)
        assertTrue(issue.message.contains("proxy at 192.168.1.5:8080"))
        assertFalse(issue.offerUseDefault)
        assertFalse(issue.recommendDefault)
    }

    @Test fun proxyUnrelatedToTheErrorIsIgnored() {
        val issue = OrbConnection.issue("http://192.168.1.5:8080", lanError, true, proxy = "10.0.0.9:3128")!!
        assertNull(issue.proxy)
        assertTrue(issue.recommendDefault)
    }

    @Test fun candidateEndpointsPairDirectAndFallback() {
        assertEquals(
            listOf(
                "https://orbcore.thomas.md",
                "https://agent-backend.thomas.md",
                "https://agent-backend.nico-best-pc-ever.ovh"
            ),
            OrbConnection.candidateEndpoints("https://orbcore.thomas.md/")
        )
        assertEquals(
            listOf(
                "https://agent-backend.nico-best-pc-ever.ovh",
                "https://agent-backend.thomas.md",
                "https://orbcore.thomas.md"
            ),
            OrbConnection.candidateEndpoints("https://agent-backend.nico-best-pc-ever.ovh/")
        )
        assertEquals(
            listOf(
                "https://agent-backend.thomas.md",
                "https://orbcore.thomas.md",
                "https://agent-backend.nico-best-pc-ever.ovh"
            ),
            OrbConnection.candidateEndpoints("https://agent-backend.thomas.md")
        )
        assertEquals(
            listOf("https://orb.example.com"),
            OrbConnection.candidateEndpoints("https://orb.example.com")
        )
        assertTrue(OrbConnection.isFastRetryableStatus(502))
        assertTrue(OrbConnection.isFastRetryableStatus(524))
        assertFalse(OrbConnection.isFastRetryableStatus(500))
        assertFalse(OrbConnection.isFastRetryableStatus(401))
    }

    @Test fun idempotencyKeyAttachmentEligibility() {
        assertTrue(OrbConnection.shouldAttachIdempotencyKey("POST", "/api/control/missions"))
        assertTrue(OrbConnection.shouldAttachIdempotencyKey("PATCH", "/api/control/missions/m1/settings"))
        assertTrue(OrbConnection.shouldAttachIdempotencyKey("DELETE", "/api/control/missions/m1"))
        assertFalse(OrbConnection.shouldAttachIdempotencyKey("GET", "/api/control/missions"))
        assertFalse(OrbConnection.shouldAttachIdempotencyKey("POST", "/api/auth/login"))
        assertFalse(OrbConnection.shouldAttachIdempotencyKey("POST", "/api/voice/transcribe?language=en"))
    }

    @Test fun transportEpochFallsBackEvenAfterEverReadyAndReprobesAfterCooldown() {
        val epoch = OrbCore.TransportEpochState()
        val base = "https://agent-backend.thomas.md"
        assertTrue(epoch.evaluateForConnect(base, 1_000L, 0L).allowWebSocket)
        epoch.noteWsReady(1_100L)
        assertTrue(epoch.everReady)

        val f1 = epoch.noteWsFailure(null, 2_000L, 0L)
        assertFalse(f1.fallbackToSse)
        assertEquals(0L, f1.sinceSeq)
        val f2 = epoch.noteWsFailure(null, 3_000L, 42L)
        assertFalse(f2.fallbackToSse)
        val f3 = epoch.noteWsFailure(null, 4_000L, 42L)
        assertTrue(f3.fallbackToSse)
        assertEquals(42L, f3.sinceSeq)
        assertEquals(OrbCore.TransportEpochState.MODE_SSE_FALLBACK, epoch.mode)

        val duringCooldown = epoch.evaluateForConnect(base, 33_999L, 99L)
        assertFalse(duringCooldown.allowWebSocket)
        assertEquals(99L, duringCooldown.sinceSeq)
        assertEquals(1L, epoch.reprobeDelayMs(33_999L))

        val highSeq = 0xFFFF_FFFFL + 77L
        val reprobe = epoch.evaluateForConnect(base, 34_000L, highSeq)
        assertTrue(reprobe.allowWebSocket)
        assertEquals(highSeq, reprobe.sinceSeq)
        assertEquals(OrbCore.TransportEpochState.MODE_WS_REPROBE, epoch.mode)
        assertNull(epoch.reprobeDelayMs(34_000L))

        val reprobeFail = epoch.noteWsFailure(null, 34_500L, highSeq)
        assertTrue(reprobeFail.fallbackToSse)
        assertEquals(highSeq, reprobeFail.sinceSeq)
        assertEquals(30_000L, epoch.reprobeDelayMs(34_500L))

        val reprobe2 = epoch.evaluateForConnect(base, 64_500L, highSeq)
        assertTrue(reprobe2.allowWebSocket)
        assertEquals(highSeq, reprobe2.sinceSeq)
        epoch.noteWsReady(64_600L)
        assertEquals(OrbCore.TransportEpochState.MODE_WS_ACTIVE, epoch.mode)
        assertEquals(0, epoch.failureStreak)
    }

    @Test fun transportEpochStickyHttpUnsupportedClearsOnBuildOrEndpointChange() {
        val epoch = OrbCore.TransportEpochState()
        val customA = "https://orb-a.example.com"
        val customB = "https://orb-b.example.com"
        epoch.applyEndpoint(customA, 1_000L)
        epoch.noteServerBuild("0.9.0", 1_000L)

        val unsupported = epoch.noteWsFailure(404, 2_000L, 17L)
        assertTrue(unsupported.fallbackToSse)
        assertTrue(epoch.stickyUnsupported)
        assertNull(epoch.reprobeDelayMs(2_000L))
        assertEquals(17L, unsupported.sinceSeq)
        assertFalse(epoch.evaluateForConnect(customA, 500_000L, 17L).allowWebSocket)

        val upgradedSeq = epoch.noteServerBuild("0.10.0", 500_100L, 18L)
        assertEquals(18L, upgradedSeq)
        assertFalse(epoch.stickyUnsupported)
        assertTrue(epoch.evaluateForConnect(customA, 500_200L, 18L).allowWebSocket)

        epoch.noteWsFailure(426, 500_500L, 19L)
        assertTrue(epoch.stickyUnsupported)
        assertNull(epoch.reprobeDelayMs(500_500L))
        epoch.noteServerBuild("0.10.1", 500_600L, 19L)
        assertFalse(epoch.stickyUnsupported)

        epoch.noteWsFailure(501, 501_000L, 20L)
        assertTrue(epoch.stickyUnsupported)
        val switched = epoch.evaluateForConnect(customB, 501_100L, 20L)
        assertTrue(switched.allowWebSocket)
        assertFalse(epoch.stickyUnsupported)
        assertEquals(20L, switched.sinceSeq)
    }

    @Test fun syncHubTeardownDrainsActiveSubscribersWithoutStrandingWaiters() {
        val dummyReq = okhttp3.Request.Builder().url("https://orbcore.thomas.md/api/control/stream").build()
        var closedFirst = 0
        var closedSecond = 0
        var closedCancelled = 0
        val reprobeJob = kotlinx.coroutines.Job()

        val throwingSub = OrbCore.SyncStreamSub(
            id = "sub-1",
            missionId = "m-1",
            kindFilter = null,
            sinceSeq = 10L,
            request = dummyReq,
            onEvent = { _, _ -> },
            onClosed = {
                closedFirst += 1
                throw IllegalStateException("listener error must not abort remaining drain")
            },
            fallbackFactory = {},
            reprobeJob = reprobeJob,
        )
        val healthySub = OrbCore.SyncStreamSub(
            id = "sub-2",
            missionId = null,
            kindFilter = "presentation",
            sinceSeq = null,
            request = dummyReq,
            onEvent = { _, _ -> },
            onClosed = { closedSecond += 1 },
            fallbackFactory = {},
        )
        val cancelledSub = OrbCore.SyncStreamSub(
            id = "sub-3",
            missionId = "m-3",
            kindFilter = null,
            sinceSeq = 5L,
            request = dummyReq,
            onEvent = { _, _ -> },
            onClosed = { closedCancelled += 1 },
            fallbackFactory = {},
            cancelled = true,
        )

        OrbCore.drainSyncSubscribersOnHubClose(null, listOf(throwingSub, healthySub, cancelledSub))

        assertTrue(reprobeJob.isCancelled)
        assertNull(throwingSub.reprobeJob)
        assertEquals(1, closedFirst)
        assertEquals(1, closedSecond)
        assertEquals(0, closedCancelled)
    }
}
