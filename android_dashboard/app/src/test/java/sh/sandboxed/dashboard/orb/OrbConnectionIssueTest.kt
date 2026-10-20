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
}
