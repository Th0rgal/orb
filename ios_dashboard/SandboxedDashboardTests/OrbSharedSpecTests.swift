import XCTest
@testable import sandboxed_sh

/// Reads shared/orb-spec (also consumed by the Android tests).
enum OrbSpec {
    static func url(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SandboxedDashboardTests
            .deletingLastPathComponent()   // ios_dashboard
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("shared/orb-spec")
            .appendingPathComponent(relative)
    }

    static func json(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(relative))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class MissionStateTests: XCTestCase {
    func testSwiftTableMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("mission-states.json")
        let states = try XCTUnwrap(spec["states"] as? [String: [String: Any]])
        XCTAssertEqual(Set(states.keys), Set(MissionState.allCases.map(\.rawValue)), "every spec state needs a MissionState case and vice versa")
        for (raw, entry) in states {
            let state = try XCTUnwrap(MissionState(rawValue: raw))
            let flags = try XCTUnwrap(entry["flags"] as? [String: Bool], raw)
            XCTAssertEqual(state.label, entry["label"] as? String, "\(raw) label")
            XCTAssertEqual(state.category.rawValue, entry["category"] as? String, "\(raw) category")
            XCTAssertEqual(state.sortRank, entry["sortRank"] as? Int, "\(raw) sortRank")
            XCTAssertEqual(state.isActive, flags["live"], "\(raw) live")
            XCTAssertEqual(state.isTerminal, flags["terminal"], "\(raw) terminal")
            XCTAssertEqual(state.needsAttention, flags["needsAttention"], "\(raw) needsAttention")
            XCTAssertEqual(state.awaitsReview, flags["unreadResponse"], "\(raw) unreadResponse")
            XCTAssertEqual(state.canRetry, flags["canRetry"], "\(raw) canRetry")
        }
        let categories = try XCTUnwrap(spec["categories"] as? [String])
        XCTAssertTrue(MissionState.allCases.allSatisfy { categories.contains($0.category.rawValue) })
    }

    func testUnknownStatesFollowSpecFallback() throws {
        let unknown = try XCTUnwrap(try OrbSpec.json("mission-states.json")["unknown"] as? [String: Any])
        XCTAssertNil(MissionState(rawValue: "brand_new_state"))
        XCTAssertEqual(MissionState.label("brand_new_state"), "brand new state")
        XCTAssertEqual(MissionState.sortRank("brand_new_state"), unknown["sortRank"] as? Int)
        XCTAssertEqual(OrbStyle.statusLabel("deleted"), "deleted")
        XCTAssertFalse(OrbRow(.object(["id": .string("x"), "status": .string("brand_new_state")])).active)
    }

    func testInboxSectionsKeepIOSBehaviour() {
        let expected: [MissionState: MissionState.InboxSection] = [
            .running: .working, .queued: .working, .waitingBackground: .working,
            .awaitingUser: .needsYou, .blocked: .needsYou, .failed: .needsYou, .notFeasible: .needsYou,
            .completed: .ready, .succeeded: .ready, .paused: .ready, .interrupted: .ready,
            .cancelled: .hidden, .acknowledged: .hidden, .archived: .hidden,
        ]
        for (state, section) in expected { XCTAssertEqual(state.inboxSection, section, state.rawValue) }
        XCTAssertTrue(MissionState.blocked.isProblem)
        XCTAssertFalse(MissionState.awaitingUser.isProblem, "waiting on the user is not a failure")
        XCTAssertTrue(MissionState.interrupted.canReopen)
        XCTAssertTrue(MissionState.acknowledged.canReopen)
        XCTAssertFalse(MissionState.running.canReopen)
        XCTAssertEqual(MissionState.completed.notificationLabel, "Done")
        XCTAssertEqual(MissionState.notFeasible.notificationLabel, "Failed")
        XCTAssertNil(MissionState.paused.notificationLabel)
    }

    func testUrgencyOrderingUsesSortRank() {
        let order: [MissionState] = [.awaitingUser, .blocked, .failed, .running, .queued, .paused, .interrupted, .completed, .archived]
        XCTAssertEqual(order.map(\.sortRank), order.map(\.sortRank).sorted())
        XCTAssertEqual(Set(order.map(\.sortRank)).count, order.count)
    }
}

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_411_230)

    private func label(secondsAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return OrbStyle.relativeTime(formatter.string(from: now.addingTimeInterval(-Double(secondsAgo))), now: now)
    }

    func testSharedFixture() throws {
        let cases = try XCTUnwrap(try OrbSpec.json("fixtures/relative-time.json")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let seconds = try XCTUnwrap(item["secondsAgo"] as? Int)
            XCTAssertEqual(label(secondsAgo: seconds), item["expected"] as? String, "\(seconds) s")
        }
    }

    func testFortyFiveToFiftyNineSecondsNeverShowZeroMinutes() {
        for seconds in 45...59 { XCTAssertEqual(label(secondsAgo: seconds), "1m", "\(seconds) s") }
        XCTAssertEqual(label(secondsAgo: 44), "now")
    }

    func testEdgesAndBadInput() {
        XCTAssertEqual(label(secondsAgo: -3600), "now", "future timestamps count as now")
        XCTAssertEqual(OrbStyle.relativeTime("", now: now), "")
        XCTAssertEqual(OrbStyle.relativeTime("not a date", now: now), "")
        XCTAssertEqual(OrbStyle.relativeTime("2026-10-19T11:59:30Z", now: now), "1m", "timestamps without fractional seconds parse")
    }
}

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class OrbReadCacheEventsTests: XCTestCase {
    private var savedFetcher: (@MainActor (String, Int) async throws -> [StoredEvent])!
    private var savedBaseURL = ""
    private var calls: [String] = []

    override func setUp() async throws {
        savedFetcher = OrbReadCache.eventsFetcher
        savedBaseURL = UserDefaults.standard.string(forKey: "api_base_url") ?? ""
        calls = []
        OrbReadCache.eventsFetcher = { [unowned self] id, _ in
            self.calls.append(OrbCore.shared.endpoint + "|" + id)
            try await Task.sleep(for: .milliseconds(20))
            return [StoredEvent(id: Int64(self.calls.count), missionId: id, sequence: Int64(self.calls.count), eventType: "assistant_message",
                                timestamp: "t", eventId: nil, toolCallId: nil, toolName: nil, content: OrbCore.shared.endpoint, metadata: [:])]
        }
    }

    override func tearDown() async throws {
        OrbReadCache.eventsFetcher = savedFetcher
        OrbCore.shared.baseURL = savedBaseURL
    }

    func testConcurrentCallersShareOneRequestAndTTLIsHonoured() async throws {
        OrbCore.shared.baseURL = "http://127.0.0.1:1"
        let id = "ttl-" + UUID().uuidString
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        async let first = OrbReadCache.events(id, now: { clock.now })
        async let second = OrbReadCache.events(id, now: { clock.now })
        let results = try await [first, second]
        XCTAssertEqual(calls.count, 1, "in-flight fetch is shared")
        XCTAssertEqual(results[0].map(\.sequence), results[1].map(\.sequence))

        clock.now = clock.now.addingTimeInterval(29)
        _ = try await OrbReadCache.events(id, ttl: 30, now: { clock.now })
        XCTAssertEqual(calls.count, 1, "fresh within TTL")

        clock.now = clock.now.addingTimeInterval(2)
        _ = try await OrbReadCache.events(id, ttl: 30, now: { clock.now })
        XCTAssertEqual(calls.count, 2, "expired after TTL")

        _ = try await OrbReadCache.events(id, ttl: 30, force: true, now: { clock.now })
        XCTAssertEqual(calls.count, 3, "force bypasses TTL")
        XCTAssertEqual(OrbReadCache.readEvents(id).count, 1, "result also lands in the events cache")
    }

    func testEventsAreScopedPerAccount() async throws {
        let id = "scope-" + UUID().uuidString
        let now = Date(timeIntervalSince1970: 2_000)
        OrbCore.shared.baseURL = "http://127.0.0.1:1"
        let a = try await OrbReadCache.events(id, now: { now })
        OrbCore.shared.baseURL = "http://127.0.0.1:2"
        let b = try await OrbReadCache.events(id, now: { now })
        XCTAssertEqual(calls.count, 2, "another account never reads the first account's events")
        XCTAssertEqual(a.first?.content, "http://127.0.0.1:1")
        XCTAssertEqual(b.first?.content, "http://127.0.0.1:2")
        OrbCore.shared.baseURL = "http://127.0.0.1:1"
        let again = try await OrbReadCache.events(id, now: { now })
        XCTAssertEqual(calls.count, 2, "switching back reuses that account's fresh cache")
        XCTAssertEqual(again.first?.content, "http://127.0.0.1:1")
    }
}

final class FleetLiveActivityTextTests: XCTestCase {
    typealias State = OrbFleetActivityAttributes.ContentState

    func testSummaryListsOnlyNonZeroCountsInOrder() {
        let state = State(done: 9, running: 2, waiting: 1, failed: 3, updatedAt: .now)
        XCTAssertEqual(state.summaryText, "2 en cours · 1 t’attend · 3 en échec · 9 terminées")
        XCTAssertEqual(state.summaryParts.map(\.part), [.running, .waiting, .failed, .done])
        XCTAssertEqual(State(done: 0, running: 1, waiting: 0, failed: 0, updatedAt: .now).summaryText, "1 en cours")
    }

    func testPluralsAndHeadline() {
        let busy = State(done: 1, running: 0, waiting: 2, failed: 0, updatedAt: .now)
        XCTAssertEqual(busy.summaryText, "2 t’attendent · 1 terminée")
        XCTAssertEqual(busy.headline, "Flotte Orb")
        XCTAssertEqual(busy.idleText, "Rien ne t’attend · les agents travaillent.")
        let done = State(done: 4, running: 0, waiting: 0, failed: 0, updatedAt: .now)
        XCTAssertTrue(done.allDone)
        XCTAssertEqual(done.headline, "Tout est terminé")
        XCTAssertEqual(done.idleText, "Rien ne t’attend.")
        XCTAssertEqual(State(done: 0, running: 0, waiting: 0, failed: 0, updatedAt: .now).summaryText, "")
    }

    func testNextDetail() {
        var state = State(done: 0, running: 0, waiting: 1, failed: 0, nextTitle: "Verity", nextProject: "Verity", nextReason: "Approuver", updatedAt: .now)
        XCTAssertEqual(state.nextDetail, "Verity · Approuver")
        state.nextProject = ""
        XCTAssertEqual(state.nextDetail, "Approuver")
        state.nextTitle = nil
        XCTAssertNil(state.nextDetail)
    }
}

final class PollerTests: XCTestCase {
    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(Poller.delay(base: .seconds(10), failures: 0, maxBackoff: .seconds(120)), .seconds(10))
        XCTAssertEqual(Poller.delay(base: .seconds(10), failures: 1, maxBackoff: .seconds(120)), .seconds(20))
        XCTAssertEqual(Poller.delay(base: .seconds(10), failures: 3, maxBackoff: .seconds(120)), .seconds(80))
        XCTAssertEqual(Poller.delay(base: .seconds(10), failures: 9, maxBackoff: .seconds(120)), .seconds(120))
        XCTAssertEqual(Poller.delay(base: .seconds(300), failures: 2, maxBackoff: .seconds(120)), .seconds(300), "never faster than the base interval")
    }
}

@MainActor
final class ErrorRingTests: XCTestCase {
    func testKeepsLastFiftyAndRedactsQueries() {
        let ring = ErrorRing()
        for i in 0..<60 { ring.record(category: .network, path: "GET /p\(i)", status: 500, message: "boom") }
        XCTAssertEqual(ring.entries.count, ErrorRing.capacity)
        XCTAssertEqual(ring.entries.first?.path, "GET /p10")
        XCTAssertEqual(ErrorRing.redact("GET /api/x?token=secret"), "GET /api/x")
        XCTAssertEqual(ErrorRing.status(of: OrbHTTPError(status: 503, detail: "")), 503)
        XCTAssertEqual(ErrorRing.status(of: OrbHTTPError.unauthorized), 401)
    }
}
