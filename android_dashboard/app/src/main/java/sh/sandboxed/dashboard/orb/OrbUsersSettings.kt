package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

object OrbUsersModel {
    val reservedUnixUsernames: Set<String> = setOf(
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
        "uucp", "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody",
        "systemd-network", "systemd-resolve", "messagebus", "sshd", "orb-node",
        "orb-privd", "sandboxed", "ubuntu", "debian", "admin",
    )

    fun validUnixUsername(raw: String): Boolean {
        val v = raw.trim()
        if (v.isEmpty() || v.toByteArray(Charsets.UTF_8).size > 31 || v in reservedUnixUsernames) {
            return false
        }
        val first = v[0]
        if (!((first in 'a'..'z') || first == '_')) return false
        for (i in 1 until v.length) {
            val ch = v[i]
            val ok = (ch in 'a'..'z') || (ch in '0'..'9') || ch == '_' || ch == '-'
            if (!ok) return false
        }
        return true
    }

    fun defaultUnixUsernameFor(username: String): String {
        val lower = username.trim().lowercase(Locale.US)
        val sb = StringBuilder()
        var prevDash = false
        for (ch in lower) {
            val isAlnum = (ch in 'a'..'z') || (ch in '0'..'9')
            if (isAlnum) {
                sb.append(ch)
                prevDash = false
            } else if (!prevDash && sb.isNotEmpty()) {
                sb.append('-')
                prevDash = true
            }
        }
        var slug = sb.toString().trimEnd('-')
        if (slug.length > 27) {
            slug = slug.take(27).trimEnd('-')
        }
        if (slug.isEmpty()) return ""
        val candidate = "orb-$slug"
        return if (validUnixUsername(candidate)) candidate else ""
    }

    fun formatUsdFromCents(cents: Int?): String {
        if (cents == null) return "Unlimited"
        return String.format(Locale.US, "$%.2f", maxOf(0, cents) / 100.0)
    }

    fun parseUsdToCents(raw: String): Result<Int?> {
        val trimmed = raw.trim().replace("$", "")
        if (trimmed.isEmpty()) return Result.success(null)
        val num = trimmed.toDoubleOrNull()
            ?: return Result.failure(IllegalArgumentException("Enter a valid non-negative USD daily cap."))
        if (!num.isFinite() || num < 0.0 || num > 1_000_000.0) {
            return Result.failure(IllegalArgumentException("Enter a valid non-negative USD daily cap."))
        }
        return Result.success((num * 100.0).roundToInt())
    }
}

data class OrbAdminUser(
    val id: String,
    val username: String,
    val role: String,
    val unixUsername: String?,
    val dailySpendCapCents: Int?,
    val spentTodayCents: Int,
    val disabled: Boolean,
    val createdAt: String,
    val lastLoginAt: String?,
) {
    companion object {
        fun from(d: OrbDict): OrbAdminUser? {
            val id = OrbJSON.str(d, "id")?.trim().orEmpty()
            val username = OrbJSON.str(d, "username")?.trim().orEmpty()
            if (id.isEmpty() || username.isEmpty()) return null
            val role = if (OrbJSON.str(d, "role") == "admin") "admin" else "member"
            val unix = OrbJSON.str(d, "unix_username")?.trim()?.takeIf { it.isNotEmpty() }
            val cap = OrbJSON.double(d, "daily_spend_cap_cents")?.let { it.roundToInt() }
            val spent = OrbJSON.double(d, "spent_today_cents")?.let { maxOf(0, it.roundToInt()) } ?: 0
            val disabled = OrbJSON.bool(d, "disabled") == true
            val created = OrbJSON.str(d, "created_at").orEmpty()
            val last = OrbJSON.str(d, "last_login_at")?.takeIf { it.isNotEmpty() }
            return OrbAdminUser(
                id = id,
                username = username,
                role = role,
                unixUsername = unix,
                dailySpendCapCents = cap,
                spentTodayCents = spent,
                disabled = disabled,
                createdAt = created,
                lastLoginAt = last,
            )
        }
    }
}

@Composable
fun OrbUsersSettingsPage(
    core: OrbCore,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val currentUser by core.currentUserFlow.collectAsState()
    var users by remember { mutableStateOf<List<OrbAdminUser>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var ready by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<OrbAdminUser?>(null) }

    suspend fun load() {
        if (loading || !core.isConfigured) return
        loading = true
        try {
            val res = core.request("/api/admin/users")
            val rawItems = OrbJSON.dictList(OrbJSON.dict(res)?.get("users") ?: res)
            users = rawItems.mapNotNull { OrbAdminUser.from(it) }
            ready = true
            error = ""
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            error = t.message ?: "Failed to load users."
        } finally {
            loading = false
        }
    }

    LaunchedEffect(Unit) {
        load()
    }

    val activeAdminCount = remember(users) {
        users.count { it.role == "admin" && !it.disabled }
    }

    fun subtitleFor(user: OrbAdminUser): String {
        val parts = mutableListOf<String>()
        if (!user.unixUsername.isNullOrEmpty()) {
            parts.add("/home/${user.unixUsername}")
        }
        val spent = OrbUsersModel.formatUsdFromCents(user.spentTodayCents)
        if (user.dailySpendCapCents != null) {
            parts.add("$spent / ${OrbUsersModel.formatUsdFromCents(user.dailySpendCapCents)} today")
        } else if (user.spentTodayCents > 0) {
            parts.add("$spent today")
        } else {
            parts.add("No daily cap")
        }
        return parts.joinToString(" · ")
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
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
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = Color.White,
                    modifier = Modifier.size(17.dp)
                )
            }
            Text(
                text = "Users",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center
            )
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { creating = true },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = "New user",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp)
                )
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (error.isNotEmpty()) {
                item {
                    OrbNotice(title = error, log = null)
                }
            }

            if (loading && users.isEmpty()) {
                item {
                    Text(
                        text = "Loading users…",
                        color = OrbStyle.textSecondary,
                        fontSize = 14.sp
                    )
                }
            }

            item {
                Text(
                    text = "ACCOUNTS",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp
                )
            }

            if (ready && users.isEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                            .padding(14.dp)
                    ) {
                        Text(
                            text = "No users configured.",
                            color = OrbStyle.textSecondary,
                            fontSize = 14.sp
                        )
                    }
                }
            } else if (users.isNotEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                    ) {
                        users.forEachIndexed { idx, user ->
                            if (idx > 0) {
                                HorizontalDivider(color = OrbStyle.border)
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable { editing = user }
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(
                                    modifier = Modifier.weight(1f),
                                    verticalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Text(
                                            text = "@${user.username}",
                                            color = Color.White,
                                            fontSize = 15.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        Text(
                                            text = if (user.role == "admin") "Admin" else "Member",
                                            color = if (user.role == "admin") OrbStyle.success else OrbStyle.textSecondary,
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(999.dp))
                                                .background(Color.White.copy(alpha = 0.08f))
                                                .padding(horizontal = 6.dp, vertical = 2.dp)
                                        )
                                        if (user.disabled) {
                                            Text(
                                                text = "Disabled",
                                                color = OrbStyle.warning,
                                                fontSize = 11.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                modifier = Modifier
                                                    .clip(RoundedCornerShape(999.dp))
                                                    .background(OrbStyle.warning.copy(alpha = 0.16f))
                                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                    Text(
                                        text = subtitleFor(user),
                                        color = OrbStyle.textSecondary,
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                Icon(
                                    imageVector = Icons.Default.ChevronRight,
                                    contentDescription = null,
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                    }
                }
            }

            item {
                Text(
                    text = "Each user runs in their own Linux home directory on shared compute nodes. User workspaces and missions remain private.",
                    color = OrbStyle.textMuted,
                    fontSize = 12.sp
                )
            }
        }
    }

    if (creating) {
        OrbCreateUserDialog(
            core = core,
            onDismiss = { creating = false },
            onCreated = {
                creating = false
                scope.launch { load() }
            }
        )
    }

    editing?.let { target ->
        OrbEditUserDialog(
            core = core,
            user = target,
            isSelf = currentUser?.id == target.id,
            isSoleActiveAdmin = target.role == "admin" && !target.disabled && activeAdminCount <= 1,
            onDismiss = { editing = null },
            onChanged = {
                scope.launch { load() }
            },
            onFinished = {
                editing = null
                scope.launch { load() }
            }
        )
    }
}

@Composable
private fun OrbCreateUserDialog(
    core: OrbCore,
    onDismiss: () -> Unit,
    onCreated: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var role by remember { mutableStateOf("member") }
    var unixUsername by remember { mutableStateOf("") }
    var unixEdited by remember { mutableStateOf(false) }
    var dailyCapUsd by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }

    fun submit() {
        val cleanUser = username.trim()
        val cleanUnix = unixUsername.trim()
        if (cleanUser.isEmpty()) {
            error = "Enter a username."
            return
        }
        if (password.length < 8) {
            error = "Password must be at least 8 characters."
            return
        }
        if (!OrbUsersModel.validUnixUsername(cleanUnix)) {
            error = "Enter a valid non-reserved POSIX Linux username."
            return
        }
        val parsedCap = OrbUsersModel.parseUsdToCents(dailyCapUsd).getOrElse {
            error = it.message ?: "Enter a valid non-negative USD daily cap."
            return
        }
        saving = true
        error = ""
        scope.launch {
            try {
                val body = LinkedHashMap<String, Any?>()
                body["username"] = cleanUser
                body["password"] = password
                body["role"] = role
                body["unix_username"] = cleanUnix
                if (parsedCap != null) {
                    body["daily_spend_cap_cents"] = parsedCap
                }
                core.request("/api/admin/users", method = "POST", body = body)
                onCreated()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to create user."
            } finally {
                saving = false
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        containerColor = OrbStyle.surface,
        title = {
            Text("New user", color = Color.White, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (error.isNotEmpty()) {
                    Text(error, color = OrbStyle.error, fontSize = 13.sp)
                }
                OrbUsersTextField(
                    label = "Username",
                    value = username,
                    placeholder = "alice",
                    onValueChange = { next ->
                        username = next
                        if (!unixEdited) {
                            unixUsername = OrbUsersModel.defaultUnixUsernameFor(next)
                        }
                    }
                )
                OrbUsersTextField(
                    label = "Temporary password (8+ chars)",
                    value = password,
                    placeholder = "••••••••",
                    isPassword = true,
                    onValueChange = { password = it }
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Role", color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    FilterChip(
                        selected = role == "member",
                        onClick = { role = "member" },
                        label = { Text("Member") }
                    )
                    FilterChip(
                        selected = role == "admin",
                        onClick = { role = "admin" },
                        label = { Text("Admin") }
                    )
                }
                OrbUsersTextField(
                    label = "Linux account",
                    value = unixUsername,
                    placeholder = "orb-alice",
                    monospace = true,
                    onValueChange = { next ->
                        unixUsername = next
                        if (next != OrbUsersModel.defaultUnixUsernameFor(username)) {
                            unixEdited = true
                        }
                    }
                )
                OrbUsersTextField(
                    label = "Daily AI & compute cap (USD)",
                    value = dailyCapUsd,
                    placeholder = "Unlimited",
                    keyboardType = KeyboardType.Decimal,
                    onValueChange = { dailyCapUsd = it }
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { submit() },
                enabled = !saving && username.trim().isNotEmpty() && password.length >= 8
            ) {
                Text(if (saving) "Creating…" else "Create", color = Color.White)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !saving) {
                Text("Cancel", color = OrbStyle.textSecondary)
            }
        }
    )
}

@Composable
private fun OrbEditUserDialog(
    core: OrbCore,
    user: OrbAdminUser,
    isSelf: Boolean,
    isSoleActiveAdmin: Boolean,
    onDismiss: () -> Unit,
    onChanged: () -> Unit,
    onFinished: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var role by remember(user.id) { mutableStateOf(user.role) }
    var unixUsername by remember(user.id) {
        mutableStateOf(user.unixUsername ?: OrbUsersModel.defaultUnixUsernameFor(user.username))
    }
    var dailyCapUsd by remember(user.id) {
        mutableStateOf(user.dailySpendCapCents?.let { String.format(Locale.US, "%.2f", it / 100.0) } ?: "")
    }
    var disabled by remember(user.id) { mutableStateOf(user.disabled) }
    var newPassword by remember(user.id) { mutableStateOf("") }
    var resetNotice by remember(user.id) { mutableStateOf("") }
    var confirmDelete by remember(user.id) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }

    fun save() {
        val cleanUnix = unixUsername.trim()
        if (!OrbUsersModel.validUnixUsername(cleanUnix)) {
            error = "Enter a valid non-reserved POSIX Linux username."
            return
        }
        val parsedCap = OrbUsersModel.parseUsdToCents(dailyCapUsd).getOrElse {
            error = it.message ?: "Enter a valid non-negative USD daily cap."
            return
        }
        saving = true
        error = ""
        scope.launch {
            try {
                val body = mapOf(
                    "role" to role,
                    "unix_username" to cleanUnix,
                    "disabled" to disabled,
                    "daily_spend_cap_cents" to parsedCap,
                )
                core.request(
                    "/api/admin/users/${core.encodeComponent(user.id)}",
                    method = "PATCH",
                    body = body
                )
                if (isSelf) {
                    core.refreshCurrentUser()
                }
                onFinished()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to update user."
            } finally {
                saving = false
            }
        }
    }

    fun resetPassword() {
        if (newPassword.length < 8) return
        saving = true
        error = ""
        resetNotice = ""
        scope.launch {
            try {
                core.request(
                    "/api/admin/users/${core.encodeComponent(user.id)}/password",
                    method = "POST",
                    body = mapOf("new_password" to newPassword)
                )
                newPassword = ""
                resetNotice = "Password updated and active sessions rotated."
                onChanged()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to reset password."
            } finally {
                saving = false
            }
        }
    }

    fun deleteUser() {
        saving = true
        error = ""
        scope.launch {
            try {
                core.request(
                    "/api/admin/users/${core.encodeComponent(user.id)}",
                    method = "DELETE"
                )
                onFinished()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to delete user."
            } finally {
                saving = false
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        containerColor = OrbStyle.surface,
        title = {
            Text("@${user.username}", color = Color.White, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (error.isNotEmpty()) {
                    Text(error, color = OrbStyle.error, fontSize = 13.sp)
                }
                if (resetNotice.isNotEmpty()) {
                    Text(resetNotice, color = OrbStyle.success, fontSize = 13.sp)
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Role", color = OrbStyle.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    FilterChip(
                        selected = role == "member",
                        onClick = { if (!isSoleActiveAdmin) role = "member" },
                        enabled = !isSoleActiveAdmin,
                        label = { Text("Member") }
                    )
                    FilterChip(
                        selected = role == "admin",
                        onClick = { if (!isSoleActiveAdmin) role = "admin" },
                        enabled = !isSoleActiveAdmin,
                        label = { Text("Admin") }
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "Disable sign-in",
                        color = Color.White,
                        fontSize = 14.sp,
                        modifier = Modifier.weight(1f)
                    )
                    Switch(
                        checked = disabled,
                        onCheckedChange = { disabled = it },
                        enabled = !isSoleActiveAdmin && !isSelf
                    )
                }
                OrbUsersTextField(
                    label = "Linux account",
                    value = unixUsername,
                    placeholder = "orb-user",
                    monospace = true,
                    onValueChange = { unixUsername = it }
                )
                Text(
                    text = "Spent today: ${OrbUsersModel.formatUsdFromCents(user.spentTodayCents)}",
                    color = OrbStyle.textSecondary,
                    fontSize = 12.sp
                )
                OrbUsersTextField(
                    label = "Daily cap (USD, blank for Unlimited)",
                    value = dailyCapUsd,
                    placeholder = "Unlimited",
                    keyboardType = KeyboardType.Decimal,
                    onValueChange = { dailyCapUsd = it }
                )
                HorizontalDivider(color = OrbStyle.border)
                OrbUsersTextField(
                    label = "Reset password (8+ chars)",
                    value = newPassword,
                    placeholder = "New temporary password",
                    isPassword = true,
                    onValueChange = { newPassword = it }
                )
                TextButton(
                    onClick = { resetPassword() },
                    enabled = !saving && newPassword.length >= 8
                ) {
                    Text("Set temporary password", color = Color.White)
                }
                if (!isSoleActiveAdmin && !isSelf) {
                    HorizontalDivider(color = OrbStyle.border)
                    if (!confirmDelete) {
                        TextButton(
                            onClick = { confirmDelete = true },
                            enabled = !saving
                        ) {
                            Text("Delete user…", color = OrbStyle.error)
                        }
                    } else {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text(
                                "Confirm delete?",
                                color = OrbStyle.error,
                                fontSize = 13.sp,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(onClick = { confirmDelete = false }, enabled = !saving) {
                                Text("Cancel", color = OrbStyle.textSecondary)
                            }
                            TextButton(onClick = { deleteUser() }, enabled = !saving) {
                                Text("Delete", color = OrbStyle.error)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { save() }, enabled = !saving) {
                Text(if (saving) "Saving…" else "Save", color = Color.White)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !saving) {
                Text("Cancel", color = OrbStyle.textSecondary)
            }
        }
    )
}

@Composable
private fun OrbUsersTextField(
    label: String,
    value: String,
    placeholder: String,
    monospace: Boolean = false,
    isPassword: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    onValueChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, color = OrbStyle.textSecondary, fontSize = 12.sp)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(OrbStyle.background)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 9.dp)
        ) {
            if (value.isEmpty()) {
                Text(
                    text = placeholder,
                    color = OrbStyle.textMuted,
                    fontSize = 14.sp,
                    fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = TextStyle(
                    color = Color.White,
                    fontSize = 14.sp,
                    fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default
                ),
                cursorBrush = SolidColor(Color.White),
                keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
                visualTransformation = if (isPassword) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
