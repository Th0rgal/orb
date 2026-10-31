package sh.sandboxed.dashboard.orb

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

enum class OrbRichTextTone(val cssColor: String) {
    Primary("#FFFFFF"),
    Secondary("#9B9B9B")
}

internal const val MAX_TRANSCRIPT_ROW_CHARS = 32_768
private const val MAX_DISPLAY_CODE_CHARS = 12_000
private const val MAX_REMOTE_IMAGE_BYTES = 20 * 1024 * 1024

@Composable
fun OrbRichText(
    markdown: String,
    tone: OrbRichTextTone = OrbRichTextTone.Primary,
    modifier: Modifier = Modifier,
    /** A reply still arriving: its committed prefix is parsed once (OrbStreamBlocks). */
    streaming: Boolean = false
) {
    val cleaned = remember(markdown, streaming) { cleanRichText(markdown, streaming) }
    OrbNativeMarkdown(
        markdown = cleaned,
        tone = tone,
        streaming = streaming,
        modifier = modifier.fillMaxWidth()
    )
}

internal sealed class OrbMdBlock {
    data class Heading(val level: Int, val text: String) : OrbMdBlock()
    data class Paragraph(val text: String) : OrbMdBlock()
    data class CodeBlock(val language: String, val code: String) : OrbMdBlock()
    data class ListBlock(val ordered: Boolean, val items: List<String>) : OrbMdBlock()
    data class Quote(val text: String) : OrbMdBlock()
    /** All-empty `headers`: a loose pipe table without a header row (hidden). */
    data class Table(val headers: List<String>, val rows: List<List<String>>, val rightAligned: List<Boolean> = emptyList()) : OrbMdBlock()
    data class MathBlock(val latex: String, val complete: Boolean) : OrbMdBlock()
    data class ImageBlock(val alt: String, val url: String) : OrbMdBlock()
    data object Divider : OrbMdBlock()
}

@Composable
private fun OrbNativeMarkdown(
    markdown: String,
    tone: OrbRichTextTone,
    modifier: Modifier = Modifier,
    streaming: Boolean = false
) {
    val context = LocalContext.current
    val files = LocalOrbFiles.current
    var showFullSource by remember(markdown.length > MAX_TRANSCRIPT_ROW_CHARS) { mutableStateOf(false) }
    val truncated = !showFullSource && markdown.length > MAX_TRANSCRIPT_ROW_CHARS
    val effectiveSource = remember(markdown, truncated) {
        if (truncated) inlinePreview(markdown, MAX_TRANSCRIPT_ROW_CHARS) else markdown
    }
    val streamBlocks = remember { OrbStreamBlocks() }
    val blocks = remember(effectiveSource, streaming) {
        runCatching {
            if (streaming) streamBlocks.blocks(effectiveSource) else OrbMdCache.parse(effectiveSource)
        }.getOrElse { listOf(OrbMdBlock.Paragraph(effectiveSource)) }
    }
    val baseColor = if (tone == OrbRichTextTone.Primary) Color(0xFFE5E5E5) else OrbStyle.textSecondary
    var copiedBlockIdx by remember { mutableIntStateOf(-1) }

    val onOpenHref: (String) -> Unit = remember(context, files) {
        { href ->
            openSafeHref(context, files, href)
        }
    }

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        blocks.forEachIndexed { idx, block ->
            when (block) {
                is OrbMdBlock.Heading -> {
                    val fontSize = when (block.level) {
                        1 -> 18.sp
                        2 -> 16.5.sp
                        else -> 15.sp
                    }
                    Text(
                        text = remember(block.text, streaming) { parseInlineAnnotated(block.text, streaming, onOpenHref) },
                        color = Color.White,
                        fontSize = fontSize,
                        fontWeight = FontWeight.SemiBold,
                        lineHeight = (fontSize.value * 1.3f).sp,
                        modifier = Modifier.padding(top = if (idx == 0) 0.dp else 3.dp)
                    )
                }
                is OrbMdBlock.Paragraph -> {
                    Text(
                        text = remember(block.text, streaming) { parseInlineAnnotated(block.text, streaming, onOpenHref) },
                        color = baseColor,
                        fontSize = 15.sp,
                        lineHeight = 22.sp
                    )
                }
                is OrbMdBlock.Quote -> {
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Box(
                            modifier = Modifier
                                .width(2.dp)
                                .heightIn(min = 20.dp)
                                .background(Color.White.copy(alpha = 0.22f))
                        )
                        Spacer(modifier = Modifier.width(10.dp))
                        Text(
                            text = remember(block.text, streaming) { parseInlineAnnotated(block.text, streaming, onOpenHref) },
                            color = OrbStyle.textSecondary,
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                    }
                }
                is OrbMdBlock.ListBlock -> {
                    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        block.items.forEachIndexed { itemIdx, item ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = if (block.ordered) "${itemIdx + 1}." else "•",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 14.sp,
                                    lineHeight = 21.sp
                                )
                                Text(
                                    text = remember(item, streaming) { parseInlineAnnotated(item, streaming, onOpenHref) },
                                    color = baseColor,
                                    fontSize = 15.sp,
                                    lineHeight = 22.sp,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                    }
                }
                is OrbMdBlock.Table -> {
                    val hScroll = rememberScrollState()
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color(0xFF171717))
                            .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(10.dp))
                            .horizontalScroll(hScroll)
                    ) {
                        val alignOf = { i: Int -> if (block.rightAligned.getOrElse(i) { false }) TextAlign.End else TextAlign.Start }
                        val showHeader = block.headers.any { it.isNotEmpty() }
                        if (showHeader) Row(
                            modifier = Modifier.background(Color.White.copy(alpha = 0.04f))
                        ) {
                            block.headers.forEachIndexed { hIdx, h ->
                                Text(
                                    text = remember(h, streaming) { parseInlineAnnotated(h, streaming, onOpenHref) },
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    textAlign = alignOf(hIdx),
                                    modifier = Modifier
                                        .widthIn(min = 96.dp, max = 230.dp)
                                        .padding(horizontal = 10.dp, vertical = 7.dp)
                                )
                            }
                        }
                        block.rows.forEachIndexed { rIdx, row ->
                            if (rIdx > 0 || showHeader) HorizontalDivider(
                                color = Color.White.copy(alpha = 0.07f),
                                thickness = 0.5.dp
                            )
                            Row {
                                val count = maxOf(block.headers.size, row.size)
                                for (cIdx in 0 until count) {
                                    val cell = row.getOrNull(cIdx) ?: ""
                                    Text(
                                        text = remember(cell, streaming) { parseInlineAnnotated(cell, streaming, onOpenHref) },
                                        color = Color(0xFFE0E0E0),
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp,
                                        textAlign = alignOf(cIdx),
                                        style = TextStyle(fontFeatureSettings = "tnum"),
                                        modifier = Modifier
                                            .widthIn(min = 96.dp, max = 230.dp)
                                            .padding(horizontal = 10.dp, vertical = 7.dp)
                                    )
                                }
                            }
                        }
                    }
                }
                is OrbMdBlock.MathBlock -> {
                    val mathResult = remember(block.latex, block.complete, streaming) {
                        OrbMath.formatCached(block.latex, complete = block.complete, streaming = streaming)
                    }
                    val hScroll = rememberScrollState()
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color(0xFF151515))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(10.dp))
                            .horizontalScroll(hScroll)
                            .padding(horizontal = 14.dp, vertical = 10.dp)
                    ) {
                        Text(
                            text = mathResult.text,
                            color = if (mathResult.valid) Color(0xFFF3F3F3) else Color(0xFFD6A16A),
                            fontSize = if (mathResult.valid) 15.5.sp else 13.sp,
                            lineHeight = 22.sp,
                            fontFamily = if (mathResult.valid) FontFamily.Serif else FontFamily.Monospace,
                            fontStyle = if (mathResult.valid) FontStyle.Italic else FontStyle.Normal
                        )
                    }
                }
                is OrbMdBlock.ImageBlock -> {
                    OrbMarkdownImageView(alt = block.alt, rawUrl = block.url, files = files, context = context)
                }
                is OrbMdBlock.CodeBlock -> {
                    val hScroll = rememberScrollState()
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                            .background(Color(0xFF161616))
                            .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(10.dp))
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = block.language.ifEmpty { "code" },
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                text = if (copiedBlockIdx == idx) "Copied ✓" else "Copy code",
                                color = if (copiedBlockIdx == idx) OrbStyle.success else OrbStyle.textSecondary,
                                fontSize = 11.5.sp,
                                maxLines = 1,
                                softWrap = false,
                                modifier = Modifier.orbPressClickable {
                                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
                                    cm?.setPrimaryClip(android.content.ClipData.newPlainText("code", block.code))
                                    copiedBlockIdx = idx
                                }
                            )
                        }
                        HorizontalDivider(
                            color = Color.White.copy(alpha = 0.06f),
                            thickness = 0.5.dp
                        )
                        val displayCode = remember(block.code) {
                            if (block.code.length > MAX_DISPLAY_CODE_CHARS) {
                                block.code.take(MAX_DISPLAY_CODE_CHARS) + "\n… [truncated for display, Copy code copies full block]"
                            } else {
                                block.code
                            }
                        }
                        Text(
                            text = displayCode,
                            color = Color(0xFFE5E5E5),
                            fontSize = 12.5.sp,
                            lineHeight = 18.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(hScroll)
                                .padding(horizontal = 13.dp, vertical = 10.dp)
                        )
                    }
                }
                OrbMdBlock.Divider -> {
                    HorizontalDivider(
                        color = Color.White.copy(alpha = 0.1f),
                        thickness = 0.5.dp
                    )
                }
            }
        }
        if (truncated) {
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.06f))
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { showFullSource = true }
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            ) {
                Text(
                    text = "Show full message (${markdown.length / 1024} KB)",
                    color = OrbStyle.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun OrbMarkdownImageView(
    alt: String,
    rawUrl: String,
    files: OrbFileContext?,
    context: Context
) {
    val trimmed = rawUrl.trim()
    if (!OrbMath.isSafeHref(trimmed)) {
        Text(
            text = alt.ifEmpty { "[unsafe image]" },
            color = OrbStyle.textMuted,
            fontSize = 13.sp
        )
        return
    }
    val lower = trimmed.lowercase()
    if (lower.startsWith("https://")) {
        val uri = runCatching { Uri.parse(trimmed) }.getOrNull()
        if (uri == null || !uri.userInfo.isNullOrEmpty()) return
        var bitmap by remember(trimmed) { mutableStateOf<Bitmap?>(null) }
        LaunchedEffect(trimmed) {
            bitmap = withContext(Dispatchers.IO) { decodeBoundedHttpsBitmap(trimmed) }
        }
        val bmp = bitmap
        if (bmp != null) {
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = alt.ifEmpty { "Image" },
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .widthIn(max = 420.dp)
                    .heightIn(max = 320.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
                    .orbPressClickable { openSafeHref(context, files, trimmed) }
            )
        } else {
            val label = alt.ifEmpty { uri.lastPathSegment ?: "Image" }
            OrbFileChip(OrbFileRef(type = "image", path = trimmed, label = label)) {
                openSafeHref(context, files, trimmed)
            }
        }
        return
    }

    if (lower.startsWith("http://")) {
        // Never auto-fetch cleartext remote media; offer an explicit tap chip only.
        val label = alt.ifEmpty { trimmed }
        OrbFileChip(OrbFileRef(type = "image", path = trimmed, label = label)) {
            openSafeHref(context, files, trimmed)
        }
        return
    }

    val cleanPath = when {
        trimmed.startsWith("sandbox:") -> trimmed.removePrefix("sandbox:")
        trimmed.startsWith("file://") -> trimmed.removePrefix("file://")
        else -> trimmed
    }
    val label = alt.ifEmpty { OrbFileRefs.fileName(cleanPath) }
    val rawRef = OrbFileRef(type = "image", path = cleanPath, label = label)
    val enriched = OrbFileRefs.enrich(rawRef, files?.shared ?: emptyList())
    val core = files?.core
    if (!enriched.unavailable && (enriched.kind == OrbFileKind.Image || enriched.kind == OrbFileKind.Svg) && core != null && files != null) {
        OrbInlineImage(core, enriched, files.scope) { files.open(enriched) }
    } else {
        OrbFileChip(enriched) { files?.open?.invoke(enriched) }
    }
}

private fun decodeBoundedHttpsBitmap(httpsUrl: String): Bitmap? = runCatching {
    val conn = (URL(httpsUrl).openConnection() as? HttpURLConnection) ?: return null
    conn.connectTimeout = 8_000
    conn.readTimeout = 12_000
    conn.instanceFollowRedirects = true
    try {
        if (conn.responseCode != 200) return null
        val contentLength = conn.contentLengthLong
        if (contentLength > MAX_REMOTE_IMAGE_BYTES) return null
        val bytes = conn.inputStream.use { stream ->
            val buf = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            var total = 0
            while (true) {
                val n = stream.read(chunk)
                if (n < 0) break
                total += n
                if (total > MAX_REMOTE_IMAGE_BYTES) return null
                buf.write(chunk, 0, n)
            }
            buf.toByteArray()
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > 1600 || bounds.outHeight / sample > 1600) {
            sample *= 2
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    } finally {
        conn.disconnect()
    }
}.getOrNull()

private fun openSafeHref(context: Context, files: OrbFileContext?, rawHref: String) {
    val href = rawHref.trim()
    if (!OrbMath.isSafeHref(href)) return
    if (OrbMath.isArtifactHref(href)) {
        val cleanPath = when {
            href.startsWith("sandbox:") -> href.removePrefix("sandbox:")
            href.startsWith("file://") -> href.removePrefix("file://")
            else -> href
        }
        val ref = OrbFileRefs.enrich(
            OrbFileRef(type = "file", path = cleanPath, label = OrbFileRefs.fileName(cleanPath)),
            files?.shared ?: emptyList()
        )
        files?.open?.invoke(ref)
        return
    }
    val uri = runCatching { Uri.parse(href) }.getOrNull() ?: return
    val scheme = uri.scheme?.lowercase() ?: return
    if (scheme !in setOf("https", "http", "mailto") || !uri.userInfo.isNullOrEmpty()) return
    runCatching {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
    }
}

internal fun parseInlineAnnotated(
    raw: String,
    streaming: Boolean = false,
    onOpenHref: ((String) -> Unit)? = null
): AnnotatedString = buildAnnotatedString {
    appendInlineTokens(OrbMath.tokenizeInline(raw), streaming = streaming, onOpenHref = onOpenHref, depth = 0)
}

private fun AnnotatedString.Builder.appendInlineTokens(
    tokens: List<OrbInlineToken>,
    streaming: Boolean,
    onOpenHref: ((String) -> Unit)?,
    depth: Int
) {
    for (token in tokens) {
        when (token) {
            is OrbInlineToken.Text -> append(token.text)
            is OrbInlineToken.Code -> {
                pushStyle(
                    SpanStyle(
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                        background = Color.White.copy(alpha = 0.08f),
                        color = Color(0xFFF0F0F0)
                    )
                )
                append(token.code)
                pop()
            }
            is OrbInlineToken.Bold -> {
                pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = Color.White))
                if (depth < 4) {
                    appendInlineTokens(OrbMath.tokenizeInline(token.inner, depth + 1), streaming, onOpenHref, depth + 1)
                } else {
                    append(token.inner)
                }
                pop()
            }
            is OrbInlineToken.Italic -> {
                pushStyle(SpanStyle(fontStyle = FontStyle.Italic))
                if (depth < 4) {
                    appendInlineTokens(OrbMath.tokenizeInline(token.inner, depth + 1), streaming, onOpenHref, depth + 1)
                } else {
                    append(token.inner)
                }
                pop()
            }
            is OrbInlineToken.Math -> {
                val result = OrbMath.formatCached(token.latex, complete = token.complete, streaming = streaming)
                if (result.valid) {
                    pushStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Serif,
                            fontStyle = FontStyle.Italic,
                            color = Color(0xFFF5F5F5)
                        )
                    )
                    append(result.text)
                    pop()
                } else {
                    pushStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            fontSize = 13.sp,
                            color = Color(0xFFD6A16A)
                        )
                    )
                    append(result.text)
                    pop()
                }
            }
            is OrbInlineToken.Link -> {
                if (!token.isSafe) {
                    append(token.label)
                } else if (token.isArtifact) {
                    val chipText = token.label.ifEmpty { OrbFileRefs.fileName(token.url) }
                    val linkStyle = TextLinkStyles(
                        style = SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.5.sp,
                            color = Color(0xFFD8E6F5),
                            background = Color.White.copy(alpha = 0.07f)
                        )
                    )
                    pushLink(
                        LinkAnnotation.Clickable(
                            tag = token.url,
                            styles = linkStyle,
                            linkInteractionListener = { onOpenHref?.invoke(token.url) }
                        )
                    )
                    append(chipText)
                    pop()
                } else {
                    val linkStyle = TextLinkStyles(
                        style = SpanStyle(
                            color = Color(0xFFB8D5EF),
                            textDecoration = TextDecoration.Underline
                        )
                    )
                    pushLink(
                        LinkAnnotation.Clickable(
                            tag = token.url,
                            styles = linkStyle,
                            linkInteractionListener = { onOpenHref?.invoke(token.url) }
                        )
                    )
                    if (depth < 4) {
                        appendInlineTokens(OrbMath.tokenizeInline(token.label, depth + 1), streaming, onOpenHref, depth + 1)
                    } else {
                        append(token.label)
                    }
                    pop()
                }
            }
            is OrbInlineToken.Image -> {
                val label = token.alt.ifEmpty { OrbFileRefs.fileName(token.url) }
                if (OrbMath.isSafeHref(token.url)) {
                    pushLink(
                        LinkAnnotation.Clickable(
                            tag = token.url,
                            styles = TextLinkStyles(style = SpanStyle(color = Color(0xFFB8D5EF), textDecoration = TextDecoration.Underline)),
                            linkInteractionListener = { onOpenHref?.invoke(token.url) }
                        )
                    )
                    append("[$label]")
                    pop()
                } else {
                    append(label)
                }
            }
        }
    }
}

private fun isMdTableRow(trimmed: String): Boolean =
    trimmed.startsWith("|") && trimmed.endsWith("|") && trimmed.length > 2

private fun parseMdTableCells(trimmed: String): List<String> {
    val inner = trimmed.substring(1, trimmed.length - 1)
    val cells = mutableListOf<String>()
    val cur = StringBuilder()
    var i = 0
    while (i < inner.length) {
        if (inner[i] == '\\' && i + 1 < inner.length && inner[i + 1] == '|') {
            cur.append('|')
            i += 2
            continue
        }
        if (inner[i] == '|') {
            cells.add(cur.toString().trim())
            cur.setLength(0)
            i++
            continue
        }
        cur.append(inner[i])
        i++
    }
    cells.add(cur.toString().trim())
    return cells
}

private fun isMdTableSeparator(cells: List<String>): Boolean =
    cells.isNotEmpty() && cells.all { cell ->
        val stripped = cell.replace("-", "").replace(":", "").trim()
        stripped.isEmpty() && cell.contains("-")
    }

private fun parseStandaloneImage(trimmed: String): Pair<String, String>? {
    if (!trimmed.startsWith("![") || !trimmed.endsWith(")")) return null
    val closeBracket = trimmed.indexOf("](")
    if (closeBracket < 2) return null
    val alt = trimmed.substring(2, closeBracket)
    val url = trimmed.substring(closeBracket + 2, trimmed.length - 1).trim()
    if (url.isEmpty() || url.contains(')') || url.contains('\n')) return null
    return alt to url
}

private fun isDisplayMathStart(trimmed: String): Boolean =
    trimmed.startsWith("$$") || trimmed.startsWith("\\[")

internal fun parseMdBlocks(source: String): List<OrbMdBlock> {
    val blocks = mutableListOf<OrbMdBlock>()
    val lines = source.split("\n")
    var idx = 0
    while (idx < lines.size) {
        val line = lines[idx]
        val trimmed = line.trim()
        if (trimmed.isEmpty()) {
            idx++
            continue
        }
        if (trimmed.startsWith("```")) {
            val lang = trimmed.drop(3).trim()
            idx++
            val codeLines = mutableListOf<String>()
            while (idx < lines.size && !lines[idx].trim().startsWith("```")) {
                codeLines.add(lines[idx])
                idx++
            }
            if (idx < lines.size) idx++
            blocks.add(OrbMdBlock.CodeBlock(lang, codeLines.joinToString("\n")))
            continue
        }
        if (trimmed == "---" || trimmed == "***") {
            blocks.add(OrbMdBlock.Divider)
            idx++
            continue
        }
        if (trimmed.startsWith("#")) {
            val hashes = trimmed.takeWhile { it == '#' }.length
            if (hashes in 1..4 && trimmed.length > hashes && trimmed[hashes] == ' ') {
                blocks.add(OrbMdBlock.Heading(hashes, trimmed.drop(hashes + 1)))
                idx++
                continue
            }
        }
        if (isDisplayMathStart(trimmed)) {
            val openDelim = if (trimmed.startsWith("$$")) "$$" else "\\["
            val closeDelim = if (openDelim == "$$") "$$" else "\\]"
            val afterOpen = trimmed.drop(openDelim.length)
            val sameLineClose = afterOpen.indexOf(closeDelim)
            if (sameLineClose >= 0) {
                val body = afterOpen.substring(0, sameLineClose)
                val trailing = afterOpen.substring(sameLineClose + closeDelim.length).trim()
                blocks.add(OrbMdBlock.MathBlock(body.trim(), complete = true))
                if (trailing.isNotEmpty()) {
                    blocks.add(OrbMdBlock.Paragraph(trailing))
                }
                idx++
                continue
            }
            val mathLines = mutableListOf<String>()
            if (afterOpen.isNotEmpty()) mathLines.add(afterOpen)
            idx++
            var closed = false
            while (idx < lines.size) {
                val cur = lines[idx]
                val curTrim = cur.trim()
                if (curTrim.isEmpty() || curTrim.startsWith("```")) break
                val closeIdx = curTrim.indexOf(closeDelim)
                if (closeIdx >= 0) {
                    val before = curTrim.substring(0, closeIdx)
                    if (before.isNotEmpty()) mathLines.add(before)
                    closed = true
                    idx++
                    break
                }
                mathLines.add(cur)
                idx++
            }
            blocks.add(OrbMdBlock.MathBlock(mathLines.joinToString("\n").trim(), complete = closed))
            continue
        }
        parseStandaloneImage(trimmed)?.let { (alt, url) ->
            blocks.add(OrbMdBlock.ImageBlock(alt, url))
            idx++
            continue
        }
        if (isMdTableRow(trimmed)) {
            val rawRows = mutableListOf<List<String>>()
            while (idx < lines.size) {
                val t = lines[idx].trim()
                if (!isMdTableRow(t)) break
                rawRows.add(parseMdTableCells(t))
                idx++
            }
            if (rawRows.size >= 2 && isMdTableSeparator(rawRows[1])) {
                blocks.add(OrbMdBlock.Table(rawRows[0], rawRows.drop(2), rawRows[1].map { val c = it.trim(); c.endsWith(":") && !c.startsWith(":") }))
                continue
            } else if (rawRows.isNotEmpty()) {
                blocks.add(OrbMdBlock.Table(rawRows[0], rawRows.drop(1)))
                continue
            }
        }
        if (trimmed.startsWith("> ") || trimmed == ">") {
            val quoteLines = mutableListOf<String>()
            while (idx < lines.size) {
                val t = lines[idx].trim()
                if (t.startsWith("> ")) {
                    quoteLines.add(t.drop(2))
                    idx++
                } else if (t == ">") {
                    quoteLines.add("")
                    idx++
                } else break
            }
            blocks.add(OrbMdBlock.Quote(quoteLines.joinToString("\n")))
            continue
        }
        if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
            val items = mutableListOf<String>()
            while (idx < lines.size) {
                val t = lines[idx].trim()
                if (t.startsWith("- ") || t.startsWith("* ")) {
                    items.add(t.drop(2))
                    idx++
                } else break
            }
            blocks.add(OrbMdBlock.ListBlock(false, items))
            continue
        }
        val dotIdx = trimmed.indexOf(". ")
        if (dotIdx in 1..3 && trimmed.substring(0, dotIdx).all { it.isDigit() }) {
            val items = mutableListOf<String>()
            while (idx < lines.size) {
                val t = lines[idx].trim()
                val d = t.indexOf(". ")
                if (d in 1..3 && t.substring(0, d).all { it.isDigit() }) {
                    items.add(t.substring(d + 2))
                    idx++
                } else break
            }
            blocks.add(OrbMdBlock.ListBlock(true, items))
            continue
        }
        val paraLines = mutableListOf<String>()
        while (idx < lines.size) {
            val l = lines[idx]
            val t = l.trim()
            if (t.isEmpty() ||
                t.startsWith("```") ||
                t.startsWith("#") ||
                t.startsWith("- ") ||
                t.startsWith("* ") ||
                t.startsWith("> ") ||
                isMdTableRow(t) ||
                isDisplayMathStart(t) ||
                parseStandaloneImage(t) != null
            ) {
                break
            }
            paraLines.add(l)
            idx++
        }
        if (paraLines.isNotEmpty()) {
            blocks.add(OrbMdBlock.Paragraph(paraLines.joinToString("\n")))
        } else {
            idx++
        }
    }
    return blocks
}

internal fun inlinePreview(source: String, limit: Int): String {
    if (source.length <= limit) return source
    val prefix = source.substring(0, limit)
    var lastBoundary = -1
    var fenceStart = -1
    var index = 0
    var previousBlank = true
    while (index < prefix.length) {
        val nl = prefix.indexOf('\n', index)
        val lineEnd = if (nl < 0) prefix.length else nl
        val line = prefix.substring(index, lineEnd).trim()
        if (line.startsWith("```") || line.startsWith("~~~")) {
            if (fenceStart < 0) fenceStart = index else {
                fenceStart = -1
                lastBoundary = lineEnd
            }
        } else if (fenceStart < 0 && line.isEmpty() && !previousBlank) {
            lastBoundary = index
        }
        previousBlank = line.isEmpty()
        index = if (lineEnd < prefix.length) lineEnd + 1 else prefix.length
    }
    val cut = when {
        fenceStart >= 0 && lastBoundary >= 0 -> minOf(lastBoundary, fenceStart)
        fenceStart >= 0 -> fenceStart
        else -> lastBoundary
    }
    return if (cut > 0) prefix.substring(0, cut).trim() else prefix
}

internal fun cleanRichText(raw: String, streaming: Boolean = false): String {
    if (streaming) {
        if (!raw.contains("STATE_SIGNATURE:") && !raw.contains(" | ")) {
            return raw.trimStart()
        }
    }
    return cleanText(raw)
}

private fun cleanText(raw: String): String {
    if (!raw.contains("STATE_SIGNATURE:")) {
        return OrbPipeTables.normalize(raw.trim())
    }
    val lines = raw.split("\n").filterNot { line ->
        val t = line.trim()
        t.startsWith("[STATE_SIGNATURE:") || t.startsWith("STATE_SIGNATURE:")
    }
    return OrbPipeTables.normalize(lines.joinToString("\n").trim())
}

internal fun needsWebRenderer(text: String): Boolean = OrbMath.usesWebRenderer(text)
