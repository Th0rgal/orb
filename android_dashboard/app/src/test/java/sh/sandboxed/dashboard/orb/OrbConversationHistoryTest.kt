package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class OrbConversationHistoryTest {
    @Test fun continuationMissionsKeepSeparateSequenceSpaces() {
        fun message(mission: String, seq: Int, text: String) = OrbRow("$mission-$seq", mapOf("mission_id" to mission, "sequence" to seq, "role" to "assistant", "content" to text))
        val history = listOf(message("first", 1, "first answer"), message("next", 1, "next answer"))
        val event = OrbRow("event", mapOf("mission_id" to "next", "sequence" to 2, "event_type" to "user_message", "content" to "follow up"))
        assertEquals(listOf("first answer", "next answer", "follow up"), OrbConversationHistory.merge(history, listOf(event)).map { it.str("content") })
    }
    @Test fun sharedFixtures() {
        val file = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, "shared/orb-spec/fixtures/conversation-history.json") }.first { it.exists() }
        for (raw in OrbJSON.parse(file.readText()) as List<*>) {
            val fixture = OrbJSON.dict(raw)!!
            fun rows(key: String) = (fixture[key] as List<*>).mapIndexed { index, row -> OrbRow("$index", OrbJSON.dict(row)!!) }
            assertEquals(fixture["name"].toString(), fixture["expected"], OrbConversationHistory.merge(rows("history"), rows("events")).map { it.str("content") })
            val displayed = OrbTimelineBuilder.build(rows("history"), rows("events"), "", false, null).mapNotNull { turn -> when (turn) {
                is OrbTurn.User -> turn.text
                is OrbTurn.Assistant -> turn.text
                else -> null
            } }
            assertEquals(fixture["name"].toString(), fixture["expected"], displayed)
        }
    }
}
