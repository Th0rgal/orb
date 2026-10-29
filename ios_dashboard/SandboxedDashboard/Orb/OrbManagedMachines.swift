import Charts
import SwiftUI

/// Managed (boat.dev) machines: payload model and presentation logic,
/// mirroring `orb/src/managedMachineModel.ts`.
struct OrbManagedMachine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var provider: String?
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
    var root_mission_id: String?
    var project: String?
    var active_mission_ids: [String]?
    /// Mission that rented it for the owner (e.g. a start_mission caller).
    var requested_by_mission_id: String?
    /// "mission" | "user"; absent on legacy rows ("No owner").
    var owner_kind: String?
    var reason: String?
    var deletable_at: String?
    var has_executed_job: Bool?
    /// When the lifecycle reaper will destroy it, and the reason it will record.
    var reap_at: String?
    var reap_reason: String?
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
    var gpu: String?
    var arch: String?
    var min_billing_hours: Int?
}

struct OrbManagedProviderInfo: Codable, Equatable, Identifiable, Sendable {
    var provider: String
    var display_name: String
    var configured: Bool
    var enabled: Bool?
    var credential_source: String?
    var key_hint: String?
    var region: String?
    var project_id: String?
    var supports_snapshots: Bool
    var supports_free_stop: Bool
    var sizes: [OrbManagedSize]
    var id: String { provider }
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
    var providers: [OrbManagedProviderInfo]?
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
    private static func stateKind(_ state: String) -> Int {
        switch state {
        case "provisioning": 0
        case "enrolling": 1
        case "online": 2
        case "destroying": 3
        case "destroyed": 4
        case "failed": 5
        case "stopped": 6
        default: 3
        }
    }

    static func isLive(_ m: OrbManagedMachine) -> Bool {
        OrbKernel.machineActionAdmitted(stateKind: stateKind(m.state), isBusy: false, isMuted: false).isLive
    }

    static func isStopped(_ m: OrbManagedMachine) -> Bool {
        OrbKernel.machineActionAdmitted(stateKind: stateKind(m.state), isBusy: false, isMuted: false).isStopped
    }

    static func canResume(_ m: OrbManagedMachine, busy: Bool = false) -> Bool {
        OrbKernel.machineActionAdmitted(stateKind: stateKind(m.state), isBusy: busy, isMuted: false).canResume
    }

    static func canStop(_ m: OrbManagedMachine, providers: [OrbManagedProviderInfo]? = nil) -> Bool {
        guard m.state == "online" else { return false }
        let p = m.provider ?? "boat"
        if let info = providers?.first(where: { $0.provider == p }) { return info.supports_free_stop }
        return p == "boat"
    }

    static func providerLabel(_ provider: String?) -> String {
        switch (provider ?? "boat").lowercased() {
        case "boat": return "boat.dev"
        case "hetzner": return "Hetzner"
        case "vastai": return "Vast.ai"
        case "scaleway": return "Scaleway"
        default: return provider ?? "boat.dev"
        }
    }

    static func nodeProvider(_ node: OrbJSON) -> String? {
        let known: Set<String> = ["boat", "hetzner", "vastai", "scaleway"]
        for item in node["labels"].items {
            let l = item.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.hasPrefix("provider=") { return String(l.dropFirst("provider=".count)) }
            if known.contains(l) { return l }
        }
        return nil
    }

    static func isProviderEnabled(_ p: OrbManagedProviderInfo) -> Bool {
        p.enabled != false
    }

    static func isProviderUsable(_ p: OrbManagedProviderInfo) -> Bool {
        p.configured && p.enabled != false
    }

    static func credentialSourceLabel(_ source: String?) -> String {
        switch source {
        case "settings": return "Settings"
        case "bitwarden": return "Bitwarden"
        case "environment": return "Environment"
        default: return source ?? ""
        }
    }

    static func providerStatusLine(_ p: OrbManagedProviderInfo) -> String {
        let enabled = isProviderEnabled(p)
        if !p.configured { return enabled ? "Not configured" : "Disabled · Not configured" }
        let cred = [credentialSourceLabel(p.credential_source), p.key_hint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return [
            enabled ? "Configured" : "Disabled",
            cred,
            p.region ?? "",
            (p.project_id?.isEmpty == false) ? "proj \(p.project_id!)" : ""
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func sectionTitle(providers: [OrbManagedProviderInfo]?, machines: [OrbManagedMachine]) -> String {
        let multiConfigured = (providers ?? []).contains { isProviderUsable($0) && $0.provider != "boat" }
        let multiActive = machines.contains { ($0.provider ?? "boat") != "boat" && !($0.provider ?? "").isEmpty }
        return (multiConfigured || multiActive) ? "Managed cloud" : "Managed (boat.dev)"
    }

    static func budgetFull(_ b: OrbManagedBudget) -> Bool {
        (b.max_concurrent.map { b.active >= $0 } ?? false) || (b.daily_cap_usd.map { b.spent_today_usd >= $0 } ?? false)
    }

    static func ttlChoices(defaultMinutes: Int, maxMinutes: Int) -> [Int] {
        let cap = maxMinutes > 0 ? maxMinutes : 720
        let raw = [15, 30, 60, 120, 240, 480, 720, 1440, defaultMinutes, cap].filter { $0 > 0 && $0 <= cap }
        return Array(Set(raw)).sorted()
    }

    static func minutesLabel(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 && m > 0 ? "\(h) h \(m) min" : h > 0 ? "\(h) h" : "\(m) min"
    }

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
        guard OrbKernel.machineActionAdmitted(stateKind: stateKind(m.state), isBusy: false, isMuted: false).meterLiveCost else { return m.cost_usd }
        let until = min(now, date(m.expires_at) ?? now)
        return m.cost_usd + max(0, until.timeIntervalSince(fetchedAt)) / 3600 * m.usd_per_hour
    }
    static func stateLabel(_ s: String) -> String {
        ["provisioning": "Provisioning", "enrolling": "Enrolling", "online": "Online", "destroying": "Destroying…", "destroyed": "Destroyed", "failed": "Failed", "stopped": "Stopped"][s] ?? s
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
    /// Owner chip kind, mirroring `machineOwner` in managedMachineModel.ts.
    enum Owner: Equatable { case mission(String), user, none }
    static func owner(_ m: OrbManagedMachine) -> Owner {
        if let id = m.owner_mission_id, !id.isEmpty { return .mission(id) }
        return m.owner_kind == "user" ? .user : .none
    }
    static func reapReasonLabel(_ reason: String) -> String {
        switch reason {
        case "ttl_expired": return "TTL"
        case "idle_no_owner": return "idle, no owner"
        case "idle_user_owned", "working_owner_idle": return "idle"
        case "owner_missing": return "owner deleted"
        default:
            var r = reason
            if r.hasPrefix("owner_") { r = "owner " + String(r.dropFirst(6)) }
            if r.hasSuffix("_idle") { r = String(r.dropLast(5)) + ", idle" }
            return r.replacingOccurrences(of: "_", with: " ")
        }
    }
    /// "Reaps in 5 min (owner completed)", "Reap due (…)"; nil when nothing is scheduled.
    static func reapLine(_ m: OrbManagedMachine, now: Date = .now) -> String? {
        guard isLive(m) else { return nil }
        if let reason = m.reap_reason, reason.hasPrefix("awaiting_deletable_at:") {
            guard let raw = m.deletable_at ?? m.reap_at, let at = date(raw) else { return nil }
            let minutes = Int(ceil(at.timeIntervalSince(now) / 60))
            if minutes <= 0 { return "24h lease ended · deleting" }
            if minutes < 60 { return "Deletes when 24h lease ends in \(minutes) min" }
            return "Deletes when 24h lease ends in \(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min"
        }
        guard let raw = m.reap_at, let at = date(raw) else { return nil }
        let why = m.reap_reason.map { " (\(reapReasonLabel($0)))" } ?? ""
        let minutes = Int(ceil(at.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "Reap due\(why)" }
        if minutes < 60 { return "Reaps in \(minutes) min\(why)" }
        return "Reaps in \(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min\(why)"
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
        return machines.filter { !isLive($0) && !isStopped($0) }.filter { at($0).map { now.timeIntervalSince($0) <= 86_400 } ?? false }
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
        let prefix = code == "budget_exceeded" ? "Daily budget reached"
            : code == "quota_exceeded" ? "Machine limit reached"
            : code == "provider_disabled" ? "Provider disabled" : ""
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
/// Extend (+1 h), Stop, Resume, Destroy and New machine sheet.
struct OrbManagedMachinesSection: View {
    let response: OrbManagedMachinesResponse
    let fetchedAt: Date
    let busy: Bool
    let onDestroy: (OrbManagedMachine) -> Void
    let onExtend: (OrbManagedMachine) -> Void
    var onStop: ((OrbManagedMachine) -> Void)? = nil
    var onResume: ((OrbManagedMachine) -> Void)? = nil
    var onCreate: ((_ provider: String?, _ size: String, _ ttl: Int, _ allow24h: Bool) -> Void)? = nil
    let onOpenMission: (String) -> Void
    @State private var destroying: OrbManagedMachine?
    @State private var creating = false
    @State private var titles: [String: String] = [:]

    var body: some View {
        let live: [OrbManagedMachine] = response.machines.filter(OrbManaged.isLive)
        let stopped: [OrbManagedMachine] = response.machines.filter(OrbManaged.isStopped)
        let recent: [OrbManagedMachine] = OrbManaged.recent(response.machines)
        Section {
            if response.enabled, let days = response.daily_spend {
                OrbManagedSpendChart(days: days, budget: response.budget, titles: titles)
                    .accessibilityIdentifier("managed.spend")
            }
            if !response.enabled { Text("Managed machines are disabled on this backend.").foregroundStyle(.secondary) }
            else if live.isEmpty && stopped.isEmpty { Text("No managed machines running.").foregroundStyle(.secondary) }
            ForEach(live) { machine in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    OrbManagedMachineRow(machine: machine, now: context.date, cost: OrbManaged.liveCost(machine, fetchedAt: fetchedAt, now: context.date),
                                         missionTitle: machine.owner_mission_id.flatMap { titles[$0] }, muted: false, onOpenMission: onOpenMission)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Destroy", role: .destructive) { destroying = machine }.disabled(!canAct(machine))
                    if OrbManaged.canStop(machine, providers: response.providers), let onStop {
                        Button("Stop") { onStop(machine) }.tint(.orange).disabled(!canAct(machine))
                    }
                    Button("+1 h") { onExtend(machine) }.tint(.accentColor).disabled(!canAct(machine))
                }
                .contextMenu { menu(machine, live: true) }
                .accessibilityIdentifier("managed.machine.\(machine.id)")
            }
            ForEach(stopped) { machine in
                OrbManagedMachineRow(machine: machine, now: .now, cost: machine.cost_usd,
                                     missionTitle: machine.owner_mission_id.flatMap { titles[$0] }, muted: false, onOpenMission: onOpenMission)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Destroy", role: .destructive) { destroying = machine }.disabled(busy)
                        if let onResume {
                            Button("Resume") { onResume(machine) }.tint(.accentColor).disabled(!OrbManaged.canResume(machine, busy: busy))
                        }
                    }
                    .contextMenu { menu(machine, live: false) }
                    .accessibilityIdentifier("managed.stopped.\(machine.id)")
            }
            ForEach(recent) { machine in
                OrbManagedMachineRow(machine: machine, now: .now, cost: machine.cost_usd,
                                     missionTitle: machine.owner_mission_id.flatMap { titles[$0] }, muted: true, onOpenMission: onOpenMission)
                    .contextMenu { menu(machine, live: false) }
            }
        } header: {
            let noUsable = (response.providers?.isEmpty == false) && !(response.providers ?? []).contains(where: OrbManaged.isProviderUsable)
            HStack {
                Text(OrbManaged.sectionTitle(providers: response.providers, machines: response.machines))
                Spacer()
                if response.enabled, onCreate != nil {
                    Button { creating = true } label: { Label("New", systemImage: "plus") }
                        .font(.caption.weight(.semibold))
                        .disabled(busy || noUsable || OrbManaged.budgetFull(response.budget))
                        .accessibilityIdentifier("managed.new")
                }
            }
        } footer: {
            if response.daily_spend == nil { Text(OrbManaged.budgetLine(response.budget)).accessibilityIdentifier("managed.budget") }
        }
        .task(id: missionIds) { await loadTitles() }
        .sheet(isPresented: $creating) {
            if let onCreate {
                OrbNewManagedMachineSheet(response: response) { provider, size, ttl, allow24h in
                    creating = false
                    onCreate(provider, size, ttl, allow24h)
                }
            }
        }
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
            if OrbManaged.canStop(m, providers: response.providers), let onStop {
                Button("Stop", systemImage: "pause.circle") { onStop(m) }.disabled(!canAct(m))
                    .accessibilityIdentifier("managed.stop")
            }
            Button("Destroy", systemImage: "trash", role: .destructive) { destroying = m }.disabled(!canAct(m))
                .accessibilityIdentifier("managed.destroy")
        } else if OrbManaged.isStopped(m) {
            if let onResume {
                Button("Resume", systemImage: "play.circle") { onResume(m) }.disabled(!OrbManaged.canResume(m, busy: busy))
                    .accessibilityIdentifier("managed.resume")
            }
            Button("Destroy", systemImage: "trash", role: .destructive) { destroying = m }.disabled(busy)
                .accessibilityIdentifier("managed.destroy")
        }
        if let mission = m.owner_mission_id, !mission.isEmpty {
            Button("Open mission", systemImage: "bubble.left") { onOpenMission(mission) }
        }
        Section {
            if let provider = m.provider, !provider.isEmpty { Text("Provider \(OrbManaged.providerLabel(provider))") }
            if let project = m.project, !project.isEmpty { Text("Project \(project)") }
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
            ownerLine
            if let reap = OrbManaged.reapLine(machine, now: now) {
                Text(reap).font(.footnote).foregroundStyle(OrbStyle.warning).lineLimit(1)
            }
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
            if let p = machine.provider, !p.isEmpty, p != "boat" {
                Text(OrbManaged.providerLabel(p)).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            Text(OrbManaged.sizeLabel(machine.size)).font(.subheadline).foregroundStyle(OrbStyle.textSecondary).lineLimit(1)
            if let project = machine.project, !project.isEmpty {
                Text(project).font(.caption2).foregroundStyle(OrbStyle.textSecondary).lineLimit(1)
            }
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

    @ViewBuilder private var ownerLine: some View {
        switch OrbManaged.owner(machine) {
        case .mission(let id): missionChip(id)
        case .user: if !muted { ownerTag("You", color: OrbStyle.textSecondary) }
        case .none:
            if !muted {
                VStack(alignment: .leading, spacing: 2) {
                    ownerTag("No owner", color: OrbStyle.warning)
                    if let reason = machine.reason, !reason.isEmpty {
                        Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityIdentifier("managed.noOwner")
            }
        }
    }

    private func ownerTag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(OrbStyle.border))
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

struct OrbNewManagedMachineSheet: View {
    let response: OrbManagedMachinesResponse
    let onCreate: (_ provider: String?, _ size: String, _ ttl: Int, _ allow24h: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var provider: String
    @State private var size: String
    @State private var ttl: Int
    @State private var allow24h = false

    init(response: OrbManagedMachinesResponse, onCreate: @escaping (_ provider: String?, _ size: String, _ ttl: Int, _ allow24h: Bool) -> Void) {
        self.response = response
        self.onCreate = onCreate
        let usable = (response.providers ?? []).filter(OrbManaged.isProviderUsable)
        let initProv = usable.first(where: { $0.provider == "boat" })?.provider ?? usable.first?.provider ?? "boat"
        let initSizes = usable.first(where: { $0.provider == initProv })?.sizes ?? response.sizes
        let initSize = initSizes.first(where: { $0.size == response.budget.default_size })?.size ?? initSizes.first?.size ?? "small"
        let defTtl = response.budget.default_ttl_minutes ?? 60
        let maxTtl = response.budget.max_ttl_minutes ?? 720
        _provider = State(initialValue: initProv)
        _size = State(initialValue: initSize)
        _ttl = State(initialValue: maxTtl > 0 ? min(defTtl, maxTtl) : defTtl)
    }

    private var usableProviders: [OrbManagedProviderInfo] { (response.providers ?? []).filter(OrbManaged.isProviderUsable) }
    private var sizes: [OrbManagedSize] { usableProviders.first(where: { $0.provider == provider })?.sizes ?? response.sizes }
    private var chosen: OrbManagedSize? { sizes.first(where: { $0.size == size }) }
    private var requires24h: Bool { (chosen?.min_billing_hours ?? 0) >= 24 }
    private var effectiveMinutes: Int { max(ttl, (chosen?.min_billing_hours ?? 0) * 60) }
    private var estimate: Double { (chosen?.usd_per_hour ?? 0) * Double(effectiveMinutes) / 60.0 }

    var body: some View {
        NavigationStack {
            Form {
                if usableProviders.count > 1 {
                    Section("Provider") {
                        Picker("Provider", selection: $provider) {
                            ForEach(usableProviders, id: \.provider) { pr in
                                Text(pr.display_name.isEmpty ? OrbManaged.providerLabel(pr.provider) : pr.display_name).tag(pr.provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: provider) { _, next in
                            allow24h = false
                            let list = usableProviders.first(where: { $0.provider == next })?.sizes ?? response.sizes
                            size = list.first?.size ?? ""
                        }
                    }
                }
                Section("Size") {
                    ForEach(sizes, id: \.size) { s in
                        Button {
                            size = s.size
                            allow24h = false
                        } label: {
                            HStack {
                                Image(systemName: s.size == size ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(s.size == size ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(OrbManaged.sizeLabel(s.size)).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(OrbManaged.sizeSpec(cpu: s.cpu, ramGB: s.ram_gb, diskGB: s.disk_gb)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(OrbManaged.usdPerHour(s.usd_per_hour)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Time to live") {
                    Picker("TTL", selection: $ttl) {
                        ForEach(OrbManaged.ttlChoices(defaultMinutes: response.budget.default_ttl_minutes ?? 60, maxMinutes: response.budget.max_ttl_minutes ?? 720), id: \.self) { m in
                            Text(OrbManaged.minutesLabel(m)).tag(m)
                        }
                    }
                }
                if requires24h {
                    Section {
                        Toggle("Confirm \(chosen?.min_billing_hours ?? 24)h minimum lease (\(OrbManaged.usd(estimate)))", isOn: $allow24h)
                    }
                }
                Section {
                    LabeledContent("Estimated cost", value: OrbManaged.usd(estimate))
                }
            }
            .navigationTitle("New managed machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(provider == "boat" ? nil : provider, size, ttl, requires24h && allow24h)
                    }
                    .disabled(chosen == nil || (requires24h && !allow24h))
                }
            }
        }
    }
}

struct OrbMachineProvidersSection: View {
    let providers: [OrbManagedProviderInfo]
    let busyProvider: String?
    let onToggle: (OrbManagedProviderInfo, Bool) -> Void
    let onSave: (String, [String: OrbJSON]) async throws -> Void
    @State private var editing: OrbManagedProviderInfo?

    var body: some View {
        Section("Machine providers") {
            ForEach(providers) { pr in
                let label = pr.display_name.isEmpty ? OrbManaged.providerLabel(pr.provider) : pr.display_name
                let enabled = OrbManaged.isProviderEnabled(pr)
                HStack(spacing: 10) {
                    Circle()
                        .fill(OrbManaged.isProviderUsable(pr) ? OrbStyle.success : OrbStyle.textMuted)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.body.weight(.medium)).lineLimit(1)
                        Text(OrbManaged.providerStatusLine(pr)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Toggle(
                        "Enable \(label)",
                        isOn: Binding(
                            get: { enabled },
                            set: { next in onToggle(pr, next) }
                        )
                    )
                    .labelsHidden()
                    .disabled(busyProvider == pr.provider)
                    Button(pr.configured ? "Configure" : "Set up") { editing = pr }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("managed.provider.\(pr.provider)")
            }
        }
        .sheet(item: $editing) { pr in
            OrbConfigureMachineProviderSheet(provider: pr) { patch in
                try await onSave(pr.provider, patch)
            }
        }
    }
}

struct OrbConfigureMachineProviderSheet: View {
    let provider: OrbManagedProviderInfo
    let onSave: ([String: OrbJSON]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var region: String
    @State private var projectID: String
    @State private var saving = false
    @State private var error = ""

    init(provider: OrbManagedProviderInfo, onSave: @escaping ([String: OrbJSON]) async throws -> Void) {
        self.provider = provider
        self.onSave = onSave
        _region = State(initialValue: provider.region ?? "")
        _projectID = State(initialValue: provider.project_id ?? "")
    }

    private var label: String {
        provider.display_name.isEmpty ? OrbManaged.providerLabel(provider.provider) : provider.display_name
    }

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(OrbStyle.error).font(.footnote) }
                }
                Section {
                    SecureField(provider.key_hint ?? "Paste API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API key")
                } footer: {
                    Text(
                        provider.configured
                            ? "Leave blank to keep the current \(OrbManaged.credentialSourceLabel(provider.credential_source).lowercased()) key\(provider.key_hint.map { " (\($0))" } ?? ""). Credentials are encrypted on Core."
                            : "Credentials are encrypted on Core and never returned to clients."
                    )
                }
                if provider.provider == "hetzner" {
                    Section {
                        TextField("fsn1", text: $region)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Default location")
                    } footer: {
                        Text("Preferred Hetzner Cloud location (falls back across fsn1, hel1, nbg1 if unavailable).")
                    }
                }
                if provider.provider == "scaleway" {
                    Section("Scaleway settings") {
                        TextField("Default zone (e.g. fr-par-1)", text: $region)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Project UUID", text: $projectID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if provider.credential_source == "settings" {
                    Section {
                        Button("Remove saved key", role: .destructive) {
                            Task { await submit(override: ["api_key": .string("")]) }
                        }
                        .disabled(saving)
                    }
                }
            }
            .navigationTitle("Configure \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await submit(override: nil) } }
                        .disabled(saving || (!provider.configured && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }

    private func submit(override: [String: OrbJSON]?) async {
        guard !saving else { return }
        saving = true; error = ""
        defer { saving = false }
        var patch: [String: OrbJSON] = override ?? [:]
        if override == nil {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                patch["api_key"] = .string(trimmedKey)
                patch["enabled"] = .bool(true)
            }
            if provider.provider == "hetzner" || provider.provider == "scaleway" {
                patch["region"] = .string(region.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if provider.provider == "scaleway" {
                patch["project_id"] = .string(projectID.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do {
            try await onSave(patch)
            dismiss()
        } catch {
            self.error = OrbManaged.message(error)
        }
    }
}
