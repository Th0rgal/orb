package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DriveFileMove
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun OrbProjectDocumentsPage(
    core: OrbCore,
    project: OrbRow,
    directoryPath: String,
    onBack: () -> Unit,
    onOpenDirectory: (String) -> Unit,
    onOpenFile: (OrbRow) -> Unit,
    modifier: Modifier = Modifier
) {
    val scope = rememberCoroutineScope()
    val slug = remember(project) { project.str("slug", "id") ?: project.id }
    val cacheKey = remember(slug, directoryPath) {
        "project_docs_${slug}_${if (directoryPath.isEmpty()) "root" else directoryPath.replace("/", "_")}"
    }

    var entries by remember(cacheKey) { mutableStateOf(OrbReadCache.loadRows(cacheKey)) }
    var loading by remember(cacheKey) { mutableStateOf(entries.isEmpty()) }
    var error by remember(cacheKey) { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    var contextMenuPath by remember { mutableStateOf<String?>(null) }
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var newFolderParent by remember { mutableStateOf(directoryPath) }
    var newFolderDraft by remember { mutableStateOf("") }
    var renameTarget by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var renameDraft by remember { mutableStateOf("") }
    var moveTarget by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var moveDraft by remember { mutableStateOf("") }
    var deleteTarget by remember { mutableStateOf<Pair<String, Boolean>?>(null) }

    val pageTitle = remember(directoryPath) {
        if (directoryPath.isEmpty()) "Project context" else directoryPath.substringAfterLast('/').ifEmpty { "Project context" }
    }

    suspend fun load() {
        if (entries.isEmpty()) loading = true
        error = null
        val encodedSlug = core.encodeComponent(slug)
        val encodedPath = core.encodeComponent(directoryPath)
        val path = "/api/projects/$encodedSlug/files?path=$encodedPath"
        try {
            val dict = core.fetchDict(path)
            val rows = OrbJSON.dictList(dict["entries"]).map { OrbRow(it) }
            entries = rows
            OrbReadCache.saveRows(cacheKey, rows)
        } catch (e: Throwable) {
            error = e.message ?: "Failed to load files"
        } finally {
            loading = false
        }
    }

    LaunchedEffect(cacheKey) {
        load()
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        // Top Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
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
            Text(
                text = pageTitle,
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 14.dp)
            )
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable {
                        newFolderParent = directoryPath
                        newFolderDraft = ""
                        showNewFolderDialog = true
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.CreateNewFolder,
                    contentDescription = "New folder",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp)
                )
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    load()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                error?.let { err ->
                    item(key = "error") {
                        OrbNotice(title = err, log = core.lastErrorLog.value)
                    }
                }

                if (loading && entries.isEmpty()) {
                    items(4) { idx ->
                        OrbSkeletonRow()
                    }
                } else if (entries.isEmpty()) {
                    item(key = "empty") {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 80.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Description,
                                contentDescription = null,
                                tint = OrbStyle.textMuted,
                                modifier = Modifier.size(28.dp)
                            )
                            Text(
                                text = "No context files yet",
                                color = OrbStyle.textSecondary,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Medium
                            )
                            Text(
                                text = "Markdown notes and specs under .paloma/ will appear here.",
                                color = OrbStyle.textMuted,
                                fontSize = 13.sp
                            )
                        }
                    }
                } else {
                    item(key = "list") {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        ) {
                            entries.forEachIndexed { idx, entry ->
                                val kind = (entry.str("kind", "type") ?: "file").lowercase()
                                val isDir = kind == "directory" || kind == "dir" ||
                                    entry.bool("is_dir", "is_directory") == true
                                val name = entry.str("name") ?: entry.id
                                val childPath = entry.str("path") ?: if (directoryPath.isEmpty()) name else "$directoryPath/$name"
                                val size = entry.int("size") ?: 0
                                val updated = OrbJSON.relative(entry.str("updated_at"))

                                Box {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .combinedClickable(
                                                onClick = {
                                                    if (isDir) {
                                                        onOpenDirectory(childPath)
                                                    } else {
                                                        val rawWithPath = entry.raw.toMutableMap()
                                                        rawWithPath["path"] = childPath
                                                        onOpenFile(OrbRow(rawWithPath, childPath))
                                                    }
                                                },
                                                onLongClick = {
                                                    contextMenuPath = childPath
                                                }
                                            )
                                            .padding(horizontal = 14.dp, vertical = 12.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                                    ) {
                                        Icon(
                                            imageVector = if (isDir) Icons.Default.Folder else Icons.Default.Description,
                                            contentDescription = null,
                                            tint = OrbStyle.icon,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp)
                                        ) {
                                            Text(
                                                text = name,
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            if (!isDir && size > 0) {
                                                Text(
                                                    text = formatBytes(size),
                                                    color = OrbStyle.textMuted,
                                                    fontSize = 11.sp
                                                )
                                            }
                                        }
                                        if (updated.isNotEmpty()) {
                                            Text(
                                                text = updated,
                                                color = OrbStyle.textMuted,
                                                fontSize = 12.sp,
                                                maxLines = 1,
                                                softWrap = false
                                            )
                                        }
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(12.dp)
                                        )
                                    }

                                    DropdownMenu(
                                        expanded = contextMenuPath == childPath,
                                        onDismissRequest = { contextMenuPath = null },
                                        containerColor = OrbStyle.elevated
                                    ) {
                                        if (isDir) {
                                            DropdownMenuItem(
                                                text = { Text("New subfolder", color = Color.White) },
                                                leadingIcon = {
                                                    Icon(Icons.Default.CreateNewFolder, contentDescription = null, tint = Color.White)
                                                },
                                                onClick = {
                                                    contextMenuPath = null
                                                    newFolderParent = childPath
                                                    newFolderDraft = ""
                                                    showNewFolderDialog = true
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
                                                contextMenuPath = null
                                                renameDraft = name
                                                renameTarget = childPath to isDir
                                            }
                                        )
                                        DropdownMenuItem(
                                            text = { Text("Move…", color = Color.White) },
                                            leadingIcon = {
                                                Icon(Icons.Default.DriveFileMove, contentDescription = null, tint = Color.White)
                                            },
                                            onClick = {
                                                contextMenuPath = null
                                                moveDraft = if (childPath.contains('/')) childPath.substringBeforeLast('/') else ""
                                                moveTarget = childPath to isDir
                                            }
                                        )
                                        HorizontalDivider(color = OrbStyle.border)
                                        DropdownMenuItem(
                                            text = { Text("Delete…", color = OrbStyle.error) },
                                            leadingIcon = {
                                                Icon(Icons.Default.Delete, contentDescription = null, tint = OrbStyle.error)
                                            },
                                            onClick = {
                                                contextMenuPath = null
                                                deleteTarget = childPath to isDir
                                            }
                                        )
                                    }
                                }

                                if (idx < entries.lastIndex) {
                                    HorizontalDivider(
                                        color = OrbStyle.border,
                                        modifier = Modifier.padding(start = 44.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showNewFolderDialog) {
        AlertDialog(
            onDismissRequest = { showNewFolderDialog = false },
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
                        if (f.isNotEmpty()) {
                            val fullPath = if (parent.isEmpty()) f else "$parent/$f"
                            scope.launch {
                                try {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/file/mkdir",
                                        method = "POST",
                                        body = mapOf("path" to fullPath)
                                    )
                                    load()
                                } catch (e: Throwable) {
                                    error = e.message ?: "Failed to create folder"
                                }
                            }
                        }
                    }
                ) {
                    Text("Create", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showNewFolderDialog = false }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    renameTarget?.let { (targetPath, isDir) ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text(if (isDir) "Rename folder" else "Rename file", fontWeight = FontWeight.SemiBold) },
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
                        Text(if (isDir) "Folder name" else "File name", color = OrbStyle.textMuted, fontSize = 14.sp)
                    }
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
                        val next = renameDraft.trim()
                        renameTarget = null
                        if (next.isEmpty() || next.contains('/') || next.contains('\\')) {
                            error = "Enter a name without slashes."
                            return@TextButton
                        }
                        val parent = if (targetPath.contains('/')) targetPath.substringBeforeLast('/') else ""
                        val dest = if (parent.isEmpty()) next else "$parent/$next"
                        if (dest != targetPath) {
                            scope.launch {
                                try {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/file/transfer",
                                        method = "POST",
                                        body = mapOf("path" to targetPath, "destination" to dest, "copy" to false)
                                    )
                                    load()
                                } catch (e: Throwable) {
                                    error = e.message ?: "Failed to rename"
                                }
                            }
                        }
                    }
                ) {
                    Text("Rename", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    moveTarget?.let { (targetPath, isDir) ->
        AlertDialog(
            onDismissRequest = { moveTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text(if (isDir) "Move folder" else "Move file", fontWeight = FontWeight.SemiBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "Destination parent folder (leave empty for project root):",
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
                        if (moveDraft.isEmpty()) {
                            Text("Project root", color = OrbStyle.textMuted, fontSize = 14.sp)
                        }
                        BasicTextField(
                            value = moveDraft,
                            onValueChange = { moveDraft = it },
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
                        val parent = moveDraft.trim().trim('/')
                        moveTarget = null
                        val base = targetPath.substringAfterLast('/')
                        val dest = if (parent.isEmpty()) base else "$parent/$base"
                        if (dest != targetPath) {
                            if (isDir && dest.startsWith("$targetPath/")) {
                                error = "Cannot move a folder inside itself."
                                return@TextButton
                            }
                            scope.launch {
                                try {
                                    core.request(
                                        "/api/projects/${core.encodeComponent(slug)}/file/transfer",
                                        method = "POST",
                                        body = mapOf("path" to targetPath, "destination" to dest, "copy" to false)
                                    )
                                    load()
                                } catch (e: Throwable) {
                                    error = e.message ?: "Failed to move"
                                }
                            }
                        }
                    }
                ) {
                    Text("Move", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { moveTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }

    deleteTarget?.let { (targetPath, isDir) ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            containerColor = OrbStyle.elevated,
            titleContentColor = Color.White,
            title = { Text(if (isDir) "Delete folder?" else "Delete file?", fontWeight = FontWeight.SemiBold) },
            text = {
                Text(
                    text = if (isDir) "Delete \"$targetPath\" and all contents inside? This cannot be undone." else "Delete \"$targetPath\"? This cannot be undone.",
                    color = OrbStyle.textSecondary,
                    fontSize = 14.sp
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteTarget = null
                        scope.launch {
                            try {
                                core.request(
                                    "/api/projects/${core.encodeComponent(slug)}/file?path=${core.encodeComponent(targetPath)}",
                                    method = "DELETE"
                                )
                                entries = entries.filterNot { e ->
                                    val n = e.str("name") ?: e.id
                                    val p = e.str("path") ?: if (directoryPath.isEmpty()) n else "$directoryPath/$n"
                                    p == targetPath
                                }
                                load()
                            } catch (e: Throwable) {
                                error = e.message ?: "Failed to delete"
                            }
                        }
                    }
                ) {
                    Text("Delete", color = OrbStyle.error, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) {
                    Text("Cancel", color = OrbStyle.textSecondary)
                }
            }
        )
    }
}

private fun formatBytes(bytes: Int): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    return "%.1f MB".format(kb / 1024.0)
}

@Composable
fun OrbProjectDocumentViewer(
    core: OrbCore,
    project: OrbRow,
    entry: OrbRow,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val slug = remember(project) { project.str("slug", "id") ?: project.id }
    val path = remember(entry) { entry.str("path", "name") ?: entry.id }
    val fileName = remember(entry, path) { entry.str("name") ?: path.substringAfterLast('/') }
    val isMarkdown = remember(fileName) {
        val lower = fileName.lowercase()
        lower.endsWith(".md") || lower.endsWith(".markdown")
    }
    val cacheKey = remember(slug, path) {
        "project_doc_${slug}_${path.replace("/", "_")}"
    }
    val draftPrefs = remember(context) {
        context.applicationContext.getSharedPreferences("orb_doc_drafts", Context.MODE_PRIVATE)
    }
    val draftKey = remember(slug, path) { "orb.doc.draft.$slug.$path" }

    var content by remember { mutableStateOf("") }
    var draftContent by remember { mutableStateOf("") }
    var revision by remember { mutableStateOf<String?>(null) }
    var isEditing by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    val hasLocalDraft = remember(draftContent, content) {
        val saved = draftPrefs.getString(draftKey, null)
        !saved.isNullOrEmpty() && saved != content
    }

    LaunchedEffect(cacheKey) {
        val cached = OrbReadCache.loadDict(cacheKey)
        val localDraft = draftPrefs.getString(draftKey, null)
        if (cached != null) {
            val cachedText = OrbJSON.rawStr(cached, "content") ?: ""
            content = cachedText
            draftContent = if (!localDraft.isNullOrEmpty()) localDraft else cachedText
            revision = OrbJSON.str(cached, "revision")
            loading = false
        } else {
            loading = true
        }
        error = null
        val encodedSlug = core.encodeComponent(slug)
        val encodedPath = core.encodeComponent(path)
        try {
            val dict = core.fetchDict("/api/projects/$encodedSlug/file?path=$encodedPath")
            val loaded = OrbJSON.rawStr(dict, "content") ?: ""
            content = loaded
            val currentDraft = draftPrefs.getString(draftKey, null)
            draftContent = if (!currentDraft.isNullOrEmpty() && currentDraft != loaded) {
                currentDraft
            } else {
                loaded
            }
            revision = OrbJSON.str(dict, "revision")
            OrbReadCache.saveDict(cacheKey, dict)
        } catch (e: Throwable) {
            if (content.isEmpty()) error = e.message ?: "Failed to load file"
        } finally {
            loading = false
        }
    }

    fun persistDraftIfNeeded(nextValue: String) {
        if (!isEditing) return
        if (nextValue == content) {
            draftPrefs.edit().remove(draftKey).apply()
        } else {
            draftPrefs.edit().putString(draftKey, nextValue).apply()
        }
    }

    fun saveDocument() {
        isSaving = true
        error = null
        val encodedSlug = core.encodeComponent(slug)
        val body = mutableMapOf<String, Any?>(
            "path" to path,
            "content" to draftContent
        )
        revision?.let { body["expected_revision"] = it }
        scope.launch {
            try {
                val res = core.request("/api/projects/$encodedSlug/file", method = "PUT", body = body)
                val dict = OrbJSON.dict(res) ?: emptyMap()
                val savedContent = OrbJSON.rawStr(dict, "content") ?: draftContent
                content = savedContent
                draftContent = savedContent
                revision = OrbJSON.str(dict, "revision") ?: revision
                draftPrefs.edit().remove(draftKey).apply()
                OrbReadCache.saveDict(
                    cacheKey,
                    mapOf("content" to savedContent, "revision" to (revision ?: ""))
                )
                isEditing = false
            } catch (e: Throwable) {
                error = e.message ?: "Failed to save file"
            } finally {
                isSaving = false
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        // Top Bar
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
            Text(
                text = fileName,
                color = Color.White,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            if (isEditing) {
                Text(
                    text = "Cancel",
                    color = OrbStyle.textSecondary,
                    fontSize = 14.sp,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .orbPressClickable {
                            draftContent = content
                            draftPrefs.edit().remove(draftKey).apply()
                            isEditing = false
                        }
                        .padding(horizontal = 8.dp, vertical = 6.dp)
                )
                Text(
                    text = if (isSaving) "Saving…" else "Save",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .orbPressClickable(enabled = !isSaving) { saveDocument() }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
            } else if (!loading) {
                Text(
                    text = if (hasLocalDraft) "Resume draft" else "Edit",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.surface)
                        .border(1.dp, OrbStyle.border, CircleShape)
                        .orbPressClickable {
                            val saved = draftPrefs.getString(draftKey, null)
                            draftContent = if (!saved.isNullOrEmpty()) saved else content
                            isEditing = true
                        }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
                if (content.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(OrbStyle.surface)
                            .border(1.dp, OrbStyle.border, CircleShape)
                            .orbPressClickable {
                                shareBytes(context, fileName, content.toByteArray())
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = "Share",
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }
        }

        when {
            loading -> {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = OrbStyle.textSecondary)
                }
            }
            error != null && content.isEmpty() -> {
                Box(modifier = Modifier.padding(20.dp)) {
                    OrbNotice(title = error!!, log = core.lastErrorLog.value)
                }
            }
            isEditing -> {
                Column(modifier = Modifier.fillMaxSize()) {
                    error?.let { err ->
                        OrbNotice(
                            title = err,
                            log = core.lastErrorLog.value,
                            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)
                        )
                    }
                    BasicTextField(
                        value = draftContent,
                        onValueChange = {
                            draftContent = it
                            persistDraftIfNeeded(it)
                        },
                        textStyle = TextStyle(
                            color = Color.White,
                            fontSize = 13.sp,
                            fontFamily = FontFamily.Monospace,
                            lineHeight = 20.sp
                        ),
                        cursorBrush = SolidColor(Color.White),
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp, vertical = 10.dp)
                    )
                }
            }
            else -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    error?.let { err ->
                        OrbNotice(title = err, log = core.lastErrorLog.value)
                    }
                    if (isMarkdown) {
                        OrbRichText(markdown = content, tone = OrbRichTextTone.Primary)
                    } else {
                        Text(
                            text = content,
                            color = Color.White,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                }
            }
        }
    }
}
