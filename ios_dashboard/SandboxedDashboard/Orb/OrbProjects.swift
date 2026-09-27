import SwiftUI

enum OrbStyle {
    static let background = Color(white: 0.073)
    static let surface = Color(white: 0.105)
    static func serviceName(_ value: String) -> String {
        ["claudecode": "Claude Code", "codex": "Codex", "cloud_chatgpt": "ChatGPT", "cloud_cursor": "Cursor Cloud", "cloud_cursor_cloud": "Cursor Cloud", "cloud_grok_bot": "Grok Bot"][value] ?? value
    }
    static let border = Color.white.opacity(0.08)
}
struct OrbNotice: View {
    let message: String
    var body: some View { Text(message).font(.subheadline).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("orb.error") }
}
struct OrbCircle: View {
    let symbol: String
    var body: some View { Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 26, height: 26) }
}

struct OrbHome: View {
    @State private var projects: [OrbRow] = []
    @State private var loading = true
    @State private var error = ""
    @State private var search = ""
    @State private var settings = false
    @State private var creating = false
    @State private var name = ""
    @State private var linkedMission: String?
    @State private var renaming: OrbRow?
    @State private var renamedTitle = ""
    private let api = OrbCore.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !error.isEmpty { OrbNotice(message: error) }
                    ForEach(projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { project in
                        NavigationLink { OrbProjectPage(project: project) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                                Text(project.name).font(.title3).foregroundStyle(.primary)
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }.padding(.vertical, 14).overlay(alignment: .bottom) { Rectangle().fill(OrbStyle.border).frame(height: 0.5).padding(.leading, 42) }
                        }.accessibilityIdentifier("project.\(project.id)")
                        .contextMenu {
                            Button("Rename") { renamedTitle = project.name; renaming = project }
                            Button("Archive") { Task { do { _ = try await api.call("/api/projects/\(OrbCore.escape(project.id))/action", method: "POST", body: .object(["action": .string("archive")])); await load() } catch { self.error = error.localizedDescription } } }
                        }
                    }
                    if loading && projects.isEmpty { ProgressView("Loading projects…").frame(maxWidth: .infinity).padding(.top, 32) }
                    if !loading && projects.isEmpty && error.isEmpty { ContentUnavailableView("Your projects", systemImage: "folder", description: Text("Create a project to start a conversation.")) }
                }.padding(.horizontal, 20)
            }
            .background(OrbStyle.background).navigationTitle("Projects").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settings = true } label: { OrbCircle(symbol: "person.crop.circle") }.accessibilityLabel("Settings") }
                ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { OrbCircle(symbol: "folder.badge.plus") }.accessibilityLabel("New project") }
            }
            .searchable(text: $search, prompt: "Search projects")
            .task { await load() }.refreshable { await load() }
            .sheet(isPresented: $settings) { SetupSheet(onComplete: { settings = false; Task { await load() } }, allowsDismissal: true) }
            .alert("New project", isPresented: $creating) {
                TextField("Project name", text: $name)
                Button("Create") { Task { await create() } }; Button("Cancel", role: .cancel) {}
            }
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renamedTitle)
                Button("Save") { if let project = renaming { Task { do { _ = try await api.call("/api/projects", method: "PUT", body: .object(["slug": .string(project.id), "title": .string(renamedTitle)])); await load() } catch { self.error = error.localizedDescription } } } }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(item: $linkedMission) { OrbConversation(missionID: $0, project: "", folder: "") }
            .onOpenURL { url in
                if ["orb", "sandboxed"].contains(url.scheme ?? ""), url.host == "mission" { linkedMission = url.lastPathComponent }
            }
        }.tint(.primary).preferredColorScheme(.dark)
    }
    private func load() async {
        defer { loading = false }
        if projects.isEmpty, let cached = OrbDisk.read("projects", as: OrbJSON.self) { projects = cached["projects"].items.map { OrbRow($0, project: true) } }
        do {
            let value = try await api.call("/api/projects")
            projects = value["projects"].items.filter { !["archived", "deleted"].contains($0["status"].text) }.map { OrbRow($0, project: true) }
            try OrbDisk.save(value, key: "projects"); error = ""
            // Warm only the first project; never fan out across the entire account.
            if let first = projects.first { Task { _ = try? await OrbReadCache.project(first.id) } }
        } catch { self.error = error.localizedDescription }
    }
    private func create() async {
        let slug = name.folding(options: .diacriticInsensitive, locale: .current).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        guard !slug.isEmpty else { return }
        do { _ = try await api.call("/api/projects", method: "PUT", body: .object(["slug": .string(slug), "title": .string(name)])); name = ""; await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct OrbProjectPage: View {
    let project: OrbRow
    @State private var missions: [OrbRow] = []
    @State private var loading = true
    @State private var folders: [String] = []
    @State private var collapsed: Set<String> = []
    @State private var search = ""
    @State private var filter = "All"
    @State private var error = ""
    @State private var newFolder = false
    @State private var folderName = ""
    private let api = OrbCore.shared
    private var visible: [OrbRow] {
        missions.filter { row in
            (search.isEmpty || row.name.localizedCaseInsensitiveContains(search)) &&
            (filter == "Archived" ? row.state == "acknowledged" : row.state != "acknowledged") &&
            (filter != "Working" || row.active) &&
            (filter != "Needs attention" || ["blocked", "failed", "interrupted"].contains(row.state))
        }
    }
    private var filtering: Bool { !search.isEmpty || filter != "All" }
    private var paths: [String] {
        let sources = (filtering ? [] : folders) + visible.map(\.folder)
        var all = Set(sources)
        for path in sources {
            let parts = path.split(separator: "/")
            for depth in 1...max(1, parts.count) where depth <= parts.count { all.insert(parts.prefix(depth).joined(separator: "/")) }
        }
        return all.filter { !$0.isEmpty }.sorted()
    }
    private func shown(_ folder: String) -> Bool { !search.isEmpty || !collapsed.contains(where: { folder.hasPrefix($0 + "/") }) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filter != "All" {
                    HStack { Text(filter).font(.subheadline); Spacer(); Button("Clear filter") { filter = "All" }.font(.subheadline) }.frame(minHeight: 44)
                }
                if !error.isEmpty { OrbNotice(message: error) }
                if loading && missions.isEmpty { conversationSkeletons }
                ForEach(visible.filter { $0.folder.isEmpty }) { row in missionLink(row) }
                folderRows
                if !loading && visible.isEmpty && (folders.isEmpty || filtering) && error.isEmpty { ContentUnavailableView(filtering ? "No matching conversations" : "No conversations yet", systemImage: "bubble.left.and.bubble.right", description: Text(filtering ? "Try another search or filter." : "Start an agent with the + button.")) }
            }.padding(.horizontal, 20)
        }.background(OrbStyle.background).navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Menu {
                Picker("Show", selection: $filter) { ForEach(["All", "Working", "Needs attention", "Archived"], id: \.self) { Text($0) } }
                Button("New folder") { newFolder = true }
                NavigationLink("Project context") { OrbDocuments(project: project.id, path: "") }
            } label: { OrbCircle(symbol: "ellipsis") }.accessibilityLabel("Project actions") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { OrbConversation(missionID: nil, project: project.id, folder: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New agent").accessibilityIdentifier("new-agent")
            }
        }
        .alert("New folder", isPresented: $newFolder) { TextField("Folder name", text: $folderName); Button("Create") { Task { await mkdir() } }; Button("Cancel", role: .cancel) {} }
        .task { await load() }.refreshable { await load(force: true) }
    }
    private var conversationSkeletons: some View {
        VStack(spacing: 0) {
            ForEach(0..<5) { index in
                HStack(alignment: .top, spacing: 14) {
                    Circle().fill(Color.secondary.opacity(0.25)).frame(width: 8, height: 8).padding(.top, 9)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index.isMultiple(of: 2) ? "Conversation title placeholder" : "Conversation title")
                            .font(.body)
                        Text("Agent · Conversation status").font(.subheadline).foregroundStyle(.secondary)
                    }.redacted(reason: .placeholder)
                    Spacer(minLength: 0)
                }.padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(OrbStyle.border).frame(height: 0.5).padding(.leading, 22) }
            }
        }.allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading conversations")
            .accessibilityIdentifier("conversations-loading")
    }
    private var folderRows: some View {
                ForEach(paths.filter(shown), id: \.self) { folder in
                    HStack {
                        Button { if !collapsed.insert(folder).inserted { collapsed.remove(folder) } } label: {
                            Label(folder.split(separator: "/").last.map(String.init) ?? folder, systemImage: collapsed.contains(folder) ? "chevron.right" : "chevron.down").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("folder.\(folder)")
                        NavigationLink { OrbConversation(missionID: nil, project: project.id, folder: folder) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("New agent in \(folder)")
                    }.padding(.leading, CGFloat(min(36, max(0, folder.split(separator: "/").count - 1) * 12))).padding(.top, 4)
                    if !collapsed.contains(folder) || !search.isEmpty { ForEach(visible.filter { $0.folder == folder }) { row in missionLink(row).padding(.leading, 18) } }
                }
    }
    private func missionLink(_ row: OrbRow) -> some View {
        NavigationLink { OrbConversation(missionID: row.id, project: project.id, folder: row.folder) } label: {
            HStack(alignment: .top, spacing: 14) {
                Circle().fill(row.active ? Color.blue : Color.gray).frame(width: 8, height: 8).padding(.top, 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.body).lineLimit(2).foregroundStyle(.primary)
                    Text("\(OrbStyle.serviceName(row.backend)) · \(row.state.replacingOccurrences(of: "_", with: " "))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }; Spacer(minLength: 0)
            }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(OrbStyle.border).frame(height: 0.5).padding(.leading, 22) }
        }.accessibilityIdentifier("mission.\(row.id)")
    }
    private func apply(_ value: OrbJSON) {
        missions = value["missions"].items.map { OrbRow($0) }.filter(\.mobile)
        if case .object(let entries) = value["manifest"]["entries"] { folders = entries.filter { $0.value["directory"].flag }.map(\.key) }
    }
    private func load(force: Bool = false) async {
        if let cached = OrbReadCache.read("project:\(project.id)") { apply(cached); loading = false }
        defer { loading = false }
        do {
            let value = try await OrbReadCache.project(project.id, force: force)
            guard !Task.isCancelled else { return }
            apply(value); loading = false; error = ""
            await OrbReadCache.prefetch(missions)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func mkdir() async {
        guard !folderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { _ = try await api.call("/api/projects/\(OrbCore.escape(project.id))/file/mkdir", method: "POST", body: .object(["path": .string(folderName)])); folderName = ""; await load(force: true) }
        catch { self.error = error.localizedDescription }
    }
}
