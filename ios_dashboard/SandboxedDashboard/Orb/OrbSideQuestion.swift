import SwiftUI

/// Harness and model of the /btw side agent (Orb: Settings → Side Questions).
@MainActor
enum OrbBtwConfig {
    private static let harnessKey = "orb.btw.harness", modelKey = "orb.btw.model"
    static let harnesses: [(String, String)] = [("opencode", "OpenCode"), ("claudecode", "Claude Code"), ("codex", "Codex"), ("grok", "Grok")]
    static var harness: String {
        get { UserDefaults.standard.string(forKey: harnessKey) ?? "opencode" }
        set { UserDefaults.standard.set(newValue, forKey: harnessKey) }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "builtin/smart" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    /// One side session per parent conversation and backend.
    static func sessionKey(_ parent: String) -> String { "orb.btw.session:\(OrbCore.shared.endpoint):\(parent)" }
}

struct OrbBtwSettingsView: View {
    @State private var harness = OrbBtwConfig.harness
    @State private var model = OrbBtwConfig.model
    @State private var message = ""
    var body: some View {
        Form {
            Section {
                Picker("Harness", selection: $harness) {
                    ForEach(OrbBtwConfig.harnesses, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("An independent agent in the main agent's folder, with the normal harness tools and permissions. Files are shared with the main agent.")
            }
            Section {
                Button("Save") {
                    OrbBtwConfig.harness = harness
                    OrbBtwConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    message = "Saved. Applies to the next side question."
                }
                .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden).background(OrbStyle.background)
        .navigationTitle("Quick questions (/btw)").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - /btw threads (desktop `btwAgent.ts`: `reconcileBtwServerHistory`, `sideAnswer`)

/// Pure rules for reading /btw side threads from Core, shared with Orb desktop.
enum OrbBtwThreads {
    /// One answered side question.
    struct Turn: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let question: String
        let answer: String
        var narration: [String] = []
        let at: String
    }

    /// The bound thread's unanswered question, while its agent works.
    struct OpenTurn: Equatable {
        let id: String
        let question: String
        let at: String
        /// Events after the question: the live turn's tools, thoughts and text.
        let events: [StoredEvent]
        let answer: String
        let narration: [String]

        static func == (a: OpenTurn, b: OpenTurn) -> Bool {
            a.id == b.id && a.question == b.question && a.answer == b.answer && a.narration == b.narration
                && a.events.count == b.events.count && a.events.last?.sequence == b.events.last?.sequence
        }
    }

    static let liveStatuses: Set<String> = ["active", "running", "pending", "queued", "starting", "resuming", "waiting_background", "paused"]
    static let resumableStatuses: Set<String> = ["awaiting_user", "completed", "interrupted"]

    /// The side agent's prompt embeds the parent conversation; show only the request.
    static func question(_ content: String) -> String {
        var text = content
        if let range = text.range(of: "Current request:\n", options: .backwards) { text = String(text[range.upperBound...]) }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.reversed().drop(while: { $0.hasPrefix("Attachment: ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func synthetic(_ text: String) -> Bool {
        text.range(of: #"^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} (?:on node '[^']+' )?(?:finished with(?:out assistant text| state)|reached state) "#, options: .regularExpression) != nil
            || text.hasPrefix("Native Codex goal stopped with status ")
    }

    /// OpenCode auto-compaction writes a summary turn ("## Objective …") and a
    /// synthetic "Continue if you have next steps…" prompt; older Core builds
    /// stored both inside the side agent's answer.
    static func stripCompaction(_ text: String) -> String {
        let pattern = #"(?:^|\n)## Objective\n[\s\S]*?\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed\.[^\S\n]*(?:\n|$)"#
        var out = text.replacingOccurrences(of: pattern, with: "\n\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The turn's answer is its final message; earlier text is progress narration.
    static func sideAnswer(_ texts: [String], final: String? = nil) -> (answer: String, narration: [String]) {
        func meaningful(_ t: String) -> Bool { !t.replacingOccurrences(of: #"[.\s…]"#, with: "", options: .regularExpression).isEmpty }
        var clean: [String] = []
        for raw in texts {
            let t = stripCompaction(raw)
            if meaningful(t) && clean.last != t { clean.append(t) }
        }
        let recorded = final.map(stripCompaction) ?? ""
        if meaningful(recorded) {
            let before = clean.lastIndex(of: recorded).map { Array(clean[..<$0]) } ?? clean
            return (recorded, before.filter { $0 != recorded })
        }
        return (clean.last ?? "", Array(clean.dropLast()))
    }

    /// The side threads of a conversation, oldest first; recovered ones are skipped.
    static func threads(_ rows: [OrbJSON], parent: String) -> [OrbJSON] {
        let tag = "btw-parent:\(parent)"
        return rows.filter { m in
            let tags = m["tags"].items.map(\.text)
            return !m["id"].text.isEmpty && tags.contains(tag) && !tags.contains("superseded")
        }
        .sorted { $0["created_at"].text < $1["created_at"].text }
    }

    static func activity(_ m: OrbJSON) -> String {
        for key in ["last_activity_at", "updated_at", "created_at"] where !m[key].text.isEmpty { return m[key].text }
        return ""
    }

    /// Each /btw question re-dispatches a job on the same mission, so an old
    /// thread can be the live one: bind to the thread with the latest activity.
    static func latest(_ threads: [OrbJSON]) -> OrbJSON? {
        threads.enumerated().max { a, b in
            let x = activity(a.element), y = activity(b.element)
            return x == y ? a.offset < b.offset : x < y
        }?.element
    }

    /// Answered turns of one thread and, when it is still working, its open question.
    static func parse(missionID: String, events: [StoredEvent], active: Bool) -> (turns: [Turn], open: OpenTurn?) {
        let ordered = events.sorted { $0.sequence < $1.sequence }
        var turns: [Turn] = []
        var question = "", at = "", seq: Int64 = 0, start = 0
        var texts: [String] = []
        var final: String?
        func flush() {
            let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = sideAnswer(texts, final: final)
            if !q.isEmpty && !result.answer.isEmpty && !synthetic(result.answer) {
                turns.append(Turn(id: "btw:\(missionID):\(seq)", question: q, answer: result.answer, narration: result.narration, at: at))
            }
            question = ""; texts = []; final = nil
        }
        for (index, e) in ordered.enumerated() {
            switch e.eventType {
            case "user_message":
                if !question.isEmpty { flush() }
                question = Self.question(e.content); at = e.timestamp; seq = e.sequence; start = index + 1
            case "assistant_message", "assistant_message_canonical":
                let text = e.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !synthetic(text) else { continue }
                if e.eventType == "assistant_message" { final = text }
                if texts.last != text { texts.append(text) }
            default: break
            }
        }
        if active && !question.isEmpty {
            // Like the desktop, the live draft is the latest text, not the stored final.
            let live = sideAnswer(texts)
            return (turns, OpenTurn(id: "btw:\(missionID):\(seq)", question: question, at: at, events: Array(ordered[start...]), answer: live.answer, narration: live.narration))
        }
        if !question.isEmpty { flush() }
        return (turns, nil)
    }

    /// Every thread's turns, in the order they were asked.
    static func merge(_ perThread: [[Turn]]) -> [Turn] {
        let all: [Turn] = perThread.flatMap { $0 }
        let indexed: [(offset: Int, turn: Turn)] = all.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { (a: (offset: Int, turn: Turn), b: (offset: Int, turn: Turn)) -> Bool in
            if a.turn.at != b.turn.at { return a.turn.at < b.turn.at }
            return a.offset < b.offset
        }
        return sorted.map { $0.turn }
    }
}

/// The /btw state of one conversation, kept in memory and on disk so the sheet
/// opens on its history at once. The conversation warms it before the sheet opens.
@Observable @MainActor
final class OrbBtwStore {
    private static var stores: [String: OrbBtwStore] = [:]
    static func shared(_ parent: String) -> OrbBtwStore {
        let key = OrbBtwConfig.sessionKey(parent)
        if let store = stores[key] { return store }
        let store = OrbBtwStore(parent: parent)
        stores[key] = store
        return store
    }

    let parent: String
    private(set) var turns: [OrbBtwThreads.Turn]
    private(set) var open: OrbBtwThreads.OpenTurn?
    /// The thread new questions continue (latest activity), and its mission.
    private(set) var bound: OrbJSON = .null
    private(set) var loaded = false
    private var eventCache: [String: (stamp: String, events: [StoredEvent])] = [:]
    private var refreshing: Task<Void, Error>?

    var boundID: String? { bound["id"].text.isEmpty ? nil : bound["id"].text }
    var boundStatus: String { bound["status"].text }
    var running: Bool { OrbBtwThreads.liveStatuses.contains(boundStatus) }
    private var cacheKey: String { "btw:turns:" + parent }

    private init(parent: String) {
        self.parent = parent
        turns = OrbDisk.read("btw:turns:" + parent, as: [OrbBtwThreads.Turn].self) ?? []
        loaded = !turns.isEmpty
    }

    /// Concurrent callers share one refresh.
    func refresh() async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await load() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    /// A question was just posted to `id`: follow it as live until Core reports it.
    func sent(to id: String) {
        if boundID != id { bound = .object(["id": .string(id), "status": .string("running")]) }
        else if !running, case .object(var fields) = bound { fields["status"] = .string("running"); bound = .object(fields) }
        eventCache[id] = nil
    }

    private func load() async throws {
        let tag = "btw-parent:\(parent)"
        let rows = try await OrbCore.shared.call("/api/control/missions?tag=\(OrbCore.escape(tag))&all=true&limit=50")
        let threads = OrbBtwThreads.threads(rows["missions"].items.isEmpty ? rows.items : rows["missions"].items, parent: parent)
        var fetched: [String: [StoredEvent]] = [:]
        // Threads are read concurrently; a finished thread whose activity has
        // not changed is not read again.
        var reads: [(id: String, stamp: String, task: Task<[StoredEvent]?, Never>)] = []
        for m in threads {
            let id = m["id"].text, stamp = OrbBtwThreads.activity(m) + m["status"].text
            let live = OrbBtwThreads.liveStatuses.contains(m["status"].text)
            if !live, let cached = eventCache[id], cached.stamp == stamp { fetched[id] = cached.events; continue }
            reads.append((id, stamp, Task { try? await OrbCore.shared.getMissionEventsWithMeta(id: id, limit: 1000).events }))
        }
        for read in reads {
            guard let events = await read.task.value else { continue }
            fetched[read.id] = events
            eventCache[read.id] = (read.stamp, events)
        }
        try Task.checkCancellation()
        var perThread: [[OrbBtwThreads.Turn]] = []
        var opens: [String: OrbBtwThreads.OpenTurn] = [:]
        for m in threads {
            let id = m["id"].text
            guard let events = fetched[id] else {
                // A failed read keeps what was shown for that thread.
                perThread.append(turns.filter { $0.id.hasPrefix("btw:\(id):") })
                continue
            }
            let result = OrbBtwThreads.parse(missionID: id, events: events, active: OrbBtwThreads.liveStatuses.contains(m["status"].text))
            perThread.append(result.turns)
            if let open = result.open { opens[id] = open }
        }
        // A live thread wins; otherwise the latest activity.
        let latestLive = threads.filter { opens[$0["id"].text] != nil }.last
        let next = latestLive ?? OrbBtwThreads.latest(threads) ?? .null
        let merged = OrbBtwThreads.merge(perThread)
        // A just-posted question may not be listed yet: keep following it.
        if let id = boundID, running, !threads.contains(where: { $0["id"].text == id }) {
            if merged != turns { turns = merged }
            loaded = true
            return
        }
        if merged != turns { turns = merged; OrbDisk.saveAsync(merged, key: cacheKey) }
        let nextOpen = opens[next["id"].text]
        if nextOpen != open { open = nextOpen }
        if next != bound { bound = next }
        if let id = boundID { UserDefaults.standard.set(id, forKey: OrbBtwConfig.sessionKey(parent)) }
        loaded = true
    }
}

/// `/btw`: ask an independent side agent about a conversation without
/// interrupting it. Core forks a side session (`POST …/btw/agent`) that shares
/// the main agent's working directory; follow-ups continue that session.
/// Messages, Markdown and the composer are the conversation tab's components.
struct OrbSideQuestionSheet: View {
    let parentID: String
    @State var question: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var store: OrbBtwStore
    @State private var dictation = OrbDictation()
    @State private var attachments: [OrbAttachment] = []
    @State private var busy = false
    @State private var error = ""
    @FocusState private var focused: Bool
    /// "New side session": keep showing history, but don't continue the old thread.
    @State private var freshSession = false
    /// The question just sent, shown at once until Core's history has it.
    @State private var pending: String?
    @State private var askedAt: Date?
    @State private var autoAsked = false
    @State private var scroller = OrbTranscriptScroller()

    init(parentID: String, question: String) {
        self.parentID = parentID
        _question = State(initialValue: question)
        _store = State(initialValue: OrbBtwStore.shared(parentID))
    }

    private var running: Bool { store.running }
    private var waiting: Bool { running || pending != nil }
    /// The optimistic bubble, until Core's thread holds the question.
    private var pendingBubble: String? {
        guard let pending else { return nil }
        if store.open?.question == pending { return nil }
        if let askedAt, let last = store.turns.last, last.question == pending,
           let at = OrbTurnSummary.parseDate(last.at), at >= askedAt.addingTimeInterval(-5) { return nil }
        return pending
    }
    private var canSend: Bool { !busy && !running && pending == nil && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            OrbTranscriptScrollView(identifier: "btw", scroller: scroller, working: waiting) {
                transcript
            }
            .scrollDismissesKeyboard(.interactively)
            // Tapping the transcript hides the keyboard, like the conversation tab
            // (simultaneous: links and buttons in the transcript still get the tap).
            .simultaneousGesture(TapGesture().onEnded { if focused { focused = false } })
            .onChange(of: store.turns.count) { _, _ in if scroller.pinned { scroller.scrollToBottom(animated: true) } }
            .onChange(of: pending) { _, value in if value != nil { scroller.scrollToBottom(animated: true) } }
            .onChange(of: focused) { _, value in if value && scroller.metrics.distanceFromBottom <= OrbTranscriptScroller.pillThreshold { scroller.scrollToBottom(animated: true) } }
            .background(OrbStyle.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Side question").navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: phase) { await follow() }
            .onAppear {
                // `/btw <question>` from the composer was already a send: don't ask for a second tap.
                let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty && !autoAsked {
                    autoAsked = true
                    Task { await ask() }
                } else if store.loaded && store.turns.isEmpty && store.open == nil {
                    focused = true
                }
            }
            .onChange(of: store.loaded) { _, loaded in
                if loaded && store.turns.isEmpty && store.open == nil && pending == nil { focused = true }
            }
        }
        // One stable detent: the keyboard never resizes it to half, and only a
        // downward drag (or Done) dismisses it.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !error.isEmpty { OrbNotice(message: error) }
            if !store.loaded && store.turns.isEmpty {
                loadingPlaceholder
            } else if store.turns.isEmpty && store.open == nil && pendingBubble == nil {
                Text("Ask about this conversation without interrupting it. The side agent reads the conversation and shares its working folder.")
                    .font(.footnote).foregroundStyle(OrbStyle.textSecondary)
                    .accessibilityIdentifier("btw.intro")
            }
            ForEach(store.turns) { turn in
                OrbUserBubble(text: turn.question).id(turn.id)
                OrbBtwNarration(updates: turn.narration)
                OrbAssistantMessage(text: turn.answer).id(turn.id + ":a")
            }
            if let open = store.open {
                OrbUserBubble(text: open.question, pending: true).id(open.id)
                liveRow(open)
            }
            if let pendingBubble {
                OrbUserBubble(text: pendingBubble, pending: true)
                if store.open == nil { liveRow(nil) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The conversation tab's Working row, then the answer as it streams.
    @ViewBuilder
    private func liveRow(_ open: OrbBtwThreads.OpenTurn?) -> some View {
        let model = OrbWorkModel.build(from: open?.events ?? [], working: true)
        let start = open.flatMap { OrbTurnSummary.parseDate($0.at) } ?? askedAt
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let headline = model.liveHeadline(fallback: statusText(open))
            let elapsed = start.map { OrbTurnSummary.clock(Int(context.date.timeIntervalSince($0))) } ?? ""
            OrbWorkFold(
                model: model,
                working: true,
                headline: headline,
                elapsed: elapsed,
                accessibilityStatus: [headline.detail.isEmpty ? headline.action : "\(headline.action) \(headline.detail)", elapsed].filter { !$0.isEmpty }.joined(separator: " · "),
                identifier: "btw.progress"
            )
        }
        if let open {
            OrbBtwNarration(updates: open.narration)
            if !open.answer.isEmpty {
                OrbRichText(source: open.answer).frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 80)
                Text("Side question placeholder line")
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("First line of the side agent's answer placeholder.").font(.subheadline)
                Text("Second line of the answer placeholder.").font(.subheadline)
            }
        }
        .redacted(reason: .placeholder)
        .orbShimmer(active: true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading side questions")
        .accessibilityIdentifier("btw.loading")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() }.accessibilityIdentifier("btw.done") }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if running { Button("Stop side agent", role: .destructive) { Task { await stop() } } }
                Button("New side session") { freshSession = true; error = "" }.disabled(running || store.boundID == nil || freshSession)
                Text("\(OrbStyle.serviceName(OrbBtwConfig.harness)) · \(OrbBtwConfig.model)")
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("Side question options")
        }
    }

    private func statusText(_ open: OrbBtwThreads.OpenTurn?) -> String {
        if pending != nil && !running { return store.boundID == nil || freshSession ? "Starting side agent…" : "Sending…" }
        switch store.boundStatus {
        case "paused": return "Side agent paused"
        case "waiting_background": return "Waiting for background work…"
        case "pending", "queued", "starting", "resuming": return "Waiting to start…"
        default: return open?.answer.isEmpty == false ? "Writing…" : "Working…"
        }
    }

    private var composer: some View {
        OrbComposerBox(
            placeholder: "Ask a side question",
            text: $question,
            focused: $focused,
            dictation: dictation,
            busy: busy,
            canSend: canSend,
            showStop: running,
            fieldIdentifier: "btw.input",
            sendIdentifier: "btw.send",
            sendLabel: "Send side question",
            stopLabel: "Stop side agent",
            containerIdentifier: "btw-composer",
            onSend: { Task { await ask() } },
            onStop: { Task { await stop() } }
        ) {
            if !attachments.isEmpty { OrbAttachments(files: $attachments, error: $error, canAdd: false) }
        } leading: {
            OrbAttachments(files: $attachments, error: $error, showFiles: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(OrbStyle.background)
    }

    private func follow() async {
        guard phase == .active else { return }
        await Poller.run(every: { .seconds(waiting || busy ? 1.5 : 15) }) {
            do {
                try await store.refresh()
                settlePending()
                return true
            } catch is CancellationError { return true } catch {
                if store.turns.isEmpty { self.error = error.localizedDescription }
                return false
            }
        }
    }

    private func settlePending() {
        if pending != nil && !busy && pendingBubble == nil { pending = nil; askedAt = nil }
    }

    private func ask() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        busy = true; defer { busy = false }
        withAnimation(.snappy(duration: 0.18)) { pending = text; askedAt = Date(); question = "" }
        let files = attachments
        attachments = []
        // One id per question: every resend after a dropped connection carries it,
        // so Core accepts the question at most once (desktop `askBtwAgent`).
        let messageID = UUID().uuidString
        do {
            if !store.loaded { try await store.refresh() }
            if running { throw OrbHTTPError(status: 409, detail: "The side agent is still running. Stop it before sending another question.") }
            let parent = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))")
            if parent["tags"].items.contains(where: { $0.text == "placement:client" }) {
                throw OrbHTTPError(status: 409, detail: "This conversation runs on a computer. Ask side questions from Orb on that computer.")
            }
            // Like the desktop: files go to the shared working folder, named in the request.
            var content = text
            for file in files {
                let node = OrbContinuation.remoteNodeID(for: parent)
                let receipt = try await OrbCore.shared.call("/api/uploads", method: "POST", body: .object(["node_id": .string(node), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                content += "\nAttachment: " + receipt["path"].text
            }
            if let id = store.boundID, !freshSession, OrbBtwThreads.resumableStatuses.contains(store.boundStatus) {
                _ = try await OrbSideSend.retrying { try await OrbCore.shared.call("/api/control/message", method: "POST", body: .object([
                    "mission_id": .string(id), "content": .string(content), "client_message_id": .string(messageID),
                ])) }
                store.sent(to: id)
            } else {
                let created = try await OrbSideSend.retrying { try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))/btw/agent", method: "POST", body: .object([
                    "backend": .string(OrbBtwConfig.harness), "model_override": .string(OrbBtwConfig.model), "model_effort": .null,
                    "idempotency_key": .string(messageID), "side_question": .string(content),
                ])) }
                freshSession = false
                store.sent(to: created["id"].text)
            }
            error = ""
            try? await store.refresh()
        } catch let e as OrbHTTPError where [404, 405].contains(e.status) && store.boundID == nil {
            restore(text, files)
            error = "This backend does not support /btw side agents yet."
        } catch {
            restore(text, files)
            self.error = error.localizedDescription
        }
    }

    /// A failed send puts the question back in the field instead of losing it.
    private func restore(_ text: String, _ files: [OrbAttachment]) {
        pending = nil; askedAt = nil
        if question.isEmpty { question = text }
        if attachments.isEmpty { attachments = files }
    }

    private func stop() async {
        guard let id = store.boundID else { return }
        do { _ = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST"); try await store.refresh() }
        catch { self.error = error.localizedDescription }
    }
}

/// Earlier narration of a side turn, folded like the desktop ("N progress updates").
struct OrbBtwNarration: View {
    let updates: [String]
    @State private var expanded = false
    var body: some View {
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("\(updates.count) progress update\(updates.count == 1 ? "" : "s")")
                            .font(.footnote)
                        Spacer()
                    }
                    .foregroundStyle(OrbStyle.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(updates.count) progress update\(updates.count == 1 ? "" : "s")")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("btw.narration")
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(updates.enumerated()), id: \.offset) { _, text in OrbRichText(source: text) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(OrbStyle.borderStrong).frame(width: 1) }
                    .opacity(0.8)
                }
            }
        }
    }
}

struct OrbSideQuestionRequest: Identifiable {
    let id = UUID()
    let parent: String
    let question: String
}

extension OrbConversation {
    /// `/btw <question>` in the composer opens a side question instead of messaging the agent.
    static func btwQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/btw" { return "" }
        guard trimmed.hasPrefix("/btw ") || trimmed.hasPrefix("/btw\n") else { return nil }
        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resends an idempotent side-question write after a dropped or timed-out
/// connection (1, 2, 4, 8 s), like desktop `askBtwAgent`. Other errors and
/// cancellation are thrown at once.
@MainActor
enum OrbSideSend {
    static let backoff: [UInt64] = [1, 2, 4, 8]
    static func transient(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code)
    }
    static func retrying<T>(_ work: () async throws -> T) async throws -> T {
        for delay in backoff {
            do { return try await work() } catch where transient(error) {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        return try await work()
    }
}
