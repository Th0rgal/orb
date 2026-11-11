import SwiftUI

/// `GET /api/control/missions/:id/budget` (desktop: `orb/src/missionBudget.ts`).
struct OrbMissionBudget: Equatable {
    static let maxVmConcurrency = 128
    static let minTokensPerMin = 1_000
    static let maxTokensPerMin = 100_000_000
    static let minInferenceUsdPerHour = 0.01
    static let maxInferenceUsdPerHour = 10_000.0
    static let maxComputeVcpuPerMin = 4_096
    static let minComputeUsdPerHour = 0.01
    static let maxComputeUsdPerHour = 10_000.0

    enum BudgetResetPeriod: String, CaseIterable, Equatable {
        case total
        case daily
        case weekly

        var label: String {
            switch self {
            case .total: return "Total"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }

        init(wire: String) {
            switch wire.lowercased() {
            case "daily": self = .daily
            case "weekly": self = .weekly
            default: self = .total
            }
        }
    }

    static let providers: [(id: String, label: String)] = [
        ("boat", "boat.dev"),
        ("leanci", "lean.ci"),
        ("hetzner", "Hetzner"),
        ("vastai", "Vast.ai"),
        ("scaleway", "Scaleway"),
        ("colab", "Google Colab"),
    ]

    struct ParseError: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct LiveLease: Equatable {
        var remainingSecs: Double
        var usdPerHour: Double
    }

    struct Pool: Equatable {
        var budget: Double
        var spent: Double
        var lifetimeSpent: Double = 0
        var reserved: Double
        var carved: Double
        var persistentCarved: Double? = nil
        var available: Double
        var liveMachines: Int = 0
        var liveLeases: [LiveLease] = []
        var resetPeriod: BudgetResetPeriod = .total
        var periodStartedAt: String? = nil
        var periodResetsAt: String? = nil
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

    struct BandwidthLimits: Equatable {
        var tokensPerMin: Int?
        var inferenceUsdPerHour: Double?
        var computeVcpuPerMin: Int?
        var computeUsdPerHour: Double?
        var protectRoot: Bool

        init(
            tokensPerMin: Int? = nil,
            inferenceUsdPerHour: Double? = nil,
            computeVcpuPerMin: Int? = nil,
            computeUsdPerHour: Double? = nil,
            protectRoot: Bool = true
        ) {
            self.tokensPerMin = tokensPerMin
            self.inferenceUsdPerHour = inferenceUsdPerHour
            self.computeVcpuPerMin = computeVcpuPerMin
            self.computeUsdPerHour = computeUsdPerHour
            self.protectRoot = protectRoot
        }

        init?(_ j: OrbJSON) {
            guard case .object(let d) = j else { return nil }
            tokensPerMin = d["tokens_per_min"]?.doubleValue.map(Int.init)
            inferenceUsdPerHour = d["inference_usd_per_hour"]?.doubleValue
            computeVcpuPerMin = d["compute_vcpu_per_min"]?.doubleValue.map(Int.init)
            computeUsdPerHour = d["compute_usd_per_hour"]?.doubleValue
            protectRoot = (d["protect_root"] ?? .null).flag
        }

        func toJSON() -> OrbJSON {
            .object([
                "tokens_per_min": tokensPerMin.map { .number(Double($0)) } ?? .null,
                "inference_usd_per_hour": inferenceUsdPerHour.map { .number($0) } ?? .null,
                "compute_vcpu_per_min": computeVcpuPerMin.map { .number(Double($0)) } ?? .null,
                "compute_usd_per_hour": computeUsdPerHour.map { .number($0) } ?? .null,
                "protect_root": .bool(protectRoot),
            ])
        }
    }

    struct EffectiveBandwidth: Equatable {
        var source: String
        var poolId: String?
        var tokensPerMin: Int?
        var inferenceUsdPerHour: Double?
        var computeVcpuPerMin: Int?
        var computeUsdPerHour: Double?
        var protectRoot: Bool
        var currentTokensPerMin: Int
        var currentInferenceUsdPerHour: Double
        var currentVcpuPerMin: Int
        var currentComputeUsdPerHour: Double
        var pacingActive: Bool
        var pacedDelayMs: Int
        var ancestorTokensPerMin: Int?
        var ancestorInferenceUsdPerHour: Double?
        var ancestorComputeVcpuPerMin: Int?
        var ancestorComputeUsdPerHour: Double?

        init(
            source: String, poolId: String?, tokensPerMin: Int?, inferenceUsdPerHour: Double? = nil,
            computeVcpuPerMin: Int?, computeUsdPerHour: Double?, protectRoot: Bool,
            currentTokensPerMin: Int, currentInferenceUsdPerHour: Double = 0,
            currentVcpuPerMin: Int, currentComputeUsdPerHour: Double, pacingActive: Bool,
            pacedDelayMs: Int, ancestorTokensPerMin: Int?, ancestorInferenceUsdPerHour: Double? = nil,
            ancestorComputeVcpuPerMin: Int?, ancestorComputeUsdPerHour: Double?
        ) {
            self.source = source; self.poolId = poolId
            self.tokensPerMin = tokensPerMin; self.inferenceUsdPerHour = inferenceUsdPerHour
            self.computeVcpuPerMin = computeVcpuPerMin
            self.computeUsdPerHour = computeUsdPerHour; self.protectRoot = protectRoot
            self.currentTokensPerMin = currentTokensPerMin
            self.currentInferenceUsdPerHour = currentInferenceUsdPerHour
            self.currentVcpuPerMin = currentVcpuPerMin
            self.currentComputeUsdPerHour = currentComputeUsdPerHour
            self.pacingActive = pacingActive; self.pacedDelayMs = pacedDelayMs
            self.ancestorTokensPerMin = ancestorTokensPerMin
            self.ancestorInferenceUsdPerHour = ancestorInferenceUsdPerHour
            self.ancestorComputeVcpuPerMin = ancestorComputeVcpuPerMin
            self.ancestorComputeUsdPerHour = ancestorComputeUsdPerHour
        }

        init?(_ j: OrbJSON) {
            guard case .object = j else { return nil }
            source = j["source"].text.isEmpty ? "none" : j["source"].text
            poolId = j["pool_id"].text.isEmpty ? nil : j["pool_id"].text
            tokensPerMin = j["tokens_per_min"].doubleValue.map(Int.init)
            inferenceUsdPerHour = j["inference_usd_per_hour"].doubleValue
            computeVcpuPerMin = j["compute_vcpu_per_min"].doubleValue.map(Int.init)
            computeUsdPerHour = j["compute_usd_per_hour"].doubleValue
            protectRoot = j["protect_root"].flag
            currentTokensPerMin = j["current_tokens_per_min"].doubleValue.map(Int.init) ?? 0
            currentInferenceUsdPerHour = j["current_inference_usd_per_hour"].doubleValue ?? 0
            currentVcpuPerMin = j["current_vcpu_per_min"].doubleValue.map(Int.init) ?? 0
            currentComputeUsdPerHour = j["current_compute_usd_per_hour"].doubleValue ?? 0
            pacingActive = j["pacing_active"].flag
            pacedDelayMs = j["paced_delay_ms"].doubleValue.map(Int.init) ?? 0
            ancestorTokensPerMin = j["ancestor_tokens_per_min"].doubleValue.map(Int.init)
            ancestorInferenceUsdPerHour = j["ancestor_inference_usd_per_hour"].doubleValue
            ancestorComputeVcpuPerMin = j["ancestor_compute_vcpu_per_min"].doubleValue.map(Int.init)
            ancestorComputeUsdPerHour = j["ancestor_compute_usd_per_hour"].doubleValue
        }
    }

    struct RunwayForecast: Equatable {
        enum Tone: String, Equatable { case ok, warning, danger }
        var hasBudget: Bool
        var capUsd: Double?
        var spentUsd: Double
        var reservedUsd: Double
        var carvedUsd: Double
        var availableUsd: Double
        var observedComputeBurnUsdPerH: Double
        var shapedComputeBurnUsdPerH: Double
        var resetPeriod: BudgetResetPeriod
        var resetsInSecs: Double?
        var sustainsUntilReset: Bool
        var leaseCliffSecs: Double?
        var etaSecs: Double?
        var etaGainSecs: Double?
        var tone: Tone
        var headline: String
        var subline: String
    }

    struct Child: Equatable, Identifiable {
        let id: String
        let mode: String
        let budget: Double?
        let spent: Double
        var reserved: Double = 0
        var hasVmLimits: Bool = false
        var vmMaxConcurrent: Int? = nil
        var hasBandwidthLimits: Bool = false
        var tokensPerMin: Int? = nil
        var liveMachines: Int = 0

        var isIdlePooled: Bool {
            mode == "pooled" && !hasVmLimits && !hasBandwidthLimits && spent == 0 && reserved == 0 && liveMachines == 0
        }
    }

    var missionId: String
    var ownBudget: Double?
    var ownBudgetResetPeriod: BudgetResetPeriod = .total
    var poolId: String?
    var mode: String
    var pool: Pool?
    var maxGrant: Double?
    var ownVmLimits: VmConcurrencyLimits?
    var vmLimitsMode: String
    var vmLimitsPoolId: String?
    var effectiveVmLimits: EffectiveVmLimits?
    var ownBandwidthLimits: BandwidthLimits?
    var bandwidthMode: String
    var bandwidthPoolId: String?
    var effectiveBandwidth: EffectiveBandwidth?
    var children: [Child]

    init(_ j: OrbJSON) {
        missionId = j["mission_id"].text
        ownBudget = j["own_budget_usd"].doubleValue
        ownBudgetResetPeriod = BudgetResetPeriod(wire: j["own_budget_reset_period"].text)
        poolId = j["pool_id"].text.isEmpty ? nil : j["pool_id"].text
        mode = j["mode"].text.isEmpty ? "none" : j["mode"].text
        let p = j["pool"]
        let pSpent = p["spent_usd"].doubleValue ?? 0
        let pCarved = p["carved_usd"].doubleValue ?? 0
        pool = p == .null ? nil : Pool(
            budget: p["budget_usd"].doubleValue ?? 0,
            spent: pSpent,
            lifetimeSpent: p["lifetime_spent_usd"].doubleValue ?? pSpent,
            reserved: p["reserved_usd"].doubleValue ?? 0,
            carved: pCarved,
            persistentCarved: p["persistent_carved_usd"].doubleValue,
            available: p["available_usd"].doubleValue ?? 0,
            liveMachines: p["live_machines"].doubleValue.map(Int.init) ?? 0,
            liveLeases: p["live_leases"].items.map {
                LiveLease(
                    remainingSecs: $0["remaining_secs"].doubleValue ?? 0,
                    usdPerHour: $0["usd_per_hour"].doubleValue ?? 0
                )
            },
            resetPeriod: BudgetResetPeriod(wire: p["reset_period"].text),
            periodStartedAt: p["period_started_at"].text.isEmpty ? nil : p["period_started_at"].text,
            periodResetsAt: p["period_resets_at"].text.isEmpty ? nil : p["period_resets_at"].text
        )
        maxGrant = j["max_grant_usd"].doubleValue
        ownVmLimits = VmConcurrencyLimits(j["own_vm_limits"])
        vmLimitsMode = j["vm_limits_mode"].text.isEmpty ? (ownVmLimits != nil ? "own" : "global") : j["vm_limits_mode"].text
        vmLimitsPoolId = j["vm_limits_pool_id"].text.isEmpty ? nil : j["vm_limits_pool_id"].text
        effectiveVmLimits = EffectiveVmLimits(j["effective_vm_limits"])
        ownBandwidthLimits = BandwidthLimits(j["own_bandwidth_limits"])
        bandwidthMode = j["bandwidth_mode"].text.isEmpty ? (ownBandwidthLimits != nil ? "own" : "none") : j["bandwidth_mode"].text
        bandwidthPoolId = j["bandwidth_pool_id"].text.isEmpty ? nil : j["bandwidth_pool_id"].text
        effectiveBandwidth = EffectiveBandwidth(j["effective_bandwidth"])
        children = j["children"].items.map {
            Child(
                id: $0["mission_id"].text,
                mode: $0["mode"].text.isEmpty ? "pooled" : $0["mode"].text,
                budget: $0["budget_usd"].doubleValue,
                spent: $0["spent_usd"].doubleValue ?? 0,
                reserved: $0["reserved_usd"].doubleValue ?? 0,
                hasVmLimits: $0["has_vm_limits"].flag,
                vmMaxConcurrent: $0["vm_max_concurrent"].doubleValue.map(Int.init),
                hasBandwidthLimits: $0["has_bandwidth_limits"].flag,
                tokensPerMin: $0["tokens_per_min"].doubleValue.map(Int.init),
                liveMachines: $0["live_machines"].doubleValue.map(Int.init) ?? 0
            )
        }
    }

    /// Same derivation as desktop `optimisticBudget`.
    func optimistic(_ amount: Double?, resetPeriod: BudgetResetPeriod? = nil) -> OrbMissionBudget {
        var next = self
        guard let amount else {
            next.mode = (mode == "own" && maxGrant != nil) ? "pooled" : "none"
            next.ownBudget = nil; next.ownBudgetResetPeriod = .total; next.pool = nil; next.poolId = nil
            return next
        }
        let effPeriod: BudgetResetPeriod = maxGrant != nil
            ? .total
            : (resetPeriod ?? pool?.resetPeriod ?? ownBudgetResetPeriod)
        if var p = pool, mode == "own" {
            p.available += amount - p.budget; p.budget = amount; p.resetPeriod = effPeriod; next.pool = p
        } else {
            next.pool = Pool(
                budget: amount, spent: 0, lifetimeSpent: 0, reserved: 0, carved: 0,
                available: amount, resetPeriod: effPeriod
            )
        }
        next.ownBudget = amount; next.ownBudgetResetPeriod = effPeriod; next.mode = "own"; next.poolId = missionId
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

    /// Same derivation as desktop `optimisticBandwidthLimits`.
    func optimisticBandwidthLimits(_ limits: BandwidthLimits?) -> OrbMissionBudget {
        var next = self
        let prev = effectiveBandwidth
        let ancTpm = prev?.ancestorTokensPerMin
        let ancInfUsdH = prev?.ancestorInferenceUsdPerHour
        let ancVcpu = prev?.ancestorComputeVcpuPerMin
        let ancUsdH = prev?.ancestorComputeUsdPerHour
        let curTpm = prev?.currentTokensPerMin ?? 0
        let curInfUsdH = prev?.currentInferenceUsdPerHour ?? 0
        let curVcpu = prev?.currentVcpuPerMin ?? 0
        let curUsdH = prev?.currentComputeUsdPerHour ?? 0

        guard let limits else {
            let inherited = bandwidthMode == "own" && (ancTpm != nil || ancInfUsdH != nil || ancVcpu != nil || ancUsdH != nil)
            next.ownBandwidthLimits = nil
            next.bandwidthMode = inherited ? "pooled" : "none"
            next.bandwidthPoolId = nil
            next.effectiveBandwidth = EffectiveBandwidth(
                source: inherited ? "mission" : "none",
                poolId: nil,
                tokensPerMin: ancTpm,
                inferenceUsdPerHour: ancInfUsdH,
                computeVcpuPerMin: ancVcpu,
                computeUsdPerHour: ancUsdH,
                protectRoot: false,
                currentTokensPerMin: curTpm,
                currentInferenceUsdPerHour: curInfUsdH,
                currentVcpuPerMin: curVcpu,
                currentComputeUsdPerHour: curUsdH,
                pacingActive: false,
                pacedDelayMs: 0,
                ancestorTokensPerMin: ancTpm,
                ancestorInferenceUsdPerHour: ancInfUsdH,
                ancestorComputeVcpuPerMin: ancVcpu,
                ancestorComputeUsdPerHour: ancUsdH
            )
            return next
        }

        let effTpm = (limits.tokensPerMin != nil && ancTpm != nil)
            ? min(limits.tokensPerMin!, ancTpm!)
            : (limits.tokensPerMin ?? ancTpm)
        let effInfUsdH = (limits.inferenceUsdPerHour != nil && ancInfUsdH != nil)
            ? min(limits.inferenceUsdPerHour!, ancInfUsdH!)
            : (limits.inferenceUsdPerHour ?? ancInfUsdH)
        let effVcpu = (limits.computeVcpuPerMin != nil && ancVcpu != nil)
            ? min(limits.computeVcpuPerMin!, ancVcpu!)
            : (limits.computeVcpuPerMin ?? ancVcpu)
        let effUsdH = (limits.computeUsdPerHour != nil && ancUsdH != nil)
            ? min(limits.computeUsdPerHour!, ancUsdH!)
            : (limits.computeUsdPerHour ?? ancUsdH)

        next.ownBandwidthLimits = limits
        next.bandwidthMode = "own"
        next.bandwidthPoolId = missionId
        next.effectiveBandwidth = EffectiveBandwidth(
            source: "mission",
            poolId: missionId,
            tokensPerMin: effTpm,
            inferenceUsdPerHour: effInfUsdH,
            computeVcpuPerMin: effVcpu,
            computeUsdPerHour: effUsdH,
            protectRoot: limits.protectRoot,
            currentTokensPerMin: curTpm,
            currentInferenceUsdPerHour: curInfUsdH,
            currentVcpuPerMin: curVcpu,
            currentComputeUsdPerHour: curUsdH,
            pacingActive: prev?.pacingActive ?? false,
            pacedDelayMs: prev?.pacedDelayMs ?? 0,
            ancestorTokensPerMin: ancTpm,
            ancestorInferenceUsdPerHour: ancInfUsdH,
            ancestorComputeVcpuPerMin: ancVcpu,
            ancestorComputeUsdPerHour: ancUsdH
        )
        return next
    }

    var modeLine: String {
        switch mode {
        case "own":
            if maxGrant != nil {
                return "Own sub-budget, carved from the parent's pool. Its subagents share it."
            }
            let period = pool?.resetPeriod ?? ownBudgetResetPeriod
            switch period {
            case .daily:
                return "Own daily budget (resets 00:00 UTC). Subagents share it unless you give one a sub-budget."
            case .weekly:
                return "Own weekly budget (resets Mon 00:00 UTC). Subagents share it unless you give one a sub-budget."
            case .total:
                return "Own budget. Subagents share it unless you give one a sub-budget."
            }
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

    var bandwidthModeLine: String {
        switch bandwidthMode {
        case "own":
            return (ownBandwidthLimits?.protectRoot ?? false)
                ? "Smooths bursts by pacing subagent calls and spawns while keeping this root agent unthrottled."
                : "Smooths inference and machine spawn bursts with pace delays instead of hard errors."
        case "pooled":
            return "Shares the bandwidth pace pool of an ancestor agent."
        default:
            return "Unthrottled. Requests and spawns run at full speed."
        }
    }

    var showsSubagents: Bool {
        guard !children.isEmpty else { return false }
        if mode != "none" || vmLimitsMode != "global" || bandwidthMode != "none" { return true }
        return children.contains { $0.mode == "sub_budget" || $0.hasVmLimits || $0.hasBandwidthLimits }
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

    static func formatTokensPerMin(_ v: Int) -> String {
        if v >= 1_000_000 {
            let m = Double(v) / 1_000_000.0
            return m == m.rounded() ? String(format: "%.0fM tok/min", m) : String(format: "%.1fM tok/min", m)
        }
        if v >= 1_000 {
            let k = Double(v) / 1_000.0
            return k == k.rounded() ? String(format: "%.0fk tok/min", k) : String(format: "%.1fk tok/min", k)
        }
        return "\(v) tok/min"
    }

    static func formatDurationEta(_ secs: Double) -> String {
        if !secs.isFinite || secs <= 0 { return "0m" }
        if secs < 60 { return "<1m" }
        let totalMins = Int((secs / 60.0).rounded())
        if totalMins < 60 { return "~\(totalMins)m" }
        let hours = totalMins / 60
        let mins = totalMins % 60
        if hours < 48 { return mins > 0 ? "~\(hours)h \(mins)m" : "~\(hours)h" }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? "~\(days)d \(remHours)h" : "~\(days)d"
    }

    static func bandwidthLimitsSummary(_ limits: BandwidthLimits?) -> String {
        guard let limits else { return "" }
        var parts: [String] = []
        if let t = limits.tokensPerMin { parts.append(formatTokensPerMin(t)) }
        if let i = limits.inferenceUsdPerHour { parts.append("\(money(i))/h LLM") }
        if let v = limits.computeVcpuPerMin { parts.append("\(v) vCPU/min") }
        if let u = limits.computeUsdPerHour { parts.append("\(money(u))/h") }
        return parts.joined(separator: " · ")
    }

    static func nextBudgetResetMs(_ period: BudgetResetPeriod, nowMs: Double) -> Double? {
        if period == .total { return nil }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let nowDate = Date(timeIntervalSince1970: nowMs / 1000.0)
        let startOfToday = cal.startOfDay(for: nowDate)
        switch period {
        case .total:
            return nil
        case .daily:
            return cal.date(byAdding: .day, value: 1, to: startOfToday).map { $0.timeIntervalSince1970 * 1000.0 }
        case .weekly:
            // ISO8601 weekday in Foundation: 1=Sun, 2=Mon .. 7=Sat -> daysSinceMonday = (weekday + 5) % 7
            let wd = cal.component(.weekday, from: startOfToday)
            let daysSinceMonday = (wd + 5) % 7
            return cal.date(byAdding: .day, value: 7 - daysSinceMonday, to: startOfToday)
                .map { $0.timeIntervalSince1970 * 1000.0 }
        }
    }

    private static func parseIso8601Ms(_ raw: String) -> Double? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d.timeIntervalSince1970 * 1000.0 }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw).map { $0.timeIntervalSince1970 * 1000.0 }
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

    private static func parseTokenRate(_ raw: String) -> Result<Int, ParseError> {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !cleaned.isEmpty else {
            return .failure(ParseError(message: "Tokens per minute must be a number"))
        }
        var mult = 1.0
        var numPart = cleaned
        if let last = cleaned.last {
            if last == "k" || last == "K" {
                mult = 1_000.0
                numPart = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
            } else if last == "m" || last == "M" {
                mult = 1_000_000.0
                numPart = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let base = Double(numPart), base.isFinite else {
            return .failure(ParseError(message: "Tokens per minute must be a number (for example 120000 or 120k)"))
        }
        let val = Int((base * mult).rounded())
        guard val >= minTokensPerMin && val <= maxTokensPerMin else {
            return .failure(ParseError(message: "Tokens per minute must be between \(minTokensPerMin) and \(maxTokensPerMin)"))
        }
        return .success(val)
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

    static func parseBandwidthLimits(
        tokensPerMinRaw: String,
        computeVcpuRaw: String,
        computeUsdPerHRaw: String,
        protectRoot: Bool,
        view: OrbMissionBudget? = nil,
        inferenceUsdPerHRaw: String = ""
    ) -> Result<BandwidthLimits, ParseError> {
        let eff = view?.effectiveBandwidth
        var tokensPerMin: Int? = nil
        let tpmTrim = tokensPerMinRaw.trimmingCharacters(in: .whitespaces)
        if !tpmTrim.isEmpty {
            switch parseTokenRate(tpmTrim) {
            case .failure(let err): return .failure(err)
            case .success(let v):
                if let anc = eff?.ancestorTokensPerMin, v > anc {
                    return .failure(ParseError(message: "Tokens per minute cannot exceed the parent pool (\(formatTokensPerMin(anc)))"))
                }
                tokensPerMin = v
            }
        }

        var inferenceUsdH: Double? = nil
        let infUsdTrim = inferenceUsdPerHRaw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if !infUsdTrim.isEmpty {
            guard let n = Double(infUsdTrim), n.isFinite, n >= minInferenceUsdPerHour, n <= maxInferenceUsdPerHour else {
                return .failure(ParseError(message: "Inference burn ceiling must be between $\(minInferenceUsdPerHour) and $\(Int(maxInferenceUsdPerHour))/h"))
            }
            let rounded = (n * 10000).rounded() / 10000
            if let anc = eff?.ancestorInferenceUsdPerHour, rounded > anc + 1e-9 {
                return .failure(ParseError(message: "Inference burn ceiling cannot exceed the parent pool (\(money(anc))/h)"))
            }
            inferenceUsdH = rounded
        }

        var computeVcpu: Int? = nil
        let vcpuTrim = computeVcpuRaw.trimmingCharacters(in: .whitespaces)
        if !vcpuTrim.isEmpty {
            switch parseWholeInt(vcpuTrim, min: 1, max: maxComputeVcpuPerMin, label: "Compute vCPU/min") {
            case .failure(let err): return .failure(err)
            case .success(let v):
                if let anc = eff?.ancestorComputeVcpuPerMin, v > anc {
                    return .failure(ParseError(message: "Compute vCPU/min cannot exceed the parent pool (\(anc) vCPU/min)"))
                }
                computeVcpu = v
            }
        }

        var computeUsdH: Double? = nil
        let usdTrim = computeUsdPerHRaw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if !usdTrim.isEmpty {
            guard let n = Double(usdTrim), n.isFinite, n >= minComputeUsdPerHour, n <= maxComputeUsdPerHour else {
                return .failure(ParseError(message: "Compute burn ceiling must be between $\(minComputeUsdPerHour) and $\(Int(maxComputeUsdPerHour))/h"))
            }
            let rounded = (n * 10000).rounded() / 10000
            if let anc = eff?.ancestorComputeUsdPerHour, rounded > anc + 1e-9 {
                return .failure(ParseError(message: "Compute burn ceiling cannot exceed the parent pool (\(money(anc))/h)"))
            }
            computeUsdH = rounded
        }

        if tokensPerMin == nil && inferenceUsdH == nil && computeVcpu == nil && computeUsdH == nil {
            return .failure(ParseError(message: "Enter at least one bandwidth limit (tokens/min, LLM $/h, vCPU/min, or VM $/h)"))
        }

        return .success(BandwidthLimits(
            tokensPerMin: tokensPerMin,
            inferenceUsdPerHour: inferenceUsdH,
            computeVcpuPerMin: computeVcpu,
            computeUsdPerHour: computeUsdH,
            protectRoot: protectRoot
        ))
    }

    func computeRunwayForecast(
        draftBudgetUsd: String? = nil,
        draftResetPeriod: BudgetResetPeriod? = nil,
        draftComputeUsdPerH: String? = nil,
        draftComputeVcpu: String? = nil,
        bandwidthEnabled: Bool? = nil,
        budgetEnabled: Bool? = nil,
        nowMs: Double? = nil
    ) -> RunwayForecast {
        let budgetOn = budgetEnabled ?? (mode == "own" || mode == "pooled")
        var capUsd: Double? = pool?.budget ?? ownBudget
        if budgetOn, let raw = draftBudgetUsd?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""),
           let parsed = Double(raw), parsed > 0, parsed <= 100_000 {
            capUsd = parsed
        }
        if !budgetOn { capUsd = nil }

        let effectiveMode: String = {
            if let budgetEnabled {
                return budgetEnabled ? "own" : (maxGrant != nil ? "pooled" : "none")
            }
            return mode
        }()

        let resetPeriod: BudgetResetPeriod = {
            guard capUsd != nil else { return .total }
            if effectiveMode == "pooled" {
                return pool?.resetPeriod ?? .total
            }
            if effectiveMode == "own", maxGrant == nil {
                if let draftResetPeriod { return draftResetPeriod }
                return pool?.resetPeriod ?? ownBudgetResetPeriod
            }
            return .total
        }()

        let refNowMs = nowMs ?? (Date().timeIntervalSince1970 * 1000.0)
        let resetsInSecs: Double? = {
            guard capUsd != nil, resetPeriod != .total else { return nil }
            if pool?.resetPeriod == resetPeriod, let raw = pool?.periodResetsAt, let serverMs = Self.parseIso8601Ms(raw) {
                return max(0, (serverMs - refNowMs) / 1000.0)
            }
            return Self.nextBudgetResetMs(resetPeriod, nowMs: refNowMs).map { max(0, ($0 - refNowMs) / 1000.0) }
        }()

        let spentUsd = pool?.spent ?? 0
        let reservedUsd = pool?.reserved ?? 0
        let carvedUsd = pool?.carved ?? 0
        let persistentCarvedUsd = pool?.persistentCarved ?? carvedUsd
        let committedPreReserved = spentUsd + carvedUsd
        let committedTotal = committedPreReserved + reservedUsd
        let availableUsd = capUsd.map { max(0, $0 - committedTotal) } ?? 0
        // `reservedUsd` holds up to 60m of future live-machine runtime, not incurred spend.
        let runwayUsd = capUsd.map { max(0, $0 - committedPreReserved) } ?? 0

        let obsCompute = max(0, effectiveBandwidth?.currentComputeUsdPerHour ?? 0)
        let curVcpu = effectiveBandwidth?.currentVcpuPerMin ?? 0
        let curTpm = effectiveBandwidth?.currentTokensPerMin ?? 0

        var shapedCompute = obsCompute
        let bwOn = bandwidthEnabled ?? (effectiveBandwidth?.source == "mission")
        if bwOn {
            var usdCap = effectiveBandwidth?.computeUsdPerHour
            if let draftComputeUsdPerH {
                let raw = draftComputeUsdPerH.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                usdCap = Double(raw).flatMap { $0 > 0 ? $0 : nil }
            }
            if let usdCap, shapedCompute > usdCap {
                shapedCompute = usdCap
            }
            var vcpuCap = effectiveBandwidth?.computeVcpuPerMin
            if let draftComputeVcpu {
                let raw = draftComputeVcpu.trimmingCharacters(in: .whitespaces)
                vcpuCap = Int(raw).flatMap { $0 > 0 ? $0 : nil }
            }
            if let vcpuCap, curVcpu > vcpuCap, curVcpu > 0 {
                shapedCompute = min(shapedCompute, obsCompute * (Double(vcpuCap) / Double(curVcpu)))
            }
        }

        let etaSecs: Double? = {
            guard capUsd != nil else { return nil }
            if runwayUsd <= 0 { return 0 }
            return shapedCompute > 0.005 ? (runwayUsd / shapedCompute) * 3600.0 : nil
        }()
        let sustainsUntilReset: Bool = {
            guard capUsd != nil, resetPeriod != .total, let rSecs = resetsInSecs, runwayUsd > 0 else { return false }
            guard let e = etaSecs else { return true }
            return e >= rSecs
        }()
        let simLeases = Self.buildSimulatedLeases(pool: pool, reservedUsd: reservedUsd, actualCompute: obsCompute)
        let liveMachineCount = max(1, simLeases.isEmpty ? (pool?.liveMachines ?? 1) : simLeases.count)
        let minExtensionStepUsd: Double = {
            if let minUsdH = simLeases.map(\.usdPerHour).min() {
                return minUsdH * 0.5
            }
            return (obsCompute / Double(liveMachineCount)) * 0.5
        }()
        let leaseCliffSecs: Double? = {
            guard let capUsd, runwayUsd > 0, reservedUsd > 0.005, !simLeases.isEmpty, availableUsd < runwayUsd - 0.005 else {
                return nil
            }
            return Self.simulateLeaseCliffSecs(
                leases: simLeases,
                capUsd: capUsd,
                spentUsd: spentUsd,
                carvedUsd: carvedUsd,
                persistentCarvedUsd: persistentCarvedUsd,
                availableUsd: availableUsd,
                resetsInSecs: resetsInSecs,
                resetPeriod: resetPeriod
            )
        }()
        let unshapedEtaSecs: Double? = (capUsd != nil && runwayUsd > 0 && obsCompute > 0.005)
            ? (runwayUsd / obsCompute) * 3600.0 : nil
        let etaGainSecs: Double? = {
            guard let e = etaSecs, let u = unshapedEtaSecs, e > u + 120 else { return nil }
            return e - u
        }()

        var tone: RunwayForecast.Tone = .ok
        if let capUsd {
            if runwayUsd <= 0 || (!sustainsUntilReset && etaSecs != nil && etaSecs! < 1800) {
                tone = .danger
            } else if (!sustainsUntilReset && ((etaSecs != nil && etaSecs! < 7200) || (capUsd > 0 && runwayUsd < capUsd * 0.15)))
                        || (leaseCliffSecs != nil && leaseCliffSecs! < 3600) {
                tone = .warning
            }
        }

        let headline: String
        let subline: String
        if let capUsd {
            if runwayUsd <= 0 {
                headline = "Budget exhausted"
                var parts = ["\(Self.money(committedPreReserved)) spent of \(Self.money(capUsd)) pool"]
                if resetPeriod != .total, let rSecs = resetsInSecs {
                    parts.append("resets in \(Self.formatDurationEta(rSecs))")
                }
                subline = parts.joined(separator: " · ")
            } else if let etaSecs {
                headline = sustainsUntilReset
                    ? "Sustains until \(resetPeriod.rawValue) reset"
                    : "\(Self.formatDurationEta(etaSecs)) runway left"
                let remPart = reservedUsd > 0.005
                    ? "\(Self.money(availableUsd)) unallocated (\(Self.money(reservedUsd)) reserved · \(Self.money(capUsd)) cap)"
                    : "\(Self.money(availableUsd)) left (\(Self.money(capUsd)) cap)"
                var parts = ["\(Self.money(shapedCompute))/h compute burn", remPart]
                if resetPeriod != .total, let rSecs = resetsInSecs {
                    if sustainsUntilReset {
                        parts.append("resets in \(Self.formatDurationEta(rSecs)) (\(Self.formatDurationEta(etaSecs)) runway)")
                    } else {
                        parts.append("exhausts \(Self.formatDurationEta(rSecs - etaSecs)) before \(resetPeriod.rawValue) reset")
                    }
                }
                if let cliff = leaseCliffSecs, cliff < 3600 {
                    if cliff <= 0 {
                        if availableUsd <= 0.005 {
                            parts.append("VM auto-extensions paused (0 unallocated)")
                        } else if availableUsd + 1e-6 < minExtensionStepUsd {
                            parts.append("VM auto-extensions paused (\(Self.money(availableUsd)) < \(Self.money(minExtensionStepUsd)) 30m step)")
                        } else {
                            parts.append("VM auto-extensions paused (\(Self.money(availableUsd)) left across \(liveMachineCount) VMs)")
                        }
                    } else {
                        parts.append("VM extensions pause in \(Self.formatDurationEta(cliff))")
                    }
                }
                if let gain = etaGainSecs {
                    let clean = Self.formatDurationEta(gain).replacingOccurrences(of: "~", with: "")
                    parts.append("+\(clean) from bandwidth cap")
                }
                subline = parts.joined(separator: " · ")
            } else {
                headline = sustainsUntilReset
                    ? "Sustains until \(resetPeriod.rawValue) reset"
                    : "\(Self.money(availableUsd)) available (\(Self.money(capUsd)) cap)"
                let baseSub = "No active managed-machine burn right now"
                if resetPeriod != .total, let rSecs = resetsInSecs {
                    subline = "\(baseSub) · resets in \(Self.formatDurationEta(rSecs))"
                } else {
                    subline = baseSub
                }
            }
        } else {
            headline = obsCompute > 0.005 ? "\(Self.money(obsCompute))/h current compute burn" : "No spending cap"
            var parts = ["Only the daily managed-machine cap applies"]
            if curTpm > 0 { parts.append(Self.formatTokensPerMin(curTpm)) }
            subline = parts.joined(separator: " · ")
        }

        return RunwayForecast(
            hasBudget: capUsd != nil,
            capUsd: capUsd,
            spentUsd: spentUsd,
            reservedUsd: reservedUsd,
            carvedUsd: carvedUsd,
            availableUsd: availableUsd,
            observedComputeBurnUsdPerH: obsCompute,
            shapedComputeBurnUsdPerH: shapedCompute,
            resetPeriod: resetPeriod,
            resetsInSecs: resetsInSecs,
            sustainsUntilReset: sustainsUntilReset,
            leaseCliffSecs: leaseCliffSecs,
            etaSecs: etaSecs,
            etaGainSecs: etaGainSecs,
            tone: tone,
            headline: headline,
            subline: subline
        )
    }

    static func money(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }

    private static func buildSimulatedLeases(pool: Pool?, reservedUsd: Double, actualCompute: Double) -> [LiveLease] {
        let raw = (pool?.liveLeases ?? []).filter { $0.usdPerHour > 0 }
        if !raw.isEmpty {
            return raw.map {
                LiveLease(remainingSecs: max(0, $0.remainingSecs), usdPerHour: $0.usdPerHour)
            }.sorted { $0.remainingSecs < $1.remainingSecs }
        }
        guard actualCompute > 0.005 else { return [] }
        let count = max(1, pool?.liveMachines ?? 1)
        let perVmUsdPerH = actualCompute / Double(count)
        let avgRemainingSecs = max(0, ((reservedUsd / actualCompute) * 3600.0).rounded())
        return Array(repeating: LiveLease(remainingSecs: avgRemainingSecs, usdPerHour: perVmUsdPerH), count: count)
    }

    private static func simulateLeaseCliffSecs(
        leases: [LiveLease],
        capUsd: Double,
        spentUsd: Double,
        carvedUsd: Double,
        persistentCarvedUsd: Double,
        availableUsd: Double,
        resetsInSecs: Double?,
        resetPeriod: BudgetResetPeriod
    ) -> Double? {
        guard !leases.isEmpty else { return nil }
        var remSecs = leases.map(\.remainingSecs)
        let heldCarvedUsd = max(0.0, min(carvedUsd, persistentCarvedUsd))
        let resettableUsd = max(0.0, spentUsd) + max(0.0, carvedUsd - heldCarvedUsd)
        var remAvail = max(0.0, availableUsd)
        var elapsed = 0.0
        var nextResetAt: Double? = (resetPeriod != .total && (resetsInSecs ?? 0) > 0) ? resetsInSecs : nil
        let periodLenSecs: Double = resetPeriod == .daily ? 86_400.0 : (resetPeriod == .weekly ? 604_800.0 : 0.0)

        func advanceTime(_ dt: Double) {
            guard dt > 0 else { return }
            for i in 0..<remSecs.count {
                let unreservedSecs = max(0.0, min(dt, remSecs[i] - 3600.0))
                if unreservedSecs > 0 {
                    remAvail -= (unreservedSecs / 3600.0) * leases[i].usdPerHour
                }
                remSecs[i] = max(0.0, remSecs[i] - dt)
            }
            elapsed += dt
        }

        func refreshAtResetBoundary() {
            var curReserved = 0.0
            for i in 0..<remSecs.count {
                curReserved += (min(3600.0, max(0.0, remSecs[i])) / 3600.0) * leases[i].usdPerHour
            }
            remAvail = max(0.0, capUsd - heldCarvedUsd - curReserved)
        }

        if resetPeriod != .total, let r = resetsInSecs, r <= 0, resettableUsd > 0 {
            refreshAtResetBoundary()
            nextResetAt = periodLenSecs > 0 ? periodLenSecs : nil
        }

        let maxSteps = min(4096, max(64, leases.count * 16))
        for _ in 0..<maxSteps {
            var bestIdx = 0
            var bestWait = max(0.0, remSecs[0] - 600.0)
            for i in 1..<remSecs.count {
                let w = max(0.0, remSecs[i] - 600.0)
                if w < bestWait {
                    bestWait = w
                    bestIdx = i
                }
            }
            while let nr = nextResetAt, elapsed + bestWait >= nr {
                let toReset = max(0.0, nr - elapsed)
                advanceTime(toReset)
                bestWait = max(0.0, bestWait - toReset)
                refreshAtResetBoundary()
                nextResetAt = periodLenSecs > 0 ? (nr + periodLenSecs) : nil
                if elapsed > 86_400.0 { return elapsed }
            }
            if bestWait > 0 {
                advanceTime(bestWait)
            }
            if elapsed > 86_400.0 { return elapsed }
            let stepUsd = leases[bestIdx].usdPerHour * 0.5
            if remAvail + 1e-6 < stepUsd {
                return elapsed
            }
            remAvail = max(0.0, remAvail - stepUsd)
            remSecs[bestIdx] += 1800.0
        }
        return elapsed
    }
}

/// Long-press "Mission settings" on a mission row: Runway forecast + Budget +
/// Bandwidth & pacing + Machine limit sections. Optimistic with rollback & Retry.
struct OrbMissionSettingsSheet: View {
    let missionId: String
    let title: String
    var readOnly: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var view: OrbMissionBudget?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var pendingRetry: (amount: Double?, period: OrbMissionBudget.BudgetResetPeriod?)?
    @State private var draft = ""
    @State private var resetPeriodDraft: OrbMissionBudget.BudgetResetPeriod = .total
    @State private var vmSaveError: String?
    @State private var pendingVmRetry: OrbMissionBudget.VmConcurrencyLimits??
    @State private var vmTotalDraft = ""
    @State private var vmProviderDrafts: [String: String] = [:]
    @State private var providersExpanded = false
    @State private var bwSaveError: String?
    @State private var pendingBwRetry: OrbMissionBudget.BandwidthLimits??
    @State private var bwTokensDraft = ""
    @State private var bwInfUsdHDraft = ""
    @State private var bwVcpuDraft = ""
    @State private var bwUsdHDraft = ""
    @State private var bwProtectRoot = true
    @State private var showIdleChildren = false
    @State private var busy = false
    private let api = OrbCore.shared
    private var path: String { "/api/control/missions/\(OrbCore.escape(missionId))/budget" }

    var body: some View {
        NavigationStack {
            Form {
                if let v = view {
                    let fc = v.computeRunwayForecast(
                        draftBudgetUsd: v.mode == "own" ? draft : nil,
                        draftResetPeriod: (v.mode == "own" && v.maxGrant == nil) ? resetPeriodDraft : nil,
                        draftComputeUsdPerH: v.bandwidthMode == "own" ? bwUsdHDraft : nil,
                        draftComputeVcpu: v.bandwidthMode == "own" ? bwVcpuDraft : nil,
                        bandwidthEnabled: v.bandwidthMode == "own" || v.effectiveBandwidth?.source == "mission",
                        budgetEnabled: v.mode == "own" || v.mode == "pooled"
                    )
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fc.headline)
                                .font(.headline)
                                .foregroundStyle(toneColor(fc.tone))
                            Text(fc.subline)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let cap = fc.capUsd, cap > 0 {
                                GeometryReader { geo in
                                    let w = max(1, geo.size.width)
                                    HStack(spacing: 1.5) {
                                        if fc.spentUsd > 0 {
                                            Rectangle().fill(Color.blue).frame(width: max(2, w * CGFloat(fc.spentUsd / cap)))
                                        }
                                        if fc.reservedUsd > 0 {
                                            Rectangle().fill(OrbStyle.warning).frame(width: max(2, w * CGFloat(fc.reservedUsd / cap)))
                                        }
                                        if fc.carvedUsd > 0 {
                                            Rectangle().fill(Color.purple.opacity(0.8)).frame(width: max(2, w * CGFloat(fc.carvedUsd / cap)))
                                        }
                                        if fc.availableUsd > 0 {
                                            Rectangle().fill(OrbStyle.success).frame(width: max(2, w * CGFloat(fc.availableUsd / cap)))
                                        }
                                    }
                                }
                                .frame(height: 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("mission.settings.forecast")
                    } header: { Text(title) }
                }

                Section {
                    if let v = view {
                        Toggle("Spending budget", isOn: Binding(get: { v.mode == "own" }, set: { on in toggle(on) }))
                            .disabled(busy || readOnly)
                            .accessibilityIdentifier("mission.settings.budget.toggle")
                        Text(v.modeLine).font(.footnote).foregroundStyle(.secondary)
                        if v.mode == "own" {
                            if v.maxGrant == nil {
                                Picker("Reset cadence", selection: $resetPeriodDraft) {
                                    ForEach(OrbMissionBudget.BudgetResetPeriod.allCases, id: \.self) { p in
                                        Text(p.label).tag(p)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(busy || readOnly)
                                .accessibilityIdentifier("mission.settings.budget.reset_period")
                            }
                            let serverPeriod = v.pool?.resetPeriod ?? v.ownBudgetResetPeriod
                            let isBudgetDirty = draft != format(v.ownBudget) || (v.maxGrant == nil && resetPeriodDraft != serverPeriod)
                            HStack {
                                TextField("Amount (USD)", text: $draft).keyboardType(.decimalPad)
                                    .disabled(readOnly)
                                    .accessibilityIdentifier("mission.settings.budget.amount")
                                Button("Save") { save() }.disabled(busy || readOnly || !isBudgetDirty)
                            }
                            if let max = v.maxGrant { Text("Up to \(OrbMissionBudget.money(max)) from the parent pool.").font(.footnote).foregroundStyle(.secondary) }
                        }
                        if let p = v.pool {
                            ProgressView(value: min(1, max(0, (p.spent + p.reserved + p.carved) / max(p.budget, 0.0001))))
                            let spentLabel = p.resetPeriod == .daily ? "Spent today" : (p.resetPeriod == .weekly ? "Spent this week" : "Spent")
                            LabeledContent(spentLabel, value: OrbMissionBudget.money(p.spent))
                            if p.resetPeriod != .total {
                                LabeledContent("Lifetime spent", value: OrbMissionBudget.money(p.lifetimeSpent))
                            }
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
                        if let retry = pendingRetry { Button("Retry") { commit(retry.amount, resetPeriod: retry.period) } }
                    }
                } header: { Text("Budget") } footer: {
                    Text("Caps what this agent and its subagents spend on managed machines. Reserved holds up to 60 minutes of each running machine.")
                }

                if let v = view {
                    Section {
                        Toggle("Bandwidth limit", isOn: Binding(get: { v.bandwidthMode == "own" }, set: { on in toggleBandwidth(on) }))
                            .disabled(busy || readOnly)
                            .accessibilityIdentifier("mission.settings.bandwidth.toggle")
                        Text(v.bandwidthModeLine).font(.footnote).foregroundStyle(.secondary)
                        if let eff = v.effectiveBandwidth, eff.source == "mission" {
                            let summary = OrbMissionBudget.bandwidthLimitsSummary(OrbMissionBudget.BandwidthLimits(
                                tokensPerMin: eff.tokensPerMin,
                                inferenceUsdPerHour: eff.inferenceUsdPerHour,
                                computeVcpuPerMin: eff.computeVcpuPerMin,
                                computeUsdPerHour: eff.computeUsdPerHour,
                                protectRoot: eff.protectRoot
                            ))
                            if !summary.isEmpty {
                                LabeledContent("Active ceiling", value: summary)
                            }
                            if eff.pacingActive {
                                LabeledContent("Pacing", value: "Smoothing bursts")
                            }
                        }
                        if v.bandwidthMode == "own" {
                            HStack {
                                Text("Tokens / min")
                                Spacer()
                                TextField("e.g. 120k", text: $bwTokensDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .disabled(readOnly)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.tpm")
                            }
                            HStack {
                                Text("Inference ceiling ($/h)")
                                Spacer()
                                TextField("Optional", text: $bwInfUsdHDraft)
                                    .disabled(readOnly)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.inf_usdh")
                            }
                            HStack {
                                Text("Compute (vCPU / min)")
                                Spacer()
                                TextField("Optional", text: $bwVcpuDraft)
                                    .disabled(readOnly)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.vcpu")
                            }
                            HStack {
                                Text("Burn ceiling ($/h)")
                                Spacer()
                                TextField("Optional", text: $bwUsdHDraft)
                                    .disabled(readOnly)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.usdh")
                            }
                            Toggle("Prioritize root agent", isOn: $bwProtectRoot)
                                .disabled(busy || readOnly)
                                .accessibilityIdentifier("mission.settings.bandwidth.protect_root")
                            Button("Save bandwidth") { saveBandwidth() }
                                .disabled(busy || readOnly || !bwDraftDirty(v))
                                .accessibilityIdentifier("mission.settings.bandwidth.save")
                        }
                        if let bwSaveError {
                            Text("Bandwidth limit not saved: \(bwSaveError)").font(.footnote).foregroundStyle(OrbStyle.warning)
                            if let retry = pendingBwRetry { Button("Retry") { commitBandwidth(retry) } }
                        }
                    } header: { Text("Bandwidth & pacing") } footer: {
                        Text(readOnly
                            ? "Shared participants can view budgets and pacing; only the mission owner can edit them."
                            : "Smooths inference and machine spawn bursts with pace delays instead of hard errors.")
                    }

                    Section {
                        Toggle("Machine limit", isOn: Binding(get: { v.vmLimitsMode == "own" }, set: { on in toggleVmLimits(on) }))
                            .disabled(busy || readOnly)
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
                                    .disabled(readOnly)
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
                                        .disabled(readOnly)
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
                                .disabled(busy || readOnly || !vmDraftDirty(v))
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

    private func toneColor(_ tone: OrbMissionBudget.RunwayForecast.Tone) -> Color {
        switch tone {
        case .ok: return .primary
        case .warning: return OrbStyle.warning
        case .danger: return OrbStyle.error
        }
    }

    private func childSummary(_ c: OrbMissionBudget.Child) -> String {
        var parts: [String] = []
        parts.append(c.mode == "sub_budget" ? "Sub-budget \(OrbMissionBudget.money(c.budget ?? 0))" : "Pooled")
        if c.hasVmLimits {
            parts.append(c.vmMaxConcurrent.map { "max \($0) VM" } ?? "custom VM cap")
        }
        if c.hasBandwidthLimits {
            parts.append(c.tokensPerMin.map { OrbMissionBudget.formatTokensPerMin($0) } ?? "paced")
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

    private func syncBudgetDrafts(_ v: OrbMissionBudget) {
        draft = format(v.ownBudget)
        resetPeriodDraft = v.maxGrant != nil ? .total : (v.pool?.resetPeriod ?? v.ownBudgetResetPeriod)
    }

    private func syncBandwidthDrafts(_ v: OrbMissionBudget) {
        bwTokensDraft = v.ownBandwidthLimits?.tokensPerMin.map(String.init) ?? ""
        bwInfUsdHDraft = format(v.ownBandwidthLimits?.inferenceUsdPerHour)
        bwVcpuDraft = v.ownBandwidthLimits?.computeVcpuPerMin.map(String.init) ?? ""
        bwUsdHDraft = format(v.ownBandwidthLimits?.computeUsdPerHour)
        bwProtectRoot = v.ownBandwidthLimits?.protectRoot ?? true
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

    private func bwDraftDirty(_ v: OrbMissionBudget) -> Bool {
        let own = v.ownBandwidthLimits
        let curT = own?.tokensPerMin.map(String.init) ?? ""
        let curI = format(own?.inferenceUsdPerHour)
        let curV = own?.computeVcpuPerMin.map(String.init) ?? ""
        let curU = format(own?.computeUsdPerHour)
        let curP = own?.protectRoot ?? true
        return bwTokensDraft.trimmingCharacters(in: .whitespaces) != curT
            || bwInfUsdHDraft.trimmingCharacters(in: .whitespaces) != curI
            || bwVcpuDraft.trimmingCharacters(in: .whitespaces) != curV
            || bwUsdHDraft.trimmingCharacters(in: .whitespaces) != curU
            || bwProtectRoot != curP
    }

    private func load() async {
        loadError = nil
        do {
            let v = OrbMissionBudget(try await api.call(path))
            view = v; syncBudgetDrafts(v); syncVmDrafts(v); syncBandwidthDrafts(v)
        } catch { loadError = error.localizedDescription }
    }

    private func toggle(_ on: Bool) {
        guard let v = view else { return }
        if !on { return commit(nil) }
        let initial = v.maxGrant.map { min(5, ($0 * 100).rounded(.down) / 100) } ?? 5
        guard initial > 0 else { saveError = "The parent pool has nothing left to grant"; return }
        commit(initial, resetPeriod: v.maxGrant == nil ? .total : nil)
    }

    private func save() {
        guard let value = Double(draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")), value > 0 else {
            saveError = "Enter a positive amount"; return
        }
        if let max = view?.maxGrant, value > max + 1e-9 { saveError = "The parent pool has \(OrbMissionBudget.money(max)) left to grant"; return }
        let period: OrbMissionBudget.BudgetResetPeriod? = view?.maxGrant == nil ? resetPeriodDraft : nil
        commit(value, resetPeriod: period)
    }

    private func commit(_ amount: Double?, resetPeriod: OrbMissionBudget.BudgetResetPeriod? = nil) {
        guard let before = view, !busy else { return }
        busy = true; saveError = nil; pendingRetry = nil
        let opt = before.optimistic(amount, resetPeriod: resetPeriod)
        view = opt; syncBudgetDrafts(opt)
        Task {
            defer { busy = false }
            do {
                var obj: [String: OrbJSON] = ["budget_usd": amount.map { .number($0) } ?? .null]
                if amount != nil, let resetPeriod {
                    obj["budget_reset_period"] = .string(resetPeriod.rawValue)
                }
                let next = OrbMissionBudget(try await api.call(path, method: "PUT", body: .object(obj)))
                view = next; syncBudgetDrafts(next); syncVmDrafts(next); syncBandwidthDrafts(next)
                OrbHaptics.selection()
            } catch {
                view = before; syncBudgetDrafts(before)
                saveError = error.localizedDescription
                pendingRetry = (amount: amount, period: resetPeriod)
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
                view = next; draft = format(next.ownBudget); syncVmDrafts(next); syncBandwidthDrafts(next)
                OrbHaptics.selection()
            } catch {
                view = before; syncVmDrafts(before)
                vmSaveError = error.localizedDescription
                pendingVmRetry = .some(limits)
            }
        }
    }

    private func toggleBandwidth(_ on: Bool) {
        guard let v = view else { return }
        if !on { return commitBandwidth(nil) }
        let ancTpm = v.effectiveBandwidth?.ancestorTokensPerMin
        let defaultTpm = ancTpm.map { min(120_000, $0) } ?? 120_000
        commitBandwidth(.init(tokensPerMin: defaultTpm, computeVcpuPerMin: nil, computeUsdPerHour: nil, protectRoot: true))
    }

    private func saveBandwidth() {
        switch OrbMissionBudget.parseBandwidthLimits(
            tokensPerMinRaw: bwTokensDraft,
            computeVcpuRaw: bwVcpuDraft,
            computeUsdPerHRaw: bwUsdHDraft,
            protectRoot: bwProtectRoot,
            view: view,
            inferenceUsdPerHRaw: bwInfUsdHDraft
        ) {
        case .failure(let err):
            bwSaveError = err.message
        case .success(let limits):
            commitBandwidth(limits)
        }
    }

    private func commitBandwidth(_ limits: OrbMissionBudget.BandwidthLimits?) {
        guard let before = view, !busy else { return }
        busy = true; bwSaveError = nil; pendingBwRetry = nil
        let opt = before.optimisticBandwidthLimits(limits)
        view = opt; syncBandwidthDrafts(opt)
        Task {
            defer { busy = false }
            do {
                let body: OrbJSON = .object(["bandwidth_limits": limits?.toJSON() ?? .null])
                let next = OrbMissionBudget(try await api.call(path, method: "PUT", body: body))
                view = next; draft = format(next.ownBudget); syncVmDrafts(next); syncBandwidthDrafts(next)
                OrbHaptics.selection()
            } catch {
                view = before; syncBandwidthDrafts(before)
                bwSaveError = error.localizedDescription
                pendingBwRetry = .some(limits)
            }
        }
    }
}
