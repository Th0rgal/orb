package sh.sandboxed.dashboard.orb

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.CallSplit
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Autorenew
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
import androidx.compose.material.icons.filled.Mic
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
import androidx.compose.runtime.withFrameNanos
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
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
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
            Plan -> if (text.startsWith("/plan", ignoreCase = true)) text else "/plan $text"
            Goal -> if (text.startsWith("/goal", ignoreCase = true)) text else "/goal $text"
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

        val eventUserTexts = mutableListOf<Pair<String, String?>>()
        if (events.isNotEmpty()) {
            events.forEach { ev ->
                val type = (ev.str("type", "event_type", "kind") ?: "").lowercase()
                val data = ev.dict("data") ?: ev.raw
                when {
                    type == "user_message" || type == "user" -> {
                        val text = OrbJSON.str(data, "content", "text", "message")
                            ?: ev.str("content", "text", "message") ?: ""
                        if (text.isNotEmpty()) {
                            eventUserTexts.add(text to ev.str("created_at", "timestamp"))
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

        // Deduplicate consecutive identical/retry assistant messages (matching iOS history logic)
        val deduplicatedMessages = mutableListOf<OrbRow>()
        for (msg in messages) {
            val role = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
            val text = (msg.str("content", "text", "message") ?: "").trim()
            if ((role == "assistant" || role == "agent") && deduplicatedMessages.isNotEmpty()) {
                val prev = deduplicatedMessages.last()
                val prevRole = (prev.str("role", "sender", "author") ?: "assistant").lowercase()
                val prevText = (prev.str("content", "text", "message") ?: "").trim()
                if (prevRole == "assistant" || prevRole == "agent") {
                    val sharedLen = minOf(160, minOf(prevText.length, text.length))
                    if (prevText == text || (sharedLen >= 80 && prevText.take(sharedLen) == text.take(sharedLen))) {
                        deduplicatedMessages[deduplicatedMessages.lastIndex] = msg
                        continue
                    }
                }
            }
            deduplicatedMessages.add(msg)
        }

        var lastAssistantTurnIndex = -1
        if (deduplicatedMessages.isNotEmpty()) {
            deduplicatedMessages.forEachIndexed { idx, msg ->
                val role = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
                val text = msg.str("content", "text", "message") ?: ""
                val ts = msg.str("created_at", "timestamp", "updated_at")
                if (role == "user" || role == "operator" || role == "human") {
                    if (text.isNotEmpty()) {
                        if (isControllerWake(text)) {
                            turns.add(OrbTurn.Wake("wake-$idx-${msg.id}", text, ts))
                        } else {
                            turns.add(OrbTurn.User("u-$idx-${msg.id}", text, ts))
                        }
                    }
                } else if (role == "assistant" || role == "agent") {
                    if (pendingWork.isEmpty()) {
                        val toolCalls = msg.rows("tool_calls")
                        toolCalls.forEach { tc ->
                            parseToolStep(tc, tc.raw)?.let { pendingWork.add(it) }
                        }
                    }
                    if (text.isNotEmpty()) {
                        lastAssistantTurnIndex = turns.size
                        turns.add(OrbTurn.Assistant("a-$idx-${msg.id}", text, ts))
                    }
                }
            }
        }

        // Include any user_message events that haven't landed in mission.history yet
        for ((evIdx, pair) in eventUserTexts.withIndex()) {
            val (uText, uTs) = pair
            val alreadyInHistory = deduplicatedMessages.any {
                val r = (it.str("role", "sender", "author") ?: "").lowercase()
                (r == "user" || r == "operator" || r == "human") && (it.str("content", "text", "message")?.trim() == uText.trim())
            }
            if (!alreadyInHistory) {
                if (isControllerWake(uText)) {
                    turns.add(OrbTurn.Wake("wake-ev-$evIdx", uText, uTs))
                } else {
                    turns.add(OrbTurn.User("u-ev-$evIdx", uText, uTs))
                }
            }
        }

        val cappedWork = if (pendingWork.size > 40) pendingWork.takeLast(40) else pendingWork.toList()
        if (cappedWork.isNotEmpty()) {
            val fold = OrbTurn.WorkFold(
                id = "work-fold-main",
                steps = cappedWork,
                isLive = isLive && streamingText.isEmpty(),
                startedAt = startedAt
            )
            // Place completed work fold right before the final assistant response (or at bottom when live)
            if (!isLive && lastAssistantTurnIndex >= 0 && lastAssistantTurnIndex <= turns.size) {
                turns.add(lastAssistantTurnIndex, fold)
            } else {
                turns.add(fold)
            }
            pendingWork.clear()
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

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
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
        val cached = if (missionId != null) OrbReadCache.loadRows(messagesCacheKey) else emptyList()
        val seeded = if (cached.isNotEmpty()) cached else (initialMission?.rows("history") ?: emptyList())
        if (cached.isEmpty() && seeded.isNotEmpty() && missionId != null) {
            OrbReadCache.saveRows(messagesCacheKey, seeded)
        }
        mutableStateOf(seeded)
    }
    var events by remember(missionId) {
        mutableStateOf(if (missionId != null) OrbReadCache.loadRows(eventsCacheKey) else emptyList())
    }
    var streamingText by remember(missionId) { mutableStateOf("") }
    // False until the first history fetch for this mission settles, so an existing
    // conversation shows a loading row instead of the "Start a conversation" empty state.
    var historySettled by remember(missionId) { mutableStateOf(missionId == null) }
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
    var sideAgentSession by remember(initialMission?.id) { mutableStateOf<OrbSideAgentSession?>(null) }
    var commandBanner by remember { mutableStateOf<String?>(null) }

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
        var anyFetchOk = false
        try {
            val idsToLoad = if (chainIds.size > 1) chainIds.takeLast(3) else listOf(targetId)
            val allMsgs = mutableListOf<OrbRow>()
            val allEvs = mutableListOf<OrbRow>()

            kotlinx.coroutines.coroutineScope {
                val jobs = idsToLoad.map { cid ->
                    async(Dispatchers.IO) {
                        val existingForCid = if (cid == targetId) events else OrbReadCache.loadRows("mission_events_$cid")
                        val lastSeq = existingForCid.lastOrNull()?.int("sequence", "seq")
                        val detailDef = async {
                            orbTry(OrbLog.Category.Network, "/api/control/missions") { core.fetchDict("/api/control/missions/${core.encodeComponent(cid)}") }.getOrNull()
                        }
                        val evPath = if (lastSeq != null && lastSeq > 0) {
                            "/api/control/missions/${core.encodeComponent(cid)}/events?limit=150&since_seq=$lastSeq"
                        } else {
                            "/api/control/missions/${core.encodeComponent(cid)}/events?limit=150"
                        }
                        val eventsDef = async {
                            orbTry(OrbLog.Category.Network, "core.fetchRows") { core.fetchRows(evPath, "events") }.getOrDefault(emptyList())
                        }
                        val detail = detailDef.await()
                        if (detail != null) anyFetchOk = true
                        val histRows = if (detail != null) {
                            OrbRow(cid, detail).rows("history")
                        } else {
                            allMissions.firstOrNull { it.id == cid }?.rows("history") ?: emptyList()
                        }
                        val deltaEvs = eventsDef.await()
                        val mergedEvs = if (lastSeq != null && lastSeq > 0 && existingForCid.isNotEmpty()) {
                            (existingForCid + deltaEvs).distinctBy { it.int("sequence", "seq") ?: it.id }
                        } else if (deltaEvs.isNotEmpty()) {
                            deltaEvs
                        } else {
                            existingForCid
                        }
                        if (cid == targetId && detail != null) {
                            withContext(Dispatchers.Main) {
                                currentMission = OrbRow(cid, detail)
                            }
                        }
                        Triple(cid, histRows, mergedEvs)
                    }
                }
                for (job in jobs) {
                    val (cid, hRows, eRows) = job.await()
                    if (hRows.isNotEmpty()) {
                        OrbReadCache.saveRows("mission_msgs_$cid", hRows)
                        allMsgs.addAll(hRows)
                    }
                    if (eRows.isNotEmpty()) {
                        OrbReadCache.saveRows("mission_events_$cid", eRows)
                        allEvs.addAll(eRows)
                    }
                }
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
        } catch (t: Throwable) {
            if (t !is kotlinx.coroutines.CancellationException) OrbLog.w(OrbLog.Category.Network, "conversation history load failed", t)
        }
        // Surface a failed first load instead of a silent empty screen; later polls
        // keep failing quietly while cached turns are on screen.
        if (!historySettled) {
            historySettled = true
            if (!anyFetchOk && messages.isEmpty() && events.isEmpty()) {
                errorMessage = "Couldn't load this conversation."
            }
        }
    }

    // Poll + SSE stream when missionId is active
    DisposableEffect(missionId) {
        var sse: EventSource? = null
        if (missionId != null) {
            sse = orbTry(OrbLog.Category.Network, "core.openSSE") {
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
            delay(if (isLive) 2800L else 10000L)
            loadHistory(id)
        }
    }

    var latestTurns by remember { mutableStateOf<List<OrbTurn>>(emptyList()) }

    // Client-side slash commands (/btw, /fork, /clone, /pause), mirroring Orb.
    fun runMissionCommand(command: OrbMissionCommand, argument: String) {
        val id = missionId
        if (id == null) {
            errorMessage = "${command.trigger} needs an existing conversation."
            return
        }
        inputText = ""
        errorMessage = null
        isSending = true
        scope.launch {
            try {
                val base = "/api/control/missions/${core.encodeComponent(id)}"
                when (command) {
                    OrbMissionCommand.Btw -> {
                        val question = argument.ifEmpty {
                            if (pendingAttachments.isNotEmpty()) "Please look at the attachments." else ""
                        }
                        if (question.isEmpty()) throw OrbError("Type a question after /btw.")
                        val child = OrbSideAgent.launch(core, id, question, latestTurns)
                        sideAgentSession = OrbSideAgentSession(child.id, question)
                    }
                    OrbMissionCommand.Fork -> {
                        val body = mutableMapOf<String, Any?>(
                            "backend" to selectedBackend,
                            "model_override" to selectedModel,
                            "model_effort" to null,
                            "idempotency_key" to UUID.randomUUID().toString()
                        )
                        val created = OrbJSON.dict(core.request("$base/fork", method = "POST", body = body))
                            ?: throw OrbError("Fork failed.")
                        core.refreshMissionsQuietly()
                        currentMission = OrbRow(created)
                        commandBanner = "Forked into a new conversation"
                    }
                    OrbMissionCommand.Clone -> {
                        val body = mutableMapOf<String, Any?>(
                            "backend" to selectedBackend,
                            "clone_messages" to false
                        )
                        if (selectedModel.isNotEmpty()) body["model_override"] = selectedModel
                        if (argument.isNotEmpty()) body["title"] = argument
                        val created = OrbJSON.dict(core.request("$base/clone", method = "POST", body = body))
                            ?: throw OrbError("Clone failed.")
                        core.refreshMissionsQuietly()
                        currentMission = OrbRow(created)
                        commandBanner = "Cloned into a new conversation"
                    }
                    OrbMissionCommand.Pause -> {
                        core.request("$base/pause", method = "POST", body = mapOf("actor" to "orb-android"))
                        core.refreshMissionsQuietly()
                        loadHistory(id)
                        commandBanner = "Agent paused"
                    }
                }
            } catch (e: Throwable) {
                errorMessage = e.message ?: "${command.trigger} failed"
            } finally {
                isSending = false
            }
        }
    }

    fun sendTurn(rawInput: String? = null) {
        val baseText = (rawInput ?: inputText).trim()
        if (baseText.isEmpty() && pendingAttachments.isEmpty()) return
        if (rawInput == null) {
            OrbMissionCommand.parse(baseText)?.let { (command, arg) ->
                runMissionCommand(command, arg)
                return
            }
        }
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

                // Optimistic user message: the exact text Core will store, so the
                // copy that comes back in events replaces it instead of doubling it.
                val optimistic = OrbRow(
                    "local-${UUID.randomUUID()}",
                    mapOf(
                        "role" to "user",
                        "content" to finalPrompt.trim(),
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
                orbTry(OrbLog.Category.Network, "/api/control/missions") {
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

    val allTurns = remember(messages, events, streamingText, isLive, liveRow) {
        OrbTimelineBuilder.build(
            messages = messages,
            events = events,
            streamingText = streamingText,
            isLive = isLive,
            startedAt = liveRow?.str("root_started_at", "started_at", "created_at")
        )
    }

    LaunchedEffect(allTurns) { latestTurns = allTurns }

    var visibleTurnLimit by remember(missionId) { mutableIntStateOf(24) }
    val turns = remember(allTurns, visibleTurnLimit) {
        if (allTurns.size > visibleTurnLimit) allTurns.takeLast(visibleTurnLimit) else allTurns
    }

    val changedFiles = remember(allTurns) { OrbTurnRecap.changedFiles(allTurns) }

    val todos = remember(events, liveRow) {
        OrbTimelineBuilder.extractTodos(events, liveRow)
    }

    val activeQuestion = remember(events, messages, liveRow, dismissedQuestionId) {
        val status = liveRow?.str("status", "state") ?: ""
        OrbQuestionExtractor.extract(events, messages, status)
            ?.takeIf { it.id != dismissedQuestionId }
    }

    var dismissedPlanReviewKeys by remember(missionId) { mutableStateOf<Set<String>>(emptySet()) }
    var isEditingPlanFeedback by remember(missionId) { mutableStateOf(false) }
    var planFeedbackDraft by remember(missionId) { mutableStateOf("") }

    val completedPlanTurnKey = remember(allTurns, isLive, activeQuestion, dismissedPlanReviewKeys) {
        if (isLive || activeQuestion != null) return@remember null
        val lastUser = allTurns.filterIsInstance<OrbTurn.User>().lastOrNull() ?: return@remember null
        val trimmed = lastUser.text.trim()
        val isPlanTurn = trimmed.equals("/plan", ignoreCase = true) ||
            trimmed.lowercase().startsWith("/plan ") ||
            trimmed.lowercase().startsWith("/plan\n") ||
            trimmed.startsWith("[MODE: PLAN]")
        if (!isPlanTurn) return@remember null
        val lastUserIdx = allTurns.indexOfLast { it.id == lastUser.id }
        val hasAssistantReply = lastUserIdx >= 0 && allTurns.drop(lastUserIdx + 1).any {
            it is OrbTurn.Assistant && it.text.trim().isNotEmpty()
        }
        if (!hasAssistantReply) return@remember null
        val key = "plan-review-${missionId ?: "new"}-${lastUser.id}"
        if (dismissedPlanReviewKeys.contains(key)) null else key
    }

    var dictationPhase by remember(missionId) { mutableStateOf(OrbAndroidDictationPhase.Idle) }
    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val matches = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            val spoken = matches?.firstOrNull()?.trim().orEmpty()
            if (spoken.isNotEmpty()) {
                inputText = if (inputText.trim().isEmpty()) spoken else "${inputText.trimEnd()} $spoken"
                dictationPhase = OrbAndroidDictationPhase.Idle
            } else {
                dictationPhase = OrbAndroidDictationPhase.Failed
            }
        } else {
            dictationPhase = OrbAndroidDictationPhase.Idle
        }
    }

    // Spark dictation (iOS OrbDictation): record 16 kHz WAV, transcribe on Core,
    // and fall back to the system recognizer if recording or transcription fails.
    remember(context) { OrbDictationSettings.init(context); OrbBtwSettings.init(context); true }
    val sparkRecorder = remember { OrbSparkRecorder() }
    var dictationElapsed by remember { mutableIntStateOf(0) }
    var showDictationLanguages by remember { mutableStateOf(false) }

    fun appendTranscript(spoken: String) {
        inputText = if (inputText.trim().isEmpty()) spoken else "${inputText.trimEnd()} $spoken"
    }

    fun launchSystemSpeech() {
        dictationPhase = OrbAndroidDictationPhase.Listening
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, OrbDictationSettings.resolve())
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Microphone")
        }
        runCatching {
            speechLauncher.launch(intent)
        }.onFailure {
            dictationPhase = OrbAndroidDictationPhase.Failed
        }
    }

    fun startSparkRecording() {
        if (!sparkRecorder.start()) {
            launchSystemSpeech()
            return
        }
        dictationElapsed = 0
        dictationPhase = OrbAndroidDictationPhase.Recording
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) startSparkRecording() else launchSystemSpeech()
    }

    fun launchSpeech() {
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) startSparkRecording() else micPermissionLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
    }

    fun finishSparkRecording() {
        val wav = sparkRecorder.stop()
        if (wav == null) {
            dictationPhase = OrbAndroidDictationPhase.Idle
            return
        }
        dictationPhase = OrbAndroidDictationPhase.Transcribing
        scope.launch {
            val text = runCatching {
                OrbSparkTranscriber.transcribe(core, wav, OrbDictationSettings.resolve())
            }.getOrNull()
            if (dictationPhase != OrbAndroidDictationPhase.Transcribing) return@launch
            if (!text.isNullOrEmpty()) {
                appendTranscript(text)
                dictationPhase = OrbAndroidDictationPhase.Idle
            } else {
                // Spark unavailable or returned nothing: let the on-device recognizer try.
                launchSystemSpeech()
            }
        }
    }

    LaunchedEffect(dictationPhase) {
        while (dictationPhase == OrbAndroidDictationPhase.Recording) {
            delay(250)
            dictationElapsed = sparkRecorder.elapsedSeconds
            if (dictationElapsed >= OrbSparkRecorder.MAX_SECONDS) finishSparkRecording()
        }
    }

    DisposableEffect(Unit) { onDispose { sparkRecorder.cancel() } }

    // Project context files for `@` mentions. Mirrors iOS OrbAttachments: the context
    // manifest (entries keyed by path) first, then a shallow walk of /files.
    var projectFiles by remember(project.id) { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(project.id) {
        val slug = core.encodeComponent(project.str("slug", "id") ?: project.id)
        val loaded = mutableListOf<String>()
        orbTry(OrbLog.Category.Network, "/api/projects") {
            val manifest = core.fetchDict("/api/projects/$slug/context/manifest")
            val entries = OrbJSON.dict(manifest["entries"]) ?: emptyMap()
            for ((path, meta) in entries) {
                if (OrbJSON.bool(OrbJSON.dict(meta), "directory") != true) loaded.add(path)
            }
        }
        if (loaded.isEmpty()) {
            runCatching {
                val queue = ArrayDeque(listOf("" to 0))
                while (queue.isNotEmpty() && loaded.size < 160) {
                    val (dir, depth) = queue.removeFirst()
                    val rows = core.fetchRows(
                        "/api/projects/$slug/files?path=${core.encodeComponent(dir)}",
                        "entries"
                    )
                    for (r in rows) {
                        val name = r.str("name") ?: continue
                        val rel = if (dir.isEmpty()) name else "$dir/$name"
                        if (r.str("kind") == "dir") {
                            if (depth < 1) queue.addLast(rel to depth + 1)
                        } else {
                            loaded.add(rel)
                        }
                    }
                }
            }
        }
        projectFiles = loaded.distinct().sorted()
    }

    val activeAtMentionQuery = remember(inputText) {
        val atIdx = inputText.lastIndexOf('@')
        if (atIdx < 0) return@remember null
        if (atIdx > 0 && !inputText[atIdx - 1].isWhitespace()) return@remember null
        val tail = inputText.substring(atIdx + 1)
        if (tail.contains(' ') || tail.contains('\n')) null else tail.lowercase()
    }

    val matchingContextFiles = remember(activeAtMentionQuery, projectFiles) {
        val q = activeAtMentionQuery ?: return@remember emptyList()
        val base = if (projectFiles.isNotEmpty()) projectFiles else listOf("AGENTS.md", "README.md", ".paloma/project.md")
        base.filter { q.isEmpty() || it.lowercase().contains(q) }.take(6)
    }

    val prUrl = remember(liveRow, events) {
        liveRow?.str("pr_url", "pull_request_url")
    }

    val listState = rememberLazyListState()
    var hasAnchoredInitial by remember(missionId) { mutableStateOf(false) }
    val workStepCount = remember(turns) {
        turns.filterIsInstance<OrbTurn.WorkFold>().sumOf { it.steps.size }
    }

    suspend fun scrollToAbsoluteBottom() {
        val layout = listState.layoutInfo
        val totalItems = layout.totalItemsCount
        val targetIdx = maxOf(0, (if (totalItems > 0) totalItems else turns.size) - 1)
        listState.scrollToItem(targetIdx, scrollOffset = 0)
        val postLayout = listState.layoutInfo
        val lastInfo = postLayout.visibleItemsInfo.lastOrNull()
        if (lastInfo != null) {
            val overflow = (lastInfo.offset + lastInfo.size) - postLayout.viewportEndOffset
            if (overflow > 0) {
                listState.scrollBy(overflow.toFloat())
            }
        }
    }

    LaunchedEffect(turns.size, turns.lastOrNull()?.id, workStepCount, streamingText.length, completedPlanTurnKey) {
        if (turns.isNotEmpty()) {
            val layout = listState.layoutInfo
            val totalItems = layout.totalItemsCount
            val lastVisible = layout.visibleItemsInfo.lastOrNull()?.index ?: 0
            val nearBottom = !hasAnchoredInitial || totalItems == 0 || lastVisible >= totalItems - 3
            if (nearBottom) {
                scrollToAbsoluteBottom()
                if (!hasAnchoredInitial) {
                    // Settle tall rows (markdown, images) for a couple of frames before revealing.
                    withFrameNanos { }
                    scrollToAbsoluteBottom()
                    withFrameNanos { }
                    scrollToAbsoluteBottom()
                    hasAnchoredInitial = true
                    delay(220)
                    scrollToAbsoluteBottom()
                }
            }
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
                            maxLines = 1,
                            softWrap = false,
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
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    val contCount = liveRow?.int("_continuation_count") ?: 1
                    if (contCount > 1) {
                        Text(
                            text = "· $contCount continuations",
                            color = OrbStyle.textMuted,
                            fontSize = 11.sp,
                            maxLines = 1,
                            softWrap = false
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
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false
                    )
                }
            }
        }

        // Conversation Body
        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                // Keep the list invisible until it has been anchored at the bottom, so
                // opening a conversation lands there without showing the top first.
                .graphicsLayer { alpha = if (hasAnchoredInitial || turns.isEmpty()) 1f else 0f },
            contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            errorMessage?.let { err ->
                item(key = "conv_error") {
                    OrbRemoteLog(
                        title = err,
                        log = core.lastErrorLog.collectAsState().value,
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

            if (OrbConversationLoadState.showLoading(turns.isEmpty(), historySettled, errorMessage != null)) {
                item(key = "loading_conv") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 72.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OrbRunningDots(color = OrbStyle.icon, dotSize = 3.dp, spacing = 3.dp)
                        Spacer(Modifier.size(10.dp))
                        Text("Loading conversation…", color = OrbStyle.textSecondary, fontSize = 13.sp)
                    }
                }
            } else if (turns.isEmpty() && !isLive && historySettled) {
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

            if (allTurns.size > visibleTurnLimit) {
                item(key = "load_earlier_turns") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.03f))
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .orbPressClickable { visibleTurnLimit += 24 }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "Load earlier messages",
                            color = OrbStyle.textSecondary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium
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
                            core = core,
                            missionId = missionId,
                            workspaceId = selectedWorkspaceId.takeIf { it.isNotEmpty() },
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

            if (!isLive && changedFiles.isNotEmpty()) {
                item(key = "turn_changes") {
                    OrbTurnChangesCard(
                        files = changedFiles,
                        prUrl = prUrl,
                        onPreviewFile = { previewFilePath = it },
                        onOpenPr = { url ->
                            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                        }
                    )
                }
            }

            if (activeQuestion != null) {
                item(key = "question_${activeQuestion.id}") {
                    OrbQuestionCard(
                        question = activeQuestion,
                        isSending = isSending,
                        onSelect = { answer ->
                            val callId = activeQuestion.toolCallId
                            if (callId != null) {
                                // Native plan/permission request: reply through tool_result like iOS/Orb.
                                val accept = answer == "Approve"
                                val result = mutableMapOf<String, Any?>("action" to if (accept) "accept" else "revise")
                                if (!accept && answer != "Decline") result["feedback"] = answer
                                scope.launch {
                                    try {
                                        val res = OrbJSON.dict(
                                            core.request(
                                                "/api/control/tool_result",
                                                method = "POST",
                                                body = mapOf(
                                                    "tool_call_id" to callId,
                                                    "name" to (activeQuestion.toolName ?: "ui_native_request"),
                                                    "result" to result
                                                )
                                            )
                                        )
                                        if (OrbJSON.bool(res, "delivered") != true) {
                                            throw OrbError("This request has expired. Refresh the conversation.")
                                        }
                                        dismissedQuestionId = activeQuestion.id
                                        missionId?.let { loadHistory(it) }
                                    } catch (e: Throwable) {
                                        errorMessage = e.message
                                    }
                                }
                            } else {
                                sendTurn(answer)
                            }
                        },
                        onDismiss = { dismissedQuestionId = activeQuestion.id }
                    )
                }
            } else if (completedPlanTurnKey != null) {
                item(key = completedPlanTurnKey) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(OrbStyle.panelRadius))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.panelRadius))
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.ListAlt,
                                contentDescription = null,
                                tint = OrbStyle.inboxBlue,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = "Review the plan",
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f)
                            )
                            Box(
                                modifier = Modifier
                                    .size(22.dp)
                                    .orbPressClickable {
                                        dismissedPlanReviewKeys = dismissedPlanReviewKeys + completedPlanTurnKey
                                        isEditingPlanFeedback = false
                                    },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = "Dismiss",
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(13.dp)
                                )
                            }
                        }

                        Text(
                            text = "Ready to implement this plan, or would you like to request adjustments first?",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium
                        )

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(Color.White)
                                    .orbPressClickable(enabled = !isSending) {
                                        dismissedPlanReviewKeys = dismissedPlanReviewKeys + completedPlanTurnKey
                                        isEditingPlanFeedback = false
                                        composeMode = OrbComposeMode.Message
                                        sendTurn("Proceed with implementing the plan.")
                                    }
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Check,
                                    contentDescription = null,
                                    tint = Color.Black,
                                    modifier = Modifier.size(13.dp)
                                )
                                Text(
                                    text = "Implement plan",
                                    color = Color.Black,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }

                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(OrbStyle.card)
                                    .border(1.dp, OrbStyle.border, CircleShape)
                                    .orbPressClickable(enabled = !isSending) {
                                        isEditingPlanFeedback = !isEditingPlanFeedback
                                    }
                                    .padding(horizontal = 14.dp, vertical = 8.dp)
                            ) {
                                Text(
                                    text = "Request changes",
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                        }

                        if (isEditingPlanFeedback) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(OrbStyle.card)
                                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(10.dp))
                                        .padding(horizontal = 11.dp, vertical = 8.dp)
                                ) {
                                    if (planFeedbackDraft.isEmpty()) {
                                        Text(
                                            text = "Describe changes to the plan…",
                                            color = OrbStyle.textMuted,
                                            fontSize = 13.sp
                                        )
                                    }
                                    BasicTextField(
                                        value = planFeedbackDraft,
                                        onValueChange = { planFeedbackDraft = it },
                                        textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                        cursorBrush = SolidColor(Color.White),
                                        singleLine = true,
                                        modifier = Modifier.fillMaxWidth()
                                    )
                                }
                                val canSendFeedback = planFeedbackDraft.trim().isNotEmpty() && !isSending
                                Box(
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(if (canSendFeedback) Color.White else OrbStyle.card)
                                        .orbPressClickable(enabled = canSendFeedback) {
                                            val feedback = planFeedbackDraft.trim()
                                            planFeedbackDraft = ""
                                            isEditingPlanFeedback = false
                                            dismissedPlanReviewKeys = dismissedPlanReviewKeys + completedPlanTurnKey
                                            sendTurn("/plan $feedback")
                                        }
                                        .padding(horizontal = 12.dp, vertical = 8.dp)
                                ) {
                                    Text(
                                        text = "Send",
                                        color = if (canSendFeedback) Color.Black else OrbStyle.textMuted,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }
                        }
                    }
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
            // @ context file mention popup
            if (matchingContextFiles.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OrbStyle.panelRadius))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.panelRadius))
                        .padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = "CONTEXT FILES",
                        color = OrbStyle.textMuted,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                    matchingContextFiles.forEach { filePath ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .orbPressClickable {
                                    val atIdx = inputText.lastIndexOf('@')
                                    if (atIdx >= 0) {
                                        inputText = inputText.substring(0, atIdx) + "@$filePath "
                                    } else {
                                        inputText = "${inputText.trimEnd()} @$filePath "
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Description,
                                contentDescription = null,
                                tint = OrbStyle.icon,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = filePath,
                                color = Color.White,
                                fontSize = 13.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }

            // Slash mode menu popup
            if (showModePicker || (inputText.startsWith("/") && !inputText.contains(' '))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OrbStyle.panelRadius))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.panelRadius))
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
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                    if (missionId != null) {
                        val typed = inputText.trim().lowercase()
                        val commands = OrbMissionCommand.entries.filter {
                            typed.length <= 1 || it.trigger.startsWith(typed)
                        }
                        if (commands.isNotEmpty()) {
                            Text(
                                text = "COMMANDS",
                                color = OrbStyle.textMuted,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.7.sp,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                            )
                        }
                        commands.forEach { command ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .orbPressClickable {
                                        showModePicker = false
                                        when (command) {
                                            OrbMissionCommand.Btw -> inputText = "/btw "
                                            OrbMissionCommand.Clone -> inputText = "/clone "
                                            else -> runMissionCommand(command, "")
                                        }
                                    }
                                    .padding(horizontal = 10.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(
                                    imageVector = when (command) {
                                        OrbMissionCommand.Btw -> Icons.Default.Psychology
                                        OrbMissionCommand.Fork -> Icons.Default.CallSplit
                                        OrbMissionCommand.Clone -> Icons.Default.ContentCopy
                                        OrbMissionCommand.Pause -> Icons.Default.Pause
                                    },
                                    contentDescription = null,
                                    tint = OrbStyle.icon,
                                    modifier = Modifier.size(15.dp)
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(command.label, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                                    Text(command.subtitle, color = OrbStyle.textMuted, fontSize = 11.sp)
                                }
                                Text(
                                    text = command.trigger,
                                    color = OrbStyle.textMuted,
                                    fontSize = 11.sp,
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 1,
                                    softWrap = false
                                )
                            }
                        }
                    }
                }
            }

            commandBanner?.let { msg ->
                Text(
                    text = msg,
                    color = OrbStyle.success,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(horizontal = 6.dp)
                )
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
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
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

            if (dictationPhase != OrbAndroidDictationPhase.Idle) {
                OrbAndroidDictationCapsule(
                    phase = dictationPhase,
                    elapsedSeconds = dictationElapsed,
                    onCancel = {
                        sparkRecorder.cancel()
                        dictationPhase = OrbAndroidDictationPhase.Idle
                    },
                    onFinish = {
                        if (dictationPhase == OrbAndroidDictationPhase.Recording) finishSparkRecording()
                        else if (dictationPhase != OrbAndroidDictationPhase.Transcribing) dictationPhase = OrbAndroidDictationPhase.Idle
                    },
                    onRetry = { launchSpeech() }
                )
            } else {
                // Shared composer surface; touch targets are sized separately from its border.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OrbStyle.panelRadius))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.panelRadius))
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
                                    OrbComposeMode.Message -> "Message agent…"
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
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        // + Attachment button
                        Box {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .orbPressClickable { showAttachMenu = true }
                                    .padding(7.dp)
                                    .clip(CircleShape)
                                    .background(OrbStyle.card)
                                    .border(1.dp, OrbStyle.border, CircleShape),
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
                                DropdownMenuItem(
                                    text = { Text("Tag Context (@)", color = Color.White, fontSize = 14.sp) },
                                    leadingIcon = {
                                        Icon(Icons.Default.AlternateEmail, contentDescription = null, tint = Color.White)
                                    },
                                    onClick = {
                                        showAttachMenu = false
                                        inputText = if (inputText.isEmpty() || inputText.endsWith(" ")) {
                                            "$inputText@"
                                        } else {
                                            "$inputText @"
                                        }
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
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    softWrap = false
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

                        // Compact Agent / Harness + Machine selector pill (matching iOS)
                        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                            val selectedWorkspaceName = remember(selectedWorkspaceId, workspaces) {
                                workspaces.firstOrNull { (it.str("id") ?: it.id) == selectedWorkspaceId }
                                    ?.str("name", "title", "slug")
                            }
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                    .orbPressClickable { showAgentPicker = true }
                                    .heightIn(min = 44.dp)
                                    .padding(horizontal = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                OrbSfIcons.CpuIcon(
                                    color = OrbStyle.textSecondary,
                                    size = 13.dp
                                )
                                Text(
                                    text = buildString {
                                        append(selectedBackend.ifEmpty { "Agent" })
                                        if (selectedModel.isNotEmpty()) {
                                            append(" · ")
                                            append(selectedModel.substringAfterLast('/'))
                                        }
                                        if (!selectedWorkspaceName.isNullOrEmpty()) {
                                            append(" · ")
                                            append(selectedWorkspaceName)
                                        }
                                    },
                                    color = OrbStyle.textSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                                Icon(
                                    imageVector = Icons.Default.ExpandMore,
                                    contentDescription = null,
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier.size(13.dp)
                                )
                            }
                        }

                        // Microphone dictation button
                        Box {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .combinedClickable(
                                        onClick = { launchSpeech() },
                                        onLongClick = { showDictationLanguages = true }
                                    )
                                    .padding(7.dp)
                                    .clip(CircleShape)
                                    .background(OrbStyle.card)
                                    .border(1.dp, OrbStyle.border, CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Mic,
                                    contentDescription = "Dictate message (hold to choose language: ${OrbDictationSettings.name(OrbDictationSettings.resolve())})",
                                    tint = OrbStyle.textSecondary,
                                    modifier = Modifier.size(16.dp)
                                )
                            }
                            DropdownMenu(
                                expanded = showDictationLanguages,
                                onDismissRequest = { showDictationLanguages = false },
                                containerColor = OrbStyle.elevated
                            ) {
                                val current = OrbDictationSettings.stored
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            "Device language (${OrbDictationSettings.name(OrbDictationSettings.deviceLanguage)})",
                                            color = Color.White
                                        )
                                    },
                                    trailingIcon = { if (current.isEmpty()) Icon(Icons.Default.Check, null, tint = Color.White) },
                                    onClick = {
                                        OrbDictationSettings.update("")
                                        showDictationLanguages = false
                                    }
                                )
                                OrbDictationSettings.languages.forEach { (code, label) ->
                                    DropdownMenuItem(
                                        text = { Text(label, color = Color.White) },
                                        trailingIcon = { if (current == code) Icon(Icons.Default.Check, null, tint = Color.White) },
                                        onClick = {
                                            OrbDictationSettings.update(code)
                                            showDictationLanguages = false
                                        }
                                    )
                                }
                            }
                        }

                        if (isLive && missionId != null) {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .orbPressClickable(enabled = !isStopping) { stopMission() }
                                    .padding(7.dp)
                                    .clip(CircleShape)
                                    .background(OrbStyle.card)
                                    .border(1.dp, OrbStyle.borderStrong, CircleShape),
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
                                .size(44.dp)
                                .orbPressClickable(enabled = canSend) { sendTurn() }
                                .padding(7.dp)
                                .clip(CircleShape)
                                .background(if (canSend) Color.White else OrbStyle.card),
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

    sideAgentSession?.let { session ->
        OrbSideAgentSheet(
            core = core,
            session = session,
            onOpen = { child ->
                sideAgentSession = null
                currentMission = child
            },
            onDismiss = { sideAgentSession = null }
        )
    }

    commandBanner?.let { msg ->
        LaunchedEffect(msg) {
            delay(2500)
            commandBanner = null
        }
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
        val trimmed = turn.text.trim()
        val strippedMode = when {
            trimmed.startsWith("[MODE: GOAL]") -> trimmed.removePrefix("[MODE: GOAL]").trim()
            trimmed.startsWith("[MODE: PLAN]") -> trimmed.removePrefix("[MODE: PLAN]").trim()
            trimmed.lowercase().startsWith("/goal ") -> trimmed.drop(6).trim()
            trimmed.lowercase().startsWith("/plan ") -> trimmed.drop(6).trim()
            else -> turn.text
        }
        OrbUserPromptParser.parse(strippedMode)
    }
    val modeBadge = remember(turn.text) {
        val trimmed = turn.text.trim()
        when {
            trimmed.startsWith("[MODE: GOAL]") || trimmed.lowercase().startsWith("/goal ") || trimmed.equals("/goal", ignoreCase = true) -> "Goal"
            trimmed.startsWith("[MODE: PLAN]") || trimmed.lowercase().startsWith("/plan ") || trimmed.equals("/plan", ignoreCase = true) -> "Plan"
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
                    maxLines = 1,
                    softWrap = false,
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
    core: OrbCore,
    missionId: String?,
    workspaceId: String?,
    onSendAnswer: (String) -> Unit
) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    val messageImages = remember(turn.text) { OrbMessageImages.parse(turn.text) }
    val imageRefs = remember(messageImages, missionId) { messageImages.refs(core, missionId) }
    val segments = remember(messageImages.text) { OrbQuizParser.split(messageImages.text) }

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

        if (imageRefs.isNotEmpty()) {
            OrbImageStrip(images = imageRefs, workspaceId = workspaceId, core = core)
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
                            fontSize = 11.sp,
                            maxLines = 1,
                            softWrap = false
                        )
                    }
                }
                val rel = OrbJSON.relative(turn.timestamp)
                if (rel.isNotEmpty()) {
                    Text(
                        text = rel,
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        maxLines = 1,
                        softWrap = false
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
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    softWrap = false
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
    val completedCount = remember(todos) { OrbTurnRecap.completedCount(todos) }
    val currentTask = remember(todos) { OrbTurnRecap.currentTask(todos) }

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
                maxLines = 1,
                softWrap = false
            )
            Text(
                text = if (!expanded && currentTask != null) currentTask.content else "",
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
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
                    val done = OrbTurnRecap.isDone(todo.status)
                    val active = OrbTurnRecap.isActive(todo.status)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = when {
                                done -> Icons.Default.CheckCircle
                                active -> Icons.Default.Autorenew
                                else -> Icons.Default.RadioButtonUnchecked
                            },
                            contentDescription = null,
                            tint = if (done) OrbStyle.success else if (active) Color.White else OrbStyle.textMuted,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = todo.content,
                            color = if (done) OrbStyle.textMuted else if (active) Color.White else OrbStyle.textSecondary,
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
                    maxLines = 1,
                    softWrap = false,
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
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                softWrap = false
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
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = wType,
                                        color = OrbStyle.textMuted,
                                        fontSize = 11.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
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
                        Text(
                            text = "Default model for $selectedBackend",
                            color = OrbStyle.textMuted,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
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

/** Pure rule for the conversation's first-load row; unit-tested. */
object OrbConversationLoadState {
    fun showLoading(turnsEmpty: Boolean, historySettled: Boolean, hasError: Boolean): Boolean =
        turnsEmpty && !historySettled && !hasError
}

/** End-of-turn recap rules (tasks progress, Changes), matching desktop Orb; unit-tested. */
object OrbTurnRecap {
    private val doneStatuses = setOf("completed", "done", "succeeded")
    private val activeStatuses = setOf("in_progress", "running", "active")

    fun isDone(status: String) = status.lowercase() in doneStatuses
    fun isActive(status: String) = status.lowercase() in activeStatuses
    fun completedCount(todos: List<OrbTodoEntry>) = todos.count { isDone(it.status) }

    /** The task in progress, else the first one not done yet. */
    fun currentTask(todos: List<OrbTodoEntry>): OrbTodoEntry? =
        todos.firstOrNull { isActive(it.status) } ?: todos.firstOrNull { !isDone(it.status) }

    /** Files edited since the last user message, in first-edit order. */
    fun changedFiles(turns: List<OrbTurn>): List<String> {
        val lastUser = turns.indexOfLast { it is OrbTurn.User }
        return turns.drop(lastUser + 1)
            .filterIsInstance<OrbTurn.WorkFold>()
            .flatMap { it.steps }
            .filter { it.kind == OrbWorkStep.Kind.Edit }
            .mapNotNull { it.filePath?.takeIf { p -> p.isNotBlank() } }
            .distinct()
    }
}

@Composable
private fun OrbTurnChangesCard(
    files: List<String>,
    prUrl: String?,
    onPreviewFile: (String) -> Unit,
    onOpenPr: (String) -> Unit
) {
    var expanded by remember(files) { mutableStateOf(files.size <= 3) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().orbPressClickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(Icons.Default.Edit, contentDescription = null, tint = OrbStyle.icon, modifier = Modifier.size(14.dp))
            Text(
                text = "Changes · ${files.size} ${if (files.size == 1) "file" else "files"}",
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            if (!prUrl.isNullOrEmpty()) {
                Text(
                    text = "Open PR",
                    color = OrbStyle.success,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.orbPressClickable { onOpenPr(prUrl) }
                )
            }
            Icon(
                imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = OrbStyle.textMuted,
                modifier = Modifier.size(15.dp)
            )
        }
        if (expanded) {
            files.forEach { path ->
                Row(
                    modifier = Modifier.fillMaxWidth().orbPressClickable { onPreviewFile(path) },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = path.substringAfterLast('/'),
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Icon(Icons.Default.ChevronRight, contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(12.dp))
                }
            }
        }
    }
}
