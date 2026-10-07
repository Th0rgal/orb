package sh.sandboxed.dashboard.orb

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.ListAlt
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.sse.EventSource
import java.util.UUID

enum class OrbComposeMode(
    val id: String,
    val label: String,
    val subtitle: String,
    val badge: String?,
    val slashTrigger: String
) {
    Message("message", "Message", "Standard interactive turn", null, "/message"),
    Plan("plan", "Plan", "Draft a plan and ask before editing", "Plan", "/plan"),
    Goal("goal", "Goal", "Autonomous multi-step loop until verified", "Goal", "/goal");

    fun wrapPrompt(raw: String): String {
        val text = raw.trim()
        return when (this) {
            Message -> text
            Plan -> "[MODE: PLAN]\nFirst inspect the relevant files and propose a clear, concise step-by-step plan. Wait for approval before making code changes.\n\n$text"
            Goal -> "[MODE: GOAL]\nWork autonomously end-to-end until the goal is verified complete. Break down tasks, implement, run checks, and self-correct without stopping early.\n\n$text"
        }
    }
}

data class OrbTodoEntry(
    val id: String,
    val content: String,
    val status: String
)

data class OrbWorkStep(
    val id: String,
    val kind: Kind,
    val title: String,
    val detail: String?,
    val filePath: String?
) {
    enum class Kind {
        Thinking,
        Read,
        Edit,
        Command,
        Search,
        Tool
    }
}

sealed class OrbTurn(open val id: String) {
    data class User(
        override val id: String,
        val text: String,
        val timestamp: String?,
        val isPending: Boolean = false
    ) : OrbTurn(id)

    data class Assistant(
        override val id: String,
        val text: String,
        val timestamp: String?,
        val isStreaming: Boolean = false
    ) : OrbTurn(id)

    data class WorkFold(
        override val id: String,
        val steps: List<OrbWorkStep>,
        val isLive: Boolean,
        val startedAt: String?
    ) : OrbTurn(id)

    data class Wake(
        override val id: String,
        val text: String,
        val timestamp: String?
    ) : OrbTurn(id)
}

object OrbTimelineBuilder {
    fun build(
        messages: List<OrbRow>,
        events: List<OrbRow>,
        streamingText: String,
        isLive: Boolean,
        startedAt: String?
    ): List<OrbTurn> {
        val turns = mutableListOf<OrbTurn>()
        val pendingWork = mutableListOf<OrbWorkStep>()

        fun flushWork(live: Boolean, indexSeed: Int) {
            if (pendingWork.isEmpty()) return
            turns.add(
                OrbTurn.WorkFold(
                    id = "work-$indexSeed-${pendingWork.first().id}",
                    steps = pendingWork.toList(),
                    isLive = live,
                    startedAt = startedAt
                )
            )
            pendingWork.clear()
        }

        if (events.isNotEmpty()) {
            events.forEachIndexed { idx, ev ->
                val type = (ev.str("type", "event_type", "kind") ?: "").lowercase()
                val data = ev.dict("data") ?: ev.raw
                when {
                    type == "user_message" || type == "user" -> {
                        flushWork(false, idx)
                        val text = OrbJSON.str(data, "content", "text", "message")
                            ?: ev.str("content", "text", "message") ?: ""
                        if (text.isNotEmpty()) {
                            if (isControllerWake(text)) {
                                turns.add(OrbTurn.Wake("wake-${ev.id}", text, ev.str("created_at", "timestamp")))
                            } else {
                                turns.add(OrbTurn.User("u-${ev.id}", text, ev.str("created_at", "timestamp")))
                            }
                        }
                    }
                    type == "assistant_message" || type == "assistant" || type == "agent_message" -> {
                        flushWork(false, idx)
                        val text = OrbJSON.str(data, "content", "text", "message")
                            ?: ev.str("content", "text", "message") ?: ""
                        if (text.isNotEmpty()) {
                            turns.add(OrbTurn.Assistant("a-${ev.id}", text, ev.str("created_at", "timestamp")))
                        }
                    }
                    type.contains("think") || type == "reasoning" -> {
                        val text = OrbJSON.str(data, "thinking", "content", "text", "summary")
                            ?: ev.str("thinking", "content", "text") ?: "Thinking…"
                        pendingWork.add(
                            OrbWorkStep(
                                id = ev.id,
                                kind = OrbWorkStep.Kind.Thinking,
                                title = OrbJSON.cleanTitle(text).take(80),
                                detail = text,
                                filePath = null
                            )
                        )
                    }
                    type.contains("tool_call") || type == "tool_use" || type == "tool" || type == "action" -> {
                        val step = parseToolStep(ev, data)
                        if (step != null) pendingWork.add(step)
                    }
                }
            }
        }

        if (turns.isEmpty() && messages.isNotEmpty()) {
            messages.forEachIndexed { idx, msg ->
                val role = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
                val text = msg.str("content", "text", "message") ?: ""
                val ts = msg.str("created_at", "timestamp", "updated_at")
                if (role == "user" || role == "operator" || role == "human") {
                    flushWork(false, idx)
                    if (text.isNotEmpty()) {
                        if (isControllerWake(text)) {
                            turns.add(OrbTurn.Wake("wake-${msg.id}", text, ts))
                        } else {
                            turns.add(OrbTurn.User("u-${msg.id}", text, ts))
                        }
                    }
                } else if (role == "assistant" || role == "agent") {
                    val toolCalls = msg.rows("tool_calls")
                    toolCalls.forEach { tc ->
                        parseToolStep(tc, tc.raw)?.let { pendingWork.add(it) }
                    }
                    flushWork(false, idx)
                    if (text.isNotEmpty()) {
                        turns.add(OrbTurn.Assistant("a-${msg.id}", text, ts))
                    }
                }
            }
        }

        if (pendingWork.isNotEmpty()) {
            flushWork(isLive && streamingText.isEmpty(), 9999)
        } else if (isLive && streamingText.isEmpty() && turns.none { it is OrbTurn.WorkFold && it.isLive }) {
            turns.add(
                OrbTurn.WorkFold(
                    id = "work-live-placeholder",
                    steps = emptyList(),
                    isLive = true,
                    startedAt = startedAt
                )
            )
        }

        if (streamingText.trim().isNotEmpty()) {
            turns.add(
                OrbTurn.Assistant(
                    id = "streaming-assistant",
                    text = streamingText,
                    timestamp = null,
                    isStreaming = true
                )
            )
        }

        return turns
    }

    private fun isControllerWake(text: String): Boolean {
        val trimmed = text.trim()
        return trimmed.startsWith("[CONTROLLER_WAKE]") ||
            trimmed.startsWith("[MISSION_COMPLETED]") ||
            trimmed.startsWith("[WEBHOOK:")
    }

    private fun parseToolStep(ev: OrbRow, data: OrbDict): OrbWorkStep? {
        val rawName = OrbJSON.str(data, "name", "tool", "tool_name", "action")
            ?: ev.str("name", "tool", "tool_name") ?: return null
        val lower = rawName.lowercase()
        val input = OrbJSON.dict(data["input"]) ?: OrbJSON.dict(data["arguments"]) ?: data
        val path = OrbJSON.str(input, "file_path", "path", "TargetFile", "AbsolutePath", "file")
        val cmd = OrbJSON.str(input, "command", "cmd", "CommandLine")
        val query = OrbJSON.str(input, "query", "pattern", "Query")

        return when {
            lower.contains("read") || lower.contains("view") || lower == "cat" -> {
                val shortPath = path?.substringAfterLast('/') ?: path ?: rawName
                OrbWorkStep(
                    id = ev.id,
                    kind = OrbWorkStep.Kind.Read,
                    title = "Read $shortPath",
                    detail = path,
                    filePath = path
                )
            }
            lower.contains("edit") || lower.contains("write") || lower.contains("replace") || lower.contains("patch") -> {
                val shortPath = path?.substringAfterLast('/') ?: path ?: rawName
                OrbWorkStep(
                    id = ev.id,
                    kind = OrbWorkStep.Kind.Edit,
                    title = "Edited $shortPath",
                    detail = path,
                    filePath = path
                )
            }
            lower.contains("bash") || lower.contains("exec") || lower.contains("run") || cmd != null -> {
                OrbWorkStep(
                    id = ev.id,
                    kind = OrbWorkStep.Kind.Command,
                    title = cmd?.lineSequence()?.firstOrNull()?.take(70) ?: "Ran command",
                    detail = cmd,
                    filePath = null
                )
            }
            lower.contains("grep") || lower.contains("search") || lower.contains("glob") || lower.contains("find") -> {
                OrbWorkStep(
                    id = ev.id,
                    kind = OrbWorkStep.Kind.Search,
                    title = if (query != null) "Searched \"$query\"" else "Searched codebase",
                    detail = query ?: path,
                    filePath = null
                )
            }
            else -> {
                OrbWorkStep(
                    id = ev.id,
                    kind = OrbWorkStep.Kind.Tool,
                    title = rawName,
                    detail = path ?: cmd ?: query,
                    filePath = path
                )
            }
        }
    }

    fun extractTodos(events: List<OrbRow>, mission: OrbRow?): List<OrbTodoEntry> {
        mission?.rows("todos")?.takeIf { it.isNotEmpty() }?.let { rows ->
            return rows.mapIndexed { idx, r ->
                OrbTodoEntry(
                    id = r.str("id") ?: "todo-$idx",
                    content = r.str("content", "title", "text") ?: "Task",
                    status = (r.str("status", "state") ?: "pending").lowercase()
                )
            }
        }
        for (ev in events.asReversed()) {
            val data = ev.dict("data") ?: ev.raw
            val name = (OrbJSON.str(data, "name", "tool", "tool_name") ?: "").lowercase()
            if (name.contains("todowrite") || name.contains("todo_write") || name == "todos") {
                val input = OrbJSON.dict(data["input"]) ?: OrbJSON.dict(data["arguments"]) ?: data
                val list = OrbJSON.dictList(input["todos"])
                if (list.isNotEmpty()) {
                    return list.mapIndexed { idx, item ->
                        OrbTodoEntry(
                            id = OrbJSON.str(item, "id") ?: "todo-$idx",
                            content = OrbJSON.str(item, "content", "title", "text") ?: "Task",
                            status = (OrbJSON.str(item, "status", "state") ?: "pending").lowercase()
                        )
                    }
                }
            }
        }
        return emptyList()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbConversationPage(
    core: OrbCore,
    project: OrbRow,
    initialMission: OrbRow?,
    initialFolder: String? = null,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val allMissions by core.missions.collectAsState()
    val backends by core.backends.collectAsState()
    val workspaces by core.workspaces.collectAsState()
    val providers by core.providers.collectAsState()
    val repositories by core.repositories.collectAsState()

    var currentMission by remember(initialMission?.id) { mutableStateOf(initialMission) }
    val missionId = currentMission?.id

    val messagesCacheKey = remember(missionId) { "mission_msgs_${missionId ?: "new"}" }
    val eventsCacheKey = remember(missionId) { "mission_events_${missionId ?: "new"}" }

    var messages by remember(missionId) {
        mutableStateOf(if (missionId != null) OrbReadCache.loadRows(messagesCacheKey) else emptyList())
    }
    var events by remember(missionId) {
        mutableStateOf(if (missionId != null) OrbReadCache.loadRows(eventsCacheKey) else emptyList())
    }
    var streamingText by remember(missionId) { mutableStateOf("") }
    var dismissedQuestionId by remember(missionId) { mutableStateOf<String?>(null) }

    var inputText by remember { mutableStateOf("") }
    var composeMode by remember { mutableStateOf(OrbComposeMode.Message) }
    var showModePicker by remember { mutableStateOf(false) }
    val queuedMessages = remember { mutableStateListOf<String>() }
    var showQueuedDrawer by remember { mutableStateOf(false) }
    val pendingAttachments = remember { mutableStateListOf<OrbPendingAttachment>() }

    var isSending by remember { mutableStateOf(false) }
    var isStopping by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var previewFilePath by remember { mutableStateOf<String?>(null) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showAttachMenu by remember { mutableStateOf(false) }

    // Agent configuration state
    var selectedBackend by remember(currentMission?.id, backends) {
        mutableStateOf(
            currentMission?.str("backend", "harness", "backend_id")
                ?: backends.firstOrNull()?.str("id", "name")
                ?: "claude"
        )
    }
    var selectedModel by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("model", "model_id") ?: "")
    }
    var selectedWorkspaceId by remember(currentMission?.id, project.id) {
        mutableStateOf(
            currentMission?.str("workspace_id", "workspaceId")
                ?: project.str("workspace_id", "default_workspace_id")
                ?: ""
        )
    }
    var selectedAccount by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("account_id", "account", "provider_account") ?: "")
    }
    var selectedRepo by remember(currentMission?.id, project.id) {
        mutableStateOf(currentMission?.str("repo", "repository") ?: project.str("repo", "repository") ?: "")
    }
    var selectedGitRef by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("git_ref", "branch") ?: "")
    }
    var selectedConfigProfile by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("config_profile", "profile") ?: "")
    }

    val liveRow = remember(allMissions, missionId, currentMission) {
        if (missionId == null) null
        else allMissions.firstOrNull { it.id == missionId } ?: currentMission
    }

    val isLive = remember(liveRow, isSending) {
        isSending || (liveRow != null && OrbMissionTree.isLive(liveRow))
    }

    val chainIds = remember(missionId, allMissions) {
        if (missionId == null) emptyList()
        else OrbContinuation.chainIds(missionId, allMissions)
    }

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetMultipleContents()
    ) { uris: List<Uri> ->
        scope.launch {
            for (uri in uris) {
                OrbAttachmentUploader.readUri(context, uri)?.let { pendingAttachments.add(it) }
            }
        }
    }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetMultipleContents()
    ) { uris: List<Uri> ->
        scope.launch {
            for (uri in uris) {
                OrbAttachmentUploader.readUri(context, uri)?.let { pendingAttachments.add(it) }
            }
        }
    }

    suspend fun loadHistory(targetId: String) {
        try {
            val idsToLoad = if (chainIds.size > 1) chainIds else listOf(targetId)
            val allMsgs = mutableListOf<OrbRow>()
            val allEvs = mutableListOf<OrbRow>()

            for (cid in idsToLoad) {
                val mRes = runCatching {
                    core.fetchRows("/api/control/missions/$cid/messages", "messages")
                }.getOrDefault(emptyList())
                val eRes = runCatching {
                    core.fetchRows("/api/control/missions/$cid/events?limit=250", "events")
                }.getOrDefault(emptyList())
                allMsgs.addAll(mRes)
                allEvs.addAll(eRes)
            }

            if (allMsgs.isNotEmpty()) {
                messages = allMsgs
                OrbReadCache.saveRows(messagesCacheKey, allMsgs)
            }
            if (allEvs.isNotEmpty()) {
                events = allEvs
                OrbReadCache.saveRows(eventsCacheKey, allEvs)
            }
            liveRow?.let { OrbMissionUnreadStore.markSeen(it) }
        } catch (_: Throwable) {
        }
    }

    // Poll + SSE stream when missionId is active
    DisposableEffect(missionId) {
        var sse: EventSource? = null
        if (missionId != null) {
            sse = runCatching {
                core.openSSE(
                    path = "/api/control/stream?mission_id=${core.encodeComponent(missionId)}",
                    onEvent = { type, data ->
                        val parsed = OrbJSON.dict(OrbJSON.parse(data)) ?: return@openSSE
                        val evType = (type ?: OrbJSON.str(parsed, "type", "event_type") ?: "").lowercase()
                        when {
                            evType == "text_delta" || evType == "delta" -> {
                                val delta = OrbJSON.rawStr(parsed, "delta", "text", "content") ?: ""
                                if (delta.isNotEmpty()) {
                                    scope.launch(Dispatchers.Main) {
                                        streamingText += delta
                                    }
                                }
                            }
                            evType == "assistant_message" || evType == "mission_completed" || evType == "turn_complete" -> {
                                scope.launch(Dispatchers.Main) {
                                    streamingText = ""
                                    loadHistory(missionId)
                                    core.refreshMissionsQuietly()
                                }
                            }
                        }
                    }
                )
            }.getOrNull()
        }
        onDispose {
            sse?.cancel()
        }
    }

    LaunchedEffect(missionId) {
        val id = missionId ?: return@LaunchedEffect
        loadHistory(id)
        while (isActive) {
            delay(if (isLive) 2800L else 6500L)
            loadHistory(id)
        }
    }

    fun sendTurn(rawInput: String? = null) {
        val baseText = (rawInput ?: inputText).trim()
        if (baseText.isEmpty() && pendingAttachments.isEmpty()) return
        if (isLive && rawInput == null && missionId != null) {
            queuedMessages.add(baseText)
            inputText = ""
            return
        }

        val attachmentsSnapshot = pendingAttachments.toList()
        if (rawInput == null) {
            inputText = ""
            pendingAttachments.clear()
        }
        isSending = true
        errorMessage = null

        scope.launch {
            try {
                val uploaded = mutableListOf<OrbUploadedAttachment>()
                for (att in attachmentsSnapshot) {
                    uploaded.add(OrbAttachmentUploader.upload(att, core))
                }
                val formattedText = OrbAttachmentUploader.formatPrompt(baseText, uploaded)
                val finalPrompt = composeMode.wrapPrompt(formattedText)

                // Optimistic user message
                val optimistic = OrbRow(
                    "local-${UUID.randomUUID()}",
                    mapOf(
                        "role" to "user",
                        "content" to formattedText,
                        "created_at" to java.time.Instant.now().toString()
                    )
                )
                messages = messages + optimistic

                val existingId = currentMission?.id
                if (existingId != null) {
                    core.request(
                        path = "/api/control/missions/$existingId/message",
                        method = "POST",
                        body = mapOf("content" to finalPrompt)
                    )
                    loadHistory(existingId)
                    core.refreshMissionsQuietly()
                } else {
                    val slug = project.str("slug", "id") ?: project.id
                    val tags = mutableListOf("project:$slug")
                    if (composeMode == OrbComposeMode.Goal) tags.add("orb-mode:goal")
                    if (!initialFolder.isNullOrEmpty()) tags.add("orb-folder:$initialFolder")

                    val body = mutableMapOf<String, Any?>(
                        "prompt" to finalPrompt,
                        "title" to OrbJSON.cleanTitle(baseText).take(72),
                        "project" to slug,
                        "backend" to selectedBackend,
                        "tags" to tags
                    )
                    if (selectedModel.isNotEmpty()) body["model"] = selectedModel
                    if (selectedWorkspaceId.isNotEmpty()) body["workspace_id"] = selectedWorkspaceId
                    if (selectedAccount.isNotEmpty()) body["account_id"] = selectedAccount
                    if (selectedRepo.isNotEmpty()) body["repo"] = selectedRepo
                    if (selectedGitRef.isNotEmpty()) body["git_ref"] = selectedGitRef
                    if (selectedConfigProfile.isNotEmpty()) body["config_profile"] = selectedConfigProfile

                    val created = core.request("/api/control/missions", method = "POST", body = body)
                    val dict = OrbJSON.dict(created) ?: OrbJSON.dict(OrbJSON.dict(created)?.get("mission"))
                    if (dict != null) {
                        val row = OrbRow(dict)
                        currentMission = row
                        core.refreshMissionsQuietly()
                        loadHistory(row.id)
                    }
                }
            } catch (e: Throwable) {
                errorMessage = e.message ?: "Failed to send message"
            } finally {
                isSending = false
            }
        }
    }

    // Drain queued messages when agent finishes turn
    LaunchedEffect(isLive, queuedMessages.size) {
        if (!isLive && queuedMessages.isNotEmpty() && !isSending) {
            val next = queuedMessages.removeAt(0)
            sendTurn(next)
        }
    }

    fun stopMission() {
        val id = missionId ?: return
        isStopping = true
        scope.launch {
            try {
                runCatching {
                    core.request("/api/control/missions/$id/cancel", method = "POST")
                }.onFailure {
                    core.request("/api/control/missions/$id/stop", method = "POST")
                }
                core.refreshMissionsQuietly()
            } catch (e: Throwable) {
                errorMessage = e.message
            } finally {
                isStopping = false
            }
        }
    }

    val turns = remember(messages, events, streamingText, isLive, liveRow) {
        OrbTimelineBuilder.build(
            messages = messages,
            events = events,
            streamingText = streamingText,
            isLive = isLive,
            startedAt = liveRow?.str("root_started_at", "started_at", "created_at")
        )
    }

    val todos = remember(events, liveRow) {
        OrbTimelineBuilder.extractTodos(events, liveRow)
    }

    val activeQuestion = remember(events, messages, liveRow, dismissedQuestionId) {
        val status = liveRow?.str("status", "state") ?: ""
        OrbQuestionExtractor.extract(events, messages, status)
            ?.takeIf { it.id != dismissedQuestionId }
    }

    val prUrl = remember(liveRow, events) {
        liveRow?.str("pr_url", "pull_request_url")
    }

    val listState = rememberLazyListState()
    LaunchedEffect(turns.size) {
        if (turns.isNotEmpty()) {
            listState.animateScrollToItem(turns.lastIndex)
        }
    }

    val headline = remember(liveRow, project) {
        if (liveRow != null) {
            OrbInboxModel.missionHeadline(liveRow)
        } else {
            "New agent"
        }
    }
    val projectName = remember(project) {
        project.str("name", "title", "slug") ?: "Project"
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .navigationBarsPadding()
            .imePadding()
    ) {
        // Top Header Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
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
                    modifier = Modifier.size(18.dp)
                )
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = headline,
                        color = Color.White,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (liveRow != null && OrbMissionTree.isGoal(liveRow)) {
                        Text(
                            text = "Goal",
                            color = OrbStyle.textSecondary,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, CircleShape)
                                .padding(horizontal = 7.dp, vertical = 2.dp)
                        )
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(OrbProjectAppearance.color(project))
                    )
                    Text(
                        text = projectName,
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        maxLines = 1
                    )
                    val contCount = liveRow?.int("_continuation_count") ?: 1
                    if (contCount > 1) {
                        Text(
                            text = "· $contCount continuations",
                            color = OrbStyle.textMuted,
                            fontSize = 11.sp
                        )
                    }
                }
            }

            if (!prUrl.isNullOrEmpty()) {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .orbPressClickable {
                            runCatching {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(prUrl)))
                            }
                        }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.OpenInNew,
                        contentDescription = "PR",
                        tint = OrbStyle.success,
                        modifier = Modifier.size(12.dp)
                    )
                    Text(
                        text = "PR",
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }

        // Conversation Body
        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            errorMessage?.let { err ->
                item(key = "conv_error") {
                    OrbRemoteLog(
                        title = err,
                        log = core.lastErrorLog.value,
                        onRetry = {
                            errorMessage = null
                            missionId?.let { scope.launch { loadHistory(it) } }
                        }
                    )
                }
            }

            if (todos.isNotEmpty()) {
                item(key = "todos_card") {
                    OrbMissionTasksCard(todos = todos)
                }
            }

            if (turns.isEmpty() && !isLive) {
                item(key = "empty_conv") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 72.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = "Start a conversation in $projectName",
                            color = Color.White,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Type / for Plan or Goal mode, or tap the harness pill below to switch backend, machine, or model.",
                            color = OrbStyle.textSecondary,
                            fontSize = 13.sp,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            modifier = Modifier.padding(horizontal = 24.dp)
                        )
                    }
                }
            }

            items(turns, key = { it.id }) { turn ->
                when (turn) {
                    is OrbTurn.User -> {
                        OrbUserBubble(
                            turn = turn,
                            workspaceId = selectedWorkspaceId.takeIf { it.isNotEmpty() },
                            core = core,
                            onPreviewFile = { previewFilePath = it }
                        )
                    }
                    is OrbTurn.Assistant -> {
                        OrbAssistantTurnView(
                            turn = turn,
                            onSendAnswer = { ans -> sendTurn(ans) }
                        )
                    }
                    is OrbTurn.WorkFold -> {
                        OrbWorkFoldView(
                            fold = turn,
                            onPreviewFile = { previewFilePath = it }
                        )
                    }
                    is OrbTurn.Wake -> {
                        OrbBackgroundWakeRow(turn = turn)
                    }
                }
            }

            if (activeQuestion != null) {
                item(key = "question_${activeQuestion.id}") {
                    OrbQuestionCard(
                        question = activeQuestion,
                        isSending = isSending,
                        onSelect = { answer -> sendTurn(answer) },
                        onDismiss = { dismissedQuestionId = activeQuestion.id }
                    )
                }
            }
        }

        // Composer Area
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Slash mode menu popup
            if (showModePicker || inputText.startsWith("/")) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(16.dp))
                        .padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = "MODES",
                        color = OrbStyle.textMuted,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                    OrbComposeMode.entries.forEach { mode ->
                        val active = composeMode == mode
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(if (active) OrbStyle.card else Color.Transparent)
                                .orbPressClickable {
                                    composeMode = mode
                                    showModePicker = false
                                    if (inputText.startsWith("/")) {
                                        inputText = ""
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = when (mode) {
                                    OrbComposeMode.Message -> Icons.Default.Code
                                    OrbComposeMode.Plan -> Icons.Default.ListAlt
                                    OrbComposeMode.Goal -> Icons.Default.Flag
                                },
                                contentDescription = null,
                                tint = if (active) Color.White else OrbStyle.icon,
                                modifier = Modifier.size(15.dp)
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = mode.label,
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    text = mode.subtitle,
                                    color = OrbStyle.textMuted,
                                    fontSize = 11.sp
                                )
                            }
                            Text(
                                text = mode.slashTrigger,
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                    }
                }
            }

            // Queued messages drawer
            if (queuedMessages.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .orbPressClickable { showQueuedDrawer = !showQueuedDrawer },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Schedule,
                            contentDescription = null,
                            tint = OrbStyle.textSecondary,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = "${queuedMessages.size} Queued",
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f)
                        )
                        Icon(
                            imageVector = if (showQueuedDrawer) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            contentDescription = null,
                            tint = OrbStyle.textMuted,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                    if (showQueuedDrawer) {
                        queuedMessages.forEachIndexed { idx, qm ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(OrbStyle.card)
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = qm,
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f)
                                )
                                Box(
                                    modifier = Modifier
                                        .size(20.dp)
                                        .orbPressClickable { queuedMessages.removeAt(idx) },
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "Remove",
                                        tint = OrbStyle.textMuted,
                                        modifier = Modifier.size(12.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }

            //Composer Capsule Card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(22.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(22.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (pendingAttachments.isNotEmpty()) {
                    OrbAttachmentStrip(
                        items = pendingAttachments,
                        onRemove = { id -> pendingAttachments.removeAll { it.id == id } }
                    )
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 24.dp, max = 140.dp)
                        .padding(horizontal = 4.dp)
                ) {
                    if (inputText.isEmpty()) {
                        Text(
                            text = when (composeMode) {
                                OrbComposeMode.Message -> "Message agent… (/ for modes)"
                                OrbComposeMode.Plan -> "Ask agent to draft a plan…"
                                OrbComposeMode.Goal -> "Describe autonomous goal…"
                            },
                            color = OrbStyle.textMuted,
                            fontSize = 15.sp
                        )
                    }
                    BasicTextField(
                        value = inputText,
                        onValueChange = { inputText = it },
                        textStyle = TextStyle(
                            color = Color.White,
                            fontSize = 15.sp,
                            lineHeight = 20.sp
                        ),
                        cursorBrush = SolidColor(Color.White),
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // + Attachment button
                    Box {
                        Box(
                            modifier = Modifier
                                .size(30.dp)
                                .clip(CircleShape)
                                .background(OrbStyle.card)
                                .border(1.dp, OrbStyle.border, CircleShape)
                                .orbPressClickable { showAttachMenu = true },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Add,
                                contentDescription = "Attach",
                                tint = OrbStyle.textSecondary,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                        DropdownMenu(
                            expanded = showAttachMenu,
                            onDismissRequest = { showAttachMenu = false },
                            containerColor = OrbStyle.elevated
                        ) {
                            DropdownMenuItem(
                                text = { Text("Photo Library", color = Color.White, fontSize = 14.sp) },
                                leadingIcon = {
                                    Icon(Icons.Default.PhotoLibrary, contentDescription = null, tint = Color.White)
                                },
                                onClick = {
                                    showAttachMenu = false
                                    photoPickerLauncher.launch("image/*")
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Attach File", color = Color.White, fontSize = 14.sp) },
                                leadingIcon = {
                                    Icon(Icons.Default.AttachFile, contentDescription = null, tint = Color.White)
                                },
                                onClick = {
                                    showAttachMenu = false
                                    filePickerLauncher.launch("*/*")
                                }
                            )
                        }
                    }

                    // Mode pill if Plan or Goal
                    composeMode.badge?.let { badge ->
                        Row(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(OrbStyle.card)
                                .border(1.dp, OrbStyle.borderStrong, CircleShape)
                                .orbPressClickable { showModePicker = !showModePicker }
                                .padding(horizontal = 9.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(
                                text = badge,
                                color = Color.White,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                            Icon(
                                imageVector = Icons.Default.Close,
                                contentDescription = "Reset mode",
                                tint = OrbStyle.textMuted,
                                modifier = Modifier
                                    .size(11.dp)
                                    .orbPressClickable { composeMode = OrbComposeMode.Message }
                            )
                        }
                    }

                    // Agent / Harness picker pill
                    Row(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .orbPressClickable { showAgentPicker = true }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp)
                    ) {
                        Text(
                            text = buildString {
                                append(selectedBackend)
                                if (selectedModel.isNotEmpty()) {
                                    append(" · ")
                                    append(selectedModel.substringAfterLast('/'))
                                }
                            },
                            color = OrbStyle.textSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 170.dp)
                        )
                        Icon(
                            imageVector = Icons.Default.ExpandMore,
                            contentDescription = null,
                            tint = OrbStyle.textMuted,
                            modifier = Modifier.size(13.dp)
                        )
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    if (isLive && missionId != null) {
                        Box(
                            modifier = Modifier
                                .size(30.dp)
                                .clip(CircleShape)
                                .background(OrbStyle.card)
                                .border(1.dp, OrbStyle.borderStrong, CircleShape)
                                .orbPressClickable(enabled = !isStopping) { stopMission() },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Stop,
                                contentDescription = "Stop",
                                tint = Color.White,
                                modifier = Modifier.size(14.dp)
                            )
                        }
                    }

                    val canSend = inputText.trim().isNotEmpty() || pendingAttachments.isNotEmpty()
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(if (canSend) Color.White else OrbStyle.card)
                            .orbPressClickable(enabled = canSend) { sendTurn() },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.ArrowUpward,
                            contentDescription = "Send",
                            tint = if (canSend) Color.Black else OrbStyle.textMuted,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }
        }
    }

    if (showAgentPicker) {
        OrbAgentPickerSheet(
            backends = backends,
            workspaces = workspaces,
            providers = providers,
            repositories = repositories,
            selectedBackend = selectedBackend,
            onSelectBackend = { selectedBackend = it },
            selectedModel = selectedModel,
            onSelectModel = { selectedModel = it },
            selectedWorkspaceId = selectedWorkspaceId,
            onSelectWorkspaceId = { selectedWorkspaceId = it },
            selectedAccount = selectedAccount,
            onSelectAccount = { selectedAccount = it },
            selectedRepo = selectedRepo,
            onSelectRepo = { selectedRepo = it },
            selectedGitRef = selectedGitRef,
            onSelectGitRef = { selectedGitRef = it },
            selectedConfigProfile = selectedConfigProfile,
            onSelectConfigProfile = { selectedConfigProfile = it },
            onDismiss = { showAgentPicker = false }
        )
    }

    previewFilePath?.let { path ->
        OrbPreviewSheet(
            core = core,
            path = path,
            workspaceId = selectedWorkspaceId.takeIf { it.isNotEmpty() },
            onDismiss = { previewFilePath = null }
        )
    }
}

@Composable
private fun OrbUserBubble(
    turn: OrbTurn.User,
    workspaceId: String?,
    core: OrbCore,
    onPreviewFile: (String) -> Unit
) {
    val parsed = remember(turn.text) {
        val strippedMode = when {
            turn.text.startsWith("[MODE: GOAL]") -> turn.text.removePrefix("[MODE: GOAL]").trim()
            turn.text.startsWith("[MODE: PLAN]") -> turn.text.removePrefix("[MODE: PLAN]").trim()
            else -> turn.text
        }
        OrbUserPromptParser.parse(strippedMode)
    }
    val modeBadge = remember(turn.text) {
        when {
            turn.text.startsWith("[MODE: GOAL]") -> "Goal"
            turn.text.startsWith("[MODE: PLAN]") -> "Plan"
            else -> null
        }
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.End
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 310.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(OrbStyle.card)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(18.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp)
                .orbShimmer(active = turn.isPending),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (modeBadge != null) {
                Text(
                    text = modeBadge,
                    color = OrbStyle.textSecondary,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.elevated)
                        .padding(horizontal = 7.dp, vertical = 2.dp)
                )
            }
            if (parsed.images.isNotEmpty()) {
                OrbImageStrip(
                    images = parsed.images,
                    workspaceId = workspaceId,
                    core = core
                )
            }
            if (parsed.files.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    parsed.files.forEach { file ->
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(OrbStyle.surface)
                                .orbPressClickable { onPreviewFile(file.path) }
                                .padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Description,
                                contentDescription = null,
                                tint = OrbStyle.textSecondary,
                                modifier = Modifier.size(12.dp)
                            )
                            Text(
                                text = file.filename,
                                color = Color.White,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
            if (parsed.body.isNotEmpty()) {
                Text(
                    text = parsed.body,
                    color = Color.White,
                    fontSize = 15.sp,
                    lineHeight = 21.sp
                )
            }
        }
    }
}

@Composable
private fun OrbAssistantTurnView(
    turn: OrbTurn.Assistant,
    onSendAnswer: (String) -> Unit
) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    val segments = remember(turn.text) { OrbQuizParser.split(turn.text) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1400L)
            copied = false
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        segments.forEach { seg ->
            when (seg) {
                is OrbSegment.Markdown -> {
                    OrbRichText(markdown = seg.text, tone = OrbRichTextTone.Primary)
                }
                is OrbSegment.Quiz -> {
                    OrbQuizCard(
                        payload = seg.payload,
                        onSubmitAnswer = onSendAnswer
                    )
                }
            }
        }

        if (!turn.isStreaming && turn.text.isNotEmpty()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .orbPressClickable {
                            OrbStyle.copyToClipboard(context, turn.text)
                            copied = true
                        }
                        .padding(vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                        contentDescription = "Copy",
                        tint = if (copied) OrbStyle.success else OrbStyle.textMuted,
                        modifier = Modifier.size(12.dp)
                    )
                    if (copied) {
                        Text(
                            text = "Copied",
                            color = OrbStyle.success,
                            fontSize = 11.sp
                        )
                    }
                }
                val rel = OrbJSON.relative(turn.timestamp)
                if (rel.isNotEmpty()) {
                    Text(
                        text = rel,
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp
                    )
                }
            }
        }
    }
}

@Composable
fun OrbWorkFoldView(
    fold: OrbTurn.WorkFold,
    onPreviewFile: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }

    LaunchedEffect(fold.isLive) {
        while (fold.isLive && isActive) {
            nowMs = System.currentTimeMillis()
            delay(1000L)
        }
    }

    val summary = remember(fold.steps, fold.isLive) {
        if (fold.isLive) {
            fold.steps.lastOrNull()?.title ?: "Working…"
        } else {
            val reads = fold.steps.count { it.kind == OrbWorkStep.Kind.Read }
            val edits = fold.steps.count { it.kind == OrbWorkStep.Kind.Edit }
            val cmds = fold.steps.count { it.kind == OrbWorkStep.Kind.Command }
            val parts = mutableListOf<String>()
            if (reads > 0) parts.add("$reads ${if (reads == 1) "read" else "reads"}")
            if (edits > 0) parts.add("$edits ${if (edits == 1) "edit" else "edits"}")
            if (cmds > 0) parts.add("$cmds ${if (cmds == 1) "command" else "commands"}")
            if (parts.isEmpty()) {
                "Worked (${fold.steps.size} ${if (fold.steps.size == 1) "step" else "steps"})"
            } else {
                "Worked — ${parts.joinToString(", ")}"
            }
        }
    }

    val elapsedText = remember(fold.startedAt, nowMs, fold.isLive) {
        if (!fold.isLive) return@remember null
        val startMs = OrbJSON.dateEpochMs(fold.startedAt) ?: return@remember null
        val sec = maxOf(0L, (nowMs - startMs) / 1000L)
        val m = sec / 60L
        val s = sec % 60L
        "%d:%02d".format(m, s)
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        if (expanded && fold.steps.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp)
            ) {
                fold.steps.forEach { step ->
                    val icon: ImageVector = when (step.kind) {
                        OrbWorkStep.Kind.Thinking -> Icons.Default.Psychology
                        OrbWorkStep.Kind.Read -> Icons.Default.Description
                        OrbWorkStep.Kind.Edit -> Icons.Default.Edit
                        OrbWorkStep.Kind.Command -> Icons.Default.Terminal
                        OrbWorkStep.Kind.Search -> Icons.Default.Search
                        OrbWorkStep.Kind.Tool -> Icons.Default.Build
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .orbPressClickable(enabled = step.filePath != null) {
                                step.filePath?.let(onPreviewFile)
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            tint = OrbStyle.icon,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = step.title,
                            color = OrbStyle.textSecondary,
                            fontSize = 12.sp,
                            fontFamily = if (step.kind == OrbWorkStep.Kind.Command) FontFamily.Monospace else FontFamily.Default,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        if (step.filePath != null) {
                            Icon(
                                imageVector = Icons.Default.ChevronRight,
                                contentDescription = null,
                                tint = OrbStyle.textMuted,
                                modifier = Modifier.size(12.dp)
                            )
                        }
                    }
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .orbPressClickable(enabled = fold.steps.isNotEmpty()) { expanded = !expanded }
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (fold.isLive) {
                OrbRunningDots(color = OrbStyle.icon, dotSize = 2.5.dp, spacing = 2.1.dp)
            }
            Text(
                text = summary,
                color = if (fold.isLive) Color.White else OrbStyle.textSecondary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f, fill = false)
                    .orbShimmer(active = fold.isLive)
            )
            if (elapsedText != null) {
                Text(
                    text = elapsedText,
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace
                )
            }
            if (fold.steps.isNotEmpty()) {
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
    }
}

@Composable
private fun OrbMissionTasksCard(todos: List<OrbTodoEntry>) {
    var expanded by remember { mutableStateOf(false) }
    val completedCount = remember(todos) {
        todos.count { it.status in setOf("completed", "done", "succeeded") }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .orbPressClickable { expanded = !expanded }
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                tint = if (completedCount == todos.size) OrbStyle.success else OrbStyle.icon,
                modifier = Modifier.size(14.dp)
            )
            Text(
                text = "$completedCount/${todos.size} tasks",
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            Icon(
                imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = OrbStyle.textMuted,
                modifier = Modifier.size(15.dp)
            )
        }

        if (expanded) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                todos.forEach { todo ->
                    val done = todo.status in setOf("completed", "done", "succeeded")
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = if (done) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = if (done) OrbStyle.success else OrbStyle.textMuted,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = todo.content,
                            color = if (done) OrbStyle.textMuted else OrbStyle.textSecondary,
                            fontSize = 12.sp
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun OrbBackgroundWakeRow(turn: OrbTurn.Wake) {
    var expanded by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .orbPressClickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                text = "Controller wake",
                color = OrbStyle.textMuted,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            Icon(
                imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ChevronRight,
                contentDescription = null,
                tint = OrbStyle.textMuted,
                modifier = Modifier.size(12.dp)
            )
        }
        if (expanded) {
            Text(
                text = turn.text,
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbAgentPickerSheet(
    backends: List<OrbRow>,
    workspaces: List<OrbRow>,
    providers: List<OrbRow>,
    repositories: List<OrbRow>,
    selectedBackend: String,
    onSelectBackend: (String) -> Unit,
    selectedModel: String,
    onSelectModel: (String) -> Unit,
    selectedWorkspaceId: String,
    onSelectWorkspaceId: (String) -> Unit,
    selectedAccount: String,
    onSelectAccount: (String) -> Unit,
    selectedRepo: String,
    onSelectRepo: (String) -> Unit,
    selectedGitRef: String,
    onSelectGitRef: (String) -> Unit,
    selectedConfigProfile: String,
    onSelectConfigProfile: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val isCloudService = selectedBackend in setOf("chatgpt", "cursor_cloud", "grok_bot", "hermes")

    val backendOptions = remember(backends) {
        val fromServer = backends.mapNotNull { it.str("id", "name", "slug") }
        (fromServer + listOf("claude", "codex", "opencode", "gemini", "hermes", "chatgpt", "cursor_cloud", "grok_bot"))
            .distinct()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = OrbStyle.background,
        contentColor = Color.White
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .height(580.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Agent Configuration",
                    color = Color.White,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "Done",
                    color = Color.White,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .orbPressClickable { onDismiss() }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }

            // Service Type (Harness vs Cloud)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "HARNESS / SERVICE",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp
                )
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    backendOptions.forEach { b ->
                        val active = selectedBackend == b
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(if (active) Color.White else OrbStyle.surface)
                                .border(1.dp, if (active) Color.Transparent else OrbStyle.border, CircleShape)
                                .orbPressClickable { onSelectBackend(b) }
                                .padding(horizontal = 13.dp, vertical = 8.dp)
                        ) {
                            Text(
                                text = b,
                                color = if (active) Color.Black else Color.White,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }
            }

            // Machine / Workspace
            if (!isCloudService && workspaces.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "MACHINE / WORKSPACE",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    ) {
                        workspaces.take(10).forEachIndexed { idx, ws ->
                            val wid = ws.str("id") ?: ws.id
                            val wName = ws.str("name", "title", "slug") ?: wid.take(8)
                            val wType = ws.str("workspace_type", "type") ?: "host"
                            val selected = selectedWorkspaceId == wid
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .orbPressClickable { onSelectWorkspaceId(wid) }
                                    .padding(horizontal = 14.dp, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = wName,
                                        color = Color.White,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium
                                    )
                                    Text(
                                        text = wType,
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp
                                    )
                                }
                                if (selected) {
                                    Icon(
                                        imageVector = Icons.Default.Check,
                                        contentDescription = null,
                                        tint = Color.White,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            if (idx < minOf(workspaces.size, 10) - 1) {
                                HorizontalDivider(color = OrbStyle.border)
                            }
                        }
                    }
                }
            }

            // Model override
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "MODEL (OPTIONAL)",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                        .padding(horizontal = 12.dp, vertical = 11.dp)
                ) {
                    if (selectedModel.isEmpty()) {
                        Text("Default model for $selectedBackend", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
                    BasicTextField(
                        value = selectedModel,
                        onValueChange = onSelectModel,
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp, fontFamily = FontFamily.Monospace),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            // Repository & Git Ref
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "REPOSITORY & GIT REF",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                            .padding(horizontal = 12.dp, vertical = 11.dp)
                    ) {
                        if (selectedRepo.isEmpty()) {
                            Text("owner/repo", color = OrbStyle.textMuted, fontSize = 13.sp)
                        }
                        BasicTextField(
                            value = selectedRepo,
                            onValueChange = onSelectRepo,
                            textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                            cursorBrush = SolidColor(Color.White),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                    Box(
                        modifier = Modifier
                            .width(110.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                            .padding(horizontal = 12.dp, vertical = 11.dp)
                    ) {
                        if (selectedGitRef.isEmpty()) {
                            Text("main", color = OrbStyle.textMuted, fontSize = 13.sp)
                        }
                        BasicTextField(
                            value = selectedGitRef,
                            onValueChange = onSelectGitRef,
                            textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                            cursorBrush = SolidColor(Color.White),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }
}
