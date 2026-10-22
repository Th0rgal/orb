import UserNotifications
import LocalAuthentication
import SwiftUI

/// Device-owner check shared by every secret-granting action. Falls back to the
/// passcode, and lets simulators without any credential through, like the
/// Secrets settings page.
enum OrbBiometric {
    static var name: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "Passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// Returns nil on success, or a message to show. Cancellation returns "".
    static func authenticate(reason: String) async -> String? {
        #if DEBUG
        // UI tests on the loopback fixture: the simulator cannot do Face ID and
        // its passcode sheet blocks XCUITest. Same guard as `orb_test_reset`.
        // Never in release builds; real Core still requires a device signature.
        if UserDefaults.standard.bool(forKey: "orb_test_biometric_pass"),
           UserDefaults.standard.string(forKey: "api_base_url")?.hasPrefix("http://127.0.0.1:") == true {
            return nil
        }
        #endif
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &policyError) else { return nil }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason) ? nil : "Authentication was not completed."
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return ""
        } catch {
            return error.localizedDescription
        }
    }
}

/// Pending Bitwarden broker requests, polled while the app is in the foreground
/// (Orb polls the same snapshot every 10 s to badge its sidebar).
@MainActor
@Observable
final class OrbSecretRequestMonitor {
    static let shared = OrbSecretRequestMonitor()
    private(set) var pending: [OrbJSON] = []
    private(set) var projects: [OrbJSON] = []
    private var endpoint = ""

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { pending = []; projects = []; endpoint = current }
        guard let snap = await Log.attempt(.network, "secret requests", { try await OrbCore.shared.call("/api/bitwarden/broker") }) else { return false }
        guard current == OrbCore.shared.endpoint else { return true }
        pending = snap["requests"].items.filter { $0["status"].text == "pending" }
        if !pending.isEmpty && projects.isEmpty {
            projects = (try? await OrbCore.shared.call("/api/bitwarden/projects").items) ?? []
        }
        return true
    }

    /// Polls until the calling task is cancelled (the view leaves or the app backgrounds).
    func poll() async {
        await Poller.run(every: .seconds(10)) { await refresh() }
    }

    func projectName(_ id: String) -> String {
        guard !id.isEmpty else { return "" }
        let name = projects.first(where: { $0["id"].text == id })?["name"].text ?? ""
        return name.isEmpty ? String(id.prefix(8)) : name
    }

    func describe(_ r: OrbJSON) -> String {
        let key = r["key"].text, project = r["project_id"].text
        if r["kind"].text == "write" { return "Store \(key) in \(projectName(project))" }
        if r["kind"].text == "delete" { return "Delete \(key) from \(projectName(project))" }
        if r["kind"].text == "move" {
            return "Move \(key) from \(projectName(project)) to \(projectName(r["target_project_id"].text))"
        }
        if !key.isEmpty { return "Read \(key)" + (project.isEmpty ? "" : " (\(projectName(project)))") }
        if r["all_projects"].flag { return "Read every project" }
        return "Read project \(projectName(project))"
    }
}

/// Home banner: one tap opens the approval sheet.
struct OrbSecretRequestBanner: View {
    let count: Int
    let open: () -> Void
    var body: some View {
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "key.viewfinder").foregroundStyle(OrbStyle.warning)
                    Text(count == 1 ? "A mission is asking for a secret" : "\(count) missions are asking for secrets")
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
            .accessibilityIdentifier("home.secret-requests")
        }
    }
}

/// Approve (secret, project or all, with a grant lifetime) or decline pending
/// secret requests. Every approval is gated by Face ID / Touch ID.
struct OrbSecretRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var monitor = OrbSecretRequestMonitor.shared
    @State private var ttlHours = 24
    @State private var acting: String?
    @State private var error = ""
    private static let lifetimes: [(Int, String)] = [(1, "1 hour"), (8, "8 hours"), (24, "24 hours"), (72, "3 days"), (168, "7 days")]

    var body: some View {
        NavigationStack {
            List {
                OrbSettingsError(message: error)
                Section {
                    Picker("Grant lasts", selection: $ttlHours) {
                        ForEach(Self.lifetimes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } footer: {
                    Text("Approvals of read requests give the mission access for this long. Projects allowed by default are set in each project's secret access page.")
                }
                if monitor.pending.isEmpty {
                    Section { Text("No pending requests.").foregroundStyle(.secondary) }
                } else {
                    Section("Pending") {
                        ForEach(monitor.pending, id: \.selfID) { requestRow($0) }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Secret requests").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .refreshable { await monitor.refresh() }
            .task { await monitor.refresh() }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func who(_ r: OrbJSON) -> String {
        let title = r["mission_title"].text.isEmpty ? "Mission \(r["mission_id"].text.prefix(8))" : r["mission_title"].text
        return [title, r["paloma_project"].text, OrbStyle.relativeTime(r["created_at"].text)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func kindBadge(_ r: OrbJSON) -> String {
        ["write": "STORE", "delete": "DELETE", "move": "MOVE"][r["kind"].text] ?? "READ"
    }

    private func requestRow(_ r: OrbJSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.kindBadge(r))
                    .font(.system(.caption2, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((r["kind"].text == "read" ? OrbStyle.success : OrbStyle.warning).opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                Text(monitor.describe(r)).font(.subheadline.weight(.medium))
            }
            Text(who(r)).font(.caption).foregroundStyle(.secondary)
            if !r["reason"].text.isEmpty { Text("“\(r["reason"].text)”").font(.caption).italic() }
            requestActions(r)
        }
        .padding(.vertical, 4)
    }

    private func requestActions(_ r: OrbJSON) -> some View {
        HStack {
            if r["kind"].text != "read" {
                Button("Approve") { act(r, scope: "", reason: monitor.describe(r)) }
            } else {
                if !r["key"].text.isEmpty {
                    Button("Secret") { act(r, scope: "secret", reason: "Give a mission \(r["key"].text)") }
                }
                if !r["project_id"].text.isEmpty {
                    Button("Project") { act(r, scope: "project", reason: "Give a mission project \(monitor.projectName(r["project_id"].text))") }
                }
                Button("All") { act(r, scope: "all", reason: "Give a mission every secret project") }
            }
            Spacer()
            Button("Decline", role: .destructive) { act(r, scope: nil, reason: "") }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(acting != nil)
    }

    private func act(_ r: OrbJSON, scope: String?, reason: String) {
        Task {
            let id = r["id"].text
            // An enrolled phone signs the approval, which prompts for Face ID /
            // Touch ID itself; otherwise ask for it here.
            let enrolled = OrbApprovalKey.deviceId != nil && OrbApprovalKey.publicKey != nil
            if scope != nil, !enrolled, let message = await OrbBiometric.authenticate(reason: reason) {
                if !message.isEmpty { error = message }
                return
            }
            acting = id
            defer { acting = nil }
            do {
                if let scope {
                    var body: [String: OrbJSON] = ["ttl_hours": .number(Double(ttlHours))]
                    if !scope.isEmpty { body["scope"] = .string(scope) }
                    // Signed with this device's Secure Enclave key, which also
                    // prompts for Face ID / Touch ID, like the Settings page.
                    _ = try await OrbApprovalKey.signedCall(
                        "/api/bitwarden/requests/\(OrbCore.escape(id))/approve",
                        method: "POST", body: .object(body), summary: reason)
                } else {
                    _ = try await OrbCore.shared.call("/api/bitwarden/requests/\(OrbCore.escape(id))/reject", method: "POST")
                }
                error = ""
                OrbHaptics.success()
            } catch {
                self.error = error.localizedDescription
            }
            await monitor.refresh()
        }
    }
}

/// Bitwarden projects that a Paloma project's missions read without asking
/// (`PUT /api/bitwarden/default-access/:slug`), as in Orb's project settings.
struct OrbProjectSecretAccess: View {
    let slug: String
    @State private var client = OrbSettingsClient()
    @State private var status: OrbJSON = .null
    @State private var projects: [OrbJSON] = []
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""

    private var allowed: [String] {
        let explicit = status["default_access"][slug].items.map(\.text)
        if status["default_access"][slug] != .null { return explicit }
        let legacy = status["project_bindings"][slug].text
        return legacy.isEmpty ? [] : [legacy]
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                if loading && projects.isEmpty {
                    HStack(spacing: 8) { OrbRunningDots(size: 10); Text("Loading…").foregroundStyle(.secondary) }
                } else if projects.isEmpty {
                    Text(status["configured"].flag ? "No Bitwarden projects visible." : "Bitwarden is not connected.").foregroundStyle(.secondary)
                }
                ForEach(projects, id: \.selfID) { p in
                    Toggle(isOn: Binding(get: { allowed.contains(p.selfID) }, set: { on in Task { await toggle(p, on: on) } })) {
                        Text(p["name"].text.isEmpty ? p.selfID : p["name"].text)
                    }
                    .disabled(saving)
                }
            } footer: {
                Text("Missions in this project read secrets from the checked Bitwarden projects without asking. Anything else waits for your approval.")
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Secret access").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            status = try await client.call("/api/bitwarden/status")
            projects = status["configured"].flag ? ((try? await client.call("/api/bitwarden/projects").items) ?? []) : []
            error = ""
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func toggle(_ project: OrbJSON, on: Bool) async {
        guard !saving else { return }
        let id = project.selfID, name = project["name"].text.isEmpty ? id : project["name"].text
        let next = on ? Array(Set(allowed + [id])) : allowed.filter { $0 != id }
        let reason = on ? "Let \(slug) missions read \(name) secrets without asking" : "Stop default access to \(name)"
        if let message = await OrbBiometric.authenticate(reason: reason) {
            if !message.isEmpty { error = message }
            return
        }
        saving = true
        defer { saving = false }
        do {
            status = try await client.call("/api/bitwarden/default-access/\(OrbCore.escape(slug))", method: "PUT", body: .object(["project_ids": .array(next.map { .string($0) })]))
            error = ""
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Mission access requests

/// Missions asking to read another mission outside their tree
/// (`GET /api/mission-access`), polled like secret requests. Approving needs a
/// device signature (Face ID / Touch ID); grants are read-only and expire.
@MainActor
@Observable
final class OrbMissionAccessMonitor {
    static let shared = OrbMissionAccessMonitor()
    private(set) var requests: [OrbJSON] = []
    private(set) var audit: [OrbJSON] = []
    /// Set when a mission access notification is tapped; the home view opens the sheet.
    var openRequested = false
    private var endpoint = ""
    private var announced: Set<String> = []

    var pending: [OrbJSON] { requests.filter { $0["state"].text == "pending" } }
    var grants: [OrbJSON] { requests.filter(Self.isLive) }
    var history: [OrbJSON] { requests.filter { $0["state"].text != "pending" && !Self.isLive($0) } }

    static func isLive(_ r: OrbJSON) -> Bool {
        guard r["state"].text == "approved" else { return false }
        return OrbStyle.parseDate(r["expires_at"].text).map { $0 > Date() } ?? false
    }

    static func mission(_ title: String, _ id: String) -> String {
        title.isEmpty ? "Mission \(id.prefix(8))" : title
    }
    static func requester(_ r: OrbJSON) -> String { mission(r["requester_title"].text, r["requester_mission_id"].text) }
    static func target(_ r: OrbJSON) -> String { mission(r["target_title"].text, r["target_mission_id"].text) }

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { requests = []; audit = []; announced = []; endpoint = current }
        guard let snap = await Log.attempt(.network, "mission access", { try await OrbCore.shared.call("/api/mission-access") }) else { return false }
        guard current == OrbCore.shared.endpoint else { return true }
        requests = snap["requests"].items
        audit = snap["audit"].items
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
            content.title = "Mission access request"
            content.body = "\(Self.requester(r)) wants to read \(Self.target(r)): \(r["reason"].text)"
            content.threadIdentifier = "orb.mission-access"
            content.userInfo = ["orb_mission_access": r["id"].text]
            let request = UNNotificationRequest(identifier: "orb.mission-access.\(r["id"].text)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
}

struct OrbMissionAccessBanner: View {
    let count: Int
    let open: () -> Void
    var body: some View {
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.trianglebadge.exclamationmark").foregroundStyle(OrbStyle.warning)
                    Text(count == 1 ? "A mission asks to read another mission" : "\(count) missions ask for read access")
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
            .accessibilityIdentifier("home.access-requests")
        }
    }
}

/// Pending requests (approve with Face ID / Touch ID, or deny), live grants
/// (revoke) and recent history. Used as the home sheet and in Settings.
struct OrbMissionAccessList: View {
    @State private var monitor = OrbMissionAccessMonitor.shared
    @State private var ttlHours = 24
    @State private var acting: String?
    @State private var error = ""
    private static let lifetimes: [(Int, String)] = [(1, "1 hour"), (8, "8 hours"), (24, "24 hours"), (72, "3 days"), (168, "7 days")]

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                Picker("Grant lasts", selection: $ttlHours) {
                    ForEach(Self.lifetimes, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("A grant lets one mission read another (events, messages, shared files). It never allows sending messages, cancel, resume or placement.")
            }
            Section("Pending") {
                if monitor.pending.isEmpty { Text("No pending requests.").foregroundStyle(.secondary) }
                ForEach(monitor.pending, id: \.selfID) { pendingRow($0) }
            }
            Section("Active grants") {
                if monitor.grants.isEmpty { Text("No active grants.").foregroundStyle(.secondary) }
                ForEach(monitor.grants, id: \.selfID) { grantRow($0) }
            }
            if !monitor.history.isEmpty {
                Section("History") {
                    ForEach(monitor.history.prefix(20), id: \.selfID) { r in
                        HStack {
                            Text(r["state"].text.uppercased()).font(.system(.caption2, weight: .bold)).foregroundStyle(.secondary)
                            Text("\(OrbMissionAccessMonitor.requester(r)) → \(OrbMissionAccessMonitor.target(r))").font(.caption)
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
            HStack(spacing: 6) {
                Text("READ")
                    .font(.system(.caption2, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(OrbStyle.success.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                Text(OrbMissionAccessMonitor.target(r)).font(.subheadline.weight(.medium))
            }
            Text("asked by \(OrbMissionAccessMonitor.requester(r)) · \(OrbStyle.relativeTime(r["created_at"].text))").font(.caption).foregroundStyle(.secondary)
            if !r["reason"].text.isEmpty { Text("“\(r["reason"].text)”").font(.caption).italic() }
            HStack {
                Button {
                    act(r, approve: true)
                } label: {
                    Label("Allow read", systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(OrbStyle.success)
                .accessibilityIdentifier("access.approve.\(r["id"].text)")
                Spacer()
                Button("Deny", role: .destructive) { act(r, approve: false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("access.deny.\(r["id"].text)")
            }
            .controlSize(.small)
            .disabled(acting != nil)
        }
        .padding(.vertical, 4)
    }

    static func left(_ raw: String, now: Date = Date()) -> String {
        guard let end = OrbStyle.parseDate(raw) else { return "expired" }
        let minutes = Int(end.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "expired" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }

    private func grantRow(_ g: OrbJSON) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(OrbMissionAccessMonitor.requester(g)) → \(OrbMissionAccessMonitor.target(g))").font(.subheadline)
                Text("Read only · \(Self.left(g["expires_at"].text))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { revoke(g) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(acting != nil)
                .accessibilityIdentifier("access.revoke.\(g["id"].text)")
        }
    }

    private func act(_ r: OrbJSON, approve: Bool) {
        Task {
            let id = r["id"].text
            let reason = approve
                ? "Let \(OrbMissionAccessMonitor.requester(r)) read \(OrbMissionAccessMonitor.target(r)) for \(ttlHours) h"
                : "Decline a mission access request"
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
                let path = "/api/mission-access/\(OrbCore.escape(id))/\(approve ? "approve" : "deny")"
                _ = try await OrbApprovalKey.signedCall(path, method: "POST",
                                                        body: approve ? .object(["ttl_hours": .number(Double(ttlHours))]) : nil,
                                                        summary: reason)
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
                _ = try await OrbCore.shared.call("/api/mission-access/\(OrbCore.escape(g["id"].text))", method: "DELETE")
                error = ""
            } catch { self.error = error.localizedDescription }
            await monitor.refresh()
        }
    }
}

struct OrbMissionAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OrbMissionAccessList()
                .navigationTitle("Mission access").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
