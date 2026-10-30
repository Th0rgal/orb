package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** Orb desktop computers linked to this account (`/api/control/client-computers`). */
suspend fun loadClientComputers(core: OrbCore): List<OrbRow> {
    val obj = core.fetchDict("/api/control/client-computers")
    return OrbJSON.dictList(obj["computers"]).map { OrbRow(it, it["client_id"]?.toString() ?: "") }
}

/**
 * The "Computers" block of Machines: each online computer can be asked to
 * start a mission, which runs there with its local agents and streams back.
 */
@Composable
fun OrbComputersBlock(core: OrbCore, computers: List<OrbRow>, ready: Boolean) {
    var starting by remember { mutableStateOf<OrbRow?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = "COMPUTERS",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.7.sp
        )
        if (ready && computers.isEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(text = "No Mac connected", color = OrbStyle.textSecondary, fontSize = 14.sp)
                Text(text = "Open Orb on Mac", color = OrbStyle.textMuted, fontSize = 12.sp)
            }
        }
        if (computers.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
            ) {
                computers.forEach { computer ->
                    val online = computer.bool("online") == true
                    val name = computer.str("name")?.takeIf { it.isNotBlank() } ?: "Computer"
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 13.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(if (online) OrbStyle.success else OrbStyle.textMuted)
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(text = name, color = OrbStyle.textPrimary, fontSize = 15.sp)
                            Text(
                                text = if (online) "Online" else "Offline · missions paused",
                                color = OrbStyle.textSecondary,
                                fontSize = 12.sp
                            )
                        }
                        if (online) {
                            TextButton(
                                onClick = { starting = computer },
                                modifier = Modifier.semantics { contentDescription = "Start a mission on $name" }
                            ) { Text("Start") }
                        }
                    }
                }
            }
            Text(
                text = "Missions started here run on that computer with its local agents.",
                color = OrbStyle.textMuted,
                fontSize = 12.sp
            )
        }
    }
    starting?.let { computer ->
        OrbRemoteStartDialog(core = core, computer = computer, onDismiss = { starting = null }) { missionId ->
            starting = null
            core.requestMissionFocus(missionId)
        }
    }
}

@Composable
private fun OrbRemoteStartDialog(
    core: OrbCore,
    computer: OrbRow,
    onDismiss: () -> Unit,
    onStarted: (String) -> Unit
) {
    val scope = rememberCoroutineScope()
    val harnesses = remember(computer) { OrbJSON.dictList(computer.raw["harnesses"]) }
    var prompt by remember { mutableStateOf("") }
    var backend by remember { mutableStateOf(harnesses.firstOrNull()?.get("backend")?.toString() ?: "") }
    val models = harnesses.firstOrNull { it["backend"]?.toString() == backend }
        ?.let { OrbJSON.dictList(it["models"]) } ?: emptyList()
    var model by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(backend) { model = models.firstOrNull()?.get("value")?.toString() ?: "" }
    val name = computer.str("name")?.takeIf { it.isNotBlank() } ?: "computer"

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Start on $name") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                error?.let { Text(it, color = OrbStyle.warning, fontSize = 13.sp) }
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    label = { Text("Prompt") },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp)
                )
                if (harnesses.isEmpty()) {
                    Text(
                        "This computer has not reported its local agents yet.",
                        color = OrbStyle.textSecondary,
                        fontSize = 13.sp
                    )
                } else {
                    Text("Harness", color = OrbStyle.textSecondary, fontSize = 12.sp)
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        harnesses.forEach { h ->
                            val id = h["backend"]?.toString() ?: return@forEach
                            FilterChip(
                                selected = id == backend,
                                onClick = { backend = id },
                                label = { Text(h["name"]?.toString()?.takeIf { it.isNotBlank() } ?: id) }
                            )
                        }
                    }
                    if (models.isNotEmpty()) {
                        Text("Model", color = OrbStyle.textSecondary, fontSize = 12.sp)
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            models.forEach { m ->
                                val value = m["value"]?.toString() ?: return@forEach
                                FilterChip(
                                    selected = value == model,
                                    onClick = { model = value },
                                    label = { Text(m["label"]?.toString()?.takeIf { it.isNotBlank() } ?: value) }
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                TextButton(
                    enabled = prompt.isNotBlank() && backend.isNotBlank(),
                    onClick = {
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                val body = buildMap<String, Any?> {
                                    put("prompt", prompt)
                                    put("backend", backend)
                                    if (model.isNotBlank()) put("model_override", model)
                                }
                                val id = core.encodeComponent(computer.str("client_id") ?: computer.id)
                                val result = OrbJSON.dict(
                                    core.request("/api/control/client-computers/$id/missions", method = "POST", body = body)
                                ) ?: emptyMap()
                                val missionId = result["mission_id"]?.toString().orEmpty()
                                if (missionId.isBlank()) error = "The computer did not return a mission." else onStarted(missionId)
                            } catch (e: Throwable) {
                                error = e.message ?: "Could not start on this computer."
                            } finally {
                                busy = false
                            }
                        }
                    }
                ) { Text("Start") }
            }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } }
    )
}
