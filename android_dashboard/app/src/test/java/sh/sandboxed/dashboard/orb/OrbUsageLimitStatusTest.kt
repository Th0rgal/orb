package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OrbUsageLimitStatusTest {
    @Test
    fun matchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/usage-limit-status.json")["cases"])
        check(cases.isNotEmpty())
        for (c in cases) {
            val name = c["name"] as String
            val got = usageLimitStatus(OrbJSON.dict(c["usage"]), (c["nowSec"] as Number).toDouble())
            val expected = OrbJSON.dict(c["expected"])
            if (expected == null) {
                assertNull(name, got)
            } else {
                assertEquals(name, expected["tone"], got?.tone)
                assertEquals(name, expected["label"], got?.label)
            }
        }
    }
}
