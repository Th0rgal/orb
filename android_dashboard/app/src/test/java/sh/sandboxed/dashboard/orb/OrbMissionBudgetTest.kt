package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbMissionBudgetTest {
    private fun own(budget: Double, maxGrant: Double? = null) = OrbMissionBudget.from(
        OrbJSON.parse(
            """{"mission_id":"m1","own_budget_usd":$budget,"pool_id":"m1","mode":"own","max_grant_usd":${maxGrant ?: "null"},
            "pool":{"budget_usd":$budget,"spent_usd":0.4,"reserved_usd":0.2,"carved_usd":1,"available_usd":${budget - 1.6}},
            "children":[{"mission_id":"c1","mode":"sub_budget","budget_usd":1,"spent_usd":0.3}]}"""
        )
    )

    @Test fun parsesTheServerView() {
        val v = own(4.0)
        assertEquals("own", v.mode)
        assertEquals(2.4, v.pool!!.available, 1e-9)
        assertEquals("sub_budget", v.children.first().mode)
        assertEquals("none", OrbMissionBudget.from(OrbJSON.parse("""{"mission_id":"x","pool":null,"children":[]}""")).mode)
    }

    @Test fun optimisticMatchesDesktop() {
        assertEquals(4.4, own(4.0).optimistic(6.0).pool!!.available, 1e-9)
        assertEquals("none", own(4.0).optimistic(null).mode)
        assertEquals("pooled", own(4.0, 2.0).optimistic(null).mode)
        assertNull(own(4.0).optimistic(null).pool)
        assertEquals("$2.00", OrbMissionBudget.money(2.0))
        assertEquals(2.5, OrbMissionBudget.parseAmount("$2.5")!!, 1e-9)
        assertNull(OrbMissionBudget.parseAmount("0"))
    }

    @Test fun decodesSharedMissionBudgetFixtureAndVmLimits() {
        val root = OrbSpec.dict("fixtures/mission-budget.json")

        val globalDefault = OrbMissionBudget.from(root["global_default"])
        assertEquals("none", globalDefault.mode)
        assertEquals("global", globalDefault.vmLimitsMode)
        assertNull(globalDefault.ownVmLimits)
        assertEquals(16, globalDefault.effectiveVmLimits?.globalMaxConcurrent)
        assertEquals("Uses the global limit (16 concurrent across Orb).", globalDefault.vmLimitsModeLine)
        assertFalse(globalDefault.showsSubagents)
        assertTrue(globalDefault.children.all { it.isIdlePooled })

        val dedicated = OrbMissionBudget.from(root["dedicated_override"])
        assertEquals("own", dedicated.mode)
        assertEquals("own", dedicated.vmLimitsMode)
        assertEquals(6, dedicated.ownVmLimits?.maxConcurrent)
        assertEquals(mapOf("hetzner" to 0, "vastai" to 2), dedicated.ownVmLimits?.providerMaxConcurrent)
        assertEquals("Hetzner: off · Vast.ai: 2", OrbMissionBudget.providerLimitsSummary(dedicated.ownVmLimits))
        assertEquals(3, dedicated.effectiveVmLimits?.active)
        assertEquals(2, dedicated.effectiveVmLimits?.providerLimits?.size)
        assertTrue(dedicated.showsSubagents)
        assertFalse(dedicated.children[0].isIdlePooled)
        assertTrue(dedicated.children[1].isIdlePooled)

        val cleared = dedicated.optimisticVmLimits(null)
        assertEquals("global", cleared.vmLimitsMode)
        assertNull(cleared.ownVmLimits)
        assertEquals(16, cleared.effectiveVmLimits?.maxConcurrent)
    }

    @Test fun validatesVmLimitsInputs() {
        val ok = OrbMissionBudget.parseVmLimits("8", mapOf("vastai" to "2", "hetzner" to "0")).getOrThrow()
        assertEquals(8, ok.maxConcurrent)
        assertEquals(mapOf("vastai" to 2, "hetzner" to 0), ok.providerMaxConcurrent)

        assertTrue(OrbMissionBudget.parseVmLimits("", emptyMap()).isFailure)
        assertTrue(OrbMissionBudget.parseVmLimits("2", mapOf("vastai" to "4")).isFailure)
    }
}
