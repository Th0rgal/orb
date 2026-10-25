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
        guard let open else { return m }
        if let m, m.backtick == open.backtick, open.count <= m.count { return nil }
        return open
    }

    mutating func scan(_ line: Line) {
        let nextTick = line.tick ? !tick : tick
        let nextFence = Self.nextFence(fence, line.marker)
        let commits = line.blank && !nextTick && nextFence == nil
        tick = nextTick; fence = nextFence; pos += 1
        if commits { commit = pos }
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
    private var prefix = ""
    private var prefixBlocks: [OrbNativeMarkdownView.Block] = []
    /// UTF-8 bytes handed to `parseBlocks` so far (`incCost`; checked against stream-cost.json).
    private(set) var parsedBytes = 0

    func blocks(_ source: String) -> [OrbNativeMarkdownView.Block] {
        if !source.hasPrefix(prefix) { prefix = ""; prefixBlocks = [] }
        let start = source.utf8.index(source.utf8.startIndex, offsetBy: prefix.utf8.count)
        let rest = Substring(source.utf8[start...])
        let advance = OrbStreamCommit.committedOffset(rest)
        let end = rest.utf8.index(rest.utf8.startIndex, offsetBy: advance)
        if advance > 0 {
            let chunk = String(Substring(rest.utf8[..<end]))
            prefixBlocks += OrbNativeMarkdownView.parseBlocks(chunk)
            prefix += chunk
        }
        let tail = String(Substring(rest.utf8[end...]))
        parsedBytes += advance + tail.utf8.count
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
