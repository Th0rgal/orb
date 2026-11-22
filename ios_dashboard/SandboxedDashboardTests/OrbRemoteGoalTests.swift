import XCTest
@testable import sandboxed_sh

final class OrbRemoteGoalTests: XCTestCase {
    func testSharedEnvelopeFixtures() throws {
        let root = try OrbSpec.json("fixtures/remote-goal.json")
        XCTAssertEqual(root["schema_version"] as? Int, 2)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for fixture in cases {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let event = try XCTUnwrap(fixture["event"] as? [String: Any])
            let actual = OrbRemoteGoal.event(event)
            if fixture["expected"] is NSNull {
                XCTAssertNil(actual, name)
            } else {
                let expected = try XCTUnwrap(fixture["expected"] as? [String: Any])
                let result = try XCTUnwrap(actual, name)
                XCTAssertTrue(NSDictionary(dictionary: result).isEqual(to: expected), name)
            }
        }
    }

    @MainActor func testNativeLaunchChecksFreshFleetBeforeSubmitting() async throws {
        let fixture = try OrbSpec.json("fixtures/native-launch-preflight.json")
        let fleet = try JSONDecoder().decode(OrbJSON.self, from: JSONSerialization.data(withJSONObject: fixture))
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        for row in cases {
            let node = try XCTUnwrap(row["node"] as? String)
            let expected = row["error"] as? String
            var reads = 0
            var failure: String?
            do {
                try await OrbNativeLaunch.require(nodeID: node, goalBackend: row["goal_backend"] as? String) {
                    reads += 1
                    return fleet
                }
            } catch let error as OrbHTTPError {
                failure = error.detail
            }
            XCTAssertEqual(failure, expected, node)
            XCTAssertEqual(reads, row["reads"] as? Int, node)
        }
    }

    func testProjectionStopsAfterTruthfulCompletion() {
        var projection = OrbRemoteGoal.Projection(phase: .active, objective: "Ship it", iteration: 0, detail: nil)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_iteration", "data": ["status": "active", "objective": "Ship it", "iteration": 2, "summary": "Progress"]])
        XCTAssertEqual(projection.iteration, 2)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_status", "data": ["status": "complete"]])
        XCTAssertEqual(projection.phase, .complete)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_status", "data": ["status": "active"]])
        XCTAssertEqual(projection.phase, .complete)
    }

    func testSharedProjectionFixtures() throws {
        let root = try OrbSpec.json("fixtures/remote-goal.json")
        let fixtures = try XCTUnwrap(root["projection_cases"] as? [[String: Any]])
        XCTAssertFalse(fixtures.isEmpty)
        for fixture in fixtures {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let phase = OrbRemoteGoal.phase(status: try XCTUnwrap(fixture["status"] as? String), reason: try XCTUnwrap(fixture["reason"] as? String))
            XCTAssertEqual(phase.rawValue, fixture["phase"] as? String, name)
            XCTAssertEqual(OrbRemoteGoal.label(phase, iteration: try XCTUnwrap(fixture["iteration"] as? Int)), fixture["label"] as? String, name)
        }
    }
}
