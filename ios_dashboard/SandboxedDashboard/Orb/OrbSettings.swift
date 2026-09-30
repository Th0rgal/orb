import SwiftUI

/// Every settings operation belongs to one connection, including multi-step OAuth flows.
@MainActor
struct OrbSettingsClient {
    let endpoint: String
    let generation: Int
    init() { endpoint = OrbCore.shared.endpoint; generation = APIService.shared.connectionGeneration }
    var current: Bool { endpoint == OrbCore.shared.endpoint && generation == APIService.shared.connectionGeneration }
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
                NavigationLink { OrbMachinesSettings() } label: { Label("Machines", systemImage: "desktopcomputer") }
                    .accessibilityIdentifier("settings.machines")
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .id(APIService.shared.connectionGeneration)
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
