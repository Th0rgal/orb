package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbSendFlowTest {
    @Test fun nonCodexAndCloudFollowUpsNeverRequestCyber() = kotlinx.coroutines.runBlocking {
        for (mission in listOf(
            mapOf("id" to "m", "backend" to "opencode"),
            mapOf("id" to "m", "backend" to "codex", "cloud" to mapOf("provider" to "chatgpt"))
        )) {
            val calls = mutableListOf<String>()
            OrbCyberAccess.requireFollowUp("m", "/goal") { path -> calls += path; mission }
            assertEquals(listOf("/api/control/missions/m?include_history=false"), calls)
        }
    }

    @Test fun sideQuestionExtractionKeepsActualGoalRequest() {
        val wrapped = OrbSideAgent.prompt("Earlier context", "/goal fix tests")
        assertFalse(OrbCyberAccess.nativeGoal("codex", wrapped))
        assertTrue(OrbCyberAccess.nativeGoal("codex", OrbSideAgent.extractQuestion(wrapped)))
    }

    @Test fun freshFollowUpRejectsActualGoalBeforeMutationButAllowsPausedGoalText() = kotlinx.coroutines.runBlocking {
        for (content in listOf("/goal implement", "/goal", "continue working")) {
            val calls = mutableListOf<String>()
            var draft = content
            try {
                OrbCyberAccess.requireFollowUp("mission", content) { path ->
                    calls += path
                    when {
                        path.endsWith("include_history=false") -> mapOf("id" to "mission", "backend" to "codex", "goal_mode" to true,
                            "model_override" to "gpt-6.1-sol")
                        path.endsWith("/cyber") -> mapOf("mode" to "standard", "status" to "requested", "revision" to "2")
                        else -> mapOf("version" to 2, "native_goals_explicit" to false)
                    }
                }
                calls += "mutation"
                draft = ""
            } catch (e: OrbError) {
                assertTrue(e.message.orEmpty().contains("draft is kept"))
            }
            assertEquals(content == "continue working", calls.contains("mutation"))
            assertEquals(if (content == "continue working") "" else content, draft)
            assertTrue(calls.first().endsWith("include_history=false"))
        }
    }

    @Test fun cyberRefusalPrecedesMutationsAndPreservesDraft() = kotlinx.coroutines.runBlocking {
        for (mode in listOf(OrbCyberMode.Standard, OrbCyberMode.Daybreak)) {
            for (capabilities in listOf(
                mapOf("version" to 2, "native_goals_explicit" to false, "route_supported" to true),
                mapOf("version" to 1), emptyMap()
            )) {
                var draft = "/goal implement the feature"
                var model = "gpt-6.1-sol"
                var program = mode
                val calls = mutableListOf<String>()
                try {
                    OrbCyberAccess.requireSupport(model, program, true, OrbCyberAccess.nativeGoal("codex", draft)) {
                        calls += it
                        capabilities
                    }
                    calls += "upload/create/send/PATCH"
                    draft = ""
                    model = ""
                    program = OrbCyberMode.Automatic
                    throw AssertionError("Expected Cyber refusal")
                } catch (e: OrbError) {
                    assertTrue(e.message.orEmpty().contains("draft is kept"))
                }
                assertEquals(1, calls.size)
                assertTrue(calls.single().startsWith("/api/control/cyber-capabilities?"))
                assertEquals("/goal implement the feature", draft)
                assertEquals("gpt-6.1-sol", model)
                assertEquals(mode, program)
            }
        }
    }

    @Test fun explicitRemoteCyberFailsClosedAndOmitsBlankModel() = kotlinx.coroutines.runBlocking {
        for (supported in listOf(null, false, true)) {
            var accepted = false
            try {
                OrbCyberAccess.requireSupport("  ", OrbCyberMode.Daybreak, true, false) { path ->
                    assertFalse(path.contains("model="))
                    mapOf("version" to 2, "route_supported" to supported)
                }
                accepted = true
            } catch (_: OrbError) { }
            assertEquals(supported == true, accepted)
        }
    }

    @Test fun pausedGoalHistoryDoesNotTurnPlainTextIntoNativeGoal() {
        assertFalse(OrbCyberAccess.nativeGoal("codex", "continue working"))
        assertFalse(OrbCyberAccess.nativeGoal("codex", "/goals are useful"))
        assertTrue(OrbCyberAccess.nativeGoal("codex", " /goal continue working"))
        assertFalse(OrbCyberAccess.nativeGoal("opencode", "/goal continue working"))
    }

    @Test fun cyberConfirmationRequiresProviderStatusAndProgram() {
        assertEquals("Daybreak · requested", OrbCyberSelection(OrbCyberMode.Daybreak, "confirmed", "1", " ").summary)
        assertEquals("Daybreak · requested", OrbCyberSelection(OrbCyberMode.Daybreak, "requested", "1", "daybreak").summary)
        assertEquals("Daybreak · confirmed: daybreak", OrbCyberSelection(OrbCyberMode.Daybreak, "confirmed", "2", "daybreak").summary)
        assertTrue(OrbCyberAccess.compatibility(OrbCyberMode.Standard, "openai/gpt-5.6-cyber") != null)
        assertTrue(OrbCyberAccess.compatibility(OrbCyberMode.Automatic, "gpt-daybreak-blue-latest")!!.contains("retired"))
        assertTrue(OrbCyberAccess.error(OrbError("access_program_not_enabled")).contains("model was not changed"))
    }

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

    @Test fun acceptedRowOnlyLeavesForQueueReadStartedAfterPosting() {
        val q = OrbFollowUpQueue().enqueue("c1", "yes", lastSequence = 20)
            .posted("c1", queued = true, atMs = 1_000)
        assertEquals(1_000L, q.row("c1")?.postedAtMs)
        assertEquals(1, q.withServer(emptyList()).count)
        assertEquals(1, q.withServer(emptyList(), fetchedAtMs = 999).count)
        assertEquals(1, q.withServer(emptyList(), fetchedAtMs = 1_000).count)
        val settled = q.withServer(emptyList(), fetchedAtMs = 1_001)
        assertEquals(0, settled.count)
        assertTrue(settled.seenAfter.isEmpty())
        assertEquals(1, OrbFollowUpQueue().enqueue("c2", "yes")
            .withServer(emptyList(), fetchedAtMs = 2_000).count)
    }

    @Test fun historicalYesStaysPendingUntilNewPostSendTurn() {
        val history = listOf(OrbDeliveredMessage(null, "yes", 5), OrbDeliveredMessage("old", " yes ", 20))
        var q = OrbFollowUpQueue().enqueue("c1", "yes", lastSequence = 20)
            .posted("c1", queued = true, atMs = 1_000)
        q = q.reconciled(history)
        assertEquals(listOf("c1"), ids(q))
        q = q.withServer(listOf(OrbQueuedRow("c1", "yes")), fetchedAtMs = 1_001, lastSequence = 25)
            .reconciled(history)
        assertEquals(20L, q.seenAfter["c1"])
        assertEquals(listOf("c1"), ids(q))
        q = q.reconciled(history + OrbDeliveredMessage("new-turn", " yes\n", 21))
        assertEquals(0, q.count)
        assertEquals(0, q.withServer(listOf(OrbQueuedRow("c1", "yes"))).count)
    }

    @Test fun deliveredByIdWinsOverContentAndReservesItsEvent() {
        val q = OrbFollowUpQueue().enqueue("c1", "yes", lastSequence = 20)
            .enqueue("c2", "edited elsewhere", lastSequence = 20)
        val next = q.reconciled(listOf(OrbDeliveredMessage("c1", "edited elsewhere", 21)))
        assertEquals(listOf("c2"), ids(next))
        assertEquals(setOf("c1"), next.delivered)
    }

    @Test fun contentFallbackDeliversOneRowPerEvent() {
        val q = OrbFollowUpQueue().enqueue("c1", "yes", lastSequence = 20)
            .enqueue("c2", "yes", lastSequence = 20)
        assertEquals(listOf("c2"), ids(q.reconciled(listOf(OrbDeliveredMessage(null, "yes", 21)))))
        assertEquals(0, q.reconciled(listOf(
            OrbDeliveredMessage(null, "yes", 21), OrbDeliveredMessage(null, "yes", 22)
        )).count)
    }

    @Test fun serverRowsKeepFirstBaselineAndDropItWhenRemoved() {
        val rows = listOf(OrbQueuedRow("s", "yes", sending = true))
        val q = OrbFollowUpQueue().withServer(rows, lastSequence = 20)
        assertFalse(q.rows.single().sending)
        assertEquals(1, q.reconciled(listOf(OrbDeliveredMessage(null, "yes", 20))).count)
        val refreshed = q.withServer(rows, lastSequence = 30)
        assertEquals(20L, refreshed.seenAfter["s"])
        assertEquals(0, refreshed.reconciled(listOf(OrbDeliveredMessage(null, "yes", 21))).count)
        assertTrue(refreshed.withServer(emptyList()).seenAfter.isEmpty())
    }

    @Test fun missingBaselineDoesNotMatchHistoricalContent() {
        val q = OrbFollowUpQueue(server = listOf(OrbQueuedRow("s", "yes")))
        assertEquals(1, q.reconciled(listOf(OrbDeliveredMessage(null, "yes", Long.MAX_VALUE))).count)
        assertEquals(0, q.reconciled(listOf(OrbDeliveredMessage("s", "changed", 1))).count)
    }

    @Test fun enqueueWithoutCursorRejectsContentButAcceptsId() {
        val q = OrbFollowUpQueue().enqueue("c1", "yes")
            .posted("c1", queued = true, atMs = 1_000)
        assertEquals(null, q.seenAfter["c1"])
        val history = listOf(OrbDeliveredMessage(null, "yes", 5), OrbDeliveredMessage("old", "yes", 20))
        assertEquals(listOf("c1"), ids(q.reconciled(history)))
        assertEquals(listOf("c1"), ids(q.reconciled(listOf(OrbDeliveredMessage(null, "yes", Long.MAX_VALUE)))))
        assertEquals(0, q.reconciled(history + OrbDeliveredMessage("c1", "changed", 21)).count)
        assertEquals(0, q.withDelivered(setOf("c1")).count)
    }

    @Test fun serverWithoutCursorArmsBaselineOnceEventsLoad() {
        val rows = listOf(OrbQueuedRow("s", "yes"))
        val cold = OrbFollowUpQueue().withServer(rows)
        assertEquals(null, cold.seenAfter["s"])
        assertEquals(listOf("s"), ids(cold.reconciled(listOf(OrbDeliveredMessage(null, "yes", 20)))))
        val armed = cold.withServer(rows, lastSequence = 20)
        assertEquals(20L, armed.seenAfter["s"])
        assertEquals(listOf("s"), ids(armed.reconciled(listOf(OrbDeliveredMessage(null, "yes", 20)))))
        assertEquals(0, armed.reconciled(listOf(OrbDeliveredMessage(null, "yes", 21))).count)
    }

    @Test fun contentEventIsNotReusedAcrossReconciliations() {
        val messages = listOf(OrbDeliveredMessage(null, "yes", 21))
        val q = OrbFollowUpQueue().enqueue("c1", "yes", lastSequence = 20)
            .enqueue("c2", "yes", lastSequence = 20)
            .reconciled(messages)
        assertEquals(listOf("c2"), ids(q))
        assertEquals(q, q.reconciled(messages))
        assertEquals(listOf("c2"), ids(q.withServer(emptyList()).reconciled(messages)))
        assertEquals(0, q.reconciled(messages + OrbDeliveredMessage(null, "yes", 22)).count)
    }

    @Test fun consumedServerEventStaysReservedAfterMatchedRowLeaves() {
        val messages = listOf(OrbDeliveredMessage("server-id", "yes", 21))
        val q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("c1", "yes")), lastSequence = 20)
            .reconciled(messages)
            .withServer(emptyList())
            .enqueue("c2", "yes", lastSequence = 20)
        assertEquals(listOf("c2"), ids(q.reconciled(messages)))
        assertEquals(0, q.reconciled(messages + OrbDeliveredMessage("next-server-id", "yes", 22)).count)
    }

    @Test fun deliveredIdEventsStayReservedWhenKnownRowLeaves() {
        val q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("c1", "yes")), lastSequence = 20)
            .withDelivered(setOf("c1"))
            .withServer(emptyList())
            .enqueue("c2", "yes", lastSequence = 20)
        val messages = listOf(OrbDeliveredMessage("c1", "yes", 21))
        val reconciled = q.reconciled(messages)
        assertEquals(listOf("c2"), ids(reconciled))
        assertEquals(reconciled, reconciled.reconciled(messages))
        assertEquals(0, reconciled.reconciled(messages + OrbDeliveredMessage(null, "yes", 22)).count)
    }

    @Test fun deliveredIdsAccumulateAcrossLiveEvents() {
        val q = OrbFollowUpQueue().withServer(listOf(OrbQueuedRow("a", "yes"), OrbQueuedRow("b", "yes")))
            .withDelivered(setOf("a")).withDelivered(setOf("b")).withDelivered(emptySet())
        assertEquals(0, q.count)
    }

    @Test fun historicalYesAnswerDoesNotSettlePendingSideQuestion() {
        val old = OrbSideAgent.Turn("old", "yes", "old answer", at = "2026-11-06T10:00:00Z")
        val askedAt = java.time.Instant.parse("2026-11-06T12:00:00Z").toEpochMilli()
        assertFalse(OrbSideAgent.doesTurnAnswerPending("yes", askedAt, listOf(old), listOf(old)))
        val new = OrbSideAgent.Turn("new", "yes", "new answer", at = "2026-11-06T12:00:01Z")
        assertTrue(OrbSideAgent.doesTurnAnswerPending("yes", askedAt, listOf(old, new), listOf(old)))
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
        assertEquals(OrbEditOutcome.AlreadySent, OrbSendFlow.editOutcome(404))
        assertEquals(OrbEditOutcome.Unsupported, OrbSendFlow.editOutcome(405))
        assertEquals(OrbEditOutcome.AlreadySent, OrbSendFlow.editOutcome(409))
        assertEquals(OrbEditOutcome.Failed, OrbSendFlow.editOutcome(500))
        assertEquals(OrbEditOutcome.Failed, OrbSendFlow.editOutcome(null))
        val initial = OrbFollowUpQueue().withServer(
            listOf(OrbQueuedRow("a", "first"), OrbQueuedRow("b", "second"), OrbQueuedRow("c", "third")),
            lastSequence = 10
        )
        for (status in listOf(404, 405, 409, 500, null)) {
            val outcome = OrbSendFlow.editOutcome(status)
            assertTrue(outcome != OrbEditOutcome.Edited)
            val reverted = initial.edit("b", "mutated").editReverted("b")
            assertEquals(listOf("a", "b", "c"), ids(reverted))
            assertEquals(listOf("first", "second", "third"), reverted.rows.map { it.content })
            assertTrue(reverted.hidden.isEmpty())
            assertTrue(reverted.pending.isEmpty())
        }
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

    @Test fun slotWaitInfoDetectsRemoteAndCoreSlotQueues() {
        val remoteQueued = OrbRow(
            OrbJSON.dict(
                OrbJSON.parse(
                    """{"id":"m1","status":"running","remote_job":{"node_id":"nippur","node_state":"queued","phase":"node_queued"}}"""
                )
            )!!
        )
        assertEquals(OrbSlotWaitInfo("Waiting for a free slot on nippur…", canForce = true), orbSlotWaitInfo(remoteQueued))

        val remoteForced = OrbRow(
            OrbJSON.dict(
                OrbJSON.parse(
                    """{"id":"m1","status":"running","remote_job":{"node_id":"nippur","node_state":"queued","forced":true}}"""
                )
            )!!
        )
        assertEquals(OrbSlotWaitInfo("Waiting for a free slot on nippur…", canForce = false), orbSlotWaitInfo(remoteForced))

        val remoteEnded = OrbRow(
            OrbJSON.dict(
                OrbJSON.parse(
                    """{"id":"m1","status":"completed","remote_job":{"node_id":"nippur","node_state":"queued","finished_at":"2026-10-31T00:00:00Z"}}"""
                )
            )!!
        )
        org.junit.Assert.assertNull(orbSlotWaitInfo(remoteEnded))

        val coreQueued = OrbRow(
            OrbJSON.dict(
                OrbJSON.parse(
                    """{"id":"m2","status":"pending","queue_wait":{"reason":"waiting_for_slot","slots_used":4,"slots_max":4}}"""
                )
            )!!
        )
        assertEquals(OrbSlotWaitInfo("Waiting for a free slot (4/4 in use)…", canForce = true), orbSlotWaitInfo(coreQueued))
    }
}
