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
    /// When Core accepted this optimistic row into its queue (`queued: true`).
    var postedAt: Date? = nil
}

/// A `user_message` Core delivered into the transcript.
struct OrbDeliveredMessage: Equatable {
    var id: String?
    var content: String
    var sequence: Int64
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
    /// Last event sequence known when a row first appeared locally; a content-only
    /// match must come from a later `user_message` (an older identical message does not count).
    var seenAfter: [String: Int64] = [:]

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

    /// Core's queue as read by a request started at `fetchedAt`. An accepted
    /// optimistic row Core no longer lists after it was posted was delivered (or
    /// removed) and leaves the drawer; a row still being posted stays.
    func withServer(_ rows: [OrbQueuedRow], fetchedAt: Date = .distantPast, lastSequence: Int64? = nil) -> OrbFollowUpQueue {
        var next = self
        let listed = Set(rows.map(\.id))
        next.server = rows.map { var r = $0; r.sending = false; return r }
        next.pending = pending.filter { row in
            if listed.contains(row.id) { return false }
            if let posted = row.postedAt, !row.sending, posted < fetchedAt { return false }
            return true
        }
        next.hidden = hidden.filter { listed.contains($0) }
        for row in rows where next.seenAfter[row.id] == nil { next.seenAfter[row.id] = lastSequence ?? 0 }
        let live = Set(next.server.map(\.id) + next.pending.map(\.id))
        next.seenAfter = next.seenAfter.filter { live.contains($0.key) }
        return next
    }

    /// A queued row becomes the transcript bubble once Core delivers it: matched by
    /// client_message_id (the event id), else by content in a later user_message.
    func reconciled(with messages: [OrbDeliveredMessage]) -> OrbFollowUpQueue {
        guard !messages.isEmpty else { return self }
        var next = self
        let ids = Set(messages.compactMap(\.id))
        var used = Set<Int64>()
        for row in rows {
            if ids.contains(row.id) {
                next.delivered.insert(row.id)
                if let m = messages.first(where: { $0.id == row.id }) { used.insert(m.sequence) }
            }
        }
        let known = Set(server.map(\.id) + pending.map(\.id))
        let content = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        for row in rows where !next.delivered.contains(row.id) {
            let after = seenAfter[row.id] ?? Int64.max
            if let m = messages.first(where: { m in
                !used.contains(m.sequence) && m.sequence > after && !(m.id.map(known.contains) ?? false) && content(m.content) == content(row.content)
            }) {
                used.insert(m.sequence)
                next.delivered.insert(row.id)
            }
        }
        return next
    }

    func enqueue(_ id: String, _ content: String, lastSequence: Int64? = nil) -> OrbFollowUpQueue {
        var next = self
        next.pending = pending.filter { $0.id != id } + [OrbQueuedRow(id: id, content: content, sending: true)]
        next.seenAfter[id] = lastSequence ?? 0
        return next
    }

    func posted(_ id: String, queued: Bool, at date: Date = Date()) -> OrbFollowUpQueue {
        var next = self
        if queued { next.pending = pending.map { var r = $0; if r.id == id { r.sending = false; r.postedAt = date }; return r } }
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

enum OrbTapAction: Equatable { case send, deferToQueue, ignore }

enum OrbSendFlow {
    /// A tap on send never does nothing: while a send is in flight a follow-up is
    /// accepted at once as an optimistic queued row and posted once that send settles.
    static func tapAction(busy: Bool, content: String, canQueue: Bool) -> OrbTapAction {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ignore }
        if !busy { return .send }
        return canQueue ? .deferToQueue : .ignore
    }

    /// Deferred follow-ups go out once the in-flight POST returned, whatever happens after.
    static func canDrain(awaitingAck: Bool, draining: Bool, pending: Int) -> Bool {
        pending > 0 && !awaitingAck && !draining
    }

    /// Start of the running turn: Core's latest user_message, unless this device just
    /// started a newer turn Core has not reported yet (then the local send time).
    /// A few seconds of clock skew still count as the same turn.
    static func turnStart(server: Date?, localSend: Date?, skew: TimeInterval = 10) -> Date? {
        guard let localSend else { return server }
        guard let server else { return localSend }
        return server < localSend.addingTimeInterval(-skew) ? localSend : server
    }
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
