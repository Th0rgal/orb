package sh.sandboxed.dashboard.orb

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class OrbHarnessTransferTest {
    @Test fun waitsForRemoteAndClientExecution() {
        assertTrue(OrbHarnessTransfer.sourceStopped(mapOf("status" to "failed")))
        assertFalse(OrbHarnessTransfer.sourceStopped(mapOf("status" to "failed", "remote_job" to mapOf("node_state" to "running"))))
        assertFalse(OrbHarnessTransfer.sourceStopped(mapOf("status" to "interrupted", "execution" to mapOf("state" to "running"))))
        assertFalse(OrbHarnessTransfer.sourceStopped(mapOf("status" to "pending")))
    }
    @Test fun historyAndEventDoNotDuplicateTheEnvelope() {
        val envelope = "Continue the work from this conversation in a fresh native session.\n<fork_context>\n" +
            """{"source_mission_id":"source","messages":[{"role":"user","content":"Objective"},{"role":"assistant","content":"Progress"}]}""" + "\n</fork_context>"
        val event = OrbRow("event", mapOf("event_type" to "user_message", "content" to envelope))
        val history = OrbRow("history", mapOf("role" to "user", "content" to envelope))
        fun text(turns: List<OrbTurn>) = turns.mapNotNull { when (it) {
            is OrbTurn.User -> it.text
            is OrbTurn.Assistant -> it.text
            else -> null
        } }
        val first = OrbTimelineBuilder.build(emptyList(), listOf(event), "", false, null)
        val later = OrbTimelineBuilder.build(listOf(history), listOf(event), "", false, null)
        assertEquals(listOf("Objective", "Progress"), text(first))
        assertEquals(text(first), text(later))
    }
    @Test fun sharedContextFixtures() {
        val file = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, "shared/orb-spec/fixtures/fork-context.json") }.first { it.exists() }
        val fixtures = OrbJSON.parse(file.readText()) as List<*>
        for (raw in fixtures) {
            val fixture = OrbJSON.dict(raw)!!
            val result = OrbForkContext.parse(fixture["text"] as String)
            if (fixture["valid"] != true) { assertNull(fixture["name"].toString(), result); continue }
            assertNotNull(result)
            val expected = (fixture["messages"] as List<*>).map { item ->
                val entry = OrbJSON.dict(item)!!
                OrbForkContext.Entry(entry["role"] as String, entry["content"] as String)
            }
            assertEquals(expected, result!!.messages)
            assertEquals(fixture["request"], result.request)
        }
    }
}
