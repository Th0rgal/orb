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

    static let unsupported = "Goal mode is unavailable for this remote harness because it cannot continue the objective safely. Choose OpenCode or send a standard turn."

    static func phase(status: String, reason: String) -> Phase {
        if reason == "remote_goal_complete" { return .complete }
        if reason == "remote_goal_stopped" || status == "cancelled" { return .stopped }
        if ["active", "pending"].contains(status) || ["remote_goal_continuation", "awaiting_wakeup"].contains(reason) { return .active }
        return status == "paused" ? .paused : .blocked
    }

    static func label(_ phase: Phase, iteration: Int) -> String {
        if phase != .active { return "Goal \(phase.rawValue)" }
        return iteration > 0 ? "Goal in progress · iteration \(iteration)" : "Goal in progress"
    }

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

/// Core supplies this owner-scoped reason on the selected fleet row.
enum OrbNativeLaunch {
    static func warning(_ fleet: OrbJSON, nodeID: String) -> String? {
        guard let row = fleet["nodes"].items.first(where: { $0["id"].text == nodeID }) else { return nil }
        switch row["launch_block"].text {
        case "native_owner_executor_unavailable":
            return "The isolated workspace executor for this enrolled Antigravity account is unavailable. Choose another machine to start a mission."
        case "native_owner_enrollment_required":
            return "This node needs an enabled Antigravity account. Check its enrollment in provider settings or choose another machine."
        default: return nil
        }
    }

    @MainActor static func require(nodeID: String, goalBackend: String?, loadFleet: () async throws -> OrbJSON) async throws {
        guard !nodeID.isEmpty, nodeID != "core", goalBackend != nil || !OrbManaged.isAutoManagedTarget(nodeID) else { return }
        let fleet = try await loadFleet()
        if let reason = warning(fleet, nodeID: nodeID) {
            throw OrbHTTPError(status: 409, detail: reason)
        }
        if let goalBackend, !fleet["remote_launch"]["goal_harnesses"].items.contains(where: { $0.text == goalBackend }) {
            throw OrbHTTPError(status: 400, detail: OrbRemoteGoal.unsupported)
        }
    }
}
