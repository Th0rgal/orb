import SwiftUI
import UIKit
import AVFoundation

extension OrbConversation {
    var conversationToolbarMenu: some View {
        let currentStatus = mission["status"].text
        let state = MissionState(rawValue: currentStatus)
        return OrbConversationMenu(
            hasMission: id != nil && !unavailable,
            agentLabel: selection.label,
            status: status.capitalized,
            canReopen: state?.canReopen == true,
            reopenTitle: currentStatus == "acknowledged" ? "Restore" : "Reopen",
            canArchive: currentStatus != "acknowledged",
            working: working,
            canStop: working && (!isCloud || selection.canCancel),
            externalURL: safeURL(execution["external_url"].text),
            local: !isCloud,
            hasProject: !effectiveProjectSlug.isEmpty
        ) { action in
            switch action {
            case .rename: title = mission["title"].text; rename = true
            case .move: destinationProject = mission["project"].text; destinationFolder = OrbRow(mission).folder; moving = true
            case .reopen: Task { await mutate(["status": .string("paused")]) }
            case .archive: Task { await mutate(["status": .string("acknowledged")]) }
            case .stop: Task { await cancel() }
            case .sideQuestion: sideQuestion = OrbSideQuestionRequest(parent: id ?? "", question: "")
            case .fork: forking = true
            case .clone: cloning = true
            case .context: showContext = true
            }
        }
        .equatable()
    }

    @ViewBuilder var cloneActions: some View {
        Button("Clone settings (fresh start)") { Task { await clone(messages: false) } }
        Button("Clone with conversation history") { Task { await clone(messages: true) } }
        Button("Cancel", role: .cancel) {}
    }

    func clone(messages: Bool) async {
        guard let id else { return }
        do {
            let cloned = try await api.call("/api/control/missions/\(OrbCore.escape(id))/clone", method: "POST", body: .object(["clone_messages": .bool(messages)]))
            OrbHaptics.success()
            forkedMission = cloned["id"].text
        } catch { self.error = error.localizedDescription }
    }

    var moveConversationSheet: some View {
        OrbMoveSheet(project: $destinationProject, folder: $destinationFolder, error: error,
                     onCancel: { moving = false }, onMove: { Task { await move() } })
    }

}
