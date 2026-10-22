package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbQuotaExhaustedTest {
    @Test
    fun matchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/quota-exhausted.json")["cases"])
        check(cases.isNotEmpty())
        for (c in cases) {
            val windows = OrbJSON.dictList(c["windows"]).map { (it["label"] as String) to (it["used"] as Number).toDouble() }
            assertEquals(c["name"] as String, c["expected"] as? String, quotaExhaustedLabel(windows))
        }
    }
}
