import SwiftUI
import UIKit

/// Same palette and sync rules as desktop `projectAppearance.ts`: the server
/// stores the color by palette name, this device keeps the hex value, which is
/// what is shown until the roster answers and all there is on a backend
/// without the field.
@MainActor @Observable
final class OrbProjectAppearance {
    struct Choice: Identifiable, Hashable {
        let name: String
        let value: String
        var id: String { value }
    }
    typealias Send = @MainActor (_ slug: String, _ color: String?) async throws -> Void
    static let colors = [
        Choice(name: "Default", value: ""), Choice(name: "Blue", value: "#8aaed4"),
        Choice(name: "Green", value: "#94b89a"), Choice(name: "Amber", value: "#c5aa70"),
        Choice(name: "Rose", value: "#cb929f"), Choice(name: "Purple", value: "#ad9acb"),
    ]
    static let shared = OrbProjectAppearance()
    private let defaults: UserDefaults
    private let endpoint: @MainActor () -> String
    private let send: Send
    /// UserDefaults is not observable; every read depends on this counter instead.
    private var revision = 0
    /// Backends seen answering without the field: writes to them are skipped.
    private var unsupported: Set<String> = []
    private var supported: Set<String> = []
    /// Last local change per project, so a roster requested before it cannot undo it.
    private var changedAt: [String: Date] = [:]
    private var sending: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    init(defaults: UserDefaults = .standard, endpoint: @escaping @MainActor () -> String = { OrbCore.shared.endpoint },
         send: @escaping Send = { slug, color in
             _ = try await OrbCore.shared.call("/api/projects/\(OrbCore.escape(slug))/appearance", method: "POST", body: .object(["color": color.map(OrbJSON.string) ?? .null]))
         }) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.send = send
    }
    static func key(endpoint: String, slug: String) -> String { "orb.projectColor:\(endpoint):\(slug)" }
    /// "1": the server has this device's value. "pending": a change it has not received yet.
    static func syncKey(endpoint: String, slug: String) -> String { "orb.projectColorSync:\(endpoint):\(slug)" }
    /// The name the server stores for a palette value; nil for Default.
    static func wireName(_ value: String) -> String? { colors.first { !$0.value.isEmpty && $0.value == value }?.name.lowercased() }
    static func value(wireName: String) -> String? {
        let name = wireName.trimmingCharacters(in: .whitespaces).lowercased()
        return colors.first { !$0.value.isEmpty && $0.name.lowercased() == name }?.value
    }
    /// Whether the connected backend is known to store colors, so they follow the operator to other devices.
    var synced: Bool { _ = revision; return supported.contains(endpoint()) }
    private func stored(_ slug: String, at endpoint: String) -> String {
        let stored = defaults.string(forKey: Self.key(endpoint: endpoint, slug: slug)) ?? ""
        return Self.colors.contains(where: { $0.value == stored }) ? stored : ""
    }
    private func store(_ value: String, slug: String, at endpoint: String) {
        let key = Self.key(endpoint: endpoint, slug: slug)
        if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }
    /// The stored palette value, or "" (Default) when nothing valid is stored.
    func value(_ slug: String) -> String {
        _ = revision
        return stored(slug, at: endpoint())
    }
    func color(_ slug: String) -> Color? { Self.color(value(slug)) }
    func set(_ slug: String, _ value: String) {
        guard Self.colors.contains(where: { $0.value == value }) else { return }
        let endpoint = endpoint()
        store(value, slug: slug, at: endpoint)
        defaults.set("pending", forKey: Self.syncKey(endpoint: endpoint, slug: slug))
        changedAt["\(endpoint):\(slug)"] = Date()
        revision += 1
        _ = upload(slug, at: endpoint)
    }
    /// Write this device's value to the server. A failure keeps it pending for the next roster.
    @discardableResult
    private func upload(_ slug: String, at endpoint: String) -> Task<Void, Never>? {
        let id = "\(endpoint):\(slug)"
        guard !unsupported.contains(endpoint), endpoint == self.endpoint() else { return nil }
        let running = sending[id]?.task, token = UUID()
        let task = Task { @MainActor [weak self] in
            // A change made during a write goes out after it, so the last one wins.
            await running?.value
            guard let self else { return }
            defer { if self.sending[id]?.token == token { self.sending[id] = nil } }
            let syncKey = Self.syncKey(endpoint: endpoint, slug: slug)
            guard self.defaults.string(forKey: syncKey) == "pending", endpoint == self.endpoint() else { return }
            let value = self.stored(slug, at: endpoint)
            do {
                try await self.send(slug, Self.wireName(value))
                self.changedAt[id] = Date()
                if self.stored(slug, at: endpoint) == value { self.defaults.set("1", forKey: syncKey) }
            } catch { /* older backend or offline: the local value keeps working */ }
        }
        sending[id] = (token, task)
        return task
    }
    /// Apply a roster answer: the server value wins, the local one is the fallback.
    /// Returns once the writes it started have finished.
    func apply(roster rows: [OrbJSON], fetchedAt: Date = Date(), endpoint: String? = nil) async {
        let endpoint = endpoint ?? self.endpoint()
        guard endpoint == self.endpoint() else { return }
        let known: [(slug: String, color: OrbJSON)] = rows.compactMap { row in
            guard case .object(let fields) = row, case .string(let slug)? = fields["slug"], let color = fields["color"] else { return nil }
            return (slug, color)
        }
        if known.isEmpty {
            if !rows.isEmpty { unsupported.insert(endpoint); if supported.remove(endpoint) != nil { revision += 1 } }
            return
        }
        unsupported.remove(endpoint)
        var changed = supported.insert(endpoint).inserted
        var writes: [Task<Void, Never>] = []
        for row in known {
            let id = "\(endpoint):\(row.slug)", syncKey = Self.syncKey(endpoint: endpoint, slug: row.slug)
            let state = defaults.string(forKey: syncKey), local = stored(row.slug, at: endpoint)
            if sending[id] != nil { continue }
            if let at = changedAt[id], at >= fetchedAt { continue }
            if state == "pending" { if let task = upload(row.slug, at: endpoint) { writes.append(task) }; continue }
            let server: String
            switch row.color {
            case .null: server = ""
            case .string(let name):
                // A name this build does not know: leave both sides as they are.
                guard let value = Self.value(wireName: name) else { continue }
                server = value
            default: continue
            }
            // First contact with a color chosen before the server stored any: upload it once.
            if server.isEmpty, !local.isEmpty, state != "1" {
                defaults.set("pending", forKey: syncKey)
                if let task = upload(row.slug, at: endpoint) { writes.append(task) }
                continue
            }
            if server != local { store(server, slug: row.slug, at: endpoint); changed = true }
            if state != "1", !server.isEmpty { defaults.set("1", forKey: syncKey) }
        }
        if changed { revision += 1 }
        for task in writes { await task.value }
    }
    /// Waits for the writes in flight; tests use it to observe their outcome.
    func settle() async { for entry in Array(sending.values) { await entry.task.value } }
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(rgb >> 16 & 0xff) / 255, Double(rgb >> 8 & 0xff) / 255, Double(rgb & 0xff) / 255)
    }
    static func color(_ hex: String) -> Color? { components(hex).map { Color(red: $0.red, green: $0.green, blue: $0.blue) } }
}

/// Menus draw template images; an original-mode image keeps the swatch color.
struct OrbProjectColorMenu: View {
    let project: String
    private let appearance = OrbProjectAppearance.shared
    var body: some View {
        Menu {
            Picker("Project color", selection: Binding(get: { appearance.value(project) }, set: { appearance.set(project, $0) })) {
                ForEach(OrbProjectAppearance.colors) { choice in
                    Label { Text(choice.name) } icon: { Image(uiImage: Self.swatch(choice.value)) }.tag(choice.value)
                }
            }
        } label: { Label("Project color", systemImage: "paintpalette") }
            .accessibilityIdentifier("project-color")
    }
    static func swatch(_ value: String) -> UIImage {
        let color = OrbProjectAppearance.color(value) ?? OrbStyle.icon
        return (UIImage(systemName: "circle.fill") ?? UIImage()).withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
}
