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

/// Unified Security → Access view: Fleet posture & Bunker Mode, unified pending
/// approvals, approval devices & phone enrollment, live privilege + mission-access
/// grants, and collapsed-by-default coalesced activity log.
struct OrbPrivilegeAccessList: View {
    @State private var monitor = OrbPrivilegeAccessMonitor.shared
    @State private var missionAccess = OrbMissionAccessMonitor.shared
    @State private var approvals = OrbApprovalQueue.shared
    @State private var secrets = OrbSecretRequestMonitor.shared
    @State private var client = OrbSettingsClient()
    @State private var devices: [OrbJSON] = []
    @State private var approvalMode = ""
    @State private var enrolledHere = false
    @State private var enrollSheet = false
    @State private var showAllGrants = false
    @State private var showActivity = false
    @State private var selectedDetail: OrbActivityDetailItem?
    @State private var acting: String?
    @State private var error = ""

    private var dedupedMissionGrants: [OrbJSON] {
        OrbActivityCompaction.dedupeMissionGrants(missionAccess.grants)
    }

    private var coalescedCommands: [OrbActivityCompaction.CoalescedCommand] {
        OrbActivityCompaction.coalescePrivilegeCommands(monitor.commands)
    }

    private var totalGrantCount: Int {
        monitor.grants.count + dedupedMissionGrants.count
    }

    private var totalActivityCount: Int {
        monitor.incidents.count + monitor.history.count + missionAccess.history.count + coalescedCommands.count
    }

    private var activitySummaryLabel: String {
        var parts: [String] = []
        if !coalescedCommands.isEmpty { parts.append("\(coalescedCommands.count) cmd\(coalescedCommands.count == 1 ? "" : "s")") }
        let histCount = monitor.history.count + missionAccess.history.count
        if histCount > 0 { parts.append("\(histCount) history") }
        if !monitor.incidents.isEmpty { parts.append("\(monitor.incidents.count) incident\(monitor.incidents.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "0" : parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            postureSection
            pendingSection
            devicesSection
            grantsSection
            activitySection
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .refreshable { await refreshAll() }
        .task { await refreshAll() }
        .sheet(isPresented: $enrollSheet, onDismiss: { Task { await loadDevices() } }) {
            OrbApprovalEnrollmentSheet()
        }
        .sheet(item: $selectedDetail) { item in
            OrbActivityDetailSheet(item: item)
        }
    }

    private var postureSection: some View {
        Section("Fleet posture") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: monitor.bunkered ? "lock.shield.fill" : "checkmark.shield")
                        .foregroundStyle(monitor.bunkered ? OrbStyle.error : OrbStyle.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OrbPrivilegeAccessMonitor.bunkerLabel(monitor.bunkerState))
                            .font(.subheadline.weight(.semibold))
                        Text(postureSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(monitor.bunkered ? 2 : 1)
                    }
                    Spacer(minLength: 8)
                    if monitor.bunkered {
                        Button {
                            toggleBunker(lock: false)
                        } label: {
                            Label("Exit", systemImage: OrbBiometric.symbolName)
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OrbStyle.success)
                        .controlSize(.small)
                        .disabled(acting != nil)
                        .accessibilityIdentifier("privilege.unbunker")
                    } else {
                        Button(role: .destructive) {
                            toggleBunker(lock: true)
                        } label: {
                            Label("Lock Down", systemImage: OrbBiometric.symbolName)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(acting != nil)
                        .accessibilityIdentifier("privilege.bunker")
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var postureSubtitle: String {
        if monitor.bunkered {
            return "Privileged requests locked · active grants revoked"
        }
        if let mesh = monitor.meshStatus {
            return "Epoch \(Int(mesh["epoch"].doubleValue ?? 0)) · \(mesh["formal_verified"].flag ? "Lean 4 verified" : "canary armed")"
        }
        return "Canary tripwires & dead-man heartbeats armed"
    }

    @ViewBuilder
    private var pendingSection: some View {
        if !approvals.items.isEmpty {
            Section("Pending approvals (\(approvals.items.count))") {
                ForEach(approvals.items, id: \.selfID) { item in
                    queuePendingRow(item)
                        .onAppear { OrbUsageTelemetry.shared.approvalShown(item["id"].text) }
                }
                if approvals.items.count > 1 {
                    let critical = approvals.items.contains(where: OrbApprovalQueue.isCritical)
                    HStack {
                        Spacer()
                        Button {
                            approveQueueBatch(OrbApprovalQueue.allBatch(approvals.items))
                        } label: {
                            Label(OrbApprovalQueue.approveAllLabel(approvals.items), systemImage: OrbBiometric.symbolName)
                                .foregroundStyle(critical ? Color.white : Color.black)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(critical ? OrbStyle.error : OrbStyle.success)
                        .controlSize(.small)
                        .disabled(acting != nil)
                        .accessibilityIdentifier("approvals.approve-all")
                    }
                }
            }
        }
    }

    private var devicesSection: some View {
        Section("Approval devices") {
            if enrolledHere {
                Toggle("Require phone signature", isOn: Binding(
                    get: { approvalMode == "enforce" },
                    set: { enforce in setApprovalMode(enforce ? "enforce" : "warn") }
                ))
                .disabled(acting != nil)
            }
            ForEach(devices, id: \.selfID) { d in
                let isMine = d["public_key"].text == OrbApprovalKey.publicKey
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d["name"].text + (isMine ? " (this iPhone)" : ""))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(d["platform"].text.isEmpty ? "Approval key" : d["platform"].text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { removeDevice(d) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(acting != nil)
                }
            }
            if !enrolledHere {
                Button {
                    enrollSheet = true
                } label: {
                    Label("Enroll this iPhone (\(OrbBiometric.name))…", systemImage: OrbBiometric.symbolName)
                }
                .accessibilityIdentifier("security.enroll-phone")
            }
        }
    }

    @ViewBuilder
    private var grantsSection: some View {
        if totalGrantCount > 0 {
            Section("Active grants (\(totalGrantCount))") {
                if totalGrantCount > 3 && !showAllGrants {
                    ForEach(monitor.grants.prefix(2), id: \.selfID) { grantRow($0) }
                    let remainingSlots = max(0, 2 - monitor.grants.prefix(2).count)
                    ForEach(dedupedMissionGrants.prefix(remainingSlots), id: \.selfID) { missionGrantRow($0) }
                    Button("Show all \(totalGrantCount) active grants") {
                        withAnimation(.snappy(duration: 0.18)) { showAllGrants = true }
                    }
                    .font(.caption.weight(.medium))
                } else {
                    ForEach(monitor.grants, id: \.selfID) { grantRow($0) }
                    ForEach(dedupedMissionGrants, id: \.selfID) { missionGrantRow($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if totalActivityCount > 0 {
            Section {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showActivity.toggle() }
                } label: {
                    HStack {
                        Image(systemName: showActivity ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(showActivity ? "Hide activity" : "Show activity")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(activitySummaryLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity.toggle")

                if showActivity {
                    ForEach(monitor.incidents.prefix(20), id: \.selfID) { inc in
                        let badge = inc["dry_run"].flag ? "CANARY" : OrbPrivilegeAccessMonitor.bunkerLabel(Int(inc["new_bunker_state"].doubleValue ?? 0)).uppercased()
                        let summary = "\(!inc["peer_name"].text.isEmpty ? "\(inc["peer_name"].text) · " : "")\(inc["reason"].text) (epoch \(Int(inc["epoch"].doubleValue ?? 0)))"
                        Button {
                            selectedDetail = OrbActivityDetailItem(
                                title: badge,
                                subtitle: OrbStyle.relativeTime(inc["at"].text),
                                body: summary
                            )
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(badge)
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(inc["dry_run"].flag ? .secondary : OrbStyle.error)
                                Text(summary)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(monitor.history.prefix(20), id: \.selfID) { r in
                        let summary = "\(OrbPrivilegeAccessMonitor.requester(r)) · \(OrbPrivilegeAccessMonitor.title(r))"
                        Button {
                            selectedDetail = OrbActivityDetailItem(
                                title: "Privileged access · \(r["state"].text.uppercased())",
                                subtitle: OrbStyle.relativeTime(r["decided_at"].text.isEmpty ? r["created_at"].text : r["decided_at"].text),
                                body: [summary, r["reason"].text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                            )
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r["state"].text.uppercased())
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(summary)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(missionAccess.history.prefix(20), id: \.selfID) { r in
                        let summary = "\(OrbMissionAccessMonitor.requester(r)) → \(OrbMissionAccessMonitor.target(r))"
                        Button {
                            selectedDetail = OrbActivityDetailItem(
                                title: "Mission access · \(r["state"].text.uppercased())",
                                subtitle: OrbStyle.relativeTime(r["created_at"].text),
                                body: [summary, r["reason"].text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                            )
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r["state"].text.uppercased())
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(summary)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(coalescedCommands.prefix(40)) { c in
                        Button {
                            selectedDetail = OrbActivityDetailItem(
                                title: "\(c.status) · \(c.host)",
                                subtitle: c.timestamp.isEmpty ? "" : OrbStyle.relativeTime(c.timestamp),
                                body: [c.command, c.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
                            )
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(c.status)
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(c.exitCode == 0 ? OrbStyle.success : (c.exitCode == nil ? .secondary : OrbStyle.error))
                                Text("\(c.host) · \(c.command)")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                if !c.timestamp.isEmpty {
                                    Text(OrbStyle.relativeTime(c.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Activity")
            }
        }
    }

    private func queuePendingRow(_ i: OrbJSON) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(OrbApprovalQueue.title(i))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OrbApprovalQueue.isCritical(i) ? OrbStyle.error : Color.primary)
            Text("asked by \(OrbApprovalQueue.requester(i)) · \(OrbStyle.relativeTime(i["created_at"].text))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !i["reason"].text.isEmpty {
                Text("“\(i["reason"].text)”")
                    .font(.caption)
                    .italic()
                    .lineLimit(2)
            }
            let detail = OrbApprovalQueue.detail(i, projectName: secrets.projectName)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Button {
                    approveQueueBatch([i])
                } label: {
                    Label("Allow", systemImage: OrbBiometric.symbolName)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(OrbStyle.success)
                .accessibilityIdentifier(
                    i["kind"].text == "privilege"
                        ? "privilege.approve.\(i["id"].text)"
                        : "approvals.approve.\(i["kind"].text).\(i["id"].text)"
                )
                Spacer()
                Button("Deny", role: .destructive) {
                    denyQueueItem(i)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    i["kind"].text == "privilege"
                        ? "privilege.deny.\(i["id"].text)"
                        : "approvals.deny.\(i["kind"].text).\(i["id"].text)"
                )
            }
            .controlSize(.small)
            .disabled(acting != nil)
        }
        .padding(.vertical, 2)
    }

    private func grantRow(_ g: OrbJSON) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(OrbPrivilegeAccessMonitor.requester(g)) · \(OrbPrivilegeAccessMonitor.title(g))")
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(g["session_scoped"].flag ? "Session" : "Fixed") · \(OrbMissionAccessList.left(g["expires_at"].text))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { revoke(g) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(acting != nil)
                .accessibilityIdentifier("privilege.revoke.\(g["id"].text)")
        }
    }

    private func missionGrantRow(_ g: OrbJSON) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(OrbMissionAccessMonitor.requester(g)) → \(OrbMissionAccessMonitor.target(g))")
                    .font(.subheadline)
                    .lineLimit(1)
                Text("Read only · \(OrbMissionAccessList.left(g["expires_at"].text))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { revokeMissionGrant(g) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(acting != nil)
                .accessibilityIdentifier("access.revoke.\(g["id"].text)")
        }
    }

    private func refreshAll() async {
        async let p: Bool = monitor.refresh()
        async let m: Bool = missionAccess.refresh()
        async let q: Bool = approvals.refresh()
        async let d: Void = loadDevices()
        _ = await (p, m, q, d)
    }

    private func loadDevices() async {
        guard let d = try? await client.call("/api/approvals/devices") else { return }
        devices = d["devices"].items
        approvalMode = d["mode"].text
        let mine = OrbApprovalKey.publicKey
        let match = devices.first { mine != nil && $0["public_key"].text == mine }
        OrbApprovalKey.deviceId = match?["id"].text
        enrolledHere = match != nil
    }

    private func setApprovalMode(_ mode: String) {
        Task {
            acting = "mode"
            defer { acting = nil }
            do {
                _ = try await OrbApprovalKey.signedCall(
                    "/api/approvals/mode",
                    method: "PUT",
                    body: .object(["mode": .string(mode)]),
                    summary: "Set approval mode to \(mode)"
                )
                error = ""
                OrbHaptics.success()
            } catch {
                if let msg = OrbBiometric.friendlyError(error) { self.error = msg }
            }
            await loadDevices()
        }
    }

    private func removeDevice(_ d: OrbJSON) {
        Task {
            acting = d["id"].text
            defer { acting = nil }
            do {
                _ = try await OrbApprovalKey.signedCall(
                    "/api/approvals/devices/\(OrbCore.escape(d["id"].text))",
                    method: "DELETE",
                    summary: "Remove approval device \(d["name"].text)"
                )
                error = ""
            } catch {
                if let msg = OrbBiometric.friendlyError(error) { self.error = msg }
            }
            await loadDevices()
        }
    }

    private func approveQueueBatch(_ items: [OrbJSON]) {
        Task {
            acting = "queue"
            defer { acting = nil }
            do {
                try await approvals.approve(items)
                error = ""
                OrbHaptics.success()
            } catch {
                if let msg = OrbBiometric.friendlyError(error) { self.error = msg }
            }
            await refreshAll()
        }
    }

    private func denyQueueItem(_ item: OrbJSON) {
        Task {
            acting = item["id"].text
            defer { acting = nil }
            do {
                try await approvals.deny(item)
                error = ""
            } catch {
                if let msg = OrbBiometric.friendlyError(error) { self.error = msg }
            }
            await refreshAll()
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

    private func revokeMissionGrant(_ g: OrbJSON) {
        Task {
            acting = g["id"].text
            defer { acting = nil }
            do {
                _ = try await OrbCore.shared.call("/api/mission-access/\(OrbCore.escape(g["id"].text))", method: "DELETE")
                error = ""
            } catch { self.error = error.localizedDescription }
            await missionAccess.refresh()
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

struct OrbActivityDetailItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let body: String
}

struct OrbActivityDetailSheet: View {
    let item: OrbActivityDetailItem
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
            .background(OrbStyle.background)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = item.body
                        copied = true
                        OrbHaptics.light()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
