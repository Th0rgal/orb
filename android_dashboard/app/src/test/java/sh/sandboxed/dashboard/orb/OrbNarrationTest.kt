package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors orb/tests/narration-fold.test.tsx. */
class OrbNarrationTest {
    private var n = 0
    private fun user() = OrbStreamItem.User("u${n++}")
    private fun say(text: String, cumulative: Boolean = false) = OrbStreamItem.Text("t${n++}", text, cumulative)
    private fun call(name: String = "bash") = OrbStreamItem.Tool("c${n++}", name)
    private fun texts(items: List<OrbStreamItem>): List<String> {
        val keys = OrbNarration.narrationKeys(items)
        return items.filterIsInstance<OrbStreamItem.Text>().filter { it.key in keys }.map { it.text }
    }

    @Test
    fun foldsTextBetweenToolCallsAndKeepsTheAnswerAfterTheLastTool() {
        val items = listOf(user(), say("Let me look."), call(), say("WAIT A MINUTE! Why did that pass?"), call(), say("Fixed: the guard was inverted."))
        assertEquals(listOf("Let me look.", "WAIT A MINUTE! Why did that pass?"), texts(items))
    }

    @Test
    fun neverFoldsAcrossAUserMessageNorNextToAnOrchestrationToolAlone() {
        val items = listOf(say("Done."), user(), call(), say("Delegating."), call("start_mission"), say("All done."))
        assertEquals(emptyList<String>(), texts(items))
        assertTrue(OrbNarration.isOrchestrationTool("mcp__sandboxed__start_mission"))
    }

    @Test
    fun neverFoldsTheProducersCumulativeBubble() {
        val items = listOf(user(), say("Inspect file.", cumulative = true), call(), say("Done."))
        assertTrue(OrbNarration.narrationKeys(items).isEmpty())
    }

    @Test
    fun clampsNarrationToOnePlainLine() {
        assertEquals("HOLD ON! Look at nm output:", OrbNarration.narrationLine("**HOLD ON!**  Look at\n`nm` output:\n```\nU x\n```"))
    }

    private fun ev(id: String, type: String, data: Map<String, Any?>) = OrbRow(id, mapOf("id" to id, "type" to type, "data" to data))
    private fun msg(id: String, role: String, text: String) = OrbRow(id, mapOf("id" to id, "role" to role, "content" to text))

    @Test
    fun timelineKeepsOnlyTheAnswerTopLevelAndNarrationInTheFold() {
        val events = listOf(
            ev("1", "user_message", mapOf("content" to "fix it")),
            ev("2", "assistant_message", mapOf("content" to "HOLD ON! Look at the symbol table.")),
            ev("3", "tool_call", mapOf("name" to "bash", "input" to mapOf("command" to "nm"))),
            ev("4", "assistant_message", mapOf("content" to "WAIT A MINUTE! Why did ld keep it?")),
            ev("5", "tool_call", mapOf("name" to "bash", "input" to mapOf("command" to "ld"))),
            ev("6", "assistant_message", mapOf("content" to "The kernel now links."))
        )
        val messages = listOf(
            msg("m1", "user", "fix it"),
            msg("m2", "assistant", "HOLD ON! Look at the symbol table."),
            msg("m3", "assistant", "WAIT A MINUTE! Why did ld keep it?"),
            msg("m4", "assistant", "The kernel now links.")
        )
        val turns = OrbTimelineBuilder.build(messages, events, "", isLive = false, startedAt = null)
        assertEquals(listOf("The kernel now links."), turns.filterIsInstance<OrbTurn.Assistant>().map { it.text })
        val folds = turns.filterIsInstance<OrbTurn.WorkFold>()
        assertEquals(1, folds.size)
        assertEquals(listOf("HOLD ON! Look at the symbol table.", "WAIT A MINUTE! Why did ld keep it?"), folds[0].narration)
    }

    @Test
    fun liveTurnFoldsAllNarrationAndItsNewestLineIsPlain() {
        val events = listOf(
            ev("1", "user_message", mapOf("content" to "fix it")),
            ev("2", "tool_call", mapOf("name" to "bash")),
            ev("3", "assistant_message", mapOf("content" to "First idea.")),
            ev("4", "tool_call", mapOf("name" to "bash")),
            ev("5", "assistant_message", mapOf("content" to "**Aha!** Look at that error.")),
            ev("6", "tool_call", mapOf("name" to "bash"))
        )
        val messages = listOf(msg("m1", "user", "fix it"), msg("m2", "assistant", "First idea."), msg("m3", "assistant", "**Aha!** Look at that error."))
        val turns = OrbTimelineBuilder.build(messages, events, "", isLive = true, startedAt = null)
        assertTrue(turns.none { it is OrbTurn.Assistant })
        val fold = turns.filterIsInstance<OrbTurn.WorkFold>().single()
        assertTrue(fold.isLive)
        assertEquals("Aha! Look at that error.", OrbNarration.narrationLine(fold.narration.last()))
    }
}
