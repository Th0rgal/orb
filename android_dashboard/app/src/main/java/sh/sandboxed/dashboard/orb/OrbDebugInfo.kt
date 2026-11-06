package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.provider.OpenableColumns
import android.os.Handler
import android.os.HandlerThread
import android.view.FrameMetrics
import android.view.Window
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.sandboxed.dashboard.BuildConfig
import java.time.Instant
import java.time.LocalDate

/**
 * Lightweight frame-stall and slow-request telemetry matching desktop `orb/src/diagnostics.ts`.
 * Uses Android's `Window.OnFrameMetricsAvailableListener` on a background HandlerThread so
 * monitoring never allocates or blocks on the UI thread.
 */
object OrbPerfMonitor {
    const val STALL_THRESHOLD_MS = 32L
    const val SLOW_REQUEST_THRESHOLD_MS = 1_500L
    private const val MAX_SLOW_REQUESTS = 20

    data class SlowRequest(
        val method: String,
        val path: String,
        val durationMs: Long,
        val bytes: Int,
        val atEpochMs: Long = System.currentTimeMillis()
    ) {
        fun format(): String {
            val cleanPath = sanitizePath(path)
            val kb = bytes / 1024
            return "${Instant.ofEpochMilli(atEpochMs)} $method $cleanPath ${durationMs}ms (${kb}KB)"
        }
    }

    data class Snapshot(
        val totalFrames: Long = 0L,
        val stalledFrames: Long = 0L,
        val worstFrameMs: Long = 0L,
        val slowRequests: List<SlowRequest> = emptyList()
    ) {
        fun stallsSummary(): String =
            if (totalFrames == 0L) "0"
            else "$stalledFrames / $totalFrames (worst ${worstFrameMs}ms)"

        fun slowRequestsSummary(): String =
            if (slowRequests.isEmpty()) "0"
            else "${slowRequests.size} (worst ${slowRequests.maxOf { it.durationMs }}ms)"
    }

    private val lock = Any()
    private var totalFrames = 0L
    private var stalledFrames = 0L
    private var worstFrameMs = 0L
    private val slowRing = ArrayDeque<SlowRequest>(MAX_SLOW_REQUESTS)
    private val _snapshot = MutableStateFlow(Snapshot())
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    private var metricsThread: HandlerThread? = null
    private var metricsHandler: Handler? = null
    private val listener = Window.OnFrameMetricsAvailableListener { _, frameMetrics, _ ->
        val totalNs = frameMetrics.getMetric(FrameMetrics.TOTAL_DURATION)
        if (totalNs > 0L) {
            recordFrameDurationMs(totalNs / 1_000_000L)
        }
    }

    fun attach(window: Window) {
        try {
            val handler = synchronized(lock) {
                metricsHandler ?: run {
                    val thread = HandlerThread("orb-frame-metrics").apply { start() }
                    metricsThread = thread
                    Handler(thread.looper).also { metricsHandler = it }
                }
            }
            window.addOnFrameMetricsAvailableListener(listener, handler)
        } catch (_: Throwable) {
            // Robolectric / headless test windows may not back FrameMetrics.
        }
    }

    fun detach(window: Window) {
        try {
            window.removeOnFrameMetricsAvailableListener(listener)
        } catch (_: Throwable) {
        }
    }

    fun recordFrameDurationMs(durationMs: Long) {
        if (durationMs < 0L) return
        var emit: Snapshot? = null
        synchronized(lock) {
            totalFrames += 1L
            var changed = false
            if (durationMs > worstFrameMs) {
                worstFrameMs = durationMs
                changed = true
            }
            if (durationMs > STALL_THRESHOLD_MS) {
                stalledFrames += 1L
                changed = true
            }
            if (changed || totalFrames % 120L == 0L) {
                emit = Snapshot(totalFrames, stalledFrames, worstFrameMs, slowRing.toList())
            }
        }
        emit?.let { _snapshot.value = it }
    }

    fun recordSlowRequest(
        method: String,
        path: String,
        durationMs: Long,
        bytes: Int,
        atEpochMs: Long = System.currentTimeMillis()
    ) {
        if (durationMs < SLOW_REQUEST_THRESHOLD_MS) return
        val next = synchronized(lock) {
            if (slowRing.size >= MAX_SLOW_REQUESTS) slowRing.removeFirst()
            slowRing.addLast(
                SlowRequest(
                    method = method,
                    path = sanitizePath(path),
                    durationMs = durationMs,
                    bytes = bytes,
                    atEpochMs = atEpochMs
                )
            )
            Snapshot(totalFrames, stalledFrames, worstFrameMs, slowRing.toList())
        }
        _snapshot.value = next
    }

    fun resetForTest() {
        synchronized(lock) {
            totalFrames = 0L
            stalledFrames = 0L
            worstFrameMs = 0L
            slowRing.clear()
        }
        _snapshot.value = Snapshot()
    }

    internal fun sanitizePath(path: String): String {
        val qIdx = path.indexOf('?')
        if (qIdx < 0) return path
        val base = path.substring(0, qIdx)
        val query = path.substring(qIdx + 1)
            .split('&')
            .filter { it.isNotEmpty() }
            .joinToString("&") { part ->
                val eq = part.indexOf('=')
                val key = if (eq >= 0) part.substring(0, eq) else part
                if (key.lowercase() in setOf("token", "access_token", "api_key", "secret", "code", "state")) {
                    "$key=<redacted>"
                } else {
                    part
                }
            }
        return if (query.isEmpty()) base else "$base?$query"
    }
}

/** Plain-text diagnostics, shared by the Debug info page and "Copy diagnostics". */
object OrbDiagnostics {
    fun build(
        context: Context,
        endpoint: String,
        token: String?,
        lastRefreshAtMs: Long?,
        errors: List<OrbLog.Entry>,
        backendVersion: String? = null,
        perf: OrbPerfMonitor.Snapshot = OrbPerfMonitor.snapshot.value,
    ): List<Pair<String, String>> {
        val (permitted, channels) = OrbNotifications.diagnostics(context)
        val account = tokenSubject(token) ?: if (token.isNullOrBlank()) "signed out" else "token (opaque)"
        return buildList {
            add("Version" to "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            add("Application ID" to BuildConfig.APPLICATION_ID)
            add("Build type" to BuildConfig.BUILD_TYPE)
            add("Endpoint" to endpoint.ifEmpty { "not configured" })
            add("Core version" to (backendVersion?.takeIf { it.isNotBlank() } ?: "unknown"))
            add("Account" to account)
            add("Last refresh" to (lastRefreshAtMs?.let { Instant.ofEpochMilli(it).toString() } ?: "never"))
            add("UI stalls (>32ms)" to perf.stallsSummary())
            add("Slow requests (>=1.5s)" to perf.slowRequestsSummary())
            add("Notification permission" to if (permitted) "granted" else "denied")
            add("In-app notifications" to if (OrbNotifications.notificationsEnabled) "on" else "off")
            for (ch in channels) {
                add("Channel ${ch.id}" to "${if (ch.enabled) "enabled" else "disabled"} · importance ${ch.importance}")
            }
            add("Recent errors" to errors.size.toString())
        }
    }

    /** Core's version from a `/api/health` response; null when the server omits it. */
    fun backendVersion(health: Any?): String? =
        OrbJSON.str(OrbJSON.dict(health), "version")?.trim()?.takeIf { it.isNotEmpty() }

    fun text(
        rows: List<Pair<String, String>>,
        errors: List<OrbLog.Entry>,
        perf: OrbPerfMonitor.Snapshot = OrbPerfMonitor.snapshot.value
    ): String = buildString {
        rows.forEach { (k, v) -> append(k).append(": ").append(v).append('\n') }
        if (perf.slowRequests.isNotEmpty()) {
            append("\n--- slow requests (oldest first) ---\n")
            perf.slowRequests.forEach { append(it.format()).append('\n') }
        }
        if (errors.isNotEmpty()) {
            append("\n--- errors (oldest first) ---\n")
            errors.forEach { append(it.format()).append('\n') }
        }
    }
}

@Composable
fun OrbDebugInfoPage(core: OrbCore, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val endpoint by core.baseURLFlow.collectAsState()
    val signedInToken by core.tokenFlow.collectAsState()
    val lastRefresh by core.lastRefreshAtMs.collectAsState()
    val errors by OrbLog.ring.collectAsState()
    val perf by OrbPerfMonitor.snapshot.collectAsState()
    var backendVersion by remember { mutableStateOf<String?>(null) }
    var authRequired by remember { mutableStateOf(true) }

    var cleanupLoaded by remember { mutableStateOf(false) }
    var cleanupEnabled by remember { mutableStateOf(false) }
    var cleanupBaseEnabled by remember { mutableStateOf(false) }
    var cleanupRawDays by remember { mutableStateOf<Int?>(null) }
    var cleanupDays by remember { mutableStateOf(OrbBackupArchive.DEFAULT_CLEANUP_RETENTION_DAYS.toString()) }
    var cleanupDaysEdited by remember { mutableStateOf(false) }
    var cleanupDirty by remember { mutableStateOf(false) }
    var cleanupSaving by remember { mutableStateOf(false) }
    var cleanupSaveSeq by remember { mutableStateOf(0) }
    var cleanupNotice by remember { mutableStateOf<String?>(null) }
    var cleanupError by remember { mutableStateOf<String?>(null) }

    var backupBusy by remember { mutableStateOf(false) }
    var backupNotice by remember { mutableStateOf<String?>(null) }
    var backupError by remember { mutableStateOf<String?>(null) }
    var pendingDownloadBytes by remember { mutableStateOf<ByteArray?>(null) }
    var pendingRestore by remember { mutableStateOf<Pair<String, ByteArray>?>(null) }

    suspend fun loadCleanupSettings(expectedScope: String = "${core.baseURL}|${core.token}") {
        if (!core.isConfigured) return
        try {
            val s = core.fetchDict("/api/settings")
            if ("${core.baseURL}|${core.token}" != expectedScope) return
            if (!cleanupDirty) {
                val isOn = OrbJSON.bool(s, "auto_cleanup_enabled") == true
                val configuredDays = OrbJSON.int(s, "auto_cleanup_days")?.takeIf { it >= 1 }
                cleanupEnabled = isOn
                cleanupBaseEnabled = isOn
                cleanupRawDays = configuredDays
                cleanupDays = OrbBackupArchive.effectiveCleanupDays(configuredDays).toString()
                cleanupDaysEdited = false
            }
            cleanupLoaded = true
        } catch (c: CancellationException) {
            throw c
        } catch (_: Throwable) {
        }
    }

    val saveBackupLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip")
    ) { uri ->
        val bytes = pendingDownloadBytes
        pendingDownloadBytes = null
        if (uri == null || bytes == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { out -> out.write(bytes) }
                        ?: error("Could not open destination file")
                }
            }.onSuccess {
                backupNotice = "Saved backup archive."
                backupError = null
            }.onFailure { err ->
                backupError = err.message ?: "Failed to save backup archive"
            }
        }
    }

    val openBackupLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    var displayName = "orb-backup.zip"
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (idx >= 0) {
                                cursor.getString(idx)?.takeIf { it.isNotBlank() }?.let { displayName = it }
                            }
                        }
                    }
                    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: error("Could not read backup archive")
                    if (bytes.isEmpty()) error("Selected archive is empty.")
                    displayName to bytes
                }
            }.onSuccess { loaded ->
                pendingRestore = loaded
                backupError = null
            }.onFailure { err ->
                backupError = err.message ?: "Failed to read backup archive"
            }
        }
    }

    LaunchedEffect(endpoint, signedInToken) {
        val reqScope = "$endpoint|$signedInToken"
        backendVersion = null
        cleanupSaveSeq += 1
        cleanupSaving = false
        cleanupLoaded = false
        cleanupDaysEdited = false
        cleanupDirty = false
        cleanupError = null
        cleanupNotice = null
        if (endpoint.isBlank()) return@LaunchedEffect
        val health = try {
            core.request("/api/health", allowAuthRetry = false)
        } catch (c: CancellationException) {
            throw c
        } catch (_: Throwable) {
            null
        }
        if ("${core.baseURL}|${core.token}" != reqScope) return@LaunchedEffect
        backendVersion = OrbDiagnostics.backendVersion(health)
        val healthDict = OrbJSON.dict(health)
        authRequired = OrbJSON.bool(healthDict, "auth_required") ?: true
        loadCleanupSettings(reqScope)
    }
    val rows = OrbDiagnostics.build(context, endpoint, core.token, lastRefresh, errors, backendVersion, perf)
    val channelRows = rows.filter { it.first.startsWith("Channel ") }
    val summaryRows = rows.filterNot {
        it.first == "Notification permission" || it.first == "In-app notifications" || it.first.startsWith("Channel ")
    }
    val (permitted, channels) = remember(context) { OrbNotifications.diagnostics(context) }
    var showChannels by remember { mutableStateOf(false) }
    var selectedError by remember { mutableStateOf<OrbActivityCompaction.CoalescedError?>(null) }

    val coalescedErrors = remember(errors) {
        OrbActivityCompaction.coalesceErrors(
            errors.asReversed().map { e ->
                OrbActivityCompaction.ErrorInput(
                    category = "${e.level.name.first()} ${e.category.tag}",
                    summary = e.message,
                    detail = e.detail ?: "",
                    at = e.atEpochMs
                )
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .padding(horizontal = 20.dp, vertical = 16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
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
                text = "Debug info",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.width(38.dp))
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            summaryRows.forEach { (k, v) ->
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(k, color = OrbStyle.textMuted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(0.42f))
                    Text(v, color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(0.58f))
                }
            }
            val enabledCount = channels.count { it.enabled }
            val notifSummary = (if (permitted) "Granted" else "Denied") +
                " · " + (if (OrbNotifications.notificationsEnabled) "In-app on" else "In-app off") +
                " · $enabledCount/${channels.size} channels"
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .orbPressClickable { showChannels = !showChannels },
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Notifications", color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.weight(0.42f))
                Row(modifier = Modifier.weight(0.58f), verticalAlignment = Alignment.CenterVertically) {
                    Text(notifSummary, color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Icon(
                        imageVector = if (showChannels) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                        contentDescription = null,
                        tint = OrbStyle.textMuted,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
            if (showChannels) {
                channelRows.forEach { (k, v) ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(start = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Text(k.removePrefix("Channel "), color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(0.45f))
                        Text(v, color = OrbStyle.textSecondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(0.55f))
                    }
                }
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White)
                .orbPressClickable {
                    val text = OrbDiagnostics.text(rows, errors, perf)
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.setPrimaryClip(ClipData.newPlainText("Orb diagnostics", text))
                    Toast.makeText(context, "Diagnostics copied", Toast.LENGTH_SHORT).show()
                }
                .padding(vertical = 13.dp),
            contentAlignment = Alignment.Center
        ) {
            Text("Copy diagnostics", color = Color.Black, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }

        if (core.isConfigured && (!signedInToken.isNullOrEmpty() || !authRequired)) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text("Workspace cleanup", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    "Audits terminal mission workspaces past retention (1–365 days, default 1). Resumable, failed, and unmatched directories are always kept.",
                    color = OrbStyle.textMuted,
                    fontSize = 12.sp
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Terminal workspace retention sweep", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    Switch(
                        checked = cleanupEnabled,
                        enabled = cleanupLoaded && !cleanupSaving,
                        onCheckedChange = {
                            cleanupEnabled = it
                            cleanupDirty = true
                            cleanupNotice = null
                        }
                    )
                }
                OutlinedTextField(
                    value = cleanupDays,
                    onValueChange = {
                        cleanupDays = it
                        cleanupDaysEdited = true
                        cleanupDirty = true
                        cleanupNotice = null
                    },
                    enabled = cleanupLoaded && !cleanupSaving,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    label = { Text("Completed retention (days)") },
                    modifier = Modifier.fillMaxWidth()
                )
                TextButton(
                    enabled = cleanupLoaded && !cleanupSaving && cleanupDirty,
                    onClick = {
                        val days = OrbBackupArchive.parseCleanupDays(cleanupDays).getOrElse { err ->
                            cleanupError = err.message
                            return@TextButton
                        }
                        val includeDays = cleanupDaysEdited || cleanupRawDays != null
                        if (!includeDays && cleanupEnabled == cleanupBaseEnabled) {
                            cleanupDirty = false
                            return@TextButton
                        }
                        val reqScope = "${core.baseURL}|${core.token}"
                        cleanupSaveSeq += 1
                        val seq = cleanupSaveSeq
                        cleanupSaving = true
                        cleanupError = null
                        cleanupNotice = null
                        scope.launch {
                            try {
                                val payload = LinkedHashMap<String, Any?>().apply {
                                    put("auto_cleanup_enabled", cleanupEnabled)
                                    if (includeDays) put("auto_cleanup_days", days)
                                }
                                val updated = OrbJSON.dict(
                                    core.request(
                                        "/api/settings",
                                        "PUT",
                                        body = payload
                                    )
                                )
                                if (cleanupSaveSeq == seq && "${core.baseURL}|${core.token}" == reqScope) {
                                    val isOn = OrbJSON.bool(updated, "auto_cleanup_enabled") ?: cleanupEnabled
                                    val nextRawDays = OrbJSON.int(updated, "auto_cleanup_days")?.takeIf { it >= 1 }
                                        ?: (if (includeDays) days else null)
                                    cleanupEnabled = isOn
                                    cleanupBaseEnabled = isOn
                                    cleanupRawDays = nextRawDays
                                    cleanupDays = OrbBackupArchive.effectiveCleanupDays(nextRawDays).toString()
                                    cleanupDaysEdited = false
                                    cleanupDirty = false
                                    cleanupNotice = "Saved workspace cleanup policy."
                                }
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Throwable) {
                                if (cleanupSaveSeq == seq && "${core.baseURL}|${core.token}" == reqScope) {
                                    cleanupError = e.message ?: "Failed to save cleanup policy"
                                }
                            } finally {
                                if (cleanupSaveSeq == seq && "${core.baseURL}|${core.token}" == reqScope) {
                                    cleanupSaving = false
                                }
                            }
                        }
                    }
                ) {
                    Text(if (cleanupSaving) "Saving…" else "Save cleanup policy")
                }
                cleanupNotice?.let { Text(it, color = OrbStyle.success, fontSize = 12.sp) }
                cleanupError?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("Backup & restore", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    "Exports or restores server configuration, credentials, and workspace metadata. Requires device approval when enforced.",
                    color = OrbStyle.textMuted,
                    fontSize = 12.sp
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    TextButton(
                        enabled = !backupBusy,
                        onClick = {
                            backupBusy = true
                            backupError = null
                            backupNotice = null
                            scope.launch {
                                try {
                                    val bytes = OrbApprovalKey.signedRequestBytes(
                                        core = core,
                                        activity = context.fragmentActivity(),
                                        method = "GET",
                                        path = "/api/settings/backup",
                                        summary = "Download settings backup"
                                    )
                                    if (bytes.isEmpty()) {
                                        backupError = "Core returned an empty backup archive."
                                    } else {
                                        pendingDownloadBytes = bytes
                                        saveBackupLauncher.launch("orb-backup-${LocalDate.now()}.zip")
                                    }
                                } catch (_: OrbApprovalKey.Cancelled) {
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Throwable) {
                                    backupError = e.message ?: "Failed to download backup"
                                } finally {
                                    backupBusy = false
                                }
                            }
                        }
                    ) {
                        Text(if (backupBusy) "Working…" else "Download backup (.zip)")
                    }
                    TextButton(
                        enabled = !backupBusy,
                        onClick = {
                            backupError = null
                            backupNotice = null
                            openBackupLauncher.launch(arrayOf("application/zip", "application/octet-stream"))
                        }
                    ) {
                        Text("Restore from backup…", color = OrbStyle.error)
                    }
                }
                backupNotice?.let { Text(it, color = OrbStyle.success, fontSize = 12.sp) }
                backupError?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
            }
        }

        if (perf.slowRequests.isNotEmpty()) {
            Text("Slow requests", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            perf.slowRequests.asReversed().take(8).forEach { req ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.card)
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            text = "${req.method} ${req.path}",
                            color = OrbStyle.textPrimary,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        Text(
                            text = "${req.durationMs}ms",
                            color = OrbStyle.warning,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                    Text(
                        text = "${req.bytes / 1024} KB · ${Instant.ofEpochMilli(req.atEpochMs)}",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }

        Text("Recent errors", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        if (coalescedErrors.isEmpty()) {
            Text("None since the app started.", color = OrbStyle.textMuted, fontSize = 13.sp)
        } else {
            coalescedErrors.forEach { entry ->
                val isErr = entry.category.startsWith("E ")
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.card)
                        .orbPressClickable { selectedError = entry }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            text = "${entry.category}: ${entry.summary}",
                            color = if (isErr) OrbStyle.error else OrbStyle.textPrimary,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        if (entry.count > 1) {
                            Text(
                                text = "×${entry.count}",
                                color = OrbStyle.warning,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                fontFamily = FontFamily.Monospace,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(OrbStyle.surface)
                                    .padding(horizontal = 7.dp, vertical = 2.dp)
                            )
                        }
                    }
                    val secondLine = entry.detail.lineSequence().firstOrNull()?.trim().orEmpty()
                    if (secondLine.isNotEmpty()) {
                        Text(
                            text = secondLine,
                            color = OrbStyle.textMuted,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }

    selectedError?.let { err ->
        val fullText = buildString {
            append(Instant.ofEpochMilli(err.at)).append(' ').append(err.category).append(": ").append(err.summary)
            if (err.count > 1) append(" (×").append(err.count).append(')')
            if (err.detail.isNotBlank()) append("\n\n").append(err.detail)
        }
        AlertDialog(
            onDismissRequest = { selectedError = null },
            containerColor = OrbStyle.elevated,
            title = { Text("Error detail", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
            text = {
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text(fullText, color = OrbStyle.textSecondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.setPrimaryClip(ClipData.newPlainText("Orb error", fullText))
                    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                    selectedError = null
                }) { Text("Copy") }
            },
            dismissButton = {
                TextButton(onClick = { selectedError = null }) { Text("Close") }
            }
        )
    }

    pendingRestore?.let { (name, bytes) ->
        AlertDialog(
            onDismissRequest = { if (!backupBusy) pendingRestore = null },
            containerColor = OrbStyle.elevated,
            title = { Text("Restore backup archive?", color = Color.White, fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    "Restoring $name overwrites server settings, provider credentials, and workspaces stored in the backup.",
                    color = OrbStyle.textSecondary,
                    fontSize = 13.sp
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !backupBusy,
                    onClick = {
                        backupBusy = true
                        backupError = null
                        backupNotice = null
                        scope.launch {
                            try {
                                val payload = OrbBackupArchive.buildRestoreMultipart(bytes, name)
                                val res = OrbJSON.dict(
                                    OrbApprovalKey.signedMultipartRequest(
                                        core = core,
                                        activity = context.fragmentActivity(),
                                        method = "POST",
                                        path = "/api/settings/restore",
                                        rawBytes = payload.body,
                                        contentType = payload.contentType,
                                        summary = "Restore settings backup"
                                    )
                                )
                                pendingRestore = null
                                val (ok, msg) = OrbBackupArchive.interpretRestoreResponse(res)
                                if (ok) {
                                    backupNotice = msg
                                    loadCleanupSettings()
                                } else {
                                    backupError = msg
                                }
                            } catch (_: OrbApprovalKey.Cancelled) {
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Throwable) {
                                backupError = e.message ?: "Failed to restore backup"
                            } finally {
                                backupBusy = false
                            }
                        }
                    }
                ) {
                    Text(if (backupBusy) "Restoring…" else "Restore", color = OrbStyle.error)
                }
            },
            dismissButton = {
                TextButton(enabled = !backupBusy, onClick = { pendingRestore = null }) { Text("Cancel") }
            }
        )
    }
}
