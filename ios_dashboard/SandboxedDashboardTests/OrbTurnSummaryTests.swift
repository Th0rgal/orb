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

    @MainActor func testSideAnswersRenderInlineMarkdown() {
        let rendered = OrbSideQuestionSheet.markdown("cible **40/45** et `b223122a`\n- next")
        XCTAssertEqual(String(rendered.characters), "cible 40/45 et b223122a\n- next")
    }

    func testNotificationSubtitleDoesNotRepeatTheProject() {
        XCTAssertEqual(OrbNotificationPayload.lead(project: "Verity", headline: "Verity", status: "Done"), ["Done"])
        XCTAssertEqual(OrbNotificationPayload.lead(project: "Default", headline: "DGX Spark", status: "Needs approval"), ["Default", "Needs approval"])
    }
}
