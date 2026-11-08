import SwiftUI

enum OrbClaudePermissionMode: String, CaseIterable, Equatable, Sendable {
    case supervised = "supervised"
    case acceptEdits = "acceptEdits"
    case auto = "auto"
    case bypassPermissions = "bypassPermissions"

    var label: String {
        switch self {
        case .supervised: return "Supervised"
        case .acceptEdits: return "Auto-edit"
        case .auto: return "Auto"
        case .bypassPermissions: return "Full access"
        }
    }

    static func parse(_ raw: String?) -> OrbClaudePermissionMode {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
        case "acceptEdits", "accept_edits": return .acceptEdits
        case "auto": return .auto
        case "bypassPermissions", "bypass_permissions", "full": return .bypassPermissions
        default: return .supervised
        }
    }
}

enum OrbWorktreeLaunchMode: String, CaseIterable, Equatable, Sendable {
    case auto = "auto"
    case worktree = "worktree"
    case local = "local"

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .worktree: return "Isolated worktree"
        case .local: return "Local checkout"
        }
    }

    static func parse(_ raw: String?) -> OrbWorktreeLaunchMode {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
        case "worktree": return .worktree
        case "local": return .local
        default: return .auto
        }
    }
}

struct OrbCheckpointMeta: Identifiable, Equatable, Sendable {
    let ref: String
    let oid: String
    let turn: Int

    var id: String { "\(turn)-\(oid)" }

    init(ref: String, oid: String, turn: Int) {
        self.ref = ref
        self.oid = oid
        self.turn = turn
    }

    init(_ json: OrbJSON) {
        self.ref = json["ref"].text
        let rawOid = json["oid"].text
        self.oid = rawOid.isEmpty ? (json["commit_sha"].text.isEmpty ? json["commit"].text : json["commit_sha"].text) : rawOid
        self.turn = Int(json["turn"].doubleValue ?? json["turn_index"].doubleValue ?? 0)
    }
}

struct OrbDiffFileEntry: Identifiable, Equatable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int

    var id: String { path }

    init(path: String, status: String, additions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    init(_ json: OrbJSON) {
        self.path = json["path"].text
        self.status = json["status"].text.isEmpty ? "M" : json["status"].text
        self.additions = Int(json["additions"].doubleValue ?? 0)
        self.deletions = Int(json["deletions"].doubleValue ?? 0)
    }
}

enum OrbDiffLineKind: String, Equatable, Sendable {
    case context
    case add
    case del
}

struct OrbDiffLine: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: OrbDiffLineKind
    let oldLine: Int?
    let newLine: Int?
    let content: String
}

struct OrbDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let lines: [OrbDiffLine]
}

struct OrbParsedFileDiff: Identifiable, Equatable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let binary: Bool
    let hunks: [OrbDiffHunk]

    var id: String { path }
}

enum OrbUnifiedDiffParser {
    private static func parseRangeStart(_ token: Substring) -> Int {
        guard let body = token.dropFirst().split(separator: ",", maxSplits: 1).first,
              let n = Int(body) else { return 1 }
        return n
    }

    static func parse(_ raw: String) -> [OrbParsedFileDiff] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var files: [OrbParsedFileDiff] = []
        var curPath = ""
        var curStatus = "M"
        var curAdd = 0
        var curDel = 0
        var curBinary = false
        var curHunks: [OrbDiffHunk] = []
        var curHunkHeader: String? = nil
        var curHunkLines: [OrbDiffLine] = []
        var oldLine = 1
        var newLine = 1
        var nextLineID = 1

        func flushHunk() {
            if let hdr = curHunkHeader {
                curHunks.append(OrbDiffHunk(id: curHunks.count, header: hdr, lines: curHunkLines))
                curHunkHeader = nil
                curHunkLines = []
            }
        }

        func flushFile() {
            flushHunk()
            if !curPath.isEmpty {
                files.append(OrbParsedFileDiff(
                    path: curPath,
                    status: curStatus,
                    additions: curAdd,
                    deletions: curDel,
                    binary: curBinary,
                    hunks: curHunks
                ))
            }
            curPath = ""
            curStatus = "M"
            curAdd = 0
            curDel = 0
            curBinary = false
            curHunks = []
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                let rest = line.dropFirst("diff --git ".count)
                if let sep = rest.range(of: " b/") {
                    curPath = String(rest[sep.upperBound...])
                } else {
                    let parts = rest.split(separator: " ")
                    curPath = parts.last.map { $0.hasPrefix("b/") ? String($0.dropFirst(2)) : String($0) } ?? "unknown"
                }
                continue
            }
            if curPath.isEmpty { continue }
            if line.hasPrefix("new file mode ") { curStatus = "A"; continue }
            if line.hasPrefix("deleted file mode ") { curStatus = "D"; continue }
            if line.hasPrefix("rename from ") { curStatus = "R"; continue }
            if line.hasPrefix("rename to ") {
                curPath = String(line.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                curBinary = true
                continue
            }
            if line.hasPrefix("@@ ") {
                flushHunk()
                curHunkHeader = line
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = parseRangeStart(parts[1])
                    newLine = parseRangeStart(parts[2])
                } else {
                    oldLine = 1
                    newLine = 1
                }
                continue
            }
            guard curHunkHeader != nil else { continue }
            if line.hasPrefix("\\ No newline at end of file") { continue }
            if line.hasPrefix("+") {
                curAdd += 1
                curHunkLines.append(OrbDiffLine(id: nextLineID, kind: .add, oldLine: nil, newLine: newLine, content: String(line.dropFirst())))
                nextLineID += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                curDel += 1
                curHunkLines.append(OrbDiffLine(id: nextLineID, kind: .del, oldLine: oldLine, newLine: nil, content: String(line.dropFirst())))
                nextLineID += 1
                oldLine += 1
            } else if line.hasPrefix(" ") {
                curHunkLines.append(OrbDiffLine(id: nextLineID, kind: .context, oldLine: oldLine, newLine: newLine, content: String(line.dropFirst())))
                nextLineID += 1
                oldLine += 1
                newLine += 1
            }
        }
        flushFile()
        return files
    }
}

struct OrbChangesSheet: View {
    let missionID: String
    var onRestored: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var checkpoints: [OrbCheckpointMeta] = []
    @State private var fromRef: String = ""
    @State private var files: [OrbDiffFileEntry] = []
    @State private var rawDiff: String = ""
    @State private var parsedFiles: [OrbParsedFileDiff] = []
    @State private var additions = 0
    @State private var deletions = 0
    @State private var truncated = false
    @State private var loading = true
    @State private var error: String?
    @State private var confirmTurn: OrbCheckpointMeta?
    @State private var restoring = false
    @State private var expandedPaths: Set<String> = []

    private var selectedCheckpoint: OrbCheckpointMeta? {
        checkpoints.first { $0.ref == fromRef }
    }

    var body: some View {
        NavigationStack {
            List {
                if !checkpoints.isEmpty {
                    Section("Baseline checkpoint") {
                        Picker("Compare from", selection: $fromRef) {
                            ForEach(checkpoints) { cp in
                                Text(cp.turn == 0 ? "Turn 0 · Baseline (\(String(cp.oid.prefix(7))))" : "Turn \(cp.turn) (\(String(cp.oid.prefix(7))))")
                                    .tag(cp.ref)
                            }
                        }
                        if let cp = selectedCheckpoint {
                            Button(role: .destructive) {
                                confirmTurn = cp
                            } label: {
                                Label("Revert workspace to Turn \(cp.turn)…", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(restoring)
                            .accessibilityIdentifier("changes.revert")
                        }
                    }
                }

                Section {
                    if loading && files.isEmpty && parsedFiles.isEmpty {
                        HStack { ProgressView(); Text("Computing workspace diff…").foregroundStyle(OrbStyle.textSecondary) }
                    } else if let error, files.isEmpty {
                        OrbNotice(message: error)
                    } else if files.isEmpty && parsedFiles.isEmpty {
                        Text("No workspace changes recorded since this checkpoint.")
                            .font(.subheadline)
                            .foregroundStyle(OrbStyle.textSecondary)
                            .accessibilityIdentifier("changes.empty")
                    } else {
                        if truncated {
                            Text("Diff output was capped to stay within the workspace diff budget.")
                                .font(.caption)
                                .foregroundStyle(OrbStyle.warning)
                        }
                        ForEach(parsedFiles.isEmpty ? files.map { OrbParsedFileDiff(path: $0.path, status: $0.status, additions: $0.additions, deletions: $0.deletions, binary: false, hunks: []) } : parsedFiles) { file in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedPaths.contains(file.path) },
                                    set: { open in
                                        if open { expandedPaths.insert(file.path) }
                                        else { expandedPaths.remove(file.path) }
                                    }
                                )
                            ) {
                                if file.binary {
                                    Text("Binary file changed.")
                                        .font(.caption)
                                        .foregroundStyle(OrbStyle.textMuted)
                                } else if file.hunks.isEmpty {
                                    Text("Diff preview omitted for budget.")
                                        .font(.caption)
                                        .foregroundStyle(OrbStyle.textMuted)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(file.hunks) { hunk in
                                                Text(hunk.header)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(OrbStyle.textMuted)
                                                    .padding(.vertical, 2)
                                                ForEach(hunk.lines) { line in
                                                    HStack(spacing: 6) {
                                                        Text(line.kind == .add ? "+" : line.kind == .del ? "-" : " ")
                                                            .foregroundStyle(line.kind == .add ? OrbStyle.success : line.kind == .del ? OrbStyle.error : OrbStyle.textMuted)
                                                        Text(line.content)
                                                            .foregroundStyle(line.kind == .add ? OrbStyle.success : line.kind == .del ? OrbStyle.error : .primary)
                                                    }
                                                    .font(.system(size: 11.5, design: .monospaced))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(
                                                        line.kind == .add ? OrbStyle.success.opacity(0.10) :
                                                        line.kind == .del ? OrbStyle.error.opacity(0.10) : Color.clear
                                                    )
                                                }
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(file.status)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(file.status == "A" ? OrbStyle.success : file.status == "D" ? OrbStyle.error : OrbStyle.textSecondary)
                                        .frame(width: 18)
                                    Text(file.path)
                                        .font(.system(.footnote, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if file.additions > 0 {
                                        Text("+\(file.additions)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(OrbStyle.success)
                                    }
                                    if file.deletions > 0 {
                                        Text("-\(file.deletions)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(OrbStyle.error)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Changed files (\(max(files.count, parsedFiles.count)))")
                        Spacer()
                        if additions > 0 || deletions > 0 {
                            Text("+\(additions)  -\(deletions)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await loadDiff() }
            .task { await loadInitial() }
            .onChange(of: fromRef) { _, _ in
                Task { await loadDiff() }
            }
            .alert(
                "Revert workspace?",
                isPresented: Binding(
                    get: { confirmTurn != nil },
                    set: { if !$0 { confirmTurn = nil } }
                ),
                presenting: confirmTurn
            ) { cp in
                Button("Cancel", role: .cancel) { confirmTurn = nil }
                Button("Revert", role: .destructive) {
                    Task { await restore(cp) }
                }
            } message: { cp in
                Text("Restore the workspace files to Turn \(cp.turn) (\(String(cp.oid.prefix(8)))). An automatic backup checkpoint is saved before restoring.")
            }
        }
        .accessibilityIdentifier("changes.sheet")
    }

    private func loadInitial() async {
        loading = true
        defer { loading = false }
        do {
            let listResp = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(missionID))/checkpoints")
            let loaded = listResp["checkpoints"].items.map(OrbCheckpointMeta.init).sorted { $0.turn < $1.turn }
            checkpoints = loaded
            if fromRef.isEmpty, let first = loaded.first {
                fromRef = first.ref
            }
            await loadDiff()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiff() async {
        loading = true
        defer { loading = false }
        do {
            var path = "/api/control/missions/\(OrbCore.escape(missionID))/checkpoints/diff"
            if !fromRef.isEmpty {
                path += "?from_ref=\(OrbCore.escape(fromRef))"
            }
            let report = try await OrbCore.shared.call(path)
            files = report["files"].items.map(OrbDiffFileEntry.init)
            rawDiff = report["raw_diff"].text
            parsedFiles = OrbUnifiedDiffParser.parse(rawDiff)
            additions = Int(report["total_additions"].doubleValue ?? 0)
            deletions = Int(report["total_deletions"].doubleValue ?? 0)
            truncated = report["truncated"].flag
            if expandedPaths.isEmpty, let first = parsedFiles.first ?? files.first.map({ OrbParsedFileDiff(path: $0.path, status: $0.status, additions: $0.additions, deletions: $0.deletions, binary: false, hunks: []) }) {
                expandedPaths.insert(first.path)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ cp: OrbCheckpointMeta) async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false; confirmTurn = nil }
        do {
            _ = try await OrbCore.shared.call(
                "/api/control/missions/\(OrbCore.escape(missionID))/checkpoints/restore",
                method: "POST",
                body: .object([
                    "ref": .string(cp.ref),
                    "turn": .number(Double(cp.turn))
                ])
            )
            OrbHaptics.success()
            onRestored?()
            await loadInitial()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
