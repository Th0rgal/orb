package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

enum class OrbClaudePermissionMode(val wire: String, val label: String) {
    Supervised("supervised", "Supervised"),
    AcceptEdits("acceptEdits", "Auto-edit"),
    Auto("auto", "Auto"),
    BypassPermissions("bypassPermissions", "Full access");

    companion object {
        fun parse(raw: String?): OrbClaudePermissionMode = when (raw?.trim()) {
            "acceptEdits", "accept_edits" -> AcceptEdits
            "auto" -> Auto
            "bypassPermissions", "bypass_permissions", "full" -> BypassPermissions
            else -> Supervised
        }
    }
}

enum class OrbWorktreeLaunchMode(val wire: String, val label: String) {
    Auto("auto", "Automatic"),
    Worktree("worktree", "Isolated worktree"),
    Local("local", "Local checkout");

    companion object {
        fun parse(raw: String?): OrbWorktreeLaunchMode = when (raw?.trim()) {
            "worktree" -> Worktree
            "local" -> Local
            else -> Auto
        }
    }
}

data class OrbCheckpointMeta(
    val ref: String,
    val oid: String,
    val turn: Int
) {
    companion object {
        fun fromDict(dict: OrbDict): OrbCheckpointMeta? {
            val ref = OrbJSON.str(dict, "ref") ?: return null
            val oid = OrbJSON.str(dict, "oid")?.ifEmpty { null }
                ?: OrbJSON.str(dict, "commit_sha")?.ifEmpty { null }
                ?: OrbJSON.str(dict, "commit")
                ?: ""
            val turn = OrbJSON.int(dict, "turn") ?: OrbJSON.int(dict, "turn_index") ?: 0
            return OrbCheckpointMeta(ref = ref, oid = oid, turn = turn)
        }
    }
}

data class OrbDiffFileEntry(
    val path: String,
    val status: String,
    val additions: Int,
    val deletions: Int
) {
    companion object {
        fun fromDict(dict: OrbDict): OrbDiffFileEntry? {
            val path = OrbJSON.str(dict, "path") ?: return null
            val status = OrbJSON.str(dict, "status")?.ifEmpty { "M" } ?: "M"
            val additions = OrbJSON.int(dict, "additions") ?: 0
            val deletions = OrbJSON.int(dict, "deletions") ?: 0
            return OrbDiffFileEntry(path = path, status = status, additions = additions, deletions = deletions)
        }
    }
}

enum class OrbDiffLineKind { Context, Add, Del }

data class OrbDiffLine(
    val id: Int,
    val kind: OrbDiffLineKind,
    val oldLine: Int?,
    val newLine: Int?,
    val content: String
)

data class OrbDiffHunk(
    val id: Int,
    val header: String,
    val lines: List<OrbDiffLine>
)

data class OrbParsedFileDiff(
    val path: String,
    val status: String,
    val additions: Int,
    val deletions: Int,
    val binary: Boolean,
    val hunks: List<OrbDiffHunk>
)

object OrbUnifiedDiffParser {
    private fun parseRangeStart(token: String): Int {
        if (token.length < 2) return 1
        return token.drop(1).substringBefore(',').toIntOrNull() ?: 1
    }

    fun parse(raw: String): List<OrbParsedFileDiff> {
        if (raw.isBlank()) return emptyList()
        val lines = raw.replace("\r\n", "\n").split('\n')
        val files = mutableListOf<OrbParsedFileDiff>()
        var curPath = ""
        var curStatus = "M"
        var curAdd = 0
        var curDel = 0
        var curBinary = false
        var curHunks = mutableListOf<OrbDiffHunk>()
        var curHunkHeader: String? = null
        var curHunkLines = mutableListOf<OrbDiffLine>()
        var oldLine = 1
        var newLine = 1
        var nextLineId = 1

        fun flushHunk() {
            val hdr = curHunkHeader
            if (hdr != null) {
                curHunks.add(OrbDiffHunk(id = curHunks.size, header = hdr, lines = curHunkLines.toList()))
                curHunkHeader = null
                curHunkLines = mutableListOf()
            }
        }

        fun flushFile() {
            flushHunk()
            if (curPath.isNotEmpty()) {
                files.add(
                    OrbParsedFileDiff(
                        path = curPath,
                        status = curStatus,
                        additions = curAdd,
                        deletions = curDel,
                        binary = curBinary,
                        hunks = curHunks.toList()
                    )
                )
            }
            curPath = ""
            curStatus = "M"
            curAdd = 0
            curDel = 0
            curBinary = false
            curHunks = mutableListOf()
        }

        for (line in lines) {
            if (line.startsWith("diff --git ")) {
                flushFile()
                val rest = line.removePrefix("diff --git ")
                val sepIdx = rest.indexOf(" b/")
                curPath = if (sepIdx >= 0) {
                    rest.substring(sepIdx + 3)
                } else {
                    rest.substringAfterLast(' ').removePrefix("b/").ifEmpty { "unknown" }
                }
                continue
            }
            if (curPath.isEmpty()) continue
            if (line.startsWith("new file mode ")) { curStatus = "A"; continue }
            if (line.startsWith("deleted file mode ")) { curStatus = "D"; continue }
            if (line.startsWith("rename from ")) { curStatus = "R"; continue }
            if (line.startsWith("rename to ")) {
                curPath = line.removePrefix("rename to ").trim()
                continue
            }
            if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
                curBinary = true
                continue
            }
            if (line.startsWith("@@ ")) {
                flushHunk()
                curHunkHeader = line
                val parts = line.split(' ')
                if (parts.size >= 3) {
                    oldLine = parseRangeStart(parts[1])
                    newLine = parseRangeStart(parts[2])
                } else {
                    oldLine = 1
                    newLine = 1
                }
                continue
            }
            if (curHunkHeader == null) continue
            if (line.startsWith("\\ No newline at end of file")) continue
            when {
                line.startsWith("+") -> {
                    curAdd += 1
                    curHunkLines.add(OrbDiffLine(nextLineId++, OrbDiffLineKind.Add, null, newLine++, line.drop(1)))
                }
                line.startsWith("-") -> {
                    curDel += 1
                    curHunkLines.add(OrbDiffLine(nextLineId++, OrbDiffLineKind.Del, oldLine++, null, line.drop(1)))
                }
                line.startsWith(" ") -> {
                    curHunkLines.add(OrbDiffLine(nextLineId++, OrbDiffLineKind.Context, oldLine++, newLine++, line.drop(1)))
                }
            }
        }
        flushFile()
        return files
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbChangesSheet(
    core: OrbCore,
    missionId: String,
    onRestored: () -> Unit = {},
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var checkpoints by remember(missionId) { mutableStateOf<List<OrbCheckpointMeta>>(emptyList()) }
    var fromRef by remember(missionId) { mutableStateOf("") }
    var files by remember(missionId) { mutableStateOf<List<OrbDiffFileEntry>>(emptyList()) }
    var parsedFiles by remember(missionId) { mutableStateOf<List<OrbParsedFileDiff>>(emptyList()) }
    var additions by remember(missionId) { mutableIntStateOf(0) }
    var deletions by remember(missionId) { mutableIntStateOf(0) }
    var truncated by remember(missionId) { mutableStateOf(false) }
    var loading by remember(missionId) { mutableStateOf(true) }
    var error by remember(missionId) { mutableStateOf<String?>(null) }
    var expandedPaths by remember(missionId) { mutableStateOf<Set<String>>(emptySet()) }
    var confirmRestore by remember { mutableStateOf<OrbCheckpointMeta?>(null) }
    var restoring by remember { mutableStateOf(false) }

    suspend fun loadDiff(selectedRef: String) {
        loading = true
        try {
            val base = "/api/control/missions/${core.encodeComponent(missionId)}/checkpoints/diff"
            val url = if (selectedRef.isNotEmpty()) "$base?from_ref=${core.encodeComponent(selectedRef)}" else base
            val report = core.fetchDict(url)
            val loadedFiles = OrbJSON.dictList(report["files"]).mapNotNull(OrbDiffFileEntry::fromDict)
            val rawDiff = OrbJSON.str(report, "raw_diff") ?: ""
            val parsed = OrbUnifiedDiffParser.parse(rawDiff)
            files = loadedFiles
            parsedFiles = parsed
            additions = OrbJSON.int(report, "total_additions") ?: 0
            deletions = OrbJSON.int(report, "total_deletions") ?: 0
            truncated = OrbJSON.bool(report, "truncated") == true
            if (expandedPaths.isEmpty()) {
                val firstPath = parsed.firstOrNull()?.path ?: loadedFiles.firstOrNull()?.path
                if (firstPath != null) expandedPaths = setOf(firstPath)
            }
            error = null
        } catch (e: Throwable) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            error = e.message ?: "Could not load workspace changes."
        } finally {
            loading = false
        }
    }

    suspend fun loadInitial() {
        loading = true
        try {
            val listResp = core.fetchDict("/api/control/missions/${core.encodeComponent(missionId)}/checkpoints")
            val loaded = OrbJSON.dictList(listResp["checkpoints"]).mapNotNull(OrbCheckpointMeta::fromDict).sortedBy { it.turn }
            checkpoints = loaded
            val nextRef = fromRef.ifEmpty { loaded.firstOrNull()?.ref ?: "" }
            fromRef = nextRef
            loadDiff(nextRef)
        } catch (e: Throwable) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            error = e.message ?: "Could not load checkpoints."
            loading = false
        }
    }

    LaunchedEffect(missionId) {
        loadInitial()
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
                .height(680.dp)
                .padding(horizontal = 16.dp)
                .testTag("changes.sheet")
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = "Changes",
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
                if (additions > 0 || deletions > 0) {
                    Text(
                        text = "+$additions  -$deletions",
                        color = OrbStyle.textSecondary,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace
                    )
                }
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

            if (checkpoints.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(bottom = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    checkpoints.forEach { cp ->
                        val active = cp.ref == fromRef
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(if (active) Color.White else OrbStyle.surface)
                                .border(1.dp, if (active) Color.Transparent else OrbStyle.border, CircleShape)
                                .orbPressClickable {
                                    fromRef = cp.ref
                                    scope.launch { loadDiff(cp.ref) }
                                }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text(
                                text = if (cp.turn == 0) "Turn 0 · Baseline" else "Turn ${cp.turn}",
                                color = if (active) Color.Black else Color.White,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                    checkpoints.firstOrNull { it.ref == fromRef }?.let { cp ->
                        Row(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.borderStrong, CircleShape)
                                .orbPressClickable(enabled = !restoring) { confirmRestore = cp }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                                .testTag("changes.revert"),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(Icons.Default.Replay, contentDescription = null, tint = OrbStyle.error, modifier = Modifier.size(13.dp))
                            Text("Revert to Turn ${cp.turn}", color = OrbStyle.error, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }

            val displayFiles = if (parsedFiles.isNotEmpty()) parsedFiles else files.map {
                OrbParsedFileDiff(it.path, it.status, it.additions, it.deletions, false, emptyList())
            }

            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    loading && displayFiles.isEmpty() -> items(3) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(0.62f)
                                    .height(14.dp)
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(OrbStyle.elevated)
                                    .orbShimmer()
                            )
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(0.38f)
                                    .height(10.dp)
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(OrbStyle.surface)
                                    .orbShimmer()
                            )
                        }
                    }
                    error != null && displayFiles.isEmpty() -> item {
                        OrbNotice(title = error!!, log = null)
                    }
                    displayFiles.isEmpty() -> item {
                        Text(
                            text = "No workspace changes recorded since this checkpoint.",
                            color = OrbStyle.textSecondary,
                            fontSize = 14.sp,
                            modifier = Modifier.padding(12.dp).testTag("changes.empty")
                        )
                    }
                    else -> {
                        if (truncated) {
                            item {
                                Text(
                                    text = "Diff output was capped to stay within the workspace diff budget.",
                                    color = OrbStyle.warning,
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(bottom = 4.dp)
                                )
                            }
                        }
                        items(displayFiles, key = { it.path }) { file ->
                            val isExpanded = file.path in expandedPaths
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(OrbStyle.surface)
                                    .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedPaths = if (isExpanded) expandedPaths - file.path else expandedPaths + file.path
                                        }
                                        .padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text(
                                        text = file.status,
                                        color = when (file.status) {
                                            "A" -> OrbStyle.success
                                            "D" -> OrbStyle.error
                                            else -> OrbStyle.textSecondary
                                        },
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold,
                                        fontFamily = FontFamily.Monospace,
                                        modifier = Modifier.width(16.dp)
                                    )
                                    Text(
                                        text = file.path,
                                        color = Color.White,
                                        fontSize = 13.sp,
                                        fontFamily = FontFamily.Monospace,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    if (file.additions > 0) {
                                        Text("+${file.additions}", color = OrbStyle.success, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                                    }
                                    if (file.deletions > 0) {
                                        Text("-${file.deletions}", color = OrbStyle.error, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                                    }
                                    Icon(
                                        imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                        contentDescription = null,
                                        tint = OrbStyle.textMuted,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                                if (isExpanded) {
                                    HorizontalDivider(color = OrbStyle.border)
                                    when {
                                        file.binary -> Text(
                                            text = "Binary file changed.",
                                            color = OrbStyle.textMuted,
                                            fontSize = 12.sp,
                                            modifier = Modifier.padding(12.dp)
                                        )
                                        file.hunks.isEmpty() -> Text(
                                            text = "Diff preview omitted for budget.",
                                            color = OrbStyle.textMuted,
                                            fontSize = 12.sp,
                                            modifier = Modifier.padding(12.dp)
                                        )
                                        else -> Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .horizontalScroll(rememberScrollState())
                                                .padding(vertical = 6.dp)
                                        ) {
                                            file.hunks.forEach { hunk ->
                                                Text(
                                                    text = hunk.header,
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 11.sp,
                                                    fontFamily = FontFamily.Monospace,
                                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp)
                                                )
                                                hunk.lines.forEach { line ->
                                                    val lineColor = when (line.kind) {
                                                        OrbDiffLineKind.Add -> OrbStyle.success
                                                        OrbDiffLineKind.Del -> OrbStyle.error
                                                        OrbDiffLineKind.Context -> Color.White.copy(alpha = 0.88f)
                                                    }
                                                    val bgColor = when (line.kind) {
                                                        OrbDiffLineKind.Add -> OrbStyle.success.copy(alpha = 0.10f)
                                                        OrbDiffLineKind.Del -> OrbStyle.error.copy(alpha = 0.10f)
                                                        OrbDiffLineKind.Context -> Color.Transparent
                                                    }
                                                    val sign = when (line.kind) {
                                                        OrbDiffLineKind.Add -> "+"
                                                        OrbDiffLineKind.Del -> "-"
                                                        OrbDiffLineKind.Context -> " "
                                                    }
                                                    Text(
                                                        text = "$sign ${line.content}",
                                                        color = lineColor,
                                                        fontSize = 11.5.sp,
                                                        fontFamily = FontFamily.Monospace,
                                                        modifier = Modifier
                                                            .fillMaxWidth()
                                                            .background(bgColor)
                                                            .padding(horizontal = 10.dp, vertical = 1.dp)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        item { Spacer(Modifier.height(24.dp)) }
                    }
                }
            }
        }
    }

    confirmRestore?.let { cp ->
        AlertDialog(
            onDismissRequest = { if (!restoring) confirmRestore = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text("Revert workspace?", fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    text = "Restore the workspace files to Turn ${cp.turn} (${cp.oid.take(8)}). An automatic backup checkpoint is saved before restoring.",
                    color = OrbStyle.textSecondary,
                    fontSize = 14.sp
                )
            },
            dismissButton = {
                TextButton(enabled = !restoring, onClick = { confirmRestore = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !restoring,
                    onClick = {
                        restoring = true
                        scope.launch {
                            try {
                                core.request(
                                    "/api/control/missions/${core.encodeComponent(missionId)}/checkpoints/restore",
                                    method = "POST",
                                    body = mapOf("ref" to cp.ref, "turn" to cp.turn)
                                )
                                confirmRestore = null
                                onRestored()
                                loadInitial()
                            } catch (e: Throwable) {
                                error = e.message ?: "Restore failed."
                                confirmRestore = null
                            } finally {
                                restoring = false
                            }
                        }
                    }
                ) {
                    Text(if (restoring) "Reverting…" else "Revert", color = OrbStyle.error, fontWeight = FontWeight.SemiBold)
                }
            }
        )
    }
}
