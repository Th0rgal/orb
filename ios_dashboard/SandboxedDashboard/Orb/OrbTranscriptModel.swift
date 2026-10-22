import SwiftUI

/// The conversation's transcript data: Core events and everything derived from them.
/// Derivations run when their inputs change, never from a view body, so the 1 s
/// Working clock and streaming re-renders stay cheap on long transcripts.
@MainActor @Observable
final class OrbTranscriptModel {
    var events: [StoredEvent] = []
    private(set) var workModel = OrbWorkModel()
    private(set) var changedFiles: [OrbTurnSummary.FileChange] = []
    /// Subagents and machines this mission started, lifted out of the work fold.
    private(set) var orchestration: [OrbOrchestration.Ref] = []
    private(set) var openQuestions: [OrbPendingQuestion] = []
    private(set) var history: [(String, String, String)] = []
    /// Completion time of each stored assistant row, by row id.
    private(set) var turnTimings: [String: OrbTurnTiming] = [:]
    /// `metadata.shared_files` of assistant messages, for file chips (size, download url).
    private(set) var sharedFiles: [OrbSharedFile] = []

    /// Work fold, changed files and open questions from `events`.
    func rebuildDerived(working: Bool) {
        let next = OrbWorkModel.build(from: events, working: working)
        if workModel != next { workModel = next }
        let refs = OrbOrchestration.build(from: events)
        if orchestration != refs { orchestration = refs }
        let files = OrbTurnSummary.changedFiles(events)
        if changedFiles != files { changedFiles = files }
        let questions = OrbPendingQuestion.extract(events)
        if questions.map(\.id) != openQuestions.map(\.id) { openQuestions = questions }
        let shared = events.lazy.filter { $0.eventType == "assistant_message" && $0.metadata["shared_files"] != nil }
            .flatMap { OrbFileRefs.sharedFiles($0.metadata.mapValues(\.value)) }
        if sharedFiles != Array(shared) { sharedFiles = Array(shared) }
    }

    /// Rebuilds the message list; returns how many rows were added (0 when unchanged or shrunk).
    @discardableResult
    func rebuildHistory(isCloud: Bool, turns: [OrbJSON], mission: OrbJSON, optimisticPrompt: String?) -> Int {
        let next = Self.computeHistory(isCloud: isCloud, turns: turns, mission: mission, events: events, optimisticPrompt: optimisticPrompt)
        let grew = max(0, next.count - history.count)
        if history.count != next.count || zip(history, next).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 || $0.2 != $1.2 }) {
            history = next
        }
        let byAnswer = OrbTurnTiming.byAnswer(events)
        var timings: [String: OrbTurnTiming] = [:]
        for row in history where row.1 == "assistant" {
            if let timing = byAnswer[row.2.trimmingCharacters(in: .whitespacesAndNewlines)] { timings[row.0] = timing }
        }
        if timings != turnTimings { turnTimings = timings }
        return grew
    }

    nonisolated static func computeHistory(
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
            // Linear: one set of trimmed user texts instead of re-scanning every row per event.
            var userTexts = Set(rows.lazy.filter { $0.1 == "user" }.map { $0.2.trimmingCharacters(in: .whitespacesAndNewlines) })
            for event in events where event.eventType == "user_message" {
                let text = event.content
                guard !text.isEmpty else { continue }
                if OrbRemoteContinuation.unpack(text) != nil { continue }
                if userTexts.insert(text.trimmingCharacters(in: .whitespacesAndNewlines)).inserted {
                    rows.append(("event-user-\(event.sequence)", "user", text))
                }
            }
        }
        if let opt = optimisticPrompt, !rows.contains(where: { $0.1 == "user" && OrbConversation.sameMessage($0.2, opt) }) {
            rows.append(("optimistic-user", "user", opt))
        }
        if !isCloud {
            rows = rows.enumerated().map { index, row in
                ("turn-\(index)-\(row.1)", row.1, row.2)
            }
        }
        return rows
    }
}
