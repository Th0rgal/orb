import Foundation

struct StoredEvent: Codable, Identifiable, Sendable {
    let id: Int64
    let missionId: String
    let sequence: Int64
    let eventType: String
    let timestamp: String
    let eventId: String?
    let toolCallId: String?
    let toolName: String?
    let content: String
    let metadata: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case id
        case missionId = "mission_id"
        case sequence
        case eventType = "event_type"
        case timestamp
        case eventId = "event_id"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case content
        case metadata
    }

    init(
        id: Int64,
        missionId: String,
        sequence: Int64,
        eventType: String,
        timestamp: String,
        eventId: String?,
        toolCallId: String?,
        toolName: String?,
        content: String,
        metadata: [String: AnyCodable]
    ) {
        self.id = id
        self.missionId = missionId
        self.sequence = sequence
        self.eventType = eventType
        self.timestamp = timestamp
        self.eventId = eventId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        missionId = try container.decode(String.self, forKey: .missionId)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        eventType = try container.decode(String.self, forKey: .eventType)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        content = try container.decode(String.self, forKey: .content)

        // Decode metadata as generic JSON
        if let metadataValue = try? container.decode([String: AnyCodable].self, forKey: .metadata) {
            metadata = metadataValue
        } else {
            metadata = [:]
        }
    }
}
