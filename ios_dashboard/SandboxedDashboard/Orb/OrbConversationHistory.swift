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
                            "content": .string(event.content), "sequence": .number(Double(event.sequence))])
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
        let known = Set(history.map { $0["role"].text + "\u{0}" + $0["content"].text.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard let anchor = incoming.lastIndex(where: { known.contains($0["role"].text + "\u{0}" + $0["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return history }
        return history + incoming.dropFirst(anchor + 1)
    }
    nonisolated private static func sequence(_ row: OrbJSON) -> Double {
        if case .number(let value) = row["sequence"] { return value }
        return 0
    }
}
