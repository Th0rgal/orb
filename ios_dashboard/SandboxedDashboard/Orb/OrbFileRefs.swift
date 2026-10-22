import Foundation

// MARK: - Shared files: one parser for the transcript and the Files tab
//
// Agents share files with rich tags (desktop `orb/src/richTags.ts`, web
// `dashboard/src/lib/rich-tags.ts`):
//   `<file path="./r.pdf" name="Report" />`, `<file path="r.pdf">Report</file>`,
//   `<image path="./chart.png" alt="Chart" />`.
// Core may also attach `metadata.shared_files` (name, size_bytes, an
// authenticated `/api/fs/download` url) to the assistant message.
// Spec and real prod samples: shared/orb-spec/file-references.json.

/// What a preview can do with a file, from its name (or a MIME hint).
enum OrbFileKind: String, Sendable, CaseIterable {
    case image, svg, pdf, markdown, csv, json, code, text, other

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
    static let codeExtensions: Set<String> = [
        "py", "swift", "kt", "kts", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rs", "go", "java", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "rb", "php", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
        "sql", "lean", "tex", "patch", "diff", "ini", "cfg", "conf", "gradle", "lua", "r", "scala", "cs", "hs", "ex", "exs",
        "nix", "proto", "graphql", "vue", "svelte", "sol", "move", "cairo", "zig", "dart", "ml", "jsonl", "ndjson", "env"
    ]
    static let textExtensions: Set<String> = ["txt", "log", "text", "out", "err", "rst"]

    static func of(_ name: String, mime: String? = nil) -> OrbFileKind {
        let ext = OrbFileRefs.fileExtension(name)
        if imageExtensions.contains(ext) { return .image }
        switch ext {
        case "svg": return .svg
        case "pdf": return .pdf
        case "md", "markdown", "mdx": return .markdown
        case "csv", "tsv": return .csv
        case "json", "geojson", "ipynb": return .json
        default: break
        }
        if codeExtensions.contains(ext) { return .code }
        if textExtensions.contains(ext) { return .text }
        if let mime = mime?.lowercased() {
            if mime == "application/pdf" { return .pdf }
            if mime == "image/svg+xml" { return .svg }
            if mime.hasPrefix("image/") { return .image }
            if mime == "application/json" { return .json }
            if mime == "text/markdown" { return .markdown }
            if mime == "text/csv" { return .csv }
            if mime.hasPrefix("text/") { return .text }
        }
        return .other
    }

    /// SF Symbol for the chip and the Files list.
    var symbol: String {
        switch self {
        case .image, .svg: "photo"
        case .pdf: "doc.richtext"
        case .markdown: "doc.text"
        case .csv: "tablecells"
        case .json: "curlybraces"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.plaintext"
        case .other: "doc"
        }
    }

    /// Text-like kinds are rendered in-app from their UTF-8 contents.
    var isTextual: Bool { [.markdown, .csv, .json, .code, .text].contains(self) }
}

/// A file an agent shared: from a tag, from `metadata.shared_files`, or both.
struct OrbFileRef: Identifiable, Hashable, Sendable {
    /// "image" or "file" (the tag that shared it).
    var type: String
    var path: String
    var label: String
    var mime: String?
    var size: Int64?
    /// Authenticated same-origin download URL from `metadata.shared_files`.
    var url: String?
    /// When it was shared (event timestamp), for the Files tab.
    var sharedAt: String?
    /// Core could not copy the file (`unavailable="true"`): shown, never fetched.
    var unavailable = false
    var id: String { OrbFileRefs.normalize(path) }
    var name: String { OrbFileRefs.fileName(path) }
    var kind: OrbFileKind {
        let byPath = OrbFileKind.of(name, mime: mime)
        return byPath == .other ? OrbFileKind.of(label, mime: mime) : byPath
    }
}

/// `metadata.shared_files[]` of an assistant message.
struct OrbSharedFile: Hashable, Sendable {
    var name: String
    var size: Int64?
    var url: String
    var contentType: String?

    init(name: String, size: Int64?, url: String, contentType: String?) {
        self.name = name; self.size = size; self.url = url; self.contentType = contentType
    }

    init?(_ raw: [String: Any]) {
        guard let url = raw["url"] as? String, !url.isEmpty else { return nil }
        let pathParam = URLComponents(string: url)?.queryItems?.first { $0.name == "path" }?.value
        let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (raw["path"] as? String).map(OrbFileRefs.fileName)
            ?? pathParam.map(OrbFileRefs.fileName) ?? "artifact"
        let size = (raw["size_bytes"] as? NSNumber)?.int64Value ?? (raw["size"] as? NSNumber)?.int64Value
        self.init(name: name, size: size, url: url, contentType: raw["content_type"] as? String)
    }

    /// The absolute workspace path Core published, from the url's `path` query.
    var sourcePath: String? { URLComponents(string: url)?.queryItems?.first { $0.name == "path" }?.value }
}

enum OrbFileSegment: Equatable {
    case text(String)
    case file(OrbFileRef)
}

enum OrbFileRefs {
    /// Same expression as desktop `RICH_TAG`.
    private static let tag = try! NSRegularExpression(
        pattern: #"<(image|file)\s+([^>]*?)(?:/\s*>|>([^<]*?)</\1\s*>)"#, options: [.caseInsensitive])
    private static let attribute = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let incompleteTail = try! NSRegularExpression(pattern: #"<(?:image|file)(?:\s[^>]*)?$"#, options: [.caseInsensitive])

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }
    static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
    static func fileExtension(_ name: String) -> String {
        let base = fileName(name)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[base.index(after: dot)...]).lowercased()
    }
    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Parses one tag's attributes the way desktop `parseRichTag` does.
    static func parseTag(type: String, attributes: String, inner: String?) -> OrbFileRef? {
        var values: [String: String] = [:]
        let ns = attributes as NSString
        for m in attribute.matches(in: attributes, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let value = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : (m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : "")
            values[key] = value
        }
        guard let path = values["path"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let kind = type.lowercased()
        let present: (String?) -> String? = { v in v.map(collapse).flatMap { $0.isEmpty ? nil : $0 } }
        let label = present(kind == "image" ? values["alt"] : values["name"]) ?? present(inner) ?? fileName(path)
        let mime = values["type"].flatMap { $0.contains("/") ? $0 : nil }
        return OrbFileRef(type: kind, path: path, label: label, mime: mime, unavailable: values["unavailable"] == "true")
    }

    /// Hermes's attachment directive alone on a line (`MEDIA:/tmp/plot.png`, `**MEDIA:/tmp/r.pdf**`,
    /// `MEDIA: "/tmp/a b.csv"`). Same expression as desktop `mediaLineTag`. Core rewrites these at
    /// ingestion; this fallback covers messages stored before it did.
    private static let mediaLine = try! NSRegularExpression(
        pattern: #"^[ \t]*[*_]{0,3}MEDIA:[ \t]*(?:"([^"<>\n]+)"|'([^'"<>\n]+)'|((?:~/|/)[^\s"'<>`]+?))[*_]{0,3}[.,;:]?[ \t\r]*$"#)
    static let mediaImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// One `MEDIA:` line as the equivalent rich tag, or nil.
    static func mediaLineTag(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = mediaLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let group = (1...3).first(where: { m.range(at: $0).location != NSNotFound }) else { return nil }
        let path = ns.substring(with: m.range(at: group)).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let name = fileName(path)
        return mediaImageExtensions.contains(fileExtension(name)) ? "<image path=\"\(path)\" alt=\"\(name)\" />" : "<file path=\"\(path)\" name=\"\(name)\" />"
    }

    /// `MEDIA:` lines outside fenced code rewritten as rich tags. While streaming, the
    /// unfinished last line is left alone.
    static func expandMedia(_ text: String, streaming: Bool = false) -> String {
        guard text.contains("MEDIA:") else { return text }
        var lines = text.components(separatedBy: "\n")
        var fence: String?
        for i in lines.indices {
            let trimmed = lines[i].drop { $0 == " " || $0 == "\t" }
            if let marker = fence { if trimmed.hasPrefix(marker) { fence = nil }; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); continue }
            if streaming && i == lines.count - 1 { continue }
            if let tag = mediaLineTag(lines[i]) { lines[i] = tag }
        }
        return lines.joined(separator: "\n")
    }

    /// Ranges of fenced code blocks: tags written there are documentation.
    private static func fencedRanges(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var open: Int?
        var marker = ""
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespaces)
            if let start = open {
                if trimmed.hasPrefix(marker) { ranges.append(NSRange(location: start, length: NSMaxRange(line) - start)); open = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                open = line.location; marker = String(trimmed.prefix(3))
            }
            location = NSMaxRange(line)
        }
        if let start = open { ranges.append(NSRange(location: start, length: text.length - start)) }
        return ranges
    }

    /// Message text split into prose and file tags, in order. Prose keeps its Markdown.
    static func segments(_ text: String, streaming: Bool = false) -> [OrbFileSegment] {
        var source = expandMedia(text, streaming: streaming)
        if streaming, let m = incompleteTail.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
            source = (source as NSString).substring(to: m.range.location)
            while source.last?.isNewline == true { source.removeLast() }
        }
        guard source.range(of: "<image", options: .caseInsensitive) != nil || source.range(of: "<file", options: .caseInsensitive) != nil else {
            return source.isEmpty ? [] : [.text(source)]
        }
        let ns = source as NSString
        let fences = fencedRanges(ns)
        var out: [OrbFileSegment] = []
        var last = 0
        func flush(_ upTo: Int) {
            guard upTo > last else { return }
            let chunk = ns.substring(with: NSRange(location: last, length: upTo - last)).trimmingCharacters(in: .newlines)
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(chunk)) }
        }
        for m in tag.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if fences.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            let inner = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
            guard let ref = parseTag(type: ns.substring(with: m.range(at: 1)), attributes: ns.substring(with: m.range(at: 2)), inner: inner) else { continue }
            flush(m.range.location)
            out.append(.file(ref))
            last = NSMaxRange(m.range)
        }
        flush(ns.length)
        return out
    }

    static func refs(_ text: String) -> [OrbFileRef] {
        segments(text).compactMap { if case .file(let r) = $0 { r } else { nil } }
    }

    /// Prose without tags, whitespace-collapsed (tests and previews).
    static func plainText(_ text: String) -> String {
        collapse(segments(text).compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: " "))
    }

    /// The `shared_files` entry published for this tag, by file name or path suffix.
    static func match(_ ref: OrbFileRef, in shared: [OrbSharedFile]) -> OrbSharedFile? {
        let rel = normalize(ref.path)
        return shared.first { file in
            if let source = file.sourcePath, source == ref.path || source.hasSuffix("/" + rel) { return true }
            return file.name == ref.name
        }
    }

    static func enrich(_ ref: OrbFileRef, shared: [OrbSharedFile]) -> OrbFileRef {
        guard let file = match(ref, in: shared) else { return ref }
        var out = ref
        out.size = out.size ?? file.size
        out.url = out.url ?? file.url
        if out.mime == nil, let type = file.contentType, type != "application/octet-stream" { out.mime = type }
        return out
    }

    struct Message: Sendable {
        var content: String
        var shared: [OrbSharedFile]
        var at: String
        var sequence: Int64
    }

    static func sharedFiles(_ metadata: Any?) -> [OrbSharedFile] {
        ((metadata as? [String: Any])?["shared_files"] as? [[String: Any]] ?? []).compactMap(OrbSharedFile.init)
    }

    /// Every file shared in a conversation, newest first, one row per path.
    static func collect(_ messages: [Message]) -> [OrbFileRef] {
        var seen = Set<String>()
        var out: [OrbFileRef] = []
        for message in messages.sorted(by: { $0.sequence > $1.sequence }) {
            var rows = refs(message.content).map { enrich($0, shared: message.shared) }
            for file in message.shared where !rows.contains(where: { match($0, in: [file]) != nil }) {
                rows.append(OrbFileRef(type: OrbFileKind.of(file.name) == .image ? "image" : "file", path: file.sourcePath ?? file.name,
                                       label: file.name, mime: file.contentType, size: file.size, url: file.url))
            }
            for var row in rows where !row.unavailable && seen.insert(row.id).inserted {
                row.sharedAt = message.at
                out.append(row)
            }
        }
        return out
    }

    static func messages(_ events: [StoredEvent]) -> [Message] {
        events.filter { $0.eventType == "assistant_message" }.map {
            Message(content: $0.content, shared: sharedFiles($0.metadata.mapValues(\.value)), at: $0.timestamp, sequence: $0.sequence)
        }
    }

    static func messages(_ json: OrbJSON) -> [Message] {
        let rows = json.items.isEmpty ? json["events"].items : json.items
        return rows.enumerated().compactMap { index, row in
            guard row["event_type"].text == "assistant_message" else { return nil }
            let metadata = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(row["metadata"]))) ?? nil
            return Message(content: row["content"].text, shared: sharedFiles(metadata), at: row["timestamp"].text,
                           sequence: Int64(row["sequence"].doubleValue ?? Double(index)))
        }
    }

    static func formatSize(_ bytes: Int64?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Code highlighting (pure; the views map kinds to colours)

enum OrbCodeHighlight {
    enum Token: Equatable { case keyword, string, comment, number, added, removed }

    private static let keywords = [
        "if", "else", "elif", "for", "while", "do", "return", "func", "fn", "fun", "def", "let", "var", "val", "const", "class", "struct",
        "enum", "interface", "protocol", "extension", "impl", "trait", "type", "import", "from", "package", "use", "pub", "mod",
        "match", "case", "switch", "when", "default", "break", "continue", "true", "false", "nil", "null", "None", "True", "False",
        "self", "this", "async", "await", "try", "catch", "throw", "throws", "guard", "in", "is", "as", "not", "and", "or", "new",
        "static", "private", "public", "protected", "mut", "where", "yield", "lambda", "with", "then", "end", "fi", "esac", "echo",
        "export", "object", "theorem", "lemma", "by", "have", "show", "select", "insert", "update", "delete", "create", "table",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON", "AND", "OR", "NOT", "NULL"
    ]
    private static let hashComment: Set<String> = ["py", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "rb", "r", "nix", "conf", "cfg", "ini", "env", "ex", "exs", "gradle"]
    private static let dashComment: Set<String> = ["sql", "lean", "hs", "lua"]

    private static func expression(_ language: String) -> NSRegularExpression {
        let comment: String
        if hashComment.contains(language) { comment = #"#[^\n]*"# }
        else if dashComment.contains(language) { comment = #"--[^\n]*|/-[\s\S]*?-/"# }
        else if language == "json" { comment = #"(?!)"# }
        else if ["html", "htm", "xml", "svg", "vue", "svelte"].contains(language) { comment = #"<!--[\s\S]*?-->"# }
        else { comment = #"//[^\n]*|/\*[\s\S]*?\*/"# }
        let strings = #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#
        let words = language == "json" ? "true|false|null" : keywords.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(\(comment))|(\(strings))|(\\b\\d+(?:\\.\\d+)?\\b)|(\\b(?:\(words))\\b)")
    }

    /// Highlighted ranges (UTF-16) of `code`. Large inputs are left plain.
    static func tokens(_ code: String, language: String) -> [(NSRange, Token)] {
        let ns = code as NSString
        guard ns.length <= 200_000 else { return [] }
        if language == "diff" || language == "patch" {
            var out: [(NSRange, Token)] = []
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let text = ns.substring(with: line)
                if text.hasPrefix("+") && !text.hasPrefix("+++") { out.append((line, .added)) }
                else if text.hasPrefix("-") && !text.hasPrefix("---") { out.append((line, .removed)) }
                else if text.hasPrefix("@@") { out.append((line, .keyword)) }
                location = NSMaxRange(line)
            }
            return out
        }
        return expression(language).matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for (group, token) in [(1, Token.comment), (2, .string), (3, .number), (4, .keyword)] where m.range(at: group).location != NSNotFound {
                return (m.range, token)
            }
            return nil
        }
    }
}

// MARK: - CSV

enum OrbCSV {
    /// RFC 4180 rows (quoted fields, doubled quotes, newlines in quotes). `limit` caps the rows read.
    static func parse(_ text: String, delimiter: Character = ",", limit: Int = 1000) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
                if rows.count >= limit { return rows }
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
