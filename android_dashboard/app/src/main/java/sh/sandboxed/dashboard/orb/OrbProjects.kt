package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DriveFileMove
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
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
import kotlinx.coroutines.launch

enum class OrbTopTab {
    Projects,
    Inbox
}

sealed class OrbNavScreen {
    data object Home : OrbNavScreen()
    data class Project(val project: OrbRow) : OrbNavScreen()
    data class Conversation(
        val project: OrbRow,
        val mission: OrbRow?,
        val initialFolder: String? = null
    ) : OrbNavScreen()
    data class Documents(
        val project: OrbRow,
        val directoryPath: String = ""
    ) : OrbNavScreen()
    data class DocumentViewer(
        val project: OrbRow,
        val entry: OrbRow
    ) : OrbNavScreen()
}

@Composable
fun OrbAppRoot(
    core: OrbCore,
    modifier: Modifier = Modifier,
    debugShowSetup: Boolean = false
) {
    val context = LocalContext.current
    remember(context) {
        OrbProjectAppearance.init(context)
        OrbMissionUnreadStore.init(context)
        OrbInboxModel.init(context)
        OrbInboxSettings.init(context)
        OrbInboxDigestStore.init(context)
        OrbNotifications.init(context)
        true
    }

    val baseURL by core.baseURLFlow.collectAsState()
    val hasLoaded by core.hasLoadedSuccessfully.collectAsState()
    val projects by core.projects.collectAsState()
    val missions by core.missions.collectAsState()
    val pendingFocus by core.pendingProjectFocus.collectAsState()
    val pendingMission by core.pendingMissionFocus.collectAsState()
    val pendingDocs by core.pendingDocumentsFocus.collectAsState()
    val pendingInbox by core.pendingInboxOpen.collectAsState()
    val pendingSettings by core.pendingSettingsOpen.collectAsState()

    val backStack = remember { mutableStateOf<List<OrbNavScreen>>(listOf(OrbNavScreen.Home)) }
    var topTab by remember { mutableStateOf(OrbTopTab.Projects) }
    var showSettingsSheet by remember { mutableStateOf(false) }
    var settingsInitialRoute by remember { mutableStateOf(OrbSettingsRoute.Root) }
    val pendingSecrets by core.pendingSecretRequests.collectAsState()
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, baseURL) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            OrbPresentation.monitor(core)
        }
    }


    // Poll the Bitwarden broker every 10 s while the app is visible (Orb App.tsx),
    // so a mission blocked on a secret request is noticed from the main screen.
    // Fleet Bunker Mode and approval-device enrollment, shown on Home like iOS.
    val homeContext = androidx.compose.ui.platform.LocalContext.current
    val homeActivity = homeContext.fragmentActivity()
    val homeScope = rememberCoroutineScope()
    var bunkerState by remember(baseURL) { mutableStateOf(0) }
    var bunkerReason by remember(baseURL) { mutableStateOf<String?>(null) }
    var bunkerDismissedLevel by remember(baseURL) { mutableStateOf(0) }
    var bunkerError by remember(baseURL) { mutableStateOf<String?>(null) }
    var approvalMode by remember(baseURL) { mutableStateOf("") }
    var approvalEnrolled by remember(baseURL) { mutableStateOf(true) }
    var approvalQueueCount by remember(baseURL) { mutableStateOf<Int?>(null) }
    val enrollPrefs = remember { homeContext.getSharedPreferences("orb.approval.prompt", android.content.Context.MODE_PRIVATE) }
    var enrollDismissedMode by remember(baseURL) { mutableStateOf(enrollPrefs.getString("dismissed.$baseURL", null)) }
    suspend fun refreshFleetPosture() {
        runCatching {
            val snap = OrbJSON.dict(core.request("/api/privilege-access")) ?: emptyMap()
            val mesh = runCatching { OrbJSON.dict(core.request("/api/mesh/status")) ?: emptyMap() }.getOrDefault(emptyMap())
            bunkerState = maxOf((snap["bunker_state"] as? Number)?.toInt() ?: 0, (mesh["bunker_state"] as? Number)?.toInt() ?: 0)
            bunkerReason = OrbPrivilegeAccess.latestIncidentReason(OrbJSON.dictList(snap["bunker_incidents"]))
            if (bunkerState <= 0) bunkerDismissedLevel = 0
        }
        runCatching {
            val d = OrbJSON.dict(core.request("/api/approvals/devices")) ?: emptyMap()
            approvalMode = OrbJSON.str(d, "mode") ?: ""
            approvalEnrolled = OrbPrivilegeAccess.isEnrolled(OrbApprovalKey.publicKey(), OrbJSON.dictList(d["devices"]))
        }
        try {
            val items = OrbJSON.dictList(OrbJSON.dict(core.request("/api/approvals/queue"))?.get("items"))
            approvalQueueCount = items.size
        } catch (e: OrbError) {
            if (e.status == 404 || e.status == 405) approvalQueueCount = null
        } catch (_: Throwable) {
        }
    }

    LaunchedEffect(baseURL, lifecycleOwner) {
        if (baseURL.trim().isEmpty()) return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) {
                core.refreshSecretRequests()
                refreshFleetPosture()
                kotlinx.coroutines.delay(10_000)
            }
        }
    }

    fun push(screen: OrbNavScreen) {
        backStack.value = backStack.value + screen
    }

    fun pop() {
        if (backStack.value.size > 1) {
            backStack.value = backStack.value.dropLast(1)
        }
    }

    LaunchedEffect(baseURL) {
        if (baseURL.trim().isNotEmpty()) {
            core.refreshAll()
        }
    }

    LaunchedEffect(pendingInbox, OrbNotifications.pendingInboxFocus, OrbInboxSettings.inboxEnabled) {
        if (!OrbInboxSettings.inboxEnabled && topTab == OrbTopTab.Inbox) {
            topTab = OrbTopTab.Projects
            return@LaunchedEffect
        }
        if (((pendingInbox && core.consumeInboxOpen()) || OrbNotifications.pendingInboxFocus != null) && OrbInboxSettings.inboxEnabled) {
            showSettingsSheet = false
            backStack.value = listOf(OrbNavScreen.Home)
            topTab = OrbTopTab.Inbox
        }
    }

    LaunchedEffect(pendingSettings) {
        if (pendingSettings && core.consumeSettingsOpen()) {
            showSettingsSheet = true
        }
    }

    LaunchedEffect(pendingFocus, projects) {
        val target = pendingFocus ?: return@LaunchedEffect
        if (projects.isEmpty()) return@LaunchedEffect
        val matched = projects.firstOrNull { p ->
            val slug = (p.str("slug", "id") ?: "").lowercase()
            val name = (p.str("name", "title") ?: "").lowercase()
            slug == target.lowercase() || name == target.lowercase()
        }
        if (matched != null) {
            core.consumeProjectFocus()
            showSettingsSheet = false
            backStack.value = listOf(OrbNavScreen.Home, OrbNavScreen.Project(matched))
        }
    }

    LaunchedEffect(pendingDocs, projects) {
        val target = pendingDocs ?: return@LaunchedEffect
        if (projects.isEmpty()) return@LaunchedEffect
        val matched = projects.firstOrNull { p ->
            val slug = (p.str("slug", "id") ?: "").lowercase()
            val name = (p.str("name", "title") ?: "").lowercase()
            slug == target.lowercase() || name == target.lowercase()
        }
        if (matched != null) {
            core.consumeDocumentsFocus()
            showSettingsSheet = false
            backStack.value = listOf(
                OrbNavScreen.Home,
                OrbNavScreen.Project(matched),
                OrbNavScreen.Documents(matched, "")
            )
        }
    }

    LaunchedEffect(pendingMission, projects, missions) {
        val targetId = pendingMission ?: return@LaunchedEffect
        val matchedMission = missions.firstOrNull { it.id == targetId || it.id.startsWith(targetId) }
            ?: OrbRow(targetId, mapOf("id" to targetId))
        val proj = OrbInboxModel.resolveProject(matchedMission, projects)
        core.consumeMissionFocus()
        showSettingsSheet = false
        backStack.value = listOf(
            OrbNavScreen.Home,
            OrbNavScreen.Conversation(proj, matchedMission)
        )
    }

    androidx.activity.compose.BackHandler(enabled = backStack.value.size > 1) {
        pop()
    }

    if ((baseURL.trim().isEmpty() && !hasLoaded) || debugShowSetup) {
        OrbSafeDrawingRoot(modifier = modifier) {
            OrbSetupView(
                core = core,
                title = "Connect to Orb",
                onConnected = {}
            )
        }
        return
    }

    val currentScreen = backStack.value.lastOrNull() ?: OrbNavScreen.Home
    // One page event per main screen (and Home tab); the settings sheet tracks its own pages.
    TrackPage(
        screen = when (currentScreen) {
            is OrbNavScreen.Home -> if (topTab == OrbTopTab.Inbox) "inbox" else "home"
            is OrbNavScreen.Project -> "project"
            is OrbNavScreen.Conversation -> "conversation"
            is OrbNavScreen.Documents -> "documents"
            is OrbNavScreen.DocumentViewer -> "document_viewer"
        },
        surface = UsageTelemetry.Surface.Screen
    )
    val totalWaitingApprovals = approvalQueueCount ?: pendingSecrets
    val showBunkerBanner = OrbPrivilegeAccess.showsBunkerCard(bunkerState, bunkerDismissedLevel)
    val showEnrollBanner = OrbPrivilegeAccess.shouldPromptEnrollment(approvalMode, approvalEnrolled, enrollDismissedMode)

    @Composable
    fun BunkerBannerContent() {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(OrbStyle.elevated)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lock, contentDescription = null, tint = Color(0xFFFF6B6B), modifier = Modifier.size(15.dp))
                Text(
                    "Fleet Bunker Mode: ${OrbPrivilegeAccess.bunkerLabel(bunkerState)}",
                    color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f).padding(start = 8.dp)
                )
                Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = OrbStyle.textMuted,
                    modifier = Modifier.size(18.dp).orbPressClickable { bunkerDismissedLevel = bunkerState })
            }
            bunkerReason?.let { Text(it, color = OrbStyle.textSecondary, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            bunkerError?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 12.sp) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = {
                    settingsInitialRoute = OrbSettingsRoute.Secrets
                    showSettingsSheet = true
                }) { Text("Review") }
                TextButton(onClick = {
                    homeScope.launch {
                        bunkerError = runCatching {
                            OrbApprovalKey.signedRequest(core, homeActivity, "POST", "/api/privilege-access/unbunker", null, "exit Fleet Bunker Mode")
                            refreshFleetPosture()
                        }.exceptionOrNull()?.message
                    }
                }) { Text("Exit Bunker Mode") }
            }
        }
    }

    OrbSafeDrawingRoot(modifier = modifier) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (currentScreen !is OrbNavScreen.Home && showBunkerBanner) {
                Box(modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                    BunkerBannerContent()
                }
            }
            Box(modifier = Modifier.weight(1f)) {
                when (currentScreen) {
                    is OrbNavScreen.Home -> {
                        OrbHomeScreen(
                            core = core,
                            selectedTab = topTab,
                            onSelectTab = { topTab = it },
                            onOpenSettings = { showSettingsSheet = true },
                            onChangeServer = {
                                settingsInitialRoute = OrbSettingsRoute.Backend
                                showSettingsSheet = true
                            },
                            onSelectProject = { proj -> push(OrbNavScreen.Project(proj)) },
                            onSelectMission = { mission, proj ->
                                push(OrbNavScreen.Conversation(proj, mission))
                            },
                            bannerContent = {
                                if (showBunkerBanner || totalWaitingApprovals > 0 || showEnrollBanner) {
                                    Column(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(horizontal = 18.dp, vertical = 4.dp),
                                        verticalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        if (showBunkerBanner) {
                                            BunkerBannerContent()
                                        }
                                        if (totalWaitingApprovals > 0) {
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .clip(RoundedCornerShape(12.dp))
                                                    .background(OrbStyle.warning.copy(alpha = 0.14f))
                                                    .border(1.dp, OrbStyle.warning.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
                                                    .orbPressClickable {
                                                        settingsInitialRoute = OrbSettingsRoute.Secrets
                                                        showSettingsSheet = true
                                                    }
                                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                                            ) {
                                                Icon(Icons.Default.Lock, contentDescription = null, tint = OrbStyle.warning, modifier = Modifier.size(14.dp))
                                                Text(
                                                    text = "$totalWaitingApprovals approval${if (totalWaitingApprovals == 1) "" else "s"} waiting",
                                                    color = Color.White,
                                                    fontSize = 13.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Text(
                                                    text = "Review",
                                                    color = OrbStyle.warning,
                                                    fontSize = 12.sp,
                                                    fontWeight = FontWeight.SemiBold
                                                )
                                            }
                                        }
                                        if (showEnrollBanner) {
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .clip(RoundedCornerShape(12.dp))
                                                    .background(OrbStyle.surface)
                                                    .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                                                    .orbPressClickable {
                                                        settingsInitialRoute = OrbSettingsRoute.Secrets
                                                        showSettingsSheet = true
                                                    }
                                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                                            ) {
                                                Icon(Icons.Default.Lock, contentDescription = null, tint = OrbStyle.inboxBlue, modifier = Modifier.size(14.dp))
                                                Text(
                                                    text = "Enroll this phone for biometric approvals",
                                                    color = Color.White,
                                                    fontSize = 13.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Text(
                                                    text = "Enroll",
                                                    color = OrbStyle.inboxBlue,
                                                    fontSize = 12.sp,
                                                    fontWeight = FontWeight.SemiBold
                                                )
                                                Icon(
                                                    Icons.Default.Close,
                                                    contentDescription = "Dismiss",
                                                    tint = OrbStyle.textMuted,
                                                    modifier = Modifier.size(16.dp).orbPressClickable {
                                                        enrollDismissedMode = approvalMode
                                                        enrollPrefs.edit().putString("dismissed.$baseURL", approvalMode).apply()
                                                    }
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        )
                    }
                    is OrbNavScreen.Project -> {
                        OrbProjectPage(
                            core = core,
                            project = currentScreen.project,
                            onBack = { pop() },
                            onOpenMission = { mission ->
                                push(OrbNavScreen.Conversation(currentScreen.project, mission))
                            },
                            onNewAgent = { folder ->
                                push(OrbNavScreen.Conversation(currentScreen.project, null, folder))
                            },
                            onOpenDocuments = { dirPath ->
                                push(OrbNavScreen.Documents(currentScreen.project, dirPath))
                            }
                        )
                    }
                    is OrbNavScreen.Conversation -> {
                        OrbConversationPage(
                            core = core,
                            project = currentScreen.project,
                            initialMission = currentScreen.mission,
                            initialFolder = currentScreen.initialFolder,
                            onBack = { pop() }
                        )
                    }
                    is OrbNavScreen.Documents -> {
                        OrbProjectDocumentsPage(
                            core = core,
                            project = currentScreen.project,
                            directoryPath = currentScreen.directoryPath,
                            onBack = { pop() },
                            onOpenDirectory = { nextDir ->
                                push(OrbNavScreen.Documents(currentScreen.project, nextDir))
                            },
                            onOpenFile = { entry ->
                                push(OrbNavScreen.DocumentViewer(currentScreen.project, entry))
                            }
                        )
                    }
                    is OrbNavScreen.DocumentViewer -> {
                        OrbProjectDocumentViewer(
                            core = core,
                            project = currentScreen.project,
                            entry = currentScreen.entry,
                            onBack = { pop() }
                        )
                    }
                }
            }
        }
    }

    // FIDO / SSH signing approvals: listen only while signed in and visible.
    val fidoToken by core.tokenFlow.collectAsState()
    LaunchedEffect(baseURL, fidoToken, lifecycleOwner) {
        if (baseURL.trim().isEmpty() || fidoToken.isNullOrBlank()) {
            OrbFido.clear()
            return@LaunchedEffect
        }
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            OrbFido.listen(core)
        }
    }
    OrbFidoApprovalDialog(core = core)

    if (showSettingsSheet) {
        OrbSettingsSheet(
            core = core,
            initialRoute = settingsInitialRoute,
            onDismiss = {
                showSettingsSheet = false
                settingsInitialRoute = OrbSettingsRoute.Root
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun OrbHomeScreen(
    core: OrbCore,
    selectedTab: OrbTopTab,
    onSelectTab: (OrbTopTab) -> Unit,
    onOpenSettings: () -> Unit,
    onSelectProject: (OrbRow) -> Unit,
    onSelectMission: (mission: OrbRow, project: OrbRow) -> Unit,
    onChangeServer: () -> Unit = onOpenSettings,
    bannerContent: @Composable () -> Unit = {}
) {
    val scope = rememberCoroutineScope()
    val projects by core.projects.collectAsState()
    val missions by core.missions.collectAsState()
    val isLoading by core.isLoading.collectAsState()
    val lastError by core.lastError.collectAsState()
    val connectionIssue by core.connectionIssue.collectAsState()
    val lastErrorLog by core.lastErrorLog.collectAsState()

    var searchQuery by remember { mutableStateOf("") }
    var isRefreshing by remember { mutableStateOf(false) }
    var showNewProjectDialog by remember { mutableStateOf(false) }
    var newProjectName by remember { mutableStateOf("") }
    var newProjectRepo by remember { mutableStateOf("") }

    var contextMenuProject by remember { mutableStateOf<OrbRow?>(null) }
    var renameProjectTarget by remember { mutableStateOf<OrbRow?>(null) }
    var renameDraft by remember { mutableStateOf("") }
    var colorPickerProject by remember { mutableStateOf<OrbRow?>(null) }

    val inboxCount = remember(projects, missions, OrbInboxModel.revision, OrbMissionUnreadStore.revision) {
        OrbInboxModel.actionableCount(projects, missions)
    }

    val liveMissionsCount = remember(projects, missions) {
        OrbInboxModel.workingMissions(projects, missions).size
    }

    val visibleProjects = remember(projects, missions, searchQuery) {
        val activeList = projects.filterNot { p ->
            val st = (p.str("status", "state") ?: "").lowercase()
            st == "archived" || st == "deleted" || p.bool("archived") == true
        }
        if (searchQuery.trim().isEmpty()) {
            activeList
        } else {
            val q = searchQuery.trim().lowercase()
            activeList.filter { p ->
                val name = (p.str("title", "name", "slug") ?: "").lowercase()
                name.contains(q)
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top bar matching iOS OrbHome toolbar exactly:
            // Leading: person.crop.circle in 44dp circle
            // Center: Projects | Inbox segmented capsule
            // Trailing: folder.badge.plus in 44dp circle
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 18.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .semantics { contentDescription = "Settings" }
                        .orbPressClickable { onOpenSettings() },
                    contentAlignment = Alignment.Center
                ) {
                    OrbSfIcons.PersonCropCircle(color = Color.White, size = 21.dp)
                }

                // Shared quiet navigation treatment with the iOS home picker.
                Row(
                    modifier = Modifier.padding(3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    val isProjects = selectedTab == OrbTopTab.Projects
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(OrbStyle.controlRadius))
                            .background(if (isProjects) OrbStyle.elevated else Color.Transparent)
                            .orbPressClickable { onSelectTab(OrbTopTab.Projects) }
                            .padding(horizontal = 11.dp, vertical = 5.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "Projects",
                            color = if (isProjects) Color.White else OrbStyle.textSecondary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            softWrap = false
                        )
                    }

                    if (OrbInboxSettings.inboxEnabled) {
                        val isInbox = selectedTab == OrbTopTab.Inbox
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                .background(if (isInbox) OrbStyle.elevated else Color.Transparent)
                                .orbPressClickable { onSelectTab(OrbTopTab.Inbox) }
                                .padding(horizontal = 11.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            Text(
                                text = "Inbox",
                                color = if (isInbox) Color.White else OrbStyle.textSecondary,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                softWrap = false
                            )
                            if (inboxCount > 0) {
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(OrbStyle.controlRadius))
                                        .background(if (isInbox) Color.White else OrbStyle.card)
                                        .padding(horizontal = 6.dp, vertical = 1.5.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(
                                        text = "$inboxCount",
                                        color = if (isInbox) OrbStyle.background else Color.White,
                                        fontSize = 10.5.sp,
                                        fontWeight = FontWeight.Bold,
                                        fontFamily = FontFamily.Monospace,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .semantics { contentDescription = "New project" }
                        .orbPressClickable {
                            newProjectName = ""
                            newProjectRepo = ""
                            showNewProjectDialog = true
                        },
                    contentAlignment = Alignment.Center
                ) {
                    OrbSfIcons.FolderBadgePlus(color = Color.White, size = 22.dp)
                }
            }

            bannerContent()

            if (selectedTab == OrbTopTab.Inbox && OrbInboxSettings.inboxEnabled) {
                OrbInboxView(
                    core = core,
                    onSelectMission = onSelectMission,
                    onSelectProject = onSelectProject,
                    modifier = Modifier.weight(1f)
                )
            } else {
                PullToRefreshBox(
                    isRefreshing = isRefreshing,
                    onRefresh = {
                        scope.launch {
                            isRefreshing = true
                            core.refreshAll()
                            isRefreshing = false
                        }
                    },
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                ) {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(
                            start = 18.dp,
                            end = 18.dp,
                            top = 4.dp,
                            bottom = 96.dp
                        )
                    ) {
                        if (OrbMoveClipboard.mission != null) {
                            item(key = "move_banner") { OrbMoveBanner(modifier = Modifier.padding(vertical = 6.dp)) }
                        }
                        val issue = connectionIssue
                        if (issue != null) {
                            item(key = "home_connection_issue") {
                                OrbConnectionIssueCard(
                                    issue = issue,
                                    log = lastErrorLog,
                                    onChangeServer = onChangeServer,
                                    onUseDefault = { scope.launch { core.useDefaultServer() } },
                                    modifier = Modifier.padding(vertical = 6.dp)
                                )
                            }
                        } else lastError?.let { err ->
                            item(key = "home_error") {
                                OrbNotice(
                                    title = err,
                                    log = lastErrorLog,
                                    modifier = Modifier.padding(vertical = 6.dp)
                                )
                            }
                        }

                        if (isLoading && visibleProjects.isEmpty()) {
                            items(5) {
                                OrbSkeletonRow()
                            }
                        } else {
                            items(visibleProjects, key = { it.id }) { proj ->
                                val pName = proj.str("title", "name", "slug") ?: proj.id
                                val pColor = OrbProjectAppearance.color(proj)
                                // Last activity across the project's missions, not the project record's
                                // own edit time (every project showed "1w" while missions ran today).
                                val latestTime = remember(proj, missions, projects) {
                                    latestActivityRelative(proj, missionsForProject(proj, missions, projects))
                                }
                                val projectWorkingCount = remember(proj, missions, projects) {
                                    missionsForProject(proj, missions, projects).count { m ->
                                        OrbMissionTree.isLive(m)
                                    }
                                }

                                Box {
                                    Column {
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .combinedClickable(
                                                    onClick = { onSelectProject(proj) },
                                                    onLongClick = { contextMenuProject = proj }
                                                )
                                                .padding(vertical = 12.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(14.dp)
                                        ) {
                                            OrbSfIcons.FolderOutline(
                                                color = pColor,
                                                size = 20.dp
                                            )
                                            Text(
                                                text = pName,
                                                color = Color.White,
                                                fontSize = 17.sp,
                                                fontWeight = FontWeight.Medium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                modifier = Modifier.weight(1f)
                                            )
                                            if (projectWorkingCount > 0) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                                                ) {
                                                    OrbRunningDots(
                                                        color = Color.White,
                                                        dotSize = 2.0.dp,
                                                        spacing = 2.0.dp
                                                    )
                                                    Text(
                                                        text = "$projectWorkingCount working",
                                                        color = OrbStyle.textSecondary,
                                                        fontSize = 12.sp,
                                                        fontFamily = FontFamily.Monospace,
                                                        maxLines = 1,
                                                        softWrap = false
                                                    )
                                                }
                                            }
                                            if (latestTime.isNotEmpty()) {
                                                Text(
                                                    text = latestTime,
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 12.sp,
                                                    fontFamily = FontFamily.Monospace,
                                                    maxLines = 1,
                                                    softWrap = false
                                                )
                                            }
                                            OrbSfIcons.ChevronRightSmall(
                                                color = OrbStyle.textMuted,
                                                size = 11.dp
                                            )
                                        }
                                        HorizontalDivider(
                                            color = OrbStyle.border,
                                            thickness = 0.5.dp,
                                            modifier = Modifier.padding(start = 34.dp)
                                        )
                                    }

                                    DropdownMenu(
                                        expanded = contextMenuProject?.id == proj.id,
                                        onDismissRequest = { contextMenuProject = null },
                                        containerColor = OrbStyle.elevated
                                    ) {
                                        val dropSlug = OrbProjectAppearance.slug(proj)
                                        if (OrbMoveClipboard.canDrop(dropSlug, "")) {
                                            DropdownMenuItem(
                                                text = { Text("Move here", color = Color.White) },
                                                leadingIcon = { Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White) },
                                                onClick = {
                                                    contextMenuProject = null
                                                    scope.launch {
                                                        orbTry(OrbLog.Category.Network, "OrbMoveClipboard.drop") {
                                                            OrbMoveClipboard.drop(core, dropSlug, "")
                                                            core.refreshMissionsQuietly()
                                                        }
                                                    }
                                                }
                                            )
                                            HorizontalDivider(color = OrbStyle.border)
                                        }
                                        DropdownMenuItem(
                                            text = { Text("Rename", color = Color.White) },
                                            leadingIcon = {
                                                Icon(Icons.Default.Edit, contentDescription = null, tint = Color.White)
                                            },
                                            onClick = {
                                                contextMenuProject = null
                                                renameDraft = pName
                                                renameProjectTarget = proj
                                            }
                                        )
                                        DropdownMenuItem(
                                            text = { Text("Project color", color = Color.White) },
                                            leadingIcon = {
                                                Icon(Icons.Default.Palette, contentDescription = null, tint = Color.White)
                                            },
                                            onClick = {
                                                contextMenuProject = null
                                                colorPickerProject = proj
                                            }
                                        )
                                        DropdownMenuItem(
                                            text = { Text("Archive", color = OrbStyle.error) },
                                            leadingIcon = {
                                                Icon(Icons.Default.Archive, contentDescription = null, tint = OrbStyle.error)
                                            },
                                            onClick = {
                                                contextMenuProject = null
                                                val slug = proj.str("slug", "id") ?: proj.id
                                                scope.launch {
                                                    orbTry(OrbLog.Category.Network, "core.request") {
                                                        core.request(
                                                            "/api/projects/${core.encodeComponent(slug)}/action",
                                                            method = "POST",
                                                            body = mapOf("action" to "archive")
                                                        )
                                                        core.refreshMissionsQuietly()
                                                    }
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Bottom Search Bar on Projects Tab
        if (selectedTab == OrbTopTab.Projects) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(OrbStyle.background.copy(alpha = 0.94f))
                    .padding(horizontal = 18.dp, vertical = 12.dp)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Search,
                        contentDescription = "Search",
                        tint = OrbStyle.textMuted,
                        modifier = Modifier.size(17.dp)
                    )
                    Box(modifier = Modifier.weight(1f)) {
                        if (searchQuery.isEmpty()) {
                            Text(
                                text = "Search projects",
                                color = OrbStyle.textMuted,
                                fontSize = 15.sp
                            )
                        }
                        BasicTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                            cursorBrush = SolidColor(Color.White),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                    if (searchQuery.isNotEmpty()) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Clear",
                            tint = OrbStyle.textMuted,
                            modifier = Modifier
                                .size(16.dp)
                                .orbPressClickable { searchQuery = "" }
                        )
                    }
                }
            }
        }
    }

    // New Project Dialog
    if (showNewProjectDialog) {
        AlertDialog(
            onDismissRequest = { showNewProjectDialog = false },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            textContentColor = Color.White,
            title = { Text("New project", fontWeight = FontWeight.SemiBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        if (newProjectName.isEmpty()) {
                            Text("Project name", color = OrbStyle.textMuted, fontSize = 14.sp)
                        }
                        BasicTextField(
                            value = newProjectName,
                            onValueChange = { newProjectName = it },
                            textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                            cursorBrush = SolidColor(Color.White),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val name = newProjectName.trim()
                        if (name.isNotEmpty()) {
                            val slug = name.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
                            showNewProjectDialog = false
                            scope.launch {
                                orbTry(OrbLog.Category.Network, "core.request") {
                                    core.request(
                                        "/api/projects",
                                        method = "PUT",
                                        body = mapOf("slug" to slug, "title" to name)
                                    )
                                    core.refreshAll()
                                }
                            }
                        }
                    }
                ) {
                    Text("Create", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showNewProjectDialog = false }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    // Rename Project Dialog
    renameProjectTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { renameProjectTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Rename project", fontWeight = FontWeight.SemiBold) },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    BasicTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val slug = target.str("slug", "id") ?: target.id
                        val nextName = renameDraft.trim()
                        renameProjectTarget = null
                        if (nextName.isNotEmpty()) {
                            scope.launch {
                                orbTry(OrbLog.Category.Network, "core.request") {
                                    core.request(
                                        "/api/projects",
                                        method = "PUT",
                                        body = mapOf("slug" to slug, "title" to nextName)
                                    )
                                    core.refreshMissionsQuietly()
                                }
                            }
                        }
                    }
                ) {
                    Text("Save", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { renameProjectTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    // Project Color Dialog
    colorPickerProject?.let { target ->
        OrbColorPickerDialog(
            project = target,
            core = core,
            onDismiss = { colorPickerProject = null }
        )
    }
}

@Composable
fun OrbColorPickerDialog(
    project: OrbRow,
    core: OrbCore,
    onDismiss: () -> Unit
) {
    val currentHex = OrbProjectAppearance.hex(project)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = OrbStyle.elevated,
        titleContentColor = Color.White,
        title = { Text("Project color", fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OrbProjectAppearance.presets.forEach { preset ->
                    val swatch = OrbProjectAppearance.colorFromHex(preset.hex) ?: OrbStyle.icon
                    val selected = currentHex.equals(preset.hex, ignoreCase = true)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (selected) OrbStyle.card else Color.Transparent)
                            .orbPressClickable {
                                OrbProjectAppearance.setColor(preset.hex, project, core)
                                onDismiss()
                            }
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OrbSfIcons.FolderOutline(
                            color = swatch,
                            size = 18.dp
                        )
                        Text(
                            text = preset.name,
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                        if (selected) {
                            Icon(
                                imageVector = Icons.Default.Check,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Close", color = OrbStyle.textSecondary)
            }
        }
    )
}

enum class OrbProjectFilter(val label: String) {
    All("All"),
    Working("Working"),
    NeedsAttention("Needs attention"),
    Archived("Archived")
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun OrbProjectPage(
    core: OrbCore,
    project: OrbRow,
    onBack: () -> Unit,
    onOpenMission: (OrbRow) -> Unit,
    onNewAgent: (folder: String?) -> Unit,
    onOpenDocuments: (directoryPath: String) -> Unit
) {
    val scope = rememberCoroutineScope()
    val missions by core.missions.collectAsState()
    val projects by core.projects.collectAsState()

    val liveProject = remember(project, projects) {
        val slug = OrbProjectAppearance.slug(project)
        projects.firstOrNull { OrbProjectAppearance.slug(it) == slug } ?: project
    }
    val projectName = remember(liveProject) {
        liveProject.str("title", "name", "slug") ?: liveProject.id
    }

    var searchQuery by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(OrbProjectFilter.All) }
    var showMenu by remember { mutableStateOf(false) }
    var showColorDialog by remember { mutableStateOf(false) }
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var newFolderParent by remember { mutableStateOf("") }
    var newFolderDraft by remember { mutableStateOf("") }
    var isRefreshing by remember { mutableStateOf(false) }
    var folderActionError by remember { mutableStateOf<String?>(null) }

    val expandedParents = remember { mutableStateMapOf<String, Boolean>() }
    val collapsedFolders = remember { mutableStateMapOf<String, Boolean>() }
    val customFolders = remember { mutableStateMapOf<String, Boolean>() }
    var contextMenuMission by remember { mutableStateOf<OrbRow?>(null) }
    var contextMenuFolder by remember { mutableStateOf<String?>(null) }
    var renameFolderTarget by remember { mutableStateOf<String?>(null) }
    var renameFolderDraft by remember { mutableStateOf("") }
    var moveFolderTarget by remember { mutableStateOf<String?>(null) }
    var moveFolderDraft by remember { mutableStateOf("") }
    var deleteFolderTarget by remember { mutableStateOf<String?>(null) }
    var deleteMissionTarget by remember { mutableStateOf<OrbRow?>(null) }
    var renameMissionTarget by remember { mutableStateOf<OrbRow?>(null) }
    var settingsMissionTarget by remember { mutableStateOf<OrbRow?>(null) }
    var renameMissionDraft by remember { mutableStateOf("") }

    val projectSlug = remember(liveProject) {
        OrbProjectAppearance.slug(liveProject)
    }

    var fetchedProjectMissions by remember(projectSlug) {
        mutableStateOf(OrbReadCache.readMemoryRows("project_missions_$projectSlug"))
    }
    var manifestFolders by remember(projectSlug) {
        val cachedManifest = OrbReadCache.loadDict("project_manifest_$projectSlug")
        val entries = OrbJSON.dict(cachedManifest?.get("entries"))
        val initialDirs = entries?.mapNotNull { (k, v) ->
            val d = OrbJSON.dict(v)
            if (OrbJSON.bool(d, "directory") == true && k != "attachments" && !k.startsWith("attachments/")) k else null
        } ?: emptyList()
        mutableStateOf(initialDirs)
    }

    suspend fun loadProjectData() {
        val encoded = core.encodeComponent(projectSlug)
        kotlinx.coroutines.coroutineScope {
            val missionsTask = async {
                orbTry(OrbLog.Category.Network, "/api/control/missions") {
                    core.fetchRows("/api/control/missions?project=$encoded&all=true&limit=100&offset=0", null)
                }.getOrNull()
            }
            val manifestTask = async {
                orbTry(OrbLog.Category.Network, "/api/projects") {
                    core.fetchDict("/api/projects/$encoded/context/manifest")
                }.getOrNull()
            }
            val rows = missionsTask.await()
            if (rows != null) {
                val mobile = OrbMissionTree.filterMobile(rows)
                fetchedProjectMissions = mobile
                OrbReadCache.saveRows("project_missions_$projectSlug", mobile)
                for (m in mobile) {
                    val hist = m.rows("history")
                    if (hist.isNotEmpty()) {
                        OrbReadCache.saveRows("mission_msgs_${m.id}", hist)
                    }
                }
                // Prefetch top 5 missions' events in background
                launch(kotlinx.coroutines.Dispatchers.IO) {
                    for (m in mobile.take(5)) {
                        val evKey = "mission_events_${m.id}"
                        if (OrbReadCache.loadRows(evKey).isEmpty()) {
                            val evs = orbTry(OrbLog.Category.Network, "/api/control/missions") {
                                core.fetchRows("/api/control/missions/${core.encodeComponent(m.id)}/events?limit=150", "events")
                            }.getOrDefault(emptyList())
                            if (evs.isNotEmpty()) {
                                OrbReadCache.saveRows(evKey, evs)
                            }
                        }
                    }
                }
            }
            val manifest = manifestTask.await()
            if (manifest != null) {
                OrbReadCache.saveDict("project_manifest_$projectSlug", manifest)
                val entries = OrbJSON.dict(manifest["entries"])
                if (entries != null) {
                    val dirs = entries.mapNotNull { (k, v) ->
                        val d = OrbJSON.dict(v)
                        if (OrbJSON.bool(d, "directory") == true && k != "attachments" && !k.startsWith("attachments/")) k else null
                    }
                    manifestFolders = dirs
                }
            }
        }
    }

    LaunchedEffect(projectSlug) {
        val cached = OrbReadCache.loadRowsAsync("project_missions_$projectSlug")
        if (fetchedProjectMissions.isEmpty() && cached.isNotEmpty()) fetchedProjectMissions = cached
        loadProjectData()
    }

    val projectMissions = remember(liveProject, fetchedProjectMissions, missions, projects) {
        if (fetchedProjectMissions.isNotEmpty()) {
            fetchedProjectMissions
        } else {
            missionsForProject(liveProject, missions, projects)
        }
    }

    val filteredMissions = remember(projectMissions, filter, searchQuery) {
        val matchesFilter: (OrbRow) -> Boolean = { m ->
            val archived = OrbMissionTree.isArchived(m)
            val passState = when (filter) {
                OrbProjectFilter.All -> !archived
                OrbProjectFilter.Working -> !archived && OrbMissionTree.isLive(m)
                OrbProjectFilter.NeedsAttention -> !archived && isNeedsAttention(m)
                OrbProjectFilter.Archived -> archived
            }
            if (!passState) {
                false
            } else if (searchQuery.trim().isEmpty()) {
                true
            } else {
                val q = searchQuery.trim().lowercase()
                OrbInboxModel.missionHeadline(m).lowercase().contains(q)
            }
        }
        if (searchQuery.trim().isNotEmpty()) {
            projectMissions.filter(matchesFilter)
        } else {
            // Retain parents of visible children (matching iOS OrbMissionTree.treeRows)
            val byId = projectMissions.associateBy { it.id }
            val retained = projectMissions.filter(matchesFilter).map { it.id }.toMutableSet()
            for (m in projectMissions) {
                if (!matchesFilter(m)) continue
                val seen = mutableSetOf(m.id)
                var parent = OrbMissionTree.parentId(m)
                while (parent != null && seen.add(parent)) {
                    val row = byId[parent] ?: break
                    retained.add(parent)
                    parent = OrbMissionTree.parentId(row)
                }
            }
            projectMissions.filter { it.id in retained }
        }
    }

    val nestedRoots = remember(filteredMissions, searchQuery) {
        if (searchQuery.trim().isNotEmpty()) {
            filteredMissions.map { OrbNestedMission(it, emptyList(), 0) }
        } else {
            OrbMissionTree.nest(filteredMissions)
        }
    }

    val filtering = searchQuery.trim().isNotEmpty() || filter != OrbProjectFilter.All

    val foldersMap = remember(nestedRoots, manifestFolders, customFolders.keys.toSet(), filtering) {
        val map = linkedMapOf<String, MutableList<OrbNestedMission>>()
        val allPaths = sortedSetOf<String>()
        val sources = (if (filtering) emptyList() else (manifestFolders + customFolders.keys)) +
            nestedRoots.mapNotNull { OrbMissionTree.folderPath(it.mission) }
        for (path in sources) {
            if (path.isEmpty()) continue
            allPaths.add(path)
            val parts = path.split("/")
            for (depth in 1..parts.size) {
                allPaths.add(parts.take(depth).joinToString("/"))
            }
        }
        for (folder in allPaths) {
            if (folder.isNotEmpty()) {
                map[folder] = mutableListOf()
            }
        }
        for (node in nestedRoots) {
            val folder = OrbMissionTree.folderPath(node.mission)
            if (!folder.isNullOrEmpty()) {
                map.getOrPut(folder) { mutableListOf() }.add(node)
            }
        }
        map
    }

    val unfiledRoots = remember(nestedRoots) {
        nestedRoots.filter { OrbMissionTree.folderPath(it.mission).isNullOrEmpty() }
    }

    fun toggleArchiveMission(mission: OrbRow) {
        val currentlyArchived = OrbMissionTree.isArchived(mission)
        val nextStatus = if (currentlyArchived) "completed" else "acknowledged"
        scope.launch {
            runCatching {
                // Archiving only changes status, so a live runner is cancelled and
                // must settle first or it keeps working on an archived conversation.
                if (!currentlyArchived && OrbMissionTree.isLive(mission)) {
                    core.request(
                        path = "/api/control/missions/${core.encodeComponent(mission.id)}/cancel",
                        method = "POST"
                    )
                    var stopped = false
                    repeat(30) {
                        if (stopped) return@repeat
                        val latest = OrbRow(mission.id, core.fetchDict("/api/control/missions/${core.encodeComponent(mission.id)}"))
                        if (!OrbMissionTree.isLive(latest)) stopped = true else kotlinx.coroutines.delay(1000)
                    }
                    if (!stopped) {
                        folderActionError = "The agent is still stopping. Try archiving again in a moment."
                        loadProjectData()
                        return@runCatching
                    }
                }
                core.request(
                    path = "/api/control/missions/${core.encodeComponent(mission.id)}/status",
                    method = "POST",
                    body = mapOf("status" to nextStatus)
                )
                loadProjectData()
                core.refreshMissionsQuietly()
            }
        }
    }

    fun pauseOrResumeMission(mission: OrbRow) {
        val paused = (mission.str("status", "state") ?: "").lowercase() == "paused"
        scope.launch {
            orbTry(OrbLog.Category.Network, "core.request") {
                core.request(
                    path = "/api/control/missions/${core.encodeComponent(mission.id)}/${if (paused) "resume" else "pause"}",
                    method = "POST"
                )
                loadProjectData()
                core.refreshMissionsQuietly()
            }.onFailure { folderActionError = it.message ?: "Couldn’t update the agent." }
        }
    }

    // Same guard rails as iOS deleteMissions: a working agent is refused, a paused
    // one is archived first, and a 404 means it is already gone.
    fun performDeleteMission(mission: OrbRow) {
        scope.launch {
            runCatching {
                val path = "/api/control/missions/${core.encodeComponent(mission.id)}"
                val status = (mission.str("status", "state") ?: "").lowercase()
                if (status == "active" || status == "waiting_background") {
                    throw OrbError("Stop or finish this agent before deleting it.")
                }
                if (status == "paused") {
                    core.request("$path/status", method = "POST", body = mapOf("status" to "acknowledged"))
                }
                val uuidRegex = Regex("[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", RegexOption.IGNORE_CASE)
                for (attempt in 0 until 4) {
                    try {
                        core.request("$path?include_descendants=true", method = "DELETE")
                        break
                    } catch (e: OrbError) {
                        if (e.status == 404) break
                        val detail = e.body ?: e.message
                        if (e.status == 409 && attempt < 3 && detail.contains("cannot delete a paused mission", ignoreCase = true)) {
                            val pausedIds = uuidRegex.findAll(detail).map { it.value }.distinct().toList()
                            if (pausedIds.isEmpty()) throw e
                            for (pid in pausedIds) {
                                core.request(
                                    "/api/control/missions/${core.encodeComponent(pid)}/status",
                                    method = "POST",
                                    body = mapOf("status" to "acknowledged")
                                )
                            }
                            continue
                        }
                        throw e
                    }
                }
                OrbReadCache.saveRowsMemoryOnly("mission_msgs_${mission.id}", emptyList())
                loadProjectData()
                core.refreshMissionsQuietly()
            }.onFailure { folderActionError = it.message ?: "Couldn’t delete the agent." }
        }
    }

    fun performRenameMission(mission: OrbRow, rawTitle: String) {
        val title = rawTitle.trim()
        if (title.isEmpty()) return
        scope.launch {
            orbTry(OrbLog.Category.Network, "core.request") {
                core.request(
                    path = "/api/control/missions/${core.encodeComponent(mission.id)}/title",
                    method = "POST",
                    body = mapOf("title" to title)
                )
                loadProjectData()
                core.refreshMissionsQuietly()
            }.onFailure { folderActionError = it.message ?: "Couldn’t rename the conversation." }
        }
    }

    fun dropMovedMission(folder: String) {
        scope.launch {
            orbTry(OrbLog.Category.Network, "OrbMoveClipboard.drop") {
                OrbMoveClipboard.drop(core, projectSlug, folder)
                loadProjectData()
                core.refreshMissionsQuietly()
            }.onFailure { folderActionError = it.message ?: "Couldn’t move the conversation." }
        }
    }

    suspend fun migrateFolderMissions(oldPath: String, destination: String) {
        val affected = projectMissions.filter { m ->
            val f = OrbMissionTree.folderPath(m) ?: ""
            f == oldPath || f.startsWith("$oldPath/")
        }
        for (m in affected) {
            val f = OrbMissionTree.folderPath(m) ?: ""
            val suffix = f.removePrefix(oldPath)
            val targetFolder = destination + suffix
            val tags = OrbJSON.strList(m.raw, "tags")
                .filter { it.isNotEmpty() && !it.startsWith("orb-folder:") }
                .toMutableList()
            if (targetFolder.isNotEmpty()) {
                tags.add("orb-folder:$targetFolder")
            }
            orbTry(OrbLog.Category.Network, "core.request") {
                core.request(
                    path = "/api/control/missions/${core.encodeComponent(m.id)}/project",
                    method = "POST",
                    body = mapOf("project" to projectSlug, "tags" to tags)
                )
            }
        }
    }

    fun performRenameFolder(folderPath: String, rawNewName: String) {
        val input = rawNewName.trim()
        if (input.isEmpty() || input.contains("/") || input.contains("\\")) {
            folderActionError = "Enter a folder name without slashes."
            return
        }
        val parent = if (folderPath.contains('/')) folderPath.substringBeforeLast('/') else ""
        val destination = if (parent.isEmpty()) input else "$parent/$input"
        if (destination == folderPath) return
        folderActionError = null
        scope.launch {
            try {
                val encoded = core.encodeComponent(projectSlug)
                val inManifest = manifestFolders.any { it == folderPath || it.startsWith("$folderPath/") }
                if (inManifest) {
                    core.request(
                        path = "/api/projects/$encoded/file/transfer",
                        method = "POST",
                        body = mapOf("path" to folderPath, "destination" to destination, "copy" to false)
                    )
                } else {
                    core.request(
                        path = "/api/projects/$encoded/file/mkdir",
                        method = "POST",
                        body = mapOf("path" to destination)
                    )
                }
                customFolders.remove(folderPath)
                customFolders[destination] = true
                migrateFolderMissions(folderPath, destination)
                loadProjectData()
                core.refreshMissionsQuietly()
            } catch (e: Throwable) {
                folderActionError = e.message ?: "Failed to rename folder"
            }
        }
    }

    fun performMoveFolder(folderPath: String, rawDestParent: String) {
        val parent = rawDestParent.trim().trim('/')
        val base = folderPath.substringAfterLast('/')
        val destination = if (parent.isEmpty()) base else "$parent/$base"
        if (destination == folderPath) return
        if (destination.startsWith("$folderPath/")) {
            folderActionError = "Cannot move a folder inside itself."
            return
        }
        folderActionError = null
        scope.launch {
            try {
                val encoded = core.encodeComponent(projectSlug)
                val inManifest = manifestFolders.any { it == folderPath || it.startsWith("$folderPath/") }
                if (inManifest) {
                    core.request(
                        path = "/api/projects/$encoded/file/transfer",
                        method = "POST",
                        body = mapOf("path" to folderPath, "destination" to destination, "copy" to false)
                    )
                } else {
                    core.request(
                        path = "/api/projects/$encoded/file/mkdir",
                        method = "POST",
                        body = mapOf("path" to destination)
                    )
                }
                customFolders.remove(folderPath)
                customFolders[destination] = true
                migrateFolderMissions(folderPath, destination)
                loadProjectData()
                core.refreshMissionsQuietly()
            } catch (e: Throwable) {
                folderActionError = e.message ?: "Failed to move folder"
            }
        }
    }

    fun performDeleteFolder(folderPath: String) {
        val hasActiveOrCompletedMissions = projectMissions.any { m ->
            if (OrbMissionTree.isArchived(m)) return@any false
            val f = OrbMissionTree.folderPath(m) ?: ""
            f == folderPath || f.startsWith("$folderPath/")
        }
        if (hasActiveOrCompletedMissions) {
            folderActionError = "Move or archive the agents in \"$folderPath\" before deleting it."
            return
        }
        folderActionError = null
        scope.launch {
            try {
                val encoded = core.encodeComponent(projectSlug)
                val encodedPath = core.encodeComponent(folderPath)
                core.request(
                    path = "/api/projects/$encoded/file?path=$encodedPath",
                    method = "DELETE"
                )
                val toRemove = customFolders.keys.filter { it == folderPath || it.startsWith("$folderPath/") }
                toRemove.forEach { customFolders.remove(it) }
                manifestFolders = manifestFolders.filterNot { it == folderPath || it.startsWith("$folderPath/") }
                loadProjectData()
            } catch (e: Throwable) {
                folderActionError = e.message ?: "Failed to delete folder"
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top bar matching iOS OrbProjectPage inline navigation bar:
            // Leading: back button
            // Center: inline project title
            // Trailing: + button and ... menu button
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 18.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OrbCircle(
                    icon = Icons.AutoMirrored.Filled.ArrowBack,
                    size = 40.dp,
                    iconSize = 18.dp,
                    modifier = Modifier.orbPressClickable { onBack() }
                )

                Text(
                    text = projectName,
                    color = Color.White,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OrbCircle(
                        icon = Icons.Default.Add,
                        size = 40.dp,
                        iconSize = 19.dp,
                        modifier = Modifier.orbPressClickable { onNewAgent(null) }
                    )

                    Box {
                        OrbCircle(
                            icon = Icons.Default.MoreHoriz,
                            size = 40.dp,
                            iconSize = 19.dp,
                            modifier = Modifier.orbPressClickable { showMenu = true }
                        )
                        DropdownMenu(
                            expanded = showMenu,
                            onDismissRequest = { showMenu = false },
                            containerColor = OrbStyle.elevated
                        ) {
                            OrbProjectFilter.entries.forEach { f ->
                                DropdownMenuItem(
                                    text = { Text("Show: ${f.label}", color = Color.White) },
                                    trailingIcon = {
                                        if (filter == f) {
                                            Icon(Icons.Default.Check, contentDescription = null, tint = Color.White)
                                        }
                                    },
                                    onClick = {
                                        filter = f
                                        showMenu = false
                                    }
                                )
                            }
                            HorizontalDivider(color = OrbStyle.border)
                            if (OrbMoveClipboard.canDrop(projectSlug, "")) {
                                DropdownMenuItem(
                                    text = { Text("Move here (project root)", color = Color.White) },
                                    leadingIcon = { Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White) },
                                    onClick = {
                                        showMenu = false
                                        dropMovedMission("")
                                    }
                                )
                            }
                            DropdownMenuItem(
                                text = { Text("New folder", color = Color.White) },
                                leadingIcon = {
                                    Icon(Icons.Default.CreateNewFolder, contentDescription = null, tint = Color.White)
                                },
                                onClick = {
                                    showMenu = false
                                    newFolderParent = ""
                                    newFolderDraft = ""
                                    showNewFolderDialog = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Project color", color = Color.White) },
                                leadingIcon = {
                                    Icon(Icons.Default.Palette, contentDescription = null, tint = Color.White)
                                },
                                onClick = {
                                    showMenu = false
                                    showColorDialog = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Project context", color = Color.White) },
                                leadingIcon = {
                                    Icon(Icons.Default.Description, contentDescription = null, tint = Color.White)
                                },
                                onClick = {
                                    showMenu = false
                                    onOpenDocuments("")
                                }
                            )
                        }
                    }
                }
            }

            PullToRefreshBox(
                isRefreshing = isRefreshing,
                onRefresh = {
                    scope.launch {
                        isRefreshing = true
                        loadProjectData()
                        core.refreshAll()
                        isRefreshing = false
                    }
                },
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = 18.dp,
                        end = 18.dp,
                        top = 4.dp,
                        bottom = 96.dp
                    )
                ) {
                    if (filter != OrbProjectFilter.All) {
                        item(key = "active_filter_bar") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(38.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = filter.label,
                                    color = OrbStyle.textSecondary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false
                                )
                                Spacer(modifier = Modifier.weight(1f))
                                Text(
                                    text = "Clear filter",
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    maxLines = 1,
                                    softWrap = false,
                                    modifier = Modifier.orbPressClickable { filter = OrbProjectFilter.All }
                                )
                            }
                        }
                    }

                    if (OrbMoveClipboard.mission != null) {
                        item(key = "move_banner") { OrbMoveBanner(modifier = Modifier.padding(vertical = 6.dp)) }
                    }
                    folderActionError?.let { err ->
                        item(key = "folder_action_error") {
                            OrbNotice(
                                title = err,
                                log = null,
                                modifier = Modifier.padding(vertical = 6.dp)
                            )
                        }
                    }

                    // Unfiled missions first (matching iOS OrbProjectPage)
                    val flatUnfiled = OrbMissionTree.flatten(
                        unfiledRoots,
                        expandedParents.filterValues { it }.keys
                    )
                    items(flatUnfiled, key = { "u-${it.id}" }) { node ->
                        OrbMissionListItem(
                            node = node,
                            isExpanded = expandedParents[node.id] == true,
                            onToggleExpand = {
                                expandedParents[node.id] = !(expandedParents[node.id] ?: false)
                            },
                            onClick = {
                                OrbMissionUnreadStore.markSeen(node.mission)
                                onOpenMission(node.mission)
                            },
                            onLongClick = { contextMenuMission = node.mission },
                            showContextMenu = contextMenuMission?.id == node.mission.id,
                            onDismissContextMenu = { contextMenuMission = null },
                            onRename = {
                                contextMenuMission = null
                                renameMissionDraft = OrbJSON.cleanTitle(node.mission.str("title", "name") ?: "")
                                renameMissionTarget = node.mission
                            },
                            onSettings = {
                                contextMenuMission = null
                                settingsMissionTarget = node.mission
                            },
                            onMove = {
                                contextMenuMission = null
                                OrbMoveClipboard.pick(node.mission, projectSlug)
                            },
                            onArchive = {
                                contextMenuMission = null
                                toggleArchiveMission(node.mission)
                            },
                            onPause = {
                                contextMenuMission = null
                                pauseOrResumeMission(node.mission)
                            },
                            onDelete = {
                                contextMenuMission = null
                                deleteMissionTarget = node.mission
                            }
                        )
                    }

                    // Folder sections
                    foldersMap.forEach { (folderPath, rootsInFolder) ->
                        val collapsed = collapsedFolders[folderPath] == true
                        val folderDepth = (folderPath.count { it == '/' }).coerceAtLeast(0)
                        val folderIndentDp = minOf(36, folderDepth * 12).dp
                        item(key = "folder_hdr_$folderPath") {
                            Box {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(start = folderIndentDp)
                                        .combinedClickable(
                                            onClick = {
                                                collapsedFolders[folderPath] = !collapsed
                                            },
                                            onLongClick = {
                                                contextMenuFolder = folderPath
                                            }
                                        )
                                        .padding(vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    OrbSfIcons.FolderOutline(
                                        color = OrbProjectAppearance.color(liveProject),
                                        size = 18.dp
                                    )
                                    Text(
                                        text = folderPath.substringAfterLast('/'),
                                        color = Color.White,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Icon(
                                        imageVector = if (collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                                        contentDescription = null,
                                        tint = OrbStyle.icon,
                                        modifier = Modifier.size(16.dp)
                                    )
                                    Icon(
                                        imageVector = Icons.Default.Add,
                                        contentDescription = "New in folder",
                                        tint = OrbStyle.textSecondary,
                                        modifier = Modifier
                                            .size(20.dp)
                                            .orbPressClickable { onNewAgent(folderPath) }
                                    )
                                }

                                DropdownMenu(
                                    expanded = contextMenuFolder == folderPath,
                                    onDismissRequest = { contextMenuFolder = null },
                                    containerColor = OrbStyle.elevated
                                ) {
                                    if (OrbMoveClipboard.canDrop(projectSlug, folderPath)) {
                                        DropdownMenuItem(
                                            text = { Text("Move here", color = Color.White) },
                                            leadingIcon = { Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White) },
                                            onClick = {
                                                contextMenuFolder = null
                                                dropMovedMission(folderPath)
                                            }
                                        )
                                        HorizontalDivider(color = OrbStyle.border)
                                    }
                                    DropdownMenuItem(
                                        text = { Text("New agent in folder", color = Color.White) },
                                        leadingIcon = {
                                            Icon(Icons.Default.Add, contentDescription = null, tint = Color.White)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            onNewAgent(folderPath)
                                        }
                                    )
                                    DropdownMenuItem(
                                        text = { Text("New subfolder", color = Color.White) },
                                        leadingIcon = {
                                            Icon(Icons.Default.CreateNewFolder, contentDescription = null, tint = Color.White)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            newFolderParent = folderPath
                                            newFolderDraft = ""
                                            showNewFolderDialog = true
                                        }
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Folder context files", color = Color.White) },
                                        leadingIcon = {
                                            Icon(Icons.Default.Description, contentDescription = null, tint = Color.White)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            onOpenDocuments(folderPath)
                                        }
                                    )
                                    HorizontalDivider(color = OrbStyle.border)
                                    DropdownMenuItem(
                                        text = { Text("Rename", color = Color.White) },
                                        leadingIcon = {
                                            Icon(Icons.Default.Edit, contentDescription = null, tint = Color.White)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            renameFolderDraft = folderPath.substringAfterLast('/')
                                            renameFolderTarget = folderPath
                                        }
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Move…", color = Color.White) },
                                        leadingIcon = {
                                            Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            moveFolderDraft = if (folderPath.contains('/')) folderPath.substringBeforeLast('/') else ""
                                            moveFolderTarget = folderPath
                                        }
                                    )
                                    HorizontalDivider(color = OrbStyle.border)
                                    DropdownMenuItem(
                                        text = { Text("Delete…", color = OrbStyle.error) },
                                        leadingIcon = {
                                            Icon(Icons.Default.Delete, contentDescription = null, tint = OrbStyle.error)
                                        },
                                        onClick = {
                                            contextMenuFolder = null
                                            deleteFolderTarget = folderPath
                                        }
                                    )
                                }
                            }
                        }

                        if (!collapsed) {
                            val flatFolderNodes = OrbMissionTree.flatten(
                                rootsInFolder,
                                expandedParents.filterValues { it }.keys
                            )
                            items(flatFolderNodes, key = { "f-${folderPath}-${it.id}" }) { node ->
                                OrbMissionListItem(
                                    node = node,
                                    isExpanded = expandedParents[node.id] == true,
                                    onToggleExpand = {
                                        expandedParents[node.id] = !(expandedParents[node.id] ?: false)
                                    },
                                    onClick = {
                                        OrbMissionUnreadStore.markSeen(node.mission)
                                        onOpenMission(node.mission)
                                    },
                                    onLongClick = { contextMenuMission = node.mission },
                                    showContextMenu = contextMenuMission?.id == node.mission.id,
                                    onDismissContextMenu = { contextMenuMission = null },
                                    onRename = {
                                        contextMenuMission = null
                                        renameMissionDraft = OrbJSON.cleanTitle(node.mission.str("title", "name") ?: "")
                                        renameMissionTarget = node.mission
                                    },
                                    onSettings = {
                                        contextMenuMission = null
                                        settingsMissionTarget = node.mission
                                    },
                                    onMove = {
                                        contextMenuMission = null
                                        OrbMoveClipboard.pick(node.mission, projectSlug)
                                    },
                                    onArchive = {
                                        contextMenuMission = null
                                        toggleArchiveMission(node.mission)
                                    },
                                    onPause = {
                                        contextMenuMission = null
                                        pauseOrResumeMission(node.mission)
                                    },
                                    onDelete = {
                                        contextMenuMission = null
                                        deleteMissionTarget = node.mission
                                    },
                                    extraIndentDp = 16
                                )
                            }
                        }
                    }

                    if (flatUnfiled.isEmpty() && foldersMap.isEmpty()) {
                        item(key = "empty_proj_missions") {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 64.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Text(
                                    text = if (searchQuery.isNotEmpty() || filter != OrbProjectFilter.All) "No matching conversations" else "No conversations yet",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    text = if (searchQuery.isNotEmpty() || filter != OrbProjectFilter.All) "Try another search or filter." else "Start an agent with the + button.",
                                    color = OrbStyle.textMuted,
                                    fontSize = 13.sp
                                )
                            }
                        }
                    }
                }
            }
        }

        // Bottom Search Bar
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(OrbStyle.background.copy(alpha = 0.94f))
                .padding(horizontal = 18.dp, vertical = 12.dp)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = "Search",
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(17.dp)
                )
                Box(modifier = Modifier.weight(1f)) {
                    if (searchQuery.isEmpty()) {
                        Text(
                            text = "Search conversations",
                            color = OrbStyle.textMuted,
                            fontSize = 15.sp
                        )
                    }
                    BasicTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                if (searchQuery.isNotEmpty()) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Clear",
                        tint = OrbStyle.textMuted,
                        modifier = Modifier
                            .size(16.dp)
                            .orbPressClickable { searchQuery = "" }
                    )
                }
            }
        }
    }

    if (showColorDialog) {
        OrbColorPickerDialog(
            project = liveProject,
            core = core,
            onDismiss = { showColorDialog = false }
        )
    }

    if (showNewFolderDialog) {
        AlertDialog(
            onDismissRequest = {
                showNewFolderDialog = false
                newFolderParent = ""
            },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = {
                Text(
                    text = if (newFolderParent.isEmpty()) "New folder" else "New subfolder in ${newFolderParent.substringAfterLast('/')}",
                    fontWeight = FontWeight.SemiBold
                )
            },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    if (newFolderDraft.isEmpty()) {
                        Text("Folder name", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
                    BasicTextField(
                        value = newFolderDraft,
                        onValueChange = { newFolderDraft = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val f = newFolderDraft.trim().trim('/')
                        val parent = newFolderParent.trim().trim('/')
                        showNewFolderDialog = false
                        newFolderParent = ""
                        if (f.isNotEmpty()) {
                            val fullPath = if (parent.isEmpty()) f else "$parent/$f"
                            customFolders[fullPath] = true
                            val slug = liveProject.str("slug", "id") ?: liveProject.id
                            scope.launch {
                                orbTry(OrbLog.Category.Network, "core.request") {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/file/mkdir",
                                        method = "POST",
                                        body = mapOf("path" to fullPath)
                                    )
                                    loadProjectData()
                                }
                            }
                        }
                    }
                ) {
                    Text("Create", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        showNewFolderDialog = false
                        newFolderParent = ""
                    }
                ) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    deleteMissionTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteMissionTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            textContentColor = OrbStyle.textSecondary,
            title = { Text("Delete agent?", fontWeight = FontWeight.SemiBold) },
            text = {
                Text("This permanently deletes \u201c${OrbJSON.cleanTitle(target.str("title", "name") ?: "this conversation")}\u201d, its child agents and associated workspace files.")
            },
            confirmButton = {
                TextButton(onClick = {
                    deleteMissionTarget = null
                    performDeleteMission(target)
                }) {
                    Text("Delete", color = OrbStyle.error, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteMissionTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    settingsMissionTarget?.let { target ->
        OrbMissionSettingsDialog(
            core = core,
            missionId = target.id,
            title = OrbJSON.cleanTitle(target.str("title", "name") ?: ""),
            onDismiss = { settingsMissionTarget = null },
        )
    }

    renameMissionTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { renameMissionTarget = null },
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
                    if (renameMissionDraft.isEmpty()) {
                        Text("Title", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
                    BasicTextField(
                        value = renameMissionDraft,
                        onValueChange = { renameMissionDraft = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val next = renameMissionDraft
                    renameMissionTarget = null
                    performRenameMission(target, next)
                }) {
                    Text("Save", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { renameMissionTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    renameFolderTarget?.let { targetFolder ->
        AlertDialog(
            onDismissRequest = { renameFolderTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Rename folder", fontWeight = FontWeight.SemiBold) },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    if (renameFolderDraft.isEmpty()) {
                        Text("Folder name", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
                    BasicTextField(
                        value = renameFolderDraft,
                        onValueChange = { renameFolderDraft = it },
                        textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val next = renameFolderDraft
                        renameFolderTarget = null
                        performRenameFolder(targetFolder, next)
                    }
                ) {
                    Text("Rename", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { renameFolderTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    moveFolderTarget?.let { targetFolder ->
        AlertDialog(
            onDismissRequest = { moveFolderTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Move folder", fontWeight = FontWeight.SemiBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "Destination parent folder within $projectName (leave empty for project root):",
                        color = OrbStyle.textSecondary,
                        fontSize = 13.sp
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        if (moveFolderDraft.isEmpty()) {
                            Text("Project root", color = OrbStyle.textMuted, fontSize = 14.sp)
                        }
                        BasicTextField(
                            value = moveFolderDraft,
                            onValueChange = { moveFolderDraft = it },
                            textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                            cursorBrush = SolidColor(Color.White),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val destParent = moveFolderDraft
                        moveFolderTarget = null
                        performMoveFolder(targetFolder, destParent)
                    }
                ) {
                    Text("Move", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { moveFolderTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    deleteFolderTarget?.let { targetFolder ->
        AlertDialog(
            onDismissRequest = { deleteFolderTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Delete folder?", fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    text = "Delete \"$targetFolder\" and all context files inside? This cannot be undone.",
                    color = OrbStyle.textSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteFolderTarget = null
                        performDeleteFolder(targetFolder)
                    }
                ) {
                    Text("Delete", color = OrbStyle.error, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteFolderTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OrbMissionListItem(
    node: OrbNestedMission,
    isExpanded: Boolean,
    onToggleExpand: () -> Unit,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    showContextMenu: Boolean,
    onDismissContextMenu: () -> Unit,
    onRename: () -> Unit,
    onSettings: () -> Unit,
    onMove: () -> Unit,
    onArchive: () -> Unit,
    onPause: () -> Unit,
    onDelete: () -> Unit,
    extraIndentDp: Int = 0
) {
    val mission = node.mission
    val isLive = OrbMissionTree.isLive(mission)
    val isGoal = OrbMissionTree.isGoal(mission)
    val unread = OrbMissionUnreadStore.isUnread(mission)
    val needsAttn = isNeedsAttention(mission)
    // An earlier version is told apart from the current one by harness and model.
    val title = if (node.version) {
        listOf(serviceName(mission.str("backend") ?: ""), mission.str("model_override") ?: "").filter { it.isNotEmpty() }.joinToString(" · ") + " · earlier"
    } else {
        OrbMissionTree.forkTitle(OrbInboxModel.missionHeadline(mission))
    }
    val relTime = OrbJSON.relative(mission.str("updated_at", "completed_at", "started_at", "created_at"))
    val indentDp = (minOf(48, node.depth * 18) + extraIndentDp).dp
    val backendRaw = mission.str("backend", "harness", "backend_id") ?: "claudecode"
    val stateRaw = (mission.str("status", "state") ?: "completed").lowercase()
    val subtitle = "${serviceName(backendRaw)} · ${statusLabel(stateRaw)}"

    Box {
        Column(modifier = Modifier.padding(start = indentDp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        onClick = onClick,
                        onLongClick = onLongClick
                    )
                    .padding(vertical = 10.dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .padding(top = 1.dp)
                        .size(width = 20.dp, height = 22.dp),
                    contentAlignment = Alignment.Center
                ) {
                    if (isLive) {
                        OrbRunningDots(color = Color.White, dotSize = 2.4.dp, spacing = 2.1.dp)
                    } else {
                        Box(contentAlignment = Alignment.BottomEnd) {
                            if (backendRaw.startsWith("cloud_")) {
                                Icon(
                                    imageVector = Icons.Default.Cloud,
                                    contentDescription = null,
                                    tint = OrbStyle.icon,
                                    modifier = Modifier.size(17.dp)
                                )
                            } else {
                                OrbSfIcons.CpuIcon(
                                    color = OrbStyle.icon,
                                    size = 17.dp
                                )
                            }
                            if (needsAttn) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(OrbStyle.warning)
                                )
                            } else if (unread) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(OrbStyle.inboxBlue)
                                )
                            }
                        }
                    }
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        if (isGoal) {
                            Row(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(Color.White.copy(alpha = 0.07f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(3.dp)
                            ) {
                                OrbSfIcons.TargetIcon(
                                    color = OrbStyle.textSecondary,
                                    size = 9.dp
                                )
                                Text(
                                    text = "Goal",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    softWrap = false
                                )
                            }
                        }
                        Text(
                            text = title,
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        if (node.childCount > 0 || node.versionCount > 0) {
                            val liveChildren = node.runningChildCount > 0
                            val badgeColor = if (liveChildren) OrbStyle.success else OrbStyle.textSecondary
                            Row(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(
                                        if (isExpanded) Color.White.copy(alpha = 0.10f)
                                        else Color.White.copy(alpha = 0.05f)
                                    )
                                    .border(
                                        0.75.dp,
                                        if (liveChildren) OrbStyle.success.copy(alpha = 0.35f)
                                        else if (isExpanded) OrbStyle.borderStrong
                                        else OrbStyle.border,
                                        CircleShape
                                    )
                                    .orbPressClickable { onToggleExpand() }
                                    .padding(start = 6.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                Text(
                                    text = if (node.childCount == 0) {
                                        "${node.versionCount} earlier"
                                    } else if (liveChildren) {
                                        "${node.runningChildCount}/${node.childCount}"
                                    } else {
                                        "${node.childCount}"
                                    },
                                    color = badgeColor,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium,
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 1,
                                    softWrap = false
                                )
                                Icon(
                                    imageVector = Icons.Default.ChevronRight,
                                    contentDescription = if (isExpanded) "Hide sub-missions" else "Show sub-missions",
                                    tint = badgeColor,
                                    modifier = Modifier
                                        .size(12.dp)
                                        .rotate(if (isExpanded) 90f else 0f)
                                )
                            }
                        }
                        if (relTime.isNotEmpty()) {
                            Text(
                                text = relTime,
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                softWrap = false
                            )
                        }
                    }
                    Text(
                        text = subtitle,
                        color = if (isLive) OrbStyle.textSecondary else OrbStyle.textMuted,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            HorizontalDivider(
                color = OrbStyle.border,
                thickness = 0.5.dp,
                modifier = Modifier.padding(start = 32.dp)
            )
        }

        DropdownMenu(
            expanded = showContextMenu,
            onDismissRequest = onDismissContextMenu,
            containerColor = OrbStyle.elevated
        ) {
            // Rename and Move work at any time; a live agent is stopped before it is archived.
            val isArchived = OrbMissionTree.isArchived(mission)
            DropdownMenuItem(
                text = { Text("Rename", color = Color.White) },
                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null, tint = Color.White) },
                onClick = onRename
            )
            DropdownMenuItem(
                text = { Text("Move…", color = Color.White) },
                leadingIcon = { Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White) },
                onClick = onMove
            )
            DropdownMenuItem(
                text = { Text("Mission settings…", color = Color.White) },
                leadingIcon = { Icon(Icons.Default.Tune, contentDescription = null, tint = Color.White) },
                onClick = onSettings
            )
            HorizontalDivider(color = OrbStyle.border)
            DropdownMenuItem(
                text = {
                    Text(
                        if (isArchived) "Unarchive" else if (isLive) "Stop & archive" else "Archive",
                        color = if (!isArchived && isLive) OrbStyle.error else Color.White
                    )
                },
                leadingIcon = {
                    Icon(
                        imageVector = if (isArchived) Icons.Default.Unarchive else Icons.Default.Archive,
                        contentDescription = null,
                        tint = if (!isArchived && isLive) OrbStyle.error else Color.White
                    )
                },
                onClick = onArchive
            )
            val isPaused = stateRaw == "paused"
            if (isLive || isPaused) {
                DropdownMenuItem(
                    text = { Text(if (isPaused) "Resume" else "Pause", color = Color.White) },
                    leadingIcon = {
                        Icon(
                            imageVector = if (isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                            contentDescription = null,
                            tint = Color.White
                        )
                    },
                    onClick = onPause
                )
            }
            HorizontalDivider(color = OrbStyle.border)
            DropdownMenuItem(
                text = { Text("Delete…", color = OrbStyle.error) },
                leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = OrbStyle.error) },
                onClick = onDelete
            )
        }
    }
}

fun serviceName(value: String): String = when (value.lowercase()) {
    "claudecode", "claude" -> "Claude Code"
    "codex" -> "Codex"
    "opencode" -> "OpenCode"
    "gemini" -> "Gemini"
    "antigravity" -> "Antigravity"
    "amp" -> "Amp"
    "cloud_cursor", "cloud_cursor_cloud", "cursor_cloud" -> "Cursor Cloud"
    "cloud_grok_bot", "grok_bot" -> "Grok Bot"
    "cloud_hermes", "hermes" -> "Hermes"
    else -> value
}

fun statusLabel(state: String): String = MissionState.label(state)

private fun isNeedsAttention(mission: OrbRow): Boolean = MissionState.of(mission)?.needsAttention == true

fun missionsForProject(
    project: OrbRow,
    missions: List<OrbRow>,
    allProjects: List<OrbRow>
): List<OrbRow> {
    val targetSlug = OrbProjectAppearance.slug(project)
    return missions.filter { m ->
        val resolved = OrbInboxModel.resolveProject(m, allProjects)
        OrbProjectAppearance.slug(resolved) == targetSlug
    }
}

private fun latestActivityRelative(
    project: OrbRow,
    projectMissions: List<OrbRow>
): String {
    var bestRaw: String? = project.str("updated_at", "last_activity_at", "created_at")
    var bestEpoch = OrbJSON.dateEpochMs(bestRaw) ?: 0L
    for (m in projectMissions) {
        val raw = m.str("updated_at", "completed_at", "started_at", "created_at")
        val epoch = OrbJSON.dateEpochMs(raw) ?: 0L
        if (epoch > bestEpoch) {
            bestEpoch = epoch
            bestRaw = raw
        }
    }
    return OrbJSON.relative(bestRaw)
}

/** A conversation picked up with "Move", waiting for a destination chosen by
 * long-pressing a folder, the project menu, or another project. */
object OrbMoveClipboard {
    var mission by mutableStateOf<OrbRow?>(null)
        private set
    var sourceSlug by mutableStateOf("")
        private set

    fun pick(target: OrbRow, slug: String) { mission = target; sourceSlug = slug }
    fun clear() { mission = null; sourceSlug = "" }
    fun canDrop(slug: String, folder: String): Boolean {
        val m = mission ?: return false
        return slug != sourceSlug || folder != (OrbMissionTree.folderPath(m) ?: "")
    }

    /** Keeps every tag except the folder, which becomes the destination. */
    suspend fun drop(core: OrbCore, slug: String, folder: String) {
        val m = mission ?: return
        val tags = OrbJSON.strList(m.raw, "tags").filter { it.isNotEmpty() && !it.startsWith("orb-folder:") }.toMutableList()
        if (folder.isNotEmpty()) tags.add("orb-folder:$folder")
        core.request(
            path = "/api/control/missions/${core.encodeComponent(m.id)}/project",
            method = "POST",
            body = mapOf("project" to slug, "tags" to tags)
        )
        UsageTelemetry.trackAction(UsageTelemetry.Action.SidebarMove, "sidebar")
        clear()
    }
}

@Composable
fun OrbMoveBanner(modifier: Modifier = Modifier) {
    val mission = OrbMoveClipboard.mission ?: return
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OrbStyle.surface)
            .border(0.75.dp, OrbStyle.border, RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = OrbStyle.textSecondary)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "Moving “${OrbJSON.cleanTitle(mission.str("title", "name") ?: "")}”",
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis
            )
            Text("Long-press a folder or project, then choose Move here.", color = OrbStyle.textSecondary, fontSize = 12.sp)
        }
        Text(
            "Cancel", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium,
            modifier = Modifier.orbPressClickable { OrbMoveClipboard.clear() }
        )
    }
}

/**
 * The single place that keeps Orb content clear of the status bar, navigation
 * bar, display cutout (camera hole) and keyboard. Every top-level screen of
 * [OrbAppRoot] — including the first-run setup — is drawn inside it, so a new
 * screen is covered automatically and must not add its own status/navigation/
 * IME padding. The background still paints edge to edge behind the bars
 * (MainActivity keeps enableEdgeToEdge). Sheets and dialogs live in their own
 * windows and use Material's inset defaults.
 */
@Composable
fun OrbSafeDrawingRoot(
    modifier: Modifier = Modifier,
    insets: androidx.compose.foundation.layout.WindowInsets =
        androidx.compose.foundation.layout.WindowInsets.safeDrawing,
    content: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(OrbStyle.background)
            .windowInsetsPadding(insets)
            .testTag("orb-safe-root"),
        content = content
    )
}

/** Connection failure card: plain-language message, the failing URL, and two ways out. */
@Composable
fun OrbConnectionIssueCard(
    issue: OrbConnectionIssue,
    log: String?,
    onChangeServer: () -> Unit,
    onUseDefault: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .padding(14.dp)
            .testTag("orb-connection-issue"),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(issue.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(
            issue.serverURL,
            color = OrbStyle.textSecondary,
            fontSize = 13.sp,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
        )
        Text(issue.message, color = OrbStyle.textSecondary, fontSize = 13.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val primaryIsDefault = issue.recommendDefault
            if (issue.offerUseDefault) {
                OrbIssueButton("Use default", primary = primaryIsDefault, onClick = onUseDefault)
            }
            OrbIssueButton("Change server", primary = !primaryIsDefault, onClick = onChangeServer)
        }
        if (!log.isNullOrEmpty() || issue.technicalDetail.isNotEmpty()) {
            OrbNotice(
                title = "Details",
                log = log ?: issue.technicalDetail
            )
        }
    }
}

@Composable
private fun OrbIssueButton(label: String, primary: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (primary) Color.White else OrbStyle.card)
            .orbPressClickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(label, color = if (primary) Color.Black else Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
