//
//  FidoApprovalState.swift
//  SandboxedDashboard
//
//  Observable state for FIDO signing approval with auto-approval rules
//

import Foundation
import LocalAuthentication
import Observation

@MainActor
@Observable
final class FidoApprovalState {
    static let shared = FidoApprovalState()

    var pendingRequests: [FidoSignRequest] = []

    /// Set of request IDs for which an approve/deny request is currently in
    /// flight to the server. The overlay disables both buttons and shows a
    /// spinner while the ID is present so users don't double-fire
    /// `fidoRespond` on a slow link. (UX audit item #23a.)
    var inFlightRequestIds: Set<String> = []

    var autoApprovalRules: [AutoApprovalRule] = [] {
        didSet { persistRules() }
    }

    var requireBiometricForAll: Bool {
        get { UserDefaults.standard.bool(forKey: "fido_require_biometric_all") }
        set { UserDefaults.standard.set(newValue, forKey: "fido_require_biometric_all") }
    }

    private let api = OrbCore.shared

    private init() {
        loadRules()
    }

    // MARK: - SSE Event Handling

    func handleSignRequest(_ data: [String: Any]) {
        guard let request = FidoSignRequest.parse(data) else { return }
        // The same request can arrive on several open streams (global monitor + conversation).
        guard !pendingRequests.contains(where: { $0.id == request.id }), !inFlightRequestIds.contains(request.id) else { return }
        clearExpiredRules()

        if matchingRule(for: request) != nil {
            // Rules skip the overlay, never the Face ID / passcode check.
            Task {
                if await authenticateDeviceOwner() {
                    await approve(request.id)
                } else {
                    pendingRequests.append(request)
                    OrbHaptics.error()
                }
            }
        } else {
            pendingRequests.append(request)
            OrbHaptics.error()
        }
    }

    // MARK: - Approve / Deny

    /// Manual approval from the overlay: always gated by Face ID / Touch ID with a
    /// device passcode fallback. A failed or cancelled check leaves the request pending.
    func approveWithAuthentication(_ requestId: String) async {
        guard !inFlightRequestIds.contains(requestId) else { return }
        lastError = nil
        if let message = await OrbBiometric.authenticate(reason: "Approve the SSH signing request") {
            if !message.isEmpty {
                lastError = message
                OrbHaptics.error()
            }
            return
        }
        await approve(requestId)
    }

    var lastError: String?

    func approve(_ requestId: String) async {
        // Idempotent — bail out if the user double-taps Approve before the
        // first call comes back, otherwise we'd fire two `fidoRespond` calls.
        guard !inFlightRequestIds.contains(requestId) else { return }
        inFlightRequestIds.insert(requestId)
        defer { inFlightRequestIds.remove(requestId) }
        do {
            try await api.fidoRespond(requestId: requestId, approved: true)
            OrbHaptics.success()
        } catch {
            // Usually the 60 s server timeout already expired the request.
            lastError = error.localizedDescription
        }
        pendingRequests.removeAll { $0.id == requestId }
    }

    func deny(_ requestId: String) async {
        guard !inFlightRequestIds.contains(requestId) else { return }
        inFlightRequestIds.insert(requestId)
        defer { inFlightRequestIds.remove(requestId) }
        do {
            try await api.fidoRespond(requestId: requestId, approved: false)
        } catch {
            lastError = error.localizedDescription
        }
        pendingRequests.removeAll { $0.id == requestId }
    }

    // MARK: - Auto-Approval Rules

    func addAutoApprovalRule(
        type: AutoApprovalRuleType,
        value: String?,
        duration: Int?,
        requireBiometric: Bool
    ) {
        let expiresAt: Date? = duration.map { Date().addingTimeInterval(Double($0) * 60) }
        let rule = AutoApprovalRule(
            id: UUID(),
            ruleType: type,
            value: value,
            expiresAt: expiresAt,
            requireBiometric: requireBiometric
        )
        autoApprovalRules.append(rule)
    }

    func removeRule(id: UUID) {
        autoApprovalRules.removeAll { $0.id == id }
    }

    func clearExpiredRules() {
        autoApprovalRules.removeAll { $0.isExpired }
    }

    func matchingRule(for request: FidoSignRequest) -> AutoApprovalRule? {
        autoApprovalRules.first { rule in
            guard !rule.isExpired else { return false }
            switch rule.ruleType {
            case .allSSH:
                return request.keyType.lowercased().contains("ssh")
            case .hostname:
                return rule.value == request.hostname
            case .keyFingerprint:
                return rule.value == request.keyFingerprint
            }
        }
    }

    // MARK: - Biometric Authentication

    func authenticateWithBiometric() async -> Bool { await authenticateDeviceOwner() }

    /// Face ID / Touch ID, falling back to the device passcode (`.deviceOwnerAuthentication`),
    /// the same LocalAuthentication pattern as `OrbBiometric` in OrbSecretRequests.swift.
    func authenticateDeviceOwner() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve the SSH signing request")
        } catch {
            return false
        }
    }

    // MARK: - Persistence

    private func persistRules() {
        if let data = try? JSONEncoder().encode(autoApprovalRules) {
            UserDefaults.standard.set(data, forKey: "fido_auto_approval_rules")
        }
    }

    private func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: "fido_auto_approval_rules"),
              let rules = try? JSONDecoder().decode([AutoApprovalRule].self, from: data) else {
            return
        }
        autoApprovalRules = rules
    }
}
