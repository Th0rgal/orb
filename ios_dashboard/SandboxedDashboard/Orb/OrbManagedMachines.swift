import SwiftUI

/// Managed (boat.dev) machines: payload model and presentation logic,
/// mirroring `orb/src/managedMachineModel.ts`.
struct OrbManagedMachine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var node_id: String?
    var size: String
    var cpu: Double
    var ram_gb: Double
    var disk_gb: Double?
    var usd_per_hour: Double
    var state: String
    var created_at: String
    var expires_at: String
    var destroyed_at: String?
    var cost_usd: Double
    var cost_is_metered: Bool?
    var owner_mission_id: String?
    var reason: String?
    var error: String?
    var ledger_closed: Bool?
    var destroy_reason: String?
}

struct OrbManagedBudget: Codable, Equatable, Sendable {
    var spent_today_usd: Double
    var committed_usd: Double?
    var daily_cap_usd: Double
    var active: Int
    var max_concurrent: Int
    var default_ttl_minutes: Int?
    var max_ttl_minutes: Int?
    var default_size: String?
    var max_size: String?
    var image: String?
}

struct OrbManagedSize: Codable, Equatable, Sendable {
    var size: String
    var cpu: Double
    var ram_gb: Double
    var disk_gb: Double?
    var usd_per_hour: Double
}

struct OrbManagedMachinesResponse: Codable, Equatable, Sendable {
    var enabled: Bool
    var provider: String?
    var machines: [OrbManagedMachine]
    var budget: OrbManagedBudget
    var sizes: [OrbManagedSize]
}

enum OrbManaged {
    static func decode(_ data: Data) throws -> OrbManagedMachinesResponse {
        try JSONDecoder().decode(OrbManagedMachinesResponse.self, from: data)
    }
    static func decode(_ json: OrbJSON) throws -> OrbManagedMachinesResponse {
        try decode(JSONEncoder().encode(json))
    }

    /// Remote nodes provisioned by the managed-machine service.
    static func isManagedNode(_ node: OrbJSON) -> Bool {
        node["labels"].items.contains { $0.text == "managed" } || node["id"].text.hasPrefix("managed-")
    }
    static func isLive(_ m: OrbManagedMachine) -> Bool { m.state != "destroyed" && m.state != "failed" }

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// "$0.42", "$12.30", "<$0.01" for tiny non-zero amounts.
    static func usd(_ amount: Double?) -> String {
        guard let amount, amount.isFinite else { return "—" }
        if amount > 0 && amount < 0.01 { return "<$0.01" }
        return "$" + String(format: "%.2f", amount)
    }
    /// "$0.12/h"; three decimals under ten cents so cheap sizes stay distinct.
    static func usdPerHour(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "—" }
        return "$" + String(format: rate > 0 && rate < 0.1 ? "%.3f" : "%.2f", rate) + "/h"
    }
    /// Time left until `expiresAt`: "1h 05m", "4m 09s", "Expired".
    static func ttlLeft(_ expiresAt: String, now: Date = .now) -> String {
        guard let end = date(expiresAt) else { return "—" }
        let s = Int(floor(end.timeIntervalSince(now)))
        if s <= 0 { return "Expired" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? "\(h)h " + String(format: "%02d", m) + "m" : "\(m)m " + String(format: "%02d", sec) + "s"
    }
    /// Under ten minutes left: the countdown is highlighted.
    static func ttlUrgent(_ expiresAt: String, now: Date = .now) -> Bool {
        guard let end = date(expiresAt) else { return false }
        return end.timeIntervalSince(now) < 600
    }
    /// Cost so far, extrapolated between polls so it ticks with the countdown.
    static func liveCost(_ m: OrbManagedMachine, fetchedAt: Date, now: Date = .now) -> Double {
        guard ["online", "enrolling", "provisioning"].contains(m.state) else { return m.cost_usd }
        let until = min(now, date(m.expires_at) ?? now)
        return m.cost_usd + max(0, until.timeIntervalSince(fetchedAt)) / 3600 * m.usd_per_hour
    }
    static func stateLabel(_ s: String) -> String {
        ["provisioning": "Provisioning", "enrolling": "Enrolling", "online": "Online", "destroying": "Destroying", "destroyed": "Destroyed", "failed": "Failed"][s] ?? s
    }
    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    static func sizeSpec(cpu: Double, ramGB: Double, diskGB: Double? = nil) -> String {
        "\(number(cpu)) vCPU · \(number(ramGB)) GB" + (diskGB.map { " · \(number($0)) GB disk" } ?? "")
    }
    /// "$1.20 spent today of $20.00 · 1 of 3 running".
    static func budgetLine(_ b: OrbManagedBudget) -> String {
        "\(usd(b.spent_today_usd)) spent today of \(usd(b.daily_cap_usd)) · \(b.active) of \(b.max_concurrent) running"
    }
    /// Machines destroyed or failed during the last 24 hours, newest first.
    static func recent(_ machines: [OrbManagedMachine], now: Date = .now) -> [OrbManagedMachine] {
        func at(_ m: OrbManagedMachine) -> Date? { date(m.destroyed_at) ?? date(m.created_at) }
        return machines.filter { !isLive($0) }.filter { at($0).map { now.timeIntervalSince($0) <= 86_400 } ?? false }
            .sorted { (at($0) ?? .distantPast) > (at($1) ?? .distantPast) }
    }
    /// Older backends answer 404/405: the section is hidden.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let http = error as? OrbHTTPError else { return false }
        return http.status == 404 || http.status == 405
    }
    /// Human message for a failed managed-machine request.
    static func message(_ error: Error) -> String {
        guard let http = error as? OrbHTTPError else { return error.localizedDescription }
        var code = "", text = http.detail
        if let data = http.detail.data(using: .utf8), let body = try? JSONDecoder().decode(OrbJSON.self, from: data), !body["error"].text.isEmpty || !body["message"].text.isEmpty {
            code = body["error"].text; text = body["message"].text
        }
        let prefix = code == "budget_exceeded" ? "Daily budget reached" : code == "quota_exceeded" ? "Machine limit reached" : ""
        if !prefix.isEmpty { return text.isEmpty ? "\(prefix)." : "\(prefix): \(text)" }
        return text.isEmpty ? "Request failed (\(http.status))" : text
    }
}

/// "Managed" capsule shown next to fleet nodes owned by the managed-machine service.
struct OrbManagedBadge: View {
    var body: some View {
        Text("Managed")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(OrbStyle.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.border))
            .accessibilityIdentifier("machines.managedBadge")
    }
}

/// Settings > Machines section: live managed machines with TTL countdown,
/// running cost, Extend (+1 h) and Destroy. No spawn UI on mobile.
struct OrbManagedMachinesSection: View {
    let response: OrbManagedMachinesResponse
    let fetchedAt: Date
    let busy: Bool
    let onDestroy: (OrbManagedMachine) -> Void
    let onExtend: (OrbManagedMachine) -> Void
    @State private var destroying: OrbManagedMachine?

    var body: some View {
        let live = response.machines.filter(OrbManaged.isLive)
        let recent = OrbManaged.recent(response.machines)
        Section {
            if !response.enabled { Text("Managed machines are disabled on this backend.").foregroundStyle(.secondary) }
            else if live.isEmpty { Text("No managed machines running.").foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ForEach(live) { machine in row(machine, now: context.date) }
            }
            ForEach(recent) { machine in
                VStack(alignment: .leading) {
                    Text(machine.size)
                    Text(Self.recentSummary(machine))
                        .font(.caption).foregroundStyle(OrbStyle.textMuted)
                }
            }
        } header: { Text("Managed machines") } footer: {
            Text(OrbManaged.budgetLine(response.budget)).accessibilityIdentifier("managed.budget")
        }
        .alert("Destroy machine?", isPresented: Binding(get: { destroying != nil }, set: { if !$0 { destroying = nil } }), presenting: destroying) { machine in
            Button("Destroy", role: .destructive) { onDestroy(machine) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Destroy \($0.size) (\($0.id))? Running jobs on it stop and its disk is deleted.") }
    }

    static func recentSummary(_ m: OrbManagedMachine) -> String {
        let state: String = OrbManaged.stateLabel(m.state)
        let cost: String = OrbManaged.usd(m.cost_usd)
        var parts: [String] = [state, cost]
        if let error = m.error, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func row(_ m: OrbManagedMachine, now: Date) -> some View {
        DisclosureGroup {
            LabeledContent("Specs", value: OrbManaged.sizeSpec(cpu: m.cpu, ramGB: m.ram_gb, diskGB: m.disk_gb))
            LabeledContent("Rate", value: OrbManaged.usdPerHour(m.usd_per_hour))
            if let node = m.node_id, !node.isEmpty { LabeledContent("Node", value: node) }
            if let reason = m.reason, !reason.isEmpty { LabeledContent("Reason", value: reason) }
            if let error = m.error, !error.isEmpty { Text(error).foregroundStyle(OrbStyle.error) }
            Button("Extend 1 h") { onExtend(m) }.disabled(busy || m.state == "destroying")
                .accessibilityIdentifier("managed.extend")
            Button("Destroy", role: .destructive) { destroying = m }.disabled(busy || m.state == "destroying")
                .accessibilityIdentifier("managed.destroy")
        } label: {
            VStack(alignment: .leading) {
                Text("\(m.size) · \(OrbManaged.sizeSpec(cpu: m.cpu, ramGB: m.ram_gb))")
                HStack(spacing: 0) {
                    Text(OrbManaged.stateLabel(m.state) + " · ")
                    Text(OrbManaged.ttlLeft(m.expires_at, now: now))
                        .foregroundStyle(OrbManaged.ttlUrgent(m.expires_at, now: now) ? OrbStyle.warning : .secondary)
                        .monospacedDigit()
                    Text(" · \(OrbManaged.usd(OrbManaged.liveCost(m, fetchedAt: fetchedAt, now: now))) · \(OrbManaged.usdPerHour(m.usd_per_hour))")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("managed.machine.\(m.id)")
    }
}
