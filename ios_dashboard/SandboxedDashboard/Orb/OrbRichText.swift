import SwiftUI
import WebKit

@MainActor
private enum OrbRichHeightCache {
    private static var heights: [Int: CGFloat] = [:]
    private static func key(_ source: String, _ size: DynamicTypeSize) -> Int {
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(size)
        return hasher.finalize()
    }
    static func get(_ source: String, _ size: DynamicTypeSize) -> CGFloat {
        if let cached = heights[key(source, size)] { return cached }
        let lines = max(1, source.split(separator: "\n", omittingEmptySubsequences: false).count + (source.count / 68))
        return min(380, max(24, CGFloat(lines) * 22))
    }
    static func set(_ value: CGFloat, for source: String, _ size: DynamicTypeSize) {
        if heights.count > 256 { heights.removeAll(keepingCapacity: true) }
        heights[key(source, size)] = value
    }
}

struct OrbRichText: View {
    let source: String
    var onArtifact: (String) -> Void = { _ in }
    @State private var height: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        RichWeb(source: source, height: $height, onArtifact: onArtifact, textSize: textSize)
            .frame(height: max(24, height))
            .onAppear { height = OrbRichHeightCache.get(source, textSize) }
    }
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
            view.scrollView.contentInsetAdjustmentBehavior = .never
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
            :root{color-scheme:dark}#content{display:flow-root}body{margin:0;color:#e3e3e3;font: \(size)px/1.52 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}p{margin:0 0 12px}p:last-child,ul:last-child,ol:last-child,blockquote:last-child,pre:last-child,.code-block:last-child{margin-bottom:0}h1,h2,h3{line-height:1.25;margin:18px 0 8px;color:#f2f2f2}h1:first-child,h2:first-child,h3:first-child{margin-top:0}h1{font-size:1.35em}h2{font-size:1.18em}h3{font-size:1.05em}a{color:#b8d5ef;text-decoration:underline}pre{overflow-x:auto;white-space:pre;padding:12px 14px;margin:0}code{font:0.85em ui-monospace,SFMono-Regular,monospace;background:rgba(255,255,255,0.08);padding:1px 5px;border-radius:4px}pre code{background:none;padding:0}blockquote{border-left:2px solid rgba(255,255,255,0.22);margin:10px 0;padding-left:12px;color:#a8a8a8}ul,ol{padding-left:22px;margin:0 0 12px}li>p{margin-bottom:4px}table{display:block;overflow-x:auto;border-collapse:collapse;margin:12px 0;font-size:0.92em}th,td{border:1px solid rgba(255,255,255,0.12);padding:7px 10px;white-space:normal;min-width:70px;text-align:left}th{background:rgba(255,255,255,0.05)}img{max-width:100%;height:auto;border-radius:10px}.math-block{overflow-x:auto;margin:10px 0}.code-block{background:#161616;border:1px solid rgba(255,255,255,0.09);border-radius:10px;margin:10px 0;overflow:hidden}.copy-code,.artifact{color:#a0a0a0;background:none;border:0;padding:7px 12px;font:inherit}.copy-code{font-size:11.5px;border-bottom:1px solid rgba(255,255,255,0.06);width:100%;text-align:right;display:block}.copy-code.copied{color:#73c991}hr{border:0;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0}.katex{font-size:1.05em}.katex-error{color:#d6a16a!important;white-space:pre-wrap}
            </style></head><body><main id="content"></main><script>
            const main=document.getElementById('content');
            window.orbUpdate=(source,size)=>{main.innerHTML=orbRender(source);document.body.style.fontSize=size+'px';report();};
            const report=()=>window.webkit.messageHandlers.orb.postMessage({height:Math.ceil(main.getBoundingClientRect().height)+1});
            new ResizeObserver(report).observe(main);document.fonts.ready.then(report);window.addEventListener('load',report);report();
            document.addEventListener('click',e=>{const copy=e.target.closest('.copy-code');if(copy){const code=copy.parentElement.querySelector('code');if(code){window.webkit.messageHandlers.orb.postMessage({copy:code.textContent});const prev=copy.textContent;copy.textContent='Copied ✓';copy.classList.add('copied');setTimeout(()=>{copy.textContent=prev;copy.classList.remove('copied');},1400);}return;}const artifact=e.target.closest('[data-artifact]');if(artifact){window.webkit.messageHandlers.orb.postMessage({artifact:artifact.dataset.artifact});return;}const a=e.target.closest('a');if(a){e.preventDefault();window.webkit.messageHandlers.orb.postMessage({link:a.getAttribute('href')});}});
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
                if let value = body["height"] as? Double, value.isFinite {
                    let resolved = max(24, CGFloat(value))
                    height.wrappedValue = resolved
                    if let source, let textSize { OrbRichHeightCache.set(resolved, for: source, textSize) }
                }
                if let copy = body["copy"] as? String {
                    UIPasteboard.general.string = copy
                    OrbHaptics.light()
                }
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
