import SwiftUI

/// `GET /api/control/missions/:id/budget` (desktop: `orb/src/missionBudget.ts`).
struct OrbMissionBudget: Equatable {
    static let maxVmConcurrency = 128
    static let minTokensPerMin = 1_000
    static let maxTokensPerMin = 100_000_000
    static let maxComputeVcpuPerMin = 4_096
    static let minComputeUsdPerHour = 0.01
    static let maxComputeUsdPerHour = 10_000.0

    static let providers: [(id: String, label: String)] = [
        ("boat", "boat.dev"),
        ("boost", "boost.ci"),
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

    struct BandwidthLimits: Equatable {
        var tokensPerMin: Int?
        var computeVcpuPerMin: Int?
        var computeUsdPerHour: Double?
        var protectRoot: Bool

        init(
            tokensPerMin: Int? = nil,
            computeVcpuPerMin: Int? = nil,
            computeUsdPerHour: Double? = nil,
            protectRoot: Bool = true
        ) {
            self.tokensPerMin = tokensPerMin
            self.computeVcpuPerMin = computeVcpuPerMin
            self.computeUsdPerHour = computeUsdPerHour
            self.protectRoot = protectRoot
        }

        init?(_ j: OrbJSON) {
            guard case .object(let d) = j else { return nil }
            tokensPerMin = d["tokens_per_min"]?.doubleValue.map(Int.init)
            computeVcpuPerMin = d["compute_vcpu_per_min"]?.doubleValue.map(Int.init)
            computeUsdPerHour = d["compute_usd_per_hour"]?.doubleValue
            protectRoot = (d["protect_root"] ?? .null).flag
        }

        func toJSON() -> OrbJSON {
            .object([
                "tokens_per_min": tokensPerMin.map { .number(Double($0)) } ?? .null,
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
        var computeVcpuPerMin: Int?
        var computeUsdPerHour: Double?
        var protectRoot: Bool
        var currentTokensPerMin: Int
        var currentVcpuPerMin: Int
        var currentComputeUsdPerHour: Double
        var pacingActive: Bool
        var pacedDelayMs: Int
        var ancestorTokensPerMin: Int?
        var ancestorComputeVcpuPerMin: Int?
        var ancestorComputeUsdPerHour: Double?

        init(
            source: String, poolId: String?, tokensPerMin: Int?, computeVcpuPerMin: Int?,
            computeUsdPerHour: Double?, protectRoot: Bool, currentTokensPerMin: Int,
            currentVcpuPerMin: Int, currentComputeUsdPerHour: Double, pacingActive: Bool,
            pacedDelayMs: Int, ancestorTokensPerMin: Int?, ancestorComputeVcpuPerMin: Int?,
            ancestorComputeUsdPerHour: Double?
        ) {
            self.source = source; self.poolId = poolId
            self.tokensPerMin = tokensPerMin; self.computeVcpuPerMin = computeVcpuPerMin
            self.computeUsdPerHour = computeUsdPerHour; self.protectRoot = protectRoot
            self.currentTokensPerMin = currentTokensPerMin; self.currentVcpuPerMin = currentVcpuPerMin
            self.currentComputeUsdPerHour = currentComputeUsdPerHour
            self.pacingActive = pacingActive; self.pacedDelayMs = pacedDelayMs
            self.ancestorTokensPerMin = ancestorTokensPerMin
            self.ancestorComputeVcpuPerMin = ancestorComputeVcpuPerMin
            self.ancestorComputeUsdPerHour = ancestorComputeUsdPerHour
        }

        init?(_ j: OrbJSON) {
            guard case .object = j else { return nil }
            source = j["source"].text.isEmpty ? "none" : j["source"].text
            poolId = j["pool_id"].text.isEmpty ? nil : j["pool_id"].text
            tokensPerMin = j["tokens_per_min"].doubleValue.map(Int.init)
            computeVcpuPerMin = j["compute_vcpu_per_min"].doubleValue.map(Int.init)
            computeUsdPerHour = j["compute_usd_per_hour"].doubleValue
            protectRoot = j["protect_root"].flag
            currentTokensPerMin = j["current_tokens_per_min"].doubleValue.map(Int.init) ?? 0
            currentVcpuPerMin = j["current_vcpu_per_min"].doubleValue.map(Int.init) ?? 0
            currentComputeUsdPerHour = j["current_compute_usd_per_hour"].doubleValue ?? 0
            pacingActive = j["pacing_active"].flag
            pacedDelayMs = j["paced_delay_ms"].doubleValue.map(Int.init) ?? 0
            ancestorTokensPerMin = j["ancestor_tokens_per_min"].doubleValue.map(Int.init)
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

    /// Same derivation as desktop `optimisticBandwidthLimits`.
    func optimisticBandwidthLimits(_ limits: BandwidthLimits?) -> OrbMissionBudget {
        var next = self
        let prev = effectiveBandwidth
        let ancTpm = prev?.ancestorTokensPerMin
        let ancVcpu = prev?.ancestorComputeVcpuPerMin
        let ancUsdH = prev?.ancestorComputeUsdPerHour
        let curTpm = prev?.currentTokensPerMin ?? 0
        let curVcpu = prev?.currentVcpuPerMin ?? 0
        let curUsdH = prev?.currentComputeUsdPerHour ?? 0

        guard let limits else {
            let inherited = bandwidthMode == "own" && (ancTpm != nil || ancVcpu != nil || ancUsdH != nil)
            next.ownBandwidthLimits = nil
            next.bandwidthMode = inherited ? "pooled" : "none"
            next.bandwidthPoolId = nil
            next.effectiveBandwidth = EffectiveBandwidth(
                source: inherited ? "mission" : "none",
                poolId: nil,
                tokensPerMin: ancTpm,
                computeVcpuPerMin: ancVcpu,
                computeUsdPerHour: ancUsdH,
                protectRoot: false,
                currentTokensPerMin: curTpm,
                currentVcpuPerMin: curVcpu,
                currentComputeUsdPerHour: curUsdH,
                pacingActive: false,
                pacedDelayMs: 0,
                ancestorTokensPerMin: ancTpm,
                ancestorComputeVcpuPerMin: ancVcpu,
                ancestorComputeUsdPerHour: ancUsdH
            )
            return next
        }

        let effTpm = (limits.tokensPerMin != nil && ancTpm != nil)
            ? min(limits.tokensPerMin!, ancTpm!)
            : (limits.tokensPerMin ?? ancTpm)
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
            computeVcpuPerMin: effVcpu,
            computeUsdPerHour: effUsdH,
            protectRoot: limits.protectRoot,
            currentTokensPerMin: curTpm,
            currentVcpuPerMin: curVcpu,
            currentComputeUsdPerHour: curUsdH,
            pacingActive: prev?.pacingActive ?? false,
            pacedDelayMs: prev?.pacedDelayMs ?? 0,
            ancestorTokensPerMin: ancTpm,
            ancestorComputeVcpuPerMin: ancVcpu,
            ancestorComputeUsdPerHour: ancUsdH
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
        if let v = limits.computeVcpuPerMin { parts.append("\(v) vCPU/min") }
        if let u = limits.computeUsdPerHour { parts.append("\(money(u))/h") }
        return parts.joined(separator: " · ")
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
        view: OrbMissionBudget? = nil
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

        if tokensPerMin == nil && computeVcpu == nil && computeUsdH == nil {
            return .failure(ParseError(message: "Enter at least one bandwidth limit (tokens/min, vCPU/min, or $/h)"))
        }

        return .success(BandwidthLimits(
            tokensPerMin: tokensPerMin,
            computeVcpuPerMin: computeVcpu,
            computeUsdPerHour: computeUsdH,
            protectRoot: protectRoot
        ))
    }

    func computeRunwayForecast(
        draftBudgetUsd: String? = nil,
        draftComputeUsdPerH: String? = nil,
        draftComputeVcpu: String? = nil,
        bandwidthEnabled: Bool? = nil,
        budgetEnabled: Bool? = nil
    ) -> RunwayForecast {
        let budgetOn = budgetEnabled ?? (mode == "own" || mode == "pooled")
        var capUsd: Double? = pool?.budget ?? ownBudget
        if budgetOn, let raw = draftBudgetUsd?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""),
           let parsed = Double(raw), parsed > 0, parsed <= 100_000 {
            capUsd = parsed
        }
        if !budgetOn { capUsd = nil }

        let spentUsd = pool?.spent ?? 0
        let reservedUsd = pool?.reserved ?? 0
        let carvedUsd = pool?.carved ?? 0
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
            guard let capUsd else { return nil }
            if runwayUsd <= 0 { return 0 }
            return shapedCompute > 0.005 ? (runwayUsd / shapedCompute) * 3600.0 : nil
        }()
        let unshapedEtaSecs: Double? = (capUsd != nil && runwayUsd > 0 && obsCompute > 0.005)
            ? (runwayUsd / obsCompute) * 3600.0 : nil
        let etaGainSecs: Double? = {
            guard let e = etaSecs, let u = unshapedEtaSecs, e > u + 120 else { return nil }
            return e - u
        }()

        var tone: RunwayForecast.Tone = .ok
        if let capUsd {
            if runwayUsd <= 0 || (etaSecs != nil && etaSecs! < 1800) {
                tone = .danger
            } else if (etaSecs != nil && etaSecs! < 7200) || (capUsd > 0 && runwayUsd < capUsd * 0.15) {
                tone = .warning
            }
        }

        let headline: String
        let subline: String
        if let capUsd {
            if runwayUsd <= 0 {
                headline = "Budget exhausted"
                subline = "\(Self.money(committedPreReserved)) spent of \(Self.money(capUsd)) pool"
            } else if let etaSecs {
                headline = "\(Self.formatDurationEta(etaSecs)) runway left"
                let remPart = reservedUsd > 0.005
                    ? "\(Self.money(availableUsd)) unallocated (\(Self.money(reservedUsd)) reserved · \(Self.money(capUsd)) cap)"
                    : "\(Self.money(availableUsd)) left (\(Self.money(capUsd)) cap)"
                var parts = ["\(Self.money(shapedCompute))/h compute burn", remPart]
                if let gain = etaGainSecs {
                    let clean = Self.formatDurationEta(gain).replacingOccurrences(of: "~", with: "")
                    parts.append("+\(clean) from bandwidth cap")
                }
                subline = parts.joined(separator: " · ")
            } else {
                headline = "\(Self.money(availableUsd)) available (\(Self.money(capUsd)) cap)"
                subline = "No active managed-machine burn right now"
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
            etaSecs: etaSecs,
            etaGainSecs: etaGainSecs,
            tone: tone,
            headline: headline,
            subline: subline
        )
    }

    static func money(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }
}

/// Long-press "Mission settings" on a mission row: Runway forecast + Budget +
/// Bandwidth & pacing + Machine limit sections. Optimistic with rollback & Retry.
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
    @State private var bwSaveError: String?
    @State private var pendingBwRetry: OrbMissionBudget.BandwidthLimits??
    @State private var bwTokensDraft = ""
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
                        Toggle("Bandwidth limit", isOn: Binding(get: { v.bandwidthMode == "own" }, set: { on in toggleBandwidth(on) }))
                            .disabled(busy)
                            .accessibilityIdentifier("mission.settings.bandwidth.toggle")
                        Text(v.bandwidthModeLine).font(.footnote).foregroundStyle(.secondary)
                        if let eff = v.effectiveBandwidth, eff.source == "mission" {
                            let summary = OrbMissionBudget.bandwidthLimitsSummary(OrbMissionBudget.BandwidthLimits(
                                tokensPerMin: eff.tokensPerMin,
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
                                TextField("e.g. 120k", text: $bwTokensDraft)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.tpm")
                            }
                            HStack {
                                Text("Compute (vCPU / min)")
                                Spacer()
                                TextField("Optional", text: $bwVcpuDraft)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.vcpu")
                            }
                            HStack {
                                Text("Burn ceiling ($/h)")
                                Spacer()
                                TextField("Optional", text: $bwUsdHDraft)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                                    .accessibilityIdentifier("mission.settings.bandwidth.usdh")
                            }
                            Toggle("Prioritize root agent", isOn: $bwProtectRoot)
                                .disabled(busy)
                                .accessibilityIdentifier("mission.settings.bandwidth.protect_root")
                            Button("Save bandwidth") { saveBandwidth() }
                                .disabled(busy || !bwDraftDirty(v))
                                .accessibilityIdentifier("mission.settings.bandwidth.save")
                        }
                        if let bwSaveError {
                            Text("Bandwidth limit not saved: \(bwSaveError)").font(.footnote).foregroundStyle(OrbStyle.warning)
                            if let retry = pendingBwRetry { Button("Retry") { commitBandwidth(retry) } }
                        }
                    } header: { Text("Bandwidth & pacing") } footer: {
                        Text("Smooths inference and machine spawn bursts with pace delays instead of hard errors.")
                    }

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

    private func syncBandwidthDrafts(_ v: OrbMissionBudget) {
        bwTokensDraft = v.ownBandwidthLimits?.tokensPerMin.map(String.init) ?? ""
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
        let curV = own?.computeVcpuPerMin.map(String.init) ?? ""
        let curU = format(own?.computeUsdPerHour)
        let curP = own?.protectRoot ?? true
        return bwTokensDraft.trimmingCharacters(in: .whitespaces) != curT
            || bwVcpuDraft.trimmingCharacters(in: .whitespaces) != curV
            || bwUsdHDraft.trimmingCharacters(in: .whitespaces) != curU
            || bwProtectRoot != curP
    }

    private func load() async {
        loadError = nil
        do {
            let v = OrbMissionBudget(try await api.call(path))
            view = v; draft = format(v.ownBudget); syncVmDrafts(v); syncBandwidthDrafts(v)
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
                view = next; draft = format(next.ownBudget); syncVmDrafts(next); syncBandwidthDrafts(next)
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
            view: view
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
