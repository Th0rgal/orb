import SwiftUI

/// Every settings operation belongs to one connection, including multi-step OAuth flows.
@MainActor
struct OrbSettingsClient {
    let endpoint: String
    let generation: Int
    init() { endpoint = OrbCore.shared.endpoint; generation = OrbCore.shared.connectionGeneration }
    var current: Bool { endpoint == OrbCore.shared.endpoint && generation == OrbCore.shared.connectionGeneration }
    func call(_ path: String, method: String = "GET", body: OrbJSON? = nil) async throws -> OrbJSON {
        guard current else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try await OrbCore.shared.call(path, method: method, body: body)
        guard current else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
}

struct OrbSettingsHome: View {
    let onBackendChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { SetupSheet(onComplete: onBackendChanged, allowsDismissal: true, embedded: true) } label: {
                    Label("Backend", systemImage: "server.rack")
                }.accessibilityIdentifier("settings.backend")
                NavigationLink { OrbProvidersSettings() } label: { Label("Providers", systemImage: "key.horizontal") }
                    .accessibilityIdentifier("settings.providers")
                NavigationLink { OrbBitwardenSettings() } label: { Label("Secrets", systemImage: "lock.shield") }
                    .accessibilityIdentifier("settings.secrets")
                NavigationLink { OrbMissionAccessList().navigationTitle("Mission access").navigationBarTitleDisplayMode(.inline) } label: { Label("Mission access", systemImage: "eye") }
                    .accessibilityIdentifier("settings.mission-access")
                NavigationLink { OrbRoutingSettings() } label: { Label("Models & Routing", systemImage: "arrow.triangle.swap") }
                    .accessibilityIdentifier("settings.routing")
                NavigationLink { OrbProxyKeysSettings() } label: { Label("Proxy API keys", systemImage: "key") }
                    .accessibilityIdentifier("settings.proxy-keys")
                NavigationLink { OrbSkillsSettings() } label: { Label("Skills", systemImage: "book.closed") }
                    .accessibilityIdentifier("settings.skills")
                NavigationLink { OrbHermesSettings() } label: { Label("Hermes", systemImage: "bubble.left.and.bubble.right") }
                    .accessibilityIdentifier("settings.hermes")
                NavigationLink { OrbBtwSettingsView() } label: { Label("Side questions", systemImage: "bubble.left.and.text.bubble.right") }
                    .accessibilityIdentifier("settings.btw")
                NavigationLink { OrbMachinesSettings() } label: { Label("Machines", systemImage: "desktopcomputer") }
                    .accessibilityIdentifier("settings.machines")
                NavigationLink { OrbInboxSettingsView() } label: { Label("Inbox", systemImage: "tray.full") }
                    .accessibilityIdentifier("settings.inbox")
                NavigationLink { OrbDictationSettingsView() } label: { Label("Dictation", systemImage: "mic") }
                    .accessibilityIdentifier("settings.dictation")
                NavigationLink { OrbDebugInfoView() } label: { Label("Debug info", systemImage: "ladybug") }
                    .accessibilityIdentifier("settings.debug")
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .id(OrbCore.shared.connectionGeneration)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

extension OrbJSON {
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var display: String { if let number { return number.formatted(.number.precision(.fractionLength(0...1))) }; return text }
}

struct OrbSettingsError: View {
    let message: String
    var body: some View { if !message.isEmpty { Section { Text(message).foregroundStyle(.orange).accessibilityIdentifier("settings.error") } } }
}
