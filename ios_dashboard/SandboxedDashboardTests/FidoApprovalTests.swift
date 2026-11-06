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

    private func payload(id: String, expiresAt: String = "2026-10-19T12:00:30.500Z") -> [String: Any] {
        var copy = event
        copy["request_id"] = id
        copy["expires_at"] = expiresAt
        return copy
    }

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
        let state = FidoApprovalState(respond: { _, _ in }, fetchPending: { [] }, authenticate: { _ in nil }, persistRules: false)
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

    @MainActor
    func testRemoveResolvedRequestClearsStaleHeadErrorForNextQueuedPrompt() {
        let state = FidoApprovalState(respond: { _, _ in }, fetchPending: { [] }, authenticate: { _ in nil }, persistRules: false)
        let firstId = "6f1c0e8a-0000-4000-8000-000000000001"
        let secondId = "6f1c0e8a-0000-4000-8000-000000000002"

        state.handleSignRequest(payload(id: firstId))
        state.lastError = "Authentication cancelled or failed."
        state.handleSignRequest(payload(id: secondId))
        XCTAssertEqual(state.pendingRequests.count, 2)
        XCTAssertEqual(state.lastError, "Authentication cancelled or failed.")

        state.removeResolvedRequest(firstId)
        XCTAssertEqual(state.pendingRequests.map(\.id), [secondId])
        XCTAssertNil(state.lastError)
    }

    @MainActor
    func testQueuedRequestErrorsStayIsolatedPerRequestId() async {
        var outcomes: [String: Result<Void, Error>] = [
            "r1": .failure(OrbHTTPError(status: 503, detail: "gateway timeout")),
            "r2": .failure(OrbHTTPError(status: 502, detail: "upstream down")),
        ]
        var authMessage: String? = nil
        let state = FidoApprovalState(
            respond: { id, _ in try outcomes[id]?.get() },
            fetchPending: { [] },
            authenticate: { _ in authMessage },
            persistRules: false
        )

        state.handleSignRequest(payload(id: "r1"))
        await state.approve("r1")
        XCTAssertEqual(state.lastError, "503: gateway timeout")

        state.handleSignRequest(payload(id: "r2"))
        state.handleSignRequest(payload(id: "r3"))
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(state.lastError, "503: gateway timeout")

        await state.approve("r2")
        XCTAssertEqual(state.lastError, "503: gateway timeout")

        outcomes["r3"] = .success(())
        await state.deny("r3")
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r1", "r2"])
        XCTAssertEqual(state.lastError, "503: gateway timeout")

        authMessage = ""
        await state.approveWithAuthentication("r1")
        XCTAssertEqual(state.lastError, "503: gateway timeout")

        outcomes["r1"] = .success(())
        authMessage = nil
        await state.approveWithAuthentication("r1")
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r2"])
        XCTAssertEqual(state.lastError, "502: upstream down")

        outcomes["r2"] = .failure(OrbHTTPError(status: 404, detail: "Not Found"))
        await state.deny("r2")
        XCTAssertTrue(state.pendingRequests.isEmpty)
        XCTAssertNil(state.lastError)
    }

    @MainActor
    func testDropExpiredAndSyncPendingPruneCleanExpiredWhileKeepingRetryableAndInFlight() async {
        let beforeExpiry = Date(timeIntervalSince1970: 1_792_411_200)
        let afterExpiry = Date(timeIntervalSince1970: 1_792_411_300)
        let futureIso = "2026-10-19T12:05:00Z"

        var respondResult: Result<Void, Error> = .failure(OrbHTTPError(status: 503, detail: "temporary outage"))
        var pendingOnHub: [[String: Any]] = []
        var onFetchPending: (@MainActor () -> Void)?

        let state = FidoApprovalState(
            respond: { _, _ in try respondResult.get() },
            fetchPending: {
                onFetchPending?()
                return pendingOnHub
            },
            authenticate: { _ in nil },
            persistRules: false
        )

        state.handleSignRequest(payload(id: "expired-clean"))
        state.handleSignRequest(payload(id: "expired-errored"))
        state.handleSignRequest(payload(id: "expired-inflight"))
        state.handleSignRequest(payload(id: "still-valid", expiresAt: futureIso))

        await state.approve("expired-errored")
        state.inFlightRequestIds.insert("expired-inflight")

        state.dropExpired(now: beforeExpiry)
        XCTAssertEqual(state.pendingRequests.count, 4)

        state.dropExpired(now: afterExpiry)
        XCTAssertEqual(state.pendingRequests.map(\.id), ["expired-errored", "expired-inflight", "still-valid"])

        pendingOnHub = [
            payload(id: "expired-on-hub"),
            payload(id: "fresh-from-hub", expiresAt: futureIso),
        ]
        onFetchPending = {
            state.handleSignRequest(self.payload(id: "arrived-mid-fetch", expiresAt: futureIso))
        }

        await state.syncPending(now: afterExpiry)
        XCTAssertEqual(
            state.pendingRequests.map(\.id),
            ["expired-errored", "expired-inflight", "arrived-mid-fetch", "fresh-from-hub"]
        )

        state.inFlightRequestIds.remove("expired-inflight")
        state.dropExpired(now: afterExpiry)
        XCTAssertEqual(state.pendingRequests.map(\.id), ["expired-errored", "arrived-mid-fetch", "fresh-from-hub"])

        respondResult = .failure(OrbHTTPError(status: 410, detail: "Gone"))
        await state.approve("expired-errored")
        XCTAssertEqual(state.pendingRequests.map(\.id), ["arrived-mid-fetch", "fresh-from-hub"])
        XCTAssertNil(state.lastError)
    }
}
