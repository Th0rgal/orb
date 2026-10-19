import Foundation

/// Every mission status Core reports, with the display and inbox rules derived from it.
/// label, category, sortRank and the flags mirror shared/orb-spec/mission-states.json
/// (shared with Android); MissionStateTests fail when the two drift apart.
enum MissionState: String, CaseIterable, Sendable {
    case active, running, starting, working
    case inProgress = "in_progress"
    case processing, streaming, resuming
    case waitingBackground = "waiting_background"
    case pending, queued
    case awaitingUser = "awaiting_user"
    case waitingUser = "waiting_user"
    case waitingForUser = "waiting_for_user"
    case needsInput = "needs_input"
    case awaitingApproval = "awaiting_approval"
    case blocked, failed, error, errored
    case notFeasible = "not_feasible"
    case timedOut = "timed_out"
    case interrupted, cancelled, paused, completed, succeeded, acknowledged, archived

    /// Shared category (spec `category`).
    enum Category: String, Sendable {
        case waiting, blocked, failed, live, queued, paused, stopped, done, archived
    }

    /// iOS Inbox section a mission in this state belongs to (before interaction / subagent rules).
    enum InboxSection: Sendable {
        case working, needsYou, ready, hidden
    }

    static let unknownSortRank = 9

    var category: Category {
        switch self {
        case .active, .running, .starting, .working, .inProgress, .processing, .streaming, .resuming, .waitingBackground: .live
        case .pending, .queued: .queued
        case .awaitingUser, .waitingUser, .waitingForUser, .needsInput, .awaitingApproval: .waiting
        case .blocked: .blocked
        case .failed, .error, .errored, .notFeasible, .timedOut: .failed
        case .interrupted, .cancelled: .stopped
        case .paused: .paused
        case .completed, .succeeded: .done
        case .acknowledged, .archived: .archived
        }
    }

    var label: String {
        switch category {
        case .live: "Working"
        case .queued: "Queued"
        case .blocked: "Blocked"
        case .stopped: "Stopped"
        case .paused: "Paused"
        case .done: "Completed"
        case .archived: "Archived"
        case .waiting:
            switch self {
            case .needsInput: "Needs input"
            case .awaitingApproval: "Awaiting approval"
            default: "Waiting for reply"
            }
        case .failed:
            switch self {
            case .notFeasible: "Not feasible"
            case .timedOut: "Timed out"
            default: "Failed"
            }
        }
    }

    /// Inbox urgency, lowest first (spec `sortRank`).
    var sortRank: Int {
        switch category {
        case .waiting: 0
        case .blocked: 1
        case .failed: 2
        case .live: 3
        case .queued: 4
        case .paused: 5
        case .stopped: 6
        case .done: 7
        case .archived: 8
        }
    }

    // MARK: Spec flags

    /// Running or about to run (spec `live`): spinners, the "Working" section, no AI digest yet.
    var isActive: Bool { category == .live || category == .queued }
    /// The run reached an outcome (spec `terminal`).
    var isTerminal: Bool { category == .done || category == .failed }
    /// Needs the operator (spec `needsAttention`): waiting, blocked or failed.
    var needsAttention: Bool { category == .waiting || category == .blocked || category == .failed }
    /// A turn finished in this state can be unread / notified (spec `unreadResponse`).
    var awaitsReview: Bool {
        switch self {
        case .awaitingUser, .waitingUser, .blocked, .failed, .notFeasible, .interrupted, .paused, .completed, .succeeded: true
        default: false
        }
    }
    /// "Retry / Resume" is offered (spec `canRetry`).
    var canRetry: Bool { [.blocked, .failed, .notFeasible, .interrupted].contains(self) }

    // MARK: iOS derived rules

    /// Blocked or failed: red/amber attention badges and failed-track counts (excludes waiting).
    var isProblem: Bool { category == .blocked || category == .failed }
    var isSuccess: Bool { category == .done }
    /// The run stopped for good, so Reopen / Restore is offered.
    var canReopen: Bool { isTerminal || category == .stopped || category == .archived }

    var inboxSection: InboxSection {
        switch category {
        case .live, .queued: .working
        case .waiting, .blocked, .failed: .needsYou
        case .done, .paused: .ready
        case .stopped: awaitsReview ? .ready : .hidden
        case .archived: .hidden
        }
    }

    /// Second line of a "needs you / done" notification; nil falls back to the Inbox badge.
    var notificationLabel: String? {
        switch category {
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .waiting: "Waiting for you"
        case .done: "Done"
        default: nil
        }
    }

    /// Label for any raw status, including ones this build doesn't know yet.
    static func label(_ raw: String) -> String {
        MissionState(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ")
    }

    static func sortRank(_ raw: String) -> Int {
        MissionState(rawValue: raw)?.sortRank ?? unknownSortRank
    }
}

extension OrbRow {
    var missionState: MissionState? { MissionState(rawValue: state) }
}
