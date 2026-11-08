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
        var scalarCount: Int = 0
        var revision: Int = -1
        var finalized: Bool = false

        init(id: String, text: String, revision: Int = -1, finalized: Bool = false) {
            self.id = id
            self.text = text
            self.scalarCount = text.unicodeScalars.count
            self.revision = revision
            self.finalized = finalized
        }
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
                let piece = (op["text"] as? String) ?? ""
                bubble.text = piece
                bubble.scalarCount = piece.unicodeScalars.count
                bubble.finalized = false
            case "insert":
                let piece = (op["text"] as? String) ?? ""
                let pos = Self.intValue(op["pos"])
                if bubbleID == "text_delta_latest" && pos == 0 {
                    bubble.text = piece
                    bubble.scalarCount = piece.unicodeScalars.count
                } else if pos == nil || pos! >= bubble.scalarCount {
                    bubble.text += piece
                    bubble.scalarCount += piece.unicodeScalars.count
                } else {
                    bubble.text = Self.spliceScalars(bubble.text, start: pos, end: pos, replacement: piece)
                    bubble.scalarCount = bubble.text.unicodeScalars.count
                }
                bubble.finalized = false
            case "replace":
                let piece = (op["text"] as? String) ?? ""
                let range = Self.intList(op["range"])
                if bubbleID == "text_delta_latest" && (range?.first ?? 0) == 0 {
                    bubble.text = piece
                    bubble.scalarCount = piece.unicodeScalars.count
                } else if let range, range.count >= 2 {
                    bubble.text = Self.spliceScalars(bubble.text, start: range[0], end: range[1], replacement: piece)
                    bubble.scalarCount = bubble.text.unicodeScalars.count
                } else {
                    bubble.text = piece
                    bubble.scalarCount = piece.unicodeScalars.count
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
        bubble.scalarCount += delta.unicodeScalars.count
        bubble.finalized = false
        upsertBubble(bubble)
    }

    private mutating func setBubble(id: String, text: String) {
        var bubble = bubbles.first(where: { $0.id == id }) ?? Bubble(id: id, text: "")
        bubble.text = text
        bubble.scalarCount = text.unicodeScalars.count
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

    static func classify<S: StringProtocol>(_ raw: S, inFence: Bool = false) -> Line {
        let rest = raw.drop(while: { $0 == " " || $0 == "\t" })
        var marker: Marker?
        if let c = rest.first, c == "`" || c == "~" {
            let n = rest.prefix(while: { $0 == c }).count
            if n >= 3 { marker = Marker(backtick: c == "`", count: n) }
        }
        // The parser's own trimming decides blank and fence lines.
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if !inFence && !trimmed.hasPrefix("```") && OrbCodeFences.splitGlued(raw) != nil {
            return Line(blank: false, tick: true, marker: Marker(backtick: true, count: 3))
        }
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
            state.scan(classify(line, inFence: state.tick))
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
    static let defaultMaxOpenTailBytes = 16_384
    private static let openFenceStreamThreshold = 4096

    let maxOpenTailBytes: Int
    private var previous = ""
    private var prevUTF8 = 0
    private var commitUTF8 = 0
    private var scanUTF8 = 0
    private var checkpointUTF8 = 0
    private(set) var openFenceCapped = false
    private var scanState = OrbStreamCommit()
    private var prefixBlocks: [OrbNativeMarkdownView.Block] = []

    private var openFenceStartUTF8 = -1
    private var openFenceBodyStartUTF8 = 0
    private var openFenceBodyCursorUTF8 = 0
    private var openFenceLang = ""
    private var openFencePrefixBlocks: [OrbNativeMarkdownView.Block]?
    private var openFenceAcc = ""
    private var openFenceHasLines = false

    private static let capOpenNone = 0
    private static let capOpenMath = 1
    private static let capOpenQuote = 2
    private static let capOpenUnorderedList = 3
    private static let capOpenOrderedList = 4
    private static let capOpenTable = 5
    private static let capOpenCode = 6
    private static let capOpenLoosePipe = 7

    private var capCursorUTF8 = 0
    private var capInTildeFence = false
    private var capTildeCount = 0
    private var capPrefixBlocks: [OrbNativeMarkdownView.Block]?
    private var capParaAcc = ""
    private var capParaHasLines = false
    private var capOpenKind = 0
    private var capOpenCodeLang = ""
    private var capOpenCodeAcc = ""
    private var capOpenCodeHasLines = false
    private var capOpenMathDelim = ""
    private var capOpenMathAcc = ""
    private var capOpenMathHasLines = false
    private var capOpenQuoteAcc = ""
    private var capOpenListItems: [String] = []
    private var capOpenTableRows: [[String]] = []
    private var capOpenLooseRawLines: [String] = []
    private var capOpenLooseCells: [[String]] = []
    private var capOpenLooseExpectedCols = 0

    /// UTF-8 bytes scanned by the checkpointed commit scanner (`Orb.Stream.CheckpointedScan`).
    private(set) var scannedBytes = 0
    /// UTF-8 bytes handed to `parseBlocks` so far (`incCost`; checked against stream-cost.json).
    private(set) var parsedBytes = 0

    init(maxOpenTailBytes: Int = OrbStreamBlocks.defaultMaxOpenTailBytes) {
        self.maxOpenTailBytes = max(1, maxOpenTailBytes)
    }

    private func resetOpenFence() {
        openFenceStartUTF8 = -1
        openFencePrefixBlocks = nil
        openFenceAcc.removeAll(keepingCapacity: true)
        openFenceHasLines = false
    }

    private func clearCapOpenBlock() {
        capOpenKind = Self.capOpenNone
        capOpenCodeLang = ""
        capOpenCodeAcc.removeAll(keepingCapacity: true)
        capOpenCodeHasLines = false
        capOpenMathDelim = ""
        capOpenMathAcc.removeAll(keepingCapacity: true)
        capOpenMathHasLines = false
        capOpenQuoteAcc.removeAll(keepingCapacity: true)
        capOpenListItems.removeAll(keepingCapacity: true)
        capOpenTableRows.removeAll(keepingCapacity: true)
        capOpenLooseRawLines.removeAll(keepingCapacity: true)
        capOpenLooseCells.removeAll(keepingCapacity: true)
        capOpenLooseExpectedCols = 0
    }

    private func resetCapState() {
        capCursorUTF8 = commitUTF8
        capInTildeFence = false
        capTildeCount = 0
        capPrefixBlocks = nil
        capParaAcc.removeAll(keepingCapacity: true)
        capParaHasLines = false
        clearCapOpenBlock()
    }

    private func updateTildeFence<S: StringProtocol>(_ rawLine: S) {
        guard let tCount = Self.tildeMarkerCount(rawLine) else { return }
        if capInTildeFence && tCount >= capTildeCount {
            capInTildeFence = false
            capTildeCount = 0
        } else if !capInTildeFence {
            capInTildeFence = true
            capTildeCount = tCount
        }
    }

    private static func isOrderedItem(_ trimmed: String) -> Bool {
        guard let dotIdx = trimmed.firstIndex(of: "."),
              !trimmed[..<dotIdx].isEmpty,
              trimmed[..<dotIdx].allSatisfy(\.isNumber),
              trimmed.index(after: dotIdx) < trimmed.endIndex,
              trimmed[trimmed.index(after: dotIdx)] == " " else { return false }
        return true
    }

    private static func isHeading(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("#") else { return false }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        return hashes >= 1 && hashes <= 4 && trimmed.dropFirst(hashes).first == " "
    }

    private static func breaksParagraph(_ trimmed: String) -> Bool {
        trimmed.isEmpty ||
            trimmed.hasPrefix("```") ||
            trimmed.hasPrefix("#") ||
            trimmed.hasPrefix("- ") ||
            trimmed.hasPrefix("* ") ||
            trimmed.hasPrefix("> ") ||
            OrbNativeMarkdownView.isBlockTableRow(trimmed) ||
            OrbNativeMarkdownView.isBlockDisplayMathStart(trimmed) ||
            OrbNativeMarkdownView.isBlockStandaloneImage(trimmed)
    }

    private static func tildeMarkerCount<S: StringProtocol>(_ raw: S) -> Int? {
        let rest = raw.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "~" else { return nil }
        let n = rest.prefix(while: { $0 == "~" }).count
        return n >= 3 ? n : nil
    }

    private static func parseCapTableCells(_ trimmed: String) -> [String] {
        let inner = Array(trimmed.dropFirst().dropLast())
        var cells: [String] = []
        var cur = ""
        var i = 0
        while i < inner.count {
            if inner[i] == "\\" && i + 1 < inner.count && inner[i + 1] == "|" {
                cur.append("|")
                i += 2
                continue
            }
            if inner[i] == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            cur.append(inner[i])
            i += 1
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isCapTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty && cell.contains("-")
        }
    }

    private static func buildTableBlock(_ rawRows: [[String]]) -> OrbNativeMarkdownView.Block {
        if rawRows.count >= 2 && isCapTableSeparator(rawRows[1]) {
            let right = rawRows[1].map {
                let c = $0.trimmingCharacters(in: .whitespaces)
                return c.hasSuffix(":") && !c.hasPrefix(":")
            }
            return .table(headers: rawRows[0], rows: Array(rawRows.dropFirst(2)), rightAligned: right)
        }
        return .table(headers: rawRows[0], rows: Array(rawRows.dropFirst(1)))
    }

    private static func isLoosePipeGfm(_ rows: [[String]]) -> Bool {
        rows.count >= 2 && rows[1].allSatisfy {
            $0.filter { !$0.isWhitespace }.range(of: "^:?-+:?$", options: .regularExpression) != nil
        }
    }

    private static func buildLoosePipeTableBlock(_ rows: [[String]]) -> OrbNativeMarkdownView.Block {
        let width = rows[0].count
        let hasHeader = !rows[0].contains { !$0.isEmpty && OrbPipeTables.isNumericCell($0) }
        let head = hasHeader ? rows[0] : Array(repeating: "", count: width)
        let body = hasHeader ? Array(rows.dropFirst()) : rows
        let right = (0..<width).map { col -> Bool in
            let cells = body.map { col < $0.count ? $0[col] : "" }.filter { !$0.isEmpty }
            return !cells.isEmpty && cells.allSatisfy(OrbPipeTables.isNumericCell)
        }
        let paddedBody = body.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
        return .table(headers: head, rows: paddedBody, rightAligned: right)
    }

    private static func buildCodeOrMermaidBlock(lang: String, code: String, closed: Bool) -> OrbNativeMarkdownView.Block {
        if lang.lowercased() == "mermaid" {
            return .mermaid(code: code, complete: closed)
        }
        return .code(language: lang, code: code)
    }

    func blocks(_ source: String) -> [OrbNativeMarkdownView.Block] {
        if !source.hasPrefix(previous) {
            prevUTF8 = 0
            commitUTF8 = 0
            scanUTF8 = 0
            checkpointUTF8 = 0
            openFenceCapped = false
            scanState = OrbStreamCommit()
            prefixBlocks = []
            resetOpenFence()
            resetCapState()
        }
        let priorLen = prevUTF8
        let priorCommit = commitUTF8
        let priorCheckpoint = max(priorCommit, min(checkpointUTF8, priorLen))
        previous = source

        let utf8 = source.utf8
        let totalUTF8 = utf8.count
        prevUTF8 = totalUTF8
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
            let glued = wasTick ? nil : OrbCodeFences.splitGlued(lineSub)
            let beforeCommit = scanState.commit
            if glued != nil {
                scanState.scan(OrbStreamCommit.Line(blank: false, tick: true, marker: OrbStreamCommit.Marker(backtick: true, count: 3)))
            } else {
                scanState.scan(OrbStreamCommit.classify(lineSub, inFence: true))
            }
            if scanState.commit != beforeCommit {
                newCommitUTF8 = scanUTF8
                resetOpenFence()
            } else if !wasTick && scanState.tick {
                if let glued {
                    openFenceStartUTF8 = lineStartUTF8 + glued.utf8Offset
                    openFenceLang = glued.lang
                } else {
                    openFenceStartUTF8 = lineStartUTF8
                    let trimmed = lineSub.trimmingCharacters(in: .whitespaces)
                    openFenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                openFenceBodyStartUTF8 = scanUTF8
                openFenceBodyCursorUTF8 = scanUTF8
                openFencePrefixBlocks = nil
                openFenceAcc.removeAll(keepingCapacity: true)
                openFenceHasLines = false
            } else if wasTick && !scanState.tick {
                resetOpenFence()
            }
        }

        let openFenceActive = scanState.tick || scanState.fence != nil
        let capVerdict = OrbKernel.streamOpenTailCapStep(
            prevLen: UInt32(clamping: priorLen),
            prevCommit: UInt32(clamping: priorCommit),
            prevCheckpoint: UInt32(clamping: priorCheckpoint),
            newLen: UInt32(clamping: totalUTF8),
            rawCommit: UInt32(clamping: newCommitUTF8),
            maxOpenTailBytes: UInt32(clamping: maxOpenTailBytes),
            openFenceActive: openFenceActive
        )
        let boundedCheckpoint = capVerdict.admitted
            ? min(totalUTF8, max(newCommitUTF8, Int(capVerdict.nextCheckpoint)))
            : newCommitUTF8
        checkpointUTF8 = boundedCheckpoint
        openFenceCapped = capVerdict.admitted && capVerdict.openFenceCapped

        let commitStartIdx = utf8.index(utf8.startIndex, offsetBy: commitUTF8)
        let advance = newCommitUTF8 - commitUTF8
        let commitEndIdx: String.UTF8View.Index
        if advance > 0 {
            commitEndIdx = utf8.index(commitStartIdx, offsetBy: advance)
            let chunk = String(Substring(utf8[commitStartIdx..<commitEndIdx]))
            prefixBlocks += OrbNativeMarkdownView.parseBlocks(chunk)
            commitUTF8 = newCommitUTF8
            resetCapState()
        } else {
            commitEndIdx = commitStartIdx
        }

        if scanState.tick && openFenceStartUTF8 >= commitUTF8 &&
            (scanUTF8 - openFenceBodyStartUTF8 >= Self.openFenceStreamThreshold ||
                (capVerdict.admitted && capVerdict.checkpointForced)) {
            let trailingSub = Substring(utf8[cursorIdx...])
            if !trailingSub.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var deltaBytes = advance
                let preBlocks: [OrbNativeMarkdownView.Block]
                if let cachedPre = openFencePrefixBlocks {
                    preBlocks = cachedPre
                } else if capPrefixBlocks != nil || capParaHasLines || capOpenKind != Self.capOpenNone || capCursorUTF8 > commitUTF8 {
                    let built = buildCapBlocksUpTo(source: source, utf8: utf8, commitEndIdx: commitEndIdx, targetUTF8: openFenceStartUTF8) { deltaBytes += $0 }
                    resetCapState()
                    openFencePrefixBlocks = built
                    preBlocks = built
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
                let openBlock = Self.buildCodeOrMermaidBlock(lang: openFenceLang, code: openCode, closed: false)
                return prefixBlocks + preBlocks + [openBlock]
            }
        }

        if !scanState.tick && capVerdict.admitted && capVerdict.checkpointForced {
            var capDelta = 0
            let bufUTF16Len = source.utf16.count
            func ensureCapPrefix() {
                guard capPrefixBlocks == nil else { return }
                let toIdx = utf8.index(utf8.startIndex, offsetBy: capCursorUTF8)
                let slice = String(Substring(utf8[commitEndIdx..<toIdx]))
                capDelta += slice.utf8.count
                capPrefixBlocks = slice.isEmpty ? [] : OrbNativeMarkdownView.parseBlocks(slice)
                if !slice.isEmpty {
                    for sLine in slice.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                        updateTildeFence(sLine)
                    }
                }
            }
            func flushCapPara() {
                guard capParaHasLines else { return }
                ensureCapPrefix()
                capPrefixBlocks?.append(.paragraph(capParaAcc))
                capParaAcc.removeAll(keepingCapacity: true)
                capParaHasLines = false
            }
            func flushCapOpenBlock(mathClosed: Bool = false) {
                switch capOpenKind {
                case Self.capOpenCode:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(Self.buildCodeOrMermaidBlock(lang: capOpenCodeLang, code: capOpenCodeAcc, closed: mathClosed))
                case Self.capOpenMath:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(.math(latex: capOpenMathAcc.trimmingCharacters(in: .whitespacesAndNewlines), complete: mathClosed))
                case Self.capOpenQuote:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(.quote(capOpenQuoteAcc))
                case Self.capOpenUnorderedList:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(.list(ordered: false, items: capOpenListItems))
                case Self.capOpenOrderedList:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(.list(ordered: true, items: capOpenListItems))
                case Self.capOpenTable:
                    ensureCapPrefix()
                    capPrefixBlocks?.append(Self.buildTableBlock(capOpenTableRows))
                case Self.capOpenLoosePipe:
                    if capOpenLooseCells.count < 2 || Self.isLoosePipeGfm(capOpenLooseCells) {
                        ensureCapPrefix()
                        let fallbackLines = capOpenLooseRawLines
                        clearCapOpenBlock()
                        for raw in fallbackLines {
                            if capOpenKind == Self.capOpenMath {
                                let rt = raw.trimmingCharacters(in: .whitespaces)
                                if let closeRange = rt.range(of: capOpenMathDelim) {
                                    let before = String(rt[..<closeRange.lowerBound])
                                    if !before.isEmpty {
                                        if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                                        capOpenMathAcc.append(before)
                                        capOpenMathHasLines = true
                                    }
                                    capPrefixBlocks?.append(.math(latex: capOpenMathAcc.trimmingCharacters(in: .whitespacesAndNewlines), complete: true))
                                    clearCapOpenBlock()
                                } else {
                                    if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                                    capOpenMathAcc.append(raw)
                                    capOpenMathHasLines = true
                                }
                                continue
                            }
                            let rt = raw.trimmingCharacters(in: .whitespaces)
                            if (rt == "---" || rt == "***") && !capParaHasLines {
                                capPrefixBlocks?.append(.divider)
                            } else if OrbNativeMarkdownView.isBlockStandaloneImage(rt) {
                                flushCapPara()
                                capDelta += raw.utf8.count + 1
                                capPrefixBlocks?.append(contentsOf: OrbNativeMarkdownView.parseBlocks(raw))
                            } else if OrbNativeMarkdownView.isBlockDisplayMathStart(rt) {
                                flushCapPara()
                                let openDelim = rt.hasPrefix("$$") ? "$$" : "\\["
                                let closeDelim = openDelim == "$$" ? "$$" : "\\]"
                                let afterOpen = String(rt.dropFirst(openDelim.count))
                                if afterOpen.contains(closeDelim) {
                                    capDelta += raw.utf8.count + 1
                                    capPrefixBlocks?.append(contentsOf: OrbNativeMarkdownView.parseBlocks(raw))
                                } else {
                                    capOpenKind = Self.capOpenMath
                                    capOpenMathDelim = closeDelim
                                    if !afterOpen.isEmpty {
                                        capOpenMathAcc = afterOpen
                                        capOpenMathHasLines = true
                                    }
                                }
                            } else {
                                if capParaHasLines { capParaAcc.append("\n") }
                                capParaAcc.append(raw)
                                capParaHasLines = true
                            }
                        }
                        return
                    } else {
                        flushCapPara()
                        ensureCapPrefix()
                        capPrefixBlocks?.append(Self.buildLoosePipeTableBlock(capOpenLooseCells))
                    }
                default:
                    break
                }
                clearCapOpenBlock()
            }
            func loosePipeAdmitted(lineStartIdx: String.UTF8View.Index, lineStr: String, cells: [String], expectedCols: Int) -> Bool {
                let lineUTF16Off = source.utf16.distance(from: source.utf16.startIndex, to: lineStartIdx)
                let leadUTF16 = lineStr.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                let rowUTF16 = lineStr.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
                return OrbKernel.gfmPipeRowAdmitted(
                    rowOff: lineUTF16Off + leadUTF16,
                    rowLen: rowUTF16,
                    bufLen: bufUTF16Len,
                    colCount: cells.count,
                    sepCols: expectedCols
                )
            }

            while capCursorUTF8 < boundedCheckpoint {
                let lineStartIdx = utf8.index(utf8.startIndex, offsetBy: capCursorUTF8)
                guard let nlIdx = utf8[lineStartIdx...].firstIndex(of: UInt8(ascii: "\n")),
                      nlIdx < cursorIdx else {
                    break
                }
                let lineSub = Substring(utf8[lineStartIdx..<nlIdx])
                let lineStr = String(lineSub)
                let lineBytes = lineSub.utf8.count + 1
                let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

                if capOpenKind != Self.capOpenNone {
                    switch capOpenKind {
                    case Self.capOpenCode:
                        if trimmed.hasPrefix("```") {
                            flushCapOpenBlock(mathClosed: true)
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        if capOpenCodeHasLines { capOpenCodeAcc.append("\n") }
                        capOpenCodeAcc.append(lineStr)
                        capOpenCodeHasLines = true
                        capCursorUTF8 += lineBytes
                        continue
                    case Self.capOpenMath:
                        if trimmed.isEmpty || trimmed.hasPrefix("```") {
                            flushCapOpenBlock(mathClosed: false)
                            continue
                        }
                        if let gluedInMath = OrbCodeFences.splitGlued(lineSub) {
                            let splitIdx = lineStr.utf8.index(lineStr.utf8.startIndex, offsetBy: gluedInMath.utf8Offset)
                            let prose = String(Substring(lineStr.utf8[..<splitIdx]))
                            let proseTrim = prose.trimmingCharacters(in: .whitespaces)
                            if let pClose = proseTrim.range(of: capOpenMathDelim) {
                                let before = String(proseTrim[..<pClose.lowerBound])
                                if !before.isEmpty {
                                    if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                                    capOpenMathAcc.append(before)
                                }
                                flushCapOpenBlock(mathClosed: true)
                            } else {
                                if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                                capOpenMathAcc.append(prose)
                                flushCapOpenBlock(mathClosed: false)
                            }
                            capOpenKind = Self.capOpenCode
                            capOpenCodeLang = String(Substring(lineStr.utf8[splitIdx...])).trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                            capOpenCodeAcc.removeAll(keepingCapacity: true)
                            capOpenCodeHasLines = false
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        if let closeRange = trimmed.range(of: capOpenMathDelim) {
                            let before = String(trimmed[..<closeRange.lowerBound])
                            if !before.isEmpty {
                                if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                                capOpenMathAcc.append(before)
                                capOpenMathHasLines = true
                            }
                            flushCapOpenBlock(mathClosed: true)
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        if capOpenMathHasLines { capOpenMathAcc.append("\n") }
                        capOpenMathAcc.append(lineStr)
                        capOpenMathHasLines = true
                        capCursorUTF8 += lineBytes
                        continue
                    case Self.capOpenQuote:
                        if trimmed.hasPrefix("> ") {
                            capOpenQuoteAcc.append("\n")
                            capOpenQuoteAcc.append(contentsOf: trimmed.dropFirst(2))
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        if trimmed == ">" {
                            capOpenQuoteAcc.append("\n")
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        flushCapOpenBlock()
                        continue
                    case Self.capOpenUnorderedList:
                        let gluedInList = OrbCodeFences.splitGlued(lineSub)
                        if gluedInList == nil && (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")) {
                            capOpenListItems.append(String(trimmed.dropFirst(2)))
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        if let gluedInList {
                            let splitIdx = lineStr.utf8.index(lineStr.utf8.startIndex, offsetBy: gluedInList.utf8Offset)
                            let pt = String(Substring(lineStr.utf8[..<splitIdx])).trimmingCharacters(in: .whitespaces)
                            if pt.hasPrefix("- ") || pt.hasPrefix("* ") {
                                capOpenListItems.append(String(pt.dropFirst(2)))
                                flushCapOpenBlock()
                                capOpenKind = Self.capOpenCode
                                capOpenCodeLang = String(Substring(lineStr.utf8[splitIdx...])).trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                                capOpenCodeAcc.removeAll(keepingCapacity: true)
                                capOpenCodeHasLines = false
                                capCursorUTF8 += lineBytes
                                continue
                            }
                        }
                        flushCapOpenBlock()
                        continue
                    case Self.capOpenOrderedList:
                        let gluedInOrd = OrbCodeFences.splitGlued(lineSub)
                        if gluedInOrd == nil {
                            if Self.isOrderedItem(trimmed), let d = trimmed.firstIndex(of: ".") {
                                let start = trimmed.index(d, offsetBy: 2)
                                capOpenListItems.append(String(trimmed[start...]))
                                capCursorUTF8 += lineBytes
                                continue
                            }
                        } else if let gluedInOrd {
                            let splitIdx = lineStr.utf8.index(lineStr.utf8.startIndex, offsetBy: gluedInOrd.utf8Offset)
                            let pt = String(Substring(lineStr.utf8[..<splitIdx])).trimmingCharacters(in: .whitespaces)
                            if Self.isOrderedItem(pt), let d = pt.firstIndex(of: ".") {
                                let start = pt.index(d, offsetBy: 2)
                                capOpenListItems.append(String(pt[start...]))
                                flushCapOpenBlock()
                                capOpenKind = Self.capOpenCode
                                capOpenCodeLang = String(Substring(lineStr.utf8[splitIdx...])).trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                                capOpenCodeAcc.removeAll(keepingCapacity: true)
                                capOpenCodeHasLines = false
                                capCursorUTF8 += lineBytes
                                continue
                            }
                        }
                        flushCapOpenBlock()
                        continue
                    case Self.capOpenTable:
                        if let gluedInTable = OrbCodeFences.splitGlued(lineSub) {
                            let splitIdx = lineStr.utf8.index(lineStr.utf8.startIndex, offsetBy: gluedInTable.utf8Offset)
                            let pt = String(Substring(lineStr.utf8[..<splitIdx])).trimmingCharacters(in: .whitespaces)
                            if OrbNativeMarkdownView.isBlockTableRow(pt) {
                                capOpenTableRows.append(Self.parseCapTableCells(pt))
                                flushCapOpenBlock()
                                capOpenKind = Self.capOpenCode
                                capOpenCodeLang = String(Substring(lineStr.utf8[splitIdx...])).trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                                capOpenCodeAcc.removeAll(keepingCapacity: true)
                                capOpenCodeHasLines = false
                                capCursorUTF8 += lineBytes
                                continue
                            }
                        } else if OrbNativeMarkdownView.isBlockTableRow(trimmed) {
                            capOpenTableRows.append(Self.parseCapTableCells(trimmed))
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        flushCapOpenBlock()
                        continue
                    case Self.capOpenLoosePipe:
                        if Self.tildeMarkerCount(lineSub) == nil && !trimmed.hasPrefix("```") && OrbCodeFences.splitGlued(lineSub) == nil,
                           let c = OrbPipeTables.cells(lineStr),
                           c.count == capOpenLooseExpectedCols,
                           loosePipeAdmitted(lineStartIdx: lineStartIdx, lineStr: lineStr, cells: c, expectedCols: capOpenLooseExpectedCols) {
                            capOpenLooseRawLines.append(lineStr)
                            capOpenLooseCells.append(c)
                            capCursorUTF8 += lineBytes
                            continue
                        }
                        flushCapOpenBlock()
                        continue
                    default:
                        break
                    }
                }

                if trimmed.isEmpty {
                    flushCapPara()
                    ensureCapPrefix()
                    capCursorUTF8 += lineBytes
                    continue
                }

                if trimmed.hasPrefix("```") {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = Self.capOpenCode
                    capOpenCodeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    capOpenCodeAcc.removeAll(keepingCapacity: true)
                    capOpenCodeHasLines = false
                    capCursorUTF8 += lineBytes
                    continue
                }

                if let glued = OrbCodeFences.splitGlued(lineSub) {
                    let splitIdx = lineStr.utf8.index(lineStr.utf8.startIndex, offsetBy: glued.utf8Offset)
                    let prose = String(Substring(lineStr.utf8[..<splitIdx]))
                    let proseTrim = prose.trimmingCharacters(in: .whitespaces)
                    let fenceLine = String(Substring(lineStr.utf8[splitIdx...])).trimmingCharacters(in: .whitespaces)
                    ensureCapPrefix()
                    if capParaHasLines && !Self.breaksParagraph(proseTrim) {
                        capParaAcc.append("\n")
                        capParaAcc.append(prose)
                        flushCapPara()
                    } else if capParaHasLines && proseTrim.hasPrefix("#") && !Self.isHeading(proseTrim) {
                        flushCapPara()
                    } else {
                        flushCapPara()
                        capDelta += prose.utf8.count
                        capPrefixBlocks?.append(contentsOf: OrbNativeMarkdownView.parseBlocks(prose))
                        updateTildeFence(prose)
                    }
                    capOpenKind = Self.capOpenCode
                    capOpenCodeLang = String(fenceLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    capOpenCodeAcc.removeAll(keepingCapacity: true)
                    capOpenCodeHasLines = false
                    capCursorUTF8 += lineBytes
                    continue
                }

                let tMarker = Self.tildeMarkerCount(lineSub)
                if !capInTildeFence && tMarker == nil &&
                   !OrbNativeMarkdownView.isBlockDisplayMathStart(trimmed) &&
                   !OrbNativeMarkdownView.isBlockStandaloneImage(trimmed),
                   let looseFirst = OrbPipeTables.cells(lineStr),
                   loosePipeAdmitted(lineStartIdx: lineStartIdx, lineStr: lineStr, cells: looseFirst, expectedCols: looseFirst.count) {
                    ensureCapPrefix()
                    capOpenKind = Self.capOpenLoosePipe
                    capOpenLooseRawLines.removeAll(keepingCapacity: true)
                    capOpenLooseCells.removeAll(keepingCapacity: true)
                    capOpenLooseRawLines.append(lineStr)
                    capOpenLooseCells.append(looseFirst)
                    capOpenLooseExpectedCols = looseFirst.count
                    capCursorUTF8 += lineBytes
                    continue
                }

                if (trimmed == "---" || trimmed == "***") && !capParaHasLines {
                    ensureCapPrefix()
                    capPrefixBlocks?.append(.divider)
                    capCursorUTF8 += lineBytes
                    continue
                }

                if trimmed.hasPrefix("#") {
                    flushCapPara()
                    ensureCapPrefix()
                    if Self.isHeading(trimmed) {
                        let hashes = trimmed.prefix(while: { $0 == "#" }).count
                        capPrefixBlocks?.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                    }
                    capCursorUTF8 += lineBytes
                    continue
                }

                if OrbNativeMarkdownView.isBlockStandaloneImage(trimmed) {
                    flushCapPara()
                    ensureCapPrefix()
                    capDelta += lineBytes
                    capPrefixBlocks?.append(contentsOf: OrbNativeMarkdownView.parseBlocks(lineStr))
                    capCursorUTF8 += lineBytes
                    continue
                }

                if OrbNativeMarkdownView.isBlockDisplayMathStart(trimmed) {
                    flushCapPara()
                    ensureCapPrefix()
                    let openDelim = trimmed.hasPrefix("$$") ? "$$" : "\\["
                    let closeDelim = openDelim == "$$" ? "$$" : "\\]"
                    let afterOpen = String(trimmed.dropFirst(openDelim.count))
                    if afterOpen.contains(closeDelim) {
                        capDelta += lineBytes
                        capPrefixBlocks?.append(contentsOf: OrbNativeMarkdownView.parseBlocks(lineStr))
                        capCursorUTF8 += lineBytes
                        continue
                    }
                    capOpenKind = Self.capOpenMath
                    capOpenMathDelim = closeDelim
                    capOpenMathAcc.removeAll(keepingCapacity: true)
                    if !afterOpen.isEmpty {
                        capOpenMathAcc = afterOpen
                        capOpenMathHasLines = true
                    } else {
                        capOpenMathHasLines = false
                    }
                    capCursorUTF8 += lineBytes
                    continue
                }

                if OrbNativeMarkdownView.isBlockTableRow(trimmed) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = Self.capOpenTable
                    capOpenTableRows.removeAll(keepingCapacity: true)
                    capOpenTableRows.append(Self.parseCapTableCells(trimmed))
                    capCursorUTF8 += lineBytes
                    continue
                }

                if trimmed.hasPrefix("> ") || (trimmed == ">" && !capParaHasLines) {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = Self.capOpenQuote
                    capOpenQuoteAcc.removeAll(keepingCapacity: true)
                    if trimmed.hasPrefix("> ") {
                        capOpenQuoteAcc = String(trimmed.dropFirst(2))
                    }
                    capCursorUTF8 += lineBytes
                    continue
                }

                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    flushCapPara()
                    ensureCapPrefix()
                    capOpenKind = Self.capOpenUnorderedList
                    capOpenListItems.removeAll(keepingCapacity: true)
                    capOpenListItems.append(String(trimmed.dropFirst(2)))
                    capCursorUTF8 += lineBytes
                    continue
                }

                if !capParaHasLines && Self.isOrderedItem(trimmed), let d = trimmed.firstIndex(of: ".") {
                    ensureCapPrefix()
                    let start = trimmed.index(d, offsetBy: 2)
                    capOpenKind = Self.capOpenOrderedList
                    capOpenListItems.removeAll(keepingCapacity: true)
                    capOpenListItems.append(String(trimmed[start...]))
                    capCursorUTF8 += lineBytes
                    continue
                }

                updateTildeFence(lineSub)

                ensureCapPrefix()
                if capParaHasLines { capParaAcc.append("\n") }
                capParaAcc.append(lineStr)
                capParaHasLines = true
                capCursorUTF8 += lineBytes
            }

            if capParaHasLines || capOpenKind != Self.capOpenNone || capCursorUTF8 > commitUTF8 {
                ensureCapPrefix()
                let remStartIdx = utf8.index(utf8.startIndex, offsetBy: capCursorUTF8)
                let remRaw = String(Substring(utf8[remStartIdx...]))
                let remBytes = remRaw.utf8.count
                let mergedTail = mergeCapRemainder(remRaw: remRaw, source: source, remStartIdx: remStartIdx, bufUTF16Len: bufUTF16Len)
                parsedBytes = OrbKernel.streamTokenCostStep(prevCost: parsedBytes, newAdvance: advance + capDelta, tailBytes: remBytes)
                return prefixBlocks + (capPrefixBlocks ?? []) + mergedTail
            }
        } else if scanState.tick && (capParaHasLines || capOpenKind != Self.capOpenNone || capPrefixBlocks != nil) {
            resetCapState()
        }

        let tail = String(Substring(utf8[commitEndIdx...]))
        parsedBytes = OrbKernel.streamTokenCostStep(prevCost: parsedBytes, newAdvance: advance, tailBytes: tail.utf8.count)
        return prefixBlocks + OrbNativeMarkdownView.parseBlocks(tail)
    }

    private func buildCapBlocksUpTo(
        source: String,
        utf8: String.UTF8View,
        commitEndIdx: String.UTF8View.Index,
        targetUTF8: Int,
        onDeltaBytes: (Int) -> Void
    ) -> [OrbNativeMarkdownView.Block] {
        if capPrefixBlocks == nil {
            let toIdx = utf8.index(utf8.startIndex, offsetBy: capCursorUTF8)
            let slice = String(Substring(utf8[commitEndIdx..<toIdx]))
            onDeltaBytes(slice.utf8.count)
            capPrefixBlocks = slice.isEmpty ? [] : OrbNativeMarkdownView.parseBlocks(slice)
            if !slice.isEmpty {
                for sLine in slice.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                    updateTildeFence(sLine)
                }
            }
        }
        let remStartIdx = utf8.index(utf8.startIndex, offsetBy: capCursorUTF8)
        let remSlice: String
        if capCursorUTF8 < targetUTF8 {
            var endUTF8 = targetUTF8
            let endCheckIdx = utf8.index(utf8.startIndex, offsetBy: endUTF8)
            let prevIdx = utf8.index(before: endCheckIdx)
            if endUTF8 > capCursorUTF8 && utf8[prevIdx] == UInt8(ascii: "\n") {
                endUTF8 -= 1
            }
            let endIdx = utf8.index(utf8.startIndex, offsetBy: endUTF8)
            remSlice = String(Substring(utf8[remStartIdx..<endIdx]))
        } else {
            remSlice = ""
        }
        onDeltaBytes(remSlice.utf8.count)
        let merged = mergeCapRemainder(remRaw: remSlice, source: source, remStartIdx: remStartIdx, bufUTF16Len: source.utf16.count)
        return (capPrefixBlocks ?? []) + merged
    }

    private func parseCapTail(_ raw: String, inTildeFence: Bool, tildeCount: Int) -> [OrbNativeMarkdownView.Block] {
        if raw.isEmpty { return [] }
        if !inTildeFence {
            return OrbNativeMarkdownView.parseBlocks(raw)
        }
        let prefixFence = String(repeating: "~", count: max(3, tildeCount))
        var blocks = OrbNativeMarkdownView.parseBlocks(prefixFence + "\n" + raw)
        if case .paragraph(let p) = blocks.first {
            if p == prefixFence {
                blocks.removeFirst()
            } else if p.hasPrefix(prefixFence + "\n") {
                blocks[0] = .paragraph(String(p.dropFirst(prefixFence.count + 1)))
            }
        }
        return blocks
    }

    private func mergeCapRemainder(
        remRaw: String,
        source: String,
        remStartIdx: String.UTF8View.Index,
        bufUTF16Len: Int
    ) -> [OrbNativeMarkdownView.Block] {
        if capOpenKind == Self.capOpenLoosePipe {
            var cells = capOpenLooseCells
            var rawLines = capOpenLooseRawLines
            let remLines = remRaw.isEmpty
                ? []
                : remRaw.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var remUTF16Base = source.utf16.distance(from: source.utf16.startIndex, to: remStartIdx)
            var idx = 0
            while idx < remLines.count {
                let rLine = remLines[idx]
                let rt = rLine.trimmingCharacters(in: .whitespaces)
                if Self.tildeMarkerCount(rLine) != nil || rt.hasPrefix("```") || OrbCodeFences.splitGlued(rLine) != nil {
                    break
                }
                guard let c = OrbPipeTables.cells(rLine), c.count == capOpenLooseExpectedCols else { break }
                let leadUTF16 = rLine.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                let rowUTF16 = rLine.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
                guard OrbKernel.gfmPipeRowAdmitted(
                    rowOff: remUTF16Base + leadUTF16,
                    rowLen: rowUTF16,
                    bufLen: bufUTF16Len,
                    colCount: c.count,
                    sepCols: capOpenLooseExpectedCols
                ) else { break }
                rawLines.append(rLine)
                cells.append(c)
                remUTF16Base += rLine.utf16.count + 1
                idx += 1
            }
            if cells.count < 2 || Self.isLoosePipeGfm(cells) {
                let remTail = idx < remLines.count ? Array(remLines[idx...]) : []
                let combined = (rawLines + remTail).joined(separator: "\n")
                return mergeParagraphWithRaw(basePara: capParaHasLines ? capParaAcc : nil, raw: combined, inTildeFence: false, tildeCount: 0)
            }
            if idx == remLines.count - 1 && remLines[idx].contains(" |") {
                let t = remLines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                let partial = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if partial.count < capOpenLooseExpectedCols && !t.hasPrefix("|") {
                    cells.append(partial)
                    idx += 1
                }
            }
            var result: [OrbNativeMarkdownView.Block] = []
            if capParaHasLines {
                result.append(.paragraph(capParaAcc))
            }
            result.append(Self.buildLoosePipeTableBlock(cells))
            if idx < remLines.count {
                let restStr = remLines[idx...].joined(separator: "\n")
                result.append(contentsOf: parseCapTail(restStr, inTildeFence: false, tildeCount: 0))
            }
            return result
        }

        if capParaHasLines {
            return mergeParagraphWithRaw(basePara: capParaAcc, raw: remRaw, inTildeFence: capInTildeFence, tildeCount: capTildeCount)
        }

        if capOpenKind == Self.capOpenNone {
            return parseCapTail(remRaw, inTildeFence: capInTildeFence, tildeCount: capTildeCount)
        }

        if remRaw.isEmpty {
            return [materializeOpenBlock()]
        }

        let normRem: String
        if capOpenKind == Self.capOpenCode {
            normRem = remRaw
        } else {
            let cf = OrbCodeFences.normalize(remRaw)
            if capInTildeFence {
                normRem = cf
            } else {
                normRem = OrbPipeTables.normalize(cf)
            }
        }
        let remLines = normRem.components(separatedBy: "\n")
        var idx = 0
        var localInTilde = capInTildeFence
        var localTildeCount = capTildeCount

        switch capOpenKind {
        case Self.capOpenCode:
            var acc = capOpenCodeAcc
            var hasLines = capOpenCodeHasLines
            while idx < remLines.count && !remLines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if hasLines { acc.append("\n") }
                acc.append(remLines[idx])
                hasLines = true
                idx += 1
            }
            let closed = idx < remLines.count
            if closed { idx += 1 }
            let block = Self.buildCodeOrMermaidBlock(lang: capOpenCodeLang, code: acc, closed: closed)
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [block] + rest
        case Self.capOpenMath:
            var acc = capOpenMathAcc
            var hasLines = capOpenMathHasLines
            var closed = false
            while idx < remLines.count {
                let cur = remLines[idx]
                let curTrim = cur.trimmingCharacters(in: .whitespaces)
                if curTrim.isEmpty || curTrim.hasPrefix("```") { break }
                if let closeRange = curTrim.range(of: capOpenMathDelim) {
                    let before = String(curTrim[..<closeRange.lowerBound])
                    if !before.isEmpty {
                        if hasLines { acc.append("\n") }
                        acc.append(before)
                    }
                    closed = true
                    idx += 1
                    break
                }
                if hasLines { acc.append("\n") }
                acc.append(cur)
                hasLines = true
                idx += 1
            }
            let block: OrbNativeMarkdownView.Block = .math(latex: acc.trimmingCharacters(in: .whitespacesAndNewlines), complete: closed)
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [block] + rest
        case Self.capOpenQuote:
            var acc = capOpenQuoteAcc
            while idx < remLines.count {
                let t = remLines[idx].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("> ") {
                    acc.append("\n")
                    acc.append(contentsOf: t.dropFirst(2))
                    idx += 1
                } else if t == ">" {
                    acc.append("\n")
                    idx += 1
                } else {
                    break
                }
            }
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [.quote(acc)] + rest
        case Self.capOpenUnorderedList:
            var items = capOpenListItems
            while idx < remLines.count {
                let t = remLines[idx].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    items.append(String(t.dropFirst(2)))
                    idx += 1
                } else {
                    break
                }
            }
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [.list(ordered: false, items: items)] + rest
        case Self.capOpenOrderedList:
            var items = capOpenListItems
            while idx < remLines.count {
                let t = remLines[idx].trimmingCharacters(in: .whitespaces)
                if Self.isOrderedItem(t), let d = t.firstIndex(of: ".") {
                    let start = t.index(d, offsetBy: 2)
                    items.append(String(t[start...]))
                    idx += 1
                } else {
                    break
                }
            }
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [.list(ordered: true, items: items)] + rest
        case Self.capOpenTable:
            var rows = capOpenTableRows
            while idx < remLines.count {
                let t = remLines[idx].trimmingCharacters(in: .whitespaces)
                guard OrbNativeMarkdownView.isBlockTableRow(t) else { break }
                rows.append(Self.parseCapTableCells(t))
                idx += 1
            }
            let rest = idx < remLines.count ? parseCapTail(remLines[idx...].joined(separator: "\n"), inTildeFence: localInTilde, tildeCount: localTildeCount) : []
            return [Self.buildTableBlock(rows)] + rest
        default:
            return parseCapTail(remRaw, inTildeFence: localInTilde, tildeCount: localTildeCount)
        }
    }

    private func mergeParagraphWithRaw(
        basePara: String?,
        raw: String,
        inTildeFence: Bool,
        tildeCount: Int
    ) -> [OrbNativeMarkdownView.Block] {
        guard let basePara else {
            return parseCapTail(raw, inTildeFence: inTildeFence, tildeCount: tildeCount)
        }
        if raw.isEmpty {
            return [.paragraph(basePara)]
        }
        let codeNorm = OrbCodeFences.normalize(raw)
        let normStr: String
        if inTildeFence {
            let prefixFence = String(repeating: "~", count: max(3, tildeCount))
            let withFence = OrbPipeTables.normalize(prefixFence + "\n" + codeNorm)
            if withFence.hasPrefix(prefixFence + "\n") {
                normStr = String(withFence.dropFirst(prefixFence.count + 1))
            } else {
                normStr = codeNorm
            }
        } else {
            normStr = OrbPipeTables.normalize(codeNorm)
        }
        let remLines = normStr.components(separatedBy: "\n")
        var mergedPara = basePara
        var idx = 0
        var localInTilde = inTildeFence
        var localTildeCount = tildeCount
        while idx < remLines.count {
            let l = remLines[idx]
            let t = l.trimmingCharacters(in: .whitespaces)
            if Self.breaksParagraph(t) {
                if t.hasPrefix("#") && !Self.isHeading(t) { idx += 1 }
                break
            }
            if let tc = Self.tildeMarkerCount(l) {
                if localInTilde && tc >= localTildeCount {
                    localInTilde = false
                    localTildeCount = 0
                } else if !localInTilde {
                    localInTilde = true
                    localTildeCount = tc
                }
            }
            mergedPara.append("\n")
            mergedPara.append(l)
            idx += 1
        }
        let restBlocks: [OrbNativeMarkdownView.Block]
        if idx < remLines.count {
            let restStr = remLines[idx...].joined(separator: "\n")
            restBlocks = restStr.isEmpty ? [] : OrbNativeMarkdownView.parseBlocks(restStr)
        } else {
            restBlocks = []
        }
        return [.paragraph(mergedPara)] + restBlocks
    }

    private func materializeOpenBlock() -> OrbNativeMarkdownView.Block {
        switch capOpenKind {
        case Self.capOpenCode:
            return Self.buildCodeOrMermaidBlock(lang: capOpenCodeLang, code: capOpenCodeHasLines ? capOpenCodeAcc + "\n" : "", closed: false)
        case Self.capOpenMath:
            return .math(latex: capOpenMathAcc.trimmingCharacters(in: .whitespacesAndNewlines), complete: false)
        case Self.capOpenQuote:
            return .quote(capOpenQuoteAcc)
        case Self.capOpenUnorderedList:
            return .list(ordered: false, items: capOpenListItems)
        case Self.capOpenOrderedList:
            return .list(ordered: true, items: capOpenListItems)
        case Self.capOpenTable:
            return Self.buildTableBlock(capOpenTableRows)
        default:
            return .paragraph("")
        }
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
