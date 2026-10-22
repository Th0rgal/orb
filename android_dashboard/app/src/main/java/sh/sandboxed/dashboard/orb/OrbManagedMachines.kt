package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
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
fun OrbManagedMachinesBlock(core: OrbCore, reloadKey: Int) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<ManagedMachinesResponse?>(null) }
    var fetchedAt by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<ManagedMachine?>(null) }

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

    val d = data ?: return
    if (!d.enabled) return
    val live = d.machines.filter { OrbManagedMachines.isLive(it) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "MANAGED (BOAT.DEV)",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.7.sp
        )
        Text(
            text = OrbManagedMachines.budgetLine(d.budget),
            color = OrbStyle.textSecondary,
            fontSize = 12.sp
        )
        loadError?.let { Text("Couldn’t refresh managed machines. $it", color = OrbStyle.warning, fontSize = 12.sp) }
        if (confirm == null) actionError?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
        ) {
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
                    onExtend = {
                        run(m, {
                            core.request(
                                "${OrbManagedMachines.PATH}/${core.encodeComponent(m.id)}/extend",
                                method = "POST",
                                body = mapOf("ttl_minutes" to OrbManagedMachines.EXTEND_MINUTES)
                            )
                        })
                    },
                    onDestroy = { actionError = null; confirm = m }
                )
                if (idx < live.lastIndex) {
                    HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                }
            }
        }
    }

    confirm?.let { m ->
        val busy = busyId == m.id
        val owner = m.ownerMissionId?.let { ", and mission ${it.take(8)} loses it" } ?: ""
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

@Composable
private fun ManagedMachineRow(
    m: ManagedMachine,
    fetchedAt: Long,
    now: Long,
    busy: Boolean,
    onExtend: () -> Unit,
    onDestroy: () -> Unit
) {
    val dot = when (m.state) {
        "online" -> OrbStyle.success
        "failed" -> OrbStyle.error
        else -> OrbStyle.warning
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(modifier = Modifier.size(7.dp).clip(CircleShape).background(dot))
            Text(OrbManagedMachines.title(m), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(OrbManagedMachines.stateLabel(m.state), color = OrbStyle.textSecondary, fontSize = 12.sp)
        }
        Text(
            text = "${m.size} · ${OrbManagedMachines.sizeSpec(m)}",
            color = OrbStyle.textSecondary,
            fontSize = 12.sp
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = "${OrbManagedMachines.ttlLeft(m.expiresAt, now)} left",
                color = if (OrbManagedMachines.ttlUrgent(m.expiresAt, now)) OrbStyle.warning else OrbStyle.textSecondary,
                fontSize = 12.sp
            )
            Text("·", color = OrbStyle.textMuted, fontSize = 12.sp)
            Text(
                text = "${OrbManagedMachines.usd(OrbManagedMachines.liveCost(m, fetchedAt, now))} · " +
                    OrbManagedMachines.usdPerHour(m.usdPerHour),
                color = OrbStyle.textSecondary,
                fontSize = 12.sp
            )
        }
        (m.error ?: m.reason)?.let {
            Text(it, color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (OrbManagedMachines.canAct(m)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ManagedPill("+1 h", OrbStyle.inboxBlue, busy, onExtend)
                ManagedPill("Destroy", OrbStyle.error, busy, onDestroy)
            }
        }
    }
}

@Composable
private fun ManagedPill(label: String, tint: Color, busy: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .alpha(if (busy) 0.5f else 1f)
            .orbPressClickable { if (!busy) onClick() }
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Text(label, color = tint, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false)
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
