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
    /// One display frame at 60 Hz.
    @ObservationIgnored var frame: Duration = .milliseconds(16)

    /// Frames that changed `text` (the coalescer's render count).
    @ObservationIgnored private(set) var renders = 0
    /// Everything received, shown or not (the conservation law: `text + pending`).
    var received: String { text + pending }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pending += delta
        if !hasText { hasText = true }
        scheduleFrame()
    }

    /// `text_op` replace: the new text wins over anything pending.
    func replace(_ content: String) {
        pending = ""
        flushTask?.cancel(); flushTask = nil
        if text != content { text = content }
        if hasText != !content.isEmpty { hasText = !content.isEmpty }
    }

    func clear() { replace("") }

    /// Moves pending text to `text` now (one render), e.g. before reading it.
    func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !pending.isEmpty else { return }
        text += pending
        pending = ""
        renders += 1
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
