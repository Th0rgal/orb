package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.ContextWrapper
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Bitwarden secrets broker API (`src/api/bitwarden.rs`, nested at `/api/bitwarden`). */
object OrbBitwardenApi {
    const val BASE = "/api/bitwarden"

    suspend fun broker(core: OrbCore): OrbDict = core.fetchDict("$BASE/broker")

    fun pending(broker: OrbDict): List<OrbRow> =
        OrbJSON.dictList(broker["requests"]).map { OrbRow(it) }.filter { it.str("status") == "pending" }

    /** Human summary of a request, like iOS `describe()`. */
    fun describe(request: OrbRow, projectName: (String?) -> String?): String {
        val key = request.str("key")
        val project = projectName(request.str("project_id"))
        return if (request.str("kind") == "write") {
            "Store ${key ?: "a secret"}" + (project?.let { " in $it" } ?: "")
        } else when {
            key != null -> "Read $key"
            request.bool("all_projects") == true -> "Read every project"
            else -> "Read project ${project ?: request.str("project_id") ?: ""}".trim()
        }
    }

    fun describeGrant(grant: OrbRow, projectName: (String?) -> String?): String {
        val scope = grant.dict("scope")
        return when (OrbJSON.str(scope, "kind")) {
            "all" -> "All projects"
            "project" -> "Project ${projectName(OrbJSON.str(scope, "project_id")) ?: OrbJSON.str(scope, "project_id") ?: ""}"
            else -> "Secret ${OrbJSON.str(scope, "key") ?: ""}"
        }
    }
}

private fun Context.findFragmentActivity(): FragmentActivity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is FragmentActivity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

/** Device-owner gate, like iOS `LAContext` with passcode fallback; unlocks if no lock is set. */
private fun authenticateOwner(context: Context, onResult: (Boolean, String?) -> Unit) {
    val activity = context.findFragmentActivity()
    val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
        BiometricManager.Authenticators.DEVICE_CREDENTIAL
    if (activity == null) {
        onResult(false, "Biometric prompt unavailable")
        return
    }
    if (BiometricManager.from(activity).canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
        onResult(true, null)
        return
    }
    val prompt = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onResult(true, null)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                onResult(false, errString.toString())
            }
        }
    )
    prompt.authenticate(
        BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock secrets")
            .setSubtitle("Unlock secrets and mission access requests")
            .setAllowedAuthenticators(authenticators)
            .build()
    )
}

private val ttlChoices = listOf(1 to "1 h", 24 to "24 h", 168 to "7 d", 720 to "30 d")

@Composable
fun OrbBitwardenSettingsPage(
    core: OrbCore,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val palomaProjects by core.projects.collectAsState()

    var unlocked by remember { mutableStateOf(false) }
    var authError by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }

    var status by remember { mutableStateOf<OrbDict>(emptyMap()) }
    var projects by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var secrets by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var selectedProjectId by remember { mutableStateOf<String?>(null) }
    var requests by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var grants by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    val revealed = remember { mutableStateMapOf<String, String>() }
    var filter by remember { mutableStateOf("") }
    var tokenDraft by remember { mutableStateOf("") }
    var ttlHours by remember { mutableStateOf(24) }
    var busy by remember { mutableStateOf(false) }

    var editorTarget by remember { mutableStateOf<OrbRow?>(null) }
    var editorOpen by remember { mutableStateOf(false) }
    var editorKey by remember { mutableStateOf("") }
    var editorValue by remember { mutableStateOf("") }
    var editorNote by remember { mutableStateOf("") }
    var deleteTarget by remember { mutableStateOf<OrbRow?>(null) }
    var accessSlug by remember { mutableStateOf<String?>(null) }
    var showDefaultProjectPicker by remember { mutableStateOf(false) }

    val configured = OrbJSON.bool(status, "configured") == true
    fun projectName(id: String?): String? = id?.let { pid -> projects.firstOrNull { it.id == pid }?.str("name") }

    fun unlock() {
        authError = null
        authenticateOwner(context) { ok, message ->
            unlocked = ok
            if (!ok) authError = message ?: "Authentication failed"
        }
    }

    suspend fun loadBroker() {
        runCatching { OrbBitwardenApi.broker(core) }.onSuccess { b ->
            requests = OrbBitwardenApi.pending(b)
            grants = OrbJSON.dictList(b["grants"]).map { OrbRow(it) }
            core.updatePendingSecretRequests(requests.size)
        }
    }

    suspend fun loadSecrets(projectId: String?) {
        if (projectId == null) {
            secrets = emptyList()
            return
        }
        runCatching {
            core.fetchRows("${OrbBitwardenApi.BASE}/projects/${core.encodeComponent(projectId)}/secrets", null)
        }.onSuccess { secrets = it }.onFailure { error = it.message }
    }

    suspend fun loadAll() {
        error = null
        try {
            status = core.fetchDict("${OrbBitwardenApi.BASE}/status")
            if (OrbJSON.bool(status, "configured") == true) {
                projects = core.fetchRows("${OrbBitwardenApi.BASE}/projects", null)
                val start = selectedProjectId?.takeIf { id -> projects.any { it.id == id } }
                    ?: OrbJSON.str(status, "default_project_id")?.takeIf { id -> projects.any { it.id == id } }
                    ?: projects.firstOrNull()?.id
                selectedProjectId = start
                loadSecrets(start)
            }
        } catch (e: Throwable) {
            error = e.message
        }
        loadBroker()
    }

    fun act(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                block()
            } catch (e: Throwable) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    LaunchedEffect(Unit) { unlock() }
    LaunchedEffect(unlocked) {
        if (!unlocked) return@LaunchedEffect
        loadAll()
        while (isActive) {
            delay(10_000)
            loadBroker()
        }
    }
    LaunchedEffect(notice) {
        if (notice != null) {
            delay(1800)
            notice = null
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            OrbBwCircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back") { onBack() }
            Text(
                text = "Secrets",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            if (unlocked) {
                OrbBwCircleButton(Icons.Default.Lock, "Lock") {
                    unlocked = false
                    revealed.clear()
                }
            } else {
                Spacer(modifier = Modifier.width(38.dp))
            }
        }

        if (!unlocked) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 80.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Icon(Icons.Default.Fingerprint, contentDescription = null, tint = Color.White, modifier = Modifier.size(42.dp))
                OrbBwPill("Unlock", primary = true) { unlock() }
                authError?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
            }
            return@Column
        }

        error?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
        notice?.let { Text(it, color = OrbStyle.success, fontSize = 12.sp) }

        val needle = filter.trim().lowercase()
        val visibleSecrets = secrets.filter {
            needle.isEmpty() || (it.str("key") ?: "").lowercase().contains(needle) ||
                (it.str("note") ?: "").lowercase().contains(needle)
        }

        LazyColumn(verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.weight(1f)) {
            if (requests.isNotEmpty() || grants.isNotEmpty()) {
                item(key = "access") {
                    OrbBwSection("MISSION ACCESS") {
                        if (requests.isNotEmpty()) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text("Grant for", color = OrbStyle.textMuted, fontSize = 12.sp)
                                ttlChoices.forEach { (hours, label) ->
                                    OrbBwChip(label, selected = ttlHours == hours) { ttlHours = hours }
                                }
                            }
                        }
                        requests.forEach { req ->
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(OrbBitwardenApi.describe(req, ::projectName), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                val origin = listOfNotNull(req.str("mission_title"), req.str("paloma_project")).joinToString(" · ")
                                if (origin.isNotEmpty()) Text(origin, color = OrbStyle.textMuted, fontSize = 12.sp)
                                req.str("reason")?.let { Text(it, color = OrbStyle.textSecondary, fontSize = 12.sp, fontStyle = androidx.compose.ui.text.font.FontStyle.Italic) }
                                fun approve(scopeValue: String) = act {
                                    val body = mutableMapOf<String, Any?>()
                                    if (req.str("kind") != "write") {
                                        if (scopeValue.isNotEmpty()) body["scope"] = scopeValue
                                        body["ttl_hours"] = ttlHours
                                    }
                                    core.request("${OrbBitwardenApi.BASE}/requests/${core.encodeComponent(req.id)}/approve", method = "POST", body = body)
                                    loadBroker()
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    if (req.str("kind") == "write") {
                                        OrbBwPill("Approve", primary = true) { approve("") }
                                    } else {
                                        if (req.str("key") != null) OrbBwPill("Secret", primary = true) { approve("secret") }
                                        if (req.str("project_id") != null) OrbBwPill("Project") { approve("project") }
                                        OrbBwPill("All") { approve("all") }
                                    }
                                    OrbBwPill("Decline", destructive = true) {
                                        act {
                                            core.request("${OrbBitwardenApi.BASE}/requests/${core.encodeComponent(req.id)}/reject", method = "POST")
                                            loadBroker()
                                        }
                                    }
                                }
                            }
                        }
                        grants.forEach { grant ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(OrbBitwardenApi.describeGrant(grant, ::projectName), color = Color.White, fontSize = 13.sp)
                                    Text(
                                        listOfNotNull(grant.str("mission_title"), grant.str("expires_at")?.let { "until ${it.take(16).replace('T', ' ')}" }).joinToString(" · "),
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                OrbBwPill("Revoke", destructive = true) {
                                    act {
                                        core.request("${OrbBitwardenApi.BASE}/grants/${core.encodeComponent(grant.id)}", method = "DELETE")
                                        loadBroker()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            item(key = "account") {
                OrbBwSection("MACHINE ACCOUNT") {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(if (configured) OrbStyle.success else OrbStyle.warning)
                        )
                        Text(
                            text = if (configured) {
                                "Connected" + (OrbJSON.str(status, "token_hint")?.let { " · …$it" } ?: "")
                            } else if (OrbJSON.bool(status, "bws_installed") == false) {
                                "bws CLI is not installed on the backend"
                            } else {
                                "Not connected"
                            },
                            color = Color.White,
                            fontSize = 14.sp
                        )
                    }
                    OrbBwField("Machine account access token", tokenDraft, secret = true) { tokenDraft = it }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OrbBwPill(if (configured) "Replace token" else "Connect", primary = true, enabled = tokenDraft.isNotBlank()) {
                            act {
                                status = OrbJSON.dict(
                                    core.request("${OrbBitwardenApi.BASE}/config", method = "PUT", body = mapOf("access_token" to tokenDraft.trim()))
                                ) ?: status
                                tokenDraft = ""
                                loadAll()
                            }
                        }
                        if (configured) {
                            OrbBwPill("Clear token", destructive = true) {
                                act {
                                    status = OrbJSON.dict(
                                        core.request("${OrbBitwardenApi.BASE}/config", method = "PUT", body = mapOf("access_token" to ""))
                                    ) ?: status
                                    projects = emptyList()
                                    secrets = emptyList()
                                }
                            }
                        }
                    }
                    if (configured) {
                        val defaultId = OrbJSON.str(status, "default_project_id")
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Default project", color = OrbStyle.textMuted, fontSize = 11.sp)
                                Text(projectName(defaultId) ?: defaultId ?: "None", color = Color.White, fontSize = 13.sp)
                            }
                            Box {
                                OrbBwPill("Change") { showDefaultProjectPicker = true }
                                androidx.compose.material3.DropdownMenu(
                                    expanded = showDefaultProjectPicker,
                                    onDismissRequest = { showDefaultProjectPicker = false },
                                    containerColor = OrbStyle.elevated
                                ) {
                                    projects.forEach { p ->
                                        androidx.compose.material3.DropdownMenuItem(
                                            text = { Text(p.str("name") ?: p.id, color = Color.White) },
                                            onClick = {
                                                showDefaultProjectPicker = false
                                                act {
                                                    status = OrbJSON.dict(
                                                        core.request("${OrbBitwardenApi.BASE}/config", method = "PUT", body = mapOf("default_project_id" to p.id))
                                                    ) ?: status
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (configured && palomaProjects.isNotEmpty()) {
                item(key = "default_access") {
                    OrbBwSection("READ WITHOUT ASKING") {
                        Text(
                            "Missions in these projects may read the chosen Bitwarden projects without a request.",
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp
                        )
                        val access = OrbJSON.dict(status["default_access"]) ?: emptyMap()
                        palomaProjects.forEach { p ->
                            val slug = p.str("slug", "id") ?: p.id
                            val ids = OrbJSON.strList(access, slug)
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable { accessSlug = slug }
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(p.str("name", "title") ?: slug, color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                                Text(
                                    if (ids.isEmpty()) "Ask" else ids.joinToString(", ") { projectName(it) ?: it.take(8) },
                                    color = OrbStyle.textMuted,
                                    fontSize = 12.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                    textAlign = androidx.compose.ui.text.style.TextAlign.End
                                )
                            }
                        }
                    }
                }
            }

            if (configured) {
                item(key = "secrets_header") {
                    OrbBwSection("SECRETS · ${projectName(selectedProjectId) ?: "—"} (${visibleSecrets.size})") {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                modifier = Modifier
                                    .weight(1f)
                                    .horizontalScrollCompat(),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                projects.forEach { p ->
                                    OrbBwChip(p.str("name") ?: p.id, selected = p.id == selectedProjectId) {
                                        selectedProjectId = p.id
                                        revealed.clear()
                                        scope.launch { loadSecrets(p.id) }
                                    }
                                }
                            }
                            OrbBwCircleButton(Icons.Default.Add, "New secret") {
                                editorTarget = null
                                editorKey = ""
                                editorValue = ""
                                editorNote = ""
                                editorOpen = true
                            }
                        }
                        OrbBwField("Filter keys or notes", filter) { filter = it }
                    }
                }
                items(visibleSecrets, key = { "s-${it.id}" }) { secret ->
                    val value = revealed[secret.id]
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(secret.str("key") ?: "", color = Color.White, fontSize = 14.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            OrbBwIcon(if (value != null) Icons.Default.VisibilityOff else Icons.Default.Visibility, "Reveal") {
                                if (value != null) {
                                    revealed.remove(secret.id)
                                } else {
                                    act {
                                        val d = core.fetchDict("${OrbBitwardenApi.BASE}/secrets/${core.encodeComponent(secret.id)}/reveal")
                                        revealed[secret.id] = OrbJSON.rawStr(d, "value") ?: ""
                                    }
                                }
                            }
                            OrbBwIcon(Icons.Default.ContentCopy, "Copy") {
                                act {
                                    val v = revealed[secret.id] ?: OrbJSON.rawStr(
                                        core.fetchDict("${OrbBitwardenApi.BASE}/secrets/${core.encodeComponent(secret.id)}/reveal"),
                                        "value"
                                    ) ?: ""
                                    OrbStyle.copyToClipboard(context, v)
                                    notice = "Copied"
                                }
                            }
                            OrbBwIcon(Icons.Default.Edit, "Edit") {
                                act {
                                    val d = core.fetchDict("${OrbBitwardenApi.BASE}/secrets/${core.encodeComponent(secret.id)}/reveal")
                                    editorTarget = secret
                                    editorKey = secret.str("key") ?: ""
                                    editorValue = OrbJSON.rawStr(d, "value") ?: ""
                                    editorNote = OrbJSON.rawStr(d, "note") ?: secret.str("note") ?: ""
                                    editorOpen = true
                                }
                            }
                            OrbBwIcon(Icons.Default.Delete, "Delete", tint = OrbStyle.error) { deleteTarget = secret }
                        }
                        secret.str("note")?.let { Text(it, color = OrbStyle.textMuted, fontSize = 12.sp) }
                        value?.let {
                            Text(it, color = OrbStyle.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                        }
                    }
                }
            }
        }
    }

    if (editorOpen) {
        AlertDialog(
            onDismissRequest = { editorOpen = false },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text(if (editorTarget == null) "New secret" else "Edit secret", fontWeight = FontWeight.SemiBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OrbBwField("Key", editorKey) { editorKey = it }
                    OrbBwField("Value", editorValue, secret = true) { editorValue = it }
                    OrbBwField("Note", editorNote) { editorNote = it }
                }
            },
            confirmButton = {
                TextButton(enabled = editorKey.isNotBlank() && !busy, onClick = {
                    val target = editorTarget
                    act {
                        if (target != null) {
                            core.request(
                                "${OrbBitwardenApi.BASE}/secrets/${core.encodeComponent(target.id)}",
                                method = "PUT",
                                body = mapOf("key" to editorKey.trim(), "value" to editorValue, "note" to editorNote, "project_id" to selectedProjectId)
                            )
                            revealed.remove(target.id)
                        } else {
                            val pid = selectedProjectId ?: throw OrbError("Choose a project first.")
                            core.request(
                                "${OrbBitwardenApi.BASE}/projects/${core.encodeComponent(pid)}/secrets",
                                method = "POST",
                                body = mapOf("key" to editorKey.trim(), "value" to editorValue, "note" to editorNote.ifBlank { null })
                            )
                        }
                        editorOpen = false
                        loadSecrets(selectedProjectId)
                    }
                }) { Text("Save", color = Color.White, fontWeight = FontWeight.SemiBold) }
            },
            dismissButton = {
                TextButton(onClick = { editorOpen = false }) { Text("Cancel", color = OrbStyle.textSecondary) }
            }
        )
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            textContentColor = OrbStyle.textSecondary,
            title = { Text("Delete ${target.str("key") ?: "secret"}?", fontWeight = FontWeight.SemiBold) },
            text = { Text("This removes the secret from Bitwarden for every machine and mission.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    act {
                        core.request("${OrbBitwardenApi.BASE}/secrets/${core.encodeComponent(target.id)}", method = "DELETE")
                        revealed.remove(target.id)
                        loadSecrets(selectedProjectId)
                    }
                }) { Text("Delete", color = OrbStyle.error, fontWeight = FontWeight.SemiBold) }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel", color = OrbStyle.textSecondary) }
            }
        )
    }

    accessSlug?.let { slug ->
        val current = OrbJSON.strList(OrbJSON.dict(status["default_access"]), slug)
        val chosen = remember(slug) { mutableStateMapOf<String, Boolean>().apply { current.forEach { put(it, true) } } }
        AlertDialog(
            onDismissRequest = { accessSlug = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Read without asking · $slug", fontWeight = FontWeight.SemiBold) },
            text = {
                Column {
                    projects.forEach { p ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .orbPressClickable { chosen[p.id] = chosen[p.id] != true },
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Checkbox(
                                checked = chosen[p.id] == true,
                                onCheckedChange = { chosen[p.id] = it },
                                colors = CheckboxDefaults.colors(checkedColor = Color.White, checkmarkColor = Color.Black)
                            )
                            Text(p.str("name") ?: p.id, color = Color.White, fontSize = 14.sp)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val ids = chosen.filterValues { it }.keys.toList()
                    accessSlug = null
                    act {
                        status = OrbJSON.dict(
                            core.request(
                                "${OrbBitwardenApi.BASE}/default-access/${core.encodeComponent(slug)}",
                                method = "PUT",
                                body = mapOf("project_ids" to ids)
                            )
                        ) ?: status
                    }
                }) { Text("Save", color = Color.White, fontWeight = FontWeight.SemiBold) }
            },
            dismissButton = {
                TextButton(onClick = { accessSlug = null }) { Text("Cancel", color = OrbStyle.textSecondary) }
            }
        )
    }
}

@Composable
private fun Modifier.horizontalScrollCompat(): Modifier =
    this.horizontalScroll(androidx.compose.foundation.rememberScrollState())

@Composable
private fun OrbBwSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = OrbStyle.textMuted, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.7.sp)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) { content() }
    }
}

@Composable
private fun OrbBwField(label: String, value: String, secret: Boolean = false, onChange: (String) -> Unit) {
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
private fun OrbBwPill(
    label: String,
    primary: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (primary && enabled) Color.White else OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable(enabled = enabled) { onClick() }
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Text(
            label,
            color = when {
                primary && enabled -> Color.Black
                destructive -> OrbStyle.error
                enabled -> Color.White
                else -> OrbStyle.textMuted
            },
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

@Composable
private fun OrbBwChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (selected) Color.White else OrbStyle.card)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 4.dp)
    ) {
        Text(label, color = if (selected) Color.Black else OrbStyle.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun OrbBwIcon(icon: ImageVector, description: String, tint: Color = OrbStyle.textSecondary, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(CircleShape)
            .orbPressClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = description, tint = tint, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun OrbBwCircleButton(icon: ImageVector, description: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = description, tint = Color.White, modifier = Modifier.size(17.dp))
    }
}
