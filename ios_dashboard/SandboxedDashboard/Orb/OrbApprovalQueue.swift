import SwiftUI

// MARK: - Approval queue

/// Every request a mission raises for the user's approval, of any kind
/// (`secret`, `privilege`, `mission_access`), as Core lists it
/// (`GET /api/approvals/queue`, src/api/approval_queue.rs). Approving signs
/// `{kind, id, digest}` for each item with one Face ID / Touch ID; Core admits
/// the batch only when every item is still pending, unchanged and, if critical,
/// confirmed (the Lean `orb_verify_approval` gate). Same names as desktop
/// `approvalQueue.ts` and Android `OrbApprovalQueue.kt`, checked against
/// `shared/orb-spec/fixtures/approvals.json`.
@MainActor
@Observable
final class OrbApprovalQueue {
    static let shared = OrbApprovalQueue()
    private(set) var items: [OrbJSON] = []
    /// Set when an approval notification is tapped; the home view opens the sheet.
    var openRequested = false
    private var endpoint = ""

    private static let secretVerb = ["read": "Read", "write": "Store", "delete": "Delete", "move": "Move"]
    private static let riskOrder = ["critical", "elevated", "routine"]

    /// What approving does, in a few words ("Root on its own node", "Store DEPLOY_TOKEN").
    static func title(_ i: OrbJSON) -> String {
        let r = i["request"]
        switch i["kind"].text {
        case "privilege": return OrbPrivilegeAccessMonitor.title(r)
        case "mission_access": return "Read \(OrbMissionAccessMonitor.mission(r["target_title"].text, r["target_mission_id"].text))"
        default:
            let verb = secretVerb[i["tier"].text] ?? "Read"
            if !r["key"].text.isEmpty { return "\(verb) \(r["key"].text)" }
            return r["all_projects"].flag ? "\(verb) every secret project" : "\(verb) a whole secret project"
        }
    }

    static func requester(_ i: OrbJSON) -> String {
        OrbMissionAccessMonitor.mission(i["requester_title"].text, i["requester_mission_id"].text)
    }

    /// The fine print: what it unlocks and for how long, and for secrets the
    /// project a write lands in, a delete removes from, or a move goes between.
    static func detail(_ i: OrbJSON, projectName: (String) -> String = { String($0.prefix(8)) }) -> String {
        let r = i["request"]
        func project(_ key: String) -> String { r[key].text.isEmpty ? "" : projectName(r[key].text) }
        switch i["kind"].text {
        case "secret":
            let from = project("project_id")
            switch i["tier"].text {
            case "move":
                let to = project("target_project_id")
                return "From \(from.isEmpty ? "unknown project" : from) to \(to.isEmpty ? "unknown project" : to)"
            case "delete": return "From \(from.isEmpty ? "unknown project" : from)"
            case "write": return from.isEmpty ? "" : "Into \(from)"
            default: return ""
            }
        case "privilege": return "Allows \(OrbPrivilegeAccessMonitor.unlocks(r)) · \(OrbPrivilegeAccessMonitor.lifetime(r))"
        case "mission_access": return "Read only · \(Int(r["ttl_hours"].doubleValue ?? 0)) h · no messages, cancel or resume"
        default: return ""
        }
    }

    static func isCritical(_ i: OrbJSON) -> Bool { i["risk"].text == "critical" }

    /// The "Approve all" line: risks most severe first, then who asks.
    struct Summary: Equatable { let risks: String; let missions: String; let critical: Int }
    static func summary(_ items: [OrbJSON]) -> Summary {
        let risks = riskOrder.compactMap { k -> String? in
            let n = items.filter { $0["risk"].text == k }.count
            return n > 0 ? "\(n) \(k)" : nil
        }
        return Summary(
            risks: risks.joined(separator: " · "),
            missions: Set(items.map(requester)).sorted().joined(separator: ", "),
            critical: items.filter(isCritical).count
        )
    }

    /// What "Approve all" covers: critical items only when ticked.
    /// Core's per-signature limit (`MAX_BATCH` in src/api/approval_queue.rs).
    static let maxBatch = 20

    /// At most `maxBatch`; the rest stay for the next signature.
    static func batchApprovable(_ items: [OrbJSON], includeCritical: Bool) -> [OrbJSON] {
        Array(items.filter { includeCritical || !isCritical($0) }.prefix(maxBatch))
    }

    /// The signed body: each item by Core's digest. A single item is its own confirmation.
    static func batchBody(_ items: [OrbJSON]) -> OrbJSON {
        .object([
            "items": .array(items.map { .object(["kind": $0["kind"], "id": $0["id"], "digest": $0["digest"]]) }),
            "confirm_critical": .bool(items.contains(where: isCritical)),
        ])
    }

    /// What the device prompt says: every item, critical first.
    static func signingReason(_ items: [OrbJSON]) -> String {
        if items.count == 1 { return "\(title(items[0])) for \(requester(items[0]))" }
        let rank = { (i: OrbJSON) in riskOrder.firstIndex(of: i["risk"].text) ?? riskOrder.count }
        let sorted = items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return "Approve \(items.count) requests (\(summary(items).risks)): " + sorted.map(title).joined(separator: "; ")
    }

    static func denyPath(_ i: OrbJSON) -> String {
        let id = OrbCore.escape(i["id"].text)
        switch i["kind"].text {
        case "privilege": return "/api/privilege-access/\(id)/deny"
        case "mission_access": return "/api/mission-access/\(id)/deny"
        default: return "/api/bitwarden/requests/\(id)/reject"
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { items = []; endpoint = current }
        guard let snap = await Log.attempt(.network, "approval queue", { try await OrbCore.shared.call("/api/approvals/queue") }) else { return false }
        guard current == OrbCore.shared.endpoint else { return true }
        items = snap["items"].items
        return true
    }

    func poll() async {
        await Poller.run(every: .seconds(10)) { await refresh() }
    }

    func approve(_ items: [OrbJSON]) async throws {
        let reason = Self.signingReason(items)
        // An enrolled device signs (and prompts for Face ID / Touch ID itself);
        // otherwise ask here. Core still requires a signature to approve.
        let enrolled = OrbApprovalKey.deviceId != nil && OrbApprovalKey.publicKey != nil
        if !enrolled, let message = await OrbBiometric.authenticate(reason: reason) {
            throw NSError(domain: "orb.approvals", code: 1, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Cancelled" : message])
        }
        _ = try await OrbApprovalKey.signedCall("/api/approvals/approve-all", method: "POST", body: Self.batchBody(items), summary: reason)
        await refresh()
    }

    func deny(_ item: OrbJSON) async throws {
        _ = try await OrbApprovalKey.signedCall(Self.denyPath(item), method: "POST", summary: "Decline: \(Self.title(item))")
        await refresh()
    }
}

/// Home banner for every pending approval; one tap opens the queue.
struct OrbApprovalQueueBanner: View {
    let count: Int
    let critical: Int
    let open: () -> Void
    var body: some View {
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: critical > 0 ? "lock.trianglebadge.exclamationmark" : "checkmark.shield")
                        .foregroundStyle(critical > 0 ? OrbStyle.error : OrbStyle.warning)
                    Text(count == 1 ? "A mission is waiting for your approval" : "\(count) requests are waiting for your approval")
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
            .accessibilityIdentifier("home.approvals")
        }
    }
}

/// Every pending approval: Allow / Deny per row, and "Approve all" with one
/// Face ID / Touch ID. Critical rows stand out and stay out of "Approve all"
/// unless ticked. Scope and lifetime choices stay in each kind's own sheet.
struct OrbApprovalQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue = OrbApprovalQueue.shared
    /// Bitwarden project names for secret rows.
    @State private var secrets = OrbSecretRequestMonitor.shared
    @State private var acting = false
    @State private var includeCritical = false
    @State private var error = ""
    @State private var secretSheet = false
    @State private var privilegeSheet = false
    @State private var accessSheet = false

    var body: some View {
        NavigationStack {
            List {
                OrbSettingsError(message: error)
                if queue.items.isEmpty {
                    Section { Text("Nothing is waiting for your approval.").foregroundStyle(.secondary) }
                } else {
                    Section {
                        ForEach(queue.items, id: \.selfID) { row($0) }
                    }
                    if queue.items.count > 1 { approveAllSection }
                }
                Section {
                    Button("Secret requests: scope and lifetime") { secretSheet = true }
                    Button("Privileged access: grants and activity") { privilegeSheet = true }
                    Button("Mission access: grants and activity") { accessSheet = true }
                } footer: {
                    Text("Allow here uses each request's default scope and lifetime.")
                }
            }
            .scrollContentBackground(.hidden).background(OrbStyle.background)
            .navigationTitle("Approvals").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .refreshable { await queue.refresh() }
            .task { await queue.refresh() }
            .onChange(of: queue.items.map { $0["digest"].text }) { _, _ in includeCritical = false }
            .sheet(isPresented: $secretSheet) { OrbSecretRequestsSheet() }
            .sheet(isPresented: $privilegeSheet) { OrbPrivilegeAccessSheet() }
            .sheet(isPresented: $accessSheet) { OrbMissionAccessSheet() }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var approveAllSection: some View {
        let s = OrbApprovalQueue.summary(queue.items)
        let ready = OrbApprovalQueue.batchApprovable(queue.items, includeCritical: includeCritical)
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.risks).font(.caption.weight(.medium))
                Text("for \(s.missions)").font(.caption).foregroundStyle(.secondary)
                if s.critical > 0 {
                    Toggle(isOn: $includeCritical) {
                        Text(s.critical == 1 ? "Include the critical request (root, secret delete or move)" : "Include \(s.critical) critical requests (root, secret delete or move)")
                            .font(.caption).foregroundStyle(OrbStyle.error)
                    }
                    .accessibilityIdentifier("approvals.include-critical")
                }
                Button {
                    run { try await queue.approve(ready) }
                } label: {
                    Label(ready.count == queue.items.count ? "Approve all" : "Approve \(ready.count)",
                          systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid")
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent).tint(OrbStyle.success).controlSize(.small)
                .disabled(acting || ready.isEmpty)
                .accessibilityIdentifier("approvals.approve-all")
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ i: OrbJSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OrbApprovalQueue.title(i)).font(.subheadline.weight(.medium))
                .foregroundStyle(OrbApprovalQueue.isCritical(i) ? OrbStyle.error : Color.primary)
            Text("asked by \(OrbApprovalQueue.requester(i)) · \(OrbStyle.relativeTime(i["created_at"].text))").font(.caption).foregroundStyle(.secondary)
            if !i["reason"].text.isEmpty { Text("“\(i["reason"].text)”").font(.caption).italic() }
            let detail = OrbApprovalQueue.detail(i, projectName: secrets.projectName)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button {
                    run { try await queue.approve([i]) }
                } label: {
                    Label("Allow", systemImage: OrbBiometric.name == "Touch ID" ? "touchid" : "faceid").foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent).tint(OrbStyle.success)
                .accessibilityIdentifier("approvals.approve.\(i["kind"].text).\(i["id"].text)")
                Spacer()
                Button("Deny", role: .destructive) { run { try await queue.deny(i) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("approvals.deny.\(i["kind"].text).\(i["id"].text)")
            }
            .controlSize(.small)
            .disabled(acting)
        }
        .padding(.vertical, 4)
    }

    private func run(_ job: @escaping () async throws -> Void) {
        Task {
            acting = true
            defer { acting = false }
            do {
                try await job()
                error = ""
                OrbHaptics.success()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
