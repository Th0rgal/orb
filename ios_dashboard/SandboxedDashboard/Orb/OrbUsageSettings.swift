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

    private static let placeholderDays: [Day] = [
        Day(id: "p1", label: "01", usd: 3),
        Day(id: "p2", label: "02", usd: 7),
        Day(id: "p3", label: "03", usd: 4),
        Day(id: "p4", label: "04", usd: 9),
        Day(id: "p5", label: "05", usd: 5),
        Day(id: "p6", label: "06", usd: 8),
        Day(id: "p7", label: "07", usd: 6),
    ]

    var body: some View {
        let days = summary.map(Self.days) ?? []
        let totalUSD = ((summary?["totals"]["cost_cents"].doubleValue) ?? 0) / 100
        let hasSpend = days.contains { $0.usd > 0 } || totalUSD > 0
        let top = summary.map { Self.topMissions($0) } ?? []

        return List {
            OrbSettingsError(message: error)
            Section {
                Picker("Window", selection: $window) {
                    Text("24 hours").tag("24h"); Text("7 days").tag("7d"); Text("30 days").tag("30d")
                }.pickerStyle(.segmented)
                if summary == nil {
                    Chart(Self.placeholderDays) { d in
                        BarMark(x: .value("Day", d.label), y: .value("Spend", d.usd), width: .ratio(0.7))
                            .foregroundStyle(.tint).cornerRadius(3)
                    }
                    .frame(height: 120)
                    .redacted(reason: .placeholder)
                    .orbShimmer(active: true)
                    .accessibilityLabel("Loading spend per day")
                } else if !hasSpend {
                    Text("No spend recorded in this window.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Chart(days) { d in
                        BarMark(x: .value("Day", d.label), y: .value("Spend", d.usd), width: .ratio(0.7))
                            .foregroundStyle(.tint).cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in AxisValueLabel { if let n = v.as(Double.self) { Text("$\(n, specifier: "%.0f")") } } } }
                    .frame(height: 150)
                    .accessibilityLabel("Spend per day")
                }
                if summary != nil {
                    LabeledContent("Total", value: String(format: "$%.2f", totalUSD))
                }
            } header: { Text("Spend over time") }
            if !top.isEmpty {
                Section("Top missions") {
                    ForEach(top) { m in
                        LabeledContent { Text(String(format: "$%.2f", m.usd)).monospacedDigit() } label: {
                            Text(m.name).lineLimit(1); Text("\(m.requests) requests").font(.caption).foregroundStyle(.secondary)
                        }
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
