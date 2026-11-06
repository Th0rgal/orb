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

    typealias Respond = @MainActor (_ requestId: String, _ approved: Bool) async throws -> Void
    typealias FetchPending = @MainActor () async throws -> [[String: Any]]
    typealias Authenticate = @MainActor (_ reason: String) async -> String?

    var pendingRequests: [FidoSignRequest] = []

    /// Set of request IDs for which an approve/deny request is currently in
    /// flight to the server. The overlay disables both buttons and shows a
    /// spinner while the ID is present so users don't double-fire
    /// `fidoRespond` on a slow link. (UX audit item #23a.)
    var inFlightRequestIds: Set<String> = []

    var authenticatingRequestIds: Set<String> = []

    var autoApprovalRules: [AutoApprovalRule] = [] {
        didSet { if persistRulesEnabled { persistRules() } }
    }

    var requireBiometricForAll: Bool {
        get { UserDefaults.standard.bool(forKey: "fido_require_biometric_all") }
        set { UserDefaults.standard.set(newValue, forKey: "fido_require_biometric_all") }
    }

    private var errorsByRequestId: [String: String] = [:]

    var lastError: String? {
        get { activeRequest.flatMap { errorsByRequestId[$0.id] } }
        set {
            guard let id = activeRequest?.id else { return }
            if let newValue, !newValue.isEmpty {
                errorsByRequestId[id] = newValue
            } else {
                errorsByRequestId.removeValue(forKey: id)
            }
        }
    }

    private var activeRequest: FidoSignRequest? { pendingRequests.first }

    @ObservationIgnored private let respond: Respond
    @ObservationIgnored private let fetchPending: FetchPending
    @ObservationIgnored private let authenticate: Authenticate
    @ObservationIgnored private let persistRulesEnabled: Bool

    init(
        respond: @escaping Respond = { id, approved in try await OrbCore.shared.fidoRespond(requestId: id, approved: approved) },
        fetchPending: @escaping FetchPending = { try await OrbCore.shared.fidoPending() },
        authenticate: @escaping Authenticate = { reason in await OrbBiometric.authenticate(reason: reason) },
        persistRules: Bool = true
    ) {
        self.respond = respond
        self.fetchPending = fetchPending
        self.authenticate = authenticate
        self.persistRulesEnabled = persistRules
        if persistRules { loadRules() }
    }

    // MARK: - SSE Event Handling

    func handleSignRequest(_ data: [String: Any], dropIfExpiredAt now: Date? = nil) {
        guard let request = FidoSignRequest.parse(data) else { return }
        if let now, request.expiresAt <= now { return }
        guard !pendingRequests.contains(where: { $0.id == request.id }), !inFlightRequestIds.contains(request.id) else { return }
        OrbUsageTelemetry.shared.approvalShown(request.id)
        clearExpiredRules()

        if matchingRule(for: request) != nil {
            Task {
                if await authenticateForRule(request) {
                    await approve(request.id, onFailureRequest: request)
                } else if !pendingRequests.contains(where: { $0.id == request.id }) {
                    pendingRequests.append(request)
                    errorsByRequestId[request.id] = "Authentication cancelled or failed. Tap Approve to retry or Deny."
                    OrbHaptics.error()
                }
            }
        } else {
            pendingRequests.append(request)
            OrbHaptics.error()
        }
    }

    private func authenticateForRule(_ request: FidoSignRequest) async -> Bool {
        authenticatingRequestIds.insert(request.id)
        defer { authenticatingRequestIds.remove(request.id) }
        return await authenticate("Approve the SSH signing request") == nil
    }

    func removeResolvedRequest(_ requestId: String) {
        pendingRequests.removeAll { $0.id == requestId }
        errorsByRequestId.removeValue(forKey: requestId)
    }

    func dropExpired(now: Date = Date()) {
        let kept = Set(pendingRequests.filter { request in
            request.expiresAt > now
                || errorsByRequestId[request.id] != nil
                || inFlightRequestIds.contains(request.id)
                || authenticatingRequestIds.contains(request.id)
        }.map(\.id))
        pendingRequests.removeAll { !kept.contains($0.id) }
        errorsByRequestId = errorsByRequestId.filter { id, _ in kept.contains(id) || pendingRequests.contains { $0.id == id } }
    }

    func syncPending(now: Date = Date()) async {
        let preExistingIds = Set(pendingRequests.map(\.id))
        guard let payloads = try? await fetchPending() else { return }
        dropExpired(now: now)
        let listed = Set(payloads.compactMap { payload -> String? in
            guard let request = FidoSignRequest.parse(payload), request.expiresAt > now else { return nil }
            handleSignRequest(payload, dropIfExpiredAt: now)
            return request.id
        })
        for id in preExistingIds where !listed.contains(id)
            && !inFlightRequestIds.contains(id)
            && !authenticatingRequestIds.contains(id)
            && errorsByRequestId[id] == nil {
            pendingRequests.removeAll { $0.id == id }
        }
    }

    // MARK: - Approve / Deny

    /// Manual approval from the overlay: always gated by Face ID / Touch ID with a
    /// device passcode fallback. A failed or cancelled check leaves the request pending.
    func approveWithAuthentication(_ requestId: String) async {
        guard !inFlightRequestIds.contains(requestId), !authenticatingRequestIds.contains(requestId) else { return }
        authenticatingRequestIds.insert(requestId)
        let message = await authenticate("Approve the SSH signing request")
        authenticatingRequestIds.remove(requestId)
        if let message {
            Self.recordApproval(requestId, .dismissed, method: .deviceOwner, consume: false)
            if !message.isEmpty {
                errorsByRequestId[requestId] = message
                OrbHaptics.error()
            }
            return
        }
        await approve(requestId)
    }

    private static func isTerminalRespondError(_ error: Error) -> Bool {
        guard let http = error as? OrbHTTPError, http.kind == .http else { return false }
        if http.status == 404 || http.status == 410 { return true }
        guard (400..<500).contains(http.status),
              let data = http.detail.data(using: .utf8),
              let body = try? JSONDecoder().decode(OrbJSON.self, from: data) else { return false }
        return body["error"] == .string("already_resolved") || body["code"] == .string("already_resolved")
    }

    func approve(_ requestId: String, onFailureRequest: FidoSignRequest? = nil) async {
        guard !inFlightRequestIds.contains(requestId) else { return }
        inFlightRequestIds.insert(requestId)
        errorsByRequestId.removeValue(forKey: requestId)
        defer { inFlightRequestIds.remove(requestId) }
        do {
            try await respond(requestId, true)
            Self.recordApproval(requestId, .approved, method: .deviceOwner)
            OrbHaptics.success()
            removeResolvedRequest(requestId)
        } catch is CancellationError {
            if let onFailureRequest, !pendingRequests.contains(where: { $0.id == requestId }) {
                pendingRequests.append(onFailureRequest)
            }
            errorsByRequestId[requestId] = "Response interrupted. Retry approval or deny."
        } catch {
            if Self.isTerminalRespondError(error) {
                removeResolvedRequest(requestId)
            } else {
                if let onFailureRequest, !pendingRequests.contains(where: { $0.id == requestId }) {
                    pendingRequests.append(onFailureRequest)
                }
                errorsByRequestId[requestId] = error.localizedDescription
            }
        }
    }

    func deny(_ requestId: String) async {
        guard !inFlightRequestIds.contains(requestId) else { return }
        inFlightRequestIds.insert(requestId)
        errorsByRequestId.removeValue(forKey: requestId)
        defer { inFlightRequestIds.remove(requestId) }
        do {
            try await respond(requestId, false)
            Self.recordApproval(requestId, .denied, method: .none)
            removeResolvedRequest(requestId)
        } catch is CancellationError {
            errorsByRequestId[requestId] = "Response interrupted. Retry approval or deny."
        } catch {
            if Self.isTerminalRespondError(error) {
                removeResolvedRequest(requestId)
            } else {
                errorsByRequestId[requestId] = error.localizedDescription
            }
        }
    }

    /// Usage telemetry: an SSH signing decision (never the request itself).
    private static func recordApproval(_ id: String, _ decision: OrbTelemetryDecision, method: OrbTelemetryMethod, consume: Bool = true) {
        let t = OrbUsageTelemetry.shared
        let wait = consume ? t.approvalWait(id) : nil
        t.trackApproval(kind: .tool, decision: decision, method: method, waitMs: wait, toolName: "ssh_sign")
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
