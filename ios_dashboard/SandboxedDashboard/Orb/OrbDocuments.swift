import SwiftUI

struct OrbDocuments: View {
    let project: String
    let path: String
    @State private var entries: [OrbJSON] = []
    @State private var loading = true
    @State private var error = ""
    @State private var creatingFolder = false
    @State private var newFolderParent = ""
    @State private var newFolderName = ""
    @State private var renamingPath: String?
    @State private var renamingIsDir = false
    @State private var renameDraft = ""
    @State private var movingPath: String?
    @State private var movingIsDir = false
    @State private var moveDraft = ""
    @State private var deletingPath: String?
    @State private var deletingIsDir = false
    private let api = OrbCore.shared

    private static func parentDir(_ p: String) -> String {
        guard let idx = p.lastIndex(of: "/") else { return "" }
        return String(p[..<idx])
    }
    private static func baseName(_ p: String) -> String {
        p.split(separator: "/").last.map(String.init) ?? p
    }

    var body: some View {
        List {
            if !error.isEmpty { OrbNotice(message: error) }
            if loading && entries.isEmpty {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        OrbListIcon(symbol: index.isMultiple(of: 2) ? "folder" : "doc.text")
                        Text(index.isMultiple(of: 2) ? "Project context folder" : "README.md")
                            .font(.subheadline)
                            .redacted(reason: .placeholder)
                    }
                    .orbShimmer(active: true)
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                let name = entry["name"].text
                let child = path.isEmpty ? name : "\(path)/\(name)"
                let isDir = entry["kind"].text == "dir" || entry["is_dir"].flag || entry["is_directory"].flag || entry["type"].text == "directory"
                Group {
                    if isDir {
                        NavigationLink { OrbDocuments(project: project, path: child) } label: { Label(name, systemImage: "folder") }
                    } else {
                        NavigationLink { OrbDocument(project: project, path: child) } label: { Label(name, systemImage: "doc.text") }
                    }
                }
                .contextMenu {
                    if isDir {
                        Button {
                            newFolderParent = child
                            newFolderName = ""
                            creatingFolder = true
                        } label: {
                            Label("New subfolder", systemImage: "folder.badge.plus")
                        }
                        Divider()
                    }
                    Button {
                        renameDraft = name
                        renamingIsDir = isDir
                        renamingPath = child
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        moveDraft = Self.parentDir(child)
                        movingIsDir = isDir
                        movingPath = child
                    } label: {
                        Label("Move…", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deletingIsDir = isDir
                        deletingPath = child
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingIsDir = isDir
                        deletingPath = child
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameDraft = name
                        renamingIsDir = isDir
                        renamingPath = child
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(path.isEmpty ? "Project context" : path.components(separatedBy: "/").last ?? path)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderParent = path
                    newFolderName = ""
                    creatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New folder")
            }
        }
        .alert(newFolderParent.isEmpty ? "New folder" : "New subfolder in \(Self.baseName(newFolderParent))", isPresented: $creatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert(renamingIsDir ? "Rename folder" : "Rename file", isPresented: Binding(get: { renamingPath != nil }, set: { if !$0 { renamingPath = nil } })) {
            TextField(renamingIsDir ? "Folder name" : "File name", text: $renameDraft)
            Button("Rename") {
                if let target = renamingPath {
                    Task { await renameItem(target, to: renameDraft) }
                }
            }
            Button("Cancel", role: .cancel) { renamingPath = nil }
        }
        .alert(movingIsDir ? "Move folder" : "Move file", isPresented: Binding(get: { movingPath != nil }, set: { if !$0 { movingPath = nil } })) {
            TextField("Destination folder (empty for root)", text: $moveDraft)
            Button("Move") {
                if let target = movingPath {
                    Task { await moveItem(target, into: moveDraft) }
                }
            }
            Button("Cancel", role: .cancel) { movingPath = nil }
        }
        .alert(deletingIsDir ? "Delete folder?" : "Delete file?", isPresented: Binding(get: { deletingPath != nil }, set: { if !$0 { deletingPath = nil } })) {
            Button("Delete", role: .destructive) {
                if let target = deletingPath {
                    Task { await deleteItem(target) }
                }
            }
            Button("Cancel", role: .cancel) { deletingPath = nil }
        } message: {
            if let target = deletingPath {
                Text(deletingIsDir ? "Delete \"\(target)\" and all contents inside? This cannot be undone." : "Delete \"\(target)\"? This cannot be undone.")
            }
        }
        .task { await reload(initial: true) }
        .refreshable { await reload(initial: false) }
    }

    private func reload(initial: Bool) async {
        let cacheKey = "docs:\(project):\(path)"
        if initial, let cached = OrbReadCache.read(cacheKey) {
            entries = cached["entries"].items
            loading = false
        }
        defer { loading = false }
        do {
            let fresh = try await api.call("/api/projects/\(OrbCore.escape(project))/files?path=\(OrbCore.escape(path))")
            entries = fresh["entries"].items
            OrbReadCache.seed(cacheKey, value: fresh)
            error = ""
        } catch {
            if entries.isEmpty || !initial { self.error = error.localizedDescription }
        }
    }

    private func invalidateProjectCaches() {
        OrbReadCache.invalidate("docs:\(project):\(path)")
        OrbReadCache.invalidate("project:\(project)")
        OrbReadCache.invalidate("project:\(project):all")
    }

    private func createFolder() async {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        let fullPath = newFolderParent.isEmpty ? trimmed : "\(newFolderParent)/\(trimmed)"
        do {
            _ = try await api.call("/api/projects/\(OrbCore.escape(project))/file/mkdir", method: "POST", body: .object(["path": .string(fullPath)]))
            newFolderName = ""
            invalidateProjectCaches()
            await reload(initial: false)
        } catch { self.error = error.localizedDescription }
    }

    private func renameItem(_ itemPath: String, to rawName: String) async {
        let input = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty && !input.contains("/") && !input.contains("\\") else {
            self.error = "Enter a name without slashes."
            return
        }
        let parent = Self.parentDir(itemPath)
        let destination = parent.isEmpty ? input : "\(parent)/\(input)"
        guard destination != itemPath else { return }
        do {
            _ = try await api.call(
                "/api/projects/\(OrbCore.escape(project))/file/transfer",
                method: "POST",
                body: .object(["path": .string(itemPath), "destination": .string(destination), "copy": .bool(false)])
            )
            invalidateProjectCaches()
            await reload(initial: false)
        } catch { self.error = error.localizedDescription }
    }

    private func moveItem(_ itemPath: String, into rawParent: String) async {
        let parent = rawParent.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = Self.baseName(itemPath)
        let destination = parent.isEmpty ? base : "\(parent)/\(base)"
        guard destination != itemPath else { return }
        if destination.hasPrefix(itemPath + "/") {
            self.error = "Cannot move a folder inside itself."
            return
        }
        do {
            _ = try await api.call(
                "/api/projects/\(OrbCore.escape(project))/file/transfer",
                method: "POST",
                body: .object(["path": .string(itemPath), "destination": .string(destination), "copy": .bool(false)])
            )
            invalidateProjectCaches()
            await reload(initial: false)
        } catch { self.error = error.localizedDescription }
    }

    private func deleteItem(_ itemPath: String) async {
        do {
            _ = try await api.call("/api/projects/\(OrbCore.escape(project))/file?path=\(OrbCore.escape(itemPath))", method: "DELETE")
            entries.removeAll { (path.isEmpty ? $0["name"].text : "\(path)/\($0["name"].text)") == itemPath }
            invalidateProjectCaches()
            await reload(initial: false)
        } catch { self.error = error.localizedDescription }
    }
}

struct OrbDocument: View {
    let project: String
    let path: String
    @State private var content = ""
    @State private var revision: OrbJSON = .null
    @State private var editing = false
    @State private var loaded = false
    @State private var error = ""
    @State private var saving = false
    @State private var savedContent = ""
    @State private var draftSaveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool
    private var draftKey: String { "document:\(project):\(path)" }
    var body: some View {
        VStack {
            if !error.isEmpty { OrbNotice(message: error) }
            if !loaded && error.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Document heading placeholder").font(.headline)
                    Text("First paragraph of project context documentation with multiple lines of descriptive content.")
                        .font(.subheadline)
                    Text("Second paragraph placeholder text.")
                        .font(.subheadline)
                }
                .redacted(reason: .placeholder)
                .orbShimmer(active: true)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if editing {
                TextEditor(text: $content).focused($editorFocused).onAppear { editorFocused = true }.scrollContentBackground(.hidden).padding(.horizontal, 12).font(.system(.body, design: .monospaced)).accessibilityIdentifier("document-editor")
            } else {
                ScrollView { OrbRichText(source: content).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.background(OrbStyle.background).navigationBarTitleDisplayMode(.inline).navigationTitle(path.components(separatedBy: "/").last ?? path)
        .toolbar {
            if loaded {
                Button(editing ? "Preview" : "Edit") { editorFocused = false; editing.toggle() }.disabled(revision == .null || !path.lowercased().hasSuffix(".md"))
                if content != savedContent { Button("Save") { Task { await save() } }.disabled(saving) }
                ShareLink(item: content)
            }
        }
        .task {
            let cacheKey = "docfile:\(project):\(path)"
            if let cached = OrbReadCache.read(cacheKey) {
                content = cached["content"].text
                savedContent = content
                revision = cached["revision"]
                loaded = true
            }
            do {
                let value = try await OrbCore.shared.call("/api/projects/\(OrbCore.escape(project))/file?path=\(OrbCore.escape(path))")
                OrbReadCache.seed(cacheKey, value: value)
                content = value["content"].text; savedContent = content; revision = value["revision"]; loaded = true
                if let draft = OrbDisk.read(draftKey, as: OrbJSON.self) {
                    content = draft["content"].text; revision = draft["revision"]; editing = true
                }
            } catch {
                if !loaded { self.error = error.localizedDescription }
            }
        }
        .onChange(of: content) { _, value in
            guard loaded && editing else { return }
            let key = draftKey
            let rev = revision
            draftSaveTask?.cancel()
            draftSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                OrbDisk.saveAsync(OrbJSON.object(["content": .string(value), "revision": rev]), key: key)
            }
        }
        .onDisappear {
            if loaded && editing && content != savedContent {
                draftSaveTask?.cancel()
                OrbDisk.saveAsync(OrbJSON.object(["content": .string(content), "revision": revision]), key: draftKey)
            }
        }
    }
    private func save() async {
        guard !saving && revision != .null else { return }; saving = true; defer { saving = false }
        draftSaveTask?.cancel()
        do {
            let result = try await OrbCore.shared.call("/api/projects/\(OrbCore.escape(project))/file", method: "PUT", body: .object(["path": .string(path), "content": .string(content), "expected_revision": revision]))
            revision = result["revision"]; savedContent = content; OrbDisk.remove(draftKey); editing = false; error = ""
        } catch let failure as OrbHTTPError where failure.status == 409 {
            error = "This document changed elsewhere. Your draft is saved. Copy or share it before reloading the server version."
        } catch { self.error = error.localizedDescription }
    }
}
