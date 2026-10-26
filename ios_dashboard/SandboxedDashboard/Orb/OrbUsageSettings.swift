import Charts
import SwiftUI

/// Models › Usage (desktop: UsageSettings.tsx): spend over time and the top missions by cost.
/// Quotas stay in Providers; this is history only.
struct OrbUsageSettings: View {
    @State private var client = OrbSettingsClient()
    @State private var summary: OrbJSON?
    @State private var window = "7d"
    @State private var error = ""

    struct Day: Identifiable { let id: String; let label: String; let usd: Double }
    struct Spender: Identifiable { let id: String; let name: String; let usd: Double; let requests: Int }

    /// Spend per day, oldest first (`by_day[].cost_cents`).
    static func days(_ s: OrbJSON) -> [Day] {
        s["by_day"].items.map { d in
            let day = d["day"].text
            return Day(id: day, label: String(day.suffix(5)), usd: (d["cost_cents"].doubleValue ?? 0) / 100)
        }
    }
    /// Missions by cost, highest first.
    static func topMissions(_ s: OrbJSON, limit: Int = 5) -> [Spender] {
        s["by_mission"].items.map { g in
            Spender(id: g["key"].text.isEmpty ? "none" : g["key"].text,
                    name: g["label"].text.isEmpty ? (g["key"].text.isEmpty ? "No mission" : g["key"].text) : g["label"].text,
                    usd: (g["cost_cents"].doubleValue ?? 0) / 100, requests: Int(g["requests"].doubleValue ?? 0))
        }.sorted { $0.usd > $1.usd }.prefix(limit).map { $0 }
    }

    var body: some View {
        List {
            OrbSettingsError(message: error)
            Section {
                Picker("Window", selection: $window) {
                    Text("24 hours").tag("24h"); Text("7 days").tag("7d"); Text("30 days").tag("30d")
                }.pickerStyle(.segmented)
                let days = summary.map(Self.days) ?? []
                Chart(days) { d in
                    BarMark(x: .value("Day", d.label), y: .value("Spend", d.usd), width: .ratio(0.7))
                        .foregroundStyle(.tint).cornerRadius(3)
                }
                .chartYAxis { AxisMarks(position: .leading) { v in AxisValueLabel { if let n = v.as(Double.self) { Text("$\(n, specifier: "%.0f")") } } } }
                .frame(height: 160)
                .redacted(reason: summary == nil ? .placeholder : [])
                .accessibilityLabel("Spend per day")
                if let s = summary { LabeledContent("Total", value: String(format: "$%.2f", (s["totals"]["cost_cents"].doubleValue ?? 0) / 100)) }
            } header: { Text("Spend over time") }
            Section("Top missions") {
                let top = summary.map { Self.topMissions($0) } ?? []
                if summary != nil && top.isEmpty { Text("No usage in this window.").foregroundStyle(.secondary) }
                ForEach(top) { m in
                    LabeledContent { Text(String(format: "$%.2f", m.usd)).monospacedDigit() } label: {
                        Text(m.name).lineLimit(1); Text("\(m.requests) requests").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Usage").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: window) { await load() }
    }

    private func load() async {
        do { summary = try await client.call("/api/ai/usage/summary?window=\(window)"); error = "" }
        catch is CancellationError {} catch { self.error = "Couldn’t load usage. Pull to retry." }
    }
}
