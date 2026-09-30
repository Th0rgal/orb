import XCTest
@testable import sandboxed_sh

@MainActor
final class OrbSettingsTests: XCTestCase {
    func testSSHAddressValidationAndRevision() throws {
        var address = OrbSSHAddress(id: "node", revision: 3, name: "Spark", host: "spark.local", user: "thomas", port: 22, note: "GPU")
        XCTAssertTrue(address.valid)
        XCTAssertEqual(address.body["revision"], .number(3))
        address.port = 65536; XCTAssertFalse(address.valid)
        address.port = 22; address.host = "host; command"; XCTAssertFalse(address.valid)
        address.host = "2001:db8::1"; XCTAssertTrue(address.valid)
        address.user = "-oProxyCommand"; XCTAssertFalse(address.valid)
    }
    func testQuotaUnitsAndRemainingPercent() {
        let values: OrbJSON = .object(["unified_5h_utilization": .number(0.4), "codex_primary_used_percent": .number(20), "minimax_weekly_remaining_percent": .number(70)])
        let windows = OrbProviderQuota.windows(values)
        XCTAssertEqual(windows.map(\.0), ["5h", "Primary", "Weekly"])
        XCTAssertEqual(windows[0].1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(windows[1].1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(windows[2].1, 0.3, accuracy: 0.0001)
        XCTAssertTrue(OrbProviderQuota.windows(.null).isEmpty)
    }
    func testOAuthUsesCredentialOwner() {
        let proxy: OrbJSON = .object(["id": .string("account"), "name": .string("OpenAI"), "provider_type": .string("openai"), "uses_oauth": .bool(true), "credential_owner": .string("cli_proxy")])
        XCTAssertTrue(OrbProvidersSettings.loginSpec(proxy)?.proxy == true)
        let foreign: OrbJSON = .object(["provider_type": .string("openai"), "uses_oauth": .bool(true), "credential_owner": .string("external")])
        XCTAssertNil(OrbProvidersSettings.loginSpec(foreign))
    }
    func testSettingsClientRejectsAnOldConnectionBeforeSending() async {
        let generation = APIService.shared.connectionGeneration
        defer { APIService.shared.connectionGeneration = generation }
        let client = OrbSettingsClient()
        APIService.shared.connectionGeneration += 1
        do { _ = try await client.call("/should-not-send"); XCTFail("Old connection should not send") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testKimiUsesNativeDeviceFlowAndAPIKeysRemainEditable() {
        XCTAssertFalse(OrbProviderKeyEditor.apiKeyTypes.contains("kimi"))
        XCTAssertFalse(OrbProvidersSettings.subscriptionLogin("kimi").proxy)
        XCTAssertTrue(OrbProvidersSettings.subscriptionTypes.contains("google"))
        XCTAssertFalse(OrbProvidersSettings.subscriptionLogin("google").proxy)
        let kimi: OrbJSON = .object(["id": .string("kimi-account"), "provider_type": .string("kimi"), "uses_oauth": .bool(true), "credential_owner": .string("sandboxed_sh")])
        XCTAssertEqual(OrbProvidersSettings.loginSpec(kimi)?.id, "kimi-account")
        XCTAssertEqual(OrbProvidersSettings.loginSpec(kimi)?.proxy, false)
        for type in ["anthropic", "openai", "google", "xai"] {
            let account: OrbJSON = .object(["provider_type": .string(type), "uses_oauth": .bool(true), "has_api_key": .bool(true), "has_oauth": .bool(false)])
            XCTAssertTrue(OrbProvidersSettings.canEditKey(account))
            XCTAssertFalse(OrbProvidersSettings.canConnectOAuth(account))
        }
        XCTAssertFalse(OrbProvidersSettings.canEditKey(kimi))
        XCTAssertTrue(OrbProvidersSettings.canConnectOAuth(kimi))
        let dual: OrbJSON = .object(["provider_type": .string("openai"), "uses_oauth": .bool(true), "has_api_key": .bool(true), "has_oauth": .bool(true)])
        XCTAssertTrue(OrbProvidersSettings.canEditKey(dual))
        XCTAssertTrue(OrbProvidersSettings.canConnectOAuth(dual))
    }

}
