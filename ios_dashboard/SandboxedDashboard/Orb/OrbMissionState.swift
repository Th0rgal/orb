import Foundation

/// Every mission status Core reports, with the display and inbox rules derived from it.
/// The table is mirrored in shared/orb-spec/mission-states.json (also consumed by
/// Android); MissionStateTests fail when the two drift apart.
enum MissionState: String, CaseIterable, Sendable {
    case active, running, starting, pending, queued, resuming
    case waitingBackground = "waiting_background"
    case awaitingUser = "awaiting_user"
    case waitingUser = "waiting_user"
    case blocked, failed
    case notFeasible = "not_feasible"
    case completed, succeeded, paused, interrupted, cancelled, acknowledged, archived, deleted

    /// Inbox section a mission in this state belongs to (before interaction / subagent rules).
    enum Category: String, Sendable {
        case working, needsYou = "needs_you", ready, hidden
    }

    init?(raw: String) { self.init(rawValue: raw) }

    var category: Category {
        switch self {
        case .active, .running, .starting, .pending, .queued, .resuming, .waitingBackground: .working
        case .awaitingUser, .waitingUser, .blocked, .failed, .notFeasible: .needsYou
        case .completed, .succeeded, .paused, .interrupted: .ready
        case .cancelled, .acknowledged, .archived, .deleted: .hidden
        }
    }

    /// Running or about to run: spinners, the "Working" Inbox section, no AI digest yet.
    var isActive: Bool { category == .working }
    /// Shown with an attention badge; counts toward "needs attention".
    var needsAttention: Bool { [.blocked, .failed, .notFeasible].contains(self) }
    /// The run ended: reopen/restore is offered and polling can stop.
    var isTerminal: Bool { [.completed, .succeeded, .failed, .notFeasible, .interrupted, .cancelled, .acknowledged, .archived, .deleted].contains(self) }
    /// "Retry / Resume" is offered.
    var canRetry: Bool { [.failed, .notFeasible, .interrupted, .blocked].contains(self) }
    var isSuccess: Bool { self == .completed || self == .succeeded }
    /// A turn finished in this state can be unread / notified.
    var awaitsReview: Bool { category == .needsYou || category == .ready }

    var label: String {
        switch self {
        case .active, .running, .starting: "Working"
        case .pending, .queued: "Queued"
        case .resuming: "Resuming"
        case .waitingBackground: "Working in background"
        case .completed, .succeeded: "Completed"
        case .awaitingUser, .waitingUser: "Waiting for reply"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .notFeasible: "Not feasible"
        case .interrupted, .cancelled: "Stopped"
        case .paused: "Paused"
        case .acknowledged: "Archived"
        case .archived: "Archived"
        case .deleted: "Deleted"
        }
    }

    /// Second line of a "needs you / done" notification; nil falls back to the Inbox badge.
    var notificationLabel: String? {
        switch self {
        case .blocked: "Blocked"
        case .failed, .notFeasible: "Failed"
        case .awaitingUser, .waitingUser: "Waiting for you"
        case .completed, .succeeded: "Done"
        default: nil
        }
    }

    /// Inbox urgency, lowest first: blocked, waiting on you, failed, everything else.
    var sortRank: Int {
        switch self {
        case .blocked: 1
        case .awaitingUser, .waitingUser: 2
        case .failed, .notFeasible: 3
        default: 4
        }
    }

    /// Label for any raw status, including ones this build doesn't know yet.
    static func label(_ raw: String) -> String {
        MissionState(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ")
    }
}

extension OrbRow {
    var missionState: MissionState? { MissionState(rawValue: state) }
}
