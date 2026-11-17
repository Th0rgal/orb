import XCTest
@testable import sandboxed_sh

final class OrbRemoteGoalTests: XCTestCase {
    func testSharedEnvelopeFixtures() throws {
        let root = try OrbSpec.json("fixtures/remote-goal.json")
        XCTAssertEqual(root["schema_version"] as? Int, 1)
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
}
