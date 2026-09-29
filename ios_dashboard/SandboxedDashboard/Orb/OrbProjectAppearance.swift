import SwiftUI
import UIKit

/// Same palette, default and per-device storage as desktop `projectAppearance.ts`.
@MainActor @Observable
final class OrbProjectAppearance {
    struct Choice: Identifiable, Hashable {
        let name: String
        let value: String
        var id: String { value }
    }
    static let colors = [
        Choice(name: "Default", value: ""), Choice(name: "Blue", value: "#8aaed4"),
        Choice(name: "Green", value: "#94b89a"), Choice(name: "Amber", value: "#c5aa70"),
        Choice(name: "Rose", value: "#cb929f"), Choice(name: "Purple", value: "#ad9acb"),
    ]
    static let shared = OrbProjectAppearance()
    private let defaults: UserDefaults
    private let endpoint: @MainActor () -> String
    /// UserDefaults is not observable; every read depends on this counter instead.
    private var revision = 0
    init(defaults: UserDefaults = .standard, endpoint: @escaping @MainActor () -> String = { OrbCore.shared.endpoint }) {
        self.defaults = defaults
        self.endpoint = endpoint
    }
    static func key(endpoint: String, slug: String) -> String { "orb.projectColor:\(endpoint):\(slug)" }
    /// The stored palette value, or "" (Default) when nothing valid is stored.
    func value(_ slug: String) -> String {
        _ = revision
        let stored = defaults.string(forKey: Self.key(endpoint: endpoint(), slug: slug)) ?? ""
        return Self.colors.contains(where: { $0.value == stored }) ? stored : ""
    }
    func color(_ slug: String) -> Color? { Self.color(value(slug)) }
    func set(_ slug: String, _ value: String) {
        guard Self.colors.contains(where: { $0.value == value }) else { return }
        let key = Self.key(endpoint: endpoint(), slug: slug)
        if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        revision += 1
    }
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
