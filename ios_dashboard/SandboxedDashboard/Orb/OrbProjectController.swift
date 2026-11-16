import Foundation
import SwiftUI

/// Project concurrency is independent of the controller mission.
enum OrbProjectGrant {
    static let noProjectLimit = 0
    static func projectLimitOf(_ grant: OrbJSON?) -> Int? {
        guard let grant, let n = grant["parallel_missions"].number.map(Int.init), n > 0 else {
            return nil
        }
        return n
    }

    static func parseProjectLimit(_ raw: String) -> Result<Int, OrbHTTPError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(noProjectLimit) }
        guard trimmed.allSatisfy(\.isNumber), let n = Int(trimmed), n >= 1 else {
            return .failure(OrbHTTPError(status: 0, detail: "Enter 1 or more, or leave empty for no limit."))
        }
        return .success(n)
    }

}

struct OrbProjectConcurrencyView: View {
    let project: OrbRow
    @State private var grant: OrbJSON?
    @State private var limitDraft = ""
    @State private var limitDirty = false
    @State private var limitSaving = false
    @State private var limitSaved = false
    @State private var error: String?
    private var slug: String { project.id }
    private let api = OrbCore.shared

    var body: some View {
        List {
            if let error { OrbNotice(message: error) }
            grantSections
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle("Project concurrency")
        .task { await loadGrant() }
        .refreshable { await loadGrant() }
    }

    @ViewBuilder
    private var grantSections: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent limit").font(.subheadline)
                    Text("Maximum unfinished missions in \(project.name). Empty for no limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                TextField("No limit", text: Binding(
                    get: { limitDraft },
                    set: { limitDraft = $0; limitDirty = true; limitSaved = false }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
            }
            Button(limitSaving ? "Saving…" : "Save agent limit") {
                Task { await saveProjectLimit() }
            }
            .disabled(limitSaving || !limitDirty)
            if limitSaved {
                Text("Saved.").font(.footnote).foregroundStyle(OrbStyle.success)
            }
        } header: {
            Text("Project concurrency")
        }

        let readOnlyPairs: [(String, String)] = [
            ("Autonomy level", grant?["autonomy_level"].text ?? ""),
            ("Merge authority", grant?["merge_authority"].text ?? ""),
            ("Budget per run", grant?["budget_per_tick"].text ?? ""),
            ("Material bar", grant?["material_bar"].text ?? ""),
            ("Pause reason", grant?["pause_reason"].text ?? ""),
            ("Resume condition", grant?["resume_condition"].text ?? "")
        ].filter { !$0.1.isEmpty }

        if !readOnlyPairs.isEmpty {
            Section("Standing authority") {
                ForEach(readOnlyPairs, id: \.0) { label, value in
                    LabeledContent(label, value: value)
                }
            }
        }
    }

    private func loadGrant() async {
        guard let raw = try? await api.call("/api/projects/\(OrbCore.escape(slug))/grant") else { return }
        let g = raw["grant"]
        grant = g
        if !limitDirty {
            limitDraft = OrbProjectGrant.projectLimitOf(g).map(String.init) ?? ""
        }
    }

    private func saveProjectLimit() async {
        switch OrbProjectGrant.parseProjectLimit(limitDraft) {
        case .failure(let err):
            self.error = err.localizedDescription
        case .success(let value):
            limitSaving = true
            defer { limitSaving = false }
            do {
                let res = try await api.call(
                    "/api/projects/\(OrbCore.escape(slug))/grant",
                    method: "POST",
                    body: .object(["parallel_missions": .number(Double(value))])
                )
                grant = res["grant"]
                limitDraft = OrbProjectGrant.projectLimitOf(grant).map(String.init) ?? ""
                limitDirty = false
                limitSaved = true
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}


/// Both optional project fields and the board response tolerate older Core versions.
struct OrbProjectBoard: Equatable {
    let text: String?
    let updatedAt: String?
    let updatedByMissionID: String?
    let controllerMissionID: String?
    let boardUpdatedAt: String?

    init(_ raw: OrbJSON) {
        func string(_ key: String) -> String? {
            guard case .string(let value) = raw[key] else { return nil }
            return value
        }
        text = string("text")
        updatedAt = string("updated_at")
        updatedByMissionID = string("updated_by_mission_id")
        controllerMissionID = string("controller_mission_id")
        boardUpdatedAt = string("board_updated_at")
    }
}

struct OrbMissionBoardSummary: Equatable, Identifiable {
    let id: String
    let title: String
    let status: String
    let parentMissionID: String?
    let updatedAt: String
    let bytes: Int
    let textSha256: String
    init(_ raw: OrbJSON) {
        id = raw["mission_id"].text
        title = raw["title"].text
        status = raw["status"].text
        parentMissionID = raw["parent_mission_id"].text.isEmpty ? nil : raw["parent_mission_id"].text
        updatedAt = raw["updated_at"].text
        bytes = Int(raw["bytes"].doubleValue ?? 0)
        textSha256 = raw["text_sha256"].text
    }
}

enum OrbMissionBoardProjection {
    static func summaries(_ raw: OrbJSON, placement: [String: UInt64] = [:], currentMissionIDs: Set<String>? = nil) -> [OrbMissionBoardSummary] {
        raw["boards"].items.map(OrbMissionBoardSummary.init)
            .filter { !$0.id.isEmpty && placement[$0.id] == nil && (currentMissionIDs == nil || currentMissionIDs!.contains($0.id)) }
            .sorted { lhs, rhs in lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt }
    }
    static func shouldShowEntry(_ board: OrbProjectBoard) -> Bool { !(board.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static func accepts(_ response: OrbJSON, missionID: String, project: String, expectedRevision: UInt64, currentProject: String, currentRevision: UInt64) -> Bool {
        response["mission_id"].text == missionID && project == currentProject && expectedRevision == currentRevision
    }
}

struct OrbMissionBoardView: View {
    let missionID: String
    let title: String
    let project: String
    let expectedRevision: UInt64
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var updatedAt: String?
    @State private var error: String?
    private let api = OrbCore.shared
    var body: some View {
        NavigationStack {
            Group {
                if let error { OrbNotice(message: error) }
                else if text.isEmpty { ProgressView() }
                else { ScrollView { Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() } }
            }
            .navigationTitle(title.isEmpty ? "Mission board" : title)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                do {
                    let raw = try await api.call("/api/control/missions/\(OrbCore.escape(missionID))/board")
                    let current = OrbHierarchy.placement(of: missionID)
                    guard OrbMissionBoardProjection.accepts(raw, missionID: missionID, project: project, expectedRevision: expectedRevision, currentProject: current?.project ?? project, currentRevision: current?.revision ?? expectedRevision) else { return }
                    text = raw["text"].text; updatedAt = raw["updated_at"].text
                } catch let failure as OrbHTTPError where failure.status == 404 { text = "" }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct OrbMissionBoardsSection: View {
    let project: OrbRow
    let missions: [OrbRow]
    let refreshID: Int
    @State private var boards: [OrbMissionBoardSummary] = []
    @State private var selected: OrbMissionBoardSummary?
    @State private var error: String?
    private let api = OrbCore.shared
    var body: some View {
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mission boards").font(.headline)
                ForEach(boards) { board in
                    Button { selected = board } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(board.title.isEmpty ? board.id : board.title); Text("\(board.status) · \(board.bytes) bytes").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(board.updatedAt).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 12)
        } else if let error { OrbNotice(message: error) }
        else { EmptyView() }
        .sheet(item: $selected) { board in
            let mission = missions.first { $0.id == board.id }
            OrbMissionBoardView(missionID: board.id, title: board.title, project: project.id, expectedRevision: mission?.placementRevision ?? 0)
        }
        .task(id: refreshID) {
            do { boards = OrbMissionBoardProjection.summaries(try await api.call("/api/projects/\(OrbCore.escape(project.id))/boards"), currentMissionIDs: Set(missions.filter { $0.project == project.id }.map(\.id))) }
            catch let failure as OrbHTTPError where failure.status == 404 { boards = [] }
            catch { error = error.localizedDescription }
        }
    }
}

struct OrbProjectBoardSection: View {
    let project: OrbRow
    let missions: [OrbRow]
    let refreshID: Int
    @State private var controllerMissionID: String?
    @State private var resolvedController: OrbRow?
    @State private var controllerRevision = 0
    @State private var board = OrbProjectBoard(.null)
    @State private var loading = true
    @State private var choosing = false
    @State private var saving = false
    @State private var steerText = ""
    @State private var sending = false
    @State private var error: String?
    private let api = OrbCore.shared
    private var path: String { "/api/projects/\(OrbCore.escape(project.id))" }
    private var controller: OrbRow? { missions.first { $0.id == controllerMissionID } ?? resolvedController }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller").font(.headline)
            if let id = controllerMissionID, !id.isEmpty {
                NavigationLink {
                    OrbConversation(missionID: id, project: project.id, folder: controller?.folder ?? "")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.map { OrbStyle.displayTitle($0.name) } ?? "Controller mission")
                        if let controller { Text(OrbStyle.statusLabel(controller.state)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Text("No controller").foregroundStyle(.secondary)
            }
            HStack {
                Button("Set controller") { choosing = true }
                if controllerMissionID != nil {
                    Button("Clear controller", role: .destructive) { Task { await setController(nil) } }
                }
            }
            .disabled(saving || sending)
            if loading {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Board").font(.headline)
                    Text("Updated date and time").font(.caption)
                    Text("Board text placeholder\nBoard text placeholder\nBoard text placeholder")
                        .font(.system(.footnote, design: .monospaced))
                        .frame(height: 180, alignment: .topLeading)
                }.redacted(reason: .placeholder).accessibilityLabel("Loading Board")
            } else if let text = board.text, !text.isEmpty {
                Text("Board").font(.headline)
                if let updatedAt = board.updatedAt, let date = OrbStyle.parseDate(updatedAt) {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
            Text("Steer").font(.headline)
            TextField("Message the controller", text: $steerText, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder)
                .disabled(controllerMissionID == nil || sending || saving)
            if controllerMissionID == nil {
                Text("Set a controller to send a message.").font(.caption).foregroundStyle(.secondary)
            }
            Button(sending ? "Sending…" : "Send") { Task { await sendSteer() } }
                .disabled(controllerMissionID == nil || steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || saving)
            if let error {
                OrbNotice(message: error)
                Button("Retry") { Task { await load() } }
            }
        }
        .padding(.vertical, 12)
        .task(id: refreshID) { await load() }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                List {
                    if missions.isEmpty { Text("No missions in this project.").foregroundStyle(.secondary) }
                    ForEach(missions.filter { !$0.isPlaceholder }) { mission in
                        Button { choosing = false; Task { await setController(mission.id) } } label: {
                            VStack(alignment: .leading) {
                                Text(OrbStyle.displayTitle(mission.name))
                                Text(OrbStyle.statusLabel(mission.state)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Set controller")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } } }
            }
        }
    }

    private func load() async {
        defer { loading = false }
        let revision = controllerRevision
        error = nil
        do {
            let raw = try await api.call(path)
            if revision == controllerRevision && !saving {
                controllerMissionID = OrbProjectBoard(raw).controllerMissionID
                await resolveController()
            }
        } catch is CancellationError { return }
        catch let failure as OrbHTTPError where failure.status == 404 {
            if revision == controllerRevision && !saving { controllerMissionID = nil; resolvedController = nil }
        }
        catch { self.error = error.localizedDescription }
        do {
            board = OrbProjectBoard(try await api.call("\(path)/board"))
        } catch is CancellationError { return }
        catch let failure as OrbHTTPError where failure.status == 404 { board = OrbProjectBoard(.null) }
        catch { self.error = error.localizedDescription }
    }

    private func resolveController() async {
        resolvedController = nil
        guard let id = controllerMissionID, !missions.contains(where: { $0.id == id }) else { return }
        if let raw = try? await api.call("/api/control/missions/\(OrbCore.escape(id))"), controllerMissionID == id {
            resolvedController = OrbRow(raw)
        }
    }

    private func setController(_ id: String?) async {
        guard !saving, !sending else { return }
        saving = true
        controllerRevision += 1
        defer { saving = false; controllerRevision += 1 }
        do {
            _ = try await api.call("\(path)/controller-mission", method: "PUT", body: .object(["mission_id": id.map(OrbJSON.string) ?? .null]))
            controllerMissionID = id
            await resolveController()
            error = nil
        } catch let failure as OrbHTTPError where failure.status == 404 { }
        catch { self.error = error.localizedDescription }
    }

    private func sendSteer() async {
        guard let id = controllerMissionID, !sending else { return }
        let content = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.sendMissionMessage(missionID: id, content: content)
            steerText = ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
