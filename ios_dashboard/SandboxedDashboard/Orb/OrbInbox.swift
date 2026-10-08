import SwiftUI

struct OrbInboxModelPreset: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let subtitle: String
}

@Observable
final class OrbInboxSettings: @unchecked Sendable {
    static let shared = OrbInboxSettings()

    static let defaultModel = "builtin/smart"
    static let modelPresets: [OrbInboxModelPreset] = [
        OrbInboxModelPreset(
            id: "builtin/smart",
            label: "Smart Router (builtin/smart)",
            subtitle: "Default router for crisp 2–3 sentence AI Overviews"
        ),
        OrbInboxModelPreset(
            id: "builtin/fast",
            label: "Fast Router (builtin/fast)",
            subtitle: "Lowest latency router"
        ),
        OrbInboxModelPreset(
            id: "builtin/reasoning",
            label: "Reasoning Router (builtin/reasoning)",
            subtitle: "Deeper technical synthesis"
        ),
    ]

    private let aiSummaryKey = "orb.inbox.aiSummary.v1"
    private let modelKey = "orb.inbox.model.v1"

    private(set) var version = 0
    var aiSummary: Bool {
        didSet {
            UserDefaults.standard.set(aiSummary, forKey: aiSummaryKey)
            version += 1
        }
    }
    var model: String {
        didSet {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? Self.defaultModel : trimmed
            if model != resolved {
                model = resolved
                return
            }
            UserDefaults.standard.set(resolved, forKey: modelKey)
            version += 1
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: aiSummaryKey) == nil {
            self.aiSummary = true
        } else {
            self.aiSummary = UserDefaults.standard.bool(forKey: aiSummaryKey)
        }
        let savedModel = (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = savedModel.isEmpty ? Self.defaultModel : savedModel
    }
}

struct OrbInboxDigest: Codable, Equatable, Sendable {
    let task: String
    let outcome: String
    let verdict: String
    let model: String
    let updatedAt: String
}

@MainActor
@Observable
final class OrbInboxDigestStore {
    static let shared = OrbInboxDigestStore()

    private let diskKey = "inbox:digests:v4"
    private let maxConcurrent = 3
    private(set) var version = 0
    private var cache: [String: OrbInboxDigest] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private var activeCount = 0
    private var queue: [(priority: Int, work: () async -> Void)] = []

    private static let digestPrompt = [
        "Generate a Google AI Overview-style summary of this coding agent conversation turn for the operator's Inbox.",
        "Return ONLY a single-line JSON object with no markdown fences and no extra commentary:",
        #"{"task":"<concise 4-10 word summary of the user's latest follow-up request, or empty string if there was no follow-up or it repeats the mission title>","outcome":"<2-3 sentences (30-65 words) summarizing what the agent did, concrete technical findings/files/PRs/tests, and the final result or exact blocker>","verdict":"succeeded|failed|waiting|needs_input"}"#,
        "Rules:",
        "- Write in the same language as the conversation.",
        #"- If there is no follow-up request different from the mission title, or if the prompt was an automatic system resume, set "task" to "". Never write generic filler like "Execute the mission goal"."#,
        #"- Write "outcome" like an executive AI Overview (2-3 clear sentences, 30-65 words): state what was accomplished or investigated, cite concrete details (commit hashes, PR numbers, files edited, test counts, root cause), and state the final status or specific blocker."#,
        #"- Never write vague boilerplate like "Mission stopped and is currently blocked" or "Finished the task"."#,
        "- Verdict must be one of: succeeded, failed, waiting, needs_input.",
    ].joined(separator: "\n")

    private init() {
        if let stored = OrbDisk.read(diskKey, as: [String: OrbInboxDigest].self) {
            cache = stored
        }
    }

    private func cacheKey(missionID: String, updatedAt: String, model: String) -> String {
        "\(missionID)|\(updatedAt)|\(model)"
    }

    func get(row: OrbRow) -> OrbInboxDigest? {
        _ = version
        let settings = OrbInboxSettings.shared
        guard settings.aiSummary else { return nil }
        let key = cacheKey(missionID: row.id, updatedAt: row.updatedAt, model: settings.model)
        if let exact = cache[key] { return exact }
        let prefix = "\(row.id)|\(row.updatedAt)|"
        return cache.first(where: { $0.key.hasPrefix(prefix) })?.value
    }

    func request(row: OrbRow, events: [StoredEvent], priority: Int = 10) {
        let settings = OrbInboxSettings.shared
        guard settings.aiSummary else { return }
        if ["active", "running", "starting", "pending", "queued", "resuming", "waiting_background"].contains(row.state) {
            return
        }
        let model = settings.model
        let key = cacheKey(missionID: row.id, updatedAt: row.updatedAt, model: model)
        if cache[key] != nil || inFlight.contains(key) { return }
        if let failDate = failedAt[key], Date().timeIntervalSince(failDate) < 45 { return }

        let snapshot = Self.buildSnapshot(row: row, events: events)
        guard snapshot.count >= 24 else { return }

        inFlight.insert(key)
        queue.append((priority: priority, work: { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }
            do {
                let answer = try await Self.fetchBtw(missionID: row.id, context: snapshot, model: model)
                if let digest = Self.parseDigest(answer, updatedAt: row.updatedAt, model: model) {
                    self.cache[key] = digest
                    self.version += 1
                    OrbDisk.saveAsync(self.cache, key: self.diskKey)
                } else {
                    self.failedAt[key] = Date()
                }
            } catch {
                self.failedAt[key] = Date()
            }
        }))
        queue.sort { $0.priority < $1.priority }
        pumpQueue()
    }

    private func pumpQueue() {
        while activeCount < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            activeCount += 1
            Task { @MainActor in
                await next.work()
                self.activeCount -= 1
                self.pumpQueue()
            }
        }
    }

    private static func buildSnapshot(row: OrbRow, events: [StoredEvent]) -> String {
        var lines: [String] = []
        lines.append("Mission title: \(row.name)")
        lines.append("Mission status: \(row.state)")
        let term = row.raw["terminal_reason"].text
        if !term.isEmpty { lines.append("Terminal reason: \(term)") }
        let statusMsg = row.raw["status_message"].text
        if !statusMsg.isEmpty { lines.append("Status message: \(statusMsg)") }
        let remoteErr = row.raw["remote_job"]["error"].text
        if !remoteErr.isEmpty { lines.append("Remote error: \(remoteErr)") }

        var lastUser = ""
        var assistantBlocks: [String] = []
        var lastError = ""

        for event in events {
            if event.eventType == "user_message" {
                let text = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !OrbInboxModel.isSyntheticUserMessage(text) {
                    lastUser = text
                }
            } else if event.eventType == "assistant_message" || event.eventType == "assistant_message_canonical" {
                let clean = OrbInboxModel.humanizeStatusText(event.content)
                if !clean.isEmpty { assistantBlocks.append(clean) }
            } else if event.eventType == "error" {
                let clean = OrbInboxModel.humanizeStatusText(event.content)
                if clean.count >= 220 { assistantBlocks.append(clean) }
                else if !clean.isEmpty { lastError = clean }
            }
        }

        for entry in row.raw["history"].items.reversed() {
            let role = entry["role"].text
            let content = entry["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if lastUser.isEmpty, role == "user", !content.isEmpty, !OrbInboxModel.isSyntheticUserMessage(content) {
                lastUser = content
            }
            if role == "assistant", !content.isEmpty {
                let clean = OrbInboxModel.humanizeStatusText(content)
                if !clean.isEmpty && !assistantBlocks.contains(clean) {
                    assistantBlocks.append(clean)
                    break
                }
            }
        }

        if !lastUser.isEmpty { lines.append("Latest user request:\n\(String(lastUser.prefix(700)))") }
        if let receipt = OrbInboxModel.extractWorkReceipt(events: events) {
            lines.append("Tools executed: \(receipt)")
        }
        if !lastError.isEmpty { lines.append("Recorded error:\n\(String(lastError.prefix(500)))") }
        if !assistantBlocks.isEmpty {
            let joined = assistantBlocks.suffix(3).joined(separator: "\n\n")
            lines.append("Latest agent response:\n\(String(joined.suffix(2400)))")
        }
        return lines.joined(separator: "\n\n")
    }

    private static func fetchBtw(missionID: String, context: String, model: String) async throws -> String {
        let endpoint = OrbCore.shared.endpoint
        guard let url = URL(string: "\(endpoint)/api/control/missions/\(OrbCore.escape(missionID))/btw") else {
            throw URLError(.badURL)
        }
        var bodyObj: [String: OrbJSON] = [
            "question": .string(digestPrompt),
            "context": .string(context),
        ]
        if !model.isEmpty && model != OrbInboxSettings.defaultModel {
            bodyObj["model"] = .string(model)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("Bearer \(APIService.shared.authToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(OrbJSON.object(bodyObj))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 422 && bodyObj["model"] != nil {
            bodyObj.removeValue(forKey: "model")
            request.httpBody = try JSONEncoder().encode(OrbJSON.object(bodyObj))
            let (retryData, retryResp) = try await URLSession.shared.data(for: request)
            guard let retryHttp = retryResp as? HTTPURLResponse, (200..<300).contains(retryHttp.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return extractBtwAnswer(String(data: retryData, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OrbHTTPError(status: http.statusCode, detail: "BTW failed")
        }
        return extractBtwAnswer(String(data: data, encoding: .utf8) ?? "")
    }

    private static func extractBtwAnswer(_ raw: String) -> String {
        var deltaText = ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONDecoder().decode(OrbJSON.self, from: data) else { continue }
            let d = json["delta"].text
            let a = json["answer"].text
            if !d.isEmpty { deltaText += d }
            else if !a.isEmpty && deltaText.isEmpty { deltaText = a }
        }
        return deltaText.isEmpty ? raw : deltaText
    }

    private static func parseDigest(_ raw: String, updatedAt: String, model: String) -> OrbInboxDigest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let json = try? JSONDecoder().decode(OrbJSON.self, from: data) else { return nil }
        let task = json["task"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomeRaw = !json["outcome"].text.isEmpty ? json["outcome"].text : json["overview"].text
        let outcome = outcomeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty || !outcome.isEmpty else { return nil }
        let rawVerdict = json["verdict"].text.lowercased()
        let verdict = ["succeeded", "failed", "waiting", "needs_input"].contains(rawVerdict) ? rawVerdict : "succeeded"
        return OrbInboxDigest(task: task, outcome: outcome, verdict: verdict, model: model, updatedAt: updatedAt)
    }
}

struct OrbInboxSettingsView: View {
    @State private var settings = OrbInboxSettings.shared
    @State private var customModel: String = {
        let cur = OrbInboxSettings.shared.model
        let isPreset = OrbInboxSettings.modelPresets.contains(where: { $0.id == cur })
        return isPreset ? "" : cur
    }()

    var body: some View {
        List {
            Section {
                Toggle("AI Overview summaries", isOn: $settings.aiSummary)
                    .accessibilityIdentifier("settings.inbox.aiSummary")
            } footer: {
                Text("Summarizes your latest request and what the agent accomplished in 2–3 sentences using the configured router.")
            }

            if settings.aiSummary {
                Section("Overview Router Model") {
                    ForEach(OrbInboxSettings.modelPresets) { preset in
                        Button {
                            customModel = ""
                            settings.model = preset.id
                            OrbHaptics.selection()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.label)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(OrbStyle.textSecondary)
                                }
                                Spacer()
                                if settings.model == preset.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Custom Model Override") {
                    TextField("e.g. builtin/smart", text: $customModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customModel) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.model = trimmed.isEmpty ? OrbInboxSettings.defaultModel : trimmed
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbStyle.background)
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@Observable
final class OrbMissionUnreadStore: @unchecked Sendable {
    static let shared = OrbMissionUnreadStore()

    private let defaultsKey = "orb.missionSeenAt.v2"
    private(set) var version = 0
    private var seenByMissionID: [String: String] = [:]
    private var manuallyUnreadIDs: Set<String> = []

    static let unreadResponseStates: Set<String> = [
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

    func markRead(_ row: OrbRow, hasInteraction: Bool = false, syncBackend: Bool = true) {
        guard hasInteraction || Self.unreadResponseStates.contains(row.state) else { return }
        markRead(id: row.id, updatedAt: row.updatedAt, syncBackend: syncBackend)
    }

    func markRead(id: String, updatedAt: String? = nil, status: String? = nil, hasInteraction: Bool = false, syncBackend: Bool = true) {
        guard !id.isEmpty else { return }
        if let status, !status.isEmpty, !hasInteraction, !Self.unreadResponseStates.contains(status) {
            return
        }
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

struct OrbInboxPeekTurn: Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let text: String
    var workReceipt: String? = nil
}

struct OrbInboxChildFailure: Identifiable, Equatable {
    let id: String
    let title: String
    let row: OrbRow
}

struct OrbInboxChildSummary: Equatable {
    let total: Int
    let completed: Int
    let running: Int
    let failed: Int
    let failedChildren: [OrbInboxChildFailure]
    let hasUnreadFailure: Bool
}

struct OrbInboxItem: Identifiable, Equatable {
    let id: String
    let row: OrbRow
    let projectSlug: String
    let projectTitle: String
    let headline: String
    let summary: String
    let lastRequest: String?
    let workReceipt: String?
    let badge: String
    let tone: OrbInboxTone
    let category: OrbInboxCategory
    let machine: String
    let isGoal: Bool
    var unread: Bool
    var attention: Bool
    let canRetry: Bool
    let peekTurns: [OrbInboxPeekTurn]
    var childSummary: OrbInboxChildSummary?
    let updatedAt: String
    let interaction: OrbInboxInteraction?
}

enum OrbInboxModel {
    static let maxSummaryChars = 320

    private static let workingStatuses: Set<String> = [
        "active", "running", "starting", "pending", "queued", "resuming", "waiting_background",
    ]
    private static let hiddenStatuses: Set<String> = [
        "acknowledged", "archived", "deleted", "cancelled",
    ]
    private static let interactiveTools: Set<String> = [
        "ui_native_request", "AskUserQuestion", "question",
    ]

    static func isSyntheticUserMessage(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.range(of: #"^\[SYSTEM:\s*AUTOMATIC[\s_]+RESUME"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            trimmed.range(of: #"^\[SYSTEM:\s*BACKGROUND"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            trimmed.range(of: #"^Continue from where you left off\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            trimmed.range(of: #"^Continue and resolve the blocker/error\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func cleanChildTrackLabel(_ raw: String) -> String {
        let base = OrbStyle.displayTitle(raw).replacingOccurrences(
            of: #"\s*·\s*fork\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "Worker track" }
        if base.range(of: #"^(i['’]ll|i will|let me|now i['’]ll|first,? i['’]ll)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            base.count > 68 {
            let clipped = clipToSentence(base, maxChars: 48)
            return clipped.isEmpty ? "Worker track" : clipped
        }
        return base
    }

    static func stripMarkdownToProse(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+[^\n]*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}>\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.*?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*|_)(.*?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clipToSentence(_ raw: String, maxChars: Int = maxSummaryChars) -> String {
        let prose = stripMarkdownToProse(raw)
        guard !prose.isEmpty else { return "" }
        if prose.count <= maxChars { return prose }

        var cutIndex: String.Index?
        for idx in prose.indices {
            let distFromStart = prose.distance(from: prose.startIndex, to: idx)
            if distFromStart >= maxChars { break }
            let ch = prose[idx]
            if ch == "." || ch == "?" || ch == "!" {
                let nextIdx = prose.index(after: idx)
                let isEnd = nextIdx == prose.endIndex || prose[nextIdx].isWhitespace
                let dist = prose.distance(from: prose.startIndex, to: nextIdx)
                if isEnd && dist >= 24 {
                    cutIndex = nextIdx
                }
            }
        }
        if let cutIndex {
            return String(prose[..<cutIndex]).trimmingCharacters(in: .whitespaces)
        }
        let prefix = String(prose.prefix(max(1, maxChars - 1)))
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

    static func extractLastRequest(row: OrbRow, events: [StoredEvent], headline: String) -> String? {
        for event in events.reversed() where event.eventType == "user_message" {
            let text = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !isSyntheticUserMessage(text) {
                let clipped = clipToSentence(text, maxChars: 96)
                if clipped.caseInsensitiveCompare(headline) != .orderedSame {
                    return clipped
                }
                return nil
            }
        }
        let history = row.raw["history"].items
        if history.count > 1 {
            for entry in history.reversed() where entry["role"].text == "user" {
                let text = entry["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !isSyntheticUserMessage(text) {
                    let clipped = clipToSentence(text, maxChars: 96)
                    if clipped.caseInsensitiveCompare(headline) != .orderedSame {
                        return clipped
                    }
                    return nil
                }
            }
        }
        return nil
    }

    static func extractWorkReceipt(events: [StoredEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        var commands = 0
        var edits = 0
        var reads = 0
        for ev in events where ev.eventType == "tool_call" {
            let name = (ev.toolName ?? "").lowercased()
            if ["bash", "run_command", "shell", "terminal", "exec_command"].contains(name) {
                commands += 1
            } else if name.contains("edit") || name.contains("write") || name.contains("patch") || name.contains("replace") {
                edits += 1
            } else if name.contains("read") || name.contains("view") || name.contains("grep") || name.contains("glob") {
                reads += 1
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) \(commands == 1 ? "command" : "commands")") }
        if edits > 0 { parts.append("Edited \(edits) \(edits == 1 ? "file" : "files")") }
        if parts.isEmpty && reads > 0 { parts.append("Read \(reads) \(reads == 1 ? "file" : "files")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    static func extractPeekTurns(
        row: OrbRow,
        events: [StoredEvent],
        summaryFallback: String
    ) -> [OrbInboxPeekTurn] {
        var turns: [OrbInboxPeekTurn] = []
        var pendingTools: [StoredEvent] = []
        let clipTurn: (String) -> String = { raw in
            let prose = stripMarkdownToProse(raw)
            if prose.count <= 800 { return prose }
            return String(prose.prefix(799)).trimmingCharacters(in: .whitespaces) + "…"
        }

        if !events.isEmpty {
            for (idx, event) in events.enumerated() {
                if event.eventType == "tool_call" {
                    pendingTools.append(event)
                } else if event.eventType == "user_message" {
                    if !isSyntheticUserMessage(event.content) {
                        let text = clipTurn(event.content)
                        if !text.isEmpty {
                            turns.append(OrbInboxPeekTurn(id: "ev-\(idx)", role: "user", text: text))
                            pendingTools.removeAll()
                        }
                    }
                } else if event.eventType == "assistant_message" || event.eventType == "assistant_message_canonical" {
                    let text = clipTurn(humanizeStatusText(event.content))
                    if !text.isEmpty {
                        let receipt = extractWorkReceipt(events: pendingTools)
                        pendingTools.removeAll()
                        if let last = turns.last, last.role == "assistant" {
                            turns[turns.count - 1] = OrbInboxPeekTurn(
                                id: last.id,
                                role: "assistant",
                                text: text,
                                workReceipt: receipt ?? last.workReceipt
                            )
                        } else {
                            turns.append(OrbInboxPeekTurn(id: "ev-\(idx)", role: "assistant", text: text, workReceipt: receipt))
                        }
                    }
                } else if event.eventType == "error" {
                    let text = clipTurn(humanizeStatusText(event.content))
                    if !text.isEmpty {
                        let isProse = text.count >= 220 && text.range(of: #"^(error|failed|exception|panic):"#, options: [.regularExpression, .caseInsensitive]) == nil
                        let role = isProse ? "assistant" : "error"
                        if role == "assistant", let last = turns.last, last.role == "assistant" {
                            turns[turns.count - 1] = OrbInboxPeekTurn(id: last.id, role: "assistant", text: text, workReceipt: last.workReceipt)
                        } else {
                            turns.append(OrbInboxPeekTurn(id: "ev-\(idx)", role: role, text: text))
                        }
                    }
                }
            }
        }

        if !turns.isEmpty && !turns.contains(where: { $0.role == "user" }) {
            let promptFallback = OrbStyle.displayTitle(row.raw["title"].text)
            if !promptFallback.isEmpty {
                turns.insert(OrbInboxPeekTurn(id: "init-user", role: "user", text: promptFallback), at: 0)
            }
        }

        if turns.isEmpty {
            for (idx, entry) in row.raw["history"].items.enumerated() {
                let role = entry["role"].text == "user" ? "user" : "assistant"
                let rawContent = entry["content"].text
                if role == "user" && isSyntheticUserMessage(rawContent) { continue }
                let text = clipTurn(humanizeStatusText(rawContent))
                if !text.isEmpty {
                    turns.append(OrbInboxPeekTurn(id: "hist-\(idx)", role: role, text: text))
                }
            }
        }

        if turns.isEmpty {
            let role = ["failed", "not_feasible"].contains(row.state) ? "error" : "assistant"
            turns.append(
                OrbInboxPeekTurn(
                    id: "fallback",
                    role: role,
                    text: summaryFallback,
                    workReceipt: extractWorkReceipt(events: events)
                )
            )
        }

        return Array(turns.suffix(6))
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
        if row.raw["tags"].items.contains(where: { $0.text == "placement:client" }) {
            return "This computer"
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

    @MainActor
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

        let rawSummary = extractSummary(row: row, events: events, interaction: interaction)
        let digest = OrbInboxDigestStore.shared.get(row: row)
        let summary = (interaction == nil && !(digest?.outcome.isEmpty ?? true)) ? (digest?.outcome ?? rawSummary) : rawSummary
        let lastRequest: String? = {
            if let dt = digest?.task, !dt.isEmpty {
                return dt.caseInsensitiveCompare(headline) == .orderedSame ? nil : dt
            }
            return extractLastRequest(row: row, events: events, headline: headline)
        }()
        let workReceipt = extractWorkReceipt(events: events)

        let (badge, tone) = resolveBadgeAndTone(row: row, summary: summary, interaction: interaction)
        let isGoal = row.raw["goal_mode"].flag || OrbStyle.goalObjective(row.raw["title"].text) != nil
        let unread = OrbMissionUnreadStore.shared.isUnread(row: row, hasInteraction: interaction != nil)
        let attention = interaction != nil || ["blocked", "failed", "not_feasible"].contains(row.state)
        let canRetry = ["failed", "not_feasible", "interrupted", "blocked"].contains(row.state)
        let peekTurns = extractPeekTurns(row: row, events: events, summaryFallback: summary)

        return OrbInboxItem(
            id: row.id,
            row: row,
            projectSlug: slug,
            projectTitle: projectTitle,
            headline: headline,
            summary: summary,
            lastRequest: lastRequest,
            workReceipt: workReceipt,
            badge: badge,
            tone: tone,
            category: category,
            machine: resolveMachine(row: row),
            isGoal: isGoal,
            unread: unread,
            attention: attention,
            canRetry: canRetry,
            peekTurns: peekTurns,
            childSummary: nil,
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

    @MainActor
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

        var childrenByParent: [String: [OrbRow]] = [:]
        var seenChildren: Set<String> = []
        for child in missions where !seenChildren.contains(child.id) {
            seenChildren.insert(child.id)
            let parentID = !child.raw["parent_mission_id"].text.isEmpty
                ? child.raw["parent_mission_id"].text
                : child.raw["callback_parent_mission_id"].text
            guard !parentID.isEmpty, !hiddenStatuses.contains(child.state) else { continue }
            childrenByParent[parentID, default: []].append(child)
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
            guard var item = buildItem(
                row: row,
                projectsBySlug: projectsBySlug,
                events: events,
                answered: answeredCallIDs
            ) else { continue }

            if let children = childrenByParent[row.id], !children.isEmpty {
                var completed = 0
                var running = 0
                var failed = 0
                var failedChildren: [OrbInboxChildFailure] = []
                var hasUnreadFailure = false

                for child in children {
                    let st = child.state
                    if ["completed", "succeeded"].contains(st) {
                        completed += 1
                    } else if workingStatuses.contains(st) {
                        running += 1
                    } else if ["failed", "not_feasible", "blocked"].contains(st) {
                        failed += 1
                        let childTitle = cleanChildTrackLabel(child.raw["title"].text)
                        failedChildren.append(
                            OrbInboxChildFailure(
                                id: child.id,
                                title: childTitle,
                                row: child
                            )
                        )
                        if OrbMissionUnreadStore.shared.isUnread(row: child) {
                            hasUnreadFailure = true
                        }
                    }
                }

                item.childSummary = OrbInboxChildSummary(
                    total: children.count,
                    completed: completed,
                    running: running,
                    failed: failed,
                    failedChildren: failedChildren,
                    hasUnreadFailure: hasUnreadFailure
                )
                if hasUnreadFailure {
                    item.unread = true
                    item.attention = true
                }
            }

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
    @State private var peekedIDs: Set<String> = []
    @FocusState private var replyFocused: Bool
    @State private var undoItem: (id: String, title: String)?

    private let api = OrbCore.shared
    private let appearance = OrbProjectAppearance.shared
    private let unreadStore = OrbMissionUnreadStore.shared
    private let digestStore = OrbInboxDigestStore.shared
    private let inboxSettings = OrbInboxSettings.shared

    private func markItemAndChildrenRead(_ item: OrbInboxItem) {
        unreadStore.markRead(item.row)
        if let cs = item.childSummary {
            for child in cs.failedChildren {
                unreadStore.markRead(child.row)
            }
        }
    }

    private func togglePeek(_ item: OrbInboxItem) {
        withAnimation(.snappy(duration: 0.2)) {
            if peekedIDs.contains(item.id) {
                peekedIDs.remove(item.id)
            } else {
                peekedIDs.insert(item.id)
                if eventsByMission[item.id] == nil {
                    Task {
                        if let batch = try? await APIService.shared.getMissionEventsWithMeta(id: item.id, limit: 120, sinceSeq: nil) {
                            OrbReadCache.saveEvents(item.id, events: batch.events)
                            eventsByMission[item.id] = batch.events
                        }
                    }
                }
            }
        }
    }

    private var computed: (needsYou: [OrbInboxItem], ready: [OrbInboxItem], working: [OrbInboxItem]) {
        _ = unreadStore.version
        _ = digestStore.version
        _ = inboxSettings.version
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
                LazyVStack(alignment: .leading, spacing: 12) {
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(OrbInboxFilterMode.allCases, id: \.rawValue) { mode in
                        let active = filterMode == mode
                        let count = mode == .unread ? unreadCount : (mode == .attention ? attentionCount : totalActionableCount)
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                filterMode = mode
                            }
                            OrbHaptics.selection()
                        } label: {
                            HStack(spacing: 4) {
                                if mode == .unread {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 6, height: 6)
                                }
                                Text(mode.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(active ? .primary : OrbStyle.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text("\(count)")
                                    .font(.caption2)
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 8)
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

                if !computed.working.isEmpty {
                    let compactWorking = unreadCount > 0
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            showWorking.toggle()
                        }
                        OrbHaptics.selection()
                    } label: {
                        HStack(spacing: 5) {
                            OrbRunningDots(size: 11)
                            Text(compactWorking ? "\(computed.working.count)" : "\(computed.working.count) working")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
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

                if unreadCount > 0 {
                    Button {
                        OrbHaptics.selection()
                        withAnimation(.snappy(duration: 0.2)) {
                            for item in (computed.needsYou + computed.ready).filter(\.unread) {
                                markItemAndChildrenRead(item)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Read all")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(OrbStyle.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(OrbStyle.surface, in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox.markAllRead")
                }
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
        let isPeeked = peekedIDs.contains(item.id)
        let isBusy = busyIDs.contains(item.id)
        let showBadge = !(item.category == .ready && item.badge == "Completed")

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                OrbHaptics.selection()
                markItemAndChildrenRead(item)
                onOpenMission(item.row)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    // Line 1: Unread dot + Project dot + Project name + Goal tag + Headline + Badge + Time
                    HStack(alignment: .center, spacing: 6) {
                        if item.unread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
                                .onTapGesture {
                                    OrbHaptics.selection()
                                    withAnimation(.snappy(duration: 0.2)) {
                                        markItemAndChildrenRead(item)
                                    }
                                }
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

                        if showBadge {
                            Text(item.badge)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(item.tone.foreground)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(item.tone.background, in: Capsule())
                        }

                        if !item.updatedAt.isEmpty {
                            Text(OrbStyle.relativeTime(item.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(OrbStyle.textMuted)
                                .monospacedDigit()
                        }
                    }

                    // Follow-up request line ("Asked: ...") when distinct from mission headline
                    if let lastReq = item.lastRequest, !lastReq.isEmpty {
                        HStack(spacing: 5) {
                            Text("Asked:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(OrbStyle.textMuted)
                            Text(lastReq)
                                .font(.caption)
                                .foregroundStyle(OrbStyle.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    // AI Overview / 4-line summary
                    Text(item.summary)
                        .font(.footnote)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let receipt = item.workReceipt, !receipt.isEmpty {
                        Text(receipt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textMuted)
                            .lineLimit(1)
                    }

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

            // Actionable child tracks only (failed or running)
            if let cs = item.childSummary, (!cs.failedChildren.isEmpty || cs.running > 0) {
                HStack(spacing: 6) {
                    if let firstFailed = cs.failedChildren.first {
                        Button {
                            OrbHaptics.selection()
                            markItemAndChildrenRead(item)
                            onOpenMission(firstFailed.row)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(OrbStyle.error)
                                    .frame(width: 6, height: 6)
                                Text("\(cs.failed) \(cs.failed == 1 ? "track" : "tracks") failed: \(firstFailed.title)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(OrbStyle.error)
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(OrbStyle.error)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(OrbStyle.error.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(OrbStyle.error.opacity(0.28), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if cs.running > 0 {
                        Text("\(cs.running) \(cs.running == 1 ? "track" : "tracks") running")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }

            // Minimalist quick actions row (Options / Retry / Peek / Reply / Done)
            HStack(spacing: 6) {
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

                if item.canRetry {
                    Button {
                        OrbHaptics.light()
                        Task { await retryMission(item) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Retry")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(OrbStyle.warning)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(OrbStyle.warning.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.warning.opacity(0.32), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityIdentifier("inbox.retry.\(item.id)")
                }

                Button {
                    OrbHaptics.selection()
                    togglePeek(item)
                } label: {
                    Text("Peek")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isPeeked ? .primary : OrbStyle.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(isPeeked ? OrbStyle.elevated : Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(OrbStyle.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("inbox.peek.\(item.id)")

                Spacer()

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

            if isPeeked {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.peekTurns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(turn.role == "user" ? "YOU" : (turn.role == "error" ? "ERROR" : "AGENT"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(
                                        turn.role == "error"
                                            ? OrbStyle.error
                                            : (turn.role == "assistant"
                                                ? Color(red: 112 / 255, green: 175 / 255, blue: 245 / 255)
                                                : OrbStyle.textSecondary)
                                    )
                                    .frame(width: 42, alignment: .leading)
                                Text(turn.text)
                                    .font(.caption)
                                    .foregroundStyle(OrbStyle.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let receipt = turn.workReceipt, !receipt.isEmpty {
                                Text(receipt)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .padding(.leading, 50)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            turn.role == "error" ? OrbStyle.error.opacity(0.08) : Color.black.opacity(0.24),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    HStack {
                        Spacer()
                        Button {
                            OrbHaptics.selection()
                            markItemAndChildrenRead(item)
                            onOpenMission(item.row)
                        } label: {
                            Text("Open full conversation →")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(OrbStyle.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                markItemAndChildrenRead(item)
                onOpenMission(item.row)
            } label: {
                Label("Open conversation", systemImage: "bubble.left.and.bubble.right")
            }
            if item.canRetry {
                Button {
                    Task { await retryMission(item) }
                } label: {
                    Label("Retry / resume", systemImage: "arrow.clockwise")
                }
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

    private var emptyInboxSubtitle: String {
        if filterMode == .unread && totalActionableCount > 0 {
            let noun = totalActionableCount == 1 ? "conversation is" : "conversations are"
            return "You’ve opened every recent agent response. \(totalActionableCount) earlier \(noun) in All."
        }
        if !computed.working.isEmpty {
            let noun = computed.working.count == 1 ? "agent is" : "agents are"
            return "\(computed.working.count) \(noun) working quietly in the background."
        }
        return "When an agent needs a decision or finishes a run, it will surface here."
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
            Text(emptyInboxSubtitle)
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
            OrbReadCache.seedFromGlobalMissions(cached.items)
            missions = cached.items.map { OrbRow($0) }.filter(\.mobile)
            seedCachedEvents(for: missions)
            actionableCount = unreadCount
        }
        do {
            let raw = try await api.call("/api/control/missions?limit=100&all=true")
            OrbReadCache.seedFromGlobalMissions(raw.items)
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
            [
                "awaiting_user", "waiting_user", "blocked", "failed", "not_feasible",
                "completed", "succeeded", "paused", "interrupted",
            ].contains($0.state)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(16)

        for (idx, row) in candidates.enumerated() {
            guard !Task.isCancelled else { return }
            var events = eventsByMission[row.id] ?? []
            if events.isEmpty && idx < 12 {
                if let batch = try? await APIService.shared.getMissionEventsWithMeta(id: row.id, limit: 120, sinceSeq: nil) {
                    OrbReadCache.saveEvents(row.id, events: batch.events)
                    eventsByMission[row.id] = batch.events
                    events = batch.events
                }
            }
            let priority = unreadStore.isUnread(row: row) ? idx : idx + 20
            digestStore.request(row: row, events: events, priority: priority)
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
        markItemAndChildrenRead(item)
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
            for item in items { markItemAndChildrenRead(item) }
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
                markItemAndChildrenRead(item)
            }
            await load(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retryMission(_ item: OrbInboxItem) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            var body: [String: OrbJSON] = [
                "mission_id": .string(item.id),
                "content": .string("Continue from where you left off."),
                "queue_followup": .bool(true),
                "client_message_id": .string(UUID().uuidString.lowercased()),
            ]
            if let identity = OrbContinuation.identity(for: item.row.raw) {
                body["continue_identity"] = identity
            }
            _ = try await api.call("/api/control/message", method: "POST", body: .object(body))
            OrbHaptics.success()
            withAnimation(.snappy(duration: 0.22)) {
                _ = dismissedIDs.insert(item.id)
                markItemAndChildrenRead(item)
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
                markItemAndChildrenRead(item)
            }
            await load(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
