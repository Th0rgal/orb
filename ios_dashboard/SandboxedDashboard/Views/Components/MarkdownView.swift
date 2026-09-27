import SwiftUI

private enum MarkdownBlock {
    case math(String)
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, items: [String])
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case blockquote(String)
    /// Inline image emitted by agents as `<image path="..." alt="..." />`
    /// (transformed upstream in the Next.js app and now mirrored here so the
    /// iOS view doesn't drop these). Path is sandboxed-relative.
    case image(path: String, alt: String)
}

/// Mission/workspace identifiers that inline rich-tag images need to fetch
/// from `/api/fs/download`. Threaded via SwiftUI environment so the single
/// MarkdownView call site doesn't need to grow extra parameters.
struct MissionFileContext: Equatable {
    let workspaceId: String?
    let missionId: String?

    static let empty = MissionFileContext(workspaceId: nil, missionId: nil)
}

private struct MissionFileContextKey: EnvironmentKey {
    static let defaultValue: MissionFileContext = .empty
}

extension EnvironmentValues {
    var missionFileContext: MissionFileContext {
        get { self[MissionFileContextKey.self] }
        set { self[MissionFileContextKey.self] = newValue }
    }
}

struct MarkdownView: View {
    let content: String
    @Environment(\.controlPerformanceDiagnosticsEnabled) private var diagnosticsEnabled
    private static let parseCache = MarkdownParseCache()

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        let blocks = Self.parseCache.blocks(
            for: content,
            diagnosticsEnabled: diagnosticsEnabled
        )
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .math(let source):
                    OrbMath(source: source)
                case .paragraph(let text):
                    MarkdownInlineText(text)
                case .heading(let level, let text):
                    MarkdownInlineText(text)
                        .font(headingFont(level))
                        .fontWeight(.semibold)
                case .list(let ordered, let items):
                    MarkdownListView(ordered: ordered, items: items)
                case .codeBlock(_, let code):
                    MarkdownCodeBlock(code: code)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                case .blockquote(let text):
                    MarkdownBlockquoteView(text: text)
                case .image(let path, let alt):
                    MarkdownInlineImageView(path: path, alt: alt)
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

@MainActor
private final class MarkdownParseCache {
    private final class Entry {
        let blocks: [MarkdownBlock]

        init(blocks: [MarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init() {
        cache.countLimit = 500
    }

    func blocks(for content: String, diagnosticsEnabled: Bool) -> [MarkdownBlock] {
        let key = "\(content.count):\(content.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }

        let parsed = diagnosticsEnabled
            ? ControlPerformanceDiagnostics.shared.measure(
                "markdown.parse",
                detail: "\(content.count) chars",
                count: content.count
            ) {
                MarkdownParser.parse(content)
            }
            : MarkdownParser.parse(content)
        cache.setObject(Entry(blocks: parsed), forKey: key)
        return parsed
    }
}

@MainActor
private final class MarkdownInlineTextCache {
    static let shared = MarkdownInlineTextCache()

    private final class Entry {
        let attributed: AttributedString?

        init(attributed: AttributedString?) {
            self.attributed = attributed
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init() {
        cache.countLimit = 1_500
    }

    func attributedString(for content: String) -> AttributedString? {
        let key = "\(content.count):\(content.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.attributed
        }

        let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        cache.setObject(Entry(attributed: attributed), forKey: key)
        return attributed
    }
}

private struct MarkdownInlineText: View {
    let content: String

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        if let attributed = MarkdownInlineTextCache.shared.attributedString(for: content) {
            Text(attributed)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
        } else {
            Text(content)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct MarkdownListView: View {
    let ordered: Bool
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 20, alignment: .leading)
                    MarkdownInlineText(items[index])
                }
            }
        }
    }
}

private struct MarkdownCodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu { Button("Copy code") { UIPasteboard.general.string = code } }
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        MarkdownInlineText(headers[index])
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.vertical, 4)
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { colIndex in
                            MarkdownInlineText(rows[rowIndex][colIndex])
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct MarkdownBlockquoteView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 3)
                .clipShape(Capsule())
            MarkdownInlineText(text)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// Reusable shimmer placeholder — matches the `animate-pulse` panel the
/// Next.js dashboard renders while an image is fetching, so a streaming
/// reply doesn't show a bare spinner.
struct ShimmerSkeleton: View {
    var cornerRadius: CGFloat = 12
    var height: CGFloat = 200

    @State private var phase: CGFloat = -1.2

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.backgroundSecondary)

            // Diagonal highlight sweeping left → right. Clipped to the shape
            // so the gradient doesn't bleed past the skeleton's rounded edge.
            GeometryReader { geo in
                let highlightWidth = geo.size.width * 0.45
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.08),
                        Color.white.opacity(0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: highlightWidth)
                .offset(x: phase * geo.size.width)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }
}

/// Renders an inline `<image>` rich tag. Mirrors the Next.js
/// `InlineImagePreview` lifecycle: fetch from `/api/fs/download` with the
/// bearer token + workspace/mission context, render shimmer while loading,
/// and degrade to a labelled error tile on failure.
struct MarkdownInlineImageView: View {
    let path: String
    let alt: String

    @Environment(\.missionFileContext) private var fileContext
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var displayAlt: String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    var body: some View {
        Group {
            if let data = imageData, let uiImage = ImageMemoryCache.shared.cachedImage(for: imageCacheURL) ?? UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
                    .accessibilityLabel(displayAlt)
            } else if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding(.horizontal, 12)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
            } else if isLoading {
                ShimmerSkeleton()
            }
        }
        .task(id: imageTaskKey) {
            await load()
        }
    }

    private var imageCacheURL: URL {
        URL(string: imageTaskKey) ?? URL(fileURLWithPath: imageTaskKey)
    }

    /// Key the `.task` view modifier so a context change (workspace/mission
    /// resolves after first paint) re-runs the fetch with the new params.
    private var imageTaskKey: String {
        "\(path)|\(fileContext.workspaceId ?? "")|\(fileContext.missionId ?? "")"
    }

    private func load() async {
        await MainActor.run {
            imageData = nil
            errorMessage = nil
            isLoading = true
        }

        let resolved = resolvedPath()
        let baseURL = APIService.shared.baseURL
        var components = URLComponents(string: baseURL + "/api/fs/download")
        var items: [URLQueryItem] = [URLQueryItem(name: "path", value: resolved)]
        if let workspaceId = fileContext.workspaceId, !workspaceId.isEmpty {
            items.append(URLQueryItem(name: "workspace_id", value: workspaceId))
        }
        if let missionId = fileContext.missionId, !missionId.isEmpty {
            items.append(URLQueryItem(name: "mission_id", value: missionId))
        }
        components?.queryItems = items

        guard let url = components?.url else {
            await MainActor.run {
                errorMessage = "Invalid path"
                isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = APIService.requestTimeout
        if let token = APIService.shared.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let image = await ImageMemoryCache.shared.image(from: data, url: url) {
                await MainActor.run {
                    ImageMemoryCache.shared.store(image, for: imageCacheURL)
                    imageData = data
                    isLoading = false
                }
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    errorMessage = status == 0 ? "Image unavailable" : "Image unavailable (\(status))"
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// URL-decode the path: rich tags arrive as `sandboxed-image://<encoded>`
    /// in markdown form, and the percent-encoding has to be stripped before
    /// hitting `/api/fs/download` which expects the raw filesystem path.
    private func resolvedPath() -> String {
        path.removingPercentEncoding ?? path
    }
}

private enum MarkdownParser {
    /// Matches both self-closing `<image path="..." />` and paired
    /// `<image ...></image>` so partial/odd agent output still extracts.
    private static let imageTagRegex: NSRegularExpression? = {
        let pattern = #"<\s*image\s+([^>]*?)(?:/\s*>|>\s*<\s*/\s*image\s*>)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    /// Pulls `name="value"` / `name='value'` attribute pairs out of the
    /// attribute substring of a rich tag.
    private static func parseAttributes(_ attrString: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return result }
        let ns = attrString as NSString
        let matches = regex.matches(in: attrString, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let doubleQuoted = match.range(at: 2)
            let singleQuoted = match.range(at: 3)
            let value: String
            if doubleQuoted.location != NSNotFound {
                value = ns.substring(with: doubleQuoted)
            } else if singleQuoted.location != NSNotFound {
                value = ns.substring(with: singleQuoted)
            } else {
                continue
            }
            result[key] = value
        }
        return result
    }

    /// Pre-pass: walk the source, replace every `<image .../>` with a
    /// fenced placeholder line that the line-based parser can recognize as
    /// a single image block. Keeps the rest of the parser unchanged.
    private static func extractImageTags(from content: String) -> (transformed: String, tags: [(path: String, alt: String)]) {
        guard let regex = imageTagRegex else { return (content, []) }
        let ns = content as NSString
        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return (content, []) }

        var tags: [(path: String, alt: String)] = []
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let attrsRange = match.range(at: 1)
            let attrs = attrsRange.location == NSNotFound
                ? [:]
                : parseAttributes(ns.substring(with: attrsRange))
            if let path = attrs["path"], !path.isEmpty {
                let alt = attrs["alt"] ?? ""
                let index = tags.count
                tags.append((path: path, alt: alt))
                // Surrounding newlines force the line parser to treat the
                // placeholder as its own block, regardless of where the tag
                // was sitting in the original text.
                result += "\n\u{1F}IMAGE:\(index)\u{1F}\n"
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return (result, tags)
    }

    /// Standard markdown image: `![alt](sandboxed-image://path)` or any URL.
    /// Returns (path, alt) when the entire trimmed line is a single image.
    private static func parseInlineImageLine(_ line: String) -> (path: String, alt: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let altEnd = trimmed.firstIndex(of: "]") else { return nil }
        let afterAlt = trimmed.index(after: altEnd)
        guard afterAlt < trimmed.endIndex, trimmed[afterAlt] == "(" else { return nil }
        let urlStart = trimmed.index(after: afterAlt)
        let urlEnd = trimmed.index(before: trimmed.endIndex)
        guard urlStart < urlEnd else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
        var url = String(trimmed[urlStart..<urlEnd])
        // Strip the sandboxed-image:// scheme so we can pass the raw path
        // to /api/fs/download. Other schemes (http/https) fall through and
        // the resolver below will try them as-is.
        if url.lowercased().hasPrefix("sandboxed-image://") {
            url = String(url.dropFirst("sandboxed-image://".count))
        }
        return (url, alt)
    }

    static func parse(_ content: String) -> [MarkdownBlock] {
        let extracted = extractImageTags(from: content)
        let normalized = extracted.transformed.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        let imagePlaceholderPrefix = "\u{1F}IMAGE:"
        let imagePlaceholderSuffix = "\u{1F}"

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Rich-tag image: pre-pass turned `<image .../>` into a unique
            // placeholder line. Resolve it back to the original (path, alt).
            if trimmed.hasPrefix(imagePlaceholderPrefix) && trimmed.hasSuffix(imagePlaceholderSuffix) {
                let middle = trimmed.dropFirst(imagePlaceholderPrefix.count).dropLast(imagePlaceholderSuffix.count)
                if let tagIndex = Int(middle), tagIndex >= 0, tagIndex < extracted.tags.count {
                    let tag = extracted.tags[tagIndex]
                    blocks.append(.image(path: tag.path, alt: tag.alt))
                    index += 1
                    continue
                }
            }

            // Standard markdown image (single-line): `![alt](url)`. Treat as
            // a block-level image when the whole line is the image — inline
            // mixing with surrounding text is handled by AttributedString.
            if let imageLine = parseInlineImageLine(trimmed) {
                blocks.append(.image(path: imageLine.path, alt: imageLine.alt))
                index += 1
                continue
            }

            if trimmed.hasPrefix("$$") {
                var expression = String(trimmed.dropFirst(2))
                index += 1
                if expression.hasSuffix("$$") { expression = String(expression.dropLast(2)) }
                else {
                    while index < lines.count {
                        let next = lines[index]; index += 1
                        if next.trimmingCharacters(in: .whitespaces).hasSuffix("$$") { expression += "\n" + String(next.trimmingCharacters(in: .whitespaces).dropLast(2)); break }
                        expression += "\n" + next
                    }
                }
                blocks.append(.math(expression)); continue
            }

            if trimmed.hasPrefix("```") {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(current)
                    index += 1
                }
                blocks.append(.codeBlock(language: language.isEmpty ? nil : String(language), code: codeLines.joined(separator: "\n")))
                continue
            }

            if isTableHeader(at: index, lines: lines) {
                let headerLine = lines[index]
                let headerCells = splitTableLine(headerLine)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || !rowLine.contains("|") {
                        break
                    }
                    rows.append(splitTableLine(rowLine))
                    index += 1
                }
                blocks.append(.table(headers: headerCells, rows: rows))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    let stripped = current.dropFirst().trimmingCharacters(in: .whitespaces)
                    quoteLines.append(String(stripped))
                    index += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let listItem = parseListItem(trimmed) {
                var items: [String] = [listItem.text]
                let ordered = listItem.ordered
                index += 1
                while index < lines.count {
                    let currentTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let nextItem = parseListItem(currentTrimmed), nextItem.ordered == ordered else { break }
                    items.append(nextItem.text)
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            var paragraphLines: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let current = lines[index]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty || isBlockStart(at: index, lines: lines) {
                    break
                }
                paragraphLines.append(currentTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6 else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return (hashes, text.isEmpty ? line : String(text))
    }

    private static func parseListItem(_ line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }

        let components = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if components.count == 2, let first = components.first {
            if first.last == ".", first.dropLast().allSatisfy({ $0.isNumber }) {
                return (true, String(components[1]))
            }
        }

        return nil
    }

    private static func isTableHeader(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index]
        let separator = lines[index + 1]
        return header.contains("|") && isTableSeparator(separator)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let parts = cleaned.split(separator: "|")
        guard !parts.isEmpty else { return false }
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            if cell.isEmpty { return false }
            let trimmedCell = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if trimmedCell.count < 3 || !trimmedCell.allSatisfy({ $0 == "-" }) {
                return false
            }
        }
        return true
    }

    private static func splitTableLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        return cleaned.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isBlockStart(at index: Int, lines: [String]) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("$$") { return true }
        if parseHeading(trimmed) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if parseListItem(trimmed) != nil { return true }
        if isTableHeader(at: index, lines: lines) { return true }
        return false
    }
}
