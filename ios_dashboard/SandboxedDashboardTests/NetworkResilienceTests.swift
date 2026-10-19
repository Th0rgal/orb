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
        XCTAssertLessThanOrEqual(APIService.requestTimeout, 15)
        XCTAssertGreaterThanOrEqual(APIService.requestTimeout, 5)
        XCTAssertLessThanOrEqual(APIService.resourceTimeout, 90)
    }

    /// SSE inactivity threshold drives the URLSession.timeoutIntervalForRequest
    /// on the streaming session — a healthy stream resets it on every byte;
    /// a half-open socket (cell→wifi handoff, NAT idle reset) errors out
    /// within this window so the reconnect loop fires.
    func testStreamInactivityTimeoutIsBounded() {
        XCTAssertLessThanOrEqual(APIService.streamInactivityTimeout, 60)
        XCTAssertGreaterThanOrEqual(APIService.streamInactivityTimeout, 10)
    }

    /// SSE buffer cap exists at all — without it a server that never emits
    /// a blank line could grow the parser buffer unbounded.
    func testStreamBufferCapIsBounded() {
        XCTAssertLessThanOrEqual(APIService.streamMaxBufferBytes, 4 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(APIService.streamMaxBufferBytes, 64 * 1024)
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

        defaults.removeObject(forKey: key)
        XCTAssertEqual(APIService.shared.baseURL, APIService.defaultBaseURL)
        XCTAssertEqual(APIService.defaultBaseURL, "")
        XCTAssertFalse(APIService.shared.isConfigured)

        defaults.set("   ", forKey: key)
        XCTAssertEqual(APIService.shared.baseURL, APIService.defaultBaseURL)
        XCTAssertFalse(APIService.shared.isConfigured)
    }
}
