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
    var revision: UInt32? = nil
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
    var consumedSequences: Set<Int64> = []
    var serverRev: UInt32 = 1
    var hasServerRevision = false
    var lastFetchedAt: Date = .distantPast

    func isStaleFetch(_ fetchedAt: Date, incomingServerRev: UInt32? = nil) -> Bool {
        if let rev = incomingServerRev, rev > 0 {
            return hasServerRevision && rev < serverRev
        }
        return fetchedAt != .distantPast && lastFetchedAt != .distantPast && fetchedAt < lastFetchedAt
    }

    static func hashMessageId(_ id: String?) -> UInt64 {
        guard let id, !id.isEmpty else { return 0 }
        var hash: UInt64 = 14695981039346656037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }

    private static func seqWord(_ value: Int64?) -> UInt64 {
        guard let value, value >= 0 else { return 0 }
        return UInt64(value)
    }

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

    func expectedRevision(for id: String) -> UInt32? {
        if hasServerRevision { return serverRev }
        if let rev = server.first(where: { $0.id == id })?.revision, rev > 0 { return rev }
        return nil
    }

    /// Core's queue as read by a request started at `fetchedAt`. An accepted
    /// optimistic row Core no longer lists after it was posted was delivered (or
    /// removed) and leaves the drawer; a row still being posted stays.
    func withServer(
        _ rows: [OrbQueuedRow],
        fetchedAt: Date = .distantPast,
        lastSequence: Int64? = nil,
        incomingServerRev: UInt32? = nil,
        turnSeq: Int64? = nil
    ) -> OrbFollowUpQueue {
        let normalizedIncoming = incomingServerRev.flatMap { $0 > 0 ? $0 : nil }
        if isStaleFetch(fetchedAt, incomingServerRev: normalizedIncoming) { return self }
        let effectiveRev = normalizedIncoming ?? serverRev
        let gate = OrbKernel.followupQueueStep(
            op: 0,
            serverRev: serverRev,
            incomingServerRev: effectiveRev,
            expectedServerRev: 0,
            clientMsgId: 0,
            trackedMsgId: 0,
            deliveredMsgId: 0,
            postedAfterSeq: 0,
            turnSeq: 0,
            optimisticSending: false,
            serverListed: false,
            contentMatched: false,
            alreadyDelivered: false
        )
        guard gate.admitted else { return self }

        var next = self
        next.serverRev = gate.nextServerRev
        if normalizedIncoming != nil { next.hasServerRevision = true }
        if fetchedAt != .distantPast && fetchedAt > next.lastFetchedAt {
            next.lastFetchedAt = fetchedAt
        }
        let listed = Set(rows.map(\.id))
        next.server = rows.map { var r = $0; r.sending = false; return r }
        next.pending = pending.filter { row in
            let rowHash = Self.hashMessageId(row.id)
            let isDelivered = next.delivered.contains(row.id)
            let isListed = listed.contains(row.id)
            let postedBeforeFetch = (row.postedAt.map { $0 < fetchedAt } ?? false) && !row.sending
            let afterSeq = next.seenAfter[row.id]
            let pollTurnSeq: UInt64 = {
                if let turnSeq, turnSeq >= 0 { return UInt64(turnSeq) }
                if postedBeforeFetch {
                    let base = Self.seqWord(afterSeq)
                    return base < UInt64.max ? base + 1 : base
                }
                return 0
            }()
            let postedWord: UInt64 = {
                if turnSeq != nil, afterSeq == nil { return UInt64.max }
                return Self.seqWord(afterSeq)
            }()
            let verdict = OrbKernel.followupQueueStep(
                op: 0,
                serverRev: serverRev,
                incomingServerRev: effectiveRev,
                expectedServerRev: 0,
                clientMsgId: rowHash,
                trackedMsgId: rowHash,
                deliveredMsgId: 0,
                postedAfterSeq: postedWord,
                turnSeq: pollTurnSeq,
                optimisticSending: row.sending,
                serverListed: isListed,
                contentMatched: false,
                alreadyDelivered: isDelivered
            )
            if verdict.retiredNow && turnSeq != nil {
                next.delivered.insert(row.id)
            }
            if isListed || postedBeforeFetch {
                return false
            }
            return verdict.optimisticLiveNext
        }
        next.hidden = hidden.filter { listed.contains($0) }
        if let lastSequence {
            for row in rows where next.seenAfter[row.id] == nil { next.seenAfter[row.id] = lastSequence }
        }
        let live = Set(next.server.map(\.id) + next.pending.map(\.id))
        next.seenAfter = next.seenAfter.filter { live.contains($0.key) }
        return next
    }

    func reconciled(with messages: [OrbDeliveredMessage]) -> OrbFollowUpQueue {
        guard !messages.isEmpty else { return self }
        var next = self
        var used = consumedSequences
        let known = Set(server.map(\.id) + pending.map(\.id)).union(delivered)
        let currentRows = rows
        for row in currentRows {
            let rowHash = Self.hashMessageId(row.id)
            for message in messages where message.id == row.id {
                let verdict = OrbKernel.followupQueueStep(
                    op: 3,
                    serverRev: next.serverRev,
                    incomingServerRev: 0,
                    expectedServerRev: 0,
                    clientMsgId: rowHash,
                    trackedMsgId: rowHash,
                    deliveredMsgId: rowHash,
                    postedAfterSeq: Self.seqWord(seenAfter[row.id]),
                    turnSeq: Self.seqWord(message.sequence),
                    optimisticSending: row.sending,
                    serverListed: server.contains { $0.id == row.id },
                    contentMatched: false,
                    alreadyDelivered: next.delivered.contains(row.id)
                )
                if verdict.retiredNow {
                    next.delivered.insert(row.id)
                }
            }
        }
        for message in messages {
            if let id = message.id, next.delivered.contains(id) {
                used.insert(message.sequence)
            }
        }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        for row in currentRows where !next.delivered.contains(row.id) {
            guard let after = seenAfter[row.id] else { continue }
            let rowHash = Self.hashMessageId(row.id)
            let rowTrimmed = trim(row.content)
            for m in messages where !used.contains(m.sequence) && m.sequence >= 0 && after >= 0 {
                let delivHash: UInt64 = {
                    guard let mid = m.id, known.contains(mid) else { return 0 }
                    return Self.hashMessageId(mid)
                }()
                let matched = trim(m.content) == rowTrimmed
                let verdict = OrbKernel.followupQueueStep(
                    op: 3,
                    serverRev: next.serverRev,
                    incomingServerRev: 0,
                    expectedServerRev: 0,
                    clientMsgId: rowHash,
                    trackedMsgId: rowHash,
                    deliveredMsgId: delivHash,
                    postedAfterSeq: UInt64(after),
                    turnSeq: UInt64(m.sequence),
                    optimisticSending: row.sending,
                    serverListed: server.contains { $0.id == row.id },
                    contentMatched: matched,
                    alreadyDelivered: next.delivered.contains(row.id)
                )
                if verdict.retiredNow {
                    used.insert(m.sequence)
                    next.delivered.insert(row.id)
                    break
                }
            }
        }
        next.consumedSequences = used
        return next
    }

    func enqueue(_ id: String, _ content: String, lastSequence: Int64? = nil) -> OrbFollowUpQueue {
        let rowHash = Self.hashMessageId(id)
        let trackedHash: UInt64 = (pending.contains { $0.id == id } || server.contains { $0.id == id }) ? rowHash : 0
        let verdict = OrbKernel.followupQueueStep(
            op: 2,
            serverRev: serverRev,
            incomingServerRev: 0,
            expectedServerRev: 0,
            clientMsgId: rowHash,
            trackedMsgId: trackedHash,
            deliveredMsgId: 0,
            postedAfterSeq: Self.seqWord(lastSequence),
            turnSeq: 0,
            optimisticSending: true,
            serverListed: server.contains { $0.id == id },
            contentMatched: false,
            alreadyDelivered: delivered.contains(id)
        )
        guard verdict.admitted else { return self }
        var next = self
        next.serverRev = verdict.nextServerRev
        next.pending = pending.filter { $0.id != id } + [OrbQueuedRow(id: id, content: content, sending: true)]
        if let lastSequence { next.seenAfter[id] = lastSequence } else { next.seenAfter.removeValue(forKey: id) }
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

    func edit(_ id: String, _ content: String, expectedServerRev: UInt32? = nil) -> OrbFollowUpQueue {
        guard !delivered.contains(id) else { return self }
        let expected = expectedServerRev ?? serverRev
        let rowHash = Self.hashMessageId(id)
        let verdict = OrbKernel.followupQueueStep(
            op: 1,
            serverRev: serverRev,
            incomingServerRev: 0,
            expectedServerRev: expected,
            clientMsgId: rowHash,
            trackedMsgId: rowHash,
            deliveredMsgId: 0,
            postedAfterSeq: 0,
            turnSeq: 0,
            optimisticSending: false,
            serverListed: server.contains { $0.id == id },
            contentMatched: false,
            alreadyDelivered: false
        )
        guard verdict.admitted else { return self }
        var next = self
        next.edits[id] = content
        return next
    }

    func editConfirmed(
        _ id: String,
        _ content: String,
        expectedServerRev: UInt32? = nil,
        confirmedServerRev: UInt32? = nil,
        confirmedAt: Date = .distantPast
    ) -> OrbFollowUpQueue {
        guard !delivered.contains(id) else { return self }
        let expected = expectedServerRev ?? serverRev
        let rowHash = Self.hashMessageId(id)
        let verdict = OrbKernel.followupQueueStep(
            op: 1,
            serverRev: serverRev,
            incomingServerRev: 0,
            expectedServerRev: expected,
            clientMsgId: rowHash,
            trackedMsgId: rowHash,
            deliveredMsgId: 0,
            postedAfterSeq: 0,
            turnSeq: 0,
            optimisticSending: false,
            serverListed: server.contains { $0.id == id },
            contentMatched: false,
            alreadyDelivered: false
        )
        guard verdict.admitted else { return self }
        var next = self
        let trackedRevision = hasServerRevision || expectedServerRev != nil || (confirmedServerRev ?? 0) > 0
        let appliedRevision: UInt32? = {
            if let confirmedServerRev, confirmedServerRev > 0 { return max(verdict.nextServerRev, confirmedServerRev) }
            return trackedRevision ? verdict.nextServerRev : nil
        }()
        if let appliedRevision {
            next.serverRev = appliedRevision
            next.hasServerRevision = true
        }
        next.server = server.map {
            var r = $0
            if r.id == id {
                r.content = content
                if let appliedRevision { r.revision = appliedRevision }
            }
            return r
        }
        next.pending = pending.map { var r = $0; if r.id == id { r.content = content }; return r }
        next.edits[id] = nil
        if confirmedAt != .distantPast && confirmedAt > next.lastFetchedAt {
            next.lastFetchedAt = confirmedAt
        }
        return next
    }

    func editReverted(_ id: String) -> OrbFollowUpQueue { var next = self; next.edits[id] = nil; return next }
    func hide(_ id: String) -> OrbFollowUpQueue { var next = self; next.hidden.insert(id); return next }
    func unhide(_ id: String) -> OrbFollowUpQueue { var next = self; next.hidden.remove(id); return next }

    private static func parseUInt32Revision(_ value: OrbJSON) -> UInt32? {
        guard let d = value.doubleValue, d.isFinite else { return nil }
        let truncated = Int64(d)
        guard truncated > 0 else { return nil }
        return truncated > Int64(UInt32.max) ? UInt32.max : UInt32(truncated)
    }

    /// Rows of `GET /api/control/queue` for `missionID` that belong in the follow-up queue.
    static func parse(_ items: [OrbJSON], missionID: String) -> [OrbQueuedRow] {
        items.compactMap { item in
            let id = item["id"].text
            guard !id.isEmpty, item["mission_id"].text == missionID, item["inflight"] != .bool(true) else { return nil }
            let source = item["source"].text
            guard source.isEmpty || source == "remote-queue" || source.hasPrefix("host-queue:api:") else { return nil }
            let error = item["queue_error"].text
            return OrbQueuedRow(
                id: id,
                content: item["content"].text,
                queueError: error.isEmpty ? nil : error,
                revision: parseUInt32Revision(item["revision"])
            )
        }
    }

    /// Parses either a raw `[...]` queue list or `{ items: [...], revision: N }` envelope.
    static func parseResponse(
        _ raw: OrbJSON,
        missionID: String,
        missionScoped: Bool = true
    ) -> (rows: [OrbQueuedRow], revision: UInt32?) {
        let items: [OrbJSON]
        let envelopeRev: UInt32?
        switch raw {
        case .array(let arr):
            items = arr
            envelopeRev = nil
        case .object:
            items = raw["items"].items
            envelopeRev = missionScoped ? parseUInt32Revision(raw["revision"]) : nil
        default:
            return ([], nil)
        }
        var maxRev = envelopeRev
        for item in items where item["mission_id"].text == missionID {
            if let r = parseUInt32Revision(item["revision"]), maxRev == nil || r > maxRev! {
                maxRev = r
            }
        }
        return (parse(items, missionID: missionID), maxRev)
    }
}

enum OrbCyberAccess {
    static let modes = ["automatic", "standard", "daybreak"]
    static func label(_ mode: String) -> String { mode.capitalized }
    static func isGoal(_ text: String, mode: String = "Message") -> Bool {
        if mode == "Goal" { return true }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = value.prefix(5).lowercased()
        return prefix == "/goal" && (value.count == 5 || value.dropFirst(5).first?.isWhitespace == true)
    }
    static func emptyGoalError(_ text: String, mode: String = "Message") -> String? {
        guard isGoal(text, mode: mode) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "Goal" && value.prefix(5).lowercased() != "/goal" {
            return value.isEmpty ? "Add an objective after /goal, for example “/goal Make the test suite pass”. Your draft is kept." : nil
        }
        let rest = value.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "Add an objective after /goal, for example “/goal Make the test suite pass”. Your draft is kept." : nil
    }
    static func compatibility(mode: String, model: String) -> String? {
        let id = model.components(separatedBy: "/").last ?? model
        if ["gpt-daybreak-blue-latest", "gpt-daybreak-red-latest"].contains(id) {
            return "OpenAI retired the \(id) alias on 2026-10-28. Choose a specific model ID such as \(id.contains("red") ? "gpt-5.6-cyber" : "gpt-6.1-sol")."
        }
        if mode == "standard" && (id.hasPrefix("gpt-daybreak-") || id == "gpt-5.6-cyber") { return "This model requires Daybreak. Choose Daybreak or Automatic, or change the model." }
        if mode == "daybreak" && !["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-cyber"].contains(id) { return "Daybreak support has not been established for this model." }
        return nil
    }
    static func capabilityPath(model: String, mode: String, remote: Bool) -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "/api/control/cyber-capabilities?" + (model.isEmpty ? "" : "model=\(OrbCore.escape(model))&") + "mode=\(mode)&remote=\(remote)"
    }
    static func refusal(_ value: OrbJSON, mode: String, remote: Bool, goal: Bool) -> String? {
        if value["version"].doubleValue != 2 { return "Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept." }
        if goal && mode != "automatic" && value["native_goals_explicit"] != .bool(true) { return "This connection cannot confirm an explicit Cyber program for native goals. Choose Automatic explicitly. Your draft is kept." }
        if remote && mode != "automatic" && value["route_supported"] != .bool(true) {
            return value["refusal"].text.isEmpty ? "This backend cannot confirm the selected Cyber route. Choose Automatic explicitly. Your draft is kept." : value["refusal"].text
        }
        return nil
    }
    static func confirmed(_ value: OrbJSON) -> Bool { value["status"].text == "confirmed" && !value["confirmed_program"].text.isEmpty }
    static func error(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("access_program_not_enabled") { return "Daybreak is not enabled for this account and model. Check the account’s approved access, or explicitly select Standard. The model was not changed." }
        if text.contains("unsupported_access_program") { return "This connection cannot apply the requested cyber program. Choose another supported connection, or explicitly select Automatic. " + text }
        if text.contains("invalid_access_program") { return "The selected cyber program is incompatible with this model. Choose another program or model." }
        if text.contains("cyberPolicy") || text.contains("cyber_policy") { return "OpenAI rejected this request under its cyber policy. This can also happen with Daybreak enabled. " + text }
        return text
    }
    @discardableResult
    @MainActor static func requireFollowUp(_ content: String, missionID: String) async throws -> (mode: String, revision: String)? {
        let mission = try await OrbCore.shared.call("/api/control/missions/\(OrbCore.escape(missionID))?include_history=false")
        return try await requireFollowUp(content, mission: mission)
    }
    @discardableResult
    @MainActor static func requireFollowUp(_ content: String, mission: OrbJSON, model: String? = nil, node: String = "", call: (String) async throws -> OrbJSON = { try await OrbCore.shared.call($0) }) async throws -> (mode: String, revision: String)? {
        guard !OrbRow(mission).cloud, mission["backend"].text == "codex" else { return nil }
        if let reason = emptyGoalError(content) { throw OrbHTTPError(status: 400, detail: reason) }
        let current = try await call("/api/control/missions/\(OrbCore.escape(mission["id"].text))/cyber")
        guard modes.contains(current["mode"].text) else {
            throw OrbHTTPError(status: 400, detail: "The backend did not return a Cyber selection. Your draft is kept.")
        }
        try await require(model: model ?? mission["model_override"].text, mode: current["mode"].text, remote: OrbContinuation.remoteNodeID(for: mission, fallback: node) != "core", goal: isGoal(content), call: call)
        return (mode: current["mode"].text, revision: current["revision"].text)
    }
    @MainActor static func require(model: String, mode: String, remote: Bool, goal: Bool, call: (String) async throws -> OrbJSON = { try await OrbCore.shared.call($0) }) async throws {
        if let reason = (remote && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : compatibility(mode: mode, model: model)) { throw OrbHTTPError(status: 400, detail: reason) }
        let value: OrbJSON
        do { value = try await call(capabilityPath(model: model, mode: mode, remote: remote)) }
        catch { throw OrbHTTPError(status: 400, detail: "Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept; the requested program was not silently omitted.") }
        if let reason = refusal(value, mode: mode, remote: remote, goal: goal) { throw OrbHTTPError(status: 400, detail: reason) }
    }
}

enum OrbEditOutcome: Equatable { case edited, unsupported, alreadySent, failed }
enum OrbSendNowOutcome: Equatable { case live, promoted, fallback }

enum OrbTapAction: Equatable { case send, deferToQueue, ignore }

enum OrbSendFlow {
    /// A tap on send never does nothing: while a send is in flight a follow-up is
    /// accepted at once as an optimistic queued row and posted once that send settles.
    static func tapAction(busy: Bool, content: String, canQueue: Bool) -> OrbTapAction {
        let nonEmpty = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let step = OrbKernel.sendFlowStep(
            isBusy: busy,
            hasNonEmptyText: nonEmpty,
            canQueue: canQueue,
            awaitingAck: false,
            isDraining: false,
            pendingCount: 0,
            httpStatus: 0
        )
        switch step.tapAction {
        case 1: return .send
        case 2: return .deferToQueue
        default: return .ignore
        }
    }

    /// Deferred follow-ups go out once the in-flight POST returned, whatever happens after.
    static func canDrain(awaitingAck: Bool, draining: Bool, pending: Int) -> Bool {
        OrbKernel.sendFlowStep(
            isBusy: false,
            hasNonEmptyText: false,
            canQueue: false,
            awaitingAck: awaitingAck,
            isDraining: draining,
            pendingCount: pending,
            httpStatus: 0
        ).canDrain
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
        if status == 404 { return .alreadySent }
        let step = OrbKernel.sendFlowStep(
            isBusy: false,
            hasNonEmptyText: false,
            canQueue: false,
            awaitingAck: false,
            isDraining: false,
            pendingCount: 0,
            httpStatus: status
        )
        switch step.editOutcome {
        case 1: return .edited
        case 2: return .unsupported
        case 3: return .alreadySent
        default: return .failed
        }
    }

    static func sendNowOutcome(_ response: OrbJSON) -> OrbSendNowOutcome {
        if response["delivered"] == .bool(true) { return .live }
        if response["promoted"] == .bool(true) { return .promoted }
        return .fallback
    }

    /// Current turn's stored assistant messages (excluding narration already moved into the work fold),
    /// so previous turns' replies never suppress live streaming text on a follow-up turn.
    static func currentTurnStoredAnswers(_ rows: [(String, String, String)], narration: Set<String> = []) -> [String] {
        let lastUserIdx = rows.lastIndex(where: { $0.1 == "user" }) ?? -1
        return Array(rows[(lastUserIdx + 1)...].lazy.compactMap { row -> String? in
            guard row.1 == "assistant" else { return nil }
            let trimmed = row.2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !narration.contains(trimmed) else { return nil }
            return row.2
        }.suffix(3))
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
            if t == l || t.hasPrefix(l) { return "" }
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

/// `/skill:<name>` composer contract (`orb/src/skillSlash.ts`). Admission goes through `OrbKernel.skillSlashStep`.
struct OrbSkillChoice: Equatable, Identifiable, Sendable {
    var name: String
    var description: String?
    var id: String { name }
}

struct OrbSkillToken: Equatable, Sendable {
    var name: String
    var start: Int
    var end: Int
}

enum OrbSkillSlash {
    static let maxName = 64
    static let maxSelected = 8
    private static let token = try! NSRegularExpression(pattern: #"(^|[\s])/skill:([^\s]*)"#)

    static func skillToken(_ name: String) -> String { "/skill:\(name)" }

    static func isValidSkillIdentifier(_ name: String) -> Bool {
        if name.isEmpty || name.contains("..") { return false }
        for scalar in name.unicodeScalars {
            let c = scalar.value
            let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95 || c == 46
            if !ok { return false }
        }
        return true
    }

    static func skillTokens(_ text: String) -> [OrbSkillToken] {
        let ns = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let lead = match.range(at: 1)
            let start = match.range.location + lead.length
            return OrbSkillToken(name: ns.substring(with: match.range(at: 2)), start: start, end: match.range.location + match.range.length)
        }
    }

    /// Open slash query at `caret` (UTF-16). Closed once the token contains `/` or starts with `skill:`.
    static func skillQuery(_ text: String, caret: Int) -> (open: Bool, query: String, start: Int) {
        let ns = text as NSString
        let end = min(max(caret, 0), ns.length)
        let before = ns.substring(to: end)
        let regex = try! NSRegularExpression(pattern: #"(^|[\s])/([^\s]*)$"#)
        guard let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else {
            return (false, "", -1)
        }
        let queryRange = match.range(at: 2)
        let query = (before as NSString).substring(with: queryRange)
        if query.contains("/") || query.hasPrefix("skill:") { return (false, "", -1) }
        let start = end - queryRange.length - 1
        return (true, query.lowercased(), start)
    }

    static func filterSkills(_ skills: [OrbSkillChoice], query: String, selected: [String]) -> [OrbSkillChoice] {
        let used = Set(selected)
        return Array(skills.filter { skill in
            !used.contains(skill.name) && (query.isEmpty || skill.name.lowercased().contains(query) || (skill.description ?? "").lowercased().contains(query))
        }.prefix(50))
    }

    static func insertSkill(_ text: String, caret: Int, name: String) -> (text: String, caret: Int) {
        let query = skillQuery(text, caret: caret)
        let ns = text as NSString
        let start = query.open && query.start >= 0 ? query.start : min(max(caret, 0), ns.length)
        let token = skillToken(name) + " "
        let next = (ns.substring(to: start) as NSString).appending(token).appending(ns.substring(from: min(max(caret, 0), ns.length)))
        return (next, start + (token as NSString).length)
    }

    static func removeSkill(_ text: String, name: String) -> String {
        guard let token = skillTokens(text).first(where: { $0.name == name }) else { return text }
        let ns = text as NSString
        let next = (ns.substring(to: token.start) as NSString).appending(ns.substring(from: token.end))
        return next.replacingOccurrences(of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[^\S\n]+|[^\S\n]+$"#, with: "", options: .regularExpression)
    }

    static func selectedSkillNames(_ text: String, available: Set<String>) -> [String] {
        var names: [String] = []
        for token in skillTokens(text) where available.contains(token.name) && !names.contains(token.name) {
            names.append(token.name)
        }
        return names
    }

    static func harnessKind(_ harness: String?) -> Int {
        harness == "opencode" ? 1 : harness == "claudecode" ? 2 : 0
    }

    static func validateSkillSelection(_ text: String, harness: String?, available: Set<String>) -> String? {
        let kind = harnessKind(harness)
        var selected: [String] = []
        for token in skillTokens(text) {
            if selected.contains(token.name) { continue }
            let verdict = OrbKernel.skillSlashStep(
                harnessKind: kind,
                isDelivered: available.contains(token.name),
                alreadySelected: false,
                nameCharsValid: isValidSkillIdentifier(token.name),
                nameLen: (token.name as NSString).length,
                maxNameLen: maxName,
                selectedCount: selected.count,
                maxSelected: maxSelected
            )
            if !verdict.admitted {
                if verdict.rejectCode == 1 || verdict.rejectCode == 2 { return "Invalid /skill: identifier (use at most 64 ASCII letters, numbers, '.', '_' or '-', without '..')" }
                if verdict.rejectCode == 3 { return "Selected skill is not delivered to this mission: \(token.name)" }
                if verdict.rejectCode == 5 { return "Select at most 8 distinct skills" }
                return "Skill selection rejected"
            }
            selected.append(token.name)
        }
        return nil
    }

    static func skillDisplayText(_ text: String, available: Set<String>) -> String {
        var current = text
        for token in skillTokens(text).reversed() where available.contains(token.name) {
            let ns = current as NSString
            guard token.end <= ns.length else { continue }
            current = (ns.substring(to: token.start) as NSString).appending("/\(token.name)").appending(ns.substring(from: token.end))
        }
        return current
    }

    static func skillPreview(_ text: String) -> String {
        skillDisplayText(text, available: Set(skillTokens(text).map(\.name)))
    }

    @MainActor static func loadDelivery(project: String, workspaceID: String? = nil) async -> (skills: [OrbSkillChoice], error: String?) {
        var parts: [String] = []
        if let workspaceID, !workspaceID.isEmpty { parts.append("workspace_id=\(OrbCore.escape(workspaceID))") }
        if !project.isEmpty { parts.append("project=\(OrbCore.escape(project))") }
        guard !parts.isEmpty else { return ([], nil) }
        do {
            let res = try await OrbCore.shared.call("/api/library/skill-delivery?\(parts.joined(separator: "&"))")
            let skills = res["skills"].items.compactMap { row -> OrbSkillChoice? in
                let name = row["name"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let desc = row["description"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                return OrbSkillChoice(name: name, description: desc.isEmpty ? nil : desc)
            }
            return (skills, nil)
        } catch let e as OrbHTTPError where e.status == 404 {
            return ([], nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }
}
