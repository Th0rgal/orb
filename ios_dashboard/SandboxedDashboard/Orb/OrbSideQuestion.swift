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
                LabeledContent("Model") {
                    TextField("builtin/smart", text: $model)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
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
    static let transcriptEventTypes = ["user_message", "assistant_message", "assistant_message_canonical"]
    static let automaticUserSources: Set<String> = [
        "api:usage-limit-replay",
        "background-task",
        "scheduler",
        "idle-worker-watchdog",
        "transport_auto_resume",
        "remote-build-terminal",
        "task-board",
    ]
    static let resumePromptText = "Your previous turn was interrupted before it finished. Check what is already done, then continue from there. Do not redo finished work."

    static func isAutomaticUserEvent(_ content: String, metadata: [String: AnyCodable] = [:]) -> Bool {
        if let source = metadata["source"]?.value as? String, automaticUserSources.contains(source) { return true }
        if metadata["backgroundWake"] != nil { return true }
        if (metadata["resumePrompt"]?.value as? Bool) == true { return true }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^\[Automatic (?:recovery|resume after a usage limit)\]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed == resumePromptText { return true }
        return trimmed.hasPrefix("Background task `") && trimmed.hasSuffix("\n\nContinue from here.")
    }
    static let maxSessionEvents: Int64 = 400
    static let maxSessionTurns = 8
    static let initialVisibleTurns = 20
    static let visibleTurnsStep = 20
    static let maxConcurrentThreadLoads = 4

    static func shouldRotateSession(turnCount: Int, maxSequence: Int64) -> Bool {
        turnCount >= maxSessionTurns || maxSequence >= maxSessionEvents
    }

    /// Merge a `since_seq` delta onto cached thread events, returning `nil` if the server log reset.
    static func mergeEvents(existing: [StoredEvent], delta: [StoredEvent]) -> [StoredEvent]? {
        guard let maxKnown = existing.map(\.sequence).max() else {
            return delta.sorted { $0.sequence < $1.sequence }
        }
        if let maxDelta = delta.map(\.sequence).max(), maxDelta < maxKnown {
            return nil
        }
        if delta.isEmpty { return existing }
        var bySeq: [Int64: StoredEvent] = Dictionary(uniqueKeysWithValues: existing.map { ($0.sequence, $0) })
        for ev in delta { bySeq[ev.sequence] = ev }
        return bySeq.values.sorted { $0.sequence < $1.sequence }
    }

    /// Include bounded recent side Q&As when starting a fresh rotated `/btw` session while
    /// keeping the final `Current request:\n` delimiter intact for `question(_:)`.
    static func launchQuestion(_ content: String, priorTurns: [Turn]) -> String {
        guard !priorTurns.isEmpty else { return content }
        let formatted = priorTurns.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        let utf8 = Array(formatted.utf8)
        let bounded: String
        if utf8.count <= 4000 {
            bounded = formatted
        } else {
            var start = utf8.count - 4000
            while start < utf8.count && (utf8[start] & 0xC0) == 0x80 { start += 1 }
            bounded = "[Earlier side history omitted]\n" + String(decoding: utf8[start...], as: UTF8.self)
        }
        return "Earlier side questions in this conversation (most recent last):\n\(bounded)\n\nCurrent request:\n\(content)"
    }

    /// The side agent's prompt embeds the parent conversation; show only the request.
    static func question(_ content: String) -> String {
        var text = content
        if let range = text.range(of: "Current request:\n", options: .backwards) { text = String(text[range.upperBound...]) }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.reversed().drop(while: { $0.hasPrefix("Attachment: ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace only the user's question inside a wrapped `/btw` prompt so in-place
    /// queue edits preserve `<main_conversation_update>` and `Attachment:` lines.
    static func replaceQuestion(_ content: String, with next: String) -> String {
        let marker = "\nCurrent request:\n"
        let trimmedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = content.range(of: marker, options: .backwards) else {
            let lines = content.components(separatedBy: "\n")
            let attachments = Array(lines.reversed().prefix(while: { $0.hasPrefix("Attachment: ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed())
                .filter { $0.hasPrefix("Attachment: ") }
            if attachments.isEmpty { return trimmedNext }
            return ([trimmedNext] + attachments).joined(separator: "\n")
        }
        let prefix = String(content[..<range.upperBound])
        let body = String(content[range.upperBound...])
        let lines = body.components(separatedBy: "\n")
        let attachments = Array(lines.reversed().prefix(while: { $0.hasPrefix("Attachment: ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed())
            .filter { $0.hasPrefix("Attachment: ") }
        if attachments.isEmpty { return prefix + trimmedNext + "\n" }
        return prefix + ([trimmedNext] + attachments).joined(separator: "\n")
    }

    static func synthetic(_ text: String) -> Bool {
        text.range(of: #"^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} (?:on node '[^']+' )?(?:finished with(?:out assistant text| state)|reached state) "#, options: .regularExpression) != nil
            || text.hasPrefix("Native Codex goal stopped with status ")
    }

    /// OpenCode auto-compaction writes a summary turn ("## Objective …") and on
    /// older builds a synthetic "Continue if you have next steps…" prompt; newer
    /// builds emit the structured checkpoint (`## Objective` … `## Work State` …
    /// `## Next Move` … `## Relevant Files`) without the synthetic footer.
    static func stripCompaction(_ text: String) -> String {
        let pattern = #"(?:^|\n)## Objective\n[\s\S]*?\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed\.[^\S\n]*(?:\n|$)"#
        var out = text.replacingOccurrences(of: pattern, with: "\n\n", options: .regularExpression)
        let checkpoint = #"^\s*## Objective\r?\n[\s\S]*?\n## (?:Work State|Progress)\r?\n[\s\S]*?\n## Next Move\r?\n[\s\S]*?\n## Relevant Files(?:\r?\n[\s\S]*)?$"#
        if out.range(of: checkpoint, options: .regularExpression) != nil { return "" }
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
            return !m["id"].text.isEmpty && tags.contains(tag) && !OrbRow.hasTypedSuperseded(m)
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
                if (e.metadata["queued"]?.value as? Bool) == true || isAutomaticUserEvent(e.content, metadata: e.metadata) { continue }
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
            // Like the desktop, the live draft includes in-flight text_delta / text_op
            // when the turn has not written a terminal assistant_message yet.
            var liveTexts = texts
            if final == nil {
                let inFlight = OrbTurnText.fromStoredEvents(Array(ordered[start...]), working: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inFlight.isEmpty, !synthetic(inFlight), liveTexts.last != inFlight {
                    liveTexts.append(inFlight)
                }
            }
            let live = sideAnswer(liveTexts)
            return (turns, OpenTurn(id: "btw:\(missionID):\(seq)", question: question, at: at, events: Array(ordered[start...]), answer: live.answer, narration: live.narration))
        }
        if !question.isEmpty { flush() }
        return (turns, nil)
    }

    /// Every thread's turns, in the order they were asked, with strictly unique row IDs.
    static func merge(_ perThread: [[Turn]]) -> [Turn] {
        let all: [Turn] = perThread.flatMap { $0 }
        let indexed: [(offset: Int, turn: Turn)] = all.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { (a: (offset: Int, turn: Turn), b: (offset: Int, turn: Turn)) -> Bool in
            if a.turn.at != b.turn.at { return a.turn.at < b.turn.at }
            return a.offset < b.offset
        }
        let ordered = sorted.map(\.turn)
        let uniqueIDs = OrbTranscriptGates.ensureUniqueIds(ordered.map(\.id))
        return zip(uniqueIDs, ordered).map { id, turn in
            id == turn.id ? turn : Turn(id: id, question: turn.question, answer: turn.answer, narration: turn.narration, at: turn.at)
        }
    }

    /// Disambiguates whether `reconciledTurns` contains Core's answer to `question`,
    /// avoiding false matches against an earlier identical prompt (e.g. `"and now?"`).
    static func doesTurnAnswerPending(
        question: String,
        askedAt: Date?,
        reconciledTurns: [Turn],
        priorTurns: [Turn] = []
    ) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let matches = reconciledTurns.filter { $0.question.trimmingCharacters(in: .whitespacesAndNewlines) == q }
        guard let latest = matches.last else { return false }
        let priorMatches = priorTurns.filter { $0.question.trimmingCharacters(in: .whitespacesAndNewlines) == q }.count
        if matches.count <= priorMatches { return false }
        if let askedAt, let turnAt = OrbTurnSummary.parseDate(latest.at), turnAt < askedAt.addingTimeInterval(-5) {
            return false
        }
        return true
    }
}

/// The /btw state of one conversation, kept in memory and on disk so the sheet
/// opens on its history at once. The conversation warms it before the sheet opens.
@Observable @MainActor
final class OrbBtwStore {
    private struct TerminalThreadSummary: Sendable {
        let stamp: String
        let turns: [OrbBtwThreads.Turn]
        let maxSequence: Int64
        let delivered: [OrbDeliveredMessage]
    }

    private enum ThreadFetchOutcome: Sendable {
        case live(id: String, stamp: String, events: [StoredEvent], maxSequence: Int64)
        case terminal(id: String, summary: TerminalThreadSummary)
        case failed(id: String)
    }

    private static var stores: [String: OrbBtwStore] = [:]
    static func shared(_ parent: String) -> OrbBtwStore {
        let key = OrbBtwConfig.sessionKey(parent)
        if let store = stores[key] { return store }
        let store = OrbBtwStore(parent: parent)
        stores[key] = store
        return store
    }

    static func peek(_ parent: String) -> OrbBtwStore? {
        stores[OrbBtwConfig.sessionKey(parent)]
    }

    static func knownBoundIdsByParent(candidates: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for parent in candidates where !parent.isEmpty {
            let key = OrbBtwConfig.sessionKey(parent)
            if let bid = stores[key]?.boundID, !bid.isEmpty {
                out[parent] = bid
            } else if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
                out[parent] = saved
            }
        }
        return out
    }

    static func reconcileWarmFollows(wantedParents: Set<String>) {
        for parent in wantedParents {
            shared(parent).setWarmFollow(true)
        }
        for (_, store) in stores where !wantedParents.contains(store.parent) {
            store.setWarmFollow(false)
        }
    }

    static func stopAllWarmFollows() {
        for store in stores.values {
            store.setWarmFollow(false)
        }
    }

    static func trimMemory() {
        for (key, store) in Array(stores) {
            store.terminalCache.removeAll()
            let activeID = store.running ? store.boundID : nil
            store.eventCache = store.eventCache.filter { $0.key == activeID }
            if !store.warmFollowWanted && store.sheetOpenCount == 0 && store.refreshing == nil && !store.running {
                store.streamTask?.cancel()
                store.streamTask = nil
                store.streamMissionId = nil
                stores.removeValue(forKey: key)
            }
        }
    }

    static func resetAll() {
        for store in stores.values {
            store.refreshing?.cancel()
            store.refreshing = nil
            store.streamTask?.cancel()
            store.streamTask = nil
            store.streamMissionId = nil
            store.terminalCache.removeAll()
            store.eventCache.removeAll()
        }
        stores.removeAll()
    }

    nonisolated private static func deliveredMessages(from events: [StoredEvent]) -> [OrbDeliveredMessage] {
        events.compactMap { e in
            guard e.eventType == "user_message",
                  (e.metadata["queued"]?.value as? Bool) != true,
                  !OrbBtwThreads.isAutomaticUserEvent(e.content, metadata: e.metadata) else { return nil }
            return OrbDeliveredMessage(id: e.eventId, content: OrbBtwThreads.question(e.content), sequence: e.sequence)
        }
    }

    let parent: String
    private(set) var turns: [OrbBtwThreads.Turn]
    private(set) var open: OrbBtwThreads.OpenTurn?
    /// The thread new questions continue (latest activity), and its mission.
    private(set) var bound: OrbJSON = .null
    private(set) var boundDeliveredMessages: [OrbDeliveredMessage] = []
    private(set) var boundTurnCount = 0
    private(set) var boundMaxSequence: Int64 = 0
    private(set) var loaded = false
    private(set) var isWarmCaughtUp = false
    /// Raw event cache retained only for live threads; finished threads keep only `terminalCache`.
    private var eventCache: [String: (stamp: String, events: [StoredEvent])] = [:]
    private var terminalCache: [String: TerminalThreadSummary] = [:]
    private var refreshing: Task<Void, Error>?
    private var warmFollowWanted = false
    private var sheetOpenCount = 0
    private var streamTask: Task<Void, Never>?
    private var streamMissionId: String?

    var boundID: String? { bound["id"].text.isEmpty ? nil : bound["id"].text }
    var boundStatus: String { bound["status"].text }
    var running: Bool { OrbBtwThreads.liveStatuses.contains(boundStatus) }
    private var cacheKey: String { "btw:turns:" + parent }

    private init(parent: String) {
        self.parent = parent
        let disk = OrbDisk.read("btw:turns:" + parent, as: [OrbBtwThreads.Turn].self) ?? []
        turns = disk.isEmpty ? [] : OrbBtwThreads.merge([disk])
        loaded = !turns.isEmpty
    }

    func noteSheetOpened() { sheetOpenCount += 1 }
    func noteSheetClosed() { sheetOpenCount = max(0, sheetOpenCount - 1) }

    func setWarmFollow(_ wanted: Bool) {
        guard warmFollowWanted != wanted else {
            if wanted { syncStreamSubscription() }
            return
        }
        warmFollowWanted = wanted
        syncStreamSubscription()
    }

    func noteExternalSessionHint(missionId: String) {
        guard !missionId.isEmpty else { return }
        if boundID != missionId {
            UserDefaults.standard.set(missionId, forKey: OrbBtwConfig.sessionKey(parent))
            bound = .object(["id": .string(missionId), "status": .string("running")])
            boundTurnCount = 0
            boundMaxSequence = 0
            boundDeliveredMessages = []
            open = nil
            isWarmCaughtUp = false
            if warmFollowWanted {
                syncStreamSubscription()
            }
        }
    }

    /// Concurrent callers share one refresh.
    func refresh(force: Bool = false) async throws {
        if !force && loaded && !running && OrbWarmSyncCoordinator.shared.canSkipBtwServerCrawl(parentId: parent) {
            syncStreamSubscription()
            return
        }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await load() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    func refreshStatusOnly() async throws {
        guard let id = boundID else { return }
        let m = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))?include_history=false")
        guard !m["id"].text.isEmpty else { return }
        bound = m
        recomputeFromCache()
    }

    /// A question was just posted to `id`: follow it as live until Core reports it.
    func sent(to id: String) {
        if boundID != id {
            bound = .object(["id": .string(id), "status": .string("running")])
            boundTurnCount = 0
            boundMaxSequence = 0
        } else if !running, case .object(var fields) = bound {
            fields["status"] = .string("running")
            bound = .object(fields)
        }
        if let existing = eventCache[id] { eventCache[id] = ("", existing.events) }
        OrbWarmSyncCoordinator.shared.markBtwDirty(parentId: parent)
        syncStreamSubscription()
    }

    private func load() async throws {
        let tag = "btw-parent:\(parent)"
        let rows = try await OrbCore.shared.call("/api/control/missions?tag=\(OrbCore.escape(tag))&all=true&limit=50")
        var threads = OrbBtwThreads.threads(rows["missions"].items.isEmpty ? rows.items : rows["missions"].items, parent: parent)
        var hadReadFailure = false
        let knownID = boundID ?? UserDefaults.standard.string(forKey: OrbBtwConfig.sessionKey(parent))
        if let knownID, !knownID.isEmpty, !threads.contains(where: { $0["id"].text == knownID }) {
            do {
                let direct = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(knownID))?include_history=false")
                if !OrbBtwThreads.threads([direct], parent: parent).isEmpty {
                    threads = OrbBtwThreads.threads(threads + [direct], parent: parent)
                }
            } catch let e as OrbHTTPError where e.status == 404 {
                // Deleted/unknown session id; ignore.
            } catch {
                hadReadFailure = true
            }
        }
        struct PendingThreadRead: Sendable {
            let id: String
            let stamp: String
            let activity: String
            let live: Bool
            let priorEvents: [StoredEvent]?
            let sinceSeq: Int64?
        }

        var liveFetched: [String: (events: [StoredEvent], maxSequence: Int64)] = [:]
        var terminalResolved: [String: TerminalThreadSummary] = [:]
        var pendingReads: [PendingThreadRead] = []

        for m in threads {
            let id = m["id"].text
            let activity = OrbBtwThreads.activity(m)
            let stamp = activity + "\u{0}" + m["status"].text
            let live = OrbBtwThreads.liveStatuses.contains(m["status"].text)
            if !live {
                if let cached = terminalCache[id], !cached.stamp.isEmpty, cached.stamp == stamp {
                    terminalResolved[id] = cached
                    eventCache.removeValue(forKey: id)
                    continue
                }
                if let cachedEvents = eventCache[id], !cachedEvents.stamp.isEmpty, cachedEvents.stamp == stamp {
                    let parsed = OrbBtwThreads.parse(missionID: id, events: cachedEvents.events, active: false)
                    let summary = TerminalThreadSummary(
                        stamp: stamp,
                        turns: parsed.turns,
                        maxSequence: cachedEvents.events.map(\.sequence).max() ?? 0,
                        delivered: Self.deliveredMessages(from: cachedEvents.events)
                    )
                    terminalCache[id] = summary
                    terminalResolved[id] = summary
                    eventCache.removeValue(forKey: id)
                    continue
                }
            }
            let priorEvents = live ? eventCache[id]?.events : nil
            let sinceSeq = priorEvents?.map(\.sequence).max()
            pendingReads.append(PendingThreadRead(
                id: id,
                stamp: stamp,
                activity: activity,
                live: live,
                priorEvents: priorEvents,
                sinceSeq: sinceSeq
            ))
        }

        pendingReads.sort { a, b in
            if a.live != b.live { return a.live && !b.live }
            return a.activity > b.activity
        }

        let outcomes = await withTaskGroup(of: ThreadFetchOutcome.self, returning: [ThreadFetchOutcome].self) { group in
            var index = 0
            let limit = OrbBtwThreads.maxConcurrentThreadLoads
            func enqueue(_ item: PendingThreadRead) {
                group.addTask {
                    guard !Task.isCancelled else { return .failed(id: item.id) }
                    if item.live {
                        if let priorEvents = item.priorEvents, let sinceSeq = item.sinceSeq,
                           let delta = try? await OrbCore.shared.getMissionEventsWithMeta(id: item.id, limit: 1000, sinceSeq: sinceSeq),
                           let merged = OrbBtwThreads.mergeEvents(existing: priorEvents, delta: delta.events) {
                            let maxSeq = max(delta.maxSequence ?? 0, merged.map(\.sequence).max() ?? 0)
                            return .live(id: item.id, stamp: item.stamp, events: merged, maxSequence: maxSeq)
                        }
                        guard let full = try? await OrbCore.shared.getMissionEventsWithMeta(id: item.id, limit: 1000) else {
                            return .failed(id: item.id)
                        }
                        let maxSeq = max(full.maxSequence ?? 0, full.events.map(\.sequence).max() ?? 0)
                        return .live(id: item.id, stamp: item.stamp, events: full.events, maxSequence: maxSeq)
                    } else {
                        guard let res = try? await OrbCore.shared.getMissionEventsWithMeta(
                            id: item.id,
                            types: OrbBtwThreads.transcriptEventTypes,
                            limit: 1000
                        ) else {
                            return .failed(id: item.id)
                        }
                        let parsed = OrbBtwThreads.parse(missionID: item.id, events: res.events, active: false)
                        let maxSeq = max(res.maxSequence ?? 0, res.events.map(\.sequence).max() ?? 0)
                        let summary = TerminalThreadSummary(
                            stamp: item.stamp,
                            turns: parsed.turns,
                            maxSequence: maxSeq,
                            delivered: Self.deliveredMessages(from: res.events)
                        )
                        return .terminal(id: item.id, summary: summary)
                    }
                }
            }
            while index < min(limit, pendingReads.count) {
                enqueue(pendingReads[index])
                index += 1
            }
            var collected: [ThreadFetchOutcome] = []
            collected.reserveCapacity(pendingReads.count)
            while let nextOutcome = await group.next() {
                collected.append(nextOutcome)
                if index < pendingReads.count && !Task.isCancelled {
                    enqueue(pendingReads[index])
                    index += 1
                }
            }
            return collected
        }

        try Task.checkCancellation()

        for outcome in outcomes {
            switch outcome {
            case .live(let id, let stamp, let events, let maxSequence):
                terminalCache.removeValue(forKey: id)
                eventCache[id] = (stamp, events)
                liveFetched[id] = (events, maxSequence)
            case .terminal(let id, let summary):
                eventCache.removeValue(forKey: id)
                terminalCache[id] = summary
                terminalResolved[id] = summary
            case .failed:
                hadReadFailure = true
            }
        }

        let validIDs = Set(threads.map { $0["id"].text })
        let protectedID = running ? boundID : nil
        eventCache = eventCache.filter { validIDs.contains($0.key) || $0.key == protectedID }
        if terminalCache.count > 256 {
            terminalCache = terminalCache.filter { validIDs.contains($0.key) }
        }

        var perThread: [[OrbBtwThreads.Turn]] = []
        var opens: [String: OrbBtwThreads.OpenTurn] = [:]
        for m in threads {
            let id = m["id"].text
            let live = OrbBtwThreads.liveStatuses.contains(m["status"].text)
            if live, let liveData = liveFetched[id] {
                let result = OrbBtwThreads.parse(missionID: id, events: liveData.events, active: true)
                perThread.append(result.turns)
                if let open = result.open { opens[id] = open }
            } else if !live, let summary = terminalResolved[id] ?? terminalCache[id] {
                perThread.append(summary.turns)
            } else {
                // A failed read keeps what was shown for that thread.
                perThread.append(terminalCache[id]?.turns ?? turns.filter { $0.id.hasPrefix("btw:\(id):") })
            }
        }
        // A live thread wins; otherwise the latest activity.
        let latestLive = threads.filter { opens[$0["id"].text] != nil }.last
        let next = latestLive ?? OrbBtwThreads.latest(threads) ?? .null
        let merged = OrbBtwThreads.merge(perThread)
        // A just-posted question may not be listed yet: keep following it.
        if let id = boundID, running, !threads.contains(where: { $0["id"].text == id }) {
            if merged != turns { turns = merged }
            loaded = true
            OrbWarmSyncCoordinator.shared.markBtwDirty(parentId: parent)
            return
        }
        if merged != turns { turns = merged; OrbDisk.saveAsync(merged, key: cacheKey) }
        let nextID = next["id"].text
        let nextOpen = opens[nextID]
        if nextOpen != open { open = nextOpen }
        if next != bound { bound = next }
        boundTurnCount = perThread.enumerated().first(where: { threads[$0.offset]["id"].text == nextID })?.element.count ?? 0
        if let liveData = liveFetched[nextID] {
            boundMaxSequence = liveData.maxSequence
            boundDeliveredMessages = Self.deliveredMessages(from: liveData.events)
        } else if let summary = terminalResolved[nextID] ?? terminalCache[nextID] {
            boundMaxSequence = summary.maxSequence
            boundDeliveredMessages = summary.delivered
        } else {
            boundMaxSequence = 0
            boundDeliveredMessages = []
        }
        if let id = boundID { UserDefaults.standard.set(id, forKey: OrbBtwConfig.sessionKey(parent)) }
        loaded = true
        if hadReadFailure {
            OrbWarmSyncCoordinator.shared.markBtwDirty(parentId: parent)
        } else {
            OrbWarmSyncCoordinator.shared.markBtwClean(parentId: parent)
        }
        syncStreamSubscription()
        OrbWarmSyncCoordinator.shared.reconcile()
    }

    private func syncStreamSubscription() {
        let targetId = warmFollowWanted ? (boundID ?? UserDefaults.standard.string(forKey: OrbBtwConfig.sessionKey(parent))) : nil
        guard let targetId, !targetId.isEmpty else {
            streamTask?.cancel()
            streamTask = nil
            streamMissionId = nil
            isWarmCaughtUp = false
            return
        }
        if streamMissionId == targetId, streamTask != nil {
            return
        }
        streamTask?.cancel()
        streamMissionId = targetId
        isWarmCaughtUp = false
        streamTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.warmFollowWanted, self.streamMissionId == targetId else { return }
                let cachedSeq = self.eventCache[targetId]?.events.map(\.sequence).max()
                let terminalSeq = self.terminalCache[targetId].flatMap { $0.maxSequence > 0 ? $0.maxSequence : nil }
                let since = cachedSeq ?? terminalSeq
                let inner = OrbCore.shared.streamControl(
                    missionId: targetId,
                    sinceSeq: since
                ) { [weak self] type, data in
                    guard let self, self.streamMissionId == targetId else { return }
                    self.handleLiveStreamEvent(missionId: targetId, type: type, data: data)
                }
                await withTaskCancellationHandler {
                    await inner.value
                } onCancel: {
                    inner.cancel()
                }
                guard !Task.isCancelled, self.warmFollowWanted, self.streamMissionId == targetId else { return }
                self.isWarmCaughtUp = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func handleLiveStreamEvent(missionId: String, type: String, data: [String: Any]) {
        if type == "sync_caught_up" {
            isWarmCaughtUp = true
            OrbWarmSyncCoordinator.shared.markBtwClean(parentId: parent)
            return
        }
        if type == "stream_lagged" || type == "error" {
            isWarmCaughtUp = false
            Task { try? await refresh(force: true) }
            return
        }
        if type == "mission_status_changed", let newStatus = data["status"] as? String, !newStatus.isEmpty {
            if boundID == missionId, case var .object(fields) = bound {
                fields["status"] = .string(newStatus)
                bound = .object(fields)
            } else if boundID == nil {
                bound = .object(["id": .string(missionId), "status": .string(newStatus)])
            }
            recomputeFromCache()
            return
        }
        if type == "text_delta", let delta = data["content"] as? String {
            let seq = (data["sequence"] as? NSNumber)?.int64Value ?? ((eventCache[missionId]?.events.last?.sequence ?? 0) + 1)
            let existing = eventCache[missionId]?.events ?? []
            let prevDelta = existing.last(where: { $0.eventType == "text_delta" })?.content ?? ""
            let synthetic = StoredEvent(
                id: seq,
                missionId: missionId,
                sequence: seq,
                eventType: "text_delta",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                eventId: "text_delta_latest",
                toolCallId: nil,
                toolName: nil,
                content: prevDelta + delta,
                metadata: [:]
            )
            let merged = OrbConversation.mergeStoredEvents(existing: existing, incoming: [synthetic])
            eventCache[missionId] = ("", merged)
            if boundID == nil || (!running && boundID == missionId) {
                bound = .object(["id": .string(missionId), "status": .string("running")])
            }
            recomputeFromCache()
            return
        }
        guard let stored = StoredEvent.fromStreamFrame(missionId: missionId, type: type, data: data) else {
            if type == "user_message", (data["queued"] as? Bool) == true {
                recomputeFromCache()
            }
            return
        }
        let existing = eventCache[missionId]?.events ?? []
        var merged = OrbConversation.mergeStoredEvents(existing: existing, incoming: [stored])
        if stored.eventType == "user_message" || stored.eventType == "assistant_message" {
            merged.removeAll { $0.eventType == "text_delta" }
        }
        eventCache[missionId] = ("", merged)
        boundMaxSequence = max(boundMaxSequence, stored.sequence)
        if stored.eventType == "user_message", (stored.metadata["queued"]?.value as? Bool) != true {
            if boundID == missionId, case var .object(fields) = bound {
                fields["status"] = .string("running")
                bound = .object(fields)
            } else if boundID == nil {
                bound = .object(["id": .string(missionId), "status": .string("running")])
            }
        }
        recomputeFromCache()
    }

    private func recomputeFromCache() {
        guard let id = boundID ?? streamMissionId else { return }
        let active = OrbBtwThreads.liveStatuses.contains(boundStatus)
        guard let cached = eventCache[id]?.events else {
            if !active && open != nil { open = nil }
            return
        }
        let parsed = OrbBtwThreads.parse(missionID: id, events: cached, active: active)
        let parsedIDs = Set(parsed.turns.map(\.id))
        let priorSameThread = (terminalCache[id]?.turns ?? turns.filter { $0.id.hasPrefix("btw:\(id):") })
            .filter { !parsedIDs.contains($0.id) }
        let mergedThreadTurns = OrbBtwThreads.merge([priorSameThread, parsed.turns])
        let otherTurns = turns.filter { !$0.id.hasPrefix("btw:\(id):") }
        let merged = OrbBtwThreads.merge([otherTurns, mergedThreadTurns])
        if merged != turns {
            turns = merged
            OrbDisk.saveAsync(merged, key: cacheKey)
        }
        if parsed.open != open {
            open = parsed.open
        }
        boundTurnCount = mergedThreadTurns.count
        let nextMaxSeq = max(boundMaxSequence, max(terminalCache[id]?.maxSequence ?? 0, cached.map(\.sequence).max() ?? 0))
        boundMaxSequence = nextMaxSeq
        var seenDelivered = Set<String>()
        var combinedDelivered: [OrbDeliveredMessage] = []
        for item in (terminalCache[id]?.delivered ?? []) + Self.deliveredMessages(from: cached) {
            let key = item.id ?? "seq:\(item.sequence)"
            if seenDelivered.insert(key).inserted {
                combinedDelivered.append(item)
            }
        }
        boundDeliveredMessages = combinedDelivered
        if !active {
            terminalCache[id] = TerminalThreadSummary(
                stamp: "",
                turns: mergedThreadTurns,
                maxSequence: nextMaxSeq,
                delivered: combinedDelivered
            )
            eventCache.removeValue(forKey: id)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var pendingBaselineTurns: [OrbBtwThreads.Turn] = []
    @State private var autoAsked = false
    @State private var scroller = OrbTranscriptScroller()
    @State private var expandedSteps = 0
    @State private var pinnedExtraTurns = 0
    @State private var followUps = OrbFollowUpQueue()
    @State private var queueExpanded = true
    @State private var editingQueuedID: String?
    @State private var rawQueuedByID: [String: String] = [:]

    init(parentID: String, question: String) {
        self.parentID = parentID
        _question = State(initialValue: question)
        _store = State(initialValue: OrbBtwStore.shared(parentID))
    }

    private var running: Bool { store.running }
    private var waiting: Bool { running || pending != nil }
    private var visibleTurnLimit: Int {
        OrbTranscriptGates.visibleTurnCount(
            total: store.turns.count,
            baseLimit: OrbBtwThreads.initialVisibleTurns + pinnedExtraTurns,
            expandedSteps: expandedSteps,
            stepSize: OrbBtwThreads.visibleTurnsStep
        )
    }
    private var hiddenTurnCount: Int {
        OrbTranscriptGates.hiddenTurnCount(
            total: store.turns.count,
            baseLimit: OrbBtwThreads.initialVisibleTurns + pinnedExtraTurns,
            expandedSteps: expandedSteps,
            stepSize: OrbBtwThreads.visibleTurnsStep
        )
    }
    /// The optimistic bubble, until Core's thread holds the question.
    private var pendingBubble: String? {
        guard let pending else { return nil }
        if store.open?.question.trimmingCharacters(in: .whitespacesAndNewlines) == pending.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        if OrbBtwThreads.doesTurnAnswerPending(question: pending, askedAt: askedAt, reconciledTurns: store.turns, priorTurns: pendingBaselineTurns) { return nil }
        return pending
    }
    private var canSend: Bool { !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var scrollTranscriptView: some View {
        ScrollViewReader { scroll in
            OrbTranscriptScrollView(identifier: "btw", scroller: scroller, working: waiting) {
                transcript(scroll: scroll)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Tapping the transcript hides the keyboard, like the conversation tab
        // (simultaneous: links and buttons in the transcript still get the tap).
        .simultaneousGesture(TapGesture().onEnded { if focused { focused = false } })
        .onChange(of: store.turns.count) { oldCount, newCount in
            let grew = newCount - oldCount
            if scroller.pinned {
                scroller.scrollToBottom(animated: true)
            } else if grew > 0 && oldCount >= visibleTurnLimit {
                pinnedExtraTurns += grew
            }
        }
        .onChange(of: store.boundDeliveredMessages) { _, delivered in
            let next = followUps.reconciled(with: delivered)
            if next != followUps { withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next } }
        }
        .onChange(of: store.boundMaxSequence) { _, _ in Task { await refreshQueue() } }
        .onChange(of: pending) { _, value in if value != nil { scroller.scrollToBottom(animated: true) } }
        .onChange(of: focused) { _, value in if value && scroller.metrics.distanceFromBottom <= OrbTranscriptScroller.pillThreshold { scroller.scrollToBottom(animated: true) } }
        .background(OrbStyle.background)
    }

    private func handleSheetAppear() {
        store.noteSheetOpened()
        OrbWarmSyncCoordinator.shared.noteBtwSheetOpened(parentId: parentID)
        // `/btw <question>` from the composer was already a send: don't ask for a second tap.
        let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && !autoAsked {
            autoAsked = true
            Task { await ask() }
        } else if store.loaded && store.turns.isEmpty && store.open == nil {
            focused = true
        }
    }

    var body: some View {
        NavigationStack {
            scrollTranscriptView
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Side question").navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: phase) { await follow() }
            .onAppear { handleSheetAppear() }
            .onDisappear {
                store.noteSheetClosed()
                OrbWarmSyncCoordinator.shared.noteBtwSheetClosed(parentId: parentID)
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

    private func transcript(scroll: ScrollViewProxy) -> some View {
        let visibleTurns = Array(store.turns.suffix(visibleTurnLimit))
        return VStack(alignment: .leading, spacing: 16) {
            if !error.isEmpty { OrbNotice(message: error) }
            if !store.loaded && store.turns.isEmpty {
                loadingPlaceholder
            } else if store.turns.isEmpty && store.open == nil && pendingBubble == nil {
                Text("Ask about this conversation without interrupting it. The side agent reads the conversation and shares its working folder.")
                    .font(.footnote).foregroundStyle(OrbStyle.textSecondary)
                    .accessibilityIdentifier("btw.intro")
            }
            if hiddenTurnCount > 0 {
                Button("Load earlier side questions") {
                    let anchor = visibleTurns.first?.id
                    scroller.pinned = false
                    expandedSteps += 1
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
                .accessibilityIdentifier("btw.loadEarlier")
            }
            ForEach(visibleTurns) { turn in
                OrbUserBubble(text: turn.question).id(turn.id)
                OrbBtwNarration(updates: turn.narration)
                OrbAssistantMessage(text: turn.answer).id(turn.id + ":a")
            }
            if let open = store.open {
                OrbUserBubble(text: open.question, pending: true).id(open.id + ":open")
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
                    Text("Editing queued side question").font(.caption2).foregroundStyle(OrbStyle.textSecondary)
                    Spacer()
                    Button("Cancel") { editingQueuedID = nil; question = "" }
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
        .accessibilityIdentifier("btw.followUpQueue")
    }

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
                    queueAction("pencil", label: "Edit queued side question", enabled: enabled) {
                        editingQueuedID = row.id
                        question = row.content
                        focused = true
                    }
                    queueAction("arrow.up", label: "Send now", enabled: enabled) {
                        OrbHaptics.light()
                        Task { await sendQueuedNow(row.id) }
                    }
                    queueAction("trash", label: "Remove queued side question", enabled: !row.sending) {
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

    private var composer: some View {
        VStack(spacing: 0) {
            if followUps.count > 0 || editingQueuedID != nil { queuedDrawer }
            OrbComposerBox(
                placeholder: running ? "Queue a side question…" : freshSession ? "Ask in a new side session…" : "Ask a side question",
                text: $question,
                focused: $focused,
                dictation: dictation,
                busy: busy,
                canSend: canSend,
                showStop: running,
                fieldIdentifier: "btw.input",
                sendIdentifier: "btw.send",
                sendLabel: running ? "Queue side question" : "Send side question",
                stopLabel: "Stop side agent",
                containerIdentifier: "btw-composer",
                onSend: { Task { await ask() } },
                onStop: { Task { await stop() } }
            ) {
                if !attachments.isEmpty { OrbAttachments(files: $attachments, error: $error, canAdd: false) }
            } leading: {
                OrbAttachments(files: $attachments, error: $error, showFiles: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(OrbStyle.background)
    }

    private func refreshQueue() async {
        guard let id = store.boundID else { return }
        let fetchedAt = Date()
        guard let response = try? await OrbCore.shared.call("/api/control/queue?mission_id=\(OrbCore.escape(id))") else {
            let next = followUps.reconciled(with: store.boundDeliveredMessages)
            if next != followUps { withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next } }
            return
        }
        let parsedQueue = OrbFollowUpQueue.parseResponse(response, missionID: id)
        guard !followUps.isStaleFetch(fetchedAt, incomingServerRev: parsedQueue.revision) else { return }
        var rawMap = rawQueuedByID
        let displayRows = parsedQueue.rows.map { row -> OrbQueuedRow in
            rawMap[row.id] = row.content
            var copy = row
            copy.content = OrbMessagePresentation.parse(row.content).text
            return copy
        }
        rawQueuedByID = rawMap
        let lastSeq = store.boundMaxSequence > 0 ? store.boundMaxSequence : store.boundDeliveredMessages.last?.sequence
        let next = followUps.withServer(
            displayRows,
            fetchedAt: fetchedAt,
            lastSequence: lastSeq,
            incomingServerRev: parsedQueue.revision
        ).reconciled(with: store.boundDeliveredMessages)
        if next != followUps {
            if next.rows != followUps.rows {
                withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = next }
            } else {
                followUps = next
            }
        }
    }

    private func follow() async {
        guard phase == .active else { return }
        do {
            try await store.refresh(force: pending != nil)
            await refreshQueue()
            settlePending()
        } catch is CancellationError {
            return
        } catch {
            if store.turns.isEmpty { self.error = error.localizedDescription }
        }
        await Poller.run(
            every: {
                if OrbCore.shared.isMultiplexSyncHealthy && store.isWarmCaughtUp {
                    return .seconds(waiting || busy || followUps.count > 0 ? 12 : 60)
                }
                return .seconds(waiting || busy || followUps.count > 0 ? 1.5 : 15)
            },
            immediately: false,
            while: { phase == .active && (!OrbCore.shared.isMultiplexSyncHealthy || !store.isWarmCaughtUp || waiting || busy || followUps.count > 0) }
        ) {
            do {
                try await store.refresh(force: pending != nil)
                await refreshQueue()
                settlePending()
                return true
            } catch is CancellationError { return true } catch {
                if store.turns.isEmpty { self.error = error.localizedDescription }
                return false
            }
        }
    }

    private func settlePending() {
        if pending != nil && !busy && pendingBubble == nil { pending = nil; askedAt = nil; pendingBaselineTurns = [] }
    }

    private func ask() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        if let editing = editingQueuedID {
            await editQueued(editing, content: text)
            return
        }
        busy = true; defer { busy = false }
        let queueing = (running || followUps.count > 0) && store.boundID != nil && !freshSession
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            if queueing {
                question = ""
            } else {
                pendingBaselineTurns = store.turns; pending = text; askedAt = Date(); question = ""
            }
        }
        let files = attachments
        attachments = []
        // One id per question: every resend after a dropped connection carries it,
        // so Core accepts the question at most once (desktop `askBtwAgent`).
        let messageID = UUID().uuidString
        if queueing {
            let enqueueSeq = store.boundMaxSequence > 0 ? store.boundMaxSequence : store.boundDeliveredMessages.last?.sequence
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                followUps = followUps.enqueue(messageID, text, lastSequence: enqueueSeq)
            }
            OrbUsageTelemetry.shared.trackAction(.queue, surface: "btw")
        }
        do {
            if !store.loaded { try await store.refresh() }
            let parent = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))?include_history=false")
            if OrbRow.isClientPlacement(parent) {
                throw OrbHTTPError(status: 409, detail: "This conversation runs on a computer. Ask side questions from Orb on that computer.")
            }
            let rotateIdle = !running && followUps.count == 0 && OrbBtwThreads.shouldRotateSession(turnCount: store.boundTurnCount, maxSequence: store.boundMaxSequence)
            let reusingBound = store.boundID != nil && !freshSession && !rotateIdle && (running || followUps.count > 0 || OrbBtwThreads.resumableStatuses.contains(store.boundStatus))
            var boundCyber: (mode: String, revision: String)? = nil
            if reusingBound, let id = store.boundID {
                boundCyber = try await OrbCyberAccess.requireFollowUp(text, missionID: id)
            } else if OrbBtwConfig.harness == "codex" {
                if let reason = OrbCyberAccess.emptyGoalError(text) {
                    throw OrbHTTPError(status: 400, detail: reason)
                }
                let cyber = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))/cyber")
                guard OrbCyberAccess.modes.contains(cyber["mode"].text) else {
                    throw OrbHTTPError(status: 400, detail: "The backend did not return a Cyber selection. Your draft is kept.")
                }
                try await OrbCyberAccess.require(model: OrbBtwConfig.model, mode: cyber["mode"].text, remote: OrbContinuation.remoteNodeID(for: parent) != "core", goal: OrbCyberAccess.isGoal(text))
            }
            var content = text
            for file in files {
                let node = OrbContinuation.remoteNodeID(for: parent)
                let receipt = try await OrbCore.shared.call("/api/uploads", method: "POST", body: .object(["node_id": .string(node), "name": .string(file.name), "data_base64": .string(file.data.base64EncodedString())]))
                guard !receipt["path"].text.isEmpty else { throw URLError(.cannotParseResponse) }
                content += "\nAttachment: " + receipt["path"].text
            }
            if reusingBound, let id = store.boundID {
                let shouldQueue = running || followUps.count > 0
                let idempotencyHeader = ["Idempotency-Key": "msg:\(id):\(messageID)"]
                var msgBody: [String: OrbJSON] = [
                    "mission_id": .string(id),
                    "content": .string(content),
                    "client_message_id": .string(messageID),
                    "queue_followup": .bool(true),
                ]
                if let cyber = boundCyber {
                    msgBody["cyber_access"] = .string(cyber.mode)
                    if !cyber.revision.isEmpty { msgBody["cyber_revision"] = .string(cyber.revision) }
                }
                let result = try await OrbSideSend.retrying { try await OrbCore.shared.call("/api/control/message", method: "POST", body: .object(msgBody), headers: idempotencyHeader) }
                let queuedNow = result["queued"] == .bool(true)
                let receiptID = result["id"].text.isEmpty ? messageID : result["id"].text
                rawQueuedByID[receiptID] = content
                if queueing || queuedNow {
                    pending = nil; askedAt = nil; pendingBaselineTurns = []
                    if receiptID == messageID {
                        followUps = followUps.posted(messageID, queued: queuedNow)
                    } else {
                        followUps = followUps.postFailed(messageID)
                        if queuedNow {
                            let postedSeq = store.boundMaxSequence > 0 ? store.boundMaxSequence : store.boundDeliveredMessages.last?.sequence
                            followUps = followUps.enqueue(receiptID, text, lastSequence: postedSeq).posted(receiptID, queued: true)
                        }
                    }
                    if !queuedNow { pendingBaselineTurns = store.turns; pending = text; askedAt = Date(); store.sent(to: id) }
                } else if !shouldQueue {
                    store.sent(to: id)
                }
            } else {
                let launchBody = OrbBtwThreads.launchQuestion(content, priorTurns: store.turns)
                let idempotencyHeader = ["Idempotency-Key": "btw:\(parentID):\(messageID)"]
                let created = try await OrbSideSend.retrying { try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(parentID))/btw/agent", method: "POST", body: .object([
                    "backend": .string(OrbBtwConfig.harness), "model_override": .string(OrbBtwConfig.model), "model_effort": .null,
                    "idempotency_key": .string(messageID), "side_question": .string(launchBody),
                ]), headers: idempotencyHeader) }
                freshSession = false
                store.sent(to: created["id"].text)
            }
            error = ""
            try? await store.refresh(force: true)
            await refreshQueue()
        } catch let e as OrbHTTPError where [404, 405].contains(e.status) && store.boundID == nil {
            if queueing { followUps = followUps.postFailed(messageID) }
            restore(text, files)
            error = "This backend does not support /btw side agents yet."
        } catch {
            if queueing { followUps = followUps.postFailed(messageID) }
            restore(text, files)
            self.error = OrbCyberAccess.error(error)
        }
    }

    private func removeQueued(_ queueID: String) async {
        if editingQueuedID == queueID { editingQueuedID = nil; question = "" }
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) { followUps = followUps.hide(queueID) }
        do {
            _ = try await OrbCore.shared.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
            await refreshQueue()
        } catch let e as OrbHTTPError where e.status == 404 {
            await refreshQueue()
        } catch {
            followUps = followUps.unhide(queueID)
            self.error = error.localizedDescription
        }
    }

    private func editQueued(_ queueID: String, content: String) async {
        guard let id = store.boundID else { return }
        guard followUps.row(queueID) != nil else {
            editingQueuedID = nil
            question = ""
            error = "This side question was already sent. Your edit was not applied."
            return
        }
        let base = rawQueuedByID[queueID] ?? followUps.row(queueID)?.content ?? content
        let wireContent = OrbMessagePresentation.replaceUserText(base, with: content)
        do {
            try await OrbCyberAccess.requireFollowUp(OrbBtwThreads.question(wireContent), missionID: id)
        } catch {
            self.error = OrbCyberAccess.error(error)
            return
        }
        editingQueuedID = nil
        question = ""
        let expectedRev = followUps.expectedRevision(for: queueID)
        let staged = followUps.edit(queueID, content, expectedServerRev: expectedRev)
        guard staged.edits[queueID] == content else {
            error = "This side question was already sent, so the edit was not applied."
            return
        }
        followUps = staged
        var patchFields: [String: OrbJSON] = ["content": .string(wireContent)]
        if let expectedRev { patchFields["expected_revision"] = .number(Double(expectedRev)) }
        var status: Int? = nil
        var errorDetail = ""
        do {
            _ = try await OrbCore.shared.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "PATCH", body: .object(patchFields))
            status = 200
        } catch let e as OrbHTTPError {
            status = e.status
            errorDetail = e.detail
        } catch {
            status = nil
        }
        switch OrbSendFlow.editOutcome(status: status) {
        case .edited:
            rawQueuedByID[queueID] = wireContent
            followUps = followUps.editConfirmed(queueID, content, expectedServerRev: expectedRev, confirmedAt: Date())
            OrbUsageTelemetry.shared.trackAction(.messageEdit, surface: "btw-queue")
        case .unsupported:
            followUps = followUps.editReverted(queueID)
            error = "This edit cannot be saved atomically. The queued messages have not been changed."
        case .alreadySent:
            followUps = followUps.editReverted(queueID)
            let isRevConflict = status == 409 && (errorDetail.localizedCaseInsensitiveContains("revision") || errorDetail.localizedCaseInsensitiveContains("stale"))
            error = isRevConflict
                ? "Queue changed on another client; refreshed queue before editing."
                : "This side question was already sent, so the edit was not applied."
            try? await store.refresh(force: true)
        case .failed:
            followUps = followUps.editReverted(queueID)
            error = "Couldn’t save the edit."
        }
        await refreshQueue()
    }

    private func sendQueuedNow(_ queueID: String) async {
        guard let id = store.boundID, editingQueuedID == nil, let row = followUps.row(queueID), !row.sending else { return }
        let wireContent = rawQueuedByID[queueID] ?? row.content
        do {
            try await OrbCyberAccess.requireFollowUp(OrbBtwThreads.question(wireContent), missionID: id)
        } catch {
            self.error = OrbCyberAccess.error(error)
            return
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
            followUps = followUps.hide(queueID)
            pendingBaselineTurns = store.turns
            pending = row.content.trimmingCharacters(in: .whitespacesAndNewlines)
            askedAt = Date()
            scroller.scrollToBottom()
        }
        do {
            let response = try await OrbCore.shared.call("/api/control/queue/\(OrbCore.escape(queueID))/send-now?interrupt=true", method: "POST")
            switch OrbSendFlow.sendNowOutcome(response) {
            case .live, .promoted:
                store.sent(to: id)
            case .fallback:
                _ = try? await OrbCore.shared.call("/api/control/queue/\(OrbCore.escape(queueID))", method: "DELETE")
                _ = try? await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST")
                _ = try await OrbCore.shared.call("/api/control/message", method: "POST", body: .object(["mission_id": .string(id), "content": .string(wireContent), "client_message_id": .string(UUID().uuidString)]))
                store.sent(to: id)
            }
            try? await store.refresh(force: true)
            await refreshQueue()
        } catch {
            withAnimation(reduceMotion ? nil : .snappy(duration: OrbSendFlow.leaveSeconds)) {
                followUps = followUps.unhide(queueID)
                pending = nil; askedAt = nil; pendingBaselineTurns = []
            }
            self.error = "Couldn’t send now. \(error.localizedDescription)"
        }
    }

    /// A failed send puts the question back in the field instead of losing it.
    private func restore(_ text: String, _ files: [OrbAttachment]) {
        pending = nil; askedAt = nil; pendingBaselineTurns = []
        if question.isEmpty { question = text }
        if attachments.isEmpty { attachments = files }
    }

    private func stop() async {
        guard let id = store.boundID else { return }
        do { _ = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(id))/cancel", method: "POST"); try await store.refresh(force: true); await refreshQueue() }
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
