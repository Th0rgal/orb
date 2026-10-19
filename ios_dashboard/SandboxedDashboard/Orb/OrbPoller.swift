import Foundation

/// The one polling loop: fixed or dynamic interval, exponential backoff after failed
/// ticks, and a gate (usually `scenePhase == .active`) that skips ticks while the app
/// is not in front. Runs until the calling task is cancelled.
@MainActor
enum Poller {
    /// Delay before the next tick: `base` after a success, doubling per consecutive failure up to `maxBackoff`.
    nonisolated static func delay(base: Duration, failures: Int, maxBackoff: Duration) -> Duration {
        guard failures > 0 else { return base }
        let factor = 1 << min(failures, 16)
        return min(base * factor, max(base, maxBackoff))
    }

    /// - Parameters:
    ///   - interval: evaluated before every sleep, so callers can poll faster while work is running.
    ///   - immediately: tick once before the first sleep.
    ///   - isActive: ticks are skipped (not counted as failures) while this is false.
    ///   - tick: returns false when the poll failed, which backs off the next delay.
    static func run(
        every interval: () -> Duration,
        immediately: Bool = true,
        maxBackoff: Duration = .seconds(120),
        while isActive: () -> Bool = { true },
        _ tick: () async -> Bool
    ) async {
        var failures = 0
        var first = immediately
        while !Task.isCancelled {
            if !first {
                do { try await Task.sleep(for: delay(base: interval(), failures: failures, maxBackoff: maxBackoff)) } catch { return }
            }
            first = false
            guard !Task.isCancelled else { return }
            guard isActive() else { continue }
            failures = await tick() ? 0 : failures + 1
        }
    }

    static func run(
        every interval: Duration,
        immediately: Bool = true,
        maxBackoff: Duration = .seconds(120),
        while isActive: () -> Bool = { true },
        _ tick: () async -> Bool
    ) async {
        await run(every: { interval }, immediately: immediately, maxBackoff: maxBackoff, while: isActive, tick)
    }
}
