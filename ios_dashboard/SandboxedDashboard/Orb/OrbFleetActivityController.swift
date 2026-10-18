import ActivityKit
import Foundation
import os

/// Keeps one fleet-summary Live Activity in step with the Inbox sections.
/// Started while any mission runs or waits; ended (and dismissed 15 min
/// later) once everything is done. ActivityKit stops an activity after 8 h,
/// so a long-lived one is replaced shortly before that.
@MainActor
final class OrbFleetActivityController {
    static let shared = OrbFleetActivityController()

    private var lastState: OrbFleetActivityAttributes.ContentState?
    private static let log = Logger(subsystem: "md.thomas.openagent.dashboard", category: "live-activity")
    private let maxAge: TimeInterval = 7 * 3600 + 50 * 60
    private var startedAt: Date?

    func reconcile(account: String, needsYou: [OrbInboxItem], ready: [OrbInboxItem], working: [OrbInboxItem]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.notice("fleet live activity disabled in Settings")
            return
        }
        Self.log.debug("fleet reconcile: \(ready.count) done, \(working.count) running, \(needsYou.count) need you")
        let failed = needsYou.filter { $0.tone == .red }
        let waiting = needsYou.filter { $0.tone != .red }
        let next = waiting.min { $0.updatedAt < $1.updatedAt }
        var state = OrbFleetActivityAttributes.ContentState(
            done: ready.count,
            running: working.count,
            waiting: waiting.count,
            failed: failed.count,
            nextTitle: next.map { Self.clip($0.headline, 60) },
            nextProject: next.map { Self.clip($0.projectTitle, 30) },
            nextReason: next.map { Self.clip($0.lastRequest ?? $0.badge, 60) },
            nextSince: next.flatMap { Self.date($0.updatedAt) },
            updatedAt: .now
        )
        let active = Activity<OrbFleetActivityAttributes>.activities
        let current = active.first { $0.attributes.account == account }
        for other in active where other.id != current?.id {
            Self.end(other.id, nil, .immediate)
        }

        let busy = state.running + state.waiting > 0
        if var stamped = lastState { stamped.updatedAt = state.updatedAt; if stamped == state, current != nil { return } }

        guard let current else {
            guard busy else { return }
            start(account: account, state: state)
            return
        }
        if busy, let startedAt, Date().timeIntervalSince(startedAt) > maxAge {
            Self.end(current.id, nil, .immediate)
            start(account: account, state: state)
            return
        }
        lastState = state
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60))
        if busy {
            Self.update(current.id, content)
        } else {
            state.nextTitle = nil
            Self.end(current.id, ActivityContent(state: state, staleDate: nil), .after(.now.addingTimeInterval(15 * 60)))
            lastState = nil
            startedAt = nil
        }
    }

    func endAll() {
        for activity in Activity<OrbFleetActivityAttributes>.activities {
            Self.end(activity.id, nil, .immediate)
        }
        lastState = nil
        startedAt = nil
    }

    private func start(account: String, state: OrbFleetActivityAttributes.ContentState) {
        do {
            _ = try Activity.request(
                attributes: OrbFleetActivityAttributes(account: account),
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60)),
                pushType: nil
            )
            lastState = state
            startedAt = .now
        } catch {
            // Disabled by the user or over the system limit: nothing to show.
            Self.log.error("fleet live activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Activity is not Sendable: hand its id to the task and look it up there.
    private static func update(_ id: String, _ content: ActivityContent<OrbFleetActivityAttributes.ContentState>) {
        Task {
            for activity in Activity<OrbFleetActivityAttributes>.activities where activity.id == id {
                await activity.update(content)
            }
        }
    }

    private static func end(
        _ id: String,
        _ content: ActivityContent<OrbFleetActivityAttributes.ContentState>?,
        _ policy: ActivityUIDismissalPolicy
    ) {
        Task {
            for activity in Activity<OrbFleetActivityAttributes>.activities where activity.id == id {
                await activity.end(content, dismissalPolicy: policy)
            }
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    private static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
