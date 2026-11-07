// macos_shell/main.swift — Hardened AppKit + WKWebView shell for Orb desktop.
// Launches `orb-locald` on loopback with an allowlisted environment, installs standard macOS
// Application + Edit + Window menus (so Cmd+A/X/C/V/Z/Q/W/M/H work natively in WKWebView),
// injects `window.__ORB_DESKTOP__` (+ `__TAURI__` / `__TAURI_INTERNALS__` compatibility aliases)
// into the main frame only (`forMainFrameOnly: true`) with captured `_fetch` and zero-idle-poll
// SSE event streaming (`/__orb_events`), handles native macOS window drag / theme / file panels,
// confines top-frame navigation to loopback/`file://`, and positions traffic lights + vibrancy.
import AppKit
import Security
import WebKit

final class OrbBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "md", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let reqURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relPath = reqURL.path
        while relPath.hasPrefix("/") { relPath.removeFirst() }
        if relPath.isEmpty { relPath = "index.html" }

        let candidate = rootURL.appendingPathComponent(relPath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : (rootURL.path + "/")
        var target = candidate
        var isDir: ObjCBool = false
        let inRoot = (candidate.path == rootURL.path) || candidate.path.hasPrefix(rootPrefix)
        if !inRoot || !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) || isDir.boolValue {
            // SPA fallback only for extensionless navigation routes; missing assets return 404.
            if URL(fileURLWithPath: relPath).pathExtension.isEmpty {
                target = rootURL.appendingPathComponent("index.html").standardizedFileURL.resolvingSymlinksInPath()
            } else {
                let resp = HTTPURLResponse(url: reqURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Access-Control-Allow-Origin": "tauri://localhost"
                ])!
                urlSchemeTask.didReceive(resp)
                urlSchemeTask.didFinish()
                return
            }
        }

        guard let data = try? Data(contentsOf: target) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mimeType(for: target.pathExtension)
        let resp = HTTPURLResponse(url: reqURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "tauri://localhost",
            "Cache-Control": "no-cache"
        ])!
        urlSchemeTask.didReceive(resp)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class OrbAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var localdProc: Process?
    var schemeHandler: OrbBundleSchemeHandler?

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
        if u.scheme == "tauri" && u.host == "localhost" { return true }
        guard u.scheme == "http", let h = u.host else { return false }
        return h == "127.0.0.1" || h == "localhost"
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Orb", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "Hide Orb", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit menu (required by AppKit + WKWebView for Cmd+Z, Shift+Cmd+Z, Cmd+X, Cmd+C, Cmd+V, Cmd+A)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func replyToWebView(id: Int, result: Any?, error: String? = nil) {
        var payload: [String: Any] = ["id": id]
        if let err = error {
            payload["error"] = err
        } else {
            payload["result"] = result ?? NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__ORB_NATIVE_REPLY__&&window.__ORB_NATIVE_REPLY__(\(json));", completionHandler: nil)
    }

    private static let skippedFolderNames: Set<String> = [
        ".git", "node_modules", ".lake", "target", ".DS_Store", "__pycache__", ".venv", ".next", "dist"
    ]

    private static func walkFolderForUpload(folderURL: URL) -> [[String: Any]] {
        let fm = FileManager.default
        let baseName = folderURL.lastPathComponent
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return [] }
        var out: [[String: Any]] = []
        let rootComponents = folderURL.standardizedFileURL.pathComponents
        for case let itemURL as URL in enumerator {
            let name = itemURL.lastPathComponent
            let vals = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if vals?.isSymbolicLink == true {
                if vals?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if vals?.isDirectory == true {
                if skippedFolderNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            guard vals?.isRegularFile == true else { continue }
            let comps = itemURL.standardizedFileURL.pathComponents
            guard comps.count > rootComponents.count else { continue }
            let relInside = comps.dropFirst(rootComponents.count).joined(separator: "/")
            let relPath = "\(baseName)/\(relInside)"
            let size = vals?.fileSize ?? 0
            out.append([
                "name": name,
                "path": itemURL.path,
                "relative_path": relPath,
                "size": size
            ])
            if out.count >= 4096 { break }
        }
        return out
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "orbNative",
              message.frameInfo.isMainFrame,
              let dict = message.body as? [String: Any],
              let cmd = dict["command"] as? String else { return }
        if cmd == "window_drag" {
            if let ev = NSApp.currentEvent {
                window?.performDrag(with: ev)
            }
            return
        }
        guard let reqId = dict["id"] as? Int else { return }
        let args = (dict["args"] as? [String: Any]) ?? [:]
        switch cmd {
        case "set_window_theme":
            let theme = (args["theme"] as? String) ?? "auto"
            if theme == "dark" {
                window?.appearance = NSAppearance(named: .darkAqua)
            } else if theme == "light" {
                window?.appearance = NSAppearance(named: .aqua)
            } else {
                window?.appearance = nil
            }
            replyToWebView(id: reqId, result: nil)
        case "pick_working_directory":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            guard let win = window else { replyToWebView(id: reqId, result: nil); return }
            panel.beginSheetModal(for: win) { resp in
                let chosen = (resp == .OK) ? panel.url?.path : nil
                self.replyToWebView(id: reqId, result: chosen)
            }
        case "pick_upload_files":
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Attach"
            guard let win = window else { replyToWebView(id: reqId, result: []); return }
            panel.beginSheetModal(for: win) { resp in
                guard resp == .OK else {
                    self.replyToWebView(id: reqId, result: [])
                    return
                }
                let items: [[String: String]] = panel.urls.map { u in
                    ["name": u.lastPathComponent, "path": u.path]
                }
                let parents = Array(Set(panel.urls.map { $0.deletingLastPathComponent().path }))
                self.replyToWebView(id: reqId, result: ["files": items, "grants": parents])
            }
        case "pick_upload_folder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Attach Folder"
            guard let win = window else {
                replyToWebView(id: reqId, result: ["batch": NSNull(), "files": []])
                return
            }
            panel.beginSheetModal(for: win) { resp in
                guard resp == .OK, let folderURL = panel.url else {
                    self.replyToWebView(id: reqId, result: ["batch": NSNull(), "files": []])
                    return
                }
                let walked = Self.walkFolderForUpload(folderURL: folderURL)
                self.replyToWebView(id: reqId, result: ["batch": folderURL.path, "files": walked])
            }
        case "save_file_prompt":
            let suggested = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if !suggested.isEmpty { panel.nameFieldStringValue = suggested }
            guard let win = window else { replyToWebView(id: reqId, result: nil); return }
            panel.beginSheetModal(for: win) { resp in
                let chosen = (resp == .OK) ? panel.url?.path : nil
                self.replyToWebView(id: reqId, result: chosen)
            }
        default:
            replyToWebView(id: reqId, result: nil, error: "Unsupported native UI command: \(cmd)")
        }
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
        installMainMenu()
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
            for k in ["HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH", "ORB_STATE_DIR"] {
                if let v = env[k] { childEnv[k] = v }
            }
            p.environment = childEnv
            try? p.run()
            self.localdProc = p
        }

        let urlLit = Self.jsonStringLiteral("http://127.0.0.1:\(port)/__orb_rpc")
        let sseLit = Self.jsonStringLiteral("http://127.0.0.1:\(port)/__orb_events")
        let tokLit = Self.jsonStringLiteral(token)
        let initJs = """
        (() => {
          const _fetch = window.fetch.bind(window);
          const _jsonStringify = JSON.stringify;
          const _postNative = window.webkit?.messageHandlers?.orbNative
            ? (msg) => window.webkit.messageHandlers.orbNative.postMessage(msg)
            : null;
          const ORB_LOCALD_URL = \(urlLit);
          const ORB_EVENTS_URL = \(sseLit);
          const ORB_TOKEN = \(tokLit);
          class Channel { constructor() { this.onmessage = () => {}; } }
          const listeners = new Map();
          const channels = new Map();
          const nativePending = new Map();
          let nextNativeId = 1;
          let streamCtrl = null;
          window.__ORB_NATIVE_REPLY__ = (msg) => {
            const entry = msg && nativePending.get(msg.id);
            if (!entry) return;
            nativePending.delete(msg.id);
            if (msg.error) entry.reject(new Error(msg.error));
            else entry.resolve(msg.result);
          };
          function callNativeUI(command, args = {}) {
            if (!_postNative) return Promise.resolve(null);
            return new Promise((resolve, reject) => {
              const id = nextNativeId++;
              nativePending.set(id, { resolve, reject });
              _postNative({ id, command, args });
            });
          }
          if (_postNative) {
            window.addEventListener('mousedown', (ev) => {
              if (ev.button !== 0 || ev.defaultPrevented) return;
              const t = ev.target instanceof Element ? ev.target : null;
              if (!t) return;
              if (!t.closest('[data-orb-drag-region], [data-tauri-drag-region], .titlebar, .file-tabs')) return;
              if (t.closest('button, a, input, select, textarea, summary, [role="button"], [contenteditable="true"], .no-drag')) return;
              if (ev.detail === 2) return;
              _postNative({ command: 'window_drag' });
            }, true);
          }
          async function callLocald(command, args = {}) {
            const r = await _fetch(ORB_LOCALD_URL, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },
              body: _jsonStringify({ command, args })
            });
            const b = await r.json();
            if (!r.ok || b.error) throw new Error(b.error || command);
            return b.result;
          }
          async function drain() {
            if (!channels.size) return;
            try {
              const res = await callLocald('__orb_poll_events', {});
              if (Array.isArray(res)) {
                for (const ev of res) channels.get(ev.token)?.onmessage(ev.payload);
              }
            } catch {}
          }
          function stopStream() {
            if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; }
          }
          function ensureStream() {
            if (streamCtrl || !channels.size) return;
            const ctrl = new AbortController();
            streamCtrl = ctrl;
            (async () => {
              while (!ctrl.signal.aborted && channels.size) {
                try {
                  const r = await _fetch(ORB_EVENTS_URL, {
                    headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN },
                    signal: ctrl.signal
                  });
                  if (!r.ok || !r.body) throw new Error('sse');
                  const reader = r.body.getReader();
                  const dec = new TextDecoder();
                  let buf = '';
                  while (!ctrl.signal.aborted && channels.size) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    buf += dec.decode(value, { stream: true });
                    let idx;
                    while ((idx = buf.indexOf('\\n\\n')) >= 0) {
                      const frame = buf.slice(0, idx);
                      buf = buf.slice(idx + 2);
                      for (const ln of frame.split('\\n')) {
                        if (ln.startsWith('data: ')) {
                          const arr = JSON.parse(ln.slice(6));
                          if (Array.isArray(arr)) for (const ev of arr) channels.get(ev.token)?.onmessage(ev.payload);
                        }
                      }
                    }
                  }
                } catch {
                  if (ctrl.signal.aborted || !channels.size) break;
                  await new Promise(res => setTimeout(res, 1500));
                  if (!ctrl.signal.aborted && channels.size) await drain();
                }
              }
              if (streamCtrl === ctrl) streamCtrl = null;
            })();
          }
          async function invoke(command, args = {}) {
            const clean = { ...(args || {}) };
            if (_postNative) {
              if (command === 'set_window_theme') return callNativeUI('set_window_theme', clean);
              if (command === 'pick_working_directory') return callNativeUI('pick_working_directory', clean);
              if (command === 'pick_upload_files') {
                const picked = await callNativeUI('pick_upload_files', clean);
                const grants = Array.isArray(picked?.grants) ? picked.grants : [];
                for (const g of grants) await callLocald('grant_upload_folder', { path: g });
                return Array.isArray(picked?.files) ? picked.files : [];
              }
              if (command === 'pick_upload_folder') {
                const offer = await callNativeUI('pick_upload_folder', clean);
                if (offer?.batch) await callLocald('grant_upload_folder', { batch: offer.batch });
                return offer || { batch: null, files: [] };
              }
              if (command === 'save_file_as' && !clean.destPath) {
                const destPath = await callNativeUI('save_file_prompt', { name: clean.name || '' });
                if (!destPath) return null;
                return callLocald('save_file_as', { destPath, dataBase64: clean.dataBase64 || '' });
              }
            }
            let bound = null;
            if (clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; }
            if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') {
              channels.delete(clean.token);
              if (!channels.size) stopStream();
            }
            const result = await callLocald(command, clean);
            if (bound && typeof result === 'number') {
              channels.set(result, bound);
              void drain();
              ensureStream();
            }
            return result;
          }
          async function listen(n, h) {
            if (!listeners.has(n)) listeners.set(n, new Set());
            listeners.get(n).add(h);
            return () => listeners.get(n)?.delete(h);
          }
          const desktop = {
            core: { invoke, Channel },
            event: { listen },
            window: { getCurrentWindow: () => ({
              innerSize: async () => ({ width: window.innerWidth, height: window.innerHeight }),
              scaleFactor: async () => window.devicePixelRatio || 1
            }) },
            webview: { getCurrentWebview: () => ({ label: 'main' }) }
          };
          window.__ORB_DESKTOP__ = desktop;
          window.__TAURI_INTERNALS__ = { invoke };
          window.__TAURI__ = desktop;
        })();
        """

        let cfg = WKWebViewConfiguration()
        if let distRoot = Bundle.main.resourceURL?.appendingPathComponent("dist") {
            let handler = OrbBundleSchemeHandler(rootURL: distRoot)
            self.schemeHandler = handler
            cfg.setURLSchemeHandler(handler, forURLScheme: "tauri")
        }
        cfg.userContentController.add(self, name: "orbNative")
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
        } else if let u = URL(string: "tauri://localhost/") {
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
