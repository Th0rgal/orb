import XCTest
@testable import sandboxed_sh

/// Same cases as the desktop `uxQuickWins.test.ts` / `uxRound2.test.ts` where both clients share a rule.
final class OrbTurnSummaryTests: XCTestCase {
    private var sequence: Int64 = 0
    private func event(_ type: String, _ content: String, tool: String? = nil, call: String? = nil, at: String = "2026-10-18T12:00:00Z") -> StoredEvent {
        sequence += 1
        return StoredEvent(id: sequence, missionId: "m", sequence: sequence, eventType: type, timestamp: at, eventId: "e\(sequence)", toolCallId: call, toolName: tool, content: content, metadata: [:])
    }
    private func json(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    func testTaskStatusesMapHarnessVocabulary() {
        XCTAssertEqual(OrbTurnSummary.taskStatus("done"), "completed")
        XCTAssertEqual(OrbTurnSummary.taskStatus("In-Progress"), "in_progress")
        XCTAssertEqual(OrbTurnSummary.taskStatus("canceled"), "cancelled")
        XCTAssertEqual(OrbTurnSummary.taskStatus("blocked"), "pending")
        XCTAssertEqual(OrbTurnSummary.taskStatus(""), "pending")
    }

    func testWorkModelDescribesOnlyTheCurrentTurn() {
        let events = [
            event("user_message", "Set up CI"),
            event("tool_call", json(["todos": [["content": "Old", "status": "pending"]]]), tool: "TodoWrite", call: "t0"),
            event("tool_call", json(["file_path": "/r/ci.yml", "old_string": "", "new_string": "x"]), tool: "Edit", call: "e0"),
            event("tool_result", "ok", tool: "Edit", call: "e0"),
            event("user_message", "Fix the build"),
            event("tool_call", json(["plan": [["step": "Reproduce", "status": "done"], ["step": "Fix", "status": "in-progress"]]]), tool: "update_plan", call: "p1"),
            event("tool_call", json(["command": "make"]), tool: "Bash", call: "b1"),
        ]
        let model = OrbWorkModel.build(from: events, working: true)
        XCTAssertEqual(model.tools.map(\.rawName), ["Bash"])
        XCTAssertEqual(model.todos.map(\.status), ["completed", "in_progress"])
        XCTAssertEqual(model.liveHeadline(fallback: "Working").action, model.tools[0].loadingLabel)
    }

    func testTurnStartIsTheLatestUserMessageServerTime() {
        let events = [
            event("user_message", "a", at: "2026-10-18T11:00:00Z"),
            event("assistant_message", "b", at: "2026-10-18T11:01:00Z"),
            event("user_message", "c", at: "2026-10-18T12:00:00.250Z"),
            event("tool_call", "{}", tool: "Bash", call: "x", at: "2026-10-18T12:00:05Z"),
        ]
        let start = OrbTurnSummary.turnStart(events)
        XCTAssertEqual(start?.timeIntervalSince1970 ?? 0, ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!.timeIntervalSince1970 + 0.25, accuracy: 0.001)
        XCTAssertNil(OrbTurnSummary.turnStart([]))
        XCTAssertEqual(OrbTurnSummary.clock(65), "1 min 05 s")
        XCTAssertEqual(OrbTurnSummary.clock(9), "9 s")
        XCTAssertEqual(OrbTurnSummary.clock(3_725), "1 h 02")
    }

    func testChangedFilesAggregatesFinishedEditsPerFile() {
        let events = [
            event("tool_call", json(["file_path": "/r/a.ts", "old_string": "x", "new_string": "x\ny"]), tool: "Edit", call: "a"),
            event("tool_result", "ok", tool: "Edit", call: "a"),
            event("tool_call", json(["file_path": "/r/a.ts", "old_string": "q", "new_string": ""]), tool: "Edit", call: "b"),
            event("tool_result", "ok", tool: "Edit", call: "b"),
            event("tool_call", json(["file_path": "/r/new.swift", "content": "one\ntwo\nthree\n"]), tool: "Write", call: "w"),
            event("tool_result", "ok", tool: "Write", call: "w"),
            event("tool_call", json(["file_path": "/r/pending.swift", "content": "x"]), tool: "Write", call: "unfinished"),
        ]
        XCTAssertEqual(OrbTurnSummary.changedFiles(events), [
            .init(file: "/r/new.swift", additions: 3, deletions: 0, edits: 1),
            .init(file: "/r/a.ts", additions: 1, deletions: 1, edits: 2),
        ])
    }

    func testPullRequestLinksAcceptEveryCoreShape() {
        XCTAssertEqual(OrbTurnSummary.prLink("https://github.com/Th0rgal/orb/pull/1132")?.label, "Th0rgal/orb#1132")
        XCTAssertEqual(OrbTurnSummary.prLink("lfglabs-dev/verity#2526")?.url?.absoluteString, "https://github.com/lfglabs-dev/verity/pull/2526")
        XCTAssertEqual(OrbTurnSummary.prLink("42")?.label, "PR 42")
        XCTAssertNil(OrbTurnSummary.prLink("42")?.url)
        XCTAssertNil(OrbTurnSummary.prLink("  "))
    }

    /// Core's `HermesRuntimeSummary` has no `api_server_healthy`: it must not read as "Unreachable".
    func testHermesRuntimeReadsTheFieldsCoreReturns() throws {
        let runtime = try JSONDecoder().decode(OrbJSON.self, from: Data(#"{"service_name":"hermes-assistant.service","service_active":true,"uses_sandboxed_proxy":true,"token_present":true,"notes":[]}"#.utf8))
        let rows = OrbTurnSummary.hermesRuntime(runtime)
        XCTAssertEqual(rows.map(\.0), ["Service", "Route"])
        XCTAssertEqual(rows.map(\.1), ["Active", "Via Core proxy"])
        let sessions = try JSONDecoder().decode(OrbJSON.self, from: Data(#"{"since":"2026-10-17T00:00:00Z","total":12,"open":2,"messages":40,"tool_calls":9,"by_source":{}}"#.utf8))
        XCTAssertEqual(OrbTurnSummary.hermesSessions(sessions), "12 · 2 open")
        XCTAssertNil(OrbTurnSummary.hermesSessions(.null))
    }

    @MainActor func testBannersAreSkippedForItemsAlreadyOnScreen() {
        XCTAssertTrue(OrbOnScreen.presentation(missionID: "m1").contains(.banner))
        OrbOnScreen.opened("m1")
        XCTAssertFalse(OrbOnScreen.presentation(missionID: "m1").contains(.banner))
        XCTAssertTrue(OrbOnScreen.presentation(missionID: "m2").contains(.banner))
        OrbOnScreen.closed("m1")
        OrbOnScreen.inboxVisible = true
        XCTAssertFalse(OrbOnScreen.presentation(missionID: "m2").contains(.banner))
        OrbOnScreen.inboxVisible = false
        XCTAssertTrue(OrbOnScreen.presentation(missionID: "m1").contains(.list))
    }

    // MARK: /btw threads (desktop btwAgent.ts after #1190 and #1197)

    private func event(_ seq: Int64, _ type: String, _ content: String, at: String = "2026-10-20T10:00:00Z") -> StoredEvent {
        StoredEvent(id: seq, missionId: "m", sequence: seq, eventType: type, timestamp: at, eventId: nil, toolCallId: nil, toolName: nil, content: content, metadata: [:])
    }

    private static let compaction = "## Objective\nFinish the side question.\n\n## Progress\n- read files\n\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."

    func testBtwCompactionBlocksAreStripped() {
        XCTAssertEqual(OrbBtwThreads.stripCompaction(Self.compaction + "\n\nThe **answer**."), "The **answer**.")
        XCTAssertEqual(OrbBtwThreads.stripCompaction("Before.\n" + Self.compaction + "  \nAfter."), "Before.\n\nAfter.")
        XCTAssertEqual(OrbBtwThreads.stripCompaction(Self.compaction), "")
        // Text that merely mentions an objective is kept.
        XCTAssertEqual(OrbBtwThreads.stripCompaction("## Objective\nShip it."), "## Objective\nShip it.")
    }

    func testBtwAnswerIsTheFinalMessageAndNarrationIsFolded() {
        let a = OrbBtwThreads.sideAnswer(["Looking at the logs…", "Checking tests.", "**Done**: 3 passed."], final: "**Done**: 3 passed.")
        XCTAssertEqual(a.answer, "**Done**: 3 passed.")
        XCTAssertEqual(a.narration, ["Looking at the logs…", "Checking tests."])
        // A compaction-only message is not narration, and dots are not meaningful.
        let b = OrbBtwThreads.sideAnswer([Self.compaction, "…", "Answer"], final: nil)
        XCTAssertEqual(b.answer, "Answer")
        XCTAssertEqual(b.narration, [])
        // The stored final wins even when a stale canonical copy came after it.
        let c = OrbBtwThreads.sideAnswer(["step", "final", "step 2"], final: Self.compaction + "\nfinal")
        XCTAssertEqual(c.answer, "final")
        XCTAssertEqual(c.narration, ["step"])
    }

    func testBtwThreadParsingKeepsAnsweredTurnsAndTheLiveQuestion() {
        let events = [
            event(1, "user_message", "<main_conversation_update>ctx</main_conversation_update>\n\nCurrent request:\nWhat broke?\nAttachment: /tmp/a.png", at: "2026-10-20T10:00:00Z"),
            event(2, "assistant_message_canonical", "Reading the build log."),
            event(3, "tool_call", "{}"),
            event(4, "assistant_message", Self.compaction + "\n\nThe **linker** failed."),
            event(5, "user_message", "Unanswered question", at: "2026-10-20T10:05:00Z"),
            event(6, "user_message", "And now?", at: "2026-10-20T10:06:00Z"),
            event(7, "assistant_message", "Remote node 'ashur' job 0123abcd-0123-0123-0123-0123456789ab finished without assistant text "),
            event(8, "assistant_message_canonical", "Still checking"),
        ]
        let done = OrbBtwThreads.parse(missionID: "m", events: events, active: false)
        XCTAssertEqual(done.turns.map(\.question), ["What broke?", "And now?"])
        XCTAssertEqual(done.turns[0].answer, "The **linker** failed.")
        XCTAssertEqual(done.turns[0].narration, ["Reading the build log."])
        XCTAssertEqual(done.turns[0].id, "btw:m:1")
        XCTAssertNil(done.open)
        let live = OrbBtwThreads.parse(missionID: "m", events: events, active: true)
        XCTAssertEqual(live.turns.map(\.question), ["What broke?"])
        XCTAssertEqual(live.open?.question, "And now?")
        XCTAssertEqual(live.open?.answer, "Still checking")
        XCTAssertEqual(live.open?.events.map(\.sequence), [7, 8])
    }

    func testBtwBindsToTheThreadWithLatestActivityAndOrdersTurnsByTime() {
        func thread(_ id: String, created: String, activity: String, tags: [String] = ["btw-parent:p"]) -> OrbJSON {
            .object(["id": .string(id), "created_at": .string(created), "updated_at": .string(created), "last_activity_at": .string(activity), "tags": .array(tags.map { .string($0) })])
        }
        let rows = [
            thread("new", created: "2026-10-20T09:00:00Z", activity: "2026-10-20T09:10:00Z"),
            thread("old", created: "2026-10-20T08:00:00Z", activity: "2026-10-20T11:00:00Z"),
            thread("gone", created: "2026-10-20T07:00:00Z", activity: "2026-10-20T12:00:00Z", tags: ["btw-parent:p", "superseded"]),
            thread("other", created: "2026-10-20T07:00:00Z", activity: "2026-10-20T12:00:00Z", tags: ["btw-parent:q"]),
        ]
        let threads = OrbBtwThreads.threads(rows, parent: "p")
        XCTAssertEqual(threads.map { $0["id"].text }, ["old", "new"])
        XCTAssertEqual(OrbBtwThreads.latest(threads)?["id"].text, "old", "a re-dispatched old thread is the live one")
        let merged = OrbBtwThreads.merge([
            [.init(id: "a1", question: "q1", answer: "x", at: "2026-10-20T08:00:00Z"), .init(id: "a3", question: "q3", answer: "x", at: "2026-10-20T11:00:00Z")],
            [.init(id: "b2", question: "q2", answer: "x", at: "2026-10-20T09:00:00Z")],
        ])
        XCTAssertEqual(merged.map(\.id), ["a1", "b2", "a3"])
    }

    func testNotificationSubtitleDoesNotRepeatTheProject() {
        XCTAssertEqual(OrbNotificationPayload.lead(project: "Verity", headline: "Verity", status: "Done"), ["Done"])
        XCTAssertEqual(OrbNotificationPayload.lead(project: "Default", headline: "DGX Spark", status: "Needs approval"), ["Default", "Needs approval"])
    }
}
