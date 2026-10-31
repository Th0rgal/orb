import XCTest
@testable import sandboxed_sh

final class OrbSendFlowTests: XCTestCase {
    private func ids(_ q: OrbFollowUpQueue) -> [String] { q.rows.map(\.id) }

    func testOptimisticSendShowsAtOnceThenSettles() {
        var q = OrbFollowUpQueue().enqueue("m1", "hello")
        XCTAssertEqual(ids(q), ["m1"])
        XCTAssertTrue(q.rows[0].sending)
        q = q.posted("m1", queued: true)
        XCTAssertFalse(q.rows[0].sending)
        q = q.withServer([OrbQueuedRow(id: "m1", content: "hello")])
        XCTAssertEqual(q.count, 1)
        XCTAssertTrue(q.pending.isEmpty)
        XCTAssertEqual(OrbFollowUpQueue().enqueue("x", "y").posted("x", queued: false).count, 0)
    }

    func testEditInPlaceKeepsIdPositionAndCount() {
        let server = [OrbQueuedRow(id: "a", content: "one"), OrbQueuedRow(id: "b", content: "two"), OrbQueuedRow(id: "c", content: "three")]
        var q = OrbFollowUpQueue().withServer(server).edit("b", "TWO")
        XCTAssertEqual(ids(q), ["a", "b", "c"])
        XCTAssertEqual(q.rows[1].content, "TWO")
        q = q.withServer(server) // stale poll
        XCTAssertEqual(q.rows[1].content, "TWO")
        q = q.editConfirmed("b", "TWO")
        XCTAssertTrue(q.edits.isEmpty)
        XCTAssertEqual(q.rows[1].content, "TWO")
        XCTAssertEqual(OrbFollowUpQueue().withServer(server).edit("a", "x").editReverted("a").rows[0].content, "one")
    }

    func testEditOutcomes() {
        XCTAssertEqual(OrbSendFlow.editOutcome(status: 200), .edited)
        XCTAssertEqual(OrbSendFlow.editOutcome(status: 404), .unsupported)
        XCTAssertEqual(OrbSendFlow.editOutcome(status: 405), .unsupported)
        XCTAssertEqual(OrbSendFlow.editOutcome(status: 409), .alreadySent)
        XCTAssertEqual(OrbSendFlow.editOutcome(status: 500), .failed)
        XCTAssertEqual(OrbSendFlow.editOutcome(status: nil), .failed)
    }

    func testHideSurvivesStalePollAndRollsBack() {
        let server = [OrbQueuedRow(id: "a", content: "one"), OrbQueuedRow(id: "b", content: "two")]
        var q = OrbFollowUpQueue().withServer(server).hide("a")
        XCTAssertEqual(ids(q), ["b"])
        q = q.withServer(server)
        XCTAssertEqual(ids(q), ["b"])
        XCTAssertEqual(ids(q.unhide("a")), ["a", "b"])
        q = q.withServer([server[1]])
        XCTAssertTrue(q.hidden.isEmpty)
    }

    func testSendNowOutcomes() {
        XCTAssertEqual(OrbSendFlow.sendNowOutcome(.object(["delivered": .bool(true)])), .live)
        XCTAssertEqual(OrbSendFlow.sendNowOutcome(.object(["ok": .bool(true), "promoted": .bool(true)])), .promoted)
        XCTAssertEqual(OrbSendFlow.sendNowOutcome(.object(["delivered": .bool(false)])), .fallback)
    }

    func testParseKeepsThisMissionsWaitingFollowUps() {
        let rows = OrbFollowUpQueue.parse([
            .object(["id": .string("a"), "content": .string("x"), "mission_id": .string("m"), "source": .string("remote-queue")]),
            .object(["id": .string("b"), "content": .string("y"), "mission_id": .string("m"), "inflight": .bool(true)]),
            .object(["id": .string("c"), "content": .string("z"), "mission_id": .string("other")]),
            .object(["id": .string("d"), "content": .string("w"), "mission_id": .string("m"), "source": .string("host-queue:api:1"), "queue_error": .string("node full")]),
        ], missionID: "m")
        XCTAssertEqual(rows.map(\.id), ["a", "d"])
        XCTAssertEqual(rows[1].queueError, "node full")
    }

    func testHandoffMasksInterruptedNotFailureAndTimesOut() {
        let start = Date(timeIntervalSince1970: 1000)
        let h = OrbHandoff(id: "m1", at: start)
        XCTAssertTrue(OrbHandoff.pending(status: "interrupted", handoff: h, now: start.addingTimeInterval(1)))
        XCTAssertTrue(OrbHandoff.pending(status: "running", handoff: h, now: start.addingTimeInterval(1)))
        XCTAssertFalse(OrbHandoff.pending(status: "failed", handoff: h, now: start.addingTimeInterval(1)))
        XCTAssertFalse(OrbHandoff.pending(status: "interrupted", handoff: h, now: start.addingTimeInterval(OrbHandoff.timeout)))
        XCTAssertFalse(OrbHandoff.pending(status: "interrupted", handoff: nil))
    }

    func testTrackerEndsAfterStopThenRunOrNewJobOrFailure() {
        let h = OrbHandoff(id: "m1", at: Date())
        var t = OrbHandoffTracker()
        XCTAssertFalse(t.observe(h, status: "running", jobID: "j1", jobEnded: false))
        XCTAssertFalse(t.observe(h, status: "interrupted", jobID: "j1", jobEnded: true))
        XCTAssertTrue(t.observe(h, status: "running", jobID: "j2", jobEnded: false))
        var t2 = OrbHandoffTracker()
        XCTAssertFalse(t2.observe(h, status: "running", jobID: "j1", jobEnded: false))
        XCTAssertTrue(t2.observe(h, status: "running", jobID: "j2", jobEnded: false))
        var t3 = OrbHandoffTracker()
        XCTAssertTrue(t3.observe(h, status: "failed", jobID: nil, jobEnded: true))
    }

    func testLiveTextAlreadyStoredIsNotShownTwice() {
        XCTAssertEqual(OrbSendFlow.dedupeLiveText("step 1 done", stored: ["step 1 done"]), "")
        XCTAssertEqual(OrbSendFlow.dedupeLiveText("step 1", stored: ["step 1 done\nstep 2 done"]), "")
        XCTAssertEqual(OrbSendFlow.dedupeLiveText("step 1 done\nstep 3", stored: ["step 1 done"]), "step 3")
        XCTAssertEqual(OrbSendFlow.dedupeLiveText("new text", stored: ["older reply"]), "new text")
    }

    // Queue while running -> Core delivers -> the row becomes the transcript bubble.
    func testDeliveredByClientMessageIdLeavesQueue() {
        var q = OrbFollowUpQueue().enqueue("c1", "third message while running", lastSequence: 10).posted("c1", queued: true)
        q = q.withServer([OrbQueuedRow(id: "c1", content: "third message while running")], fetchedAt: Date(), lastSequence: 10)
        XCTAssertEqual(ids(q), ["c1"])
        // Stale queue read still lists it, but the user_message event arrived.
        q = q.reconciled(with: [OrbDeliveredMessage(id: "c1", content: "edited elsewhere", sequence: 12)])
        XCTAssertEqual(q.count, 0)
        q = q.withServer([OrbQueuedRow(id: "c1", content: "third message while running")])
        XCTAssertEqual(q.count, 0)
    }

    func testDeliveredByContentFallbackOnlyForLaterEvents() {
        let q = OrbFollowUpQueue().enqueue("c1", "ok", lastSequence: 20).posted("c1", queued: true)
        XCTAssertEqual(q.reconciled(with: [OrbDeliveredMessage(id: nil, content: "ok", sequence: 5)]).count, 1, "an older identical message is not this delivery")
        XCTAssertEqual(q.reconciled(with: [OrbDeliveredMessage(id: "server-id", content: " ok ", sequence: 21)]).count, 0)
        // One event delivers one row.
        let two = q.enqueue("c2", "ok", lastSequence: 20).posted("c2", queued: true)
        XCTAssertEqual(ids(two.reconciled(with: [OrbDeliveredMessage(id: nil, content: "ok", sequence: 21)])), ["c2"])
    }

    func testQueueReadWithoutAcceptedRowRemovesIt() {
        let posted = Date()
        let q = OrbFollowUpQueue().enqueue("c1", "x").posted("c1", queued: true, at: posted)
        // A read that started before Core accepted it may not list it yet.
        XCTAssertEqual(q.withServer([], fetchedAt: posted.addingTimeInterval(-1)).count, 1)
        // A later read that no longer lists it: delivered or removed.
        XCTAssertEqual(q.withServer([], fetchedAt: posted.addingTimeInterval(1)).count, 0)
        // A row still being posted stays.
        XCTAssertEqual(OrbFollowUpQueue().enqueue("c2", "y").withServer([], fetchedAt: Date().addingTimeInterval(5)).count, 1)
        // A server row that disappears is gone.
        let listed = OrbFollowUpQueue().withServer([OrbQueuedRow(id: "s", content: "z")])
        XCTAssertEqual(listed.withServer([], fetchedAt: Date()).count, 0)
    }

    func testTapWhileSendingIsQueuedNeverDropped() {
        XCTAssertEqual(OrbSendFlow.tapAction(busy: false, content: "fourth idle", canQueue: true), .send)
        XCTAssertEqual(OrbSendFlow.tapAction(busy: true, content: "fifth queued", canQueue: true), .deferToQueue)
        XCTAssertEqual(OrbSendFlow.tapAction(busy: true, content: "x", canQueue: false), .ignore)
        XCTAssertEqual(OrbSendFlow.tapAction(busy: false, content: "  ", canQueue: true), .ignore)
        // The deferred row shows at once, then settles like any queued follow-up.
        let q = OrbFollowUpQueue().enqueue("d1", "fifth queued")
        XCTAssertEqual(q.rows.map(\.content), ["fifth queued"])
        XCTAssertEqual(q.posted("d1", queued: true).count, 1)
    }

    func testWorkingClockStartsFromNewTurnNotStaleStart() {
        let now = Date()
        let stale = now.addingTimeInterval(-2150)
        XCTAssertEqual(OrbSendFlow.turnStart(server: stale, localSend: now), now, "an old turn's start is never used for a new send")
        let server = now.addingTimeInterval(-1)
        XCTAssertEqual(OrbSendFlow.turnStart(server: server, localSend: now), server, "Core's start wins once it reports the new turn")
        XCTAssertEqual(OrbSendFlow.turnStart(server: stale, localSend: nil), stale, "reopening keeps a long turn's clock")
        XCTAssertEqual(OrbSendFlow.turnStart(server: nil, localSend: now), now)
    }

    func testDeferredSendGoesOutRightAfterTheAck() {
        XCTAssertFalse(OrbSendFlow.canDrain(awaitingAck: true, draining: false, pending: 1), "not before the first POST returns")
        XCTAssertTrue(OrbSendFlow.canDrain(awaitingAck: false, draining: false, pending: 1), "right after it, not after its refresh")
        XCTAssertFalse(OrbSendFlow.canDrain(awaitingAck: false, draining: true, pending: 1), "one drain at a time keeps order")
        XCTAssertFalse(OrbSendFlow.canDrain(awaitingAck: false, draining: false, pending: 0))
    }

    func testSlotWaitInfoDetectsRemoteAndCoreSlotQueues() {
        let remoteQueued = OrbJSON.object([
            "status": .string("running"),
            "remote_job": .object([
                "node_id": .string("nippur"),
                "node_state": .string("queued"),
                "phase": .string("node_queued"),
            ]),
        ])
        let r = OrbConversation.slotWaitInfo(remoteQueued)
        XCTAssertEqual(r?.label, "Waiting for a free slot on nippur…")
        XCTAssertEqual(r?.canForce, true)

        let remoteForced = OrbJSON.object([
            "status": .string("running"),
            "remote_job": .object([
                "node_id": .string("nippur"),
                "node_state": .string("queued"),
                "forced": .bool(true),
            ]),
        ])
        XCTAssertEqual(OrbConversation.slotWaitInfo(remoteForced)?.canForce, false)

        let remoteEnded = OrbJSON.object([
            "status": .string("completed"),
            "remote_job": .object([
                "node_id": .string("nippur"),
                "node_state": .string("queued"),
                "finished_at": .string("2026-10-31T00:00:00Z"),
            ]),
        ])
        XCTAssertNil(OrbConversation.slotWaitInfo(remoteEnded))

        let coreQueued = OrbJSON.object([
            "status": .string("pending"),
            "queue_wait": .object([
                "reason": .string("waiting_for_slot"),
                "slots_used": .number(4),
                "slots_max": .number(4),
            ]),
        ])
        let c = OrbConversation.slotWaitInfo(coreQueued)
        XCTAssertEqual(c?.label, "Waiting for a free slot (4/4 in use)…")
        XCTAssertEqual(c?.canForce, true)
    }
}
