package sh.sandboxed.dashboard.orb

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.security.MessageDigest
import java.util.UUID

/**
 * Deterministic multipart archive builder and cleanup retention parser, matching
 * desktop `orb/src/accountAdmin.ts` and iOS `OrbBackupArchive` in `OrbGitHubSignIn.swift`.
 */
object OrbBackupArchive {
    /** Matches `src/api/mission_workspace_gc.rs::DEFAULT_RETENTION_DAYS`. */
    const val DEFAULT_CLEANUP_RETENTION_DAYS = 1

    fun effectiveCleanupDays(days: Int?): Int =
        if (days != null && days >= 1) days else DEFAULT_CLEANUP_RETENTION_DAYS

    data class MultipartPayload(
        val body: ByteArray,
        val contentType: String,
        val sha256Hex: String
    )

    fun buildRestoreMultipart(
        zipBytes: ByteArray,
        filename: String = "orb-backup.zip",
        boundary: String = "----OrbRestore" + UUID.randomUUID().toString().replace("-", "")
    ): MultipartPayload {
        val safeName = filename
            .replace("\"", "")
            .replace("\r", "")
            .replace("\n", "")
            .ifEmpty { "orb-backup.zip" }
        val head = "--$boundary\r\nContent-Disposition: form-data; name=\"backup\"; filename=\"$safeName\"\r\nContent-Type: application/zip\r\n\r\n"
            .toByteArray(Charsets.UTF_8)
        val tail = "\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8)
        val body = ByteArray(head.size + zipBytes.size + tail.size)
        System.arraycopy(head, 0, body, 0, head.size)
        System.arraycopy(zipBytes, 0, body, head.size, zipBytes.size)
        System.arraycopy(tail, 0, body, head.size + zipBytes.size, tail.size)
        val sha = MessageDigest.getInstance("SHA-256")
            .digest(body)
            .joinToString("") { "%02x".format(it) }
        return MultipartPayload(
            body = body,
            contentType = "multipart/form-data; boundary=$boundary",
            sha256Hex = sha
        )
    }

    fun parseCleanupDays(raw: String): Result<Int> {
        val trimmed = raw.trim()
        val value = trimmed.toIntOrNull()
            ?: return Result.failure(IllegalArgumentException("Retention days must be a whole number between 1 and 365."))
        if (value !in 1..365) {
            return Result.failure(IllegalArgumentException("Retention days must be between 1 and 365."))
        }
        return Result.success(value)
    }

    fun interpretRestoreResponse(res: OrbDict?): Pair<Boolean, String> {
        val success = OrbJSON.bool(res, "success") == true
        val restored = OrbJSON.strList(res, "restored_files")
        val errors = OrbJSON.strList(res, "errors")
        val rawMessage = OrbJSON.str(res, "message").orEmpty()
        if (!success) {
            val base = rawMessage.ifEmpty { "No files were restored. The backup may be empty or invalid." }
            val full = if (errors.isEmpty()) base else "$base (${errors.joinToString("; ")})"
            return false to full
        }
        val summary = rawMessage.ifEmpty {
            if (restored.isEmpty()) "Backup restored."
            else "Restored ${restored.size} files (${restored.joinToString(", ")})."
        }
        return true to summary
    }
}

/** Single-tenant password rotation dialog (`GET /api/auth/status`, `POST /api/auth/change-password`). */
@Composable
fun OrbChangePasswordDialog(
    core: OrbCore,
    onDismiss: () -> Unit,
    onSaved: (String) -> Unit
) {
    val scope = rememberCoroutineScope()
    var requiresCurrent by remember { mutableStateOf(true) }
    var currentPassword by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var confirmPassword by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        runCatching { core.fetchDict("/api/auth/status") }.onSuccess { st ->
            val devMode = OrbJSON.bool(st, "dev_mode") == true
            val source = OrbJSON.str(st, "password_source").orEmpty()
            requiresCurrent = !devMode && source != "none"
        }
    }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        containerColor = OrbStyle.elevated,
        title = { Text("Change password", color = Color.White, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                error?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
                if (requiresCurrent) {
                    OutlinedTextField(
                        value = currentPassword,
                        onValueChange = { currentPassword = it; error = null },
                        enabled = !saving,
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        label = { Text("Current password") },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                OutlinedTextField(
                    value = newPassword,
                    onValueChange = { newPassword = it; error = null },
                    enabled = !saving,
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    label = { Text("New password (at least 8 chars)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = confirmPassword,
                    onValueChange = { confirmPassword = it; error = null },
                    enabled = !saving,
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    label = { Text("Confirm new password") },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving && newPassword.isNotEmpty(),
                onClick = {
                    if (requiresCurrent && currentPassword.isEmpty()) {
                        error = "Enter your current password."
                        return@TextButton
                    }
                    if (newPassword.length < 8) {
                        error = "New password must be at least 8 characters."
                        return@TextButton
                    }
                    if (newPassword != confirmPassword) {
                        error = "New passwords do not match."
                        return@TextButton
                    }
                    saving = true
                    error = null
                    scope.launch {
                        try {
                            val body = LinkedHashMap<String, Any?>().apply {
                                put("new_password", newPassword)
                                if (requiresCurrent) put("current_password", currentPassword)
                            }
                            val res = OrbJSON.dict(
                                core.request(
                                    "/api/auth/change-password",
                                    "POST",
                                    body = body,
                                    allowAuthRetry = false
                                )
                            )
                            core.configureSession(core.baseURL, core.token, newPassword, core.savedUsername())
                            val msg = OrbJSON.str(res, "message") ?: "Server password updated."
                            onSaved(msg)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Throwable) {
                            error = e.message ?: "Could not update password"
                        } finally {
                            saving = false
                        }
                    }
                }
            ) { Text(if (saving) "Saving…" else "Update") }
        },
        dismissButton = {
            TextButton(enabled = !saving, onClick = onDismiss) { Text("Cancel") }
        }
    )
}

/** GitHub device-flow integration (`Settings → Account`) for `git push` and `gh` inside mission workspaces. */
@Composable
fun OrbGitHubIntegrationCard(core: OrbCore) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<OrbDict?>(null) }
    var authorizeState by remember { mutableStateOf<OrbDict?>(null) }
    var busy by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun refresh() {
        runCatching { core.fetchDict("/api/integrations/github/status") }.onSuccess { s ->
            status = s
            if (OrbJSON.bool(s, "connected") == true) {
                authorizeState = null
            } else if (OrbJSON.bool(s, "pending") == true && !OrbJSON.str(s, "user_code").isNullOrEmpty() && authorizeState == null) {
                authorizeState = s
            }
        }
    }

    LaunchedEffect(core.baseURL) {
        refresh()
    }

    LaunchedEffect(authorizeState) {
        val auth = authorizeState ?: return@LaunchedEffect
        val intervalMs = (((auth["interval"] as? Number)?.toLong() ?: 5L).coerceAtLeast(4L)) * 1_000L
        while (isActive && authorizeState != null) {
            delay(intervalMs)
            refresh()
        }
    }

    val connected = OrbJSON.bool(status, "connected") == true
    val oauthConfigured = status?.let {
        if (it.containsKey("configured") && it["configured"] != null) OrbJSON.bool(it, "configured") != false else true
    } ?: true
    val login = OrbJSON.str(status, "login") ?: OrbJSON.str(OrbJSON.dict(status?.get("user")), "login")
    val scopeList = OrbJSON.strList(status, "scopes")
    val scopes = if (scopeList.isNotEmpty()) scopeList.joinToString(", ") else OrbJSON.str(status, "scopes")

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "GITHUB MISSION CREDENTIALS",
            color = OrbStyle.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.6.sp
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(OrbStyle.surface)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = when {
                            status == null -> "Checking GitHub status…"
                            connected -> if (!login.isNullOrBlank()) "Connected as @$login" else "Connected to GitHub"
                            else -> "GitHub account"
                        },
                        color = Color.White,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        text = when {
                            connected && !scopes.isNullOrBlank() -> "Scopes: $scopes"
                            connected -> "Available to mission workspaces."
                            !oauthConfigured -> "Configure GITHUB_OAUTH_CLIENT_ID on Core to connect."
                            else -> "Authorize git push and gh inside mission workspaces."
                        },
                        color = OrbStyle.textMuted,
                        fontSize = 12.sp,
                        lineHeight = 17.sp
                    )
                }
                if (connected) {
                    TextButton(enabled = !busy, onClick = { confirmDisconnect = true }) {
                        Text("Disconnect", color = OrbStyle.error)
                    }
                } else {
                    TextButton(
                        enabled = !busy && oauthConfigured,
                        onClick = {
                            busy = true
                            error = null
                            scope.launch {
                                try {
                                    val res = OrbJSON.dict(core.request("/api/integrations/github/authorize", "POST"))
                                        ?: emptyMap()
                                    authorizeState = res
                                    val code = OrbJSON.str(res, "user_code").orEmpty()
                                    if (code.isNotEmpty()) {
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                        cm?.setPrimaryClip(ClipData.newPlainText("GitHub device code", code))
                                        Toast.makeText(context, "Copied code $code", Toast.LENGTH_SHORT).show()
                                    }
                                    val uri = OrbJSON.str(res, "verification_uri")
                                    if (!uri.isNullOrBlank()) {
                                        runCatching {
                                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                        }
                                    }
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Throwable) {
                                    error = e.message ?: "Could not start GitHub authorization"
                                } finally {
                                    busy = false
                                }
                            }
                        }
                    ) {
                        Text(if (busy) "Starting…" else if (authorizeState != null) "Restart" else "Connect")
                    }
                }
            }

            authorizeState?.let { auth ->
                val userCode = OrbJSON.str(auth, "user_code").orEmpty()
                val verifyUri = OrbJSON.str(auth, "verification_uri").orEmpty()
                HorizontalDivider(color = OrbStyle.border)
                Text(
                    text = "Enter code $userCode at GitHub to finish connecting.",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .orbPressClickable {
                                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                cm?.setPrimaryClip(ClipData.newPlainText("GitHub device code", userCode))
                                Toast.makeText(context, "Code copied", Toast.LENGTH_SHORT).show()
                            }
                            .padding(horizontal = 12.dp, vertical = 7.dp)
                    ) {
                        Text("Copy code", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
                    if (verifyUri.isNotEmpty()) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color.White)
                                .orbPressClickable {
                                    runCatching {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(verifyUri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                    }
                                }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Text("Open GitHub", color = Color.Black, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }

            error?.let { Text(it, color = OrbStyle.error, fontSize = 12.sp) }
        }
    }

    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            containerColor = OrbStyle.elevated,
            title = { Text("Disconnect GitHub?", color = Color.White) },
            text = {
                Text(
                    "Remove stored GitHub mission credentials from Core? Running or new missions will no longer receive this GitHub token.",
                    color = OrbStyle.textSecondary
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDisconnect = false
                    busy = true
                    scope.launch {
                        try {
                            core.request("/api/integrations/github", "DELETE")
                            authorizeState = null
                            refresh()
                        } catch (e: Throwable) {
                            error = e.message
                        } finally {
                            busy = false
                        }
                    }
                }) { Text("Disconnect", color = OrbStyle.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisconnect = false }) { Text("Cancel") }
            }
        )
    }
}
