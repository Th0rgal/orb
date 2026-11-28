package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbRoutingProviderTest {
    @Test fun r32SignInAgainSharedFixture() {
        val spec = OrbSpec.dict("fixtures/provider-login-health.json")
        assertEquals(spec["expected_label"], providerLoginStatusLabel(spec["expected_status"] as String))
        assertEquals(null, providerLoginStatusLabel("connected"))
    }
    @Test fun aliasesMatchSharedFixture() {
        val spec = OrbSpec.dict("fixtures/routing-provider.json")
        val catalog = OrbJSON.dictList(spec["catalog"]).map { OrbRow(it) }
        for (case in OrbJSON.dictList(spec["cases"])) {
            val id = case["id"] as String
            assertEquals(case["canonical"], OrbRoutingProvider.find(catalog, id)?.id)
            assertEquals(case["label"], OrbRoutingProvider.label(catalog, id))
        }
    }

    @Test fun routingHealthAndBuiltinDeleteContract() {
        val unknownHealthy = OrbRow(mapOf("account_id" to "a1", "is_healthy" to null, "is_degraded" to false, "cooldown_secs_remaining" to 0))
        assertEquals(false, routingHealthNeedsAttention(unknownHealthy))
        assertEquals("no requests yet", routingHealthSummaryLine(unknownHealthy))

        val cooling = OrbRow(mapOf("account_id" to "a2", "is_healthy" to null, "is_degraded" to true, "cooldown_secs_remaining" to 90, "parked_reason" to "usage_limit"))
        assertEquals(true, routingHealthNeedsAttention(cooling))
        assertEquals(90, routingHealthCooldownSecs(cooling))
        assertEquals("cooldown 1m 30s · usage_limit", routingHealthSummaryLine(cooling))

        val banned = OrbRow(mapOf("account_id" to "a3", "account_state" to "disabled_by_provider", "disabled_by_provider" to true, "disabled_by_provider_message" to "TOS_VIOLATION"))
        assertEquals(true, routingHealthNeedsAttention(banned))
        assertEquals("disabled by provider · TOS_VIOLATION", routingHealthSummaryLine(banned))

        assertEquals(false, routingChainCanDelete("builtin/smart"))
        assertEquals(true, routingChainCanDelete("custom/fast"))
        assertEquals(false, routingChainCanCreate("builtin/spoof"))
        assertEquals(false, routingChainCanCreate("   "))
        assertEquals(true, routingChainCanCreate("fast-fallback"))
    }
}
