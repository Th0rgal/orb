package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
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
    val children: List<Child>,
) {
    data class Pool(val budget: Double, val spent: Double, val reserved: Double, val carved: Double, val available: Double)
    data class Child(val id: String, val mode: String, val budget: Double?, val spent: Double)

    /** Same derivation as desktop `optimisticBudget`. */
    fun optimistic(amount: Double?): OrbMissionBudget {
        if (amount == null) {
            return copy(ownBudget = null, mode = if (mode == "own" && maxGrant != null) "pooled" else "none", pool = null, poolId = null)
        }
        val p = if (pool != null && mode == "own") pool.copy(budget = amount, available = pool.available + amount - pool.budget)
        else Pool(amount, 0.0, 0.0, 0.0, amount)
        return copy(ownBudget = amount, mode = "own", poolId = missionId, pool = p)
    }

    val modeLine: String
        get() = when (mode) {
            "own" -> if (maxGrant != null) "Own sub-budget, carved from the parent's pool. Its subagents share it."
            else "Own budget. Subagents share it unless you give one a sub-budget."
            "pooled" -> "Shares the pool of an ancestor agent."
            else -> "No budget. Only the daily managed-machine cap applies."
        }

    companion object {
        fun from(raw: Any?): OrbMissionBudget {
            val d = OrbJSON.dict(raw)
            val p = OrbJSON.dict(d?.get("pool"))
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
                children = OrbJSON.dictList(d?.get("children")).map {
                    Child(OrbJSON.str(it, "mission_id") ?: "", OrbJSON.str(it, "mode") ?: "pooled", OrbJSON.double(it, "budget_usd"), OrbJSON.double(it, "spent_usd") ?: 0.0)
                },
            )
        }

        fun money(v: Double): String = if (v < 10) String.format(java.util.Locale.US, "$%.2f", v) else String.format(java.util.Locale.US, "$%.0f", v)

        /** A positive dollar amount, or null. */
        fun parseAmount(raw: String): Double? = raw.trim().removePrefix("$").toDoubleOrNull()?.takeIf { it > 0 && it <= 100000 }
    }
}

private fun formatAmount(v: Double?): String = when {
    v == null -> ""
    v == Math.floor(v) -> v.toLong().toString()
    else -> v.toString()
}

/** Long-press "Mission settings…": the desktop sheet's Budget section.
 * Optimistic, with rollback and Retry on refusal. */
@Composable
fun OrbMissionSettingsDialog(core: OrbCore, missionId: String, title: String, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val path = "/api/control/missions/${core.encodeComponent(missionId)}/budget"
    var view by remember { mutableStateOf<OrbMissionBudget?>(null) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableStateOf<(() -> Unit)?>(null) }
    var busy by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }

    suspend fun load() {
        loadError = null
        runCatching { OrbMissionBudget.from(core.request(path)) }
            .onSuccess { view = it; draft = formatAmount(it.ownBudget) }
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
                .onSuccess { view = it; draft = formatAmount(it.ownBudget) }
                .onFailure {
                    view = before; draft = formatAmount(before.ownBudget)
                    saveError = it.message ?: "Budget not saved."
                    retry = { commit(amount) }
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
                        if (v.children.isNotEmpty()) {
                            Text("Subagents", color = Color.White, fontWeight = FontWeight.Medium, modifier = Modifier.padding(top = 4.dp))
                            v.children.forEach { c ->
                                Row {
                                    Text("Agent ${c.id.take(8)}", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                    Text(
                                        "${if (c.mode == "sub_budget") "Sub-budget ${OrbMissionBudget.money(c.budget ?: 0.0)}" else "Pooled"} · ${OrbMissionBudget.money(c.spent)} spent",
                                        color = OrbStyle.textSecondary, fontSize = 13.sp,
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
                saveError?.let { err ->
                    Text("Budget not saved: $err", color = OrbStyle.error, fontSize = 13.sp)
                    retry?.let { r -> TextButton(onClick = r) { Text("Retry", color = Color.White) } }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done", color = Color.White, fontWeight = FontWeight.SemiBold) } },
    )
}
