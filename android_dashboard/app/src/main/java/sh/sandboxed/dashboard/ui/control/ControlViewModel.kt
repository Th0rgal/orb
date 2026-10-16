package sh.sandboxed.dashboard.ui.control

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import sh.sandboxed.dashboard.data.AppContainer
import sh.sandboxed.dashboard.data.BuiltinCommandsResponse
import sh.sandboxed.dashboard.data.ChatMessage
import sh.sandboxed.dashboard.data.ChatMessageKind
import sh.sandboxed.dashboard.data.CreateMissionRequest
import sh.sandboxed.dashboard.data.Mission
import sh.sandboxed.dashboard.data.MissionStatus
import sh.sandboxed.dashboard.data.QueuedMessage
import sh.sandboxed.dashboard.data.RunningMissionInfo
import sh.sandboxed.dashboard.data.SendState
import sh.sandboxed.dashboard.data.SharedFile
import sh.sandboxed.dashboard.data.api.HttpException
import sh.sandboxed.dashboard.data.SlashCommand
import sh.sandboxed.dashboard.data.SseEvent
import sh.sandboxed.dashboard.data.ToolUiParser
import java.util.UUID

data class NewMissionOptions(
    val workspaceId: String? = null,
    val agent: String? = null,
    val modelOverride: String? = null,
    val backend: String? = null,
)

data class ExecutionProgress(
    val total: Int,
    val completed: Int,
    val current: String? = null,
    val depth: Int = 0,
) {
    val displayText: String get() = "Subtask ${completed + 1}/$total"
}

enum class ControlRunState(val wireValue: String, val label: String) {
    IDLE("idle", "Idle"),
    RUNNING("running", "Running"),
    WAITING_FOR_TOOL("waiting_for_tool", "Waiting"),
    ;

    companion object {
        fun fromWire(value: String): ControlRunState =
            entries.firstOrNull { it.wireValue == value } ?: IDLE
    }
}

data class ControlState(
    val mission: Mission? = null,
    val parallel: List<RunningMissionInfo> = emptyList(),
    val maxParallel: Int = 1,
    val childMissions: List<Mission> = emptyList(),
    val recentMissions: List<Mission> = emptyList(),
    val messages: List<ChatMessage> = emptyList(),
    val queue: List<QueuedMessage> = emptyList(),
    val draft: String = "",
    val isSending: Boolean = false,
    val isConnected: Boolean = false,
    val error: String? = null,
    val goalStatus: String? = null,
    val runState: ControlRunState = ControlRunState.IDLE,
    val progress: ExecutionProgress? = null,
    val slashCommands: BuiltinCommandsResponse? = null,
    val slashCommandsLoading: Boolean = false,
    val desktopDisplay: String = ":101",
    val desktopOpenRequest: Long = 0,
    val loadingRecent: Boolean = false,
    /// True when the rendered conversation came from the on-disk cache because
    /// the server could not be reached. Cleared on the next successful fetch.
    val staleCache: Boolean = false,
    // Diagnostics (surfaced via the debug overlay on the Control screen).
    val transport: String = "sse",
    val eventsReceived: Long = 0,
    val lastEventSeq: Long? = null,
)

class ControlViewModel(private val container: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(ControlState())
    val state: StateFlow<ControlState> = _state.asStateFlow()

    private var streamJob: Job? = null
    private var pollJob: Job? = null
    private var slashCommandsJob: Job? = null
    @Volatile private var lastSeq: Long? = null
    private var foreground = true
    // Some deployments lack /api/control/parallel/config; remember the 404
    // instead of re-probing it on every poll tick.

    init {
        viewModelScope.launch {
            try {
                refreshMission()
                refreshRunning()
                refreshQueue()
            } catch (_: Throwable) {
                loadFromCache(container.cached.value.lastMissionId)
            }
            if (_state.value.mission == null) loadDraftFor(null)
            startStream()
            startRunningPoller()
        }
    }

    /// Lifecycle hook from the Control screen: tear down the event stream and
    /// pollers while the app is backgrounded, resume (with delta replay via
    /// lastSeq) when it comes back.
    fun setForeground(active: Boolean) {
        if (active == foreground) return
        foreground = active
        if (active) {
            startStream()
            startRunningPoller()
            viewModelScope.launch { runCatching { refreshQueue() } }
        } else {
            streamJob?.cancel()
            pollJob?.cancel()
            _state.update { it.copy(isConnected = false) }
        }
    }

    private fun loadDraftFor(missionId: String?) {
        val stored = container.cached.value.drafts[missionId.orEmpty()].orEmpty()
        _state.update { it.copy(draft = stored) }
    }

    /// Render the cached copy of a mission when the live fetch failed, flagged
    /// stale so the UI can show it isn't current.
    private suspend fun loadFromCache(missionId: String?) {
        val cached = missionId?.let { container.missionCache.load(it) } ?: return
        if (_state.value.messages.isNotEmpty()) return
        _state.update { it.copy(mission = cached, messages = mapHistory(cached), staleCache = true) }
    }

    fun setDraft(text: String) {
        _state.update { it.copy(draft = text) }
        viewModelScope.launch { container.settings.setDraft(_state.value.mission?.id, text) }
        if (text.trim().startsWith("/")) loadSlashCommandsIfNeeded()
    }

    fun applySlashCommand(command: SlashCommand) {
        setDraft("/${command.name} ")
    }

    /// Bridge from the Ask co-pilot: drop a co-pilot answer into the real
    /// composer, appending to any existing draft rather than replacing it.
    fun appendToComposer(text: String) {
        val addition = text.trim()
        if (addition.isEmpty()) return
        val current = _state.value.draft
        val next = if (current.isBlank()) addition else current.trimEnd() + "\n" + addition
        setDraft(next)
    }

    fun send() {
        val text = _state.value.draft.trim()
        if (text.isEmpty()) return
        val missionIdForDraft = _state.value.mission?.id
        val draftMsg = ChatMessage(kind = ChatMessageKind.User, content = text, sendState = SendState.PENDING)
        _state.update { it.copy(isSending = true, messages = it.messages + draftMsg, draft = "") }
        viewModelScope.launch { container.settings.setDraft(missionIdForDraft, "") }
        viewModelScope.launch { deliver(draftMsg.id, text) }
    }

    /// Retry a message whose send failed; reuses the original bubble.
    fun retrySend(messageId: String) {
        val msg = _state.value.messages.firstOrNull { it.id == messageId } ?: return
        if (msg.sendState != SendState.FAILED) return
        markSendState(messageId, SendState.PENDING)
        _state.update { it.copy(isSending = true) }
        viewModelScope.launch { deliver(messageId, msg.content) }
    }

    private suspend fun deliver(messageId: String, text: String) {
        runCatching {
            var missionId = _state.value.mission?.id
            if (missionId == null) {
                val s = container.cached.value
                val mission = container.api.createMission(CreateMissionRequest(
                    title = text.take(60),
                    agent = s.defaultAgent.takeIf { it.isNotBlank() },
                    backend = s.defaultBackend.takeIf { it.isNotBlank() },
                    modelOverride = s.defaultModel.takeIf { it.isNotBlank() },
                ))
                _state.update { it.copy(mission = mission, childMissions = emptyList(), progress = null) }
                container.settings.setLastMission(mission.id)
                missionId = mission.id
            }
            // mission_id pins the send to the conversation on screen;
            // client_message_id lets the server dedupe retries.
            container.api.sendMessage(text, missionId = missionId, clientMessageId = messageId)
            refreshQueue()
        }.onSuccess {
            markSendState(messageId, SendState.SENT)
        }.onFailure { e ->
            markSendState(messageId, SendState.FAILED)
            _state.update { it.copy(error = e.message) }
        }
        _state.update { it.copy(isSending = false) }
    }

    private fun markSendState(id: String, sendState: SendState) {
        _state.update { st ->
            st.copy(messages = st.messages.map { if (it.id == id) it.copy(sendState = sendState) else it })
        }
    }

    /// Resolve a `user_message` event by id. The optimistic bubble already
    /// uses `client_message_id` as its id, so a live echo confirms it instead
    /// of duplicating; a failed bubble whose POST actually reached the server
    /// is healed to SENT when the echo arrives.
    private fun confirmUserMessage(id: String, content: String) {
        _state.update { st ->
            val idx = st.messages.indexOfFirst { it.id == id }
            if (idx >= 0) {
                st.copy(
                    messages = st.messages.mapIndexed { i, m ->
                        if (i == idx) m.copy(content = content, sendState = SendState.SENT) else m
                    },
                )
            } else {
                st.copy(messages = st.messages + ChatMessage(id = id, kind = ChatMessageKind.User, content = content))
            }
        }
    }

    /// Send the current draft as a parallel (child) mission instead of a turn
    /// in the current conversation. The backend spawns a worker mission that
    /// shows up in the running bar and the workers dialog.
    fun sendParallel() {
        val text = _state.value.draft.trim()
        val mission = _state.value.mission ?: return
        if (text.isEmpty()) return
        _state.update { it.copy(draft = "") }
        viewModelScope.launch {
            container.settings.setDraft(mission.id, "")
            val model = container.cached.value.defaultModel.takeIf { it.isNotBlank() }
            runCatching { container.api.parallelSend(mission.id, text, model) }
                .onSuccess { runCatching { refreshRunning() } }
                .onFailure { e -> _state.update { it.copy(error = e.message) } }
        }
    }

    fun cancel() { viewModelScope.launch { runCatching { container.api.cancelControl() } } }
    fun resume() {
        val id = _state.value.mission?.id ?: return
        resumeMission(id)
    }
    fun resumeMission(id: String) {
        viewModelScope.launch {
            runCatching { container.api.resumeMission(id) }
                .onSuccess { if (id == _state.value.mission?.id) _state.update { st -> st.copy(mission = it) } }
            loadRecentMissions()
            runCatching { refreshRunning() }
        }
    }
    fun cancelMission(id: String) {
        viewModelScope.launch {
            runCatching { container.api.cancelMission(id) }
            loadRecentMissions()
            runCatching { refreshRunning() }
        }
    }
    fun deleteMission(id: String) {
        viewModelScope.launch {
            runCatching { container.api.deleteMission(id) }
            _state.update { st ->
                st.copy(
                    recentMissions = st.recentMissions.filterNot { it.id == id },
                    childMissions = st.childMissions.filterNot { it.id == id },
                    parallel = st.parallel.filterNot { it.missionId == id },
                )
            }
        }
    }
    fun createMission(options: NewMissionOptions = NewMissionOptions()) {
        viewModelScope.launch {
            runCatching {
                container.api.createMission(
                    CreateMissionRequest(
                        workspaceId = options.workspaceId,
                        agent = options.agent,
                        modelOverride = options.modelOverride,
                        backend = options.backend,
                    )
                )
            }.onSuccess { mission ->
                lastSeq = null
                _state.update { it.copy(mission = mission, messages = emptyList(), childMissions = emptyList(), goalStatus = null, progress = null) }
                container.settings.setLastMission(mission.id)
                loadDraftFor(mission.id)
                runCatching { refreshRunning() }
            }.onFailure { e ->
                _state.update { it.copy(error = e.message) }
            }
        }
    }
    fun createFollowUpMission(source: Mission) {
        viewModelScope.launch {
            runCatching {
                container.api.createMission(
                    CreateMissionRequest(
                        workspaceId = source.workspaceId,
                        agent = source.agent,
                        modelOverride = source.modelOverride,
                        backend = source.backend,
                    )
                )
            }.onSuccess { mission ->
                val title = source.title?.trim().takeUnless { it.isNullOrEmpty() }
                    ?: source.shortDescription?.trim().takeUnless { it.isNullOrEmpty() }
                val prompt = if (title.isNullOrEmpty()) {
                    "Follow up on this mission with the next concrete implementation steps."
                } else {
                    "Follow up on \"$title\" and implement the next concrete steps."
                }
                lastSeq = null
                _state.update {
                    it.copy(
                        mission = mission,
                        messages = emptyList(),
                        childMissions = emptyList(),
                        draft = prompt,
                        goalStatus = null,
                        progress = null,
                    )
                }
                container.settings.setLastMission(mission.id)
                container.settings.setDraft(mission.id, prompt)
                runCatching { refreshRunning() }
            }.onFailure { e ->
                _state.update { it.copy(error = e.message) }
            }
        }
    }
    fun deleteQueueItem(id: String) {
        viewModelScope.launch { runCatching { container.api.deleteQueueItem(id); refreshQueue() } }
    }
    fun clearQueue() {
        viewModelScope.launch { runCatching { container.api.clearQueue(); refreshQueue() } }
    }

    fun switchMission(missionId: String) {
        viewModelScope.launch {
            runCatching {
                val mission = container.api.loadMission(missionId)
                container.missionCache.save(mission)
                _state.update { it.copy(mission = mission, messages = emptyList(), goalStatus = null, progress = null, staleCache = false) }
                container.settings.setLastMission(mission.id)
                lastSeq = null
                if (!hydrateFromEvents(mission.id)) {
                    _state.update { it.copy(messages = mapHistory(mission)) }
                    runCatching {
                        val (_, max) = container.api.missionEvents(mission.id, latest = true, limit = 1)
                        lastSeq = max
                    }
                }
                refreshChildMissions(mission.id)
                loadDraftFor(mission.id)
            }.onFailure {
                loadFromCache(missionId)
            }
        }
    }

    /// Rebuild the conversation from the stored event log instead of
    /// `mission.history`, which only keeps user/assistant text and drops tool
    /// calls, thinking, costs, and shared files. Loads the most recent window
    /// of events in ascending order, then sets the replay cursor.
    private suspend fun hydrateFromEvents(missionId: String): Boolean = runCatching {
        val (_, maxSeq) = container.api.missionEvents(missionId, latest = true, limit = 1)
        val events = if (maxSeq != null && maxSeq > 0) {
            container.api.missionEvents(missionId, beforeSeq = maxSeq + 1, limit = 300).first
        } else {
            emptyList()
        }
        if (_state.value.mission?.id != missionId) return@runCatching true
        _state.update { it.copy(messages = emptyList()) }
        events.forEach { handle(storedEventToSse(it), live = false) }
        lastSeq = maxSeq
        _state.update { it.copy(lastEventSeq = maxSeq) }
        true
    }.getOrDefault(false)

    fun loadRecentMissions() {
        viewModelScope.launch {
            _state.update { it.copy(loadingRecent = true) }
            runCatching { container.api.listMissions(limit = 200) }
                .onSuccess { missions ->
                    _state.update {
                        it.copy(
                            recentMissions = missions.sortedByDescending { m -> m.updatedAt },
                            loadingRecent = false,
                        )
                    }
                }
                .onFailure { e -> _state.update { it.copy(error = e.message, loadingRecent = false) } }
        }
    }

    private suspend fun refreshMission() {
        val cur = container.api.currentMission() ?: return
        container.missionCache.save(cur)
        _state.update {
            it.copy(
                mission = cur,
                messages = emptyList(),
                progress = null,
                staleCache = false,
            )
        }
        if (!hydrateFromEvents(cur.id)) {
            _state.update { it.copy(messages = mapHistory(cur)) }
            // Fetch event seq high-water-mark for delta resume on stream reconnect
            runCatching {
                val (_, max) = container.api.missionEvents(cur.id, latest = true, limit = 1)
                lastSeq = max
            }
        }
        refreshChildMissions(cur.id)
        loadDraftFor(cur.id)
    }

    private fun loadSlashCommandsIfNeeded() {
        if (_state.value.slashCommands != null || _state.value.slashCommandsLoading || slashCommandsJob?.isActive == true) return
        slashCommandsJob = viewModelScope.launch {
            _state.update { it.copy(slashCommandsLoading = true) }
            runCatching { container.api.listBuiltinCommands() }
                .onSuccess { commands -> _state.update { it.copy(slashCommands = commands, slashCommandsLoading = false) } }
                .onFailure { _state.update { it.copy(slashCommandsLoading = false) } }
        }
    }

    private suspend fun refreshQueue() {
        runCatching { container.api.getQueue() }.onSuccess { q -> _state.update { it.copy(queue = q) } }
    }

    private fun startStream() {
        streamJob?.cancel()
        streamJob = viewModelScope.launch {
            var attempt = 0
            // SSE is the primary transport; after two consecutive SSE failures
            // fall back to the WebSocket stream (some proxies buffer or kill
            // long-lived SSE responses), then keep alternating.
            var useWs = false
            while (true) {
                try {
                    // Replay any events we missed since last seq before opening live stream.
                    val mid = _state.value.mission?.id
                    val sinceSeq = lastSeq
                    if (mid != null && sinceSeq != null) {
                        runCatching {
                            val (events, max) = container.api.missionEvents(mid, sinceSeq = sinceSeq, limit = 200)
                            events.forEach { ev ->
                                handle(storedEventToSse(ev), live = false)
                            }
                            if (max != null) {
                                lastSeq = max
                                _state.update { it.copy(lastEventSeq = max) }
                            }
                        }
                    }

                    _state.update { it.copy(transport = if (useWs) "ws" else "sse") }
                    val flow = if (useWs) container.controlWs.stream() else container.sse.stream()
                    flow
                        .catch { e -> _state.update { it.copy(isConnected = false, error = e.message) } }
                        .collect { evt ->
                            attempt = 0
                            // Back online: drop the stale-cache flag and re-sync
                            // the conversation we were showing from disk.
                            val wasStale = _state.value.staleCache
                            _state.update { it.copy(isConnected = true, error = null, eventsReceived = it.eventsReceived + 1, staleCache = false) }
                            if (wasStale) viewModelScope.launch { runCatching { refreshMission() } }
                            handle(evt, live = true)
                        }
                } catch (_: Throwable) {
                    _state.update { it.copy(isConnected = false) }
                }
                attempt += 1
                if (attempt >= 2) useWs = !useWs
                val backoff = (1000L shl minOf(attempt, 5)).coerceAtMost(30_000L)
                delay(backoff)
            }
        }
    }

    private fun startRunningPoller() {
        pollJob?.cancel()
        pollJob = viewModelScope.launch {
            while (true) {
                runCatching { refreshRunning() }
                delay(3_000)
            }
        }
    }

    private suspend fun refreshRunning() {
        val running = container.api.running()
        _state.update { it.copy(parallel = running) }
        // Only refetch the (large) mission list for child workers when the
        // current mission plausibly has any — mirrors the iOS fix for the
        // same every-3s no-op fetch.
        val mid = _state.value.mission?.id ?: return
        if (_state.value.childMissions.isNotEmpty() || running.any { it.missionId == mid }) {
            refreshChildMissions(mid)
        }
    }

    private fun handle(evt: SseEvent, live: Boolean) {
        val obj = (evt.data as? JsonObject) ?: return
        fun s(k: String): String? = obj[k]?.jsonPrimitive?.content
        fun b(k: String): Boolean? = obj[k]?.jsonPrimitive?.booleanOrNull
        fun i(k: String): Int? = obj[k]?.jsonPrimitive?.intOrNull
        val eventMissionId = s("mission_id")
        val currentMissionId = _state.value.mission?.id
        val isMissionLevelEvent = evt.type == "status" ||
            evt.type == "mission_status_changed" ||
            evt.type == "mission_title_changed" ||
            evt.type == "mission_metadata_updated"
        if (!isMissionLevelEvent && eventMissionId != null && eventMissionId != currentMissionId) return

        when (evt.type) {
            "user_message" -> {
                val content = s("content") ?: return
                val id = s("id")
                if (id != null) {
                    confirmUserMessage(id, content)
                } else {
                    appendMessage(ChatMessage(kind = ChatMessageKind.User, content = content))
                }
            }
            "assistant_message" -> {
                val content = s("content") ?: return
                val cost = i("cost_cents") ?: 0
                val source = s("cost_source") ?: "actual"
                val model = s("model")
                val files = parseSharedFiles(obj["shared_files"])
                val msg = ChatMessage(
                    kind = ChatMessageKind.Assistant(costCents = cost, costSource = source, model = model, sharedFiles = files),
                    content = content,
                )
                // The final assistant_message finalizes the bubble that
                // text_delta has been streaming into (and some flows emit the
                // same assistant_message twice) — replace instead of stacking
                // a duplicate.
                _state.update { st ->
                    val msgs = st.messages.toMutableList()
                    val last = msgs.lastOrNull()
                    val finalizesLast = last?.kind is ChatMessageKind.Assistant &&
                        (last.content == content || content.startsWith(last.content) || last.content.startsWith(content))
                    if (finalizesLast) msgs[msgs.lastIndex] = msg else msgs += msg
                    st.copy(messages = msgs)
                }
            }
            "text_delta" -> { val content = s("content") ?: return; setStreamingAssistant(content) }
            "thinking" -> {
                val text = s("content") ?: ""
                val done = b("done") == true
                upsertThinking(text, done)
            }
            "agent_phase" -> {
                val phase = s("phase") ?: return
                appendMessage(ChatMessage(kind = ChatMessageKind.Phase(phase, s("detail"), s("agent")), content = ""))
            }
            "tool_call" -> {
                val name = s("name") ?: return
                val args = obj["args"]
                val toolUi = ToolUiParser.parse(name, args)
                if (toolUi !is sh.sandboxed.dashboard.data.ToolUiContent.Unknown) {
                    appendMessage(ChatMessage(kind = ChatMessageKind.ToolUi(name, toolUi), content = ""))
                } else {
                    appendMessage(ChatMessage(kind = ChatMessageKind.ToolCall(name, true), content = args.displayText()))
                }
            }
            "tool_result" -> {
                val name = s("name") ?: ""
                val isError = b("is_error") == true
                parseDesktopDisplay(name, obj["result"])?.let { display ->
                    _state.update {
                        it.copy(
                            desktopDisplay = display,
                            desktopOpenRequest = if (live) it.desktopOpenRequest + 1 else it.desktopOpenRequest,
                        )
                    }
                }
                appendMessage(ChatMessage(
                    kind = if (isError) ChatMessageKind.ErrorMsg else ChatMessageKind.ToolCall(name, false),
                    content = obj["result"].displayText(),
                ))
            }
            "tool_ui" -> {
                val name = s("name") ?: "ui"
                val content = ToolUiParser.parse(name, obj["args"])
                appendMessage(ChatMessage(kind = ChatMessageKind.ToolUi(name, content), content = ""))
            }
            "goal_iteration" -> {
                val iter = i("iteration") ?: 0
                val status = s("status") ?: ""
                val obj0 = s("objective") ?: ""
                appendMessage(ChatMessage(kind = ChatMessageKind.Goal(iter, status, obj0), content = ""))
            }
            "goal_status" -> _state.update { it.copy(goalStatus = s("status")) }
            "progress" -> {
                val total = i("total_subtasks") ?: 0
                val completed = i("completed_subtasks") ?: 0
                val current = s("current_subtask")
                val depth = i("depth") ?: i("current_depth") ?: 0
                if (total > 0) {
                    _state.update {
                        it.copy(progress = ExecutionProgress(total = total, completed = completed, current = current, depth = depth))
                    }
                }
            }
            "mission_status_changed" -> {
                val status = s("status") ?: return
                val parsed = parseStatus(status)
                _state.update { st ->
                    val appliesToCurrent = eventMissionId == null || st.mission?.id == eventMissionId
                    st.copy(
                        mission = st.mission?.let { if (appliesToCurrent) it.copy(status = parsed) else it },
                        recentMissions = st.recentMissions.map { if (it.id == eventMissionId) it.copy(status = parsed) else it },
                        childMissions = st.childMissions.map { if (it.id == eventMissionId) it.copy(status = parsed) else it },
                        progress = if (appliesToCurrent && parsed != MissionStatus.ACTIVE && parsed != MissionStatus.PENDING) {
                            null
                        } else {
                            st.progress
                        },
                    )
                }
                viewModelScope.launch { runCatching { refreshRunning() } }
            }
            "mission_title_changed" -> {
                val t = s("title") ?: return
                _state.update { st ->
                    val appliesToCurrent = eventMissionId == null || st.mission?.id == eventMissionId
                    st.copy(
                        mission = st.mission?.let { if (appliesToCurrent) it.copy(title = t) else it },
                        recentMissions = st.recentMissions.map { if (it.id == eventMissionId) it.copy(title = t) else it },
                        childMissions = st.childMissions.map { if (it.id == eventMissionId) it.copy(title = t) else it },
                    )
                }
                if (live) viewModelScope.launch { runCatching { refreshRunning() } }
            }
            "mission_metadata_updated" -> {
                val id = s("mission_id") ?: return
                applyMissionMetadataUpdate(id, obj)
                if (live) viewModelScope.launch { runCatching { refreshRunning() } }
            }
            "status" -> {
                if (eventMissionId != null && eventMissionId != _state.value.mission?.id) return
                val runState = s("state")?.let { ControlRunState.fromWire(it) }
                val queueLen = i("queue_len")
                val shouldRefreshQueue = live && queueLen != null && queueLen > 0 && queueLen != _state.value.queue.size
                _state.update { st ->
                    st.copy(
                        runState = runState ?: st.runState,
                        queue = if (queueLen == 0) emptyList() else st.queue,
                        progress = if (runState == ControlRunState.IDLE) null else st.progress,
                    )
                }
                if (shouldRefreshQueue) viewModelScope.launch { runCatching { refreshQueue() } }
            }
            "error" -> _state.update { it.copy(error = s("message")) }
        }
    }

    private fun parseSharedFiles(el: JsonElement?): List<SharedFile> {
        val arr = el as? JsonArray ?: return emptyList()
        return arr.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            SharedFile(
                name = o["name"]?.jsonPrimitive?.content.orEmpty(),
                url = o["url"]?.jsonPrimitive?.content.orEmpty(),
                contentType = o["content_type"]?.jsonPrimitive?.content.orEmpty(),
                sizeBytes = o["size_bytes"]?.jsonPrimitive?.content?.toLongOrNull(),
            )
        }
    }

    private fun parseStatus(s: String): MissionStatus = runCatching {
        MissionStatus.valueOf(s.uppercase())
    }.getOrDefault(MissionStatus.UNKNOWN)

    private fun mapHistory(mission: Mission): List<ChatMessage> =
        mission.history.map { entry ->
            ChatMessage(
                kind = if (entry.role == "user") ChatMessageKind.User else ChatMessageKind.Assistant(),
                content = entry.content,
            )
        }

    private suspend fun refreshChildMissions(parentId: String) {
        runCatching { container.api.childMissions(parentId) }
            .onSuccess { workers ->
                if (_state.value.mission?.id == parentId) {
                    _state.update { it.copy(childMissions = workers) }
                }
            }
    }

    private fun parseDesktopDisplay(name: String, result: JsonElement?): String? {
        if (!name.contains("desktop_start_session")) return null
        val obj = when (result) {
            is JsonObject -> result
            is JsonPrimitive -> runCatching {
                sh.sandboxed.dashboard.data.api.Net.json.parseToJsonElement(result.content) as? JsonObject
            }.getOrNull()
            else -> null
        }
        return obj?.get("display")?.jsonPrimitive?.content
    }

    private fun appendMessage(m: ChatMessage) { _state.update { it.copy(messages = it.messages + m) } }

    private fun applyMissionMetadataUpdate(missionId: String, obj: JsonObject) {
        _state.update { st ->
            st.copy(
                mission = st.mission?.let { if (it.id == missionId) mergeMissionMetadata(it, obj) else it },
                recentMissions = st.recentMissions.map { if (it.id == missionId) mergeMissionMetadata(it, obj) else it },
                childMissions = st.childMissions.map { if (it.id == missionId) mergeMissionMetadata(it, obj) else it },
            )
        }
    }

    private fun mergeMissionMetadata(mission: Mission, obj: JsonObject): Mission =
        mission.copy(
            title = stringField(obj, "title", mission.title),
            shortDescription = stringField(obj, "short_description", mission.shortDescription),
            metadataUpdatedAt = stringField(obj, "metadata_updated_at", mission.metadataUpdatedAt),
            updatedAt = stringField(obj, "updated_at", mission.updatedAt) ?: mission.updatedAt,
            metadataSource = stringField(obj, "metadata_source", mission.metadataSource),
            metadataModel = stringField(obj, "metadata_model", mission.metadataModel),
            metadataVersion = stringField(obj, "metadata_version", mission.metadataVersion),
        )

    private fun stringField(obj: JsonObject, key: String, fallback: String?): String? =
        if (obj.containsKey(key)) obj[key]?.jsonPrimitive?.contentOrNull else fallback

    private fun storedEventToSse(ev: sh.sandboxed.dashboard.data.StoredEvent): SseEvent {
        val data = ev.metadata.toMutableMap()
        data["mission_id"] = JsonPrimitive(ev.missionId)
        if (ev.content.isNotBlank()) data["content"] = JsonPrimitive(ev.content)
        ev.eventId?.let { data["id"] = JsonPrimitive(it) }
        ev.toolCallId?.let { data["tool_call_id"] = JsonPrimitive(it) }
        ev.toolName?.let { data["name"] = JsonPrimitive(it) }
        when (ev.eventType) {
            "tool_call" -> data["args"] = parseJsonOrString(ev.content)
            "tool_result" -> data["result"] = parseJsonOrString(ev.content)
        }
        return SseEvent(ev.eventType, JsonObject(data))
    }

    private fun parseJsonOrString(value: String): JsonElement =
        runCatching { sh.sandboxed.dashboard.data.api.Net.json.parseToJsonElement(value) }
            .getOrElse { JsonPrimitive(value) }

    private fun JsonElement?.displayText(): String = when (this) {
        null -> ""
        is JsonPrimitive -> content
        else -> toString()
    }

    private fun setStreamingAssistant(content: String) {
        _state.update { st ->
            val msgs = st.messages.toMutableList()
            val last = msgs.lastOrNull()
            if (last?.kind is ChatMessageKind.Assistant) {
                msgs[msgs.lastIndex] = last.copy(content = content)
            } else {
                msgs += ChatMessage(kind = ChatMessageKind.Assistant(), content = content)
            }
            st.copy(messages = msgs)
        }
    }

    private fun upsertThinking(text: String, done: Boolean) {
        _state.update { st ->
            val msgs = st.messages.toMutableList()
            val idx = msgs.indexOfLast { it.kind is ChatMessageKind.Thinking }
            if (idx == -1) {
                msgs += ChatMessage(kind = ChatMessageKind.Thinking(done = done), content = text, id = UUID.randomUUID().toString())
            } else {
                val cur = msgs[idx]
                val kind = (cur.kind as ChatMessageKind.Thinking).copy(done = done)
                val merged = if (text.startsWith(cur.content)) text else cur.content + text
                msgs[idx] = cur.copy(kind = kind, content = merged)
            }
            st.copy(messages = msgs)
        }
    }
}
