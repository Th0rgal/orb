package sh.sandboxed.dashboard.orb

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color as AndroidColor
import android.net.Uri
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewAssetLoader
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.ceil

enum class OrbRichTextTone(val cssColor: String) {
    Primary("#FFFFFF"),
    Secondary("#9B9B9B")
}

object OrbRichTextHeightCache {
    private val map = ConcurrentHashMap<String, Float>()

    private fun key(markdown: String, tone: OrbRichTextTone, widthBucket: Int): String =
        "${tone.cssColor}|$widthBucket|${markdown.hashCode()}|${markdown.length}"

    fun height(markdown: String, tone: OrbRichTextTone, widthDp: Float): Float? {
        val bucket = maxOf(120, (widthDp / 8f).toInt() * 8)
        return map[key(markdown, tone, bucket)]
    }

    fun store(heightDp: Float, markdown: String, tone: OrbRichTextTone, widthDp: Float) {
        val bucket = maxOf(120, (widthDp / 8f).toInt() * 8)
        map[key(markdown, tone, bucket)] = heightDp
    }
}

class OrbRichWebViewHolder(context: Context) {
    val webView: WebView
    var isBootstrapped: Boolean = false
    var pendingScript: String? = null
    var lastRenderedSignature: String = ""
    var onHeightChanged: ((Float) -> Unit)? = null

    private val assetLoader = WebViewAssetLoader.Builder()
        .setDomain("appassets.androidplatform.net")
        .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context.applicationContext))
        .build()

    init {
        webView = createWebView(context.applicationContext)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(appContext: Context): WebView {
        return WebView(appContext).apply {
            setBackgroundColor(AndroidColor.TRANSPARENT)
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
            overScrollMode = WebView.OVER_SCROLL_NEVER
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = false
            settings.allowFileAccess = true
            settings.allowContentAccess = false
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            settings.textZoom = 100

            addJavascriptInterface(
                object {
                    @JavascriptInterface
                    fun onHeight(heightCssPx: Double) {
                        if (heightCssPx > 0.0) {
                            post {
                                onHeightChanged?.invoke(ceil(heightCssPx).toFloat())
                            }
                        }
                    }
                },
                "OrbBridge"
            )

            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView?,
                    request: WebResourceRequest?
                ): WebResourceResponse? {
                    val uri = request?.url ?: return null
                    return assetLoader.shouldInterceptRequest(uri)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    isBootstrapped = true
                    pendingScript?.let { script ->
                        pendingScript = null
                        evaluateJavascript(script, null)
                    }
                }

                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?
                ): Boolean {
                    val uri = request?.url ?: return false
                    val scheme = uri.scheme?.lowercase() ?: ""
                    if (scheme == "http" || scheme == "https" || scheme == "mailto") {
                        if (uri.host == "appassets.androidplatform.net") return false
                        runCatching {
                            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            appContext.startActivity(intent)
                        }
                        return true
                    }
                    return false
                }
            }

            loadDataWithBaseURL(
                "https://appassets.androidplatform.net/assets/MathAssets/",
                SHELL_HTML,
                "text/html",
                "utf-8",
                null
            )
        }
    }

    fun render(markdown: String, tone: OrbRichTextTone) {
        val signature = "${tone.cssColor}|$markdown"
        if (signature == lastRenderedSignature && isBootstrapped) {
            webView.evaluateJavascript("window.orbReportHeight && window.orbReportHeight();", null)
            return
        }
        lastRenderedSignature = signature
        val b64 = Base64.encodeToString(markdown.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val escapedTone = tone.cssColor.replace("\\", "\\\\").replace("'", "\\'")
        val js = "window.orbRenderBase64 && window.orbRenderBase64('$b64', '$escapedTone');"
        if (isBootstrapped) {
            webView.evaluateJavascript(js, null)
        } else {
            pendingScript = js
        }
    }

    companion object {
        private val pool = ArrayDeque<OrbRichWebViewHolder>()
        private const val MAX_POOL_SIZE = 18

        fun acquire(context: Context): OrbRichWebViewHolder {
            val holder = synchronized(pool) {
                if (pool.isNotEmpty()) pool.removeLast() else null
            } ?: OrbRichWebViewHolder(context)
            (holder.webView.parent as? android.view.ViewGroup)?.removeView(holder.webView)
            return holder
        }

        fun release(holder: OrbRichWebViewHolder) {
            holder.onHeightChanged = null
            (holder.webView.parent as? android.view.ViewGroup)?.removeView(holder.webView)
            synchronized(pool) {
                if (pool.size < MAX_POOL_SIZE) {
                    pool.addLast(holder)
                } else {
                    holder.webView.destroy()
                }
            }
        }

        private const val SHELL_HTML = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="katex.min.css">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body {
    margin: 0;
    padding: 0;
    background: transparent;
    color: #FFFFFF;
    font: 15px/1.48 -apple-system, BlinkMacSystemFont, "Roboto", "Inter", sans-serif;
    -webkit-text-size-adjust: 100%;
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  #root > :first-child { margin-top: 0 !important; }
  #root > :last-child { margin-bottom: 0 !important; }
  p { margin: 0 0 10px 0; }
  h1, h2, h3, h4, h5, h6 {
    color: #FFFFFF;
    font-weight: 650;
    line-height: 1.26;
    margin: 14px 0 7px 0;
    letter-spacing: -0.01em;
  }
  h1 { font-size: 19px; }
  h2 { font-size: 17px; }
  h3 { font-size: 15.5px; }
  h4, h5, h6 { font-size: 14.5px; color: #D8D8D8; }
  ul, ol {
    margin: 0 0 10px 0;
    padding-left: 20px;
  }
  li { margin: 3px 0; }
  li > p { margin: 0 0 4px 0; }
  a {
    color: #82B4FF;
    text-decoration: none;
  }
  strong { color: #FFFFFF; font-weight: 640; }
  em { font-style: italic; }
  hr {
    border: 0;
    height: 1px;
    background: rgba(255,255,255,0.09);
    margin: 12px 0;
  }
  blockquote {
    margin: 8px 0;
    padding: 4px 0 4px 12px;
    border-left: 2px solid rgba(255,255,255,0.22);
    color: #B4B4B4;
  }
  code {
    font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 12.5px;
    background: rgba(255,255,255,0.075);
    color: #EFEFEF;
    padding: 1.5px 5px;
    border-radius: 5px;
  }
  pre.orb-code {
    margin: 9px 0;
    padding: 11px 12px;
    background: #181818;
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 12px;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }
  pre.orb-code code {
    background: transparent;
    padding: 0;
    border-radius: 0;
    font-size: 12px;
    line-height: 1.45;
    color: #E5E5E5;
    white-space: pre;
    word-break: normal;
    overflow-wrap: normal;
  }
  .orb-table-wrap {
    margin: 9px 0;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    border: 1px solid rgba(255,255,255,0.09);
    border-radius: 10px;
    background: #171717;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  th, td {
    padding: 7px 10px;
    border-bottom: 1px solid rgba(255,255,255,0.07);
    text-align: left;
    vertical-align: top;
  }
  th {
    color: #FFFFFF;
    font-weight: 600;
    background: rgba(255,255,255,0.04);
  }
  tr:last-child td { border-bottom: 0; }
  .katex { font-size: 1.03em; color: #F5F5F5; }
  .katex-display {
    margin: 9px 0;
    padding: 4px 2px;
    overflow-x: auto;
    overflow-y: hidden;
    -webkit-overflow-scrolling: touch;
  }
  .katex-fallback {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 12.5px;
    color: #CFCFCF;
  }
  .math-block {
    overflow-x: auto;
    margin: 10px 0;
  }
  .code-block {
    background: #161616;
    border: 1px solid rgba(255,255,255,0.09);
    border-radius: 10px;
    margin: 10px 0;
    overflow: hidden;
  }
  .code-block pre {
    overflow-x: auto;
    white-space: pre;
    padding: 12px 14px;
    margin: 0;
  }
  .code-block pre code {
    background: none;
    padding: 0;
    font-size: 12.5px;
    line-height: 1.45;
  }
  .copy-code, .artifact {
    color: #a0a0a0;
    background: none;
    border: 0;
    padding: 7px 12px;
    font: inherit;
  }
  .copy-code {
    font-size: 11.5px;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    width: 100%;
    text-align: right;
    display: block;
  }
  .copy-code.copied {
    color: #73c991;
  }
  a.file-link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font: 0.86em ui-monospace, SFMono-Regular, monospace;
    color: #d8e6f5;
    background: rgba(255,255,255,0.07);
    border: 1px solid rgba(255,255,255,0.12);
    padding: 1px 7px;
    border-radius: 6px;
    text-decoration: none;
  }
</style>
</head>
<body>
<div id="root"></div>
<script src="markdown-it.min.js"></script>
<script src="katex.min.js"></script>
<script src="orb-renderer.js"></script>
<script>
  window.orbReportHeight = function() {
    var root = document.getElementById('root');
    if (!root) return;
    var rect = root.getBoundingClientRect();
    var h = Math.ceil(Math.max(rect.height, root.scrollHeight, 18));
    if (window.OrbBridge && window.OrbBridge.onHeight) {
      window.OrbBridge.onHeight(h + 2);
    }
  };
  window.orbRenderBase64 = function(b64, color) {
    var root = document.getElementById('root');
    if (!root) return;
    try {
      var bytes = Uint8Array.from(atob(b64), function(c) { return c.charCodeAt(0); });
      var text = new TextDecoder('utf-8').decode(bytes);
      document.body.style.color = color || '#e3e3e3';
      root.innerHTML = window.orbRender ? window.orbRender(text) : text;
      window.orbReportHeight();
      requestAnimationFrame(window.orbReportHeight);
      setTimeout(window.orbReportHeight, 40);
      setTimeout(window.orbReportHeight, 180);
      setTimeout(window.orbReportHeight, 500);
    } catch (e) {
      root.textContent = e.toString();
      window.orbReportHeight();
    }
  };
  if (typeof ResizeObserver !== 'undefined') {
    var ro = new ResizeObserver(function() { window.orbReportHeight(); });
    ro.observe(document.getElementById('root'));
  }
</script>
</body>
</html>"""
    }
}

@Composable
fun OrbRichText(
    markdown: String,
    tone: OrbRichTextTone = OrbRichTextTone.Primary,
    modifier: Modifier = Modifier
) {
    val cleaned = remember(markdown) { cleanText(markdown) }
    if (!needsWebRenderer(cleaned)) {
        OrbNativeMarkdown(
            markdown = cleaned,
            tone = tone,
            modifier = modifier.fillMaxWidth()
        )
        return
    }

    val context = LocalContext.current
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val widthDp = maxWidth.value.takeIf { it > 0f } ?: 320f
        var heightDp by remember(cleaned, tone) {
            mutableFloatStateOf(
                OrbRichTextHeightCache.height(cleaned, tone, widthDp)
                    ?: estimatedHeight(cleaned)
            )
        }
        val holder = remember { OrbRichWebViewHolder.acquire(context) }

        DisposableEffect(holder) {
            onDispose {
                OrbRichWebViewHolder.release(holder)
            }
        }

        holder.onHeightChanged = { reported ->
            val next = maxOf(18f, reported)
            OrbRichTextHeightCache.store(next, cleaned, tone, widthDp)
            if (abs(heightDp - next) > 0.5f) {
                heightDp = next
            }
        }

        AndroidView(
            factory = {
                holder.render(cleaned, tone)
                holder.webView
            },
            update = {
                holder.render(cleaned, tone)
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(heightDp.dp)
        )
    }
}

private sealed class OrbMdBlock {
    data class Heading(val level: Int, val text: String) : OrbMdBlock()
    data class Paragraph(val text: String) : OrbMdBlock()
    data class CodeBlock(val language: String, val code: String) : OrbMdBlock()
    data class ListBlock(val ordered: Boolean, val items: List<String>) : OrbMdBlock()
    data class Quote(val text: String) : OrbMdBlock()
    data class Table(val headers: List<String>, val rows: List<List<String>>) : OrbMdBlock()
    data object Divider : OrbMdBlock()
}

@Composable
private fun OrbNativeMarkdown(
    markdown: String,
    tone: OrbRichTextTone,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val blocks = remember(markdown) { parseMdBlocks(markdown) }
    val baseColor = if (tone == OrbRichTextTone.Primary) Color(0xFFE5E5E5) else OrbStyle.textSecondary
    var copiedBlockIdx by remember { androidx.compose.runtime.mutableIntStateOf(-1) }

    androidx.compose.foundation.layout.Column(
        modifier = modifier,
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(9.dp)
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
                        text = remember(block.text) { parseInlineAnnotated(block.text) },
                        color = Color.White,
                        fontSize = fontSize,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        lineHeight = (fontSize.value * 1.3f).sp,
                        modifier = Modifier.padding(top = if (idx == 0) 0.dp else 3.dp)
                    )
                }
                is OrbMdBlock.Paragraph -> {
                    Text(
                        text = remember(block.text) { parseInlineAnnotated(block.text) },
                        color = baseColor,
                        fontSize = 15.sp,
                        lineHeight = 22.sp
                    )
                }
                is OrbMdBlock.Quote -> {
                    androidx.compose.foundation.layout.Row(
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        androidx.compose.foundation.layout.Box(
                            modifier = Modifier
                                .width(2.dp)
                                .heightIn(min = 20.dp)
                                .background(Color.White.copy(alpha = 0.22f))
                        )
                        androidx.compose.foundation.layout.Spacer(modifier = Modifier.width(10.dp))
                        Text(
                            text = remember(block.text) { parseInlineAnnotated(block.text) },
                            color = OrbStyle.textSecondary,
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                    }
                }
                is OrbMdBlock.ListBlock -> {
                    androidx.compose.foundation.layout.Column(
                        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(5.dp)
                    ) {
                        block.items.forEachIndexed { itemIdx, item ->
                            androidx.compose.foundation.layout.Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = if (block.ordered) "${itemIdx + 1}." else "•",
                                    color = OrbStyle.textSecondary,
                                    fontSize = 14.sp,
                                    lineHeight = 21.sp
                                )
                                Text(
                                    text = remember(item) { parseInlineAnnotated(item) },
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
                    val hScroll = androidx.compose.foundation.rememberScrollState()
                    androidx.compose.foundation.layout.Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip( androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                            .background(Color(0xFF171717))
                            .border(1.dp, Color.White.copy(alpha = 0.09f), androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                            .horizontalScroll(hScroll)
                    ) {
                        androidx.compose.foundation.layout.Row(
                            modifier = Modifier.background(Color.White.copy(alpha = 0.04f))
                        ) {
                            block.headers.forEach { h ->
                                Text(
                                    text = remember(h) { parseInlineAnnotated(h) },
                                    color = Color.White,
                                    fontSize = 13.sp,
                                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                                    modifier = Modifier
                                        .widthIn(min = 96.dp, max = 230.dp)
                                        .padding(horizontal = 10.dp, vertical = 7.dp)
                                )
                            }
                        }
                        block.rows.forEach { row ->
                            androidx.compose.material3.HorizontalDivider(
                                color = Color.White.copy(alpha = 0.07f),
                                thickness = 0.5.dp
                            )
                            androidx.compose.foundation.layout.Row {
                                val count = maxOf(block.headers.size, row.size)
                                for (cIdx in 0 until count) {
                                    val cell = row.getOrNull(cIdx) ?: ""
                                    Text(
                                        text = remember(cell) { parseInlineAnnotated(cell) },
                                        color = Color(0xFFE0E0E0),
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp,
                                        modifier = Modifier
                                            .widthIn(min = 96.dp, max = 230.dp)
                                            .padding(horizontal = 10.dp, vertical = 7.dp)
                                    )
                                }
                            }
                        }
                    }
                }
                is OrbMdBlock.CodeBlock -> {
                    val hScroll = androidx.compose.foundation.rememberScrollState()
                    androidx.compose.foundation.layout.Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                            .background(Color(0xFF161616))
                            .border(1.dp, Color.White.copy(alpha = 0.09f), androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                    ) {
                        androidx.compose.foundation.layout.Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                        ) {
                            Text(
                                text = block.language.ifEmpty { "code" },
                                color = OrbStyle.textMuted,
                                fontSize = 11.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
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
                        androidx.compose.material3.HorizontalDivider(
                            color = Color.White.copy(alpha = 0.06f),
                            thickness = 0.5.dp
                        )
                        Text(
                            text = block.code,
                            color = Color(0xFFE5E5E5),
                            fontSize = 12.5.sp,
                            lineHeight = 18.sp,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(hScroll)
                                .padding(horizontal = 13.dp, vertical = 10.dp)
                        )
                    }
                }
                OrbMdBlock.Divider -> {
                    androidx.compose.material3.HorizontalDivider(
                        color = Color.White.copy(alpha = 0.1f),
                        thickness = 0.5.dp
                    )
                }
            }
        }
    }
}

private fun parseInlineAnnotated(raw: String): androidx.compose.ui.text.AnnotatedString {
    return androidx.compose.ui.text.buildAnnotatedString {
        var i = 0
        val n = raw.length
        while (i < n) {
            if (raw[i] == '`') {
                val end = raw.indexOf('`', i + 1)
                if (end > i) {
                    pushStyle(
                        androidx.compose.ui.text.SpanStyle(
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            fontSize = 13.sp,
                            background = Color.White.copy(alpha = 0.08f),
                            color = Color(0xFFF0F0F0)
                        )
                    )
                    append(raw.substring(i + 1, end))
                    pop()
                    i = end + 1
                    continue
                }
            }
            if (i + 1 < n && raw[i] == '*' && raw[i + 1] == '*') {
                val end = raw.indexOf("**", i + 2)
                if (end > i) {
                    pushStyle(
                        androidx.compose.ui.text.SpanStyle(
                            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                            color = Color.White
                        )
                    )
                    append(parseInlineAnnotated(raw.substring(i + 2, end)))
                    pop()
                    i = end + 2
                    continue
                }
            }
            if (raw[i] == '[') {
                val closeBracket = raw.indexOf(']', i + 1)
                if (closeBracket > i && closeBracket + 1 < n && raw[closeBracket + 1] == '(') {
                    val closeParen = raw.indexOf(')', closeBracket + 2)
                    if (closeParen > closeBracket) {
                        val label = raw.substring(i + 1, closeBracket)
                        pushStyle(
                            androidx.compose.ui.text.SpanStyle(
                                color = Color(0xFFB8D5EF)
                            )
                        )
                        append(parseInlineAnnotated(label))
                        pop()
                        i = closeParen + 1
                        continue
                    }
                }
            }
            append(raw[i])
            i++
        }
    }
}

private fun isMdTableRow(trimmed: String): Boolean =
    trimmed.startsWith("|") && trimmed.endsWith("|") && trimmed.length > 2

private fun parseMdTableCells(trimmed: String): List<String> =
    trimmed.substring(1, trimmed.length - 1).split("|").map { it.trim() }

private fun isMdTableSeparator(cells: List<String>): Boolean =
    cells.isNotEmpty() && cells.all { cell ->
        val stripped = cell.replace("-", "").replace(":", "").trim()
        stripped.isEmpty() && cell.contains("-")
    }

private fun parseMdBlocks(source: String): List<OrbMdBlock> {
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
        if (isMdTableRow(trimmed)) {
            val rawRows = mutableListOf<List<String>>()
            while (idx < lines.size) {
                val t = lines[idx].trim()
                if (!isMdTableRow(t)) break
                rawRows.add(parseMdTableCells(t))
                idx++
            }
            if (rawRows.size >= 2 && isMdTableSeparator(rawRows[1])) {
                blocks.add(OrbMdBlock.Table(rawRows[0], rawRows.drop(2)))
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
            if (t.isEmpty() || t.startsWith("```") || t.startsWith("#") || t.startsWith("- ") || t.startsWith("* ") || t.startsWith("> ") || isMdTableRow(t)) {
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

private fun cleanText(raw: String): String {
    val lines = raw.split("\n").filterNot { line ->
        val t = line.trim()
        t.startsWith("[STATE_SIGNATURE:") || t.startsWith("STATE_SIGNATURE:")
    }
    return lines.joinToString("\n").trim()
}

private fun needsWebRenderer(text: String): Boolean {
    return containsLatexOrEmbeddedMediaOutsideCode(text)
}

private fun containsLatexOrEmbeddedMediaOutsideCode(source: String): Boolean {
    if (!source.contains("$") && !source.contains("\\(") && !source.contains("\\[") && !source.contains("![") && !source.contains("<img")) {
        return false
    }
    var inFence = false
    for (rawLine in source.split("\n")) {
        val trimmed = rawLine.trim()
        if (trimmed.startsWith("```")) {
            inFence = !inFence
            continue
        }
        if (inFence) continue
        val sb = StringBuilder()
        var inTick = false
        for (ch in rawLine) {
            if (ch == '`') {
                inTick = !inTick
                continue
            }
            if (!inTick) sb.append(ch)
        }
        val stripped = sb.toString()
        if (stripped.contains("$$") || stripped.contains("\\(") || stripped.contains("\\[")) return true
        if (stripped.contains("![") || stripped.contains("<img ")) return true
        val parts = stripped.split("$")
        if (parts.size < 3) continue
        var idx = 1
        while (idx < parts.size - 1) {
            val candidate = parts[idx]
            if (candidate.isNotEmpty() &&
                candidate.length <= 120 &&
                !candidate.first().isWhitespace() &&
                !candidate.last().isWhitespace() &&
                (candidate.contains("\\") || candidate.contains("^") || candidate.contains("_") || candidate.contains("{") || candidate.contains("}"))
            ) {
                return true
            }
            idx += 2
        }
    }
    return false
}

private fun estimatedHeight(markdown: String): Float {
    val lines = maxOf(1, markdown.split("\n").size)
    val chars = maxOf(1, markdown.length)
    val wrappedLines = ceil(chars / 46.0).toFloat()
    val effectiveLines = maxOf(lines.toFloat(), wrappedLines)
    return minOf(900f, maxOf(22f, effectiveLines * 21f))
}
