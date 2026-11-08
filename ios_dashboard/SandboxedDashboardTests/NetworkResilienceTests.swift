//
//  NetworkResilienceTests.swift
//  SandboxedDashboardTests
//
//  Coverage for the bad-network paths reworked in the May 2026 hardening
//  pass: SSE parser correctness, request timeout enforcement, and the
//  UserDefaults→filesystem cache migration. Each test pins a behaviour the
//  user explicitly called out (cold-start latency, large JSON, byte-level
//  stream corruption) so future regressions surface immediately.
//

import XCTest
@testable import sandboxed_sh

final class NetworkResilienceTests: XCTestCase {

    // MARK: - URLSession configuration

    /// The dedicated JSON session must override URLSession.shared's 60s
    /// request / 7d resource defaults. Previously the cold-start chain
    /// could stall the UI behind "Connecting…" for a full minute on a
    /// black-hole host. The bound here is 15s/60s — large enough for a
    /// big mission tail on cellular, small enough that the user sees
    /// feedback if the server is gone.
    func testRequestTimeoutIsBounded() {
        XCTAssertLessThanOrEqual(OrbCore.requestTimeout, 15)
        XCTAssertGreaterThanOrEqual(OrbCore.requestTimeout, 5)
        XCTAssertLessThanOrEqual(OrbCore.resourceTimeout, 90)
    }

    /// SSE inactivity threshold drives the URLSession.timeoutIntervalForRequest
    /// on the streaming session — a healthy stream resets it on every byte;
    /// a half-open socket (cell→wifi handoff, NAT idle reset) errors out
    /// within this window so the reconnect loop fires.
    func testStreamInactivityTimeoutIsBounded() {
        XCTAssertLessThanOrEqual(OrbCore.streamInactivityTimeout, 60)
        XCTAssertGreaterThanOrEqual(OrbCore.streamInactivityTimeout, 10)
    }

    /// SSE buffer cap exists at all — without it a server that never emits
    /// a blank line could grow the parser buffer unbounded.
    func testStreamBufferCapIsBounded() {
        XCTAssertLessThanOrEqual(OrbCore.streamMaxBufferBytes, 4 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(OrbCore.streamMaxBufferBytes, 64 * 1024)
    }

    /// A missing/blank saved server URL must not silently connect to a
    /// developer-specific backend. Unless a build explicitly supplies
    /// `SandboxedDefaultAPIBaseURL`, first launch should show setup instead of
    /// marking the API as configured.
    @MainActor
    func testBlankBaseURLRequiresConfigurationWhenNoBundleDefaultExists() {
        let defaults = UserDefaults.standard
        let key = "api_base_url"
        let original = defaults.string(forKey: key)

        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // A new client reads saved configuration once; changing UserDefaults
        // behind the shared client's endpoint cache does not model first launch.
        defaults.removeObject(forKey: key)
        let missing = OrbCore()
        XCTAssertEqual(missing.baseURL, OrbCore.defaultBaseURL)
        XCTAssertEqual(OrbCore.defaultBaseURL, "")
        XCTAssertFalse(missing.isConfigured)

        defaults.set("   ", forKey: key)
        let blank = OrbCore()
        XCTAssertEqual(blank.baseURL, OrbCore.defaultBaseURL)
        XCTAssertFalse(blank.isConfigured)
    }

    /// One error type for every backend request: HTTP failures keep the
    /// "status: detail" text, transport failures keep their old messages.
    func testOrbHTTPErrorIsTheSingleErrorType() {
        XCTAssertEqual(OrbHTTPError(status: 404, detail: "Not Found").errorDescription, "404: Not Found")
        XCTAssertEqual(OrbHTTPError.unauthorized.status, 401)
        XCTAssertEqual(OrbHTTPError.unauthorized.errorDescription, "Authentication required")
        XCTAssertEqual(OrbHTTPError.invalidURL.errorDescription, "Invalid URL")
        XCTAssertEqual(ErrorRing.status(of: OrbHTTPError.unauthorized), 401)
        XCTAssertNil(ErrorRing.status(of: OrbHTTPError.invalidResponse))
        XCTAssertTrue(ErrorRing.isNetworkLayer(OrbHTTPError.decoding(URLError(.cannotParseResponse))))
    }

    func testDebugInfoDescribesBackendVersion() {
        XCTAssertEqual(OrbDebugInfoView.describeBackend("0.42.1"), "0.42.1")
        XCTAssertEqual(OrbDebugInfoView.describeBackend(nil), "Unknown")
        XCTAssertEqual(OrbDebugInfoView.describeBackend(""), "Unknown")
    }

    func testTransportEpochFallsBackEvenAfterEverReadyAndReprobesAfterCooldown() {
        var epoch = OrbTransportEpochState()
        let base = "https://agent-backend.thomas.md"
        XCTAssertEqual(epoch.evaluateForConnect(url: base, nowMs: 1_000, sinceSeq: 0).allowWebSocket, true)
        epoch.noteWsReady(nowMs: 1_100)
        XCTAssertTrue(epoch.everReady)

        let f1 = epoch.noteWsFailure(httpStatus: nil, nowMs: 2_000, sinceSeq: 0)
        XCTAssertFalse(f1.fallbackToSse)
        XCTAssertEqual(f1.sinceSeq, 0)
        let f2 = epoch.noteWsFailure(httpStatus: nil, nowMs: 3_000, sinceSeq: 42)
        XCTAssertFalse(f2.fallbackToSse)
        let f3 = epoch.noteWsFailure(httpStatus: nil, nowMs: 4_000, sinceSeq: 42)
        XCTAssertTrue(f3.fallbackToSse, "everReady must not wedge SSE fallback at 3 transient WS failures")
        XCTAssertEqual(f3.sinceSeq, 42)
        XCTAssertEqual(epoch.mode, OrbTransportEpochState.modeSseFallback)

        let duringCooldown = epoch.evaluateForConnect(url: base, nowMs: 33_999, sinceSeq: 99)
        XCTAssertFalse(duringCooldown.allowWebSocket)
        XCTAssertEqual(duringCooldown.sinceSeq, 99)
        XCTAssertEqual(epoch.reprobeDelayMs(nowMs: 33_999), 1)

        let highSeq = Int64(UInt32.max) + 77
        let reprobe = epoch.evaluateForConnect(url: base, nowMs: 34_000, sinceSeq: highSeq)
        XCTAssertTrue(reprobe.allowWebSocket)
        XCTAssertEqual(reprobe.sinceSeq, highSeq)
        XCTAssertEqual(epoch.mode, OrbTransportEpochState.modeWsReprobe)
        XCTAssertNil(epoch.reprobeDelayMs(nowMs: 34_000))

        let reprobeFail = epoch.noteWsFailure(httpStatus: nil, nowMs: 34_500, sinceSeq: highSeq)
        XCTAssertTrue(reprobeFail.fallbackToSse)
        XCTAssertEqual(reprobeFail.sinceSeq, highSeq)
        XCTAssertEqual(epoch.reprobeDelayMs(nowMs: 34_500), 30_000)

        let reprobe2 = epoch.evaluateForConnect(url: base, nowMs: 64_500, sinceSeq: highSeq)
        XCTAssertTrue(reprobe2.allowWebSocket)
        XCTAssertEqual(reprobe2.sinceSeq, highSeq)
        epoch.noteWsReady(nowMs: 64_600)
        XCTAssertEqual(epoch.mode, OrbTransportEpochState.modeWsActive)
        XCTAssertEqual(epoch.failureStreak, 0)
    }

    func testTransportEpochStickyHttpUnsupportedClearsOnBuildOrEndpointChange() {
        var epoch = OrbTransportEpochState()
        let customA = "https://orb-a.example.com"
        let customB = "https://orb-b.example.com"
        _ = epoch.applyEndpoint(customA, nowMs: 1_000)
        _ = epoch.noteServerBuild("0.9.0", nowMs: 1_000)

        let unsupported = epoch.noteWsFailure(httpStatus: 404, nowMs: 2_000, sinceSeq: 17)
        XCTAssertTrue(unsupported.fallbackToSse)
        XCTAssertTrue(epoch.stickyUnsupported)
        XCTAssertNil(epoch.reprobeDelayMs(nowMs: 2_000))
        XCTAssertEqual(unsupported.sinceSeq, 17)
        XCTAssertFalse(epoch.evaluateForConnect(url: customA, nowMs: 500_000, sinceSeq: 17).allowWebSocket)

        let upgradedSeq = epoch.noteServerBuild("0.10.0", nowMs: 500_100, sinceSeq: 18)
        XCTAssertEqual(upgradedSeq, 18)
        XCTAssertFalse(epoch.stickyUnsupported)
        XCTAssertTrue(epoch.evaluateForConnect(url: customA, nowMs: 500_200, sinceSeq: 18).allowWebSocket)

        _ = epoch.noteWsFailure(httpStatus: 426, nowMs: 500_500, sinceSeq: 19)
        XCTAssertTrue(epoch.stickyUnsupported, "HTTP 426 Upgrade Required latches sticky unsupported until build/endpoint changes")
        XCTAssertNil(epoch.reprobeDelayMs(nowMs: 500_500))
        _ = epoch.noteServerBuild("0.10.1", nowMs: 500_600, sinceSeq: 19)
        XCTAssertFalse(epoch.stickyUnsupported)

        _ = epoch.noteWsFailure(httpStatus: 501, nowMs: 501_000, sinceSeq: 20)
        XCTAssertTrue(epoch.stickyUnsupported)
        let switched = epoch.evaluateForConnect(url: customB, nowMs: 501_100, sinceSeq: 20)
        XCTAssertTrue(switched.allowWebSocket, "switching between distinct custom endpoints resets sticky fallback")
        XCTAssertFalse(epoch.stickyUnsupported)
        XCTAssertEqual(switched.sinceSeq, 20)
    }
}
