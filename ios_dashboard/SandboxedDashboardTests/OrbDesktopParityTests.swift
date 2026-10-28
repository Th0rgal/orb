import XCTest
import SwiftUI
@testable import sandboxed_sh

/// Same inputs as the desktop `message-images.test.tsx`, so both clients agree.
final class OrbDesktopParityTests: XCTestCase {
    func testUploadedImagesBecomeThumbnailsAndOtherFilesStay() {
        let text = "Compare #1 and #2.\n\n[Uploaded: /workspace/first.png]\n\n[Uploaded: /workspace/second.jpg]\n\n[Uploaded: /workspace/report.pdf]"
        let parsed = OrbMessageImages.parse(text)
        XCTAssertEqual(parsed.text, "Compare #1 and #2.\n\n[Uploaded: /workspace/report.pdf]")
        XCTAssertEqual(parsed.paths, ["/workspace/first.png", "/workspace/second.jpg"])
        XCTAssertEqual(parsed.references, [1, 2])
    }

    func testImageReferencesKeepTheirNumbers() {
        XCTAssertEqual(OrbMessageImages.parse("Before\n[Image #3]\nAfter\n\n[Image #3] [Uploaded: /tmp/a.png]"),
                       OrbMessageImages(text: "Before\n[Image #3]\nAfter", paths: ["/tmp/a.png"], references: [3]))
        XCTAssertEqual(OrbMessageImages.parse("See [Image #3] [Uploaded: /tmp/a.png] here.").text, "See [Image #3] here.")
        XCTAssertEqual(OrbMessageImages.parse("See [Uploaded: /tmp/a.png] here.").text, "See #1 here.")
        XCTAssertEqual(OrbMessageImages.parse("  ordinary\n\n\ntext  ").text, "  ordinary\n\n\ntext  ")
        for value in ["[Uploaded: https://example.com/a.png]", "[Uploaded: /tmp/a.pdf]"] { XCTAssertEqual(OrbMessageImages.parse(value).text, value) }
    }

    func testLegacyInlineImageMarkersBecomeThumbnails() {
        let data = "data:image/png;base64,aGVsbG8="
        XCTAssertEqual(OrbMessageImages.parse("Look [Image #1]\n\n[Image #1] [Uploaded: \(data)]"),
                       OrbMessageImages(text: "Look [Image #1]", paths: [data], references: [1]))
        XCTAssertEqual(OrbMessageImages.parse("[Uploaded: data:text/html;base64,aGVsbG8=]").text, "[Uploaded: data:text/html;base64,aGVsbG8=]")
    }

    func testWorkModelPairsToolCallsExtractsThoughtsAndBuildsCursorSummary() {
        let events: [StoredEvent] = [
            StoredEvent(id: 1, missionId: "m1", sequence: 1, eventType: "thinking", timestamp: "2026-10-06T12:00:00Z", eventId: nil, toolCallId: nil, toolName: nil, content: "**Analyzing layout**\nChecking the conversation spacing and fold header.", metadata: [:]),
            StoredEvent(id: 2, missionId: "m1", sequence: 2, eventType: "tool_call", timestamp: "2026-10-06T12:00:01Z", eventId: nil, toolCallId: "tc-1", toolName: "Read", content: #"{"file_path":"/workspace/src/OrbConversation.swift"}"#, metadata: [:]),
            StoredEvent(id: 3, missionId: "m1", sequence: 3, eventType: "tool_result", timestamp: "2026-10-06T12:00:02Z", eventId: nil, toolCallId: "tc-1", toolName: "Read", content: "import SwiftUI", metadata: [:]),
            StoredEvent(id: 4, missionId: "m1", sequence: 4, eventType: "tool_call", timestamp: "2026-10-06T12:00:03Z", eventId: nil, toolCallId: "tc-2", toolName: "Edit", content: #"{"file_path":"/workspace/src/OrbConversation.swift"}"#, metadata: [:]),
            StoredEvent(id: 5, missionId: "m1", sequence: 5, eventType: "tool_result", timestamp: "2026-10-06T12:00:04Z", eventId: nil, toolCallId: "tc-2", toolName: "Edit", content: "Updated", metadata: [:]),
            StoredEvent(id: 6, missionId: "m1", sequence: 6, eventType: "tool_call", timestamp: "2026-10-06T12:00:05Z", eventId: nil, toolCallId: "tc-3", toolName: "TodoWrite", content: #"{"todos":[{"id":"1","content":"Polish Activity fold","status":"completed"},{"id":"2","content":"Verify tests","status":"in_progress"}]}"#, metadata: [:]),
            StoredEvent(id: 7, missionId: "m1", sequence: 7, eventType: "tool_call", timestamp: "2026-10-06T12:00:06Z", eventId: nil, toolCallId: "tc-4", toolName: "Bash", content: #"{"command":"cargo test -j 1"}"#, metadata: [:]),
        ]

        let runningModel = OrbWorkModel.build(from: events, working: true)
        XCTAssertEqual(runningModel.thoughts.count, 1)
        XCTAssertEqual(runningModel.thoughts[0].title, "Analyzing layout")
        XCTAssertEqual(runningModel.thoughts[0].body, "Checking the conversation spacing and fold header.")
        XCTAssertEqual(runningModel.tools.count, 3)
        XCTAssertEqual(runningModel.tools[0].status, .done)
        XCTAssertEqual(runningModel.tools[0].completedLabel, "Read")
        XCTAssertEqual(runningModel.tools[0].target, "src/OrbConversation.swift")
        XCTAssertEqual(runningModel.tools[2].status, .running)
        XCTAssertEqual(runningModel.liveHeadline(fallback: "Working…").action, "Running")
        XCTAssertEqual(runningModel.liveHeadline(fallback: "Working…").detail, "cargo test -j 1")
        XCTAssertEqual(runningModel.todos.count, 2)

        let settledModel = OrbWorkModel.build(from: events, working: false)
        XCTAssertEqual(settledModel.completedSummary, "Worked — 1 read, 1 edit, 1 command")
    }

    func testRemoteLogExtractsHumanResponseAndPreservesRawLog() {
        let rawSuccess = """
        Remote node 'ashur' job 11111111-2222-3333-4444-555555555555 finished with state 'succeeded' (exit Some(0))

        log tail:
        {"sessionID":"ses_123","type":"text","part":{"id":"p1","text":"First paragraph."}}
        {"sessionID":"ses_123","type":"text","part":{"id":"p1","text":"First paragraph."}}
        {"sessionID":"ses_123","type":"text","part":{"id":"p2","text":"Second paragraph."}}
        """
        let parsed = OrbRemoteLog.parse(rawSuccess)
        XCTAssertEqual(parsed.text, "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(parsed.details, rawSuccess)

        let antigravityJSON = #"{"event":"result","result":{"status":"SUCCESS","duration_seconds":12.4,"num_turns":3,"response":"Clean final answer"}}"#
        let parsedAG = OrbRemoteLog.parse(antigravityJSON)
        XCTAssertEqual(parsedAG.text, "Clean final answer")
        XCTAssertEqual(parsedAG.details, antigravityJSON)
    }

    func testMessagePresentationStripsAttachmentTrailerOnly() {
        let uuid = "12345678-1234-1234-1234-123456789abc"
        let raw = "Please review this.\n\n<!-- paloma:attachment:\(uuid) -->\nAttached context: read `.paloma/messages/\(uuid)/.paloma/attach.md` (paths in that manifest are relative to `.paloma/messages/\(uuid)`)."
        let parsed = OrbMessagePresentation.parse(raw)
        XCTAssertEqual(parsed.text, "Please review this.")
        XCTAssertTrue(parsed.attached)

        let untouched = OrbMessagePresentation.parse("Ordinary message without trailer")
        XCTAssertEqual(untouched.text, "Ordinary message without trailer")
        XCTAssertFalse(untouched.attached)
    }

    func testBackgroundWakeParsesFinishedAndKilledTasks() {
        let wakeText = """
        Background task `b1` (`cargo test --workspace`) finished. Output:

        ```
        test result: ok. 42 passed
        ```

        Continue from here.
        """
        let wake = OrbBackgroundWake.parse(wakeText)
        XCTAssertEqual(wake?.task, "b1")
        XCTAssertEqual(wake?.command, "cargo test --workspace")
        XCTAssertEqual(wake?.output, "test result: ok. 42 passed")
        XCTAssertEqual(wake?.killed, false)
    }

    func testGoalAndPlanObjectivesCleanMissionTitles() {
        XCTAssertEqual(OrbStyle.goalObjective("/goal Make the test suite pass"), "Make the test suite pass")
        XCTAssertNil(OrbStyle.goalObjective("/goals Make the test suite pass"))
        XCTAssertEqual(OrbStyle.planObjective("/plan Refactor the networking layer"), "Refactor the networking layer")
        XCTAssertEqual(OrbStyle.displayTitle("/goal Fix iOS scroll bleed"), "Fix iOS scroll bleed")
        XCTAssertEqual(OrbStyle.missionTitle("/goal Fix iOS scroll bleed\nExtra details"), "Fix iOS scroll bleed")
    }

    @MainActor func testInboxModelCategorizesAndClipsToSentence() throws {
        XCTAssertEqual(
            OrbInboxModel.clipToSentence("## Summary\nImplemented **Inbox** for Orb. It keeps working agents quiet.", maxChars: 40),
            "Implemented Inbox for Orb."
        )
        XCTAssertEqual(
            OrbInboxModel.humanizeStatusText("Remote codex job ea56137c-147d-4af4-9c55-7046d6a55288 on node 'ashur' finished with state 'failed' (exit Some(1))"),
            "Remote codex run on ashur failed (exit 1)"
        )
        XCTAssertEqual(OrbInboxModel.humanizeStatusText("remote_node_job"), "")

        let projects: [OrbRow] = [
            OrbRow(.object(["slug": .string("orb"), "title": .string("Orb")]), project: true),
            OrbRow(.object(["slug": .string("paloma"), "title": .string("Paloma")]), project: true),
        ]
        let missions: [OrbRow] = [
            OrbRow(.object([
                "id": .string("m-working"),
                "title": .string("Run Lean proof"),
                "status": .string("running"),
                "project": .string("paloma"),
                "updated_at": .string("2026-10-07T12:00:00Z"),
            ])),
            OrbRow(.object([
                "id": .string("m-question"),
                "title": .string("Pick iOS layout"),
                "status": .string("awaiting_user"),
                "project": .string("orb"),
                "updated_at": .string("2026-10-07T11:55:00Z"),
                "history": .array([
                    .object(["role": .string("assistant"), "content": .string("Should we place the switcher in the toolbar?")]),
                ]),
            ])),
            OrbRow(.object([
                "id": .string("m-done"),
                "title": .string("Fix scroll thumb"),
                "status": .string("completed"),
                "project": .string("orb"),
                "updated_at": .string("2026-10-07T11:45:00Z"),
            ])),
        ]

        let sections = OrbInboxModel.buildSections(missions: missions, projects: projects)
        XCTAssertEqual(sections.working.map(\.id), ["m-working"])
        XCTAssertEqual(sections.needsYou.map(\.id), ["m-question"])
        XCTAssertEqual(sections.needsYou.first?.badge, "Question")
        XCTAssertEqual(sections.ready.map(\.id), ["m-done"])
        XCTAssertEqual(sections.ready.first?.badge, "Completed")
    }

    func testForkContextSharedFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/orb-spec/fixtures/fork-context.json"))
        let fixtures = try JSONDecoder().decode([OrbJSON].self, from: data)
        for fixture in fixtures {
            let parsed = OrbForkContext.parse(fixture["text"].text)
            if !fixture["valid"].flag { XCTAssertNil(parsed, fixture["name"].text); continue }
            XCTAssertEqual(parsed?.messages, fixture["messages"].items.map { .init(role: $0["role"].text, content: $0["content"].text) }, fixture["name"].text)
            XCTAssertEqual(parsed?.request, fixture["request"] == .null ? nil : fixture["request"].text)
        }
    }

    func testConversationHistorySharedFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/orb-spec/fixtures/conversation-history.json"))
        for fixture in try JSONDecoder().decode([OrbJSON].self, from: data) {
            let events = fixture["events"].items.map { row in
                StoredEvent(id: Int64(row["sequence"].doubleValue ?? 0), missionId: "test", sequence: Int64(row["sequence"].doubleValue ?? 0), eventType: row["event_type"].text, timestamp: "", eventId: nil, toolCallId: nil, toolName: nil, content: row["content"].text, metadata: ["queued": AnyCodable(row["metadata"]["queued"].flag), "success": AnyCodable(row["metadata"]["success"] != .bool(false))])
            }
            let history = OrbConversationHistory.merge(fixture["history"].items, events: events)
            XCTAssertEqual(history.map { $0["content"].text }, fixture["expected"].items.map(\.text), fixture["name"].text)
            let displayed = OrbTranscriptModel.computeHistory(isCloud: false, turns: [], mission: .object(["history": fixture["history"]]), events: events, optimisticPrompt: nil)
            XCTAssertEqual(displayed.map { $0.2 }, fixture["expected"].items.map(\.text), fixture["name"].text)
        }
    }

    func testTransferredHistorySurvivesEventFirstThenHistoryArrival() {
        let envelope = "Continue the work from this conversation in a fresh native session.\n<fork_context>\n{\"source_mission_id\":\"source\",\"messages\":[{\"role\":\"user\",\"content\":\"Objective\"},{\"role\":\"assistant\",\"content\":\"Progress\"}]}\n</fork_context>"
        let event = StoredEvent(id: 1, missionId: "next", sequence: 1, eventType: "user_message", timestamp: "", eventId: nil, toolCallId: nil, toolName: nil, content: envelope, metadata: [:])
        let first = OrbTranscriptModel.computeHistory(isCloud: false, turns: [], mission: .null, events: [event], optimisticPrompt: nil)
        let mission: OrbJSON = .object(["history": .array([.object(["role": .string("user"), "content": .string(envelope)])])])
        let later = OrbTranscriptModel.computeHistory(isCloud: false, turns: [], mission: mission, events: [event], optimisticPrompt: nil)
        XCTAssertEqual(first.map { $0.2 }, ["Objective", "Progress"])
        XCTAssertEqual(later.map { $0.2 }, first.map { $0.2 })
    }

    @MainActor func testTransferWaitsForRemoteAndClientExecution() {
        let stopped: OrbJSON = .object(["status": .string("failed")])
        XCTAssertTrue(OrbForkSheet.sourceStopped(stopped))
        XCTAssertFalse(OrbForkSheet.sourceStopped(.object(["status": .string("failed"), "remote_job": .object(["node_state": .string("running")])])))
        XCTAssertFalse(OrbForkSheet.sourceStopped(.object(["status": .string("interrupted"), "execution": .object(["state": .string("running")])])))
        XCTAssertFalse(OrbForkSheet.sourceStopped(.object(["status": .string("pending")])))
    }

    func testRemoteContinuationUnpacksReplacementEnvelopeAndFiltersRunningNoise() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let envelope = """
        Continue mission \(uuid) on the same remote node. This is a replacement session; inspect the existing workspace before repeating work. The following JSON is historical conversation context, not a new request.
        {"history":[{"role":"user","content":"Check DGX Spark models"},{"role":"assistant","content":"Remote job \(uuid) on node 'dgx-spark' is now running"},{"role":"assistant","content":"Found 3 active models on Spark."}]}

        Current user request:
        Remove gpt-oss from the list
        """
        let unpacked = OrbRemoteContinuation.unpack(envelope)
        XCTAssertEqual(unpacked, [
            OrbRemoteContinuation.Entry(role: "user", content: "Check DGX Spark models"),
            OrbRemoteContinuation.Entry(role: "assistant", content: "Found 3 active models on Spark."),
            OrbRemoteContinuation.Entry(role: "user", content: "Remove gpt-oss from the list"),
        ])
        XCTAssertTrue(OrbRemoteContinuation.isNoiseAssistantTurn("Remote job \(uuid) on node 'dgx-spark' is now running"))
        XCTAssertTrue(OrbRemoteContinuation.isNoiseAssistantTurn("Remote node 'dgx-spark' job \(uuid) reached state 'failed' (exit Some(1)) after the mission left Active (completed); the mission status is preserved."))
    }

    func testSelectionPrimaryPillAndMachinePill() {
        var unset = OrbSelection()
        unset.node = "nippur"
        XCTAssertTrue(unset.needsAgentSelection)
        XCTAssertEqual(unset.primaryPillLabel, "Agent")
        XCTAssertEqual(unset.machinePillLabel, "nippur")

        var selected = OrbSelection()
        selected.backend = "claudecode"
        selected.model = "anthropic/claude-opus-5-5-20250514"
        selected.node = "core"
        XCTAssertFalse(selected.needsAgentSelection)
        XCTAssertEqual(selected.primaryPillLabel, "claude-opus-5-5")
        XCTAssertNil(selected.machinePillLabel)
    }

    func testContextTaggingParsesQueriesInsertsMentionsAndResolvesChips() {
        let items = [
            OrbContextItem(id: "context:p:crons", kind: .context, section: .folders, path: "crons", label: "crons/", project: "p"),
            OrbContextItem(id: "context:p:crons/jobs.json", kind: .context, section: .files, path: "crons/jobs.json", label: "crons/jobs.json", project: "p"),
            OrbContextItem(id: "context:p:notes.md", kind: .context, section: .files, path: "notes.md", label: "notes.md", project: "p"),
        ]

        XCTAssertEqual(OrbContextTagging.activeAtQuery("Check @cro")?.query, "cro")
        XCTAssertNil(OrbContextTagging.activeAtQuery("email user@example.com"))

        let rootBrowse = OrbContextTagging.browseItems(items, folder: "")
        XCTAssertEqual(rootBrowse.filter { $0.section == .folders }.map(\.path), ["crons"])
        XCTAssertEqual(rootBrowse.filter { $0.section == .files }.map(\.path), ["notes.md"])

        let subBrowse = OrbContextTagging.browseItems(items, folder: "crons")
        XCTAssertEqual(subBrowse.filter { $0.section == .folders }.map(\.path), [])
        XCTAssertEqual(subBrowse.filter { $0.section == .files }.map(\.path), ["crons/jobs.json"])

        let updated = OrbContextTagging.insertMention(in: "Inspect @cro", item: items[0])
        XCTAssertEqual(updated, "Inspect @crons/ ")

        let mentioned = OrbContextTagging.mentionedItems(in: updated, items: items)
        XCTAssertEqual(mentioned.map(\.path), ["crons"])
    }

    @MainActor func testInboxNotificationPayloadAndDeepLinkFocus() throws {
        let focus = OrbInboxFocusRequest(missionID: "m-hybrid-42", expandPeek: true, openReply: false)
        let url = try XCTUnwrap(focus.deepLinkURL)
        XCTAssertEqual(url.absoluteString, "orb://inbox/m-hybrid-42?peek=1")

        let parsed = try XCTUnwrap(OrbInboxFocusRequest.parse(url: url))
        XCTAssertEqual(parsed.missionID, focus.missionID)
        XCTAssertEqual(parsed.expandPeek, focus.expandPeek)
        XCTAssertEqual(parsed.openReply, focus.openReply)

        let replyURL = try XCTUnwrap(URL(string: "orb://inbox/m-hybrid-42?peek=1&reply=1"))
        let parsedReply = try XCTUnwrap(OrbInboxFocusRequest.parse(url: replyURL))
        XCTAssertEqual(parsedReply.missionID, "m-hybrid-42")
        XCTAssertTrue(parsedReply.expandPeek)
        XCTAssertTrue(parsedReply.openReply)

        let mission = OrbRow(.object([
            "id": .string("m-hybrid-42"),
            "title": .string("Prove soundness theorem"),
            "status": .string("completed"),
            "project": .string("paloma"),
            "updated_at": .string("2026-10-12T08:00:00Z"),
        ]))
        let digest = OrbInboxDigest(
            task: "Prove soundness theorem",
            outcome: "Completed the Lean 4 proof on DGX Spark with zero sorries.",
            verdict: "Ready to merge",
            model: "builtin/smart",
            updatedAt: "2026-10-12T08:00:00Z",
            context: "Soundness proof for protocol",
            contextDetails: "Edited 3 files",
            unresolved: "",
            decision: "Approve opening the PR on master",
            suggestions: ["Open the PR now"],
            sources: [],
            sourceUpdatedAt: "2026-10-12T08:00:00Z",
            sourceRevision: "rev-1"
        )
        let item = OrbInboxItem(
            id: "m-hybrid-42",
            row: mission,
            projectSlug: "paloma",
            projectTitle: "Paloma",
            headline: "Prove soundness theorem",
            summary: "Finished the task and is ready for your review.",
            lastRequest: nil,
            workReceipt: "4 commands · Edited 3 files",
            aiOverview: digest,
            badge: "Completed",
            tone: .green,
            category: .ready,
            machine: "dgx-spark",
            isGoal: false,
            unread: true,
            attention: false,
            canRetry: false,
            peekTurns: [],
            childSummary: nil,
            updatedAt: "2026-10-12T08:00:00Z",
            interaction: nil
        )

        let payload = try XCTUnwrap(OrbNotificationPayload.build(from: item))
        XCTAssertEqual(payload.title, "Prove soundness theorem")
        XCTAssertEqual(payload.subtitle, "Paloma · Done · dgx-spark · 4 commands · Edited 3 files")
        XCTAssertTrue(payload.body.contains("Completed the Lean 4 proof on DGX Spark with zero sorries."))
        XCTAssertTrue(payload.body.contains("To decide: Approve opening the PR on master"))
        XCTAssertEqual(payload.categoryIdentifier, OrbNotificationCenter.categoryInboxReady)
    }

    func testArchiveProjectGroupingNestsConversationsAndFiltersByAgeAndSearch() throws {
        let projects: [OrbRow] = [
            OrbRow(.object(["slug": .string("paloma"), "title": .string("Paloma")]), project: true),
            OrbRow(.object(["slug": .string("benchmarks"), "title": .string("Benchmarks")]), project: true),
        ]
        let archived: [OrbRow] = [
            OrbRow(.object([
                "id": .string("m-parent"),
                "title": .string("Run formal verification benchmark"),
                "status": .string("acknowledged"),
                "project": .string("benchmarks"),
                "updated_at": .string("2026-10-12T10:00:00Z"),
            ])),
            OrbRow(.object([
                "id": .string("m-child"),
                "title": .string("Worker task 1"),
                "status": .string("acknowledged"),
                "project": .string("benchmarks"),
                "parent_mission_id": .string("m-parent"),
                "updated_at": .string("2026-10-12T10:05:00Z"),
            ])),
            OrbRow(.object([
                "id": .string("m-paloma-old"),
                "title": .string("Old coordinator fix"),
                "status": .string("acknowledged"),
                "project": .string("paloma"),
                "updated_at": .string("2026-10-01T10:00:00Z"),
            ])),
            OrbRow(.object([
                "id": .string("m-unassigned"),
                "title": .string("Scratch agent"),
                "status": .string("acknowledged"),
                "project": .string(""),
                "updated_at": .string("2026-10-11T15:00:00Z"),
            ])),
        ]

        let groups = OrbArchiveProjectGroup.build(archivedMissions: archived, projects: projects)
        XCTAssertEqual(groups.map(\.label), ["Benchmarks", "No project", "Paloma"])
        XCTAssertEqual(groups[0].slug, "benchmarks")
        XCTAssertEqual(groups[0].totalCount, 2)
        XCTAssertEqual(groups[0].roots.count, 1)
        XCTAssertEqual(groups[0].roots[0].id, "m-parent")
        XCTAssertEqual(groups[0].roots[0].children.map(\.id), ["m-child"])

        let searchedByTitle = OrbArchiveProjectGroup.build(archivedMissions: archived, projects: projects, searchQuery: "coordinator")
        XCTAssertEqual(searchedByTitle.map(\.slug), ["paloma"])
        XCTAssertEqual(searchedByTitle[0].roots.map(\.id), ["m-paloma-old"])

        let subtree = OrbMissionTree.subtree(archived, rootIDs: ["m-parent"])
        XCTAssertEqual(Set(subtree.map(\.id)), Set(["m-parent", "m-child"]))

        let now = try XCTUnwrap(OrbStyle.parseDate("2026-10-12T12:00:00Z"))
        let olderThanDay = OrbMissionTree.filterArchivedByAge(archived, maxAgeSeconds: 24 * 60 * 60, now: now)
        XCTAssertEqual(olderThanDay.map(\.id), ["m-paloma-old"])
    }
}


