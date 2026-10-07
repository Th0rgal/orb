import Foundation
import OrbLocalKit
import UIKit
import UserNotifications

/// Executes agent actions with public iOS APIs only. Anything iOS does not
/// allow comes back as an explicit refusal with a usable alternative.
final class OrbIOSActionExecutor: IOSActionExecutor, @unchecked Sendable {
    static let shared = OrbIOSActionExecutor()
    let registry: AppRegistry
    private let keyboard: KeyboardCommandQueue?

    private init() {
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orb/app-observations.json")
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        registry = AppRegistry(store: store)
        keyboard = OrbAppGroup.keyboard.map(KeyboardCommandQueue.init(root:))
    }

    @MainActor var capabilities: DeviceCapabilities {
        DeviceCapabilities(
            localAgents: true,
            unixShell: orb_linux_linked() == 1 && ISHLinuxRuntime.shared.installed,
            screenObservation: ScreenObservationService.shared.isBroadcasting,
            keyboardInjection: keyboard?.presence() != nil,
            backgroundAppOpen: UserDefaults.standard.object(forKey: "orb.probe.backgroundOpen") as? Bool)
    }

    func perform(_ action: IOSComputerAction) async -> ComputerActionResult {
        switch action {
        case .capabilities:
            let report = await MainActor.run { capabilities.agentReport }
            return .init(ok: true, detail: report)
        case .screenshot(let max):
            return await screenshot(maxDimension: max)
        case .observe(let since):
            guard let frame = await ScreenObservationService.shared.nextFrame(after: since) else { return noScreen() }
            return .init(ok: true, detail: ["ok": true, "changed": .bool(since.map { frame.sequence > $0 } ?? true)], frame: frame)
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(30, seconds)) * 1_000_000_000))
            return await screenshot(maxDimension: nil)
        case .openURL(let raw):
            guard let url = URL(string: raw), url.scheme != nil else { return .refused("Invalid URL \(raw)") }
            return await open(url, app: nil)
        case .openApp(let target):
            guard let entry = registry.entry(target) else {
                return .refused("Unknown app \(target)", alternative: "Call list_apps, or open_url with the app's documented URL scheme or a universal link.")
            }
            guard let launch = entry.launchURL, let url = URL(string: launch) else {
                return .refused("\(entry.name) has no launch URL", alternative: "Use one of its app_action entries.")
            }
            return await open(url, app: entry.id)
        case .appAction(let app, let name, let parameters):
            do {
                let url = try registry.url(app: app, action: name, parameters: parameters)
                let result = await open(url, app: registry.entry(app)?.id)
                if let id = registry.entry(app)?.id { registry.observe(id) { $0.verifiedActions[name] = result.ok } }
                return result
            } catch {
                return .refused(error.localizedDescription)
            }
        case .listApps:
            await probeInstalled()
            return .init(ok: true, detail: ["apps": registry.listing])
        case .runShortcut(let name, let input):
            var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
            components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "x-success", value: "orb://shortcut/done"),
                                     URLQueryItem(name: "x-error", value: "orb://shortcut/error")]
            if let input { components.queryItems! += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)] }
            return await open(components.url!, app: "shortcuts")
        case .typeText(let text):
            return await keyboardCommand(KeyboardCommand(kind: .insert, text: text))
        case .keyboardDelete(let count):
            return await keyboardCommand(KeyboardCommand(kind: .delete, count: count))
        case .keyboardReturn:
            return await keyboardCommand(KeyboardCommand(kind: .return))
        case .keyboardContext:
            return await keyboardCommand(KeyboardCommand(kind: .context))
        case .clipboardSet(let text):
            await MainActor.run { UIPasteboard.general.string = text }
            return .init(ok: true, detail: ["ok": true, "note": "Paste requires the user (or the Orb keyboard type_text) in the target app."])
        case .clipboardGet:
            let text = await MainActor.run { UIPasteboard.general.string }
            return .init(ok: text != nil, detail: ["ok": .bool(text != nil), "text": text.map(JSONValue.string) ?? .null])
        case .share(let text, let url):
            return await share(text: text, url: url)
        }
    }

    private func noScreen() -> ComputerActionResult {
        .refused("No screen frame is available.", alternative: "Ask the user to start Orb Screen sharing (Control Center → Screen Recording → Orb Screen), or work from deep-link results.")
    }

    private func screenshot(maxDimension: Int?) async -> ComputerActionResult {
        guard let frame = await ScreenObservationService.shared.latestFrame(maxDimension: maxDimension) else { return noScreen() }
        var detail: [String: JSONValue] = ["ok": true]
        if frame.source == "in_app" { detail["warning"] = "Screen broadcast is off: this frame shows Orb only, not other apps." }
        return .init(ok: true, detail: .object(detail), frame: frame)
    }

    /// `UIApplication.open` with an honest result. When Orb is not in the
    /// foreground iOS may refuse; the probe records what this device does and
    /// a notification lets the user continue with one tap.
    private func open(_ url: URL, app: String?) async -> ComputerActionResult {
        let state = await MainActor.run { UIApplication.shared.applicationState }
        let opened = await openOnMain(url)
        if let app { registry.observe(app) { $0.lastOpenSucceeded = opened; $0.lastOpenedAt = Date(); if opened { $0.installed = true } } }
        if state != .active { UserDefaults.standard.set(opened, forKey: "orb.probe.backgroundOpen") }
        if opened {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let shot = await screenshot(maxDimension: nil)
            return .init(ok: true, detail: ["ok": true, "opened": .string(url.absoluteString)], frame: shot.frame)
        }
        if state != .active { await notifyToContinue(url) }
        return .refused(state == .active ? "iOS could not open \(url.absoluteString) (app missing or URL unsupported)."
                                         : "iOS refused to open \(url.absoluteString) while Orb is in the background.",
                        alternative: state == .active ? "Check list_apps or use a universal https link." : "Orb posted a notification; the user can tap it to continue.")
    }

    @MainActor private func openOnMain(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }

    private func notifyToContinue(_ url: URL) async {
        let content = UNMutableNotificationContent()
        content.title = "Orb agent wants to open an app"
        content.body = url.host ?? url.absoluteString
        content.userInfo = ["orb_open_url": url.absoluteString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func keyboardCommand(_ command: KeyboardCommand) async -> ComputerActionResult {
        guard let keyboard else { return .refused("App Group unavailable", alternative: nil) }
        guard keyboard.presence()?.isActive() == true else {
            return .refused("The Orb keyboard is not the active keyboard in a focused text field.",
                            alternative: "Prefill text via a URL (sms:&body=, mailto:?body=, maps://?q=) or clipboard_set, or ask the user to tap a field and switch to the Orb keyboard (globe key).")
        }
        do { try keyboard.enqueue(command) } catch { return .refused(error.localizedDescription) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(KeyboardCommandQueue.commandNotification as CFString), nil, nil, true)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let result = keyboard.result(for: command.id) {
                let detail: JSONValue = ["ok": .bool(result.ok), "reason": result.reason.map(JSONValue.string) ?? .null,
                                         "before_cursor": result.before.map(JSONValue.string) ?? .null,
                                         "after_cursor": result.after.map(JSONValue.string) ?? .null,
                                         "keyboard_type": result.keyboardType.map { .number(Double($0)) } ?? .null]
                if command.kind == .context { return .init(ok: result.ok, detail: detail) }
                let shot = await screenshot(maxDimension: nil)
                return .init(ok: result.ok, detail: detail, frame: shot.frame)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        keyboard.cancel(command.id)
        return .refused("The Orb keyboard did not respond (it may have been dismissed).", alternative: "Take a screenshot and retry once a field is focused.")
    }

    @MainActor private func share(text: String?, url: String?) async -> ComputerActionResult {
        guard UIApplication.shared.applicationState == .active,
              let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        else { return .refused("The share sheet needs Orb in the foreground.") }
        var items: [Any] = []
        if let text { items.append(text) }
        if let url, let u = URL(string: url) { items.append(u) }
        guard !items.isEmpty else { return .refused("Nothing to share") }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
        return .init(ok: true, detail: ["ok": true, "note": "Share sheet shown; the user picks the destination."])
    }

    /// `canOpenURL` only answers for schemes in LSApplicationQueriesSchemes.
    @MainActor private func probeInstalled() async {
        for entry in registry.entries {
            guard let scheme = entry.probeScheme, let url = URL(string: "\(scheme)://") else { continue }
            let installed = UIApplication.shared.canOpenURL(url)
            registry.observe(entry.id) { $0.installed = installed }
        }
    }
}
