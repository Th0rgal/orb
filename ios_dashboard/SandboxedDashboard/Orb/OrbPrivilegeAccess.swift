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
    private(set) var bunkered = false
    /// Set when a privileged access notification is tapped; the home view opens the sheet.
    var openRequested = false
    private var endpoint = ""
    private var announced: Set<String> = []

    var pending: [OrbJSON] { requests.filter { $0["state"].text == "pending" } }
    var grants: [OrbJSON] { requests.filter { Self.isLive($0) } }
    var history: [OrbJSON] { requests.filter { $0["state"].text != "pending" && !Self.isLive($0) } }

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

    /// What one "Approve all" grants: count per tier (root first), hosts and
    /// missions. Same strings as desktop `batchSummary`.
    struct Batch: Equatable { let tiers: String; let hosts: String; let missions: String; let root: Int }
    static func batchSummary(_ rs: [OrbJSON]) -> Batch {
        let tiers = ["root_exec", "service_deploy", "ops_read"].compactMap { s -> String? in
            let n = rs.filter { $0["scope"].text == s }.count
            return n > 0 ? "\(n) \(scopeLabel(s))" : nil
        }
        return Batch(
            tiers: tiers.joined(separator: " · "),
            hosts: Set(rs.map { $0["target_host"].text }).sorted().map(host).joined(separator: ", "),
            missions: Set(rs.map(requester)).sorted().joined(separator: ", "),
            root: rs.filter { $0["scope"].text == "root_exec" }.count
        )
    }
    /// Root stays out of "Approve all" unless ticked; Core enforces it too (`confirm_root`).
    static func batchApprovable(_ rs: [OrbJSON], includeRoot: Bool) -> [OrbJSON] {
        rs.filter { includeRoot || $0["scope"].text != "root_exec" }
    }
    /// The signed body for `/api/approvals/approve-all`: each request by Core's
    /// digest of what it grants. Core refuses the whole batch if one changed.
    static func batchBody(_ rs: [OrbJSON]) -> OrbJSON {
        .object([
            "items": .array(rs.map { r in
                .object(["kind": .string("privilege"), "id": r["id"], "digest": .string(r["digest"].text)])
            }),
            "confirm_critical": .bool(batchSummary(rs).root > 0),
        ])
    }

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { requests = []; commands = []; announced = []; endpoint = current }
        guard let snap = await Log.attempt(.network, "privilege access", { try await OrbCore.shared.call("/api/privilege-access") }) else { return false }
        guard current == OrbCore.shared.endpoint else { return true }
        requests = snap["requests"].items
        commands = snap["command_audit"].items
        bunkered = (snap["bunker_state"].doubleValue ?? 0) > 0
        announce()
        return true
    }

    func poll() async {
        await Poller.run(every: .seconds(10)) { await refresh() }
    }

    /// One local notification per new pending request.
    private func announce() {
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

struct OrbPrivilegeAccessBanner: View {
    let count: Int
    let open: () -> Void
    var body: some View {
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(OrbStyle.warning)
                    Text(count == 1 ? "A mission asks for privileged access" : "\(count) missions ask for privileged access")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("\(count)")
                        .font(.system(.caption, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(OrbStyle.warning.opacity(0.25), in: Capsule())
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(OrbStyle.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(OrbStyle.elevated, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
                .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.borderStrong))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityIdentifier("home.privilege-requests")
        }
    }
}

/// Pending requests (approve with Face ID / Touch ID, or deny), live grants
/// (revoke), history and Core's per-command audit. Home sheet and Settings.
struct OrbPrivilegeAccessList: View {
    @State private var monitor = OrbPrivilegeAccessMonitor.shared
    @State private var acting: String?
    @State private var error = ""
    @State private var includeRoot = false

    var body: some View {
        List {
            OrbSettingsError(message: error)
            if monitor.bunkered {
                Section { Label("Bunker Mode is on: new privileged requests are locked.", systemImage: "lock.shield").font(.footnote) }
            }
            Section {
                if monitor.pending.isEmpty { Text("No pending requests.").foregroundStyle(.secondary) }
                ForEach(monitor.pending, id: \.selfID) { pendingRow($0) }
                if monitor.pending.count > 1 { approveAllRow }
            } header: { Text("Pending") } footer: {
                Text("A grant lasts at most the mission session. Core checks and logs every command, and you can revoke it at any time.")
            }
            Section("Active grants") {
                if monitor.grants.isEmpty { Text("No active grants.").foregroundStyle(.secondary) }
                ForEach(monitor.grants, id: \.selfID) { grantRow($0) }
            }
            if !monitor.history.isEmpty || !monitor.commands.isEmpty {
                Section("Activity") {
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

    /// One Face ID / Touch ID for every pending request shown, root only when ticked.
    private var approveAllRow: some View {
        let summary = OrbPrivilegeAccessMonitor.batchSummary(monitor.pending)
        let ready = OrbPrivilegeAccessMonitor.batchApprovable(monitor.pending, includeRoot: includeRoot)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.tiers) · on \(summary.hosts)").font(.caption.weight(.medium))
            Text("for \(summary.missions)").font(.caption).foregroundStyle(.secondary)
            if summary.root > 0 {
                Toggle(isOn: $includeRoot) {
                    Text(summary.root == 1 ? "Include the root request (any command as root)" : "Include \(summary.root) root requests (any command as root)")
                        .font(.caption).foregroundStyle(OrbStyle.error)
                }
                .accessibilityIdentifier("privilege.approve-all.include-root")
            }
            Button {
                approveAll(ready)
            } label: {
                Label(ready.count == monitor.pending.count ? "Approve all" : "Approve \(ready.count)",
                      systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .tint(OrbStyle.success)
            .controlSize(.small)
            .disabled(acting != nil || ready.isEmpty)
            .accessibilityIdentifier("privilege.approve-all")
        }
        .padding(.vertical, 4)
    }

    private func approveAll(_ rs: [OrbJSON]) {
        Task {
            let s = OrbPrivilegeAccessMonitor.batchSummary(rs)
            let reason = "Grant \(rs.count) privileged requests (\(s.tiers)) on \(s.hosts)"
            let enrolled = OrbApprovalKey.deviceId != nil && OrbApprovalKey.publicKey != nil
            if !enrolled, let message = await OrbBiometric.authenticate(reason: reason) {
                if !message.isEmpty { error = message }
                return
            }
            acting = "all"
            defer { acting = nil }
            do {
                _ = try await OrbApprovalKey.signedCall("/api/approvals/approve-all", method: "POST",
                                                        body: OrbPrivilegeAccessMonitor.batchBody(rs), summary: reason)
                error = ""
                includeRoot = false
                OrbHaptics.success()
            } catch {
                self.error = error.localizedDescription
            }
            await monitor.refresh()
        }
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
                    Label("Allow", systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
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
            let enrolled = OrbApprovalKey.deviceId != nil && OrbApprovalKey.publicKey != nil
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
                self.error = error.localizedDescription
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
