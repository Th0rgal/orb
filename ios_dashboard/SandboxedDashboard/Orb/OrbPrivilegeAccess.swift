import SwiftUI
import UserNotifications

// MARK: - Privileged access requests

/// Missions asking for root, a service deploy or read-only ops on a host
/// (`GET /api/privilege-access`), polled like mission access requests.
/// Approving needs a device signature (Face ID / Touch ID); Core checks the
/// grant on every command. Grants end with the mission session or expire,
/// and can be revoked. Labels match desktop `privilegeAccessApi.ts` and
/// `shared/orb-spec/fixtures/privilege-access.json`.
@MainActor
@Observable
final class OrbPrivilegeAccessMonitor {
    static let shared = OrbPrivilegeAccessMonitor()
    private(set) var requests: [OrbJSON] = []
    private(set) var commands: [OrbJSON] = []
    private(set) var incidents: [OrbJSON] = []
    private(set) var meshStatus: OrbJSON?
    private(set) var bunkerState = 0
    var bunkered: Bool { bunkerState > 0 }
    /// Set when a privileged access notification is tapped; the home view opens the sheet.
    var openRequested = false
    private var endpoint = ""
    private var announced: Set<String> = []
    private var announcedBunkerLevel = 0
    /// The Bunker Mode card stays hidden at this level once dismissed; a new level shows it again.
    private(set) var bunkerDismissedForLevel = 0

    var showsBunkerCard: Bool { Self.showsBunkerCard(state: bunkerState, dismissedLevel: bunkerDismissedForLevel) }
    var latestIncidentReason: String? { Self.latestIncidentReason(incidents) }

    nonisolated static func showsBunkerCard(state: Int, dismissedLevel: Int) -> Bool {
        state > 0 && dismissedLevel != state
    }

    /// Core lists incidents newest first; canary dry runs do not change the posture.
    nonisolated static func latestIncidentReason(_ incidents: [OrbJSON]) -> String? {
        incidents.first { !$0["dry_run"].flag && !$0["reason"].text.isEmpty }?["reason"].text
    }

    func dismissBunkerCard() { bunkerDismissedForLevel = bunkerState }

    var pending: [OrbJSON] { requests.filter { $0["state"].text == "pending" } }
    var grants: [OrbJSON] { requests.filter { Self.isLive($0) } }
    var history: [OrbJSON] { requests.filter { $0["state"].text != "pending" && !Self.isLive($0) } }

    static func bunkerLabel(_ state: Int) -> String {
        switch state {
        case 0: return "Normal"
        case 1: return "Soft Quarantine"
        case 2: return "Hard Lockdown"
        case 3: return "Sovereign Dead-Man Tripped"
        default: return "Locked (\(state))"
        }
    }

    static func isLive(_ r: OrbJSON, now: Date = Date()) -> Bool {
        guard r["state"].text == "approved", r["revoked_at"].text.isEmpty else { return false }
        return OrbStyle.parseDate(r["expires_at"].text).map { $0 > now } ?? false
    }

    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "ops_read": return "Read-only ops"
        case "service_deploy": return "Service deploy"
        case "root_exec": return "Root"
        default: return scope
        }
    }
    static func host(_ h: String) -> String { h == "self" ? "its own node" : h }
    static func title(_ r: OrbJSON) -> String { "\(scopeLabel(r["scope"].text)) on \(host(r["target_host"].text))" }
    static func unlocks(_ r: OrbJSON) -> String {
        let unit = r["allowed_unit"].text
        switch r["scope"].text {
        case "service_deploy" where !unit.isEmpty: return "restart and deploy \(unit) only"
        case "ops_read": return "logs, status and disk checks as root; no changes"
        case "service_deploy": return "restart and deploy services, including production"
        case "root_exec": return "any command as root"
        default: return ""
        }
    }
    static func lifetime(_ r: OrbJSON) -> String {
        let m = Int(r["ttl_minutes"].doubleValue ?? 0)
        let span = m >= 60 && m % 60 == 0 ? "\(m / 60) h" : "\(m) min"
        return r["session_scoped"].flag ? "for this session (max \(span))" : "for \(span)"
    }
    static func requester(_ r: OrbJSON) -> String {
        OrbMissionAccessMonitor.mission(r["requester_title"].text, r["requester_mission_id"].text)
    }

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { requests = []; commands = []; incidents = []; meshStatus = nil; announced = []; announcedBunkerLevel = 0; endpoint = current }
        guard let snap = await Log.attempt(.network, "privilege access", { try await OrbCore.shared.call("/api/privilege-access") }) else { return false }
        guard current == OrbCore.shared.endpoint else { return true }
        requests = snap["requests"].items
        commands = snap["command_audit"].items
        incidents = snap["bunker_incidents"].items
        let snapBunker = Int(snap["bunker_state"].doubleValue ?? 0)
        meshStatus = await Log.attempt(.network, "mesh status", { try await OrbCore.shared.call("/api/mesh/status") })
        let meshBunker = Int(meshStatus?["bunker_state"].doubleValue ?? 0)
        bunkerState = max(snapBunker, meshBunker)
        if bunkerState <= 0 { bunkerDismissedForLevel = 0 }
        announce()
        return true
    }

    /// Enter (level 2) or exit Fleet Bunker Mode, signed by this phone's approval key.
    /// Same endpoints and bodies as desktop `privilegeAccessApi.ts`.
    func setBunker(lock: Bool) async throws {
        let reason = lock ? "enter Hard Bunker Lockdown across the fleet" : "exit Fleet Bunker Mode"
        let enrolled = await OrbApprovalKey.ensureEnrolled()
        if !enrolled, let message = await OrbBiometric.authenticate(reason: reason) {
            if message.isEmpty { throw CancellationError() }
            throw OrbHTTPError(status: 0, detail: message)
        }
        let path = lock ? "/api/privilege-access/bunker" : "/api/privilege-access/unbunker"
        let body: OrbJSON? = lock
            ? .object([
                "level": .number(2),
                "reason": .string("Operator manual Fleet Bunker lockdown from Orb iOS"),
                "canary_tripped": .bool(true),
                "auth_failure_burst": .bool(false)
            ])
            : nil
        _ = try await OrbApprovalKey.signedCall(path, method: "POST", body: body, summary: reason)
        OrbHaptics.success()
        await refresh()
    }

    func poll() async {
        await Poller.run(every: .seconds(10)) { await refresh() }
    }

    /// One local notification per new pending request or Bunker Mode state transition.
    private func announce() {
        if bunkerState <= 0 {
            announcedBunkerLevel = 0
        } else if bunkerState != announcedBunkerLevel {
            announcedBunkerLevel = bunkerState
            let content = UNMutableNotificationContent()
            content.title = "Fleet Bunker Mode: \(Self.bunkerLabel(bunkerState))"
            content.body = "New privileged requests are locked and active root/deploy grants are revoked."
            content.threadIdentifier = "orb.privilege-access"
            content.userInfo = ["orb_privilege_access": "bunker"]
            let request = UNNotificationRequest(identifier: "orb.bunker-mode.\(bunkerState)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
        for r in pending where !announced.contains(r["id"].text) {
            announced.insert(r["id"].text)
            let content = UNMutableNotificationContent()
            content.title = "Privileged access request"
            content.body = "\(Self.requester(r)) asks for \(Self.title(r)): \(r["reason"].text)"
            content.threadIdentifier = "orb.privilege-access"
            content.userInfo = ["orb_privilege_access": r["id"].text]
            let request = UNNotificationRequest(identifier: "orb.privilege-access.\(r["id"].text)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
}

/// Pending requests (approve with Face ID / Touch ID, or deny), live grants
/// (revoke), history and Core's per-command audit. Home sheet and Settings.
struct OrbPrivilegeAccessList: View {
    @State private var monitor = OrbPrivilegeAccessMonitor.shared
    @State private var acting: String?
    @State private var error = ""

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            "Fleet posture: \(OrbPrivilegeAccessMonitor.bunkerLabel(monitor.bunkerState))",
                            systemImage: monitor.bunkered ? "lock.shield.fill" : "checkmark.shield"
                        )
                        .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    if let mesh = monitor.meshStatus {
                        Text("lean-mesh epoch \(Int(mesh["epoch"].doubleValue ?? 0)) · \(mesh["formal_verified"].flag ? "Lean 4 verified" : "unverified")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(
                        monitor.bunkered
                            ? "Bunker Mode is on: new privileged requests are locked and active grants are revoked."
                            : "Normal operation. Canary tripwires and dead-man heartbeat switches are armed across all workers."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if monitor.bunkered {
                            Button {
                                toggleBunker(lock: false)
                            } label: {
                                Label("Exit Bunker Mode", systemImage: OrbBiometric.symbolName)
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(OrbStyle.success)
                            .accessibilityIdentifier("privilege.unbunker")
                        } else {
                            Button(role: .destructive) {
                                toggleBunker(lock: true)
                            } label: {
                                Label("Lock Down Fleet", systemImage: OrbBiometric.symbolName)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("privilege.bunker")
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    .disabled(acting != nil)
                }
                .padding(.vertical, 4)
            } header: { Text("Fleet posture & lean-mesh") }
            Section {
                if monitor.pending.isEmpty { Text("No pending requests.").foregroundStyle(.secondary) }
                ForEach(monitor.pending, id: \.selfID) { pendingRow($0) }
            } header: { Text("Pending") } footer: {
                Text("A grant lasts at most the mission session. Core checks and logs every command, and you can revoke it at any time.")
            }
            Section("Active grants") {
                if monitor.grants.isEmpty { Text("No active grants.").foregroundStyle(.secondary) }
                ForEach(monitor.grants, id: \.selfID) { grantRow($0) }
            }
            if !monitor.incidents.isEmpty || !monitor.history.isEmpty || !monitor.commands.isEmpty {
                Section("Activity") {
                    ForEach(monitor.incidents.prefix(20), id: \.selfID) { inc in
                        HStack(alignment: .firstTextBaseline) {
                            Text(inc["dry_run"].flag ? "CANARY TEST" : OrbPrivilegeAccessMonitor.bunkerLabel(Int(inc["new_bunker_state"].doubleValue ?? 0)).uppercased())
                                .font(.system(.caption2, weight: .bold)).foregroundStyle(.secondary)
                            Text("\(!inc["peer_name"].text.isEmpty ? "\(inc["peer_name"].text) · " : "")\(inc["reason"].text) (epoch \(Int(inc["epoch"].doubleValue ?? 0)))")
                                .font(.caption).lineLimit(2)
                        }
                    }
                    ForEach(monitor.history.prefix(20), id: \.selfID) { r in
                        HStack {
                            Text(r["state"].text.uppercased()).font(.system(.caption2, weight: .bold)).foregroundStyle(.secondary)
                            Text("\(OrbPrivilegeAccessMonitor.requester(r)) · \(OrbPrivilegeAccessMonitor.title(r))").font(.caption)
                        }
                    }
                    ForEach(monitor.commands.prefix(40), id: \.selfID) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c["exit_code"].doubleValue.map { "EXIT \(Int($0))" } ?? "RUN")
                                .font(.system(.caption2, weight: .bold)).foregroundStyle(.secondary)
                            Text("\(c["target_host"].text) · \(c["command"].text)").font(.caption.monospaced()).lineLimit(2)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .refreshable { await monitor.refresh() }
        .task { await monitor.refresh() }
    }

    private func pendingRow(_ r: OrbJSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OrbPrivilegeAccessMonitor.title(r)).font(.subheadline.weight(.medium))
                .foregroundStyle(r["scope"].text == "root_exec" ? OrbStyle.error : Color.primary)
            Text("asked by \(OrbPrivilegeAccessMonitor.requester(r)) · \(OrbStyle.relativeTime(r["created_at"].text))").font(.caption).foregroundStyle(.secondary)
            if !r["reason"].text.isEmpty { Text("“\(r["reason"].text)”").font(.caption).italic() }
            Text("Allows \(OrbPrivilegeAccessMonitor.unlocks(r)) · \(OrbPrivilegeAccessMonitor.lifetime(r))").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    act(r, approve: true)
                } label: {
                    Label("Allow", systemImage: OrbBiometric.symbolName)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(OrbStyle.success)
                .accessibilityIdentifier("privilege.approve.\(r["id"].text)")
                Spacer()
                Button("Deny", role: .destructive) { act(r, approve: false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("privilege.deny.\(r["id"].text)")
            }
            .controlSize(.small)
            .disabled(acting != nil)
        }
        .padding(.vertical, 4)
    }

    private func grantRow(_ g: OrbJSON) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(OrbPrivilegeAccessMonitor.requester(g)) · \(OrbPrivilegeAccessMonitor.title(g))").font(.subheadline)
                Text("\(g["session_scoped"].flag ? "Ends with the session" : "Fixed lifetime") · \(OrbMissionAccessList.left(g["expires_at"].text))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { revoke(g) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(acting != nil)
                .accessibilityIdentifier("privilege.revoke.\(g["id"].text)")
        }
    }

    private func act(_ r: OrbJSON, approve: Bool) {
        Task {
            let id = r["id"].text
            let reason = approve
                ? "Grant \(OrbPrivilegeAccessMonitor.title(r)) to \(OrbPrivilegeAccessMonitor.requester(r))"
                : "Decline a privileged access request"
            // An enrolled device signs the request, which prompts for Face ID /
            // Touch ID itself; otherwise ask for it here (Core still requires a
            // signature to approve).
            let enrolled = await OrbApprovalKey.ensureEnrolled()
            if approve, !enrolled, let message = await OrbBiometric.authenticate(reason: reason) {
                if !message.isEmpty { error = message }
                return
            }
            acting = id
            defer { acting = nil }
            do {
                let path = "/api/privilege-access/\(OrbCore.escape(id))/\(approve ? "approve" : "deny")"
                let body: OrbJSON? = approve
                    ? .object(["ttl_minutes": r["ttl_minutes"], "session_scoped": .bool(r["session_scoped"].flag)])
                    : nil
                _ = try await OrbApprovalKey.signedCall(path, method: "POST", body: body, summary: reason)
                error = ""
                OrbHaptics.success()
            } catch {
                if let msg = OrbBiometric.friendlyError(error) {
                    self.error = msg
                }
            }
            await monitor.refresh()
        }
    }

    private func revoke(_ g: OrbJSON) {
        Task {
            acting = g["id"].text
            defer { acting = nil }
            do {
                _ = try await OrbCore.shared.call("/api/privilege-access/\(OrbCore.escape(g["id"].text))", method: "DELETE")
                error = ""
            } catch { self.error = error.localizedDescription }
            await monitor.refresh()
        }
    }

    private func toggleBunker(lock: Bool) {
        Task {
            acting = lock ? "bunker" : "unbunker"
            defer { acting = nil }
            do {
                try await monitor.setBunker(lock: lock)
                error = ""
            } catch is CancellationError {
            } catch {
                if let msg = OrbBiometric.friendlyError(error) {
                    self.error = msg
                }
            }
        }
    }
}

/// Home card while the fleet is in Bunker Mode, like desktop `BunkerModeCard`:
/// the level, the latest incident, Review and a Face ID-signed exit.
struct OrbBunkerModeCard: View {
    @State private var monitor = OrbPrivilegeAccessMonitor.shared
    @State private var exiting = false
    @State private var error = ""
    let review: () -> Void

    var body: some View {
        if monitor.showsBunkerCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(OrbStyle.error)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fleet Bunker Mode: \(OrbPrivilegeAccessMonitor.bunkerLabel(monitor.bunkerState))")
                            .font(.footnote.weight(.semibold))
                        Text("New privileged requests are locked and active root/deploy grants are revoked.")
                            .font(.caption).foregroundStyle(OrbStyle.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reason = monitor.latestIncidentReason {
                            Text(reason).font(.caption).italic().lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("home.bunker.reason")
                        }
                        if !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(OrbStyle.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { monitor.dismissBunkerCard() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(OrbStyle.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                HStack {
                    Button("Review", action: review)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("home.bunker.review")
                    Spacer()
                    Button { exit() } label: {
                        Label("Exit Bunker Mode", systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OrbStyle.success)
                    .disabled(exiting)
                    .accessibilityIdentifier("home.bunker.exit")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(OrbStyle.elevated, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.error.opacity(0.5)))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityIdentifier("home.bunker")
        }
    }

    private func exit() {
        Task {
            exiting = true
            defer { exiting = false }
            do {
                try await monitor.setBunker(lock: false)
                error = ""
            } catch is CancellationError {
            } catch {
                if let msg = OrbBiometric.friendlyError(error) {
                    self.error = msg
                }
            }
        }
    }
}

struct OrbPrivilegeAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OrbPrivilegeAccessList()
                .navigationTitle("Privileged access").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
