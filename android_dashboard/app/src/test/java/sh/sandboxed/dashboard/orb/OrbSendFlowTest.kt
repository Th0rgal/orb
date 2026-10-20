package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbSendFlowTest {
    private fun ids(q: OrbFollowUpQueue) = q.rows.map { it.id }

    @Test fun optimisticSendShowsAtOnceThenSettlesWithoutJump() {
        var q = OrbFollowUpQueue().enqueue("m1", "hello")
        assertEquals(listOf("m1"), ids(q))
        assertTrue(q.rows[0].sending)
        q = q.posted("m1", queued = true)
        assertFalse(q.rows[0].sending)
        q = q.withServer(listOf(OrbQueuedRow("m1", "hello")))
        assertEquals(1, q.count)
        assertTrue(q.pending.isEmpty())
    }

    @Test fun deliveredImmediatelyLeavesNoRow() {
        val q = OrbFollowUpQueue().enqueue("m1", "hi").posted("m1", queued = false)
        assertEquals(0, q.count)
    }

    @Test fun editInPlaceKeepsIdPositionAndCount() {
        var q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("a", "one"), OrbQueuedRow("b", "two"), OrbQueuedRow("c", "three")))
        q = q.edit("b", "TWO")
        assertEquals(listOf("a", "b", "c"), ids(q))
        assertEquals("TWO", q.rows[1].content)
        assertEquals(3, q.count)
        // A stale poll before PATCH returns does not flash the old text.
        q = q.withServer(listOf(OrbQueuedRow("a", "one"), OrbQueuedRow("b", "two"), OrbQueuedRow("c", "three")))
        assertEquals("TWO", q.rows[1].content)
        q = q.editConfirmed("b", "TWO")
        assertTrue(q.edits.isEmpty())
        assertEquals("TWO", q.rows[1].content)
    }

    @Test fun editRevertRestoresServerText() {
        val q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("a", "one"))).edit("a", "x").editReverted("a")
        assertEquals("one", q.rows[0].content)
    }

    @Test fun editOutcomes() {
        assertEquals(OrbEditOutcome.Edited, OrbSendFlow.editOutcome(200))
        assertEquals(OrbEditOutcome.Unsupported, OrbSendFlow.editOutcome(404))
        assertEquals(OrbEditOutcome.Unsupported, OrbSendFlow.editOutcome(405))
        assertEquals(OrbEditOutcome.AlreadySent, OrbSendFlow.editOutcome(409))
        assertEquals(OrbEditOutcome.Failed, OrbSendFlow.editOutcome(500))
        assertEquals(OrbEditOutcome.Failed, OrbSendFlow.editOutcome(null))
    }

    @Test fun sendNowAndRemoveHideImmediatelyAndRollBack() {
        var q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("a", "one"), OrbQueuedRow("b", "two")))
        q = q.hide("a")
        assertEquals(listOf("b"), ids(q))
        // A poll that still lists it does not bring it back.
        q = q.withServer(listOf(OrbQueuedRow("a", "one"), OrbQueuedRow("b", "two")))
        assertEquals(listOf("b"), ids(q))
        assertEquals(listOf("a", "b"), ids(q.unhide("a")))
        // Once Core stops listing it, the hidden mark is dropped.
        q = q.withServer(listOf(OrbQueuedRow("b", "two")))
        assertTrue(q.hidden.isEmpty())
    }

    @Test fun deliveredRowsAreNotAlsoQueued() {
        val q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("a", "one"))).withDelivered(setOf("a"))
        assertEquals(0, q.count)
    }

    @Test fun sendNowOutcomes() {
        assertEquals(OrbSendFlow.SendNow.Live, OrbSendFlow.sendNowOutcome(mapOf("delivered" to true)))
        assertEquals(OrbSendFlow.SendNow.Promoted, OrbSendFlow.sendNowOutcome(mapOf("ok" to true, "promoted" to true)))
        assertEquals(OrbSendFlow.SendNow.Fallback, OrbSendFlow.sendNowOutcome(mapOf("delivered" to false)))
    }

    @Test fun parseKeepsOnlyThisMissionsWaitingFollowUps() {
        val rows = OrbFollowUpQueue.parse(
            listOf(
                mapOf("id" to "a", "content" to "x", "mission_id" to "m", "source" to "remote-queue"),
                mapOf("id" to "b", "content" to "y", "mission_id" to "m", "inflight" to true),
                mapOf("id" to "c", "content" to "z", "mission_id" to "other"),
                mapOf("id" to "d", "content" to "w", "mission_id" to "m", "source" to "host-queue:api:1", "queue_error" to "node full")
            ),
            "m"
        )
        assertEquals(listOf("a", "d"), rows.map { it.id })
        assertEquals("node full", rows[1].queueError)
    }

    @Test fun handoffMasksInterruptedButNotFailureAndTimesOut() {
        val h = OrbHandoff("m1", atMs = 1_000)
        assertTrue(OrbHandoff.pending("interrupted", h, 2_000))
        assertTrue(OrbHandoff.pending("awaiting_user", h, 2_000))
        assertTrue(OrbHandoff.pending("running", h, 2_000))
        assertFalse(OrbHandoff.pending("failed", h, 2_000))
        assertFalse(OrbHandoff.pending("interrupted", h, 1_000 + OrbHandoff.TIMEOUT_MS))
        assertFalse(OrbHandoff.pending("interrupted", null, 2_000))
    }

    @Test fun trackerEndsAfterStopThenRun() {
        val t = OrbHandoffTracker()
        val h = OrbHandoff("m1", 0)
        assertFalse(t.observe(h, "running", "job1", jobEnded = false))   // old turn still running
        assertFalse(t.observe(h, "interrupted", "job1", jobEnded = true)) // stopped
        assertTrue(t.observe(h, "running", "job2", jobEnded = false))     // new turn
    }

    @Test fun trackerEndsOnNewJobWithoutSeeingTheStop() {
        val t = OrbHandoffTracker()
        val h = OrbHandoff("m1", 0)
        assertFalse(t.observe(h, "running", "job1", false))
        assertTrue(t.observe(h, "running", "job2", false))
    }

    @Test fun trackerEndsOnFailure() {
        val t = OrbHandoffTracker()
        assertTrue(t.observe(OrbHandoff("m1", 0), "failed", null, true))
    }

    @Test fun liveTextAlreadyStoredIsNotShownTwice() {
        assertEquals("", OrbSendFlow.dedupeLiveText("step 1 done", listOf("step 1 done")))
        assertEquals("", OrbSendFlow.dedupeLiveText("step 1", listOf("step 1 done\nstep 2 done")))
        assertEquals("step 3", OrbSendFlow.dedupeLiveText("step 1 done\nstep 3", listOf("step 1 done")))
        assertEquals("new text", OrbSendFlow.dedupeLiveText("new text", listOf("older reply")))
        assertEquals("", OrbSendFlow.dedupeLiveText("  ", listOf()))
    }
}
