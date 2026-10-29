package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Android parity for Models (`Fallback Chains`, `API Keys`) and Agents (`Skills`, `Assistant`)
 * matching `OrbAdminSettings.swift` and desktop settings panels.
 */
object OrbAdminFormatting {
    fun cleanKeyTitle(raw: String): String {
        val trimmed = raw.trim()
        val spaceIdx = trimmed.lastIndexOf(' ')
        if (spaceIdx > 0) {
            val tail = trimmed.substring(spaceIdx + 1)
            if (tail.length >= 19 && tail.getOrNull(4) == '-' && tail.contains('T') && (tail.endsWith('Z') || tail.contains('+') || tail.contains(':'))) {
                val prefix = trimmed.substring(0, spaceIdx).trim()
                if (prefix.isNotEmpty()) return prefix
            }
        }
        return trimmed
    }

    fun skillRepoLine(status: OrbDict?, nowSecs: Long = System.currentTimeMillis() / 1000L): String {
        if (status == null) return "Library"
        var remote = OrbJSON.str(status, "remote").orEmpty()
        if (remote.endsWith(".git")) remote = remote.dropLast(4)
        val parts = remote.split('/', ':').filter { it.isNotEmpty() }.takeLast(2).joinToString("/")
        val label = if ('/' in parts) parts else "Library"
        val syncedAt = (status["last_synced_at"] as? Number)?.toLong()
            ?: return "$label · not synced yet"
        val rel = OrbJSON.relativeSeconds(maxOf(0L, nowSecs - syncedAt))
        return "$label · synced " + if (rel == "now") "just now" else "$rel ago"
    }

    fun skillBody(markdown: String): String {
        if (!markdown.startsWith("---\n")) return markdown
        val end = markdown.indexOf("\n---", startIndex = 4)
        if (end < 0) return markdown
        return markdown.substring(end + 4).trim()
    }

    fun normalizeSkillName(raw: String): String =
        raw.trim().lowercase().replace(Regex("[^a-z0-9-_]+"), "-").trim('-')

    fun hermesRuntime(runtime: OrbDict?): List<Pair<String, String>> {
        if (runtime == null) return listOf("Status" to "Unavailable")
        val rows = mutableListOf<Pair<String, String>>()
        val active = runtime["service_active"] as? Boolean
        if (active != null) {
            rows += "Service" to if (active) "Active" else "Stopped"
        } else {
            rows += "Service" to (OrbJSON.str(runtime, "service_state")?.takeIf { it.isNotEmpty() } ?: "Unknown")
        }
        OrbJSON.str(runtime, "gateway_state")?.takeIf { it.isNotEmpty() }?.let { rows += "Gateway" to it }
        (runtime["api_server_healthy"] as? Boolean)?.let { rows += "API" to if (it) "Healthy" else "Unreachable" }
        (runtime["uses_sandboxed_proxy"] as? Boolean)?.let { rows += "Route" to if (it) "Via Core proxy" else "Direct provider" }
        if (runtime["token_present"] == false) rows += "Token" to "Missing"
        return rows
    }

    fun hermesSessions(sessions: OrbDict?): String? {
        val total = (sessions?.get("total") as? Number)?.toInt() ?: return null
        val open = (sessions["open"] as? Number)?.toInt() ?: 0
        return "$total · $open open"
    }
}

@Composable
private fun OrbAdminHeader(
    title: String,
    onBack: () -> Unit,
    trailing: @Composable () -> Unit = { Spacer(Modifier.width(38.dp)) }
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, CircleShape)
                .orbPressClickable { onBack() },
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(17.dp))
        }
        Text(
            text = title,
            color = Color.White,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.Center
        )
        trailing()
    }
}

@Composable
private fun OrbAdminCircleAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, CircleShape)
            .orbPressClickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = description, tint = Color.White, modifier = Modifier.size(17.dp))
    }
}

// MARK: - 1. Fallback Chains (/api/model-routing)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun OrbRoutingSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var chains by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var health by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var events by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var providerLabels by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var showHealthyAccounts by remember { mutableStateOf(false) }
    var showEvents by remember { mutableStateOf(false) }
    var isRefreshing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }

    var editingChain by remember { mutableStateOf<OrbRow?>(null) }
    var showEditor by remember { mutableStateOf(false) }
    var deletingChain by remember { mutableStateOf<OrbRow?>(null) }

    suspend fun load() {
        try {
            chains = OrbJSON.dictList(core.request("/api/model-routing/chains")).map { OrbRow(it) }
            health = runCatching { OrbJSON.dictList(core.request("/api/model-routing/health")).map { OrbRow(it, (it["account_id"] as? String).orEmpty()) } }.getOrDefault(emptyList())
            events = runCatching { OrbJSON.dictList(core.request("/api/model-routing/events")).mapIndexed { i, d -> OrbRow(d, "ev-$i") } }.getOrDefault(emptyList())
            runCatching { core.fetchRows("/api/ai/providers", "providers") }.getOrNull()?.let { provs ->
                providerLabels = provs.associate { p ->
                    val s = splitProviderDisplayName(p)
                    p.id to s.account.ifEmpty { s.title }
                }
            }
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        try { load() } finally { isRefreshing = false }
    }

    fun runAct(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                action()
                load()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    fun isAttentionHealth(h: OrbRow): Boolean =
        h.bool("is_healthy") == false || h.bool("is_degraded") == true || (h.int("cooldown_remaining_secs") ?: 0) > 0

    fun accountTitle(h: OrbRow): String {
        val pid = h.str("provider_id")?.takeIf { it.isNotEmpty() } ?: h.str("account_id").orEmpty()
        val aid = h.str("account_id").orEmpty()
        val mapped = providerLabels[aid]
        if (!mapped.isNullOrEmpty() && !mapped.equals(pid, ignoreCase = true)) {
            return "$pid · $mapped"
        }
        val inlineLabel = h.str("account_label", "account_email").orEmpty()
        if (inlineLabel.isNotEmpty()) return "$pid · $inlineLabel"
        if (aid.isNotEmpty() && aid != pid) return "$pid · ${aid.take(8)}"
        return pid
    }

    fun healthLine(h: OrbRow): String {
        val parts = mutableListOf("${h.int("total_successes") ?: 0}/${h.int("total_requests") ?: 0} ok")
        val rl = h.int("total_rate_limits") ?: 0
        if (rl > 0) parts += "$rl rate limits"
        h.double("avg_latency_ms")?.let { parts += "${it.roundToInt()} ms" }
        val cd = h.int("cooldown_remaining_secs") ?: 0
        if (cd > 0) parts += "cooldown ${OrbActivityCompaction.formatCooldown(cd)}"
        h.str("last_failure_reason")?.takeIf { it.isNotEmpty() }?.let { parts += it }
        return parts.joinToString(" · ")
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        OrbAdminHeader(
            title = "Fallback Chains",
            onBack = onBack,
            trailing = {
                OrbAdminCircleAction(Icons.Default.Add, "New chain") {
                    editingChain = null
                    showEditor = true
                }
            }
        )

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try { load() } finally { isRefreshing = false }
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            val attentionRows = remember(health) { health.filter(::isAttentionHealth) }
            val healthyRows = remember(health) { health.filterNot(::isAttentionHealth) }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                error?.let { err -> item { Text(err, color = OrbStyle.error, fontSize = 13.sp) } }
                notice?.let { msg ->
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                .padding(12.dp)
                        ) {
                            Text(msg, color = OrbStyle.textSecondary, fontSize = 12.sp)
                        }
                    }
                }

                item {
                    Text("FALLBACK CHAINS", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.7.sp)
                }

                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (chains.isEmpty() && !isRefreshing) {
                            Text("No chains.", color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        }
                        chains.forEachIndexed { idx, chain ->
                            var menuOpen by remember(chain.id) { mutableStateOf(false) }
                            val entriesStr = chain.rows("entries").joinToString(" → ") {
                                "${it.str("provider_id").orEmpty()}/${it.str("model_id").orEmpty()}"
                            }
                            Box {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .combinedClickable(
                                            onClick = { menuOpen = true },
                                            onLongClick = { menuOpen = true }
                                        )
                                        .padding(horizontal = 16.dp, vertical = 12.dp),
                                    verticalArrangement = Arrangement.spacedBy(3.dp)
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Text(
                                            text = chain.str("name")?.takeIf { it.isNotEmpty() } ?: chain.id,
                                            color = Color.White,
                                            fontSize = 15.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f, fill = false)
                                        )
                                        if (chain.bool("is_default") == true) {
                                            Text("Default", color = OrbStyle.success, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                        }
                                        Spacer(Modifier.weight(1f))
                                        Icon(Icons.Default.MoreVert, contentDescription = "Actions", tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
                                    }
                                    Text(chain.id, color = OrbStyle.textMuted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                                    if (entriesStr.isNotEmpty()) {
                                        Text(entriesStr, color = OrbStyle.textSecondary, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, containerColor = OrbStyle.elevated) {
                                    DropdownMenuItem(text = { Text("Edit", color = Color.White) }, onClick = {
                                        menuOpen = false
                                        editingChain = chain
                                        showEditor = true
                                    })
                                    if (chain.bool("is_default") != true) {
                                        DropdownMenuItem(text = { Text("Make default", color = Color.White) }, onClick = {
                                            menuOpen = false
                                            runAct { core.request("/api/model-routing/chains/${core.encodeComponent(chain.id)}", "PUT", body = mapOf("is_default" to true)) }
                                        })
                                    }
                                    DropdownMenuItem(text = { Text("Test chain", color = Color.White) }, onClick = {
                                        menuOpen = false
                                        scope.launch {
                                            runCatching {
                                                val res = OrbJSON.dict(core.request("/api/model-routing/chains/${core.encodeComponent(chain.id)}/test", "POST"))
                                                val ok = OrbJSON.bool(res, "ok") == true
                                                val model = OrbJSON.str(OrbJSON.dict(res?.get("response")), "model").orEmpty()
                                                notice = if (ok) "Test ${chain.id}: OK · $model" else "Test ${chain.id} failed"
                                            }.onFailure { error = it.message }
                                        }
                                    })
                                    DropdownMenuItem(text = { Text("Copy model ID", color = Color.White) }, onClick = {
                                        menuOpen = false
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                        cm?.setPrimaryClip(ClipData.newPlainText("Model ID", chain.id))
                                        Toast.makeText(context, "Copied ${chain.id}", Toast.LENGTH_SHORT).show()
                                    })
                                    DropdownMenuItem(text = { Text("Delete", color = OrbStyle.error) }, onClick = {
                                        menuOpen = false
                                        deletingChain = chain
                                    })
                                }
                            }
                            if (idx < chains.lastIndex) {
                                HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                            }
                        }
                    }
                }

                item {
                    Text("PROVIDER HEALTH", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.7.sp)
                }

                item {
                    @Composable
                    fun HealthRowView(h: OrbRow) {
                        val dotColor = when {
                            h.bool("is_healthy") == false -> OrbStyle.error
                            h.bool("is_degraded") == true -> OrbStyle.warning
                            else -> OrbStyle.success
                        }
                        val cooldown = h.int("cooldown_remaining_secs") ?: 0
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(dotColor))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(accountTitle(h), color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(healthLine(h), color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            if (cooldown > 0) {
                                TextButton(enabled = !busy, onClick = {
                                    val aid = h.str("account_id").orEmpty()
                                    runAct { core.request("/api/model-routing/health/${core.encodeComponent(aid)}/clear", "POST") }
                                }) { Text("Clear", fontSize = 12.sp) }
                            }
                        }
                    }

                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (health.isEmpty()) {
                            Text("No requests recorded yet.", color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        }
                        attentionRows.forEachIndexed { idx, h ->
                            HealthRowView(h)
                            if (idx < attentionRows.lastIndex || healthyRows.isNotEmpty()) {
                                HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                            }
                        }
                        if (healthyRows.isNotEmpty()) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable { showHealthyAccounts = !showHealthyAccounts }
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(
                                    imageVector = if (showHealthyAccounts) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                                    contentDescription = null,
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text("Healthy accounts (${healthyRows.size})", color = OrbStyle.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                            }
                            if (showHealthyAccounts) {
                                healthyRows.forEachIndexed { idx, h ->
                                    if (idx > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                                    HealthRowView(h)
                                }
                            }
                        }
                    }
                }

                if (events.isNotEmpty()) {
                    item {
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
                                    .orbPressClickable { showEvents = !showEvents }
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(
                                    imageVector = if (showEvents) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                                    contentDescription = null,
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text("Recent fallback events (${events.size})", color = OrbStyle.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                            }
                            if (showEvents) {
                                events.take(25).forEachIndexed { idx, ev ->
                                    if (idx > 0) HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                                    val toP = ev.str("to_provider")?.takeIf { it.isNotEmpty() } ?: "none"
                                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(
                                            "${ev.str("from_provider").orEmpty()}/${ev.str("from_model").orEmpty()} → $toP",
                                            color = Color.White,
                                            fontSize = 12.sp,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        Text(
                                            "${ev.str("reason").orEmpty()} · ${ev.str("chain_id").orEmpty()} · ${OrbJSON.relative(ev.str("timestamp"))}",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showEditor) {
        val existing = editingChain
        var chainId by remember(existing) { mutableStateOf(existing?.id.orEmpty()) }
        var chainName by remember(existing) { mutableStateOf(existing?.str("name").orEmpty()) }
        var stripThinking by remember(existing) { mutableStateOf(existing?.bool("strip_thinking") == true) }
        var editorError by remember(existing) { mutableStateOf<String?>(null) }
        val entriesText = remember(existing) {
            mutableStateOf(
                existing?.rows("entries")?.joinToString("\n") {
                    "${it.str("provider_id").orEmpty()}/${it.str("model_id").orEmpty()}"
                }.orEmpty()
            )
        }
        val parsedEntries = entriesText.value.lines()
            .map { it.trim() }
            .filter { '/' in it }
            .map { line ->
                val p = line.substringBefore('/').trim()
                val m = line.substringAfter('/').trim()
                p to m
            }
            .filter { it.first.isNotEmpty() && it.second.isNotEmpty() }

        AlertDialog(
            onDismissRequest = { showEditor = false },
            containerColor = OrbStyle.elevated,
            title = { Text(if (existing != null) "Edit chain" else "New chain", color = Color.White) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = chainId,
                        onValueChange = { if (existing == null) chainId = it },
                        enabled = existing == null,
                        singleLine = true,
                        label = { Text("Chain ID (e.g. builtin/smart)") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = chainName,
                        onValueChange = { chainName = it },
                        singleLine = true,
                        label = { Text("Name") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = entriesText.value,
                        onValueChange = { entriesText.value = it },
                        label = { Text("Entries (provider/model per line)") },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 100.dp)
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Strip <think> blocks", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                        Switch(checked = stripThinking, onCheckedChange = { stripThinking = it }, enabled = !busy)
                    }
                    editorError?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = chainId.isNotBlank() && parsedEntries.isNotEmpty() && !busy,
                    onClick = {
                        val trimmedId = chainId.trim()
                        if (existing == null && chains.any { it.id.equals(trimmedId, ignoreCase = true) }) {
                            editorError = "\"$trimmedId\" already exists."
                            return@TextButton
                        }
                        val body = mapOf(
                            "id" to trimmedId,
                            "name" to chainName.trim(),
                            "strip_thinking" to stripThinking,
                            "entries" to parsedEntries.map { mapOf("provider_id" to it.first, "model_id" to it.second) }
                        )
                        busy = true
                        editorError = null
                        scope.launch {
                            try {
                                if (existing != null) {
                                    core.request("/api/model-routing/chains/${core.encodeComponent(trimmedId)}", "PUT", body = body)
                                } else {
                                    core.request("/api/model-routing/chains", "POST", body = body)
                                }
                                load()
                                showEditor = false
                            } catch (e: Throwable) {
                                editorError = e.message
                            } finally {
                                busy = false
                            }
                        }
                    }
                ) { Text(if (busy) "Saving…" else "Save") }
            },
            dismissButton = { TextButton(enabled = !busy, onClick = { showEditor = false }) { Text("Cancel") } }
        )
    }

    deletingChain?.let { target ->
        AlertDialog(
            onDismissRequest = { deletingChain = null },
            containerColor = OrbStyle.elevated,
            title = { Text("Delete chain?", color = Color.White) },
            text = { Text("Delete ${target.str("name") ?: target.id}? Requests using its ID stop resolving.", color = OrbStyle.textSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    val id = target.id
                    deletingChain = null
                    runAct { core.request("/api/model-routing/chains/${core.encodeComponent(id)}", "DELETE") }
                }) { Text("Delete", color = OrbStyle.error) }
            },
            dismissButton = { TextButton(onClick = { deletingChain = null }) { Text("Cancel") } }
        )
    }
}

// MARK: - 2. Proxy API Keys (/api/proxy-keys)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbProxyKeysSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var keys by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var isRefreshing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var creatingKey by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var createdKey by remember { mutableStateOf<OrbDict?>(null) }
    var deletingKey by remember { mutableStateOf<OrbRow?>(null) }
    var cleanupDays by remember { mutableIntStateOf(30) }
    var staleKeys by remember { mutableStateOf<List<OrbRow>?>(null) }

    suspend fun load() {
        try {
            keys = OrbJSON.dictList(core.request("/api/proxy-keys")).map { OrbRow(it) }
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        try { load() } finally { isRefreshing = false }
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        OrbAdminHeader(
            title = "API Keys",
            onBack = onBack,
            trailing = {
                OrbAdminCircleAction(Icons.Default.Add, "New key") {
                    newName = ""
                    creatingKey = true
                }
            }
        )

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try { load() } finally { isRefreshing = false }
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                error?.let { err -> item { Text(err, color = OrbStyle.error, fontSize = 13.sp) } }

                createdKey?.let { created ->
                    item {
                        val secretVal = OrbJSON.str(created, "key").orEmpty()
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.success.copy(alpha = 0.5f), RoundedCornerShape(16.dp))
                                .padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text("Key ${OrbJSON.str(created, "name").orEmpty()}", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                            Text("Copy it now — it will not be shown again.", color = OrbStyle.textMuted, fontSize = 12.sp)
                            androidx.compose.foundation.text.selection.SelectionContainer {
                                Text(secretVal, color = OrbStyle.success, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = {
                                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                    cm?.setPrimaryClip(ClipData.newPlainText("API Key", secretVal))
                                    Toast.makeText(context, "Key copied", Toast.LENGTH_SHORT).show()
                                }) { Text("Copy key") }
                                TextButton(onClick = { createdKey = null }) { Text("Done") }
                            }
                        }
                    }
                }

                item {
                    Text("KEYS (${keys.size})", color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.7.sp)
                }

                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (keys.isEmpty() && !isRefreshing) {
                            Text("No keys.", color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        }
                        keys.forEachIndexed { idx, key ->
                            val lastUsed = key.str("last_used_at")
                            val usedText = if (lastUsed.isNullOrEmpty()) "never used" else "used ${OrbJSON.relative(lastUsed)}"
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        text = OrbAdminFormatting.cleanKeyTitle(key.str("name").orEmpty()),
                                        color = Color.White,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = "${key.str("key_prefix").orEmpty()}… · created ${OrbJSON.relative(key.str("created_at"))} · $usedText",
                                        color = OrbStyle.textMuted,
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                Icon(
                                    imageVector = Icons.Default.Delete,
                                    contentDescription = "Delete key",
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(18.dp).orbPressClickable { deletingKey = key }
                                )
                            }
                            if (idx < keys.lastIndex) {
                                HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                            }
                        }
                    }
                }

                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("Unused for $cleanupDays days", color = OrbStyle.textSecondary, fontSize = 13.sp)
                        TextButton(enabled = !busy, onClick = {
                            busy = true
                            scope.launch {
                                try {
                                    val resp = OrbJSON.dict(
                                        core.request(
                                            "/api/proxy-keys/cleanup",
                                            "POST",
                                            body = mapOf("max_age_days" to cleanupDays, "dry_run" to true)
                                        )
                                    )
                                    staleKeys = OrbJSON.dictList(resp?.get("keys")).map { OrbRow(it) }
                                } catch (e: Throwable) {
                                    error = e.message
                                } finally {
                                    busy = false
                                }
                            }
                        }) { Text("Find stale keys") }
                    }
                }
            }
        }
    }

    if (creatingKey) {
        AlertDialog(
            onDismissRequest = { creatingKey = false },
            containerColor = OrbStyle.elevated,
            title = { Text("New API key", color = Color.White) },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    singleLine = true,
                    label = { Text("Key name") },
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(
                    enabled = newName.isNotBlank() && !busy,
                    onClick = {
                        val trimmed = newName.trim()
                        creatingKey = false
                        busy = true
                        scope.launch {
                            try {
                                createdKey = OrbJSON.dict(core.request("/api/proxy-keys", "POST", body = mapOf("name" to trimmed)))
                                load()
                            } catch (e: Throwable) {
                                error = e.message
                            } finally {
                                busy = false
                            }
                        }
                    }
                ) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { creatingKey = false }) { Text("Cancel") } }
        )
    }

    deletingKey?.let { key ->
        AlertDialog(
            onDismissRequest = { deletingKey = null },
            containerColor = OrbStyle.elevated,
            title = { Text("Delete key?", color = Color.White) },
            text = { Text("Clients using ${key.str("name").orEmpty()} will stop working.", color = OrbStyle.textSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    val id = key.id
                    deletingKey = null
                    scope.launch {
                        runCatching { core.request("/api/proxy-keys/${core.encodeComponent(id)}", "DELETE") }
                            .onFailure { error = it.message }
                        load()
                    }
                }) { Text("Delete", color = OrbStyle.error) }
            },
            dismissButton = { TextButton(onClick = { deletingKey = null }) { Text("Cancel") } }
        )
    }

    staleKeys?.let { stale ->
        AlertDialog(
            onDismissRequest = { staleKeys = null },
            containerColor = OrbStyle.elevated,
            title = { Text(if (stale.isEmpty()) "No stale keys" else "Delete ${stale.size} stale keys?", color = Color.White) },
            text = {
                Text(
                    if (stale.isEmpty()) "All keys were created or used within the last $cleanupDays days."
                    else stale.joinToString(", ") { OrbAdminFormatting.cleanKeyTitle(it.str("name").orEmpty()) },
                    color = OrbStyle.textSecondary
                )
            },
            confirmButton = {
                if (stale.isNotEmpty()) {
                    TextButton(onClick = {
                        val targets = stale
                        staleKeys = null
                        scope.launch {
                            var firstErr: String? = null
                            targets.forEach { k ->
                                runCatching { core.request("/api/proxy-keys/${core.encodeComponent(k.id)}", "DELETE") }
                                    .onFailure { if (firstErr == null) firstErr = it.message }
                            }
                            load()
                            if (firstErr != null) error = firstErr
                        }
                    }) { Text("Delete", color = OrbStyle.error) }
                } else {
                    TextButton(onClick = { staleKeys = null }) { Text("OK") }
                }
            },
            dismissButton = {
                if (stale.isNotEmpty()) TextButton(onClick = { staleKeys = null }) { Text("Cancel") }
            }
        )
    }
}

// MARK: - 3. Skills (/api/library/skill)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbSkillsSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var skills by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var repoStatus by remember { mutableStateOf<OrbDict?>(null) }
    var search by remember { mutableStateOf("") }
    var isRefreshing by remember { mutableStateOf(false) }
    var pulling by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var createBusy by remember { mutableStateOf(false) }
    var createError by remember { mutableStateOf<String?>(null) }
    var newName by remember { mutableStateOf("") }
    var openedSkill by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        try {
            skills = OrbJSON.dictList(core.request("/api/library/skill"))
                .map { OrbRow(it, (it["name"] as? String).orEmpty()) }
                .sortedBy { it.id }
            repoStatus = runCatching { core.fetchDict("/api/library/status") }.getOrNull()
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    suspend fun commitAndPush(message: String) {
        core.request("/api/library/commit", "POST", body = mapOf("message" to message))
        core.request("/api/library/push", "POST")
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        try { load() } finally { isRefreshing = false }
    }

    val targetSkill = openedSkill
    if (targetSkill != null) {
        OrbSkillDetailView(
            core = core,
            name = targetSkill,
            onBack = {
                openedSkill = null
                scope.launch { load() }
            }
        )
        return
    }

    val filtered = remember(skills, search) {
        val q = search.trim().lowercase()
        if (q.isEmpty()) skills
        else skills.filter {
            it.id.lowercase().contains(q) || (it.str("description")?.lowercase()?.contains(q) == true)
        }
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        OrbAdminHeader(
            title = "Skills",
            onBack = onBack,
            trailing = {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OrbAdminCircleAction(Icons.Default.Refresh, "Pull from repo", enabled = !pulling) {
                        pulling = true
                        scope.launch {
                            try {
                                core.request("/api/library/sync", "POST")
                                load()
                            } catch (e: Throwable) {
                                error = "Couldn’t pull the Library: ${e.message}"
                            } finally {
                                pulling = false
                            }
                        }
                    }
                    OrbAdminCircleAction(Icons.Default.Add, "New skill") {
                        newName = ""
                        createError = null
                        creating = true
                    }
                }
            }
        )

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try { load() } finally { isRefreshing = false }
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                error?.let { err -> item { Text(err, color = OrbStyle.error, fontSize = 13.sp) } }

                item {
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        singleLine = true,
                        placeholder = { Text("Search skills") },
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                item {
                    Text(
                        text = if (pulling) "Pulling…" else OrbAdminFormatting.skillRepoLine(repoStatus),
                        color = OrbStyle.textMuted,
                        fontSize = 12.sp
                    )
                }

                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        if (filtered.isEmpty() && !isRefreshing) {
                            Text("No matching skills.", color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        }
                        filtered.forEachIndexed { idx, skill ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable { openedSkill = skill.id }
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Text(skill.id, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                                        if (skill.str("scope") == "global") {
                                            Text(
                                                "Always loaded",
                                                color = OrbStyle.textSecondary,
                                                fontSize = 10.sp,
                                                modifier = Modifier
                                                    .clip(CircleShape)
                                                    .background(OrbStyle.card)
                                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                    skill.str("description")?.takeIf { it.isNotEmpty() }?.let { desc ->
                                        Text(desc, color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                                Icon(Icons.Default.ChevronRight, contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
                            }
                            if (idx < filtered.lastIndex) {
                                HorizontalDivider(color = OrbStyle.border, modifier = Modifier.padding(start = 16.dp))
                            }
                        }
                    }
                }
            }
        }
    }

    if (creating) {
        AlertDialog(
            onDismissRequest = { if (!createBusy) creating = false },
            containerColor = OrbStyle.elevated,
            title = { Text("New Library skill", color = Color.White) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = {
                            newName = it
                            createError = null
                        },
                        enabled = !createBusy,
                        singleLine = true,
                        label = { Text("skill-name") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    createError?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = newName.isNotBlank() && !createBusy,
                    onClick = {
                        val slug = OrbAdminFormatting.normalizeSkillName(newName)
                        if (slug.isEmpty()) {
                            createError = "Enter a skill name such as lean-prover."
                            return@TextButton
                        }
                        if (skills.any { it.id.equals(slug, ignoreCase = true) }) {
                            createError = "\"$slug\" already exists in the Library."
                            return@TextButton
                        }
                        createBusy = true
                        createError = null
                        val template = "---\nname: $slug\ndescription: \"Describe when $slug should be used.\"\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n---\n\n# $slug\n\n## When to use\n\n- \n\n## Instructions\n\n- \n"
                        scope.launch {
                            try {
                                val latest = OrbJSON.dictList(core.request("/api/library/skill"))
                                    .map { OrbRow(it, (it["name"] as? String).orEmpty()) }
                                    .sortedBy { it.id }
                                skills = latest
                                if (latest.any { it.id.equals(slug, ignoreCase = true) }) {
                                    createError = "\"$slug\" already exists in the Library."
                                    return@launch
                                }
                                core.request("/api/library/skill/${core.encodeComponent(slug)}", "PUT", body = mapOf("content" to template))
                                commitAndPush("skill: create $slug")
                                load()
                                creating = false
                                newName = ""
                            } catch (e: Throwable) {
                                createError = e.message
                            } finally {
                                createBusy = false
                            }
                        }
                    }
                ) { Text(if (createBusy) "Creating…" else "Create") }
            },
            dismissButton = {
                TextButton(enabled = !createBusy, onClick = { creating = false }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun OrbSkillDetailView(core: OrbCore, name: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var content by remember(name) { mutableStateOf("") }
    var original by remember(name) { mutableStateOf("") }
    var loaded by remember(name) { mutableStateOf(false) }
    var editing by remember(name) { mutableStateOf(false) }
    var saving by remember(name) { mutableStateOf(false) }
    var error by remember(name) { mutableStateOf<String?>(null) }
    var confirmDelete by remember(name) { mutableStateOf(false) }

    LaunchedEffect(name) {
        try {
            val d = core.fetchDict("/api/library/skill/${core.encodeComponent(name)}")
            content = OrbJSON.str(d, "content").orEmpty()
            original = content
            loaded = true
            error = null
        } catch (e: Throwable) {
            error = e.message
        }
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        OrbAdminHeader(
            title = name,
            onBack = onBack,
            trailing = {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(enabled = loaded && !saving, onClick = { editing = !editing }) {
                        Text(if (editing) "Done" else "Edit")
                    }
                    if (content != original) {
                        TextButton(enabled = !saving, onClick = {
                            val submitted = content
                            saving = true
                            scope.launch {
                                try {
                                    core.request("/api/library/skill/${core.encodeComponent(name)}", "PUT", body = mapOf("content" to submitted))
                                    core.request("/api/library/commit", "POST", body = mapOf("message" to "skill: update $name"))
                                    core.request("/api/library/push", "POST")
                                    original = submitted
                                    if (content == submitted) {
                                        editing = false
                                    }
                                    error = null
                                } catch (e: Throwable) {
                                    error = "Couldn’t save: ${e.message}"
                                } finally {
                                    saving = false
                                }
                            }
                        }) { Text(if (saving) "Saving…" else "Save") }
                    }
                }
            }
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            error?.let { Text(it, color = OrbStyle.error, fontSize = 13.sp) }
            if (editing) {
                OutlinedTextField(
                    value = content,
                    onValueChange = { content = it },
                    enabled = !saving,
                    textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 320.dp)
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(16.dp)
                ) {
                    val body = OrbAdminFormatting.skillBody(content)
                    Text(
                        text = if (!loaded) "Loading…" else body.ifEmpty { "(Empty skill)" },
                        color = OrbStyle.textPrimary,
                        fontSize = 13.sp,
                        lineHeight = 19.sp
                    )
                }
            }

            if (loaded) {
                TextButton(onClick = { confirmDelete = true }) {
                    Text("Delete skill…", color = OrbStyle.error)
                }
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = OrbStyle.elevated,
            title = { Text("Delete $name?", color = Color.White) },
            text = { Text("It leaves the Library and every agent.", color = OrbStyle.textSecondary) },
            confirmButton = {
                TextButton(enabled = !saving, onClick = {
                    confirmDelete = false
                    saving = true
                    scope.launch {
                        try {
                            core.request("/api/library/skill/${core.encodeComponent(name)}", "DELETE")
                            core.request("/api/library/commit", "POST", body = mapOf("message" to "skill: delete $name"))
                            core.request("/api/library/push", "POST")
                            onBack()
                        } catch (e: Throwable) {
                            error = e.message
                        } finally {
                            saving = false
                        }
                    }
                }) { Text("Delete", color = OrbStyle.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } }
        )
    }
}

// MARK: - 4. Assistant / Hermes (/api/cloud/hermes/settings)

@Composable
fun OrbHermesSettingsPage(core: OrbCore, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var rawState by remember { mutableStateOf<OrbDict?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var showSoulDialog by remember { mutableStateOf(false) }

    var useRouter by remember { mutableStateOf(true) }
    var defaultModel by remember { mutableStateOf("") }
    var reasoningEffort by remember { mutableStateOf("") }
    var memory by remember { mutableStateOf(true) }
    var memoryLimit by remember { mutableIntStateOf(8000) }
    var userProfile by remember { mutableStateOf(true) }
    var userLimit by remember { mutableIntStateOf(4000) }
    var compression by remember { mutableStateOf(true) }
    var compressionThreshold by remember { mutableDoubleStateOf(0.5) }
    var telegramProgress by remember { mutableStateOf("new") }
    var telegramCleanup by remember { mutableStateOf(false) }
    var soul by remember { mutableStateOf("") }

    fun applyState(s: OrbDict) {
        rawState = s
        useRouter = s["use_sandboxed_router"] == true
        defaultModel = OrbJSON.str(s, "default_model").orEmpty()
        reasoningEffort = OrbJSON.str(s, "reasoning_effort").orEmpty()
        memory = s["memory_enabled"] == true
        memoryLimit = (s["memory_char_limit"] as? Number)?.toInt() ?: 8000
        userProfile = s["user_profile_enabled"] == true
        userLimit = (s["user_char_limit"] as? Number)?.toInt() ?: 4000
        compression = s["compression_enabled"] == true
        compressionThreshold = (s["compression_threshold"] as? Number)?.toDouble() ?: 0.5
        telegramProgress = OrbJSON.str(s, "telegram_tool_progress")?.takeIf { it.isNotEmpty() } ?: "new"
        telegramCleanup = s["telegram_cleanup_progress"] == true
        soul = OrbJSON.str(s, "soul_markdown").orEmpty()
    }

    LaunchedEffect(Unit) {
        try {
            val s = core.fetchDict("/api/cloud/hermes/settings")
            applyState(s)
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        }
    }

    fun save(restart: Boolean) {
        if (busy) return
        val subDefaultModel = defaultModel
        val subReasoningEffort = reasoningEffort
        val subUseRouter = useRouter
        val subMemory = memory
        val subUserProfile = userProfile
        val subMemoryLimit = memoryLimit
        val subUserLimit = userLimit
        val subCompression = compression
        val subCompressionThreshold = compressionThreshold
        val subTelegramProgress = telegramProgress
        val subTelegramCleanup = telegramCleanup
        val subSoul = soul
        busy = true
        notice = null
        scope.launch {
            try {
                val body = mapOf(
                    "default_model" to subDefaultModel.trim(),
                    "reasoning_effort" to subReasoningEffort,
                    "use_sandboxed_router" to subUseRouter,
                    "memory_enabled" to subMemory,
                    "user_profile_enabled" to subUserProfile,
                    "memory_char_limit" to subMemoryLimit,
                    "user_char_limit" to subUserLimit,
                    "compression_enabled" to subCompression,
                    "compression_threshold" to subCompressionThreshold,
                    "telegram_tool_progress" to subTelegramProgress,
                    "telegram_cleanup_progress" to subTelegramCleanup,
                    "soul_markdown" to subSoul,
                    "restart_service" to restart
                )
                val updated = OrbJSON.dict(core.request("/api/cloud/hermes/settings", "PUT", body = body))
                if (updated != null) {
                    rawState = updated
                    if (useRouter == subUseRouter) useRouter = updated["use_sandboxed_router"] == true
                    if (defaultModel == subDefaultModel) defaultModel = OrbJSON.str(updated, "default_model").orEmpty()
                    if (reasoningEffort == subReasoningEffort) reasoningEffort = OrbJSON.str(updated, "reasoning_effort").orEmpty()
                    if (memory == subMemory) memory = updated["memory_enabled"] == true
                    if (memoryLimit == subMemoryLimit) memoryLimit = (updated["memory_char_limit"] as? Number)?.toInt() ?: 8000
                    if (userProfile == subUserProfile) userProfile = updated["user_profile_enabled"] == true
                    if (userLimit == subUserLimit) userLimit = (updated["user_char_limit"] as? Number)?.toInt() ?: 4000
                    if (compression == subCompression) compression = updated["compression_enabled"] == true
                    if (compressionThreshold == subCompressionThreshold) compressionThreshold = (updated["compression_threshold"] as? Number)?.toDouble() ?: 0.5
                    if (telegramProgress == subTelegramProgress) telegramProgress = OrbJSON.str(updated, "telegram_tool_progress")?.takeIf { it.isNotEmpty() } ?: "new"
                    if (telegramCleanup == subTelegramCleanup) telegramCleanup = updated["telegram_cleanup_progress"] == true
                    if (soul == subSoul) soul = OrbJSON.str(updated, "soul_markdown").orEmpty()
                }
                error = null
                notice = if (restart) "Saved configuration and restarted Hermes." else "Saved Hermes configuration."
            } catch (e: Throwable) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize().background(OrbStyle.background)) {
        OrbAdminHeader(title = "Assistant", onBack = onBack)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            error?.let { Text(it, color = OrbStyle.error, fontSize = 13.sp) }
            notice?.let { Text(it, color = OrbStyle.success, fontSize = 13.sp) }

            val state = rawState
            if (state == null && error == null) {
                Text("Loading Hermes settings…", color = OrbStyle.textMuted, fontSize = 13.sp)
            } else if (state != null) {
                // Runtime & gateway
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("Runtime & gateway", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    OrbAdminFormatting.hermesRuntime(OrbJSON.dict(state["runtime"])).forEach { (k, v) ->
                        OrbKeyValueLine(k, v)
                    }
                    OrbAdminFormatting.hermesSessions(OrbJSON.dict(state["sessions"]))?.let { line ->
                        OrbKeyValueLine("Sessions", line)
                    }
                }

                // Model & router
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("Model & router", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Route through Core router", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Switch(checked = useRouter, onCheckedChange = { useRouter = it }, enabled = !busy)
                    }
                    OrbMiniField("Default model", defaultModel, enabled = !busy) { defaultModel = it }
                    OrbMiniField("Reasoning effort (default / low / medium / high)", reasoningEffort, enabled = !busy) { reasoningEffort = it }
                }

                // Memory & compression
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("Memory & compression", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Persistent memory (MEMORY.md)", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Switch(checked = memory, onCheckedChange = { memory = it }, enabled = !busy)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("User profile memory (USER.md)", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Switch(checked = userProfile, onCheckedChange = { userProfile = it }, enabled = !busy)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Context auto-compression", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Switch(checked = compression, onCheckedChange = { compression = it }, enabled = !busy)
                    }
                    if (compression) {
                        Text("Threshold ${(compressionThreshold * 100).roundToInt()}% of context", color = OrbStyle.textSecondary, fontSize = 12.sp)
                        Slider(
                            value = compressionThreshold.toFloat(),
                            onValueChange = { compressionThreshold = ((it * 20).roundToInt() / 20.0) },
                            enabled = !busy,
                            valueRange = 0.1f..0.95f
                        )
                    }
                }

                // Channels & Persona (SOUL.md pushed into dedicated modal!)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("Channels & persona", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Clean up Telegram progress", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Switch(checked = telegramCleanup, onCheckedChange = { telegramCleanup = it }, enabled = !busy)
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .orbPressClickable(enabled = !busy) { showSoulDialog = true }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Persona (SOUL.md)", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Text(
                            text = if (soul.isBlank()) "Empty" else "${soul.length} chars",
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace
                        )
                        Spacer(Modifier.width(6.dp))
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
                    }
                }

                // Save buttons
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(14.dp))
                            .background(Color.White)
                            .orbPressClickable(enabled = !busy) { save(restart = false) }
                            .padding(vertical = 13.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(if (busy) "Saving…" else "Save", color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                            .orbPressClickable(enabled = !busy) { save(restart = true) }
                            .padding(vertical = 13.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("Save & restart", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
        }
    }

    if (showSoulDialog) {
        AlertDialog(
            onDismissRequest = { showSoulDialog = false },
            containerColor = OrbStyle.elevated,
            title = { Text("Persona (SOUL.md)", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
            text = {
                OutlinedTextField(
                    value = soul,
                    onValueChange = { soul = it },
                    enabled = !busy,
                    textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 260.dp)
                )
            },
            confirmButton = {
                TextButton(onClick = { showSoulDialog = false }) { Text("Done") }
            }
        )
    }
}
