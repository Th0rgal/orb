package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test

class OrbActivityCompactionTest {
    private val spec = OrbSpec.dict("fixtures/mobile-debloat.json")

    @Test
    fun privilegeCommandCoalescingMatchesSharedSpec() {
        for (c in OrbJSON.dictList(spec["privilege_commands"])) {
            val name = c["name"] as String
            val input = OrbJSON.dictList(c["input"])
            val got = OrbActivityCompaction.coalescePrivilegeCommands(input)
            val expected = OrbJSON.dictList(c["expected"])
            assertEquals(name, expected.size, got.size)
            for ((item, exp) in got.zip(expected)) {
                assertEquals(name, exp["id"], item.id)
                assertEquals(name, exp["status"], item.status)
                assertEquals(name, exp["host"], item.host)
                assertEquals(name, exp["command"], item.command)
            }
        }
    }

    @Test
    fun errorCoalescingMatchesSharedSpec() {
        for (c in OrbJSON.dictList(spec["error_coalescing"])) {
            val name = c["name"] as String
            val input = OrbJSON.dictList(c["input"]).map {
                OrbActivityCompaction.ErrorInput(
                    category = (it["category"] as? String).orEmpty(),
                    summary = (it["summary"] as? String).orEmpty(),
                    detail = (it["detail"] as? String).orEmpty(),
                    at = (it["at"] as? Number)?.toLong() ?: 0L,
                )
            }
            val got = OrbActivityCompaction.coalesceErrors(input)
            val expected = OrbJSON.dictList(c["expected"])
            assertEquals(name, expected.size, got.size)
            for ((item, exp) in got.zip(expected)) {
                assertEquals(name, exp["category"], item.category)
                assertEquals(name, exp["summary"], item.summary)
                assertEquals(name, (exp["count"] as Number).toInt(), item.count)
                assertEquals(name, (exp["at"] as Number).toLong(), item.at)
            }
        }
    }

    @Test
    fun grantDeduplicationMatchesSharedSpec() {
        for (c in OrbJSON.dictList(spec["grant_deduplication"])) {
            val name = c["name"] as String
            val input = OrbJSON.dictList(c["input"])
            val got = OrbActivityCompaction.dedupeMissionGrants(input)
            assertEquals(name, c["expected_ids"], got.map { (it["id"] as? String).orEmpty() })
        }
    }

    @Test
    fun cooldownFormatMatchesSharedSpec() {
        for (c in OrbJSON.dictList(spec["cooldown_format"])) {
            val secs = (c["seconds"] as Number).toInt()
            assertEquals(c["expected"], OrbActivityCompaction.formatCooldown(secs))
        }
    }

    @Test
    fun inboxPreviewSanitizationMatchesSharedSpec() {
        for (c in OrbJSON.dictList(spec["inbox_preview"])) {
            val name = c["name"] as String
            assertEquals(name, c["expected"], OrbActivityCompaction.cleanInboxPreview(c["input"] as String))
        }
    }

    @Test
    fun placeholderTurnsAndCanonicalUUIDMatchSharedSpec() {
        for (c in OrbJSON.dictList(spec["placeholder_turns"])) {
            val text = c["text"] as String
            assertEquals("placeholder: $text", c["expected"], OrbActivityCompaction.isPlaceholderTurn(text))
        }
        for (c in OrbJSON.dictList(spec["canonical_uuid"])) {
            val id = c["id"] as String
            assertEquals("uuid: $id", c["expected"], OrbActivityCompaction.isCanonicalUUID(id))
        }
    }
}
