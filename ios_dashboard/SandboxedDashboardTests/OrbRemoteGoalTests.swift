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

    func testProjectionStopsAfterTruthfulCompletion() {
        var projection = OrbRemoteGoal.Projection(phase: .active, objective: "Ship it", iteration: 0, detail: nil)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_iteration", "data": ["status": "active", "objective": "Ship it", "iteration": 2, "summary": "Progress"]])
        XCTAssertEqual(projection.iteration, 2)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_status", "data": ["status": "complete"]])
        XCTAssertEqual(projection.phase, .complete)
        projection = OrbRemoteGoal.apply(projection, event: ["type": "goal_status", "data": ["status": "active"]])
        XCTAssertEqual(projection.phase, .complete)
    }
}
