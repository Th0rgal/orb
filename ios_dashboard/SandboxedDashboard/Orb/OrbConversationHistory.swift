import Foundation

/// Conversation rows reconcile together; a partial raw tail never owns older history.
enum OrbConversationHistory {
    static let eventTypes = ["user_message", "assistant_message", "assistant_message_canonical"]

    nonisolated static func merge(_ history: [OrbJSON], events: [StoredEvent]) -> [OrbJSON] {
        let incoming: [OrbJSON] = events.sorted { $0.sequence < $1.sequence }.compactMap { event in
            guard eventTypes.contains(event.eventType), !event.content.isEmpty,
                  (event.metadata["queued"]?.value as? Bool) != true,
                  (event.metadata["success"]?.value as? Bool) != false else { return nil }
            return .object(["role": .string(event.eventType == "user_message" ? "user" : "assistant"),
                            "content": .string(event.content), "sequence": .number(Double(event.sequence)),
                            "canonical": .bool(event.eventType == "assistant_message_canonical"),
                            "bubble_id": .string(event.metadata["bubble_id"]?.value as? String ?? "text_delta_latest"),
                            "revision": .number((event.metadata["revision"]?.value as? NSNumber)?.doubleValue ?? 0)])
        }
        guard !history.isEmpty else { return incoming }
        // New snapshots preserve event identities, including repeated identical prompts.
        if history.allSatisfy({ $0["sequence"] != .null }) {
            var bySequence = Dictionary(history.map { (sequence($0), $0) }, uniquingKeysWith: { _, new in new })
            let first = history.map(sequence).min() ?? 0
            for row in incoming where sequence(row) >= first { bySequence[sequence(row)] = row }
            return bySequence.values.sorted { sequence($0) < sequence($1) }
        }
        // Legacy disk/history rows have no IDs. Only append beyond a known overlap;
        // an unanchored tail must wait for the authoritative conversation request.
        let last = history[history.count - 1]
        guard let anchor = incoming.lastIndex(where: {
            $0["role"].text == last["role"].text && $0["content"].text.trimmingCharacters(in: .whitespacesAndNewlines) == last["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }) else { return history }
        return history + incoming.dropFirst(anchor + 1)
    }
    /// Mirrors desktop's canonical bubble revisions and terminal receipt handling.
    /// Stored rows remain intact so skipped receipts still advance the read cursor.
    nonisolated static func visible(_ rows: [OrbJSON]) -> [OrbJSON] {
        var result: [OrbJSON] = []
        var bubbles: [String: Int] = [:]
        var native: [Int] = []
        for row in rows {
            if row["role"].text == "user" {
                bubbles.removeAll(); native.removeAll(); result.append(row); continue
            }
            let bubble = row["bubble_id"].text.isEmpty ? "text_delta_latest" : row["bubble_id"].text
            if row["canonical"].flag {
                if let index = bubbles[bubble] {
                    if (row["revision"].doubleValue ?? 0) >= (result[index]["revision"].doubleValue ?? 0) { result[index] = row }
                } else {
                    bubbles[bubble] = result.count
                    if bubble.hasPrefix("antigravity:") || bubble.hasPrefix("opencode:") { native.append(result.count) }
                    result.append(row)
                }
                continue
            }
            let text = row["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let receipt = !native.isEmpty && (text == native.map { result[$0]["content"].text }.joined().trimmingCharacters(in: .whitespacesAndNewlines) || text == result[native.last!]["content"].text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !receipt {
                if let index = bubbles[bubble] { result[index] = row } else { result.append(row) }
            }
            bubbles.removeAll(); native.removeAll()
        }
        return result
    }
    nonisolated private static func sequence(_ row: OrbJSON) -> Double {
        if case .number(let value) = row["sequence"] { return value }
        return 0
    }
}
