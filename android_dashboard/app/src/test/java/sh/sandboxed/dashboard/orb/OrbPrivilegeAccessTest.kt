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

    @Test fun approveAllSummaryMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/privilege-access.json")
        val cases = OrbJSON.dictList(spec["cases"])
        val batches = OrbJSON.dictList(spec["batches"])
        assertTrue(batches.isNotEmpty())
        for (b in batches) {
            val rs = (b["requests"] as List<*>).mapIndexed { n, i ->
                (cases[(i as Number).toInt()]["request"] as Map<String, Any?>) + ("id" to "b$n")
            }
            val s = OrbPrivilegeAccess.batchSummary(rs)
            assertEquals(b["tiers"], s.tiers)
            assertEquals(b["hosts"], s.hosts)
            assertEquals(b["missions"], s.missions)
            assertEquals((b["root"] as Number).toInt(), s.root)
            assertEquals((b["without_root"] as Number).toInt(), OrbPrivilegeAccess.batchApprovable(rs, false).size)
            assertEquals(rs.size, OrbPrivilegeAccess.batchApprovable(rs, true).size)
        }
    }

    @Test fun approveAllBodyListsEachRequestAndConfirmsRootOnlyWhenIncluded() {
        val deploy = mapOf("id" to "p1", "requester_mission_id" to "m1", "target_host" to "agent-core", "scope" to "service_deploy",
            "allowed_unit" to null, "ttl_minutes" to 240.0, "session_scoped" to true, "reason" to "x")
        val root = mapOf("id" to "p2", "requester_mission_id" to "m2", "target_host" to "self", "scope" to "root_exec",
            "allowed_unit" to "", "ttl_minutes" to 60.0, "session_scoped" to false)
        val body = OrbPrivilegeAccess.batchBody(listOf(deploy, root))
        assertEquals(true, body["confirm_root"])
        assertEquals(
            listOf(
                mapOf("id" to "p1", "requester_mission_id" to "m1", "target_host" to "agent-core", "scope" to "service_deploy",
                    "allowed_unit" to null, "ttl_minutes" to 240, "session_scoped" to true),
                mapOf("id" to "p2", "requester_mission_id" to "m2", "target_host" to "self", "scope" to "root_exec",
                    "allowed_unit" to null, "ttl_minutes" to 60, "session_scoped" to false),
            ),
            body["items"]
        )
        assertEquals(false, OrbPrivilegeAccess.batchBody(listOf(deploy))["confirm_root"])
    }
}
