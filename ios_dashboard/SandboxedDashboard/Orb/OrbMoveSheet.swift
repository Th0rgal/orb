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
    private let appearance = OrbProjectAppearance.shared

    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                Section("Project") {
                    if projects.isEmpty && loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if projects.isEmpty {
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
        defer { loading = false }
        if let cached = OrbDisk.read("projects", as: OrbJSON.self) { projects = Self.rows(cached) }
        folders = Self.folders(in: project)
        if let fresh = try? await OrbCore.shared.call("/api/projects") {
            let rows = Self.rows(fresh)
            if !rows.isEmpty { projects = rows }
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
