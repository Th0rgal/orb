package sh.sandboxed.dashboard.orb

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.webkit.MimeTypeMap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.InsertDriveFile
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.TextSnippet
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.File

/** What file chips need from their conversation (iOS `OrbFileContext`). */
data class OrbFileContext(
    val scope: OrbFileScope,
    val shared: List<OrbSharedFile> = emptyList(),
    /** Loads shared images inline; without it images stay chips. */
    val core: OrbCore? = null,
    val open: (OrbFileRef) -> Unit
)

val LocalOrbFiles = compositionLocalOf<OrbFileContext?> { null }

fun OrbFileKind.icon(): ImageVector = when (this) {
    OrbFileKind.Image, OrbFileKind.Svg -> Icons.Default.Image
    OrbFileKind.Pdf -> Icons.Default.PictureAsPdf
    OrbFileKind.Markdown -> Icons.Default.Description
    OrbFileKind.Csv -> Icons.Default.TableChart
    OrbFileKind.Json -> Icons.Default.DataObject
    OrbFileKind.Code -> Icons.Default.Code
    OrbFileKind.Text -> Icons.Default.TextSnippet
    OrbFileKind.Other -> Icons.Default.InsertDriveFile
}

/** Assistant Markdown with shared-file tags rendered as chips (never as raw markup). */
@Composable
fun OrbMarkdownWithFiles(text: String, streaming: Boolean = false) {
    val files = LocalOrbFiles.current
    val segments = remember(text, streaming) { OrbFileRefs.segments(text, streaming) }
    if (segments.size == 1 && segments[0] is OrbFileSegment.Text) {
        OrbRichText(markdown = (segments[0] as OrbFileSegment.Text).text, tone = OrbRichTextTone.Primary, streaming = streaming)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        segments.forEach { segment ->
            when (segment) {
                is OrbFileSegment.Text -> OrbRichText(markdown = segment.text, tone = OrbRichTextTone.Primary, streaming = streaming && segment == segments.last())
                is OrbFileSegment.File -> {
                    val ref = OrbFileRefs.enrich(segment.ref, files?.shared ?: emptyList())
                    val core = files?.core
                    when {
                        ref.unavailable -> OrbUnavailableFileChip(ref)
                        ref.type == "image" && (ref.kind == OrbFileKind.Image || ref.kind == OrbFileKind.Svg) && core != null ->
                            OrbInlineImage(core, ref, files.scope) { files.open(ref) }
                        else -> OrbFileChip(ref) { files?.open?.invoke(ref) }
                    }
                }
            }
        }
    }
}

@Composable
fun OrbFileChip(ref: OrbFileRef, onClick: () -> Unit) {
    val subtitle = listOfNotNull(ref.name.takeIf { it != ref.label }, OrbFileRefs.formatSize(ref.size))
        .joinToString(" · ").ifEmpty { ref.kind.key.replaceFirstChar { it.uppercase() } }
    Row(
        modifier = Modifier
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.card)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .orbPressClickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .testTag("file.chip.${ref.name}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(7.dp)).background(OrbStyle.elevated),
            contentAlignment = Alignment.Center
        ) { Icon(ref.kind.icon(), contentDescription = null, tint = OrbStyle.textSecondary, modifier = Modifier.size(17.dp)) }
        Column(modifier = Modifier.weight(1f)) {
            Text(ref.label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.Default.ChevronRight, contentDescription = "Open ${ref.label}", tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
    }
}

/** An image an agent shared, shown in the transcript; tap opens the preview. The chip stands in until it loads. */
@Composable
fun OrbInlineImage(core: OrbCore, ref: OrbFileRef, scope: OrbFileScope, onClick: () -> Unit) {
    val context = LocalContext.current
    val service = remember { OrbFileService.get(core, context) }
    var bitmap by remember(ref) { mutableStateOf<Bitmap?>(null) }
    var svg by remember(ref) { mutableStateOf<Pair<ByteArray, Double>?>(null) }
    LaunchedEffect(ref, scope) {
        if (ref.kind == OrbFileKind.Svg) {
            svg = try {
                val file = service.fetch(ref, scope)
                withContext(Dispatchers.IO) { OrbSvg.read(file)?.let { it to (OrbSvg.aspectRatio(String(it, Charsets.UTF_8)) ?: (4.0 / 3.0)) } }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Throwable) {
                null
            }
            return@LaunchedEffect
        }
        bitmap = try {
            val file = service.fetch(ref, scope)
            withContext(Dispatchers.Default) { decodeBitmap(file, maxDimension = 1600) }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Throwable) {
            null
        }
    }
    svg?.let { (bytes, ratio) ->
        Box(
            Modifier
                .widthIn(max = 420.dp)
                .heightIn(max = 320.dp)
                .aspectRatio(ratio.toFloat().coerceIn(0.5f, 4f), matchHeightConstraintsFirst = true)
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                .testTag("file.image.${ref.name}")
        ) {
            AndroidView(factory = { OrbSvg.webView(it, bytes, interactive = false) }, modifier = Modifier.fillMaxSize())
            // The web view never takes touches; the overlay opens the preview.
            Box(Modifier.fillMaxSize().orbPressClickable { onClick() })
        }
        return
    }
    val image = bitmap
    if (image == null) {
        OrbFileChip(ref, onClick)
        return
    }
    Image(
        bitmap = image.asImageBitmap(),
        contentDescription = ref.label,
        contentScale = ContentScale.Fit,
        alignment = Alignment.CenterStart,
        modifier = Modifier
            .widthIn(max = 420.dp)
            .heightIn(max = 320.dp)
            .aspectRatio((image.width.toFloat() / image.height.coerceAtLeast(1)).coerceIn(0.5f, 4f), matchHeightConstraintsFirst = true)
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .orbPressClickable { onClick() }
            .testTag("file.image.${ref.name}")
    )
}

/** A share Core could not copy: named, never fetched. */
@Composable
fun OrbUnavailableFileChip(ref: OrbFileRef) {
    Row(
        modifier = Modifier
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.card)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .testTag("file.unavailable.${ref.name}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(7.dp)).background(OrbStyle.elevated),
            contentAlignment = Alignment.Center
        ) { Icon(ref.kind.icon(), contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(17.dp)) }
        Column(modifier = Modifier.weight(1f)) {
            Text(ref.label, color = OrbStyle.textSecondary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("File no longer available", color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1)
        }
    }
}

fun shareFile(context: Context, file: File, label: String) {
    try {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(OrbFileRefs.fileExtension(file.name)) ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, label))
    } catch (_: ActivityNotFoundException) {
    } catch (_: IllegalArgumentException) {
    }
}

@Composable
private fun OrbSheetHeader(title: String, onBack: (() -> Unit)?, file: File?, onDone: () -> Unit) {
    val context = LocalContext.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (onBack != null) {
            Box(Modifier.size(34.dp).clip(CircleShape).background(OrbStyle.surface).orbPressClickable { onBack() }, contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(16.dp))
            }
        }
        Text(title, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (file != null) {
            Box(Modifier.size(34.dp).clip(CircleShape).background(OrbStyle.surface).orbPressClickable { shareFile(context, file, title) }, contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Share, contentDescription = "Share", tint = Color.White, modifier = Modifier.size(16.dp))
            }
        }
        Text("Done", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(CircleShape).orbPressClickable { onDone() }.padding(horizontal = 10.dp, vertical = 6.dp))
    }
}

/** One preview component for chips, the Files tab and the workspace. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbFileViewerSheet(core: OrbCore, ref: OrbFileRef, scope: OrbFileScope, onDismiss: () -> Unit) {
    TrackPage("file_viewer", UsageTelemetry.Surface.Sheet, entryPoint = "transcript")
    androidx.compose.runtime.LaunchedEffect(Unit) { UsageTelemetry.trackAction(UsageTelemetry.Action.FileViewerOpen, "transcript") }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var file by remember(ref) { mutableStateOf<File?>(null) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = OrbStyle.background, contentColor = Color.White) {
        Column(Modifier.fillMaxWidth().height(680.dp).padding(horizontal = 16.dp)) {
            OrbSheetHeader(ref.label, null, file, onDismiss)
            OrbFileViewer(core, ref, scope) { file = it }
        }
    }
}

@Composable
fun OrbFileViewer(core: OrbCore, ref: OrbFileRef, scope: OrbFileScope, onLoaded: (File?) -> Unit = {}) {
    val context = LocalContext.current
    val service = remember { OrbFileService.get(core, context) }
    var file by remember(ref) { mutableStateOf<File?>(null) }
    var progress by remember(ref) { mutableStateOf<Float?>(null) }
    var failure by remember(ref) { mutableStateOf<OrbFileError?>(null) }
    var attempt by remember(ref) { mutableIntStateOf(0) }
    LaunchedEffect(ref, attempt) {
        failure = null
        try {
            val loaded = service.fetch(ref, scope) { value -> progress = value }
            file = loaded
            onLoaded(loaded)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            failure = OrbFileError.from(e, ref.label)
        }
    }
    val loaded = file
    val error = failure
    Box(Modifier.fillMaxSize().testTag("file.viewer"), contentAlignment = Alignment.Center) {
        when {
            loaded != null -> OrbFileContent(ref, loaded)
            error != null -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(24.dp)) {
                Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = OrbStyle.warning, modifier = Modifier.size(30.dp))
                Text(error.message ?: "Couldn’t open this file.", color = Color.White, fontSize = 14.sp, modifier = Modifier.testTag("file.viewer.error"))
                if (error !is OrbFileError.NotFound) {
                    Text("Try again", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(CircleShape).background(OrbStyle.surface).orbPressClickable { attempt++ }.padding(horizontal = 14.dp, vertical = 8.dp))
                }
            }
            else -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.testTag("file.viewer.loading")) {
                Icon(ref.kind.icon(), contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(34.dp))
                val value = progress
                if (value != null) {
                    LinearProgressIndicator(progress = { value }, modifier = Modifier.width(220.dp), color = Color.White, trackColor = OrbStyle.surface)
                    val percent = "${(value * 100).toInt()}%"
                    val sizeText = ref.size?.let { "${OrbFileRefs.formatSize((it * value).toLong())} of ${OrbFileRefs.formatSize(it)} · " } ?: ""
                    Text(sizeText + percent, color = OrbStyle.textSecondary, fontSize = 12.sp)
                } else {
                    CircularProgressIndicator(color = OrbStyle.textSecondary)
                    Text("Downloading…", color = OrbStyle.textSecondary, fontSize = 12.sp)
                }
            }
        }
    }
}

private const val TEXT_LIMIT = 4 * 1024 * 1024

private fun readText(file: File): Pair<String, Boolean>? {
    val bytes = file.inputStream().use { input -> input.readNBytesCompat(TEXT_LIMIT + 1) }
    val truncated = bytes.size > TEXT_LIMIT
    val slice = if (truncated) bytes.copyOf(TEXT_LIMIT) else bytes
    if (slice.take(8192).any { it == 0.toByte() }) return null
    return slice.decodeToString() to truncated
}

private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (out.size() < limit) {
        val n = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (n < 0) break
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}

private fun decodeBitmap(file: File, maxDimension: Int = 4096): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (bounds.outWidth / sample > maxDimension || bounds.outHeight / sample > maxDimension) sample *= 2
    return runCatching { BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) }.getOrNull()
}

fun prettyJson(text: String): String {
    if (text.length > 2 * 1024 * 1024) return text
    val parsed = OrbJSON.parse(text) ?: return text
    return runCatching {
        kotlinx.serialization.json.Json { prettyPrint = true }.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), OrbJSON.toJsonElement(parsed))
    }.getOrDefault(text)
}

@Composable
fun OrbFileContent(ref: OrbFileRef, file: File) {
    when (ref.kind) {
        OrbFileKind.Image -> {
            val bitmap = remember(file) { decodeBitmap(file) }
            if (bitmap != null) {
                Image(bitmap.asImageBitmap(), contentDescription = ref.label, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().testTag("file.viewer.image"))
            } else OrbUnsupported(ref, file, "This image format can’t be shown here.")
        }
        OrbFileKind.Svg -> {
            val svg = remember(file) { OrbSvg.read(file) }
            if (svg != null) {
                AndroidView(factory = { OrbSvg.webView(it, svg, interactive = true) }, modifier = Modifier.fillMaxSize().testTag("file.viewer.svg"))
            } else OrbUnsupported(ref, file, "This SVG is too large or isn’t valid text.")
        }
        OrbFileKind.Pdf -> OrbPdfPages(ref, file)
        OrbFileKind.Markdown, OrbFileKind.Csv, OrbFileKind.Json, OrbFileKind.Code, OrbFileKind.Text -> {
            val text = remember(file) { runCatching { readText(file) }.getOrNull() }
            if (text == null) { OrbUnsupported(ref, file, "This file isn’t text Orb can show."); return }
            Column(Modifier.fillMaxSize()) {
                if (text.second) Text("Showing the first 4 MB. Share the file to see all of it.", color = OrbStyle.textSecondary, fontSize = 12.sp, modifier = Modifier.padding(8.dp))
                when (ref.kind) {
                    OrbFileKind.Markdown -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp).testTag("file.viewer.markdown")) {
                        OrbRichText(markdown = text.first, tone = OrbRichTextTone.Primary)
                    }
                    OrbFileKind.Csv -> OrbCsvTable(remember(text) { OrbCSV.parse(text.first, if (OrbFileRefs.fileExtension(ref.name) == "tsv") '\t' else ',') })
                    OrbFileKind.Json -> OrbCodeView(remember(text) { prettyJson(text.first) }, "json")
                    else -> OrbCodeView(text.first, OrbFileRefs.fileExtension(ref.name))
                }
            }
        }
        OrbFileKind.Other -> OrbUnsupported(ref, file, null)
    }
}

@Composable
private fun OrbUnsupported(ref: OrbFileRef, file: File, reason: String?) {
    val context = LocalContext.current
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(28.dp).testTag("file.viewer.unsupported")) {
        Icon(ref.kind.icon(), contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(40.dp))
        Text(ref.name, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        OrbFileRefs.formatSize(file.length())?.let { Text(it, color = OrbStyle.textSecondary, fontSize = 12.sp) }
        Text(reason ?: "No preview for this type. Save it or open it in another app.", color = OrbStyle.textSecondary, fontSize = 14.sp)
        Row(
            modifier = Modifier.clip(CircleShape).background(Color.White).orbPressClickable { shareFile(context, file, ref.label) }
                .padding(horizontal = 16.dp, vertical = 10.dp).testTag("file.viewer.shareButton"),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Icon(Icons.Default.Share, contentDescription = null, tint = Color.Black, modifier = Modifier.size(16.dp))
            Text("Share or save…", color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun OrbPdfPages(ref: OrbFileRef, file: File) {
    val pages = remember(file) { mutableStateListOf<Bitmap>() }
    var failed by remember(file) { mutableStateOf(false) }
    LaunchedEffect(file) {
        withContext(Dispatchers.IO) {
            runCatching {
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { renderer ->
                        for (index in 0 until minOf(renderer.pageCount, 200)) {
                            renderer.openPage(index).use { page ->
                                val width = 1080
                                val bitmap = Bitmap.createBitmap(width, (width.toFloat() * page.height / page.width).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                                bitmap.eraseColor(android.graphics.Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                withContext(Dispatchers.Main) { pages.add(bitmap) }
                            }
                        }
                    }
                }
            }.onFailure { failed = true }
        }
    }
    if (failed && pages.isEmpty()) { OrbUnsupported(ref, file, "This PDF can’t be opened."); return }
    LazyColumn(Modifier.fillMaxSize().testTag("file.viewer.pdf"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(pages.size) { index ->
            Image(pages[index].asImageBitmap(), contentDescription = "Page ${index + 1}", contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth())
        }
    }
}

fun orbCodeColor(token: OrbCodeHighlight.Token): Color = when (token) {
    OrbCodeHighlight.Token.Keyword -> Color(0xFFC78FF2)
    OrbCodeHighlight.Token.Str -> Color(0xFF99D18C)
    OrbCodeHighlight.Token.Comment -> OrbStyle.textMuted
    OrbCodeHighlight.Token.Number -> Color(0xFFF2B873)
    OrbCodeHighlight.Token.Added -> OrbStyle.success
    OrbCodeHighlight.Token.Removed -> OrbStyle.error
}

fun orbHighlighted(text: String, language: String): AnnotatedString {
    val builder = AnnotatedString.Builder(text)
    for ((range, token) in OrbCodeHighlight.tokens(text, language)) {
        builder.addStyle(SpanStyle(color = orbCodeColor(token)), range.first, range.last + 1)
    }
    return builder.toAnnotatedString()
}

/** Monospaced, highlighted, selectable source. */
@Composable
fun OrbCodeView(text: String, language: String) {
    val highlighted = remember(text, language) { orbHighlighted(text, language) }
    SelectionContainer {
        Text(
            highlighted, color = Color(0xFFE6E6E6), fontSize = 12.sp, fontFamily = FontFamily.Monospace, softWrap = false,
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(4.dp).testTag("file.viewer.text")
        )
    }
}

@Composable
fun OrbCsvTable(rows: List<List<String>>) {
    val columns = rows.maxOfOrNull { it.size } ?: 0
    val widths = remember(rows) {
        (0 until columns).map { c -> (rows.take(200).maxOfOrNull { it.getOrNull(c)?.length ?: 0 } ?: 0).let { (it * 7.4f + 18).coerceIn(56f, 260f).dp } }
    }
    val shown = 500
    Box(Modifier.fillMaxSize().horizontalScroll(rememberScrollState()).testTag("file.viewer.csv")) {
        LazyColumn {
            itemsIndexed(rows.take(shown + 1)) { index, row ->
                Row(Modifier.background(if (index == 0) OrbStyle.elevated else if (index % 2 == 0) OrbStyle.surface else Color.Transparent)) {
                    widths.forEachIndexed { c, width ->
                        Text(row.getOrElse(c) { "" }, color = Color.White, fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                            fontWeight = if (index == 0) FontWeight.SemiBold else FontWeight.Normal, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.width(width).padding(horizontal = 6.dp, vertical = 6.dp))
                    }
                }
            }
            if (rows.size - 1 > shown) item { Text("Showing $shown of ${rows.size - 1} rows", color = OrbStyle.textMuted, fontSize = 12.sp, modifier = Modifier.padding(10.dp)) }
        }
    }
}

/**
 * Files tab: every file shared in the conversation (newest first) and, when the mission
 * has one, its workspace (read-only).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbFilesSheet(core: OrbCore, scope: OrbFileScope, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val service = remember { OrbFileService.get(core, context) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var files by remember { mutableStateOf<List<OrbFileRef>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var workspace by remember { mutableStateOf(false) }
    var sessions by remember { mutableStateOf<List<OrbFileSession>>(emptyList()) }
    // The source being browsed: the workspace, or an earlier session of the chain.
    var browsing by remember(scope) { mutableStateOf(scope) }
    var browseTitle by remember { mutableStateOf("Workspace") }
    var viewing by remember { mutableStateOf<OrbFileRef?>(null) }
    var viewingFile by remember { mutableStateOf<File?>(null) }
    val browse = remember { mutableStateListOf<String>() }
    var entries by remember { mutableStateOf<List<OrbWorkspaceEntry>>(emptyList()) }
    var browseError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(scope) {
        coroutineScope {
            val roots = async { runCatching { service.roots(scope) }.getOrNull() }
            try { files = OrbFileRefs.collect(service.messages(scope)); error = null } catch (e: Throwable) { error = e.message }
            loading = false
            roots.await()?.let { (hasWorkspace, found) -> workspace = hasWorkspace; sessions = found }
        }
    }
    val currentDir = browse.lastOrNull()
    LaunchedEffect(currentDir) {
        val dir = currentDir ?: return@LaunchedEffect
        entries = emptyList(); browseError = null
        try { entries = service.list(browsing, dir) } catch (e: Throwable) { browseError = e.message }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = OrbStyle.background, contentColor = Color.White) {
        Column(Modifier.fillMaxWidth().height(680.dp).padding(horizontal = 16.dp).testTag("files.sheet")) {
            val open = viewing
            when {
                open != null -> {
                    OrbSheetHeader(open.label, { viewing = null; viewingFile = null }, viewingFile, onDismiss)
                    OrbFileViewer(core, open, if (currentDir != null) browsing else scope) { viewingFile = it }
                }
                currentDir != null -> {
                    OrbSheetHeader(if (currentDir.isEmpty()) browseTitle else OrbFileRefs.fileName(currentDir), { browse.removeAt(browse.lastIndex) }, null, onDismiss)
                    browseError?.let { OrbNotice(title = it, log = null) }
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        items(entries, key = { it.path }) { entry ->
                            val ref = OrbFileRef(type = "file", path = entry.path, label = entry.name, size = entry.size)
                            OrbFileRow(
                                icon = if (entry.isDirectory) Icons.Default.Folder else ref.kind.icon(),
                                title = entry.name,
                                subtitle = if (entry.isDirectory) "Folder" else OrbFileRefs.formatSize(entry.size) ?: "",
                                tag = "workspace.row.${entry.name}"
                            ) { if (entry.isDirectory) browse.add(entry.path) else viewing = ref }
                        }
                    }
                }
                else -> {
                    OrbSheetHeader("Files", null, null, onDismiss)
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        item { OrbSectionLabel("Shared in this conversation") }
                        when {
                            loading && files.isEmpty() -> item { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { CircularProgressIndicator(Modifier.size(16.dp), color = OrbStyle.textSecondary, strokeWidth = 2.dp); Text("Loading files…", color = OrbStyle.textSecondary, fontSize = 14.sp) } }
                            error != null && files.isEmpty() -> item { OrbNotice(title = error!!, log = null) }
                            files.isEmpty() -> item { Text("No files shared yet. Files the agent shares appear here.", color = OrbStyle.textSecondary, fontSize = 14.sp, modifier = Modifier.padding(12.dp).testTag("files.empty")) }
                        }
                        items(files, key = { it.id }) { file ->
                            OrbFileRow(
                                icon = file.kind.icon(), title = file.label,
                                subtitle = listOfNotNull(file.name.takeIf { it != file.label }, OrbFileRefs.formatSize(file.size), file.sharedAt?.let { OrbJSON.relative(it) })
                                    .filter { it.isNotEmpty() }.joinToString(" · "),
                                tag = "files.row.${file.name}"
                            ) { viewing = file }
                        }
                        if (workspace) {
                            item { Spacer(Modifier.height(12.dp)); OrbSectionLabel("Workspace") }
                            item { OrbFileRow(Icons.Default.Folder, "Browse workspace", "Read-only view of the mission’s files, wherever it runs.", "files.workspace") { browsing = scope; browseTitle = "Workspace"; browse.add("") } }
                        }
                        for (later in listOf(false, true)) {
                            val group = sessions.filter { it.later == later }
                            if (group.isEmpty()) continue
                            item { Spacer(Modifier.height(12.dp)); OrbSectionLabel(if (later) "Later sessions" else "Earlier sessions") }
                            items(group, key = { it.id }) { session ->
                                OrbFileRow(Icons.Default.History, session.label, "Read-only workspace of that session on the same machine.", "files.session.${session.id}") {
                                    browsing = scope.copy(source = session.id); browseTitle = session.label; browse.add("")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OrbSectionLabel(text: String) {
    Text(text.uppercase(), color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 6.dp))
}

@Composable
private fun OrbFileRow(icon: ImageVector, title: String, subtitle: String, tag: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).orbPressClickable { onClick() }.padding(horizontal = 8.dp, vertical = 10.dp).testTag(tag),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(icon, contentDescription = null, tint = OrbStyle.textSecondary, modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle.isNotEmpty()) Text(subtitle, color = OrbStyle.textMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = OrbStyle.textMuted, modifier = Modifier.size(16.dp))
    }
}
