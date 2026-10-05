package sh.sandboxed.dashboard.ui.control

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CallSplit
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.core.net.toUri
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import kotlinx.coroutines.launch
import sh.sandboxed.dashboard.data.AppContainer
import sh.sandboxed.dashboard.data.Backend
import sh.sandboxed.dashboard.data.BackendAgent
import sh.sandboxed.dashboard.data.BuiltinCommandsResponse
import sh.sandboxed.dashboard.data.ChatMessage
import sh.sandboxed.dashboard.data.ChatMessageKind
import sh.sandboxed.dashboard.data.Mission
import sh.sandboxed.dashboard.data.MissionStatus
import sh.sandboxed.dashboard.data.Provider
import sh.sandboxed.dashboard.data.QueuedMessage
import sh.sandboxed.dashboard.data.RunningMissionInfo
import sh.sandboxed.dashboard.data.SendState
import sh.sandboxed.dashboard.data.SharedFile
import sh.sandboxed.dashboard.data.SlashCommand
import sh.sandboxed.dashboard.data.Workspace
import sh.sandboxed.dashboard.ui.TestTags
import sh.sandboxed.dashboard.ui.tag
import sh.sandboxed.dashboard.ui.components.ErrorBanner
import sh.sandboxed.dashboard.ui.components.GlassCard
import sh.sandboxed.dashboard.ui.components.StatusBadge
import sh.sandboxed.dashboard.ui.components.ToolUiWidget
import sh.sandboxed.dashboard.ui.theme.Palette
import sh.sandboxed.dashboard.util.Haptics

@Composable
fun ControlScreen(
    container: AppContainer,
    onOpenAutomations: (String) -> Unit,
    onOpenDesktop: (String) -> Unit,
) {
    val vm = remember { ControlViewModel(container) }
    val state by vm.state.collectAsState()
    val listState = rememberLazyListState()
    val haptics = remember { Haptics(container) }
    val ctx = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var showNewMission by remember { mutableStateOf(false) }
    var showMissionSwitcher by remember { mutableStateOf(false) }
    var showWorkers by remember { mutableStateOf(false) }
    var showAsk by remember { mutableStateOf(false) }
    var showThoughts by remember { mutableStateOf(false) }
    var showDiagnostics by remember { mutableStateOf(false) }
    val settingsSnapshot by container.cached.collectAsState()
    val resolveUrl: (String) -> String = remember(container) {
        { url -> if (url.startsWith("http")) url else runCatching { container.api.urlOf(url) }.getOrDefault(url) }
    }
    val onCopy: (String) -> Unit = { text ->
        clipboard.setText(AnnotatedString(text))
        haptics.light()
        Toast.makeText(ctx, "Copied", Toast.LENGTH_SHORT).show()
    }
    val thoughts = remember(state.messages) { state.messages.filter { it.kind is ChatMessageKind.Thinking } }
    val slashSuggestions = remember(state.draft, state.mission?.backend, state.slashCommands) {
        visibleSlashSuggestions(
            draft = state.draft,
            backend = state.mission?.backend,
            catalog = state.slashCommands,
        )
    }
    val slashPanelActive = isSlashPanelActive(state.draft)
    val scope = rememberCoroutineScope()

    // Pause the event stream and pollers while the app is backgrounded; the
    // lastSeq replay catches the conversation up on resume.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> vm.setForeground(true)
                Lifecycle.Event.ON_STOP -> vm.setForeground(false)
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Only follow the stream when the user is already at the bottom; otherwise
    // surface a "new messages" chip instead of yanking them down.
    val atBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            info.totalItemsCount == 0 || lastVisible >= info.totalItemsCount - 2
        }
    }
    var newMessagesBelow by remember { mutableStateOf(false) }
    var lastMessageCount by remember { mutableStateOf(0) }
    LaunchedEffect(state.messages.size) {
        val count = state.messages.size
        val wasEmpty = lastMessageCount == 0
        lastMessageCount = count
        if (count == 0) return@LaunchedEffect
        when {
            // Fresh hydration (mission load/switch): snap straight to the end.
            wasEmpty -> {
                listState.scrollToItem(count - 1)
                newMessagesBelow = false
            }
            atBottom -> listState.animateScrollToItem(count - 1)
            else -> newMessagesBelow = true
        }
    }
    LaunchedEffect(atBottom) {
        if (atBottom) newMessagesBelow = false
    }

    LaunchedEffect(showMissionSwitcher) {
        if (showMissionSwitcher) vm.loadRecentMissions()
    }

    LaunchedEffect(state.desktopOpenRequest) {
        if (state.desktopOpenRequest > 0) onOpenDesktop(state.desktopDisplay)
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().imePadding()) {
            TopBar(
                mission = state.mission,
                connected = state.isConnected,
                canResume = state.mission?.let { it.status.canResume || it.resumable } == true,
                workerCount = state.childMissions.size,
                runningCount = state.parallel.size,
                runState = state.runState,
                progress = state.progress,
                hasThoughts = thoughts.isNotEmpty(),
                onResume = { haptics.success(); vm.resume() },
                onAutomations = { state.mission?.id?.let(onOpenAutomations) },
                onAsk = { if (state.mission != null) showAsk = true },
                onThoughts = { showThoughts = true },
                onNewMission = { showNewMission = true },
                onSwitchMissions = { showMissionSwitcher = true },
                onWorkers = { showWorkers = true },
                onDesktop = { onOpenDesktop(state.desktopDisplay) },
                onToggleDiagnostics = { showDiagnostics = !showDiagnostics },
            )
            if (state.parallel.isNotEmpty()) {
                ParallelBar(state.parallel, state.mission?.id) { haptics.selection(); vm.switchMission(it) }
            }
            state.goalStatus?.takeIf { it.isNotBlank() }?.let { GoalBanner(it) }
            state.error?.let { Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) { ErrorBanner(it) } }
            if (state.staleCache) StaleCachePill()
            if (showDiagnostics) DiagnosticsOverlay(state)
            if (state.queue.isNotEmpty()) QueueBar(state.queue, vm::deleteQueueItem, vm::clearQueue)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(state.messages, key = { it.id }) { msg ->
                        MessageRow(msg, resolveUrl, settingsSnapshot.jwtToken, onCopy, onRetry = { vm.retrySend(it) })
                    }
                }
                if (newMessagesBelow && !atBottom) {
                    Row(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 12.dp)
                            .background(Palette.Accent, RoundedCornerShape(999.dp))
                            .clickable {
                                scope.launch {
                                    if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.lastIndex)
                                }
                            }
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                            .tag(TestTags.CONTROL_NEW_MESSAGES_CHIP),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.ArrowDownward, null, tint = Color.White, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("New messages", color = Color.White, style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
            if (slashPanelActive && (slashSuggestions.isNotEmpty() || state.slashCommandsLoading)) {
                SlashSuggestions(
                    commands = slashSuggestions,
                    loading = state.slashCommandsLoading && slashSuggestions.isEmpty(),
                    onSelect = {
                        haptics.selection()
                        vm.applySlashCommand(it)
                    },
                )
            }
            Composer(
                value = state.draft,
                onChange = vm::setDraft,
                onSend = { haptics.medium(); vm.send() },
                onSendParallel = { haptics.medium(); vm.sendParallel() },
                onCancel = { haptics.error(); vm.cancel() },
                isSending = state.isSending,
                // The parallel-config endpoint doesn't exist on all servers, so
                // don't gate on maxParallel — the backend enforces its own limit.
                parallelAvailable = state.mission != null,
            )
        }
    }

    if (showNewMission) {
        NewMissionDialog(
            container = container,
            onDismiss = { showNewMission = false },
            onCreate = { options ->
                showNewMission = false
                haptics.success()
                vm.createMission(options)
            },
        )
    }
    if (showMissionSwitcher) {
        MissionSwitcherDialog(
            currentMissionId = state.mission?.id,
            running = state.parallel,
            recent = state.recentMissions,
            loading = state.loadingRecent,
            onDismiss = { showMissionSwitcher = false },
            onOpen = {
                showMissionSwitcher = false
                haptics.selection()
                vm.switchMission(it)
            },
            onResume = {
                showMissionSwitcher = false
                haptics.success()
                vm.resumeMission(it)
            },
            onFollowUp = {
                showMissionSwitcher = false
                haptics.selection()
                vm.createFollowUpMission(it)
            },
            onCancel = {
                haptics.error()
                vm.cancelMission(it)
            },
            onDelete = {
                haptics.error()
                vm.deleteMission(it)
            },
            onNewMission = {
                showMissionSwitcher = false
                showNewMission = true
            },
        )
    }
    if (showWorkers) {
        WorkerDialog(
            workers = state.childMissions,
            running = state.parallel,
            onDismiss = { showWorkers = false },
            onOpen = {
                showWorkers = false
                vm.switchMission(it)
            },
        )
    }
    if (showAsk) {
        state.mission?.id?.let { missionId ->
            AskSheet(
                container = container,
                missionId = missionId,
                onSendToAgent = { vm.appendToComposer(it) },
                onDismiss = { showAsk = false },
            )
        }
    }
    if (showThoughts) {
        ThoughtsDialog(thoughts = thoughts, onCopy = onCopy, onDismiss = { showThoughts = false })
    }
}

/// Expanded view of the agent's reasoning: every thinking block of the
/// current conversation, full text, copyable.
@Composable
private fun ThoughtsDialog(thoughts: List<ChatMessage>, onCopy: (String) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Thoughts", color = Palette.TextPrimary) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (thoughts.isEmpty()) item { Text("No thinking yet", color = Palette.TextTertiary) }
                items(thoughts, key = { it.id }) { t ->
                    val done = (t.kind as? ChatMessageKind.Thinking)?.done == true
                    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = { onCopy(t.content) }) {
                        Column(Modifier.padding(12.dp)) {
                            Text(
                                if (done) "thinking complete" else "thinking…",
                                color = Palette.TextTertiary,
                                style = MaterialTheme.typography.labelMedium,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(t.content, color = Palette.TextSecondary, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.tag(TestTags.CONTROL_THOUGHTS_CLOSE)) { Text("Close") } },
        containerColor = Palette.Card,
    )
}

@Composable
private fun StaleCachePill() {
    Row(
        Modifier
            .fillMaxWidth()
            .background(Palette.Warning.copy(alpha = 0.12f))
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .tag(TestTags.CONTROL_STALE_PILL),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.CloudOff, null, tint = Palette.Warning, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(8.dp))
        Text("Showing cached conversation — server unreachable", color = Palette.Warning, style = MaterialTheme.typography.labelMedium)
    }
}

/// Debug overlay with stream internals, toggled by long-pressing the
/// connection status in the top bar. Mirrors the iOS control diagnostics.
@Composable
private fun DiagnosticsOverlay(state: ControlState) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.BackgroundTertiary)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .tag(TestTags.CONTROL_DIAGNOSTICS),
    ) {
        val mono = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp)
        Text("transport=${state.transport} connected=${state.isConnected}", color = Palette.TextSecondary, style = mono)
        Text("events=${state.eventsReceived} lastSeq=${state.lastEventSeq ?: "-"}", color = Palette.TextSecondary, style = mono)
        Text("messages=${state.messages.size} queue=${state.queue.size} runState=${state.runState.wireValue}", color = Palette.TextSecondary, style = mono)
        Text("mission=${state.mission?.id?.take(8) ?: "-"} stale=${state.staleCache} parallel=${state.parallel.size}/${state.maxParallel}", color = Palette.TextSecondary, style = mono)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TopBar(
    mission: Mission?,
    connected: Boolean,
    canResume: Boolean,
    workerCount: Int,
    runningCount: Int,
    runState: ControlRunState,
    progress: ExecutionProgress?,
    hasThoughts: Boolean,
    onResume: () -> Unit,
    onAutomations: () -> Unit,
    onAsk: () -> Unit,
    onThoughts: () -> Unit,
    onNewMission: () -> Unit,
    onSwitchMissions: () -> Unit,
    onWorkers: () -> Unit,
    onDesktop: () -> Unit,
    onToggleDiagnostics: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().background(Palette.BackgroundSecondary).padding(horizontal = 16.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(mission?.title ?: "New mission", style = MaterialTheme.typography.titleMedium, color = Palette.TextPrimary, maxLines = 1)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    // Long-press the status line to toggle the stream diagnostics overlay.
                    modifier = Modifier.combinedClickable(onClick = {}, onLongClick = onToggleDiagnostics),
                ) {
                    Text(
                        if (connected) "Connected" else "Reconnecting…",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (connected) Palette.Success else Palette.Warning,
                        maxLines = 1,
                    )
                    Text("•", color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall)
                    Text(runState.label, color = runStateColor(runState), style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    progress?.takeIf { it.total > 0 }?.let {
                        Text("•", color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall)
                        Text(it.displayText, color = Palette.Success, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    }
                }
            }
            mission?.status?.let { StatusBadge(it) }
            if (canResume) {
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = onResume, modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_RESUME)) { Icon(Icons.Filled.PlayArrow, "Resume", tint = Palette.Accent) }
            }
            if (mission != null) {
                IconButton(onClick = onAsk, modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_ASK)) { Icon(Icons.Filled.AutoAwesome, "Ask co-pilot", tint = Color(0xFF22D3EE)) }
            }
            IconButton(onClick = onSwitchMissions, modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_MISSIONS)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.History, "Missions", tint = if (runningCount > 0) Palette.Accent else Palette.TextSecondary)
                    if (runningCount > 0) {
                        Text(runningCount.toString(), color = Palette.TextPrimary, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 18.dp))
                    }
                }
            }
            IconButton(onClick = onNewMission, modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_NEW_MISSION)) { Icon(Icons.Filled.Add, "New mission", tint = Palette.Accent) }
            // Secondary actions live in an overflow menu so the title and
            // status line keep usable width on phones.
            Box {
                var menuOpen by remember { mutableStateOf(false) }
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_OVERFLOW)) {
                    Icon(Icons.Filled.MoreVert, "More actions", tint = Palette.TextSecondary)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (mission != null) {
                        DropdownMenuItem(
                            text = { Text("Automations") },
                            leadingIcon = { Icon(Icons.Filled.Settings, null) },
                            onClick = { menuOpen = false; onAutomations() },
                            modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_AUTOMATIONS),
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Desktop") },
                        leadingIcon = { Icon(Icons.Filled.Computer, null) },
                        onClick = { menuOpen = false; onDesktop() },
                        modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_DESKTOP),
                    )
                    if (hasThoughts) {
                        DropdownMenuItem(
                            text = { Text("Thoughts") },
                            leadingIcon = { Icon(Icons.Filled.Psychology, null) },
                            onClick = { menuOpen = false; onThoughts() },
                            modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_THOUGHTS),
                        )
                    }
                    if (workerCount > 0) {
                        DropdownMenuItem(
                            text = { Text("Workers ($workerCount)") },
                            leadingIcon = { Icon(Icons.Filled.CallSplit, null) },
                            onClick = { menuOpen = false; onWorkers() },
                            modifier = Modifier.tag(TestTags.CONTROL_TOPBAR_WORKERS),
                        )
                    }
                }
            }
        }
        if (mission != null && (mission.metadataModel != null || mission.metadataSource != null || mission.workspaceName != null)) {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                mission.metadataModel?.let { Tag(it) }
                mission.metadataSource?.let { Tag(it) }
                mission.workspaceName?.let { Tag(it) }
            }
        }
    }
}

private fun runStateColor(runState: ControlRunState): Color = when (runState) {
    ControlRunState.IDLE -> Palette.TextSecondary
    ControlRunState.RUNNING -> Palette.Success
    ControlRunState.WAITING_FOR_TOOL -> Palette.Warning
}

@Composable
private fun Tag(text: String) {
    Text(
        text,
        color = Palette.TextTertiary,
        style = MaterialTheme.typography.labelSmall,
        modifier = Modifier
            .background(Palette.BackgroundTertiary, RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
private fun GoalBanner(status: String) {
    val color = when (status) {
        "complete" -> Palette.Success
        "paused", "budgetLimited" -> Palette.Warning
        "active" -> Palette.Info
        else -> Palette.TextTertiary
    }
    Row(
        Modifier.fillMaxWidth().background(color.copy(alpha = 0.12f)).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Flag, null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text("/goal · $status", color = color, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun QueueBar(queue: List<QueuedMessage>, onDelete: (String) -> Unit, onClear: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Palette.BackgroundSecondary).padding(horizontal = 12.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Schedule, null, tint = Palette.AccentLight, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text("Queued · ${queue.size}", color = Palette.AccentLight, style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
            IconButton(onClick = onClear) { Icon(Icons.Filled.Close, "Clear queue", tint = Palette.TextTertiary) }
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            items(queue, key = { it.id }) { q ->
                Row(
                    modifier = Modifier
                        .background(Palette.Card, RoundedCornerShape(8.dp))
                        .border(1.dp, Palette.Border, RoundedCornerShape(8.dp))
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(q.displayContent, color = Palette.TextPrimary, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Filled.Close, "Remove", tint = Palette.TextTertiary, modifier = Modifier.size(14.dp).clickable { onDelete(q.id) })
                }
            }
        }
    }
}

@Composable
private fun ParallelBar(running: List<RunningMissionInfo>, currentId: String?, onSwitch: (String) -> Unit) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.BackgroundSecondary)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(running, key = { it.missionId }) { r ->
            val color = when {
                r.isSeverelyStalled -> Palette.Error
                r.isStalled -> Palette.Warning
                r.isRunning -> Palette.Success
                else -> Palette.TextTertiary
            }
            val active = r.missionId == currentId
            Row(
                modifier = Modifier
                    .background(if (active) Palette.Accent.copy(alpha = 0.16f) else Palette.Card, RoundedCornerShape(999.dp))
                    .border(1.dp, if (active) Palette.Accent else Palette.Border, RoundedCornerShape(999.dp))
                    .clickable { onSwitch(r.missionId) }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(8.dp).background(color, RoundedCornerShape(4.dp)))
                Spacer(Modifier.width(6.dp))
                Text(r.title?.take(20) ?: r.missionId.take(8), style = MaterialTheme.typography.labelMedium, color = Palette.TextPrimary)
            }
        }
    }
}

@Composable
private fun NewMissionDialog(
    container: AppContainer,
    onDismiss: () -> Unit,
    onCreate: (NewMissionOptions) -> Unit,
) {
    var workspaces by remember { mutableStateOf<List<Workspace>>(emptyList()) }
    var backends by remember { mutableStateOf<List<Backend>>(emptyList()) }
    var agentsByBackend by remember { mutableStateOf<Map<String, List<BackendAgent>>>(emptyMap()) }
    var providers by remember { mutableStateOf<List<Provider>>(emptyList()) }
    var selectedWorkspaceId by remember { mutableStateOf<String?>(null) }
    var selectedBackend by remember { mutableStateOf("") }
    var selectedAgent by remember { mutableStateOf("") }
    var selectedModel by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        val settings = container.cached.value
        workspaces = runCatching { container.api.listWorkspaces() }.getOrNull().orEmpty()
        backends = runCatching { container.api.listBackends() }.getOrNull().orEmpty()
        agentsByBackend = backends.associate { backend ->
            backend.id to runCatching { container.api.listBackendAgents(backend.id) }.getOrNull().orEmpty()
        }
        providers = runCatching { container.api.listProviders() }.getOrNull()?.providers.orEmpty()

        selectedWorkspaceId = workspaces.firstOrNull { it.isDefault }?.id ?: workspaces.firstOrNull()?.id
        selectedBackend = settings.defaultBackend.takeIf { saved -> backends.any { it.id == saved } }
            ?: backends.firstOrNull()?.id.orEmpty()
        val selectedAgents = agentsByBackend[selectedBackend].orEmpty()
        selectedAgent = settings.defaultAgent.takeIf { saved -> selectedAgents.any { it.id == saved } }
            ?: selectedAgents.firstOrNull()?.id.orEmpty()
        selectedModel = settings.defaultModel
        loading = false
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New mission", color = Palette.TextPrimary) },
        text = {
            if (loading) {
                Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Palette.Accent)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    item { DialogSection("Workspace") }
                    items(workspaces, key = { it.id }) { workspace ->
                        SelectRow(
                            title = workspace.name,
                            subtitle = "${workspace.workspaceType} · ${workspace.path}",
                            selected = selectedWorkspaceId == workspace.id,
                        ) { selectedWorkspaceId = workspace.id }
                    }

                    item { DialogSection("Agent") }
                    item {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(backends, key = { it.id }) { backend ->
                                FilterChip(
                                    selected = selectedBackend == backend.id,
                                    onClick = {
                                        selectedBackend = backend.id
                                        selectedAgent = agentsByBackend[backend.id].orEmpty().firstOrNull()?.id.orEmpty()
                                        selectedModel = ""
                                    },
                                    label = { Text(backend.name, style = MaterialTheme.typography.labelSmall) },
                                    colors = dialogChipColors(),
                                )
                            }
                        }
                    }
                    items(agentsByBackend[selectedBackend].orEmpty(), key = { it.id }) { agent ->
                        SelectRow(
                            title = agent.name,
                            subtitle = selectedBackend,
                            selected = selectedAgent == agent.id,
                        ) { selectedAgent = agent.id }
                    }

                    item { DialogSection("Model override") }
                    item {
                        SelectRow(
                            title = "Default",
                            subtitle = "Use the selected agent or server default",
                            selected = selectedModel.isBlank(),
                        ) { selectedModel = "" }
                    }
                    items(filteredProviders(providers, selectedBackend), key = { it.id }) { provider ->
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(provider.name, color = Palette.TextTertiary, style = MaterialTheme.typography.labelMedium)
                            provider.models.take(12).forEach { model ->
                                val value = if (selectedBackend == "opencode") "${provider.id}/${model.id}" else model.id
                                SelectRow(
                                    title = model.name,
                                    subtitle = value,
                                    selected = selectedModel == value,
                                ) { selectedModel = value }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    onCreate(
                        NewMissionOptions(
                            workspaceId = selectedWorkspaceId,
                            agent = selectedAgent.takeIf { it.isNotBlank() },
                            modelOverride = selectedModel.takeIf { it.isNotBlank() },
                            backend = selectedBackend.takeIf { it.isNotBlank() },
                        )
                    )
                },
                enabled = !loading && selectedWorkspaceId != null && selectedBackend.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = Palette.Accent),
                modifier = Modifier.tag(TestTags.NEW_MISSION_CREATE),
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss, modifier = Modifier.tag(TestTags.NEW_MISSION_CANCEL)) { Text("Cancel") } },
        containerColor = Palette.Card,
    )
}

@Composable
private fun MissionSwitcherDialog(
    currentMissionId: String?,
    running: List<RunningMissionInfo>,
    recent: List<Mission>,
    loading: Boolean,
    onDismiss: () -> Unit,
    onOpen: (String) -> Unit,
    onResume: (String) -> Unit,
    onFollowUp: (Mission) -> Unit,
    onCancel: (String) -> Unit,
    onDelete: (String) -> Unit,
    onNewMission: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val normalized = query.trim().lowercase()
    val runningIds = running.map { it.missionId }.toSet()
    val visibleRecent = recent.filter { m ->
        normalized.isBlank() ||
            (m.title ?: "").lowercase().contains(normalized) ||
            (m.shortDescription ?: "").lowercase().contains(normalized) ||
            (m.agent ?: "").lowercase().contains(normalized) ||
            m.id.lowercase().contains(normalized)
    }
    val byId = recent.associateBy { it.id }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Missions", color = Palette.TextPrimary) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 540.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        label = { Text("Search") },
                        modifier = Modifier.fillMaxWidth().tag(TestTags.SWITCHER_SEARCH),
                        colors = dialogFieldColors(),
                    )
                }
                if (loading) item { LinearLoading() }
                if (running.isNotEmpty()) item { DialogSection("Running") }
                items(running, key = { it.missionId }) { info ->
                    MissionSwitcherRunningRow(
                        info = info,
                        mission = byId[info.missionId],
                        current = currentMissionId == info.missionId,
                        onOpen = { onOpen(info.missionId) },
                        onCancel = { onCancel(info.missionId) },
                    )
                }

                val nonRunning = visibleRecent.filterNot { it.id in runningIds }
                if (nonRunning.any { it.status.isOpen }) {
                    item { DialogSection("Active & pending") }
                    items(nonRunning.filter { it.status.isOpen }, key = { it.id }) { m ->
                        MissionSwitcherMissionRow(m, currentMissionId == m.id, onOpen, onResume, onFollowUp, onCancel, onDelete)
                    }
                }
                val completed = nonRunning.filter { it.status.isDone }
                if (completed.isNotEmpty()) {
                    item { DialogSection("Completed") }
                    items(completed, key = { it.id }) { m ->
                        MissionSwitcherMissionRow(m, currentMissionId == m.id, onOpen, onResume, onFollowUp, onCancel, onDelete)
                    }
                }
                val failed = nonRunning.filter { it.status == MissionStatus.FAILED || it.status == MissionStatus.NOT_FEASIBLE }
                if (failed.isNotEmpty()) {
                    item { DialogSection("Failed") }
                    items(failed, key = { it.id }) { m ->
                        MissionSwitcherMissionRow(m, currentMissionId == m.id, onOpen, onResume, onFollowUp, onCancel, onDelete)
                    }
                }
                val interrupted = nonRunning.filter { it.status == MissionStatus.INTERRUPTED || it.status == MissionStatus.BLOCKED }
                if (interrupted.isNotEmpty()) {
                    item { DialogSection("Interrupted") }
                    items(interrupted, key = { it.id }) { m ->
                        MissionSwitcherMissionRow(m, currentMissionId == m.id, onOpen, onResume, onFollowUp, onCancel, onDelete)
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = onNewMission, colors = ButtonDefaults.buttonColors(containerColor = Palette.Accent), modifier = Modifier.tag(TestTags.SWITCHER_NEW)) {
                Text("New")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss, modifier = Modifier.tag(TestTags.SWITCHER_CLOSE)) { Text("Close") } },
        containerColor = Palette.Card,
    )
}

@Composable
private fun WorkerDialog(
    workers: List<Mission>,
    running: List<RunningMissionInfo>,
    onDismiss: () -> Unit,
    onOpen: (String) -> Unit,
) {
    val runningIds = running.map { it.missionId }.toSet()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Workers", color = Palette.TextPrimary) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 460.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val active = workers.filter { it.id in runningIds || it.status.isOpen }
                val completed = workers.filter { it.status.isDone }
                val failed = workers.filter { it.status == MissionStatus.FAILED || it.status == MissionStatus.NOT_FEASIBLE || it.status == MissionStatus.INTERRUPTED }
                if (active.isNotEmpty()) item { DialogSection("Running") }
                items(active, key = { it.id }) { worker -> WorkerRow(worker, running.firstOrNull { it.missionId == worker.id }, onOpen) }
                if (completed.isNotEmpty()) item { DialogSection("Completed") }
                items(completed, key = { it.id }) { worker -> WorkerRow(worker, null, onOpen) }
                if (failed.isNotEmpty()) item { DialogSection("Failed") }
                items(failed, key = { it.id }) { worker -> WorkerRow(worker, null, onOpen) }
                if (workers.isEmpty()) item { Text("No workers yet", color = Palette.TextTertiary) }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        containerColor = Palette.Card,
    )
}

@Composable
private fun WorkerRow(worker: Mission, running: RunningMissionInfo?, onOpen: (String) -> Unit) {
    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = { onOpen(worker.id) }) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(worker.title ?: worker.shortDescription ?: worker.id.take(8), color = Palette.TextPrimary, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                StatusBadge(worker.status)
            }
            running?.currentActivity?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall, maxLines = 2)
            }
        }
    }
}

@Composable
private fun MissionSwitcherRunningRow(
    info: RunningMissionInfo,
    mission: Mission?,
    current: Boolean,
    onOpen: () -> Unit,
    onCancel: () -> Unit,
) {
    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = onOpen) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val color = when {
                    info.isSeverelyStalled -> Palette.Error
                    info.isStalled -> Palette.Warning
                    info.isRunning -> Palette.Success
                    else -> Palette.TextTertiary
                }
                Box(Modifier.size(10.dp).background(color, RoundedCornerShape(5.dp)))
                Spacer(Modifier.width(8.dp))
                Text(info.title ?: mission?.title ?: info.missionId.take(8), color = if (current) Palette.AccentLight else Palette.TextPrimary, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                IconButton(onClick = onCancel) { Icon(Icons.Filled.Cancel, "Cancel", tint = Palette.Warning) }
            }
            info.currentActivity?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall, maxLines = 2)
            }
            if (info.queueLen > 0) Text("${info.queueLen} queued", color = Palette.Warning, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun MissionSwitcherMissionRow(
    mission: Mission,
    current: Boolean,
    onOpen: (String) -> Unit,
    onResume: (String) -> Unit,
    onFollowUp: (Mission) -> Unit,
    onCancel: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = { onOpen(mission.id) }) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(mission.title ?: mission.shortDescription ?: mission.id.take(8), color = if (current) Palette.AccentLight else Palette.TextPrimary, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                StatusBadge(mission.status)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(mission.updatedAt.take(19).replace('T', ' '), color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                if (mission.status.canResume || mission.resumable || mission.status == MissionStatus.FAILED || mission.status == MissionStatus.NOT_FEASIBLE) {
                    TextButton(onClick = { onResume(mission.id) }) { Text(if (mission.status == MissionStatus.FAILED || mission.status == MissionStatus.NOT_FEASIBLE) "Retry" else "Resume") }
                }
                if (mission.status != MissionStatus.ACTIVE && mission.status != MissionStatus.PENDING) {
                    TextButton(onClick = { onFollowUp(mission) }) { Text("Follow up") }
                } else {
                    IconButton(onClick = { onCancel(mission.id) }) { Icon(Icons.Filled.Cancel, "Cancel", tint = Palette.Warning) }
                }
                if (mission.status != MissionStatus.ACTIVE && mission.status != MissionStatus.PENDING) {
                    IconButton(onClick = { onDelete(mission.id) }) { Icon(Icons.Filled.Delete, "Delete", tint = Palette.Error) }
                }
            }
        }
    }
}

@Composable
private fun DialogSection(title: String) {
    Text(title.uppercase(), color = Palette.TextTertiary, style = MaterialTheme.typography.labelMedium)
}

@Composable
private fun SelectRow(title: String, subtitle: String?, selected: Boolean, onClick: () -> Unit) {
    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = onClick) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, color = if (selected) Palette.AccentLight else Palette.TextPrimary, style = MaterialTheme.typography.bodyMedium)
                subtitle?.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                }
            }
            if (selected) Text("Selected", color = Palette.Accent, style = MaterialTheme.typography.labelSmall)
        }
    }
}

private fun filteredProviders(providers: List<Provider>, backend: String): List<Provider> = when (backend) {
    "claudecode", "amp" -> providers.filter { it.id == "anthropic" }
    "codex" -> providers.filter { it.id == "openai" }
    else -> providers
}

@Composable
private fun dialogChipColors() = FilterChipDefaults.filterChipColors(
    containerColor = Palette.Card,
    selectedContainerColor = Palette.Accent.copy(alpha = 0.18f),
    labelColor = Palette.TextSecondary,
    selectedLabelColor = Palette.Accent,
)

@Composable
private fun dialogFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = Palette.Card,
    unfocusedContainerColor = Palette.Card,
    focusedTextColor = Palette.TextPrimary,
    unfocusedTextColor = Palette.TextPrimary,
    cursorColor = Palette.Accent,
)

@Composable
private fun LinearLoading() {
    Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.height(20.dp), color = Palette.Accent)
    }
}

@Composable
private fun SlashSuggestions(
    commands: List<SlashCommand>,
    loading: Boolean,
    onSelect: (SlashCommand) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.BackgroundSecondary)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (loading) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Card, RoundedCornerShape(10.dp))
                    .border(1.dp, Palette.Border, RoundedCornerShape(10.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(14.dp), color = Palette.Accent)
                Spacer(Modifier.width(8.dp))
                Text("Loading commands…", color = Palette.TextSecondary, style = MaterialTheme.typography.bodySmall)
            }
        } else {
            commands.take(8).forEach { command ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Palette.Card, RoundedCornerShape(10.dp))
                        .border(1.dp, Palette.Border, RoundedCornerShape(10.dp))
                        .clickable { onSelect(command) }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("/${command.name}", color = Palette.AccentLight, style = MaterialTheme.typography.labelLarge, modifier = Modifier.widthIn(min = 92.dp))
                    Column(Modifier.weight(1f)) {
                        command.description?.takeIf { it.isNotBlank() }?.let {
                            Text(it, color = Palette.TextSecondary, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                        }
                        val hint = slashCommandHint(command)
                        if (hint.isNotBlank()) {
                            Text(hint, color = Palette.TextTertiary, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
        }
    }
}

private fun isSlashPanelActive(draft: String): Boolean {
    val trimmed = draft.trim()
    if (!trimmed.startsWith("/")) return false
    return !trimmed.drop(1).any { it.isWhitespace() }
}

private fun visibleSlashSuggestions(
    draft: String,
    backend: String?,
    catalog: BuiltinCommandsResponse?,
): List<SlashCommand> {
    catalog ?: return emptyList()
    val trimmed = draft.trim()
    if (!trimmed.startsWith("/")) return emptyList()
    val fragment = trimmed.drop(1)
    if (fragment.any { it.isWhitespace() }) return emptyList()
    val pool = when (backend) {
        "codex" -> catalog.codex
        "claudecode" -> catalog.claudecode
        "opencode" -> catalog.opencode
        else -> catalog.opencode + catalog.claudecode + catalog.codex
    }
    return pool
        .filter { command ->
            fragment.isBlank() ||
                command.name.startsWith(fragment, ignoreCase = true)
        }
        .distinctBy { "${it.path}:${it.name}" }
}

private fun slashCommandHint(command: SlashCommand): String =
    command.params.joinToString(" ") { param ->
        if (param.required) "<${param.name}>" else "[${param.name}]"
    }

@Composable
private fun MessageRow(
    msg: ChatMessage,
    resolveUrl: (String) -> String,
    authToken: String?,
    onCopy: (String) -> Unit,
    onRetry: (String) -> Unit,
) {
    when (val k = msg.kind) {
        ChatMessageKind.User -> Bubble(msg.content, mine = true, onCopy = onCopy, sendState = msg.sendState, onRetry = { onRetry(msg.id) })
        is ChatMessageKind.Assistant -> AssistantBubble(msg.content, k, resolveUrl, authToken, onCopy)
        is ChatMessageKind.Thinking -> ThinkingNote(done = k.done, body = msg.content)
        is ChatMessageKind.Phase -> SystemNote("phase: ${k.phase}${k.detail?.let { " — $it" } ?: ""}")
        is ChatMessageKind.ToolCall -> ToolCallRow(k.name, k.isActive, msg.content)
        is ChatMessageKind.ToolUi -> ToolUiWidget(k.content)
        is ChatMessageKind.Goal -> SystemNote("goal · iter ${k.iteration} · ${k.status}", body = k.objective.takeIf { it.isNotBlank() })
        ChatMessageKind.SystemNote -> SystemNote(msg.content)
        ChatMessageKind.ErrorMsg -> ErrorBanner(msg.content)
    }
}

/// Inline reasoning block: collapsed to a few lines by default, tap to expand.
/// The full backlog of thoughts lives in ThoughtsDialog (brain icon, top bar).
@Composable
private fun ThinkingNote(done: Boolean, body: String) {
    var expanded by remember { mutableStateOf(false) }
    GlassCard(modifier = Modifier.fillMaxWidth(), onClick = { expanded = !expanded }) {
        Column(Modifier.padding(12.dp)) {
            Text(if (done) "thinking complete" else "thinking…", color = Palette.TextTertiary, style = MaterialTheme.typography.labelMedium)
            if (body.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    body,
                    color = Palette.TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = if (expanded) Int.MAX_VALUE else 3,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Bubble(
    text: String,
    mine: Boolean,
    onCopy: (String) -> Unit,
    sendState: SendState = SendState.SENT,
    onRetry: () -> Unit = {},
) {
    val failed = mine && sendState == SendState.FAILED
    val pending = mine && sendState == SendState.PENDING
    val bg = if (mine) Palette.Accent.copy(alpha = if (pending) 0.6f else 1f) else Palette.Card
    val fg = if (mine) Color(0xFFFFFFFF) else Palette.TextPrimary
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Column(horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
            Column(
                Modifier
                    .widthIn(max = 320.dp)
                    .background(bg, RoundedCornerShape(16.dp))
                    .then(if (failed) Modifier.border(1.dp, Palette.Error, RoundedCornerShape(16.dp)) else Modifier)
                    .combinedClickable(onClick = { if (failed) onRetry() }, onLongClick = { onCopy(text) })
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                if (mine) {
                    Text(text, color = fg, style = MaterialTheme.typography.bodyMedium)
                } else {
                    // Agent replies are mostly markdown: code blocks, lists, links.
                    Markdown(
                        content = text,
                        colors = markdownColor(
                            text = fg,
                            codeText = Palette.TextSecondary,
                            codeBackground = Palette.BackgroundTertiary,
                            inlineCodeText = Palette.AccentLight,
                            inlineCodeBackground = Palette.BackgroundTertiary,
                            linkText = Palette.AccentLight,
                            dividerColor = Palette.Border,
                        ),
                    )
                }
            }
            if (failed) {
                Text(
                    "Failed — tap to retry",
                    color = Palette.Error,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(top = 2.dp, end = 4.dp).tag(TestTags.CONTROL_MESSAGE_RETRY),
                )
            }
        }
    }
}

@Composable
private fun AssistantBubble(
    text: String,
    a: ChatMessageKind.Assistant,
    resolveUrl: (String) -> String,
    authToken: String?,
    onCopy: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Bubble(text, mine = false, onCopy = onCopy)
        val (images, others) = a.sharedFiles.partition { it.contentType.startsWith("image/") }
        images.forEach { f ->
            Spacer(Modifier.height(6.dp))
            SharedInlineImage(f, resolveUrl, authToken)
        }
        if (others.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(others, key = { it.url }) { f -> SharedFileChip(f) }
            }
        }
        formatAssistantFooter(a)?.let {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(costSourceIcon(a.costSource), null, tint = Palette.TextTertiary, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(4.dp))
                Text(it, color = Palette.TextTertiary, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/// Image shared by the agent, rendered inline in the conversation. Tap opens
/// the full image in an external viewer.
@Composable
private fun SharedInlineImage(f: SharedFile, resolveUrl: (String) -> String, authToken: String?) {
    val ctx = LocalContext.current
    val url = resolveUrl(f.url)
    // Only attach the dashboard JWT to our own backend (relative paths that
    // resolveUrl rebased onto baseUrl). Absolute third-party URLs must not
    // receive the token — that would leak the session to an external host.
    val tokenForHost = if (f.url.startsWith("http")) null else authToken
    val request = remember(url, tokenForHost) {
        ImageRequest.Builder(ctx)
            .data(url)
            .apply { tokenForHost?.let { setHeader("Authorization", "Bearer $it") } }
            .crossfade(true)
            .build()
    }
    AsyncImage(
        model = request,
        contentDescription = f.name,
        contentScale = ContentScale.FillWidth,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 360.dp)
            .background(Palette.Card, RoundedCornerShape(12.dp))
            .border(1.dp, Palette.Border, RoundedCornerShape(12.dp))
            .clickable {
                val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, url.toUri())
                runCatching { ctx.startActivity(intent) }
            },
    )
}

private fun costSourceIcon(source: String): ImageVector = when (source) {
    "actual" -> Icons.Filled.PlayArrow
    "estimated" -> Icons.Filled.Schedule
    else -> Icons.Filled.PlayArrow
}

@Composable
private fun SharedFileChip(f: SharedFile) {
    val ctx = LocalContext.current
    Row(
        modifier = Modifier
            .background(Palette.Card, RoundedCornerShape(8.dp))
            .border(1.dp, Palette.Border, RoundedCornerShape(8.dp))
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .clickable {
                val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, f.url.toUri())
                runCatching { ctx.startActivity(intent) }
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.AttachFile, null, tint = Palette.AccentLight, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(6.dp))
        Text(f.name.ifBlank { "file" }, color = Palette.TextPrimary, style = MaterialTheme.typography.labelMedium)
        Spacer(Modifier.width(6.dp))
        Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = Palette.TextTertiary, modifier = Modifier.size(12.dp))
    }
}

private fun formatAssistantFooter(a: ChatMessageKind.Assistant): String? {
    val parts = buildList<String> {
        a.model?.let { add(it) }
        if (a.costCents > 0) add("$" + "%.2f".format(a.costCents / 100.0))
        if (a.costSource == "estimated") add("est.")
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" • ")
}

@Composable
private fun SystemNote(label: String, body: String? = null, muted: Boolean = false) {
    GlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Text(label, color = if (muted) Palette.TextTertiary else Palette.TextSecondary, style = MaterialTheme.typography.labelMedium)
            if (!body.isNullOrBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(body, color = Palette.TextSecondary, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun ToolCallRow(name: String, active: Boolean, args: String) {
    GlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (active) CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(14.dp), color = Palette.Accent)
                if (active) Spacer(Modifier.width(8.dp))
                Text("tool: $name", color = Palette.AccentLight, style = MaterialTheme.typography.labelLarge)
            }
            if (args.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(args.take(400), color = Palette.TextTertiary, style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp))
            }
        }
    }
}

@Composable
private fun Composer(
    value: String,
    onChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendParallel: () -> Unit,
    onCancel: () -> Unit,
    isSending: Boolean,
    parallelAvailable: Boolean,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.BackgroundSecondary)
            .padding(12.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        Box(
            Modifier
                .weight(1f)
                .heightIn(min = 44.dp)
                .background(Palette.Card, RoundedCornerShape(20.dp))
                .border(1.dp, Palette.Border, RoundedCornerShape(20.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            BasicTextField(
                value = value,
                onValueChange = onChange,
                cursorBrush = SolidColor(Palette.Accent),
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = Palette.TextPrimary),
                modifier = Modifier.fillMaxWidth().tag(TestTags.CONTROL_COMPOSER_INPUT),
            )
            if (value.isEmpty()) {
                Text("Message…", color = Palette.TextMuted, style = MaterialTheme.typography.bodyMedium)
            }
        }
        if (parallelAvailable) {
            Spacer(Modifier.width(4.dp))
            IconButton(
                onClick = onSendParallel,
                enabled = !isSending && value.isNotBlank(),
                modifier = Modifier.tag(TestTags.CONTROL_COMPOSER_PARALLEL),
            ) {
                Icon(Icons.Filled.CallSplit, contentDescription = "Send as parallel mission", tint = Palette.AccentLight)
            }
        }
        Spacer(Modifier.width(8.dp))
        IconButton(onClick = if (isSending) onCancel else onSend, enabled = isSending || value.isNotBlank(), modifier = Modifier.tag(TestTags.CONTROL_COMPOSER_SEND)) {
            Icon(
                if (isSending) Icons.Filled.Cancel else Icons.AutoMirrored.Filled.Send,
                contentDescription = if (isSending) "Cancel" else "Send",
                tint = if (isSending) Palette.Error else Palette.Accent,
            )
        }
    }
}
