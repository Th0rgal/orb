import SwiftUI

@Observable
final class OrbMissionUnreadStore {
    static let shared = OrbMissionUnreadStore()

    private let defaultsKey = "orb.missionSeenAt.v2"
    private(set) var version = 0
    private var seenByMissionID: [String: String] = [:]
    private var manuallyUnreadIDs: Set<String> = []

    private static let unreadResponseStates: Set<String> = [
        "awaiting_user", "waiting_user", "completed", "succeeded",
        "failed", "blocked", "not_feasible", "paused", "interrupted",
    ]

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            seenByMissionID = stored
        }
    }

    func isUnread(row: OrbRow, hasInteraction: Bool = false) -> Bool {
        _ = version
        guard hasInteraction || Self.unreadResponseStates.contains(row.state) else {
            return false
        }
        if manuallyUnreadIDs.contains(row.id) {
            return true
        }
        let firstViewed = row.raw["first_viewed_at"].text
        if !firstViewed.isEmpty {
            if row.updatedAt.isEmpty || firstViewed >= row.updatedAt {
                return false
            }
        }
        if let seen = seenByMissionID[row.id] {
            if row.updatedAt.isEmpty || seen >= row.updatedAt {
                return false
            }
        }
        return true
    }

    func markRead(_ row: OrbRow, syncBackend: Bool = true) {
        markRead(id: row.id, updatedAt: row.updatedAt, syncBackend: syncBackend)
    }

    func markRead(id: String, updatedAt: String? = nil, syncBackend: Bool = true) {
        guard !id.isEmpty else { return }
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let stamp = max(updatedAt ?? "", nowIso)
        manuallyUnreadIDs.remove(id)
        if seenByMissionID[id] != stamp {
            seenByMissionID[id] = stamp
            UserDefaults.standard.set(seenByMissionID, forKey: defaultsKey)
            version += 1
        }
        if syncBackend {
            Task {
                _ = try? await OrbCore.shared.call(
                    "/api/control/missions/\(OrbCore.escape(id))/opened",
                    method: "POST"
                )
            }
        }
    }

    func markUnread(id: String) {
        guard !id.isEmpty else { return }
        manuallyUnreadIDs.insert(id)
        version += 1
    }

    func toggleUnread(_ row: OrbRow) {
        if isUnread(row: row) {
            markRead(row)
        } else {
            manuallyUnreadIDs.insert(row.id)
            version += 1
        }
    }

    func markAllRead(_ rows: [OrbRow]) {
        guard !rows.isEmpty else { return }
        let nowIso = ISO8601DateFormatter().string(from: Date())
        for row in rows {
            manuallyUnreadIDs.remove(row.id)
            seenByMissionID[row.id] = max(row.updatedAt, nowIso)
            let id = row.id
            Task {
                _ = try? await OrbCore.shared.call(
                    "/api/control/missions/\(OrbCore.escape(id))/opened",
                    method: "POST"
                )
            }
        }
        UserDefaults.standard.set(seenByMissionID, forKey: defaultsKey)
        version += 1
    }
}

enum OrbInboxTone: String, Equatable, Sendable {
    case amber
    case red
    case blue
    case green
    case muted

    var foreground: Color {
        switch self {
        case .amber: return OrbStyle.warning
        case .red: return OrbStyle.error
        case .blue: return Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255)
        case .green: return OrbStyle.success
        case .muted: return OrbStyle.textSecondary
        }
    }

    var background: Color {
        switch self {
        case .amber: return OrbStyle.warning.opacity(0.14)
        case .red: return OrbStyle.error.opacity(0.14)
        case .blue: return Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255).opacity(0.14)
        case .green: return OrbStyle.success.opacity(0.14)
        case .muted: return Color.white.opacity(0.06)
        }
    }
}

enum OrbInboxCategory: String, Equatable, Sendable {
    case needsYou
    case ready
    case working
    case hidden
}

struct OrbInboxOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let isPrimary: Bool
    let payload: OrbJSON
}

struct OrbInboxInteraction: Equatable, Sendable {
    let callID: String
    let toolName: String
    let kind: String
    let prompt: String
    let commandPreview: String?
    let options: [OrbInboxOption]
}

struct OrbInboxItem: Identifiable, Equatable {
    let id: String
    let row: OrbRow
    let projectSlug: String
    let projectTitle: String
    let headline: String
    let summary: String
    let badge: String
    let tone: OrbInboxTone
    let category: OrbInboxCategory
    let machine: String
    let isGoal: Bool
    let unread: Bool
    let attention: Bool
    let updatedAt: String
    let interaction: OrbInboxInteraction?
}

enum OrbInboxModel {
    static let maxSummaryChars = 112

    private static let workingStatuses: Set<String> = [
        "active", "running", "starting", "pending", "queued", "resuming", "waiting_background",
    ]
    private static let hiddenStatuses: Set<String> = [
        "acknowledged", "archived", "deleted", "cancelled",
    ]
    private static let interactiveTools: Set<String> = [
        "ui_native_request", "AskUserQuestion", "question",
    ]

    static func stripMarkdownToProse(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw
        // Replace fenced code blocks with compact placeholder
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        // Drop standalone markdown heading lines (e.g. "## Summary") so the actual prose sentence leads
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+[^\n]*$"#, with: " ", options: .regularExpression)
        // Strip blockquote prefixes
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}>\s*"#, with: "", options: .regularExpression)
        // Strip bullet and numbered list markers
        s = s.replacingOccurrences(of: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        // Unwrap markdown links [label](url) -> label
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Unwrap inline code and emphasis markers
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.*?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*|_)(.*?)\1"#, with: "$2", options: .regularExpression)
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clipToSentence(_ raw: String, maxChars: Int = maxSummaryChars) -> String {
        let prose = stripMarkdownToProse(raw)
        guard !prose.isEmpty else { return "" }

        var cutIndex: String.Index?
        for idx in prose.indices {
            let ch = prose[idx]
            if ch == "." || ch == "?" || ch == "!" {
                let nextIdx = prose.index(after: idx)
                let isEnd = nextIdx == prose.endIndex || prose[nextIdx].isWhitespace
                let dist = prose.distance(from: prose.startIndex, to: nextIdx)
                if isEnd && dist >= 12 {
                    cutIndex = nextIdx
                    break
                }
            }
        }
        let candidate = cutIndex.map { String(prose[..<$0]).trimmingCharacters(in: .whitespaces) } ?? prose
        if candidate.count <= maxChars { return candidate }
        let prefix = String(candidate.prefix(max(1, maxChars - 1)))
        if let lastSpace = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: lastSpace) >= maxChars / 2 {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func humanizeStatusText(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
            return ""
        }
        trimmed = trimmed.replacingOccurrences(
            of: #"(?i);\s*error:\s*command exited with (?:Some\()?(-?\d+)\)?"#,
            with: "",
            options: .regularExpression
        )
        trimmed = trimmed.replacingOccurrences(
            of: #"\(exit Some\((-?\d+)\)\)"#,
            with: "(exit $1)",
            options: .regularExpression
        )
        trimmed = trimmed.replacingOccurrences(
            of: #"\bSome\((-?\d+)\)"#,
            with: "$1",
            options: .regularExpression
        )
        trimmed = trimmed.replacingOccurrences(
            of: #"finished with state 'failed'\s*"#,
            with: "failed ",
            options: [.regularExpression, .caseInsensitive]
        )
        trimmed = trimmed.replacingOccurrences(
            of: #"(?i)^Remote\s+(\S+)\s+job\s+[0-9a-f-]{36}\s+on\s+node\s+'([^']+)'\s+"#,
            with: "Remote $1 run on $2 ",
            options: .regularExpression
        )
        trimmed = trimmed.replacingOccurrences(
            of: #"(?i)^Job\s+[0-9a-f-]{36}\s+on\s+node\s+'([^']+)'\s+"#,
            with: "Remote run on $1 ",
            options: .regularExpression
        )
        return trimmed
    }

    static func extractInteraction(
        row: OrbRow,
        events: [StoredEvent],
        answered: Set<String> = []
    ) -> OrbInboxInteraction? {
        if hiddenStatuses.contains(row.state) || ["completed", "succeeded", "failed", "not_feasible"].contains(row.state) {
            return nil
        }
        let resolvedCalls = Set(events.compactMap { $0.eventType == "tool_result" ? $0.toolCallId : nil })
        guard let callEvent = events.reversed().first(where: { event in
            guard event.eventType == "tool_call",
                  let name = event.toolName,
                  interactiveTools.contains(name),
                  let callID = event.toolCallId,
                  !callID.isEmpty else { return false }
            return !answered.contains(callID) && !resolvedCalls.contains(callID)
        }),
        let callID = callEvent.toolCallId,
        let data = callEvent.content.data(using: .utf8),
        let request = try? JSONDecoder().decode(OrbJSON.self, from: data) else {
            return nil
        }

        let toolName = callEvent.toolName ?? "ui_native_request"
        let method = request["method"].text.isEmpty
            ? (toolName == "AskUserQuestion" ? "claude_questions" : "question")
            : request["method"].text
        let params = request["params"] == .null ? request : request["params"]

        if method == "permission" {
            let desc = [
                params["input"]["description"].text,
                params["input"]["command"].text,
                params["input"]["file_path"].text,
                params["tool"].text,
            ].first(where: { !$0.isEmpty }) ?? "Allow this tool action?"
            let cmd = params["input"]["command"].text.isEmpty ? nil : params["input"]["command"].text
            return OrbInboxInteraction(
                callID: callID,
                toolName: toolName,
                kind: "permission",
                prompt: clipToSentence(desc),
                commandPreview: cmd,
                options: [
                    OrbInboxOption(
                        id: "1",
                        label: "Approve",
                        isPrimary: true,
                        payload: .object(["action": .string("accept")])
                    ),
                    OrbInboxOption(
                        id: "2",
                        label: "Decline",
                        isPrimary: false,
                        payload: .object(["action": .string("revise")])
                    ),
                ]
            )
        }

        if method == "plan" {
            let planText = params["plan"].text.isEmpty
                ? "Review the proposed implementation plan."
                : params["plan"].text
            return OrbInboxInteraction(
                callID: callID,
                toolName: toolName,
                kind: "plan",
                prompt: clipToSentence(planText),
                commandPreview: nil,
                options: [
                    OrbInboxOption(
                        id: "1",
                        label: "Approve plan",
                        isPrimary: true,
                        payload: .object(["action": .string("accept")])
                    ),
                    OrbInboxOption(
                        id: "2",
                        label: "Revise",
                        isPrimary: false,
                        payload: .object(["action": .string("revise")])
                    ),
                ]
            )
        }

        let questions = params["questions"].items
        let firstQ = questions.first ?? .null
        let qPrompt = firstQ["question"].text.isEmpty
            ? "Waiting for your answer."
            : firstQ["question"].text
        let canQuickPick = questions.count == 1 && !firstQ["multiSelect"].flag && !firstQ["options"].items.isEmpty
        let claudeFormat = method == "claude_questions" || toolName == "AskUserQuestion"
        let qKey = firstQ["id"].text.isEmpty ? "0" : firstQ["id"].text

        var options: [OrbInboxOption] = []
        if canQuickPick {
            for (idx, opt) in firstQ["options"].items.prefix(3).enumerated() {
                let label = opt["label"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                let mapped: [String: OrbJSON] = claudeFormat
                    ? [firstQ["question"].text: .string(label)]
                    : [qKey: .object(["answers": .array([.string(label)])])]
                options.append(
                    OrbInboxOption(
                        id: String(idx + 1),
                        label: label,
                        isPrimary: idx == 0,
                        payload: .object(["answers": .object(mapped)])
                    )
                )
            }
        }

        return OrbInboxInteraction(
            callID: callID,
            toolName: toolName,
            kind: "question",
            prompt: clipToSentence(qPrompt),
            commandPreview: nil,
            options: options
        )
    }

    static func isSubagent(row: OrbRow) -> Bool {
        if !row.raw["parent_mission_id"].text.isEmpty || !row.raw["callback_parent_mission_id"].text.isEmpty {
            return true
        }
        if row.raw["tags"].items.contains(where: {
            $0.text.hasPrefix("worker-dispatch:") || $0.text == "superseded" || $0.text.hasPrefix("superseded-by:")
        }) {
            return true
        }
        let rawTitle = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTitle.range(of: #"^you are a sub-?agent\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    static func classify(row: OrbRow, interaction: OrbInboxInteraction?) -> OrbInboxCategory {
        guard row.mobile else { return .hidden }
        let status = row.state
        if hiddenStatuses.contains(status) { return .hidden }
        if interaction != nil { return .needsYou }
        if isSubagent(row: row) { return .hidden }
        if workingStatuses.contains(status) { return .working }
        if ["blocked", "failed", "not_feasible", "awaiting_user", "waiting_user"].contains(status) {
            return .needsYou
        }
        if ["completed", "succeeded", "paused", "interrupted"].contains(status) {
            return .ready
        }
        return .hidden
    }

    static func extractSummary(
        row: OrbRow,
        events: [StoredEvent],
        interaction: OrbInboxInteraction?
    ) -> String {
        if let prompt = interaction?.prompt, !prompt.isEmpty {
            return prompt
        }

        for event in events.reversed() {
            if event.eventType == "error" {
                let clean = humanizeStatusText(event.content)
                if !clean.isEmpty { return clipToSentence(clean) }
            }
            if event.eventType == "assistant_message" || event.eventType == "assistant_message_canonical" {
                let clean = humanizeStatusText(event.content)
                if !clean.isEmpty { return clipToSentence(clean) }
            }
        }

        for entry in row.raw["history"].items.reversed() where entry["role"].text == "assistant" {
            let clean = humanizeStatusText(entry["content"].text)
            if !clean.isEmpty { return clipToSentence(clean) }
        }

        let remoteErr = humanizeStatusText(row.raw["remote_job"]["error"].text)
        if !remoteErr.isEmpty { return clipToSentence(remoteErr) }

        let statusMsg = humanizeStatusText(row.raw["status_message"].text)
        if !statusMsg.isEmpty { return clipToSentence(statusMsg) }

        let termReason = humanizeStatusText(row.raw["terminal_reason"].text)
        if !termReason.isEmpty { return clipToSentence(termReason) }

        switch row.state {
        case "completed", "succeeded":
            return "Finished the task and is ready for your review."
        case "awaiting_user", "waiting_user":
            return "Finished the turn and is waiting for your follow-up."
        case "blocked":
            return "Blocked and needs your input to continue."
        case "failed", "not_feasible":
            return "Stopped with an error — open to inspect or resume."
        case "active", "running", "starting":
            return "Working in the background…"
        default:
            return "Ready for your review."
        }
    }

    static func resolveBadgeAndTone(
        row: OrbRow,
        summary: String,
        interaction: OrbInboxInteraction?
    ) -> (badge: String, tone: OrbInboxTone) {
        if let interaction {
            switch interaction.kind {
            case "permission": return ("Approval", .amber)
            case "plan": return ("Plan review", .amber)
            default: return ("Question", .amber)
            }
        }
        switch row.state {
        case "blocked":
            return ("Blocked", .amber)
        case "failed":
            return ("Failed", .red)
        case "not_feasible":
            return ("Not feasible", .red)
        case "awaiting_user", "waiting_user":
            return summary.trimmingCharacters(in: .whitespaces).hasSuffix("?")
                ? ("Question", .blue)
                : ("Waiting", .blue)
        case "completed", "succeeded":
            return ("Completed", .green)
        case "paused", "interrupted":
            return ("Paused", .muted)
        default:
            return ("Working", .muted)
        }
    }

    static func resolveMachine(row: OrbRow) -> String {
        if row.clientPlaced {
            return row.clientMachineLabel
        }
        if row.backend.hasPrefix("cloud_") {
            return OrbStyle.serviceName(row.backend)
        }
        let nodeID = [
            row.raw["remote_job"]["node_id"].text,
            row.raw["remote_node_id"].text,
        ].first(where: { !$0.isEmpty }) ?? ""
        if !nodeID.isEmpty { return nodeID }
        return ""
    }

    static func buildItem(
        row: OrbRow,
        projectsBySlug: [String: String],
        events: [StoredEvent] = [],
        answered: Set<String> = []
    ) -> OrbInboxItem? {
        let interaction = extractInteraction(row: row, events: events, answered: answered)
        let category = classify(row: row, interaction: interaction)
        guard category != .hidden else { return nil }

        let slug = row.raw["project"].text.isEmpty ? "default" : row.raw["project"].text
        let projectTitle = projectsBySlug[slug] ?? (slug == "default" ? "Default" : slug)

        let rawTitle = OrbStyle.displayTitle(row.raw["title"].text)
        let firstUser = row.raw["history"].items.first(where: { $0["role"].text == "user" })?["content"].text ?? ""
        let headline = !rawTitle.isEmpty
            ? rawTitle
            : (!firstUser.isEmpty ? clipToSentence(firstUser, maxChars: 54) : "Untitled conversation")

        let summary = extractSummary(row: row, events: events, interaction: interaction)
        let (badge, tone) = resolveBadgeAndTone(row: row, summary: summary, interaction: interaction)
        let isGoal = row.raw["goal_mode"].flag || OrbStyle.goalObjective(row.raw["title"].text) != nil
        let unread = OrbMissionUnreadStore.shared.isUnread(row: row, hasInteraction: interaction != nil)
        let attention = interaction != nil || ["blocked", "failed", "not_feasible"].contains(row.state)

        return OrbInboxItem(
            id: row.id,
            row: row,
            projectSlug: slug,
            projectTitle: projectTitle,
            headline: headline,
            summary: summary,
            badge: badge,
            tone: tone,
            category: category,
            machine: resolveMachine(row: row),
            isGoal: isGoal,
            unread: unread,
            attention: attention,
            updatedAt: row.updatedAt,
            interaction: interaction
        )
    }

    private static func urgencyRank(_ item: OrbInboxItem) -> Int {
        if item.interaction != nil { return 0 }
        switch item.row.state {
        case "blocked": return 1
        case "awaiting_user", "waiting_user": return 2
        case "failed", "not_feasible": return 3
        default: return 4
        }
    }

    static func buildSections(
        missions: [OrbRow],
        projects: [OrbRow],
        eventsByMission: [String: [StoredEvent]] = [:],
        answeredCallIDs: Set<String> = [],
        dismissedIDs: Set<String> = []
    ) -> (needsYou: [OrbInboxItem], ready: [OrbInboxItem], working: [OrbInboxItem]) {
        var projectsBySlug: [String: String] = ["default": "Default"]
        for p in projects {
            projectsBySlug[p.id] = p.name
        }

        var needsYou: [OrbInboxItem] = []
        var ready: [OrbInboxItem] = []
        var working: [OrbInboxItem] = []
        var seen: Set<String> = []

        for row in missions where !seen.contains(row.id) && !dismissedIDs.contains(row.id) {
            seen.insert(row.id)
            let rawSlug = row.raw["project"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !projects.isEmpty {
                let isClient = row.raw["tags"].items.contains(where: { $0.text == "placement:client" })
                if rawSlug.isEmpty && !isClient { continue }
                let slug = rawSlug.isEmpty ? "default" : rawSlug
                if projectsBySlug[slug] == nil { continue }
            }
            let events = eventsByMission[row.id] ?? []
            guard let item = buildItem(
                row: row,
                projectsBySlug: projectsBySlug,
                events: events,
                answered: answeredCallIDs
            ) else { continue }
            switch item.category {
            case .needsYou: needsYou.append(item)
            case .ready: ready.append(item)
            case .working: working.append(item)
            case .hidden: break
            }
        }

        needsYou.sort { a, b in
            let ua = urgencyRank(a)
            let ub = urgencyRank(b)
            if ua != ub { return ua < ub }
            return a.updatedAt > b.updatedAt
        }
        ready.sort { $0.updatedAt > $1.updatedAt }
        working.sort { $0.updatedAt > $1.updatedAt }

        return (needsYou, ready, working)
    }
}

enum OrbInboxFilterMode: String, CaseIterable {
    case unread
    case attention
    case all

    var title: String {
        switch self {
        case .unread: return "Unread"
        case .attention: return "Attention"
        case .all: return "All"
        }
    }
}

struct OrbInboxView: View {
    let projects: [OrbRow]
    @Binding var actionableCount: Int
    let onOpenMission: (OrbRow) -> Void

    @State private var missions: [OrbRow] = []
    @State private var loading = true
    @State private var error = ""
    @State private var filterMode: OrbInboxFilterMode = .unread
    @State private var selectedProject: String?
    @State private var showWorking = false
    @State private var dismissedIDs: Set<String> = []
    @State private var busyIDs: Set<String> = []
    @State private var answeredCallIDs: Set<String> = []
    @State private var eventsByMission: [String: [StoredEvent]] = [:]
    @State private var replyingMissionID: String?
    @State private var replyDraft = ""
    @FocusState private var replyFocused: Bool
    @State private var undoItem: (id: String, title: String)?

    private let api = OrbCore.shared
    private let appearance = OrbProjectAppearance.shared
    private let unreadStore = OrbMissionUnreadStore.shared

    private var computed: (needsYou: [OrbInboxItem], ready: [OrbInboxItem], working: [OrbInboxItem]) {
        _ = unreadStore.version
        return OrbInboxModel.buildSections(
            missions: missions,
            projects: projects,
            eventsByMission: eventsByMission,
            answeredCallIDs: answeredCallIDs,
            dismissedIDs: dismissedIDs
        )
    }

    private func matchesFilter(_ item: OrbInboxItem, mode: OrbInboxFilterMode? = nil) -> Bool {
        switch mode ?? filterMode {
        case .unread: return item.unread
        case .attention: return item.attention
        case .all: return true
        }
    }

    private var unreadCount: Int {
        (computed.needsYou + computed.ready).filter(\.unread).count
    }

    private var attentionCount: Int {
        (computed.needsYou + computed.ready).filter(\.attention).count
    }

    private var totalActionableCount: Int {
        computed.needsYou.count + computed.ready.count
    }

    private var modeFilteredNeedsYou: [OrbInboxItem] {
        computed.needsYou.filter { matchesFilter($0) }
    }

    private var modeFilteredReady: [OrbInboxItem] {
        computed.ready.filter { matchesFilter($0) }
    }

    private var filteredNeedsYou: [OrbInboxItem] {
        guard let slug = selectedProject else { return modeFilteredNeedsYou }
        return modeFilteredNeedsYou.filter { $0.projectSlug == slug }
    }

    private var filteredReady: [OrbInboxItem] {
        guard let slug = selectedProject else { return modeFilteredReady }
        return modeFilteredReady.filter { $0.projectSlug == slug }
    }

    private var projectFilters: [(slug: String, title: String, count: Int)] {
        var counts: [String: (title: String, count: Int)] = [:]
        for item in modeFilteredNeedsYou + modeFilteredReady {
            let current = counts[item.projectSlug] ?? (item.projectTitle, 0)
            counts[item.projectSlug] = (item.projectTitle, current.count + 1)
        }
        return counts
            .map { (slug: $0.key, title: $0.value.title, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    headerSummary
                    modeFilterBar

                    if projectFilters.count > 1 {
                        projectFilterChips
                    }

                    if !error.isEmpty {
                        OrbNotice(message: error)
                    }

                    if showWorking && !computed.working.isEmpty {
                        workingSection
                    }

                    if loading && missions.isEmpty {
                        inboxSkeletons
                    } else if filteredNeedsYou.isEmpty && filteredReady.isEmpty {
                        emptyInboxState
                    } else {
                        if !filteredNeedsYou.isEmpty {
                            sectionHeader(title: "NEEDS YOU", count: filteredNeedsYou.count)
                            VStack(spacing: 8) {
                                ForEach(filteredNeedsYou) { item in
                                    inboxCard(item)
                                }
                            }
                        }

                        if !filteredReady.isEmpty {
                            HStack {
                                sectionHeader(title: "READY FOR REVIEW", count: filteredReady.count)
                                Spacer()
                                Button {
                                    OrbHaptics.success()
                                    Task { await markAllReadyDone() }
                                } label: {
                                    Text("Mark all done")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(OrbStyle.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("inbox.markAllDone")
                            }
                            VStack(spacing: 8) {
                                ForEach(filteredReady) { item in
                                    inboxCard(item)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, undoItem != nil ? 76 : 24)
            }
            .background(OrbStyle.background)
            .refreshable { await load(force: true) }

            if let undo = undoItem {
                undoToast(undo)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await load(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled {
                    await load(force: true)
                }
            }
        }
        .onChange(of: unreadCount) { _, newValue in
            actionableCount = newValue
        }
    }

    private var modeFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(OrbInboxFilterMode.allCases, id: \.rawValue) { mode in
                    let active = filterMode == mode
                    let count = mode == .unread ? unreadCount : (mode == .attention ? attentionCount : totalActionableCount)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            filterMode = mode
                        }
                        OrbHaptics.selection()
                    } label: {
                        HStack(spacing: 5) {
                            if mode == .unread {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                            }
                            Text(mode.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(active ? .primary : OrbStyle.textSecondary)
                            Text("\(count)")
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            active ? OrbStyle.elevated : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox.filter.\(mode.rawValue)")
                }
            }
            .padding(3)
            .background(OrbStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))

            Spacer()

            if unreadCount > 0 {
                Button {
                    OrbHaptics.selection()
                    withAnimation(.snappy(duration: 0.2)) {
                        unreadStore.markAllRead((computed.needsYou + computed.ready).filter(\.unread).map(\.row))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Read all")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(OrbStyle.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inbox.markAllRead")
            }
        }
    }

    private var headerSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("New agent responses and questions waiting on you.")
                .font(.footnote)
                .foregroundStyle(OrbStyle.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if !computed.working.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        showWorking.toggle()
                    }
                    OrbHaptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        OrbRunningDots(size: 11)
                        Text("\(computed.working.count) working")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        showWorking ? OrbStyle.elevated : OrbStyle.surface,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(showWorking ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inbox.workingPill")
            }
        }
    }

    private var projectFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selectedProject = nil }
                    OrbHaptics.selection()
                } label: {
                    Text("All projects")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(selectedProject == nil ? .primary : OrbStyle.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            selectedProject == nil ? OrbStyle.elevated : OrbStyle.surface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(selectedProject == nil ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                ForEach(projectFilters, id: \.slug) { proj in
                    let active = selectedProject == proj.slug
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedProject = active ? nil : proj.slug
                        }
                        OrbHaptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appearance.color(proj.slug) ?? OrbStyle.icon)
                                .frame(width: 6, height: 6)
                            Text(proj.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(active ? .primary : OrbStyle.textSecondary)
                                .lineLimit(1)
                            Text("\(proj.count)")
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            active ? OrbStyle.elevated : OrbStyle.surface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(active ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title: "WORKING IN BACKGROUND", count: computed.working.count)
            VStack(spacing: 6) {
                ForEach(computed.working) { item in
                    Button {
                        OrbHaptics.selection()
                        onOpenMission(item.row)
                    } label: {
                        HStack(spacing: 10) {
                            OrbRunningDots(size: 11)
                            Circle()
                                .fill(appearance.color(item.projectSlug) ?? OrbStyle.icon)
                                .frame(width: 6, height: 6)
                            Text(item.projectTitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(OrbStyle.textSecondary)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(OrbStyle.textMuted)
                            Text(item.headline)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if !item.updatedAt.isEmpty {
                                Text(OrbStyle.relativeTime(item.updatedAt))
                                    .font(.caption2)
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(OrbStyle.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(OrbPressButtonStyle())
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(OrbStyle.textMuted)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OrbStyle.textMuted)
                .monospacedDigit()
        }
        .padding(.top, 2)
    }

    private func inboxCard(_ item: OrbInboxItem) -> some View {
        let isReplying = replyingMissionID == item.id
        let isBusy = busyIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 9) {
            Button {
                OrbHaptics.selection()
                unreadStore.markRead(item.row)
                onOpenMission(item.row)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // Line 1: Unread dot + Project dot + Project name + Goal tag + Headline + Badge + Time
                    HStack(alignment: .center, spacing: 6) {
                        if item.unread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
                        }
                        Circle()
                            .fill(appearance.color(item.projectSlug) ?? OrbStyle.icon)
                            .frame(width: 7, height: 7)
                        Text(item.projectTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(OrbStyle.textMuted)
                        if item.isGoal {
                            Text("Goal")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255).opacity(0.14),
                                    in: Capsule()
                                )
                        }
                        Text(item.headline)
                            .font(.subheadline.weight(item.unread ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(item.badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(item.tone.foreground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(item.tone.background, in: Capsule())

                        if !item.updatedAt.isEmpty {
                            Text(OrbStyle.relativeTime(item.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                                .monospacedDigit()
                        }
                    }

                    // Line 2: 1-sentence prose summary
                    Text(item.summary)
                        .font(.footnote)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let cmd = item.interaction?.commandPreview, !cmd.isEmpty {
                        Text(cmd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Quick actions row (Options / Read / Reply / Done)
            HStack(spacing: 8) {
                if let interaction = item.interaction, !interaction.options.isEmpty {
                    ForEach(interaction.options) { opt in
                        Button {
                            OrbHaptics.light()
                            Task { await pickOption(item: item, interaction: interaction, option: opt) }
                        } label: {
                            Text(opt.label)
                                .font(.caption.weight(opt.isPrimary ? .semibold : .medium))
                                .foregroundStyle(opt.isPrimary ? OrbStyle.background : .primary)
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(
                                    opt.isPrimary ? Color.white : Color.white.opacity(0.06),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(opt.isPrimary ? Color.clear : OrbStyle.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }

                if !item.machine.isEmpty && (item.interaction?.options.isEmpty ?? true) {
                    Text(item.machine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OrbStyle.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                if item.unread {
                    Button {
                        OrbHaptics.selection()
                        withAnimation(.snappy(duration: 0.2)) {
                            unreadStore.markRead(item.row)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                            Text("Read")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(OrbStyle.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }

                Button {
                    OrbHaptics.selection()
                    withAnimation(.snappy(duration: 0.2)) {
                        if isReplying {
                            replyingMissionID = nil
                            replyDraft = ""
                            replyFocused = false
                        } else {
                            replyingMissionID = item.id
                            replyDraft = ""
                            replyFocused = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reply")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(isReplying ? .primary : OrbStyle.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isReplying ? OrbStyle.elevated : Color.white.opacity(0.04),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("inbox.reply.\(item.id)")

                Button {
                    OrbHaptics.success()
                    Task { await markDone(item) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Done")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(OrbStyle.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04), in: Capsule())
                    .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("inbox.done.\(item.id)")
            }

            if isReplying {
                HStack(spacing: 8) {
                    TextField(
                        item.interaction != nil ? "Reply to \(item.headline)…" : "Send follow-up…",
                        text: $replyDraft
                    )
                    .font(.footnote)
                    .focused($replyFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await submitInlineReply(item) }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OrbStyle.borderStrong, lineWidth: 1)
                    )

                    Button {
                        OrbHaptics.light()
                        Task { await submitInlineReply(item) }
                    } label: {
                        Text(isBusy ? "…" : "Send")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? OrbStyle.textMuted
                                    : OrbStyle.background
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.white.opacity(0.08)
                                    : Color.white,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isReplying ? OrbStyle.borderStrong : OrbStyle.border, lineWidth: 1)
        )
        .opacity(isBusy ? 0.6 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.row.\(item.id)")
        .contextMenu {
            Button {
                unreadStore.markRead(item.row)
                onOpenMission(item.row)
            } label: {
                Label("Open conversation", systemImage: "bubble.left.and.bubble.right")
            }
            Button {
                unreadStore.toggleUnread(item.row)
            } label: {
                Label(item.unread ? "Mark as read" : "Mark as unread", systemImage: item.unread ? "envelope.open" : "envelope.badge")
            }
            Button {
                replyingMissionID = item.id
                replyFocused = true
            } label: {
                Label("Quick reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                Task { await markDone(item) }
            } label: {
                Label("Mark done", systemImage: "checkmark.circle")
            }
        }
    }

    private var emptyInboxState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(OrbStyle.success.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OrbStyle.success)
            }
            Text(
                selectedProject != nil
                    ? "Nothing in this project"
                    : (filterMode == .unread ? "All caught up on unread responses" : "Inbox zero")
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            Text(
                filterMode == .unread && totalActionableCount > 0
                    ? "You’ve opened every recent agent response. \(totalActionableCount) earlier \(totalActionableCount == 1 ? "conversation is" : "conversations are") in All."
                    : (!computed.working.isEmpty
                        ? "\(computed.working.count) \(computed.working.count == 1 ? "agent is" : "agents are") working quietly in the background."
                        : "When an agent needs a decision or finishes a run, it will surface here.")
            )
            .font(.footnote)
            .foregroundStyle(OrbStyle.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if filterMode != .all && totalActionableCount > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { filterMode = .all }
                    OrbHaptics.selection()
                } label: {
                    Text("View all (\(totalActionableCount))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(OrbStyle.elevated, in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(OrbStyle.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OrbStyle.border, lineWidth: 1)
        )
        .accessibilityIdentifier("inbox.empty")
    }

    private var inboxSkeletons: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { idx in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 7, height: 7)
                        Text(idx.isMultiple(of: 2) ? "Project · Refactor mission title" : "Project · Verify proof build")
                            .font(.subheadline.weight(.semibold))
                            .redacted(reason: .placeholder)
                        Spacer()
                        Text("12m")
                            .font(.caption2)
                            .redacted(reason: .placeholder)
                    }
                    Text("Finished the requested changes and verified the test suite passes cleanly.")
                        .font(.footnote)
                        .redacted(reason: .placeholder)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OrbStyle.border, lineWidth: 1)
                )
            }
        }
        .orbShimmer(active: true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading inbox")
        .accessibilityIdentifier("inbox.loading")
    }

    private func undoToast(_ undo: (id: String, title: String)) -> some View {
        HStack(spacing: 12) {
            Text("Marked “\(undo.title)” as done")
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button {
                OrbHaptics.light()
                Task { await undoLastDone() }
            } label: {
                Text("Undo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OrbStyle.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.undo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OrbStyle.elevated, in: Capsule())
        .overlay(Capsule().stroke(OrbStyle.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func load(force: Bool) async {
        defer { loading = false }
        if missions.isEmpty, let cached = OrbDisk.read("inbox:missions", as: OrbJSON.self) {
            missions = cached.items.map { OrbRow($0) }.filter(\.mobile)
            seedCachedEvents(for: missions)
            actionableCount = unreadCount
        }
        do {
            let raw = try await api.call("/api/control/missions?limit=100&all=true")
            let rows = raw.items.map { OrbRow($0) }.filter(\.mobile)
            missions = rows
            OrbDisk.saveAsync(raw, key: "inbox:missions")
            seedCachedEvents(for: rows)
            actionableCount = unreadCount
            error = ""
            await prefetchActiveEvents(for: rows)
            actionableCount = unreadCount
        } catch {
            if missions.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func seedCachedEvents(for rows: [OrbRow]) {
        for row in rows {
            let cached = OrbReadCache.readEvents(row.id)
            if !cached.isEmpty {
                eventsByMission[row.id] = cached
            }
        }
    }

    private func prefetchActiveEvents(for rows: [OrbRow]) async {
        let candidates = rows.filter {
            ["active", "running", "starting", "awaiting_user", "waiting_user", "blocked"].contains($0.state)
        }.prefix(8)
        for row in candidates {
            guard !Task.isCancelled else { return }
            if let batch = try? await APIService.shared.getMissionEventsWithMeta(id: row.id, limit: 120, sinceSeq: nil) {
                OrbReadCache.saveEvents(row.id, events: batch.events)
                eventsByMission[row.id] = batch.events
            }
        }
    }

    private func markDone(_ item: OrbInboxItem) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        withAnimation(.snappy(duration: 0.22)) {
            _ = dismissedIDs.insert(item.id)
            if replyingMissionID == item.id {
                replyingMissionID = nil
                replyDraft = ""
            }
            undoItem = (id: item.id, title: item.headline)
        }
        unreadStore.markRead(item.row)
        actionableCount = unreadCount
        do {
            _ = try await api.call(
                "/api/control/missions/\(OrbCore.escape(item.id))/status",
                method: "POST",
                body: .object(["status": .string("acknowledged")])
            )
            OrbReadCache.invalidate("project:\(item.projectSlug)")
        } catch {
            withAnimation(.snappy(duration: 0.2)) {
                dismissedIDs.remove(item.id)
                undoItem = nil
            }
            self.error = error.localizedDescription
        }
    }

    private func markAllReadyDone() async {
        let items = filteredReady
        guard !items.isEmpty else { return }
        let ids = items.map(\.id)
        withAnimation(.snappy(duration: 0.22)) {
            for id in ids { dismissedIDs.insert(id) }
            unreadStore.markAllRead(items.map(\.row))
        }
        actionableCount = unreadCount
        do {
            for item in items {
                _ = try await api.call(
                    "/api/control/missions/\(OrbCore.escape(item.id))/status",
                    method: "POST",
                    body: .object(["status": .string("acknowledged")])
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func undoLastDone() async {
        guard let last = undoItem else { return }
        withAnimation(.snappy(duration: 0.22)) {
            undoItem = nil
            dismissedIDs.remove(last.id)
            unreadStore.markUnread(id: last.id)
        }
        actionableCount = unreadCount
        do {
            _ = try await api.call(
                "/api/control/missions/\(OrbCore.escape(last.id))/status",
                method: "POST",
                body: .object(["status": .string("paused")])
            )
            await load(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pickOption(
        item: OrbInboxItem,
        interaction: OrbInboxInteraction,
        option: OrbInboxOption
    ) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            let result = try await api.call(
                "/api/control/tool_result",
                method: "POST",
                body: .object([
                    "tool_call_id": .string(interaction.callID),
                    "name": .string(interaction.toolName),
                    "result": option.payload,
                ])
            )
            guard result["delivered"].flag else {
                throw OrbHTTPError(status: 409, detail: "This request has expired. Open the conversation to refresh.")
            }
            withAnimation(.snappy(duration: 0.22)) {
                _ = answeredCallIDs.insert(interaction.callID)
                unreadStore.markRead(item.row)
            }
            await load(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submitInlineReply(_ item: OrbInboxItem) async {
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            var body: [String: OrbJSON] = [
                "mission_id": .string(item.id),
                "content": .string(text),
                "queue_followup": .bool(true),
                "client_message_id": .string(UUID().uuidString.lowercased()),
            ]
            if let identity = OrbContinuation.identity(for: item.row.raw) {
                body["continue_identity"] = identity
            }
            _ = try await api.call("/api/control/message", method: "POST", body: .object(body))
            OrbHaptics.success()
            withAnimation(.snappy(duration: 0.22)) {
                replyingMissionID = nil
                replyDraft = ""
                replyFocused = false
                _ = dismissedIDs.insert(item.id)
                unreadStore.markRead(item.row)
            }
            await load(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
