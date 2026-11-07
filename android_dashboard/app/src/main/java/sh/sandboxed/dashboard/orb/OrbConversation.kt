package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.sync.withLock

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.DragInteraction
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.animation.animateContentSize
import androidx.compose.ui.platform.testTag
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowDown
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
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.DriveFileMove
import androidx.compose.material.icons.filled.ListAlt
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
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
        val startedAt: String?,
        /** Assistant text written between this work's tool calls (see OrbNarration). */
        val narration: List<String> = emptyList()
    ) : OrbTurn(id)

    data class Wake(
        override val id: String,
        val text: String,
        val timestamp: String?
    ) : OrbTurn(id)
}

object OrbTimelineBuilder {
    /** The transcript without the streaming reply, and the stored answers it dedupes against. */
    data class Base(val turns: List<OrbTurn>, val storedAnswers: List<String>)

    fun build(
        messages: List<OrbRow>,
        events: List<OrbRow>,
        streamingText: String,
        isLive: Boolean,
        startedAt: String?
    ): List<OrbTurn> = withStreaming(buildBase(messages, events, streamingText.isNotEmpty(), isLive, startedAt), streamingText)

    /**
     * The screen's timeline: [base] plus an empty streaming placeholder while text streams.
     * The placeholder's item reads the live text itself ([OrbLiveReply]), so a frame of deltas
     * recomposes that item only.
     */
    fun withLiveBubble(base: Base, hasStreamingText: Boolean): List<OrbTurn> =
        if (!hasStreamingText) base.turns
        else OrbTranscriptGates.ensureUniqueTurns(
            base.turns + OrbTurn.Assistant(id = "streaming-assistant", text = "", timestamp = null, isStreaming = true)
        )

    /** The streaming reply on top of [base] (tests, one-off snapshots). */
    fun withStreaming(base: Base, streamingText: String): List<OrbTurn> {
        // Live text the stored history already holds is not shown twice (reloads, SSE replays).
        val liveText = OrbSendFlow.dedupeLiveText(streamingText, base.storedAnswers)
        if (liveText.trim().isEmpty()) return base.turns
        return OrbTranscriptGates.ensureUniqueTurns(
            base.turns + OrbTurn.Assistant(id = "streaming-assistant", text = liveText, timestamp = null, isStreaming = true)
        )
    }

    fun buildBase(
        messages: List<OrbRow>,
        events: List<OrbRow>,
        hasStreamingText: Boolean,
        isLive: Boolean,
        startedAt: String?
    ): Base {
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

        val streamItems = mutableListOf<OrbStreamItem>()
        val assistantTexts = mutableMapOf<String, String>()
        if (events.isNotEmpty()) {
            events.forEachIndexed { evIdx, ev ->
                val type = (ev.str("type", "event_type", "kind") ?: "").lowercase()
                val data = ev.dict("data") ?: ev.raw
                val meta = ev.dict("metadata") ?: OrbJSON.dict(data["metadata"]) ?: emptyMap()
                val queued = OrbJSON.bool(meta, "queued") == true || OrbJSON.bool(data, "queued") == true
                val itemKey = "ev-$evIdx-${ev.id}"
                when {
                    (type == "user_message" || type == "user") && !queued -> streamItems.add(OrbStreamItem.User(itemKey))
                    type.contains("think") || type == "reasoning" -> streamItems.add(OrbStreamItem.Think(itemKey))
                    type.contains("tool_call") || type == "tool_use" || type == "tool" || type == "action" -> {
                        val name = OrbJSON.str(data, "name", "tool", "tool_name", "action") ?: ev.str("name", "tool", "tool_name")
                        if (name != null) streamItems.add(OrbStreamItem.Tool(itemKey, name))
                    }
                    type == "assistant_message" || type == "assistant_message_canonical" -> {
                        val text = OrbJSON.str(data, "content", "text", "message") ?: ev.str("content", "text", "message") ?: ""
                        if (OrbJSON.bool(data, "success") != false && OrbJSON.bool(meta, "success") != false) {
                            streamItems.add(OrbStreamItem.Text(itemKey, text))
                            assistantTexts[itemKey] = text
                        }
                    }
                    type == "tool_result" || type.contains("delta") || type == "text_op" -> Unit
                    else -> streamItems.add(OrbStreamItem.Other(itemKey))
                }
                when {
                    (type == "user_message" || type == "user") && !queued -> pendingWork.clear()
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
        for (msg in OrbConversationHistory.visible(OrbConversationHistory.merge(messages, events)).flatMap { OrbForkContext.expand(it) }) {
            val role = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
            val text = (msg.str("content", "text", "message") ?: "").trim()
            if (msg.int("sequence") == null && (role == "assistant" || role == "agent") && deduplicatedMessages.isNotEmpty()) {
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

        // Narration (text between the active/last turn's tool calls) folds into the work, not the transcript.
        val lastStreamUserIdx = streamItems.indexOfLast { it is OrbStreamItem.User }
        val currentTurnStreamKeys = streamItems.subList(lastStreamUserIdx + 1, streamItems.size).mapTo(mutableSetOf()) { it.key }
        val narrationTexts = OrbNarration.narrationKeys(streamItems)
            .filter { it in currentTurnStreamKeys }
            .mapNotNull { assistantTexts[it]?.trim() }
            .filter { it.isNotEmpty() }
        val narrationSet = narrationTexts.toSet()
        val lastUserMsgIdx = deduplicatedMessages.indexOfLast {
            (it.str("role", "sender", "author") ?: "assistant").lowercase() in setOf("user", "operator", "human")
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
                    if (idx > lastUserMsgIdx && pendingWork.isEmpty()) {
                        val toolCalls = msg.rows("tool_calls")
                        toolCalls.forEach { tc ->
                            parseToolStep(tc, tc.raw)?.let { pendingWork.add(it) }
                        }
                    }
                    val foldedInCurrentTurn = idx > lastUserMsgIdx && narrationSet.isNotEmpty() && text.trim() in narrationSet
                    if (text.isNotEmpty() && !OrbActivityCompaction.isPlaceholderTurn(text) && !foldedInCurrentTurn) {
                        lastAssistantTurnIndex = turns.size
                        turns.add(OrbTurn.Assistant("a-$idx-${msg.id}", text, ts))
                    }
                }
            }
        }

        val cappedWork = if (pendingWork.size > 40) pendingWork.takeLast(40) else pendingWork.toList()
        if (cappedWork.isNotEmpty()) {
            val fold = OrbTurn.WorkFold(
                id = "work-fold-main",
                steps = cappedWork,
                isLive = isLive,
                startedAt = startedAt,
                narration = narrationTexts
            )
            // Place completed work fold right before the final assistant response (or at bottom when live)
            if (!isLive && lastAssistantTurnIndex >= 0 && lastAssistantTurnIndex <= turns.size) {
                turns.add(lastAssistantTurnIndex, fold)
            } else {
                turns.add(fold)
            }
            pendingWork.clear()
        } else if (isLive && turns.none { it is OrbTurn.WorkFold && it.isLive }) {
            turns.add(
                OrbTurn.WorkFold(
                    id = "work-live-placeholder",
                    steps = emptyList(),
                    isLive = true,
                    startedAt = startedAt
                )
            )
        }

        val messagePairs = deduplicatedMessages.map { msg ->
            val rawRole = (msg.str("role", "sender", "author") ?: "assistant").lowercase()
            val normalizedRole = if (rawRole in setOf("user", "operator", "human")) "user" else "assistant"
            normalizedRole to (msg.str("content", "text", "message") ?: "")
        }
        val storedAnswers = OrbSendFlow.currentTurnStoredAnswers(messagePairs, narrationSet)
        return Base(OrbTranscriptGates.ensureUniqueTurns(turns), storedAnswers)
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

data class OrbSlotWaitInfo(
    val label: String,
    val canForce: Boolean
)

fun orbSlotWaitInfo(row: OrbRow?): OrbSlotWaitInfo? {
    if (row == null) return null
    val job = row.dict("remote_job")
    val jobEnded = job != null && (
        OrbJSON.str(job, "phase") == "finished" ||
            OrbJSON.str(job, "finished_at") != null ||
            OrbJSON.str(job, "terminal_reason") != null
        )
    if (job != null && !jobEnded && OrbJSON.str(job, "node_state") == "queued") {
        val node = OrbJSON.str(job, "node_id") ?: row.str("remote_node_id")
        val label = if (node.isNullOrEmpty()) "Waiting for a free slot…" else "Waiting for a free slot on $node…"
        return OrbSlotWaitInfo(label = label, canForce = OrbJSON.bool(job, "forced") != true)
    }
    val status = (row.str("status", "state") ?: "").lowercase()
    val wait = row.dict("queue_wait")
    if ((status == "pending" || status == "queued") && OrbJSON.str(wait, "reason") == "waiting_for_slot") {
        val maxSlots = OrbJSON.int(wait, "slots_max") ?: 0
        val usedSlots = OrbJSON.int(wait, "slots_used") ?: maxSlots
        val label = if (maxSlots > 0) "Waiting for a free slot ($usedSlots/$maxSlots in use)…" else "Waiting for a free slot…"
        return OrbSlotWaitInfo(label = label, canForce = true)
    }
    return null
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun OrbConversationPage(
    core: OrbCore,
    project: OrbRow,
    initialMission: OrbRow?,
    initialFolder: String? = null,
    onOpenDocuments: ((String) -> Unit)? = null,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val allMissions by core.missions.collectAsState()
    val placementVersion by core.placementVersion.collectAsState()
    val backends by core.backends.collectAsState()
    val backendModels by core.backendModels.collectAsState()
    val workspaces by core.workspaces.collectAsState()
    val nodes by core.nodes.collectAsState()
    val providers by core.providers.collectAsState()
    val repositories by core.repositories.collectAsState()

    var currentMission by remember(initialMission?.id) { mutableStateOf(initialMission) }
    val missionId = currentMission?.id

    LaunchedEffect(placementVersion, missionId) {
        if (placementVersion <= 0L || missionId == null) return@LaunchedEffect
        val state = OrbMissionTree.placementOf(missionId) ?: return@LaunchedEffect
        val cur = currentMission ?: return@LaunchedEffect
        val effProj = (state.optimisticProject ?: state.project).takeIf { it.isNotEmpty() }
        val effFolder = state.optimisticFolder ?: state.folder
        currentMission = OrbReadCache.patchRowPlacement(
            cur,
            OrbPlacementCommitItem(
                missionId = missionId,
                project = effProj,
                folder = effFolder,
                placementRevision = state.revision,
                explicitProject = true
            )
        )
    }

    val messagesCacheKey = remember(missionId) { "mission_msgs_${missionId ?: "new"}" }
    val eventsCacheKey = remember(missionId) { "mission_events_${missionId ?: "new"}" }

    var messages by remember(missionId) {
        val cached = if (missionId != null) OrbReadCache.readMemoryRows(messagesCacheKey) else emptyList()
        val seeded = if (cached.isNotEmpty()) cached else (initialMission?.rows("history") ?: emptyList())
        if (cached.isEmpty() && seeded.isNotEmpty() && missionId != null) {
            OrbReadCache.saveRows(messagesCacheKey, seeded)
        }
        mutableStateOf(seeded)
    }
    var events by remember(missionId) {
        mutableStateOf(if (missionId != null) OrbReadCache.readMemoryRows(eventsCacheKey) else emptyList())
    }
    // Streamed reply: deltas coalesce to one state change per frame (OrbStreamText.kt).
    val live = remember(missionId) { OrbLiveText(scope) }
    // False until the first history fetch for this mission settles, so an existing
    // conversation shows a loading row instead of the "Start a conversation" empty state.
    val fastReopen = remember(missionId) {
        missionId != null && OrbWarmSyncCoordinator.canSkipFullRefreshOnReopen(core, missionId)
    }
    var historySettled by remember(missionId) {
        mutableStateOf(missionId == null || fastReopen)
    }
    var dismissedQuestionId by remember(missionId) { mutableStateOf<String?>(null) }

    var inputText by remember { mutableStateOf("") }
    val composerDraftStore = remember { OrbComposerDraftStore(initialMission?.id) }
    var adoptedNewMissionId by remember { mutableStateOf<String?>(null) }
    if (composerDraftStore.activeMissionId != missionId) {
        inputText = composerDraftStore.syncMission(
            nextMissionId = missionId,
            currentInput = inputText,
            adoptedNewMissionId = adoptedNewMissionId,
        )
        if (adoptedNewMissionId == missionId) {
            adoptedNewMissionId = null
        }
    }
    var composeMode by remember { mutableStateOf(OrbComposeMode.Message) }
    var showModePicker by remember { mutableStateOf(false) }
    // Core's durable follow-up queue merged with optimistic sends/edits (OrbSendFlow.kt).
    var followUps by remember(missionId) { mutableStateOf(OrbFollowUpQueue()) }
    var showQueuedDrawer by remember { mutableStateOf(true) }
    /** Queued follow-up being edited in the composer (edit in place on send). */
    var editingQueuedId by remember(missionId) { mutableStateOf<String?>(null) }
    /** Send now in flight: one continuous Sending… → Working… state, Stop kept. */
    var handoff by remember(missionId) { mutableStateOf<OrbHandoff?>(null) }
    val handoffTracker = remember(missionId) { OrbHandoffTracker() }
    val reducedMotion = orbReducedMotion()
    val pendingAttachments = remember { mutableStateListOf<OrbPendingAttachment>() }

    var isSending by remember { mutableStateOf(false) }
    var isStopping by remember { mutableStateOf(false) }
    var isForcingSlot by remember(missionId) { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var previewFilePath by remember { mutableStateOf<String?>(null) }
    // Shared files: chip previews, the Files tab, and shared_files metadata (size, url).
    var fileRef by remember { mutableStateOf<OrbFileRef?>(null) }
    var showFiles by remember { mutableStateOf(false) }
    var sharedFiles by remember(missionId) { mutableStateOf<List<OrbSharedFile>>(emptyList()) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showAttachMenu by remember { mutableStateOf(false) }
    var showHeaderMenu by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf("") }
    var sideAgentSession by remember(initialMission?.id) { mutableStateOf<OrbSideAgentSession?>(null) }
    var commandBanner by remember { mutableStateOf<String?>(null) }

    var userExplicitlyPickedAgent by remember(currentMission?.id) { mutableStateOf(false) }
    var cloudAccounts by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    // Agent configuration state
    var selectedBackend by remember(currentMission?.id, backends) {
        mutableStateOf(
            currentMission?.str("backend", "harness", "backend_id")?.removePrefix("cloud_")
                ?: backends.firstOrNull()?.str("id", "name")
                ?: "claudecode"
        )
    }
    var selectedModel by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("model_override", "model", "model_id") ?: "")
    }
    var selectedCyber by remember(currentMission?.id) { mutableStateOf(OrbCyberMode.Automatic) }
    var cyberSelection by remember(currentMission?.id) { mutableStateOf<OrbCyberSelection?>(null) }
    var cyberLoading by remember(currentMission?.id) { mutableStateOf(currentMission != null) }
    LaunchedEffect(currentMission?.id, showAgentPicker, currentMission?.str("status")) {
        val id = currentMission?.id ?: return@LaunchedEffect
        if (!OrbCyberAccess.nativeCodex(currentMission?.str("backend"), currentMission?.dict("cloud"))) {
            cyberLoading = false
            return@LaunchedEffect
        }
        cyberLoading = true
        try {
            val value = OrbJSON.dict(core.request("/api/control/missions/${core.encodeComponent(id)}/cyber"))
                ?: throw OrbError("Cyber settings unavailable")
            cyberSelection = OrbCyberSelection.parse(value)
            selectedCyber = cyberSelection!!.mode
        } catch (e: Exception) {
            errorMessage = OrbCyberAccess.error(e)
        } finally { cyberLoading = false }
    }
    var selectedWorkspaceId by remember(currentMission?.id, project.id) {
        mutableStateOf(
            currentMission?.str("workspace_id", "workspaceId")
                ?: project.str("workspace_id", "default_workspace_id")
                ?: ""
        )
    }
    var selectedNodeId by remember(currentMission?.id, project.id) {
        mutableStateOf(
            currentMission?.str("remote_node_id")
                ?: project.str("remote_node_id")
                ?: ""
        )
    }
    var nodePinnedByUser by remember(currentMission?.id, project.id) {
        mutableStateOf(
            !currentMission?.str("remote_node_id").isNullOrEmpty() ||
                !project.str("remote_node_id").isNullOrEmpty()
        )
    }
    var allow24hCommitment by remember(currentMission?.id) { mutableStateOf(false) }
    var managedCatalog by remember { mutableStateOf<ManagedMachinesResponse?>(null) }
    LaunchedEffect(showAgentPicker, currentMission?.id) {
        if (currentMission == null && (showAgentPicker || managedCatalog == null)) {
            val raw = orbTry(OrbLog.Category.Network, OrbManagedMachines.PATH) {
                core.fetchDict(OrbManagedMachines.PATH)
            }.getOrNull()
            if (raw != null) {
                managedCatalog = OrbManagedMachines.parse(raw)
            }
        }
    }
    LaunchedEffect(currentMission?.id, nodes, selectedBackend, selectedModel, selectedWorkspaceId, nodePinnedByUser) {
        val isCloudService = selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes")
        if (currentMission == null && !isCloudService && selectedWorkspaceId.isEmpty() && !nodePinnedByUser) {
            selectedNodeId = if (selectedBackend == "opencode" && selectedModel.isBlank()) {
                "core"
            } else {
                OrbComputePlacement.firstAvailableNodeId(nodes, backend = selectedBackend) ?: "core"
            }
        }
    }
    val fileScope = remember(missionId, selectedWorkspaceId) { OrbFileScope(missionId, selectedWorkspaceId.takeIf { it.isNotEmpty() }) }
    var selectedAccount by remember(currentMission?.id) {
        mutableStateOf(currentMission?.str("account_id", "account", "provider_account") ?: "")
    }
    LaunchedEffect(currentMission?.id, initialFolder, selectedWorkspaceId, nodePinnedByUser, backends.size, userExplicitlyPickedAgent) {
        if (currentMission != null) return@LaunchedEffect
        val loaded = if (cloudAccounts.isNotEmpty()) {
            cloudAccounts
        } else {
            runCatching { core.fetchRows("/api/cloud/accounts", "items") }.getOrDefault(emptyList()).also {
                if (it.isNotEmpty()) cloudAccounts = it
            }
        }
        val hermesAccount = loaded.firstOrNull {
            it.str("provider") == "hermes" && it.bool("available") == true && !it.str("id").isNullOrEmpty()
        }
        val step = OrbKernel.composerDefaultStep(
            hasExplicitChoice = userExplicitlyPickedAgent,
            hasPinnedContext = !initialFolder.isNullOrEmpty() || nodePinnedByUser || selectedWorkspaceId.isNotEmpty(),
            hermesAvailable = hermesAccount != null,
            hasNativeHarness = backends.isNotEmpty()
        )
        if (step == OrbKernel.ComposerDefaultStepResult.DEFAULT_PALOMA_HERMES && hermesAccount != null) {
            selectedBackend = "hermes"
            selectedAccount = hermesAccount.str("id").orEmpty()
        }
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
    var settingsSaveJob by remember(missionId) { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var settingsSaveGeneration by remember(missionId) { mutableStateOf(0) }
    var settingsSyncedGeneration by remember(missionId) { mutableStateOf(0) }
    var settingsRemoteRevision by remember(missionId) { mutableStateOf(0) }
    var confirmedSettingsModel by remember(missionId) { mutableStateOf<String?>(null) }

    fun mergeConfirmedSettingsInto(current: OrbRow?, resp: Map<String, Any?>, targetId: String, keepOptimisticModel: Boolean = false): OrbRow {
        if (current == null || current.id != targetId) return OrbRow(targetId, resp)
        val merged = current.raw.toMutableMap()
        if ((merged["history"] as? List<*>)?.isEmpty() != false) {
            (resp["history"] as? List<*>)?.takeIf { it.isNotEmpty() }?.let { merged["history"] = it }
        }
        val settingsKeys = listOf("backend", "agent", "model_override", "model_effort", "fast_mode", "service_tier", "config_profile", "session_id")
        if (!keepOptimisticModel) {
            for (k in settingsKeys) {
                if (resp.containsKey(k)) merged[k] = resp[k]
            }
        }
        val curEpoch = OrbJSON.dateEpochMs(OrbJSON.str(merged, "updated_at"))
        val nextEpoch = OrbJSON.dateEpochMs(OrbJSON.str(resp, "updated_at"))
        if (nextEpoch != null && (curEpoch == null || nextEpoch >= curEpoch)) {
            merged["updated_at"] = resp["updated_at"]
        }
        return OrbRow(targetId, merged)
    }

    fun persistMissionModelIfNeeded(targetId: String) {
        val row = currentMission ?: return
        val storedBackend = row.str("backend", "harness", "backend_id").orEmpty()
        if (row.id != targetId || storedBackend.startsWith("cloud_")) return
        if (storedBackend.isNotEmpty() && selectedBackend != storedBackend) return
        val currentModel = row.str("model_override") ?: ""
        if ((settingsSaveJob == null && settingsSyncedGeneration == settingsSaveGeneration) || confirmedSettingsModel == null) {
            confirmedSettingsModel = currentModel
        }
        val nextModel = selectedModel.trim()
        if (nextModel == currentModel) return
        val updatedRaw = row.raw + ("model_override" to nextModel.ifEmpty { null })
        currentMission = OrbRow(targetId, updatedRaw)
        val gen = settingsSaveGeneration + 1
        settingsSaveGeneration = gen
        val prior = settingsSaveJob
        val job = scope.launch {
            prior?.join()
            try {
                val resp = OrbJSON.dict(
                    core.request(
                        path = "/api/control/missions/${core.encodeComponent(targetId)}/settings",
                        method = "PATCH",
                        body = mapOf("model_override" to nextModel, "resume" to false)
                    )
                )
                if (resp != null && currentMission?.id == targetId) {
                    confirmedSettingsModel = OrbJSON.str(resp, "model_override") ?: ""
                    val confirmedRow = mergeConfirmedSettingsInto(currentMission, resp, targetId, keepOptimisticModel = false)
                    core.upsertMissionInMemory(confirmedRow)
                    currentMission = mergeConfirmedSettingsInto(currentMission, resp, targetId, keepOptimisticModel = settingsSaveGeneration != gen)
                }
                core.refreshMissionsQuietly()
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                if (currentMission?.id == targetId) {
                    if (settingsSaveGeneration == gen) {
                        val fallbackModel = confirmedSettingsModel ?: currentModel
                        selectedModel = fallbackModel
                        val latestRaw = currentMission?.raw ?: row.raw
                        val revertedRow = OrbRow(targetId, latestRaw + ("model_override" to fallbackModel.ifEmpty { null }))
                        currentMission = revertedRow
                        core.upsertMissionInMemory(revertedRow)
                    }
                    errorMessage = e.message ?: "Could not update model."
                }
            } finally {
                if (gen > settingsSyncedGeneration) settingsSyncedGeneration = gen
                if (settingsSaveGeneration == gen) {
                    settingsSaveJob = null
                    confirmedSettingsModel = null
                }
            }
        }
        settingsSaveJob = job
    }

    val liveRow = remember(allMissions, missionId, currentMission) {
        if (missionId == null) null
        else allMissions.firstOrNull { it.id == missionId } ?: currentMission
    }
    val slotWait = remember(liveRow) { orbSlotWaitInfo(liveRow) }
    val isCloudMission = remember(liveRow) {
        liveRow?.str("backend", "harness", "backend_id")?.startsWith("cloud_") == true ||
            !OrbJSON.str(liveRow?.dict("cloud"), "provider").isNullOrEmpty()
    }
    val isCloudComposer = isCloudMission || selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes") || selectedBackend.startsWith("cloud_")
    val effectiveProjectSlug = remember(currentMission, project) {
        currentMission?.str("project")?.takeIf { it.isNotEmpty() } ?: project.str("slug", "id") ?: project.id
    }
    var skillItems by remember(effectiveProjectSlug, selectedWorkspaceId) { mutableStateOf<List<OrbSkillChoice>>(emptyList()) }
    var skillCatalogError by remember(effectiveProjectSlug, selectedWorkspaceId) { mutableStateOf<String?>(null) }
    var skillCatalogLoaded by remember(effectiveProjectSlug, selectedWorkspaceId) { mutableStateOf(false) }
    suspend fun ensureSkillCatalog() {
        if (isCloudComposer) {
            skillItems = emptyList()
            skillCatalogError = null
            skillCatalogLoaded = true
            return
        }
        val (loaded, err) = OrbSkillSlash.loadDelivery(core, effectiveProjectSlug, selectedWorkspaceId.takeIf { it.isNotEmpty() })
        skillItems = loaded
        skillCatalogError = err
        skillCatalogLoaded = true
    }
    LaunchedEffect(effectiveProjectSlug, selectedWorkspaceId, isCloudComposer) {
        ensureSkillCatalog()
    }
    val availableSkillNames = remember(skillItems) { skillItems.mapTo(LinkedHashSet()) { it.name } }
    val selectedSkillNames = remember(inputText, availableSkillNames, isCloudComposer) {
        if (isCloudComposer) emptyList() else OrbSkillSlash.selectedSkillNames(inputText, availableSkillNames)
    }
    suspend fun validateComposerSkills(content: String): String? {
        if (isCloudComposer || OrbSkillSlash.skillTokens(content).isEmpty()) return null
        if (!skillCatalogLoaded || (skillItems.isEmpty() && skillCatalogError != null)) ensureSkillCatalog()
        skillCatalogError?.let { return "$it. Your draft is kept." }
        val harness = currentMission?.str("backend", "harness", "backend_id") ?: selectedBackend
        return OrbSkillSlash.validateSkillSelection(content, harness, skillItems.mapTo(LinkedHashSet()) { it.name })
            ?.let { "$it. Your draft is kept." }
    }
    val canForceSlot = missionId != null && !isCloudMission && slotWait?.canForce == true

    val handoffActive = OrbHandoff.pending(liveRow?.str("status", "state"), handoff, System.currentTimeMillis())
    val isLive = remember(liveRow, isSending, handoffActive) {
        isSending || handoffActive || (liveRow != null && OrbMissionTree.isLive(liveRow))
    }

    // End the handoff once the new turn runs (or a failure shows), and after the 30 s fallback.
    LaunchedEffect(liveRow, handoff) {
        val h = handoff ?: run { handoffTracker.reset(); return@LaunchedEffect }
        val job = liveRow?.dict("remote_job")
        val jobEnded = job != null && (OrbJSON.str(job, "finished_at") != null || OrbJSON.str(job, "terminal_reason") != null)
        if (handoffTracker.observe(h, liveRow?.str("status", "state"), job?.let { OrbJSON.str(it, "job_id") }, jobEnded)) {
            handoff = null
        }
    }
    LaunchedEffect(handoff) {
        val h = handoff ?: return@LaunchedEffect
        delay(OrbHandoff.TIMEOUT_MS + 50)
        if (handoff == h) handoff = null
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

    val historyLoadMutex = remember(missionId) { kotlinx.coroutines.sync.Mutex() }
    var coalescedEventRefreshJob by remember(missionId) { mutableStateOf<kotlinx.coroutines.Job?>(null) }

    fun mergeMissionEvents(existing: List<OrbRow>, incoming: List<OrbRow>): List<OrbRow> {
        if (incoming.isEmpty()) return existing
        val byKey = LinkedHashMap<Any, OrbRow>(existing.size + incoming.size)
        for (row in existing + incoming) {
            val key: Any = row.int("sequence", "seq") ?: row.id
            byKey[key] = row
        }
        var sorted = byKey.values.sortedWith(compareBy { it.int("sequence", "seq") ?: Int.MAX_VALUE })
        val latestDeltaSeq = sorted.lastOrNull { ev ->
            val t = (ev.str("event_type", "type") ?: "").lowercase()
            val eid = ev.str("event_id")
            t == "text_delta" && (eid == null || eid == "text_delta_latest")
        }?.int("sequence", "seq")
        if (latestDeltaSeq != null) {
            sorted = sorted.filterNot { ev ->
                val t = (ev.str("event_type", "type") ?: "").lowercase()
                val eid = ev.str("event_id")
                val seq = ev.int("sequence", "seq") ?: Int.MAX_VALUE
                t == "text_delta" && (eid == null || eid == "text_delta_latest") && seq < latestDeltaSeq
            }
        }
        if (sorted.size > 600) {
            val tailStartSeq = sorted[sorted.size - 400].int("sequence", "seq") ?: 0
            val lastUserSeq = sorted.lastOrNull { ev ->
                (ev.str("event_type", "type") ?: "").lowercase() == "user_message" && OrbJSON.bool(ev.dict("metadata"), "queued") != true
            }?.int("sequence", "seq") ?: 0
            sorted = sorted.filter { ev ->
                val seq = ev.int("sequence", "seq") ?: Int.MAX_VALUE
                val t = (ev.str("event_type", "type") ?: "").lowercase()
                val tool = (ev.str("tool_name", "name", "tool") ?: "").lowercase()
                seq >= tailStartSeq || (seq >= lastUserSeq && (t == "user_message" || tool in setOf("todowrite", "todo_write", "update_plan")))
            }
        }
        return sorted
    }

    fun targetMissionEvents(evs: List<OrbRow>, targetId: String): List<OrbRow> =
        if (evs.any { !it.str("mission_id").isNullOrEmpty() }) {
            OrbConversationHistory.forMission(evs, targetId)
        } else {
            evs
        }

    fun lastMissionSequence(evs: List<OrbRow>, targetId: String): Long? {
        val target = targetMissionEvents(evs, targetId)
        return target.mapNotNull { row ->
            (row.raw["sequence"] as? Number)?.toLong()
                ?: (row.raw["seq"] as? Number)?.toLong()
                ?: row.int("sequence", "seq")?.toLong()
        }.maxOrNull()
    }

    fun deliveredMessagesFrom(messages: List<OrbRow>, events: List<OrbRow>, targetId: String): List<OrbDeliveredMessage> {
        val combined = mergeMissionEvents(
            targetMissionEvents(messages, targetId),
            targetMissionEvents(events, targetId)
        )
        return combined.mapNotNull { ev ->
            if ((ev.str("event_type", "type") ?: "").lowercase() != "user_message") return@mapNotNull null
            val data = ev.dict("data") ?: ev.raw
            val meta = ev.dict("metadata") ?: OrbJSON.dict(data["metadata"]) ?: emptyMap()
            if (OrbJSON.bool(meta, "queued") == true || OrbJSON.bool(data, "queued") == true) return@mapNotNull null
            val seq = (ev.raw["sequence"] as? Number)?.toLong()
                ?: (ev.raw["seq"] as? Number)?.toLong()
                ?: ev.int("sequence", "seq")?.toLong()
                ?: return@mapNotNull null
            val cid = listOf("client_message_id", "message_id", "event_id").firstNotNullOfOrNull { key ->
                (OrbJSON.str(meta, key) ?: OrbJSON.str(data, key) ?: ev.str(key))?.takeIf { it.isNotEmpty() }
            }
            val content = (ev.raw["content"] as? String)
                ?: OrbJSON.str(data, "content", "text", "message")
                ?: ev.str("content", "text", "message")
                ?: ""
            OrbDeliveredMessage(id = cid, content = content, sequence = seq)
        }
    }

    suspend fun loadHistory(targetId: String) = historyLoadMutex.withLock {
        val account = OrbDisk.currentScope()
        val streamEpochBefore = live.streamEpoch
        val settingsGenBefore = settingsSaveGeneration
        val settingsRemoteRevBefore = settingsRemoteRevision
        var anyFetchOk = false
        var latestDetailForTarget: OrbRow? = null
        try {
            val idsToLoad = if (chainIds.size > 1) chainIds.takeLast(3) else listOf(targetId)
            val allMsgs = mutableListOf<OrbRow>()
            val allEvs = mutableListOf<OrbRow>()

            kotlinx.coroutines.coroutineScope {
                val jobs = idsToLoad.map { cid ->
                    async(Dispatchers.IO) {
                        val existingForCid = OrbConversationHistory.forMission(if (cid == targetId) events else OrbReadCache.loadRowsAsync("mission_events_$cid"), cid)
                        val lastSeq = existingForCid.lastOrNull()?.int("sequence", "seq")
                        val detailDef = async {
                            orbTry(OrbLog.Category.Network, "/api/control/missions") { core.fetchDict("/api/control/missions/${core.encodeComponent(cid)}?include_history=false") }.getOrNull()
                        }
                        val maxPayload = OrbReadCache.RESULT_KEEP_CHARS
                        val evPath = if (lastSeq != null && lastSeq > 0) {
                            "/api/control/missions/${core.encodeComponent(cid)}/events?limit=150&since_seq=$lastSeq&max_payload=$maxPayload"
                        } else {
                            "/api/control/missions/${core.encodeComponent(cid)}/events?limit=150&max_payload=$maxPayload"
                        }
                        val eventsDef = async {
                            orbTry(OrbLog.Category.Network, "core.fetchRows") { core.fetchRows(evPath, "events") }.getOrDefault(emptyList())
                        }
                        val savedHistory = OrbConversationHistory.forMission(OrbReadCache.loadRowsAsync("mission_msgs_$cid"), cid)
                        val conversationCursor = savedHistory.takeIf { it.isNotEmpty() && it.all { row -> row.int("sequence") != null } }?.maxOf { it.int("sequence")!! }
                        val conversationSuffix = conversationCursor?.let { "&since_seq=$it" } ?: ""
                        val conversationDef = async {
                            orbTry(OrbLog.Category.Network, "conversation messages") {
                                core.fetchRows("/api/control/missions/${core.encodeComponent(cid)}/events?types=user_message,assistant_message,assistant_message_canonical&limit=400&max_payload=$maxPayload$conversationSuffix", "events")
                            }.getOrNull()
                        }
                        val detail = detailDef.await()
                        if (detail != null) anyFetchOk = true
                        val conversation = conversationDef.await()
                        if (conversation != null) anyFetchOk = true
                        if (account != OrbDisk.currentScope()) throw kotlinx.coroutines.CancellationException()
                        val isCloudCid = (detail?.get("backend") as? String)?.startsWith("cloud_") == true ||
                            allMissions.firstOrNull { it.id == cid }?.str("backend")?.startsWith("cloud_") == true
                        val cloudExec = if (isCloudCid) {
                            orbTry(OrbLog.Category.Network, "/api/control/missions/cloud") {
                                core.fetchDict("/api/control/missions/${core.encodeComponent(cid)}/cloud")
                            }.getOrNull()?.also { anyFetchOk = true }
                        } else null
                        val cloudHistRows = if (cloudExec != null) {
                            OrbJSON.dictList(cloudExec["turns"]).flatMapIndexed { idx, turn ->
                                val key = OrbJSON.str(turn, "key") ?: "turn-$idx"
                                val prompt = OrbJSON.str(turn, "prompt")?.trim().orEmpty()
                                val result = OrbJSON.str(turn, "result")?.trim().orEmpty()
                                val detailErr = OrbJSON.str(turn, "detail")?.trim().orEmpty()
                                val phase = OrbJSON.str(turn, "phase").orEmpty()
                                buildList {
                                    if (prompt.isNotEmpty()) {
                                        add(OrbRow("$cid:$key:user", mapOf("role" to "user", "content" to prompt, "mission_id" to cid)))
                                    }
                                    val assistantBody = result.ifEmpty { if (phase == "failed" && detailErr.isNotEmpty()) detailErr else "" }
                                    if (assistantBody.isNotEmpty()) {
                                        add(OrbRow("$cid:$key:assistant", mapOf("role" to "assistant", "content" to assistantBody, "mission_id" to cid)))
                                    }
                                }
                            }
                        } else emptyList()
                        val histRows = if (cloudHistRows.isNotEmpty()) {
                            cloudHistRows
                        } else if (!conversation.isNullOrEmpty()) {
                            OrbConversationHistory.merge(if (conversationCursor == null) emptyList() else savedHistory, conversation)
                        } else if (conversationCursor != null) {
                            savedHistory
                        } else if (detail != null) {
                            OrbRow(cid, detail).rows("history")
                        } else {
                            allMissions.firstOrNull { it.id == cid }?.rows("history") ?: emptyList()
                        }
                        val collectedEvs = eventsDef.await().toMutableList()
                        if (lastSeq != null && lastSeq > 0 && collectedEvs.size >= 150) {
                            var cursor = collectedEvs.lastOrNull()?.int("sequence", "seq") ?: lastSeq
                            var fullPage = true
                            for (page in 0 until 2) {
                                val more = orbTry(OrbLog.Category.Network, "core.fetchRows") {
                                    core.fetchRows("/api/control/missions/${core.encodeComponent(cid)}/events?limit=150&since_seq=$cursor&max_payload=$maxPayload", "events")
                                }.getOrDefault(emptyList())
                                if (more.isEmpty()) {
                                    fullPage = false
                                    break
                                }
                                collectedEvs.addAll(more)
                                cursor = more.lastOrNull()?.int("sequence", "seq") ?: cursor
                                if (more.size < 150) {
                                    fullPage = false
                                    break
                                }
                            }
                            if (fullPage) {
                                val tail = orbTry(OrbLog.Category.Network, "core.fetchRows") {
                                    core.fetchRows("/api/control/missions/${core.encodeComponent(cid)}/events?limit=200&max_payload=$maxPayload", "events")
                                }.getOrDefault(emptyList())
                                if (tail.isNotEmpty()) collectedEvs.addAll(tail)
                            }
                        }
                        var mergedEvs = if (lastSeq != null && lastSeq > 0 && existingForCid.isNotEmpty()) {
                            mergeMissionEvents(existingForCid, collectedEvs)
                        } else if (collectedEvs.isNotEmpty()) {
                            mergeMissionEvents(emptyList(), collectedEvs)
                        } else {
                            existingForCid
                        }
                        val firstSeq = mergedEvs.firstOrNull()?.int("sequence", "seq") ?: 0
                        val hasDeliveredUser = mergedEvs.any { ev ->
                            (ev.str("event_type", "type") ?: "").lowercase() == "user_message" &&
                                OrbJSON.bool(ev.dict("metadata"), "queued") != true
                        }
                        if (!isCloudCid && firstSeq > 1 && !hasDeliveredUser) {
                            val usersDef = async {
                                orbTry(OrbLog.Category.Network, "turn start user") {
                                    core.fetchRows("/api/control/missions/${core.encodeComponent(cid)}/events?types=user_message&limit=5&before_seq=$firstSeq&max_payload=$maxPayload", "events")
                                }.getOrDefault(emptyList())
                            }
                            val toolsDef = async {
                                orbTry(OrbLog.Category.Network, "turn start tools") {
                                    core.fetchRows("/api/control/missions/${core.encodeComponent(cid)}/events?types=tool_call&limit=400&before_seq=$firstSeq&max_payload=$maxPayload", "events")
                                }.getOrDefault(emptyList())
                            }
                            val startUser = usersDef.await().lastOrNull { ev ->
                                (ev.str("event_type", "type") ?: "").lowercase() == "user_message" &&
                                    OrbJSON.bool(ev.dict("metadata"), "queued") != true
                            }
                            val startSeq = startUser?.int("sequence", "seq") ?: 0
                            val keep = buildList {
                                if (startUser != null) add(startUser)
                                for (tc in toolsDef.await()) {
                                    val seq = tc.int("sequence", "seq") ?: 0
                                    val toolName = (tc.str("tool_name", "name", "tool") ?: "").lowercase()
                                    if (seq >= startSeq && (toolName.contains("todowrite") || toolName.contains("todo_write") || toolName == "update_plan" || toolName == "todos")) {
                                        add(tc)
                                    }
                                }
                            }
                            if (keep.isNotEmpty()) {
                                mergedEvs = mergeMissionEvents(keep, mergedEvs)
                            }
                        }
                        if (cid == targetId && detail != null) {
                            withContext(Dispatchers.Main) {
                                val fetchedEpoch = OrbJSON.dateEpochMs(OrbJSON.str(detail, "updated_at"))
                                val currentEpoch = OrbJSON.dateEpochMs(currentMission?.str("updated_at"))
                                val pendingLocal = settingsSaveGeneration != settingsGenBefore || settingsSaveJob != null
                                val confirmedRemoteStale = settingsRemoteRevision != settingsRemoteRevBefore ||
                                    (!pendingLocal && fetchedEpoch != null && currentEpoch != null && fetchedEpoch < currentEpoch)
                                val settingsChangedDuringLoad = pendingLocal || confirmedRemoteStale
                                val mergedDetail = if (settingsChangedDuringLoad && currentMission?.id == cid) {
                                    val cur = currentMission!!.raw
                                    detail + mapOf(
                                        "backend" to cur["backend"],
                                        "model_override" to cur["model_override"],
                                        "updated_at" to (cur["updated_at"] ?: detail["updated_at"])
                                    )
                                } else {
                                    detail
                                }
                                val updatedRow = OrbRow(cid, mergedDetail)
                                latestDetailForTarget = updatedRow
                                currentMission = updatedRow
                                if ((confirmedRemoteStale || pendingLocal) && settingsSaveJob == null) {
                                    core.upsertMissionInMemory(updatedRow)
                                }
                                if (!showAgentPicker && !settingsChangedDuringLoad && updatedRow.str("backend")?.startsWith("cloud_") != true) {
                                    val rowBackend = updatedRow.str("backend", "harness", "backend_id").orEmpty()
                                    if (rowBackend.isEmpty() || selectedBackend == rowBackend) {
                                        selectedModel = updatedRow.str("model_override", "model", "model_id") ?: ""
                                    }
                                }
                            }
                        }
                        Triple(cid, histRows, mergedEvs)
                    }
                }
                for (job in jobs) {
                    val (cid, hRows, eRows) = job.await()
                    if (account != OrbDisk.currentScope()) throw kotlinx.coroutines.CancellationException()
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
                events = OrbReadCache.compactEvents(allEvs)
                OrbReadCache.saveRows(eventsCacheKey, events)
            }
            val effectiveMission = latestDetailForTarget ?: liveRow
            val effectiveWorking = isSending || handoffActive || (effectiveMission != null && OrbMissionTree.isLive(effectiveMission))
            val targetEvents = OrbConversationHistory.forMission(events, targetId).ifEmpty { events }
            if (targetId == missionId) followUps = followUps.reconciled(deliveredMessagesFrom(messages, events, targetId))
            live.reconcileStored(targetEvents, working = effectiveWorking, streamAdvanced = live.streamEpoch != streamEpochBefore)
            OrbWarmSyncCoordinator.markMissionSynced(core, targetId, targetEvents.lastOrNull()?.int("sequence", "seq")?.toLong())
            liveRow?.let { OrbMissionUnreadStore.markSeen(it) }
        } catch (t: Throwable) {
            if (t is kotlinx.coroutines.CancellationException) throw t
            OrbLog.w(OrbLog.Category.Network, "conversation history load failed", t)
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

    fun scheduleCoalescedHistoryRefresh(targetId: String) {
        if (coalescedEventRefreshJob?.isActive == true) return
        coalescedEventRefreshJob = scope.launch(Dispatchers.Main) {
            delay(450L)
            coalescedEventRefreshJob = null
            if (targetId == missionId) loadHistory(targetId)
        }
    }

    suspend fun refreshFollowUps(id: String) {
        val fetchedAtMs = System.currentTimeMillis()
        val lastSequence = maxOf(
            lastMissionSequence(events, id) ?: Long.MIN_VALUE,
            lastMissionSequence(messages, id) ?: Long.MIN_VALUE
        ).takeIf { it != Long.MIN_VALUE }
        val rows = orbTry(OrbLog.Category.Network, "/api/control/queue") {
            OrbJSON.dictList(core.request("/api/control/queue?mission_id=${core.encodeComponent(id)}"))
        }.getOrNull()
        if (id != missionId) return
        if (rows != null) {
            followUps = followUps.withServer(OrbFollowUpQueue.parse(rows, id), fetchedAtMs = fetchedAtMs, lastSequence = lastSequence)
        }
        followUps = followUps.reconciled(deliveredMessagesFrom(messages, events, id))
    }

    var streamConnected by remember(missionId) { mutableStateOf(false) }

    DisposableEffect(missionId) {
        val id = missionId
        if (!id.isNullOrEmpty()) {
            OrbWarmSyncCoordinator.noteOpened(core, id)
        }
        onDispose {
            if (!id.isNullOrEmpty()) {
                OrbWarmSyncCoordinator.noteClosed(core, id)
            }
        }
    }

    // Live multiplexed WS / SSE stream via OrbWarmSyncCoordinator (applies live events directly in memory)
    LaunchedEffect(missionId, lifecycleOwner) {
        val id = missionId ?: return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val sinceSeq = events.lastOrNull()?.int("sequence", "seq")?.toLong()
            val token = OrbWarmSyncCoordinator.attachMissionListener(
                core = core,
                missionId = id,
                sinceSeq = sinceSeq
            ) { evType, parsed, storedRow ->
                if (id != missionId) return@attachMissionListener
                streamConnected = evType != "disconnected"
                when {
                    evType == "sync_caught_up" -> {
                        streamConnected = true
                    }
                    evType == "text_delta" || evType == "delta" -> {
                        live.applyTextDelta(parsed)
                    }
                    evType == "text_op" -> {
                        live.applyTextOp(parsed)
                    }
                    storedRow != null -> {
                        val epochBefore = live.streamEpoch
                        if (evType == "user_message" && OrbJSON.bool(parsed, "queued") != true) {
                            live.resetTurn()
                        }
                        events = mergeMissionEvents(events, listOf(storedRow))
                        val sType = storedRow.str("event_type", "type") ?: ""
                        if (sType in OrbConversationHistory.eventTypes) {
                            messages = OrbConversationHistory.merge(messages, listOf(storedRow))
                        }
                        val targetEvents = OrbConversationHistory.forMission(events, id).ifEmpty { events }
                        followUps = followUps.reconciled(deliveredMessagesFrom(messages, events, id))
                        live.reconcileStored(targetEvents, working = isLive, streamAdvanced = live.streamEpoch != epochBefore)
                    }
                    evType == "mission_settings_updated" -> {
                        val pendingLocalSettings = settingsSaveJob != null || settingsSyncedGeneration < settingsSaveGeneration
                        val cur = currentMission ?: liveRow
                        if (!pendingLocalSettings && cur != null) {
                            val updatedMap = cur.raw.toMutableMap()
                            OrbJSON.str(parsed, "backend")?.takeIf { it.isNotEmpty() }?.let { updatedMap["backend"] = it }
                            if (parsed?.containsKey("model_override") == true) {
                                updatedMap["model_override"] = OrbJSON.str(parsed, "model_override")
                            }
                            OrbJSON.str(parsed, "updated_at")?.let { updatedMap["updated_at"] = it }
                            val updatedRow = OrbRow(id, updatedMap)
                            settingsRemoteRevision += 1
                            currentMission = updatedRow
                            core.upsertMissionInMemory(updatedRow)
                            if (!showAgentPicker && updatedRow.str("backend")?.startsWith("cloud_") != true) {
                                val rowBackend = updatedRow.str("backend", "harness", "backend_id").orEmpty()
                                if (rowBackend.isEmpty() || selectedBackend == rowBackend) {
                                    selectedModel = updatedRow.str("model_override") ?: ""
                                }
                            }
                        }
                    }
                    evType in setOf("mission_status_changed", "mission_completed", "turn_complete") -> {
                        val newStatus = OrbJSON.str(parsed, "status")
                        if (!newStatus.isNullOrEmpty()) {
                            val cur = currentMission ?: liveRow
                            if (cur != null) {
                                currentMission = OrbRow(id, cur.raw + ("status" to newStatus))
                            }
                        }
                        scope.launch(Dispatchers.Main) {
                            loadHistory(id)
                            core.refreshMissionsQuietly()
                        }
                    }
                    evType == "stream_lagged" || evType == "disconnected" -> {
                        scope.launch(Dispatchers.Main) { loadHistory(id) }
                    }
                    evType in setOf("user_message", "assistant_message", "assistant_message_canonical", "tool_call", "tool_result", "thinking") -> {
                        if (evType == "user_message" && OrbJSON.bool(parsed, "queued") == true) {
                            scope.launch(Dispatchers.Main) { refreshFollowUps(id) }
                        } else {
                            if (evType == "user_message") {
                                live.resetTurn()
                                OrbJSON.str(parsed, "id")?.takeIf { it.isNotEmpty() }?.let { cid ->
                                    followUps = followUps.withDelivered(setOf(cid))
                                }
                            }
                            scheduleCoalescedHistoryRefresh(id)
                        }
                    }
                }
            }
            streamConnected = true
            try {
                kotlinx.coroutines.awaitCancellation()
            } finally {
                streamConnected = false
                OrbWarmSyncCoordinator.detachMissionListener(core, id, token)
            }
        }
    }

    LaunchedEffect(isLive, historySettled) {
        if (!isLive && historySettled) live.clear()
    }

    LaunchedEffect(missionId, lifecycleOwner) {
        val id = missionId ?: return@LaunchedEffect
        val (cachedMessages, cachedEvents) = coroutineScope {
            val msgsTask = async { OrbReadCache.loadRowsAsync(messagesCacheKey) }
            val evsTask = async { OrbReadCache.loadRowsAsync(eventsCacheKey) }
            msgsTask.await() to evsTask.await()
        }
        if (id != missionId) return@LaunchedEffect
        // An SSE response or optimistic send may have populated these during the read.
        if (messages.isEmpty() && cachedMessages.isNotEmpty()) messages = cachedMessages
        if (events.isEmpty() && cachedEvents.isNotEmpty()) {
            events = cachedEvents
            val targetEvents = OrbConversationHistory.forMission(cachedEvents, id).ifEmpty { cachedEvents }
            live.reconcileStored(targetEvents, working = isLive, streamAdvanced = false)
        }
        OrbPresentation.remember(id)
        if (messages.isEmpty()) {
            val preview = OrbReadCache.loadRowsAsync("presentation_$id").ifEmpty {
                try { OrbPresentation.load(id, core) } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    emptyList()
                }
            }
            if (messages.isEmpty()) messages = preview
        }
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val canSkipInitial = !isCloudMission && chainIds.size <= 1 &&
                (fastReopen || OrbWarmSyncCoordinator.canSkipFullRefreshOnReopen(core, id))
            if (canSkipInitial && (messages.isNotEmpty() || events.isNotEmpty())) {
                historySettled = true
                liveRow?.let { OrbMissionUnreadStore.markSeen(it) }
            } else {
                loadHistory(id)
            }
            while (isActive) {
                val intervalMs = when {
                    isLive && streamConnected && core.isMultiplexSyncHealthy -> 30_000L
                    isLive && streamConnected -> 12_000L
                    isLive -> 3_500L
                    streamConnected && core.isMultiplexSyncHealthy -> 60_000L
                    streamConnected -> 25_000L
                    else -> 12_000L
                }
                delay(intervalMs)
                if (isLive || !streamConnected || !core.isMultiplexSyncHealthy) {
                    loadHistory(id)
                }
            }
        }
    }

    LaunchedEffect(missionId, lifecycleOwner) {
        val id = missionId ?: return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (!fastReopen || isLive || followUps.count > 0) {
                refreshFollowUps(id)
            }
            while (isActive) {
                delay(if (isLive || followUps.count > 0) 4_000L else 30_000L)
                if (isLive || followUps.count > 0 || !core.isMultiplexSyncHealthy) {
                    refreshFollowUps(id)
                }
            }
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
                        sideAgentSession = OrbSideAgentSession(
                            parentId = id,
                            initialQuestion = question,
                            contextTurns = latestTurns
                        )
                        UsageTelemetry.trackAction(UsageTelemetry.Action.Btw, "composer")
                    }
                    OrbMissionCommand.Fork -> {
                        val nativeFallback = backends.firstOrNull()?.str("id", "slug") ?: "claudecode"
                        val targetBackend = if (isCloudMission || selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes") || selectedBackend.startsWith("cloud_")) {
                            nativeFallback
                        } else {
                            selectedBackend
                        }
                        val body = mutableMapOf<String, Any?>(
                            "backend" to targetBackend,
                            "model_override" to if (isCloudMission) "" else selectedModel,
                            "model_effort" to null,
                            "idempotency_key" to UUID.randomUUID().toString()
                        )
                        if (isCloudMission && selectedNodeId.isNotEmpty() && selectedNodeId != "core") {
                            body["remote_node_id"] = selectedNodeId
                        }
                        val created = OrbJSON.dict(core.request("$base/fork", method = "POST", body = body))
                            ?: throw OrbError("Fork failed.")
                        core.refreshMissionsQuietly()
                        currentMission = OrbRow(created)
                        commandBanner = if (isCloudMission) "Continued in workspace" else "Forked into a new conversation"
                        UsageTelemetry.trackAction(UsageTelemetry.Action.Fork, "composer")
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

    /** Optimistic follow-up while a turn runs: the row shows now, Core queues it durably. */
    fun queueFollowUp(id: String, content: String) {
        val clientId = UUID.randomUUID().toString()
        val lastSequence = maxOf(
            lastMissionSequence(events, id) ?: Long.MIN_VALUE,
            lastMissionSequence(messages, id) ?: Long.MIN_VALUE
        ).takeIf { it != Long.MIN_VALUE }
        followUps = followUps.enqueue(clientId, content, lastSequence = lastSequence)
        UsageTelemetry.trackAction(UsageTelemetry.Action.Queue, "composer")
        scope.launch {
            try {
                settingsSaveJob?.join()
                val cyber = OrbCyberAccess.requireFollowUp(core, id, content)
                val msgBody = mutableMapOf<String, Any?>(
                    "content" to content,
                    "mission_id" to id,
                    "queue_followup" to true,
                    "client_message_id" to clientId
                )
                if (cyber != null) {
                    msgBody["cyber_access"] = cyber.mode.wire
                    if (!cyber.revision.isNullOrEmpty()) msgBody["cyber_revision"] = cyber.revision
                }
                val receipt = OrbJSON.dict(
                    core.request(
                        "/api/control/message",
                        method = "POST",
                        body = msgBody
                    )
                )
                if (receipt?.get("message_accepted") == false) throw OrbError("Message was not accepted.")
                val queued = receipt?.get("queued") == true
                val receiptId = OrbJSON.str(receipt, "id") ?: clientId
                val postedAtMs = System.currentTimeMillis()
                followUps = if (receiptId == clientId) followUps.posted(clientId, queued, atMs = postedAtMs)
                else followUps.postFailed(clientId).let { if (queued) it.enqueue(receiptId, content, lastSequence = lastSequence).posted(receiptId, true, atMs = postedAtMs) else it }
                if (!queued) loadHistory(id)
                refreshFollowUps(id)
            } catch (e: Throwable) {
                followUps = followUps.postFailed(clientId)
                inputText = inputText.ifEmpty { content }
                errorMessage = OrbCyberAccess.error(e)
            }
        }
    }

    fun editQueued(queueId: String, content: String) {
        val id = missionId ?: return
        editingQueuedId = null
        inputText = ""
        val before = followUps.row(queueId)
        if (before == null) {
            errorMessage = "This message was already sent. Your edit was not applied."
            return
        }
        val wireContent = OrbMessagePresentation.replaceUserText(before.content, content)
        followUps = followUps.edit(queueId, wireContent)
        scope.launch {
            try {
                OrbCyberAccess.requireFollowUp(core, id, content)
            } catch (e: Exception) {
                followUps = followUps.editReverted(queueId)
                inputText = content
                editingQueuedId = queueId
                errorMessage = OrbCyberAccess.error(e)
                return@launch
            }
            val status = try {
                core.request("/api/control/queue/${core.encodeComponent(queueId)}", method = "PATCH", body = mapOf("content" to wireContent))
                200
            } catch (e: OrbError) {
                e.status ?: -1
            } catch (e: Throwable) {
                -1
            }
            when (OrbSendFlow.editOutcome(status.takeIf { it >= 0 })) {
                OrbEditOutcome.Edited -> {
                    followUps = followUps.editConfirmed(queueId, wireContent)
                    UsageTelemetry.trackAction(UsageTelemetry.Action.MessageEdit, "followup_queue")
                }
                OrbEditOutcome.Unsupported -> {
                    followUps = followUps.editReverted(queueId)
                    errorMessage = "This edit cannot be saved atomically. The queued messages have not been changed."
                }
                OrbEditOutcome.AlreadySent -> {
                    followUps = followUps.editReverted(queueId)
                    errorMessage = "This message was already sent, so the edit was not applied."
                    loadHistory(id)
                }
                OrbEditOutcome.Failed -> {
                    followUps = followUps.editReverted(queueId)
                    errorMessage = "Couldn't save the edit."
                }
            }
            refreshFollowUps(id)
        }
    }

    fun removeQueued(queueId: String) {
        val id = missionId ?: return
        if (editingQueuedId == queueId) { editingQueuedId = null; inputText = "" }
        followUps = followUps.hide(queueId)
        scope.launch {
            try {
                core.request("/api/control/queue/${core.encodeComponent(queueId)}", method = "DELETE")
                refreshFollowUps(id)
            } catch (e: OrbError) {
                if (e.status != 404) {
                    followUps = followUps.unhide(queueId)
                    errorMessage = e.message
                }
            } catch (e: Throwable) {
                followUps = followUps.unhide(queueId)
                errorMessage = e.message
            }
        }
    }

    // Follow the latest message only while the reader has not scrolled away.
    val transcriptFollow = remember(missionId) { OrbTranscriptFollow() }
    var followPinned by remember(missionId) { mutableStateOf(true) }
    fun syncFollow() { followPinned = transcriptFollow.pinned }

    fun performSendTurn(rawInput: String? = null, cyberAssertion: OrbCyberSelection? = null) {
        val baseText = (rawInput ?: inputText).trim()
        if (baseText.isEmpty() && pendingAttachments.isEmpty()) return
        transcriptFollow.pin(); syncFollow()
        if (rawInput == null) {
            OrbMissionCommand.parse(baseText)?.let { (command, arg) ->
                runMissionCommand(command, arg)
                return
            }
        }
        val editingId = editingQueuedId
        if (editingId != null && rawInput == null && missionId != null) {
            editQueued(editingId, baseText)
            return
        }
        if ((handoffActive || liveRow?.let { OrbMissionTree.isLive(it) } == true) && rawInput == null && missionId != null && pendingAttachments.isEmpty()) {
            queueFollowUp(missionId, composeMode.wrapPrompt(baseText))
            inputText = ""
            return
        }

        val isCloudServiceForLaunch = selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes")
        if (currentMission == null && !isCloudServiceForLaunch && selectedWorkspaceId.isEmpty() && selectedNodeId.isNotEmpty() && selectedNodeId != "core" && selectedBackend == "opencode" && selectedModel.isBlank() && nodePinnedByUser) {
            errorMessage = "Choose an explicit model to run OpenCode on a remote machine, or select Core."
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
                live.resetTurn()
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
                    settingsSaveJob?.join()
                    val row = currentMission
                    val rowBackend = row?.str("backend", "harness", "backend_id").orEmpty()
                    val persistedModel = row?.str("model_override") ?: ""
                    val desiredModel = selectedModel.trim()
                    if (!rowBackend.startsWith("cloud_") && (rowBackend.isEmpty() || selectedBackend == rowBackend) && desiredModel != persistedModel) {
                        val updated = OrbJSON.dict(
                            core.request(
                                path = "/api/control/missions/${core.encodeComponent(existingId)}/settings",
                                method = "PATCH",
                                body = mapOf("model_override" to desiredModel, "resume" to false)
                            )
                        )
                        if (updated != null) {
                            val savedRow = mergeConfirmedSettingsInto(currentMission, updated, existingId)
                            currentMission = savedRow
                            core.upsertMissionInMemory(savedRow)
                        }
                    }
                    if (rowBackend.startsWith("cloud_")) {
                        core.request(
                            path = "/api/control/message",
                            method = "POST",
                            body = mapOf(
                                "mission_id" to existingId,
                                "content" to finalPrompt,
                                "client_message_id" to UUID.randomUUID().toString()
                            )
                        )
                    } else {
                        val msgBody = mutableMapOf<String, Any?>(
                            "mission_id" to existingId,
                            "content" to finalPrompt,
                            "client_message_id" to UUID.randomUUID().toString()
                        )
                        val cyber = cyberAssertion ?: cyberSelection
                        if (rowBackend == "codex" && cyber != null) {
                            msgBody["cyber_access"] = cyber.mode.wire
                            if (!cyber.revision.isNullOrEmpty()) msgBody["cyber_revision"] = cyber.revision
                        }
                        core.request(
                            path = "/api/control/message",
                            method = "POST",
                            body = msgBody
                        )
                    }
                    loadHistory(existingId)
                    core.refreshMissionsQuietly()
                } else {
                    val slug = project.str("slug", "id") ?: project.id
                    val tags = mutableListOf<String>()
                    if (composeMode == OrbComposeMode.Goal) tags.add("orb-mode:goal")
                    val cleanFolder = OrbMissionTree.normalizeFolder(initialFolder)

                    val isCloudService = selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes")
                    val body = if (isCloudService) {
                        val accounts = if (cloudAccounts.isNotEmpty()) {
                            cloudAccounts
                        } else {
                            runCatching { core.fetchRows("/api/cloud/accounts", "items") }.getOrDefault(emptyList()).also {
                                if (it.isNotEmpty()) cloudAccounts = it
                            }
                        }
                        val resolvedAccount = selectedAccount.ifEmpty {
                            accounts.firstOrNull { it.str("provider") == selectedBackend && it.bool("available") == true }?.str("id")
                                ?: accounts.firstOrNull { it.str("provider") == selectedBackend }?.str("id")
                                ?: when (selectedBackend) {
                                    "hermes" -> "hermes-default"
                                    "cursor_cloud" -> "cursor-default"
                                    else -> "grok-default"
                                }
                        }
                        if (selectedBackend == "cursor_cloud" && (selectedRepo.isBlank() || selectedGitRef.isBlank())) {
                            throw OrbError("Choose a repository and Git reference for Cursor Cloud.")
                        }
                        val cloudSpec = mutableMapOf<String, Any?>(
                            "provider" to selectedBackend,
                            "account" to resolvedAccount
                        )
                        if (selectedModel.isNotEmpty()) cloudSpec["model"] = selectedModel
                        if (selectedRepo.isNotEmpty()) cloudSpec["repository"] = selectedRepo
                        if (selectedGitRef.isNotEmpty()) cloudSpec["git_ref"] = selectedGitRef
                        val cloudBody = mutableMapOf<String, Any?>(
                            "prompt" to finalPrompt,
                            "title" to OrbJSON.cleanTitle(baseText).take(72),
                            "project" to slug,
                            "folder" to cleanFolder,
                            "idempotency_key" to UUID.randomUUID().toString(),
                            "cloud" to cloudSpec
                        )
                        if (tags.isNotEmpty()) cloudBody["tags"] = tags
                        cloudBody
                    } else {
                        val nativeBody = mutableMapOf<String, Any?>(
                            "prompt" to finalPrompt,
                            "title" to OrbJSON.cleanTitle(baseText).take(72),
                            "project" to slug,
                            "folder" to cleanFolder,
                            "backend" to selectedBackend
                        )
                        if (tags.isNotEmpty()) nativeBody["tags"] = tags
                        if (OrbCyberAccess.nativeCodex(selectedBackend)) nativeBody["cyber_access"] = selectedCyber.wire
                        if (selectedModel.isNotEmpty()) nativeBody["model_override"] = selectedModel
                        if (selectedWorkspaceId.isNotEmpty()) nativeBody["workspace_id"] = selectedWorkspaceId
                        if (selectedWorkspaceId.isEmpty() && selectedNodeId.isNotEmpty() && selectedNodeId != "core") {
                            if (OrbManagedMachines.isAutoManagedTarget(selectedNodeId) && selectedBackend in setOf("grok", "vibe")) {
                                throw OrbError("${OrbAgentCatalog.backendLabel(selectedBackend, backends)} is not supported on managed cloud VMs. Choose Claude Code, Codex, OpenCode, or Antigravity, or select Core.")
                            }
                            if (selectedBackend == "opencode" && selectedModel.isBlank()) {
                                if (nodePinnedByUser) {
                                    throw OrbError("Choose an explicit model to run OpenCode on a remote machine, or select Core.")
                                }
                            } else {
                                nativeBody["remote_node_id"] = selectedNodeId
                                if (allow24hCommitment && OrbManagedMachines.isAutoManagedTarget(selectedNodeId)) {
                                    nativeBody["managed_allow_24h_commitment"] = true
                                }
                            }
                        }
                        if (selectedAccount.isNotEmpty()) nativeBody["account_id"] = selectedAccount
                        if (selectedRepo.isNotEmpty()) nativeBody["repo"] = selectedRepo
                        if (selectedGitRef.isNotEmpty()) nativeBody["git_ref"] = selectedGitRef
                        if (selectedConfigProfile.isNotEmpty()) nativeBody["config_profile"] = selectedConfigProfile
                        nativeBody
                    }

                    val created = core.request("/api/control/missions", method = "POST", body = body)
                    val dict = OrbJSON.dict(created) ?: OrbJSON.dict(OrbJSON.dict(created)?.get("mission"))
                    if (dict != null) {
                        val row = OrbRow(dict)
                        adoptedNewMissionId = row.id
                        currentMission = row
                        core.refreshMissionsQuietly()
                        loadHistory(row.id)
                    }
                }
            } catch (e: Throwable) {
                errorMessage = OrbCyberAccess.error(e)
            } finally {
                isSending = false
            }
        }
    }

    fun sendTurn(rawInput: String? = null) {
        if (isSending) return
        val text = (rawInput ?: inputText).trim()
        if (text.isEmpty() && pendingAttachments.isEmpty()) return
        isSending = true
        scope.launch {
            try {
                validateComposerSkills(composeMode.wrapPrompt(text))?.let { err ->
                    errorMessage = err
                    isSending = false
                    return@launch
                }
                val mission = currentMission
                if (mission != null) {
                    val cyber = OrbCyberAccess.requireFollowUp(core, mission.id, composeMode.wrapPrompt(text))
                    isSending = false
                    performSendTurn(rawInput, cyber)
                    return@launch
                }
                if (!OrbCyberAccess.nativeCodex(selectedBackend)) {
                    isSending = false
                    performSendTurn(rawInput)
                    return@launch
                }
                val selection = selectedCyber
                val backend = selectedBackend
                val model = selectedModel
                if (OrbCyberAccess.nativeGoal(backend, composeMode.wrapPrompt(text)) &&
                    composeMode.wrapPrompt(text).trim().equals("/goal", ignoreCase = true))
                    throw OrbError(OrbCyberAccess.EMPTY_GOAL)
                val remote = (selectedWorkspaceId.isEmpty() &&
                    selectedNodeId.isNotEmpty() && selectedNodeId != "core" &&
                    selectedBackend !in setOf("cursor_cloud", "grok_bot", "hermes") &&
                    !(selectedBackend == "opencode" && selectedModel.isBlank() && !nodePinnedByUser))
                OrbCyberAccess.requireSupport(model, selection, remote,
                    OrbCyberAccess.nativeGoal(backend, composeMode.wrapPrompt(text))) { path ->
                    OrbJSON.dict(core.request(path)) ?: emptyMap()
                }
                isSending = false
                performSendTurn(rawInput)
            } catch (e: Exception) {
                errorMessage = OrbCyberAccess.error(e)
                isSending = false
            }
        }
    }

    // Follow-ups now live in Core's durable queue: Core delivers them in order
    // when the turn ends, so nothing is drained from the phone.

    fun stopMission() {
        val id = missionId ?: return
        isStopping = true
        handoff = null
        scope.launch {
            try {
                if (isCloudMission) {
                    core.request("/api/control/missions/${core.encodeComponent(id)}/cloud/cancel", method = "POST")
                } else {
                    orbTry(OrbLog.Category.Network, "/api/control/missions") {
                        core.request("/api/control/missions/$id/cancel", method = "POST")
                    }.onFailure {
                        core.request("/api/control/missions/$id/stop", method = "POST")
                    }
                }
                core.refreshMissionsQuietly()
            } catch (e: Throwable) {
                errorMessage = e.message
            } finally {
                isStopping = false
            }
        }
    }

    fun forceSlotNow() {
        val id = missionId ?: return
        if (isForcingSlot || !canForceSlot) return
        isForcingSlot = true
        scope.launch {
            try {
                val res = core.request("/api/control/missions/${core.encodeComponent(id)}/force-slot", method = "POST")
                val updated = OrbJSON.dict(res)
                if (updated != null) {
                    currentMission = OrbRow(id, updated)
                }
                core.refreshMissionsQuietly()
                loadHistory(id)
            } catch (e: Throwable) {
                errorMessage = "Couldn't run immediately. ${e.message ?: ""}".trim()
            } finally {
                isForcingSlot = false
            }
        }
    }

    /**
     * Send now: the row leaves the queue and the message enters the thread in the
     * same frame; Core promotes it (stop, then this message next under the same
     * id) or injects it live. A refusal puts everything back.
     */
    fun sendQueuedNow(queueId: String) {
        val id = missionId ?: return
        if (editingQueuedId != null) return
        val row = followUps.row(queueId) ?: return
        if (row.sending) return
        val localId = "local-sendnow-$queueId"
        live.resetTurn()
        followUps = followUps.hide(queueId)
        messages = messages + OrbRow(
            localId,
            mapOf("role" to "user", "content" to OrbMessagePresentation.parse(row.content).text.trim(), "created_at" to java.time.Instant.now().toString())
        )
        handoff = OrbHandoff(queueId, System.currentTimeMillis())
        scope.launch {
            try {
                OrbCyberAccess.requireFollowUp(core, id, row.content)
                val resp = OrbJSON.dict(
                    core.request("/api/control/queue/${core.encodeComponent(queueId)}/send-now?interrupt=true", method = "POST")
                )
                when (OrbSendFlow.sendNowOutcome(resp)) {
                    OrbSendFlow.SendNow.Live -> handoff = null
                    OrbSendFlow.SendNow.Promoted -> Unit // handoff ends when the new turn runs
                    OrbSendFlow.SendNow.Fallback -> {
                        OrbCyberAccess.requireFollowUp(core, id, row.content)
                        // Older Core without promote: stop the turn, then send this message.
                        messages = messages.filterNot { it.id == localId }
                        orbTry(OrbLog.Category.Network, "/api/control/queue") {
                            core.request("/api/control/queue/${core.encodeComponent(queueId)}", method = "DELETE")
                        }
                        orbTry(OrbLog.Category.Network, "/api/control/missions") {
                            core.request("/api/control/missions/$id/cancel", method = "POST")
                        }
                        sendTurn(OrbMessagePresentation.parse(row.content).text)
                    }
                }
                core.refreshMissionsQuietly()
                refreshFollowUps(id)
            } catch (e: Throwable) {
                messages = messages.filterNot { it.id == localId }
                followUps = followUps.unhide(queueId)
                handoff = null
                errorMessage = OrbCyberAccess.error(e)
            }
        }
    }

    // The transcript is rebuilt when history changes; a streaming frame only adds its bubble.
    // Changes on the first delta and on clear only; the text itself is read by the bubble.
    val hasStreamingText = live.hasText
    val baseTurns = remember(messages, events, hasStreamingText, isLive, liveRow) {
        OrbTimelineBuilder.buildBase(
            messages = messages,
            events = events,
            hasStreamingText = hasStreamingText,
            isLive = isLive,
            startedAt = liveRow?.str("root_started_at", "started_at", "created_at")
        )
    }
    val allTurns = remember(baseTurns, hasStreamingText) { OrbTimelineBuilder.withLiveBubble(baseTurns, hasStreamingText) }

    LaunchedEffect(allTurns) {
        latestTurns = allTurns
        transcriptFollow.advanceLayoutEpoch()
        transcriptFollow.verifyClientParity(
            transcriptSeq = events.lastOrNull()?.int("sequence") ?: allTurns.size,
            markdownBlocksCount = allTurns.size,
            sendQueueDepth = if (inputText.isNotBlank()) 1 else 0
        )
    }

    var visibleTurnLimit by remember(missionId) { mutableIntStateOf(24) }
    val turns = remember(allTurns, visibleTurnLimit) {
        if (allTurns.size > visibleTurnLimit) allTurns.takeLast(visibleTurnLimit) else allTurns
    }
    DisposableEffect(missionId) {
        missionId?.let { OrbCrashBreadcrumbs.enterConversation(it, turns.size) }
        onDispose { OrbCrashBreadcrumbs.leaveConversation() }
    }
    LaunchedEffect(turns.size) { OrbCrashBreadcrumbs.updateTurnCount(turns.size) }

    val changedFiles = remember(baseTurns) { OrbTurnRecap.changedFiles(baseTurns.turns) }

    // shared_files metadata for chips: refreshed when a message with a file tag lands.
    val fileTagTurns = remember(baseTurns) {
        baseTurns.turns.count { it is OrbTurn.Assistant && !it.isStreaming && (it.text.contains("<file", true) || it.text.contains("<image", true)) }
    }
    val fileContext = LocalContext.current
    LaunchedEffect(missionId, fileTagTurns) {
        if (missionId == null || fileTagTurns == 0) return@LaunchedEffect
        runCatching { OrbFileService.get(core, fileContext).messages(fileScope) }
            .onSuccess { messages -> sharedFiles = messages.flatMap { it.shared } }
    }

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

    var speechTargetMissionId by remember { mutableStateOf(missionId) }
    var dictationPhase by remember(missionId) { mutableStateOf(OrbAndroidDictationPhase.Idle) }
    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (speechTargetMissionId != composerDraftStore.activeMissionId) return@rememberLauncherForActivityResult
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
        speechTargetMissionId = composerDraftStore.activeMissionId
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

    val sparkDictation = remember(sparkRecorder, core, missionId) {
        OrbSparkDictationSessionCoordinator(
            recorder = sparkRecorder,
            isSparkAvailable = { core.isConfigured },
            transcribeWav = { wav -> OrbSparkTranscriber.transcribe(core, wav, OrbDictationSettings.resolve()) },
            onPhaseChange = { phase ->
                if (missionId == composerDraftStore.activeMissionId) dictationPhase = phase
            },
            onAppendTranscript = { spoken ->
                if (missionId == composerDraftStore.activeMissionId) appendTranscript(spoken)
            },
            onFallbackSystemSpeech = {
                if (missionId == composerDraftStore.activeMissionId) launchSystemSpeech()
            },
            onError = { message ->
                if (missionId == composerDraftStore.activeMissionId) {
                    errorMessage = message?.takeIf { it.isNotEmpty() }
                }
            },
        )
    }

    var permissionTargetMissionId by remember { mutableStateOf(missionId) }

    fun startSparkRecording() {
        if (sparkDictation.startRecording()) {
            dictationElapsed = 0
        }
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (permissionTargetMissionId != composerDraftStore.activeMissionId) return@rememberLauncherForActivityResult
        if (granted) {
            startSparkRecording()
        } else {
            sparkDictation.cancel(resetPhase = false)
            launchSystemSpeech()
        }
    }

    fun launchSpeech() {
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) {
            startSparkRecording()
        } else {
            permissionTargetMissionId = missionId
            micPermissionLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
        }
    }

    fun finishSparkRecording() {
        sparkDictation.finishRecording(scope)
    }

    LaunchedEffect(dictationPhase) {
        while (dictationPhase == OrbAndroidDictationPhase.Recording) {
            delay(250)
            dictationElapsed = sparkRecorder.elapsedSeconds
            if (dictationElapsed >= OrbSparkRecorder.MAX_SECONDS) finishSparkRecording()
        }
    }

    DisposableEffect(sparkDictation, missionId) {
        onDispose {
            sparkDictation.cancel(resetPhase = false)
        }
    }

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
        val currentTopPx = listState.firstVisibleItemIndex * 64 + listState.firstVisibleItemScrollOffset
        val targetTopPx = maxOf(currentTopPx + 1, (targetIdx + 1) * 64)
        if (hasAnchoredInitial && !transcriptFollow.shouldCorrectInEpoch(targetTopPx, currentTopPx)) {
            return
        }
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

    // Streaming growth follows the bottom without recomposing the screen.
    LaunchedEffect(live) {
        androidx.compose.runtime.snapshotFlow { live.text.length }.collect { length ->
            if (length > 0 && hasAnchoredInitial && transcriptFollow.shouldFollow(true)) scrollToAbsoluteBottom()
        }
    }

    LaunchedEffect(turns.size, turns.lastOrNull()?.id, workStepCount, completedPlanTurnKey) {
        if (turns.isNotEmpty()) {
            // Not "the last few items are visible": one tall turn is several screens,
            // and a reader scrolled up into it was pulled to the bottom on every delta.
            if (transcriptFollow.shouldFollow(hasAnchoredInitial)) {
                scrollToAbsoluteBottom()
                if (!hasAnchoredInitial) {
                    withFrameNanos { }
                    scrollToAbsoluteBottom()
                    hasAnchoredInitial = true
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

            if (missionId != null || onOpenDocuments != null) {
                Box {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .orbPressClickable { showHeaderMenu = true }
                            .testTag("conversation.menu"),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.MoreHoriz,
                            contentDescription = "Conversation actions",
                            tint = Color.White,
                            modifier = Modifier.size(19.dp)
                        )
                    }
                    DropdownMenu(
                        expanded = showHeaderMenu,
                        onDismissRequest = { showHeaderMenu = false },
                        containerColor = OrbStyle.elevated
                    ) {
                        if (missionId != null && liveRow != null) {
                            val rawStatus = liveRow.str("status", "state") ?: ""
                            val liveStreaming = isLive || live.hasText || baseTurns.turns.any { (it is OrbTurn.WorkFold && it.isLive) || (it is OrbTurn.Assistant && it.isStreaming) }
                            val statusText = when {
                                liveStreaming && (rawStatus.isEmpty() || MissionState.of(rawStatus)?.live != true) -> "Working"
                                rawStatus.isNotEmpty() && rawStatus != "unknown" -> MissionState.label(rawStatus)
                                else -> ""
                            }
                            val shortModel = selectedModel.substringAfterLast('/')
                            val agentText = shortModel.ifEmpty { OrbAgentCatalog.backendLabel(selectedBackend.ifEmpty { "Agent" }, backends) }
                            val summary = listOf(agentText, statusText).filter { it.isNotEmpty() }.joinToString(" · ")
                            if (summary.isNotEmpty()) {
                                Text(
                                    text = summary,
                                    color = OrbStyle.textMuted,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                                )
                                HorizontalDivider(color = OrbStyle.border)
                            }
                            if (!isCloudMission) {
                                DropdownMenuItem(
                                    text = { Text("Side question", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.Psychology, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showHeaderMenu = false
                                        sideAgentSession = OrbSideAgentSession(parentId = missionId, initialQuestion = "", contextTurns = latestTurns)
                                        UsageTelemetry.trackAction(UsageTelemetry.Action.Btw, "header_menu")
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text("Files", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.Folder, contentDescription = null, tint = Color.White) },
                                    modifier = Modifier.testTag("conversation.files"),
                                    onClick = {
                                        showHeaderMenu = false
                                        showFiles = true
                                    }
                                )
                            }
                            if (onOpenDocuments != null) {
                                DropdownMenuItem(
                                    text = { Text("Project context", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.Description, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showHeaderMenu = false
                                        onOpenDocuments("")
                                    }
                                )
                            }
                            val externalUrl = OrbJSON.str(liveRow.dict("execution"), "external_url")
                            if (!externalUrl.isNullOrEmpty()) {
                                DropdownMenuItem(
                                    text = { Text("Open in service", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.OpenInNew, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showHeaderMenu = false
                                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(externalUrl))) }
                                    }
                                )
                            }
                            HorizontalDivider(color = OrbStyle.border)
                            DropdownMenuItem(
                                text = { Text("Rename", color = Color.White) },
                                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null, tint = Color.White) },
                                onClick = {
                                    showHeaderMenu = false
                                    renameDraft = OrbJSON.cleanTitle(liveRow.str("title", "name") ?: "")
                                    showRenameDialog = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Move", color = Color.White) },
                                leadingIcon = { Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White) },
                                onClick = {
                                    showHeaderMenu = false
                                    val projectSlug = OrbMissionTree.effectiveProject(liveRow).ifEmpty {
                                        if (OrbMissionTree.hasAuthoritativePlacement(liveRow)) "" else (project.str("slug", "id") ?: project.id)
                                    }
                                    val cachedProjectRows = OrbReadCache.readMemoryRows("project_missions_$projectSlug")
                                    OrbMoveClipboard.pick(liveRow, projectSlug, cachedProjectRows.ifEmpty { core.missions.value })
                                    commandBanner = "Ready to move — open destination project or folder"
                                }
                            )
                            val canCloudHandoff = isCloudMission && OrbKernel.cloudHandoffStep(
                                sourceIsCloud = true,
                                isSideQuestion = false,
                                targetIsNative = true,
                                hasHistoryTurns = turns.isNotEmpty(),
                                targetPlacementValid = true
                            ) == OrbKernel.CloudHandoffStepResult.ALLOW_HANDOFF
                            if (!isCloudMission || canCloudHandoff) {
                                DropdownMenuItem(
                                    text = { Text(if (isCloudMission) "Continue in workspace" else "Fork", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.CallSplit, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showHeaderMenu = false
                                        if (isCloudMission) {
                                            if (selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes") || selectedBackend.startsWith("cloud_")) {
                                                selectedBackend = backends.firstOrNull()?.str("id", "slug") ?: "claudecode"
                                                selectedModel = ""
                                            }
                                            showAgentPicker = true
                                        } else {
                                            runMissionCommand(OrbMissionCommand.Fork, "")
                                        }
                                    }
                                )
                            }
                            if (!isCloudMission) {
                                DropdownMenuItem(
                                    text = { Text("Clone", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.ContentCopy, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showHeaderMenu = false
                                        runMissionCommand(OrbMissionCommand.Clone, "")
                                    }
                                )
                            }
                            val isArchived = OrbMissionTree.isArchived(liveRow)
                            HorizontalDivider(color = OrbStyle.border)
                            if (liveStreaming) {
                                DropdownMenuItem(
                                    text = { Text("Stop", color = OrbStyle.error) },
                                    leadingIcon = { Icon(Icons.Default.Stop, contentDescription = null, tint = OrbStyle.error) },
                                    onClick = {
                                        showHeaderMenu = false
                                        stopMission()
                                    }
                                )
                            } else {
                                val nextStatus = if (isArchived) "paused" else "acknowledged"
                                DropdownMenuItem(
                                    text = { Text(if (isArchived) "Restore" else "Archive", color = Color.White) },
                                    leadingIcon = {
                                        Icon(
                                            imageVector = if (isArchived) Icons.Default.Unarchive else Icons.Default.Archive,
                                            contentDescription = null,
                                            tint = Color.White
                                        )
                                    },
                                    onClick = {
                                        showHeaderMenu = false
                                        scope.launch {
                                            orbTry(OrbLog.Category.Network, "/api/control/missions") {
                                                core.request(
                                                    "/api/control/missions/${core.encodeComponent(missionId)}/status",
                                                    method = "POST",
                                                    body = mapOf("status" to nextStatus)
                                                )
                                                core.refreshMissionsQuietly()
                                                loadHistory(missionId)
                                            }.onFailure { errorMessage = it.message }
                                        }
                                    }
                                )
                            }
                        } else if (onOpenDocuments != null) {
                            DropdownMenuItem(
                                text = { Text("Project context", color = Color.White) },
                                leadingIcon = { Icon(Icons.Default.Description, contentDescription = null, tint = Color.White) },
                                onClick = {
                                    showHeaderMenu = false
                                    onOpenDocuments("")
                                }
                            )
                        }
                    }
                }
            }
        }

        // Pinned state comes from the reader's own drags and flings, never from content growth.
        LaunchedEffect(listState, missionId) {
            listState.interactionSource.interactions.collect { interaction ->
                if (interaction is DragInteraction.Start) { transcriptFollow.onDragStart(); syncFollow() }
            }
        }
        LaunchedEffect(listState, missionId) {
            snapshotFlow { listState.isScrollInProgress }.collect { moving ->
                if (!moving) { transcriptFollow.onSettled(atEnd = !listState.canScrollForward); syncFollow() }
            }
        }

        // Conversation Body
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
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
                Box(
                    modifier = if (reducedMotion) Modifier else Modifier.animateItem(
                        fadeInSpec = androidx.compose.animation.core.tween(220),
                        placementSpec = androidx.compose.animation.core.spring(stiffness = androidx.compose.animation.core.Spring.StiffnessMediumLow),
                        fadeOutSpec = androidx.compose.animation.core.tween(OrbSendFlow.LEAVE_MS)
                    )
                ) {
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
                        androidx.compose.runtime.CompositionLocalProvider(
                            LocalOrbFiles provides OrbFileContext(fileScope, sharedFiles, core) { fileRef = it }
                        ) {
                            val showTurn: @Composable (OrbTurn.Assistant) -> Unit = { shown ->
                                OrbAssistantTurnView(
                                    turn = shown,
                                    core = core,
                                    missionId = missionId,
                                    workspaceId = selectedWorkspaceId.takeIf { it.isNotEmpty() },
                                    onSendAnswer = { ans -> sendTurn(ans) }
                                )
                            }
                            if (turn.isStreaming) OrbLiveReply(live, baseTurns.storedAnswers) { text -> showTurn(turn.copy(text = text)) }
                            else showTurn(turn)
                        }
                    }
                    is OrbTurn.WorkFold -> {
                        val workingLabel = when {
                            handoffActive -> "Sending…"
                            slotWait != null -> slotWait.label
                            events.isEmpty() -> missionId?.let { OrbPresentation.activity(it) }?.takeIf { it.isNotEmpty() }
                            else -> null
                        }
                        androidx.compose.runtime.CompositionLocalProvider(
                            LocalOrbWorkingLabel provides workingLabel
                        ) {
                            OrbWorkFoldView(
                                fold = turn,
                                onPreviewFile = { previewFilePath = it },
                                onForceSlot = if (turn.isLive && canForceSlot) ({ forceSlotNow() }) else null,
                                forceSlotPending = isForcingSlot
                            )
                        }
                    }
                    is OrbTurn.Wake -> {
                        OrbBackgroundWakeRow(turn = turn)
                    }
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
        if (!followPinned && hasAnchoredInitial && listState.canScrollForward) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 10.dp)
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable {
                        transcriptFollow.pin(); syncFollow()
                        scope.launch { scrollToAbsoluteBottom() }
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(imageVector = Icons.Default.KeyboardArrowDown, contentDescription = "Jump to latest", tint = Color.White, modifier = Modifier.size(20.dp))
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

            // Slash mode & skill menu popup
            val slashQuery = remember(inputText, isCloudComposer) {
                if (isCloudComposer) OrbSkillQuery(open = false, query = "", start = -1)
                else OrbSkillSlash.skillQuery(inputText, inputText.length)
            }
            val slashModes = remember(showModePicker, slashQuery, composeMode) {
                when {
                    showModePicker -> OrbComposeMode.entries
                    slashQuery.open && slashQuery.start == 0 && composeMode == OrbComposeMode.Message ->
                        OrbComposeMode.entries.filter { slashQuery.query.isEmpty() || it.id.startsWith(slashQuery.query) }
                    else -> emptyList()
                }
            }
            val slashCommands = remember(showModePicker, slashQuery, missionId) {
                if (missionId == null || (!showModePicker && !(slashQuery.open && slashQuery.start == 0))) emptyList()
                else OrbMissionCommand.entries.filter {
                    showModePicker || slashQuery.query.isEmpty() || it.trigger.removePrefix("/").startsWith(slashQuery.query)
                }
            }
            val slashSkills = remember(slashQuery, skillItems, selectedSkillNames, isCloudComposer) {
                if (isCloudComposer || !slashQuery.open) emptyList()
                else OrbSkillSlash.filterSkills(skillItems, slashQuery.query, selectedSkillNames)
            }
            val showSlashMenu = showModePicker || (slashQuery.open && (slashModes.isNotEmpty() || slashCommands.isNotEmpty() || slashSkills.isNotEmpty() || skillCatalogError != null))
            if (showSlashMenu) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(OrbStyle.panelRadius))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(OrbStyle.panelRadius))
                        .padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (slashModes.isNotEmpty()) {
                        Text(
                            text = "MODES",
                            color = OrbStyle.textMuted,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.7.sp,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                        )
                        slashModes.forEach { mode ->
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
                    }
                    if (slashCommands.isNotEmpty()) {
                        Text(
                            text = "COMMANDS",
                            color = OrbStyle.textMuted,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.7.sp,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                        )
                        slashCommands.forEach { command ->
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
                    if (slashSkills.isNotEmpty() || skillCatalogError != null) {
                        Text(
                            text = "SKILLS",
                            color = OrbStyle.textMuted,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.7.sp,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                        )
                        skillCatalogError?.let { err ->
                            Text(err, color = OrbStyle.warning, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
                        }
                        Column(modifier = Modifier.heightIn(max = 190.dp).verticalScroll(rememberScrollState())) {
                            slashSkills.forEach { skill ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(10.dp))
                                        .orbPressClickable {
                                            val inserted = OrbSkillSlash.insertSkill(inputText, inputText.length, skill.name)
                                            inputText = inserted.first
                                            showModePicker = false
                                        }
                                        .padding(horizontal = 10.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Icon(Icons.Default.Terminal, contentDescription = null, tint = OrbStyle.icon, modifier = Modifier.size(14.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(skill.name, color = Color.White, fontSize = 13.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        skill.description?.takeIf { it.isNotEmpty() }?.let {
                                            Text(it, color = OrbStyle.textMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    }
                                }
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

            // Queued follow-ups: compact rows (edit / send now / remove), Codex-style.
            OrbFollowUpQueueView(
                rows = followUps.rows,
                expanded = showQueuedDrawer,
                onToggle = { showQueuedDrawer = !showQueuedDrawer },
                editingId = editingQueuedId,
                reducedMotion = reducedMotion,
                onEdit = { row ->
                    editingQueuedId = row.id
                    inputText = OrbMessagePresentation.parse(row.content).text
                },
                onSendNow = { row -> sendQueuedNow(row.id) },
                onRemove = { row -> removeQueued(row.id) }
            )
            if (editingQueuedId != null) {
                Row(
                    modifier = Modifier.padding(horizontal = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("Editing queued message", color = OrbStyle.textSecondary, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    Text(
                        "Cancel",
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.orbPressClickable { editingQueuedId = null; inputText = "" }
                    )
                }
            }

            if (dictationPhase != OrbAndroidDictationPhase.Idle) {
                OrbAndroidDictationCapsule(
                    phase = dictationPhase,
                    elapsedSeconds = dictationElapsed,
                    onCancel = {
                        sparkDictation.cancel()
                    },
                    onFinish = {
                        if (dictationPhase == OrbAndroidDictationPhase.Recording) finishSparkRecording()
                        else if (dictationPhase != OrbAndroidDictationPhase.Transcribing) sparkDictation.cancel()
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
                        selectedSkillNames.forEach { name ->
                            Row(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(OrbStyle.card)
                                    .border(1.dp, OrbStyle.borderStrong, CircleShape)
                                    .orbPressClickable { inputText = OrbSkillSlash.removeSkill(inputText, name) }
                                    .padding(horizontal = 9.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Text("/$name", color = Color.White, fontSize = 11.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
                                Icon(Icons.Default.Close, contentDescription = "Remove skill $name", tint = OrbStyle.textMuted, modifier = Modifier.size(11.dp))
                            }
                        }

                        // Compact Agent / Harness + Machine selector pill (matching iOS)
                        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                            val selectedWorkspaceName = remember(selectedWorkspaceId, workspaces) {
                                workspaces.firstOrNull { (it.str("id") ?: it.id) == selectedWorkspaceId }
                                    ?.str("name", "title", "slug")
                                    ?.replace(Regex("-[0-9a-f]{8}$"), "")
                            }
                            val selectedMachineLabel = remember(selectedWorkspaceName, selectedNodeId, nodes, selectedBackend) {
                                val isCloudService = selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes")
                                when {
                                    isCloudService -> null
                                    !selectedWorkspaceName.isNullOrEmpty() -> selectedWorkspaceName
                                    OrbManagedMachines.isAutoManagedTarget(selectedNodeId) ->
                                        OrbManagedMachines.autoManagedLabel(selectedNodeId)
                                    selectedNodeId.isNotEmpty() && selectedNodeId != "core" -> {
                                        val found = nodes.firstOrNull { (it.str("id") ?: it.id) == selectedNodeId }
                                        found?.str("display_name", "name", "id") ?: selectedNodeId
                                    }
                                    selectedNodeId == "core" -> "Core"
                                    else -> null
                                }
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
                                        append(OrbAgentCatalog.backendLabel(selectedBackend.ifEmpty { "Agent" }, backends))
                                        if (selectedModel.isNotEmpty()) {
                                            append(" · ")
                                            append(selectedModel.substringAfterLast('/'))
                                        }
                                        if (!selectedMachineLabel.isNullOrEmpty()) {
                                            append(" · ")
                                            append(selectedMachineLabel)
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

    val transferKey = remember(missionId) { UUID.randomUUID().toString() }
    var transferRequest by remember(missionId) { mutableStateOf<Map<String, Any?>?>(null) }
    var transferredMission by remember(missionId) { mutableStateOf<OrbRow?>(null) }
    if (showAgentPicker) {
        val isCloudHandoffSheet = currentMission?.str("backend")?.startsWith("cloud_") == true
        val canCloudHandoff = isCloudHandoffSheet && OrbKernel.cloudHandoffStep(
            sourceIsCloud = true,
            isSideQuestion = false,
            targetIsNative = selectedBackend !in setOf("cursor_cloud", "grok_bot", "hermes") && !selectedBackend.startsWith("cloud_"),
            hasHistoryTurns = latestTurns.isNotEmpty() || messages.isNotEmpty(),
            targetPlacementValid = true
        ) == OrbKernel.CloudHandoffStepResult.ALLOW_HANDOFF
        OrbAgentPickerSheet(
            backends = backends,
            backendModels = backendModels,
            workspaces = workspaces,
            nodes = nodes,
            managedCatalog = managedCatalog,
            providers = providers,
            repositories = repositories,
            selectedBackend = selectedBackend,
            onSelectBackend = {
                userExplicitlyPickedAgent = true
                if (it != selectedBackend) selectedModel = ""
                selectedBackend = it
            },
            selectedModel = selectedModel,
            onSelectModel = { selectedModel = it },
            cyberMode = selectedCyber,
            showCyber = OrbCyberAccess.nativeCodex(selectedBackend, currentMission?.dict("cloud")),
            cyberSummary = if (currentMission == null) "Uses the account’s default access unless explicitly selected." else
                cyberSelection?.summary ?: "Cyber: unavailable",
            cyberEnabled = !cyberLoading && (currentMission == null || cyberSelection != null),
            cyberRemote = currentMission?.let { OrbCyberAccess.remote(it) } ?: (selectedWorkspaceId.isEmpty() &&
                selectedNodeId.isNotEmpty() && selectedNodeId != "core"),
            onSelectCyber = { mode ->
                if (!isSending) {
                    val mission = currentMission
                    val model = selectedModel
                    val prompt = composeMode.wrapPrompt(inputText)
                    val remote = mission?.let { OrbCyberAccess.remote(it) } ?: (selectedWorkspaceId.isEmpty() &&
                        selectedNodeId.isNotEmpty() && selectedNodeId != "core")
                    isSending = true
                    scope.launch {
                        try {
                            if (prompt.trim().equals("/goal", ignoreCase = true))
                                throw OrbError(OrbCyberAccess.EMPTY_GOAL)
                            OrbCyberAccess.requireSupport(model, mode, remote,
                                OrbCyberAccess.nativeGoal(selectedBackend, prompt)) { path ->
                                OrbJSON.dict(core.request(path)) ?: emptyMap()
                            }
                            if (mission == null) selectedCyber = mode
                            else {
                                val patchBody = mutableMapOf<String, Any?>("mode" to mode.wire)
                                cyberSelection?.revision?.takeIf { it.isNotEmpty() }?.let { patchBody["expected_revision"] = it }
                                val value = OrbJSON.dict(core.request("/api/control/missions/${core.encodeComponent(mission.id)}/cyber",
                                    method = "PATCH", body = patchBody)) ?: throw OrbError("Cyber settings unavailable")
                                cyberSelection = OrbCyberSelection.parse(value)
                                selectedCyber = cyberSelection!!.mode
                            }
                        } catch (e: Exception) { errorMessage = OrbCyberAccess.error(e) }
                        finally { isSending = false }
                    }
                }
            },
            selectedWorkspaceId = selectedWorkspaceId,
            onSelectWorkspaceId = {
                selectedWorkspaceId = it
                if (it.isNotEmpty()) {
                    selectedNodeId = ""
                    nodePinnedByUser = false
                    allow24hCommitment = false
                }
            },
            selectedNodeId = selectedNodeId,
            onSelectNodeId = { nodeId, allow24h ->
                selectedNodeId = nodeId
                nodePinnedByUser = true
                allow24hCommitment = allow24h
                selectedWorkspaceId = ""
            },
            selectedAccount = selectedAccount,
            onSelectAccount = { selectedAccount = it },
            selectedRepo = selectedRepo,
            onSelectRepo = { selectedRepo = it },
            selectedGitRef = selectedGitRef,
            onSelectGitRef = { selectedGitRef = it },
            selectedConfigProfile = selectedConfigProfile,
            onSelectConfigProfile = { selectedConfigProfile = it },
            existing = currentMission != null,
            cloudHandoff = isCloudHandoffSheet,
            locked = isSending || transferRequest != null,
            busy = isSending,
            transferError = errorMessage,
            onTransfer = if (currentMission != null && (!isCloudHandoffSheet || canCloudHandoff)) ({
                val targetBackend = if (selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes") || selectedBackend.startsWith("cloud_")) {
                    backends.firstOrNull()?.str("id", "slug") ?: "claudecode"
                } else {
                    selectedBackend
                }
                if (!isSending && targetBackend.isNotEmpty()) {
                    isSending = true
                    errorMessage = null
                    scope.launch {
                        try {
                            val source = currentMission ?: throw OrbError("Conversation unavailable.")
                            OrbCyberAccess.requireInherited(core, source.id, selectedBackend, selectedModel, "")
                            val base = "/api/control/missions/${core.encodeComponent(source.id)}"
                            var next = transferredMission
                            if (next == null) {
                                if (!isCloudHandoffSheet) {
                                    OrbHarnessTransfer.stopSource(core, base)
                                }
                                if (transferRequest == null) {
                                    val req = mutableMapOf<String, Any?>(
                                        "backend" to targetBackend,
                                        "model_override" to selectedModel,
                                        "idempotency_key" to transferKey
                                    )
                                    if (isCloudHandoffSheet && selectedNodeId.isNotEmpty() && selectedNodeId != "core") {
                                        req["remote_node_id"] = selectedNodeId
                                    }
                                    if (isCloudHandoffSheet && selectedWorkspaceId.isNotEmpty()) {
                                        req["workspace_id"] = selectedWorkspaceId
                                    }
                                    transferRequest = req
                                }
                                val value = OrbJSON.dict(core.request("$base/fork", method = "POST", body = transferRequest)) ?: throw OrbError("Transfer response unavailable. Retry to recover it.")
                                next = OrbRow(value)
                                transferredMission = next
                            }
                            if (!isCloudHandoffSheet) {
                                core.request("$base/status", method = "POST", body = mapOf("status" to "acknowledged"))
                            }
                            showAgentPicker = false
                            currentMission = next
                            core.refreshMissionsQuietly()
                        } catch (e: Exception) {
                            errorMessage = (if (transferredMission != null) "The new agent is ready, but the original could not be archived. " else "") + (e.message ?: "Transfer failed. Retry.")
                        } finally { isSending = false }
                    }
                }
            }) else null,
            onDismiss = {
                if (!isSending) {
                    showAgentPicker = false
                    currentMission?.id?.let { persistMissionModelIfNeeded(it) }
                }
            }
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

    fileRef?.let { ref ->
        OrbFileViewerSheet(core = core, ref = ref, scope = fileScope, onDismiss = { fileRef = null })
    }
    if (showFiles) {
        OrbFilesSheet(core = core, scope = fileScope, onDismiss = { showFiles = false })
    }

    if (showRenameDialog && missionId != null) {
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Rename conversation", fontWeight = FontWeight.SemiBold) },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    if (renameDraft.isEmpty()) {
                        Text("Title", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
                    BasicTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val next = renameDraft.trim()
                    showRenameDialog = false
                    if (next.isNotEmpty()) {
                        scope.launch {
                            orbTry(OrbLog.Category.Network, "/api/control/missions") {
                                core.request(
                                    path = "/api/control/missions/${core.encodeComponent(missionId)}/title",
                                    method = "POST",
                                    body = mapOf("title" to next)
                                )
                                currentMission?.let { cur ->
                                    currentMission = OrbRow(cur.id, cur.raw.toMutableMap().apply { put("title", next) })
                                }
                                core.refreshMissionsQuietly()
                            }.onFailure { errorMessage = it.message ?: "Couldn’t rename the conversation." }
                        }
                    }
                }) {
                    Text("Save", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
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
    val presentation = remember(turn.text) { OrbMessagePresentation.parse(turn.text) }
    val parsed = remember(presentation.text) {
        val trimmed = presentation.text.trim()
        val strippedMode = when {
            trimmed.startsWith("[MODE: GOAL]") -> trimmed.removePrefix("[MODE: GOAL]").trim()
            trimmed.startsWith("[MODE: PLAN]") -> trimmed.removePrefix("[MODE: PLAN]").trim()
            trimmed.lowercase().startsWith("/goal ") -> trimmed.drop(6).trim()
            trimmed.lowercase().startsWith("/plan ") -> trimmed.drop(6).trim()
            else -> presentation.text
        }
        OrbUserPromptParser.parse(strippedMode)
    }
    val modeBadge = remember(presentation.text) {
        val trimmed = presentation.text.trim()
        when {
            trimmed.startsWith("[MODE: GOAL]") || trimmed.lowercase().startsWith("/goal ") || trimmed.equals("/goal", ignoreCase = true) -> "Goal"
            trimmed.startsWith("[MODE: PLAN]") || trimmed.lowercase().startsWith("/plan ") || trimmed.equals("/plan", ignoreCase = true) -> "Plan"
            else -> null
        }
    }
    val skillNames = remember(parsed.body) { OrbSkillSlash.skillTokens(parsed.body).map { it.name }.distinct() }
    val visibleBody = remember(parsed.body) { OrbSkillSlash.skillPreview(parsed.body) }

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
            if (modeBadge != null || skillNames.isNotEmpty() || presentation.attached) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
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
                    skillNames.forEach { name ->
                        Text(
                            text = "/$name",
                            color = OrbStyle.textSecondary,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            softWrap = false,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(OrbStyle.elevated)
                                .padding(horizontal = 7.dp, vertical = 2.dp)
                        )
                    }
                    if (presentation.attached) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.AttachFile,
                                contentDescription = null,
                                tint = OrbStyle.textSecondary,
                                modifier = Modifier.size(11.dp)
                            )
                            Text(
                                text = "Attached context",
                                color = OrbStyle.textSecondary,
                                fontSize = 11.sp,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                }
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
            if (visibleBody.isNotEmpty()) {
                Text(
                    text = visibleBody,
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
                    OrbMarkdownWithFiles(seg.text, streaming = turn.isStreaming)
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
    onPreviewFile: (String) -> Unit,
    onForceSlot: (() -> Unit)? = null,
    forceSlotPending: Boolean = false
) {
    var expanded by remember { mutableStateOf(false) }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val workingOverride = LocalOrbWorkingLabel.current

    LaunchedEffect(fold.isLive) {
        while (fold.isLive && isActive) {
            nowMs = System.currentTimeMillis()
            delay(1000L)
        }
    }

    val summary = remember(fold.steps, fold.isLive, workingOverride) {
        if (fold.isLive) {
            workingOverride ?: fold.steps.lastOrNull()?.title ?: "Working…"
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
        if (expanded && (fold.steps.isNotEmpty() || fold.narration.isNotEmpty())) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp)
            ) {
                fold.narration.forEach { note ->
                    OrbRichText(markdown = note, tone = OrbRichTextTone.Secondary)
                }
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
                .orbPressClickable(enabled = fold.steps.isNotEmpty() || fold.narration.isNotEmpty()) { expanded = !expanded }
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
            if (fold.isLive && onForceSlot != null) {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.08f))
                        .border(1.dp, OrbStyle.borderStrong, CircleShape)
                        .orbPressClickable(enabled = !forceSlotPending, onClick = onForceSlot)
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                        .testTag("force-slot-run-now"),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (forceSlotPending) "Starting…" else "Run now",
                        color = if (forceSlotPending) OrbStyle.textSecondary else Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        softWrap = false
                    )
                }
            }
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
        val liveNote = remember(fold.narration) { fold.narration.lastOrNull()?.let(OrbNarration::narrationLine) }
        if (fold.isLive && !expanded) {
            Text(
                text = liveNote?.takeIf { it.isNotEmpty() } ?: "\u00a0",
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth()
            )
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

/** Pure harness and model catalog projection for Android's agent picker; unit-tested. */
object OrbAgentCatalog {
    private val fallbackNames = mapOf(
        "claudecode" to "Claude Code",
        "codex" to "Codex",
        "grok" to "Grok",
        "opencode" to "OpenCode",
        "antigravity" to "Antigravity CLI",
        "vibe" to "Mistral Vibe",
        "hermes" to "Hermes",
        "cursor_cloud" to "Cursor Cloud",
        "grok_bot" to "Grok Bot",
    )

    data class ModelChoice(val value: String, val label: String)

    fun backendOptions(backends: List<OrbRow>, existing: Boolean): List<String> {
        val fromServer = backends
            .mapNotNull { it.str("id", "slug", "name") }
            .filter { it != "gemini" }
        return if (existing) fromServer.distinct() else (fromServer + listOf("hermes", "cursor_cloud", "grok_bot")).distinct()
    }

    fun backendLabel(id: String, backends: List<OrbRow>): String =
        fallbackNames[id]
            ?: backends.firstOrNull { (it.str("id", "slug") ?: it.id) == id }?.str("name")
            ?: id

    fun modelsForBackend(backend: String, backendModels: OrbDict): List<ModelChoice> {
        val raw = backendModels["backends"]?.let { OrbJSON.dict(it) } ?: backendModels
        return OrbJSON.dictList(raw[backend]).mapNotNull { item ->
            val value = OrbJSON.str(item, "value", "id") ?: return@mapNotNull null
            val label = OrbJSON.str(item, "label", "displayName", "name") ?: value
            ModelChoice(value = value, label = label)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbAgentPickerSheet(
    backends: List<OrbRow>,
    backendModels: OrbDict = emptyMap(),
    workspaces: List<OrbRow>,
    nodes: List<OrbRow> = emptyList(),
    managedCatalog: ManagedMachinesResponse? = null,
    providers: List<OrbRow>,
    repositories: List<OrbRow>,
    selectedBackend: String,
    onSelectBackend: (String) -> Unit,
    selectedModel: String,
    onSelectModel: (String) -> Unit,
    cyberMode: OrbCyberMode = OrbCyberMode.Automatic,
    showCyber: Boolean = false,
    cyberRemote: Boolean = false,
    cyberSummary: String = "",
    cyberEnabled: Boolean = true,
    onSelectCyber: (OrbCyberMode) -> Unit = {},
    selectedWorkspaceId: String,
    onSelectWorkspaceId: (String) -> Unit,
    selectedNodeId: String = "",
    onSelectNodeId: (String, Boolean) -> Unit = { _, _ -> },
    selectedAccount: String,
    onSelectAccount: (String) -> Unit,
    selectedRepo: String,
    onSelectRepo: (String) -> Unit,
    selectedGitRef: String,
    onSelectGitRef: (String) -> Unit,
    selectedConfigProfile: String,
    onSelectConfigProfile: (String) -> Unit,
    existing: Boolean = false,
    cloudHandoff: Boolean = false,
    locked: Boolean = false,
    busy: Boolean = false,
    transferError: String? = null,
    onTransfer: (() -> Unit)? = null,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { !busy || it != androidx.compose.material3.SheetValue.Hidden })
    val isCloudService = selectedBackend in setOf("cursor_cloud", "grok_bot", "hermes")

    val backendOptions = remember(backends, existing, cloudHandoff) {
        OrbAgentCatalog.backendOptions(backends, existing || cloudHandoff)
    }
    val modelChoices = remember(selectedBackend, backendModels) {
        OrbAgentCatalog.modelsForBackend(selectedBackend, backendModels)
    }
    var workspaceQuery by remember { mutableStateOf("") }
    val managedOwners = remember(managedCatalog) {
        OrbManagedMachines.ownerByNodeId(managedCatalog?.machines.orEmpty())
    }
    val usableCloudProviders = remember(managedCatalog) {
        OrbManagedMachines.usableProviders(managedCatalog)
    }
    var expandedCloudProvider by remember {
        mutableStateOf(OrbManagedMachines.parseAutoManagedTarget(selectedNodeId)?.provider)
    }
    var pending24hPick by remember { mutableStateOf<Pair<ManagedProviderInfo, ManagedSize>?>(null) }

    val sortedNodes = remember(nodes) {
        OrbComputePlacement.sortedComputeNodes(nodes)
    }
    val filteredNodes = remember(sortedNodes, workspaceQuery) {
        val q = workspaceQuery.trim().lowercase()
        if (q.isEmpty()) {
            sortedNodes
        } else {
            sortedNodes.filter { node ->
                val nid = (node.str("id") ?: node.id).lowercase()
                val nName = (node.str("display_name", "name") ?: nid).lowercase()
                val nStatus = (node.str("status") ?: "online").lowercase()
                nid.contains(q) || nName.contains(q) || nStatus.contains(q) || "remote".contains(q)
            }
        }
    }
    val staticFilteredNodes = remember(filteredNodes) {
        filteredNodes.filter { !OrbManagedMachines.isManagedNode(it) }
    }
    val userManagedNodes = remember(filteredNodes, managedOwners) {
        filteredNodes.filter { OrbManagedMachines.isUserManagedNode(it, managedOwners) }
    }
    val agentManagedNodes = remember(filteredNodes, managedOwners) {
        filteredNodes.filter { OrbManagedMachines.isAgentSpawnedManagedNode(it, managedOwners) }
    }
    var agentVmsExpanded by remember {
        mutableStateOf(
            nodes.any {
                (it.str("id") ?: it.id) == selectedNodeId &&
                    OrbManagedMachines.isAgentSpawnedManagedNode(it, managedOwners)
            }
        )
    }
    val showCoreRow = remember(sortedNodes, usableCloudProviders, workspaceQuery) {
        val q = workspaceQuery.trim().lowercase()
        (sortedNodes.isNotEmpty() || usableCloudProviders.isNotEmpty()) &&
            (q.isEmpty() || "core".contains(q) || "host".contains(q))
    }
    val filteredWorkspaces = remember(workspaces, workspaceQuery, selectedWorkspaceId) {
        val q = workspaceQuery.trim().lowercase()
        val matching = if (q.isEmpty()) {
            workspaces
        } else {
            workspaces.filter { ws ->
                val wName = (ws.str("name", "title", "slug") ?: ws.id).lowercase()
                val wType = (ws.str("workspace_type", "type") ?: "host").lowercase()
                wName.contains(q) || wType.contains(q)
            }
        }
        if (selectedWorkspaceId.isEmpty() || q.isNotEmpty()) {
            matching
        } else {
            val selectedFirst = matching.filter { (it.str("id") ?: it.id) == selectedWorkspaceId }
            val others = matching.filterNot { (it.str("id") ?: it.id) == selectedWorkspaceId }
            selectedFirst + others
        }
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
                .heightIn(max = 640.dp)
                .navigationBarsPadding()
                .imePadding()
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

            if (onTransfer != null) {
                Text(
                    if (cloudHandoff) "Starts a workspace agent with this cloud conversation's history on the selected machine."
                    else "Continues with the selected agent and history in the same workspace, then archives the original.",
                    color = OrbStyle.textMuted
                )
                androidx.compose.material3.Button(onClick = onTransfer, enabled = !busy && selectedBackend.isNotEmpty() && (!cloudHandoff || !isCloudService)) {
                    Text(
                        if (busy) (if (cloudHandoff) "Handing off…" else "Transferring…")
                        else if (locked) (if (cloudHandoff) "Retry handoff" else "Retry transfer")
                        else if (cloudHandoff) "Continue in workspace"
                        else "Transfer conversation"
                    )
                }
                if (!transferError.isNullOrEmpty()) Text(transferError, color = OrbStyle.textMuted)
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
                val harnessScrollState = rememberScrollState()
                val showRightFade = harnessScrollState.canScrollForward
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .drawWithContent {
                            drawContent()
                            if (showRightFade) {
                                val fadeWidth = 28.dp.toPx()
                                drawRect(
                                    brush = Brush.horizontalGradient(
                                        colors = listOf(Color.Transparent, OrbStyle.background),
                                        startX = size.width - fadeWidth,
                                        endX = size.width
                                    ),
                                    topLeft = Offset(size.width - fadeWidth, 0f),
                                    size = Size(fadeWidth, size.height)
                                )
                            }
                        }
                ) {
                    Row(
                        modifier = Modifier.horizontalScroll(harnessScrollState),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        backendOptions.forEach { b ->
                            val active = selectedBackend == b
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(if (active) Color.White else OrbStyle.surface)
                                    .border(1.dp, if (active) Color.Transparent else OrbStyle.border, CircleShape)
                                    .orbPressClickable { if (!locked) onSelectBackend(b) }
                                    .padding(horizontal = 13.dp, vertical = 8.dp)
                            ) {
                                Text(
                                    text = OrbAgentCatalog.backendLabel(b, backends),
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
            }

            // Machine / Workspace
            if ((!existing || cloudHandoff) && !isCloudService && (sortedNodes.isNotEmpty() || workspaces.isNotEmpty() || usableCloudProviders.isNotEmpty())) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "MACHINE / WORKSPACE",
                            color = OrbStyle.textMuted,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.7.sp,
                            modifier = Modifier.weight(1f)
                        )
                        val totalMachines = (if (sortedNodes.isNotEmpty() || usableCloudProviders.isNotEmpty()) 1 else 0) + sortedNodes.size + workspaces.size
                        val matchedMachines = (if (showCoreRow) 1 else 0) + filteredNodes.size + filteredWorkspaces.size
                        if (totalMachines > 6) {
                            Text(
                                text = "$matchedMachines/$totalMachines",
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                    }
                    if ((sortedNodes.size + workspaces.size) > 6) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                .padding(horizontal = 12.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Search,
                                contentDescription = null,
                                tint = OrbStyle.textMuted,
                                modifier = Modifier.size(15.dp)
                            )
                            Box(modifier = Modifier.weight(1f)) {
                                if (workspaceQuery.isEmpty()) {
                                    Text("Filter machines…", color = OrbStyle.textMuted, fontSize = 13.sp)
                                }
                                BasicTextField(
                                    value = workspaceQuery,
                                    onValueChange = { workspaceQuery = it },
                                    textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                                    cursorBrush = SolidColor(Color.White),
                                    singleLine = true,
                                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }
                            if (workspaceQuery.isNotEmpty()) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = "Clear filter",
                                    tint = OrbStyle.textMuted,
                                    modifier = Modifier
                                        .size(15.dp)
                                        .orbPressClickable { workspaceQuery = "" }
                                )
                            }
                        }
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                    ) {
                        val visibleStaticNodes = staticFilteredNodes
                        val hasBelowStatic = filteredWorkspaces.isNotEmpty() || userManagedNodes.isNotEmpty() || agentManagedNodes.isNotEmpty()
                        if (!showCoreRow && visibleStaticNodes.isEmpty() && !hasBelowStatic && usableCloudProviders.isEmpty()) {
                            Text(
                                text = "No matching workspaces",
                                color = OrbStyle.textMuted,
                                fontSize = 13.sp,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)
                            )
                        } else {
                            if (showCoreRow) {
                                val coreSelected = selectedWorkspaceId.isEmpty() && (selectedNodeId == "core" || selectedNodeId.isEmpty())
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable { if (!locked) onSelectNodeId("core", false) }
                                        .padding(horizontal = 14.dp, vertical = 11.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = "Core",
                                            color = Color.White,
                                            fontSize = 14.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        Text(
                                            text = "host",
                                            color = OrbStyle.textMuted,
                                            fontSize = 11.sp,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                    if (coreSelected) {
                                        Icon(
                                            imageVector = Icons.Default.Check,
                                            contentDescription = null,
                                            tint = Color.White,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }
                                }
                                if (visibleStaticNodes.isNotEmpty() || hasBelowStatic) {
                                    HorizontalDivider(color = OrbStyle.border)
                                }
                            }
                            visibleStaticNodes.forEachIndexed { idx, node ->
                                val nid = node.str("id") ?: node.id
                                val nName = node.str("name")?.takeIf { it.isNotEmpty() } ?: nid
                                val nStatus = node.str("status") ?: "online"
                                val selected = selectedWorkspaceId.isEmpty() && selectedNodeId == nid
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable { if (!locked) onSelectNodeId(nid, false) }
                                        .padding(horizontal = 14.dp, vertical = 11.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = nName,
                                            color = Color.White,
                                            fontSize = 14.sp,
                                            fontWeight = FontWeight.Medium,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        Text(
                                            text = "remote · $nStatus",
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
                                if (idx < visibleStaticNodes.size - 1 || hasBelowStatic) {
                                    HorizontalDivider(color = OrbStyle.border)
                                }
                            }
                            filteredWorkspaces.forEachIndexed { idx, ws ->
                                val wid = ws.str("id") ?: ws.id
                                val wName = ws.str("name", "title", "slug") ?: wid.take(8)
                                val wType = ws.str("workspace_type", "type") ?: "host"
                                val selected = selectedWorkspaceId == wid
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable { if (!locked) onSelectWorkspaceId(wid) }
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
                                if (idx < filteredWorkspaces.size - 1 || userManagedNodes.isNotEmpty() || agentManagedNodes.isNotEmpty()) {
                                    HorizontalDivider(color = OrbStyle.border)
                                }
                            }
                            if (userManagedNodes.isNotEmpty()) {
                                Text(
                                    text = "YOUR VMS",
                                    color = OrbStyle.textMuted,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    letterSpacing = 0.6.sp,
                                    modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 4.dp)
                                )
                                userManagedNodes.forEachIndexed { idx, node ->
                                    val nid = node.str("id") ?: node.id
                                    val nName = OrbManagedMachines.nodeTitle(nid, node)
                                    val nStatus = node.str("status") ?: "online"
                                    val provLabel = OrbManagedMachines.nodeProvider(OrbManagedMachines.nodeLabels(node))
                                        ?.let { OrbManagedMachines.providerLabel(it) }
                                    val selected = selectedWorkspaceId.isEmpty() && selectedNodeId == nid
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .orbPressClickable { if (!locked) onSelectNodeId(nid, false) }
                                            .padding(horizontal = 14.dp, vertical = 11.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                text = nName,
                                                color = Color.White,
                                                fontSize = 14.sp,
                                                fontWeight = FontWeight.Medium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Text(
                                                text = listOfNotNull(provLabel, nStatus).joinToString(" · "),
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
                                    if (idx < userManagedNodes.size - 1 || agentManagedNodes.isNotEmpty()) {
                                        HorizontalDivider(color = OrbStyle.border)
                                    }
                                }
                            }
                            if (agentManagedNodes.isNotEmpty()) {
                                val expanded = agentVmsExpanded || workspaceQuery.isNotBlank()
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable { agentVmsExpanded = !agentVmsExpanded }
                                        .padding(horizontal = 14.dp, vertical = 11.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text(
                                        text = "Agent-spawned VMs (${agentManagedNodes.size})",
                                        color = OrbStyle.textSecondary,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Icon(
                                        imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                        contentDescription = null,
                                        tint = OrbStyle.textMuted,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                                if (expanded) {
                                    HorizontalDivider(color = OrbStyle.border)
                                    agentManagedNodes.forEachIndexed { idx, node ->
                                        val nid = node.str("id") ?: node.id
                                        val nName = OrbManagedMachines.nodeTitle(nid, node)
                                        val nStatus = node.str("status") ?: "online"
                                        val provLabel = OrbManagedMachines.nodeProvider(OrbManagedMachines.nodeLabels(node))
                                            ?.let { OrbManagedMachines.providerLabel(it) }
                                        val selected = selectedWorkspaceId.isEmpty() && selectedNodeId == nid
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .orbPressClickable { if (!locked) onSelectNodeId(nid, false) }
                                                .padding(horizontal = 14.dp, vertical = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    text = nName,
                                                    color = Color.White,
                                                    fontSize = 14.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis
                                                )
                                                Text(
                                                    text = listOfNotNull(provLabel, nStatus).joinToString(" · "),
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
                                        if (idx < agentManagedNodes.size - 1) {
                                            HorizontalDivider(color = OrbStyle.border)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (usableCloudProviders.isNotEmpty() && workspaceQuery.isBlank()) {
                        Text(
                            text = "CLOUD VMS (START ON SEND)",
                            color = OrbStyle.textMuted,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 0.7.sp,
                            modifier = Modifier.padding(top = 6.dp)
                        )
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
                        ) {
                            val parsedAuto = OrbManagedMachines.parseAutoManagedTarget(selectedNodeId)
                            usableCloudProviders.forEachIndexed { pIdx, prov ->
                                val provKey = OrbManagedMachines.machineProviderKey(prov.provider)
                                val sizes = OrbManagedMachines.allowedSizes(prov.sizes, managedCatalog?.budget?.maxSize)
                                val isExpanded = expandedCloudProvider == provKey
                                val selectedSizeForProv = if (selectedWorkspaceId.isEmpty() && parsedAuto?.provider == provKey) parsedAuto.size else null
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedCloudProvider = if (isExpanded) null else provKey
                                        }
                                        .padding(horizontal = 14.dp, vertical = 11.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Cloud,
                                        contentDescription = null,
                                        tint = OrbStyle.textSecondary,
                                        modifier = Modifier.size(15.dp)
                                    )
                                    Text(
                                        text = OrbManagedMachines.providerDisplayLabel(prov.provider, usableCloudProviders),
                                        color = Color.White,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.weight(1f)
                                    )
                                    if (!selectedSizeForProv.isNullOrEmpty()) {
                                        Text(
                                            text = OrbManagedMachines.sizeLabel(selectedSizeForProv),
                                            color = OrbStyle.textSecondary,
                                            fontSize = 12.sp
                                        )
                                    }
                                    Icon(
                                        imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ChevronRight,
                                        contentDescription = null,
                                        tint = OrbStyle.textMuted,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                                if (isExpanded) {
                                    HorizontalDivider(color = OrbStyle.border)
                                    sizes.forEachIndexed { sIdx, s ->
                                        val target = OrbManagedMachines.formatAutoManagedTarget(prov.provider, s.size)
                                        val sizeSelected = selectedWorkspaceId.isEmpty() && selectedNodeId.equals(target, ignoreCase = true)
                                        val is24h = OrbManagedMachines.is24hCommitmentSize(s)
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .orbPressClickable {
                                                    if (!locked) {
                                                        if (is24h) {
                                                            pending24hPick = prov to s
                                                        } else {
                                                            onSelectNodeId(target, false)
                                                        }
                                                    }
                                                }
                                                .padding(start = 36.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                        ) {
                                            Column(modifier = Modifier.weight(1f)) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                                ) {
                                                    Text(
                                                        text = OrbManagedMachines.sizeLabel(s.size),
                                                        color = Color.White,
                                                        fontSize = 13.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                    if (is24h) {
                                                        Text(
                                                            text = "24h min",
                                                            color = OrbStyle.textSecondary,
                                                            fontSize = 10.sp,
                                                            fontWeight = FontWeight.SemiBold,
                                                            modifier = Modifier
                                                                .clip(CircleShape)
                                                                .background(OrbStyle.elevated)
                                                                .border(1.dp, OrbStyle.border, CircleShape)
                                                                .padding(horizontal = 6.dp, vertical = 2.dp)
                                                        )
                                                    }
                                                }
                                                Text(
                                                    text = OrbManagedMachines.compactSizeSpec(s),
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 11.sp
                                                )
                                            }
                                            Text(
                                                text = OrbManagedMachines.usdPerHour(s.usdPerHour),
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp,
                                                fontFamily = FontFamily.Monospace
                                            )
                                            if (sizeSelected) {
                                                Icon(
                                                    imageVector = Icons.Default.Check,
                                                    contentDescription = null,
                                                    tint = Color.White,
                                                    modifier = Modifier.size(15.dp)
                                                )
                                            }
                                        }
                                        if (sIdx < sizes.size - 1) {
                                            HorizontalDivider(color = OrbStyle.border)
                                        }
                                    }
                                }
                                if (pIdx < usableCloudProviders.size - 1) {
                                    HorizontalDivider(color = OrbStyle.border)
                                }
                            }
                        }
                    }
                }
            }

            if (showCyber) {
                Text("Cyber program", color = OrbStyle.textMuted, fontSize = 12.sp)
                Column(modifier = Modifier.fillMaxWidth()) {
                    OrbCyberMode.entries.forEach { mode ->
                        TextButton(enabled = !locked && cyberEnabled, onClick = { onSelectCyber(mode) }) {
                            Text("${if (mode == cyberMode) "✓ " else ""}${mode.label}", color = Color.White)
                        }
                    }
                    Text(cyberSummary, color = OrbStyle.textMuted, fontSize = 12.sp)
                    if (!cyberRemote || selectedModel.isNotBlank()) {
                        OrbCyberAccess.compatibility(cyberMode, selectedModel)?.let {
                            Text(it, color = OrbStyle.textMuted, fontSize = 12.sp)
                        }
                    }
                }
            }

            // Model override
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "MODEL (OPTIONAL)",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp
                )
                if (modelChoices.isNotEmpty()) {
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        val defaultActive = selectedModel.isEmpty()
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(if (defaultActive) Color.White else OrbStyle.surface)
                                .border(1.dp, if (defaultActive) Color.Transparent else OrbStyle.border, CircleShape)
                                .orbPressClickable { if (!locked) onSelectModel("") }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Text(
                                text = "Service default",
                                color = if (defaultActive) Color.Black else Color.White,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                        modelChoices.forEach { choice ->
                            val active = selectedModel == choice.value
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(if (active) Color.White else OrbStyle.surface)
                                    .border(1.dp, if (active) Color.Transparent else OrbStyle.border, CircleShape)
                                    .orbPressClickable { if (!locked) onSelectModel(choice.value) }
                                    .padding(horizontal = 12.dp, vertical = 7.dp)
                            ) {
                                Text(
                                    text = choice.label.substringAfterLast("—").trim(),
                                    color = if (active) Color.Black else Color.White,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false
                                )
                            }
                        }
                    }
                }
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
                            text = "Default model for ${OrbAgentCatalog.backendLabel(selectedBackend, backends)}",
                            color = OrbStyle.textMuted,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    BasicTextField(
                        value = selectedModel,
                        onValueChange = { if (!locked) onSelectModel(it) },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp, fontFamily = FontFamily.Monospace),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
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
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
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
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    pending24hPick?.let { (prov, size) ->
        val hours = size.minBillingHours ?: 24
        val minCost = OrbManagedMachines.usd(size.usdPerHour * hours)
        AlertDialog(
            onDismissRequest = { pending24hPick = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("24-hour minimum commitment", fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    text = "${OrbManagedMachines.providerDisplayLabel(prov.provider)} ${OrbManagedMachines.sizeLabel(size.size)} carries a $hours-hour minimum lease ($minCost total) once started on prompt send.",
                    color = OrbStyle.textSecondary,
                    fontSize = 14.sp
                )
            },
            dismissButton = {
                TextButton(onClick = { pending24hPick = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val target = OrbManagedMachines.formatAutoManagedTarget(prov.provider, size.size)
                    pending24hPick = null
                    onSelectNodeId(target, true)
                }) {
                    Text("Select ($minCost min)", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            }
        )
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

/** Overrides the live work row's label (e.g. "Sending…" during a Send now handoff). */
val LocalOrbWorkingLabel = androidx.compose.runtime.compositionLocalOf<String?> { null }

/** True when the user turned animations off (Settings > Accessibility > Remove animations). */
@Composable
fun orbReducedMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        android.provider.Settings.Global.getFloat(
            context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f
        ) == 0f
    }
}

/** Compact follow-up queue above the composer: one line per message, actions on the right. */
@Composable
fun OrbFollowUpQueueView(
    rows: List<OrbQueuedRow>,
    expanded: Boolean,
    onToggle: () -> Unit,
    editingId: String?,
    reducedMotion: Boolean,
    onEdit: (OrbQueuedRow) -> Unit,
    onSendNow: (OrbQueuedRow) -> Unit,
    onRemove: (OrbQueuedRow) -> Unit
) {
    // Rows that just left keep their slot for one short collapse (desktop LEAVE_MS).
    val shown = remember { mutableStateListOf<OrbQueuedRow>() }
    val visible = remember { androidx.compose.runtime.mutableStateMapOf<String, Boolean>() }
    LaunchedEffect(rows) {
        val ids = rows.map { it.id }.toSet()
        for (row in rows) {
            val i = shown.indexOfFirst { it.id == row.id }
            if (i >= 0) shown[i] = row else shown.add(row)
            visible[row.id] = true
        }
        for (row in shown.toList()) if (row.id !in ids) visible[row.id] = false
        // Keep Core's order for the rows still queued.
        val order = rows.withIndex().associate { it.value.id to it.index }
        val sorted = shown.sortedBy { order[it.id] ?: Int.MAX_VALUE }
        shown.clear(); shown.addAll(sorted)
        delay(if (reducedMotion) 0L else OrbSendFlow.LEAVE_MS.toLong() + 40)
        shown.removeAll { visible[it.id] == false }
        visible.keys.retainAll(shown.map { it.id }.toSet())
    }
    if (shown.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .then(if (reducedMotion) Modifier else Modifier.animateContentSize(animationSpec = androidx.compose.animation.core.tween<androidx.compose.ui.unit.IntSize>(OrbSendFlow.LEAVE_MS)))
            .then(Modifier.testTag("orb-followup-queue"))
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().orbPressClickable(onClick = onToggle).padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "${rows.size} Queued",
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            Icon(
                imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = if (expanded) "Hide queued messages" else "Show queued messages",
                tint = OrbStyle.textMuted,
                modifier = Modifier.size(14.dp)
            )
        }
        if (expanded) {
            for (row in shown) {
                androidx.compose.runtime.key(row.id) {
                    androidx.compose.animation.AnimatedVisibility(
                        visible = visible[row.id] != false,
                        enter = if (reducedMotion) androidx.compose.animation.EnterTransition.None
                        else androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(180)) +
                            androidx.compose.animation.expandVertically(androidx.compose.animation.core.tween(180)),
                        exit = if (reducedMotion) androidx.compose.animation.ExitTransition.None
                        else androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(OrbSendFlow.LEAVE_MS)) +
                            androidx.compose.animation.shrinkVertically(androidx.compose.animation.core.tween(OrbSendFlow.LEAVE_MS))
                    ) {
                        OrbFollowUpRow(
                            row = row,
                            editing = editingId == row.id,
                            actionsEnabled = !row.sending && editingId == null,
                            onEdit = { onEdit(row) },
                            onSendNow = { onSendNow(row) },
                            onRemove = { onRemove(row) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun OrbFollowUpRow(
    row: OrbQueuedRow,
    editing: Boolean,
    actionsEnabled: Boolean,
    onEdit: () -> Unit,
    onSendNow: () -> Unit,
    onRemove: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 32.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                text = OrbSkillSlash.skillPreview(OrbMessagePresentation.parse(row.content).text.trim()),
                color = if (editing) OrbStyle.textMuted else Color.White,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            // One geometry from "sending" to "confirmed": the action area is always reserved.
            if (editing) {
                Text("Editing", color = OrbStyle.textMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp))
            } else {
                OrbQueueAction(Icons.Default.Edit, "Edit queued message", actionsEnabled, onEdit)
                OrbQueueAction(Icons.Default.ArrowUpward, "Send now", actionsEnabled, onSendNow)
                OrbQueueAction(Icons.Default.DeleteOutline, "Remove queued message", !row.sending && !editing, onRemove)
            }
        }
        row.queueError?.let {
            Text("Delivery paused · $it", color = OrbStyle.warning, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun OrbQueueAction(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .orbPressClickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (enabled) OrbStyle.textSecondary else OrbStyle.textMuted.copy(alpha = 0.4f),
            modifier = Modifier.size(15.dp)
        )
    }
}
