import SwiftUI
import ImageIO
import PDFKit
import WebKit

// MARK: - Context

/// What file chips need from their conversation: where to fetch from, the
/// `shared_files` Core published, and how to open a preview.
struct OrbFileContext {
    var scope: OrbFileService.Scope
    var shared: [OrbSharedFile] = []
    var open: (OrbFileRef) -> Void
}

private struct OrbFileContextKey: EnvironmentKey { static var defaultValue: OrbFileContext? { nil } }
extension EnvironmentValues {
    var orbFiles: OrbFileContext? {
        get { self[OrbFileContextKey.self] }
        set { self[OrbFileContextKey.self] = newValue }
    }
}


// MARK: - Transcript

/// Assistant Markdown with shared-file tags rendered as chips (never as raw markup).
struct OrbMessageWithFiles: View {
    let text: String
    var streaming = false
    var onArtifact: (String) -> Void = { _ in }
    @Environment(\.orbFiles) private var files

    var body: some View {
        let segments = OrbFileRefs.segments(text, streaming: streaming)
        if segments.count == 1, case .text(let only) = segments[0] {
            OrbRichText(source: only, streaming: streaming, onArtifact: onArtifact)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let prose): OrbRichText(source: prose, streaming: streaming && segment == segments.last, onArtifact: onArtifact)
                    case .file(let ref):
                        let enriched = OrbFileRefs.enrich(ref, shared: files?.shared ?? [])
                        if enriched.unavailable {
                            OrbUnavailableFileChip(ref: enriched)
                        } else if enriched.type == "image", enriched.kind == .image || enriched.kind == .svg, let scope = files?.scope {
                            OrbInlineImage(ref: enriched, scope: scope) { files?.open(enriched) }
                        } else {
                            OrbFileChip(ref: enriched) { files?.open(enriched) }
                        }
                    }
                }
            }
        }
    }
}

struct OrbFileChip: View {
    let ref: OrbFileRef
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: ref.kind.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OrbStyle.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(OrbStyle.elevated, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(OrbStyle.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(OrbStyle.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: 420, alignment: .leading)
            .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ref.label), \(subtitle)")
        .accessibilityHint("Opens a preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("file.chip.\(ref.name)")
    }

    private var subtitle: String {
        [ref.label == ref.name ? nil : ref.name, OrbFileRefs.formatSize(ref.size)].compactMap { $0 }.joined(separator: " · ")
            .nonEmpty ?? ref.kind.rawValue.capitalized
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// An image an agent shared, shown in the transcript; tap opens the preview.
/// Until it loads (or if it cannot), the regular chip stands in.
struct OrbInlineImage: View {
    let ref: OrbFileRef
    let scope: OrbFileService.Scope
    let open: () -> Void
    @State private var image: UIImage?
    @State private var svg: (data: Data, ratio: Double)?

    var body: some View {
        Group {
            if let svg {
                Button(action: open) {
                    OrbSvgView(svg: svg.data, interactive: false)
                        .aspectRatio(min(max(svg.ratio, 0.5), 4), contentMode: .fit)
                        .frame(maxWidth: 420, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.border))
                        .contentShape(RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ref.label)
                .accessibilityHint("Opens a preview")
                .accessibilityIdentifier("file.image.\(ref.name)")
            } else if let image {
                Button(action: open) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ref.label)
                .accessibilityHint("Opens a preview")
                .accessibilityIdentifier("file.image.\(ref.name)")
            } else {
                OrbFileChip(ref: ref, action: open)
            }
        }
        .task(id: ref) {
            guard let url = try? await OrbFileService.shared.fetch(ref, scope: scope) else { return }
            if ref.kind == .svg {
                svg = await Task.detached(priority: .userInitiated) { () -> (data: Data, ratio: Double)? in
                    guard let data = OrbSvg.read(url) else { return nil }
                    return (data, OrbSvg.aspectRatio(String(decoding: data, as: UTF8.self)) ?? 4.0 / 3.0)
                }.value
                return
            }
            image = await Task.detached(priority: .userInitiated) { OrbInlineImage.thumbnail(url) }.value
        }
    }

    /// Downsampled off the main thread: a 25 MB PNG never decodes at full size.
    nonisolated static func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

/// A share Core could not copy: named, never fetched.
struct OrbUnavailableFileChip: View {
    let ref: OrbFileRef

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ref.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OrbStyle.textMuted)
                .frame(width: 32, height: 32)
                .background(OrbStyle.elevated, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.label).font(.subheadline.weight(.medium)).foregroundStyle(OrbStyle.textSecondary).lineLimit(1).truncationMode(.middle)
                Text("File no longer available").font(.caption).foregroundStyle(OrbStyle.textMuted).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius).stroke(OrbStyle.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("file.unavailable.\(ref.name)")
    }
}

// MARK: - Preview

/// Sheet wrapper: one preview component for chips, the Files tab and the workspace.
struct OrbFileViewerSheet: View {
    let ref: OrbFileRef
    let scope: OrbFileService.Scope
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OrbFileViewer(ref: ref, scope: scope)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityIdentifier("file.viewer.done") } }
        }
    }
}

struct OrbFileViewer: View {
    let ref: OrbFileRef
    let scope: OrbFileService.Scope
    @State private var file: URL?
    @State private var progress: Double?
    @State private var failure: OrbFileError?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let file { OrbFileContent(ref: ref, url: file) }
            else if let failure { errorView(failure) }
            else { loadingView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrbStyle.background)
        .navigationTitle(ref.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let file { ToolbarItem(placement: .topBarLeading) { ShareLink(item: file).accessibilityIdentifier("file.viewer.share") } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file.viewer")
        .onAppear { OrbUsageTelemetry.shared.trackAction(.fileViewerOpen, surface: "file_viewer") }
        .task(id: attempt) { await load() }
    }

    private func load() async {
        failure = nil
        do {
            file = try await OrbFileService.shared.fetch(ref, scope: scope) { progress = $0 }
        } catch is CancellationError {
        } catch {
            failure = OrbFileError.from(error, name: ref.label)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            Image(systemName: ref.kind.symbol).font(.system(size: 34)).foregroundStyle(OrbStyle.textMuted)
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 220).tint(.white)
                Text(progressText(progress)).font(.caption.monospacedDigit()).foregroundStyle(OrbStyle.textSecondary)
            } else {
                ProgressView().tint(.white)
                Text("Downloading…").font(.caption).foregroundStyle(OrbStyle.textSecondary)
            }
        }
        .orbA11yContainer("file.viewer.loading")
    }

    private func progressText(_ value: Double) -> String {
        let percent = "\(Int((value * 100).rounded()))%"
        guard let size = ref.size else { return percent }
        return "\(OrbFileRefs.formatSize(Int64(Double(size) * value)) ?? "") of \(OrbFileRefs.formatSize(size) ?? "") · \(percent)"
    }

    private func errorView(_ error: OrbFileError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: { if case .notFound = error { "questionmark.folder" } else if case .machineOffline = error { "server.rack" } else if case .offline = error { "wifi.slash" } else { "exclamationmark.triangle" } }())
                .font(.system(size: 30)).foregroundStyle(OrbStyle.warning)
            Text(error.errorDescription ?? "Couldn’t open this file.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.primary)
                .accessibilityIdentifier("file.viewer.error")
            if error != .notFound(ref.label) {
                Button("Try again") { attempt += 1 }.buttonStyle(.bordered).accessibilityIdentifier("file.viewer.retry")
            }
        }
        .padding(32)
    }
}

/// Renders a downloaded file by kind; anything else goes to the share sheet.
struct OrbFileContent: View {
    let ref: OrbFileRef
    let url: URL
    private static let textLimit = 4 * 1024 * 1024

    var body: some View {
        switch ref.kind {
        case .image:
            if let image = UIImage(contentsOfFile: url.path) {
                OrbZoomImage(image: image, name: ref.label).orbA11yContainer("file.viewer.image")
            } else { unsupported("This image format can’t be shown here.") }
        case .svg:
            if let data = OrbSvg.read(url) { OrbSvgView(svg: data).orbA11yContainer("file.viewer.svg") }
            else { unsupported("This SVG is too large or isn’t valid text.") }
        case .pdf:
            if let document = PDFDocument(url: url) { OrbPDFView(document: document).orbA11yContainer("file.viewer.pdf") }
            else { unsupported("This PDF can’t be opened.") }
        case .markdown, .csv, .json, .code, .text:
            if let text = Self.text(url) { textual(text.content, truncated: text.truncated) }
            else { unsupported("This file isn’t text Orb can show.") }
        case .other: unsupported(nil)
        }
    }

    static func text(_ url: URL) -> (content: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit + 1)) ?? Data()
        let truncated = data.count > textLimit
        let slice = data.prefix(textLimit)
        if slice.prefix(8192).contains(0) { return nil }
        guard let text = String(data: slice, encoding: .utf8) ?? String(data: slice.dropLast(3), encoding: .utf8) else { return nil }
        return (text, truncated)
    }

    @ViewBuilder private func textual(_ text: String, truncated: Bool) -> some View {
        VStack(spacing: 0) {
            if truncated {
                Text("Showing the first 4 MB. Share the file to see all of it.")
                    .font(.caption).foregroundStyle(OrbStyle.textSecondary).padding(8).frame(maxWidth: .infinity).background(OrbStyle.surface)
            }
            switch ref.kind {
            case .markdown:
                ScrollView { OrbRichText(source: text).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                    .orbA11yContainer("file.viewer.markdown")
            case .csv:
                OrbCSVTable(rows: OrbCSV.parse(text, delimiter: OrbFileRefs.fileExtension(ref.name) == "tsv" ? "\t" : ","))
                    .orbA11yContainer("file.viewer.csv")
            case .json: OrbCodeView(text: Self.prettyJSON(text), language: "json")
            default: OrbCodeView(text: text, language: OrbFileRefs.fileExtension(ref.name))
            }
        }
    }

    static func prettyJSON(_ text: String) -> String {
        guard text.utf8.count <= 2 * 1024 * 1024, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let out = String(data: pretty, encoding: .utf8) else { return text }
        return out
    }

    private func unsupported(_ reason: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: ref.kind.symbol).font(.system(size: 40)).foregroundStyle(OrbStyle.textMuted)
            Text(ref.name).font(.headline).multilineTextAlignment(.center)
            if let size = OrbFileRefs.formatSize((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) {
                Text(size).font(.caption).foregroundStyle(OrbStyle.textSecondary)
            }
            Text(reason ?? "No preview for this type. Save it to Files or open it in another app.")
                .font(.subheadline).foregroundStyle(OrbStyle.textSecondary).multilineTextAlignment(.center)
            ShareLink(item: url) { Label("Share or save…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .accessibilityIdentifier("file.viewer.shareButton")
        }
        .padding(32)
        .orbA11yContainer("file.viewer.unsupported")
    }
}

/// Monospaced, highlighted, selectable source.
struct OrbCodeView: View {
    let text: String
    let language: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(Self.highlighted(text, language: language))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading)
        .orbA11yContainer("file.viewer.text")
    }

    static func color(_ token: OrbCodeHighlight.Token) -> Color {
        switch token {
        case .keyword: Color(red: 0.78, green: 0.56, blue: 0.95)
        case .string: Color(red: 0.6, green: 0.82, blue: 0.55)
        case .comment: OrbStyle.textMuted
        case .number: Color(red: 0.95, green: 0.72, blue: 0.45)
        case .added: OrbStyle.success
        case .removed: OrbStyle.error
        }
    }

    static func highlighted(_ text: String, language: String) -> AttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.foregroundColor: UIColor(white: 0.9, alpha: 1)])
        for (range, token) in OrbCodeHighlight.tokens(text, language: language) {
            out.addAttribute(.foregroundColor, value: UIColor(color(token)), range: range)
        }
        return (try? AttributedString(out, including: \.uiKit)) ?? AttributedString(text)
    }
}

struct OrbCSVTable: View {
    let rows: [[String]]
    private let shown = 500

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in
            min(260, max(56, CGFloat(rows.prefix(200).map { $0.count > c ? $0[c].count : 0 }.max() ?? 0) * 7.4 + 18))
        }
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.dropFirst().prefix(shown).enumerated()), id: \.offset) { index, row in
                        line(row, widths: widths, header: false).background(index.isMultiple(of: 2) ? Color.clear : OrbStyle.surface)
                    }
                    if rows.count - 1 > shown {
                        Text("Showing \(shown) of \(rows.count - 1) rows").font(.caption).foregroundStyle(OrbStyle.textMuted).padding(10)
                    }
                } header: {
                    if let header = rows.first { line(header, widths: widths, header: true).background(OrbStyle.elevated) }
                }
            }
            .padding(.bottom, 20)
        }
        .defaultScrollAnchor(.topLeading)
    }

    private func line(_ row: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(widths.indices, id: \.self) { c in
                Text(c < row.count ? row[c] : "")
                    .font(.system(size: 12, weight: header ? .semibold : .regular, design: .monospaced))
                    .lineLimit(2)
                    .frame(width: widths[c], alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .overlay(alignment: .trailing) { Rectangle().fill(OrbStyle.border).frame(width: 1) }
            }
        }
    }
}

struct OrbPDFView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(OrbStyle.background)
        view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}

// MARK: - Files tab

/// Every file shared in the conversation (newest first) and, when the mission
/// has one, its workspace (read-only).
struct OrbFilesSheet: View {
    let scope: OrbFileService.Scope
    @Environment(\.dismiss) private var dismiss
    @State private var files: [OrbFileRef] = []
    @State private var loading = true
    @State private var error: String?
    @State private var workspace = false
    @State private var sessions: [OrbFileService.Session] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Shared in this conversation") {
                    if loading && files.isEmpty {
                        HStack { ProgressView(); Text("Loading files…").foregroundStyle(OrbStyle.textSecondary) }
                    } else if let error, files.isEmpty {
                        OrbNotice(message: error)
                    } else if files.isEmpty {
                        Text("No files shared yet. Files the agent shares appear here.")
                            .font(.subheadline).foregroundStyle(OrbStyle.textSecondary)
                            .accessibilityIdentifier("files.empty")
                    }
                    ForEach(files) { file in
                        NavigationLink { OrbFileViewer(ref: file, scope: scope) } label: { row(file) }
                            .accessibilityIdentifier("files.row.\(file.name)")
                    }
                }
                if workspace {
                    Section {
                        NavigationLink { OrbWorkspaceBrowser(scope: scope, path: "") } label: {
                            Label("Browse workspace", systemImage: "folder")
                        }
                        .accessibilityIdentifier("files.workspace")
                    } header: { Text("Workspace") } footer: { Text("Read-only view of the mission’s files, wherever it runs.") }
                }
                ForEach([false, true], id: \.self) { later in
                    let group = sessions.filter { $0.later == later }
                    if !group.isEmpty {
                        Section(later ? "Later sessions" : "Earlier sessions") {
                            ForEach(group) { session in
                                NavigationLink {
                                    OrbWorkspaceBrowser(scope: .init(missionID: scope.missionID, workspaceID: scope.workspaceID, source: session.id), path: "", title: session.label)
                                } label: { Label(session.label, systemImage: "clock.arrow.circlepath").lineLimit(1).truncationMode(.middle) }
                                .accessibilityIdentifier("files.session.\(session.id)")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityIdentifier("files.done") } }
            .refreshable { await load() }
            .task { await load() }
        }
        .accessibilityIdentifier("files.sheet")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let roots = try? OrbFileService.shared.roots(scope)
        do { files = try await OrbFileService.shared.sharedFiles(scope); error = nil }
        catch { self.error = (error as? OrbFileError)?.errorDescription ?? error.localizedDescription }
        let found = await roots
        workspace = found?.workspace ?? false
        sessions = found?.sessions ?? []
    }

    private func row(_ file: OrbFileRef) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind.symbol).foregroundStyle(OrbStyle.textSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.label).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text([file.label == file.name ? nil : file.name, OrbFileRefs.formatSize(file.size), file.sharedAt.map { OrbStyle.relativeTime($0) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(OrbStyle.textMuted).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

struct OrbWorkspaceBrowser: View {
    let scope: OrbFileService.Scope
    let path: String
    var title: String? = nil
    @State private var entries: [OrbWorkspaceEntry] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { OrbNotice(message: error) }
            if loading && entries.isEmpty { HStack { ProgressView(); Text("Loading…").foregroundStyle(OrbStyle.textSecondary) } }
            if !loading && error == nil && entries.isEmpty { Text("This folder is empty.").foregroundStyle(OrbStyle.textSecondary) }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink { OrbWorkspaceBrowser(scope: scope, path: entry.path, title: nil) } label: { Label(entry.name, systemImage: "folder") }
                } else {
                    let ref = OrbFileRef(type: "file", path: entry.path, label: entry.name, size: entry.size)
                    NavigationLink { OrbFileViewer(ref: ref, scope: scope) } label: {
                        HStack {
                            Label(entry.name, systemImage: ref.kind.symbol).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let size = OrbFileRefs.formatSize(entry.size) { Text(size).font(.caption).foregroundStyle(OrbStyle.textMuted) }
                        }
                    }
                    .accessibilityIdentifier("workspace.row.\(entry.name)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle(path.isEmpty ? (title ?? "Workspace") : OrbFileRefs.fileName(path))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { entries = try await OrbFileService.shared.list(scope, path: path); error = nil }
        catch { self.error = (error as? OrbFileError)?.errorDescription ?? error.localizedDescription }
    }
}

extension View {
    /// A 1 pt marker naming the rendered preview kind (UI tests); the content keeps its own elements.
    func orbA11yContainer(_ id: String) -> some View {
        overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Preview")
                .accessibilityIdentifier(id)
        }
    }
}
