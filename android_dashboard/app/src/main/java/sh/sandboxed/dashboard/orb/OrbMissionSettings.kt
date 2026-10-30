package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

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
    val children: List<Child>,
) {
    data class Pool(val budget: Double, val spent: Double, val reserved: Double, val carved: Double, val available: Double)
    data class VmConcurrencyLimits(val maxConcurrent: Int?, val providerMaxConcurrent: Map<String, Int>) {
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
    data class Child(
        val id: String,
        val mode: String,
        val budget: Double?,
        val spent: Double,
        val reserved: Double = 0.0,
        val hasVmLimits: Boolean = false,
        val vmMaxConcurrent: Int? = null,
        val liveMachines: Int = 0,
    ) {
        val isIdlePooled: Boolean
            get() = mode == "pooled" && !hasVmLimits && spent == 0.0 && reserved == 0.0 && liveMachines == 0
    }

    /** Same derivation as desktop `optimisticBudget`. */
    fun optimistic(amount: Double?): OrbMissionBudget {
        if (amount == null) {
            return copy(ownBudget = null, mode = if (mode == "own" && maxGrant != null) "pooled" else "none", pool = null, poolId = null)
        }
        val p = if (pool != null && mode == "own") pool.copy(budget = amount, available = pool.available + amount - pool.budget)
        else Pool(amount, 0.0, 0.0, 0.0, amount)
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

    val showsSubagents: Boolean
        get() = children.isNotEmpty() && (
            mode != "none" || vmLimitsMode != "global" || children.any { it.mode == "sub_budget" || it.hasVmLimits }
        )

    companion object {
        const val MAX_VM_CONCURRENCY = 128
        val PROVIDERS: List<Pair<String, String>> = listOf(
            "boat" to "boat.dev",
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
            return OrbMissionBudget(
                missionId = OrbJSON.str(d, "mission_id") ?: "",
                ownBudget = OrbJSON.double(d, "own_budget_usd"),
                poolId = OrbJSON.str(d, "pool_id"),
                mode = OrbJSON.str(d, "mode") ?: "none",
                pool = p?.let {
                    Pool(
                        OrbJSON.double(it, "budget_usd") ?: 0.0, OrbJSON.double(it, "spent_usd") ?: 0.0,
                        OrbJSON.double(it, "reserved_usd") ?: 0.0, OrbJSON.double(it, "carved_usd") ?: 0.0,
                        OrbJSON.double(it, "available_usd") ?: 0.0,
                    )
                },
                maxGrant = OrbJSON.double(d, "max_grant_usd"),
                ownVmLimits = ownVmLimits,
                vmLimitsMode = OrbJSON.str(d, "vm_limits_mode") ?: if (ownVmLimits != null) "own" else "global",
                vmLimitsPoolId = OrbJSON.str(d, "vm_limits_pool_id"),
                effectiveVmLimits = effectiveVmLimits,
                children = OrbJSON.dictList(d?.get("children")).map {
                    Child(
                        id = OrbJSON.str(it, "mission_id") ?: "",
                        mode = OrbJSON.str(it, "mode") ?: "pooled",
                        budget = OrbJSON.double(it, "budget_usd"),
                        spent = OrbJSON.double(it, "spent_usd") ?: 0.0,
                        reserved = OrbJSON.double(it, "reserved_usd") ?: 0.0,
                        hasVmLimits = OrbJSON.bool(it, "has_vm_limits") ?: false,
                        vmMaxConcurrent = OrbJSON.int(it, "vm_max_concurrent"),
                        liveMachines = OrbJSON.int(it, "live_machines") ?: 0,
                    )
                },
            )
        }

        fun money(v: Double): String = if (v < 10) String.format(java.util.Locale.US, "$%.2f", v) else String.format(java.util.Locale.US, "$%.0f", v)

        /** A positive dollar amount, or null. */
        fun parseAmount(raw: String): Double? = raw.trim().removePrefix("$").toDoubleOrNull()?.takeIf { it > 0 && it <= 100000 }

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
    }
}

private fun formatAmount(v: Double?): String = when {
    v == null -> ""
    v == Math.floor(v) -> v.toLong().toString()
    else -> v.toString()
}

private fun childSummary(c: OrbMissionBudget.Child): String = buildList {
    add(if (c.mode == "sub_budget") "Sub-budget ${OrbMissionBudget.money(c.budget ?: 0.0)}" else "Pooled")
    if (c.hasVmLimits) {
        add(c.vmMaxConcurrent?.let { "max $it VM" } ?: "custom VM cap")
    }
    add("${OrbMissionBudget.money(c.spent)} spent")
}.joinToString(" · ")

/** Long-press "Mission settings…": Budget + Machine limit sections of the desktop sheet.
 * Optimistic, with rollback and Retry on refusal. */
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
    var busy by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var vmTotalDraft by remember { mutableStateOf("") }
    var vmProviderDrafts by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var providersExpanded by remember { mutableStateOf(false) }
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

    fun vmDraftDirty(v: OrbMissionBudget): Boolean {
        val curTotal = v.ownVmLimits?.maxConcurrent?.toString() ?: ""
        if (vmTotalDraft.trim() != curTotal) return true
        return OrbMissionBudget.PROVIDERS.any { (id, _) ->
            val cur = v.ownVmLimits?.providerMaxConcurrent?.get(id)?.toString() ?: ""
            (vmProviderDrafts[id] ?: "").trim() != cur
        }
    }

    suspend fun load() {
        loadError = null
        runCatching { OrbMissionBudget.from(core.request(path)) }
            .onSuccess { view = it; draft = formatAmount(it.ownBudget); syncVmDrafts(it) }
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
                .onSuccess { view = it; draft = formatAmount(it.ownBudget); syncVmDrafts(it) }
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
                .onSuccess { view = it; draft = formatAmount(it.ownBudget); syncVmDrafts(it) }
                .onFailure {
                    view = before; syncVmDrafts(before)
                    vmSaveError = it.message ?: "Machine limit not saved."
                    vmRetry = { commitVmLimits(limits) }
                }
            busy = false
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = OrbStyle.elevated,
        titleContentColor = Color.White,
        title = { Text("Mission settings", fontWeight = FontWeight.SemiBold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(title, color = OrbStyle.textSecondary, fontSize = 13.sp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Budget", color = Color.White, fontWeight = FontWeight.Medium)
                        Text("Caps what this agent and its subagents spend on managed machines.", color = OrbStyle.textSecondary, fontSize = 12.sp)
                    }
                    val v = view
                    Switch(
                        checked = v?.mode == "own",
                        enabled = v != null && !busy,
                        onCheckedChange = { on ->
                            if (v == null) return@Switch
                            if (!on) commit(null) else {
                                val initial = v.maxGrant?.let { minOf(5.0, Math.floor(it * 100) / 100) } ?: 5.0
                                if (initial <= 0) saveError = "The parent pool has nothing left to grant" else commit(initial)
                            }
                        },
                        modifier = Modifier.testTag("mission.settings.budget.toggle"),
                    )
                }
                val v = view
                when {
                    v != null -> {
                        Text(v.modeLine, color = OrbStyle.textSecondary, fontSize = 13.sp)
                        if (v.mode == "own") {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 10.dp)
                                ) {
                                    if (draft.isEmpty()) Text("Amount (USD)", color = OrbStyle.textMuted, fontSize = 14.sp)
                                    BasicTextField(
                                        value = draft, onValueChange = { draft = it }, singleLine = true,
                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp), cursorBrush = SolidColor(Color.White),
                                        modifier = Modifier.fillMaxWidth().testTag("mission.settings.budget.amount"),
                                    )
                                }
                                TextButton(enabled = !busy && draft != formatAmount(v.ownBudget), onClick = {
                                    val amount = OrbMissionBudget.parseAmount(draft)
                                    val max = v.maxGrant
                                    saveError = when {
                                        amount == null -> "Enter a positive amount"
                                        max != null && amount > max + 1e-9 -> "The parent pool has ${OrbMissionBudget.money(max)} left to grant"
                                        else -> null
                                    }
                                    if (saveError == null && amount != null) commit(amount)
                                }) { Text("Save", color = Color.White) }
                            }
                            v.maxGrant?.let { Text("Up to ${OrbMissionBudget.money(it)} from the parent pool.", color = OrbStyle.textSecondary, fontSize = 12.sp) }
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
                                Row { Text(label, color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f)); Text(value, color = Color.White, fontSize = 13.sp) }
                            }
                        }
                        saveError?.let { err ->
                            Text("Budget not saved: $err", color = OrbStyle.error, fontSize = 13.sp)
                            retry?.let { r -> TextButton(onClick = r) { Text("Retry", color = Color.White) } }
                        }

                        HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(vertical = 4.dp))

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Machine limit", color = Color.White, fontWeight = FontWeight.Medium)
                                Text("Overrides the global concurrent machine cap for this agent and its subagents.", color = OrbStyle.textSecondary, fontSize = 12.sp)
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
                                Text(if (eff.source == "mission") "Pool active" else "Global active", color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
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
                                    Modifier.width(96.dp).clip(RoundedCornerShape(8.dp)).background(OrbStyle.surface)
                                        .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 8.dp)
                                ) {
                                    if (vmTotalDraft.isEmpty()) Text("Optional", color = OrbStyle.textMuted, fontSize = 13.sp)
                                    BasicTextField(
                                        value = vmTotalDraft, onValueChange = { vmTotalDraft = it }, singleLine = true,
                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp), cursorBrush = SolidColor(Color.White),
                                        modifier = Modifier.fillMaxWidth().testTag("mission.settings.vmlimits.total"),
                                    )
                                }
                            }
                            val summary = OrbMissionBudget.providerLimitsSummary(v.ownVmLimits)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth().clickable { providersExpanded = !providersExpanded }.padding(vertical = 4.dp),
                            ) {
                                Text(if (providersExpanded) "▾ Per-provider limits" else "▸ Per-provider limits", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                Text(summary.ifEmpty { "Optional" }, color = OrbStyle.textSecondary, fontSize = 12.sp)
                            }
                            if (providersExpanded) {
                                OrbMissionBudget.PROVIDERS.forEach { (id, label) ->
                                    val curVal = vmProviderDrafts[id] ?: ""
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text(label, color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                        Box(
                                            Modifier.width(120.dp).clip(RoundedCornerShape(8.dp)).background(OrbStyle.surface)
                                                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 7.dp)
                                        ) {
                                            if (curVal.isEmpty()) Text("No cap (0=off)", color = OrbStyle.textMuted, fontSize = 12.sp)
                                            BasicTextField(
                                                value = curVal,
                                                onValueChange = { next -> vmProviderDrafts = vmProviderDrafts + (id to next) },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                textStyle = TextStyle(color = Color.White, fontSize = 13.sp), cursorBrush = SolidColor(Color.White),
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

                        if (v.showsSubagents) {
                            HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(vertical = 4.dp))
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
                    loadError != null -> {
                        Text(loadError!!, color = OrbStyle.error, fontSize = 13.sp)
                        TextButton(onClick = { scope.launch { load() } }) { Text("Retry", color = Color.White) }
                    }
                    else -> LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done", color = Color.White, fontWeight = FontWeight.SemiBold) } },
    )
}
