import SwiftUI
import QuickLook
import PhotosUI
import UniformTypeIdentifiers

struct OrbAttachment: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let data: Data
}
struct OrbPreviewFile: Identifiable { let id = UUID(); let url: URL }
struct OrbPreviewSheet: View {
    let file: OrbPreviewFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: file.url.path) {
                    OrbZoomImage(image: image, name: file.url.lastPathComponent)
                } else if let text = textContent {
                    ScrollView {
                        if file.url.pathExtension.lowercased() == "md" { OrbRichText(source: text).padding() }
                        else { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("artifact-text") }
                    }
                } else { OrbFilePreview(url: file.url) }
            }.accessibilityIdentifier("artifact-preview")
                .navigationTitle(file.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { ShareLink(item: file.url) }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityLabel("Close preview") }
                }
        }
    }
    private var textContent: String? {
        guard ["md", "txt", "csv", "json", "py", "swift", "js", "ts", "yaml", "yml", "log"].contains(file.url.pathExtension.lowercased()),
              let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { return nil }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

}
/// Images render directly and retain native pinch/drag zoom, without waiting for a QuickLook extension.
struct OrbZoomImage: UIViewRepresentable {
    let image: UIImage
    let name: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ImageScroll {
        let view = ImageScroll()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 8
        view.imageView.image = image
        view.imageView.isAccessibilityElement = true
        view.imageView.accessibilityIdentifier = "artifact-image"
        view.imageView.accessibilityLabel = name
        return view
    }
    func updateUIView(_ view: ImageScroll, context: Context) {}
    final class ImageScroll: UIScrollView {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScroll)?.imageView }
    }
}
struct OrbFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { controller.reloadData() }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
struct OrbAttachments: View {
    @Binding var files: [OrbAttachment]
    @Binding var error: String
    var canAdd = true
    var showContextMention: (() -> Void)? = nil
    var showMode: (() -> Void)? = nil
    var showFiles = true
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: OrbPreviewFile?
    var body: some View {
        VStack(alignment: .leading) {
            if canAdd {
                Menu {
                    if let showContextMention {
                        Button(action: showContextMention) { Label("Project context", systemImage: "at") }
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Photos", systemImage: "photo") }
                    Button { importing = true } label: { Label("Files", systemImage: "paperclip") }
                    if let showMode {
                        Divider()
                        Button(action: showMode) { Label("Mode", systemImage: "target") }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(OrbStyle.border, lineWidth: 1))
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add context, attachments, or mode")
                .accessibilityIdentifier("composer-add")
            }
            if showFiles && !files.isEmpty { ScrollView(.horizontal) {
                HStack {
                    ForEach(files) { file in
                        HStack {
                            Button(file.name) {
                                do { let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.id.uuidString + "-" + file.name); try file.data.write(to: url, options: .atomic); preview = OrbPreviewFile(url: url) }
                                catch { self.error = error.localizedDescription }
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                            Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Remove \(file.name)")
                        }.padding(8).background(.white.opacity(0.07), in: Capsule())
                    }
                }
            } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try add(Data(contentsOf: url), name: url.lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: photo) { _, item in
            Task { do { if let data = try await item?.loadTransferable(type: Data.self) { try add(data, name: "Photo.\(item?.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")") } } catch { self.error = error.localizedDescription } }
        }
        .sheet(item: $preview) { OrbPreviewSheet(file: $0) }
    }
    private func add(_ data: Data, name: String) throws {
        guard data.count <= 20 * 1024 * 1024 else { throw OrbHTTPError(status: 413, detail: "Files must be 20 MiB or smaller.") }
        files.append(OrbAttachment(id: UUID(), name: name, data: data))
    }
}

// MARK: - Project Context Tagging (`@` Mention Parity with Desktop `orb/src/attach.tsx`)

struct OrbContextItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case file, folder, context }
    enum Section: String, Sendable { case folders = "Folders", files = "Files" }
    let id: String
    let kind: Kind
    let section: Section
    let path: String
    let label: String
    let project: String
}

enum OrbContextTagging {
    /// Detect an active `@query` token at the end of `text` (`atQuery` in `orb/src/attach.tsx`).
    static func activeAtQuery(_ text: String) -> (query: String, tokenRange: Range<String.Index>)? {
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        if atIdx > text.startIndex {
            let prev = text[text.index(before: atIdx)]
            guard prev.isWhitespace || prev == "(" || prev == "[" || prev == "{" else { return nil }
        }
        let afterAt = text[text.index(after: atIdx)...]
        guard !afterAt.contains(where: \.isWhitespace) else { return nil }
        return (String(afterAt).lowercased(), atIdx..<text.endIndex)
    }

    static func mentionText(for item: OrbContextItem) -> String {
        let isFolder = item.section == .folders || item.kind == .folder
        let written = isFolder && !item.path.hasSuffix("/") ? "\(item.path)/" : item.path
        if written.contains(where: { $0.isWhitespace || $0 == "\"" }) {
            let escaped = written.replacingOccurrences(of: "\"", with: "\\\"")
            return "@\"\(escaped)\""
        }
        return "@\(written)"
    }

    static func insertMention(in text: String, item: OrbContextItem) -> String {
        let token = mentionText(for: item) + " "
        if let active = activeAtQuery(text) {
            var next = text
            next.replaceSubrange(active.tokenRange, with: token)
            return next
        }
        let sep = (text.isEmpty || text.last?.isWhitespace == true) ? "" : " "
        return text + sep + token
    }

    static func setFolderQuery(in text: String, folder: String) -> String {
        let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = clean.isEmpty ? "@" : "@\(clean)/"
        if let active = activeAtQuery(text) {
            var next = text
            next.replaceSubrange(active.tokenRange, with: token)
            return next
        }
        let sep = (text.isEmpty || text.last?.isWhitespace == true) ? "" : " "
        return text + sep + token
    }

    static func folderPrefixFromQuery(items: [OrbContextItem], query: String) -> String? {
        let raw = query.hasPrefix("@") ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query.trimmingCharacters(in: .whitespaces)
        guard raw.hasSuffix("/") else { return nil }
        let folder = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if folder.isEmpty { return "" }
        let exists = items.contains { it in
            let p = it.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            return (it.section == .folders && p == folder) || p.hasPrefix("\(folder)/")
        }
        return exists ? folder : nil
    }

    static func browseItems(_ items: [OrbContextItem], folder: String) -> [OrbContextItem] {
        let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = clean.isEmpty ? "" : "\(clean)/"
        let prefixLower = prefix.lowercased()
        var folders: [String: OrbContextItem] = [:]
        var files: [OrbContextItem] = []

        for item in items {
            let rawPath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rawPath.isEmpty else { continue }
            if !prefix.isEmpty && !rawPath.lowercased().hasPrefix(prefixLower) { continue }
            let rest = prefix.isEmpty ? rawPath : String(rawPath.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            if let slashIdx = rest.firstIndex(of: "/") {
                let childName = String(rest[..<slashIdx])
                let childPath = "\(prefix)\(childName)"
                let key = childPath.lowercased()
                if folders[key] == nil {
                    let exact = items.first { $0.section == .folders && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == key }
                    folders[key] = exact ?? OrbContextItem(
                        id: "context:\(item.project):\(childPath)",
                        kind: item.kind == .context ? .context : .folder,
                        section: .folders,
                        path: childPath,
                        label: "\(childPath)/",
                        project: item.project
                    )
                }
            } else if item.section == .folders || item.kind == .folder {
                let key = rawPath.lowercased()
                if folders[key] == nil {
                    folders[key] = OrbContextItem(
                        id: item.id,
                        kind: item.kind,
                        section: .folders,
                        path: rawPath,
                        label: "\(rawPath)/",
                        project: item.project
                    )
                }
            } else {
                files.append(item)
            }
        }
        let sortedFolders = folders.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let sortedFiles = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Array((sortedFolders + sortedFiles).prefix(80))
    }

    static func filterItems(_ items: [OrbContextItem], query: String, browseFolder: String) -> [OrbContextItem] {
        if !browseFolder.isEmpty {
            return browseItems(items, folder: browseFolder)
        }
        let q = (query.hasPrefix("@") ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            return browseItems(items, folder: "")
        }
        if let prefix = folderPrefixFromQuery(items: items, query: q) {
            return browseItems(items, folder: prefix)
        }
        return Array(items.filter {
            $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }.sorted {
            if $0.section != $1.section { return $0.section == .folders }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.prefix(80))
    }

    private static let mentionRegex = try! NSRegularExpression(pattern: #"(?:^|[\s(\[{])@(?:"((?:[^"\\]|\\.)*)"|([^\s)\]},;]+))"#)

    /// Resolve `@path` mentions written in `text` against the project's context items (`mentionedChips` in `orb/src/attach.tsx`).
    static func mentionedItems(in text: String, items: [OrbContextItem]) -> [OrbContextItem] {
        guard text.contains("@"), !items.isEmpty else { return [] }
        let ns = text as NSString
        let matches = mentionRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var resolved: [OrbContextItem] = []
        var seen: Set<String> = []
        let punctuation = CharacterSet(charactersIn: ".,;:!?/")
        for match in matches {
            let value: String
            if match.range(at: 1).location != NSNotFound {
                value = ns.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else if match.range(at: 2).location != NSNotFound {
                value = ns.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: punctuation)
            } else {
                continue
            }
            guard !value.isEmpty else { continue }
            let candidates = items.filter { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == value }
            let roots = Set(candidates.map(\.project))
            guard roots.count == 1, let item = candidates.first, !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            resolved.append(item)
        }
        return resolved
    }

    /// Convert a context item into its wire attachment object (`chipToAttachment` in `orb/src/attach.tsx`).
    static func wireAttachment(for item: OrbContextItem) -> OrbJSON {
        let kind = item.kind == .context ? "path" : item.kind.rawValue
        return .object(["kind": .string(kind), "path": .string(item.path)])
    }

    /// Parse `/api/projects/:slug/context/manifest` into `OrbContextItem` entries.
    static func parseManifest(_ manifest: OrbJSON, project: String) -> [OrbContextItem] {
        guard case .object(let entries) = manifest["entries"] else { return [] }
        return entries.map { path, entry in
            let isDir = entry["directory"].flag
            return OrbContextItem(
                id: "context:\(project):\(path)",
                kind: .context,
                section: isDir ? .folders : .files,
                path: path,
                label: isDir ? "\(path)/" : path,
                project: project
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    @MainActor static func loadItems(for project: String) async -> [OrbContextItem] {
        guard !project.isEmpty else { return [] }
        if let cached = OrbReadCache.read("project:\(project)"),
           case .object = cached["manifest"]["entries"] {
            let parsed = parseManifest(cached["manifest"], project: project)
            if !parsed.isEmpty { return parsed }
        }
        if let manifest = try? await OrbCore.shared.call("/api/projects/\(OrbCore.escape(project))/context/manifest") {
            let parsed = parseManifest(manifest, project: project)
            if !parsed.isEmpty { return parsed }
        }
        // Fallback to `/api/projects/:slug/files` for older servers or projects without manifest cache
        var fallback: [OrbContextItem] = []
        await walkFiles(project: project, path: "", into: &fallback, depth: 0)
        return fallback
    }

    @MainActor private static func walkFiles(project: String, path: String, into items: inout [OrbContextItem], depth: Int) async {
        guard depth <= 2, items.count < 160 else { return }
        let query = path.isEmpty ? "" : "?path=\(OrbCore.escape(path))"
        guard let resp = try? await OrbCore.shared.call("/api/projects/\(OrbCore.escape(project))/files\(query)") else { return }
        for entry in resp["entries"].items {
            guard items.count < 160 else { break }
            let name = entry["name"].text
            guard !name.isEmpty else { continue }
            let rel = path.isEmpty ? name : "\(path)/\(name)"
            if entry["kind"].text == "dir" {
                items.append(OrbContextItem(id: "folder:\(rel)", kind: .folder, section: .folders, path: rel, label: "\(rel)/", project: project))
                await walkFiles(project: project, path: rel, into: &items, depth: depth + 1)
            } else {
                items.append(OrbContextItem(id: "file:\(rel)", kind: .file, section: .files, path: rel, label: rel, project: project))
            }
        }
    }
}
