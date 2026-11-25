package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
            val got = OrbSettingsSection.attention(s["bunkerActive"] as Boolean, s["deviceEnrolled"] as Boolean)
            assertEquals(c["name"] as String, (c["expected"] as List<*>).toSet(), got.map { it.id }.toSet())
        }
    }

    @Test
    fun airVpnSettingsModelMatchesSharedFixture() {
        val airSpec = OrbSpec.dict("fixtures/airvpn-settings.json")
        for (c in OrbJSON.dictList(airSpec["status"])) {
            val name = c["name"] as String
            val got = OrbAirVpnModel.parseStatus(c["input"])
            val exp = OrbJSON.dict(c["expected"])
            if (exp == null) {
                assertNull(name, got)
            } else {
                val unwrapped = requireNotNull(got) { name }
                assertEquals(name, exp["apiKeyConfigured"], unwrapped.apiKeyConfigured)
                assertEquals(name, (exp["sessionLimit"] as Number).toInt(), unwrapped.sessionLimit)
                assertEquals(name, (exp["activeTunnelsCount"] as Number).toInt(), unwrapped.activeTunnels.size)
                val expProfiles = OrbJSON.dictList(exp["profiles"]).map { p ->
                    OrbAirVpnModel.ProfileView(
                        device = p["device"] as String,
                        country = p["country"] as String,
                        server = p["server"] as String,
                        active = p["active"] as Boolean,
                        exits = (p["exits"] as List<*>).filterIsInstance<String>(),
                        accounts = (p["accounts"] as Number).toInt(),
                    )
                }
                assertEquals(name, expProfiles, unwrapped.profiles)
            }
        }
        for (c in OrbJSON.dictList(airSpec["filename_hints"])) {
            val filename = c["filename"] as String
            val exp = OrbJSON.dict(c["expected"])!!
            assertEquals(
                filename,
                OrbAirVpnModel.FilenameHint(
                    country = exp["country"] as String,
                    server = exp["server"] as String,
                    device = exp["device"] as String,
                ),
                OrbAirVpnModel.parseFilenameHint(filename),
            )
        }
        for (c in OrbJSON.dictList(airSpec["session_summaries"])) {
            val name = c["name"] as String
            val active = (c["activeSessions"] as? Number)?.toInt()
            val orb = (c["orbTunnels"] as Number).toInt()
            val limit = (c["sessionLimit"] as Number).toInt()
            assertEquals(name, c["expected"] as String, OrbAirVpnModel.sessionSummary(active, orb, limit))
        }
    }
}

class OrbUsageSettingsTest {
    @Test
    fun spendPerDayAndTopMissionsByCost() {
        val s = mapOf(
            "totals" to mapOf("cost_cents" to 1450),
            "by_day" to listOf(mapOf("day" to "2026-10-25", "cost_cents" to 250), mapOf("day" to "2026-10-26", "cost_cents" to 1200)),
            "by_mission" to listOf(mapOf("key" to "a", "label" to "Cheap", "cost_cents" to 10, "requests" to 2), mapOf("key" to "b", "label" to "Pricey", "cost_cents" to 900, "requests" to 40)),
        )
        assertEquals(listOf(2.5, 12.0), usageDays(s).map { it.usd })
        assertEquals(listOf("10-25", "10-26"), usageDays(s).map { it.label })
        assertEquals(14.5, usageTotalUsd(s), 0.001)
        assertEquals(listOf("Pricey", "Cheap"), usageTopMissions(s).map { it.name })
    }
}

class OrbInboxSummaryChoiceTest {
    @Test fun selectionMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/inbox-summary-choice.json")
        for (c in OrbJSON.dictList(spec["cases"])) {
            var model = c["initial"] as String
            val expected = OrbJSON.dictList(c["expected"])
            (c["choices"] as List<*>).forEachIndexed { index, choice ->
                val result = OrbInboxSummaryChoice.apply(model, choice as String)
                assertEquals(expected[index]["aiSummary"], result.aiSummary)
                assertEquals(expected[index]["model"], result.model)
                model = result.model
            }
        }
    }

    @Test fun policyMatchesSharedFixture() {
        val spec = OrbSpec.dict("fixtures/inbox-summary-policy.json")
        assertEquals((spec["ecoQuietMs"] as Number).toLong(), OrbInboxPolicy.ECO_QUIET_MS)
        for (c in OrbJSON.dictList(spec["normalization"])) {
            val name = c["name"] as String
            val got = OrbInboxPolicy.normalize(OrbJSON.dict(c["input"]))
            val expected = OrbJSON.dict(c["expected"])!!
            assertEquals(name, expected["inboxEnabled"], got.inboxEnabled)
            assertEquals(name, expected["includeAutonomous"], got.includeAutonomous)
            assertEquals(name, expected["aiSummary"], got.aiSummary)
            assertEquals(name, expected["summaryMode"], got.summaryMode.id)
            assertEquals(name, expected["model"], got.model)
        }
        for (g in OrbJSON.dictList(spec["gates"])) {
            val name = g["name"] as String
            val norm = OrbInboxPolicy.normalize(OrbJSON.dict(g["prefs"]))
            val got = OrbInboxPolicy.shouldRequestDigest(
                inboxEnabled = norm.inboxEnabled,
                aiSummary = norm.aiSummary,
                summaryMode = norm.summaryMode,
                surface = g["surface"] as String,
                isLive = g["isLive"] as Boolean,
                updatedMs = (g["updatedMs"] as Number).toLong(),
                nowMs = (g["nowMs"] as Number).toLong(),
            )
            assertEquals(name, g["expected"] as Boolean, got)
        }
    }
}
