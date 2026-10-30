import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

// Opt-in usage telemetry (docs/USAGE_TELEMETRY.md). Events go to Core
// (`POST /api/usage-telemetry/events`), which drops everything while telemetry
// is off and every field not in `shared/orb-spec/fixtures/usage-telemetry.json`.
// Enum raw values below equal that fixture's lists (OrbUsageTelemetryTests).
// Never put prompt text, approval payloads, commands or secrets in an event.

enum OrbTelemetryAction: String, CaseIterable, Sendable {
    case sidebarMove = "sidebar_move", btw, fork, queue
    case fileViewerOpen = "file_viewer_open"
    case inboxOpen = "inbox_open", inboxArchive = "inbox_archive", inboxSnooze = "inbox_snooze", inboxDone = "inbox_done"
    case messageEdit = "message_edit", messageResend = "message_resend"
}

enum OrbTelemetryApprovalKind: String, CaseIterable, Sendable { case tool, commandClass = "command_class", grant, payment }
enum OrbTelemetryDecision: String, CaseIterable, Sendable { case approved, denied, expired, dismissed }
enum OrbTelemetryMethod: String, CaseIterable, Sendable {
    case faceId = "face_id", touchId = "touch_id", passcode, desktopClick = "desktop_click", none

    /// What `.deviceOwnerAuthentication` on this phone resolves to: the enrolled
    /// biometry, or the passcode when there is none.
    static var deviceOwner: OrbTelemetryMethod {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .passcode }
        switch context.biometryType {
        case .faceID: return .faceId
        case .touchID: return .touchId
        default: return .passcode
        }
    }
}
enum OrbTelemetrySurface: String, CaseIterable, Sendable { case screen, sheet, pane }

/// `GET /api/usage-telemetry`. The token itself is never returned.
struct OrbTelemetryStatus: Equatable, Sendable {
    var enabled = false, promptsEnabled = false, active = false
    var hubURL = "", namespace = "", tokenConfigured = false
    var queued = 0, lastError = ""
    init() {}
    init(_ j: OrbJSON) {
        enabled = j["enabled"].flag; promptsEnabled = j["prompts_enabled"].flag; active = j["active"].flag
        hubURL = j["hub_url"].text; namespace = j["namespace"].text; tokenConfigured = j["token_configured"].flag
        queued = Int(j["queued"].doubleValue ?? 0); lastError = j["last_error"].text
    }
}

@MainActor
@Observable
final class OrbUsageTelemetry {
    static let shared = OrbUsageTelemetry()

    typealias Transport = @MainActor ([OrbJSON]) async throws -> Void
    typealias StatusFetcher = @MainActor () async throws -> OrbJSON

    static let maxQueued = 500
    static let batchSize = 50
    static let flushInterval: Duration = .seconds(30)
    nonisolated(unsafe) static let identPattern = /^[A-Za-z0-9_.:\/+@-]{1,120}$/

    private(set) var status = OrbTelemetryStatus()
    private(set) var queue: [OrbJSON] = []
    var active: Bool { status.active }

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let fetchStatus: StatusFetcher
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var approvalShownAt: [String: Date] = [:]

    init(
        transport: @escaping Transport = { events in
            _ = try await OrbCore.shared.call("/api/usage-telemetry/events", method: "POST", body: .object(["events": .array(events)]))
        },
        fetchStatus: @escaping StatusFetcher = { try await OrbCore.shared.call("/api/usage-telemetry") }
    ) {
        self.transport = transport
        self.fetchStatus = fetchStatus
    }

    // MARK: Lifecycle

    /// Called once at launch: status now and on every foreground, flush on background.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await OrbUsageTelemetry.shared.refreshStatus() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await OrbUsageTelemetry.shared.flush() }
        }
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard let json = try? await fetchStatus() else { return }
        apply(OrbTelemetryStatus(json))
    }

    /// Takes a status from Core (after a fetch or a settings change).
    func apply(_ next: OrbTelemetryStatus) {
        status = next
        if next.active {
            if timer == nil {
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.flushInterval)
                        await self?.flush()
                    }
                }
            }
        } else {
            timer?.cancel(); timer = nil
            queue.removeAll()
        }
    }

    // MARK: Tracking

    /// Open a page visit; `close()` emits `orb.page.v1` with the dwell time.
    func trackPage(screen: String, surface: OrbTelemetrySurface, entryPoint: String? = nil) -> OrbPageVisit {
        OrbPageVisit(screen: screen, surface: surface, entryPoint: entryPoint, telemetry: self)
    }

    func trackAction(_ action: OrbTelemetryAction, surface: String? = nil, count: Int? = nil) {
        var f: [String: OrbJSON] = ["action": .string(action.rawValue)]
        if let count { f["count"] = .number(Double(max(0, count))) }
        if let surface { f["surface"] = .string(surface) }
        enqueue(Self.event("orb.action.v1", f))
    }

    func trackApproval(kind: OrbTelemetryApprovalKind, decision: OrbTelemetryDecision, method: OrbTelemetryMethod,
                       waitMs: Int?, toolName: String? = nil, commandClass: String? = nil) {
        var f: [String: OrbJSON] = ["kind": .string(kind.rawValue), "decision": .string(decision.rawValue), "method": .string(method.rawValue)]
        if let waitMs { f["wait_ms"] = .number(Double(max(0, waitMs))) }
        if let toolName { f["tool_name"] = .string(toolName) }
        if let commandClass { f["command_class"] = .string(commandClass) }
        enqueue(Self.event("orb.approval.v1", f))
    }

    /// Marks when an approval prompt was first shown (idempotent per id).
    func approvalShown(_ id: String) {
        if approvalShownAt[id] == nil { approvalShownAt[id] = Date() }
    }

    /// Milliseconds since `approvalShown(id)`, consuming the mark.
    func approvalWait(_ id: String) -> Int? {
        guard let shown = approvalShownAt.removeValue(forKey: id) else { return nil }
        return Int(Date().timeIntervalSince(shown) * 1000)
    }

    fileprivate func pageClosed(_ visit: OrbPageVisit, dwell: TimeInterval) {
        var f: [String: OrbJSON] = ["screen": .string(visit.screen), "surface": .string(visit.surface.rawValue),
                                    "dwell_ms": .number(Double(Int(max(0, dwell) * 1000)))]
        if let entry = visit.entryPoint { f["entry_point"] = .string(entry) }
        enqueue(Self.event("orb.page.v1", f))
    }

    // MARK: Events

    nonisolated static func isIdent(_ value: String) -> Bool { value.wholeMatch(of: identPattern) != nil }

    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = "\(info["CFBundleShortVersionString"] as? String ?? "0")+\(info["CFBundleVersion"] as? String ?? "0")"
        return isIdent(v) ? v : "unknown"
    }

    /// One event: common fields plus `fields`, with string values that are not
    /// identifiers dropped (Core would drop them too).
    nonisolated static func event(_ schema: String, _ fields: [String: OrbJSON], now: Date = Date()) -> OrbJSON {
        var out: [String: OrbJSON] = [
            "schema": .string(schema),
            "event_id": .string(UUID().uuidString),
            "ts": .string(isoTimestamp(now)),
            "client": .string("ios"),
            "app_version": .string(appVersion),
        ]
        for (k, v) in fields {
            if case .string(let s) = v, !isIdent(s) { continue }
            out[k] = v
        }
        return .object(out)
    }

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func enqueue(_ event: OrbJSON) {
        guard status.active else { return }
        queue.append(event)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        if queue.count >= Self.batchSize { Task { await flush() } }
    }

    /// Sends everything queued in batches; a failed batch stays queued for the next flush.
    func flush() async {
        guard !flushing, status.active else { return }
        flushing = true; defer { flushing = false }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(Self.batchSize))
            do { try await transport(batch) } catch { return }
            queue.removeFirst(min(batch.count, queue.count))
        }
    }
}

/// One page visit. `close()` is idempotent.
@MainActor
final class OrbPageVisit {
    let screen: String, surface: OrbTelemetrySurface, entryPoint: String?
    private let opened = Date()
    private weak var telemetry: OrbUsageTelemetry?
    private var closed = false
    fileprivate init(screen: String, surface: OrbTelemetrySurface, entryPoint: String?, telemetry: OrbUsageTelemetry) {
        self.screen = screen; self.surface = surface; self.entryPoint = entryPoint; self.telemetry = telemetry
    }
    func close() {
        guard !closed else { return }
        closed = true
        telemetry?.pageClosed(self, dwell: Date().timeIntervalSince(opened))
    }
}

private struct OrbTrackPage: ViewModifier {
    let screen: String, surface: OrbTelemetrySurface, entryPoint: String?
    @State private var visit: OrbPageVisit?
    func body(content: Content) -> some View {
        content
            .onAppear { if visit == nil { visit = OrbUsageTelemetry.shared.trackPage(screen: screen, surface: surface, entryPoint: entryPoint) } }
            .onDisappear { visit?.close(); visit = nil }
    }
}

extension View {
    /// Records an `orb.page.v1` visit from appear to disappear.
    func orbTrackPage(_ screen: String, surface: OrbTelemetrySurface = .screen, entryPoint: String? = nil) -> some View {
        modifier(OrbTrackPage(screen: screen, surface: surface, entryPoint: entryPoint))
    }
}

// MARK: - Settings › Account › Usage telemetry

struct OrbUsageTelemetrySettings: View {
    @State private var client = OrbSettingsClient()
    @State private var loaded = false
    @State private var enabled = false
    @State private var prompts = false
    @State private var namespace = ""
    @State private var hubURL = ""
    @State private var token = ""
    @State private var saving = false
    @State private var error = ""
    private var telemetry: OrbUsageTelemetry { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Share usage telemetry", isOn: Binding(get: { enabled }, set: { enabled = $0; save(["enabled": .bool($0)]) }))
                    .accessibilityIdentifier("telemetry.enabled")
                Toggle("Include prompts (secrets scrubbed)", isOn: Binding(get: { prompts }, set: { prompts = $0; save(["prompts_enabled": .bool($0)]) }))
                    .disabled(!enabled)
                    .accessibilityIdentifier("telemetry.prompts")
            } footer: {
                Text("Off by default. Orb sends which screens you use, approvals (method and wait time, never what was approved) and a few actions to your own hub. Prompts are only included when you turn that on.")
            }
            Section("Hub") {
                LabeledContent("Namespace") {
                    TextField("personal", text: $namespace)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Hub URL") {
                    TextField("https://…", text: $hubURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                SecureField(telemetry.status.tokenConfigured ? "Token (configured)" : "Token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    var body: [String: OrbJSON] = ["namespace": .string(namespace.trimmingCharacters(in: .whitespaces)),
                                                   "hub_url": .string(hubURL.trimmingCharacters(in: .whitespaces))]
                    if !token.isEmpty { body["token"] = .string(token) }
                    save(body)
                }
                .disabled(saving || namespace.trimmingCharacters(in: .whitespaces) == "community")
                if telemetry.status.tokenConfigured {
                    Button("Clear token", role: .destructive) { save(["token": .string("")]) }.disabled(saving)
                }
            }
            Section("Status") {
                LabeledContent("Token", value: telemetry.status.tokenConfigured ? "Configured" : "Not set")
                LabeledContent("Sending", value: telemetry.status.active ? "Yes" : "No")
                LabeledContent("Queued on server", value: "\(telemetry.status.queued)")
                LabeledContent("Queued on this phone", value: "\(telemetry.queue.count)")
                if !telemetry.status.lastError.isEmpty {
                    Text(telemetry.status.lastError).font(.footnote).foregroundStyle(.red)
                }
            }
            if !error.isEmpty { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Usage telemetry").navigationBarTitleDisplayMode(.inline)
        .task {
            await telemetry.refreshStatus()
            if !loaded { sync(telemetry.status); loaded = true }
        }
    }

    private func sync(_ s: OrbTelemetryStatus) {
        enabled = s.enabled; prompts = s.promptsEnabled; namespace = s.namespace; hubURL = s.hubURL
    }

    private func save(_ body: [String: OrbJSON]) {
        Task {
            saving = true; defer { saving = false }
            do {
                let next = OrbTelemetryStatus(try await OrbApprovalKey.signedCall("/api/usage-telemetry/config", method: "PUT", body: .object(body), summary: "change usage telemetry"))
                telemetry.apply(next)
                sync(next)
                token = ""
                error = ""
            } catch is CancellationError {
            } catch {
                sync(telemetry.status)
                self.error = error.localizedDescription
            }
        }
    }
}

extension OrbUsageTelemetry {
    /// A grant decision (privileged access, mission access, secrets). Enrolled
    /// phones sign with the Secure Enclave key, which asks for the device owner;
    /// unenrolled ones ask for it before approving. Deny is a plain tap.
    static func recordGrant(_ id: String, approve: Bool, enrolled: Bool) {
        let t = shared
        t.trackApproval(kind: .grant, decision: approve ? .approved : .denied,
                        method: approve || enrolled ? .deviceOwner : .none, waitMs: t.approvalWait(id))
    }
}
