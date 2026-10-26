package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

/** Same five sections, names, subtitles and tab labels as desktop (settings-nav.json). */
class OrbSettingsNavTest {
    private val spec = OrbSpec.dict("fixtures/settings-nav.json")

    @Test
    fun sectionsMatchSharedFixture() {
        val sections = OrbJSON.dictList(spec["sections"])
        assertEquals(sections.map { it["id"] }, OrbSettingsSection.entries.map { it.id })
        for ((json, section) in sections.zip(OrbSettingsSection.entries)) {
            assertEquals(json["label"], section.label)
            assertEquals(json["subtitle"], section.subtitle)
            val tabs = OrbJSON.dictList(json["tabs"]).associate { it["id"] as String to it["label"] as String }
            for ((id, label, _) in section.pages) tabs[id]?.let { assertEquals(id, it, label) }
        }
    }

    @Test
    fun attentionMatchesSharedFixture() {
        for (c in OrbJSON.dictList(spec["attention"])) {
            val s = OrbJSON.dict(c["state"])!!
            val got = OrbSettingsSection.attention(s["bunkerActive"] as Boolean, s["deviceEnrolled"] as Boolean, s["quotaExhausted"] as Boolean)
            assertEquals(c["name"] as String, (c["expected"] as List<*>).toSet(), got.map { it.id }.toSet())
        }
    }
}

class OrbUsageSettingsTest {
    @Test
    fun spendPerDayAndTopMissionsByCost() {
        val s = mapOf(
            "by_day" to listOf(mapOf("day" to "2026-10-25", "cost_cents" to 250), mapOf("day" to "2026-10-26", "cost_cents" to 1200)),
            "by_mission" to listOf(mapOf("key" to "a", "label" to "Cheap", "cost_cents" to 10, "requests" to 2), mapOf("key" to "b", "label" to "Pricey", "cost_cents" to 900, "requests" to 40)),
        )
        assertEquals(listOf(2.5, 12.0), usageDays(s).map { it.usd })
        assertEquals(listOf("10-25", "10-26"), usageDays(s).map { it.label })
        assertEquals(listOf("Pricey", "Cheap"), usageTopMissions(s).map { it.name })
    }
}
