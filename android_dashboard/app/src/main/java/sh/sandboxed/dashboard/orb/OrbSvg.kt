package sh.sandboxed.dashboard.orb

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Agent-written SVGs (iOS `OrbSvg`, spec in shared/orb-spec/svg-images.json).
 * SVG can carry scripts and external references, so it is only ever drawn as an
 * `<img>` inside a page that allows no script, no network and no navigation:
 * image context never runs SVG script or fetches what it references, the page CSP
 * forbids every load except the inline image, JavaScript and file access are off,
 * network loads are blocked, and the web view refuses every navigation and request.
 */
object OrbSvg {
    const val limit = 5 * 1024 * 1024

    private val comment = Regex("""<!--[\s\S]*?-->""")
    private val root = Regex("""<svg\b[^>]*>""", RegexOption.IGNORE_CASE)
    private val attribute = Regex("""(?:^|\s)(width|height|viewBox)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
    private val length = Regex("""^\s*([0-9]*\.?[0-9]+)\s*(?:px)?\s*$""")

    /** Width over height from the root element, to size the frame before it draws. */
    fun aspectRatio(svg: String): Double? {
        val tag = root.find(comment.replace(svg, ""))?.value ?: return null
        val values = attribute.findAll(tag).associate { m -> m.groupValues[1] to (m.groups[2]?.value ?: m.groups[3]?.value ?: "") }
        fun number(s: String?) = s?.let { length.find(it)?.groupValues?.get(1)?.toDoubleOrNull() }
        val w = number(values["width"]); val h = number(values["height"])
        if (w != null && h != null && w > 0 && h > 0) return w / h
        val box = (values["viewBox"] ?: "").split(Regex("[\\s,]+")).filter { it.isNotEmpty() }.mapNotNull { it.toDoubleOrNull() }
        if (box.size == 4 && box[2] > 0 && box[3] > 0) return box[2] / box[3]
        return null
    }

    /** The page that shows the SVG: an inline `<img>`, nothing else can load. */
    fun html(svg: ByteArray): String =
        "<!doctype html><html><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">" +
            "<style>html,body{margin:0;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style>" +
            "</head><body><img alt=\"\" src=\"data:image/svg+xml;base64,${java.util.Base64.getEncoder().encodeToString(svg)}\"></body></html>"

    /** The SVG in [file], or null when it is too large or is not UTF-8 text. */
    fun read(file: File): ByteArray? {
        if (!file.isFile || file.length() > limit) return null
        val bytes = runCatching { file.readBytes() }.getOrNull() ?: return null
        if (bytes.size > limit) return null
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        return if (runCatching { decoder.decode(ByteBuffer.wrap(bytes)) }.isSuccess) bytes else null
    }

    /** A web view that can show [html] and nothing else. */
    fun webView(context: android.content.Context, svg: ByteArray, interactive: Boolean): WebView = WebView(context).apply {
        settings.javaScriptEnabled = false
        settings.blockNetworkLoads = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.setSupportMultipleWindows(false)
        settings.builtInZoomControls = interactive
        settings.displayZoomControls = false
        isClickable = interactive
        isFocusable = interactive
        isLongClickable = false
        isVerticalScrollBarEnabled = interactive
        isHorizontalScrollBarEnabled = interactive
        setBackgroundColor(0)
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                if (request.url.scheme == "data") null else WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), null)
        }
        loadDataWithBaseURL(null, html(svg), "text/html", "utf-8", null)
    }
}
