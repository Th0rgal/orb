import SwiftUI

/// "Move conversation": pick a project from the roster (cached first, then refreshed)
/// and optionally a folder, with that project's existing folders as suggestions.
/// Replaces typing a raw project slug.
struct OrbMoveSheet: View {
    @Binding var project: String
    @Binding var folder: String
    let error: String
    let onCancel: () -> Void
    let onMove: () -> Void

    @State private var projects: [OrbRow] = []
    @State private var folders: [String] = []
    @State private var loading = true
    @State private var loadError = ""
    private let appearance = OrbProjectAppearance.shared

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                if !loadError.isEmpty {
                    Section {
                        OrbNotice(message: loadError)
                        Button("Retry") { Task { await load() } }
                    }
                }
                Section("Project") {
                    if projects.isEmpty && loading {
                        ForEach(0..<3, id: \.self) { idx in
                            HStack(spacing: 12) {
                                OrbListIcon(symbol: "folder")
                                Text(idx.isMultiple(of: 2) ? "Project workspace" : "Project name")
                                    .redacted(reason: .placeholder)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .orbShimmer(active: true)
                            .allowsHitTesting(false)
                        }
                    } else if projects.isEmpty && loadError.isEmpty {
                        Text("No projects available").foregroundStyle(OrbStyle.textSecondary)
                    }
                    ForEach(projects) { row in
                        Button {
                            OrbHaptics.selection()
                            if project != row.id { project = row.id; folder = "" }
                        } label: {
                            HStack(spacing: 12) {
                                OrbListIcon(symbol: "folder", color: appearance.color(row.id))
                                Text(row.name).foregroundStyle(.primary)
                                Spacer()
                                if project == row.id {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(project == row.id ? .isSelected : [])
                        .accessibilityIdentifier("move.project.\(row.id)")
                    }
                }
                Section {
                    TextField("No folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("move.folder")
                    ForEach(folders.filter { $0 != folder }, id: \.self) { name in
                        Button {
                            OrbHaptics.selection()
                            folder = name
                        } label: {
                            Label(name, systemImage: "folder")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Leave empty to keep the conversation at the project's top level.")
                }
            }
            .navigationTitle("Move conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move", action: onMove)
                        .fontWeight(.semibold)
                        .disabled(project.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("move.confirm")
                }
            }
            .task { await load() }
            .onChange(of: project) { _, _ in folders = Self.folders(in: project) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        if projects.isEmpty { loading = true }
        defer { loading = false }
        if let cached = await OrbDisk.readAsync("projects", as: OrbJSON.self) {
            let cachedRows = Self.rows(cached)
            if !cachedRows.isEmpty {
                projects = cachedRows
                loading = false
            }
        }
        folders = Self.folders(in: project)
        do {
            let fresh = try await OrbCore.shared.call("/api/projects")
            guard !Task.isCancelled else { return }
            projects = Self.rows(fresh)
            loadError = ""
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            if projects.isEmpty {
                loadError = error.localizedDescription
            }
        }
    }

    static func rows(_ value: OrbJSON) -> [OrbRow] {
        value["projects"].items
            .filter { !["archived", "deleted"].contains($0["status"].text) }
            .map { OrbRow($0, project: true) }
    }

    /// Folders already used in a project, from the cached mission list.
    static func folders(in project: String) -> [String] {
        guard let missions = OrbDisk.read("inbox:missions", as: OrbJSON.self) else { return [] }
        let names = missions.items.map { OrbRow($0) }.filter { $0.raw["project"].text == project && !$0.folder.isEmpty }.map(\.folder)
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
