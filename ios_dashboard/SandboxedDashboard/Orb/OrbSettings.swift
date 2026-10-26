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
    func callText(_ path: String, method: String = "GET", body: OrbJSON? = nil) async throws -> String {
        guard current else { throw CancellationError() }
        let result = try await OrbCore.shared.callText(path, method: method, body: body)
        guard current else { throw CancellationError() }
        return result
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
