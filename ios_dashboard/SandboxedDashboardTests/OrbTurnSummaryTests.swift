import XCTest
@testable import sandboxed_sh

/// Same cases as the desktop `uxQuickWins.test.ts` / `uxRound2.test.ts` where both clients share a rule.
final class OrbTurnSummaryTests: XCTestCase {
    private var sequence: Int64 = 0
    private func event(_ type: String, _ content: String, tool: String? = nil, call: String? = nil, at: String = "2026-10-18T12:00:00Z") -> StoredEvent {
        sequence += 1
        return StoredEvent(id: sequence, missionId: "m", sequence: sequence, eventType: type, timestamp: at, eventId: "e\(sequence)", toolCallId: call, toolName: tool, content: content, metadata: [:])
    }
    private func answer(_ content: String, success: Bool) -> StoredEvent {
        sequence += 1
        return StoredEvent(id: sequence, missionId: "m", sequence: sequence, eventType: "assistant_message", timestamp: "2026-10-22T09:02:02Z", eventId: "e\(sequence)", toolCallId: nil, toolName: nil, content: content, metadata: ["success": AnyCodable(success)])
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

    /// Mission ccd5a32b (statuses only, same as desktop
    /// `fixtures/stale-tasks-ccd5a32b.json`): three todowrites, the last one
    /// [completed, completed, in_progress, pending], then phases 3-4 done
    /// without another todowrite and a successful final answer.
    private func ccd5a32b(final: StoredEvent?) -> [StoredEvent] {
        let todos = { (s: [String]) in self.json(["todos": s.enumerated().map { ["content": "Phase \($0.offset + 1)", "status": $0.element] }]) }
        var events = [event("user_message", "Continue mission")]
        for (i, statuses) in [["in_progress", "pending", "pending", "pending"], ["completed", "in_progress", "pending", "pending"], ["completed", "completed", "in_progress", "pending"]].enumerated() {
            events.append(event("tool_call", todos(statuses), tool: "todowrite", call: "todo\(i)"))
            events.append(event("tool_call", json(["command": "make"]), tool: "bash", call: "b\(i)"))
            events.append(event("tool_result", "ok", tool: "bash", call: "b\(i)"))
        }
        if let final { events.append(final) }
        return events
    }

    func testFinishedTurnWithStaleTodosIsNotStopped() {
        let model = OrbWorkModel.build(from: ccd5a32b(final: answer("All 4 phases of the implementation plan are complete.", success: true)), working: false)
        XCTAssertEqual(model.todos.map(\.status), ["completed", "completed", "in_progress", "pending"])
        XCTAssertEqual(model.outcomeAfterTodos, .finished)
        XCTAssertEqual(OrbMissionTasksCard.state(todos: model.todos, ended: true, outcome: model.outcomeAfterTodos), .stale)
        let label = OrbMissionTasksCard.label(todos: model.todos, ended: true, outcome: model.outcomeAfterTodos)
        XCTAssertEqual(label, "Task list not updated · turn finished (2/4)")
        XCTAssertEqual(model.todos.map { OrbMissionTasksCard.shownStatus($0.status, state: .stale) }, ["completed", "completed", "stale", "stale"])
    }

    func testInterruptedOrFailedTurnStaysStopped() {
        for final in [nil, answer("Interrupted", success: false)] {
            let model = OrbWorkModel.build(from: ccd5a32b(final: final), working: false)
            XCTAssertEqual(model.outcomeAfterTodos, .stopped)
            XCTAssertEqual(OrbMissionTasksCard.label(todos: model.todos, ended: true, outcome: model.outcomeAfterTodos), "Stopped at step 3/4")
        }
        let done = [OrbWorkModel.TodoItem(id: "a", content: "a", status: "completed")]
        XCTAssertEqual(OrbMissionTasksCard.state(todos: done, ended: true, outcome: .finished), .done)
        XCTAssertEqual(OrbMissionTasksCard.state(todos: done, ended: false, outcome: .stopped), .live)
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

    private func event(_ seq: Int64, _ type: String, _ content: String, at: String = "2026-10-20T10:00:00Z", queued: Bool = false) -> StoredEvent {
        StoredEvent(id: seq, missionId: "m", sequence: seq, eventType: type, timestamp: at, eventId: "e\(seq)", toolCallId: nil, toolName: nil, content: content, metadata: queued ? ["queued": AnyCodable(true)] : [:])
    }

    private static let compaction = "## Objective\nFinish the side question.\n\n## Progress\n- read files\n\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."
    private static let checkpointCompaction = "## Objective\nVerify `/btw` turn.\n\n## Work State\n- Checked logs\n\n## Next Move\n- Answer the user\n\n## Relevant Files\n- `src/main.rs`"

    func testBtwCompactionBlocksAreStripped() {
        XCTAssertEqual(OrbBtwThreads.stripCompaction(Self.compaction + "\n\nThe **answer**."), "The **answer**.")
        XCTAssertEqual(OrbBtwThreads.stripCompaction("Before.\n" + Self.compaction + "  \nAfter."), "Before.\n\nAfter.")
        XCTAssertEqual(OrbBtwThreads.stripCompaction(Self.compaction), "")
        XCTAssertEqual(OrbBtwThreads.stripCompaction(Self.checkpointCompaction), "")
        // Text that merely mentions an objective is kept.
        XCTAssertEqual(OrbBtwThreads.stripCompaction("## Objective\nShip it."), "## Objective\nShip it.")
    }

    func testBtwQueuedFollowUpEventsDoNotAdvanceActiveTurnAndReplacePreservesWrapper() {
        let events = [
            event(1, "user_message", "<main_conversation_update>ctx</main_conversation_update>\n\nCurrent request:\nFirst question?", at: "2026-10-20T10:00:00Z"),
            event(2, "assistant_message_canonical", "Investigating first question…"),
            event(3, "user_message", "<main_conversation_update>ctx2</main_conversation_update>\n\nCurrent request:\nQueued follow-up", at: "2026-10-20T10:00:10Z", queued: true),
            event(4, "text_delta", "Almost done"),
        ]
        let live = OrbBtwThreads.parse(missionID: "m", events: events, active: true)
        XCTAssertEqual(live.turns, [])
        XCTAssertEqual(live.open?.question, "First question?")
        XCTAssertEqual(live.open?.answer, "Almost done")
        XCTAssertEqual(live.open?.narration, ["Investigating first question…"])

        let wrapped = "You are the independent /btw agent.\n\n<main_conversation_update>\nUser: hi\n</main_conversation_update>\n\nCurrent request:\nOld question?\nAttachment: /tmp/a.png"
        let replaced = OrbBtwThreads.replaceQuestion(wrapped, with: "Edited question?")
        XCTAssertEqual(OrbBtwThreads.question(replaced), "Edited question?")
        XCTAssertTrue(replaced.contains("<main_conversation_update>\nUser: hi\n</main_conversation_update>"))
        XCTAssertTrue(replaced.hasSuffix("Attachment: /tmp/a.png"))
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

        // Replays 23bad383 / fc153ce6: automatic recovery user_message continues the user's side turn.
        let recoveredEvents = [
            StoredEvent(id: 274, missionId: "fc153ce6", sequence: 274, eventType: "user_message", timestamp: "2026-11-07T04:47:37Z", eventId: "8652b679", toolCallId: nil, toolName: nil, content: "<main_conversation_update>\nctx\n</main_conversation_update>\n\nCurrent request:\noù en est le run sur babylon ?\n", metadata: ["queued": AnyCodable(false), "source": AnyCodable("api:prod")]),
            StoredEvent(id: 286, missionId: "fc153ce6", sequence: 286, eventType: "assistant_message", timestamp: "2026-11-07T04:49:34Z", eventId: nil, toolCallId: nil, toolName: nil, content: "Remote opencode job 155911be-15b0-4184-a58b-acb8875ac36c on node 'babylon' finished with state 'failed' (exit Some(1)); error: command exited with Some(1).", metadata: [:]),
            StoredEvent(id: 289, missionId: "fc153ce6", sequence: 289, eventType: "user_message", timestamp: "2026-11-07T04:51:10Z", eventId: "e2abbfa2", toolCallId: nil, toolName: nil, content: "[Automatic recovery] Inference connection interrupted stopped your previous turn. Resume your work where it stopped, and check the state of anything you had started before continuing. Do not redo finished work.", metadata: ["queued": AnyCodable(false), "source": AnyCodable("api:usage-limit-replay")]),
            StoredEvent(id: 301, missionId: "fc153ce6", sequence: 301, eventType: "assistant_message", timestamp: "2026-11-07T04:55:02Z", eventId: nil, toolCallId: nil, toolName: nil, content: "Oui, ça a nettement progressé ces deux dernières heures sur babylon.", metadata: [:]),
        ]
        let recovered = OrbBtwThreads.parse(missionID: "fc153ce6", events: recoveredEvents, active: false)
        XCTAssertEqual(recovered.turns.count, 1)
        XCTAssertEqual(recovered.turns[0].id, "btw:fc153ce6:274")
        XCTAssertEqual(recovered.turns[0].question, "où en est le run sur babylon ?")
        XCTAssertEqual(recovered.turns[0].answer, "Oui, ça a nettement progressé ces deux dernières heures sur babylon.")
    }

    func testBtwBindsToTheThreadWithLatestActivityAndOrdersTurnsByTime() {
        func thread(_ id: String, created: String, activity: String, tags: [String] = ["btw-parent:p"], supersededBy: String? = nil) -> OrbJSON {
            var dict: [String: OrbJSON] = ["id": .string(id), "created_at": .string(created), "updated_at": .string(created), "last_activity_at": .string(activity), "tags": .array(tags.map { .string($0) })]
            if let supersededBy { dict["superseded_by_mission_id"] = .string(supersededBy) }
            return .object(dict)
        }
        let rows = [
            thread("new", created: "2026-10-20T09:00:00Z", activity: "2026-10-20T09:10:00Z"),
            thread("old", created: "2026-10-20T08:00:00Z", activity: "2026-10-20T11:00:00Z"),
            thread("gone", created: "2026-10-20T07:00:00Z", activity: "2026-10-20T12:00:00Z", tags: ["btw-parent:p", "superseded"], supersededBy: "new"),
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

    func testTurnTimingMatchesDesktopFormatting() {
        let events = [
            event("user_message", "Refactor", at: "2026-10-15T17:24:00Z"),
            event("text_delta", "Working", at: "2026-10-15T18:00:00Z"),
            event("assistant_message", " Done. ", at: "2026-10-16T05:30:00Z"),
            event("assistant_message", "Orphan", at: "bad"),
        ]
        let timing = OrbTurnTiming.byAnswer(events)["Done."]
        XCTAssertEqual(timing?.workedSeconds, (12 * 60 + 6) * 60)
        XCTAssertNil(OrbTurnTiming.byAnswer(events)["Orphan"])
        let end = timing!.completedAt
        XCTAssertEqual(OrbTurnTiming.ago(end, now: end.addingTimeInterval(59)), "just now")
        XCTAssertEqual(OrbTurnTiming.ago(end, now: end.addingTimeInterval(300)), "5m ago")
        XCTAssertEqual(OrbTurnTiming.ago(end, now: end.addingTimeInterval(2 * 3600 + 3540)), "2h ago")
        XCTAssertEqual(OrbTurnTiming.ago(end, now: end.addingTimeInterval(6 * 86_400)), "6d ago")
        XCTAssertEqual(OrbTurnTiming.workedFor(42), "42s")
        XCTAssertEqual(OrbTurnTiming.workedFor(185), "3m 5s")
        XCTAssertEqual(OrbTurnTiming.workedFor((12 * 60 + 6) * 60), "12h 6m")
        XCTAssertEqual(OrbTurnTiming.workedFor(51 * 3600), "2d 3h")
    }

    func testBtwSessionRotationMergeEventsAndLaunchSummary() {
        XCTAssertFalse(OrbBtwThreads.shouldRotateSession(turnCount: 7, maxSequence: 399))
        XCTAssertTrue(OrbBtwThreads.shouldRotateSession(turnCount: 8, maxSequence: 10))
        XCTAssertTrue(OrbBtwThreads.shouldRotateSession(turnCount: 2, maxSequence: 400))

        let existing = [
            event(1, "user_message", "First?", at: "2026-11-02T05:00:00Z"),
            event(2, "assistant_message", "Answer 1", at: "2026-11-02T05:00:05Z"),
        ]
        XCTAssertEqual(OrbBtwThreads.mergeEvents(existing: existing, delta: [])?.map(\.sequence), [1, 2])
        let delta = [
            event(3, "user_message", "Second?", at: "2026-11-02T05:01:00Z"),
            event(4, "assistant_message", "Answer 2", at: "2026-11-02T05:01:05Z"),
        ]
        XCTAssertEqual(OrbBtwThreads.mergeEvents(existing: existing, delta: delta)?.map(\.sequence), [1, 2, 3, 4])
        XCTAssertNil(OrbBtwThreads.mergeEvents(existing: existing + delta, delta: [event(1, "user_message", "Reset", at: "2026-11-02T05:02:00Z")]))

        let wrapped = OrbBtwThreads.launchQuestion(
            "What is left?\nAttachment: /tmp/spec.md",
            priorTurns: [.init(id: "btw:m:1", question: "First?", answer: "Answer 1", at: "2026-11-02T05:00:00Z")]
        )
        XCTAssertTrue(wrapped.contains("Earlier side questions in this conversation"))
        XCTAssertEqual(OrbBtwThreads.question(wrapped), "What is left?")
    }

    @MainActor
    func testLargeBtwCampaignBoundsVisibleWindowMountBudgetAndUniqueTurnIDs() {
        // Replays the structural shape of a 25-thread, 251-turn /btw campaign with 28 Mermaid
        // diagrams, glued fences, pipe tables, `<file>` CLI placeholders, and duplicate row IDs.
        var perThread: [[OrbBtwThreads.Turn]] = []
        for threadIdx in 0..<25 {
            let count = threadIdx == 0 ? 11 : 10
            var turns: [OrbBtwThreads.Turn] = []
            for turnIdx in 0..<count {
                let globalIdx = threadIdx * 10 + turnIdx
                let hasMermaid = globalIdx < 28
                let body: String
                if globalIdx == 0 {
                    body = """
                    Run `turbo-lean check <file>` first. Let's present the updated diagram cleanly!```mermaid
                    flowchart TD
                      A["Gate \(globalIdx)"] --> B["Verified"]
                    ```
                    | Metric | Value |
                    | --- | --- |
                    | Turns | 251 |
                    """
                } else if hasMermaid {
                    body = "Diagram \(globalIdx):\n```mermaid\nflowchart LR\n  N\(globalIdx) --> M\(globalIdx)\n```\nDone."
                } else {
                    body = "Checked `<file>` in thread \(threadIdx) turn \(turnIdx)."
                }
                let stamp = String(format: "2026-11-05T%02d:%02d:%02dZ", (globalIdx / 60) % 24, globalIdx % 60, turnIdx % 60)
                // Intentionally collide sequence 1 on thread 24 to verify `ensureUniqueIds`.
                let seq = (threadIdx == 24 && turnIdx == 1) ? 0 : turnIdx
                turns.append(.init(
                    id: "btw:t\(threadIdx):\(seq)",
                    question: "Question \(globalIdx)?",
                    answer: body,
                    narration: ["Inspecting step \(turnIdx)"],
                    at: stamp
                ))
            }
            perThread.append(turns)
        }

        let merged = OrbBtwThreads.merge(perThread)
        XCTAssertEqual(merged.count, 251)
        XCTAssertEqual(Set(merged.map(\.id)).count, 251, "every merged /btw turn must have a unique ForEach/ScrollPosition ID")
        XCTAssertTrue(merged.contains { $0.id == "btw:t24:0#1" }, "colliding IDs retain thread prefix while disambiguating")

        let initialVisible = OrbTranscriptGates.visibleTurnCount(
            total: merged.count,
            baseLimit: OrbBtwThreads.initialVisibleTurns,
            expandedSteps: 0,
            stepSize: OrbBtwThreads.visibleTurnsStep
        )
        let initialHidden = OrbTranscriptGates.hiddenTurnCount(
            total: merged.count,
            baseLimit: OrbBtwThreads.initialVisibleTurns,
            expandedSteps: 0,
            stepSize: OrbBtwThreads.visibleTurnsStep
        )
        XCTAssertEqual(initialVisible, 20)
        XCTAssertEqual(initialHidden, 231)
        XCTAssertEqual(
            OrbTranscriptGates.visibleTurnCount(
                total: merged.count,
                baseLimit: OrbBtwThreads.initialVisibleTurns,
                expandedSteps: 2,
                stepSize: OrbBtwThreads.visibleTurnsStep
            ),
            60
        )

        // Parse blocks across all visible turns + glued Mermaid turn without crashing or dropping prose.
        let gluedBlocks = OrbNativeMarkdownView.parseBlocks(merged[0].answer)
        XCTAssertTrue(gluedBlocks.contains { if case .mermaid(_, complete: true) = $0 { return true }; return false })
        for turn in merged.suffix(initialVisible) {
            for seg in OrbFileRefs.segments(turn.answer) {
                if case .text(let md) = seg {
                    _ = OrbNativeMarkdownView.parseBlocks(md)
                }
            }
        }

        // Verify OrbMermaidRenderer's inline WebView mount gate caps automatic mounts at 8.
        let renderer = OrbMermaidRenderer.shared
        while renderer.activeInlineMounts > 0 { renderer.releaseInlineMount() }
        var admittedCount = 0
        for _ in 0..<28 {
            if renderer.acquireInlineMount() { admittedCount += 1 }
        }
        XCTAssertEqual(admittedCount, OrbMermaidRenderer.maxInlineDiagramMounts)
        XCTAssertEqual(renderer.activeInlineMounts, OrbMermaidRenderer.maxInlineDiagramMounts)
        for _ in 0..<admittedCount { renderer.releaseInlineMount() }
        XCTAssertEqual(renderer.activeInlineMounts, 0)
    }
}
