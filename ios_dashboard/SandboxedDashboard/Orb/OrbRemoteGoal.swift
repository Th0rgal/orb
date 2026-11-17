import Foundation

/// Lossless transport envelope, not a capability declaration or completion verdict.
enum OrbRemoteGoal {
    static func event(_ value: [String: Any]) -> [String: Any]? {
        guard let type = value["type"] as? String,
              type == "goal_status" || type == "goal_iteration",
              let data = value["data"] as? [String: Any] else { return nil }
        return ["type": type, "data": data]
    }
}
