// macos_shell/main.swift — Hardened AppKit + WKWebView shell for Orb desktop.
// Launches `orb-locald` on loopback with an allowlisted environment, injects `window.__TAURI__` /
// `window.__TAURI_INTERNALS__` into the main frame only (`forMainFrameOnly: true`) with captured `_fetch`,
// confines top-frame navigation to loopback/`file://`, and positions macOS traffic lights + sidebar vibrancy.
import AppKit
import Security
import WebKit

final class OrbAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var localdProc: Process?

    private static func randomHex256() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func jsonStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }

    private static func isConfinedShellURL(_ u: URL) -> Bool {
        if u.isFileURL || u.absoluteString == "about:blank" { return true }
        guard u.scheme == "http", let h = u.host else { return false }
        return h == "127.0.0.1" || h == "localhost"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        if let u = navigationAction.request.url, Self.isConfinedShellURL(u) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let rawPort = Int(env["ORB_LOCALD_PORT"] ?? "19479") ?? 19479
        let port = (1024...65535).contains(rawPort) ? rawPort : 19479
        let envTok = env["ORB_LOCALD_TOKEN"] ?? ""
        let token = (envTok.utf8.count >= 32 && envTok != "orb-locald-default-token") ? envTok : Self.randomHex256()

        let bundledLocald = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orb-locald")
        let resolvedLocald: URL? = {
            if let p = env["ORB_LOCALD_BIN"], !p.isEmpty { return URL(fileURLWithPath: p) }
            if let b = bundledLocald, FileManager.default.isExecutableFile(atPath: b.path) { return b }
            return nil
        }()
        if let localdURL = resolvedLocald {
            let p = Process()
            p.executableURL = localdURL
            var childEnv: [String: String] = [
                "ORB_LOCALD_PORT": String(port),
                "ORB_LOCALD_TOKEN": token
            ]
            for k in ["HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH"] {
                if let v = env[k] { childEnv[k] = v }
            }
            p.environment = childEnv
            try? p.run()
            self.localdProc = p
        }

        let urlLit = Self.jsonStringLiteral("http://127.0.0.1:\(port)/__orb_rpc")
        let tokLit = Self.jsonStringLiteral(token)
        let initJs = """
        (() => {
          const _fetch = window.fetch.bind(window);
          const _jsonStringify = JSON.stringify;
          const ORB_LOCALD_URL = \(urlLit);
          const ORB_TOKEN = \(tokLit);
          class Channel { constructor() { this.onmessage = () => {}; } }
          const listeners = new Map();
          const channels = new Map();
          let timer = 0;
          async function drain() {
            if (!channels.size) { if (timer) { clearInterval(timer); timer = 0; } return; }
            try {
              const r = await _fetch(ORB_LOCALD_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },
                body: _jsonStringify({ command: '__orb_poll_events', args: {} })
              });
              const b = await r.json();
              if (Array.isArray(b.result)) {
                for (const ev of b.result) channels.get(ev.token)?.onmessage(ev.payload);
              }
            } catch {}
          }
          async function invoke(command, args = {}) {
            const clean = { ...(args || {}) };
            let bound = null;
            if (clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; }
            if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') channels.delete(clean.token);
            const r = await _fetch(ORB_LOCALD_URL, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },
              body: _jsonStringify({ command, args: clean })
            });
            const b = await r.json();
            if (!r.ok || b.error) throw new Error(b.error || command);
            if (bound && typeof b.result === 'number') {
              channels.set(b.result, bound);
              if (!timer) timer = setInterval(drain, 250);
              void drain();
            }
            return b.result;
          }
          async function listen(n, h) {
            if (!listeners.has(n)) listeners.set(n, new Set());
            listeners.get(n).add(h);
            return () => listeners.get(n)?.delete(h);
          }
          window.__TAURI_INTERNALS__ = { invoke };
          window.__TAURI__ = {
            core: { invoke, Channel },
            event: { listen },
            window: { getCurrentWindow: () => ({
              innerSize: async () => ({ width: window.innerWidth, height: window.innerHeight }),
              scaleFactor: async () => window.devicePixelRatio || 1
            }) },
            webview: { getCurrentWebview: () => ({ label: 'main' }) }
          };
        })();
        """

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(
            WKUserScript(source: initJs, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let rect = NSRect(x: 0, y: 0, width: 1470, height: 923)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 720, height: 480)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        for (idx, btnType) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let btn = window.standardWindowButton(btnType) {
                btn.setFrameOrigin(NSPoint(x: 12 + CGFloat(idx) * 20, y: 12))
            }
        }
        let vibrancy = NSVisualEffectView(frame: rect)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        webView = WKWebView(frame: rect, configuration: cfg)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        vibrancy.addSubview(webView)
        window.contentView = vibrancy
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let devUrl = env["ORB_DEV_URL"], let u = URL(string: devUrl), Self.isConfinedShellURL(u) {
            webView.load(URLRequest(url: u))
        } else if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localdProc?.terminate()
    }
}

let app = NSApplication.shared
let delegate = OrbAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
