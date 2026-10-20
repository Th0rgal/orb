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
}
