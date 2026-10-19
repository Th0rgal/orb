import XCTest
@testable import sandboxed_sh

/// Pins the FIDO approval wire mapping: `fido_sign_request` stream events in,
/// `POST /api/fido/respond` bodies out (see src/api/fido.rs).
final class FidoApprovalTests: XCTestCase {
    private let event: [String: Any] = [
        "request_id": "6f1c0e8a-0000-4000-8000-000000000001",
        "key_type": "ssh-ed25519",
        "key_fingerprint": "SHA256:abc",
        "origin": "ssh",
        "hostname": "babylon",
        "workspace": "verity",
        "expires_at": "2026-10-19T12:00:30.500Z",
    ]

    func testSignRequestEventMapsEveryField() throws {
        let request = try XCTUnwrap(FidoSignRequest.parse(event))
        XCTAssertEqual(request.id, "6f1c0e8a-0000-4000-8000-000000000001")
        XCTAssertEqual(request.keyType, "ssh-ed25519")
        XCTAssertEqual(request.keyFingerprint, "SHA256:abc")
        XCTAssertEqual(request.origin, "ssh")
        XCTAssertEqual(request.hostname, "babylon")
        XCTAssertEqual(request.workspace, "verity")
        XCTAssertEqual(request.expiresAt.timeIntervalSince1970, 1_792_411_230.5, accuracy: 0.01)
    }

    func testExpiryWithoutFractionalSecondsAndFallback() throws {
        var plain = event
        plain["expires_at"] = "2026-10-19T12:00:30Z"
        XCTAssertEqual(try XCTUnwrap(FidoSignRequest.parse(plain)).expiresAt.timeIntervalSince1970, 1_792_411_230, accuracy: 0.01)
        var garbage = event
        garbage["expires_at"] = "soon"
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(try XCTUnwrap(FidoSignRequest.parse(garbage, now: now)).expiresAt, now.addingTimeInterval(30))
    }

    func testMissingRequiredFieldsAreRejected() {
        for key in ["request_id", "key_type", "key_fingerprint", "origin", "expires_at"] {
            var partial = event
            partial.removeValue(forKey: key)
            XCTAssertNil(FidoSignRequest.parse(partial), "missing \(key) must not produce a request")
        }
        var optional = event
        optional.removeValue(forKey: "hostname")
        optional.removeValue(forKey: "workspace")
        XCTAssertNotNil(FidoSignRequest.parse(optional))
    }

    func testRespondBodyMatchesCoreContract() throws {
        for approved in [true, false] {
            let data = try JSONEncoder().encode(FidoRespondBody(request_id: "r1", approved: approved))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json.count, 2)
            XCTAssertEqual(json["request_id"] as? String, "r1")
            XCTAssertEqual(json["approved"] as? Bool, approved)
        }
    }

    @MainActor
    func testDuplicateStreamDeliveryIsDeduplicated() {
        let state = FidoApprovalState.shared
        state.pendingRequests.removeAll()
        let saved = state.autoApprovalRules
        state.autoApprovalRules = []
        defer { state.pendingRequests.removeAll(); state.autoApprovalRules = saved }
        state.handleSignRequest(event)
        state.handleSignRequest(event)
        XCTAssertEqual(state.pendingRequests.map(\.id), ["6f1c0e8a-0000-4000-8000-000000000001"])
    }

    func testPendingListDecodesIntoSignRequests() throws {
        let json = Data("""
        {"requests":[{"request_id":"6f1c0e8a-0000-4000-8000-000000000002","key_type":"ssh-ed25519",
        "key_fingerprint":"SHA256:abc","origin":"ssh","hostname":null,"workspace":"verity",
        "expires_at":"2026-10-19T12:00:30.500Z"}]}
        """.utf8)
        let list = try JSONDecoder().decode(FidoPendingResponse.self, from: json)
        let request = try XCTUnwrap(list.payloads.first.flatMap { FidoSignRequest.parse($0) })
        XCTAssertEqual(request.id, "6f1c0e8a-0000-4000-8000-000000000002")
        XCTAssertNil(request.hostname)
        XCTAssertEqual(request.workspace, "verity")
        XCTAssertEqual(try JSONDecoder().decode(FidoPendingResponse.self, from: Data(#"{"requests":[]}"#.utf8)).payloads.count, 0)
    }
}
