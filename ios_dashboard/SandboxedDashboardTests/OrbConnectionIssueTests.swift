import XCTest
@testable import sandboxed_sh

final class OrbConnectionIssueTests: XCTestCase {
    private let lanError = "Could not connect to the server."

    func testPrivateAddresses() {
        for u in ["http://192.168.1.5:8080", "http://10.0.0.2", "http://172.20.1.1:3000", "http://127.0.0.1:8080",
                  "http://localhost:8080", "http://mac.local:8080", "http://100.101.2.3", "http://[fd00::1]:80", "http://devbox:8080"] {
            XCTAssertTrue(OrbConnection.isPrivateAddress(u), u)
        }
        for u in ["https://agent-backend.thomas.md", "https://8.8.8.8", "http://172.32.0.1", "https://example.com"] {
            XCTAssertFalse(OrbConnection.isPrivateAddress(u), u)
        }
    }

    func testUnreachableDetection() {
        XCTAssertTrue(OrbConnection.isUnreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(OrbConnection.isUnreachable(URLError(.timedOut)))
        XCTAssertTrue(OrbConnection.isUnreachable("The request timed out."))
        XCTAssertFalse(OrbConnection.isUnreachable("HTTP 401"))
        XCTAssertFalse(OrbConnection.isUnreachable(nil as String?))
    }

    func testLanFailureWithDefaultOnlineRecommendsDefault() throws {
        let issue = try XCTUnwrap(OrbConnection.issue(serverURL: "http://192.168.1.5:8080/", error: lanError, defaultReachable: true))
        XCTAssertEqual(issue.serverURL, "http://192.168.1.5:8080")
        XCTAssertTrue(issue.offerUseDefault)
        XCTAssertTrue(issue.recommendDefault)
        XCTAssertTrue(issue.message.contains("default Orb server is online"))
    }

    func testLanFailureWhileProbePendingOrDefaultDown() throws {
        for reach in [nil, false] as [Bool?] {
            let issue = try XCTUnwrap(OrbConnection.issue(serverURL: "http://192.168.1.5:8080", error: lanError, defaultReachable: reach))
            XCTAssertTrue(issue.offerUseDefault)
            XCTAssertFalse(issue.recommendDefault)
        }
    }

    func testDefaultServerFailureOffersNoUseDefault() throws {
        let issue = try XCTUnwrap(OrbConnection.issue(serverURL: "https://agent-backend.thomas.md/", error: "timed out", defaultReachable: true))
        XCTAssertFalse(issue.offerUseDefault)
        XCTAssertFalse(issue.recommendDefault)
    }

    func testPublicCustomServerOffersDefaultWithoutRecommending() throws {
        let issue = try XCTUnwrap(OrbConnection.issue(serverURL: "https://orb.example.com", error: lanError, defaultReachable: true))
        XCTAssertTrue(issue.offerUseDefault)
        XCTAssertFalse(issue.recommendDefault)
    }

    func testHttpErrorsAreNotConnectionIssues() {
        XCTAssertNil(OrbConnection.issue(serverURL: "http://192.168.1.5:8080", error: "HTTP 500", defaultReachable: true))
    }

    func testSystemProxyIsNamed() throws {
        let issue = try XCTUnwrap(OrbConnection.issue(serverURL: "https://agent-backend.thomas.md", error: lanError,
                                                      defaultReachable: nil, proxy: "192.168.1.5:8080"))
        XCTAssertEqual(issue.proxy, "192.168.1.5:8080")
        XCTAssertTrue(issue.message.contains("proxy at 192.168.1.5:8080"))
        XCTAssertFalse(issue.recommendDefault)
    }

    func testProbeOnlyWhenItCanChangeTheAdvice() {
        XCTAssertTrue(OrbConnection.shouldProbeDefault(serverURL: "http://192.168.1.5:8080", unreachable: true))
        XCTAssertFalse(OrbConnection.shouldProbeDefault(serverURL: "https://agent-backend.thomas.md", unreachable: true))
        XCTAssertFalse(OrbConnection.shouldProbeDefault(serverURL: "https://orb.example.com", unreachable: true))
        XCTAssertFalse(OrbConnection.shouldProbeDefault(serverURL: "http://192.168.1.5:8080", unreachable: false))
    }
}
