import SwiftUI
import UIKit
import WebKit

/// Renders Mermaid source to SVG with the bundled mermaid build (`MermaidAssets`),
/// in one hidden WKWebView shared by every diagram. Results are cached by source,
/// so a transcript re-render or a recycled row never runs layout again.
@MainActor
final class OrbMermaidRenderer: NSObject, WKNavigationDelegate {
    enum Result: Equatable {
        case svg(String, width: CGFloat, height: CGFloat)
        case failure(String)
    }

    static let shared = OrbMermaidRenderer()
    private var cache: [String: Result] = [:]
    private var order: [String] = []
    private var web: WKWebView?
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func cached(_ source: String) -> Result? { cache[source] }

    func render(_ source: String) async -> Result {
        if let hit = cache[source] { return hit }
        guard source.count <= 50_000 else { return .failure("Diagram source is too large") }
        await load()
        guard let web else { return .failure("The diagram renderer is unavailable") }
        let result: Result
        do {
            let value = try await web.callAsyncJavaScript("return await window.orbRender(source)", arguments: ["source": source], contentWorld: .page)
            let dict = value as? [String: Any] ?? [:]
            if let svg = dict["svg"] as? String, let w = dict["width"] as? Double, let h = dict["height"] as? Double, w > 0, h > 0 {
                result = .svg(svg, width: w, height: h)
            } else {
                result = .failure((dict["error"] as? String) ?? "Unknown syntax error")
            }
        } catch {
            result = .failure(error.localizedDescription)
        }
        cache[source] = result
        order.append(source)
        if order.count > 100 { cache[order.removeFirst()] = nil }
        return result
    }

    private func load() async {
        if ready { return }
        if web == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view.navigationDelegate = self
            web = view
            if let url = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "MermaidAssets") {
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                ready = true
                return
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in self.ready = false; self.web = nil }
    }

    private func finishLoading() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A ```mermaid block: Diagram | Code toggle, copy, and tap to open fullscreen with pinch zoom.
struct OrbMermaidBlock: View {
    let code: String
    let complete: Bool
    @State private var result: OrbMermaidRenderer.Result?
    @State private var showCode = false
    @State private var copied = false
    @State private var fullscreen = false

    private var source: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var failure: String? { if case .failure(let message) = result { return message }; return nil }
    private var diagramVisible: Bool { complete && failure == nil && !showCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if diagramVisible {
                if case .svg(let svg, let width, let height) = result {
                    OrbSVGView(svg: svg, interactive: false)
                        .aspectRatio(width / height, contentMode: .fit)
                        .frame(maxWidth: width, maxHeight: max(120, min(height, 520)))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { fullscreen = true }
                        .accessibilityLabel("Diagram")
                        .accessibilityHint("Opens the diagram fullscreen")
                        .accessibilityAddTraits(.isButton)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Rendering diagram").font(.caption).foregroundStyle(OrbStyle.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
            } else {
                if let failure {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couldn't render diagram").font(.caption.weight(.medium)).foregroundStyle(OrbStyle.error)
                        Text(failure).font(.system(.caption2, design: .monospaced)).foregroundStyle(OrbStyle.textSecondary).lineLimit(6)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrbStyle.error.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.error.opacity(0.28)))
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color(white: 0.9))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
        .background(Color(white: 0.086), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.09)))
        .task(id: complete ? source : "") {
            guard complete else { return }
            if let hit = OrbMermaidRenderer.shared.cached(source) { result = hit; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let rendered = await OrbMermaidRenderer.shared.render(source)
            if !Task.isCancelled { result = rendered }
        }
        .fullScreenCover(isPresented: $fullscreen) {
            if case .svg(let svg, _, _) = result { OrbMermaidFullscreen(svg: svg) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Mermaid").font(.caption.weight(.medium)).foregroundStyle(OrbStyle.textMuted)
            HStack(spacing: 2) {
                segment("Diagram", selected: diagramVisible, enabled: complete && failure == nil) { showCode = false }
                segment("Code", selected: !diagramVisible, enabled: true) { showCode = true }
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
            Button {
                UIPasteboard.general.string = code
                OrbHaptics.light()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? OrbStyle.success : OrbStyle.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy diagram source")
            Button { fullscreen = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OrbStyle.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!(diagramVisible && result != nil))
            .opacity(diagramVisible && result != nil ? 1 : 0.4)
            .accessibilityLabel("Expand diagram")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func segment(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : OrbStyle.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(selected ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OrbMermaidFullscreen: View {
    let svg: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OrbSVGView(svg: svg, interactive: true)
                .ignoresSafeArea(edges: .bottom)
                .background(Color(white: 0.073))
                .navigationTitle("Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// Displays a rendered SVG. The page's CSP forbids every script, so diagram
/// content can only be drawn, never executed. Interactive views pinch-zoom and pan.
struct OrbSVGView: UIViewRepresentable {
    let svg: String
    let interactive: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = interactive
        view.scrollView.bouncesZoom = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = interactive
        view.accessibilityIdentifier = interactive ? "mermaid-fullscreen" : "mermaid-diagram"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.svg != svg else { return }
        context.coordinator.svg = svg
        let viewport = interactive ? "width=device-width,initial-scale=1,minimum-scale=0.2,maximum-scale=8" : "width=device-width,initial-scale=1,user-scalable=no"
        let layout = interactive
            ? "body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box}svg{max-width:100%;height:auto}"
            : "body{display:flex;align-items:center;justify-content:center;height:100vh}svg{width:100%;height:100%}"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="\(viewport)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>html,body{margin:0;background:transparent;font:13px -apple-system,system-ui,sans-serif}\(layout)</style></head><body>\(svg)</body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var svg: String? }
}
