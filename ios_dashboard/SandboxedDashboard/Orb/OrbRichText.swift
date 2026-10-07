import SwiftUI
import WebKit

@MainActor
enum OrbRichHeightCache {
    private static var heights: [Int: CGFloat] = [:]
    private static func key(_ source: String, _ size: DynamicTypeSize) -> Int {
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(size)
        return hasher.finalize()
    }
    static func get(_ source: String, _ size: DynamicTypeSize) -> CGFloat {
        if let cached = heights[key(source, size)] { return cached }
        // Heuristic height estimate accounting for paragraphs, code blocks, and headings
        var totalHeight: CGFloat = 0
        var inCodeBlock = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                totalHeight += 18
                continue
            }
            if inCodeBlock {
                totalHeight += 19
            } else if line.hasPrefix("#") {
                totalHeight += 32
            } else if line.isEmpty {
                totalHeight += 10
            } else {
                let wraps = max(1, (line.count + 54) / 55)
                totalHeight += CGFloat(wraps) * 22
            }
        }
        return min(640, max(24, totalHeight))
    }
    static func set(_ value: CGFloat, for source: String, _ size: DynamicTypeSize) {
        if heights.count > 512 { heights.removeAll(keepingCapacity: true) }
        heights[key(source, size)] = value
    }
}

/// Shared WKWebView pool that pre-loads `MathAssets` (`markdown-it` + `KaTeX`) so message rows
/// never pay cold HTML/JS parse latency when scrolling into view.
@MainActor
final class OrbWebViewPool {
    static let shared = OrbWebViewPool()
    private var idle: [WKWebView] = []
    private let maxIdle = 6

    func warmUp(count: Int = 2) {
        while idle.count < min(count, maxIdle) {
            idle.append(createWebView())
        }
    }

    func acquire() -> WKWebView {
        if let view = idle.popLast() {
            return view
        }
        return createWebView()
    }

    func release(_ view: WKWebView) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "orb")
        view.navigationDelegate = nil
        guard idle.count < maxIdle else {
            view.stopLoading()
            return
        }
        view.evaluateJavaScript("if(window.orbClear)window.orbClear();")
        idle.append(view)
    }

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 361, height: 48), configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.accessibilityIdentifier = "rich-response"
        if let root = Bundle.main.url(forResource: "MathAssets", withExtension: nil) {
            view.loadHTMLString(Self.htmlTemplate(fontSize: 17), baseURL: root)
        }
        return view
    }

    static func htmlTemplate(fontSize size: CGFloat) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' file:; style-src 'unsafe-inline' file:; font-src file:; img-src https:; connect-src 'none'; frame-src 'none'"><link rel="stylesheet" href="katex.min.css"><script src="markdown-it.min.js"></script><script src="katex.min.js"></script><script src="orb-renderer.js"></script><style>
        :root{color-scheme:dark}#content{display:flow-root}body{margin:0;color:#e3e3e3;font: \(size)px/1.52 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}p{margin:0 0 12px}p:last-child,ul:last-child,ol:last-child,blockquote:last-child,pre:last-child,.code-block:last-child{margin-bottom:0}h1,h2,h3{line-height:1.25;margin:18px 0 8px;color:#f2f2f2}h1:first-child,h2:first-child,h3:first-child{margin-top:0}h1{font-size:1.35em}h2{font-size:1.18em}h3{font-size:1.05em}a{color:#b8d5ef;text-decoration:underline}a.file-link{display:inline-flex;align-items:center;gap:4px;font:0.86em ui-monospace,SFMono-Regular,monospace;color:#d8e6f5;background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.12);padding:1px 7px;border-radius:6px;text-decoration:none}pre{overflow-x:auto;white-space:pre;padding:12px 14px;margin:0}code{font:0.85em ui-monospace,SFMono-Regular,monospace;background:rgba(255,255,255,0.08);padding:1px 5px;border-radius:4px}pre code{background:none;padding:0}blockquote{border-left:2px solid rgba(255,255,255,0.22);margin:10px 0;padding-left:12px;color:#a8a8a8}ul,ol{padding-left:22px;margin:0 0 12px}li>p{margin-bottom:4px}table{display:block;overflow-x:auto;border-collapse:collapse;margin:12px 0;font-size:0.92em}th,td{border:1px solid rgba(255,255,255,0.12);padding:7px 10px;white-space:normal;min-width:70px;text-align:left}th{background:rgba(255,255,255,0.05)}img{max-width:100%;height:auto;border-radius:10px}.math-block{overflow-x:auto;margin:10px 0}.code-block{background:#161616;border:1px solid rgba(255,255,255,0.09);border-radius:10px;margin:10px 0;overflow:hidden}.copy-code,.artifact{color:#a0a0a0;background:none;border:0;padding:7px 12px;font:inherit}.copy-code{font-size:11.5px;border-bottom:1px solid rgba(255,255,255,0.06);width:100%;text-align:right;display:block}.copy-code.copied{color:#73c991}hr{border:0;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0}.katex{font-size:1.05em}.katex-error{color:#d6a16a!important;white-space:pre-wrap}
        </style></head><body><main id="content"></main><script>
        const main=document.getElementById('content');
        const report=()=>{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.orb){const h=Math.ceil(main.getBoundingClientRect().height);if(h>0)window.webkit.messageHandlers.orb.postMessage({height:h+1});}};
        window.orbClear=()=>{main.innerHTML='';};
        window.orbUpdate=(source,size)=>{main.innerHTML=orbRender(source);document.body.style.fontSize=size+'px';report();requestAnimationFrame(report);setTimeout(report,40);};
        new ResizeObserver(report).observe(main);document.fonts.ready.then(report);window.addEventListener('load',report);
        document.addEventListener('click',e=>{const copy=e.target.closest('.copy-code');if(copy){const code=copy.parentElement.querySelector('code');if(code){window.webkit.messageHandlers.orb.postMessage({copy:code.textContent});const prev=copy.textContent;copy.textContent='Copied ✓';copy.classList.add('copied');setTimeout(()=>{copy.textContent=prev;copy.classList.remove('copied');},1400);}return;}const artifact=e.target.closest('[data-artifact]');if(artifact){window.webkit.messageHandlers.orb.postMessage({artifact:artifact.dataset.artifact});return;}const a=e.target.closest('a');if(a){e.preventDefault();window.webkit.messageHandlers.orb.postMessage({link:a.getAttribute('href')});}});
        </script></body></html>
        """
    }
}

/// Pure-SwiftUI block Markdown renderer (Option A candidate) for zero-WebKit-process rendering
/// of standard prose, headings, lists, blockquotes, and copyable code fences.
struct OrbNativeMarkdownView: View {
    let source: String
    var onArtifact: (String) -> Void = { _ in }
    @State private var copiedBlockIndex: Int?

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String, code: String)
        case list(ordered: Bool, items: [String])
        case quote(String)
        case divider
    }

    static func requiresWebRenderer(_ source: String) -> Bool {
        if source.contains("$$") || source.contains("\\(") || source.contains("\\[") { return true }
        if source.contains("<script") || source.contains("<img") || source.contains("![") { return true }
        // Markdown tables (`| col | col |`) or inline `$math$`
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 { return true }
        }
        if source.contains("$") { return true }
        return false
    }

    static func parseBlocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                idx += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                idx += 1
                var codeLines: [String] = []
                while idx < lines.count && !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[idx])
                    idx += 1
                }
                if idx < lines.count { idx += 1 }
                blocks.append(.code(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider)
                idx += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 4 && trimmed.dropFirst(hashes).first == " " {
                    let title = String(trimmed.dropFirst(hashes + 1))
                    blocks.append(.heading(level: hashes, text: title))
                    idx += 1
                    continue
                }
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") { quoteLines.append(String(t.dropFirst(2))); idx += 1 }
                    else if t == ">" { quoteLines.append(""); idx += 1 }
                    else { break }
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") {
                        items.append(String(t.dropFirst(2)))
                        idx += 1
                    } else { break }
                }
                blocks.append(.list(ordered: false, items: items))
                continue
            }
            var paraLines: [String] = []
            while idx < lines.count {
                let l = lines[idx]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("> ") {
                    break
                }
                paraLines.append(l)
                idx += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            } else {
                idx += 1
            }
        }
        return blocks
    }

    var body: some View {
        let blocks = Self.parseBlocks(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let text):
                    inlineMarkdownText(text)
                        .font(level == 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .foregroundStyle(Color(white: 0.95))
                        .padding(.top, index == 0 ? 0 : 4)
                case .paragraph(let text):
                    inlineMarkdownText(text)
                        .font(.body)
                        .foregroundStyle(Color(white: 0.89))
                        .lineSpacing(3)
                case .quote(let text):
                    inlineMarkdownText(text)
                        .font(.subheadline)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 2)
                        }
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•")
                                    .font(.subheadline)
                                    .foregroundStyle(OrbStyle.textSecondary)
                                inlineMarkdownText(item)
                                    .font(.body)
                                    .foregroundStyle(Color(white: 0.89))
                            }
                        }
                    }
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OrbStyle.textMuted)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = code
                                OrbHaptics.light()
                                copiedBlockIndex = index
                                Task {
                                    try? await Task.sleep(for: .seconds(1.4))
                                    if copiedBlockIndex == index { copiedBlockIndex = nil }
                                }
                            } label: {
                                Text(copiedBlockIndex == index ? "Copied ✓" : "Copy code")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(copiedBlockIndex == index ? OrbStyle.success : OrbStyle.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color(white: 0.9))
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                        }
                    }
                    .background(Color(white: 0.086), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.09)))
                case .divider:
                    Divider().overlay(Color.white.opacity(0.1))
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            let str = url.absoluteString
            if str.hasPrefix("file:///") || str.hasPrefix("sandbox:") || str.hasPrefix("/mnt/data/") {
                onArtifact(str)
                return .handled
            }
            return .systemAction
        })
    }

    private func inlineMarkdownText(_ raw: String) -> Text {
        if let attr = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(raw)
    }
}

struct OrbRichText: View {
    let source: String
    var onArtifact: (String) -> Void = { _ in }
    /// Set to `true` during A/B benchmarking to force native SwiftUI block rendering when no LaTeX/tables are present.
    @MainActor static var preferNativeWhenSimple = false
    @State private var height: CGFloat?
    @Environment(\.dynamicTypeSize) private var textSize
    private var resolvedHeight: CGFloat {
        height ?? OrbRichHeightCache.get(source, textSize)
    }
    var body: some View {
        if Self.preferNativeWhenSimple && !OrbNativeMarkdownView.requiresWebRenderer(source) {
            OrbNativeMarkdownView(source: source, onArtifact: onArtifact)
        } else {
            RichWeb(source: source, height: Binding(
                get: { resolvedHeight },
                set: { height = $0 }
            ), onArtifact: onArtifact, textSize: textSize)
            .frame(height: max(24, resolvedHeight))
        }
    }
    private struct RichWeb: UIViewRepresentable {
        let source: String
        @Binding var height: CGFloat
        let onArtifact: (String) -> Void
        let textSize: DynamicTypeSize
        func makeCoordinator() -> Coordinator { Coordinator(height: $height, onArtifact: onArtifact) }
        func makeUIView(context: Context) -> WKWebView {
            let view = OrbWebViewPool.shared.acquire()
            view.configuration.userContentController.removeScriptMessageHandler(forName: "orb")
            view.configuration.userContentController.add(context.coordinator, name: "orb")
            view.navigationDelegate = context.coordinator
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
            // Check if the pooled WKWebView already loaded our template
            view.evaluateJavaScript("typeof window.orbUpdate === 'function'") { result, _ in
                if (result as? Bool) == true {
                    context.coordinator.ready = true
                    view.evaluateJavaScript(context.coordinator.updateScript)
                    return
                }
                guard !context.coordinator.loading else { return }
                context.coordinator.loading = true
                view.loadHTMLString(OrbWebViewPool.htmlTemplate(fontSize: size), baseURL: root)
            }
        }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
            OrbWebViewPool.shared.release(view)
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
                    if let source, let textSize { OrbRichHeightCache.set(resolved, for: source, textSize) }
                    if abs(height.wrappedValue - resolved) > 0.5 {
                        height.wrappedValue = resolved
                    }
                }
                if let copy = body["copy"] as? String {
                    UIPasteboard.general.string = copy
                    OrbHaptics.light()
                }
                if let artifact = body["artifact"] as? String { onArtifact(artifact) }
                if let link = body["link"] as? String {
                    if link.hasPrefix("sandbox:") || link.hasPrefix("/mnt/data/") || link.hasPrefix("file:///") || link.hasPrefix("/srv/") || link.hasPrefix("/Users/") || link.hasPrefix("/root/") || link.hasPrefix("/workspace/") || link.hasPrefix("/home/") || link.hasPrefix("/var/") || link.hasPrefix("/tmp/") {
                        onArtifact(link)
                        return
                    }
                    if let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme ?? ""), url.user == nil, url.password == nil { UIApplication.shared.open(url) }
                }
            }
            func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                decisionHandler(action.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}

// MARK: - Desktop Message Presentation Parity (`remoteLog.ts`, `backgroundWake.ts`, `messagePresentation.ts`)

/// Recover human text from remote terminal receipts (`remoteLog.ts`).
enum OrbRemoteLog {
    struct Parsed: Equatable {
        let text: String
        let details: String?
    }

    private static let receiptHeaderRegex = try! NSRegularExpression(pattern: #"^Remote node '[^']+' job [0-9a-f-]{36} (?:finished with|reached) state '"#)
    private static let succeededReceiptRegex = try! NSRegularExpression(pattern: #"^Remote node '[^']+' job [0-9a-f-]{36} finished with state 'succeeded' \(exit Some\(0\)\)$"#)
    private static let trailingJobTrailerRegex = try! NSRegularExpression(pattern: #"(?:^|\n\n)(Remote (?:node '[^']+'|[a-z0-9_-]+) job [0-9a-f-]{36}(?: on node '[^']+')? (?:finished with|reached) state '[\s\S]*)$"#)
    private static let uuidRegex = try! NSRegularExpression(pattern: #"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#, options: .caseInsensitive)

    static func parse(_ raw: String) -> Parsed {
        if let native = antigravityResponse(raw) {
            return Parsed(text: native, details: raw)
        }
        let nsRaw = raw as NSString
        guard receiptHeaderRegex.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)) != nil else {
            if let match = trailingJobTrailerRegex.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)),
               match.range.location > 0 {
                let humanText = nsRaw.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                let trailerDetails = nsRaw.substring(with: match.range(at: 1))
                if !humanText.isEmpty {
                    return Parsed(text: humanText, details: trailerDetails)
                }
            }
            return Parsed(text: raw, details: nil)
        }
        let marker = "\n\nlog tail:\n"
        guard let markerRange = raw.range(of: marker) else {
            return Parsed(text: raw, details: nil)
        }
        let header = String(raw[..<markerRange.lowerBound])
        let log = String(raw[markerRange.upperBound...])
        var parts: [String] = []
        var seen: Set<String> = []
        for line in log.components(separatedBy: "\n") {
            if let native = antigravityResponse(line) {
                parts.append(native)
                continue
            }
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(OrbJSON.self, from: data) else { continue }
            let sessionID = event["sessionID"].text
            guard sessionID.hasPrefix("ses_"), event["type"].text == "text" else { continue }
            guard case .string(let partText) = event["part"]["text"] else { continue }
            let id = event["part"]["id"].text
            if !id.isEmpty {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            parts.append(partText)
        }
        if parts.isEmpty {
            let nsHeader = header as NSString
            let success = succeededReceiptRegex.firstMatch(in: header, range: NSRange(location: 0, length: nsHeader.length)) != nil
            if success && !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !structuredHarnessLog(log) {
                return Parsed(text: log, details: raw)
            }
            return Parsed(text: header, details: raw)
        }
        let failed = !header.contains("finished with state 'succeeded'")
        return Parsed(text: (failed ? header + "\n\n" : "") + parts.joined(separator: "\n\n"), details: raw)
    }

    private static func structuredHarnessLog(_ log: String) -> Bool {
        for line in log.components(separatedBy: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(OrbJSON.self, from: data),
                  case .object = event else { continue }
            let sessionID = event["sessionID"].text
            if sessionID.hasPrefix("ses_") {
                if ["text", "tool_use", "step_start", "step_finish", "error"].contains(event["type"].text) && event["part"] != .null {
                    return true
                }
            }
            let evType = event["event"].text
            let payload: OrbJSON = evType == "step_update" ? event["step_update"] : (evType == "result" ? event["result"] : .null)
            guard payload != .null else { continue }
            let convID = payload["conversation_id"].text
            let nsConv = convID as NSString
            guard uuidRegex.firstMatch(in: convID, range: NSRange(location: 0, length: nsConv.length)) != nil else { continue }
            if evType == "step_update" {
                if case .number(let stepIdx) = payload["step_index"], stepIdx.rounded() == stepIdx,
                   ["ACTIVE", "DONE", "ERROR"].contains(payload["state"].text) {
                    return true
                }
            } else if ["SUCCESS", "ERROR"].contains(payload["status"].text),
                      case .number = payload["duration_seconds"] {
                return true
            }
        }
        return false
    }

    private static func antigravityResponse(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(OrbJSON.self, from: data) else { return nil }
        let result = value["event"].text == "result" ? value["result"] : value
        guard case .object = result,
              case .string(let response) = result["response"],
              ["SUCCESS", "ERROR"].contains(result["status"].text),
              case .number = result["duration_seconds"],
              case .number = result["num_turns"] else { return nil }
        return response
    }
}

/// Hide only the exact server-generated attachment transport trailer (`messagePresentation.ts`).
enum OrbMessagePresentation {
    struct Parsed: Equatable {
        let text: String
        let attached: Bool
    }

    private static let trailerRegex = try! NSRegularExpression(
        pattern: #"\n\n<!-- paloma:attachment:([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}) -->\nAttached context: read `\.paloma\/messages\/\1\/\.paloma\/attach\.md` \(paths in that manifest are relative to `\.paloma\/messages\/\1`\)\.$"#,
        options: .caseInsensitive
    )

    static func parse(_ content: String) -> Parsed {
        let ns = content as NSString
        guard let match = trailerRegex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else {
            return Parsed(text: content, attached: false)
        }
        return Parsed(text: ns.substring(to: match.range.location), attached: true)
    }
}

/// The coordinator's wake message after a Claude Code background shell ends (`backgroundWake.ts`).
struct OrbBackgroundWake: Equatable {
    let task: String
    let command: String
    let output: String
    let killed: Bool
    let note: String

    private static let wakeRegex = try! NSRegularExpression(
        pattern: #"^Background task `([^`\n]+)` \(`([\s\S]*)`\) finished\.(?: Output:\n\n```\n([\s\S]*)\n```| \(No captured output was available\.\)(.*))([\s\S]*?)\n\nContinue from here\.$"#
    )

    static func parse(_ text: String, source: String? = nil) -> OrbBackgroundWake? {
        if let source, !source.isEmpty, source != "background-task" { return nil }
        let ns = text as NSString
        guard let match = wakeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let task = ns.substring(with: match.range(at: 1))
        let command = ns.substring(with: match.range(at: 2))
        let output = (match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let part4 = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
        let part5 = match.range(at: 5).location != NSNotFound ? ns.substring(with: match.range(at: 5)) : ""
        var rawNote = (part4 + part5).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawNote.hasPrefix("(Note: ") && rawNote.hasSuffix(")") {
            rawNote = String(rawNote.dropFirst(7).dropLast(1))
        } else if rawNote.hasPrefix("(") && rawNote.hasSuffix(")") {
            rawNote = String(rawNote.dropFirst(1).dropLast(1))
        }
        let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return OrbBackgroundWake(task: task, command: command, output: output, killed: output == "[killed]", note: note)
    }
}
