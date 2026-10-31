import XCTest
@testable import sandboxed_sh

/// Same cases as desktop `orb/tests/narration-fold.test.tsx`.
final class OrbNarrationFoldTests: XCTestCase {
    private var sequence: Int64 = 0
    private func event(_ type: String, _ content: String, tool: String? = nil, call: String? = nil) -> StoredEvent {
        sequence += 1
        return StoredEvent(id: sequence, missionId: "m", sequence: sequence, eventType: type, timestamp: "2026-10-22T12:00:00Z", eventId: "e\(sequence)", toolCallId: call, toolName: tool, content: content, metadata: [:])
    }
    private func say(_ text: String) -> StoredEvent { event("assistant_message", text) }
    private func call(_ id: String, _ name: String = "bash", done: Bool = true) -> [StoredEvent] {
        [event("tool_call", "{\"command\":\"run \(id)\"}", tool: name, call: id)] + (done ? [event("tool_result", "ok", tool: name, call: id)] : [])
    }
    private func keys(_ events: [StoredEvent]) -> [String] {
        let found = OrbWorkModel.narrationKeys(OrbWorkModel.narrationItems(events), standalone: { OrbOrchestration.kind($0) != nil })
        return events.filter { found.contains("seq-\($0.sequence)") }.map(\.content)
    }

    func testFoldsTextBetweenToolsAndKeepsTheAnswer() {
        let events = [event("user_message", "fix it"), say("Let me look.")] + call("1") + [say("WAIT A MINUTE! Why did that pass?")] + call("2") + [say("Fixed: the guard was inverted.")]
        XCTAssertEqual(keys(events), ["Let me look.", "WAIT A MINUTE! Why did that pass?"])
        let model = OrbWorkModel.build(from: events, working: false)
        XCTAssertEqual(model.notes.map(\.text), ["Let me look.", "WAIT A MINUTE! Why did that pass?"])
        XCTAssertEqual(model.notes.map(\.afterTools), [0, 1])
        XCTAssertEqual(model.outcomeAfterTodos, .finished)
        let rows = [("u", "user", "fix it"), ("a1", "assistant", "Let me look."), ("a2", "assistant", "WAIT A MINUTE! Why did that pass?"), ("a3", "assistant", "Fixed: the guard was inverted.")]
        XCTAssertEqual(OrbConversation.withoutNarration(rows, narration: model.narrationTexts).map(\.2), ["fix it", "Fixed: the guard was inverted."])
    }

    func testNeverFoldsAcrossUserMessageNorBesideOrchestrationOnly() {
        let events = [say("Done."), event("user_message", "again")] + call("1") + [say("Delegating.")] + call("s", "start_mission") + [say("All done.")]
        XCTAssertEqual(keys(events), [])
    }

    func testCumulativeBubbleIsNeverNarration() {
        let items: [OrbWorkModel.NarrationItem] = [.user, .text(key: "c", text: "Inspect file.", cumulative: true), .tool(name: "bash"), .text(key: "a", text: "Inspect file. Done.", cumulative: false)]
        XCTAssertTrue(OrbWorkModel.narrationKeys(items).isEmpty)
    }

    func testLatestNarrationWhileWorking() {
        let events = [event("user_message", "fix it")] + call("1") + [say("First idea.")] + call("2") + [say("**Aha!** Look at that error.")] + call("3", done: false)
        let model = OrbWorkModel.build(from: events, working: true)
        XCTAssertEqual(model.notes.last.map { OrbWorkModel.narrationLine($0.text) }, "Aha! Look at that error.")
    }

    func testNarrationLineClampsToOnePlainLine() {
        XCTAssertEqual(OrbWorkModel.narrationLine("**HOLD ON!**  Look at\n`nm` output:\n```\nU x\n```"), "HOLD ON! Look at nm output:")
    }

    func testCanonicalNarrationFoldsBetweenToolsDuringLiveTurn() {
        let canonical = StoredEvent(id: 10, missionId: "m", sequence: 10, eventType: "assistant_message_canonical", timestamp: "2026-10-22T12:00:00Z", eventId: "step:1", toolCallId: nil, toolName: nil, content: "Inspecting the Blacksmith runner.", metadata: ["bubble_id": AnyCodable("step:1"), "revision": AnyCodable(1)])
        let events = [event("user_message", "check")] + call("1") + [canonical] + call("2", done: false)
        let model = OrbWorkModel.build(from: events, working: true)
        XCTAssertEqual(model.notes.map(\.text), ["Inspecting the Blacksmith runner."])
    }

    func testMergeStoredEventsDeduplicatesMutableTextDeltaLatestToHighestSequence() {
        let user = event("user_message", "check")
        let oldDelta = StoredEvent(id: 2, missionId: "m", sequence: 12, eventType: "text_delta", timestamp: "", eventId: "text_delta_latest", toolCallId: nil, toolName: nil, content: "Step 1", metadata: [:])
        let newDelta = StoredEvent(id: 2, missionId: "m", sequence: 28, eventType: "text_delta", timestamp: "", eventId: "text_delta_latest", toolCallId: nil, toolName: nil, content: "Step 1\n\nStep 2", metadata: [:])
        let merged = OrbConversation.mergeStoredEvents(existing: [user, oldDelta], incoming: [newDelta])
        let deltas = merged.filter { $0.eventType == "text_delta" }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.sequence, 28)
        XCTAssertEqual(deltas.first?.content, "Step 1\n\nStep 2")
    }
}
