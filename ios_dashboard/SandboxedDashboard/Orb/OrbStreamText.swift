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

extension OrbNativeMarkdownView {
    /// The reply being streamed: blocks of its committed prefix, parsed once.
    @MainActor private static var streamPrefix = ""
    @MainActor private static var streamPrefixBlocks: [Block] = []

    /// `parseBlocks(source)` for text that grows by appending: the committed prefix is parsed
    /// once (Orb.Stream `resume_at_commit`), only the open tail on each update. Streaming text
    /// stays out of `cachedBlocks`, whose entries it would otherwise evict on every delta.
    @MainActor static func streamingBlocks(_ source: String) -> [Block] {
        if !source.hasPrefix(streamPrefix) {
            streamPrefix = ""; streamPrefixBlocks = []
        }
        let start = source.utf8.index(source.utf8.startIndex, offsetBy: streamPrefix.utf8.count)
        let rest = Substring(source.utf8[start...])
        let advance = OrbStreamCommit.committedOffset(rest)
        if advance > 0 {
            let end = rest.utf8.index(rest.utf8.startIndex, offsetBy: advance)
            let chunk = String(Substring(rest.utf8[..<end]))
            streamPrefixBlocks += parseBlocks(chunk)
            streamPrefix += chunk
            return streamPrefixBlocks + parseBlocks(String(Substring(rest.utf8[end...])))
        }
        return streamPrefixBlocks + parseBlocks(String(rest))
    }
}

/// The streaming bubble. The only view that reads `OrbLiveText.text`, so a frame of deltas
/// re-renders this bubble, not the conversation screen around it.
struct OrbLiveReply: View {
    let live: OrbLiveText
    /// The last stored assistant answers: live text they already hold is not shown twice.
    let stored: [String]
    let onArtifact: (String) -> Void

    var body: some View {
        let text = OrbSendFlow.dedupeLiveText(live.text, stored: stored)
        if !text.isEmpty {
            OrbMessageWithFiles(text: text, streaming: true, onArtifact: onArtifact)
        }
    }
}
