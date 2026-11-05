package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** `GET /api/control/missions/:id/budget` (desktop: `orb/src/missionBudget.ts`). */
data class OrbMissionBudget(
    val missionId: String,
    val ownBudget: Double?,
    val poolId: String?,
    val mode: String,
    val pool: Pool?,
    val maxGrant: Double?,
    val ownVmLimits: VmConcurrencyLimits? = null,
    val vmLimitsMode: String = "global",
    val vmLimitsPoolId: String? = null,
    val effectiveVmLimits: EffectiveVmLimits? = null,
    val ownBandwidthLimits: BandwidthLimits? = null,
    val bandwidthMode: String = "none",
    val bandwidthPoolId: String? = null,
    val effectiveBandwidth: EffectiveBandwidth? = null,
    val children: List<Child>,
) {
    data class Pool(
        val budget: Double,
        val spent: Double,
        val reserved: Double,
        val carved: Double,
        val available: Double,
    )

    data class VmConcurrencyLimits(
        val maxConcurrent: Int?,
        val providerMaxConcurrent: Map<String, Int>,
    ) {
        fun toWire(): Map<String, Any?> = mapOf(
            "max_concurrent" to maxConcurrent,
            "provider_max_concurrent" to providerMaxConcurrent,
        )
    }

    data class ProviderCapUsage(val provider: String, val active: Int, val maxConcurrent: Int)

    data class EffectiveVmLimits(
        val source: String,
        val poolId: String?,
        val active: Int,
        val maxConcurrent: Int?,
        val globalActive: Int,
        val globalMaxConcurrent: Int?,
        val ancestorMaxConcurrent: Int?,
        val providerLimits: List<ProviderCapUsage>,
    )

    data class BandwidthLimits(
        val tokensPerMin: Int? = null,
        val computeVcpuPerMin: Int? = null,
        val computeUsdPerHour: Double? = null,
        val protectRoot: Boolean = true,
    ) {
        fun toWire(): Map<String, Any?> = mapOf(
            "tokens_per_min" to tokensPerMin,
            "compute_vcpu_per_min" to computeVcpuPerMin,
            "compute_usd_per_hour" to computeUsdPerHour,
            "protect_root" to protectRoot,
        )
    }

    data class EffectiveBandwidth(
        val source: String,
        val poolId: String?,
        val tokensPerMin: Int?,
        val computeVcpuPerMin: Int?,
        val computeUsdPerHour: Double?,
        val protectRoot: Boolean,
        val currentTokensPerMin: Int,
        val currentVcpuPerMin: Int,
        val currentComputeUsdPerHour: Double,
        val pacingActive: Boolean,
        val pacedDelayMs: Int,
        val ancestorTokensPerMin: Int?,
        val ancestorComputeVcpuPerMin: Int?,
        val ancestorComputeUsdPerHour: Double?,
    )

    data class RunwayForecast(
        val hasBudget: Boolean,
        val capUsd: Double?,
        val spentUsd: Double,
        val reservedUsd: Double,
        val carvedUsd: Double,
        val availableUsd: Double,
        val observedComputeBurnUsdPerH: Double,
        val shapedComputeBurnUsdPerH: Double,
        val etaSecs: Double?,
        val etaGainSecs: Double?,
        val tone: Tone,
        val headline: String,
        val subline: String,
    ) {
        enum class Tone { OK, WARNING, DANGER }
    }

    data class Child(
        val id: String,
        val mode: String,
        val budget: Double?,
        val spent: Double,
        val reserved: Double = 0.0,
        val hasVmLimits: Boolean = false,
        val vmMaxConcurrent: Int? = null,
        val hasBandwidthLimits: Boolean = false,
        val tokensPerMin: Int? = null,
        val liveMachines: Int = 0,
    ) {
        val isIdlePooled: Boolean
            get() = mode == "pooled" && !hasVmLimits && !hasBandwidthLimits && spent == 0.0 && reserved == 0.0 && liveMachines == 0
    }

    /** Same derivation as desktop `optimisticBudget`. */
    fun optimistic(amount: Double?): OrbMissionBudget {
        if (amount == null) {
            return copy(
                ownBudget = null,
                mode = if (mode == "own" && maxGrant != null) "pooled" else "none",
                pool = null,
                poolId = null,
            )
        }
        val p = if (pool != null && mode == "own") {
            pool.copy(budget = amount, available = pool.available + amount - pool.budget)
        } else {
            Pool(amount, 0.0, 0.0, 0.0, amount)
        }
        return copy(ownBudget = amount, mode = "own", poolId = missionId, pool = p)
    }

    /** Same derivation as desktop `optimisticVmLimits`. */
    fun optimisticVmLimits(limits: VmConcurrencyLimits?): OrbMissionBudget {
        val prev = effectiveVmLimits
        val globalActive = prev?.globalActive ?: 0
        val globalMax = prev?.globalMaxConcurrent
        val ancestorMax = prev?.ancestorMaxConcurrent
        if (limits == null) {
            val inherited = vmLimitsMode == "own" && ancestorMax != null
            return copy(
                ownVmLimits = null,
                vmLimitsMode = if (inherited) "pooled" else "global",
                vmLimitsPoolId = null,
                effectiveVmLimits = EffectiveVmLimits(
                    source = if (inherited) "mission" else "global",
                    poolId = null,
                    active = globalActive,
                    maxConcurrent = if (inherited) ancestorMax else globalMax,
                    globalActive = globalActive,
                    globalMaxConcurrent = globalMax,
                    ancestorMaxConcurrent = ancestorMax,
                    providerLimits = emptyList(),
                ),
            )
        }
        val active = if (prev?.source == "mission") prev.active else 0
        val provCaps = PROVIDERS.mapNotNull { (id, _) ->
            val maxC = limits.providerMaxConcurrent[id] ?: return@mapNotNull null
            val cur = prev?.providerLimits?.firstOrNull { it.provider == id }?.active ?: 0
            ProviderCapUsage(id, cur, maxC)
        }
        val maxC = if (limits.maxConcurrent != null && ancestorMax != null) {
            minOf(limits.maxConcurrent, ancestorMax)
        } else {
            limits.maxConcurrent ?: ancestorMax
        }
        return copy(
            ownVmLimits = limits,
            vmLimitsMode = "own",
            vmLimitsPoolId = missionId,
            effectiveVmLimits = EffectiveVmLimits(
                source = "mission",
                poolId = missionId,
                active = active,
                maxConcurrent = maxC,
                globalActive = globalActive,
                globalMaxConcurrent = globalMax,
                ancestorMaxConcurrent = ancestorMax,
                providerLimits = provCaps,
            ),
        )
    }

    /** Same derivation as desktop `optimisticBandwidthLimits`. */
    fun optimisticBandwidthLimits(limits: BandwidthLimits?): OrbMissionBudget {
        val prev = effectiveBandwidth
        val ancTpm = prev?.ancestorTokensPerMin
        val ancVcpu = prev?.ancestorComputeVcpuPerMin
        val ancUsdH = prev?.ancestorComputeUsdPerHour
        val curTpm = prev?.currentTokensPerMin ?: 0
        val curVcpu = prev?.currentVcpuPerMin ?: 0
        val curUsdH = prev?.currentComputeUsdPerHour ?: 0.0

        if (limits == null) {
            val inherited = bandwidthMode == "own" && (ancTpm != null || ancVcpu != null || ancUsdH != null)
            return copy(
                ownBandwidthLimits = null,
                bandwidthMode = if (inherited) "pooled" else "none",
                bandwidthPoolId = null,
                effectiveBandwidth = EffectiveBandwidth(
                    source = if (inherited) "mission" else "none",
                    poolId = null,
                    tokensPerMin = ancTpm,
                    computeVcpuPerMin = ancVcpu,
                    computeUsdPerHour = ancUsdH,
                    protectRoot = false,
                    currentTokensPerMin = curTpm,
                    currentVcpuPerMin = curVcpu,
                    currentComputeUsdPerHour = curUsdH,
                    pacingActive = false,
                    pacedDelayMs = 0,
                    ancestorTokensPerMin = ancTpm,
                    ancestorComputeVcpuPerMin = ancVcpu,
                    ancestorComputeUsdPerHour = ancUsdH,
                ),
            )
        }

        val effTpm = if (limits.tokensPerMin != null && ancTpm != null) {
            minOf(limits.tokensPerMin, ancTpm)
        } else {
            limits.tokensPerMin ?: ancTpm
        }
        val effVcpu = if (limits.computeVcpuPerMin != null && ancVcpu != null) {
            minOf(limits.computeVcpuPerMin, ancVcpu)
        } else {
            limits.computeVcpuPerMin ?: ancVcpu
        }
        val effUsdH = if (limits.computeUsdPerHour != null && ancUsdH != null) {
            min(limits.computeUsdPerHour, ancUsdH)
        } else {
            limits.computeUsdPerHour ?: ancUsdH
        }

        return copy(
            ownBandwidthLimits = limits,
            bandwidthMode = "own",
            bandwidthPoolId = missionId,
            effectiveBandwidth = EffectiveBandwidth(
                source = "mission",
                poolId = missionId,
                tokensPerMin = effTpm,
                computeVcpuPerMin = effVcpu,
                computeUsdPerHour = effUsdH,
                protectRoot = limits.protectRoot,
                currentTokensPerMin = curTpm,
                currentVcpuPerMin = curVcpu,
                currentComputeUsdPerHour = curUsdH,
                pacingActive = prev?.pacingActive ?: false,
                pacedDelayMs = prev?.pacedDelayMs ?: 0,
                ancestorTokensPerMin = ancTpm,
                ancestorComputeVcpuPerMin = ancVcpu,
                ancestorComputeUsdPerHour = ancUsdH,
            ),
        )
    }

    val modeLine: String
        get() = when (mode) {
            "own" -> if (maxGrant != null) "Own sub-budget, carved from the parent's pool. Its subagents share it."
            else "Own budget. Subagents share it unless you give one a sub-budget."
            "pooled" -> "Shares the pool of an ancestor agent."
            else -> "No budget. Only the daily managed-machine cap applies."
        }

    val vmLimitsModeLine: String
        get() = when (vmLimitsMode) {
            "own" -> effectiveVmLimits?.ancestorMaxConcurrent?.let {
                "Own sub-limit within the parent pool (up to $it concurrent)."
            } ?: "Dedicated cap for this agent and its subagents (bypasses the global limit)."
            "pooled" -> "Shares the machine limit of an ancestor agent."
            else -> effectiveVmLimits?.globalMaxConcurrent?.let {
                "Uses the global limit ($it concurrent across Orb)."
            } ?: "Uses the global machine limit."
        }

    val bandwidthModeLine: String
        get() = when (bandwidthMode) {
            "own" -> if (ownBandwidthLimits?.protectRoot == true) {
                "Smooths bursts by pacing subagent calls and spawns while keeping this root agent unthrottled."
            } else {
                "Smooths inference and machine spawn bursts with pace delays instead of hard errors."
            }
            "pooled" -> "Shares the bandwidth pace pool of an ancestor agent."
            else -> "Unthrottled. Requests and spawns run at full speed."
        }

    val showsSubagents: Boolean
        get() = children.isNotEmpty() && (
            mode != "none" ||
                vmLimitsMode != "global" ||
                bandwidthMode != "none" ||
                children.any { it.mode == "sub_budget" || it.hasVmLimits || it.hasBandwidthLimits }
            )

    fun computeRunwayForecast(
        draftBudgetUsd: String? = null,
        draftComputeUsdPerH: String? = null,
        draftComputeVcpu: String? = null,
        bandwidthEnabled: Boolean? = null,
        budgetEnabled: Boolean? = null,
    ): RunwayForecast {
        val budgetOn = budgetEnabled ?: (mode == "own" || mode == "pooled")
        var capUsd: Double? = pool?.budget ?: ownBudget
        if (budgetOn && draftBudgetUsd != null) {
            val parsed = draftBudgetUsd.trim().removePrefix("$").toDoubleOrNull()
            if (parsed != null && parsed > 0.0 && parsed <= 100_000.0) {
                capUsd = parsed
            }
        }
        if (!budgetOn) capUsd = null

        val spentUsd = pool?.spent ?: 0.0
        val reservedUsd = pool?.reserved ?: 0.0
        val carvedUsd = pool?.carved ?: 0.0
        val committedPreReserved = spentUsd + carvedUsd
        val committedTotal = committedPreReserved + reservedUsd
        val availableUsd = capUsd?.let { maxOf(0.0, it - committedTotal) } ?: 0.0
        // `reservedUsd` holds up to 60m of future live-machine runtime, not incurred spend.
        val runwayUsd = capUsd?.let { maxOf(0.0, it - committedPreReserved) } ?: 0.0

        val obsCompute = maxOf(0.0, effectiveBandwidth?.currentComputeUsdPerHour ?: 0.0)
        val curVcpu = effectiveBandwidth?.currentVcpuPerMin ?: 0
        val curTpm = effectiveBandwidth?.currentTokensPerMin ?: 0

        var shapedCompute = obsCompute
        val bwOn = bandwidthEnabled ?: (effectiveBandwidth?.source == "mission")
        if (bwOn) {
            var usdCap = effectiveBandwidth?.computeUsdPerHour
            if (draftComputeUsdPerH != null) {
                usdCap = draftComputeUsdPerH.trim().removePrefix("$").toDoubleOrNull()?.takeIf { it > 0.0 }
            }
            if (usdCap != null && shapedCompute > usdCap) {
                shapedCompute = usdCap
            }
            var vcpuCap = effectiveBandwidth?.computeVcpuPerMin
            if (draftComputeVcpu != null) {
                vcpuCap = draftComputeVcpu.trim().toIntOrNull()?.takeIf { it > 0 }
            }
            if (vcpuCap != null && curVcpu > vcpuCap && curVcpu > 0) {
                shapedCompute = min(shapedCompute, obsCompute * (vcpuCap.toDouble() / curVcpu.toDouble()))
            }
        }

        val etaSecs: Double? = when {
            capUsd == null -> null
            runwayUsd <= 0.0 -> 0.0
            shapedCompute > 0.005 -> (runwayUsd / shapedCompute) * 3600.0
            else -> null
        }
        val unshapedEtaSecs: Double? = if (capUsd != null && runwayUsd > 0.0 && obsCompute > 0.005) {
            (runwayUsd / obsCompute) * 3600.0
        } else {
            null
        }
        val etaGainSecs: Double? = if (etaSecs != null && unshapedEtaSecs != null && etaSecs > unshapedEtaSecs + 120.0) {
            etaSecs - unshapedEtaSecs
        } else {
            null
        }

        var tone = RunwayForecast.Tone.OK
        if (capUsd != null) {
            if (runwayUsd <= 0.0 || (etaSecs != null && etaSecs < 1800.0)) {
                tone = RunwayForecast.Tone.DANGER
            } else if ((etaSecs != null && etaSecs < 7200.0) || (capUsd > 0.0 && runwayUsd < capUsd * 0.15)) {
                tone = RunwayForecast.Tone.WARNING
            }
        }

        val headline: String
        val subline: String
        if (capUsd != null) {
            if (runwayUsd <= 0.0) {
                headline = "Budget exhausted"
                subline = "${money(committedPreReserved)} spent of ${money(capUsd)} pool"
            } else if (etaSecs != null) {
                headline = "${formatDurationEta(etaSecs)} runway left"
                val remPart = if (reservedUsd > 0.005) {
                    "${money(availableUsd)} unallocated (${money(reservedUsd)} reserved · ${money(capUsd)} cap)"
                } else {
                    "${money(availableUsd)} left (${money(capUsd)} cap)"
                }
                val parts = mutableListOf(
                    "${money(shapedCompute)}/h compute burn",
                    remPart,
                )
                if (etaGainSecs != null) {
                    val clean = formatDurationEta(etaGainSecs).replace("~", "")
                    parts.add("+$clean from bandwidth cap")
                }
                subline = parts.joinToString(" · ")
            } else {
                headline = "${money(availableUsd)} available (${money(capUsd)} cap)"
                subline = "No active managed-machine burn right now"
            }
        } else {
            headline = if (obsCompute > 0.005) "${money(obsCompute)}/h current compute burn" else "No spending cap"
            val parts = mutableListOf("Only the daily managed-machine cap applies")
            if (curTpm > 0) parts.add(formatTokensPerMin(curTpm))
            subline = parts.joinToString(" · ")
        }

        return RunwayForecast(
            hasBudget = capUsd != null,
            capUsd = capUsd,
            spentUsd = spentUsd,
            reservedUsd = reservedUsd,
            carvedUsd = carvedUsd,
            availableUsd = availableUsd,
            observedComputeBurnUsdPerH = obsCompute,
            shapedComputeBurnUsdPerH = shapedCompute,
            etaSecs = etaSecs,
            etaGainSecs = etaGainSecs,
            tone = tone,
            headline = headline,
            subline = subline,
        )
    }

    companion object {
        const val MAX_VM_CONCURRENCY = 128
        const val MIN_TOKENS_PER_MIN = 1_000
        const val MAX_TOKENS_PER_MIN = 100_000_000
        const val MAX_COMPUTE_VCPU_PER_MIN = 4_096
        const val MIN_COMPUTE_USD_PER_HOUR = 0.01
        const val MAX_COMPUTE_USD_PER_HOUR = 10_000.0

        val PROVIDERS: List<Pair<String, String>> = listOf(
            "boat" to "boat.dev",
            "boost" to "boost.ci",
            "hetzner" to "Hetzner",
            "vastai" to "Vast.ai",
            "scaleway" to "Scaleway",
        )

        fun providerLabel(id: String): String = PROVIDERS.firstOrNull { it.first == id }?.second ?: id

        fun providerLimitsSummary(limits: VmConcurrencyLimits?): String {
            val map = limits?.providerMaxConcurrent ?: return ""
            return PROVIDERS.mapNotNull { (id, label) ->
                val v = map[id] ?: return@mapNotNull null
                "$label: ${if (v == 0) "off" else v.toString()}"
            }.joinToString(" · ")
        }

        fun formatTokensPerMin(v: Int): String {
            if (v >= 1_000_000) {
                val m = v / 1_000_000.0
                return if (m == floor(m)) {
                    String.format(Locale.US, "%.0fM tok/min", m)
                } else {
                    String.format(Locale.US, "%.1fM tok/min", m)
                }
            }
            if (v >= 1_000) {
                val k = v / 1_000.0
                return if (k == floor(k)) {
                    String.format(Locale.US, "%.0fk tok/min", k)
                } else {
                    String.format(Locale.US, "%.1fk tok/min", k)
                }
            }
            return "$v tok/min"
        }

        fun formatDurationEta(secs: Double): String {
            if (!secs.isFinite() || secs <= 0.0) return "0m"
            if (secs < 60.0) return "<1m"
            val totalMins = (secs / 60.0).roundToInt()
            if (totalMins < 60) return "~${totalMins}m"
            val hours = totalMins / 60
            val mins = totalMins % 60
            if (hours < 48) return if (mins > 0) "~${hours}h ${mins}m" else "~${hours}h"
            val days = hours / 24
            val remHours = hours % 24
            return if (remHours > 0) "~${days}d ${remHours}h" else "~${days}d"
        }

        fun bandwidthLimitsSummary(limits: BandwidthLimits?): String {
            if (limits == null) return ""
            return buildList {
                limits.tokensPerMin?.let { add(formatTokensPerMin(it)) }
                limits.computeVcpuPerMin?.let { add("$it vCPU/min") }
                limits.computeUsdPerHour?.let { add("${money(it)}/h") }
            }.joinToString(" · ")
        }

        fun from(raw: Any?): OrbMissionBudget {
            val d = OrbJSON.dict(raw)
            val p = OrbJSON.dict(d?.get("pool"))
            val ownLimDict = OrbJSON.dict(d?.get("own_vm_limits"))
            val ownVmLimits = ownLimDict?.let { lim ->
                val pmRaw = OrbJSON.dict(lim["provider_max_concurrent"])
                val pm = buildMap {
                    if (pmRaw != null) {
                        for ((k, _) in pmRaw) {
                            OrbJSON.int(pmRaw, k)?.let { put(k, it) }
                        }
                    }
                }
                VmConcurrencyLimits(OrbJSON.int(lim, "max_concurrent"), pm)
            }
            val effDict = OrbJSON.dict(d?.get("effective_vm_limits"))
            val effectiveVmLimits = effDict?.let { eff ->
                EffectiveVmLimits(
                    source = OrbJSON.str(eff, "source") ?: "global",
                    poolId = OrbJSON.str(eff, "pool_id"),
                    active = OrbJSON.int(eff, "active") ?: 0,
                    maxConcurrent = OrbJSON.int(eff, "max_concurrent"),
                    globalActive = OrbJSON.int(eff, "global_active") ?: 0,
                    globalMaxConcurrent = OrbJSON.int(eff, "global_max_concurrent"),
                    ancestorMaxConcurrent = OrbJSON.int(eff, "ancestor_max_concurrent"),
                    providerLimits = OrbJSON.dictList(eff["provider_limits"]).map { pc ->
                        ProviderCapUsage(
                            provider = OrbJSON.str(pc, "provider") ?: "",
                            active = OrbJSON.int(pc, "active") ?: 0,
                            maxConcurrent = OrbJSON.int(pc, "max_concurrent") ?: 0,
                        )
                    },
                )
            }
            val ownBwDict = OrbJSON.dict(d?.get("own_bandwidth_limits"))
            val ownBandwidthLimits = ownBwDict?.let { bw ->
                BandwidthLimits(
                    tokensPerMin = OrbJSON.int(bw, "tokens_per_min"),
                    computeVcpuPerMin = OrbJSON.int(bw, "compute_vcpu_per_min"),
                    computeUsdPerHour = OrbJSON.double(bw, "compute_usd_per_hour"),
                    protectRoot = OrbJSON.bool(bw, "protect_root") ?: false,
                )
            }
            val effBwDict = OrbJSON.dict(d?.get("effective_bandwidth"))
            val effectiveBandwidth = effBwDict?.let { eff ->
                EffectiveBandwidth(
                    source = OrbJSON.str(eff, "source") ?: "none",
                    poolId = OrbJSON.str(eff, "pool_id"),
                    tokensPerMin = OrbJSON.int(eff, "tokens_per_min"),
                    computeVcpuPerMin = OrbJSON.int(eff, "compute_vcpu_per_min"),
                    computeUsdPerHour = OrbJSON.double(eff, "compute_usd_per_hour"),
                    protectRoot = OrbJSON.bool(eff, "protect_root") ?: false,
                    currentTokensPerMin = OrbJSON.int(eff, "current_tokens_per_min") ?: 0,
                    currentVcpuPerMin = OrbJSON.int(eff, "current_vcpu_per_min") ?: 0,
                    currentComputeUsdPerHour = OrbJSON.double(eff, "current_compute_usd_per_hour") ?: 0.0,
                    pacingActive = OrbJSON.bool(eff, "pacing_active") ?: false,
                    pacedDelayMs = OrbJSON.int(eff, "paced_delay_ms") ?: 0,
                    ancestorTokensPerMin = OrbJSON.int(eff, "ancestor_tokens_per_min"),
                    ancestorComputeVcpuPerMin = OrbJSON.int(eff, "ancestor_compute_vcpu_per_min"),
                    ancestorComputeUsdPerHour = OrbJSON.double(eff, "ancestor_compute_usd_per_hour"),
                )
            }
            return OrbMissionBudget(
                missionId = OrbJSON.str(d, "mission_id") ?: "",
                ownBudget = OrbJSON.double(d, "own_budget_usd"),
                poolId = OrbJSON.str(d, "pool_id"),
                mode = OrbJSON.str(d, "mode") ?: "none",
                pool = p?.let {
                    Pool(
                        OrbJSON.double(it, "budget_usd") ?: 0.0,
                        OrbJSON.double(it, "spent_usd") ?: 0.0,
                        OrbJSON.double(it, "reserved_usd") ?: 0.0,
                        OrbJSON.double(it, "carved_usd") ?: 0.0,
                        OrbJSON.double(it, "available_usd") ?: 0.0,
                    )
                },
                maxGrant = OrbJSON.double(d, "max_grant_usd"),
                ownVmLimits = ownVmLimits,
                vmLimitsMode = OrbJSON.str(d, "vm_limits_mode") ?: if (ownVmLimits != null) "own" else "global",
                vmLimitsPoolId = OrbJSON.str(d, "vm_limits_pool_id"),
                effectiveVmLimits = effectiveVmLimits,
                ownBandwidthLimits = ownBandwidthLimits,
                bandwidthMode = OrbJSON.str(d, "bandwidth_mode") ?: if (ownBandwidthLimits != null) "own" else "none",
                bandwidthPoolId = OrbJSON.str(d, "bandwidth_pool_id"),
                effectiveBandwidth = effectiveBandwidth,
                children = OrbJSON.dictList(d?.get("children")).map {
                    Child(
                        id = OrbJSON.str(it, "mission_id") ?: "",
                        mode = OrbJSON.str(it, "mode") ?: "pooled",
                        budget = OrbJSON.double(it, "budget_usd"),
                        spent = OrbJSON.double(it, "spent_usd") ?: 0.0,
                        reserved = OrbJSON.double(it, "reserved_usd") ?: 0.0,
                        hasVmLimits = OrbJSON.bool(it, "has_vm_limits") ?: false,
                        vmMaxConcurrent = OrbJSON.int(it, "vm_max_concurrent"),
                        hasBandwidthLimits = OrbJSON.bool(it, "has_bandwidth_limits") ?: false,
                        tokensPerMin = OrbJSON.int(it, "tokens_per_min"),
                        liveMachines = OrbJSON.int(it, "live_machines") ?: 0,
                    )
                },
            )
        }

        fun money(v: Double): String =
            if (v < 10) String.format(Locale.US, "$%.2f", v) else String.format(Locale.US, "$%.0f", v)

        /** A positive dollar amount, or null. */
        fun parseAmount(raw: String): Double? =
            raw.trim().removePrefix("$").toDoubleOrNull()?.takeIf { it > 0 && it <= 100000 }

        private fun parseWholeInt(raw: String, min: Int, max: Int, label: String): Result<Int> {
            if (raw.isEmpty() || !raw.all { it.isDigit() }) {
                return Result.failure(IllegalArgumentException("$label must be a whole number"))
            }
            val value = raw.toIntOrNull()
            if (value == null || value !in min..max) {
                return Result.failure(IllegalArgumentException("$label must be between $min and $max"))
            }
            return Result.success(value)
        }

        private fun parseTokenRate(raw: String): Result<Int> {
            val cleaned = raw.trim().replace(",", "").replace("_", "")
            if (cleaned.isEmpty()) {
                return Result.failure(IllegalArgumentException("Tokens per minute must be a number"))
            }
            var mult = 1.0
            var numPart = cleaned
            val last = cleaned.last()
            if (last == 'k' || last == 'K') {
                mult = 1_000.0
                numPart = cleaned.dropLast(1).trim()
            } else if (last == 'm' || last == 'M') {
                mult = 1_000_000.0
                numPart = cleaned.dropLast(1).trim()
            }
            val base = numPart.toDoubleOrNull()
            if (base == null || !base.isFinite()) {
                return Result.failure(IllegalArgumentException("Tokens per minute must be a number (for example 120000 or 120k)"))
            }
            val value = (base * mult).roundToLong()
            if (value < MIN_TOKENS_PER_MIN || value > MAX_TOKENS_PER_MIN) {
                return Result.failure(IllegalArgumentException("Tokens per minute must be between $MIN_TOKENS_PER_MIN and $MAX_TOKENS_PER_MIN"))
            }
            return Result.success(value.toInt())
        }

        fun parseVmLimits(
            totalRaw: String,
            providerRaws: Map<String, String>,
            view: OrbMissionBudget? = null,
        ): Result<VmConcurrencyLimits> {
            val ancestorMax = view?.effectiveVmLimits?.ancestorMaxConcurrent
            val trimmedTotal = totalRaw.trim()
            var maxConcurrent: Int? = null
            if (trimmedTotal.isNotEmpty()) {
                val parsed = parseWholeInt(trimmedTotal, 1, MAX_VM_CONCURRENCY, "Max concurrent")
                    .getOrElse { return Result.failure(it) }
                if (ancestorMax != null && parsed > ancestorMax) {
                    return Result.failure(IllegalArgumentException("The parent agent limits concurrent machines to $ancestorMax"))
                }
                maxConcurrent = parsed
            }
            val provMap = linkedMapOf<String, Int>()
            for ((id, label) in PROVIDERS) {
                val text = (providerRaws[id] ?: "").trim()
                if (text.isEmpty()) continue
                val parsed = parseWholeInt(text, 0, MAX_VM_CONCURRENCY, label)
                    .getOrElse { return Result.failure(it) }
                if (maxConcurrent != null && parsed > maxConcurrent) {
                    return Result.failure(IllegalArgumentException("$label limit ($parsed) cannot exceed max concurrent ($maxConcurrent)"))
                }
                if (ancestorMax != null && parsed > ancestorMax) {
                    return Result.failure(IllegalArgumentException("$label limit ($parsed) cannot exceed the parent limit ($ancestorMax)"))
                }
                provMap[id] = parsed
            }
            if (maxConcurrent == null && provMap.isEmpty()) {
                return Result.failure(IllegalArgumentException("Enter a max concurrent limit or at least one provider limit"))
            }
            return Result.success(VmConcurrencyLimits(maxConcurrent, provMap))
        }

        fun parseBandwidthLimits(
            tokensPerMinRaw: String,
            computeVcpuRaw: String,
            computeUsdPerHRaw: String,
            protectRoot: Boolean,
            view: OrbMissionBudget? = null,
        ): Result<BandwidthLimits> {
            val eff = view?.effectiveBandwidth
            var tokensPerMin: Int? = null
            val tpmTrim = tokensPerMinRaw.trim()
            if (tpmTrim.isNotEmpty()) {
                val parsed = parseTokenRate(tpmTrim).getOrElse { return Result.failure(it) }
                val anc = eff?.ancestorTokensPerMin
                if (anc != null && parsed > anc) {
                    return Result.failure(IllegalArgumentException("Tokens per minute cannot exceed the parent pool (${formatTokensPerMin(anc)})"))
                }
                tokensPerMin = parsed
            }

            var computeVcpu: Int? = null
            val vcpuTrim = computeVcpuRaw.trim()
            if (vcpuTrim.isNotEmpty()) {
                val parsed = parseWholeInt(vcpuTrim, 1, MAX_COMPUTE_VCPU_PER_MIN, "Compute vCPU/min")
                    .getOrElse { return Result.failure(it) }
                val anc = eff?.ancestorComputeVcpuPerMin
                if (anc != null && parsed > anc) {
                    return Result.failure(IllegalArgumentException("Compute vCPU/min cannot exceed the parent pool ($anc vCPU/min)"))
                }
                computeVcpu = parsed
            }

            var computeUsdH: Double? = null
            val usdTrim = computeUsdPerHRaw.trim().removePrefix("$")
            if (usdTrim.isNotEmpty()) {
                val n = usdTrim.toDoubleOrNull()
                if (n == null || !n.isFinite() || n < MIN_COMPUTE_USD_PER_HOUR || n > MAX_COMPUTE_USD_PER_HOUR) {
                    return Result.failure(
                        IllegalArgumentException(
                            "Compute burn ceiling must be between $${MIN_COMPUTE_USD_PER_HOUR} and $${MAX_COMPUTE_USD_PER_HOUR.toInt()}/h",
                        ),
                    )
                }
                val rounded = (n * 10_000.0).roundToLong() / 10_000.0
                val anc = eff?.ancestorComputeUsdPerHour
                if (anc != null && rounded > anc + 1e-9) {
                    return Result.failure(IllegalArgumentException("Compute burn ceiling cannot exceed the parent pool (${money(anc)}/h)"))
                }
                computeUsdH = rounded
            }

            if (tokensPerMin == null && computeVcpu == null && computeUsdH == null) {
                return Result.failure(IllegalArgumentException("Enter at least one bandwidth limit (tokens/min, vCPU/min, or $/h)"))
            }

            return Result.success(
                BandwidthLimits(
                    tokensPerMin = tokensPerMin,
                    computeVcpuPerMin = computeVcpu,
                    computeUsdPerHour = computeUsdH,
                    protectRoot = protectRoot,
                ),
            )
        }
    }
}

private fun formatAmount(v: Double?): String = when {
    v == null -> ""
    v == floor(v) -> v.toLong().toString()
    else -> v.toString()
}

private fun childSummary(c: OrbMissionBudget.Child): String = buildList {
    add(if (c.mode == "sub_budget") "Sub-budget ${OrbMissionBudget.money(c.budget ?: 0.0)}" else "Pooled")
    if (c.hasVmLimits) {
        add(c.vmMaxConcurrent?.let { "max $it VM" } ?: "custom VM cap")
    }
    if (c.hasBandwidthLimits) {
        add(c.tokensPerMin?.let { OrbMissionBudget.formatTokensPerMin(it) } ?: "paced")
    }
    add("${OrbMissionBudget.money(c.spent)} spent")
}.joinToString(" · ")

private fun toneColor(tone: OrbMissionBudget.RunwayForecast.Tone): Color = when (tone) {
    OrbMissionBudget.RunwayForecast.Tone.OK -> Color.White
    OrbMissionBudget.RunwayForecast.Tone.WARNING -> OrbStyle.warning
    OrbMissionBudget.RunwayForecast.Tone.DANGER -> OrbStyle.error
}

@Composable
private fun MissionSettingsCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrbStyle.panelRadius))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(OrbStyle.panelRadius))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

/** Full-screen Mission settings page on Android: Runway forecast + Budget + Bandwidth & pacing +
 * Machine limit + Subagents. Optimistic, with rollback and Retry on refusal. */
@Composable
fun OrbMissionSettingsDialog(core: OrbCore, missionId: String, title: String, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val path = "/api/control/missions/${core.encodeComponent(missionId)}/budget"
    var view by remember { mutableStateOf<OrbMissionBudget?>(null) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableStateOf<(() -> Unit)?>(null) }
    var vmSaveError by remember { mutableStateOf<String?>(null) }
    var vmRetry by remember { mutableStateOf<(() -> Unit)?>(null) }
    var bwSaveError by remember { mutableStateOf<String?>(null) }
    var bwRetry by remember { mutableStateOf<(() -> Unit)?>(null) }
    var busy by remember { mutableStateOf(false) }

    var draft by remember { mutableStateOf("") }
    var vmTotalDraft by remember { mutableStateOf("") }
    var vmProviderDrafts by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var providersExpanded by remember { mutableStateOf(false) }

    var bwTokensDraft by remember { mutableStateOf("") }
    var bwVcpuDraft by remember { mutableStateOf("") }
    var bwUsdHDraft by remember { mutableStateOf("") }
    var bwProtectRoot by remember { mutableStateOf(true) }
    var showIdleChildren by remember { mutableStateOf(false) }

    fun syncVmDrafts(v: OrbMissionBudget) {
        vmTotalDraft = v.ownVmLimits?.maxConcurrent?.toString() ?: ""
        vmProviderDrafts = OrbMissionBudget.PROVIDERS.associate { (id, _) ->
            id to (v.ownVmLimits?.providerMaxConcurrent?.get(id)?.toString() ?: "")
        }
        if (!v.ownVmLimits?.providerMaxConcurrent.isNullOrEmpty()) {
            providersExpanded = true
        }
    }

    fun syncBwDrafts(v: OrbMissionBudget) {
        bwTokensDraft = v.ownBandwidthLimits?.tokensPerMin?.toString() ?: ""
        bwVcpuDraft = v.ownBandwidthLimits?.computeVcpuPerMin?.toString() ?: ""
        bwUsdHDraft = formatAmount(v.ownBandwidthLimits?.computeUsdPerHour)
        bwProtectRoot = v.ownBandwidthLimits?.protectRoot ?: true
    }

    fun vmDraftDirty(v: OrbMissionBudget): Boolean {
        val curTotal = v.ownVmLimits?.maxConcurrent?.toString() ?: ""
        if (vmTotalDraft.trim() != curTotal) return true
        return OrbMissionBudget.PROVIDERS.any { (id, _) ->
            val cur = v.ownVmLimits?.providerMaxConcurrent?.get(id)?.toString() ?: ""
            (vmProviderDrafts[id] ?: "").trim() != cur
        }
    }

    fun bwDraftDirty(v: OrbMissionBudget): Boolean {
        val own = v.ownBandwidthLimits
        val curT = own?.tokensPerMin?.toString() ?: ""
        val curV = own?.computeVcpuPerMin?.toString() ?: ""
        val curU = formatAmount(own?.computeUsdPerHour)
        val curP = own?.protectRoot ?: true
        return bwTokensDraft.trim() != curT ||
            bwVcpuDraft.trim() != curV ||
            bwUsdHDraft.trim() != curU ||
            bwProtectRoot != curP
    }

    suspend fun load() {
        loadError = null
        runCatching { OrbMissionBudget.from(core.request(path)) }
            .onSuccess {
                view = it
                draft = formatAmount(it.ownBudget)
                syncVmDrafts(it)
                syncBwDrafts(it)
            }
            .onFailure { loadError = it.message ?: "Couldn’t load the budget." }
    }
    LaunchedEffect(missionId) { load() }

    fun commit(amount: Double?) {
        val before = view ?: return
        if (busy) return
        busy = true; saveError = null; retry = null
        view = before.optimistic(amount)
        scope.launch {
            runCatching { OrbMissionBudget.from(core.request(path, method = "PUT", body = mapOf("budget_usd" to amount))) }
                .onSuccess {
                    view = it
                    draft = formatAmount(it.ownBudget)
                    syncVmDrafts(it)
                    syncBwDrafts(it)
                }
                .onFailure {
                    view = before; draft = formatAmount(before.ownBudget)
                    saveError = it.message ?: "Budget not saved."
                    retry = { commit(amount) }
                }
            busy = false
        }
    }

    fun commitVmLimits(limits: OrbMissionBudget.VmConcurrencyLimits?) {
        val before = view ?: return
        if (busy) return
        busy = true; vmSaveError = null; vmRetry = null
        val opt = before.optimisticVmLimits(limits)
        view = opt; syncVmDrafts(opt)
        scope.launch {
            runCatching { OrbMissionBudget.from(core.request(path, method = "PUT", body = mapOf("vm_limits" to limits?.toWire()))) }
                .onSuccess {
                    view = it
                    draft = formatAmount(it.ownBudget)
                    syncVmDrafts(it)
                    syncBwDrafts(it)
                }
                .onFailure {
                    view = before; syncVmDrafts(before)
                    vmSaveError = it.message ?: "Machine limit not saved."
                    vmRetry = { commitVmLimits(limits) }
                }
            busy = false
        }
    }

    fun commitBandwidth(limits: OrbMissionBudget.BandwidthLimits?) {
        val before = view ?: return
        if (busy) return
        busy = true; bwSaveError = null; bwRetry = null
        val opt = before.optimisticBandwidthLimits(limits)
        view = opt; syncBwDrafts(opt)
        scope.launch {
            runCatching { OrbMissionBudget.from(core.request(path, method = "PUT", body = mapOf("bandwidth_limits" to limits?.toWire()))) }
                .onSuccess {
                    view = it
                    draft = formatAmount(it.ownBudget)
                    syncVmDrafts(it)
                    syncBwDrafts(it)
                }
                .onFailure {
                    view = before; syncBwDrafts(before)
                    bwSaveError = it.message ?: "Bandwidth limit not saved."
                    bwRetry = { commitBandwidth(limits) }
                }
            busy = false
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            color = OrbStyle.background,
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .imePadding(),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Mission settings", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                        if (title.isNotEmpty()) {
                            Text(
                                title,
                                color = OrbStyle.textSecondary,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    TextButton(onClick = onDismiss) {
                        Text("Done", color = Color.White, fontWeight = FontWeight.SemiBold)
                    }
                }
                HorizontalDivider(color = OrbStyle.border)

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    val v = view
                    when {
                        v != null -> {
                            val fc = v.computeRunwayForecast(
                                draftBudgetUsd = if (v.mode == "own") draft else null,
                                draftComputeUsdPerH = if (v.bandwidthMode == "own") bwUsdHDraft else null,
                                draftComputeVcpu = if (v.bandwidthMode == "own") bwVcpuDraft else null,
                                bandwidthEnabled = v.bandwidthMode == "own" || v.effectiveBandwidth?.source == "mission",
                                budgetEnabled = v.mode == "own" || v.mode == "pooled",
                            )
                            MissionSettingsCard(modifier = Modifier.testTag("mission.settings.forecast")) {
                                Text("Runway forecast", color = OrbStyle.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                                Text(fc.headline, color = toneColor(fc.tone), fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                                Text(fc.subline, color = OrbStyle.textSecondary, fontSize = 12.sp)
                                val cap = fc.capUsd
                                if (cap != null && cap > 0.0) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .height(8.dp)
                                            .clip(RoundedCornerShape(4.dp))
                                            .background(OrbStyle.card),
                                        horizontalArrangement = Arrangement.spacedBy(1.5.dp),
                                    ) {
                                        if (fc.spentUsd > 0.0) {
                                            Box(
                                                Modifier
                                                    .weight((fc.spentUsd / cap).toFloat().coerceAtLeast(0.01f))
                                                    .fillMaxHeight()
                                                    .background(OrbStyle.inboxBlue),
                                            )
                                        }
                                        if (fc.reservedUsd > 0.0) {
                                            Box(
                                                Modifier
                                                    .weight((fc.reservedUsd / cap).toFloat().coerceAtLeast(0.01f))
                                                    .fillMaxHeight()
                                                    .background(OrbStyle.warning),
                                            )
                                        }
                                        if (fc.carvedUsd > 0.0) {
                                            Box(
                                                Modifier
                                                    .weight((fc.carvedUsd / cap).toFloat().coerceAtLeast(0.01f))
                                                    .fillMaxHeight()
                                                    .background(Color(0xFFAD9ACB)),
                                            )
                                        }
                                        if (fc.availableUsd > 0.0) {
                                            Box(
                                                Modifier
                                                    .weight((fc.availableUsd / cap).toFloat().coerceAtLeast(0.01f))
                                                    .fillMaxHeight()
                                                    .background(OrbStyle.success),
                                            )
                                        }
                                    }
                                }
                            }

                            MissionSettingsCard {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("Budget", color = Color.White, fontWeight = FontWeight.Medium)
                                        Text(
                                            "Caps what this agent and its subagents spend on managed machines.",
                                            color = OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                        )
                                    }
                                    Switch(
                                        checked = v.mode == "own",
                                        enabled = !busy,
                                        onCheckedChange = { on ->
                                            if (!on) commit(null) else {
                                                val initial = v.maxGrant?.let { minOf(5.0, floor(it * 100) / 100) } ?: 5.0
                                                if (initial <= 0) saveError = "The parent pool has nothing left to grant" else commit(initial)
                                            }
                                        },
                                        modifier = Modifier.testTag("mission.settings.budget.toggle"),
                                    )
                                }
                                Text(v.modeLine, color = OrbStyle.textSecondary, fontSize = 13.sp)
                                if (v.mode == "own") {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Box(
                                            Modifier
                                                .weight(1f)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(OrbStyle.card)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                .padding(horizontal = 12.dp, vertical = 10.dp),
                                        ) {
                                            if (draft.isEmpty()) Text("Amount (USD)", color = OrbStyle.textMuted, fontSize = 14.sp)
                                            BasicTextField(
                                                value = draft,
                                                onValueChange = { draft = it },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                                textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                                                cursorBrush = SolidColor(Color.White),
                                                modifier = Modifier.fillMaxWidth().testTag("mission.settings.budget.amount"),
                                            )
                                        }
                                        TextButton(
                                            enabled = !busy && draft != formatAmount(v.ownBudget),
                                            onClick = {
                                                val amount = OrbMissionBudget.parseAmount(draft)
                                                val max = v.maxGrant
                                                saveError = when {
                                                    amount == null -> "Enter a positive amount"
                                                    max != null && amount > max + 1e-9 -> "The parent pool has ${OrbMissionBudget.money(max)} left to grant"
                                                    else -> null
                                                }
                                                if (saveError == null && amount != null) commit(amount)
                                            },
                                        ) { Text("Save", color = Color.White) }
                                    }
                                    v.maxGrant?.let {
                                        Text("Up to ${OrbMissionBudget.money(it)} from the parent pool.", color = OrbStyle.textSecondary, fontSize = 12.sp)
                                    }
                                }
                                v.pool?.let { p ->
                                    LinearProgressIndicator(
                                        progress = { ((p.spent + p.reserved + p.carved) / maxOf(p.budget, 0.0001)).toFloat().coerceIn(0f, 1f) },
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                    listOf(
                                        "Spent" to OrbMissionBudget.money(p.spent),
                                        "Reserved" to OrbMissionBudget.money(p.reserved),
                                        "Sub-budgets" to OrbMissionBudget.money(p.carved),
                                        "Remaining" to "${OrbMissionBudget.money(maxOf(0.0, p.available))} of ${OrbMissionBudget.money(p.budget)}",
                                    ).forEach { (label, value) ->
                                        Row {
                                            Text(label, color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                            Text(value, color = Color.White, fontSize = 13.sp)
                                        }
                                    }
                                }
                                saveError?.let { err ->
                                    Text("Budget not saved: $err", color = OrbStyle.error, fontSize = 13.sp)
                                    retry?.let { r -> TextButton(onClick = r) { Text("Retry", color = Color.White) } }
                                }
                            }

                            MissionSettingsCard {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("Bandwidth & pacing", color = Color.White, fontWeight = FontWeight.Medium)
                                        Text(
                                            "Smooths inference and machine spawn bursts with pace delays instead of hard errors.",
                                            color = OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                        )
                                    }
                                    Switch(
                                        checked = v.bandwidthMode == "own",
                                        enabled = !busy,
                                        onCheckedChange = { on ->
                                            if (!on) commitBandwidth(null) else {
                                                val ancTpm = v.effectiveBandwidth?.ancestorTokensPerMin
                                                val defaultTpm = ancTpm?.let { minOf(120_000, it) } ?: 120_000
                                                commitBandwidth(
                                                    OrbMissionBudget.BandwidthLimits(
                                                        tokensPerMin = defaultTpm,
                                                        computeVcpuPerMin = null,
                                                        computeUsdPerHour = null,
                                                        protectRoot = true,
                                                    ),
                                                )
                                            }
                                        },
                                        modifier = Modifier.testTag("mission.settings.bandwidth.toggle"),
                                    )
                                }
                                Text(v.bandwidthModeLine, color = OrbStyle.textSecondary, fontSize = 13.sp)
                                v.effectiveBandwidth?.takeIf { it.source == "mission" }?.let { eff ->
                                    val summary = OrbMissionBudget.bandwidthLimitsSummary(
                                        OrbMissionBudget.BandwidthLimits(
                                            tokensPerMin = eff.tokensPerMin,
                                            computeVcpuPerMin = eff.computeVcpuPerMin,
                                            computeUsdPerHour = eff.computeUsdPerHour,
                                            protectRoot = eff.protectRoot,
                                        ),
                                    )
                                    if (summary.isNotEmpty()) {
                                        Row {
                                            Text("Active ceiling", color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                            Text(summary, color = Color.White, fontSize = 13.sp)
                                        }
                                    }
                                    if (eff.pacingActive) {
                                        Row {
                                            Text("Pacing", color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                            Text("Smoothing bursts", color = OrbStyle.warning, fontSize = 13.sp)
                                        }
                                    }
                                }
                                if (v.bandwidthMode == "own") {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text("Tokens / min", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                        Box(
                                            Modifier
                                                .width(124.dp)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(OrbStyle.card)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                .padding(horizontal = 10.dp, vertical = 8.dp),
                                        ) {
                                            if (bwTokensDraft.isEmpty()) Text("e.g. 120k", color = OrbStyle.textMuted, fontSize = 13.sp)
                                            BasicTextField(
                                                value = bwTokensDraft,
                                                onValueChange = { bwTokensDraft = it },
                                                singleLine = true,
                                                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                                cursorBrush = SolidColor(Color.White),
                                                modifier = Modifier.fillMaxWidth().testTag("mission.settings.bandwidth.tpm"),
                                            )
                                        }
                                    }
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text("Compute (vCPU / min)", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                        Box(
                                            Modifier
                                                .width(124.dp)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(OrbStyle.card)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                .padding(horizontal = 10.dp, vertical = 8.dp),
                                        ) {
                                            if (bwVcpuDraft.isEmpty()) Text("Optional", color = OrbStyle.textMuted, fontSize = 13.sp)
                                            BasicTextField(
                                                value = bwVcpuDraft,
                                                onValueChange = { bwVcpuDraft = it },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                                cursorBrush = SolidColor(Color.White),
                                                modifier = Modifier.fillMaxWidth().testTag("mission.settings.bandwidth.vcpu"),
                                            )
                                        }
                                    }
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text("Burn ceiling ($/h)", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                        Box(
                                            Modifier
                                                .width(124.dp)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(OrbStyle.card)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                .padding(horizontal = 10.dp, vertical = 8.dp),
                                        ) {
                                            if (bwUsdHDraft.isEmpty()) Text("Optional", color = OrbStyle.textMuted, fontSize = 13.sp)
                                            BasicTextField(
                                                value = bwUsdHDraft,
                                                onValueChange = { bwUsdHDraft = it },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                                cursorBrush = SolidColor(Color.White),
                                                modifier = Modifier.fillMaxWidth().testTag("mission.settings.bandwidth.usdh"),
                                            )
                                        }
                                    }
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text("Prioritize root agent", color = Color.White, fontSize = 13.sp)
                                            Text("Subagents absorb pace delays first.", color = OrbStyle.textSecondary, fontSize = 12.sp)
                                        }
                                        Switch(
                                            checked = bwProtectRoot,
                                            enabled = !busy,
                                            onCheckedChange = { bwProtectRoot = it },
                                            modifier = Modifier.testTag("mission.settings.bandwidth.protect_root"),
                                        )
                                    }
                                    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                        TextButton(
                                            enabled = !busy && bwDraftDirty(v),
                                            onClick = {
                                                OrbMissionBudget.parseBandwidthLimits(
                                                    tokensPerMinRaw = bwTokensDraft,
                                                    computeVcpuRaw = bwVcpuDraft,
                                                    computeUsdPerHRaw = bwUsdHDraft,
                                                    protectRoot = bwProtectRoot,
                                                    view = v,
                                                )
                                                    .onSuccess { commitBandwidth(it) }
                                                    .onFailure { bwSaveError = it.message }
                                            },
                                            modifier = Modifier.testTag("mission.settings.bandwidth.save"),
                                        ) { Text("Save bandwidth", color = Color.White) }
                                    }
                                }
                                bwSaveError?.let { err ->
                                    Text("Bandwidth limit not saved: $err", color = OrbStyle.error, fontSize = 13.sp)
                                    bwRetry?.let { r -> TextButton(onClick = r) { Text("Retry", color = Color.White) } }
                                }
                            }

                            MissionSettingsCard {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("Machine limit", color = Color.White, fontWeight = FontWeight.Medium)
                                        Text(
                                            "Overrides the global concurrent machine cap for this agent and its subagents.",
                                            color = OrbStyle.textSecondary,
                                            fontSize = 12.sp,
                                        )
                                    }
                                    Switch(
                                        checked = v.vmLimitsMode == "own",
                                        enabled = !busy,
                                        onCheckedChange = { on ->
                                            if (!on) commitVmLimits(null) else {
                                                val ancMax = v.effectiveVmLimits?.ancestorMaxConcurrent
                                                if (ancMax != null && ancMax <= 0) {
                                                    vmSaveError = "The parent pool does not allow concurrent machines"
                                                } else {
                                                    val initial = ancMax?.let { minOf(4, it) } ?: 4
                                                    commitVmLimits(OrbMissionBudget.VmConcurrencyLimits(initial, emptyMap()))
                                                }
                                            }
                                        },
                                        modifier = Modifier.testTag("mission.settings.vmlimits.toggle"),
                                    )
                                }
                                Text(v.vmLimitsModeLine, color = OrbStyle.textSecondary, fontSize = 13.sp)
                                v.effectiveVmLimits?.let { eff ->
                                    val activeLabel = eff.maxConcurrent?.let { "${eff.active} / $it" } ?: "${eff.active} running"
                                    Row {
                                        Text(
                                            if (eff.source == "mission") "Pool active" else "Global active",
                                            color = OrbStyle.textSecondary,
                                            fontSize = 13.sp,
                                            modifier = Modifier.weight(1f),
                                        )
                                        Text(activeLabel, color = Color.White, fontSize = 13.sp)
                                    }
                                    eff.providerLimits.forEach { pc ->
                                        Row {
                                            Text(OrbMissionBudget.providerLabel(pc.provider), color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                            Text(if (pc.maxConcurrent == 0) "Blocked" else "${pc.active} / ${pc.maxConcurrent}", color = Color.White, fontSize = 13.sp)
                                        }
                                    }
                                }
                                if (v.vmLimitsMode == "own") {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text("Max concurrent", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                        Box(
                                            Modifier
                                                .width(104.dp)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(OrbStyle.card)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                .padding(horizontal = 10.dp, vertical = 8.dp),
                                        ) {
                                            if (vmTotalDraft.isEmpty()) Text("Optional", color = OrbStyle.textMuted, fontSize = 13.sp)
                                            BasicTextField(
                                                value = vmTotalDraft,
                                                onValueChange = { vmTotalDraft = it },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                                cursorBrush = SolidColor(Color.White),
                                                modifier = Modifier.fillMaxWidth().testTag("mission.settings.vmlimits.total"),
                                            )
                                        }
                                    }
                                    val summary = OrbMissionBudget.providerLimitsSummary(v.ownVmLimits)
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable { providersExpanded = !providersExpanded }
                                            .padding(vertical = 4.dp),
                                    ) {
                                        Text(
                                            if (providersExpanded) "▾ Per-provider limits" else "▸ Per-provider limits",
                                            color = Color.White,
                                            fontSize = 13.sp,
                                            modifier = Modifier.weight(1f),
                                        )
                                        Text(summary.ifEmpty { "Optional" }, color = OrbStyle.textSecondary, fontSize = 12.sp)
                                    }
                                    if (providersExpanded) {
                                        OrbMissionBudget.PROVIDERS.forEach { (id, label) ->
                                            val curVal = vmProviderDrafts[id] ?: ""
                                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                Text(label, color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                                Box(
                                                    Modifier
                                                        .width(124.dp)
                                                        .clip(RoundedCornerShape(8.dp))
                                                        .background(OrbStyle.card)
                                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                                                        .padding(horizontal = 10.dp, vertical = 7.dp),
                                                ) {
                                                    if (curVal.isEmpty()) Text("No cap (0=off)", color = OrbStyle.textMuted, fontSize = 12.sp)
                                                    BasicTextField(
                                                        value = curVal,
                                                        onValueChange = { next -> vmProviderDrafts = vmProviderDrafts + (id to next) },
                                                        singleLine = true,
                                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                                        cursorBrush = SolidColor(Color.White),
                                                        modifier = Modifier.fillMaxWidth().testTag("mission.settings.vmlimits.provider.$id"),
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                        TextButton(
                                            enabled = !busy && vmDraftDirty(v),
                                            onClick = {
                                                OrbMissionBudget.parseVmLimits(vmTotalDraft, vmProviderDrafts, v)
                                                    .onSuccess { commitVmLimits(it) }
                                                    .onFailure { vmSaveError = it.message }
                                            },
                                            modifier = Modifier.testTag("mission.settings.vmlimits.save"),
                                        ) { Text("Save machine limit", color = Color.White) }
                                    }
                                }
                                vmSaveError?.let { err ->
                                    Text("Machine limit not saved: $err", color = OrbStyle.error, fontSize = 13.sp)
                                    vmRetry?.let { r -> TextButton(onClick = r) { Text("Retry", color = Color.White) } }
                                }
                            }

                            if (v.showsSubagents) {
                                MissionSettingsCard {
                                    val activeRows = v.children.filter { !it.isIdlePooled }
                                    val idleRows = v.children.filter { it.isIdlePooled }
                                    val visible = if (showIdleChildren) v.children else activeRows
                                    Text("Subagents", color = Color.White, fontWeight = FontWeight.Medium)
                                    visible.forEach { c ->
                                        Row {
                                            Text("Agent ${c.id.take(8)}", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                            Text(childSummary(c), color = OrbStyle.textSecondary, fontSize = 13.sp)
                                        }
                                    }
                                    if (idleRows.isNotEmpty()) {
                                        TextButton(onClick = { showIdleChildren = !showIdleChildren }) {
                                            Text(
                                                if (showIdleChildren) "Hide $0 rows" else "${idleRows.size} with $0 spend · Show",
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        loadError != null -> {
                            MissionSettingsCard {
                                Text(loadError!!, color = OrbStyle.error, fontSize = 13.sp)
                                TextButton(onClick = { scope.launch { load() } }) { Text("Retry", color = Color.White) }
                            }
                        }
                        else -> {
                            repeat(3) {
                                MissionSettingsCard(modifier = Modifier.orbShimmer()) {
                                    Box(Modifier.width(120.dp).height(14.dp).clip(RoundedCornerShape(4.dp)).background(OrbStyle.card))
                                    Spacer(Modifier.height(2.dp))
                                    Box(Modifier.fillMaxWidth().height(12.dp).clip(RoundedCornerShape(4.dp)).background(OrbStyle.card))
                                    Box(Modifier.width(180.dp).height(12.dp).clip(RoundedCornerShape(4.dp)).background(OrbStyle.card))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
