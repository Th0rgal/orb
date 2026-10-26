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

    var stateId: UInt8 {
        switch self {
        case .active: 0
        case .running: 1
        case .starting: 2
        case .working: 3
        case .inProgress: 4
        case .processing: 5
        case .streaming: 6
        case .resuming: 7
        case .waitingBackground: 8
        case .pending: 9
        case .queued: 10
        case .awaitingUser: 11
        case .waitingUser: 12
        case .waitingForUser: 13
        case .needsInput: 14
        case .awaitingApproval: 15
        case .blocked: 16
        case .failed: 17
        case .error: 18
        case .errored: 19
        case .notFeasible: 20
        case .timedOut: 21
        case .interrupted: 22
        case .cancelled: 23
        case .paused: 24
        case .completed: 25
        case .succeeded: 26
        case .acknowledged: 27
        case .archived: 28
        }
    }

    var category: Category {
        switch OrbKernel.missionStateClassify(stateId) {
        case 0: .waiting
        case 1: .blocked
        case 2: .failed
        case 3: .live
        case 4: .queued
        case 5: .paused
        case 6: .stopped
        case 7: .done
        default: .archived
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
    var sortRank: Int { OrbKernel.missionSortRank(stateId) }

    // MARK: Spec flags

    private var flags: UInt32 { OrbKernel.missionFlags(stateId) }

    /// Running or about to run (spec `live`): spinners, the "Working" section, no AI digest yet.
    var isActive: Bool { (flags & 1) != 0 }
    /// The run reached an outcome (spec `terminal`).
    var isTerminal: Bool { (flags & 2) != 0 }
    /// Needs the operator (spec `needsAttention`): waiting, blocked or failed.
    var needsAttention: Bool { (flags & 4) != 0 }
    /// A turn finished in this state can be unread / notified (spec `unreadResponse`).
    var awaitsReview: Bool { (flags & 8) != 0 }
    /// "Retry / Resume" is offered (spec `canRetry`).
    var canRetry: Bool { (flags & 16) != 0 }

    // MARK: iOS derived rules

    /// Blocked or failed: red/amber attention badges and failed-track counts (excludes waiting).
    var isProblem: Bool { (flags & 32) != 0 }
    var isSuccess: Bool { (flags & 64) != 0 }
    /// The run stopped for good, so Reopen / Restore is offered.
    var canReopen: Bool { (flags & 128) != 0 }

    var inboxSection: InboxSection {
        switch OrbKernel.missionInboxSection(stateId) {
        case 0: .working
        case 1: .needsYou
        case 2: .ready
        default: .hidden
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
