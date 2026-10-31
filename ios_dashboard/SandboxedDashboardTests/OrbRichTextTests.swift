import XCTest
import SwiftUI
@testable import sandboxed_sh

@MainActor
final class OrbRichTextTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func mountView<V: View>(_ root: V) -> UIView {
        let host = UIHostingController(rootView: root)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        win.rootViewController = host
        win.makeKeyAndVisible()
        self.window = win
        host.view.layoutIfNeeded()
        return host.view
    }

    private func countWebViews(in root: UIView) -> Int {
        let webClass: AnyClass? = NSClassFromString("WKWebView")
        func walk(_ view: UIView) -> Int {
            let selfHit = (webClass != nil && view.isKind(of: webClass!)) ? 1 : 0
            return selfHit + view.subviews.reduce(0) { $0 + walk($1) }
        }
        return walk(root)
    }

    func testRendererRoutingMatchesSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/rich-text-routing.json")
        for c in try XCTUnwrap(spec["cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let source = try XCTUnwrap(c["source"] as? String)
            XCTAssertEqual(OrbNativeMarkdownView.requiresWebRenderer(source), c["web"] as? Bool, name)
            if let expectedRich = c["rich"] as? Bool {
                XCTAssertEqual(OrbMath.containsMathOrMedia(source), expectedRich, "\(name) (rich)")
            }
        }
    }

    func testChatGPTMathInlineDisplayAndCurrency() {
        let source = #"""
        # Annual return
        The formula is \(r=(V_f/V_i)^{1/n}-1\), also $x^2+y^2=z^2$.
        Prices are $15 and $20; VM cost is $0.072/hr and cap is $50.

        $$
        \begin{aligned} r &= \frac{V_f}{V_i} \\ s &= \sqrt{2} \end{aligned}
        $$

        \[
        \int_0^1 x^2\,dx=\frac{1}{3}
        \]
        """#

        let blocks = OrbNativeMarkdownView.parseBlocks(source)
        let mathBlocks = blocks.compactMap { block -> (String, Bool)? in
            if case .math(let latex, let complete) = block { return (latex, complete) }
            return nil
        }
        XCTAssertEqual(mathBlocks.count, 2)
        XCTAssertTrue(mathBlocks.allSatisfy(\.1))

        let aligned = OrbMath.formatLatex(mathBlocks[0].0, complete: true)
        XCTAssertTrue(aligned.valid)
        XCTAssertTrue(aligned.text.contains("√2"))

        let integral = OrbMath.formatLatex(mathBlocks[1].0, complete: true)
        XCTAssertTrue(integral.valid)
        XCTAssertTrue(integral.text.contains("∫"))
        XCTAssertTrue(integral.text.contains("1/3"))

        let paragraphBlocks = blocks.compactMap { block -> String? in
            if case .paragraph(let p) = block { return p }
            return nil
        }
        let joinedPlain = paragraphBlocks
            .map { String(OrbNativeMarkdownView.inlineAttributed($0).characters) }
            .joined(separator: "\n")
        XCTAssertTrue(joinedPlain.contains("$15 and $20"))
        XCTAssertTrue(joinedPlain.contains("$0.072/hr and cap is $50"))
        XCTAssertTrue(joinedPlain.contains("x²+y²=z²"))

        let mounted = mountView(OrbRichText(source: source))
        XCTAssertEqual(countWebViews(in: mounted), 0, "OrbRichText must never mount a WKWebView for math")
    }

    func testMarkdownStructureEscapedTableCellsAndCode() {
        let source = #"""
        ## Findings
        - Parent
        1. First
        2. Second

        > A quoted result

        | Name | Value | Empty |
        | --- | ---: | --- |
        | a\|b | `x` | |

        ```python
        price = "$not_math$"
        html = "<script>alert(1)</script>"
        ```

        [Source](https://example.com/reference)
        """#

        let blocks = OrbNativeMarkdownView.parseBlocks(source)
        guard let table = blocks.compactMap({ block -> ([String], [[String]], [Bool])? in
            if case .table(let h, let r, let align) = block { return (h, r, align) }
            return nil
        }).first else {
            return XCTFail("Expected parsed Markdown table")
        }
        XCTAssertEqual(table.0, ["Name", "Value", "Empty"])
        XCTAssertEqual(table.1.first, ["a|b", "`x`", ""])
        XCTAssertEqual(table.2, [false, true, false])

        guard let code = blocks.compactMap({ block -> (String, String)? in
            if case .code(let lang, let body) = block { return (lang, body) }
            return nil
        }).first else {
            return XCTFail("Expected fenced code block")
        }
        XCTAssertEqual(code.0, "python")
        XCTAssertTrue(code.1.contains("$not_math$"))
        XCTAssertTrue(code.1.contains("<script>alert(1)</script>"))

        let linkAttr = OrbNativeMarkdownView.inlineAttributed("[Source](https://example.com/reference)")
        let links = linkAttr.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/reference")!])
    }

    func testUntrustedHTMLAndUnsafeLinksNeverExecute() {
        let unsafeLink = OrbNativeMarkdownView.inlineAttributed("[bad](javascript:alert(1)) and [data](data:text/html,<script>x</script>)")
        XCTAssertTrue(unsafeLink.runs.compactMap(\.link).isEmpty, "javascript: and data: links must never attach clickable URLs")

        let hrefMath = OrbMath.formatLatex(#"\href{javascript:alert(1)}{unsafe}"#, complete: true)
        XCTAssertEqual(hrefMath.text, "unsafe")

        let artifactLink = OrbNativeMarkdownView.inlineAttributed("See [OrbCore.swift](file:///Users/thomas/OrbCore.swift)")
        let artifactURL = artifactLink.runs.compactMap(\.link).first
        XCTAssertEqual(artifactURL?.scheme, "orb-artifact")

        let imgBlocks = OrbNativeMarkdownView.parseBlocks("![Generated chart](sandbox:/mnt/data/chart.png)")
        XCTAssertEqual(imgBlocks, [.image(alt: "Generated chart", url: "sandbox:/mnt/data/chart.png")])

        let mounted = mountView(OrbRichText(source: """
        <script>window.ORB_INJECTED=true</script>
        <img src=x onerror="window.ORB_INJECTED=true">
        [bad](javascript:alert(1))
        ![artifact](sandbox:/mnt/data/chart.png)
        $$\\href{javascript:alert(1)}{unsafe}$$
        """))
        XCTAssertEqual(countWebViews(in: mounted), 0)
    }

    func testIncompleteStreamingAndBoundedMathNeverTraps() {
        let incompleteFrac = OrbMath.formatLatex(#"\frac{"#, complete: false)
        XCTAssertFalse(incompleteFrac.valid)
        XCTAssertFalse(incompleteFrac.text.isEmpty)

        let blocks = OrbNativeMarkdownView.parseBlocks("Before.\n\n$$\\frac{$$\n\nAfter and an unfinished \\(x+")
        XCTAssertEqual(blocks.count, 3)
        let afterAttr = OrbNativeMarkdownView.inlineAttributed("After and an unfinished \\(x+", streaming: true)
        XCTAssertTrue(String(afterAttr.characters).contains("After"))

        let deep = String(repeating: "{", count: 40) + "x" + String(repeating: "}", count: 40)
        let deepRes = OrbMath.formatLatex(deep, complete: true)
        XCTAssertFalse(deepRes.valid)
        XCTAssertFalse(deepRes.text.isEmpty)

        let huge = String(repeating: "x + ", count: 3000)
        let hugeRes = OrbMath.formatLatex(huge, complete: true)
        XCTAssertFalse(hugeRes.valid)
        XCTAssertLessThanOrEqual(hugeRes.text.count, OrbMath.maxSpanChars)
    }

    func testBoostCiTranscriptReplaysNativelyWithUniqueTurnKeysAndZeroWebViews() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/orb-spec/fixtures/transcripts/boost_ci.json"))
        let fixture = try JSONDecoder().decode(OrbJSON.self, from: data)
        let events: [StoredEvent] = fixture["events"].items.map { row in
            var meta: [String: AnyCodable] = [:]
            if case .object(let dict) = row["metadata"] {
                for (k, v) in dict {
                    switch v {
                    case .bool(let b): meta[k] = AnyCodable(b)
                    case .number(let n): meta[k] = AnyCodable(n)
                    case .string(let s): meta[k] = AnyCodable(s)
                    default: break
                    }
                }
            }
            func optText(_ v: OrbJSON) -> String? {
                if case .string(let s) = v { return s }
                return nil
            }
            return StoredEvent(
                id: Int64(row["id"].doubleValue ?? 0),
                missionId: row["mission_id"].text,
                sequence: Int64(row["sequence"].doubleValue ?? 0),
                eventType: row["event_type"].text,
                timestamp: row["timestamp"].text,
                eventId: optText(row["event_id"]),
                toolCallId: optText(row["tool_call_id"]),
                toolName: optText(row["tool_name"]),
                content: row["content"].text,
                metadata: meta
            )
        }
        XCTAssertEqual(events.count, 481)

        let turns = OrbTranscriptModel.computeHistory(
            isCloud: false,
            turns: [],
            mission: fixture["mission"],
            events: events,
            optimisticPrompt: nil
        )
        XCTAssertGreaterThanOrEqual(turns.count, 10)
        let ids = turns.map(\.0)
        XCTAssertEqual(Set(ids).count, ids.count, "Every displayed turn ID in boost_ci must be unique")

        var assistantTexts: [String] = []
        for (_, role, content) in turns {
            let parsed = OrbNativeMarkdownView.parseBlocks(content)
            XCTAssertTrue(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !parsed.isEmpty)
            for block in parsed {
                if case .paragraph(let p) = block {
                    _ = OrbNativeMarkdownView.inlineAttributed(p)
                }
            }
            if role == "assistant" {
                assistantTexts.append(content)
            }
        }
        XCTAssertFalse(assistantTexts.isEmpty)

        struct TranscriptMount: View {
            let messages: [String]
            var body: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                            OrbRichText(source: msg)
                        }
                    }
                }
            }
        }
        let mounted = mountView(TranscriptMount(messages: assistantTexts))
        XCTAssertEqual(countWebViews(in: mounted), 0, "Replaying boost_ci must mount zero WKWebViews")

        for name in ["cloud-rich.md", "cursor-live.md", "grok-live.md"] {
            let corpusURL = root.appendingPathComponent("ios_dashboard/TestsSupport/fixtures/\(name)")
            let md = try String(contentsOf: corpusURL, encoding: .utf8)
            let blocks = OrbNativeMarkdownView.parseBlocks(md)
            XCTAssertFalse(blocks.isEmpty, name)
            XCTAssertTrue(OrbMath.containsMathOrMedia(md), name)
            let corpusView = mountView(OrbRichText(source: md))
            XCTAssertEqual(countWebViews(in: corpusView), 0, name)
        }
    }

    func testMermaidFenceBlockParsing() {
        let streaming = OrbNativeMarkdownView.parseBlocks("Intro\n\n```mermaid\nflowchart LR\n  A --> B")
        XCTAssertEqual(streaming.last, .mermaid(code: "flowchart LR\n  A --> B", complete: false))
        let done = OrbNativeMarkdownView.parseBlocks("```mermaid\nflowchart LR\n  A --> B\n```")
        XCTAssertEqual(done, [.mermaid(code: "flowchart LR\n  A --> B", complete: true)])
    }

    func testLoosePipeTablesCRLFPreservesRightAlignment() {
        let crlf = "a | b | c\r\nx | 1 | 2\r\nThat is all."
        let expected = "| a | b | c |\n| --- | ---: | ---: |\n| x | 1 | 2 |\n\nThat is all."
        XCTAssertEqual(OrbPipeTables.normalize(crlf), expected)
    }

    func testTranscriptGatesAndRandomizedFuzzInvariants() throws {
        let gatesURL = repoRoot.appendingPathComponent("shared/orb-spec/fixtures/transcript-gates.json")
        let gatesDoc = try OrbJSON.parse(Data(contentsOf: gatesURL))
        let cases = gatesDoc["cases"].items
        XCTAssertGreaterThanOrEqual(cases.count, 60)

        for (idx, item) in cases.enumerated() {
            switch item["op"].text {
            case "allocTurnKeys":
                let cands = item["candidates"].items.map {
                    OrbTranscriptGates.CandidateKey(
                        tag: Int($0["tag"].doubleValue ?? 0),
                        item: Int($0["item"].doubleValue ?? 0)
                    )
                }
                let expected = item["expected"].items.map {
                    OrbTranscriptGates.TurnKey(
                        tag: Int($0["tag"].doubleValue ?? 0),
                        item: Int($0["item"].doubleValue ?? 0),
                        gen: Int($0["gen"].doubleValue ?? 0)
                    )
                }
                let got = OrbTranscriptGates.allocTurnKeys(cands)
                XCTAssertEqual(got, expected, "allocTurnKeys case \(idx)")
            case "latexSpanAdmitted":
                let got = OrbTranscriptGates.latexSpanAdmitted(
                    len: Int(item["len"].doubleValue ?? 0),
                    prevBlocked: item["prevBlocked"].flag,
                    nextDigit: item["nextDigit"].flag,
                    leadSpace: item["leadSpace"].flag,
                    trailSpace: item["trailSpace"].flag,
                    hasNewline: item["hasNewline"].flag,
                    firstDigit: item["firstDigit"].flag,
                    internalSpace: item["internalSpace"].flag,
                    hasMathOp: item["hasMathOp"].flag
                )
                XCTAssertEqual(got, item["expected"].flag, item["name"].text)
            case "windowBudget":
                let total = Int(item["total"].doubleValue ?? 0)
                let base = Int(item["baseLimit"].doubleValue ?? 24)
                let steps = Int(item["expandedSteps"].doubleValue ?? 0)
                let step = Int(item["stepSize"].doubleValue ?? 24)
                XCTAssertEqual(OrbTranscriptGates.visibleTurnCount(total: total, baseLimit: base, expandedSteps: steps, stepSize: step), Int(item["expectedVisible"].doubleValue ?? 0))
                XCTAssertEqual(OrbTranscriptGates.hiddenTurnCount(total: total, baseLimit: base, expandedSteps: steps, stepSize: step), Int(item["expectedHidden"].doubleValue ?? 0))
            case "admitMount":
                let res = OrbTranscriptGates.admitMount(active: Int(item["active"].doubleValue ?? 0), cap: Int(item["cap"].doubleValue ?? 0))
                XCTAssertEqual(res.admitted, item["expectedAdmitted"].flag)
                XCTAssertEqual(res.nextActive, Int(item["expectedNextActive"].doubleValue ?? 0))
            default:
                XCTFail("Unknown op at \(idx): \(item["op"].text)")
            }
        }

        // Cloud turns with empty / duplicate keys must still yield strictly unique non-empty row IDs.
        let cloudDupes: [OrbJSON] = [
            .object(["key": .string(""), "prompt": .string("p1"), "result": .string("r1")]),
            .object(["key": .string(""), "prompt": .string("p2"), "result": .string("r2")]),
            .object(["key": .string("k1"), "prompt": .string("p3"), "result": .string("r3")]),
            .object(["key": .string("k1"), "prompt": .string("p4"), "result": .string("r4")])
        ]
        let cloudRows = OrbTranscriptModel.computeHistory(
            isCloud: true,
            turns: cloudDupes,
            mission: .object([:]),
            events: [],
            optimisticPrompt: "pending follow-up"
        )
        let cloudIds = cloudRows.map(\.0)
        XCTAssertEqual(Set(cloudIds).count, cloudIds.count)
        XCTAssertTrue(cloudIds.allSatisfy { !$0.isEmpty })

        // 500-seed deterministic fuzzing across transcript history + native Markdown + math.
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextInt(_ bound: Int) -> Int {
            rng ^= rng >> 12
            rng ^= rng << 25
            rng ^= rng >> 27
            let mixed = rng &* 0x2545_F491_4F6C_DD1D
            return Int((mixed >> 1) % UInt64(bound))
        }
        let payloads = [
            "Plain update with 🔹 surrogate pair",
            "Currency $15 and $20 stays prose while $x^2 + y_1$ renders math",
            "$$\n\\frac{\\alpha + 1}{\\sqrt{2}\n",
            "colA | colB | colC\r\n🔹 | 12 | 3.5%\r\nDone.",
            "<fork_context>\n<turn role=\"user\">Prior prompt</turn>\n<turn role=\"assistant\">Prior answer</turn>\n</fork_context>\nFollow-up question",
            "![chart](https://example.com/chart.png) and [artifact](file:///workspace/out.txt)"
        ]

        for seed in 0..<500 {
            let count = 1 + nextInt(14)
            var events: [StoredEvent] = []
            for i in 0..<count {
                let seq = nextInt(4) == 0 ? 5 : Int64(i + 1)
                let evType = nextInt(3) == 0 ? "user_message" : (nextInt(2) == 0 ? "assistant_message_canonical" : "assistant_message")
                events.append(
                    StoredEvent(
                        id: seq,
                        missionId: "m-fuzz",
                        sequence: seq,
                        eventType: evType,
                        timestamp: "2026-10-31T00:00:00Z",
                        eventId: nil,
                        toolCallId: nil,
                        toolName: nil,
                        content: payloads[nextInt(payloads.count)],
                        metadata: [
                            "bubble_id": AnyCodable(nextInt(2) == 0 ? "antigravity:b1" : "text_delta_latest"),
                            "revision": AnyCodable(nextInt(4))
                        ]
                    )
                )
            }
            let opt = nextInt(2) == 0 ? "optimistic \(seed)" : nil
            let rows = OrbTranscriptModel.computeHistory(
                isCloud: false,
                turns: [],
                mission: .object(["history": .array([])]),
                events: events,
                optimisticPrompt: opt
            )
            let rowIds = rows.map(\.0)
            XCTAssertEqual(Set(rowIds).count, rowIds.count, "Duplicate row ID at seed \(seed)")
            for (_, _, text) in rows {
                let blocks = OrbNativeMarkdownView.parseBlocks(text)
                for block in blocks {
                    if case .paragraph(let p) = block {
                        _ = OrbNativeMarkdownView.inlineAttributed(p)
                    }
                }
            }
        }
    }
}
