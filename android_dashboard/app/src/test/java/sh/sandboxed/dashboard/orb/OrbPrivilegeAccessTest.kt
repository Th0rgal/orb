package sh.sandboxed.dashboard.orb

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
