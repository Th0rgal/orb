package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

data class OrbDirectoryUser(
    val id: String,
    val username: String,
    val role: String,
) {
    companion object {
        fun from(d: OrbDict): OrbDirectoryUser? {
            val id = OrbJSON.str(d, "id")?.trim().orEmpty()
            val username = OrbJSON.str(d, "username")?.trim().orEmpty()
            if (id.isEmpty() || username.isEmpty()) return null
            val role = if (OrbJSON.str(d, "role") == "admin") "admin" else "member"
            return OrbDirectoryUser(id = id, username = username, role = role)
        }
    }
}

data class OrbMissionShareItem(
    val userId: String,
    val username: String,
    val role: String,
) {
    companion object {
        fun from(d: OrbDict): OrbMissionShareItem? {
            val uid = (OrbJSON.str(d, "user_id")?.takeIf { it.isNotEmpty() } ?: OrbJSON.str(d, "id"))
                ?.trim().orEmpty()
            if (uid.isEmpty()) return null
            val username = OrbJSON.str(d, "username")?.trim()?.takeIf { it.isNotEmpty() } ?: uid
            val role = OrbJSON.str(d, "role")?.trim()?.takeIf { it.isNotEmpty() } ?: "participant"
            return OrbMissionShareItem(userId = uid, username = username, role = role)
        }
    }
}

object OrbMissionSharing {
    suspend fun leaveSharedMission(core: OrbCore, missionId: String) {
        if (core.currentUserFlow.value == null) {
            core.refreshCurrentUser()
        }
        val myId = core.currentUserFlow.value?.id?.takeIf { it.isNotEmpty() }
            ?: throw OrbError("Current user identity is unavailable.", status = 400)
        core.request(
            "/api/control/missions/${core.encodeComponent(missionId)}/shares/${core.encodeComponent(myId)}",
            method = "DELETE"
        )
        core.removeMissionInMemory(missionId)
        runCatching { core.refreshMissionsQuietly(forceFull = true) }
    }
}

@Composable
fun OrbShareMissionDialog(
    core: OrbCore,
    missionId: String,
    title: String,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val currentUser by core.currentUserFlow.collectAsState()
    var shares by remember(missionId) { mutableStateOf<List<OrbMissionShareItem>>(emptyList()) }
    var directory by remember(missionId) { mutableStateOf<List<OrbDirectoryUser>>(emptyList()) }
    var search by remember(missionId) { mutableStateOf("") }
    var loading by remember(missionId) { mutableStateOf(true) }
    var busyUserId by remember(missionId) { mutableStateOf<String?>(null) }
    var error by remember(missionId) { mutableStateOf("") }

    suspend fun load() {
        loading = true
        try {
            if (core.currentUserFlow.value == null) {
                runCatching { core.refreshCurrentUser() }
            }
            coroutineScope {
                val sharesDeferred = async {
                    core.request("/api/control/missions/${core.encodeComponent(missionId)}/shares")
                }
                val dirDeferred = async {
                    core.request("/api/users/directory")
                }
                val sharesVal = sharesDeferred.await()
                val dirVal = dirDeferred.await()
                val rawShares = OrbJSON.dictList(OrbJSON.dict(sharesVal)?.get("shares") ?: sharesVal)
                val rawUsers = OrbJSON.dictList(OrbJSON.dict(dirVal)?.get("users") ?: dirVal)
                shares = rawShares.mapNotNull { OrbMissionShareItem.from(it) }
                directory = rawUsers.mapNotNull { OrbDirectoryUser.from(it) }
                error = ""
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            error = t.message ?: "Failed to load collaborators."
        } finally {
            loading = false
        }
    }

    LaunchedEffect(missionId) {
        load()
    }

    val availableUsers = remember(shares, directory, currentUser, search) {
        val sharedIds = shares.map { it.userId }.toSet()
        val myId = currentUser?.id.orEmpty()
        val q = search.trim()
        directory.filter { u ->
            u.id != myId && u.id !in sharedIds && (q.isEmpty() || u.username.contains(q, ignoreCase = true))
        }
    }

    fun add(user: OrbDirectoryUser) {
        if (busyUserId != null) return
        busyUserId = user.id
        scope.launch {
            try {
                core.request(
                    "/api/control/missions/${core.encodeComponent(missionId)}/shares",
                    method = "POST",
                    body = mapOf("user_id" to user.id)
                )
                load()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to invite user."
            } finally {
                busyUserId = null
            }
        }
    }

    fun remove(userId: String) {
        if (busyUserId != null) return
        busyUserId = userId
        scope.launch {
            try {
                core.request(
                    "/api/control/missions/${core.encodeComponent(missionId)}/shares/${core.encodeComponent(userId)}",
                    method = "DELETE"
                )
                load()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                error = t.message ?: "Failed to remove collaborator."
            } finally {
                busyUserId = null
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (busyUserId == null) onDismiss() },
        containerColor = OrbStyle.surface,
        title = {
            Text(
                text = if (title.isBlank()) "Share mission" else "Share “$title”",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                if (error.isNotEmpty()) {
                    Text(error, color = OrbStyle.error, fontSize = 13.sp)
                }

                Text(
                    text = "COLLABORATORS",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp
                )

                if (loading && shares.isEmpty()) {
                    Text("Loading…", color = OrbStyle.textSecondary, fontSize = 13.sp)
                } else if (shares.isEmpty()) {
                    Text(
                        "Only you can see this conversation.",
                        color = OrbStyle.textSecondary,
                        fontSize = 13.sp
                    )
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (share in shares) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "@${share.username}",
                                        color = Color.White,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = "Participant · can read and send follow-ups",
                                        color = OrbStyle.textSecondary,
                                        fontSize = 11.sp
                                    )
                                }
                                TextButton(
                                    onClick = { remove(share.userId) },
                                    enabled = busyUserId == null
                                ) {
                                    Text("Remove", color = OrbStyle.error, fontSize = 13.sp)
                                }
                            }
                        }
                    }
                }

                Text(
                    text = "Participants can read messages, view files, and send follow-up turns, without access to your other projects or settings.",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp
                )

                HorizontalDivider(color = OrbStyle.border)

                Text(
                    text = "ADD PEOPLE",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp
                )

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(OrbStyle.background)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(8.dp))
                        .padding(horizontal = 10.dp, vertical = 9.dp)
                ) {
                    if (search.isEmpty()) {
                        Text("Find user", color = OrbStyle.textMuted, fontSize = 13.sp)
                    }
                    BasicTextField(
                        value = search,
                        onValueChange = { search = it },
                        singleLine = true,
                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                        cursorBrush = SolidColor(Color.White),
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                if (!loading && availableUsers.isEmpty()) {
                    Text(
                        text = if (search.isBlank()) "No other users available to invite." else "No matching users.",
                        color = OrbStyle.textSecondary,
                        fontSize = 13.sp
                    )
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (user in availableUsers) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "@${user.username}",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    modifier = Modifier.weight(1f)
                                )
                                TextButton(
                                    onClick = { add(user) },
                                    enabled = busyUserId == null
                                ) {
                                    Text(
                                        text = if (busyUserId == user.id) "Adding…" else "Add",
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, enabled = busyUserId == null) {
                Text("Done", color = Color.White)
            }
        }
    )
}
