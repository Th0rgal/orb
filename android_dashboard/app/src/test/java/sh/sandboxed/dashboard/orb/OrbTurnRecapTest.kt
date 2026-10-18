package sh.sandboxed.dashboard.orb

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
}
