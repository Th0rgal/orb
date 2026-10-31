package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

data class OrbSoftwareComponent(
    val id: String,
    val name: String,
    val version: String?,
    val path: String?,
    val installed: Boolean,
    val owner: String,
    val updateSupported: Boolean,
    val latest: String?,
    val releaseError: String?,
    val instructions: String,
    val ready: Boolean? = null,
    val readyDetail: String? = null
)

data class OrbSoftwareJob(
    val id: String,
    val component: String,
    val version: String,
    val path: String,
    val state: String,
    val error: String?
)

data class OrbSoftwareRuntime(
    val name: String,
    val version: String,
    val build: String,
    val path: String?,
    val restartRequired: Boolean
)

data class OrbSoftwareInventory(
    val checkedAt: Double,
    val components: List<OrbSoftwareComponent>,
    val runtime: OrbSoftwareRuntime,
    val jobs: List<OrbSoftwareJob>
)

data class OrbSoftwareMachine(
    val id: String,
    val name: String,
    val online: Boolean,
    val inventory: OrbSoftwareInventory? = null,
    val error: String? = null
)

enum class OrbSoftwareStatusTone { NORMAL, ATTENTION, FAILED }

data class OrbSoftwareStatus(
    val label: String,
    val tone: OrbSoftwareStatusTone
)

/**
 * Pure fleet software inventory & readiness model mirroring `orb/src/softwareInventory.ts`
 * and `ios_dashboard/SandboxedDashboard/Orb/OrbAgentSoftware.swift`.
 */
object OrbAgentSoftware {
    fun parseInventory(d: OrbDict): OrbSoftwareInventory? {
        val checkedAt = OrbJSON.double(d, "checked_at") ?: return null
        val runtimeDict = d["runtime"] as? Map<*, *> ?: return null
        @Suppress("UNCHECKED_CAST")
        val rt = runtimeDict as OrbDict
        val runtime = OrbSoftwareRuntime(
            name = OrbJSON.str(rt, "name") ?: "Runner",
            version = OrbJSON.str(rt, "version") ?: "",
            build = OrbJSON.str(rt, "build") ?: "",
            path = OrbJSON.str(rt, "path"),
            restartRequired = OrbJSON.bool(rt, "restart_required") ?: false
        )
        val components = OrbJSON.dictList(d["components"]).mapNotNull { c ->
            val id = OrbJSON.str(c, "id") ?: return@mapNotNull null
            OrbSoftwareComponent(
                id = id,
                name = OrbJSON.str(c, "name") ?: id,
                version = OrbJSON.str(c, "version"),
                path = OrbJSON.str(c, "path"),
                installed = OrbJSON.bool(c, "installed") ?: false,
                owner = OrbJSON.str(c, "owner") ?: "External",
                updateSupported = OrbJSON.bool(c, "update_supported") ?: false,
                latest = OrbJSON.str(c, "latest"),
                releaseError = OrbJSON.str(c, "release_error"),
                instructions = OrbJSON.str(c, "instructions") ?: "",
                ready = OrbJSON.bool(c, "ready"),
                readyDetail = OrbJSON.str(c, "ready_detail")
            )
        }
        val jobs = OrbJSON.dictList(d["jobs"]).mapNotNull { j ->
            val id = OrbJSON.str(j, "id") ?: return@mapNotNull null
            OrbSoftwareJob(
                id = id,
                component = OrbJSON.str(j, "component") ?: "",
                version = OrbJSON.str(j, "version") ?: "",
                path = OrbJSON.str(j, "path") ?: "",
                state = OrbJSON.str(j, "state") ?: "",
                error = OrbJSON.str(j, "error")
            )
        }
        return OrbSoftwareInventory(
            checkedAt = checkedAt,
            components = components,
            runtime = runtime,
            jobs = jobs
        )
    }

    fun softwareVersion(raw: String?): List<Int>? {
        if (raw.isNullOrBlank()) return null
        for (token in raw.trim().split(Regex("\\s+"))) {
            val cleaned = if (token.startsWith("v")) token.substring(1) else token
            val parts = cleaned.split(".")
            if (parts.size == 3) {
                val a = parts[0].toIntOrNull()
                val b = parts[1].toIntOrNull()
                val c = parts[2].toIntOrNull()
                if (a != null && b != null && c != null) return listOf(a, b, c)
            }
        }
        return null
    }

    fun displayVersion(raw: String?): String {
        val parsed = softwareVersion(raw)
        if (parsed != null) return parsed.joinToString(".")
        return raw?.takeIf { it.isNotBlank() } ?: "—"
    }

    fun newer(latest: String?, current: String?): Boolean {
        val a = softwareVersion(latest) ?: return false
        val b = softwareVersion(current) ?: return false
        for (i in 0..2) {
            if (a[i] != b[i]) return a[i] > b[i]
        }
        return false
    }

    fun matchesSoftwareJob(job: OrbSoftwareJob, row: OrbSoftwareComponent): Boolean =
        job.component == row.id && (row.path.isNullOrEmpty() || job.path == row.path)

    fun canInstallSoftware(row: OrbSoftwareComponent): Boolean =
        !row.installed && row.updateSupported && !row.latest.isNullOrEmpty()

    fun canUpdateSoftware(row: OrbSoftwareComponent): Boolean =
        row.installed && row.updateSupported && !row.path.isNullOrEmpty() && newer(row.latest, row.version)

    fun activeJob(inventory: OrbSoftwareInventory?, row: OrbSoftwareComponent): OrbSoftwareJob? =
        inventory?.jobs?.lastOrNull { matchesSoftwareJob(it, row) }

    fun availableSoftwareUpdates(machines: List<OrbSoftwareMachine>): List<Pair<OrbSoftwareMachine, OrbSoftwareComponent>> =
        machines.flatMap { machine ->
            val inv = machine.inventory
            if (!machine.online || !machine.error.isNullOrEmpty() || inv == null) emptyList()
            else inv.components.filter { row ->
                (canUpdateSoftware(row) || canInstallSoftware(row)) &&
                    inv.jobs.none { j -> matchesSoftwareJob(j, row) && (j.state == "queued" || j.state == "installing") }
            }.map { row -> machine to row }
        }

    fun softwareAttentionSummary(machines: List<OrbSoftwareMachine>): String {
        val restarts = machines.count { it.inventory?.runtime?.restartRequired == true }
        val missing = machines.sumOf { m -> m.inventory?.components?.count { !it.installed } ?: 0 }
        val unready = machines.sumOf { m -> m.inventory?.components?.count { it.installed && it.ready == false } ?: 0 }
        val updates = machines.sumOf { m -> m.inventory?.components?.count { it.installed && newer(it.latest, it.version) } ?: 0 }
        return listOf(
            if (restarts > 0) "$restarts restart${if (restarts == 1) "" else "s"} needed" else "",
            if (missing > 0) "$missing missing" else "",
            if (unready > 0) "$unready setup needed" else "",
            if (updates > 0) "$updates update${if (updates == 1) "" else "s"}" else ""
        ).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    fun componentStatus(row: OrbSoftwareComponent, job: OrbSoftwareJob?): OrbSoftwareStatus {
        if (job?.state == "queued") return OrbSoftwareStatus("Waiting for ${row.name} sessions", OrbSoftwareStatusTone.NORMAL)
        if (job?.state == "installing") return OrbSoftwareStatus(if (row.installed) "Updating…" else "Installing…", OrbSoftwareStatusTone.NORMAL)
        if (job?.state == "failed") return OrbSoftwareStatus(if (row.installed) "Update failed" else "Install failed", OrbSoftwareStatusTone.FAILED)
        val installable = canInstallSoftware(row)
        if (!row.installed) {
            return OrbSoftwareStatus(
                if (installable) "Not installed · ${row.latest}" else "Not installed",
                if (installable) OrbSoftwareStatusTone.ATTENTION else OrbSoftwareStatusTone.NORMAL
            )
        }
        if (row.releaseError != null) return OrbSoftwareStatus("Version check unavailable", OrbSoftwareStatusTone.NORMAL)
        if (softwareVersion(row.version) == null) return OrbSoftwareStatus("Version unknown", OrbSoftwareStatusTone.NORMAL)
        if (newer(row.latest, row.version)) return OrbSoftwareStatus("→ ${row.latest}", OrbSoftwareStatusTone.ATTENTION)
        if (row.ready == false) return OrbSoftwareStatus("Setup required", OrbSoftwareStatusTone.ATTENTION)
        if (row.latest.isNullOrEmpty()) return OrbSoftwareStatus(if (row.ready == true) "Ready" else "Release unknown", OrbSoftwareStatusTone.NORMAL)
        return OrbSoftwareStatus("Up to date", OrbSoftwareStatusTone.NORMAL)
    }
}

@Composable
fun OrbAgentSoftwareBlock(
    core: OrbCore,
    fleetNodes: List<OrbRow>,
    reloadKey: Int
) {
    val scope = rememberCoroutineScope()
    var machines by remember { mutableStateOf<List<OrbSoftwareMachine>>(emptyList()) }
    var refreshing by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    var expandedMachineIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var busyKey by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }

    suspend fun refresh(force: Boolean) {
        if (refreshing) return
        refreshing = true
        try {
            val targets = buildList {
                add(OrbSoftwareMachine(id = "core", name = "Core", online = true))
                fleetNodes.forEach { node ->
                    val nodeId = node.str("id", "name") ?: node.id
                    if (nodeId.isNotBlank() && !OrbManagedMachines.isManagedNode(nodeId, OrbManagedMachines.nodeLabels(node))) {
                        val display = node.str("display_name")?.takeIf { it.isNotBlank() } ?: nodeId
                        val online = (node.str("status", "state") ?: "online") == "online"
                        add(OrbSoftwareMachine(id = nodeId, name = display, online = online))
                    }
                }
            }
            val oldMap = machines.associateBy { it.id }
            machines = coroutineScope {
                targets.map { target ->
                    async {
                        val previous = oldMap[target.id]
                        if (!target.online) {
                            target.copy(inventory = previous?.inventory, error = "Offline")
                        } else {
                            val suffix = if (target.id == "core") "" else "&node=${core.encodeComponent(target.id)}"
                            try {
                                val raw = core.fetchDict("/api/software?force=${if (force) "true" else "false"}$suffix")
                                val inv = OrbAgentSoftware.parseInventory(raw) ?: throw IllegalStateException("Invalid inventory")
                                target.copy(inventory = inv, error = null)
                            } catch (_: Throwable) {
                                target.copy(inventory = previous?.inventory, error = "Inventory unavailable")
                            }
                        }
                    }
                }.awaitAll()
            }
        } finally {
            refreshing = false
        }
    }

    LaunchedEffect(reloadKey, fleetNodes.size) {
        refresh(force = false)
    }

    val summary = remember(machines) { OrbAgentSoftware.softwareAttentionSummary(machines) }
    val actions = remember(machines) { OrbAgentSoftware.availableSoftwareUpdates(machines) }
    val hasInstalls = remember(actions) { actions.any { !it.second.installed } }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "AGENT SOFTWARE",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.7.sp
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .orbPressClickable { expanded = !expanded }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "Versions and readiness",
                    color = Color.White,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = if (summary.isNotEmpty()) summary else if (machines.isEmpty()) (if (refreshing) "Checking…" else "") else "All ready",
                    color = if (summary.isNotEmpty()) OrbStyle.warning else OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(18.dp)
                )
            }

            if (expanded) {
                HorizontalDivider(color = OrbStyle.border)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    actionError?.let { err ->
                        Text(text = err, color = OrbStyle.warning, fontSize = 12.sp)
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (actions.isNotEmpty()) {
                            SoftwarePillButton(
                                label = if (busyKey == "__all__") "Queuing…" else if (hasInstalls) "Install & update all" else "Update all",
                                enabled = busyKey == null && !refreshing
                            ) {
                                busyKey = "__all__"
                                actionError = null
                                scope.launch {
                                    val failures = mutableListOf<String>()
                                    for ((m, r) in actions) {
                                        val latest = r.latest ?: continue
                                        val suffix = if (m.id == "core") "" else "?node=${core.encodeComponent(m.id)}"
                                        try {
                                            core.request(
                                                "/api/software/updates$suffix",
                                                method = "POST",
                                                body = mapOf("component" to r.id, "version" to latest, "path" to (r.path ?: ""))
                                            )
                                        } catch (_: Throwable) {
                                            failures.add("${m.name} · ${r.name}")
                                        }
                                    }
                                    refresh(force = false)
                                    if (failures.isNotEmpty()) {
                                        actionError = "Could not queue: ${failures.joinToString(", ")}"
                                    }
                                    busyKey = null
                                }
                            }
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        SoftwarePillButton(
                            label = if (refreshing) "Checking…" else "Check versions",
                            enabled = !refreshing && busyKey == null
                        ) {
                            scope.launch { refresh(force = true) }
                        }
                    }

                    if (machines.isEmpty() && refreshing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = OrbStyle.textSecondary
                        )
                    }

                    machines.forEachIndexed { idx, machine ->
                        val isMachineOpen = expandedMachineIds.contains(machine.id)
                        val machineSummary = OrbAgentSoftware.softwareAttentionSummary(listOf(machine))
                        val subtitle = when {
                            !machine.error.isNullOrEmpty() -> machine.error
                            !machine.online -> "Offline"
                            machine.inventory == null -> "Checking…"
                            machineSummary.isNotEmpty() -> machineSummary
                            else -> "${machine.inventory.components.count { it.installed }}/${machine.inventory.components.size} ready"
                        }
                        val needsAttention = machineSummary.isNotEmpty()

                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable {
                                        expandedMachineIds =
                                            if (isMachineOpen) expandedMachineIds - machine.id else expandedMachineIds + machine.id
                                    },
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = machine.name,
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.weight(1f)
                                )
                                Text(
                                    text = subtitle,
                                    color = if (needsAttention) OrbStyle.warning else OrbStyle.textSecondary,
                                    fontSize = 12.sp
                                )
                                Spacer(modifier = Modifier.size(6.dp))
                                Icon(
                                    imageVector = if (isMachineOpen) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                                    contentDescription = null,
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(16.dp)
                                )
                            }

                            if (isMachineOpen && machine.inventory != null) {
                                val inv = machine.inventory
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(start = 8.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    inv.components.forEach { row ->
                                        val job = OrbAgentSoftware.activeJob(inv, row)
                                        val pending = job?.state == "queued" || job?.state == "installing"
                                        val status = OrbAgentSoftware.componentStatus(row, job)
                                        val actionable = !pending && (OrbAgentSoftware.canInstallSoftware(row) || OrbAgentSoftware.canUpdateSoftware(row))
                                        val rowKey = "${machine.id}:${row.id}"
                                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                                            ) {
                                                Text(row.name, color = Color.White, fontSize = 13.sp)
                                                Text(
                                                    OrbAgentSoftware.displayVersion(row.version),
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 12.sp,
                                                    fontFamily = FontFamily.Monospace
                                                )
                                                Spacer(modifier = Modifier.weight(1f))
                                                Text(
                                                    text = status.label,
                                                    color = when (status.tone) {
                                                        OrbSoftwareStatusTone.FAILED -> OrbStyle.error
                                                        OrbSoftwareStatusTone.ATTENTION -> OrbStyle.warning
                                                        OrbSoftwareStatusTone.NORMAL -> OrbStyle.textSecondary
                                                    },
                                                    fontSize = 12.sp
                                                )
                                            }
                                            if (!row.readyDetail.isNullOrEmpty() && (!row.installed || row.ready == false)) {
                                                Text(row.readyDetail, color = OrbStyle.textSecondary, fontSize = 11.sp)
                                            }
                                            if (!job?.error.isNullOrEmpty()) {
                                                Text(job!!.error!!, color = OrbStyle.error, fontSize = 11.sp)
                                            }
                                            if (machine.online && machine.error.isNullOrEmpty() && (job?.state == "queued" || actionable)) {
                                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                    if (job?.state == "queued") {
                                                        SoftwarePillButton(
                                                            label = "Cancel",
                                                            enabled = busyKey == null
                                                        ) {
                                                            busyKey = rowKey
                                                            actionError = null
                                                            scope.launch {
                                                                val suffix = if (machine.id == "core") "" else "?node=${core.encodeComponent(machine.id)}"
                                                                try {
                                                                    core.request(
                                                                        "/api/software/updates/cancel$suffix",
                                                                        method = "POST",
                                                                        body = mapOf("id" to job.id)
                                                                    )
                                                                    refresh(force = false)
                                                                } catch (e: Throwable) {
                                                                    actionError = e.message
                                                                } finally {
                                                                    busyKey = null
                                                                }
                                                            }
                                                        }
                                                    }
                                                    if (actionable) {
                                                        SoftwarePillButton(
                                                            label = if (busyKey == rowKey) "Queuing…" else if (job?.state == "failed") "Retry" else if (row.installed) "Update" else "Install",
                                                            enabled = busyKey == null
                                                        ) {
                                                            val latest = row.latest ?: return@SoftwarePillButton
                                                            busyKey = rowKey
                                                            actionError = null
                                                            scope.launch {
                                                                val suffix = if (machine.id == "core") "" else "?node=${core.encodeComponent(machine.id)}"
                                                                try {
                                                                    core.request(
                                                                        "/api/software/updates$suffix",
                                                                        method = "POST",
                                                                        body = mapOf(
                                                                            "component" to row.id,
                                                                            "version" to latest,
                                                                            "path" to (row.path ?: "")
                                                                        )
                                                                    )
                                                                    refresh(force = false)
                                                                } catch (e: Throwable) {
                                                                    actionError = e.message
                                                                } finally {
                                                                    busyKey = null
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    OrbKeyValueLine(
                                        inv.runtime.name,
                                        if (inv.runtime.restartRequired) "Restart required" else inv.runtime.version
                                    )
                                }
                            }
                        }
                        if (idx < machines.lastIndex) {
                            Spacer(modifier = Modifier.height(2.dp))
                            HorizontalDivider(color = OrbStyle.border)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SoftwarePillButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable(enabled = enabled) { onClick() }
            .padding(horizontal = 12.dp, vertical = 5.dp)
    ) {
        Text(
            text = label,
            color = if (enabled) OrbStyle.inboxBlue else OrbStyle.textMuted,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            softWrap = false
        )
    }
}
