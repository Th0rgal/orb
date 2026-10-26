package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** Account › Usage telemetry (desktop/iOS parity): opt-in, off by default; Core holds the config. */
@Composable
fun OrbUsageTelemetrySettingsPage(core: OrbCore, onBack: () -> Unit) {
    val status by UsageTelemetry.status.collectAsState()
    val scope = rememberCoroutineScope()
    var namespace by remember { mutableStateOf("") }
    var hubUrl by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { UsageTelemetry.refresh() }
    LaunchedEffect(status["namespace"], status["hub_url"]) {
        namespace = status["namespace"] as? String ?: ""
        hubUrl = status["hub_url"] as? String ?: ""
    }

    fun save(patch: Map<String, Any?>) {
        busy = true
        scope.launch {
            runCatching { OrbJSON.dict(core.request("/api/usage-telemetry/config", "PUT", body = patch)) ?: emptyMap() }
                .onSuccess { UsageTelemetry.applyStatus(it); error = null }
                .onFailure { error = it.message ?: "Couldn’t save telemetry settings." }
            busy = false
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().background(OrbStyle.background).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier.size(38.dp).clip(CircleShape).background(OrbStyle.surface).border(1.dp, OrbStyle.border, CircleShape).orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp)) }
            Text("Usage telemetry", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
            Spacer(modifier = Modifier.width(38.dp))
        }
        Text(
            "Off by default. When on, Orb sends which screens, actions and approvals you use (never prompts, commands or secrets) to your telemetry hub through Core.",
            color = OrbStyle.textMuted, fontSize = 12.sp
        )
        error?.let { Text(it, color = OrbStyle.warning, fontSize = 12.sp) }

        TelemetryToggle("Send usage telemetry", status["enabled"] == true, !busy) { save(mapOf("enabled" to it)) }
        TelemetryToggle("Include prompts (secrets scrubbed)", status["prompts_enabled"] == true, !busy && status["enabled"] == true) {
            save(mapOf("prompts_enabled" to it))
        }

        TelemetryField("Namespace", namespace) { namespace = it }
        if (namespace.trim() == "community") Text("“community” is reserved.", color = OrbStyle.warning, fontSize = 12.sp)
        TelemetryField("Hub URL", hubUrl) { hubUrl = it }
        TelemetryField(if (status["token_configured"] == true) "Token: configured (type to replace)" else "Token", token, secret = true) { token = it }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TelemetryPill("Save", enabled = !busy && namespace.trim() != "community") {
                val patch = mutableMapOf<String, Any?>("namespace" to namespace.trim(), "hub_url" to hubUrl.trim())
                if (token.isNotEmpty()) patch["token"] = token
                token = ""
                save(patch)
            }
            if (status["token_configured"] == true) TelemetryPill("Clear token", enabled = !busy) { save(mapOf("token" to "")) }
        }

        val active = status["active"] == true
        Text("Status: ${if (active) "sending" else "not sending"}", color = OrbStyle.textSecondary, fontSize = 12.sp)
        Text("Queued on Core: ${(status["queued"] as? Number)?.toLong() ?: 0} · on this phone: ${UsageTelemetry.queued}", color = OrbStyle.textSecondary, fontSize = 12.sp)
        (status["last_error"] as? String)?.takeIf { it.isNotBlank() }?.let {
            Text("Last error: $it", color = OrbStyle.warning, fontSize = 12.sp)
        }
    }
}

@Composable
private fun TelemetryToggle(label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 14.sp, color = Color.White, modifier = Modifier.weight(1f))
        Switch(checked = checked, enabled = enabled, onCheckedChange = onChange)
    }
}

@Composable
private fun TelemetryField(label: String, value: String, secret: Boolean = false, onChange: (String) -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(OrbStyle.card)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 9.dp)
    ) {
        if (value.isEmpty()) Text(label, color = OrbStyle.textMuted, fontSize = 13.sp)
        BasicTextField(
            value = value,
            onValueChange = onChange,
            textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
            cursorBrush = SolidColor(Color.White),
            singleLine = true,
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun TelemetryPill(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (enabled) Color.White else OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable(enabled = enabled) { onClick() }
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) { Text(label, color = if (enabled) Color.Black else OrbStyle.textMuted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
}
