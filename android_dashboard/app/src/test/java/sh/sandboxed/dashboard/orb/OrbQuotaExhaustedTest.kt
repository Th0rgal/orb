package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbQuotaExhaustedTest {
    @Test
    fun statusMatchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/quota-exhausted.json")["cases"])
        check(cases.isNotEmpty())
        for (c in cases) {
            val windows = OrbJSON.dictList(c["windows"]).map { (it["label"] as String) to (it["used"] as Number).toDouble() }
            @Suppress("UNCHECKED_CAST")
            val expected = (c["expected"] as? Map<String, Any?>)?.let { e ->
                OrbQuotaStatus(OrbQuotaLevel.values().first { it.wire == e["level"] }, e["label"] as String, e["accountWide"] as Boolean)
            }
            assertEquals(c["name"] as String, expected, quotaStatus(windows))
        }
    }

    @Test
    fun levelMatchesSharedFixture() {
        val cases = OrbJSON.dictList(OrbSpec.dict("fixtures/quota-level.json")["cases"])
        check(cases.isNotEmpty())
        for (c in cases) {
            val level = OrbQuotaLevel.of((c["used"] as? Number)?.toDouble(), c["hasReset"] as? Boolean ?: false)
            assertEquals(c["name"] as String, c["expected"] as String, level.wire)
        }
    }

    @Test
    fun antigravityResetWithoutFigureIsSpent() {
        val detail: OrbDict = mapOf("antigravity_windows" to listOf(mapOf("label" to "Gemini · 5h", "reset_at" to 2_000_000_000.0)))
        assertEquals(listOf("Gemini · 5h" to 1.0), providerQuotaWindows(detail))
    }
}
