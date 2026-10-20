import Foundation

/// Smooth sending on mobile, mirroring the desktop work in PR #1174
/// (orb/src/RemoteQueue.tsx, orb/src/mission/handoff.ts, orb/src/missionStatus.ts)
/// and Android OrbSendFlow.kt. Pure state, unit tested in OrbSendFlowTests.

struct OrbQueuedRow: Equatable, Identifiable {
    var id: String
    var content: String
    /// Optimistic: posted, Core has not listed it yet. Not actionable.
    var sending = false
    var queueError: String? = nil
}

/// Core's durable follow-up inbox merged with optimistic sends, in-place edits and removals.
struct OrbFollowUpQueue: Equatable {
    var server: [OrbQueuedRow] = []
    var pending: [OrbQueuedRow] = []
    var edits: [String: String] = [:]
    /// Removed or sent now locally; hidden even if a stale poll still lists them.
    var hidden: Set<String> = []
    /// Ids already shown as delivered in the transcript.
    var delivered: Set<String> = []

    var rows: [OrbQueuedRow] {
        var seen = Set<String>()
        var out: [OrbQueuedRow] = []
        for row in server + pending where !hidden.contains(row.id) && !delivered.contains(row.id) && seen.insert(row.id).inserted {
            var r = row
            if let edit = edits[row.id] { r.content = edit }
            out.append(r)
        }
        return out
    }

    var count: Int { rows.count }

    func row(_ id: String) -> OrbQueuedRow? { rows.first { $0.id == id } }

    func withServer(_ rows: [OrbQueuedRow]) -> OrbFollowUpQueue {
        var next = self
        let listed = Set(rows.map(\.id))
        next.server = rows.map { var r = $0; r.sending = false; return r }
        next.pending = pending.filter { !listed.contains($0.id) }
        next.hidden = hidden.filter { listed.contains($0) }
        return next
    }

    func enqueue(_ id: String, _ content: String) -> OrbFollowUpQueue {
        var next = self
        next.pending = pending.filter { $0.id != id } + [OrbQueuedRow(id: id, content: content, sending: true)]
        return next
    }

    func posted(_ id: String, queued: Bool) -> OrbFollowUpQueue {
        var next = self
        if queued { next.pending = pending.map { var r = $0; if r.id == id { r.sending = false }; return r } }
        else { next.pending = pending.filter { $0.id != id } }
        return next
    }

    func postFailed(_ id: String) -> OrbFollowUpQueue {
        var next = self; next.pending = pending.filter { $0.id != id }; return next
    }

    func edit(_ id: String, _ content: String) -> OrbFollowUpQueue {
        var next = self; next.edits[id] = content; return next
    }

    func editConfirmed(_ id: String, _ content: String) -> OrbFollowUpQueue {
        var next = self
        next.server = server.map { var r = $0; if r.id == id { r.content = content }; return r }
        next.pending = pending.map { var r = $0; if r.id == id { r.content = content }; return r }
        next.edits[id] = nil
        return next
    }

    func editReverted(_ id: String) -> OrbFollowUpQueue { var next = self; next.edits[id] = nil; return next }
    func hide(_ id: String) -> OrbFollowUpQueue { var next = self; next.hidden.insert(id); return next }
    func unhide(_ id: String) -> OrbFollowUpQueue { var next = self; next.hidden.remove(id); return next }

    /// Rows of `GET /api/control/queue` for `missionID` that belong in the follow-up queue.
    static func parse(_ items: [OrbJSON], missionID: String) -> [OrbQueuedRow] {
        items.compactMap { item in
            let id = item["id"].text
            guard !id.isEmpty, item["mission_id"].text == missionID, item["inflight"] != .bool(true) else { return nil }
            let source = item["source"].text
            guard source.isEmpty || source == "remote-queue" || source.hasPrefix("host-queue:api:") else { return nil }
            let error = item["queue_error"].text
            return OrbQueuedRow(id: id, content: item["content"].text, queueError: error.isEmpty ? nil : error)
        }
    }
}

enum OrbEditOutcome: Equatable { case edited, unsupported, alreadySent, failed }
enum OrbSendNowOutcome: Equatable { case live, promoted, fallback }

enum OrbSendFlow {
    /// How long a sent row takes to collapse out of the queue (desktop LEAVE_MS).
    static let leaveSeconds = 0.16

    static func editOutcome(status: Int?) -> OrbEditOutcome {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .edited
        case 404, 405: return .unsupported
        case 409: return .alreadySent
        default: return .failed
        }
    }

    static func sendNowOutcome(_ response: OrbJSON) -> OrbSendNowOutcome {
        if response["delivered"] == .bool(true) { return .live }
        if response["promoted"] == .bool(true) { return .promoted }
        return .fallback
    }

    /// Live streamed text that stored history already holds is dropped, so a
    /// reload never shows the assistant's words twice; when stored text is a
    /// prefix of the live text, only the unseen tail stays live.
    static func dedupeLiveText(_ live: String, stored: [String]) -> String {
        let l = live.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return "" }
        for s in stored.reversed().prefix(3) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t == l || t.contains(l) { return "" }
            if l.hasPrefix(t) { return String(l.dropFirst(t.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return live
    }
}

/// Send now = stop the turn, then a new turn with the promoted message. While a
/// handoff is pending the screen keeps one Sending… → Working… state, keeps
/// Stop, and shows no "interrupted" error.
struct OrbHandoff: Equatable {
    var id: String
    var at: Date
    static let timeout: TimeInterval = 30
    private static let statuses: Set<String> = ["interrupted", "cancelled", "paused", "awaiting_user", "waiting_user", "waiting_for_user", "completed", "idle", ""]

    static func pending(status: String?, handoff: OrbHandoff?, now: Date = Date()) -> Bool {
        guard let handoff else { return false }
        let age = now.timeIntervalSince(handoff.at)
        guard age < timeout, age > -1 else { return false }
        let s = (status ?? "").lowercased()
        return statuses.contains(s) || (MissionState(rawValue: s)?.isActive ?? false)
    }
}

/// handoff.ts: feed mission snapshots; `observe` returns true when the handoff is over.
struct OrbHandoffTracker {
    private var current: String?
    private var stopSeen = false
    private var oldJob: String?

    mutating func reset() { current = nil; stopSeen = false; oldJob = nil }

    mutating func observe(_ handoff: OrbHandoff, status: String?, jobID: String?, jobEnded: Bool) -> Bool {
        if current != handoff.id {
            current = handoff.id
            stopSeen = false
            oldJob = (jobID != nil && !jobEnded) ? jobID : nil
        }
        let s = (status ?? "").lowercased()
        if ["failed", "error", "errored", "not_feasible", "timed_out"].contains(s) { return true }
        let running = (MissionState(rawValue: s)?.isActive ?? false) && !jobEnded
        if !running { stopSeen = true; return false }
        let newJob = jobID != nil && oldJob != nil && jobID != oldJob
        return stopSeen || newJob
    }
}
