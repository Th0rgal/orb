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
