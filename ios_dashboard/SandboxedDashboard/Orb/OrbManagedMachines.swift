import Charts
import SwiftUI

/// Managed (boat.dev) machines: payload model and presentation logic,
/// mirroring `orb/src/managedMachineModel.ts`.
struct OrbManagedMachine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
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
    /// `nil` = unlimited (the default).
    var daily_cap_usd: Double?
    var active: Int
    /// `nil` = unlimited (the default).
    var max_concurrent: Int?
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

/// One UTC day of managed spend from Core; missions/sizes highest first.
struct OrbDailySpend: Codable, Equatable, Identifiable, Sendable {
    struct Mission: Codable, Equatable, Sendable { var mission_id: String?; var usd: Double }
    struct Size: Codable, Equatable, Sendable { var size: String; var usd: Double }
    var day: String
    var usd: Double
    var missions: [Mission]
    var sizes: [Size]
    var id: String { day }
}

struct OrbManagedMachinesResponse: Codable, Equatable, Sendable {
    var enabled: Bool
    var provider: String?
    var machines: [OrbManagedMachine]
    var budget: OrbManagedBudget
    var sizes: [OrbManagedSize]
    /// Last 7 UTC days, oldest first; `nil` on Cores that predate the spend chart.
    var daily_spend: [OrbDailySpend]?
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
    /// Row title: the friendly `name` ("small-a"), falling back to the id.
    static func title(_ m: OrbManagedMachine) -> String {
        if let name = m.name, !name.isEmpty { return name }
        return m.id
    }
    /// Fleet label: managed nodes carry a `display_name`; others keep their id.
    static func nodeTitle(_ node: OrbJSON) -> String {
        let display = node["display_name"].text
        return display.isEmpty ? node["id"].text : display
    }
    /// Optimistic Destroy: the row flips to "destroying" before the call returns.
    static func markDestroying(_ response: OrbManagedMachinesResponse, id: String) -> OrbManagedMachinesResponse {
        var copy = response
        if let i = copy.machines.firstIndex(where: { $0.id == id }) { copy.machines[i].state = "destroying" }
        return copy
    }
    static func isLive(_ m: OrbManagedMachine) -> Bool { m.state != "destroyed" && m.state != "failed" }

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // Backends emit nanosecond fractions; the formatter only takes milliseconds.
        let trimmed = value.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
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
        ["provisioning": "Provisioning", "enrolling": "Enrolling", "online": "Online", "destroying": "Destroying…", "destroyed": "Destroyed", "failed": "Failed"][s] ?? s
    }
    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    static func sizeSpec(cpu: Double, ramGB: Double, diskGB: Double? = nil) -> String {
        "\(number(cpu)) vCPU · \(number(ramGB)) GB" + (diskGB.map { " · \(number($0)) GB disk" } ?? "")
    }
    /// "$1.20 spent today of $20.00 · 1 of 3 running"; unlimited caps drop "of …":
    /// "$0.11 spent today · 1 running".
    static func budgetLine(_ b: OrbManagedBudget) -> String {
        let spent = usd(b.spent_today_usd) + " spent today" + (b.daily_cap_usd.map { " of \(usd($0))" } ?? "")
        let running = "\(b.active)" + (b.max_concurrent.map { " of \($0)" } ?? "") + " running"
        return spent + " · " + running
    }
    /// Spend chart header: the window's sum, today (the last day) and the tallest bar.
    static func spendSummary(_ days: [OrbDailySpend]) -> (total: Double, today: Double, max: Double) {
        (days.reduce(0) { $0 + $1.usd }, days.last?.usd ?? 0, days.map(\.usd).max() ?? 0)
    }
    /// Bar height as a 0…1 fraction of the tallest day; zero days stay 0 (a baseline).
    static func spendFraction(_ usd: Double, max: Double) -> Double {
        max > 0 && usd > 0 ? Swift.max(usd / max, 0.04) : 0
    }
    /// First `top` mission ids of a day (nil = no mission) and how many more there are.
    static func topMissions(_ d: OrbDailySpend, top: Int = 2) -> (ids: [String?], more: Int) {
        (d.missions.prefix(top).map(\.mission_id), Swift.max(0, d.missions.count - top))
    }
    static func spendDate(_ day: String) -> Date? { date(day + "T00:00:00Z") }
    /// "Mon" / "Mon 20 Oct" for a UTC `YYYY-MM-DD` day.
    static func spendWeekday(_ day: String) -> String { spendFormat(day, "EEE") }
    static func spendDayLabel(_ day: String) -> String { spendFormat(day, "EEE d MMM") }
    private static func spendFormat(_ day: String, _ template: String) -> String {
        guard let d = spendDate(day) else { return day }
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }
    /// "Mon 20 Oct · $0.53 · Fix login $0.50, No mission $0.03 +1 more".
    static func spendDayDetail(_ d: OrbDailySpend, titles: [String: String], top: Int = 2) -> String {
        if d.usd <= 0 { return spendDayLabel(d.day) + " · no spend" }
        let name = { (id: String?) in id.map { titles[$0] ?? "Mission \($0.prefix(8))" } ?? "No mission" }
        let parts = d.missions.prefix(top).map { "\(name($0.mission_id)) \(usd($0.usd))" }
        let more = topMissions(d, top: top).more
        return spendDayLabel(d.day) + " · " + usd(d.usd) + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")) + (more > 0 ? " +\(more) more" : "")
    }
    /// "1 of 3 running" / "1 running".
    static func runningLine(_ b: OrbManagedBudget) -> String { "\(b.active)" + (b.max_concurrent.map { " of \($0)" } ?? "") + " running" }

    /// Size label for display: the backend's "default" size is the medium one.
    static func sizeLabel(_ size: String) -> String { size == "default" ? "medium" : size }
    /// "4 vCPU · 8 GB RAM · 50 GB".
    static func specLine(_ m: OrbManagedMachine) -> String {
        var parts = ["\(number(m.cpu)) vCPU", "\(number(m.ram_gb)) GB RAM"]
        if let disk = m.disk_gb { parts.append("\(number(disk)) GB") }
        return parts.joined(separator: " · ")
    }
    /// Compact TTL: "21 min left", "1 h 05 min left", "<1 min left", "Expired".
    static func ttlShort(_ expiresAt: String, now: Date = .now) -> String {
        guard let end = date(expiresAt) else { return "—" }
        let s = Int(floor(end.timeIntervalSince(now)))
        if s <= 0 { return "Expired" }
        if s < 60 { return "<1 min left" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min left"
    }
    /// Remaining share of the machine's lifetime (created → expires), 0…1.
    static func ttlFraction(_ m: OrbManagedMachine, now: Date = .now) -> Double {
        guard let start = date(m.created_at), let end = date(m.expires_at) else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, end.timeIntervalSince(now) / total))
    }
    /// "<$0.01 so far · $0.036/h".
    static func costLine(_ cost: Double, rate: Double) -> String { "\(usd(cost)) so far · \(usdPerHour(rate))" }
    /// Mission chip text: the mission title, else the short id.
    static func missionLabel(title: String?, id: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return String(id.prefix(8))
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

/// Mission titles for owner chips, fetched once per mission and cached for the session.
@MainActor enum OrbMissionTitles {
    private(set) static var cache: [String: String] = [:]
    private static var inFlight: Set<String> = []
    static func load(_ id: String) async -> String? {
        if let cached = cache[id] { return cached }
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id); defer { inFlight.remove(id) }
        guard let mission = try? await OrbSettingsClient().call("/api/control/missions/\(OrbCore.escape(id))") else { return nil }
        let title = mission["title"].text
        cache[id] = title
        return title
    }
}

/// Settings > Machines section: managed machines laid out like desktop rows,
/// Extend (+1 h) and Destroy via swipe or long-press. No spawn UI on mobile.
struct OrbManagedMachinesSection: View {
    let response: OrbManagedMachinesResponse
    let fetchedAt: Date
    let busy: Bool
    let onDestroy: (OrbManagedMachine) -> Void
    let onExtend: (OrbManagedMachine) -> Void
    let onOpenMission: (String) -> Void
    @State private var destroying: OrbManagedMachine?
    @State private var titles: [String: String] = [:]

    var body: some View {
        let live: [OrbManagedMachine] = response.machines.filter(OrbManaged.isLive)
        let recent: [OrbManagedMachine] = OrbManaged.recent(response.machines)
        Section {
            if response.enabled, let days = response.daily_spend {
                OrbManagedSpendChart(days: days, budget: response.budget, titles: titles)
                    .accessibilityIdentifier("managed.spend")
            }
            if !response.enabled { Text("Managed machines are disabled on this backend.").foregroundStyle(.secondary) }
            else if live.isEmpty { Text("No managed machines running.").foregroundStyle(.secondary) }
            ForEach(live) { machine in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    OrbManagedMachineRow(machine: machine, now: context.date, cost: OrbManaged.liveCost(machine, fetchedAt: fetchedAt, now: context.date),
                                         missionTitle: machine.owner_mission_id.flatMap { titles[$0] }, muted: false, onOpenMission: onOpenMission)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Destroy", role: .destructive) { destroying = machine }.disabled(!canAct(machine))
                    Button("+1 h") { onExtend(machine) }.tint(.accentColor).disabled(!canAct(machine))
                }
                .contextMenu { menu(machine, live: true) }
                .accessibilityIdentifier("managed.machine.\(machine.id)")
            }
            ForEach(recent) { machine in
                OrbManagedMachineRow(machine: machine, now: .now, cost: machine.cost_usd,
                                     missionTitle: machine.owner_mission_id.flatMap { titles[$0] }, muted: true, onOpenMission: onOpenMission)
                    .contextMenu { menu(machine, live: false) }
            }
        } header: { Text("Managed machines") } footer: {
            if response.daily_spend == nil { Text(OrbManaged.budgetLine(response.budget)).accessibilityIdentifier("managed.budget") }
        }
        .task(id: missionIds) { await loadTitles() }
        .alert("Destroy machine?", isPresented: Binding(get: { destroying != nil }, set: { if !$0 { destroying = nil } }), presenting: destroying) { machine in
            Button("Destroy", role: .destructive) { onDestroy(machine) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Destroy \(OrbManaged.title($0)) (\(OrbManaged.sizeLabel($0.size)))? Running jobs on it stop and its disk is deleted.") }
    }

    private func canAct(_ m: OrbManagedMachine) -> Bool { !busy && m.state != "destroying" }

    /// Long-press details: the raw reason, node and error live here, never inline.
    @ViewBuilder private func menu(_ m: OrbManagedMachine, live: Bool) -> some View {
        if live {
            Button("Extend 1 h", systemImage: "clock.arrow.circlepath") { onExtend(m) }.disabled(!canAct(m))
                .accessibilityIdentifier("managed.extend")
            Button("Destroy", systemImage: "trash", role: .destructive) { destroying = m }.disabled(!canAct(m))
                .accessibilityIdentifier("managed.destroy")
        }
        if let mission = m.owner_mission_id, !mission.isEmpty {
            Button("Open mission", systemImage: "bubble.left") { onOpenMission(mission) }
        }
        Section {
            if let reason = m.reason, !reason.isEmpty { Text(reason) }
            if let node = m.node_id, !node.isEmpty { Text("Node \(node)") }
            if let error = m.error, !error.isEmpty { Text(error) }
        }
    }

    private var missionIds: Set<String> {
        Set(response.machines.compactMap(\.owner_mission_id) + (response.daily_spend ?? []).flatMap { $0.missions.compactMap(\.mission_id) })
    }

    private func loadTitles() async {
        for id in missionIds where titles[id] == nil {
            if let title = await OrbMissionTitles.load(id) { titles[id] = title }
        }
    }
}

/// Spend over the last days: one bar per UTC day, the window total, today and
/// the running count. Tap or drag across the bars to read a day's total and top
/// missions in the caption (fixed height: nothing moves). `days == nil` is a
/// same-size skeleton.
struct OrbManagedSpendChart: View {
    let days: [OrbDailySpend]?
    let budget: OrbManagedBudget
    var titles: [String: String] = [:]
    @State private var selected: String?

    var body: some View {
        let list = days ?? []
        let sum = OrbManaged.spendSummary(list)
        let picked = list.first { $0.day == selected }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(OrbManaged.usd(sum.total)).font(.subheadline.weight(.semibold).monospacedDigit())
                Text("last \(list.isEmpty ? 7 : list.count) days").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(OrbManaged.runningLine(budget)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(days == nil ? Self.skeleton : list) { d in
                    BarMark(x: .value("Day", OrbManaged.spendWeekday(d.day)),
                            y: .value("Spend", days == nil ? d.usd : OrbManaged.spendFraction(d.usd, max: sum.max)), width: .ratio(0.7))
                        .foregroundStyle(barColor(d, last: d.day == list.last?.day))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.separator).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartYScale(domain: 0...1)
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
            .chartXSelection(value: Binding(get: { picked.map { OrbManaged.spendWeekday($0.day) } }, set: { label in
                selected = label.flatMap { l in list.first { OrbManaged.spendWeekday($0.day) == l }?.day }
            }))
            .frame(height: 64)
            Text(caption(picked, sum.today))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("managed.spend.caption")
        }
        .redacted(reason: days == nil ? .placeholder : [])
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ d: OrbDailySpend?, _ today: Double) -> String {
        if let d { return OrbManaged.spendDayDetail(d, titles: titles) }
        return OrbManaged.usd(today) + " today" + (budget.daily_cap_usd.map { " of \(OrbManaged.usd($0)) daily cap" } ?? "")
    }

    private func barColor(_ d: OrbDailySpend, last: Bool) -> Color {
        if days == nil { return Color.secondary.opacity(0.25) }
        if d.day == selected { return .accentColor }
        return Color.accentColor.opacity(last ? 0.9 : 0.5)
    }

    /// Placeholder bars (heights only) while the first list is loading.
    private static let skeleton: [OrbDailySpend] = [0.4, 0.65, 0.4, 0.65, 0.4, 0.65, 0.4].enumerated().map {
        OrbDailySpend(day: "2026-01-0\($0.offset + 1)", usd: $0.element, missions: [], sizes: [])
    }
}

/// One managed machine: status dot + bold name + size + status, then specs, TTL ring and cost.
struct OrbManagedMachineRow: View {
    let machine: OrbManagedMachine
    let now: Date
    let cost: Double
    let missionTitle: String?
    let muted: Bool
    let onOpenMission: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    static func statusColor(_ state: String) -> Color {
        switch state {
        case "online": OrbStyle.success
        case "provisioning", "enrolling": OrbStyle.warning
        case "failed": OrbStyle.error
        default: OrbStyle.textMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            detailLine
            if let mission = machine.owner_mission_id, !mission.isEmpty { missionChip(mission) }
        }
        .padding(.vertical, 2)
        .opacity(muted ? 0.6 : 1)
    }

    private var titleLine: some View {
        let status: String = OrbManaged.stateLabel(machine.state)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Self.statusColor(machine.state)).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(OrbManaged.title(machine)).font(.body.weight(.semibold)).lineLimit(1)
            Text(OrbManaged.sizeLabel(machine.size)).font(.subheadline).foregroundStyle(OrbStyle.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(status).font(.subheadline).foregroundStyle(OrbStyle.textSecondary).lineLimit(1)
        }
    }

    @ViewBuilder private var detailLine: some View {
        let specs = Text(OrbManaged.specLine(machine)).lineLimit(1)
        let ttl = ttlView
        let costText = Text(OrbManaged.costLine(cost, rate: machine.usd_per_hour)).monospacedDigit().lineLimit(1)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { specs; ttl; costText }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { specs; ttl; costText }
                    VStack(alignment: .leading, spacing: 2) { specs; HStack(spacing: 8) { ttl; costText } }
                }
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var ttlView: some View {
        if !muted {
            let fraction: Double = OrbManaged.ttlFraction(machine, now: now)
            let urgent: Bool = OrbManaged.ttlUrgent(machine.expires_at, now: now)
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(OrbStyle.border, lineWidth: 2)
                    Circle().trim(from: 0, to: fraction).stroke(urgent ? OrbStyle.warning : OrbStyle.icon, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11).accessibilityHidden(true)
                Text(OrbManaged.ttlShort(machine.expires_at, now: now)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(urgent ? OrbStyle.warning : .secondary)
            }
        }
    }

    private func missionChip(_ id: String) -> some View {
        Button { onOpenMission(id) } label: {
            Label(OrbManaged.missionLabel(title: missionTitle, id: id), systemImage: "bubble.left")
                .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(OrbStyle.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(OrbStyle.border))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("managed.mission")
    }
}
