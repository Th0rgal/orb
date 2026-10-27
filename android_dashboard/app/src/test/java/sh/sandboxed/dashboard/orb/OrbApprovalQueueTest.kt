package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The approval queue labels, summarizes and signs exactly like desktop and iOS, via shared/orb-spec/fixtures/approvals.json. */
@Suppress("UNCHECKED_CAST")
class OrbApprovalQueueTest {
    private val spec = OrbSpec.dict("fixtures/approvals.json")
    private val labels = OrbJSON.dictList(spec["labels"])
    private fun item(n: Int): Map<String, Any?> = (labels[n]["item"] as Map<String, Any?>) + mapOf("id" to "i$n", "digest" to "d$n")

    @Test fun labelsMatchSharedFixture() {
        assertTrue(labels.isNotEmpty())
        labels.indices.forEach { n ->
            val i = item(n)
            assertEquals(labels[n]["title"], OrbApprovalQueue.title(i))
            assertEquals(labels[n]["requester"], OrbApprovalQueue.requester(i))
            assertEquals(labels[n]["detail"], OrbApprovalQueue.detail(i))
        }
    }

    @Test fun summaryAndCriticalExclusionMatchSharedFixture() {
        for (s in OrbJSON.dictList(spec["summaries"])) {
            val items = (s["items"] as List<*>).map { item((it as Number).toInt()) }
            val got = OrbApprovalQueue.summary(items)
            assertEquals(s["risks"], got.risks)
            assertEquals(s["missions"], got.missions)
            assertEquals((s["without_critical"] as Number).toInt(), OrbApprovalQueue.batchApprovable(items, false).size)
            assertEquals(items.size, OrbApprovalQueue.batchApprovable(items, true).size)
        }
    }

    @Test fun signsKindIdAndDigestAndConfirmsCriticalOnlyWhenListed() {
        val body = OrbApprovalQueue.batchBody(listOf(item(0), item(2)))
        assertEquals(false, body["confirm_critical"])
        assertEquals(
            listOf(mapOf("kind" to "privilege", "id" to "i0", "digest" to "d0"), mapOf("kind" to "secret", "id" to "i2", "digest" to "d2")),
            body["items"]
        )
        assertEquals(true, OrbApprovalQueue.batchBody(listOf(item(1)))["confirm_critical"])
        assertEquals(
            "Approve 3 requests (1 critical · 1 elevated · 1 routine): Move OLD_TOKEN; Service deploy on agent-core; Read OPENAI_API_KEY",
            OrbApprovalQueue.signingReason(listOf(item(0), item(9), item(2)))
        )
    }

    @Test fun deniesThroughEachKindsRoute() {
        assertEquals("/api/privilege-access/i0/deny", OrbApprovalQueue.denyPath(item(0)) { it })
        assertEquals("/api/bitwarden/requests/i2/reject", OrbApprovalQueue.denyPath(item(2)) { it })
        assertEquals("/api/mission-access/i7/deny", OrbApprovalQueue.denyPath(item(7)) { it })
    }

    @Test fun riskMatchesCoreRiskTable() {
        for (c in OrbJSON.dictList(spec["risk"])) {
            assertEquals(c.toString(), c["risk"], OrbApprovalQueue.riskOf(c["kind"] as String, c["tier"] as String, mapOf("all_projects" to (c["all_projects"] == true))))
        }
    }

    /** A Core without /api/approvals: the per-kind lists still produce cards, and an empty list hides nothing else. */
    @Test fun legacyListsBuildTheSameItems() {
        val privilege = listOf(
            mapOf("id" to "p1", "state" to "pending", "scope" to "service_deploy", "target_host" to "agent-core", "requester_mission_id" to "m1",
                "requester_title" to "Ship usage fix", "reason" to "deploy", "ttl_minutes" to 240.0, "session_scoped" to true, "created_at" to "2026-10-27T10:00:00Z"),
            mapOf("id" to "p0", "state" to "approved", "scope" to "ops_read", "target_host" to "ashur", "created_at" to "2026-10-27T08:00:00Z"),
        )
        val missions = listOf(
            mapOf("id" to "a1", "state" to "pending", "requester_mission_id" to "m2", "requester_title" to "Fleet health", "target_mission_id" to "t1",
                "target_title" to "Disk cleanup", "reason" to "r", "ttl_hours" to 24.0, "created_at" to "2026-10-27T09:00:00Z"),
        )
        val items = OrbApprovalQueue.legacyItems(privilege, emptyList(), missions)
        assertEquals(listOf("Service deploy on agent-core", "Read Disk cleanup"), items.map { OrbApprovalQueue.title(it) })
        assertEquals(listOf("Ship usage fix", "Fleet health"), items.map { OrbApprovalQueue.requester(it) })
        assertEquals(listOf("elevated", "elevated"), items.map { it["risk"] })
        assertTrue(items.all { it["legacy"] == true })
        assertEquals("Allows restart and deploy services, including production · for this session (max 4 h)", OrbApprovalQueue.detail(items[0]))
        assertEquals("/api/privilege-access/p1/approve" to mapOf("ttl_minutes" to 240, "session_scoped" to true), OrbApprovalQueue.legacyApprove(items[0]) { it })
        assertEquals("/api/mission-access/a1/approve" to mapOf("ttl_hours" to 24), OrbApprovalQueue.legacyApprove(items[1]) { it })
        val secret = OrbApprovalQueue.legacyItem("secret", mapOf("id" to "s1", "status" to "pending", "kind" to "delete", "mission_id" to "m3", "key" to "OLD", "reason" to "x"))
        assertEquals("critical", secret["risk"])
        assertEquals("/api/bitwarden/requests/s1/approve", OrbApprovalQueue.legacyApprove(secret) { it }.first)
    }
}
