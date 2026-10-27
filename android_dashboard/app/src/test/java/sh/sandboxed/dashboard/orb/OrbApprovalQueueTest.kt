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

    @Test fun neverAsksCoreForMoreThanOneSignatureCanApprove() {
        val many = (0 until OrbApprovalQueue.MAX_BATCH + 5).map { item(2) + ("id" to "i$it") }
        assertEquals(OrbApprovalQueue.MAX_BATCH, OrbApprovalQueue.batchApprovable(many, true).size)
    }

    @Test fun deniesThroughEachKindsRoute() {
        assertEquals("/api/privilege-access/i0/deny", OrbApprovalQueue.denyPath(item(0)) { it })
        assertEquals("/api/bitwarden/requests/i2/reject", OrbApprovalQueue.denyPath(item(2)) { it })
        assertEquals("/api/mission-access/i7/deny", OrbApprovalQueue.denyPath(item(7)) { it })
    }
}
