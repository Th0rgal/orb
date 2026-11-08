// macos_shell/main.swift — Hardened AppKit + WKWebView shell for Orb desktop.
// Launches `orb-locald` on loopback with an allowlisted environment, installs standard macOS
// Application + Edit + View + Window menus (so Cmd+A/X/C/V/Z/Q/W/M/H/R/0/+/-/, work natively),
// injects `window.__ORB_DESKTOP__` (+ `__TAURI__` / `__TAURI_INTERNALS__` compatibility aliases)
// into the main frame only (`forMainFrameOnly: true`) with captured `_fetch` and zero-idle-poll
// SSE event streaming (`/__orb_events`), handles native macOS window drag / theme / file panels /
// Finder file+folder drag-and-drop / ephemeral Mistral usage sign-in / WKUIDelegate alerts & mic,
// confines top-frame navigation to loopback/`file://`/`tauri://localhost` (routing external links
// to the default browser), and positions traffic lights + vibrancy.
import AppKit
import Darwin
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

final class OrbWebView: WKWebView {
    var onFinderDragEvent: ((String, [URL], NSPoint) -> Void)?

    private static func finderFileURLs(from info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource == nil else { return [] }
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return urls.filter { $0.isFileURL }
    }

    private func topLeftWindowPoint(for info: NSDraggingInfo) -> NSPoint {
        let locInView = convert(info.draggingLocation, from: nil)
        let yTop = isFlipped ? locInView.y : (bounds.height - locInView.y)
        return NSPoint(x: locInView.x, y: yTop)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = Self.finderFileURLs(from: sender)
        if !urls.isEmpty {
            onFinderDragEvent?("enter", urls, topLeftWindowPoint(for: sender))
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = Self.finderFileURLs(from: sender)
        if !urls.isEmpty {
            onFinderDragEvent?("over", urls, topLeftWindowPoint(for: sender))
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let s = sender, !Self.finderFileURLs(from: s).isEmpty {
            onFinderDragEvent?("leave", [], .zero)
            return
        }
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.finderFileURLs(from: sender)
        if !urls.isEmpty {
            onFinderDragEvent?("drop", urls, topLeftWindowPoint(for: sender))
            return true
        }
        return super.performDragOperation(sender)
    }
}

final class OrbMistralSignInController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private var signInWindow: NSWindow?
    private var signInWebView: WKWebView?
    private var dataStore: WKWebsiteDataStore?
    private var pollTimer: Timer?
    private var visitedConsole = false
    private var finished = false
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init()
    }

    func present() {
        let store = WKWebsiteDataStore.nonPersistent()
        self.dataStore = store
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        let rect = NSRect(x: 0, y: 0, width: 520, height: 680)
        let wv = WKWebView(frame: rect, configuration: cfg)
        wv.navigationDelegate = self
        wv.autoresizingMask = [.width, .height]
        self.signInWebView = wv

        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in to Mistral"
        win.minSize = NSSize(width: 420, height: 520)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = wv
        win.center()
        self.signInWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let u = URL(string: "https://admin.mistral.ai/subscription") {
            wv.load(URLRequest(url: u))
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.checkCookies()
        }
    }

    private static func isMistralDomain(_ rawDomain: String) -> Bool {
        let d = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return d == "mistral.ai" || d.hasSuffix(".mistral.ai")
    }

    private func checkCookies() {
        guard !finished, let store = dataStore else { return }
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.finished else { return }
            var oryPair: (String, String)?
            var csrfVal: String?
            for c in cookies where Self.isMistralDomain(c.domain) {
                if c.name.hasPrefix("ory_session_"), !c.value.isEmpty {
                    oryPair = (c.name, c.value)
                } else if c.name == "csrftoken", !c.value.isEmpty {
                    csrfVal = c.value
                }
            }
            if let (oryName, oryValue) = oryPair {
                if let csrf = csrfVal {
                    self.finish(with: "\(oryName)=\(oryValue); csrftoken=\(csrf)")
                } else if !self.visitedConsole {
                    self.visitedConsole = true
                    if let u = URL(string: "https://console.mistral.ai/") {
                        self.signInWebView?.load(URLRequest(url: u))
                    }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    private func finish(with cookieHeader: String?) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        let win = signInWindow
        signInWindow = nil
        signInWebView = nil
        dataStore = nil
        win?.delegate = nil
        win?.orderOut(nil)
        win?.close()
        completion(cookieHeader)
    }
}

final class OrbAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static let titlebarHeight: CGFloat = 35
    private static let trafficLightInsetX: CGFloat = 12
    private static let trafficLightStepX: CGFloat = 20
    private static let frameAutosaveName = "OrbMainWindow"

    var window: NSWindow!
    var webView: OrbWebView!
    var vibrancyView: NSVisualEffectView?
    var localdProc: Process?
    var signalSources: [DispatchSourceSignal] = []
    var schemeHandler: OrbBundleSchemeHandler?
    private var mistralSignIn: OrbMistralSignInController?

    static func canBindLoopbackPort(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func selectAvailableLoopbackPort(preferred: Int) -> Int {
        for cand in [preferred, 29479, 39479, 49479] where canBindLoopbackPort(cand) {
            return cand
        }
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard bound else { continue }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len) == 0
                }
            }
            if named {
                let p = Int(UInt16(bigEndian: addr.sin_port))
                if (1024...65520).contains(p) { return p }
            }
        }
        return preferred
    }

    private func installTerminationSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.localdProc?.terminate()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private static func setBoolPreference(_ prefs: WKPreferences, selector name: String, value: Bool) {
        let sel = Selector((name))
        guard prefs.responds(to: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let fn = unsafeBitCast(prefs.method(for: sel), to: Setter.self)
        fn(prefs, sel, ObjCBool(value))
    }

    private func layoutTrafficLights() {
        guard let win = window else { return }
        let targetMidYFromTop = Self.titlebarHeight / 2.0
        for (idx, btnType) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let btn = win.standardWindowButton(btnType), let sv = btn.superview else { continue }
            let x = Self.trafficLightInsetX + CGFloat(idx) * Self.trafficLightStepX
            let rawY = sv.isFlipped
                ? (targetMidYFromTop - btn.frame.height / 2.0)
                : (sv.bounds.height - targetMidYFromTop - btn.frame.height / 2.0)
            btn.setFrameOrigin(NSPoint(x: x, y: (rawY * 2.0).rounded() / 2.0))
        }
    }

    private func refreshWebViewDisplay() {
        guard let wv = webView else { return }
        wv.needsDisplay = true
        wv.layer?.setNeedsDisplay()
    }

    func windowDidResize(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        layoutTrafficLights()
        refreshWebViewDisplay()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutTrafficLights()
        refreshWebViewDisplay()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
        refreshWebViewDisplay()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let win = window, win.occlusionState.contains(.visible) else { return }
        layoutTrafficLights()
        refreshWebViewDisplay()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let win = window {
            win.makeKeyAndOrderFront(nil)
            layoutTrafficLights()
            if let wv = webView { win.makeFirstResponder(wv) }
        }
        return true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    static func randomHex256() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func jsonStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }

    static func isConfinedShellURL(_ u: URL) -> Bool {
        if u.isFileURL || u.absoluteString == "about:blank" { return true }
        if u.scheme == "tauri" && u.host == "localhost" { return true }
        guard u.scheme == "http", let h = u.host else { return false }
        return h == "127.0.0.1" || h == "localhost"
    }

    static func isSafeExternalOpenURL(_ u: URL) -> Bool {
        guard let scheme = u.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }

    func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem(title: "Orb", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Orb")
        appMenu.addItem(withTitle: "About Orb", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openAppSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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

        // Edit menu (required by AppKit + WKWebView for Cmd+Z, Shift+Cmd+Z, Cmd+X, Cmd+C, Cmd+V, Cmd+A).
        // Route explicitly through OrbAppDelegate with autoenablesItems disabled: WKWebView's
        // validateUserInterfaceItem(_:) inspects only the focused editable element's _editorState,
        // returning false for copy:/cut: whenever an empty <textarea> (Composer) retains focus while
        // the user selects non-editable transcript/page text — causing AppKit to swallow Cmd+C.
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = false
        let undoItem = NSMenuItem(title: "Undo", action: #selector(editUndo(_:)), keyEquivalent: "z")
        undoItem.target = self
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: #selector(editRedo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        let cutItem = NSMenuItem(title: "Cut", action: #selector(editCut(_:)), keyEquivalent: "x")
        cutItem.target = self
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(editCopy(_:)), keyEquivalent: "c")
        copyItem.target = self
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(editPaste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(editSelectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        editMenu.addItem(selectAllItem)
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let reloadItem = NSMenuItem(title: "Reload", action: #selector(viewReload(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenu.addItem(.separator())
        let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(viewActualSize(_:)), keyEquivalent: "0")
        actualSizeItem.target = self
        viewMenu.addItem(actualSizeItem)
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(viewZoomIn(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(viewZoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)
        viewMenuItem.submenu = viewMenu

        // Window menu
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openAppSettings(_ sender: Any?) {
        if let win = window, !win.isVisible {
            win.makeKeyAndOrderFront(nil)
        }
        webView?.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('orb:open-page',{detail:'settings'}));",
            completionHandler: nil
        )
    }

    @objc private func viewReload(_ sender: Any?) {
        webView?.reload()
    }

    @objc private func viewActualSize(_ sender: Any?) {
        webView?.pageZoom = 1.0
    }

    @objc private func viewZoomIn(_ sender: Any?) {
        guard let wv = webView else { return }
        wv.pageZoom = min(3.0, (wv.pageZoom * 10.0 + 1.0).rounded() / 10.0)
    }

    @objc private func viewZoomOut(_ sender: Any?) {
        guard let wv = webView else { return }
        wv.pageZoom = max(0.5, (wv.pageZoom * 10.0 - 1.0).rounded() / 10.0)
    }

    @discardableResult
    private func sendWebViewEditAction(_ action: Selector, from sender: Any?) -> Bool {
        if let win = window, win.attachedSheet == nil, let wv = webView {
            if win.firstResponder === win || win.firstResponder === win.contentView || win.firstResponder === vibrancyView {
                win.makeFirstResponder(wv)
            }
            if win.firstResponder === wv {
                // Walk the responder chain from WKWebView instead of forcing `to: wv`:
                // WKWebView implements cut:/copy:/paste:/selectAll: directly, whereas undo:/redo:
                // are implemented on NSWindow (delegating to `firstResponder?.undoManager`, i.e.
                // `wv.undoManager`). Passing `to: wv` without checking `responds(to:)` throws
                // NSInvalidArgumentException (`-[WKWebView undo:]: unrecognized selector`).
                var responder: NSResponder? = wv
                while let r = responder {
                    if r.responds(to: action) {
                        return NSApp.sendAction(action, to: r, from: sender)
                    }
                    responder = r.nextResponder
                }
                return false
            }
        }
        return NSApp.sendAction(action, to: nil, from: sender)
    }

    @objc private func editUndo(_ sender: Any?) { sendWebViewEditAction(Selector(("undo:")), from: sender) }
    @objc private func editRedo(_ sender: Any?) { sendWebViewEditAction(Selector(("redo:")), from: sender) }
    @objc private func editCut(_ sender: Any?) { sendWebViewEditAction(#selector(NSText.cut(_:)), from: sender) }
    @objc private func editCopy(_ sender: Any?) { sendWebViewEditAction(#selector(NSText.copy(_:)), from: sender) }
    @objc private func editPaste(_ sender: Any?) { sendWebViewEditAction(#selector(NSText.paste(_:)), from: sender) }
    @objc private func editSelectAll(_ sender: Any?) { sendWebViewEditAction(#selector(NSText.selectAll(_:)), from: sender) }

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

    private func emitToWebView(event: String, payload: Any) {
        let nameLit = Self.jsonStringLiteral(event)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__ORB_EMIT__&&window.__ORB_EMIT__(\(nameLit),\(json));", completionHandler: nil)
    }

    private static let skippedFolderNames: Set<String> = [
        ".git", "node_modules", ".lake", "target", ".DS_Store", "__pycache__", ".venv", ".next", "dist"
    ]

    static func walkFolderForUpload(folderURL: URL, prefixOverride: String? = nil) -> [[String: Any]] {
        let fm = FileManager.default
        let resolvedFolder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let baseName = prefixOverride ?? folderURL.lastPathComponent
        guard let enumerator = fm.enumerator(
            at: resolvedFolder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return [] }
        var out: [[String: Any]] = []
        let rootComponents = resolvedFolder.pathComponents
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

    private func handleFinderDrag(phase: String, urls: [URL], point: NSPoint) {
        let pos: [String: Double] = ["x": Double(point.x), "y": Double(point.y)]
        switch phase {
        case "enter":
            emitToWebView(event: "orb://drag-enter", payload: ["paths": urls.map(\.path), "position": pos])
        case "over":
            emitToWebView(event: "orb://drag-over", payload: ["paths": urls.map(\.path), "position": pos])
        case "leave":
            emitToWebView(event: "orb://drag-leave", payload: ["paths": [] as [String], "position": pos])
        case "drop":
            var filePaths: [String] = []
            var folderFiles: [[String: Any]] = []
            var folderRoots: [String] = []
            let fm = FileManager.default
            for u in urls {
                var isDir: ObjCBool = false
                let resolved = u.standardizedFileURL.resolvingSymlinksInPath()
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    folderRoots.append(resolved.path)
                    let walked = Self.walkFolderForUpload(folderURL: u)
                    let remaining = max(0, 4096 - folderFiles.count)
                    if remaining > 0 {
                        folderFiles.append(contentsOf: walked.prefix(remaining))
                    }
                } else {
                    filePaths.append(resolved.path)
                }
            }
            var dropPayload: [String: Any] = [
                "paths": filePaths,
                "x": Double(point.x),
                "y": Double(point.y)
            ]
            if !folderFiles.isEmpty {
                let batchId = UUID().uuidString.lowercased()
                dropPayload["folder"] = [
                    "batch": batchId,
                    "roots": folderRoots,
                    "files": folderFiles
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dropPayload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript(
                "window.__ORB_HANDLE_NATIVE_DROP__&&window.__ORB_HANDLE_NATIVE_DROP__(\(json));",
                completionHandler: nil
            )
        default:
            break
        }
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
            let appearance: NSAppearance?
            if theme == "dark" {
                appearance = NSAppearance(named: .darkAqua)
            } else if theme == "light" {
                appearance = NSAppearance(named: .aqua)
            } else {
                appearance = nil
            }
            window?.appearance = appearance
            vibrancyView?.appearance = appearance
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
                    let resolved = u.standardizedFileURL.resolvingSymlinksInPath()
                    return ["name": u.lastPathComponent, "path": resolved.path]
                }
                let filePaths = items.compactMap { $0["path"] }
                self.replyToWebView(id: reqId, result: ["files": items, "grants": filePaths])
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
                let resolvedRoot = folderURL.standardizedFileURL.resolvingSymlinksInPath()
                let batchId = UUID().uuidString.lowercased()
                let walked = Self.walkFolderForUpload(folderURL: folderURL)
                self.replyToWebView(id: reqId, result: [
                    "batch": batchId,
                    "root": resolvedRoot.path,
                    "files": walked
                ])
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
        case "mistral_usage_sign_in":
            let controller = OrbMistralSignInController { [weak self] cookie in
                self?.mistralSignIn = nil
                self?.replyToWebView(id: reqId, result: cookie)
            }
            self.mistralSignIn = controller
            controller.present()
        default:
            replyToWebView(id: reqId, result: nil, error: "Unsupported native UI command: \(cmd)")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil {
            if let u = navigationAction.request.url, Self.isSafeExternalOpenURL(u) {
                NSWorkspace.shared.open(u)
            }
            decisionHandler(.cancel)
            return
        }
        guard let u = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if Self.isConfinedShellURL(u) {
            decisionHandler(.allow)
        } else {
            if navigationAction.targetFrame?.isMainFrame == true, Self.isSafeExternalOpenURL(u) {
                NSWorkspace.shared.open(u)
            }
            decisionHandler(.cancel)
        }
    }

    // MARK: - WKUIDelegate (JavaScript dialogs + loopback/tauri microphone capture)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Orb"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let win = window, win.isVisible {
            alert.beginSheetModal(for: win) { _ in completionHandler() }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Orb"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let win = window, win.isVisible {
            alert.beginSheetModal(for: win) { resp in
                completionHandler(resp == .alertFirstButtonReturn)
            }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let proto = origin.protocol.lowercased()
        let host = origin.host.lowercased()
        let isConfinedOrigin = (proto == "tauri" && host == "localhost") ||
                               (proto == "http" && (host == "127.0.0.1" || host == "localhost"))
        if isConfinedOrigin && type == .microphone {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    static func buildInitScript(port: Int, token: String) -> String {
        let urlLit = Self.jsonStringLiteral("http://127.0.0.1:\(port)/__orb_rpc")
        let sseLit = Self.jsonStringLiteral("http://127.0.0.1:\(port)/__orb_events")
        let tokLit = Self.jsonStringLiteral(token)
        return """
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
          function emitEvent(name, payload) {
            const set = listeners.get(name);
            if (!set) return;
            for (const fn of Array.from(set)) {
              try { fn({ event: name, payload }); } catch {}
            }
          }
          window.__ORB_EMIT__ = emitEvent;
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
          function uint8ToBase64(bytes) {
            let bin = '';
            const chunk = 0x8000;
            for (let i = 0; i < bytes.length; i += chunk) {
              bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
            }
            return btoa(bin);
          }
          async function callLocald(command, args = {}) {
            let r;
            for (let attempt = 0; ; attempt++) {
              try {
                r = await _fetch(ORB_LOCALD_URL, {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },
                  body: _jsonStringify({ command, args })
                });
                break;
              } catch (err) {
                if (attempt >= 8) throw err;
                await new Promise((res) => setTimeout(res, 75));
              }
            }
            const b = await r.json();
            if (!r.ok || b.error) throw new Error(b.error || command);
            return b.result;
          }
          window.__ORB_HANDLE_NATIVE_DROP__ = async (drop) => {
            try {
              if (Array.isArray(drop?.paths) && drop.paths.length) {
                await callLocald('grant_upload_files', { paths: drop.paths });
              }
              if (drop?.folder?.batch) {
                await callLocald('offer_upload_folder', {
                  batch: drop.folder.batch,
                  roots: drop.folder.roots || [],
                  files: drop.folder.files || []
                });
              }
            } catch {}
            const folderOffer = drop?.folder
              ? { batch: drop.folder.batch, files: drop.folder.files || [] }
              : undefined;
            emitEvent('orb-upload-drop', {
              paths: Array.isArray(drop?.paths) ? drop.paths : [],
              ...(folderOffer ? { folder: folderOffer } : {}),
              x: Number(drop?.x) || 0,
              y: Number(drop?.y) || 0
            });
          };
          async function drain() {
            if (!channels.size) return;
            try {
              const res = await callLocald('__orb_poll_events', { tokens: Array.from(channels.keys()) });
              if (Array.isArray(res)) {
                for (const ev of res) {
                  if (typeof ev.event === 'string') emitEvent(ev.event, ev.payload);
                  else channels.get(ev.token)?.onmessage(ev.payload);
                }
              }
            } catch {}
          }
          function hasActiveStreams() {
            return channels.size > 0 || listeners.size > 0;
          }
          function stopStream() {
            if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; }
          }
          function ensureStream() {
            if (streamCtrl || !hasActiveStreams()) return;
            const ctrl = new AbortController();
            streamCtrl = ctrl;
            (async () => {
              while (!ctrl.signal.aborted && hasActiveStreams()) {
                try {
                  const r = await _fetch(ORB_EVENTS_URL, {
                    headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN },
                    signal: ctrl.signal
                  });
                  if (!r.ok || !r.body) throw new Error('sse');
                  const reader = r.body.getReader();
                  const dec = new TextDecoder();
                  let buf = '';
                  while (!ctrl.signal.aborted && hasActiveStreams()) {
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
                          if (Array.isArray(arr)) {
                            for (const ev of arr) {
                              if (typeof ev.event === 'string') emitEvent(ev.event, ev.payload);
                              else channels.get(ev.token)?.onmessage(ev.payload);
                            }
                          }
                        }
                      }
                    }
                  }
                } catch {
                  if (ctrl.signal.aborted || !hasActiveStreams()) break;
                  await new Promise(res => setTimeout(res, 1500));
                  if (!ctrl.signal.aborted && channels.size) await drain();
                }
              }
              if (streamCtrl === ctrl) streamCtrl = null;
            })();
          }
          async function invoke(command, args = {}, options = {}) {
            const isBinary = (args instanceof Uint8Array) || (args instanceof ArrayBuffer);
            const clean = isBinary
              ? {
                  __binaryBase64: uint8ToBase64(args instanceof Uint8Array ? args : new Uint8Array(args)),
                  __headers: (options && options.headers) ? options.headers : {}
                }
              : { ...(args || {}) };
            if (!isBinary && options && options.headers && clean.__headers === undefined) {
              clean.__headers = options.headers;
            }
            if (_postNative) {
              if (command === 'set_window_theme') return callNativeUI('set_window_theme', clean);
              if (command === 'pick_working_directory') {
                const dir = await callNativeUI('pick_working_directory', clean);
                if (typeof dir === 'string' && dir) {
                  try { await callLocald('grant_browse_root', { path: dir }); } catch {}
                }
                return dir;
              }
              if (command === 'pick_upload_files') {
                const picked = await callNativeUI('pick_upload_files', clean);
                const grants = Array.isArray(picked?.grants) ? picked.grants : [];
                if (grants.length) await callLocald('grant_upload_files', { paths: grants });
                return Array.isArray(picked?.files) ? picked.files : [];
              }
              if (command === 'pick_upload_folder') {
                const offer = await callNativeUI('pick_upload_folder', clean);
                if (offer?.batch) {
                  await callLocald('offer_upload_folder', {
                    batch: offer.batch,
                    roots: offer.root ? [offer.root] : [],
                    files: offer.files || []
                  });
                }
                return offer ? { batch: offer.batch, files: offer.files || [] } : { batch: null, files: [] };
              }
              if (command === 'save_file_as' && !clean.destPath) {
                const destPath = await callNativeUI('save_file_prompt', { name: clean.name || '' });
                if (!destPath) return null;
                return callLocald('save_file_as', { destPath, dataBase64: clean.dataBase64 || '' });
              }
              if (command === 'mistral_usage_sign_in') {
                return callNativeUI('mistral_usage_sign_in', clean);
              }
            }
            let bound = null;
            if (!isBinary && clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; }
            if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') {
              channels.delete(clean.token);
              if (!hasActiveStreams()) stopStream();
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
            ensureStream();
            return () => {
              listeners.get(n)?.delete(h);
              if (listeners.get(n)?.size === 0) listeners.delete(n);
              if (!hasActiveStreams()) stopStream();
            };
          }
          const desktop = {
            core: { invoke, Channel },
            event: { listen },
            window: { getCurrentWindow: () => ({
              innerSize: async () => { const s = window.devicePixelRatio || 1; return { width: Math.round(window.innerWidth * s), height: Math.round(window.innerHeight * s) }; },
              scaleFactor: async () => window.devicePixelRatio || 1
            }) },
            webview: { getCurrentWebview: () => ({ label: 'main' }) }
          };
          window.__ORB_DESKTOP__ = desktop;
          window.__TAURI_INTERNALS__ = { invoke };
          window.__TAURI__ = desktop;
        })();
        """
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installTerminationSignalHandlers()
        let env = ProcessInfo.processInfo.environment
        let explicitPortEnv = env["ORB_LOCALD_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawPort = Int(explicitPortEnv) ?? 19479
        let preferredPort = (1024...65535).contains(rawPort) ? rawPort : 19479
        let port = explicitPortEnv.isEmpty ? Self.selectAvailableLoopbackPort(preferred: preferredPort) : preferredPort
        let envTok = env["ORB_LOCALD_TOKEN"] ?? ""
        let token = (envTok.utf8.count >= 32 && envTok != "orb-locald-default-token") ? envTok : Self.randomHex256()

        let bundledLocald = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orb-locald")
        let bundledSigner = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orb-signer")
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
                "ORB_LOCALD_TOKEN": token,
                "ORB_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
            ]
            if let bundleVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !bundleVer.isEmpty {
                childEnv["ORB_APP_VERSION"] = bundleVer
            } else if let envVer = env["ORB_APP_VERSION"], !envVer.isEmpty {
                childEnv["ORB_APP_VERSION"] = envVer
            }
            for k in ["HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH", "ORB_STATE_DIR", "ORB_VOICE_PYTHON", "ORB_VOICE_MODEL_DIR", "ORB_VOICE_FAKE"] {
                if let v = env[k] { childEnv[k] = v }
            }
            if childEnv["ORB_SIGNER_BIN"] == nil,
               let s = bundledSigner, FileManager.default.isExecutableFile(atPath: s.path) {
                childEnv["ORB_SIGNER_BIN"] = s.path
            }
            p.environment = childEnv
            try? p.run()
            self.localdProc = p
        }

        let initJs = Self.buildInitScript(port: port, token: token)

        let cfg = WKWebViewConfiguration()
        // Keep the desktop shell's layer backing store and live sync active when occluded:
        // under memory pressure, WebKit's background page-visibility suppression marks remote
        // layer tiles volatile (`FailedToAcquireBufferSpan`), leaving non-isolated regions blank.
        Self.setBoolPreference(cfg.preferences, selector: "_setPageVisibilityBasedProcessSuppressionEnabled:", value: false)
        Self.setBoolPreference(cfg.preferences, selector: "_setHiddenPageDOMTimerThrottlingEnabled:", value: false)
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
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        // Place NSVisualEffectView as a sibling behind WKWebView inside a plain container NSView
        // (matching AppKit/window-vibrancy requirements: never host WKWebView inside NSVisualEffectView,
        // which propagates vibrant CAFilter group-blending into WebKit's non-isolated tile layers).
        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]
        let vibrancy = NSVisualEffectView(frame: rect)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        self.vibrancyView = vibrancy
        webView = OrbWebView(frame: rect, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if env["ORB_DEV_URL"] != nil || env["ORB_WEB_INSPECTOR"] == "1" {
            if #available(macOS 13.3, *) {
                webView.isInspectable = true
            }
        }
        webView.onFinderDragEvent = { [weak self] phase, urls, pt in
            self?.handleFinderDrag(phase: phase, urls: urls, point: pt)
        }
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        container.addSubview(vibrancy)
        container.addSubview(webView, positioned: .above, relativeTo: vibrancy)
        window.contentView = container
        window.initialFirstResponder = webView
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        layoutTrafficLights()
        window.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
        if let devUrl = env["ORB_DEV_URL"], let u = URL(string: devUrl), Self.isConfinedShellURL(u) {
            webView.load(URLRequest(url: u))
        } else if let u = URL(string: "tauri://localhost/") {
            webView.load(URLRequest(url: u))
        } else if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let win = window, win.attachedSheet == nil, let wv = webView,
           win.firstResponder === win || win.firstResponder === win.contentView || win.firstResponder === vibrancyView {
            win.makeFirstResponder(wv)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localdProc?.terminate()
    }

    fileprivate func runSelfTest() {
        let allowed = ["tauri://localhost/", "tauri://localhost/index.html", "http://127.0.0.1:19479/", "http://localhost:1430/", "file:///tmp/index.html", "about:blank"]
        for raw in allowed {
            guard let u = URL(string: raw), Self.isConfinedShellURL(u) else {
                fputs("self-test failed: expected confined URL to be allowed: \(raw)\n", stderr)
                exit(1)
            }
        }
        let denied = ["https://example.com/", "http://example.com/", "tauri://evil.example/", "javascript:alert(1)"]
        for raw in denied {
            if let u = URL(string: raw), Self.isConfinedShellURL(u) {
                fputs("self-test failed: expected external URL to be rejected: \(raw)\n", stderr)
                exit(1)
            }
        }
        guard let extHttps = URL(string: "https://example.com/docs"), Self.isSafeExternalOpenURL(extHttps),
              let extMail = URL(string: "mailto:test@example.com"), Self.isSafeExternalOpenURL(extMail),
              let badJs = URL(string: "javascript:alert(1)"), !Self.isSafeExternalOpenURL(badJs) else {
            fputs("self-test failed: external open URL safety filter mismatch\n", stderr)
            exit(1)
        }

        let initJs = Self.buildInitScript(port: 19479, token: "0123456789abcdef0123456789abcdef")
        for needle in ["__ORB_EMIT__", "__ORB_HANDLE_NATIVE_DROP__", "__binaryBase64", "offer_upload_folder", "mistral_usage_sign_in", "window.innerWidth * s"] {
            guard initJs.contains(needle) else {
                fputs("self-test failed: init script missing \(needle)\n", stderr)
                exit(1)
            }
        }

        installMainMenu()
        let rect = NSRect(x: 0, y: 0, width: 320, height: 240)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: rect)
        let vibrancy = NSVisualEffectView(frame: rect)
        vibrancyView = vibrancy
        webView = OrbWebView(frame: rect)
        webView.uiDelegate = self
        container.addSubview(vibrancy)
        container.addSubview(webView, positioned: .above, relativeTo: vibrancy)
        window.contentView = container
        window.makeFirstResponder(webView)

        // Verify Dock reopen restores hidden window
        window.orderOut(nil)
        guard applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) else {
            fputs("self-test failed: applicationShouldHandleReopen returned false\n", stderr)
            exit(1)
        }

        // Verify App, Edit, View, Window menus
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              appMenu.item(withTitle: "Settings…") != nil else {
            fputs("self-test failed: missing Settings… menu item\n", stderr)
            exit(1)
        }
        guard let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu,
              viewMenu.item(withTitle: "Reload") != nil,
              viewMenu.item(withTitle: "Actual Size") != nil,
              viewMenu.item(withTitle: "Zoom In") != nil,
              viewMenu.item(withTitle: "Zoom Out") != nil,
              viewMenu.item(withTitle: "Toggle Full Screen") != nil else {
            fputs("self-test failed: missing View menu items\n", stderr)
            exit(1)
        }

        guard let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu ?? NSApp.mainMenu?.items.dropFirst().first?.submenu else {
            fputs("self-test failed: missing Edit menu\n", stderr)
            exit(1)
        }
        let expectedTitles: Set<String> = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
        var exercised = Set<String>()
        for initialResponder in [webView as NSResponder, window as NSResponder, container as NSResponder, vibrancy as NSResponder] {
            window.makeFirstResponder(initialResponder)
            for item in editMenu.items where !item.isSeparatorItem {
                guard let action = item.action else {
                    fputs("self-test failed: missing action on menu item \(item.title)\n", stderr)
                    exit(1)
                }
                guard NSApp.sendAction(action, to: item.target, from: item) else {
                    fputs("self-test failed: menu item \(item.title) action was not handled\n", stderr)
                    exit(1)
                }
                guard window.firstResponder === webView else {
                    fputs("self-test failed: expected WKWebView to be firstResponder after \(item.title)\n", stderr)
                    exit(1)
                }
                exercised.insert(item.title)
            }
        }
        guard exercised == expectedTitles else {
            fputs("self-test failed: exercised \(exercised), expected \(expectedTitles)\n", stderr)
            exit(1)
        }
        for sel in [Selector(("undo:")), Selector(("redo:")), #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))] {
            guard sendWebViewEditAction(sel, from: nil) else {
                fputs("self-test failed: sendWebViewEditAction(\(sel)) returned false\n", stderr)
                exit(1)
            }
        }

        // Verify loopback port conflict fallback when another process already holds the preferred port.
        let busyFd = socket(AF_INET, SOCK_STREAM, 0)
        guard busyFd >= 0 else {
            fputs("self-test failed: socket() failed\n", stderr)
            exit(1)
        }
        defer { close(busyFd) }
        var busyAddr = sockaddr_in()
        busyAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        busyAddr.sin_family = sa_family_t(AF_INET)
        busyAddr.sin_port = 0
        busyAddr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let boundBusy = withUnsafePointer(to: &busyAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(busyFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedBusy = boundBusy && withUnsafeMutablePointer(to: &busyAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(busyFd, $0, &addrLen) == 0
            }
        } && listen(busyFd, 4) == 0
        guard namedBusy else {
            fputs("self-test failed: could not bind busy loopback socket\n", stderr)
            exit(1)
        }
        let occupiedPort = Int(UInt16(bigEndian: busyAddr.sin_port))
        guard !Self.canBindLoopbackPort(occupiedPort) else {
            fputs("self-test failed: expected occupied loopback port \(occupiedPort) to fail bind check\n", stderr)
            exit(1)
        }
        let fallbackPort = Self.selectAvailableLoopbackPort(preferred: occupiedPort)
        guard fallbackPort != occupiedPort, (1024...65520).contains(fallbackPort), Self.canBindLoopbackPort(fallbackPort) else {
            fputs("self-test failed: selectAvailableLoopbackPort(\(occupiedPort)) chose invalid port \(fallbackPort)\n", stderr)
            exit(1)
        }
    }
}

let app = NSApplication.shared
let delegate = OrbAppDelegate()
if CommandLine.arguments.contains("--self-test") {
    app.setActivationPolicy(.prohibited)
    delegate.runSelfTest()
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
