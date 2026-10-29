package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import sh.sandboxed.dashboard.BuildConfig
import java.time.Instant

/** Plain-text diagnostics, shared by the Debug info page and "Copy diagnostics". */
object OrbDiagnostics {
    fun build(
        context: Context,
        endpoint: String,
        token: String?,
        lastRefreshAtMs: Long?,
        errors: List<OrbLog.Entry>,
        backendVersion: String? = null,
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

    fun text(rows: List<Pair<String, String>>, errors: List<OrbLog.Entry>): String = buildString {
        rows.forEach { (k, v) -> append(k).append(": ").append(v).append('\n') }
        if (errors.isNotEmpty()) {
            append("\n--- errors (oldest first) ---\n")
            errors.forEach { append(it.format()).append('\n') }
        }
    }
}

@Composable
fun OrbDebugInfoPage(core: OrbCore, onBack: () -> Unit) {
    val context = LocalContext.current
    val endpoint by core.baseURLFlow.collectAsState()
    val lastRefresh by core.lastRefreshAtMs.collectAsState()
    val errors by OrbLog.ring.collectAsState()
    var backendVersion by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(endpoint) {
        backendVersion = null
        if (endpoint.isBlank()) return@LaunchedEffect
        backendVersion = try {
            OrbDiagnostics.backendVersion(core.request("/api/health", allowAuthRetry = false))
        } catch (c: kotlinx.coroutines.CancellationException) {
            throw c
        } catch (t: Throwable) {
            null
        }
    }
    val rows = OrbDiagnostics.build(context, endpoint, core.token, lastRefresh, errors, backendVersion)
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
                    val text = OrbDiagnostics.text(rows, errors)
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.setPrimaryClip(ClipData.newPlainText("Orb diagnostics", text))
                    Toast.makeText(context, "Diagnostics copied", Toast.LENGTH_SHORT).show()
                }
                .padding(vertical = 13.dp),
            contentAlignment = Alignment.Center
        ) {
            Text("Copy diagnostics", color = Color.Black, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
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
}
