package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLEncoder
import java.util.UUID

data class OrbPendingAttachment(
    val id: String = UUID.randomUUID().toString(),
    val filename: String,
    val mimeType: String,
    val data: ByteArray,
    val thumbnail: Bitmap?
) {
    val isImage: Boolean get() = mimeType.startsWith("image/")
}

data class OrbUploadedAttachment(
    val filename: String,
    val remotePath: String,
    val url: String?,
    val isImage: Boolean
)

object OrbAttachmentUploader {
    suspend fun upload(item: OrbPendingAttachment, core: OrbCore): OrbUploadedAttachment =
        withContext(Dispatchers.IO) {
            val encodedName = URLEncoder.encode(item.filename, Charsets.UTF_8.name()).replace("+", "%20")
            val endpoint = "/api/uploads?filename=$encodedName"
            val url = core.makeURL(endpoint)

            // Try raw binary upload first (matches iOS OrbAttachmentUploader)
            val rawReq = Request.Builder()
                .url(url)
                .post(item.data.toRequestBody(item.mimeType.toMediaType()))
                .header("Accept", "application/json")
                .apply {
                    core.token?.trim()?.takeIf { it.isNotEmpty() }?.let {
                        header("Authorization", "Bearer $it")
                    }
                }
                .build()

            val resp = core.httpClient.newCall(rawReq).execute()
            val code = resp.code
            val bytes = resp.body?.bytes() ?: ByteArray(0)
            resp.close()

            if (code in 200..299) {
                val parsed = OrbJSON.dict(OrbJSON.parse(bytes))
                val remotePath = OrbJSON.str(parsed, "path", "file_path", "local_path", "url", "id")
                    ?: item.filename
                val remoteURL = OrbJSON.str(parsed, "url", "download_url")
                return@withContext OrbUploadedAttachment(
                    filename = item.filename,
                    remotePath = remotePath,
                    url = remoteURL,
                    isImage = item.isImage
                )
            }

            // Fallback to multipart
            val multipartUrl = core.makeURL("/api/uploads")
            val multipartBody = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                    "file",
                    item.filename,
                    item.data.toRequestBody(item.mimeType.toMediaType())
                )
                .build()
            val multiReq = Request.Builder()
                .url(multipartUrl)
                .post(multipartBody)
                .header("Accept", "application/json")
                .apply {
                    core.token?.trim()?.takeIf { it.isNotEmpty() }?.let {
                        header("Authorization", "Bearer $it")
                    }
                }
                .build()
            val multiResp = core.httpClient.newCall(multiReq).execute()
            val multiCode = multiResp.code
            val multiBytes = multiResp.body?.bytes() ?: ByteArray(0)
            multiResp.close()
            if (multiCode !in 200..299) {
                throw OrbError("Upload failed (HTTP $multiCode)")
            }
            val parsed = OrbJSON.dict(OrbJSON.parse(multiBytes))
            val remotePath = OrbJSON.str(parsed, "path", "file_path", "local_path", "url", "id")
                ?: item.filename
            val remoteURL = OrbJSON.str(parsed, "url", "download_url")
            OrbUploadedAttachment(
                filename = item.filename,
                remotePath = remotePath,
                url = remoteURL,
                isImage = item.isImage
            )
        }

    fun formatPrompt(text: String, uploaded: List<OrbUploadedAttachment>): String {
        val trimmed = text.trim()
        if (uploaded.isEmpty()) return trimmed
        val lines = uploaded.map { item ->
            val kind = if (item.isImage) "image" else "file"
            if (!item.url.isNullOrEmpty()) {
                "- [$kind] ${item.filename}: ${item.remotePath} (${item.url})"
            } else {
                "- [$kind] ${item.filename}: ${item.remotePath}"
            }
        }
        val header = if (trimmed.isEmpty()) {
            "Please inspect the attached file(s):"
        } else {
            "$trimmed\n\nAttached context:"
        }
        return "$header\n${lines.joinToString("\n")}"
    }

    suspend fun readUri(context: Context, uri: Uri): OrbPendingAttachment? = withContext(Dispatchers.IO) {
        try {
            val cr = context.contentResolver
            val mime = cr.getType(uri) ?: "application/octet-stream"
            var name = "attachment"
            cr.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) {
                    cursor.getString(idx)?.takeIf { it.isNotEmpty() }?.let { name = it }
                }
            }
            val rawBytes = cr.openInputStream(uri)?.use { it.readBytes() } ?: return@withContext null
            if (mime.startsWith("image/")) {
                val bmp = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
                if (bmp != null) {
                    val out = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    val jpgBytes = out.toByteArray()
                    val finalName = if (name.contains(".")) name else "photo-${UUID.randomUUID().toString().take(6)}.jpg"
                    return@withContext OrbPendingAttachment(
                        filename = finalName,
                        mimeType = "image/jpeg",
                        data = jpgBytes,
                        thumbnail = bmp
                    )
                }
            }
            OrbPendingAttachment(
                filename = name,
                mimeType = mime,
                data = rawBytes,
                thumbnail = null
            )
        } catch (_: Throwable) {
            null
        }
    }
}

@Composable
fun OrbAttachmentStrip(
    items: List<OrbPendingAttachment>,
    onRemove: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items.forEach { item ->
            Box(contentAlignment = Alignment.TopEnd) {
                if (item.thumbnail != null) {
                    Image(
                        bitmap = item.thumbnail.asImageBitmap(),
                        contentDescription = item.filename,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(54.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                    )
                } else {
                    Row(
                        modifier = Modifier
                            .height(54.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Description,
                            contentDescription = null,
                            tint = OrbStyle.textSecondary,
                            modifier = Modifier.size(13.dp)
                        )
                        Text(
                            text = item.filename,
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 120.dp)
                        )
                    }
                }
                Box(
                    modifier = Modifier
                        .offset(x = 5.dp, y = (-5).dp)
                        .size(18.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.78f))
                        .border(0.5.dp, OrbStyle.borderStrong, CircleShape)
                        .orbPressClickable { onRemove(item.id) },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Remove",
                        tint = Color.White,
                        modifier = Modifier.size(9.dp)
                    )
                }
            }
        }
    }
}

data class OrbImageAttachmentRef(
    val id: String,
    val filename: String,
    val path: String,
    val url: String?
)

data class OrbParsedUserPrompt(
    val body: String,
    val images: List<OrbImageAttachmentRef>,
    val files: List<OrbImageAttachmentRef>
)

object OrbUserPromptParser {
    private val lineRegex = Regex("^\\s*-\\s*\\[(image|file)\\]\\s*([^:]+):\\s*(\\S+)(?:\\s*\\(([^)]+)\\))?\\s*$", RegexOption.IGNORE_CASE)

    fun parse(raw: String): OrbParsedUserPrompt {
        val images = mutableListOf<OrbImageAttachmentRef>()
        val files = mutableListOf<OrbImageAttachmentRef>()
        val keptLines = mutableListOf<String>()

        for (line in raw.split("\n")) {
            val trimmed = line.trim()
            if (trimmed == "Attached context:" || trimmed == "Please inspect the attached file(s):") {
                continue
            }
            val m = lineRegex.matchEntire(line)
            if (m != null) {
                val kind = m.groupValues[1].lowercase()
                val filename = m.groupValues[2].trim()
                val path = m.groupValues[3].trim()
                val url = m.groupValues[4].trim().takeIf { it.isNotEmpty() }
                val ref = OrbImageAttachmentRef(
                    id = "$kind-$filename-$path",
                    filename = filename,
                    path = path,
                    url = url
                )
                if (kind == "image") images.add(ref) else files.add(ref)
            } else {
                keptLines.add(line)
            }
        }
        val body = keptLines.joinToString("\n").trim()
        return OrbParsedUserPrompt(body = body, images = images, files = files)
    }
}

object OrbRemoteImageLoader {
    private val cache = mutableStateMapOf<String, Bitmap>()

    fun cached(key: String): Bitmap? = cache[key]

    suspend fun load(
        ref: OrbImageAttachmentRef,
        workspaceId: String?,
        core: OrbCore
    ): Bitmap? = withContext(Dispatchers.IO) {
        val cacheKey = "${ref.path}|${ref.url ?: ""}"
        cache[cacheKey]?.let { return@withContext it }

        for (endpoint in candidateEndpoints(ref, workspaceId, core)) {
            val bytes = fetchBytes(endpoint, core) ?: continue
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bmp != null) {
                withContext(Dispatchers.Main) {
                    cache[cacheKey] = bmp
                }
                return@withContext bmp
            }
        }
        null
    }

    private fun candidateEndpoints(
        ref: OrbImageAttachmentRef,
        workspaceId: String?,
        core: OrbCore
    ): List<String> {
        val list = mutableListOf<String>()
        if (!ref.url.isNullOrEmpty()) list.add(ref.url)
        val encodedPath = core.encodeComponent(ref.path)
        val encodedName = core.encodeComponent(ref.filename)
        if (!workspaceId.isNullOrEmpty()) {
            list.add("/api/workspaces/$workspaceId/files/download?path=$encodedPath")
        }
        list.add("/api/fs/download?path=$encodedPath")
        list.add("/api/uploads/$encodedName")
        if (ref.path.startsWith("/api/") || ref.path.startsWith("http://") || ref.path.startsWith("https://")) {
            list.add(ref.path)
        }
        return list
    }

    private fun fetchBytes(endpoint: String, core: OrbCore): ByteArray? {
        return try {
            val url = if (endpoint.startsWith("http://") || endpoint.startsWith("https://")) {
                endpoint
            } else {
                core.makeURL(endpoint)
            }
            val req = Request.Builder()
                .url(url)
                .get()
                .apply {
                    core.token?.trim()?.takeIf { it.isNotEmpty() }?.let {
                        header("Authorization", "Bearer $it")
                    }
                }
                .build()
            val resp = core.httpClient.newCall(req).execute()
            val code = resp.code
            val bytes = resp.body?.bytes()
            resp.close()
            if (code in 200..299 && bytes != null && bytes.isNotEmpty()) bytes else null
        } catch (_: Throwable) {
            null
        }
    }
}

@Composable
fun OrbImageStrip(
    images: List<OrbImageAttachmentRef>,
    workspaceId: String?,
    core: OrbCore
) {
    var selectedIndex by remember { mutableStateOf<Int?>(null) }

    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        images.forEachIndexed { idx, ref ->
            OrbImageThumb(
                ref = ref,
                workspaceId = workspaceId,
                core = core,
                onTap = { selectedIndex = idx }
            )
        }
    }

    selectedIndex?.let { startIndex ->
        Dialog(
            onDismissRequest = { selectedIndex = null },
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            OrbImageGallery(
                images = images,
                startIndex = startIndex,
                workspaceId = workspaceId,
                core = core,
                onDismiss = { selectedIndex = null }
            )
        }
    }
}

@Composable
private fun OrbImageThumb(
    ref: OrbImageAttachmentRef,
    workspaceId: String?,
    core: OrbCore,
    onTap: () -> Unit
) {
    val cacheKey = "${ref.path}|${ref.url ?: ""}"
    var bitmap by remember(cacheKey) { mutableStateOf(OrbRemoteImageLoader.cached(cacheKey)) }
    var failed by remember(cacheKey) { mutableStateOf(false) }

    LaunchedEffect(cacheKey) {
        if (bitmap == null) {
            val loaded = OrbRemoteImageLoader.load(ref, workspaceId, core)
            bitmap = loaded
            failed = loaded == null
        }
    }

    Box(
        modifier = Modifier
            .size(132.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(14.dp))
            .orbPressClickable { onTap() },
        contentAlignment = Alignment.Center
    ) {
        val bmp = bitmap
        if (bmp != null) {
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = ref.filename,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(8.dp)
            ) {
                if (failed) {
                    Icon(
                        imageVector = Icons.Default.Image,
                        contentDescription = null,
                        tint = OrbStyle.textMuted,
                        modifier = Modifier.size(18.dp)
                    )
                } else {
                    CircularProgressIndicator(
                        color = OrbStyle.textSecondary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(18.dp)
                    )
                }
                Text(
                    text = ref.filename,
                    color = OrbStyle.textSecondary,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
fun OrbImageGallery(
    images: List<OrbImageAttachmentRef>,
    startIndex: Int,
    workspaceId: String?,
    core: OrbCore,
    onDismiss: () -> Unit
) {
    val pagerState = rememberPagerState(
        initialPage = startIndex.coerceIn(0, maxOf(0, images.lastIndex)),
        pageCount = { images.size }
    )
    val currentTitle = images.getOrNull(pagerState.currentPage)?.filename ?: ""

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.96f))
    ) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxSize()
        ) { page ->
            val ref = images[page]
            val cacheKey = "${ref.path}|${ref.url ?: ""}"
            var bitmap by remember(cacheKey) { mutableStateOf(OrbRemoteImageLoader.cached(cacheKey)) }
            var scale by remember { mutableFloatStateOf(1f) }
            var offset by remember { mutableStateOf(Offset.Zero) }

            LaunchedEffect(cacheKey) {
                if (bitmap == null) {
                    bitmap = OrbRemoteImageLoader.load(ref, workspaceId, core)
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            scale = (scale * zoom).coerceIn(1f, 4f)
                            offset = if (scale > 1f) offset + pan else Offset.Zero
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                val bmp = bitmap
                if (bmp != null) {
                    Image(
                        bitmap = bmp.asImageBitmap(),
                        contentDescription = ref.filename,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(16.dp)
                            .graphicsLayer(
                                scaleX = scale,
                                scaleY = scale,
                                translationX = offset.x,
                                translationY = offset.y
                            )
                    )
                } else {
                    CircularProgressIndicator(color = Color.White)
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 20.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = currentTitle,
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Spacer(modifier = Modifier.width(12.dp))
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f))
                    .orbPressClickable { onDismiss() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = "Close",
                    tint = Color.White,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbPreviewSheet(
    core: OrbCore,
    path: String,
    workspaceId: String?,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var content by remember { mutableStateOf("") }
    var imageBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var rawBytes by remember { mutableStateOf<ByteArray?>(null) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    val fileName = remember(path) { path.substringAfterLast('/').ifEmpty { path } }

    LaunchedEffect(path, workspaceId) {
        loading = true
        error = null
        withContext(Dispatchers.IO) {
            val encoded = core.encodeComponent(path)
            val endpoint = if (!workspaceId.isNullOrEmpty()) {
                "/api/workspaces/$workspaceId/files/download?path=$encoded"
            } else {
                "/api/fs/download?path=$encoded"
            }
            try {
                val url = core.makeURL(endpoint)
                val req = Request.Builder().url(url).get().apply {
                    core.token?.trim()?.takeIf { it.isNotEmpty() }?.let {
                        header("Authorization", "Bearer $it")
                    }
                }.build()
                val resp = core.httpClient.newCall(req).execute()
                val code = resp.code
                val bytes = resp.body?.bytes() ?: ByteArray(0)
                resp.close()
                if (code !in 200..299) {
                    throw OrbError("HTTP $code")
                }
                rawBytes = bytes
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bmp != null) {
                    imageBitmap = bmp
                } else {
                    content = bytes.decodeToString()
                }
            } catch (e: Throwable) {
                error = e.message ?: "Failed to load file"
            } finally {
                loading = false
            }
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
                .height(640.dp)
                .padding(horizontal = 16.dp)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = fileName,
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                if (rawBytes != null) {
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(OrbStyle.surface)
                            .orbPressClickable {
                                shareBytes(context, fileName, rawBytes!!)
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
                    Spacer(modifier = Modifier.width(8.dp))
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

            when {
                loading -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = OrbStyle.textSecondary)
                    }
                }
                error != null -> {
                    OrbNotice(title = error!!, log = core.lastErrorLog.value)
                }
                imageBitmap != null -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Image(
                            bitmap = imageBitmap!!.asImageBitmap(),
                            contentDescription = fileName,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                }
                else -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(bottom = 24.dp)
                    ) {
                        if (path.lowercase().endsWith(".md")) {
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
}

fun shareBytes(context: Context, fileName: String, bytes: ByteArray) {
    try {
        val dir = File(context.cacheDir, "orb_shared")
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, fileName.replace(Regex("[^a-zA-Z0-9._-]"), "_"))
        file.writeBytes(bytes)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "*/*"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, fileName))
    } catch (_: Throwable) {
    }
}
