package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbManagedSpendTest {
    @Test
    fun matchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/managed-spend.json")["cases"])
        assertEquals(4, cases.size)
        for (c in cases) {
            val name = c["name"] as String
            val days = OrbManagedMachines.parseDailySpend(c["days"])!!
            val s = OrbManagedMachines.spendSummary(days)
            assertEquals(name, (c["total"] as Number).toDouble(), s.total, 1e-9)
            assertEquals(name, (c["today"] as Number).toDouble(), s.today, 1e-9)
            assertEquals(name, (c["max"] as Number).toDouble(), s.max, 1e-9)
            val fractions = (c["fractions"] as List<*>).map { (it as Number).toDouble() }
            val tops = OrbJSON.dictList(c["top"])
            days.forEachIndexed { i, d ->
                assertEquals("$name ${d.day}", fractions[i], OrbManagedMachines.spendFraction(d.usd, s.max), 1e-9)
                val (ids, more) = OrbManagedMachines.topMissions(d)
                assertEquals(name, tops[i]["ids"] as List<*>, ids)
                assertEquals(name, (tops[i]["more"] as Number).toInt(), more)
            }
        }
    }

    @Test
    fun detailAndLines() {
        val day = DailySpend("2026-10-22", 1.0, listOf("abc" to 0.6, null to 0.3, "zzzzzzzz9" to 0.1), emptyList())
        assertTrue(OrbManagedMachines.spendDayDetail(day, mapOf("abc" to "Fix login")).endsWith(" · $1.00 · Fix login $0.60, No mission $0.30 +1 more"))
        assertTrue(OrbManagedMachines.spendDayDetail(day.copy(usd = 0.0, missions = emptyList()), emptyMap()).endsWith(" · no spend"))
        val b = ManagedBudget(0.25, 0.0, 20.0, 1, 3, 60, 240)
        assertEquals("$0.25 today of $20.00 daily cap", OrbManagedMachines.spendTodayLine(0.25, b))
        assertEquals("1 running", OrbManagedMachines.runningLine(b.copy(maxConcurrent = null)))
        assertNull(OrbManagedMachines.parseDailySpend(null))
    }
}
