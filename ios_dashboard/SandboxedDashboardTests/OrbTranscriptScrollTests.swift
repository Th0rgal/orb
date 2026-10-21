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
