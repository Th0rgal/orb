package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
