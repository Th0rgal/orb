import SwiftUI

struct OrbDocuments: View {
    let project: String
    let path: String
    @State private var entries: [OrbJSON] = []
    @State private var loading = true
    @State private var error = ""
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
                if entry["kind"].text == "dir" || entry["is_dir"].flag || entry["is_directory"].flag || entry["type"].text == "directory" {
                    NavigationLink { OrbDocuments(project: project, path: child) } label: { Label(name, systemImage: "folder") }
                } else {
                    NavigationLink { OrbDocument(project: project, path: child) } label: { Label(name, systemImage: "doc.text") }
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(OrbStyle.background).navigationBarTitleDisplayMode(.inline).navigationTitle(path.isEmpty ? "Project context" : path.components(separatedBy: "/").last ?? path)
        .task {
            let cacheKey = "docs:\(project):\(path)"
            if let cached = OrbReadCache.read(cacheKey) {
                entries = cached["entries"].items
                loading = false
            }
            defer { loading = false }
            do {
                let fresh = try await OrbCore.shared.call("/api/projects/\(OrbCore.escape(project))/files?path=\(OrbCore.escape(path))")
                entries = fresh["entries"].items
                OrbReadCache.seed(cacheKey, value: fresh)
            } catch {
                if entries.isEmpty { self.error = error.localizedDescription }
            }
        }
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
