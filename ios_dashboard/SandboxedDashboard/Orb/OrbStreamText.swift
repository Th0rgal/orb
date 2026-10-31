import SwiftUI

/// Streaming reply text, specified by `lean/Orb/Stream.lean` (checked against
/// `shared/orb-spec/fixtures/stream-commit.json` in `OrbStreamTextTests`).
///
/// A reply arrives as thousands of 4-character deltas. Two pieces keep the cost of
/// each delta bounded instead of growing with the reply:
/// - `OrbLiveText` coalesces deltas into one update per display frame, and only the
///   streaming bubble observes the text (not the whole conversation screen).
/// - `OrbStreamCommit` finds the committed Markdown prefix, so the block parser only
///   re-parses the open tail of a growing reply.

/// Pure reducer for the active turn's live intermediate text (`text_op` and `text_delta`),
/// shared with `OrbTurnText` in `OrbStreamText.kt` and desktop `TranscriptReducer`.
struct OrbTurnText: Equatable {
    struct Bubble: Equatable {
        var id: String
        var text: String
        var revision: Int = -1
        var finalized: Bool = false
    }

    struct StoredRow {
        var sequence: Int64
        var eventType: String
        var content: String
        var bubbleId: String?
        var queued: Bool
        var success: Bool
        var partial: Bool
    }

    private(set) var bubbles: [Bubble] = []
    private(set) var storedCanonicalIDs: Set<String> = []
    private(set) var lastUserSequence: Int64 = -1
    private(set) var streamEpoch: Int = 0

    var renderedText: String {
        let parts = bubbles.compactMap { b -> String? in
            guard !storedCanonicalIDs.contains(b.id), !b.text.isEmpty else { return nil }
            return b.text
        }
        return parts.joined(separator: "\n\n")
    }

    mutating func clear() {
        bubbles.removeAll()
        storedCanonicalIDs.removeAll()
        lastUserSequence = -1
    }

    mutating func resetTurn(userSequence: Int64 = -1) {
        bubbles.removeAll()
        storedCanonicalIDs.removeAll()
        if userSequence >= 0 { lastUserSequence = userSequence }
    }

    mutating func applyTextDelta(_ data: [String: Any]) {
        streamEpoch &+= 1
        let bubbleID = Self.nonEmptyString(data["bubble_id"]) ?? "text_delta_latest"
        if let delta = data["delta"] as? String {
            appendBubble(id: bubbleID, delta: delta)
        } else if (data["mode"] as? String) == "delta",
                  let chunk = (data["content"] as? String) ?? (data["text"] as? String) {
            appendBubble(id: bubbleID, delta: chunk)
        } else if let snapshot = (data["content"] as? String) ?? (data["text"] as? String) {
            setBubble(id: bubbleID, text: snapshot)
        }
    }

    mutating func applyTextOp(_ data: [String: Any]) {
        streamEpoch &+= 1
        let bubbleID = Self.nonEmptyString(data["bubble_id"]) ?? "text_delta_latest"
        if bubbleID != "text_delta_latest", storedCanonicalIDs.contains(bubbleID) { return }
        if let ops = data["ops"] as? [[String: Any]] {
            applyOps(bubbleID: bubbleID, ops: ops)
        } else if let op = data["op"] as? String {
            let content = data["content"] as? String ?? ""
            if op == "append" { appendBubble(id: bubbleID, delta: content) }
            else if op == "replace" { setBubble(id: bubbleID, text: content) }
        }
    }

    mutating func reconcileStored(_ rows: [StoredRow], working: Bool, streamAdvanced: Bool = false) {
        guard working else { clear(); return }
        let ordered = rows.sorted { $0.sequence < $1.sequence }
        let lastUserIdx = ordered.lastIndex(where: { $0.eventType == "user_message" && !$0.queued }) ?? -1
        let lastUserSeq: Int64 = lastUserIdx >= 0 ? ordered[lastUserIdx].sequence : 0
        if lastUserSequence >= 0 && lastUserSeq > lastUserSequence {
            bubbles.removeAll()
            storedCanonicalIDs.removeAll()
        }
        if lastUserSeq > 0 || lastUserSequence < 0 {
            lastUserSequence = max(lastUserSequence, lastUserSeq)
        }

        var turnEnded = false
        var storedDelta: String?
        var storedOpsOrder: [String] = []
        var storedOpsByBubble: [String: [[String: Any]]] = [:]
        var canonicalIDs: Set<String> = []

        for row in ordered[(lastUserIdx + 1)...] {
            switch row.eventType {
            case "text_delta":
                storedDelta = row.content
                turnEnded = false
            case "text_op":
                let bid = row.bubbleId ?? "text_delta_latest"
                let ops = Self.parseOpsJSON(row.content)
                if !ops.isEmpty {
                    if storedOpsByBubble[bid] == nil { storedOpsOrder.append(bid) }
                    storedOpsByBubble[bid, default: []].append(contentsOf: ops)
                }
                turnEnded = false
            case "assistant_message_canonical":
                let bid = row.bubbleId ?? "text_delta_latest"
                canonicalIDs.insert(bid)
                storedOpsByBubble.removeValue(forKey: bid)
            case "assistant_message":
                if !row.partial && row.success {
                    storedDelta = nil
                    storedOpsByBubble.removeAll()
                    storedOpsOrder.removeAll()
                    turnEnded = true
                }
            default:
                break
            }
        }

        storedCanonicalIDs = canonicalIDs
        bubbles.removeAll { canonicalIDs.contains($0.id) && $0.id != "text_delta_latest" }
        if turnEnded {
            bubbles.removeAll()
            return
        }

        if let stored = storedDelta, !stored.isEmpty {
            let current = bubbles.first(where: { $0.id == "text_delta_latest" })?.text ?? ""
            if current.isEmpty {
                setBubble(id: "text_delta_latest", text: stored)
            } else if current.hasPrefix(stored) {
                // Live SSE stream is already ahead of this stored snapshot.
            } else if stored.hasPrefix(current) || !streamAdvanced {
                setBubble(id: "text_delta_latest", text: stored)
            }
        }

        for bid in storedOpsOrder where !canonicalIDs.contains(bid) {
            if !bubbles.contains(where: { $0.id == bid }), let ops = storedOpsByBubble[bid] {
                applyOps(bubbleID: bid, ops: ops)
            }
        }
    }

    static func rows(from events: [StoredEvent]) -> [StoredRow] {
        events.map { e in
            let metaBubble = e.metadata["bubble_id"]?.value as? String
            let bid = Self.nonEmptyString(metaBubble) ?? Self.nonEmptyString(e.eventId)
            let queued = (e.metadata["queued"]?.value as? Bool) == true
            let success = (e.metadata["success"]?.value as? Bool) != false
            let partial = (e.metadata["partial"]?.value as? Bool) == true || (e.metadata["turn_end"]?.value as? String) == "partial"
            return StoredRow(sequence: e.sequence, eventType: e.eventType, content: e.content, bubbleId: bid, queued: queued, success: success, partial: partial)
        }
    }

    static func fromStoredEvents(_ events: [StoredEvent], working: Bool) -> String {
        var turn = OrbTurnText()
        turn.reconcileStored(rows(from: events), working: working)
        return turn.renderedText
    }

    mutating func applyOps(bubbleID: String, ops: [[String: Any]]) {
        var bubble = bubbles.first(where: { $0.id == bubbleID }) ?? Bubble(id: bubbleID, text: "")
        for op in ops {
            switch (op["type"] as? String) ?? "" {
            case "snapshot":
                guard let rev = Self.intValue(op["revision"]), rev > bubble.revision else { return }
                bubble.revision = rev
                bubble.text = (op["text"] as? String) ?? ""
                bubble.finalized = false
            case "insert":
                let piece = (op["text"] as? String) ?? ""
                let pos = Self.intValue(op["pos"])
                if bubbleID == "text_delta_latest" && pos == 0 {
                    bubble.text = piece
                } else {
                    bubble.text = Self.spliceScalars(bubble.text, start: pos, end: pos, replacement: piece)
                }
                bubble.finalized = false
            case "replace":
                let piece = (op["text"] as? String) ?? ""
                let range = Self.intList(op["range"])
                if bubbleID == "text_delta_latest" && (range?.first ?? 0) == 0 {
                    bubble.text = piece
                } else if let range, range.count >= 2 {
                    bubble.text = Self.spliceScalars(bubble.text, start: range[0], end: range[1], replacement: piece)
                } else {
                    bubble.text = piece
                }
                bubble.finalized = false
            case "finalize":
                bubble.finalized = true
            default:
                break
            }
        }
        upsertBubble(bubble)
    }

    private mutating func appendBubble(id: String, delta: String) {
        guard !delta.isEmpty else { return }
        var bubble = bubbles.first(where: { $0.id == id }) ?? Bubble(id: id, text: "")
        bubble.text += delta
        bubble.finalized = false
        upsertBubble(bubble)
    }

    private mutating func setBubble(id: String, text: String) {
        var bubble = bubbles.first(where: { $0.id == id }) ?? Bubble(id: id, text: "")
        bubble.text = text
        bubble.finalized = false
        upsertBubble(bubble)
    }

    private mutating func upsertBubble(_ bubble: Bubble) {
        if let idx = bubbles.firstIndex(where: { $0.id == bubble.id }) {
            if bubble.text.isEmpty && !bubble.finalized {
                bubbles.remove(at: idx)
            } else {
                bubbles[idx] = bubble
            }
        } else if !bubble.text.isEmpty || bubble.finalized {
            bubbles.append(bubble)
        }
    }

    static func spliceScalars(_ text: String, start: Int?, end: Int?, replacement: String) -> String {
        guard let start else { return text + replacement }
        let targetEnd = end ?? start
        if start >= text.utf16.count && targetEnd >= text.utf16.count {
            return text + replacement
        }
        let scalars = Array(text.unicodeScalars)
        let s = max(0, min(start, scalars.count))
        let e = max(s, min(targetEnd, scalars.count))
        if s == scalars.count && e == scalars.count {
            return text + replacement
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count - (e - s) + replacement.unicodeScalars.count)
        out.append(contentsOf: scalars[..<s])
        out.append(contentsOf: replacement.unicodeScalars)
        out.append(contentsOf: scalars[e...])
        return String(out)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? Int64 { return Int(n) }
        if let n = raw as? Double, n.isFinite { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private static func intList(_ raw: Any?) -> [Int]? {
        if let ints = raw as? [Int] { return ints }
        if let any = raw as? [Any] {
            let parsed = any.compactMap { intValue($0) }
            return parsed.count == any.count ? parsed : nil
        }
        return nil
    }

    private static func parseOpsJSON(_ content: String) -> [[String: Any]] {
        guard !content.isEmpty, let data = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parsed
    }
}

/// `Orb.Stream.Coalescer`: deltas collect in `pending`; a frame moves them to `text`.
/// At most one observable change per frame, nothing lost, an idle frame changes nothing.
@MainActor @Observable
final class OrbLiveText {
    /// What the streaming bubble shows.
    private(set) var text = ""
    /// Whether there is any text; observed by the screen (status label, bubble presence),
    /// so it changes on the first delta and on clear, not on every frame.
    private(set) var hasText = false
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var turn = OrbTurnText()
    /// One display frame at 60 Hz.
    @ObservationIgnored var frame: Duration = .milliseconds(16)

    /// Frames that changed `text` (the coalescer's render count).
    @ObservationIgnored private(set) var renders = 0
    /// Everything received, shown or not (the conservation law: `text + pending`).
    var received: String { text + pending }
    /// Monotonic counter incremented on every live SSE/WS delta or op.
    var streamEpoch: Int { turn.streamEpoch }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        turn.applyTextDelta(["delta": delta])
        appendCoalesced(delta)
    }

    /// `text_op` replace: the new text wins over anything pending.
    func replace(_ content: String) {
        if content.isEmpty {
            turn.clear()
        } else {
            turn.applyTextDelta(["content": content])
        }
        replaceImmediate(content)
    }

    func clear() { replace("") }

    func resetTurn(userSequence: Int64 = -1) {
        turn.resetTurn(userSequence: userSequence)
        replaceImmediate("")
    }

    func applyTextDelta(_ data: [String: Any]) {
        turn.applyTextDelta(data)
        syncWithTurn(immediate: false)
    }

    func applyTextOp(_ data: [String: Any]) {
        turn.applyTextOp(data)
        syncWithTurn(immediate: false)
    }

    func reconcileStored(_ events: [StoredEvent], working: Bool, streamAdvanced: Bool = false) {
        let wasEmpty = received.isEmpty
        turn.reconcileStored(OrbTurnText.rows(from: events), working: working, streamAdvanced: streamAdvanced)
        syncWithTurn(immediate: wasEmpty)
    }

    /// Moves pending text to `text` now (one render), e.g. before reading it.
    func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !pending.isEmpty else { return }
        text += pending
        pending = ""
        renders += 1
    }

    private func syncWithTurn(immediate: Bool) {
        let next = turn.renderedText
        let current = received
        if next == current { return }
        if next.isEmpty {
            replaceImmediate("")
            return
        }
        if !immediate && next.hasPrefix(current) {
            appendCoalesced(String(next.dropFirst(current.count)))
        } else {
            replaceImmediate(next)
        }
    }

    private func appendCoalesced(_ delta: String) {
        guard !delta.isEmpty else { return }
        pending += delta
        if !hasText { hasText = true }
        scheduleFrame()
    }

    private func replaceImmediate(_ content: String) {
        pending = ""
        flushTask?.cancel(); flushTask = nil
        if text != content { text = content }
        if hasText != !content.isEmpty { hasText = !content.isEmpty }
    }

    private func scheduleFrame() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, frame] in
            try? await Task.sleep(for: frame)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }
}

/// `Orb.Stream.Scan`: the committed Markdown prefix. Ends after the last blank line that
/// lies outside every code fence: the block parser's backtick toggle and the pipe-table
/// normalizer's fence marker. `parseBlocks` starts fresh there, so blocks before it are final.
struct OrbStreamCommit: Equatable {
    struct Line: Equatable {
        var blank: Bool
        var tick: Bool
        /// (backtick, run length) of a fence marker.
        var marker: Marker?
    }
    struct Marker: Equatable { var backtick: Bool; var count: Int }

    var tick = false
    var fence: Marker?
    var pos = 0
    var commit = 0

    static func classify<S: StringProtocol>(_ raw: S) -> Line {
        let rest = raw.drop(while: { $0 == " " || $0 == "\t" })
        var marker: Marker?
        if let c = rest.first, c == "`" || c == "~" {
            let n = rest.prefix(while: { $0 == c }).count
            if n >= 3 { marker = Marker(backtick: c == "`", count: n) }
        }
        // The parser's own trimming decides blank and fence lines.
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return Line(blank: trimmed.isEmpty, tick: trimmed.hasPrefix("```"), marker: marker)
    }

    static func nextFence(_ open: Marker?, _ m: Marker?) -> Marker? {
        let openKind = open.map { $0.backtick ? 1 : 2 } ?? 0
        let openCount = open?.count ?? 0
        let markerKind = m.map { $0.backtick ? 1 : 2 } ?? 0
        let markerCount = m?.count ?? 0
        let res = OrbKernel.streamFenceStep(openKind: openKind, openCount: openCount, markerKind: markerKind, markerCount: markerCount)
        guard res.kind != 0 else { return nil }
        return Marker(backtick: res.kind == 1, count: res.count)
    }

    mutating func scan(_ line: Line) {
        let openKind = fence.map { $0.backtick ? 1 : 2 } ?? 0
        let openCount = fence?.count ?? 0
        let markerKind = line.marker.map { $0.backtick ? 1 : 2 } ?? 0
        let markerCount = line.marker?.count ?? 0
        let res = OrbKernel.streamCommitStep(
            tick: tick,
            openKind: openKind,
            openCount: openCount,
            lineBlank: line.blank,
            lineTick: line.tick,
            markerKind: markerKind,
            markerCount: markerCount,
            pos: pos,
            commit: commit
        )
        tick = res.tick
        fence = res.openKind == 0 ? nil : Marker(backtick: res.openKind == 1, count: res.openCount)
        pos = res.pos
        commit = res.commit
    }

    /// The UTF-8 offset in `text` where the committed prefix ends: after the newline of the
    /// last committing line. The last line is still growing (a delta can turn a blank line
    /// into text), so only newline-terminated lines can commit.
    static func committedOffset(_ text: Substring) -> Int {
        var state = OrbStreamCommit()
        var offset = 0
        var committed = 0
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        while let end = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = Substring(utf8[lineStart..<end])
            let before = state.commit
            state.scan(classify(line))
            offset += line.utf8.count + 1
            if state.commit != before { committed = offset }
            lineStart = utf8.index(after: end)
        }
        return committed
    }
}

/// `parseBlocks` for text that grows by appending (Orb.Stream §3): the committed prefix is
/// parsed once (`resume_at_commit`), only the open tail on each update, so a stream re-parses
/// its final committed length plus its tails (`incCost_eq`) instead of every prefix in full.
@MainActor
final class OrbStreamBlocks {
    private static let openFenceStreamThreshold = 4096

    private var previous = ""
    private var commitUTF8 = 0
    private var scanUTF8 = 0
    private var scanState = OrbStreamCommit()
    private var prefixBlocks: [OrbNativeMarkdownView.Block] = []

    private var openFenceStartUTF8 = -1
    private var openFenceBodyStartUTF8 = 0
    private var openFenceBodyCursorUTF8 = 0
    private var openFenceLang = ""
    private var openFencePrefixBlocks: [OrbNativeMarkdownView.Block]?
    private var openFenceAcc = ""
    private var openFenceHasLines = false

    /// UTF-8 bytes scanned by the checkpointed commit scanner (`Orb.Stream.CheckpointedScan`).
    private(set) var scannedBytes = 0
    /// UTF-8 bytes handed to `parseBlocks` so far (`incCost`; checked against stream-cost.json).
    private(set) var parsedBytes = 0

    private func resetOpenFence() {
        openFenceStartUTF8 = -1
        openFencePrefixBlocks = nil
        openFenceAcc.removeAll(keepingCapacity: true)
        openFenceHasLines = false
    }

    func blocks(_ source: String) -> [OrbNativeMarkdownView.Block] {
        if !source.hasPrefix(previous) {
            commitUTF8 = 0
            scanUTF8 = 0
            scanState = OrbStreamCommit()
            prefixBlocks = []
            resetOpenFence()
        }
        previous = source

        let utf8 = source.utf8
        var newCommitUTF8 = commitUTF8
        var cursorIdx = utf8.index(utf8.startIndex, offsetBy: scanUTF8)
        while let nlIdx = utf8[cursorIdx...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineSub = Substring(utf8[cursorIdx..<nlIdx])
            let lineLen = lineSub.utf8.count
            let lineStartUTF8 = scanUTF8
            scanUTF8 += lineLen + 1
            scannedBytes += lineLen + 1
            cursorIdx = utf8.index(after: nlIdx)

            let wasTick = scanState.tick
            let beforeCommit = scanState.commit
            scanState.scan(OrbStreamCommit.classify(lineSub))
            if scanState.commit != beforeCommit {
                newCommitUTF8 = scanUTF8
                resetOpenFence()
            } else if !wasTick && scanState.tick {
                openFenceStartUTF8 = lineStartUTF8
                openFenceBodyStartUTF8 = scanUTF8
                openFenceBodyCursorUTF8 = scanUTF8
                let trimmed = lineSub.trimmingCharacters(in: .whitespaces)
                openFenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                openFencePrefixBlocks = nil
                openFenceAcc.removeAll(keepingCapacity: true)
                openFenceHasLines = false
            } else if wasTick && !scanState.tick {
                resetOpenFence()
            }
        }

        let commitStartIdx = utf8.index(utf8.startIndex, offsetBy: commitUTF8)
        let advance = newCommitUTF8 - commitUTF8
        let commitEndIdx: String.UTF8View.Index
        if advance > 0 {
            commitEndIdx = utf8.index(commitStartIdx, offsetBy: advance)
            let chunk = String(Substring(utf8[commitStartIdx..<commitEndIdx]))
            prefixBlocks += OrbNativeMarkdownView.parseBlocks(chunk)
            commitUTF8 = newCommitUTF8
        } else {
            commitEndIdx = commitStartIdx
        }

        if scanState.tick && openFenceStartUTF8 >= commitUTF8 && scanUTF8 - openFenceBodyStartUTF8 >= Self.openFenceStreamThreshold {
            let trailingSub = Substring(utf8[cursorIdx...])
            if !trailingSub.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var deltaBytes = advance
                let preBlocks: [OrbNativeMarkdownView.Block]
                if let cachedPre = openFencePrefixBlocks {
                    preBlocks = cachedPre
                } else {
                    let fenceIdx = utf8.index(utf8.startIndex, offsetBy: openFenceStartUTF8)
                    let preSlice = String(Substring(utf8[commitEndIdx..<fenceIdx]))
                    deltaBytes += preSlice.utf8.count
                    let parsedPre = preSlice.isEmpty ? [] : OrbNativeMarkdownView.parseBlocks(preSlice)
                    openFencePrefixBlocks = parsedPre
                    preBlocks = parsedPre
                }
                var bodyIdx = utf8.index(utf8.startIndex, offsetBy: openFenceBodyCursorUTF8)
                while let nlIdx = utf8[bodyIdx...].firstIndex(of: UInt8(ascii: "\n")) {
                    let rawLine = Substring(utf8[bodyIdx..<nlIdx])
                    let rawLen = rawLine.utf8.count
                    openFenceBodyCursorUTF8 += rawLen + 1
                    deltaBytes += rawLen + 1
                    if openFenceHasLines { openFenceAcc.append("\n") }
                    openFenceAcc.append(contentsOf: rawLine)
                    openFenceHasLines = true
                    bodyIdx = utf8.index(after: nlIdx)
                }
                let totalUTF8 = utf8.count
                let openCode: String
                if openFenceBodyCursorUTF8 == totalUTF8 && openFenceBodyCursorUTF8 > openFenceBodyStartUTF8 {
                    openCode = openFenceAcc + "\n"
                } else if openFenceBodyCursorUTF8 < totalUTF8 {
                    let trailStr = String(trailingSub)
                    deltaBytes += trailStr.utf8.count
                    openCode = openFenceHasLines ? openFenceAcc + "\n" + trailStr : trailStr
                } else {
                    openCode = ""
                }
                parsedBytes = OrbKernel.streamTokenCostStep(prevCost: parsedBytes, newAdvance: deltaBytes, tailBytes: 0)
                let openBlock: OrbNativeMarkdownView.Block = openFenceLang.lowercased() == "mermaid"
                    ? .mermaid(code: openCode, complete: false)
                    : .code(language: openFenceLang, code: openCode)
                return prefixBlocks + preBlocks + [openBlock]
            }
        }

        let tail = String(Substring(utf8[commitEndIdx...]))
        parsedBytes = OrbKernel.streamTokenCostStep(prevCost: parsedBytes, newAdvance: advance, tailBytes: tail.utf8.count)
        return prefixBlocks + OrbNativeMarkdownView.parseBlocks(tail)
    }
}

/// Orb.Stream §4: a parse cache keyed by the text itself (no hash collisions), bounded, and
/// evicting only its least recently used entry (never everything at once, which re-parsed the
/// whole transcript after each long reply). A hit moves the key to the front.
@MainActor
final class OrbTextCache<Value> {
    let capacity: Int
    private var entries: [String: (value: Value, stamp: Int)] = [:]
    private var clock = 0
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { entries.count }
    /// Keys, most recently used first (the Lean model's order).
    var keys: [String] { entries.sorted { $0.value.stamp > $1.value.stamp }.map(\.key) }

    func get(_ key: String) -> Value? {
        guard let entry = entries[key] else { misses += 1; return nil }
        hits += 1
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    func put(_ key: String, _ value: Value) {
        clock += 1
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            entries[oldest] = nil
        }
        entries[key] = (value, clock)
    }

    /// Memory warning only: an explicit event, not a capacity policy.
    func removeAll() { entries.removeAll() }
}

extension OrbNativeMarkdownView {
    /// The reply being streamed.
    @MainActor static let streamParser = OrbStreamBlocks()

    @MainActor static func streamingBlocks(_ source: String) -> [Block] { streamParser.blocks(source) }
}

/// The streaming bubble. The only view that reads `OrbLiveText.text`, so a frame of deltas
/// re-renders this bubble, not the conversation screen around it.
struct OrbLiveReply: View {
    let live: OrbLiveText
    /// The last stored assistant answers: live text they already hold is not shown twice.
    let stored: [String]
    let onArtifact: (String) -> Void

    var body: some View {
        #if DEBUG
        let _ = OrbRenderProbe.hit("liveReply")
        #endif
        let text = OrbSendFlow.dedupeLiveText(live.text, stored: stored)
        if !text.isEmpty {
            OrbMessageWithFiles(text: text, streaming: true, onArtifact: onArtifact)
        }
    }
}

#if DEBUG
/// Counts view body evaluations in tests (which views a stream re-renders).
@MainActor enum OrbRenderProbe {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
}
#endif
