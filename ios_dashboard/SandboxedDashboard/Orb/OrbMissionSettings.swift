import SwiftUI

/// `GET /api/control/missions/:id/budget` (desktop: `orb/src/missionBudget.ts`).
struct OrbMissionBudget: Equatable {
    struct Pool: Equatable {
        var budget: Double, spent: Double, reserved: Double, carved: Double, available: Double
    }
    struct Child: Equatable, Identifiable {
        let id: String
        let mode: String
        let budget: Double?
        let spent: Double
    }
    var missionId: String
    var ownBudget: Double?
    var poolId: String?
    var mode: String
    var pool: Pool?
    var maxGrant: Double?
    var children: [Child]

    init(_ j: OrbJSON) {
        missionId = j["mission_id"].text
        ownBudget = j["own_budget_usd"].doubleValue
        poolId = j["pool_id"].text.isEmpty ? nil : j["pool_id"].text
        mode = j["mode"].text.isEmpty ? "none" : j["mode"].text
        let p = j["pool"]
        pool = p == .null ? nil : Pool(budget: p["budget_usd"].doubleValue ?? 0, spent: p["spent_usd"].doubleValue ?? 0,
                                       reserved: p["reserved_usd"].doubleValue ?? 0, carved: p["carved_usd"].doubleValue ?? 0,
                                       available: p["available_usd"].doubleValue ?? 0)
        maxGrant = j["max_grant_usd"].doubleValue
        children = j["children"].items.map { Child(id: $0["mission_id"].text, mode: $0["mode"].text, budget: $0["budget_usd"].doubleValue, spent: $0["spent_usd"].doubleValue ?? 0) }
    }

    /// Same derivation as desktop `optimisticBudget`.
    func optimistic(_ amount: Double?) -> OrbMissionBudget {
        var next = self
        guard let amount else {
            next.mode = (mode == "own" && maxGrant != nil) ? "pooled" : "none"
            next.ownBudget = nil; next.pool = nil; next.poolId = nil
            return next
        }
        if var p = pool, mode == "own" {
            p.available += amount - p.budget; p.budget = amount; next.pool = p
        } else {
            next.pool = Pool(budget: amount, spent: 0, reserved: 0, carved: 0, available: amount)
        }
        next.ownBudget = amount; next.mode = "own"; next.poolId = missionId
        return next
    }

    var modeLine: String {
        switch mode {
        case "own": return maxGrant != nil ? "Own sub-budget, carved from the parent's pool. Its subagents share it." : "Own budget. Subagents share it unless you give one a sub-budget."
        case "pooled": return "Shares the pool of an ancestor agent."
        default: return "No budget. Only the daily managed-machine cap applies."
        }
    }

    static func money(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }
}

/// Long-press "Mission settings…" on a mission row: the Budget section of
/// the desktop sheet. Optimistic, with rollback and Retry on refusal.
struct OrbMissionSettingsSheet: View {
    let missionId: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var view: OrbMissionBudget?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var pendingRetry: Double??
    @State private var draft = ""
    @State private var busy = false
    private let api = OrbCore.shared
    private var path: String { "/api/control/missions/\(OrbCore.escape(missionId))/budget" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let v = view {
                        Toggle("Spending budget", isOn: Binding(get: { v.mode == "own" }, set: { on in toggle(on) }))
                            .disabled(busy)
                            .accessibilityIdentifier("mission.settings.budget.toggle")
                        Text(v.modeLine).font(.footnote).foregroundStyle(.secondary)
                        if v.mode == "own" {
                            HStack {
                                TextField("Amount (USD)", text: $draft).keyboardType(.decimalPad)
                                    .accessibilityIdentifier("mission.settings.budget.amount")
                                Button("Save") { save() }.disabled(busy || draft == format(v.ownBudget))
                            }
                            if let max = v.maxGrant { Text("Up to \(OrbMissionBudget.money(max)) from the parent pool.").font(.footnote).foregroundStyle(.secondary) }
                        }
                        if let p = v.pool {
                            ProgressView(value: min(1, max(0, (p.spent + p.reserved + p.carved) / max(p.budget, 0.0001))))
                            LabeledContent("Spent", value: OrbMissionBudget.money(p.spent))
                            LabeledContent("Reserved", value: OrbMissionBudget.money(p.reserved))
                            LabeledContent("Sub-budgets", value: OrbMissionBudget.money(p.carved))
                            LabeledContent("Remaining", value: "\(OrbMissionBudget.money(max(0, p.available))) of \(OrbMissionBudget.money(p.budget))")
                        }
                    } else if let loadError {
                        Text(loadError).foregroundStyle(OrbStyle.warning)
                        Button("Retry") { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let saveError {
                        Text("Budget not saved: \(saveError)").font(.footnote).foregroundStyle(OrbStyle.warning)
                        if let retry = pendingRetry { Button("Retry") { commit(retry) } }
                    }
                } header: { Text("Budget") } footer: {
                    Text("Caps what this agent and its subagents spend on managed machines. Reserved holds up to 60 minutes of each running machine.")
                }
                if let children = view?.children, !children.isEmpty {
                    Section("Subagents") {
                        ForEach(children) { c in
                            LabeledContent("Agent \(c.id.prefix(8))", value: "\(c.mode == "sub_budget" ? "Sub-budget \(OrbMissionBudget.money(c.budget ?? 0))" : "Pooled") · \(OrbMissionBudget.money(c.spent)) spent")
                        }
                    }
                }
            }
            .navigationTitle("Mission settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func format(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }

    private func load() async {
        loadError = nil
        do {
            let v = OrbMissionBudget(try await api.call(path))
            view = v; draft = format(v.ownBudget)
        } catch { loadError = error.localizedDescription }
    }

    private func toggle(_ on: Bool) {
        guard let v = view else { return }
        if !on { return commit(nil) }
        let initial = v.maxGrant.map { min(5, ($0 * 100).rounded(.down) / 100) } ?? 5
        guard initial > 0 else { saveError = "The parent pool has nothing left to grant"; return }
        commit(initial)
    }

    private func save() {
        guard let value = Double(draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")), value > 0 else {
            saveError = "Enter a positive amount"; return
        }
        if let max = view?.maxGrant, value > max + 1e-9 { saveError = "The parent pool has \(OrbMissionBudget.money(max)) left to grant"; return }
        commit(value)
    }

    private func commit(_ amount: Double?) {
        guard let before = view, !busy else { return }
        busy = true; saveError = nil; pendingRetry = nil
        view = before.optimistic(amount)
        Task {
            defer { busy = false }
            do {
                let body: OrbJSON = .object(["budget_usd": amount.map { .number($0) } ?? .null])
                let next = OrbMissionBudget(try await api.call(path, method: "PUT", body: body))
                view = next; draft = format(next.ownBudget)
                OrbHaptics.selection()
            } catch {
                view = before; draft = format(before.ownBudget)
                saveError = error.localizedDescription
                pendingRetry = .some(amount)
            }
        }
    }
}
