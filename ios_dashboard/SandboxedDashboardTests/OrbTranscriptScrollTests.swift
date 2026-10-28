import SwiftUI
import XCTest
@testable import sandboxed_sh

final class OrbTranscriptScrollTests: XCTestCase {
    /// Values measured on iPhone 17 Pro: 874 pt bounds, 116 pt navigation bar, 133 pt composer.
    private func metrics(offset: CGFloat, content: CGFloat = 4442, container: CGFloat = 625, top: CGFloat = 116, bottom: CGFloat = 133) -> OrbScrollMetrics {
        var m = OrbScrollMetrics()
        m.offsetY = offset; m.contentHeight = content; m.visibleHeight = container
        m.topInset = top; m.bottomInset = bottom
        return m
    }

    func testDistanceFromBottomUsesInsetFreeContainer() {
        XCTAssertEqual(metrics(offset: 3701).distanceFromBottom, 0, "fully scrolled: content + bottom inset - bounds")
        XCTAssertEqual(metrics(offset: 3691).distanceFromBottom, 10, "the old open path stopped 10 pt short")
        XCTAssertEqual(metrics(offset: -116).progress, 0)
        XCTAssertEqual(metrics(offset: 3701).progress, 1)
    }

    func testKeyboardInsetKeepsSameBottomMath() {
        // Keyboard up: the container shrinks and the bottom inset grows by the same amount.
        let m = metrics(offset: 3992, container: 324, bottom: 434)
        XCTAssertEqual(m.distanceFromBottom, 10)
    }

    func testShortTranscriptIsNotScrollable() {
        let m = metrics(offset: -116, content: 400)
        XCTAssertFalse(m.scrollable)
        XCTAssertEqual(m.distanceFromBottom, 0)
        XCTAssertEqual(m.progress, 1)
    }

    @MainActor func testUnpinnedScrollerShowsPillOnlyFarFromBottom() {
        let scroller = OrbTranscriptScroller()
        scroller.update(metrics(offset: 3701))
        scroller.phaseChanged(.interacting)
        XCTAssertFalse(scroller.pinned)
        scroller.update(metrics(offset: 3600))
        XCTAssertFalse(scroller.showsJumpToLatest, "101 pt away is still near the latest message")
        scroller.update(metrics(offset: 2000))
        scroller.phaseChanged(.idle)
        XCTAssertTrue(scroller.showsJumpToLatest)
        XCTAssertFalse(scroller.pinned)
        scroller.phaseChanged(.interacting)
        scroller.update(metrics(offset: 3680))
        scroller.phaseChanged(.idle)
        XCTAssertTrue(scroller.pinned, "settling within 40 pt re-pins")
        XCTAssertFalse(scroller.showsJumpToLatest)
    }

    @MainActor func testSingleScrollCorrectionPerLayoutEpochAndClientParity() {
        let scroller = OrbTranscriptScroller()
        scroller.update(metrics(offset: 3600))
        let epoch1 = scroller.layoutEpoch
        XCTAssertEqual(scroller.correctionsInEpoch, 1, "first layout pass in epoch applies one scroll correction")
        XCTAssertEqual(scroller.lastCorrectedEpoch, epoch1)

        // Second pass in the same layoutEpoch must be suppressed (`scroll_single_correction_per_epoch`)
        let secondInSameEpoch = scroller.evaluateEpochScrollCorrection(targetTop: 3817, currentTop: 3700)
        XCTAssertFalse(secondInSameEpoch, "duplicate scroll correction in the same layout epoch is suppressed")
        XCTAssertEqual(scroller.correctionsInEpoch, 1)

        // Advancing to a new layout epoch (content height grows) admits exactly one new correction
        scroller.update(metrics(offset: 3600, content: 4800))
        XCTAssertEqual(scroller.layoutEpoch, epoch1 + 1)
        XCTAssertEqual(scroller.correctionsInEpoch, 1)
        XCTAssertEqual(scroller.lastCorrectedEpoch, epoch1 + 1)

        // Verify cross-client parity digest across Core (0), iOS (1), Android (2), and Desktop wasm32 (3)
        let coreParity = OrbKernel.clientParityStep(
            clientTarget: 0, wireSchemaId: 1, transcriptSeq: 42, markdownBlocksCount: 7, sendQueueDepth: 1, scrollCorrectedInEpoch: 1
        )
        let iosParity = OrbKernel.clientParityStep(
            clientTarget: 1, wireSchemaId: 1, transcriptSeq: 42, markdownBlocksCount: 7, sendQueueDepth: 1, scrollCorrectedInEpoch: 1
        )
        let androidParity = OrbKernel.clientParityStep(
            clientTarget: 2, wireSchemaId: 1, transcriptSeq: 42, markdownBlocksCount: 7, sendQueueDepth: 1, scrollCorrectedInEpoch: 1
        )
        let wasmParity = OrbKernel.clientParityStep(
            clientTarget: 3, wireSchemaId: 1, transcriptSeq: 42, markdownBlocksCount: 7, sendQueueDepth: 1, scrollCorrectedInEpoch: 1
        )
        XCTAssertTrue(iosParity.parityAdmitted)
        XCTAssertTrue(iosParity.singleScrollCorrectionOk)
        XCTAssertEqual(coreParity.digest32, iosParity.digest32)
        XCTAssertEqual(iosParity.digest32, androidParity.digest32)
        XCTAssertEqual(androidParity.digest32, wasmParity.digest32)
    }

    func testInlinePreviewNeverEndsInsideATableOrFence() {
        let table = (1...200).map { "| row \($0) | value \($0) | more |" }.joined(separator: "\n")
        let source = "# Title\n\nIntro paragraph.\n\n| A | B | C |\n| --- | --- | --- |\n" + table
        let preview = OrbNativeMarkdownView.inlinePreview(source, limit: 400)
        XCTAssertEqual(preview, "# Title\n\nIntro paragraph.")

        let fenced = "Before.\n\n```swift\n" + String(repeating: "let x = 1\n", count: 100) + "```\n\nAfter."
        XCTAssertEqual(OrbNativeMarkdownView.inlinePreview(fenced, limit: 200), "Before.")

        let closed = "Text.\n\n```sh\nls\n```\n\n" + String(repeating: "word ", count: 200)
        XCTAssertEqual(OrbNativeMarkdownView.inlinePreview(closed, limit: 300), "Text.\n\n```sh\nls\n```")
        XCTAssertEqual(OrbNativeMarkdownView.inlinePreview("short", limit: 300), "short")
    }
}

final class OrbDateCacheTests: XCTestCase {
    func testParsesBothCoreTimestampShapesAndMemoizes() {
        let a = OrbDateCache.parse("2026-10-21T06:50:29.656722494+00:00")
        let b = OrbDateCache.parse("2026-10-21T06:50:29Z")
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(a!.timeIntervalSince1970, b!.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(OrbDateCache.parse("2026-10-21T06:50:29Z"), b, "cached value is stable")
        XCTAssertNil(OrbDateCache.parse(""))
        XCTAssertNil(OrbDateCache.parse("not a date"))
        XCTAssertEqual(OrbStyle.parseDate("2026-10-21T06:50:29Z"), b)
        XCTAssertEqual(OrbTurnSummary.parseDate("2026-10-21T06:50:29Z"), b)
    }
}

final class OrbPendingQuestionTests: XCTestCase {
    private func event(_ id: Int64, _ type: String, call: String?, tool: String? = nil, content: String = "{}") -> StoredEvent {
        StoredEvent(id: id, missionId: "m", sequence: id, eventType: type, timestamp: "", eventId: nil, toolCallId: call, toolName: tool, content: content, metadata: [:])
    }

    func testOnlyUnansweredDecodableQuestionsRemain() {
        let events = [
            event(1, "tool_call", call: "a", tool: "AskUserQuestion", content: #"{"question":"Pick one"}"#),
            event(2, "tool_call", call: "b", tool: "question", content: #"{"question":"Answered"}"#),
            event(3, "tool_result", call: "b"),
            event(4, "tool_call", call: "c", tool: "bash", content: "{}"),
            event(5, "tool_call", call: "d", tool: "ui_native_request", content: "not json"),
        ]
        let open = OrbPendingQuestion.extract(events)
        XCTAssertEqual(open.map(\.id), [1])
        XCTAssertEqual(open.first?.request["question"].text, "Pick one")
    }

    func testLinearOnLongTranscripts() {
        var events: [StoredEvent] = []
        for i in 0..<20_000 { events.append(event(Int64(i), i % 2 == 0 ? "tool_call" : "tool_result", call: "c\(i / 2)", tool: "bash")) }
        measure { _ = OrbPendingQuestion.extract(events) }
    }
}

@MainActor
final class OrbTranscriptModelTests: XCTestCase {
    private func userEvent(_ seq: Int64, _ text: String) -> StoredEvent {
        StoredEvent(id: seq, missionId: "m", sequence: seq, eventType: "user_message", timestamp: "", eventId: nil, toolCallId: nil, toolName: nil, content: text, metadata: [:])
    }

    func testDistinctEventSequencesSurviveAndHistoryReportsGrowth() {
        let mission: OrbJSON = .object(["history": .array([
            .object(["role": .string("user"), "content": .string("first")]),
            .object(["role": .string("assistant"), "content": .string("reply")]),
        ])])
        let model = OrbTranscriptModel()
        model.events = [userEvent(1, "first "), userEvent(2, "second"), userEvent(3, " second")]
        XCTAssertEqual(model.rebuildHistory(isCloud: false, turns: [], mission: mission, optimisticPrompt: nil), 4)
        XCTAssertEqual(model.history.map(\.2), ["first", "reply", "second", " second"], "distinct delivered sequences are not deduplicated by text")
        XCTAssertEqual(model.rebuildHistory(isCloud: false, turns: [], mission: mission, optimisticPrompt: "third"), 1)
        XCTAssertEqual(model.history.last?.2, "third")
        XCTAssertEqual(model.rebuildHistory(isCloud: false, turns: [], mission: mission, optimisticPrompt: "third"), 0)
    }

    func testHistoryIsLinearOnManyUserEvents() {
        let events = (0..<5_000).map { userEvent(Int64($0), "message \($0)") }
        measure { _ = OrbTranscriptModel.computeHistory(isCloud: false, turns: [], mission: .null, events: events, optimisticPrompt: nil) }
    }

    /// SwiftUI writes the resolved position back through `.scrollPosition` while it applies
    /// a request. If that write invalidated the transcript, the body re-issued the request in
    /// the same update and a long transcript never settled (send hang, mission 1c33522d).
    @MainActor func testScrollPositionWriteBackDoesNotInvalidateButRequestsDo() {
        let scroller = OrbTranscriptScroller()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        var changes: Int { counter.value }
        func track() { withObservationTracking { _ = scroller.position } onChange: { counter.value += 1 } }
        track()
        var resolved = ScrollPosition(edge: .bottom); resolved.scrollTo(y: 1234)
        scroller.position = resolved
        XCTAssertEqual(changes, 0, "a write-back from SwiftUI must not invalidate the view")
        XCTAssertEqual(scroller.position, resolved, "the write-back is still stored")
        scroller.scrollToBottom()
        XCTAssertEqual(changes, 1, "Orb's own scroll request reaches SwiftUI")
        track(); scroller.scroll(toProgress: 0.2)
        XCTAssertEqual(changes, 2)
    }
}
