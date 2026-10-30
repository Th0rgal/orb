import SwiftUI

/// `GET /api/control/missions/:id/budget` (desktop: `orb/src/missionBudget.ts`).
struct OrbMissionBudget: Equatable {
    static let maxVmConcurrency = 128
    static let providers: [(id: String, label: String)] = [
        ("boat", "boat.dev"),
        ("hetzner", "Hetzner"),
        ("vastai", "Vast.ai"),
        ("scaleway", "Scaleway"),
    ]

    struct ParseError: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Pool: Equatable {
        var budget: Double, spent: Double, reserved: Double, carved: Double, available: Double
    }

    struct VmConcurrencyLimits: Equatable {
        var maxConcurrent: Int?
        var providerMaxConcurrent: [String: Int]

        init(maxConcurrent: Int? = nil, providerMaxConcurrent: [String: Int] = [:]) {
            self.maxConcurrent = maxConcurrent
            self.providerMaxConcurrent = providerMaxConcurrent
        }

        init?(_ j: OrbJSON) {
            guard case .object(let d) = j else { return nil }
            maxConcurrent = d["max_concurrent"]?.doubleValue.map(Int.init)
            var pm: [String: Int] = [:]
            if case .object(let rawMap) = d["provider_max_concurrent"] ?? .null {
                for (k, v) in rawMap {
                    if let n = v.doubleValue { pm[k] = Int(n) }
                }
            }
            providerMaxConcurrent = pm
        }

        func toJSON() -> OrbJSON {
            var provObj: [String: OrbJSON] = [:]
            for (k, v) in providerMaxConcurrent { provObj[k] = .number(Double(v)) }
            return .object([
                "max_concurrent": maxConcurrent.map { .number(Double($0)) } ?? .null,
                "provider_max_concurrent": .object(provObj),
            ])
        }
    }

    struct ProviderCapUsage: Equatable, Identifiable {
        var id: String { provider }
        var provider: String
        var active: Int
        var maxConcurrent: Int
    }

    struct EffectiveVmLimits: Equatable {
        var source: String
        var poolId: String?
        var active: Int
        var maxConcurrent: Int?
        var globalActive: Int
        var globalMaxConcurrent: Int?
        var ancestorMaxConcurrent: Int?
        var providerLimits: [ProviderCapUsage]

        init(
            source: String, poolId: String?, active: Int, maxConcurrent: Int?,
            globalActive: Int, globalMaxConcurrent: Int?, ancestorMaxConcurrent: Int?,
            providerLimits: [ProviderCapUsage]
        ) {
            self.source = source; self.poolId = poolId; self.active = active; self.maxConcurrent = maxConcurrent
            self.globalActive = globalActive; self.globalMaxConcurrent = globalMaxConcurrent
            self.ancestorMaxConcurrent = ancestorMaxConcurrent; self.providerLimits = providerLimits
        }

        init?(_ j: OrbJSON) {
            guard case .object = j else { return nil }
            source = j["source"].text.isEmpty ? "global" : j["source"].text
            poolId = j["pool_id"].text.isEmpty ? nil : j["pool_id"].text
            active = j["active"].doubleValue.map(Int.init) ?? 0
            maxConcurrent = j["max_concurrent"].doubleValue.map(Int.init)
            globalActive = j["global_active"].doubleValue.map(Int.init) ?? 0
            globalMaxConcurrent = j["global_max_concurrent"].doubleValue.map(Int.init)
            ancestorMaxConcurrent = j["ancestor_max_concurrent"].doubleValue.map(Int.init)
            providerLimits = j["provider_limits"].items.map {
                ProviderCapUsage(
                    provider: $0["provider"].text,
                    active: $0["active"].doubleValue.map(Int.init) ?? 0,
                    maxConcurrent: $0["max_concurrent"].doubleValue.map(Int.init) ?? 0
                )
            }
        }
    }

    struct Child: Equatable, Identifiable {
        let id: String
        let mode: String
        let budget: Double?
        let spent: Double
        var reserved: Double = 0
        var hasVmLimits: Bool = false
        var vmMaxConcurrent: Int? = nil
        var liveMachines: Int = 0

        var isIdlePooled: Bool {
            mode == "pooled" && !hasVmLimits && spent == 0 && reserved == 0 && liveMachines == 0
        }
    }

    var missionId: String
    var ownBudget: Double?
    var poolId: String?
    var mode: String
    var pool: Pool?
    var maxGrant: Double?
    var ownVmLimits: VmConcurrencyLimits?
    var vmLimitsMode: String
    var vmLimitsPoolId: String?
    var effectiveVmLimits: EffectiveVmLimits?
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
        ownVmLimits = VmConcurrencyLimits(j["own_vm_limits"])
        vmLimitsMode = j["vm_limits_mode"].text.isEmpty ? (ownVmLimits != nil ? "own" : "global") : j["vm_limits_mode"].text
        vmLimitsPoolId = j["vm_limits_pool_id"].text.isEmpty ? nil : j["vm_limits_pool_id"].text
        effectiveVmLimits = EffectiveVmLimits(j["effective_vm_limits"])
        children = j["children"].items.map {
            Child(
                id: $0["mission_id"].text,
                mode: $0["mode"].text.isEmpty ? "pooled" : $0["mode"].text,
                budget: $0["budget_usd"].doubleValue,
                spent: $0["spent_usd"].doubleValue ?? 0,
                reserved: $0["reserved_usd"].doubleValue ?? 0,
                hasVmLimits: $0["has_vm_limits"].flag,
                vmMaxConcurrent: $0["vm_max_concurrent"].doubleValue.map(Int.init),
                liveMachines: $0["live_machines"].doubleValue.map(Int.init) ?? 0
            )
        }
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

    /// Same derivation as desktop `optimisticVmLimits`.
    func optimisticVmLimits(_ limits: VmConcurrencyLimits?) -> OrbMissionBudget {
        var next = self
        let prev = effectiveVmLimits
        let globalActive = prev?.globalActive ?? 0
        let globalMax = prev?.globalMaxConcurrent
        let ancestorMax = prev?.ancestorMaxConcurrent
        guard let limits else {
            let inherited = vmLimitsMode == "own" && ancestorMax != nil
            next.ownVmLimits = nil
            next.vmLimitsMode = inherited ? "pooled" : "global"
            next.vmLimitsPoolId = nil
            next.effectiveVmLimits = EffectiveVmLimits(
                source: inherited ? "mission" : "global",
                poolId: nil,
                active: globalActive,
                maxConcurrent: inherited ? ancestorMax : globalMax,
                globalActive: globalActive,
                globalMaxConcurrent: globalMax,
                ancestorMaxConcurrent: ancestorMax,
                providerLimits: []
            )
            return next
        }
        let active = prev?.source == "mission" ? (prev?.active ?? 0) : 0
        let provCaps: [ProviderCapUsage] = Self.providers.compactMap { p in
            guard let maxC = limits.providerMaxConcurrent[p.id] else { return nil }
            let cur = prev?.providerLimits.first(where: { $0.provider == p.id })?.active ?? 0
            return ProviderCapUsage(provider: p.id, active: cur, maxConcurrent: maxC)
        }
        let maxC: Int?
        if let m = limits.maxConcurrent, let a = ancestorMax {
            maxC = min(m, a)
        } else {
            maxC = limits.maxConcurrent ?? ancestorMax
        }
        next.ownVmLimits = limits
        next.vmLimitsMode = "own"
        next.vmLimitsPoolId = missionId
        next.effectiveVmLimits = EffectiveVmLimits(
            source: "mission",
            poolId: missionId,
            active: active,
            maxConcurrent: maxC,
            globalActive: globalActive,
            globalMaxConcurrent: globalMax,
            ancestorMaxConcurrent: ancestorMax,
            providerLimits: provCaps
        )
        return next
    }

    var modeLine: String {
        switch mode {
        case "own": return maxGrant != nil ? "Own sub-budget, carved from the parent's pool. Its subagents share it." : "Own budget. Subagents share it unless you give one a sub-budget."
        case "pooled": return "Shares the pool of an ancestor agent."
        default: return "No budget. Only the daily managed-machine cap applies."
        }
    }

    var vmLimitsModeLine: String {
        switch vmLimitsMode {
        case "own":
            if let anc = effectiveVmLimits?.ancestorMaxConcurrent {
                return "Own sub-limit within the parent pool (up to \(anc) concurrent)."
            }
            return "Dedicated cap for this agent and its subagents (bypasses the global limit)."
        case "pooled":
            return "Shares the machine limit of an ancestor agent."
        default:
            if let g = effectiveVmLimits?.globalMaxConcurrent {
                return "Uses the global limit (\(g) concurrent across Orb)."
            }
            return "Uses the global machine limit."
        }
    }

    var showsSubagents: Bool {
        guard !children.isEmpty else { return false }
        if mode != "none" || vmLimitsMode != "global" { return true }
        return children.contains { $0.mode == "sub_budget" || $0.hasVmLimits }
    }

    static func providerLabel(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.label ?? id
    }

    static func providerLimitsSummary(_ limits: VmConcurrencyLimits?) -> String {
        guard let map = limits?.providerMaxConcurrent, !map.isEmpty else { return "" }
        return providers.compactMap { p in
            guard let v = map[p.id] else { return nil }
            return "\(p.label): \(v == 0 ? "off" : String(v))"
        }.joined(separator: " · ")
    }

    private static func parseWholeInt(_ raw: String, min: Int, max: Int, label: String) -> Result<Int, ParseError> {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else {
            return .failure(ParseError(message: "\(label) must be a whole number"))
        }
        guard let value = Int(raw), value >= min, value <= max else {
            return .failure(ParseError(message: "\(label) must be between \(min) and \(max)"))
        }
        return .success(value)
    }

    static func parseVmLimits(
        totalRaw: String,
        providerRaws: [String: String],
        view: OrbMissionBudget? = nil
    ) -> Result<VmConcurrencyLimits, ParseError> {
        let ancestorMax = view?.effectiveVmLimits?.ancestorMaxConcurrent
        let trimmedTotal = totalRaw.trimmingCharacters(in: .whitespaces)
        var maxConcurrent: Int? = nil
        if !trimmedTotal.isEmpty {
            switch parseWholeInt(trimmedTotal, min: 1, max: maxVmConcurrency, label: "Max concurrent") {
            case .failure(let err): return .failure(err)
            case .success(let v):
                if let anc = ancestorMax, v > anc {
                    return .failure(ParseError(message: "The parent agent limits concurrent machines to \(anc)"))
                }
                maxConcurrent = v
            }
        }
        var provMap: [String: Int] = [:]
        for p in providers {
            let text = (providerRaws[p.id] ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            switch parseWholeInt(text, min: 0, max: maxVmConcurrency, label: p.label) {
            case .failure(let err): return .failure(err)
            case .success(let v):
                if let maxC = maxConcurrent, v > maxC {
                    return .failure(ParseError(message: "\(p.label) limit (\(v)) cannot exceed max concurrent (\(maxC))"))
                }
                if let anc = ancestorMax, v > anc {
                    return .failure(ParseError(message: "\(p.label) limit (\(v)) cannot exceed the parent limit (\(anc))"))
                }
                provMap[p.id] = v
            }
        }
        if maxConcurrent == nil && provMap.isEmpty {
            return .failure(ParseError(message: "Enter a max concurrent limit or at least one provider limit"))
        }
        return .success(VmConcurrencyLimits(maxConcurrent: maxConcurrent, providerMaxConcurrent: provMap))
    }

    static func money(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }
}

/// Long-press "Mission settings…" on a mission row: Budget + Machine limit
/// sections of the desktop sheet. Optimistic, with rollback and Retry on refusal.
struct OrbMissionSettingsSheet: View {
    let missionId: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var view: OrbMissionBudget?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var pendingRetry: Double??
    @State private var draft = ""
    @State private var vmSaveError: String?
    @State private var pendingVmRetry: OrbMissionBudget.VmConcurrencyLimits??
    @State private var vmTotalDraft = ""
    @State private var vmProviderDrafts: [String: String] = [:]
    @State private var providersExpanded = false
    @State private var showIdleChildren = false
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

                if let v = view {
                    Section {
                        Toggle("Machine limit", isOn: Binding(get: { v.vmLimitsMode == "own" }, set: { on in toggleVmLimits(on) }))
                            .disabled(busy)
                            .accessibilityIdentifier("mission.settings.vmlimits.toggle")
                        Text(v.vmLimitsModeLine).font(.footnote).foregroundStyle(.secondary)
                        if let eff = v.effectiveVmLimits {
                            let activeLabel = eff.maxConcurrent.map { "\(eff.active) / \($0)" } ?? "\(eff.active) running"
                            LabeledContent(eff.source == "mission" ? "Pool active" : "Global active", value: activeLabel)
                            ForEach(eff.providerLimits) { pc in
                                LabeledContent(
                                    OrbMissionBudget.providerLabel(pc.provider),
                                    value: pc.maxConcurrent == 0 ? "Blocked" : "\(pc.active) / \(pc.maxConcurrent)"
                                )
                            }
                        }
                        if v.vmLimitsMode == "own" {
                            HStack {
                                Text("Max concurrent")
                                Spacer()
                                TextField("Optional", text: $vmTotalDraft)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 110)
                                    .accessibilityIdentifier("mission.settings.vmlimits.total")
                            }
                            DisclosureGroup(isExpanded: $providersExpanded) {
                                ForEach(OrbMissionBudget.providers, id: \.id) { p in
                                    HStack {
                                        Text(p.label)
                                        Spacer()
                                        TextField("No cap (0 = off)", text: Binding(
                                            get: { vmProviderDrafts[p.id] ?? "" },
                                            set: { vmProviderDrafts[p.id] = $0 }
                                        ))
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: 140)
                                        .accessibilityIdentifier("mission.settings.vmlimits.provider.\(p.id)")
                                    }
                                }
                            } label: {
                                let summary = OrbMissionBudget.providerLimitsSummary(v.ownVmLimits)
                                LabeledContent("Per-provider limits", value: summary.isEmpty ? "Optional" : summary)
                            }
                            Button("Save machine limit") { saveVmLimits() }
                                .disabled(busy || !vmDraftDirty(v))
                                .accessibilityIdentifier("mission.settings.vmlimits.save")
                        }
                        if let vmSaveError {
                            Text("Machine limit not saved: \(vmSaveError)").font(.footnote).foregroundStyle(OrbStyle.warning)
                            if let retry = pendingVmRetry { Button("Retry") { commitVmLimits(retry) } }
                        }
                    } header: { Text("Machine limit") } footer: {
                        Text("Overrides the global concurrent machine cap for this agent and its subagents. Set a provider to 0 to block it.")
                    }

                    if v.showsSubagents {
                        let activeRows = v.children.filter { !$0.isIdlePooled }
                        let idleRows = v.children.filter(\.isIdlePooled)
                        let visible = showIdleChildren ? v.children : activeRows
                        Section("Subagents") {
                            ForEach(visible) { c in
                                LabeledContent("Agent \(c.id.prefix(8))", value: childSummary(c))
                            }
                            if !idleRows.isEmpty {
                                Button(showIdleChildren ? "Hide $0 rows" : "\(idleRows.count) with $0 spend · Show") {
                                    showIdleChildren.toggle()
                                }
                                .font(.footnote)
                            }
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

    private func childSummary(_ c: OrbMissionBudget.Child) -> String {
        var parts: [String] = []
        parts.append(c.mode == "sub_budget" ? "Sub-budget \(OrbMissionBudget.money(c.budget ?? 0))" : "Pooled")
        if c.hasVmLimits {
            parts.append(c.vmMaxConcurrent.map { "max \($0) VM" } ?? "custom VM cap")
        }
        parts.append("\(OrbMissionBudget.money(c.spent)) spent")
        return parts.joined(separator: " · ")
    }

    private func format(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }

    private func syncVmDrafts(_ v: OrbMissionBudget) {
        vmTotalDraft = v.ownVmLimits?.maxConcurrent.map(String.init) ?? ""
        var map: [String: String] = [:]
        for p in OrbMissionBudget.providers {
            map[p.id] = v.ownVmLimits?.providerMaxConcurrent[p.id].map(String.init) ?? ""
        }
        vmProviderDrafts = map
        if !(v.ownVmLimits?.providerMaxConcurrent.isEmpty ?? true) {
            providersExpanded = true
        }
    }

    private func vmDraftDirty(_ v: OrbMissionBudget) -> Bool {
        let curTotal = v.ownVmLimits?.maxConcurrent.map(String.init) ?? ""
        if vmTotalDraft.trimmingCharacters(in: .whitespaces) != curTotal { return true }
        for p in OrbMissionBudget.providers {
            let cur = v.ownVmLimits?.providerMaxConcurrent[p.id].map(String.init) ?? ""
            if (vmProviderDrafts[p.id] ?? "").trimmingCharacters(in: .whitespaces) != cur { return true }
        }
        return false
    }

    private func load() async {
        loadError = nil
        do {
            let v = OrbMissionBudget(try await api.call(path))
            view = v; draft = format(v.ownBudget); syncVmDrafts(v)
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
                view = next; draft = format(next.ownBudget); syncVmDrafts(next)
                OrbHaptics.selection()
            } catch {
                view = before; draft = format(before.ownBudget)
                saveError = error.localizedDescription
                pendingRetry = .some(amount)
            }
        }
    }

    private func toggleVmLimits(_ on: Bool) {
        guard let v = view else { return }
        if !on { return commitVmLimits(nil) }
        let ancMax = v.effectiveVmLimits?.ancestorMaxConcurrent
        if let anc = ancMax, anc <= 0 {
            vmSaveError = "The parent pool does not allow concurrent machines"
            return
        }
        let initial = ancMax.map { min(4, $0) } ?? 4
        commitVmLimits(.init(maxConcurrent: initial, providerMaxConcurrent: [:]))
    }

    private func saveVmLimits() {
        switch OrbMissionBudget.parseVmLimits(totalRaw: vmTotalDraft, providerRaws: vmProviderDrafts, view: view) {
        case .failure(let err):
            vmSaveError = err.message
        case .success(let limits):
            commitVmLimits(limits)
        }
    }

    private func commitVmLimits(_ limits: OrbMissionBudget.VmConcurrencyLimits?) {
        guard let before = view, !busy else { return }
        busy = true; vmSaveError = nil; pendingVmRetry = nil
        let opt = before.optimisticVmLimits(limits)
        view = opt; syncVmDrafts(opt)
        Task {
            defer { busy = false }
            do {
                let body: OrbJSON = .object(["vm_limits": limits?.toJSON() ?? .null])
                let next = OrbMissionBudget(try await api.call(path, method: "PUT", body: body))
                view = next; draft = format(next.ownBudget); syncVmDrafts(next)
                OrbHaptics.selection()
            } catch {
                view = before; syncVmDrafts(before)
                vmSaveError = error.localizedDescription
                pendingVmRetry = .some(limits)
            }
        }
    }
}
