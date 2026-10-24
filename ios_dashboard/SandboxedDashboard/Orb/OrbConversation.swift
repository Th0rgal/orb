import SwiftUI
import UIKit
import AVFoundation

struct OrbConversation: View {
    let missionID: String?
    let project: String
    let folder: String
    @State var id: String?
    @State var loading = true
    @State var visibleCount = 20
    @State var scroller = OrbTranscriptScroller()
    /// Events and everything derived from them (work fold, changed files, open questions, history).
    @State var transcript = OrbTranscriptModel()
    @State var mission: OrbJSON = .null
    @State var execution: OrbJSON = .null
    @State var text = ""
    @State var dictation = OrbDictation()
    @State var error = ""
    @State var busy = false
    /// Follow-ups tapped while a send was in flight, posted once it settles (never dropped).
    @State var deferredSends: [(id: String, content: String)] = []
    /// The send being acknowledged: deferred follow-ups wait only for its POST, not for its refresh.
    @State var awaitingAck = false
    @State var draining = false
    /// When this device last started a turn (idle send), for the Working clock.
    @State var localTurnStart: Date?
    @State var unavailable = false
    @State var selection = OrbSelection()
    @State var showSelection = false
    @State var showContext = false
    @State var rename = false
    @State var moving = false
    @State var destinationProject = ""
    @State var destinationFolder = ""
    @State var title = ""
    @State var attachments: [OrbAttachment] = []
    @State var preview: OrbPreviewFile?
    @State var queued: [OrbJSON] = []
    /// Core's follow-up queue merged with optimistic sends/edits (OrbSendFlow.swift).
    @State var followUps = OrbFollowUpQueue()
    /// Queued follow-up being edited in the composer (edit in place on send).
    @State var editingQueuedID: String?
    /// Send now in flight: one continuous Sending… → Working… state, Stop kept.
    @State var handoff: OrbHandoff?
    @State var handoffTracker = OrbHandoffTracker()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var mode = "Message"
    @State var refreshing = false
    /// An event arrived while a refresh was running; run once more after it.
    @State var refreshAgain = false
    @State var streamToken = UUID()
    @State var lastRefresh = Date.distantPast
    @State var stream: Task<Void, Never>?
    @State var draftSaveTask: Task<Void, Never>?
    @State var eventRefreshTask: Task<Void, Never>?
    @State var optimisticPrompt: String?
    @State var liveText = ""
    @State var answered: Set<String> = []
    @State var expandedLogIDs: Set<String> = []
    @State var expandedUserMessageIDs: Set<String> = []
    @State var queueExpanded = true
    @State var contextItems: [OrbContextItem] = []
    @State var contextBrowseFolder = ""
    @State var dismissedAtToken: String?
    @State var forking = false
    @State var cloning = false
    @State var forkedMission: String?
    @State var sideQuestion: OrbSideQuestionRequest?
    /// Shared file being previewed from a chip, and the Files tab.
    @State var fileRef: OrbFileRef?
    @State var showFiles = false
    @FocusState var composerFocused: Bool
    @Environment(\.scenePhase) var phase
    let api = OrbCore.shared
    var fileScope: OrbFileService.Scope {
        OrbFileService.Scope(missionID: id, workspaceID: mission["workspace_id"].text.isEmpty ? nil : mission["workspace_id"].text)
    }
    var draftKey: String { "draft:\(missionID ?? "new:\(project):\(folder)")" }
    var pendingKey: String { draftKey + ":pending" }
    var turns: [OrbJSON] { execution["turns"].items }
    var isCloud: Bool { execution != .null || !mission["cloud"]["provider"].text.isEmpty || (id == nil && selection.cloud) }
    /// Core stores trimmed text, so a reply echoed back may differ from the
    /// draft only by surrounding whitespace.
    static func sameMessage(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let workingPhases: Set<String> = ["queued", "submitting", "running", "cancel_requested"]
    static let goalHarnesses: Set<String> = ["antigravity", "claudecode", "codex", "grok", "opencode"]
    var supportsMode: Bool { !isCloud && (selection.backend.isEmpty || Self.goalHarnesses.contains(selection.backend)) }
    var handoffActive: Bool { OrbHandoff.pending(status: mission["status"].text, handoff: handoff) }
    var working: Bool { optimisticPrompt != nil || handoffActive || (isCloud ? turns.contains { Self.workingPhases.contains($0["phase"].text) } : (MissionState(rawValue: mission["status"].text)?.isActive ?? false)) }

    /// Derived transcript state lives in `transcript` (OrbTranscriptModel); these keep the
    /// screen's call sites unchanged.
    var events: [StoredEvent] { get { transcript.events } nonmutating set { transcript.events = newValue } }
    var workModel: OrbWorkModel { transcript.workModel }
    var changedFiles: [OrbTurnSummary.FileChange] { transcript.changedFiles }
    var openQuestions: [OrbPendingQuestion] { transcript.openQuestions }
    var history: [(String, String, String)] { transcript.history }

    func rebuildWorkModel() { transcript.rebuildDerived(working: working) }

    func rebuildHistory() {
        let grew = transcript.rebuildHistory(isCloud: isCloud, turns: turns, mission: mission, optimisticPrompt: optimisticPrompt)
        if !scroller.pinned && grew > 0 && transcript.history.count - grew >= visibleCount { visibleCount += grew }
    }

    static func computeHistory(isCloud: Bool, turns: [OrbJSON], mission: OrbJSON, events: [StoredEvent], optimisticPrompt: String?) -> [(String, String, String)] {
        OrbTranscriptModel.computeHistory(isCloud: isCloud, turns: turns, mission: mission, events: events, optimisticPrompt: optimisticPrompt)
    }

    /// Live text minus what stored history already holds (no doubled reply after a reload).
    var visibleLiveText: String {
        OrbSendFlow.dedupeLiveText(liveText, stored: history.filter { $0.1 == "assistant" }.map(\.2))
    }

    func baseStepLabel() -> String {
        let turn = turns.first { Self.workingPhases.contains($0["phase"].text) }
        let provider = ["cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot", "hermes": "Hermes"][execution["selection"]["provider"].text] ?? "the service"
        if let turn {
            switch turn["phase"].text {
            case "cancel_requested": return "Stopping…"
            case "queued": return "Queued…"
            case "submitting": return turn["detail"].text.isEmpty ? "Opening \(provider)…" : turn["detail"].text
            default: return !turn["result"].text.isEmpty ? "Writing…" : (turn["detail"].text.isEmpty ? "Thinking…" : turn["detail"].text)
            }
        }
        if handoffActive { return "Sending…" }
        return !liveText.isEmpty ? "Writing…" : "Working…"
    }

    /// Same wording as the desktop: the step, then how long the turn has been running.
    func progress(at now: Date) -> String {
        let headline = workModel.liveHeadline(fallback: baseStepLabel())
        let label = headline.detail.isEmpty ? headline.action : "\(headline.action) \(headline.detail)"
        return "\(label) · \(elapsedClock(at: now))"
    }

    /// Turn start from Core (latest delivered user message), so reopening the app
    /// does not restart a long turn at 0:00; Orb's own clock only as a fallback.
    func elapsedClock(at now: Date) -> String {
        let turn = turns.first { Self.workingPhases.contains($0["phase"].text) }
        let key = turn?["key"].text ?? "local:\(id ?? "")"
        let serverStart = isCloud ? nil : OrbSendFlow.turnStart(server: OrbTurnSummary.turnStart(events), localSend: localTurnStart)
        let started = serverStart.map { min($0, now) } ?? OrbWorkClock.start(key)
        return OrbTurnSummary.clock(Int(now.timeIntervalSince(started)))
    }

    /// Sends a canned reply through the normal, idempotent send path; the typed draft is restored after.
    func sendReply(_ reply: String) async -> Bool {
        if let pending = OrbDisk.read(pendingKey, as: OrbPending.self), pending.body["content"].text != reply {
            error = "Another message is still being confirmed. Send it first."
            return false
        }
        let draft = text; text = reply
        let sent = await send()
        text = draft
        return sent
    }

    var cloudBlocked: Bool { isCloud && turns.contains { ["submission_uncertain", "incompatible", "reconnect_required"].contains($0["phase"].text) } }
    var status: String { (turns.last?["phase"].text ?? mission["status"].text).replacingOccurrences(of: "_", with: " ") }
    var lastUserItemID: String? {
        history.last(where: { $0.1 == "user" })?.0
    }
    var resolvedNavigationTitle: String {
        let raw = mission["title"].text
        if !raw.isEmpty { return OrbStyle.displayTitle(raw) }
        return missionID == nil ? "New agent" : "Conversation"
    }

    var effectiveProjectSlug: String {
        let mProj = mission["project"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mProj.isEmpty { return mProj }
        return project.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { scroll in
            conversationContainer(scroll: scroll)
                .background(OrbStyle.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(resolvedNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(OrbStyle.background.opacity(0.92), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                // The project list's search field lives in the bottom toolbar; hiding it here
                // makes UIKit slide it out with the push instead of drawing over the composer.
                .toolbarVisibility(.hidden, for: .bottomBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        conversationToolbarMenu
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !unavailable {
                        composer
                            .padding(.top, 4)
                            .background(OrbStyle.background.ignoresSafeArea(edges: .bottom))
                    }
                }
                .environment(\.orbFiles, OrbFileContext(scope: fileScope, shared: transcript.sharedFiles) { fileRef = $0 })
                .sheet(item: $fileRef) { OrbFileViewerSheet(ref: $0, scope: fileScope) }
                .sheet(isPresented: $showFiles) { OrbFilesSheet(scope: fileScope) }
                .sheet(item: $preview) { OrbPreviewSheet(file: $0) }
                .sheet(isPresented: $showSelection) { OrbAgentPicker(selection: $selection, existing: id != nil) }
                .sheet(isPresented: $showContext) { NavigationStack { OrbDocuments(project: effectiveProjectSlug, path: "").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showContext = false } } } } }
                .alert("Rename conversation", isPresented: $rename) { TextField("Title", text: $title); Button("Save") { Task { await mutate(["title": .string(title)]) } }; Button("Cancel", role: .cancel) {} }
                .sheet(isPresented: $moving) { moveConversationSheet }
                .sheet(isPresented: $forking) { OrbForkSheet(mission: mission) { forkedMission = $0["id"].text } }
                .sheet(item: $sideQuestion) { OrbSideQuestionSheet(parentID: $0.parent, question: $0.question) }
                // Warm the /btw history so the side sheet opens on it, not on a spinner.
                .task(id: id) {
                    guard let id, !id.isEmpty else { return }
                    try? await Task.sleep(for: .seconds(1))
                    try? await OrbBtwStore.shared(id).refresh()
                }
                .confirmationDialog("Clone conversation", isPresented: $cloning, titleVisibility: .visible) { cloneActions }
                .navigationDestination(item: $forkedMission) { OrbConversation(missionID: $0, project: effectiveProjectSlug, folder: OrbRow(mission).folder) }
                .task {
                    if let missionID { OrbOnScreen.opened(missionID) }
                    id = missionID
                    // Never overwrite what the user already typed while the screen opened.
                    if text.isEmpty { text = OrbDisk.read(draftKey, as: String.self) ?? "" }
                    attachments = OrbDisk.read(draftKey + ":files", as: [OrbAttachment].self) ?? []
                    if let pending = OrbDisk.read(pendingKey, as: OrbPending.self) {
                        if OrbSendsInFlight.keys.contains(pendingKey) {
                            // Sent from an earlier visit and still awaiting Core: show it as
                            // working, not as a failed send, and settle when it returns.
                            optimisticPrompt = pending.body["content"].text.isEmpty ? pending.body["prompt"].text : pending.body["content"].text
                            Task { await settleInFlightSend() }
                        } else {
                            error = "An earlier send needs verification. Retry sends the same request without creating a new identity."
                        }
                    }
                    if let id {
                        mission = OrbReadCache.read("mission:\(id)") ?? .null
                        execution = OrbReadCache.read("cloud:\(id)") ?? .null
                        let cachedEvents = OrbReadCache.readEvents(id)
                        if !cachedEvents.isEmpty {
                            events = cachedEvents
                            rebuildWorkModel()
                        }
                        rebuildHistory()
                        scrollToBottomOnOpen(scroll: scroll)
                        if execution != .null { selection.restore(execution["selection"]) }
                        else if mission != .null {
                            selection.backend = mission["backend"].text
                            selection.node = mission["remote_node_id"].text
                            selection.model = mission["model_override"].text
                            selection.serviceTier = OrbCodexSpeed.of(mission)
                        }
                        if mission != .null { loading = false }
                        let ts = mission["last_output_at"].text.isEmpty ? mission["updated_at"].text : mission["last_output_at"].text
                        OrbMissionUnreadStore.shared.markRead(id: id, updatedAt: ts.isEmpty ? nil : ts, status: mission["status"].text, hasInteraction: !pendingQuestionEvents.isEmpty)
                    } else if !selection.cloud && selection.node.isEmpty {
                        if let cached = OrbReadCache.read("catalog:agent") {
                            selection.node = OrbSelection.firstAvailableNodeID(cached["nodes"]["nodes"].items) ?? "core"
                        }
                        if let catalog = try? await OrbReadCache.agentCatalog(), !selection.cloud && (selection.node.isEmpty || selection.node == "core") {
                            selection.node = OrbSelection.firstAvailableNodeID(catalog["nodes"]["nodes"].items) ?? "core"
                        }
                    }
                    let targetProject = effectiveProjectSlug
                    if !targetProject.isEmpty {
                        Task {
                            contextItems = await OrbContextTagging.loadItems(for: targetProject)
                        }
                    }
                    await refresh()
                    scrollToBottomOnOpen(scroll: scroll)
                    // Off the open path: building web views before the first frame delayed the composer.
                    OrbWebViewPool.shared.warmUp(count: 2)
                    if contextItems.isEmpty && !effectiveProjectSlug.isEmpty {
                        contextItems = await OrbContextTagging.loadItems(for: effectiveProjectSlug)
                    }
                    if let id {
                        let ts = mission["last_output_at"].text.isEmpty ? mission["updated_at"].text : mission["last_output_at"].text
                        OrbMissionUnreadStore.shared.markRead(id: id, updatedAt: ts.isEmpty ? nil : ts, status: mission["status"].text, hasInteraction: !pendingQuestionEvents.isEmpty)
                    }
                    // When SSE stream is connected for local/remote agents, poll lightly (12s);
                    // for cloud turns without SSE, poll every 3s while working.
                    await Poller.run(every: { (stream != nil && !isCloud) ? .seconds(12) : .seconds(3) }, immediately: false,
                                     while: { phase == .active && (working || isCloud) }) {
                        await refresh(force: working)
                        return true
                    }
                }
                .onChange(of: text) { _, value in
                    // Absorb typed `/goal ` or `/plan ` prefix into the mode pill when supported.
                    if supportsMode && mode == "Message" {
                        if value == "/goal " { mode = "Goal"; text = ""; return }
                        if value == "/plan " { mode = "Plan"; text = ""; return }
                    }
                    if let active = OrbContextTagging.activeAtQuery(value) {
                        if dismissedAtToken != active.query {
                            dismissedAtToken = nil
                        }
                        if !active.query.hasSuffix("/") {
                            contextBrowseFolder = ""
                        }
                    } else {
                        dismissedAtToken = nil
                        contextBrowseFolder = ""
                    }
                    let key = draftKey
                    draftSaveTask?.cancel()
                    draftSaveTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        OrbDisk.saveAsync(value, key: key)
                    }
                }
                .onChange(of: attachments) { _, value in
                    OrbDisk.saveAsync(value, key: draftKey + ":files")
                }
                .onDisappear {
                    if let missionID { OrbOnScreen.closed(missionID) }
                    dictation.cancel()
                    draftSaveTask?.cancel()
                    eventRefreshTask?.cancel()
                    if !text.isEmpty { OrbDisk.saveAsync(text, key: draftKey) }
                    stream?.cancel(); stream = nil
                }
                .onChange(of: missionID) { _, _ in dictation.cancel() }
                .onChange(of: api.endpoint) { _, _ in dictation.cancel() }
                .onReceive(OrbDictation.audioNotifications(AVAudioSession.interruptionNotification)) { notification in
                    if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                       type == AVAudioSession.InterruptionType.began.rawValue { dictation.cancel() }
                }
                .onReceive(OrbDictation.audioNotifications(AVAudioSession.routeChangeNotification)) { notification in
                    if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                       reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { dictation.cancel() }
                }
                .onChange(of: phase) { _, value in
                    if value == .active { Task { await refresh(force: true) } }
                    else {
                        if value == .background || dictation.phase != .permission { dictation.cancel() }
                        stream?.cancel(); stream = nil
                    }
                }
        }
    }

    func scrollToBottomOnOpen(scroll: ScrollViewProxy) {
        guard !history.isEmpty else { return }
        scroller.scrollToBottom()
    }

    @ViewBuilder
    func conversationContainer(scroll: ScrollViewProxy) -> some View {
        OrbTranscriptScrollView(identifier: "conversation", scroller: scroller, working: working, onDoubleTap: composerFocused ? { composerFocused = false } : nil) {
            VStack(alignment: .leading, spacing: 14) {
                if unavailable {
                    ContentUnavailableView("Available on your Mac", systemImage: "laptopcomputer", description: Text("This conversation runs locally in Orb and cannot be controlled from iOS."))
                } else {
                    conversationContent(scroll: scroll)
                }
                if !error.isEmpty { OrbNotice(message: error) }
                Color.clear.frame(height: 1).id("conversation-bottom").accessibilityIdentifier("conversation-bottom")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: working) { _, now in
            if !now { OrbWorkClock.stop("local:\(id ?? "")") }
            rebuildWorkModel()
        }
        .onChange(of: history.last?.0) { _, _ in
            if scroller.pinned { scroller.scrollToBottom() }
        }
        .onChange(of: composerFocused) { _, focused in
            // The keyboard covers the transcript: keep the latest message visible, like Messages.
            if focused && scroller.metrics.distanceFromBottom <= OrbTranscriptScroller.pillThreshold { scroller.scrollToBottom(animated: true) }
        }
    }

}
