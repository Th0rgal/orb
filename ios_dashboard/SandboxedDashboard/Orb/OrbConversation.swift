import SwiftUI
import UIKit
import AVFoundation

struct OrbConversation: View {
    let missionID: String?
    let project: String
    let folder: String
    @State private var id: String?
    @State private var loading = true
    @State private var visibleCount = 20
    @State private var followsLatest = true
    @State private var userScrolling = false
    @State private var atBottom = true
    @State private var openedAtLatest = false
    @State private var mission: OrbJSON = .null
    @State private var execution: OrbJSON = .null
    @State private var text = ""
    @State private var dictation = OrbDictation()
    @State private var error = ""
    @State private var busy = false
    @State private var unavailable = false
    @State private var selection = OrbSelection()
    @State private var showSelection = false
    @State private var showContext = false
    @State private var rename = false
    @State private var moving = false
    @State private var destinationProject = ""
    @State private var destinationFolder = ""
    @State private var title = ""
    @State private var attachments: [OrbAttachment] = []
    @State private var preview: OrbPreviewFile?
    @State private var events: [StoredEvent] = []
    @State private var workModel = OrbWorkModel()
    @State private var changedFiles: [OrbTurnSummary.FileChange] = []
    @State private var queued: [OrbJSON] = []
    /// Core's follow-up queue merged with optimistic sends/edits (OrbSendFlow.swift).
    @State private var followUps = OrbFollowUpQueue()
    /// Queued follow-up being edited in the composer (edit in place on send).
    @State private var editingQueuedID: String?
    /// Send now in flight: one continuous Sending… → Working… state, Stop kept.
    @State private var handoff: OrbHandoff?
    @State private var handoffTracker = OrbHandoffTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = "Message"
    @State private var refreshing = false
    @State private var lastRefresh = Date.distantPast
    @State private var stream: Task<Void, Never>?
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var eventRefreshTask: Task<Void, Never>?
    @State private var optimisticPrompt: String?
    @State private var liveText = ""
    @State private var answered: Set<String> = []
    @State private var copiedItemID: String?
    @State private var expandedLogIDs: Set<String> = []
    @State private var expandedUserMessageIDs: Set<String> = []
    @State private var queueExpanded = true
    @State private var history: [(String, String, String)] = []
    @State private var contextItems: [OrbContextItem] = []
    @State private var contextBrowseFolder = ""
    @State private var dismissedAtToken: String?
    @State private var forking = false
    @State private var cloning = false
    @State private var forkedMission: String?
    @State private var sideQuestion: OrbSideQuestionRequest?
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var phase
    private let api = OrbCore.shared
    private var draftKey: String { "draft:\(missionID ?? "new:\(project):\(folder)")" }
    private var pendingKey: String { draftKey + ":pending" }
    private var turns: [OrbJSON] { execution["turns"].items }
    private var isCloud: Bool { execution != .null || !mission["cloud"]["provider"].text.isEmpty || (id == nil && selection.cloud) }
    /// Core stores trimmed text, so a reply echoed back may differ from the
    /// draft only by surrounding whitespace.
    static func sameMessage(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let workingPhases: Set<String> = ["queued", "submitting", "running", "cancel_requested"]
    static let goalHarnesses: Set<String> = ["antigravity", "claudecode", "codex", "grok", "opencode"]
    private var supportsMode: Bool { !isCloud && (selection.backend.isEmpty || Self.goalHarnesses.contains(selection.backend)) }
    private var handoffActive: Bool { OrbHandoff.pending(status: mission["status"].text, handoff: handoff) }
    private var working: Bool { optimisticPrompt != nil || handoffActive || (isCloud ? turns.contains { Self.workingPhases.contains($0["phase"].text) } : (MissionState(rawValue: mission["status"].text)?.isActive ?? false)) }

    private func rebuildWorkModel() {
        let next = OrbWorkModel.build(from: events, working: working)
        if workModel != next {
            workModel = next
        }
        let files = OrbTurnSummary.changedFiles(events)
        if changedFiles != files { changedFiles = files }
    }

    private func rebuildHistory() {
        let next = Self.computeHistory(
            isCloud: isCloud,
            turns: turns,
            mission: mission,
            events: events,
            optimisticPrompt: optimisticPrompt
        )
        if !followsLatest && next.count > history.count && history.count >= visibleCount {
            visibleCount += (next.count - history.count)
        }
        if history.count != next.count || zip(history, next).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 || $0.2 != $1.2 }) {
            history = next
        }
    }

    private static func computeHistory(
        isCloud: Bool,
        turns: [OrbJSON],
        mission: OrbJSON,
        events: [StoredEvent],
        optimisticPrompt: String?
    ) -> [(String, String, String)] {
        var rows: [(String, String, String)] = []
        if isCloud {
            rows = turns.flatMap { turn in
                [(turn["key"].text + ":u", "user", turn["prompt"].text), (turn["key"].text + ":a", "assistant", turn["result"].text)].filter { !$0.2.isEmpty }
            }
        } else {
            var expandedRaw: [(String, String, String)] = []
            for (offset, element) in mission["history"].items.enumerated() {
                let role = element["role"].text
                let content = element["content"].text
                guard !content.isEmpty else { continue }
                if role == "assistant" && OrbRemoteContinuation.isNoiseAssistantTurn(content) {
                    continue
                }
                if role == "user", let unpacked = OrbRemoteContinuation.unpack(content) {
                    for (subIdx, sub) in unpacked.enumerated() {
                        expandedRaw.append(("cont-\(offset)-\(subIdx)", sub.role, sub.content))
                    }
                } else {
                    expandedRaw.append((String(offset), role, content))
                }
            }
            var deduplicated: [(String, String, String)] = []
            for item in expandedRaw {
                let (itemID, role, content) = item
                if role == "assistant", let last = deduplicated.last, last.1 == "assistant" {
                    let prevTrimmed = last.2.trimmingCharacters(in: .whitespacesAndNewlines)
                    let currTrimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sharedPrefixLen = min(160, min(prevTrimmed.count, currTrimmed.count))
                    if prevTrimmed == currTrimmed || (sharedPrefixLen >= 80 && prevTrimmed.prefix(sharedPrefixLen) == currTrimmed.prefix(sharedPrefixLen)) {
                        deduplicated[deduplicated.count - 1] = (itemID, role, content)
                        continue
                    }
                }
                deduplicated.append(item)
            }
            rows = deduplicated
            for event in events where event.eventType == "user_message" {
                let text = event.content
                guard !text.isEmpty else { continue }
                if OrbRemoteContinuation.unpack(text) != nil { continue }
                if !rows.contains(where: { $0.1 == "user" && Self.sameMessage($0.2, text) }) {
                    rows.append(("event-user-\(event.sequence)", "user", text))
                }
            }
        }
        if let opt = optimisticPrompt, !rows.contains(where: { $0.1 == "user" && Self.sameMessage($0.2, opt) }) {
            rows.append(("optimistic-user", "user", opt))
        }
        if !isCloud {
            rows = rows.enumerated().map { index, row in
                ("turn-\(index)-\(row.1)", row.1, row.2)
            }
        }
        return rows
    }

    /// Live text minus what stored history already holds (no doubled reply after a reload).
    private var visibleLiveText: String {
        OrbSendFlow.dedupeLiveText(liveText, stored: history.filter { $0.1 == "assistant" }.map(\.2))
    }

    private func baseStepLabel() -> String {
        let turn = turns.first { Self.workingPhases.contains($0["phase"].text) }
        let provider = ["chatgpt": "ChatGPT", "cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot", "hermes": "Hermes"][execution["selection"]["provider"].text] ?? "the service"
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
    private func progress(at now: Date) -> String {
        let headline = workModel.liveHeadline(fallback: baseStepLabel())
        let label = headline.detail.isEmpty ? headline.action : "\(headline.action) \(headline.detail)"
        return "\(label) · \(elapsedClock(at: now))"
    }

    /// Turn start from Core (latest delivered user message), so reopening the app
    /// does not restart a long turn at 0:00; Orb's own clock only as a fallback.
    private func elapsedClock(at now: Date) -> String {
        let turn = turns.first { Self.workingPhases.contains($0["phase"].text) }
        let key = turn?["key"].text ?? "local:\(id ?? "")"
        let serverStart = isCloud ? nil : OrbTurnSummary.turnStart(events)
        let started = serverStart.map { min($0, now) } ?? OrbWorkClock.start(key)
        return OrbTurnSummary.clock(Int(now.timeIntervalSince(started)))
    }

    /// Only the latest ChatGPT answer becomes an interactive quiz, like the desktop.
    private func quiz(for item: (String, String, String)) -> OrbQuizData? {
        guard isCloud, execution["selection"]["provider"].text == "chatgpt", let last = turns.last, item.0 == last["key"].text + ":a", !Self.workingPhases.contains(last["phase"].text) else { return nil }
        return OrbQuizData.parse(item.2)
    }

    /// Sends quiz answers through the normal, idempotent send path; the typed draft is restored after.
    private func sendReply(_ reply: String) async -> Bool {
        if let pending = OrbDisk.read(pendingKey, as: OrbPending.self), pending.body["content"].text != reply {
            error = "Another message is still being confirmed. Send it before answering the quiz."
            return false
        }
        let draft = text; text = reply
        let sent = await send()
        text = draft
        return sent
    }

    private var cloudBlocked: Bool { isCloud && turns.contains { ["submission_uncertain", "incompatible", "reconnect_required"].contains($0["phase"].text) } }
    private var status: String { (turns.last?["phase"].text ?? mission["status"].text).replacingOccurrences(of: "_", with: " ") }
    private var lastUserItemID: String? {
        history.last(where: { $0.1 == "user" })?.0
    }
    private var resolvedNavigationTitle: String {
        let raw = mission["title"].text
        if !raw.isEmpty { return OrbStyle.displayTitle(raw) }
        return missionID == nil ? "New agent" : "Conversation"
    }

    private var effectiveProjectSlug: String {
        let mProj = mission["project"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mProj.isEmpty { return mProj }
        return project.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { scroll in
            conversationContainer(scroll: scroll)
                .background(OrbStyle.background)
                .scrollDismissesKeyboard(.interactively)
                .background(OrbDoubleTapDismissesKeyboard(active: composerFocused) { composerFocused = false })
                .navigationTitle(resolvedNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(OrbStyle.background.opacity(0.92), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
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
                .sheet(item: $preview) { OrbPreviewSheet(file: $0) }
                .sheet(isPresented: $showSelection) { OrbAgentPicker(selection: $selection, existing: id != nil) }
                .sheet(isPresented: $showContext) { NavigationStack { OrbDocuments(project: effectiveProjectSlug, path: "").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showContext = false } } } } }
                .alert("Rename conversation", isPresented: $rename) { TextField("Title", text: $title); Button("Save") { Task { await mutate(["title": .string(title)]) } }; Button("Cancel", role: .cancel) {} }
                .sheet(isPresented: $moving) { moveConversationSheet }
                .sheet(isPresented: $forking) { OrbForkSheet(mission: mission) { forkedMission = $0["id"].text } }
                .sheet(item: $sideQuestion) { OrbSideQuestionSheet(parentID: $0.parent, question: $0.question) }
                .confirmationDialog("Clone conversation", isPresented: $cloning, titleVisibility: .visible) { cloneActions }
                .navigationDestination(item: $forkedMission) { OrbConversation(missionID: $0, project: effectiveProjectSlug, folder: OrbRow(mission).folder) }
                .task {
                    if let missionID { OrbOnScreen.opened(missionID) }
                    OrbWebViewPool.shared.warmUp(count: 2)
                    id = missionID
                    text = OrbDisk.read(draftKey, as: String.self) ?? ""
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

    private func scrollToBottomOnOpen(scroll: ScrollViewProxy) {
        guard !history.isEmpty else { return }
        followsLatest = true
        openedAtLatest = true
        scroll.scrollTo("conversation-bottom", anchor: .bottom)
        Task { @MainActor in
            await Task.yield()
            if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
            try? await Task.sleep(for: .milliseconds(90))
            if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
            try? await Task.sleep(for: .milliseconds(220))
            if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func conversationContainer(scroll: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomTrailing) {
            conversationScrollView(scroll: scroll)
            if !atBottom && !history.isEmpty {
                scrollToLatestButton(scroll: scroll)
            }
        }
    }

    @ViewBuilder
    private func conversationScrollView(scroll: ScrollViewProxy) -> some View {
        ScrollView {
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
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling { followsLatest = atBottom }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let maxScrollableY = max(0, geometry.contentSize.height - geometry.visibleRect.height)
            return maxScrollableY <= 24 || geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        } action: { _, value in
            atBottom = value
            if value {
                followsLatest = true
            } else if userScrolling {
                followsLatest = false
            }
        }
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
        } action: { _, _ in
            if followsLatest {
                Task { @MainActor in
                    await Task.yield()
                    if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
        }
        .onChange(of: working) { _, now in
            if !now { OrbWorkClock.stop("local:\(id ?? "")") }
            rebuildWorkModel()
        }
        .onChange(of: history.last?.0) { _, _ in
            if !openedAtLatest || followsLatest {
                scroll.scrollTo("conversation-bottom", anchor: .bottom)
                openedAtLatest = true
                Task { @MainActor in
                    await Task.yield()
                    if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
                    try? await Task.sleep(for: .milliseconds(120))
                    if followsLatest { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var completedPlanTurnKey: String? {
        guard !working, !isCloud, pendingQuestionEvents.isEmpty else { return nil }
        guard let lastUserIdx = history.lastIndex(where: { $0.1 == "user" }) else { return nil }
        let userItem = history[lastUserIdx]
        let presentation = OrbMessagePresentation.parse(userItem.2)
        let images = OrbMessageImages.parse(presentation.text)
        guard OrbStyle.planObjective(images.text) != nil else { return nil }
        let hasAssistantReply = history[(lastUserIdx + 1)...].contains(where: { $0.1 == "assistant" && !$0.2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard hasAssistantReply else { return nil }
        let key = "plan-review:\(userItem.0)"
        guard !answered.contains(key) else { return nil }
        return key
    }

    @ViewBuilder
    private func completedPlanReviewCard(key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrbStyle.textSecondary)
                Text("Review the plan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    OrbHaptics.selection()
                    answered.insert(key)
                    mode = "Message"
                    Task { _ = await sendReply("Proceed with implementing the plan.") }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("Implement plan")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(OrbStyle.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("plan.implement")

                Button {
                    OrbHaptics.selection()
                    answered.insert(key)
                    mode = "Plan"
                    composerFocused = true
                } label: {
                    Text("Request changes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("plan.requestChanges")

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-review-card")
    }

    @ViewBuilder
    private func conversationContent(scroll: ScrollViewProxy) -> some View {
        if loading && missionID != nil && mission == .null {
            conversationLoadingSkeletons
        }
        if missionID == nil && id == nil && optimisticPrompt == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("What would you like to work on?")
                    .font(.title3.weight(.semibold))
                Text(folder.isEmpty ? project : "\(project) / \(folder)")
                    .font(.footnote)
                    .foregroundStyle(OrbStyle.textSecondary)
            }
            .padding(.top, 16)
        }
        if history.count > visibleCount {
            Button("Load earlier messages") {
                let anchor = history.suffix(visibleCount).first?.0
                followsLatest = false
                visibleCount += 20
                Task { @MainActor in
                    await Task.yield()
                    if let anchor { scroll.scrollTo(anchor, anchor: .top) }
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(OrbStyle.textSecondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.03), in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.border))
            .accessibilityIdentifier("load-earlier")
        }
        ForEach(Array(history.suffix(visibleCount)), id: \.0) { item in
            messageHistoryRow(item: item)
        }
        ForEach(turns.indices, id: \.self) { index in
            turnSummaryRow(turn: turns[index])
        }
        if !workModel.todos.isEmpty {
            OrbMissionTasksCard(todos: workModel.todos)
        }
        if working {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                OrbWorkFold(
                    model: workModel,
                    working: true,
                    headline: workModel.liveHeadline(fallback: baseStepLabel()),
                    elapsed: elapsedClock(at: context.date),
                    accessibilityStatus: progress(at: context.date)
                )
            }
        } else if !workModel.isEmpty {
            OrbWorkFold(
                model: workModel,
                working: false,
                headline: workModel.liveHeadline(fallback: baseStepLabel()),
                elapsed: "",
                accessibilityStatus: ""
            )
        }
        if !working && !isCloud {
            turnChangesCard
        }
        if working && !visibleLiveText.isEmpty {
            OrbRichText(source: visibleLiveText, onArtifact: { path in
                Task { await openWorkspaceOrArtifact(path) }
            })
            .transition(.opacity)
        }
        ForEach(pendingQuestionEvents) { event in
            if let data = event.content.data(using: .utf8), let request = try? JSONDecoder().decode(OrbJSON.self, from: data) {
                OrbQuestion(event: event, request: request) { answered.insert(event.toolCallId ?? "") }
            }
        }
        if let planKey = completedPlanTurnKey {
            completedPlanReviewCard(key: planKey)
        }
        if !working && ["failed", "blocked", "interrupted", "cancelled", "reconnect required", "submission uncertain", "incompatible", "waiting user"].contains(status), turns.last?["detail"].text.isEmpty != false {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                Text(status == "waiting user" ? "Waiting for your reply" : status.capitalized)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(OrbStyle.warning)
            .padding(.vertical, 2)
        }
    }

    /// Files edited in this conversation and its pull request, like the desktop's Changes.
    @ViewBuilder
    private var turnChangesCard: some View {
        let pr = OrbTurnSummary.prLink(mission["github_pr"].text)
        if !changedFiles.isEmpty || pr != nil {
            OrbChangesCard(files: changedFiles, pr: pr)
        }
    }

    private var conversationLoadingSkeletons: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 80)
                Text("User message prompt placeholder line")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Assistant response heading placeholder")
                    .font(.headline)
                Text("First line of assistant markdown response with technical details and context.")
                    .font(.subheadline)
                Text("Second line of assistant response placeholder.")
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
        .redacted(reason: .placeholder)
        .orbShimmer(active: true)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading conversation")
    }

    private var pendingQuestionEvents: [StoredEvent] {
        events.filter { event in
            event.eventType == "tool_call" && ["ui_native_request", "AskUserQuestion", "question"].contains(event.toolName ?? "") && !answered.contains(event.toolCallId ?? "") && !events.contains(where: { $0.eventType == "tool_result" && $0.toolCallId == event.toolCallId })
        }
    }

    @ViewBuilder
    private func messageHistoryRow(item: (String, String, String)) -> some View {
        if item.1 == "user" {
            let presentation = OrbMessagePresentation.parse(item.2)
            if let wake = OrbBackgroundWake.parse(presentation.text) {
                backgroundWakeRow(itemID: item.0, wake: wake)
            } else {
                let images = OrbMessageImages.parse(presentation.text)
                let goalObj = OrbStyle.goalObjective(images.text)
                let planObj = goalObj == nil ? OrbStyle.planObjective(images.text) : nil
                let displayBody = goalObj ?? planObj ?? images.text
                let isPendingTurn = working && item.0 == lastUserItemID
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .leading, spacing: 8) {
                        if !images.paths.isEmpty { OrbImageStrip(images: images, missionID: id) }
                        if goalObj != nil || planObj != nil || presentation.attached {
                            HStack(spacing: 6) {
                                if goalObj != nil {
                                    HStack(spacing: 4) {
                                        Image(systemName: "target")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("Goal")
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                                } else if planObj != nil {
                                    HStack(spacing: 4) {
                                        Image(systemName: "list.bullet.clipboard")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("Plan")
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                                }
                                if presentation.attached {
                                    HStack(spacing: 4) {
                                        Image(systemName: "paperclip")
                                            .font(.system(size: 10, weight: .medium))
                                        Text("Attached context")
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .foregroundStyle(OrbStyle.textSecondary)
                                }
                            }
                        }
                        if !displayBody.isEmpty {
                            let isLongUserMsg = displayBody.count > 4000 && !expandedUserMessageIDs.contains(item.0)
                            let shownUserText = isLongUserMsg ? String(displayBody.prefix(4000)) + "…" : displayBody
                            Text(shownUserText)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .orbShimmer(active: isPendingTurn)
                            if isLongUserMsg {
                                Button {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        _ = expandedUserMessageIDs.insert(item.0)
                                    }
                                } label: {
                                    Text("Show full message")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(OrbStyle.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isPendingTurn ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
                    )
                    .contextMenu {
                        if !displayBody.isEmpty {
                            Button {
                                UIPasteboard.general.string = displayBody
                                OrbHaptics.light()
                            } label: {
                                Label("Copy message", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                .id(item.0)
            }
        } else if let quiz = quiz(for: item) {
            VStack(alignment: .leading, spacing: 12) {
                if !quiz.before.isEmpty { OrbRichText(source: quiz.before) }
                OrbQuiz(quiz: quiz, disabled: busy || cloudBlocked || working) { reply in await sendReply(reply) }
                if !quiz.after.isEmpty { OrbRichText(source: quiz.after) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(item.0)
        } else {
            let parsedRemote = OrbRemoteLog.parse(item.2)
            VStack(alignment: .leading, spacing: 4) {
                OrbRichText(source: parsedRemote.text, onArtifact: { path in
                    Task { await openWorkspaceOrArtifact(path) }
                })
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = parsedRemote.text
                        OrbHaptics.light()
                        withAnimation(.snappy(duration: 0.15)) { copiedItemID = item.0 }
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            if copiedItemID == item.0 {
                                withAnimation(.snappy(duration: 0.15)) { copiedItemID = nil }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedItemID == item.0 ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                            if copiedItemID == item.0 {
                                Text("Copied")
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(copiedItemID == item.0 ? OrbStyle.success : OrbStyle.textMuted)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copiedItemID == item.0 ? "Copied response" : "Copy response")

                    if parsedRemote.details != nil {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                if !expandedLogIDs.insert(item.0).inserted {
                                    expandedLogIDs.remove(item.0)
                                }
                            }
                            OrbHaptics.selection()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(expandedLogIDs.contains(item.0) ? 90 : 0))
                                Text("Remote log")
                                    .font(.caption2)
                            }
                            .foregroundStyle(OrbStyle.textMuted)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                if let details = parsedRemote.details, expandedLogIDs.contains(item.0) {
                    ScrollView {
                        Text(details.prefix(8000))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
                }
            }
            .id(item.0)
        }
    }

    @ViewBuilder
    private func backgroundWakeRow(itemID: String, wake: OrbBackgroundWake) -> some View {
        let isExpanded = expandedLogIDs.contains(itemID)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if !expandedLogIDs.insert(itemID).inserted {
                        expandedLogIDs.remove(itemID)
                    }
                }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: wake.killed ? "xmark.octagon" : "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(wake.killed ? OrbStyle.warning : OrbStyle.textMuted)
                    Text(wake.killed ? "Background task stopped" : "Background task finished")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(wake.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(OrbStyle.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task \(wake.task) · \(wake.command)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(OrbStyle.textMuted)
                    if !wake.output.isEmpty {
                        ScrollView {
                            Text(wake.output.prefix(4000))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OrbStyle.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    if !wake.note.isEmpty {
                        Text(wake.note)
                            .font(.caption2)
                            .foregroundStyle(OrbStyle.textMuted)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
            }
        }
        .id(itemID)
    }

    @ViewBuilder
    private func turnSummaryRow(turn: OrbJSON) -> some View {
        if !turn["detail"].text.isEmpty && !Self.workingPhases.contains(turn["phase"].text) {
            Text(turn["detail"].text)
                .font(.footnote)
                .foregroundStyle(OrbStyle.textSecondary)
        }
        ForEach(turn["branches"].items.indices, id: \.self) { branchIndex in
            if let url = safeURL(turn["branches"].items[branchIndex]["prUrl"].text) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.caption)
                        Text("View pull request")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border))
                }
            }
        }
        ForEach(turn["artifacts"].items.indices, id: \.self) { artifactIndex in
            let artifact = turn["artifacts"].items[artifactIndex]
            Button {
                Task { await download(artifact["path"].text) }
            } label: {
                Label(artifact["path"].text.components(separatedBy: "/").last ?? "File", systemImage: "doc")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border))
            }
            .buttonStyle(.plain)
        }
    }

    private func scrollToLatestButton(scroll: ScrollViewProxy) -> some View {
        Button {
            OrbHaptics.selection()
            followsLatest = true
            withAnimation(.snappy(duration: 0.22)) {
                scroll.scrollTo("conversation-bottom", anchor: .bottom)
            }
        } label: {
            HStack(spacing: 6) {
                if working { OrbRunningDots(size: 10) }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(OrbStyle.elevated.opacity(0.95), in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.borderStrong))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 10)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .accessibilityLabel("Scroll to latest message")
    }

    private var conversationToolbarMenu: some View {
        let currentStatus = mission["status"].text
        return Menu {
            if id != nil && !unavailable {
                Section {
                    Text(selection.label)
                    if !status.isEmpty { Text(status.capitalized) }
                }
                Button("Rename") { title = mission["title"].text; rename = true }
                Button("Move") { destinationProject = mission["project"].text; destinationFolder = OrbRow(mission).folder; moving = true }
                if MissionState(rawValue: currentStatus)?.canReopen == true {
                    Button(currentStatus == "acknowledged" ? "Restore" : "Reopen") {
                        Task { await mutate(["status": .string("paused")]) }
                    }
                    .disabled(working)
                }
                if currentStatus != "acknowledged" {
                    Button("Archive") { Task { await mutate(["status": .string("acknowledged")]) } }.disabled(working)
                }
                if working && (!isCloud || selection.canCancel) {
                    Button("Stop", role: .destructive) { Task { await cancel() } }
                }
                if let url = safeURL(execution["external_url"].text) {
                    Link("Open in service", destination: url)
                }
                if !isCloud {
                    Divider()
                    Button { sideQuestion = OrbSideQuestionRequest(parent: id ?? "", question: "") } label: { Label("Side question (/btw)", systemImage: "bubble.left.and.text.bubble.right") }
                    Button { forking = true } label: { Label("Fork conversation", systemImage: "arrow.triangle.branch") }
                    Button { cloning = true } label: { Label("Clone", systemImage: "plus.square.on.square") }
                }
            }
            if !effectiveProjectSlug.isEmpty { Button("Project context") { showContext = true } }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Conversation actions")
    }

    @ViewBuilder private var cloneActions: some View {
        Button("Clone settings (fresh start)") { Task { await clone(messages: false) } }
        Button("Clone with conversation history") { Task { await clone(messages: true) } }
        Button("Cancel", role: .cancel) {}
    }

    private func clone(messages: Bool) async {
        guard let id else { return }
        do {
            let cloned = try await api.call("/api/control/missions/\(OrbCore.escape(id))/clone", method: "POST", body: .object(["clone_messages": .bool(messages)]))
            OrbHaptics.success()
            forkedMission = cloned["id"].text
        } catch { self.error = error.localizedDescription }
    }

    private var moveConversationSheet: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                TextField("Project slug", text: $destinationProject).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Folder", text: $destinationFolder).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle("Move conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { moving = false } }
                ToolbarItem(placement: .topBarTrailing) { Button("Move") { Task { await move() } }.disabled(destinationProject.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }

    private var activeAtMentionQuery: String? {
        guard !isCloud, !effectiveProjectSlug.isEmpty else { return nil }
        guard let active = OrbContextTagging.activeAtQuery(text) else { return nil }
        if dismissedAtToken == active.query { return nil }
        return active.query
    }

    private var effectiveContextFolder: String {
        if !contextBrowseFolder.isEmpty { return contextBrowseFolder }
        guard let q = activeAtMentionQuery else { return "" }
        return OrbContextTagging.folderPrefixFromQuery(items: contextItems, query: q) ?? ""
    }

    private var filteredContextItems: [OrbContextItem] {
        guard let query = activeAtMentionQuery else { return [] }
        return OrbContextTagging.filterItems(contextItems, query: query, browseFolder: contextBrowseFolder)
    }

    private var mentionedContextItems: [OrbContextItem] {
        OrbContextTagging.mentionedItems(in: text, items: contextItems)
    }

    private var modeQuery: String? {
        guard supportsMode else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            let query = String(trimmed.dropFirst()).lowercased()
            if ["message", "plan", "goal"].contains(where: { $0.hasPrefix(query) }) { return query }
        }
        return nil
    }

    private func chooseMode(_ value: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            text = ""
        } else if let range = text.range(of: "@", options: .backwards) {
            text.removeSubrange(range.lowerBound...)
        }
        withAnimation(.snappy(duration: 0.18)) {
            mode = value
        }
        OrbHaptics.selection()
        composerFocused = true
    }

    private func pickContextItem(_ item: OrbContextItem) {
        contextBrowseFolder = ""
        dismissedAtToken = nil
        text = OrbContextTagging.insertMention(in: text, item: item)
        OrbHaptics.selection()
        composerFocused = true
    }

    private func openContextFolder(_ folder: String) {
        let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        contextBrowseFolder = clean
        text = OrbContextTagging.setFolderQuery(in: text, folder: clean)
        OrbHaptics.selection()
        composerFocused = true
    }

    private func navigateBackContextFolder() {
        let current = effectiveContextFolder
        let parent = current.contains("/") ? String(current[..<current.lastIndex(of: "/")!]) : ""
        contextBrowseFolder = parent
        text = OrbContextTagging.setFolderQuery(in: text, folder: parent)
        OrbHaptics.selection()
    }

    private var contextMentionPicker: some View {
        let items = filteredContextItems
        let currentFolder = effectiveContextFolder
        let folderRows = items.filter { $0.section == .folders }
        let fileRows = items.filter { $0.section == .files }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !currentFolder.isEmpty {
                    Button {
                        navigateBackContextFolder()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(currentFolder)/")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .foregroundStyle(.primary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        let folderItem = OrbContextItem(
                            id: "context:\(effectiveProjectSlug):\(currentFolder)",
                            kind: .context,
                            section: .folders,
                            path: currentFolder,
                            label: "\(currentFolder)/",
                            project: effectiveProjectSlug
                        )
                        pickContextItem(folderItem)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 11))
                            Text("Tag folder")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "at")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OrbStyle.textSecondary)
                    Text("PROJECT CONTEXT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                    Spacer()
                    Button {
                        showContext = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
                            Text("Manage")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(OrbStyle.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(OrbStyle.textMuted)
                    Text(contextItems.isEmpty ? "No project context files yet. Tap Manage to add files." : "No matching context files or folders.")
                        .font(.caption)
                        .foregroundStyle(OrbStyle.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !folderRows.isEmpty {
                            Text("FOLDERS")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                            ForEach(folderRows) { item in
                                HStack(spacing: 6) {
                                    Button {
                                        openContextFolder(item.path)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(OrbStyle.textSecondary)
                                                .frame(width: 20)
                                            Text(item.label)
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(OrbStyle.textMuted)
                                        }
                                        .padding(.vertical, 7)
                                        .padding(.leading, 10)
                                        .padding(.trailing, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        pickContextItem(item)
                                    } label: {
                                        Text("Tag")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.07), in: Capsule())
                                            .overlay(Capsule().stroke(OrbStyle.border))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 8)
                                }
                                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityIdentifier("context-item-\(item.path)")
                            }
                        }
                        if !fileRows.isEmpty {
                            Text("FILES")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, folderRows.isEmpty ? 4 : 6)
                                .padding(.bottom, 2)
                            ForEach(fileRows) { item in
                                Button {
                                    pickContextItem(item)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 13))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                            .frame(width: 20)
                                        Text(item.label)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("context-item-\(item.path)")
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 210)
            }
        }
        .padding(4)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong))
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("context-mention-picker")
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MODES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OrbStyle.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(["Message", "Plan", "Goal"].filter { modeQuery?.isEmpty != false || $0.lowercased().hasPrefix(modeQuery ?? "") }, id: \.self) { value in
                let subtitle = value == "Goal" ? "Keep iterating until this objective is met" : (value == "Plan" ? "Plan before making changes" : "Standard conversation turn")
                Button { chooseMode(value) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: value == "Goal" ? "target" : value == "Plan" ? "list.bullet.clipboard" : "bubble.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(mode == value ? .primary : OrbStyle.textSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(value)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                        }
                        Spacer()
                        if mode == value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(mode == value ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mode-option-" + value.lowercased())
            }
        }
        .padding(6)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong))
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mode-picker")
    }

    private var queuedDrawer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { queueExpanded.toggle() }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(queueExpanded ? 90 : 0))
                    Text("\(followUps.count) Queued")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if queueExpanded {
                ForEach(followUps.rows) { row in
                    queuedRow(row)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if editingQueuedID != nil {
                HStack {
                    Text("Editing queued message").font(.caption2).foregroundStyle(OrbStyle.textSecondary)
                    Spacer()
                    Button("Cancel") { editingQueuedID = nil; text = "" }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OrbStyle.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OrbStyle.border))
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds), value: followUps.rows)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orb.followUpQueue")
    }

    /// One compact line: text, then edit / send now / remove. The action area is
    /// always reserved so a row does not change size from "sending" to "queued".
    private func queuedRow(_ row: OrbQueuedRow) -> some View {
        let editing = editingQueuedID == row.id
        let enabled = !row.sending && editingQueuedID == nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(row.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption)
                    .foregroundStyle(editing ? OrbStyle.textMuted : .primary.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if editing {
                    Text("Editing").font(.caption2).foregroundStyle(OrbStyle.textMuted).padding(.horizontal, 6)
                } else {
                    queueAction("pencil", label: "Edit queued message", enabled: enabled) {
                        editingQueuedID = row.id
                        text = row.content
                        composerFocused = true
                    }
                    queueAction("arrow.up", label: "Send now", enabled: enabled) {
                        OrbHaptics.light()
                        Task { await sendQueuedNow(row.id) }
                    }
                    queueAction("trash", label: "Remove queued message", enabled: !row.sending) {
                        OrbHaptics.light()
                        Task { await removeQueued(row.id) }
                    }
                }
            }
            if let error = row.queueError {
                Text("Delivery paused · \(error)").font(.caption2).foregroundStyle(OrbStyle.warning).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .opacity(row.sending ? 0.75 : 1)
    }

    private func queueAction(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? OrbStyle.textSecondary : OrbStyle.textMuted.opacity(0.4))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var canSend: Bool {
        !busy && !cloudBlocked && modeQuery == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        Button {
            OrbHaptics.light()
            Task { await send() }
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? Color.white : Color.white.opacity(busy ? 0.12 : 0.06))
                    .frame(width: 32, height: 32)
                if busy {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.85))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSend ? OrbStyle.background : Color.white.opacity(0.25))
                }
            }
            .frame(width: 38, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(busy ? "Sending message" : "Send message")
        .accessibilityValue(busy ? "Sending" : canSend ? "Ready" : "Unavailable")
    }

    private var stopButton: some View {
        Button {
            OrbHaptics.light()
            Task { await cancel() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(OrbStyle.borderStrong, lineWidth: 1))
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 34, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop agent")
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if activeAtMentionQuery != nil {
                contextMentionPicker
            } else if modeQuery != nil {
                modePicker
            }
            if followUps.count > 0 || editingQueuedID != nil { queuedDrawer }
            if dictation.active {
                OrbDictationCapsule(dictation: dictation)
            } else {
                composerInput
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty { OrbAttachments(files: $attachments, error: $error, canAdd: false) }
            let mentioned = mentionedContextItems
            if (mode != "Message" && supportsMode) || !mentioned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if mode != "Message" && supportsMode {
                            Button {
                                withAnimation(.snappy(duration: 0.18)) { mode = "Message" }
                                OrbHaptics.selection()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: mode == "Goal" ? "target" : "list.bullet.clipboard")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(mode)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(OrbStyle.textSecondary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.09), in: Capsule())
                                .overlay(Capsule().stroke(OrbStyle.borderStrong))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear " + mode + " mode")
                        }
                        ForEach(mentioned) { item in
                            HStack(spacing: 4) {
                                Image(systemName: item.section == .folders ? "folder.fill" : "doc.text")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(OrbStyle.textSecondary)
                                Text(item.label)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .overlay(Capsule().stroke(OrbStyle.border))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            TextField(id == nil ? (mode == "Goal" ? "Describe the goal objective…" : mode == "Plan" ? "What should we plan?" : "Plan, ask, build… (@ for context)") : (working ? "Queue a follow-up…" : "Follow up… (@ for context)"), text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.subheadline)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .focused($composerFocused)
                .accessibilityIdentifier("composer")
            HStack(spacing: 5) {
                if !effectiveProjectSlug.isEmpty && !isCloud {
                    OrbAttachments(
                        files: $attachments,
                        error: $error,
                        showContextMention: {
                            if activeAtMentionQuery == nil {
                                text += (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + "@"
                            }
                            composerFocused = true
                        },
                        showMode: supportsMode ? {
                            if modeQuery == nil {
                                text = "/"
                            }
                            composerFocused = true
                        } : nil,
                        showFiles: false
                    )
                }
                Button {
                    composerFocused = false
                    showSelection = true
                } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: selection.primaryIcon)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(selection.needsAgentSelection ? .white : OrbStyle.textSecondary)
                            Text(selection.primaryPillLabel)
                                .font(.caption.weight(selection.needsAgentSelection ? .semibold : .medium))
                                .foregroundStyle(selection.needsAgentSelection ? .white : OrbStyle.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(
                            selection.needsAgentSelection ? Color.white.opacity(0.09) : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                selection.needsAgentSelection ? OrbStyle.borderStrong : OrbStyle.border,
                                lineWidth: 1
                            )
                        )

                        if let nodeBadge = selection.machinePillLabel {
                            HStack(spacing: 3.5) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(OrbStyle.textMuted)
                                Text(nodeBadge)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(OrbStyle.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.04), in: Capsule())
                            .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                        }
                    }
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent and model: \(selection.label)")
                .accessibilityIdentifier("agent-selection")

                Spacer(minLength: 2)

                OrbDictationButton(dictation: dictation, text: $text, onStart: { composerFocused = false }, onComplete: { composerFocused = true })
                    .disabled(busy)
                if working && (!isCloud || selection.canCancel) {
                    stopButton
                }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbStyle.panelRadius, style: .continuous).stroke(OrbStyle.borderStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-composer")
    }

    private func scheduleCoalescedRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }

    private func refresh(force: Bool = false) async {
        guard let id, !refreshing else { return }
        if !force && !working && Date().timeIntervalSince(lastRefresh) < 30 { return }
        refreshing = true; defer { refreshing = false; loading = false }
        do {
            let knownCloud = mission != .null && OrbRow(mission).cloud
            let sinceSeq = events.last?.sequence
            async let valueTask = OrbReadCache.conversation(id, force: force)
            async let batchTask = knownCloud ? nil : (try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 150, sinceSeq: sinceSeq))
            async let queueTask: OrbJSON = knownCloud ? .null : ((try? await api.call("/api/control/queue")) ?? .null)

            var value = try await valueTask
            if value["history"].items.isEmpty && !mission["history"].items.isEmpty, case var .object(dict) = value {
                dict["history"] = mission["history"]
                value = .object(dict)
            }
            if mission != value {
                mission = value
            }
            unavailable = !OrbRow(value).mobile
            guard !unavailable else {
                rebuildHistory()
                return
            }
            if OrbRow(value).cloud && execution == .null {
                do {
                    execution = try await OrbReadCache.cloud(id, force: force)
                    selection.restore(execution["selection"])
                } catch let e as OrbHTTPError where e.status == 404 { selection.backend = value["backend"].text; selection.model = value["model_override"].text }
            } else if OrbRow(value).cloud { execution = try await OrbReadCache.cloud(id, force: force) }
            if !OrbRow(value).cloud {
                if stream == nil && phase == .active {
                    stream = OrbCore.shared.streamControl(missionId: id, sinceSeq: events.last?.sequence, preferWebSocket: false) { type, data in
                        if type == "fido_sign_request" { FidoApprovalState.shared.handleSignRequest(data); return }
                        if type == "text_delta", let delta = data["delta"] as? String ?? data["content"] as? String {
                            liveText += delta
                        } else if type == "text_op" {
                            let op = data["op"] as? String ?? ""
                            let content = data["content"] as? String ?? ""
                            if op == "append" { liveText += content }
                            else if op == "replace" { liveText = content }
                        }
                        if ["assistant_message", "mission_status_changed", "user_message"].contains(type) {
                            Task { await refresh(force: true) }
                        } else if ["tool_call", "tool_result", "thinking"].contains(type) {
                            scheduleCoalescedRefresh()
                        }
                    }
                }
                if !working { liveText = "" }
                selection.backend = value["backend"].text
                selection.node = value["remote_node_id"].text
                if selection.model.isEmpty { selection.model = value["model_override"].text; selection.serviceTier = OrbCodexSpeed.of(value) }
                if let batch = await batchTask, (!batch.events.isEmpty || events.isEmpty) {
                    let unique = Dictionary((events + batch.events).map { ($0.sequence, $0) }, uniquingKeysWith: { old, _ in old })
                    events = unique.values.sorted { $0.sequence < $1.sequence }
                    OrbReadCache.saveEvents(id, events: events)
                    rebuildWorkModel()
                }
                let queueResp = await queueTask
                if queueResp != .null {
                    queued = queueResp.items.filter { $0["mission_id"].text == id }
                    let next = followUps.withServer(OrbFollowUpQueue.parse(queueResp.items, missionID: id))
                    if next != followUps { withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next } }
                }
                if let current = handoff {
                    let job = value["remote_job"]
                    let ended = !job["finished_at"].text.isEmpty || !job["terminal_reason"].text.isEmpty
                    if handoffTracker.observe(current, status: value["status"].text, jobID: job["job_id"].text.isEmpty ? nil : job["job_id"].text, jobEnded: ended) {
                        handoff = nil
                        handoffTracker.reset()
                    }
                }
            } else {
                let accounts = (try? await OrbReadCache.cloudAccounts().items) ?? []
                let account = accounts.first { $0["id"].text == execution["selection"]["account"].text && $0["provider"].text == execution["selection"]["provider"].text }
                selection.canCancel = account?["capabilities"]["cancel"].flag ?? false
            }
            if let opt = optimisticPrompt {
                let inHistory = mission["history"].items.contains(where: { $0["role"].text == "user" && Self.sameMessage($0["content"].text, opt) })
                let inEvents = events.contains(where: { $0.eventType == "user_message" && Self.sameMessage($0.content, opt) })
                let inCloud = turns.contains(where: { Self.sameMessage($0["prompt"].text, opt) })
                let inQueue = queued.contains(where: { Self.sameMessage($0["content"].text, opt) })
                if inHistory || inEvents || inCloud || inQueue {
                    optimisticPrompt = nil
                }
            }
            rebuildHistory()
            if execution != .null { OrbDisk.saveAsync(execution, key: "cloud:\(id)") }
            OrbDisk.saveAsync(value, key: "mission:\(id)")
            lastRefresh = Date()
        } catch {
            if mission == .null {
                mission = OrbDisk.read("mission:\(id)", as: OrbJSON.self) ?? .null
                rebuildHistory()
            }
            self.error = "Connection unavailable. Last observed state is preserved. \(error.localizedDescription)"
        }
    }

    /// True once Core accepted the request, even if the refresh that follows fails.
    @discardableResult private func send() async -> Bool {
        guard !busy, !cloudBlocked else { return false }
        if let id, !isCloud, let question = Self.btwQuestion(text) {
            sideQuestion = OrbSideQuestionRequest(parent: id, question: question)
            text = ""
            return true
        }
        if let editing = editingQueuedID, id != nil {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return false }
            await editQueued(editing, content: content)
            return true
        }
        busy = true; defer { busy = false }
        let clientID = UUID().uuidString
        // A follow-up during a turn shows at once as a queued row, not as a bubble that jumps away.
        let queueing = working && id != nil && !isCloud && attachments.isEmpty && OrbDisk.read(pendingKey, as: OrbPending.self) == nil
        let savedDraft = text
        let savedAttachments = attachments
        let savedMode = mode
        do {
            let mentionedContext = isCloud ? [] : OrbContextTagging.mentionedItems(in: text, items: contextItems)
            guard !isCloud || attachments.isEmpty else { throw OrbHTTPError(status: 400, detail: "This cloud service does not support attachments. Remove the files before sending.") }
            draftSaveTask?.cancel()
            OrbDisk.saveAsync(attachments, key: draftKey + ":files")
            let pending: OrbPending
            if let saved = OrbDisk.read(pendingKey, as: OrbPending.self) {
                pending = saved
                optimisticPrompt = saved.body["content"].text.isEmpty ? saved.body["prompt"].text : saved.body["content"].text
                rebuildHistory()
            } else {
                var uploaded: [OrbJSON] = mentionedContext.map { OrbContextTagging.wireAttachment(for: $0) }
                // Core trims messages; send exactly what it will store so the
                // optimistic bubble is recognised and replaced, not shown twice.
                var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if supportsMode && mode != "Message" { prompt = "/" + mode.lowercased() + " " + prompt }
                // Optimistic UI: show the user bubble immediately and clear composer text while sending.
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if queueing {
                        followUps = followUps.enqueue(clientID, prompt)
                        text = ""
                    } else {
                        optimisticPrompt = prompt
                        text = ""
                        followsLatest = true
                        rebuildHistory()
                    }
                }
                for file in attachments {
                    let receipt = try await api.call("/api/uploads", method: "POST", body: .object(["node_id": .string(selection.node.isEmpty ? "core" : selection.node), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                    guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                    uploaded.append(.object(["kind": .string("file"), "path": receipt["path"]]))
                    prompt += "\n[Uploaded: " + receipt["path"].text + "]"
                }
                if !queueing {
                    optimisticPrompt = prompt
                    rebuildHistory()
                }
                var body: [String: OrbJSON]
                if let id {
                    body = ["mission_id": .string(id), "content": .string(prompt), "client_message_id": .string(clientID)]
                    if queueing { body["queue_followup"] = .bool(true) }
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if let identity = OrbContinuation.identity(for: mission) {
                        body["continue_identity"] = identity
                    }
                    if isCloud { body["cloud_model"] = .string(selection.model); body["cloud_model_params"] = selection.params }
                    if !isCloud && !selection.model.isEmpty && selection.model != mission["model_override"].text {
                        guard !working || optimisticPrompt != nil || queueing else { throw OrbHTTPError(status: 409, detail: "Wait for this turn to finish before changing its model.") }
                        _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["model_override": .string(selection.model)]))
                    }
                    if !isCloud && selection.backend == "codex" && selection.serviceTier != OrbCodexSpeed.of(mission) {
                        try await OrbCodexSpeed.require(model: selection.model.isEmpty ? mission["model_override"].text : selection.model, tier: selection.serviceTier, missionID: id)
                        _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/settings", method: "PATCH", body: .object(["service_tier": .string(selection.serviceTier)]))
                    }
                    pending = OrbPending(path: "/api/control/message", body: .object(body))
                } else {
                    try selection.validate()
                    body = ["title": .string(OrbStyle.missionTitle(prompt)), "prompt": .string(prompt), "project": .string(project), "tags": .array(folder.isEmpty ? [] : [.string("orb-folder:\(folder)")]), "idempotency_key": .string(UUID().uuidString)]
                    if !uploaded.isEmpty { body["attachments"] = .array(uploaded) }
                    if selection.cloud { body["cloud"] = selection.wire }
                    else if selection.backend == "codex" { try await OrbCodexSpeed.require(model: selection.model, tier: selection.serviceTier); body["service_tier"] = .string(selection.serviceTier) }
                    if !selection.cloud { body["backend"] = .string(selection.backend); body["model_override"] = .string(selection.model); if !selection.node.isEmpty && selection.node != "core" { body["remote_node_id"] = .string(selection.node) } }
                    pending = OrbPending(path: "/api/control/missions", body: .object(body))
                }
                try OrbDisk.save(pending, key: pendingKey)
            }
            OrbSendsInFlight.keys.insert(pendingKey)
            defer { OrbSendsInFlight.keys.remove(pendingKey) }
            if pending.path == "/api/control/message", let id, !isCloud {
                let currentStatus = mission["status"].text
                if currentStatus == "paused" || currentStatus == "acknowledged" {
                    _ = try await api.call(
                        "/api/control/missions/\(OrbCore.escape(id))/status",
                        method: "POST",
                        body: .object(["status": .string("awaiting_user")])
                    )
                }
            }
            let result = try await api.call(pending.path, method: "POST", body: pending.body)
            if pending.path == "/api/control/message" {
                guard !result["id"].text.isEmpty, result["message_accepted"] != .bool(false), result["queued"] != .null else { throw OrbHTTPError(status: 409, detail: "Core has not confirmed acceptance. The saved request is retained.") }
            }
            if id == nil { guard !result["id"].text.isEmpty else { throw URLError(.cannotParseResponse) }; id = result["id"].text }
            // A queued follow-up is not in the conversation yet; the queue drawer shows it.
            if pending.path == "/api/control/message" && result["queued"] == .bool(true) {
                optimisticPrompt = nil
                rebuildHistory()
            }
            if queueing {
                let queuedNow = result["queued"] == .bool(true)
                let receiptID = result["id"].text
                if receiptID.isEmpty || receiptID == clientID { followUps = followUps.posted(clientID, queued: queuedNow) }
                else {
                    followUps = followUps.postFailed(clientID)
                    if queuedNow { followUps = followUps.enqueue(receiptID, savedDraft.trimmingCharacters(in: .whitespacesAndNewlines)).posted(receiptID, queued: true) }
                }
            }
            if let id {
                OrbReadCache.invalidate("mission:\(id)")
            }
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            OrbDisk.remove(pendingKey)
            OrbDisk.remove(draftKey)
            attachments = []
            OrbDisk.remove(draftKey + ":files")
            error = ""
            followsLatest = true
            openedAtLatest = false
            await refresh(force: true)
            return true
        } catch {
            optimisticPrompt = nil
            if queueing { followUps = followUps.postFailed(clientID) }
            rebuildHistory()
            if text.isEmpty { text = savedDraft }
            attachments = savedAttachments
            mode = savedMode
            if let http = error as? OrbHTTPError, [400, 422].contains(http.status) { OrbDisk.remove(pendingKey) }
            self.error = "Message kept. \(error.localizedDescription)"
            return false
        }
    }

    /// Waits for a send started by an earlier instance of this screen.
    private func settleInFlightSend() async {
        while OrbSendsInFlight.keys.contains(pendingKey) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        optimisticPrompt = nil
        if OrbDisk.read(pendingKey, as: OrbPending.self) != nil {
            error = "An earlier send needs verification. Retry sends the same request without creating a new identity."
        }
        rebuildHistory()
        await refresh(force: true)
    }

    private func move() async {
        guard let id, !destinationProject.isEmpty else { return }
        var tags = mission["tags"].items.filter { !$0.text.hasPrefix("orb-folder:") }
        if !destinationFolder.isEmpty { tags.append(.string("orb-folder:" + destinationFolder)) }
        do {
            _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/project", method: "POST", body: .object(["project": .string(destinationProject), "tags": .array(tags)]))
            moving = false
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            OrbReadCache.invalidate("project:\(destinationProject)")
            OrbReadCache.invalidate("project:\(destinationProject):all")
            await refresh(force: true)
        } catch { self.error = error.localizedDescription }
    }
    private func mutate(_ fields: [String: OrbJSON]) async {
        guard let id else { return }
        do {
            _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(fields["title"] != nil ? "title" : "status")", method: "POST", body: .object(fields))
            OrbReadCache.invalidate("project:\(project)")
            OrbReadCache.invalidate("project:\(project):all")
            await refresh(force: true)
        } catch { self.error = error.localizedDescription }
    }
    private func cancel() async {
        guard let id else { return }
        handoff = nil
        do { _ = try await api.call("/api/control/missions/\(OrbCore.escape(id))/\(isCloud ? "cloud/cancel" : "cancel")", method: "POST"); await refresh(force: true) } catch { self.error = error.localizedDescription }
    }
    private func removeQueued(_ message: String) async {
        if editingQueuedID == message { editingQueuedID = nil; text = "" }
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = followUps.hide(message) }
        do { _ = try await api.call("/api/control/queue/\(OrbCore.escape(message))", method: "DELETE"); await refresh(force: true) }
        catch let e as OrbHTTPError where e.status == 404 { await refresh(force: true) }
        catch {
            followUps = followUps.unhide(message)
            self.error = error.localizedDescription
        }
    }

    /// Edit in place via PATCH (same id and position); replace on 404/405 (older Core).
    private func editQueued(_ queueID: String, content: String) async {
        guard let id else { return }
        editingQueuedID = nil
        text = ""
        guard followUps.row(queueID) != nil else {
            error = "This message was already sent. Your edit was not applied."
            return
        }
        followUps = followUps.edit(queueID, content)
        var status: Int? = nil
        do {
            _ = try await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "PATCH", body: .object(["content": .string(content)]))
            status = 200
        } catch let e as OrbHTTPError { status = e.status } catch { status = nil }
        switch OrbSendFlow.editOutcome(status: status) {
        case .edited:
            followUps = followUps.editConfirmed(queueID, content)
        case .unsupported:
            followUps = followUps.editReverted(queueID).hide(queueID)
            _ = try? await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
            let clientID = UUID().uuidString
            followUps = followUps.enqueue(clientID, content)
            do {
                let result = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(content), "client_message_id": .string(clientID), "queue_followup": .bool(true)]))
                followUps = followUps.posted(clientID, queued: result["queued"] == .bool(true))
            } catch {
                followUps = followUps.postFailed(clientID)
                text = content
                self.error = "Couldn’t save the edit. Your text is back in the composer."
            }
        case .alreadySent:
            followUps = followUps.editReverted(queueID)
            error = "This message was already sent, so the edit was not applied."
        case .failed:
            followUps = followUps.editReverted(queueID)
            error = "Couldn’t save the edit."
        }
        await refresh(force: true)
    }

    /// Send now: the row leaves and the bubble appears together; Core promotes the
    /// message (stop, then it next under the same id) or injects it live.
    private func sendQueuedNow(_ queueID: String) async {
        guard let id, editingQueuedID == nil, let row = followUps.row(queueID), !row.sending else { return }
        let started = OrbHandoff(id: queueID, at: Date())
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
            followUps = followUps.hide(queueID)
            optimisticPrompt = row.content.trimmingCharacters(in: .whitespacesAndNewlines)
            handoff = started
            handoffTracker.reset()
            followsLatest = true
            rebuildHistory()
        }
        Task {
            try? await Task.sleep(for: .seconds(OrbHandoff.timeout))
            if handoff == started { handoff = nil }
        }
        do {
            let response = try await api.call("/api/control/queue/\(OrbCore.escape(queueID))/send-now?interrupt=true", method: "POST")
            switch OrbSendFlow.sendNowOutcome(response) {
            case .live: handoff = nil
            case .promoted: break
            case .fallback:
                // Older Core without promote: stop the turn, then send this message.
                _ = try? await api.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
                _ = try? await api.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST")
                _ = try await api.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(row.content), "client_message_id": .string(UUID().uuidString)]))
            }
            OrbReadCache.invalidate("mission:\(id)")
            await refresh(force: true)
        } catch {
            withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
                followUps = followUps.unhide(queueID)
                optimisticPrompt = nil
                handoff = nil
                rebuildHistory()
            }
            self.error = "Couldn’t send now. \(error.localizedDescription)"
        }
    }
    private func safeURL(_ value: String) -> URL? { guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil else { return nil }; return url }

    private func openWorkspaceOrArtifact(_ rawLink: String) async {
        if rawLink.hasPrefix("file:///") {
            guard let url = URL(string: rawLink) else { return }
            await downloadWorkspaceFile(url.path)
        } else if rawLink.hasPrefix("/srv/") || rawLink.hasPrefix("/Users/") || rawLink.hasPrefix("/root/") || rawLink.hasPrefix("/workspace/") || rawLink.hasPrefix("/home/") || rawLink.hasPrefix("/var/") || rawLink.hasPrefix("/tmp/") {
            let cleanPath = rawLink.components(separatedBy: "#").first ?? rawLink
            await downloadWorkspaceFile(cleanPath)
        } else {
            await download(rawLink.replacingOccurrences(of: "sandbox:", with: ""))
        }
    }

    private func downloadWorkspaceFile(_ path: String) async {
        let token = OrbCore.shared.authToken ?? ""
        var candidates: [[URLQueryItem]] = []
        if let id { candidates.append([.init(name: "path", value: path), .init(name: "mission_id", value: id)]) }
        candidates.append([.init(name: "path", value: path)])
        for query in candidates {
            var components = URLComponents(string: OrbCore.shared.endpoint + "/api/fs/download")
            components?.queryItems = query
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (tempFile, response) = try? await URLSession.shared.download(for: request) else { continue }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tempFile)
                continue
            }
            let name = path.components(separatedBy: "/").last ?? "file"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(["", ".", ".."].contains(name) ? "file" : name)
            try? FileManager.default.moveItem(at: tempFile, to: dest)
            preview = OrbPreviewFile(url: dest)
            return
        }
        error = "File preview unavailable for \(path.components(separatedBy: "/").last ?? path)."
    }

    private func download(_ path: String) async {
        guard let id else { return }
        do {
            let result = try await api.call("/api/control/missions/\(OrbCore.escape(id))/cloud/artifact?path=\(OrbCore.escape(path))")
            if let url = safeURL(result["url"].text) { await UIApplication.shared.open(url) }
            else if let data = Data(base64Encoded: result["content_base64"].text), data.count <= 50 * 1024 * 1024 {
                let name = (result["name"].text.isEmpty ? path : result["name"].text).components(separatedBy: "/").last ?? "artifact"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(["", ".", ".."].contains(name) ? "artifact" : name)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); preview = OrbPreviewFile(url: url)
            } else { error = "Artifact download unavailable." }
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Cursor-Style Work Model & Collapsible Activity Fold

struct OrbWorkModel: Equatable {
    struct ToolItem: Identifiable, Equatable {
        enum Status: Equatable { case running, done, error }
        let id: String
        let rawName: String
        let category: String
        let loadingLabel: String
        let completedLabel: String
        let target: String
        let argsText: String
        let outputText: String
        var status: Status
    }

    struct ThoughtItem: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        var streaming: Bool
    }

    struct TodoItem: Identifiable, Equatable {
        let id: String
        let content: String
        let status: String
    }

    var thoughts: [ThoughtItem] = []
    var tools: [ToolItem] = []
    var todos: [TodoItem] = []

    var isEmpty: Bool { thoughts.isEmpty && tools.isEmpty }

    func liveHeadline(fallback: String) -> (action: String, detail: String) {
        if let activeTool = tools.last(where: { $0.status == .running }) {
            return (activeTool.loadingLabel, activeTool.target)
        }
        if let lastThought = thoughts.last, lastThought.streaming {
            let detail = lastThought.title == "Thought" ? "" : lastThought.title
            return ("Thinking", detail)
        }
        return (fallback, "")
    }

    /// Matches Cursor's `buildSummaryParts` (`Worked — 3 reads, 2 edits, 1 command`).
    var completedSummary: String {
        let reads = tools.filter { $0.category == "read" }.count
        let searches = tools.filter { $0.category == "search" }.count
        let edits = tools.filter { $0.category == "edit" }.count
        let commands = tools.filter { $0.category == "command" }.count
        let fetches = tools.filter { $0.category == "web" }.count
        let tasks = tools.filter { $0.category == "task" }.count
        let others = tools.filter { $0.category == "other" }.count

        var parts: [String] = []
        if !thoughts.isEmpty && tools.isEmpty {
            return thoughts.count == 1 ? (thoughts[0].title == "Thought" ? "Thought" : "Thought · \(thoughts[0].title)") : "Thought (\(thoughts.count) steps)"
        }
        if reads > 0 { parts.append("\(reads) \(reads == 1 ? "read" : "reads")") }
        if searches > 0 { parts.append("\(searches) \(searches == 1 ? "search" : "searches")") }
        if edits > 0 { parts.append("\(edits) \(edits == 1 ? "edit" : "edits")") }
        if commands > 0 { parts.append("\(commands) \(commands == 1 ? "command" : "commands")") }
        if fetches > 0 { parts.append("\(fetches) \(fetches == 1 ? "fetch" : "fetches")") }
        if tasks > 0 { parts.append("\(tasks) \(tasks == 1 ? "agent" : "agents")") }
        if others > 0 { parts.append("\(others) \(others == 1 ? "step" : "steps")") }
        if parts.isEmpty { return "Worked" }
        return "Worked — " + parts.joined(separator: ", ")
    }

    static func build(from events: [StoredEvent], working: Bool) -> OrbWorkModel {
        var model = OrbWorkModel()
        var toolIndexByCallID: [String: Int] = [:]

        for (idx, event) in events.enumerated() {
            let isLastEvent = idx == events.count - 1
            switch event.eventType {
            case "user_message":
                // Like the desktop: the fold, counts and task list describe the
                // current turn, not every turn loaded so far.
                model = OrbWorkModel()
                toolIndexByCallID = [:]

            case "thinking":
                let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let (title, body) = parseThought(trimmed)
                if !model.thoughts.isEmpty && model.thoughts[model.thoughts.count - 1].body == body && model.thoughts[model.thoughts.count - 1].title == title {
                    model.thoughts[model.thoughts.count - 1].streaming = working && isLastEvent
                } else {
                    model.thoughts.append(ThoughtItem(id: "thought-\(event.sequence)", title: title, body: body, streaming: working && isLastEvent))
                }

            case "tool_call":
                let rawName = event.toolName ?? "tool"
                if ["ui_native_request", "AskUserQuestion", "question"].contains(rawName) { continue }
                let parsed = (try? JSONDecoder().decode(OrbJSON.self, from: Data(event.content.utf8))) ?? .null
                let lower = rawName.lowercased()
                if lower == "todowrite" || lower == "todo_write" || lower == "update_plan" {
                    let items = extractTodos(from: parsed)
                    if !items.isEmpty { model.todos = items }
                    continue
                }
                let meta = classifyTool(name: rawName, args: parsed, rawContent: event.content)
                let callID = event.toolCallId ?? "seq-\(event.sequence)"
                let item = ToolItem(
                    id: callID,
                    rawName: rawName,
                    category: meta.category,
                    loadingLabel: meta.loading,
                    completedLabel: meta.completed,
                    target: meta.target,
                    argsText: formatCompactJSON(event.content),
                    outputText: "",
                    status: working ? .running : .done
                )
                toolIndexByCallID[callID] = model.tools.count
                model.tools.append(item)

            case "tool_result":
                guard let callID = event.toolCallId, let toolIdx = toolIndexByCallID[callID] else { continue }
                let isError = event.metadata["is_error"]?.value as? Bool == true || event.content.lowercased().hasPrefix("error:")
                let output = formatCompactOutput(event.content)
                let old = model.tools[toolIdx]
                model.tools[toolIdx] = ToolItem(
                    id: old.id,
                    rawName: old.rawName,
                    category: old.category,
                    loadingLabel: old.loadingLabel,
                    completedLabel: old.completedLabel,
                    target: old.target,
                    argsText: old.argsText,
                    outputText: output,
                    status: isError ? .error : .done
                )

            case "goal_status", "goal_iteration":
                let text = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                model.tools.append(ToolItem(
                    id: "goal-\(event.sequence)",
                    rawName: event.eventType,
                    category: "other",
                    loadingLabel: "Updating goal",
                    completedLabel: "Goal update",
                    target: String(text.prefix(60)),
                    argsText: "",
                    outputText: text,
                    status: .done
                ))

            default:
                break
            }
        }

        // Keep the latest 40 tools so the fold stays snappy on long missions.
        if model.tools.count > 40 {
            model.tools = Array(model.tools.suffix(40))
        }
        if model.thoughts.count > 12 {
            model.thoughts = Array(model.thoughts.suffix(12))
        }
        return model
    }

    static func parseThought(_ text: String) -> (title: String, body: String) {
        let lines = text.components(separatedBy: .newlines)
        var lastHeader: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                lastHeader = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("#") {
                lastHeader = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            }
        }
        var body = text
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           (first.hasPrefix("**") && first.hasSuffix("**")) || first.hasPrefix("#") {
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (lastHeader ?? "Thought", body.isEmpty ? text : body)
    }

    private static func extractTodos(from json: OrbJSON) -> [TodoItem] {
        let candidates = !json["todos"].items.isEmpty ? json["todos"].items : (!json["plan"].items.isEmpty ? json["plan"].items : json["input"]["todos"].items)
        return candidates.enumerated().compactMap { idx, item in
            let text = !item["content"].text.isEmpty ? item["content"].text : (!item["step"].text.isEmpty ? item["step"].text : item["title"].text)
            guard !text.isEmpty else { return nil }
            let status = OrbTurnSummary.taskStatus(item["status"].text)
            return TodoItem(id: item["id"].text.isEmpty ? "todo-\(idx)" : item["id"].text, content: text, status: status)
        }
    }

    private static func classifyTool(name: String, args: OrbJSON, rawContent: String) -> (category: String, loading: String, completed: String, target: String) {
        let input = args["input"] != .null ? args["input"] : (args["arguments"] != .null ? args["arguments"] : args)
        let n = name.lowercased().replacingOccurrences(of: "-", with: "_")

        func shortPath(_ raw: String) -> String {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "" }
            let parts = clean.split(separator: "/").map(String.init)
            if parts.count >= 2 { return parts.suffix(2).joined(separator: "/") }
            return parts.last ?? clean
        }

        let filePath = [input["file_path"].text, input["path"].text, input["target_file"].text, input["file"].text, input["filename"].text].first(where: { !$0.isEmpty }) ?? ""
        let command = [input["command"].text, input["cmd"].text, input["CommandLine"].text].first(where: { !$0.isEmpty }) ?? ""
        let query = [input["pattern"].text, input["query"].text, input["Query"].text, input["search"].text].first(where: { !$0.isEmpty }) ?? ""
        let url = [input["url"].text, input["Url"].text].first(where: { !$0.isEmpty }) ?? ""

        if ["read", "read_file", "view_file", "cat"].contains(n) {
            return ("read", "Reading", "Read", shortPath(filePath))
        }
        if ["ls", "list_dir", "list_directory", "find_by_name", "glob"].contains(n) {
            let target = !filePath.isEmpty ? shortPath(filePath) : (!query.isEmpty ? query : "")
            return ("read", "Listing", "Listed", target)
        }
        if ["edit", "write", "write_file", "write_to_file", "replace_file_content", "multi_replace_file_content", "multiedit", "patch", "apply_patch", "notebookedit"].contains(n) {
            return ("edit", "Editing", "Edited", shortPath(filePath))
        }
        if ["bash", "run_command", "shell", "exec", "terminal"].contains(n) {
            let firstLine = command.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            let summary = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
            return ("command", "Running", "Ran", summary)
        }
        if ["grep", "grep_search", "rg", "ripgrep", "search", "semsearch"].contains(n) {
            let target = !query.isEmpty ? "\"\(query.prefix(36))\"" : shortPath(filePath)
            return ("search", "Searching", "Searched", target)
        }
        if ["websearch", "web_search", "search_web", "webfetch", "web_fetch", "read_url_content", "fetch"].contains(n) {
            let host = URL(string: url)?.host ?? (!query.isEmpty ? query : url)
            return ("web", "Fetching", "Fetched", String(host.prefix(40)))
        }
        if ["task", "subagent", "invoke_subagent", "delegate"].contains(n) {
            let desc = [input["description"].text, input["Role"].text, input["prompt"].text].first(where: { !$0.isEmpty }) ?? ""
            return ("task", "Working on task", "Completed task", String(desc.prefix(42)))
        }
        let fallbackTarget = !filePath.isEmpty ? shortPath(filePath) : (!command.isEmpty ? String(command.prefix(40)) : (!query.isEmpty ? String(query.prefix(36)) : ""))
        let cleanName = name.replacingOccurrences(of: "_", with: " ")
        return ("other", cleanName, cleanName, fallbackTarget)
    }

    private static func formatCompactJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return "" }
        return String(trimmed.prefix(800))
    }

    private static func formatCompactOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(1200))
    }
}

struct OrbWorkFold: View {
    let model: OrbWorkModel
    let working: Bool
    let headline: (action: String, detail: String)
    let elapsed: String
    let accessibilityStatus: String
    @State private var expanded = false
    @State private var expandedItemIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Expanded items render ABOVE the toggle button (matching Desktop WorkFold),
            // so the toggle button stays anchored at the bottom for easy collapsing.
            if expanded && !model.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.thoughts) { thought in
                        OrbThoughtRow(thought: thought, isExpanded: expandedItemIDs.contains(thought.id)) {
                            toggleItem(thought.id)
                        }
                    }
                    ForEach(model.tools) { tool in
                        OrbToolRow(tool: tool, isExpanded: expandedItemIDs.contains(tool.id)) {
                            toggleItem(tool.id)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(OrbStyle.borderStrong)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if working {
                Button {
                    guard !model.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 8) {
                        OrbRunningDots(size: 12)
                        HStack(spacing: 5) {
                            Text(headline.action)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(OrbStyle.textSecondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbShimmer(active: true)
                            if !headline.detail.isEmpty {
                                Text(headline.detail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(elapsed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if !model.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                                .rotationEffect(.degrees(expanded ? -90 : 0))
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityStatus)
                .accessibilityIdentifier("agent-working")
            } else if !model.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(OrbStyle.textMuted)
                            .rotationEffect(.degrees(expanded ? -90 : 0))
                        Text(model.completedSummary)
                            .font(.footnote)
                            .foregroundStyle(OrbStyle.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity-fold")
            }
        }
    }

    private func toggleItem(_ id: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if !expandedItemIDs.insert(id).inserted {
                expandedItemIDs.remove(id)
            }
        }
        OrbHaptics.selection()
    }
}

private struct OrbThoughtRow: View {
    let thought: OrbWorkModel.ThoughtItem
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded || thought.streaming {
                Text(thought.body)
                    .font(.caption)
                    .foregroundStyle(OrbStyle.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.leading, 12)
                    .padding(.vertical, 2)
            }

            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees((isExpanded || thought.streaming) ? -90 : 0))
                    Text(thought.streaming ? "Thinking" : "Thought")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbShimmer(active: thought.streaming)
                    if thought.title != "Thought" {
                        Text(thought.title)
                            .font(.caption)
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OrbToolRow: View {
    let tool: OrbWorkModel.ToolItem
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var copied = false

    private var hasDetails: Bool {
        !tool.argsText.isEmpty || !tool.outputText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: 6) {
                    let combined = [tool.argsText, tool.outputText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    HStack {
                        Text(tool.rawName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = combined
                            OrbHaptics.light()
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                copied = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy")
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? OrbStyle.success : OrbStyle.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(combined)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
                .padding(.leading, 14)
            }

            Button {
                if hasDetails { onTap() }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        switch tool.status {
                        case .running:
                            OrbRunningDots(size: 9)
                        case .done:
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(OrbStyle.textMuted)
                        case .error:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(OrbStyle.warning)
                        }
                    }
                    .frame(width: 12)

                    Text(tool.status == .running ? tool.loadingLabel : tool.completedLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tool.status == .error ? OrbStyle.warning : OrbStyle.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if !tool.target.isEmpty {
                        Text(tool.target)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(OrbStyle.textMuted)
                            .rotationEffect(.degrees(isExpanded ? -90 : 0))
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OrbMissionTasksCard: View {
    let todos: [OrbWorkModel.TodoItem]
    @State private var expanded = false

    private var completedCount: Int {
        todos.filter { $0.status == "completed" }.count
    }
    static func icon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "record.circle"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }
    private var activeTodo: OrbWorkModel.TodoItem? {
        todos.first { $0.status == "in_progress" } ?? todos.first { $0.status == "pending" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                OrbHaptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: completedCount == todos.count ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(completedCount == todos.count ? OrbStyle.success : OrbStyle.textSecondary)
                    Text("\(completedCount)/\(todos.count) tasks")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OrbStyle.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let active = activeTodo, !expanded {
                        Text("· \(active.content)")
                            .font(.caption)
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OrbStyle.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: Self.icon(item.status))
                                .font(.system(size: 11))
                                .foregroundStyle(item.status == "completed" ? OrbStyle.success : (item.status == "in_progress" ? .white : OrbStyle.textMuted))
                                .padding(.top, 2)
                            Text(item.content)
                                .font(.caption)
                                .foregroundStyle(item.status == "completed" ? OrbStyle.textMuted : .primary.opacity(0.9))
                                .strikethrough(item.status == "completed" || item.status == "cancelled")
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(OrbStyle.border))
    }
}

struct OrbSelection {
    var provider = "agent", account = "", backend = "", model = "", node = "", repository = "", gitRef = ""
    var serviceTier = "standard"
    var params: OrbJSON = .array([])
    var canCancel = false
    var cloud: Bool { provider != "agent" }
    var needsAgentSelection: Bool { cloud ? account.isEmpty : backend.isEmpty }
    var primaryIcon: String {
        if cloud { return "cloud" }
        switch backend {
        case "": return "cpu"
        case "claudecode": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "terminal"
        case "antigravity": return "wand.and.stars"
        case "grok": return "bolt.fill"
        default: return "cpu"
        }
    }
    var primaryPillLabel: String {
        if cloud {
            let service = ["chatgpt": "ChatGPT", "cursor_cloud": "Cursor", "grok_bot": "Grok", "hermes": "Hermes"][provider] ?? provider
            return model.isEmpty ? service : Self.shortModelName(model, harness: service)
        }
        if backend.isEmpty {
            return "Agent"
        }
        let harness = OrbStyle.serviceName(backend)
        if model.isEmpty {
            return harness
        }
        return Self.shortModelName(model, harness: harness)
    }
    var machinePillLabel: String? {
        guard !cloud, !node.isEmpty, node != "core" else { return nil }
        switch node {
        case "dgx-spark": return "spark"
        case "dgx-spark-admin": return "spark·admin"
        default: return node
        }
    }
    private static func shortModelName(_ raw: String, harness: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "/"), slash < s.index(before: s.endIndex) {
            s = String(s[s.index(after: slash)...])
        }
        for prefix in ["anthropic.", "openai.", "google.", "xai."] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // Strip trailing date stamps like -20250514
        if s.count > 10, let dash = s.lastIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            if tail.count == 8 && tail.allSatisfy(\.isNumber) {
                s = String(s[..<dash])
            }
        }
        if !harness.isEmpty, s.lowercased().hasPrefix(harness.lowercased() + " ") {
            let rest = String(s.dropFirst(harness.count + 1)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return s
    }
    var label: String { [cloud ? ["chatgpt": "ChatGPT", "cursor_cloud": "Cursor Cloud", "grok_bot": "Grok Bot", "hermes": "Hermes"][provider] ?? provider : backend.isEmpty ? "Select agent" : OrbStyle.serviceName(backend), model].filter { !$0.isEmpty }.joined(separator: " · ") }
    var compactLabel: String {
        if let machine = machinePillLabel {
            return "\(primaryPillLabel) · \(machine)"
        }
        return primaryPillLabel
    }
    var wire: OrbJSON {
        var value: [String: OrbJSON] = ["provider": .string(provider), "account": .string(account)]
        if !model.isEmpty { value["model"] = .string(model); if !params.items.isEmpty { value["model_params"] = params } }
        if !repository.isEmpty { value["repository"] = .string(repository) }
        if !gitRef.isEmpty { value["git_ref"] = .string(gitRef) }
        return .object(value)
    }
    mutating func restore(_ value: OrbJSON) { provider = value["provider"].text; account = value["account"].text; model = value["model"].text; params = value["model_params"] == .null ? .array([]) : value["model_params"]; repository = value["repository"].text; gitRef = value["git_ref"].text }
    func validate() throws {
        if cloud && account.isEmpty || !cloud && backend.isEmpty { throw OrbHTTPError(status: 400, detail: "Choose an available agent and account.") }
        if provider == "cursor_cloud" && (repository.isEmpty || gitRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { throw OrbHTTPError(status: 400, detail: "Choose a repository and Git reference for Cursor Cloud.") }
    }
    static func isUsableComputeNode(_ node: OrbJSON) -> Bool {
        guard node["status"].text == "online", !node["cordoned"].flag else { return false }
        let labels = node["labels"].items.map(\.text)
        return !labels.contains("manual-only")
    }
    static func sortedComputeNodes(_ rawNodes: [OrbJSON]) -> [OrbJSON] {
        let hasSparkAdmin = rawNodes.contains { $0["id"].text == "dgx-spark-admin" && $0["status"].text == "online" }
        let filtered = hasSparkAdmin ? rawNodes.filter { $0["id"].text != "dgx-spark" } : rawNodes
        return filtered.sorted { a, b in
            let aUsable = isUsableComputeNode(a)
            let bUsable = isUsableComputeNode(b)
            if aUsable != bUsable { return aUsable && !bUsable }
            let aJobs = a["active_jobs"].number ?? 0
            let bJobs = b["active_jobs"].number ?? 0
            if aJobs != bJobs { return aJobs < bJobs }
            let aFree = a["mem_available_bytes"].number ?? -1
            let bFree = b["mem_available_bytes"].number ?? -1
            if aFree != bFree { return aFree > bFree }
            return a["id"].text < b["id"].text
        }
    }
    static func firstAvailableNodeID(_ rawNodes: [OrbJSON]) -> String? {
        let sorted = sortedComputeNodes(rawNodes)
        guard let first = sorted.first(where: isUsableComputeNode) else { return nil }
        let id = first["id"].text
        return id.isEmpty ? nil : id
    }
}

struct OrbAgentPicker: View {
    @Binding var selection: OrbSelection
    let existing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [OrbJSON] = []
    @State private var models: [OrbJSON] = []
    @State private var backends: [OrbJSON] = []
    @State private var nodes: [OrbJSON] = []
    @State private var repos: [OrbJSON] = []
    @State private var backendModelsMap: OrbJSON = .null
    @State private var loadingOptions = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                if !error.isEmpty { OrbNotice(message: error) }
                if !existing {
                    Picker("Service", selection: $selection.provider) {
                        Text("Agent").tag("agent"); Text("Hermes").tag("hermes"); Text("ChatGPT").tag("chatgpt"); Text("Cursor Cloud").tag("cursor_cloud"); Text("Grok Bot").tag("grok_bot")
                    }.accessibilityIdentifier("picker.service")
                }
                if selection.cloud {
                    Picker("Account", selection: $selection.account) {
                        Text("Choose account").tag("")
                        ForEach(accounts.filter { $0["provider"].text == selection.provider }.indices, id: \.self) { index in
                            let account = accounts.filter { $0["provider"].text == selection.provider }[index]
                            Text(account["label"].text.isEmpty ? account["id"].text : account["label"].text).tag(account["id"].text).disabled(!account["available"].flag)
                        }
                    }.disabled(existing).accessibilityIdentifier("picker.account")
                    if selection.provider == "cursor_cloud" && !existing {
                        Picker("Repository", selection: $selection.repository) { Text("Choose repository").tag(""); ForEach(repos.indices, id: \.self) { Text(repos[$0]["url"].text).tag(repos[$0]["url"].text) } }.accessibilityIdentifier("picker.repository")
                        TextField("Git reference (required)", text: $selection.gitRef).accessibilityIdentifier("picker.git-ref").textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    Picker("Harness", selection: $selection.backend) { Text("Choose harness").tag(""); ForEach(backends.indices, id: \.self) { Text(backends[$0]["name"].text.isEmpty ? backends[$0]["id"].text : backends[$0]["name"].text).tag(backends[$0]["id"].text) } }.disabled(existing).accessibilityIdentifier("picker.harness")
                    if !existing { Picker("Machine", selection: $selection.node) { Text("Core").tag("core"); ForEach(nodes.indices, id: \.self) { Text(nodes[$0]["name"].text.isEmpty ? nodes[$0]["id"].text : nodes[$0]["name"].text).tag(nodes[$0]["id"].text) } } }
                }
                if selection.provider != "grok_bot" { Picker("Model", selection: $selection.model) {
                    Text("Service default").tag("")
                    ForEach(models.filter { !($0["id"].text.isEmpty && $0["value"].text.isEmpty) }.indices, id: \.self) { index in
                        let filtered = models.filter { !($0["id"].text.isEmpty && $0["value"].text.isEmpty) }
                        let model = filtered[index]
                        let display = !model["displayName"].text.isEmpty ? model["displayName"].text : (!model["name"].text.isEmpty ? model["name"].text : (!model["label"].text.isEmpty ? model["label"].text : model["id"].text))
                        Text(display).tag(model["id"].text.isEmpty ? model["value"].text : model["id"].text)
                    }
                }.accessibilityIdentifier("picker.model") }
                if let model = models.first(where: { $0["id"].text == selection.model }), model["variants"].items.count > 1 {
                    let variants = model["variants"].items
                    Picker("Configuration", selection: Binding(get: { variants.firstIndex(where: { $0["params"] == selection.params }) ?? 0 }, set: { selection.params = variants[$0]["params"] })) {
                        ForEach(variants.indices, id: \.self) { index in
                            Text(variants[index]["displayName"].text.isEmpty ? variants[index]["params"].items.map { $0["value"].text }.joined(separator: " · ") : variants[index]["displayName"].text).tag(index)
                        }
                    }
                }
                if !selection.cloud && selection.backend == "codex" && !selection.model.isEmpty {
                    OrbCodexSpeedSection(model: selection.model, tier: $selection.serviceTier)
                }
                if loadingOptions && models.isEmpty {
                    HStack(spacing: 8) {
                        OrbRunningDots(size: 10)
                        Text("Loading options…").font(.footnote).foregroundStyle(OrbStyle.textSecondary)
                    }
                }
                if existing && selection.provider != "grok_bot" { Text("Model changes apply to the next message.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Agent settings").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively).toolbar { Button("Done") { dismiss() } }
            .task { await load() }
            .onChange(of: selection.provider) { _, _ in selection.account = ""; selection.model = ""; selection.params = .array([]); Task { await load() } }
            .onChange(of: selection.backend) { _, _ in Task { await loadModels() } }
            .onChange(of: selection.model) { _, _ in selection.params = models.first(where: { $0["id"].text == selection.model })?["variants"].items.first?["params"] ?? .array([]) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func applyAgentCatalog(_ catalog: OrbJSON) {
        let response = catalog["backends"]
        backends = (response.items.isEmpty ? response["backends"].items : response.items)
            .filter { $0["id"].text != "chatgpt_ui" }
        if !existing && selection.backend == "chatgpt_ui" {
            selection.backend = ""; selection.model = ""; selection.params = .array([])
        }
        nodes = OrbSelection.sortedComputeNodes(catalog["nodes"]["nodes"].items)
        if !existing && selection.node.isEmpty {
            selection.node = OrbSelection.firstAvailableNodeID(nodes) ?? "core"
        }
        backendModelsMap = catalog["models"]["backends"]
        models = backendModelsMap[selection.backend].items
    }
    private func load() async {
        loadingOptions = true
        defer { loadingOptions = false }
        do {
            if selection.cloud {
                if let cachedAccounts = OrbReadCache.read("catalog:cloud:accounts") {
                    accounts = cachedAccounts.items
                }
                let provider = selection.provider
                if provider != "grok_bot" {
                    let endpoint = provider == "hermes" ? "hermes" : (provider == "chatgpt" ? "chatgpt" : "cursor")
                    if let cachedOpts = OrbReadCache.read("catalog:cloud:\(endpoint)") {
                        models = cachedOpts["models"]["items"].items
                        repos = cachedOpts["repositories"]["items"].items
                    }
                    async let accountsTask = OrbReadCache.cloudAccounts()
                    async let optionsTask = OrbReadCache.cloudOptions(endpoint)
                    let (accValue, optValue) = try await (accountsTask, optionsTask)
                    accounts = accValue.items
                    if selection.provider == provider {
                        models = optValue["models"]["items"].items
                        repos = optValue["repositories"]["items"].items
                    }
                } else {
                    accounts = try await OrbReadCache.cloudAccounts().items
                    models = []
                }
            } else {
                if let cached = OrbReadCache.read("catalog:agent") {
                    applyAgentCatalog(cached)
                }
                let catalog = try await OrbReadCache.agentCatalog()
                applyAgentCatalog(catalog)
            }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func loadModels() async {
        let provider = selection.provider, backend = selection.backend
        if !selection.cloud && backendModelsMap != .null {
            models = backendModelsMap[backend].items
            return
        }
        do {
            if selection.cloud {
                guard provider != "grok_bot" else { models = []; return }
                let endpoint = provider == "hermes" ? "hermes" : (provider == "chatgpt" ? "chatgpt" : "cursor")
                if let cachedOpts = OrbReadCache.read("catalog:cloud:\(endpoint)") {
                    models = cachedOpts["models"]["items"].items
                    repos = cachedOpts["repositories"]["items"].items
                }
                let value = try await OrbReadCache.cloudOptions(endpoint)
                guard selection.provider == provider else { return }
                models = value["models"]["items"].items; repos = value["repositories"]["items"].items
            } else {
                let catalog = try await OrbReadCache.agentCatalog()
                guard selection.backend == backend && selection.provider == provider else { return }
                backendModelsMap = catalog["models"]["backends"]
                models = backendModelsMap[backend].items
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Cloud turns carry no timestamps; time each from when this device first saw it working.
@MainActor enum OrbWorkClock {
    private static var starts: [String: Date] = [:]
    static func start(_ key: String) -> Date { if let date = starts[key] { return date }; let now = Date(); starts[key] = now; return now }
    static func stop(_ key: String) { starts[key] = nil }
}

/// Double-tapping anywhere in the conversation closes the keyboard. Messages
/// render through UIKit text and web views that swallow SwiftUI gestures, so
/// this is a window-level recognizer that never cancels their touches and
/// ignores double-taps inside the focused field (word selection).
struct OrbDoubleTapDismissesKeyboard: UIViewRepresentable {
    let active: Bool
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.recognizer.isEnabled = active
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
            window?.addGestureRecognizer(coordinator.recognizer)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var dismiss: () -> Void = {}
        lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(fire))
            recognizer.numberOfTapsRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        @objc private func fire() { dismiss() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current.isFirstResponder { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Sends survive leaving the screen; a reopened conversation must not mistake
/// one still awaiting Core for a failed send.
@MainActor enum OrbSendsInFlight {
    static var keys: Set<String> = []
}
