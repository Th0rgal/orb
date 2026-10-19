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

/// Text drawn by the Lock Screen activity, kept here so the app's unit tests pin it.
extension OrbFleetActivityAttributes.ContentState {
    enum Part: String, Sendable { case running, waiting, failed, done }

    var headline: String { allDone ? "Tout est terminé" : "Flotte Orb" }

    /// "2 en cours · 1 t’attend · 9 terminées": only non-zero states, in this order.
    var summaryParts: [(count: Int, label: String, part: Part)] {
        [
            (running, "en cours", Part.running),
            (waiting, waiting > 1 ? "t’attendent" : "t’attend", Part.waiting),
            (failed, "en échec", Part.failed),
            (done, done > 1 ? "terminées" : "terminée", Part.done),
        ].filter { $0.0 > 0 }
    }

    var summaryText: String { summaryParts.map { "\($0.count) \($0.label)" }.joined(separator: " · ") }

    /// Shown when no mission is waiting on the user.
    var idleText: String { allDone ? "Rien ne t’attend." : "Rien ne t’attend · les agents travaillent." }

    /// Project and reason of the next waiting mission, nil when there is none.
    var nextDetail: String? {
        guard let title = nextTitle, !title.isEmpty else { return nil }
        return [nextProject, nextReason].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

enum OrbFleetActivityLink {
    static let inbox = URL(string: "orb://inbox")!
}
