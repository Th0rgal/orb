import XCTest
import SwiftUI
@testable import sandboxed_sh

/// Streaming reply text (lean/Orb/Stream.lean). Replays shared/orb-spec/fixtures/stream-commit.json,
/// checks that incremental parsing equals a full parse at every streamed prefix, and the
/// coalescer's laws.
@MainActor
final class OrbStreamTextTests: XCTestCase {
    func testCommitPointsMatchLean() throws {
        let cases = try XCTUnwrap(OrbSpec.json("fixtures/stream-commit.json")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let doc = try XCTUnwrap(c["doc"] as? String), expected = try XCTUnwrap(c["commits"] as? [Int])
            let lines = doc.components(separatedBy: "\n")
            var state = OrbStreamCommit()
            var commits = [state.commit]
            for line in lines { state.scan(OrbStreamCommit.classify(line)); commits.append(state.commit) }
            XCTAssertEqual(commits, expected, doc)
        }
    }

    /// Every fixture doc and a long synthetic reply, streamed 1 to 7 characters at a time
    /// (and grapheme by grapheme through multi-byte text): the incremental blocks equal a
    /// full parse at every step, so the bubble never shows anything a full parse would not.
    func testIncrementalBlocksEqualFullParse() throws {
        let cases = try XCTUnwrap(OrbSpec.json("fixtures/stream-commit.json")["cases"] as? [[String: Any]])
        var docs = cases.compactMap { $0["doc"] as? String }
        docs.append(Self.longReply(sections: 6))
        docs.append("Prix : 3 € | 4 €\nligne | deux\n\n| a | b |\n|---|---|\n| é | 😀 |\n\n```\n\n```\n\ndone")
        docs.append("text\n\n  \n   indented after a whitespace line\n\n> q\n\n---\n\n1. x\n\n")
        for doc in docs {
            for stride in [1, 3, 7] {
                var shown = ""
                var rest = Substring(doc)
                while !rest.isEmpty {
                    shown += rest.prefix(stride); rest = rest.dropFirst(stride)
                    XCTAssertEqual(OrbNativeMarkdownView.streamingBlocks(shown), OrbNativeMarkdownView.parseBlocks(shown), "\(stride): \(shown.debugDescription)")
                }
            }
        }
    }

    func testCoalescerConservesAndRendersOncePerFrame() async throws {
        let live = OrbLiveText()
        live.frame = .milliseconds(30)
        for i in 0..<200 { live.append("d\(i % 10)") }
        XCTAssertTrue(live.hasText)
        XCTAssertEqual(live.received.count, 400, "nothing lost")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(live.text.count, 400, "drained after a frame")
        XCTAssertEqual(live.renders, 1, "200 deltas in one frame render once")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(live.renders, 1, "an idle frame renders nothing")
        live.replace("new")
        XCTAssertEqual(live.text, "new")
        live.clear()
        XCTAssertFalse(live.hasText)
    }

    /// Cost of rendering an 8 KB reply streamed as 4-character deltas (2,000 updates):
    /// a full parse of the reply per update vs the committed-prefix parse.
    func testStreamingParseCostFull() {
        let doc = Self.longReply(sections: 22)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var shown = ""
            for chunk in Self.chunks(doc) { shown += chunk; _ = OrbNativeMarkdownView.parseBlocks(shown) }
        }
    }

    func testStreamingParseCostIncremental() {
        let doc = Self.longReply(sections: 22)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var shown = ""
            for chunk in Self.chunks(doc) { shown += chunk; _ = OrbNativeMarkdownView.streamingBlocks(shown) }
        }
    }

    /// Big tool output is bounded; the work fold shows the same text and error state,
    /// and orchestration results (parsed as JSON) stay whole.
    func testCompactedToolResultsKeepWhatTheFoldShows() {
        func event(_ type: String, _ tool: String, _ content: String, seq: Int64) -> StoredEvent {
            StoredEvent(id: seq, missionId: "m", sequence: seq, eventType: type, timestamp: "", eventId: nil, toolCallId: "c\(seq / 2)", toolName: tool, content: content, metadata: [:])
        }
        let big = "Error: build failed\n" + String(repeating: "line of build output\n", count: 5000)
        let orch = "{\"id\":\"x\",\"pad\":\"" + String(repeating: "a", count: 20000) + "\"}"
        let events = [event("tool_call", "bash", "{\"command\":\"make\"}", seq: 2), event("tool_result", "bash", big, seq: 3),
                      event("tool_call", "sandboxed_start_mission", "{}", seq: 4), event("tool_result", "sandboxed_start_mission", orch, seq: 5)]
        let compact = events.map(\.compacted)
        XCTAssertLessThanOrEqual(compact[1].content.utf8.count, StoredEvent.resultKeepUTF8)
        XCTAssertEqual(compact[3].content, orch, "orchestration results stay whole")
        XCTAssertEqual(OrbWorkModel.build(from: compact, working: false), OrbWorkModel.build(from: events, working: false))
    }

    // MARK: Cost specs (shared/orb-spec/fixtures/stream-cost.json, from lean/Orb/Stream.lean §3-4)

    private func costFixture() throws -> [String: Any] { try OrbSpec.json("fixtures/stream-cost.json") }

    /// Bytes re-parsed over a stream equal Lean's `incCost`: committed text once, plus tails.
    /// A full re-parse per delta (the O(n²) bug) parses `fullBytes` and fails this.
    func testReparsedBytesMatchLean() throws {
        let streams = try XCTUnwrap(costFixture()["streams"] as? [[String: Any]])
        XCTAssertFalse(streams.isEmpty)
        for s in streams {
            let doc = try XCTUnwrap(s["doc"] as? String), stride = try XCTUnwrap(s["stride"] as? Int)
            let parser = OrbStreamBlocks()
            var shown = "", rest = Substring(doc), updates = 0
            while !rest.isEmpty {
                shown += rest.prefix(stride); rest = rest.dropFirst(stride); updates += 1
                _ = parser.blocks(shown)
            }
            XCTAssertEqual(updates, s["updates"] as? Int)
            XCTAssertEqual(parser.parsedBytes, s["reparsedBytes"] as? Int, "stride \(stride): \(doc.prefix(30))")
            XCTAssertLessThanOrEqual(parser.parsedBytes, try XCTUnwrap(s["fullBytes"] as? Int))
        }
    }

    /// The parse cache is a text-keyed LRU: same hits and recency order as the Lean model.
    func testTextCacheMatchesLean() throws {
        let spec = try XCTUnwrap(costFixture()["cache"] as? [String: Any])
        let cache = OrbTextCache<Int>(capacity: try XCTUnwrap(spec["capacity"] as? Int))
        var hits: [Bool] = []
        for op in try XCTUnwrap(spec["ops"] as? [[String: String]]) {
            let key = op["key"]!
            if op["op"] == "get" { hits.append(cache.get(key) != nil) } else { cache.put(key, 0) }
            XCTAssertLessThanOrEqual(cache.count, cache.capacity)
        }
        XCTAssertEqual(hits, spec["hits"] as? [Bool])
        XCTAssertEqual(cache.keys, spec["keys"] as? [String])
    }

    /// A stream does not evict the transcript's parsed blocks (the old cache cleared itself
    /// every 256 streamed prefixes).
    func testStreamingKeepsHistoryParseCache() {
        let history = (0..<20).map { "History message \($0)\n\n- item\n" }
        for h in history { _ = OrbNativeMarkdownView.cachedBlocks(h) }
        let hitsBefore = OrbNativeMarkdownView.blockCache.hits
        var shown = ""
        for chunk in Self.chunks(Self.longReply(sections: 22)) { shown += chunk; _ = OrbNativeMarkdownView.streamingBlocks(shown) }
        for h in history { _ = OrbNativeMarkdownView.cachedBlocks(h) }
        XCTAssertEqual(OrbNativeMarkdownView.blockCache.hits - hitsBefore, history.count, "every history message is still cached")
    }

    /// The coalescer renders as the Lean model does (frames driven by hand).
    func testRendersMatchLean() throws {
        let spec = try XCTUnwrap(costFixture()["renders"] as? [String: Any])
        let live = OrbLiveText()
        live.frame = .seconds(3600)
        for ev in try XCTUnwrap(spec["events"] as? [[String: Any]]) {
            if let d = ev["delta"] as? String { live.append(d) } else { live.flush() }
        }
        XCTAssertEqual(live.renders, spec["renders"] as? Int)
        XCTAssertEqual(live.text, spec["shown"] as? String)
        XCTAssertEqual(String(live.received.dropFirst(live.text.count)), spec["pending"] as? String)
    }

    /// Only the streaming bubble re-renders during a stream: a screen that, like the
    /// conversation, reads `hasText` and hosts `OrbLiveReply` is evaluated once per state
    /// change, not per frame.
    func testOnlyTheBubbleRerendersWhileStreaming() async throws {
        let live = OrbLiveText()
        live.frame = .milliseconds(5)
        OrbRenderProbe.counts = [:]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = UIHostingController(rootView: ProbeScreen(live: live))
        window.makeKeyAndVisible()
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(40))
            window.rootViewController?.view.layoutIfNeeded()
        }
        try await settle()
        let frames = 30
        for i in 0..<frames {
            for _ in 0..<20 { live.append("w\(i) ") }
            try await settle()
        }
        let screen = OrbRenderProbe.counts["probeScreen"] ?? 0
        let bubble = OrbRenderProbe.counts["liveReply"] ?? 0
        XCTAssertGreaterThanOrEqual(bubble, frames / 2, "the bubble follows the stream")
        XCTAssertLessThanOrEqual(bubble, live.renders + 2, "at most one bubble render per frame")
        XCTAssertLessThanOrEqual(screen, 3, "the screen renders on hasText changes only (\(screen))")
    }

    static func chunks(_ doc: String) -> [Substring] {
        var out: [Substring] = []; var rest = Substring(doc)
        while !rest.isEmpty { out.append(rest.prefix(4)); rest = rest.dropFirst(4) }
        return out
    }

    /// The fixture server's STREAM_LONG answer (headings, lists, a table, code), synthetic.
    static func longReply(sections: Int) -> String {
        var body = "STREAM_LONG_OK: here is the full report."
        for k in 0..<sections {
            body += "\n\n## Section \(k)\n\nThe pass rewrote `Module\(k).lean`, kept every **invariant**, and re-ran the suite.\n\n"
                + "- step \(k).1 checked\n- step \(k).2 proved\n\n| Case | Before | After |\n| --- | ---: | ---: |\n| \(k) | \(k * 3) ms | \(k) ms |\n\n"
                + "```lean\ntheorem pass\(k) : \(k) + 0 = \(k) := by simp\n```"
        }
        return body + "\n\nSTREAM_LONG_END"
    }
}

/// Mirrors how `OrbConversation` uses the live text: the screen reads only `hasText`.
private struct ProbeScreen: View {
    let live: OrbLiveText
    var body: some View {
        let _ = OrbRenderProbe.hit("probeScreen")
        VStack {
            Text(live.hasText ? "Writing…" : "Working…")
            if live.hasText { OrbLiveReply(live: live, stored: []) { _ in } }
        }
    }
}
