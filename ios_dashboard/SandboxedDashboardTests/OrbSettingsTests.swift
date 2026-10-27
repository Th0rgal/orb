import XCTest
@testable import sandboxed_sh

@MainActor
final class OrbSettingsTests: XCTestCase {
    /// Core trims messages, so a keyboard's trailing space must not leave the
    /// optimistic bubble next to the stored copy.
    func testOptimisticMessageMatchesTrimmedCoreCopy() {
        XCTAssertTrue(OrbConversation.sameMessage("Vas y ", "Vas y"))
        XCTAssertTrue(OrbConversation.sameMessage("\nVas y\n", "Vas y"))
        XCTAssertFalse(OrbConversation.sameMessage("Vas y", "Vas-y"))
    }
    func testUsageLimitStatusMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/usage-limit-status.json")
        let cases = try XCTUnwrap(spec["cases"] as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: c["usage"] ?? [:])
            let usage = try JSONDecoder().decode(OrbJSON.self, from: data)
            let got = OrbUsageLimitStatus.from(usage, now: try XCTUnwrap(c["nowSec"] as? Double))
            if let expected = c["expected"] as? [String: String] {
                XCTAssertEqual(got?.tone.rawValue, expected["tone"], name)
                XCTAssertEqual(got?.label, expected["label"], name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }
    /// Same five sections, names, subtitles and tab labels as desktop (`settings-nav.json`).
    func testSettingsNavMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/settings-nav.json")
        let sections = try XCTUnwrap(spec["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.map { $0["id"] as? String }, OrbSettingsSection.allCases.map(\.rawValue))
        for (json, section) in zip(sections, OrbSettingsSection.allCases) {
            XCTAssertEqual(json["label"] as? String, section.label)
            XCTAssertEqual(json["subtitle"] as? String, section.subtitle)
            let tabs = Dictionary(uniqueKeysWithValues: try XCTUnwrap(json["tabs"] as? [[String: String]]).map { ($0["id"]!, $0["label"]!) })
            for page in section.pages where tabs[page.id] != nil { XCTAssertEqual(page.label, tabs[page.id], page.id) }
        }
        for c in try XCTUnwrap(spec["attention"] as? [[String: Any]]) {
            let s = try XCTUnwrap(c["state"] as? [String: Bool])
            let got = OrbSettingsSection.attention(bunkerActive: s["bunkerActive"]!, deviceEnrolled: s["deviceEnrolled"]!, quotaExhausted: s["quotaExhausted"]!)
            XCTAssertEqual(Set(got.map(\.rawValue)), Set(c["expected"] as? [String] ?? []), c["name"] as? String ?? "?")
        }
    }
    func testSkillsRepoLineNamesTheRepoAndSyncAge() {
        let status = OrbJSON.object(["remote": .string("git@github.com:Th0rgal/sandboxed-library.git"), "last_synced_at": .number(1_000)])
        XCTAssertEqual(OrbSkillsSettings.repoLine(status, now: 1_120), "Th0rgal/sandboxed-library · synced 2m ago")
        XCTAssertEqual(OrbSkillsSettings.repoLine(.object(["remote": .string("https://github.com/Th0rgal/sandboxed-library")]), now: 0), "Th0rgal/sandboxed-library · not synced yet")
        XCTAssertEqual(OrbSkillsSettings.repoLine(nil), "Library")
    }
    func testUsageSpendPerDayAndTopMissionsByCost() {
        let s = OrbJSON.object([
            "by_day": .array([.object(["day": .string("2026-10-25"), "cost_cents": .number(250)]), .object(["day": .string("2026-10-26"), "cost_cents": .number(1200)])]),
            "by_mission": .array([.object(["key": .string("a"), "label": .string("Cheap"), "cost_cents": .number(10), "requests": .number(2)]),
                                  .object(["key": .string("b"), "label": .string("Pricey"), "cost_cents": .number(900), "requests": .number(40)])]),
        ])
        XCTAssertEqual(OrbUsageSettings.days(s).map(\.usd), [2.5, 12])
        XCTAssertEqual(OrbUsageSettings.days(s).map(\.label), ["10-25", "10-26"])
        XCTAssertEqual(OrbUsageSettings.topMissions(s).map(\.name), ["Pricey", "Cheap"])
    }
    func testSkillDeleteFailureIsInPlainWords() {
        XCTAssertEqual(OrbSkillsSettings.deleteMessage("agent-browser", "500 git commit failed: gpg failed to sign the data"), "Core couldn’t sign the Library commit, so agent-browser is still there.")
        XCTAssertEqual(OrbSkillsSettings.deleteMessage("x", "503 Service Unavailable"), "Couldn’t delete x: Service Unavailable")
    }
    func testQuotaExhaustedLabelMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/quota-exhausted.json")
        let cases = try XCTUnwrap(spec["cases"] as? [[String: Any]])
        for c in cases {
            let windows = try XCTUnwrap(c["windows"] as? [[String: Any]]).map { ($0["label"] as? String ?? "", ($0["used"] as? NSNumber)?.doubleValue ?? 0) }
            let expected = (c["expected"] as? [String: Any]).map { OrbQuotaStatus(level: OrbQuotaLevel(rawValue: $0["level"] as? String ?? "")!, label: $0["label"] as? String ?? "", accountWide: $0["accountWide"] as? Bool ?? false) }
            XCTAssertEqual(OrbProviderQuota.quotaStatus(windows), expected, c["name"] as? String ?? "?")
        }
    }
    func testQuotaLevelMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/quota-level.json")
        for c in try XCTUnwrap(spec["cases"] as? [[String: Any]]) {
            let used = (c["used"] as? NSNumber)?.doubleValue
            XCTAssertEqual(OrbQuotaLevel.of(used, hasReset: c["hasReset"] as? Bool ?? false).rawValue, c["expected"] as? String, c["name"] as? String ?? "?")
        }
    }
    func testAntigravityResetWithoutFigureIsSpent() {
        let value: OrbJSON = .object(["antigravity_windows": .array([.object(["label": .string("Gemini · 5h"), "reset_at": .number(2_000_000_000)])])])
        XCTAssertEqual(OrbProviderQuota.windows(value).map(\.1), [1])
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
        let generation = OrbCore.shared.connectionGeneration
        defer { OrbCore.shared.connectionGeneration = generation }
        let client = OrbSettingsClient()
        OrbCore.shared.connectionGeneration += 1
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
