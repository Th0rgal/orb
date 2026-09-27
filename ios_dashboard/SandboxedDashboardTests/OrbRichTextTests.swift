import XCTest
import SwiftUI
import WebKit
@testable import sandboxed_sh

@MainActor
final class OrbRichTextTests: XCTestCase {
    private var window: UIWindow?
    private struct Content: View {
        let source: String
        var size: DynamicTypeSize = .large
        var onArtifact: (String) -> Void = { _ in }
        var body: some View { OrbRichText(source: source, onArtifact: onArtifact).environment(\.dynamicTypeSize, size) }
    }
    private var host: UIHostingController<Content>?
    private var openedArtifact: String?
    private func render(_ source: String) async throws -> WKWebView {
        let host = UIHostingController(rootView: Content(source: source, onArtifact: { self.openedArtifact = $0 }))
        self.host = host
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible(); self.window = window
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(find).first
        }
        for _ in 0..<60 {
            if let web = find(host.view), (try? await web.evaluateJavaScript("typeof orbRender === 'function' && !!document.querySelector('#content')?.childNodes.length")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Local Markdown/KaTeX assets did not load in WKWebView")
        throw NSError(domain: "OrbRichTextTests", code: 1)
    }
    override func tearDown() { window?.isHidden = true; window = nil; super.tearDown() }
    func testChatGPTMathInlineDisplayAndCurrency() async throws {
        let web = try await render(#"""
        # Annual return
        The formula is \(r=(V_f/V_i)^{1/n}-1\), also $x^2+y^2=z^2$.
        Prices are $15 and $20; this is currency.

        $$
        \begin{aligned} r &= \frac{V_f}{V_i} \\ s &= \sqrt{2} \end{aligned}
        $$

        \[
        \int_0^1 x^2\,dx=\frac{1}{3}
        \]
        """#)
        let result1 = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
        XCTAssertEqual(result1, 4)
        let result2 = try await web.evaluateJavaScript("document.querySelectorAll('.katex-error').length") as? Int
        XCTAssertEqual(result2, 0)
        let result3 = try await web.evaluateJavaScript("document.querySelectorAll('math').length") as? Int
        XCTAssertEqual(result3, 4)
        let result4 = try await web.evaluateJavaScript("document.body.textContent.includes('$15 and $20')") as? Bool
        XCTAssertEqual(result4, true)
        let result5 = try await web.evaluateJavaScript("document.querySelectorAll('.math-block').length") as? Int
        XCTAssertEqual(result5, 2)
    }
    func testMarkdownStructureEscapedTableCellsAndCode() async throws {
        let web = try await render(#"""
        ## Findings
        - Parent
          - **Nested** item
        1. First
        2. Second

        > A quoted result

        | Name | Value | Empty |
        | --- | --- | --- |
        | a\|b | `x` | |

        ```python
        price = "$not_math$"
        html = "<script>alert(1)</script>"
        ```

        [Source](https://example.com/reference)
        """#)
        let result6 = try await web.evaluateJavaScript("document.querySelectorAll('ul ul li').length") as? Int
        XCTAssertEqual(result6, 1)
        let result7 = try await web.evaluateJavaScript("document.querySelectorAll('tbody td').length") as? Int
        XCTAssertEqual(result7, 3)
        let result8 = try await web.evaluateJavaScript("document.querySelector('tbody td').textContent") as? String
        XCTAssertEqual(result8, "a|b")
        let result9 = try await web.evaluateJavaScript("document.querySelectorAll('pre code .katex').length") as? Int
        XCTAssertEqual(result9, 0)
        let result10 = try await web.evaluateJavaScript("document.querySelectorAll('.copy-code').length") as? Int
        XCTAssertEqual(result10, 1)
        let result11 = try await web.evaluateJavaScript("document.querySelector('a').getAttribute('href')") as? String
        XCTAssertEqual(result11, "https://example.com/reference")
    }
    func testUntrustedHTMLAndUnsafeLinksNeverExecute() async throws {
        let web = try await render(#"""
        <script>window.ORB_INJECTED=true</script>
        <img src=x onerror="window.ORB_INJECTED=true">
        [bad](javascript:alert(1))
        ![artifact](sandbox:/mnt/data/chart.png)
        $$\href{javascript:alert(1)}{unsafe}$$
        """#)
        let result12 = try await web.evaluateJavaScript("typeof window.ORB_INJECTED") as? String
        XCTAssertEqual(result12, "undefined")
        let result13 = try await web.evaluateJavaScript("document.querySelectorAll('#content script,#content [onerror],#content a[href^=\"javascript:\"]').length") as? Int
        XCTAssertEqual(result13, 0)
        let result14 = try await web.evaluateJavaScript("document.querySelectorAll('[data-artifact]').length") as? Int
        XCTAssertEqual(result14, 1)
    }
    func testIncompleteAndInvalidMathKeepsReadableContent() async throws {
        let web = try await render(#"""
        Before.

        $$\frac{$$

        After and an unfinished \(x+
        """#)
        let result15 = try await web.evaluateJavaScript("document.body.textContent.includes('After')") as? Bool
        XCTAssertEqual(result15, true)
        let result16 = try await web.evaluateJavaScript("document.querySelectorAll('.katex-error').length") as? Int
        XCTAssertEqual(result16, 1)
    }
    func testSmallScreenMathFontsOverflowAndCopy() async throws {
        let web = try await render(#"""
        # ChatGPT response
        The annual return is \(r = (V_f/V_i)^{1/n} - 1\).

        $$
        \sum_{i=1}^{100} \frac{\alpha_i + \beta_i + \gamma_i + \delta_i}{\sqrt{1+x_i^2}} = \int_0^{\infty} e^{-x^2}\,dx
        $$

        | Year | Euro | Dollar | Explanation |
        | --- | --- | --- | --- |
        | 1999 | 243 € | 287 $ | Initial investment |

        ```swift
        let formula = "$x$"
        ```

        ![Generated chart](sandbox:/mnt/data/chart.png)
        """#)
        _ = try await web.callAsyncJavaScript("await document.fonts.ready; return true", arguments: [:], in: nil, contentWorld: .page)
        let fonts = try await web.evaluateJavaScript("document.fonts.check('16px KaTeX_Main')") as? Bool
        XCTAssertEqual(fonts, true)
        let contained = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= window.innerWidth + 1") as? Bool
        XCTAssertEqual(contained, true, "Wide math and tables must scroll inside the message")
        _ = try await web.evaluateJavaScript("document.querySelector('.copy-code').click()")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(UIPasteboard.general.string, "let formula = \"$x$\"\n")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-artifact]').click()")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(openedArtifact, "sandbox:/mnt/data/chart.png")
    }
    func testStreamingUpdatesReuseWebViewAndShrinkHeight() async throws {
        let web = try await render("First partial \\(x+")
        _ = try await web.evaluateJavaScript("window.orbTestIdentity = 42")
        host?.rootView = Content(source: String(repeating: "Paragraph with **content**.\n\n", count: 25))
        try await Task.sleep(for: .milliseconds(350))
        let longHeight = try await web.evaluateJavaScript("document.querySelector('#content').getBoundingClientRect().height") as! Double
        host?.rootView = Content(source: #"Final \(x+1\)."#)
        try await Task.sleep(for: .milliseconds(350))
        let identity = try await web.evaluateJavaScript("window.orbTestIdentity") as? Int
        XCTAssertEqual(identity, 42, "Streaming must update the document without reloading WebKit")
        let shortHeight = try await web.evaluateJavaScript("document.querySelector('#content').getBoundingClientRect().height") as! Double
        XCTAssertLessThan(shortHeight, longHeight)
        let formulas = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
        XCTAssertEqual(formulas, 1)
    }

    func testLongConversationAndAccessibilityTextSize() async throws {
        let web = try await render(String(repeating: "## Section\n\nA paragraph with \\(x^2\\).\n\n", count: 120))
        let count = try await web.evaluateJavaScript("document.querySelectorAll('h2').length") as? Int
        XCTAssertEqual(count, 120)
        let normalSize = try await web.evaluateJavaScript("parseFloat(getComputedStyle(document.body).fontSize)") as! Double
        host?.rootView = Content(source: #"Large text with \(x^2\)."#, size: .accessibility3)
        try await Task.sleep(for: .milliseconds(350))
        let largeSize = try await web.evaluateJavaScript("parseFloat(getComputedStyle(document.body).fontSize)") as! Double
        XCTAssertGreaterThan(largeSize, normalSize * 1.5)
        let formulas = try await web.evaluateJavaScript("document.querySelectorAll('math').length") as? Int
        XCTAssertEqual(formulas, 1, "MathML must remain available to accessibility at larger sizes")
    }

}
