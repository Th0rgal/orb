package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbTurnRecapTest {
    private fun edit(id: String, path: String?) =
        OrbWorkStep(id, OrbWorkStep.Kind.Edit, "Edit $path", null, path)

    private fun read(id: String, path: String) =
        OrbWorkStep(id, OrbWorkStep.Kind.Read, "Read $path", null, path)

    @Test
    fun changedFilesOnlyCountsEditsAfterLastUserMessage() {
        val turns = listOf(
            OrbTurn.User("u1", "first", null),
            OrbTurn.WorkFold("w1", listOf(edit("e0", "old.kt")), false, null),
            OrbTurn.User("u2", "second", null),
            OrbTurn.WorkFold("w2", listOf(read("r1", "a.kt"), edit("e1", "src/b.kt"), edit("e2", "src/b.kt")), false, null),
            OrbTurn.Assistant("a1", "done", null),
            OrbTurn.WorkFold("w3", listOf(edit("e3", "c.kt"), edit("e4", null)), false, null)
        )
        assertEquals(listOf("src/b.kt", "c.kt"), OrbTurnRecap.changedFiles(turns))
    }

    @Test
    fun changedFilesEmptyWithoutEdits() {
        assertEquals(emptyList<String>(), OrbTurnRecap.changedFiles(listOf(OrbTurn.User("u", "hi", null))))
    }

    @Test
    fun currentTaskPrefersInProgress() {
        val todos = listOf(
            OrbTodoEntry("1", "Plan", "completed"),
            OrbTodoEntry("2", "Write", "pending"),
            OrbTodoEntry("3", "Test", "in_progress")
        )
        assertEquals("Test", OrbTurnRecap.currentTask(todos)?.content)
        assertEquals(1, OrbTurnRecap.completedCount(todos))
    }

    @Test
    fun currentTaskFallsBackToFirstPendingAndNullWhenAllDone() {
        val pending = listOf(OrbTodoEntry("1", "Plan", "done"), OrbTodoEntry("2", "Write", "pending"))
        assertEquals("Write", OrbTurnRecap.currentTask(pending)?.content)
        assertNull(OrbTurnRecap.currentTask(listOf(OrbTodoEntry("1", "Plan", "Completed"))))
    }

    @Test
    fun loadingRowOnlyBeforeFirstFetchSettles() {
        assertTrue(OrbConversationLoadState.showLoading(turnsEmpty = true, historySettled = false, hasError = false))
        assertFalse(OrbConversationLoadState.showLoading(turnsEmpty = true, historySettled = true, hasError = false))
        assertFalse(OrbConversationLoadState.showLoading(turnsEmpty = false, historySettled = false, hasError = false))
        assertFalse(OrbConversationLoadState.showLoading(turnsEmpty = true, historySettled = false, hasError = true))
    }

    @Test
    fun sideAgentPollsFastThenBacksOff() {
        assertEquals(1_000L, OrbSideAgent.pollDelayMs(0))
        assertEquals(2_500L, OrbSideAgent.pollDelayMs(30_000))
        assertEquals(5_000L, OrbSideAgent.pollDelayMs(120_000))
        assertEquals("7s", OrbSideAgent.elapsedLabel(7_400))
        assertEquals("1:05", OrbSideAgent.elapsedLabel(65_000))
    }

    @Test
    fun sideAgentStripsLegacyAndCheckpointCompactionWithoutTouchingNormalHeadings() {
        val legacy = "## Objective\nFinish side question.\n\n## Progress\n- read files\n\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."
        val checkpoint = "## Objective\nVerify `/btw` queue.\n\n## Work State\n- Checked logs\n\n## Next Move\n- Reply\n\n## Relevant Files\n- `src/main.rs`"
        assertEquals("The **answer**.", OrbSideAgent.stripCompaction("$legacy\n\nThe **answer**."))
        assertEquals("", OrbSideAgent.stripCompaction(checkpoint))
        assertEquals("## Objective\nShip it.", OrbSideAgent.stripCompaction("## Objective\nShip it."))
    }

    @Test
    fun sideAgentIgnoresQueuedFollowUpUserMessagesAndPreservesWrapperOnEdit() {
        fun ev(seq: Long, type: String, content: String, queued: Boolean = false, clientId: String? = null): OrbRow {
            val meta = mutableMapOf<String, Any?>()
            if (queued) meta["queued"] = true
            if (clientId != null) meta["client_message_id"] = clientId
            return OrbRow(
                "e-$seq",
                mapOf(
                    "sequence" to seq,
                    "event_id" to "e-$seq",
                    "event_type" to type,
                    "content" to content,
                    "timestamp" to "2026-11-01T05:00:0${seq}Z",
                    "metadata" to meta
                )
            )
        }
        val events = listOf(
            ev(1L, "user_message", "<main_conversation_update>ctx</main_conversation_update>\n\nCurrent request:\nFirst question?\nAttachment: /tmp/a.png", clientId = "m1"),
            ev(2L, "assistant_message_canonical", "Investigating first question…"),
            ev(3L, "user_message", "<main_conversation_update>ctx2</main_conversation_update>\n\nCurrent request:\nQueued second question?", queued = true, clientId = "q2"),
            ev(4L, "text_delta", "Almost done")
        )
        val parsed = OrbSideAgent.parseTurns("side-1", events, active = true)
        assertEquals(emptyList<OrbSideAgent.Turn>(), parsed.turns)
        assertEquals("First question?", parsed.open?.question)
        assertEquals("Almost done", parsed.open?.answer)
        assertEquals(listOf("Investigating first question…"), parsed.open?.narration)
        assertTrue("m1" in parsed.deliveredIds)
        assertFalse("q2" in parsed.deliveredIds)

        val wrapped = OrbSideAgent.prompt("User: hi", "Original question?") + "\nAttachment: /tmp/a.png"
        val replaced = OrbSideAgent.replaceQuestion(wrapped, "Edited question?")
        assertEquals("Edited question?", OrbSideAgent.extractQuestion(replaced))
        assertTrue(replaced.contains("<main_conversation_update>\nUser: hi\n</main_conversation_update>"))
        assertTrue(replaced.endsWith("Attachment: /tmp/a.png"))
    }

    @Test
    fun sideAgentPagesBackwardBeyond200EventsAndPreservesCachedTurnsWhenWindowIsTruncated() = runBlocking {
        fun ev(seq: Long, type: String, content: String): OrbRow =
            OrbRow(
                "e-$seq",
                mapOf(
                    "sequence" to seq,
                    "event_id" to "e-$seq",
                    "event_type" to type,
                    "content" to content,
                    "timestamp" to "2026-11-01T06:00:${seq.toString().padStart(2, '0')}Z"
                )
            )

        val fullLog = buildList {
            add(ev(1L, "user_message", "<main_conversation_update>ctx</main_conversation_update>\n\nCurrent request:\nLong turn question?"))
            for (seq in 2L..245L) {
                add(ev(seq, "tool_call", """{"tool":"read","seq":$seq}"""))
            }
            add(ev(246L, "assistant_message", "Long turn final answer."))
        }
        val requestedBefore = mutableListOf<Long?>()
        val paged = OrbSideAgent.loadThreadEvents(pageSize = 200, maxPages = 5) { beforeSeq ->
            requestedBefore.add(beforeSeq)
            val eligible = if (beforeSeq == null) fullLog else fullLog.filter { (it.raw["sequence"] as Long) < beforeSeq }
            eligible.takeLast(200)
        }
        assertEquals(listOf(null, 47L), requestedBefore)
        assertEquals(246, paged.size)
        val parsed = OrbSideAgent.parseTurns("side-long", paged, active = false)
        assertEquals(1, parsed.turns.size)
        assertEquals("Long turn question?", parsed.turns.first().question)
        assertEquals("Long turn final answer.", parsed.turns.first().answer)

        // Fallback when events are empty/unavailable or capped before the user_message:
        // history rows + previous cached turns keep the thread intact.
        val history = listOf(
            OrbRow("h0", mapOf("role" to "user", "content" to "Header\n\nCurrent request:\nFallback question?", "timestamp" to "2026-11-01T06:10:00Z")),
            OrbRow("h1", mapOf("role" to "assistant", "content" to "Fallback answer.", "timestamp" to "2026-11-01T06:10:05Z"))
        )
        val tailOnly = fullLog.takeLast(20)
        val recovered = OrbSideAgent.parseTurns("side-long", tailOnly, active = false, history = history, previous = parsed)
        assertEquals(listOf("Long turn question?", "Fallback question?"), recovered.turns.map { it.question })

        // Transient empty window without history preserves previous cached state instead of wiping it.
        val preserved = OrbSideAgent.parseTurns("side-long", emptyList(), active = false, previous = parsed)
        assertEquals(parsed.turns, preserved.turns)
    }

    @Test
    fun sideAgentRotatesBloatedSessionsMergesDeltasAndSummarizesPriorTurns() {
        assertFalse(OrbSideAgent.shouldRotateSession(7, 399L))
        assertTrue(OrbSideAgent.shouldRotateSession(8, 10L))
        assertTrue(OrbSideAgent.shouldRotateSession(2, 400L))

        fun ev(seq: Long, content: String) = OrbRow(
            "e-$seq",
            mapOf("sequence" to seq, "event_id" to "e-$seq", "event_type" to "assistant_message", "content" to content)
        )
        val existing = listOf(ev(1L, "one"), ev(2L, "two"))
        assertEquals(listOf(1L, 2L), OrbSideAgent.mergeThreadEvents(existing, emptyList())?.map { it.raw["sequence"] })
        val merged = OrbSideAgent.mergeThreadEvents(existing, listOf(ev(3L, "three"), ev(4L, "four")))
        assertEquals(listOf(1L, 2L, 3L, 4L), merged?.map { it.raw["sequence"] })
        assertEquals(4L, OrbSideAgent.maxEventSeq(merged.orEmpty()))
        assertEquals(null, OrbSideAgent.mergeThreadEvents(merged.orEmpty(), listOf(ev(1L, "reset"))))

        val wrapped = OrbSideAgent.prompt(
            context = "User: objective",
            question = "Next question?",
            priorTurns = listOf(OrbSideAgent.Turn(id = "btw:m:1", question = "First?", answer = "Answer 1"))
        )
        assertTrue(wrapped.contains("Earlier side questions in this conversation"))
        assertTrue(wrapped.contains("Q: First?\nA: Answer 1"))
        assertEquals("Next question?", OrbSideAgent.extractQuestion(wrapped))
    }
}
