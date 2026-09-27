import SwiftUI
import WebKit

struct OrbRichText: View {
    let source: String
    var onArtifact: (String) -> Void = { _ in }
    @State private var height: CGFloat = 60
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View { RichWeb(source: source, height: $height, onArtifact: onArtifact, textSize: textSize).frame(height: height) }
    private struct RichWeb: UIViewRepresentable {
        let source: String
        @Binding var height: CGFloat
        let onArtifact: (String) -> Void
        let textSize: DynamicTypeSize
        func makeCoordinator() -> Coordinator { Coordinator(height: $height, onArtifact: onArtifact) }
        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(context.coordinator, name: "orb")
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
            view.accessibilityIdentifier = "rich-response"
            return view
        }
        func updateUIView(_ view: WKWebView, context: Context) {
            context.coordinator.onArtifact = onArtifact
            guard context.coordinator.source != source || context.coordinator.textSize != textSize else { return }
            context.coordinator.source = source; context.coordinator.textSize = textSize
            guard let root = Bundle.main.url(forResource: "MathAssets", withExtension: nil),
                  let encoded = try? JSONEncoder().encode(source), let json = String(data: encoded, encoding: .utf8) else { return }
            let safe = json.replacingOccurrences(of: "<", with: "\\u003c")
            let category: UIContentSizeCategory = switch textSize {
            case .xSmall: .extraSmall
            case .small: .small
            case .medium: .medium
            case .large: .large
            case .xLarge: .extraLarge
            case .xxLarge: .extraExtraLarge
            case .xxxLarge: .extraExtraExtraLarge
            case .accessibility1: .accessibilityMedium
            case .accessibility2: .accessibilityLarge
            case .accessibility3: .accessibilityExtraLarge
            case .accessibility4: .accessibilityExtraExtraLarge
            case .accessibility5: .accessibilityExtraExtraExtraLarge
            @unknown default: .large
            }
            let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
            context.coordinator.updateScript = "orbUpdate(\(safe), \(size))"
            if context.coordinator.ready {
                view.evaluateJavaScript(context.coordinator.updateScript)
                return
            }
            guard !context.coordinator.loading else { return }
            context.coordinator.loading = true
            view.loadHTMLString("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' file:; style-src 'unsafe-inline' file:; font-src file:; img-src https:; connect-src 'none'; frame-src 'none'"><link rel="stylesheet" href="katex.min.css"><script src="markdown-it.min.js"></script><script src="katex.min.js"></script><script src="orb-renderer.js"></script><style>
            :root{color-scheme:dark}body{margin:0;color:#ddd;font: \(size)px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}p{margin:0 0 16px}h1,h2,h3{line-height:1.25;margin:22px 0 12px}h1{font-size:1.45em}h2{font-size:1.25em}h3{font-size:1.1em}a{color:#b8d5ef;text-decoration:underline}pre{overflow-x:auto;white-space:pre;padding:14px;margin:0}code{font:0.85em ui-monospace,monospace;background:#252525;border-radius:3px}pre code{background:none}blockquote{border-left:3px solid #555;margin:12px 0;padding-left:14px;color:#aaa}ul,ol{padding-left:24px}li>p{margin-bottom:6px}table{display:block;overflow-x:auto;border-collapse:collapse;margin:16px 0}th,td{border:1px solid #363636;padding:8px 12px;white-space:normal;min-width:75px;text-align:left}th{background:#202020}img{max-width:100%;height:auto;border-radius:12px}.math-block{overflow-x:auto;margin:12px 0}.code-block{background:#1d1d1d;border:1px solid #303030;border-radius:12px;margin:12px 0}.copy-code,.artifact{color:#bbb;background:none;border:0;padding:9px 14px;font:inherit}.copy-code{font-size:12px}hr{border:0;border-top:1px solid #333;margin:20px 0}.katex{font-size:1.08em}.katex-error{color:#d6a16a!important;white-space:pre-wrap}
            </style></head><body><main id="content"></main><script>
            const main=document.getElementById('content');
            window.orbUpdate=(source,size)=>{main.innerHTML=orbRender(source);document.body.style.fontSize=size+'px';report();};
            const report=()=>window.webkit.messageHandlers.orb.postMessage({height:Math.ceil(main.getBoundingClientRect().height)+1});
            new ResizeObserver(report).observe(main);document.fonts.ready.then(report);window.addEventListener('load',report);report();
            document.addEventListener('click',e=>{const copy=e.target.closest('.copy-code');if(copy){window.webkit.messageHandlers.orb.postMessage({copy:copy.parentElement.querySelector('code').textContent});return;}const artifact=e.target.closest('[data-artifact]');if(artifact){window.webkit.messageHandlers.orb.postMessage({artifact:artifact.dataset.artifact});return;}const a=e.target.closest('a');if(a){e.preventDefault();window.webkit.messageHandlers.orb.postMessage({link:a.getAttribute('href')});}});
            </script></body></html>
            """, baseURL: root)
        }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "orb")
            view.navigationDelegate = nil
            view.stopLoading()
        }
        final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
            var source: String?
            var textSize: DynamicTypeSize?
            var ready = false, loading = false
            var updateScript = ""
            var height: Binding<CGFloat>
            var onArtifact: (String) -> Void
            init(height: Binding<CGFloat>, onArtifact: @escaping (String) -> Void) { self.height = height; self.onArtifact = onArtifact }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                ready = true
                webView.evaluateJavaScript(updateScript)
            }
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
                ready = false
                webView.reload()
            }
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? [String: Any] else { return }
                if let value = body["height"] as? Double, value.isFinite { height.wrappedValue = max(24, value) }
                if let copy = body["copy"] as? String { UIPasteboard.general.string = copy }
                if let artifact = body["artifact"] as? String { onArtifact(artifact) }
                if let link = body["link"] as? String {
                    if link.hasPrefix("sandbox:") || link.hasPrefix("/mnt/data/") { onArtifact(link); return }
                    if let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme ?? ""), url.user == nil, url.password == nil { UIApplication.shared.open(url) }
                }
            }
            func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                decisionHandler(action.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}
