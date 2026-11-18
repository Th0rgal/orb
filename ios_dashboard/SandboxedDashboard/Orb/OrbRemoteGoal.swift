import Foundation

/// Lossless transport envelope, not a capability declaration or completion verdict.
enum OrbRemoteGoal {
    static func event(_ value: [String: Any]) -> [String: Any]? {
        guard let type = value["type"] as? String,
              type == "goal_status" || type == "goal_iteration",
              let data = value["data"] as? [String: Any] else { return nil }
        return ["type": type, "data": data]
    }

    enum Phase: String { case active, complete, stopped, paused, blocked }
    struct Projection { var phase: Phase; var objective: String; var iteration: Int; var detail: String? }

    static func apply(_ previous: Projection, event value: [String: Any]) -> Projection {
        guard let envelope = event(value), let data = envelope["data"] as? [String: Any] else { return previous }
        let status = data["status"] as? String
        let phase: Phase
        if previous.phase == .complete && status == "active" {
            phase = previous.phase
        } else if previous.phase == .stopped && status == "active" {
            phase = previous.phase
        } else {
            phase = Phase(rawValue: status ?? "") ?? previous.phase
        }
        return Projection(phase: phase, objective: data["objective"] as? String ?? previous.objective, iteration: data["iteration"] as? Int ?? previous.iteration, detail: data["summary"] as? String ?? previous.detail)
    }
}
