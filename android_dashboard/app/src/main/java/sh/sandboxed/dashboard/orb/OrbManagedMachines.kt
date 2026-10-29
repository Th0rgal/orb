package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * "Managed (boat.dev)" section of the Machines page: list, budget, Destroy and
 * +1 h Extend. No spawn UI on mobile. Renders nothing when the backend lacks
 * the endpoint (404/405) or has the feature disabled.
 * `reloadKey` changes whenever the page pulls to refresh.
 */
@Composable
fun OrbManagedMachinesBlock(
    core: OrbCore,
    reloadKey: Int,
    onActiveChanged: (Boolean) -> Unit = {}
) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<ManagedMachinesResponse?>(null) }
    var fetchedAt by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<ManagedMachine?>(null) }
    var details by remember { mutableStateOf<ManagedMachine?>(null) }
    var creating by remember { mutableStateOf(false) }
    var showRecent by remember { mutableStateOf(false) }

    suspend fun refresh() {
        try {
            data = OrbManagedMachines.parse(core.fetchDict(OrbManagedMachines.PATH))
            fetchedAt = System.currentTimeMillis()
            loadError = null
        } catch (e: OrbError) {
            if (OrbManagedMachines.isUnsupported(e.status)) data = null
            else loadError = OrbManagedMachines.errorMessage(e)
        } catch (e: Throwable) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            loadError = OrbManagedMachines.errorMessage(e)
        }
    }

    LaunchedEffect(reloadKey) {
        while (isActive) {
            refresh()
            delay(15_000)
        }
    }
    LaunchedEffect(Unit) {
        while (isActive) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }

    fun run(m: ManagedMachine, action: suspend () -> Any?, onDone: () -> Unit = {}) {
        if (busyId != null) return
        busyId = m.id
        actionError = null
        scope.launch {
            try {
                val updated = OrbJSON.dict(action())?.let { OrbManagedMachines.parseMachine(it) }
                if (updated != null) {
                    data = data?.let { d -> d.copy(machines = listOf(updated) + d.machines.filter { it.id != updated.id }) }
                    fetchedAt = System.currentTimeMillis()
                }
                onDone()
                refresh()
            } catch (e: Throwable) {
                actionError = OrbManagedMachines.errorMessage(e)
            } finally {
                busyId = null
            }
        }
    }

    // Optimistic: the row reads "Destroying…" at once; a failure restores it and shows the error.
    fun destroy(m: ManagedMachine) {
        if (busyId != null) return
        busyId = m.id
        actionError = null
        confirm = null
        data = data?.let { it.copy(machines = OrbManagedMachines.markDestroying(it.machines, m.id)) }
        scope.launch {
            try {
                val updated = OrbJSON.dict(
                    core.request("${OrbManagedMachines.PATH}/${core.encodeComponent(m.id)}", method = "DELETE")
                )?.let { OrbManagedMachines.parseMachine(it) }
                if (updated != null) {
                    data = data?.let { d -> d.copy(machines = listOf(updated) + d.machines.filter { it.id != updated.id }) }
                    fetchedAt = System.currentTimeMillis()
                }
                refresh()
            } catch (e: Throwable) {
                data = data?.let { it.copy(machines = OrbManagedMachines.revert(it.machines, m)) }
                actionError = "Couldn’t destroy ${OrbManagedMachines.title(m)}. ${OrbManagedMachines.errorMessage(e)}"
            } finally {
                busyId = null
            }
        }
    }

    val isActiveManaged = data?.enabled == true
    LaunchedEffect(isActiveManaged) { onActiveChanged(isActiveManaged) }
    val d = data ?: return
    if (!d.enabled) return
    val live = d.machines.filter { OrbManagedMachines.isLive(it) }
    val stopped = d.machines.filter { OrbManagedMachines.isStopped(it) }
    val recent = OrbManagedMachines.recentMachines(d.machines, now)

    // Mission titles for owner chips, fetched once per id.
    val missionIds = (d.machines.mapNotNull { it.ownerMissionId } + d.dailySpend.orEmpty().flatMap { day -> day.missions.mapNotNull { it.first } }).toSet()
    LaunchedEffect(missionIds) {
        for (id in missionIds) {
            if (ManagedMissionTitles.cache.containsKey(id)) continue
            ManagedMissionTitles.cache[id] = try {
                OrbManagedMachines.missionTitle(core.fetchDict("/api/control/missions/${core.encodeComponent(id)}"))
            } catch (e: Throwable) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                null
            }
        }
    }

    fun extend(m: ManagedMachine) = run(m, {
        core.request(
            "${OrbManagedMachines.PATH}/${core.encodeComponent(m.id)}/extend",
            method = "POST",
            body = mapOf("ttl_minutes" to OrbManagedMachines.EXTEND_MINUTES)
        )
    })

    fun stop(m: ManagedMachine) = run(m, {
        core.request("${OrbManagedMachines.PATH}/${core.encodeComponent(m.id)}/stop", method = "POST", body = emptyMap<String, Any>())
    })

    fun resume(m: ManagedMachine) = run(m, {
        core.request("${OrbManagedMachines.PATH}/${core.encodeComponent(m.id)}/resume", method = "POST", body = emptyMap<String, Any>())
    })

    fun create(provider: String?, size: String, ttlMinutes: Int, allow24h: Boolean) {
        if (busyId != null) return
        busyId = "create"
        creating = false
        actionError = null
        scope.launch {
            try {
                val body = mutableMapOf<String, Any>("size" to size, "ttl_minutes" to ttlMinutes, "wait" to false)
                if (!provider.isNullOrEmpty() && provider != "boat") body["provider"] = provider
                if (allow24h) body["allow_24h_commitment"] = true
                val updated = OrbJSON.dict(core.request(OrbManagedMachines.PATH, method = "POST", body = body))
                    ?.let { OrbManagedMachines.parseMachine(it) }
                if (updated != null) {
                    data = data?.let { cur -> cur.copy(machines = listOf(updated) + cur.machines.filter { it.id != updated.id }) }
                    fetchedAt = System.currentTimeMillis()
                }
                refresh()
            } catch (e: Throwable) {
                actionError = OrbManagedMachines.errorMessage(e)
            } finally {
                busyId = null
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = OrbManagedMachines.sectionTitle(d.providers, d.machines).uppercase(java.util.Locale.US),
                color = OrbStyle.textMuted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.7.sp,
                modifier = Modifier.weight(1f)
            )
            ManagedPill(
                label = "+ New",
                tint = OrbStyle.inboxBlue,
                busy = busyId != null || OrbManagedMachines.budgetFull(d.budget),
                onClick = { if (!OrbManagedMachines.budgetFull(d.budget)) creating = true }
            )
        }
        val spend = d.dailySpend
        if (spend != null) ManagedSpendChart(spend, d.budget, ManagedMissionTitles.cache)
        else Text(
            text = OrbManagedMachines.budgetLine(d.budget),
            color = OrbStyle.textSecondary,
            fontSize = 12.sp
        )
        loadError?.let { Text("Couldn’t refresh managed machines. $it", color = OrbStyle.warning, fontSize = 12.sp) }
        if (confirm == null) actionError?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }

        ManagedCard {
            if (live.isEmpty()) {
                Text(
                    text = "No managed machines running.",
                    color = OrbStyle.textMuted,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 13.dp)
                )
            }
            live.forEachIndexed { idx, m ->
                ManagedMachineRow(
                    m = m,
                    fetchedAt = fetchedAt,
                    now = now,
                    busy = busyId == m.id,
                    muted = false,
                    canStop = OrbManagedMachines.canStop(m, d.providers),
                    onExtend = { extend(m) },
                    onStop = { stop(m) },
                    onResume = {},
                    onDestroy = { actionError = null; confirm = m },
                    onDetails = { details = m }
                )
                if (idx < live.lastIndex) {
                    HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                }
            }
        }

        if (stopped.isNotEmpty()) {
            Text("Stopped · disk kept, nothing billed, resumable for 24 h", color = OrbStyle.textMuted, fontSize = 12.sp)
            ManagedCard {
                stopped.forEachIndexed { idx, m ->
                    ManagedMachineRow(
                        m = m,
                        fetchedAt = fetchedAt,
                        now = now,
                        busy = busyId == m.id,
                        muted = false,
                        canStop = false,
                        onExtend = {},
                        onStop = {},
                        onResume = { resume(m) },
                        onDestroy = { actionError = null; confirm = m },
                        onDetails = { details = m }
                    )
                    if (idx < stopped.lastIndex) {
                        HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                    }
                }
            }
        }

        if (recent.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .orbPressClickable { showRecent = !showRecent }
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = if (showRecent) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(16.dp)
                )
                Text("Recent · last 24 h (${recent.size})", color = OrbStyle.textMuted, fontSize = 12.sp)
            }
            if (showRecent) {
                ManagedCard {
                    recent.forEachIndexed { idx, m ->
                        ManagedMachineRow(
                            m = m, fetchedAt = fetchedAt, now = now, busy = false, muted = true,
                            canStop = false, onExtend = {}, onStop = {}, onResume = {}, onDestroy = {}, onDetails = { details = m }
                        )
                        if (idx < recent.lastIndex) {
                            HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                        }
                    }
                }
            }
        }
    }

    if (creating) {
        ManagedNewMachineDialog(
            response = d,
            onDismiss = { creating = false },
            onCreate = { prov, sz, ttl, allow24h -> create(prov, sz, ttl, allow24h) }
        )
    }

    details?.let { m ->
        AlertDialog(
            onDismissRequest = { details = null },
            title = { Text(OrbManagedMachines.title(m)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    OrbKeyValueLine("Provider", OrbManagedMachines.providerLabel(m.provider))
                    OrbKeyValueLine("Size", OrbManagedMachines.sizeLabel(m.size))
                    OrbKeyValueLine("State", OrbManagedMachines.stateLabel(m.state))
                    OrbKeyValueLine("Node", m.nodeId)
                    m.project?.let { OrbKeyValueLine("Project", it) }
                    m.ownerMissionId?.let { OrbKeyValueLine("Mission", it.take(8)) }
                    m.reason?.let { Text("Reason: $it", color = OrbStyle.textSecondary, fontSize = 13.sp) }
                    m.error?.let { Text("Error: $it", color = OrbStyle.warning, fontSize = 13.sp) }
                    m.destroyReason?.let { Text("Destroyed: $it", color = OrbStyle.textSecondary, fontSize = 13.sp) }
                }
            },
            confirmButton = { TextButton(onClick = { details = null }) { Text("Close") } }
        )
    }

    confirm?.let { m ->
        val busy = busyId == m.id
        val owner = m.ownerMissionId?.let {
            ", and mission ${OrbManagedMachines.missionChip(it, ManagedMissionTitles.cache[it])} loses it"
        } ?: ""
        AlertDialog(
            onDismissRequest = { if (!busy) { confirm = null; actionError = null } },
            title = { Text("Destroy ${OrbManagedMachines.title(m)}?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "The machine and everything on it are deleted now$owner. " +
                            "Cost so far: ${OrbManagedMachines.usd(OrbManagedMachines.liveCost(m, fetchedAt, now))}."
                    )
                    actionError?.let { Text(it, color = OrbStyle.warning, fontSize = 13.sp) }
                }
            },
            confirmButton = {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(onClick = { destroy(m) }) { Text("Destroy", color = OrbStyle.error) }
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { confirm = null; actionError = null }) { Text("Cancel") }
            }
        )
    }
}

/**
 * Spend over the last days: one Canvas bar per UTC day, the window total,
 * today and the running count. Tap a bar to read its total and top missions in
 * the caption (tap again to clear); the caption has a fixed height so nothing
 * moves. `days == null` draws a same-size skeleton.
 */
@Composable
internal fun ManagedSpendChart(days: List<DailySpend>?, budget: ManagedBudget, titles: Map<String, String?>) {
    var picked by remember { mutableStateOf<Int?>(null) }
    val list = days.orEmpty()
    val sum = OrbManagedMachines.spendSummary(list)
    val count = if (days == null) 7 else list.size
    val bar = OrbStyle.inboxBlue
    val skeleton = OrbStyle.elevated
    ManagedCard {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth().height(18.dp), verticalAlignment = Alignment.CenterVertically) {
                if (days == null) {
                    Box(Modifier.size(110.dp, 10.dp).clip(RoundedCornerShape(4.dp)).background(skeleton).orbShimmer())
                    Spacer(Modifier.weight(1f))
                    Box(Modifier.size(70.dp, 10.dp).clip(RoundedCornerShape(4.dp)).background(skeleton).orbShimmer())
                } else {
                    Text(OrbManagedMachines.usd(sum.total), color = OrbStyle.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text("  last $count days", color = OrbStyle.textSecondary, fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text(OrbManagedMachines.runningLine(budget), color = OrbStyle.textSecondary, fontSize = 12.sp)
                }
            }
            Canvas(
                Modifier.fillMaxWidth().height(44.dp).testTag("managed.spend.bars").pointerInput(list) {
                    detectTapGestures { o ->
                        if (list.isEmpty()) return@detectTapGestures
                        val i = (o.x / (size.width / list.size)).toInt().coerceIn(0, list.size - 1)
                        picked = if (picked == i) null else i
                    }
                }
            ) {
                val slot = size.width / count
                val gap = 6.dp.toPx()
                for (i in 0 until count) {
                    val frac = if (days == null) (if (i % 2 == 0) 0.4 else 0.65) else OrbManagedMachines.spendFraction(list[i].usd, sum.max)
                    val h = (size.height * frac).toFloat()
                    if (h > 0f) {
                        val color = when {
                            days == null -> skeleton
                            picked == i -> bar
                            i == count - 1 -> bar.copy(alpha = 0.9f)
                            else -> bar.copy(alpha = 0.5f)
                        }
                        drawRoundRect(color, topLeft = Offset(i * slot + gap / 2, size.height - h), size = Size(slot - gap, h), cornerRadius = CornerRadius(3.dp.toPx()))
                    }
                }
                drawLine(Color.White.copy(alpha = 0.14f), Offset(0f, size.height - 0.5f), Offset(size.width, size.height - 0.5f), strokeWidth = 1.dp.toPx())
            }
            Row(Modifier.fillMaxWidth()) {
                for (i in 0 until count) {
                    Text(
                        if (days == null) "" else OrbManagedMachines.spendWeekday(list[i].day),
                        modifier = Modifier.weight(1f).height(14.dp),
                        color = if (picked == i || i == count - 1) OrbStyle.textSecondary else OrbStyle.textMuted,
                        fontSize = 10.sp, textAlign = TextAlign.Center, maxLines = 1
                    )
                }
            }
            val caption = when {
                days == null -> ""
                picked != null && picked!! < list.size -> OrbManagedMachines.spendDayDetail(list[picked!!], titles)
                else -> OrbManagedMachines.spendTodayLine(sum.today, budget)
            }
            Text(caption, modifier = Modifier.fillMaxWidth().height(16.dp).testTag("managed.spend.caption"),
                color = OrbStyle.textSecondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Mission titles shared across recompositions and page visits. */
private object ManagedMissionTitles {
    val cache = mutableStateMapOf<String, String?>()
}

@Composable
private fun ManagedCard(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
    ) { content() }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ManagedMachineRow(
    m: ManagedMachine,
    fetchedAt: Long,
    now: Long,
    busy: Boolean,
    muted: Boolean,
    canStop: Boolean,
    onExtend: () -> Unit,
    onStop: () -> Unit,
    onResume: () -> Unit,
    onDestroy: () -> Unit,
    onDetails: () -> Unit
) {
    val dot = when (m.state) {
        "online" -> OrbStyle.success
        "failed" -> OrbStyle.error
        "destroyed" -> OrbStyle.textMuted
        else -> OrbStyle.warning
    }
    val primary = if (muted) OrbStyle.textSecondary else Color.White
    val secondary = if (muted) OrbStyle.textMuted else OrbStyle.textSecondary
    val live = OrbManagedMachines.isLive(m)
    val stopped = OrbManagedMachines.isStopped(m)
    val actionable = !muted && OrbManagedMachines.canAct(m)
    val resumable = !muted && OrbManagedMachines.canResume(m, busy)
    val fontScale = LocalDensity.current.fontScale

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onDetails, onLongClick = onDetails)
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        val compact = maxWidth < 340.dp || fontScale > 1.3f
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                // Line 1: dot · name · provider · size · status.
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(modifier = Modifier.size(7.dp).clip(CircleShape).background(dot))
                    Text(
                        OrbManagedMachines.title(m),
                        color = primary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (!m.provider.isNullOrEmpty() && m.provider != "boat") {
                        Text(
                            OrbManagedMachines.providerLabel(m.provider),
                            color = OrbStyle.inboxBlue, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false
                        )
                    }
                    Text(
                        OrbManagedMachines.sizeLabel(m.size),
                        color = secondary, fontSize = 12.sp, maxLines = 1, softWrap = false
                    )
                    Text(
                        OrbManagedMachines.stateLabel(m.state),
                        color = secondary, fontSize = 12.sp, maxLines = 1, softWrap = false
                    )
                }
                // Line 2: specs.
                Text(
                    OrbManagedMachines.specLine(m),
                    color = secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                // Line 3: TTL (with remaining-time bar) and cost.
                if (live) {
                    val urgent = OrbManagedMachines.ttlUrgent(m.expiresAt, now)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OrbManagedMachines.ttlFraction(m, now)?.let { f ->
                            LinearProgressIndicator(
                                progress = { f },
                                modifier = Modifier.width(28.dp).height(3.dp).clip(CircleShape),
                                color = if (urgent) OrbStyle.warning else OrbStyle.textSecondary,
                                trackColor = OrbStyle.border,
                                drawStopIndicator = {}
                            )
                        }
                        Text(
                            OrbManagedMachines.ttlShort(m.expiresAt, now),
                            color = if (urgent) OrbStyle.warning else secondary,
                            fontSize = 12.sp, maxLines = 1, softWrap = false
                        )
                        Text("·", color = OrbStyle.textMuted, fontSize = 12.sp)
                        Text(
                            OrbManagedMachines.costLine(m, fetchedAt, now),
                            color = secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                    }
                } else {
                    Text(OrbManagedMachines.finalCostLine(m), color = secondary, fontSize = 12.sp, maxLines = 1)
                }
                OrbManagedMachines.reapLine(m, now)?.let {
                    Text(it, color = OrbStyle.warning, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (OrbManagedMachines.isLive(m)) when (OrbManagedMachines.owner(m)) {
                    is OrbManagedMachines.Owner.User -> Text("You", color = secondary, fontSize = 11.sp, maxLines = 1)
                    is OrbManagedMachines.Owner.None -> {
                        Text("No owner", color = OrbStyle.warning, fontSize = 11.sp, maxLines = 1)
                        m.reason?.takeIf { it.isNotBlank() }?.let {
                            Text(it, color = secondary, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    is OrbManagedMachines.Owner.Mission -> {}
                }
                m.ownerMissionId?.let { id ->
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .padding(horizontal = 8.dp, vertical = 2.dp)
                    ) {
                        Text(
                            OrbManagedMachines.missionChip(id, ManagedMissionTitles.cache[id]),
                            color = secondary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            if (stopped && !muted) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (resumable) ManagedPill("Resume", OrbStyle.inboxBlue, busy, onResume)
                    ManagedPill("Destroy", OrbStyle.error.copy(alpha = 0.85f), busy, onDestroy, quiet = true)
                }
            } else if (actionable) {
                if (compact) {
                    var open by remember { mutableStateOf(false) }
                    Box {
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape)
                                .orbPressClickable { if (!busy) open = true },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Default.MoreVert, contentDescription = "Actions", tint = secondary, modifier = Modifier.size(18.dp))
                        }
                        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                            DropdownMenuItem(text = { Text("Extend +1 h") }, onClick = { open = false; onExtend() })
                            if (canStop) DropdownMenuItem(text = { Text("Stop") }, onClick = { open = false; onStop() })
                            DropdownMenuItem(text = { Text("Destroy", color = OrbStyle.error) }, onClick = { open = false; onDestroy() })
                        }
                    }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        ManagedPill("+1 h", OrbStyle.inboxBlue, busy, onExtend)
                        if (canStop) ManagedPill("Stop", OrbStyle.textSecondary, busy, onStop, quiet = true)
                        ManagedPill("Destroy", OrbStyle.error.copy(alpha = 0.85f), busy, onDestroy, quiet = true)
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagedNewMachineDialog(
    response: ManagedMachinesResponse,
    onDismiss: () -> Unit,
    onCreate: (provider: String?, size: String, ttlMinutes: Int, allow24h: Boolean) -> Unit
) {
    val configured = response.providers.filter { it.configured }
    val initProv = configured.firstOrNull { it.provider == "boat" }?.provider ?: configured.firstOrNull()?.provider ?: "boat"
    var provider by remember { mutableStateOf(initProv) }
    val sizes = configured.firstOrNull { it.provider == provider }?.sizes?.takeIf { it.isNotEmpty() } ?: response.sizes
    var size by remember(provider) {
        mutableStateOf(sizes.firstOrNull { it.size == response.budget.defaultSize }?.size ?: sizes.firstOrNull()?.size ?: "small")
    }
    val ttlChoices = OrbManagedMachines.ttlChoices(response.budget.defaultTtlMinutes, response.budget.maxTtlMinutes)
    var ttl by remember { mutableStateOf(ttlChoices.firstOrNull { it == response.budget.defaultTtlMinutes } ?: ttlChoices.firstOrNull() ?: 60) }
    var allow24h by remember(provider, size) { mutableStateOf(false) }
    val chosen = sizes.firstOrNull { it.size == size }
    val requires24h = (chosen?.minBillingHours ?: 0) >= 24
    val effectiveMinutes = maxOf(ttl, (chosen?.minBillingHours ?: 0) * 60)
    val estimate = (chosen?.usdPerHour ?: 0.0) * effectiveMinutes / 60.0

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New managed machine") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (configured.size > 1) {
                    Text("Provider", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        configured.forEach { pr ->
                            ManagedPill(
                                label = pr.displayName,
                                tint = if (pr.provider == provider) OrbStyle.inboxBlue else OrbStyle.textSecondary,
                                busy = false,
                                quiet = pr.provider != provider,
                                onClick = { provider = pr.provider }
                            )
                        }
                    }
                }
                Text("Size", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                sizes.forEach { s ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .border(1.dp, if (s.size == size) OrbStyle.inboxBlue else OrbStyle.border, RoundedCornerShape(10.dp))
                            .orbPressClickable { size = s.size }
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(OrbManagedMachines.sizeLabel(s.size), color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                            Text("${s.cpu} vCPU · ${s.ramGb.toInt()} GB" + (s.gpu?.let { " · $it" } ?: ""), color = OrbStyle.textSecondary, fontSize = 11.sp)
                        }
                        Text(OrbManagedMachines.usdPerHour(s.usdPerHour), color = OrbStyle.textSecondary, fontSize = 12.sp)
                    }
                }
                Text("TTL", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ttlChoices.take(4).forEach { m ->
                        ManagedPill(
                            label = OrbManagedMachines.minutesLabel(m),
                            tint = if (m == ttl) OrbStyle.inboxBlue else OrbStyle.textSecondary,
                            busy = false,
                            quiet = m != ttl,
                            onClick = { ttl = m }
                        )
                    }
                }
                if (requires24h) {
                    Row(
                        modifier = Modifier.orbPressClickable { allow24h = !allow24h },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(if (allow24h) "[x]" else "[ ]", color = OrbStyle.warning, fontSize = 13.sp)
                        Text("Confirm ${chosen?.minBillingHours}h minimum lease (${OrbManagedMachines.usd(estimate)})", color = OrbStyle.warning, fontSize = 12.sp)
                    }
                }
                OrbKeyValueLine("Estimated cost", OrbManagedMachines.usd(estimate))
            }
        },
        confirmButton = {
            TextButton(
                enabled = chosen != null && (!requires24h || allow24h),
                onClick = { onCreate(if (provider == "boat") null else provider, size, ttl, requires24h && allow24h) }
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun ManagedPill(label: String, tint: Color, busy: Boolean, onClick: () -> Unit, quiet: Boolean = false) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (quiet) Color.Transparent else OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .alpha(if (busy) 0.5f else 1f)
            .orbPressClickable { if (!busy) onClick() }
            .padding(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Text(label, color = tint, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false)
    }
}

/** Small "Managed" chip for fleet rows provisioned by the managed-machine service. */
@Composable
fun OrbManagedBadge() {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(OrbStyle.inboxBlue.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 2.dp)
    ) {
        Text("Managed", color = OrbStyle.inboxBlue, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}
