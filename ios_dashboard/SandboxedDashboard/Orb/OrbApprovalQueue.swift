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

    /// Critical items only when ticked, never a critical legacy item (an old
    /// Core cannot check the confirmation, so those go one row at a time),
    /// and at most `maxBatch`; the rest stay for the next signature.
    static func batchApprovable(_ items: [OrbJSON], includeCritical: Bool) -> [OrbJSON] {
        Array(items.filter { !isCritical($0) || (includeCritical && !$0["legacy"].flag) }.prefix(maxBatch))
    }

    /// What identifies the list on screen: a new, removed or changed item
    /// (legacy items have no digest) must be ticked again.
    static func listKey(_ items: [OrbJSON]) -> [String] {
        items.map { "\($0["kind"].text):\($0["id"].text):\($0["digest"].text)" }
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

    /// The kind's own approve route and body, for a Core without the queue.
    static func legacyApprove(_ i: OrbJSON) -> (String, OrbJSON) {
        let id = OrbCore.escape(i["id"].text), r = i["request"]
        switch i["kind"].text {
        case "privilege":
            return ("/api/privilege-access/\(id)/approve", .object(["ttl_minutes": r["ttl_minutes"], "session_scoped": .bool(r["session_scoped"].flag)]))
        case "mission_access":
            return ("/api/mission-access/\(id)/approve", .object(["ttl_hours": r["ttl_hours"]]))
        default:
            return ("/api/bitwarden/requests/\(id)/approve", .object([:]))
        }
    }

    static func denyPath(_ i: OrbJSON) -> String {
        let id = OrbCore.escape(i["id"].text)
        switch i["kind"].text {
        case "privilege": return "/api/privilege-access/\(id)/deny"
        case "mission_access": return "/api/mission-access/\(id)/deny"
        default: return "/api/bitwarden/requests/\(id)/reject"
        }
    }

    /// Risk of a kind's tier, as Core assigns it (approvals.json `risk`).
    static func riskOf(kind: String, tier: String, request: OrbJSON = .null) -> String {
        switch kind {
        case "privilege": return tier == "root_exec" ? "critical" : tier == "service_deploy" ? "elevated" : "routine"
        case "mission_access": return "elevated"
        default:
            if tier == "delete" || tier == "move" { return "critical" }
            return tier == "write" || request["all_projects"].flag ? "elevated" : "routine"
        }
    }

    /// A per-kind request as a queue item, for a Core without the queue. No
    /// digest: approved through the kind's own signed route.
    static func legacyItem(kind: String, _ r: OrbJSON) -> OrbJSON {
        let tier = kind == "privilege" ? r["scope"].text : kind == "secret" ? r["kind"].text : "read_mission"
        let target = kind == "privilege" ? r["target_host"].text
            : kind == "mission_access" ? r["target_mission_id"].text
            : [r["key"].text, r["project_id"].text, "*"].first { !$0.isEmpty } ?? "*"
        let mission = r["requester_mission_id"].text.isEmpty ? r["mission_id"].text : r["requester_mission_id"].text
        let title = r["requester_title"].text.isEmpty ? r["mission_title"] : r["requester_title"]
        return .object([
            "kind": .string(kind), "id": r["id"], "requester_mission_id": .string(mission), "requester_title": title,
            "tier": .string(tier), "target": .string(target), "risk": .string(riskOf(kind: kind, tier: tier, request: r)),
            "reason": r["reason"], "created_at": r["created_at"], "digest": .string(""), "request": r, "legacy": .bool(true),
        ])
    }

    /// Pending items built from the per-kind lists the earlier clients used,
    /// each list on its own so one failure never hides the others' requests.
    static func legacyItems(privilege: OrbJSON?, secrets: OrbJSON?, missions: OrbJSON?) -> [OrbJSON] {
        let p = (privilege?["requests"].items ?? []).filter { $0["state"].text == "pending" }.map { legacyItem(kind: "privilege", $0) }
        let s = (secrets?["requests"].items ?? []).filter { $0["status"].text == "pending" }.map { legacyItem(kind: "secret", $0) }
        let m = (missions?["requests"].items ?? []).filter { $0["state"].text == "pending" }.map { legacyItem(kind: "mission_access", $0) }
        return (p + s + m).sorted { $0["created_at"].text > $1["created_at"].text }
    }

    @discardableResult
    func refresh() async -> Bool {
        let current = OrbCore.shared.endpoint
        if current != endpoint { items = []; endpoint = current }
        let next: [OrbJSON]
        do {
            next = try await OrbCore.shared.call("/api/approvals/queue")["items"].items
        } catch let error as OrbHTTPError where error.status == 404 || error.status == 405 {
            // Core predates /api/approvals: read the per-kind lists instead.
            async let privilege = Log.attempt(.network, "privilege access", { try await OrbCore.shared.call("/api/privilege-access") })
            async let secrets = Log.attempt(.network, "secret requests", { try await OrbCore.shared.call("/api/bitwarden/broker") })
            async let missions = Log.attempt(.network, "mission access", { try await OrbCore.shared.call("/api/mission-access") })
            let (p, s, m) = await (privilege, secrets, missions)
            if p == nil && s == nil && m == nil { return false }
            next = Self.legacyItems(privilege: p, secrets: s, missions: m)
        } catch {
            // Keep what is on screen: a failed read never erases requests.
            Log.error(.network, "approval queue", error)
            return false
        }
        guard current == OrbCore.shared.endpoint else { return true }
        items = next
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
        if items.contains(where: { $0["legacy"].flag }) {
            // No batch route on this Core: each request through its kind's own
            // signed route, with the lifetime it asked for.
            for i in items {
                let (path, body) = Self.legacyApprove(i)
                _ = try await OrbApprovalKey.signedCall(path, method: "POST", body: body, summary: Self.signingReason([i]))
            }
        } else {
            _ = try await OrbApprovalKey.signedCall("/api/approvals/approve-all", method: "POST", body: Self.batchBody(items), summary: reason)
        }
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
            .onChange(of: OrbApprovalQueue.listKey(queue.items)) { _, _ in includeCritical = false }
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
