import SwiftUI
import WebKit

/// Agent-written SVGs (Android `OrbSvg`, spec in shared/orb-spec/svg-images.json).
/// SVG can carry scripts and external references, so it is only ever drawn as an
/// `<img>` inside a page that allows no script, no network and no navigation:
/// image context never runs SVG script or fetches what it references, the page CSP
/// forbids every load except the inline image, JavaScript is off, and the web view
/// refuses any navigation after the page itself.
enum OrbSvg {
    static let limit = 5 * 1024 * 1024

    private static let comment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let root = try! NSRegularExpression(pattern: #"<svg\b[^>]*>"#, options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: #"(?:^|\s)(width|height|viewBox)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let length = try! NSRegularExpression(pattern: #"^\s*([0-9]*\.?[0-9]+)\s*(?:px)?\s*$"#)

    /// Width over height from the root element, to size the frame before it draws.
    static func aspectRatio(_ svg: String) -> Double? {
        let stripped = comment.stringByReplacingMatches(in: svg, range: NSRange(svg.startIndex..., in: svg), withTemplate: "") as NSString
        guard let tag = root.firstMatch(in: stripped as String, range: NSRange(location: 0, length: stripped.length)) else { return nil }
        let attrs = stripped.substring(with: tag.range) as NSString
        var values: [String: String] = [:]
        for m in attribute.matches(in: attrs as String, range: NSRange(location: 0, length: attrs.length)) {
            let value = m.range(at: 2).location != NSNotFound ? attrs.substring(with: m.range(at: 2)) : attrs.substring(with: m.range(at: 3))
            values[attrs.substring(with: m.range(at: 1))] = value
        }
        func number(_ s: String?) -> Double? {
            guard let s, let m = length.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
            return Double((s as NSString).substring(with: m.range(at: 1)))
        }
        if let w = number(values["width"]), let h = number(values["height"]), w > 0, h > 0 { return w / h }
        let box = (values["viewBox"] ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        if box.count == 4, box[2] > 0, box[3] > 0 { return box[2] / box[3] }
        return nil
    }

    /// The page that shows the SVG: an inline `<img>`, nothing else can load.
    static func html(_ svg: Data) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">\
        <style>html,body{margin:0;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style>\
        </head><body><img alt="" src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
        """
    }

    /// The SVG at `url`, or nil when it is too large or is not text.
    static func read(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              String(data: data, encoding: .utf8) != nil else { return nil }
        return data
    }
}

/// An SVG drawn in a script-free, network-free, non-navigating web view.
struct OrbSvgView: UIViewRepresentable {
    let svg: Data
    var interactive = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.isUserInteractionEnabled = interactive
        view.scrollView.isScrollEnabled = interactive
        view.allowsLinkPreview = false
        view.loadHTMLString(OrbSvg.html(svg), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded = false
        /// Only the page itself loads; links, frames and redirects are refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allow = !loaded && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank"
            if allow { loaded = true }
            decisionHandler(allow ? .allow : .cancel)
        }
    }
}
