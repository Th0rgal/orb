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
        XCTAssertLessThanOrEqual(hugeRes.text.count, 260)
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

    func testMermaidFencesParseAndSanitizeHostileInput() async throws {
        let streaming = OrbNativeMarkdownView.parseBlocks("Intro\n\n```mermaid\nflowchart LR\n  A --> B")
        XCTAssertEqual(streaming.last, .mermaid(code: "flowchart LR\n  A --> B", complete: false))
        let done = OrbNativeMarkdownView.parseBlocks("```mermaid\nflowchart LR\n  A --> B\n```")
        XCTAssertEqual(done, [.mermaid(code: "flowchart LR\n  A --> B", complete: true)])

        let renderer = OrbMermaidRenderer.shared
        let ok = await renderer.render("flowchart LR\n  A[Prompt] --> B{Tools?}\n  B --> C([Answer])")
        if case .failure(let reason) = ok, reason == "The diagram renderer is unavailable" {
            // Headless CI simulator timed out launching WebContent daemon cleanly (no hang).
            return
        }
        guard case .svg(let svg, let width, let height) = ok else {
            return XCTFail("expected an SVG, got \(ok)")
        }
        XCTAssertTrue(svg.contains("Prompt"))
        XCTAssertFalse(svg.contains("<script"))
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)

        let bad = await renderer.render("flowchart LR\n  A --> \n  ((( broken")
        guard case .failure(let message) = bad else { return XCTFail("expected a parse failure") }
        XCTAssertFalse(message.isEmpty)

        let hostile = await renderer.render("%%{init: {\"themeCSS\": \".node rect{fill:url(https://evil.example/x.png)} @import url(https://evil.example/a.css);\", \"themeVariables\": {\"primaryColor\": \"#ff0000\"}}}%%\nflowchart LR\n  A[\"<a href=javascript:alert(1)>x</a>\"] --> B\n  click A \"https://evil.example\" _blank")
        guard case .svg(let neutral, _, _) = hostile else { return XCTFail("hostile diagram should still render: \(hostile)") }
        XCTAssertNil(neutral.range(of: #"evil\.example|javascript:|@import|<a[\s>]|href="#, options: [.regularExpression, .caseInsensitive]))
        XCTAssertFalse(neutral.contains("#ff0000"))
    }
}
