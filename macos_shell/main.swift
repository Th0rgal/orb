// macos_shell/main.swift — Minimal AppKit + WKWebView shell for Orb desktop (< 90 LOC).
// Launches `orb-locald` on loopback, injects `window.__TAURI__` / `window.__TAURI_INTERNALS__`,
// configures NSVisualEffectView(.sidebar) vibrancy + traffic lights at (12, 20), and loads `orb/dist/index.html`.
import AppKit
import WebKit

final class OrbAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var localdProc: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let port = ProcessInfo.processInfo.environment["ORB_LOCALD_PORT"] ?? "19479"
        let token = UUID().uuidString
        if let localdPath = ProcessInfo.processInfo.environment["ORB_LOCALD_BIN"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: localdPath)
            var env = ProcessInfo.processInfo.environment
            env["ORB_LOCALD_PORT"] = port
            env["ORB_LOCALD_TOKEN"] = token
            p.environment = env
            try? p.run()
            self.localdProc = p
        }

        let initJs = """
        (() => {
          const ORB_LOCALD_URL = 'http://127.0.0.1:\(port)/__orb_rpc';
          const ORB_TOKEN = '\(token)';
          class Channel { constructor() { this.onmessage = () => {}; } }
          const listeners = new Map();
          async function invoke(command, args = {}) {
            const clean = { ...(args || {}) };
            if (clean.onEvent instanceof Channel) delete clean.onEvent;
            const r = await fetch(ORB_LOCALD_URL, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },
              body: JSON.stringify({ command, args: clean })
            });
            const b = await r.json();
            if (!r.ok || b.error) throw new Error(b.error || command);
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
            WKUserScript(source: initJs, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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
        let vibrancy = NSVisualEffectView(frame: rect)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        webView = WKWebView(frame: rect, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        vibrancy.addSubview(webView)
        window.contentView = vibrancy
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let devUrl = ProcessInfo.processInfo.environment["ORB_DEV_URL"], let u = URL(string: devUrl) {
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
