import ActivityKit
import Foundation

/// Fleet summary shown as one Live Activity: how many missions are done,
/// running and waiting, plus the next mission that needs the user.
/// Shared by the app (which starts and updates it) and the widget extension
/// (which draws it). Keep `ContentState` small: ActivityKit caps it at 4 KB.
struct OrbFleetActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var done: Int
        var running: Int
        var waiting: Int
        var failed: Int
        /// The mission waiting longest for the user, if any.
        var nextTitle: String?
        var nextProject: String?
        var nextReason: String?
        var nextSince: Date?
        var updatedAt: Date

        var total: Int { done + running + waiting + failed }
        var allDone: Bool { running == 0 && waiting == 0 && total > 0 }
    }

    /// Account the activity belongs to, so a sign-out can end it.
    var account: String
}

enum OrbFleetActivityLink {
    static let inbox = URL(string: "orb://inbox")!
}
