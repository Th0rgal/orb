package sh.sandboxed.dashboard.orb

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Privileged access labels match desktop and iOS via shared/orb-spec. */
class OrbPrivilegeAccessTest {
    @Test fun labelsMatchSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/privilege-access.json")["cases"])
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val r = c["request"] as Map<String, Any?>
            assertEquals(c["title"], OrbPrivilegeAccess.title(r))
            assertEquals(c["unlocks"], OrbPrivilegeAccess.unlocks(r))
            assertEquals(c["lifetime"], OrbPrivilegeAccess.lifetime(r))
            assertEquals(c["requester"], OrbPrivilegeAccess.requester(r))
        }
    }

    @Test fun onlyApprovedUnexpiredUnrevokedGrantsAreLive() {
        val now = Instant.parse("2026-10-25T12:00:00Z")
        val later = "2026-10-25T12:10:00Z"
        val earlier = "2026-10-25T11:50:00Z"
        assertTrue(OrbPrivilegeAccess.isLive(mapOf("state" to "approved", "expires_at" to later), now))
        assertFalse(OrbPrivilegeAccess.isLive(mapOf("state" to "pending", "expires_at" to later), now))
        assertFalse(OrbPrivilegeAccess.isLive(mapOf("state" to "approved", "expires_at" to earlier), now))
        assertFalse(OrbPrivilegeAccess.isLive(mapOf("state" to "approved", "expires_at" to later, "revoked_at" to earlier), now))
    }

    @Test fun approveKeepsTheRequestedLifetime() {
        assertEquals(
            mapOf("ttl_minutes" to 240, "session_scoped" to true),
            OrbPrivilegeAccess.approveBody(mapOf("ttl_minutes" to 240.0, "session_scoped" to true))
        )
    }

    @Test fun bunkerStateLabelsAndBody() {
        assertEquals("Normal", OrbPrivilegeAccess.bunkerLabel(0))
        assertEquals("Soft Quarantine", OrbPrivilegeAccess.bunkerLabel(1))
        assertEquals("Hard Lockdown", OrbPrivilegeAccess.bunkerLabel(2))
        assertEquals("Sovereign Dead-Man Tripped", OrbPrivilegeAccess.bunkerLabel(3))
        assertEquals(
            mapOf(
                "level" to 2,
                "reason" to "Canary test",
                "canary_tripped" to true,
                "auth_failure_burst" to false
            ),
            OrbPrivilegeAccess.bunkerBody(2, "Canary test")
        )
    }

    @Test
    fun bunkerCardShowsAboveNormalUntilDismissedAtThatLevel() {
        assertFalse(OrbPrivilegeAccess.showsBunkerCard(0, 0))
        assertTrue(OrbPrivilegeAccess.showsBunkerCard(2, 0))
        assertFalse(OrbPrivilegeAccess.showsBunkerCard(2, 2))
        assertTrue(OrbPrivilegeAccess.showsBunkerCard(3, 2))
    }

    @Test
    fun latestIncidentReasonSkipsCanaryDryRuns() {
        val incidents = listOf(
            mapOf("reason" to "canary test", "dry_run" to true),
            mapOf("reason" to "honeytoken read by pid 4242", "dry_run" to false),
            mapOf("reason" to "older", "dry_run" to false),
        )
        assertEquals("honeytoken read by pid 4242", OrbPrivilegeAccess.latestIncidentReason(incidents))
        assertNull(OrbPrivilegeAccess.latestIncidentReason(emptyList()))
    }

    @Test
    fun enrollmentPromptOnlyWhenSignaturesAreAskedAndThisKeyIsMissing() {
        assertFalse(OrbPrivilegeAccess.shouldPromptEnrollment("off", false, null))
        assertTrue(OrbPrivilegeAccess.shouldPromptEnrollment("warn", false, null))
        assertTrue(OrbPrivilegeAccess.shouldPromptEnrollment("enforce", false, null))
        assertFalse(OrbPrivilegeAccess.shouldPromptEnrollment("enforce", true, null))
        assertFalse(OrbPrivilegeAccess.shouldPromptEnrollment("warn", false, "warn"))
        assertTrue(OrbPrivilegeAccess.shouldPromptEnrollment("enforce", false, "warn"))
    }

    @Test
    fun thisDeviceIsEnrolledOnlyWhenItsKeyIsListed() {
        val devices = listOf(mapOf("public_key" to "AAA"), mapOf("public_key" to "BBB"))
        assertTrue(OrbPrivilegeAccess.isEnrolled("BBB", devices))
        assertFalse(OrbPrivilegeAccess.isEnrolled("CCC", devices))
        assertFalse(OrbPrivilegeAccess.isEnrolled(null, devices))
    }
}
