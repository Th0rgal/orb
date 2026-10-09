import XCTest
import SwiftUI
@testable import sandboxed_sh

/// Same inputs as the desktop `quiz.test.tsx` and `message-images.test.tsx`, so both clients agree.
final class OrbDesktopParityTests: XCTestCase {
    private let quiz = "Oui.\n\n## Quiz de test\n\n**1. Combien font 7 × 8 ?** A) 48   B) 56   C) 64\n\n**2. Quel mot est un verbe ?** A) Rapidement B) Maison C) Apprendre\n\n**3. Tous les chats sont des mammifères. Félix est un chat. Que peut-on conclure ?** A) Félix est un mammifère. B) Tous les mammifères sont des chats. C) Félix n’est pas un mammifère.\n\nRéponds avec le numéro et la lettre pour chaque question, et je te donnerai ton score."

    func testQuizKeepsQuestionsChoicesIntroAndOutro() throws {
        let q = try XCTUnwrap(OrbQuizData.parse(quiz))
        XCTAssertEqual(q.questions.count, 3)
        XCTAssertEqual(q.questions[0].text, "Combien font 7 × 8 ?")
        XCTAssertEqual(q.questions[0].choices.map(\.letter), ["A", "B", "C"])
        XCTAssertEqual(q.questions[2].choices[2].text, "Félix n’est pas un mammifère.")
        XCTAssertTrue(q.before.contains("Oui."))
        XCTAssertTrue(q.after.contains("Réponds"))
    }

    func testQuizRefusesAnythingItWouldHaveToGuess() {
        XCTAssertNil(OrbQuizData.parse("Quiz\n1. Question A) one C) three"))
        XCTAssertNil(OrbQuizData.parse("Ordinary list\n1. Question A) one B) two"))
        XCTAssertNil(OrbQuizData.parse("Quiz\n```\n1. Question A) one B) two\n```"))
        XCTAssertNil(OrbQuizData.parse("Quiz\n1. Question A) One B) Two\n\nUnrelated prose\n\n2. Other A) X B) Y"))
        XCTAssertEqual(OrbQuizData.parse("Quiz\n1. Question ?\nA) One\nB) Two\n\n2. Another ?\nA) Three\nB) Four")?.questions.count, 2)
    }

    func testQuizReplyMatchesTheDesktopMessage() throws {
        let q = try XCTUnwrap(OrbQuizData.parse(quiz))
        XCTAssertEqual(q.reply(["1": "B", "2": "C", "3": "A"]),
                       "Mes réponses au quiz :\n1. B) 56\n2. C) Apprendre\n3. A) Félix est un mammifère.")
    }

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
}

