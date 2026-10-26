package sh.sandboxed.dashboard.orb

import java.net.URI
import java.net.URLDecoder

// Shared files: one parser for the transcript and the Files tab.
//
// Agents share files with rich tags (desktop `orb/src/richTags.ts`, iOS `OrbFileRefs.swift`):
//   `<file path="./r.pdf" name="Report" />`, `<file path="r.pdf">Report</file>`,
//   `<image path="./chart.png" alt="Chart" />`.
// Core may also attach `metadata.shared_files` (name, size_bytes, an authenticated
// `/api/fs/download` url) to the assistant message.
// Spec and real prod samples: shared/orb-spec/file-references.json.

enum class OrbFileKind(val key: String) {
    Image("image"), Svg("svg"), Pdf("pdf"), Markdown("markdown"), Csv("csv"), Json("json"), Code("code"), Text("text"), Other("other");

    val isTextual: Boolean get() = this in setOf(Markdown, Csv, Json, Code, Text)

    companion object {
        val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp")
        val codeExtensions = setOf(
            "py", "swift", "kt", "kts", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rs", "go", "java", "c", "h", "cc", "cpp", "hpp",
            "m", "mm", "rb", "php", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
            "sql", "lean", "tex", "patch", "diff", "ini", "cfg", "conf", "gradle", "lua", "r", "scala", "cs", "hs", "ex", "exs",
            "nix", "proto", "graphql", "vue", "svelte", "sol", "move", "cairo", "zig", "dart", "ml", "jsonl", "ndjson", "env"
        )
        val textExtensions = setOf("txt", "log", "text", "out", "err", "rst")

        fun of(name: String, mime: String? = null): OrbFileKind {
            val ext = OrbFileRefs.fileExtension(name)
            if (ext in imageExtensions) return Image
            when (ext) {
                "svg" -> return Svg
                "pdf" -> return Pdf
                "md", "markdown", "mdx" -> return Markdown
                "csv", "tsv" -> return Csv
                "json", "geojson", "ipynb" -> return Json
            }
            if (ext in codeExtensions) return Code
            if (ext in textExtensions) return Text
            val m = mime?.lowercase() ?: return Other
            return when {
                m == "application/pdf" -> Pdf
                m == "image/svg+xml" -> Svg
                m.startsWith("image/") -> Image
                m == "application/json" -> Json
                m == "text/markdown" -> Markdown
                m == "text/csv" -> Csv
                m.startsWith("text/") -> Text
                else -> Other
            }
        }
    }
}

/** A file an agent shared: from a tag, from `metadata.shared_files`, or both. */
data class OrbFileRef(
    /** "image" or "file" (the tag that shared it). */
    val type: String,
    val path: String,
    val label: String,
    val mime: String? = null,
    val size: Long? = null,
    /** Authenticated same-origin download URL from `metadata.shared_files`. */
    val url: String? = null,
    /** When it was shared (event timestamp), for the Files tab. */
    val sharedAt: String? = null,
    /** Core could not copy the file (`unavailable="true"`): shown, never fetched. */
    val unavailable: Boolean = false
) {
    val id: String get() = OrbFileRefs.normalize(path)
    val name: String get() = OrbFileRefs.fileName(path)
    val kind: OrbFileKind
        get() = OrbFileKind.of(name, mime).let { if (it == OrbFileKind.Other) OrbFileKind.of(label, mime) else it }
}

/** `metadata.shared_files[]` of an assistant message. */
data class OrbSharedFile(val name: String, val size: Long?, val url: String, val contentType: String?) {
    /** The absolute workspace path Core published, from the url's `path` query. */
    val sourcePath: String? get() = OrbFileRefs.queryParam(url, "path")

    companion object {
        fun from(raw: OrbDict): OrbSharedFile? {
            val url = (raw["url"] as? String)?.takeIf { it.isNotEmpty() } ?: return null
            val name = (raw["name"] as? String)?.takeIf { it.isNotEmpty() }
                ?: (raw["path"] as? String)?.let(OrbFileRefs::fileName)
                ?: OrbFileRefs.queryParam(url, "path")?.let(OrbFileRefs::fileName) ?: "artifact"
            val size = (raw["size_bytes"] as? Number ?: raw["size"] as? Number)?.toLong()
            return OrbSharedFile(name, size, url, raw["content_type"] as? String)
        }
    }
}

sealed class OrbFileSegment {
    data class Text(val text: String) : OrbFileSegment()
    data class File(val ref: OrbFileRef) : OrbFileSegment()
}

object OrbFileRefs {
    /** Same expression as desktop `RICH_TAG`. */
    private val tag = Regex("""<(image|file)\s+([^>]*?)(?:/\s*>|>([^<]*?)</\1\s*>)""", RegexOption.IGNORE_CASE)
    private val attribute = Regex("""(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
    private val incompleteTail = Regex("""<(?:image|file)(?:\s[^>]*)?$""", RegexOption.IGNORE_CASE)
    private val whitespace = Regex("""\s+""")

    fun normalize(path: String): String {
        var p = path.trim()
        while (p.startsWith("./")) p = p.substring(2)
        return p
    }

    fun fileName(path: String): String = path.trimEnd('/').substringAfterLast('/').ifEmpty { path }

    fun fileExtension(name: String): String {
        val base = fileName(name)
        val dot = base.lastIndexOf('.')
        return if (dot <= 0) "" else base.substring(dot + 1).lowercase()
    }

    fun queryParam(url: String, key: String): String? = runCatching {
        URI(url).rawQuery?.split('&')?.firstNotNullOfOrNull { pair ->
            val parts = pair.split('=', limit = 2)
            if (parts[0] == key && parts.size == 2) URLDecoder.decode(parts[1], "UTF-8") else null
        }
    }.getOrNull()

    private fun collapse(s: String) = s.trim().replace(whitespace, " ")

    /** Parses one tag's attributes the way desktop `parseRichTag` does. */
    fun parseTag(
        type: String,
        attributes: String,
        inner: String?,
        tagOff: Int = 0,
        tagLen: Int = attributes.length,
        attrOff: Int = 0,
        bufLen: Int = attributes.length
    ): OrbFileRef? {
        val values = attribute.findAll(attributes).associate { m ->
            m.groupValues[1].lowercase() to (m.groups[2]?.value ?: m.groups[3]?.value ?: "")
        }
        val path = values["path"]?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val kind = type.lowercase()
        val tagKind = if (kind == "image") 2 else 1
        if (!OrbKernel.richTagAdmitted(tagOff, tagLen, attrOff, attributes.length, bufLen, tagKind)) return null
        fun present(v: String?) = v?.let(::collapse)?.takeIf { it.isNotEmpty() }
        val label = present(if (kind == "image") values["alt"] else values["name"]) ?: present(inner) ?: fileName(path)
        return OrbFileRef(type = kind, path = path, label = label, mime = values["type"]?.takeIf { '/' in it },
            unavailable = values["unavailable"] == "true")
    }

    /**
     * Hermes's attachment directive alone on a line (`MEDIA:/tmp/plot.png`, `**MEDIA:/tmp/r.pdf**`,
     * `MEDIA: "/tmp/a b.csv"`). Same expression as desktop `mediaLineTag`. Core rewrites these at
     * ingestion; this fallback covers messages stored before it did.
     */
    private val mediaLine = Regex("""^[ \t]*[*_]{0,3}MEDIA:[ \t]*(?:"([^"<>\n]+)"|'([^'"<>\n]+)'|((?:~/|/)[^\s"'<>`]+?))[*_]{0,3}[.,;:]?[ \t\r]*$""")
    val mediaImageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "bmp")

    /** One `MEDIA:` line as the equivalent rich tag, or null. */
    fun mediaLineTag(line: String): String? {
        val m = mediaLine.find(line) ?: return null
        val path = (m.groups[1] ?: m.groups[2] ?: m.groups[3])?.value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val name = fileName(path)
        return if (fileExtension(name) in mediaImageExtensions) "<image path=\"$path\" alt=\"$name\" />" else "<file path=\"$path\" name=\"$name\" />"
    }

    /** `MEDIA:` lines outside fenced code rewritten as rich tags. While streaming, the unfinished last line is left alone. */
    fun expandMedia(text: String, streaming: Boolean = false): String {
        if (!text.contains("MEDIA:")) return text
        val lines = text.split("\n").toMutableList()
        var fence: String? = null
        for (i in lines.indices) {
            val trimmed = lines[i].trimStart(' ', '\t')
            val marker = fence
            if (marker != null) { if (trimmed.startsWith(marker)) fence = null; continue }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) { fence = trimmed.take(3); continue }
            if (streaming && i == lines.lastIndex) continue
            mediaLineTag(lines[i])?.let { lines[i] = it }
        }
        return lines.joinToString("\n")
    }

    /** Ranges of fenced code blocks: tags written there are documentation. */
    private fun fencedRanges(text: String): List<IntRange> {
        val out = mutableListOf<IntRange>()
        var open: Int? = null
        var marker = ""
        var index = 0
        while (index < text.length) {
            val end = text.indexOf('\n', index).let { if (it < 0) text.length else it + 1 }
            val trimmed = text.substring(index, end).trim()
            val start = open
            if (start != null) {
                if (trimmed.startsWith(marker)) { out.add(start until end); open = null }
            } else if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                open = index; marker = trimmed.take(3)
            }
            index = end
        }
        open?.let { out.add(it until text.length) }
        return out
    }

    /** Message text split into prose and file tags, in order. Prose keeps its Markdown. */
    fun segments(text: String, streaming: Boolean = false): List<OrbFileSegment> {
        val expanded = expandMedia(text, streaming)
        val source = if (streaming) incompleteTail.find(expanded)?.let { expanded.substring(0, it.range.first).trimEnd('\n', '\r') } ?: expanded else expanded
        if (!source.contains("<image", ignoreCase = true) && !source.contains("<file", ignoreCase = true)) {
            return if (source.isEmpty()) emptyList() else listOf(OrbFileSegment.Text(source))
        }
        val fences = fencedRanges(source)
        val out = mutableListOf<OrbFileSegment>()
        var last = 0
        fun flush(upTo: Int) {
            if (upTo <= last) return
            val chunk = source.substring(last, upTo).trim('\n', '\r')
            if (chunk.isNotBlank()) out.add(OrbFileSegment.Text(chunk))
        }
        for (m in tag.findAll(source)) {
            if (fences.any { m.range.first in it }) continue
            val attrs = m.groups[2]!!
            val ref = parseTag(
                m.groupValues[1], attrs.value, m.groups[3]?.value,
                tagOff = m.range.first, tagLen = m.value.length, attrOff = attrs.range.first, bufLen = source.length
            ) ?: continue
            flush(m.range.first)
            out.add(OrbFileSegment.File(ref))
            last = m.range.last + 1
        }
        flush(source.length)
        return out
    }

    fun refs(text: String): List<OrbFileRef> = segments(text).mapNotNull { (it as? OrbFileSegment.File)?.ref }

    /** Prose without tags, whitespace-collapsed (tests and previews). */
    fun plainText(text: String): String =
        collapse(segments(text).mapNotNull { (it as? OrbFileSegment.Text)?.text }.joinToString(" "))

    /** The `shared_files` entry published for this tag, by file name or path suffix. */
    fun match(ref: OrbFileRef, shared: List<OrbSharedFile>): OrbSharedFile? {
        val rel = normalize(ref.path)
        return shared.firstOrNull { file ->
            val source = file.sourcePath
            (source != null && (source == ref.path || source.endsWith("/$rel"))) || file.name == ref.name
        }
    }

    fun enrich(ref: OrbFileRef, shared: List<OrbSharedFile>): OrbFileRef {
        val file = match(ref, shared) ?: return ref
        return ref.copy(
            size = ref.size ?: file.size,
            url = ref.url ?: file.url,
            mime = ref.mime ?: file.contentType?.takeIf { it != "application/octet-stream" }
        )
    }

    data class Message(val content: String, val shared: List<OrbSharedFile>, val at: String, val sequence: Long)

    fun sharedFiles(metadata: Any?): List<OrbSharedFile> =
        OrbJSON.dictList(OrbJSON.dict(metadata)?.get("shared_files")).mapNotNull(OrbSharedFile::from)

    /** Assistant messages of a `/events` reply (a bare array or `{events: […]}`). */
    fun messages(events: Any?): List<Message> {
        val rows = OrbJSON.dictList(events).ifEmpty { OrbJSON.dictList(OrbJSON.dict(events)?.get("events")) }
        return rows.mapIndexedNotNull { index, row ->
            if (row["event_type"] != "assistant_message") return@mapIndexedNotNull null
            Message(
                content = row["content"] as? String ?: "",
                shared = sharedFiles(row["metadata"]),
                at = row["timestamp"] as? String ?: "",
                sequence = (row["sequence"] as? Number)?.toLong() ?: index.toLong()
            )
        }
    }

    /** Every file shared in a conversation, newest first, one row per path. */
    fun collect(messages: List<Message>): List<OrbFileRef> {
        val seen = mutableSetOf<String>()
        val out = mutableListOf<OrbFileRef>()
        for (message in messages.sortedByDescending { it.sequence }) {
            val rows = refs(message.content).map { enrich(it, message.shared) }.toMutableList()
            for (file in message.shared) {
                if (rows.none { match(it, listOf(file)) != null }) {
                    rows.add(OrbFileRef(
                        type = if (OrbFileKind.of(file.name) == OrbFileKind.Image) "image" else "file",
                        path = file.sourcePath ?: file.name, label = file.name, mime = file.contentType, size = file.size, url = file.url
                    ))
                }
            }
            for (row in rows) if (!row.unavailable && seen.add(row.id)) out.add(row.copy(sharedAt = message.at))
        }
        return out
    }

    fun formatSize(bytes: Long?): String? {
        if (bytes == null || bytes < 0) return null
        if (bytes < 1000) return "$bytes bytes"
        val units = listOf("KB", "MB", "GB", "TB")
        var value = bytes / 1000.0
        var unit = 0
        while (value >= 1000 && unit < units.lastIndex) { value /= 1000; unit++ }
        return if (value >= 100) "${value.toLong()} ${units[unit]}" else "%.1f %s".format(java.util.Locale.US, value, units[unit])
    }

    fun validLineSpan(startLine: Int, endLine: Int, totalLines: Int = 0): Pair<Boolean, Int> =
        OrbKernel.fileRefLineSpan(startLine, endLine, totalLines)
}

/** Code highlighting (pure; the views map tokens to colours). */
object OrbCodeHighlight {
    enum class Token { Keyword, Str, Comment, Number, Added, Removed }

    private val keywords = listOf(
        "if", "else", "elif", "for", "while", "do", "return", "func", "fn", "fun", "def", "let", "var", "val", "const", "class", "struct",
        "enum", "interface", "protocol", "extension", "impl", "trait", "type", "import", "from", "package", "use", "pub", "mod",
        "match", "case", "switch", "when", "default", "break", "continue", "true", "false", "nil", "null", "None", "True", "False",
        "self", "this", "async", "await", "try", "catch", "throw", "throws", "guard", "in", "is", "as", "not", "and", "or", "new",
        "static", "private", "public", "protected", "mut", "where", "yield", "lambda", "with", "then", "end", "fi", "esac", "echo",
        "export", "object", "theorem", "lemma", "by", "have", "show", "select", "insert", "update", "delete", "create", "table",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON", "AND", "OR", "NOT", "NULL"
    )
    private val hashComment = setOf("py", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "rb", "r", "nix", "conf", "cfg", "ini", "env", "ex", "exs", "gradle")
    private val dashComment = setOf("sql", "lean", "hs", "lua")

    private fun expression(language: String): Regex {
        val comment = when {
            language in hashComment -> """#[^\n]*"""
            language in dashComment -> """--[^\n]*|/-[\s\S]*?-/"""
            language == "json" -> """(?!)"""
            language in setOf("html", "htm", "xml", "svg", "vue", "svelte") -> """<!--[\s\S]*?-->"""
            else -> """//[^\n]*|/\*[\s\S]*?\*/"""
        }
        val strings = """"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"""
        val words = if (language == "json") "true|false|null" else keywords.joinToString("|")
        return Regex("($comment)|($strings)|(\\b\\d+(?:\\.\\d+)?\\b)|(\\b(?:$words)\\b)")
    }

    /** Highlighted ranges of `code`. Large inputs are left plain. */
    fun tokens(code: String, language: String): List<Pair<IntRange, Token>> {
        if (code.length > 200_000) return emptyList()
        if (language == "diff" || language == "patch") {
            val out = mutableListOf<Pair<IntRange, Token>>()
            var index = 0
            while (index < code.length) {
                val end = code.indexOf('\n', index).let { if (it < 0) code.length else it + 1 }
                val line = code.substring(index, end)
                when {
                    line.startsWith("+") && !line.startsWith("+++") -> out.add((index until end) to Token.Added)
                    line.startsWith("-") && !line.startsWith("---") -> out.add((index until end) to Token.Removed)
                    line.startsWith("@@") -> out.add((index until end) to Token.Keyword)
                }
                index = end
            }
            return out
        }
        return expression(language).findAll(code).mapNotNull { m ->
            val token = when {
                m.groups[1] != null -> Token.Comment
                m.groups[2] != null -> Token.Str
                m.groups[3] != null -> Token.Number
                m.groups[4] != null -> Token.Keyword
                else -> null
            }
            token?.let { m.range to it }
        }.toList()
    }
}

object OrbCSV {
    /** RFC 4180 rows (quoted fields, doubled quotes, newlines in quotes). [limit] caps the rows read. */
    fun parse(text: String, delimiter: Char = ',', limit: Int = 1000): List<List<String>> {
        val rows = mutableListOf<List<String>>()
        var row = mutableListOf<String>()
        val field = StringBuilder()
        var quoted = false
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < text.length && text[i + 1] == '"') { field.append('"'); i++ } else quoted = false
                } else field.append(c)
            } else when {
                c == '"' && field.isEmpty() -> quoted = true
                c == delimiter -> { row.add(field.toString()); field.clear() }
                c == '\r' || c == '\n' -> {
                    if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++
                    row.add(field.toString()); field.clear()
                    rows.add(row); row = mutableListOf()
                    if (rows.size >= limit) return rows
                }
                else -> field.append(c)
            }
            i++
        }
        if (field.isNotEmpty() || row.isNotEmpty()) { row.add(field.toString()); rows.add(row) }
        return rows
    }
}
