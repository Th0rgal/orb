package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

object OrbProjectGrant {
    const val NO_PROJECT_LIMIT = 0
    fun projectLimitOf(grant: OrbDict?): Int? {
        val n = OrbJSON.int(grant, "parallel_missions") ?: return null
        return if (n > 0) n else null
    }

    fun parseProjectLimit(raw: String): Result<Int> {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return Result.success(NO_PROJECT_LIMIT)
        val n = if (trimmed.all { it.isDigit() }) trimmed.toIntOrNull() else null
        if (n == null || n < 1) {
            return Result.failure(IllegalArgumentException("Enter 1 or more, or leave empty for no limit."))
        }
        return Result.success(n)
    }

}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbProjectConcurrencyPage(core: OrbCore, project: OrbRow, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val slug = OrbProjectAppearance.slug(project).ifEmpty { project.id }
    val projectName = project.str("title", "name", "slug") ?: project.id
    var refreshing by remember(slug) { mutableStateOf(false) }
    var grant by remember(slug) { mutableStateOf<OrbDict?>(null) }
    var limitDraft by remember(slug) { mutableStateOf("") }
    var limitDirty by remember(slug) { mutableStateOf(false) }
    var limitSaving by remember(slug) { mutableStateOf(false) }
    var limitSaved by remember(slug) { mutableStateOf(false) }
    var error by remember(slug) { mutableStateOf<String?>(null) }
    suspend fun loadGrant() {
        val raw = runCatching { core.fetchDict("/api/projects/${core.encodeComponent(slug)}/grant") }.getOrNull() ?: return
        val g = OrbJSON.dict(raw["grant"])
        grant = g
        if (!limitDirty) {
            limitDraft = OrbProjectGrant.projectLimitOf(g)?.toString().orEmpty()
        }
    }

    suspend fun saveProjectLimit() {
        val value = OrbProjectGrant.parseProjectLimit(limitDraft).getOrElse { err ->
            error = err.message
            return
        }
        limitSaving = true
        try {
            val res = OrbJSON.dict(
                core.request(
                    "/api/projects/${core.encodeComponent(slug)}/grant",
                    "POST",
                    body = mapOf("parallel_missions" to value)
                )
            )
            grant = OrbJSON.dict(res?.get("grant"))
            limitDraft = OrbProjectGrant.projectLimitOf(grant)?.toString().orEmpty()
            limitDirty = false
            limitSaved = true
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            error = e.message
        } finally {
            limitSaving = false
        }
    }


    LaunchedEffect(slug) { loadGrant() }
    Column(Modifier.fillMaxSize().background(OrbStyle.background)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("Back") }
            Text("Project concurrency", color = Color.White, fontSize = 17.sp)
        }
        PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
            scope.launch { refreshing = true; try { loadGrant() } finally { refreshing = false } }
        }) {
            LazyColumn(contentPadding = PaddingValues(20.dp)) {
                error?.let { item { Text(it, color = OrbStyle.error) } }
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text("Project concurrency", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Maximum unfinished missions in $projectName. Leave empty for no limit.",
                            color = OrbStyle.textMuted,
                            fontSize = 12.sp
                        )
                        OutlinedTextField(
                            value = limitDraft,
                            onValueChange = {
                                limitDraft = it
                                limitDirty = true
                                limitSaved = false
                            },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            placeholder = { Text("No limit") },
                            label = { Text("Agent limit") },
                            modifier = Modifier.fillMaxWidth()
                        )
                        TextButton(
                            enabled = !limitSaving && limitDirty,
                            onClick = { scope.launch { saveProjectLimit() } }
                        ) {
                            Text(if (limitSaving) "Saving…" else "Save agent limit")
                        }
                        if (limitSaved) {
                            Text("Saved.", color = OrbStyle.success, fontSize = 12.sp)
                        }
                    }
                }

                val readOnlyPairs = listOf(
                    "Autonomy level" to OrbJSON.str(grant, "autonomy_level").orEmpty(),
                    "Merge authority" to OrbJSON.str(grant, "merge_authority").orEmpty(),
                    "Budget per run" to OrbJSON.str(grant, "budget_per_tick").orEmpty(),
                    "Material bar" to OrbJSON.str(grant, "material_bar").orEmpty(),
                    "Pause reason" to OrbJSON.str(grant, "pause_reason").orEmpty(),
                    "Resume condition" to OrbJSON.str(grant, "resume_condition").orEmpty()
                ).filter { it.second.isNotEmpty() }

                if (readOnlyPairs.isNotEmpty()) {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                                .padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text("Standing authority", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            readOnlyPairs.forEach { (k, v) ->
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text(k, color = OrbStyle.textMuted, fontSize = 13.sp, modifier = Modifier.weight(0.45f))
                                    Text(v, color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(0.55f))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Optional wire fields stay absent when an older Core does not implement the board. */
data class OrbProjectBoard(
    val text: String?, val updatedAt: String?, val updatedByMissionID: String?,
    val controllerMissionID: String?, val boardUpdatedAt: String?
) {
    companion object {
        fun decode(raw: OrbDict?): OrbProjectBoard = OrbProjectBoard(
            raw?.get("text") as? String, raw?.get("updated_at") as? String,
            raw?.get("updated_by_mission_id") as? String, raw?.get("controller_mission_id") as? String,
            raw?.get("board_updated_at") as? String
        )
    }
}

data class OrbMissionBoardSummary(val id: String, val title: String, val status: String, val parentMissionID: String?, val updatedAt: String, val bytes: Int, val textSha256: String) {
    companion object { fun decode(raw: OrbDict) = OrbMissionBoardSummary(OrbJSON.str(raw, "mission_id").orEmpty(), OrbJSON.str(raw, "title").orEmpty(), OrbJSON.str(raw, "status").orEmpty(), OrbJSON.str(raw, "parent_mission_id"), OrbJSON.str(raw, "updated_at").orEmpty(), OrbJSON.int(raw, "bytes") ?: 0, OrbJSON.str(raw, "text_sha256").orEmpty()) }
}

object OrbMissionBoardProjection {
    fun summaries(raw: OrbDict, currentMissionIDs: Set<String>? = null): List<OrbMissionBoardSummary> = OrbJSON.dictList(raw["boards"]).map(OrbMissionBoardSummary::decode).filter { it.id.isNotEmpty() && (currentMissionIDs == null || it.id in currentMissionIDs) }.sortedWith(compareByDescending<OrbMissionBoardSummary> { it.updatedAt }.thenBy { it.id })
    fun shouldShowEntry(board: OrbProjectBoard) = !board.text.isNullOrBlank()
    fun accepts(raw: OrbDict, missionID: String, project: String, expectedRevision: Long, currentProject: String, currentRevision: Long) = OrbJSON.str(raw, "mission_id") == missionID && project == currentProject && expectedRevision == currentRevision
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbMissionBoardView(core: OrbCore, item: OrbMissionBoardSummary, project: String, expectedRevision: Long, onDismiss: () -> Unit) {
    var text by remember(item.id) { mutableStateOf<String?>(null) }
    var error by remember(item.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(item.id) {
        try {
            val raw = core.fetchDict("/api/control/missions/${core.encodeComponent(item.id)}/board")
            val current = OrbMissionTree.placementOf(item.id)
            if (OrbMissionBoardProjection.accepts(raw, item.id, project, expectedRevision, current?.project ?: project, current?.revision ?: expectedRevision)) text = raw["text"] as? String
        } catch (e: OrbError) { if (e.status == 404) text = "" else error = e.message } catch (e: Exception) { error = e.message }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = OrbStyle.background, contentColor = Color.White) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(item.title.ifEmpty { "Mission board" }, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            when { error != null -> Text(error!!, color = OrbStyle.error); text == null -> CircularProgressIndicator(); else -> androidx.compose.foundation.text.selection.SelectionContainer { Text(text.orEmpty(), fontFamily = FontFamily.Monospace) } }
            TextButton(onClick = onDismiss) { Text("Done") }
        }
    }
}

@Composable
fun OrbMissionBoardsSection(core: OrbCore, project: OrbRow, missions: List<OrbRow>, refreshID: Int, onOpen: (OrbMissionBoardSummary, Long) -> Unit) {
    var boards by remember(project.id) { mutableStateOf<List<OrbMissionBoardSummary>>(emptyList()) }
    var error by remember(project.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(project.id, refreshID) { try { boards = OrbMissionBoardProjection.summaries(core.fetchDict("/api/projects/${core.encodeComponent(project.id)}/boards"), missions.filter { OrbMissionTree.effectiveProject(it) == project.id }.map { it.id }.toSet()) } catch (e: OrbError) { if (e.status == 404) boards = emptyList() else error = e.message } catch (e: Exception) { error = e.message } }
    if (boards.isNotEmpty()) Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Mission boards", color = Color.White, fontWeight = FontWeight.SemiBold)
        boards.forEach { board -> TextButton(onClick = { onOpen(board, missions.firstOrNull { it.id == board.id }?.let { (it.raw["placement_revision"] as? Number)?.toLong() ?: 0 } ?: 0) }) { Column(Modifier.fillMaxWidth()) { Text(board.title.ifEmpty { board.id }, color = Color.White); Text("${board.status} · ${board.bytes} bytes · ${board.updatedAt}", color = OrbStyle.textSecondary, fontSize = 12.sp) } } }
    } else if (error != null) Text(error!!, color = OrbStyle.error)
}

@Composable
fun OrbProjectBoardSection(core: OrbCore, project: OrbRow, missions: List<OrbRow>, refreshID: Int, onOpenMission: (OrbRow) -> Unit) {
    val slug = OrbProjectAppearance.slug(project).ifEmpty { project.id }
    val path = "/api/projects/${core.encodeComponent(slug)}"
    val scope = rememberCoroutineScope()
    var controllerMissionID by remember(slug) { mutableStateOf<String?>(null) }
    var resolvedController by remember(slug) { mutableStateOf<OrbRow?>(null) }
    var controllerRevision by remember(slug) { mutableStateOf(0) }
    var board by remember(slug) { mutableStateOf(OrbProjectBoard.decode(null)) }
    var loading by remember(slug) { mutableStateOf(true) }
    var reloadID by remember(slug) { mutableStateOf(0) }
    var choosing by remember(slug) { mutableStateOf(false) }
    var saving by remember(slug) { mutableStateOf(false) }
    var steerText by remember(slug) { mutableStateOf("") }
    var sending by remember(slug) { mutableStateOf(false) }
    var error by remember(slug) { mutableStateOf<String?>(null) }
    val controller = missions.firstOrNull { it.id == controllerMissionID } ?: resolvedController

    suspend fun resolveController() {
        resolvedController = null
        val id = controllerMissionID ?: return
        if (missions.any { it.id == id }) return
        try {
            val raw = core.fetchDict("/api/control/missions/${core.encodeComponent(id)}")
            if (controllerMissionID == id) resolvedController = OrbRow(raw)
        } catch (e: CancellationException) { throw e }
        catch (_: Exception) { /* The mission list can still supply metadata later. */ }
    }

    LaunchedEffect(slug, refreshID, reloadID) {
        val revision = controllerRevision
        error = null
        try {
            val raw = core.fetchDict(path)
            if (revision == controllerRevision && !saving) {
                controllerMissionID = OrbProjectBoard.decode(raw).controllerMissionID
                resolveController()
            }
        } catch (e: CancellationException) { throw e }
        catch (e: OrbError) {
            if (e.status == 404) {
                if (revision == controllerRevision && !saving) { controllerMissionID = null; resolvedController = null }
            } else error = e.message
        }
        catch (e: Exception) { error = e.message }
        try {
            board = OrbProjectBoard.decode(core.fetchDict("$path/board"))
        } catch (e: CancellationException) { throw e }
        catch (e: OrbError) { if (e.status == 404) board = OrbProjectBoard.decode(null) else error = e.message }
        catch (e: Exception) { error = e.message }
        finally { loading = false }
    }

    fun setController(id: String?) {
        if (saving || sending) return
        saving = true
        controllerRevision += 1
        scope.launch {
            try {
                core.request("$path/controller-mission", "PUT", body = mapOf("mission_id" to id))
                controllerMissionID = id
                resolveController()
                error = null
            } catch (e: CancellationException) { throw e }
            catch (e: OrbError) { if (e.status != 404) error = e.message }
            catch (e: Exception) { error = e.message }
            finally { saving = false; controllerRevision += 1 }
        }
    }

    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Controller", fontWeight = FontWeight.SemiBold, color = Color.White)
        if (controllerMissionID != null) {
            Column(Modifier.fillMaxWidth().orbPressClickable {
                val id = controllerMissionID ?: return@orbPressClickable
                onOpenMission(controller ?: OrbRow(id, mapOf("id" to id, "project" to slug)))
            }) {
                Text(controller?.let { OrbInboxModel.missionHeadline(it) } ?: "Controller mission", color = Color.White)
                controller?.let { Text(statusLabel(it.str("status", "state").orEmpty()), color = OrbStyle.textSecondary, fontSize = 12.sp) }
            }
        } else { Text("No controller", color = OrbStyle.textSecondary) }
        Row {
            TextButton(onClick = { choosing = true }, enabled = !saving && !sending) { Text("Set controller") }
            if (controllerMissionID != null) TextButton(onClick = { setController(null) }, enabled = !saving && !sending) { Text("Clear controller") }
        }
        if (loading) {
            Column(Modifier.semantics { contentDescription = "Loading Board" }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.fillMaxWidth(0.25f).height(16.dp).background(OrbStyle.surface))
                Box(Modifier.fillMaxWidth(0.5f).height(12.dp).background(OrbStyle.surface))
                Box(Modifier.fillMaxWidth().height(180.dp).background(OrbStyle.surface))
            }
        } else if (!board.text.isNullOrEmpty()) {
            Text("Board", fontWeight = FontWeight.SemiBold, color = Color.White)
            board.updatedAt?.let { timestamp ->
                OrbJSON.dateEpochMs(timestamp)?.let { millis ->
                    val formatted = java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(millis))
                    Text("Updated $formatted", color = OrbStyle.textSecondary, fontSize = 12.sp)
                }
            }
            androidx.compose.foundation.text.selection.SelectionContainer {
                Box(Modifier.fillMaxWidth().height(180.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())) {
                    Text(board.text.orEmpty(), fontFamily = FontFamily.Monospace, color = Color.White, fontSize = 13.sp)
                }
            }
        }
        Text("Steer", fontWeight = FontWeight.SemiBold, color = Color.White)
        OutlinedTextField(value = steerText, onValueChange = { steerText = it }, label = { Text("Message the controller") },
            enabled = controllerMissionID != null && !sending && !saving, minLines = 2, maxLines = 6, modifier = Modifier.fillMaxWidth())
        if (controllerMissionID == null) Text("Set a controller to send a message.", color = OrbStyle.textSecondary, fontSize = 12.sp)
        TextButton(enabled = controllerMissionID != null && steerText.isNotBlank() && !sending && !saving, onClick = {
            val id = controllerMissionID ?: return@TextButton
            val content = steerText.trim()
            sending = true
            scope.launch {
                try { core.sendMissionMessage(id, content); steerText = ""; error = null }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { error = e.message }
                finally { sending = false }
            }
        }) { Text(if (sending) "Sending…" else "Send") }
        error?.let {
            Text(it, color = OrbStyle.error)
            TextButton(onClick = { reloadID += 1 }) { Text("Retry") }
        }
    }
    if (choosing) AlertDialog(onDismissRequest = { choosing = false }, title = { Text("Set controller") },
        text = {
            LazyColumn {
                if (missions.isEmpty()) item { Text("No missions in this project.") }
                items(missions.filter { !OrbMissionTree.isPlaceholder(it) }, key = { it.id }) { mission ->
                    TextButton(onClick = { choosing = false; setController(mission.id) }) {
                        Column {
                            Text(OrbInboxModel.missionHeadline(mission))
                            Text(statusLabel(mission.str("status", "state").orEmpty()), fontSize = 12.sp)
                        }
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } })
}
