import XCTest
@testable import sandboxed_sh

@MainActor
final class OrbSettingsTests: XCTestCase {
    func testR32SignInAgainSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/provider-login-health.json")
        let status = try XCTUnwrap(spec["expected_status"] as? String)
        XCTAssertEqual(OrbProvidersSettings.loginStatusLabel(status), spec["expected_label"] as? String)
        XCTAssertNil(OrbProvidersSettings.loginStatusLabel("connected"))
    }
    func testRoutingProviderAliasesMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/routing-provider.json")
        let data = try JSONSerialization.data(withJSONObject: spec["catalog"] as Any)
        let catalog = try JSONDecoder().decode([OrbJSON].self, from: data)
        for c in try XCTUnwrap(spec["cases"] as? [[String: Any]]) {
            let id = try XCTUnwrap(c["id"] as? String)
            XCTAssertEqual(OrbRoutingProvider.find(catalog, id)?.selfID, c["canonical"] as? String)
            XCTAssertEqual(OrbRoutingProvider.label(catalog, id), c["label"] as? String)
        }
    }
    private func orbJSON(_ value: Any?) throws -> OrbJSON {
        let data = try JSONSerialization.data(withJSONObject: [value ?? NSNull()])
        return try XCTUnwrap(JSONDecoder().decode([OrbJSON].self, from: data).first)
    }
    func testAccountConnectionMatchesSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/account-vpn.json")
        let routes = try XCTUnwrap(spec["routes"] as? [[String: Any]])
        XCTAssertFalse(routes.isEmpty)
        for c in routes {
            let name = try XCTUnwrap(c["name"] as? String)
            let payload = try orbJSON(c["payload"])
            let route = try XCTUnwrap(OrbAccountVpn.route(payload), name)
            let native = try XCTUnwrap(c["native"] as? Bool)
            let expected = try XCTUnwrap(c["view"] as? [String: Any])
            let view = OrbAccountVpn.View(
                selected: try XCTUnwrap(expected["selected"] as? String),
                countries: try XCTUnwrap(expected["countries"] as? [String]),
                editable: try XCTUnwrap(expected["editable"] as? Bool),
                confirmDirect: try XCTUnwrap(expected["confirm_direct"] as? Bool),
                notice: try XCTUnwrap(expected["notice"] as? String),
                status: try XCTUnwrap(expected["status"] as? String),
                retry: try XCTUnwrap(expected["retry"] as? Bool),
                poll: try XCTUnwrap(expected["poll"] as? Bool))
            XCTAssertEqual(OrbAccountVpn.view(route, nativeAccount: native), view, name)
        }
        let invalid = try XCTUnwrap(spec["invalid_routes"] as? [Any])
        XCTAssertFalse(invalid.isEmpty)
        for value in invalid {
            let payload = try orbJSON(value)
            XCTAssertNil(OrbAccountVpn.route(payload), "\(value)")
        }
        let writes = try XCTUnwrap(spec["writes"] as? [[String: Any]])
        XCTAssertFalse(writes.isEmpty)
        for c in writes {
            let country = try XCTUnwrap(c["country"] as? String)
            let body = try orbJSON(c["body"])
            XCTAssertEqual(OrbAccountVpn.write(country), body, country)
        }
    }
    func testAccountConnectionRequestsMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/account-vpn.json")
        let cases = try XCTUnwrap(spec["requests"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            var requests = OrbAccountVpn.Requests()
            for step in try XCTUnwrap(c["steps"] as? [[String: Any]]) {
                if let kind = step["start"] as? String {
                    let started = requests.start(write: kind == "write")
                    XCTAssertEqual(started?.latest, step["request"] as? Int, name)
                    requests = started ?? requests
                } else if let request = step["current"] as? Int {
                    let expected = try XCTUnwrap(step["is"] as? Bool)
                    XCTAssertEqual(requests.current(request), expected, name)
                } else {
                    XCTAssertNotNil(step["saved"], name)
                    requests = requests.saved()
                }
                if let saving = step["saving"] as? Bool { XCTAssertEqual(requests.saving, saving, name) }
            }
        }
    }
    func testAccountSettingReadErrorsAndRouterAccessMatchSharedFixture() throws {
        let spec = try OrbSpec.json("fixtures/account-vpn.json")
        let labels = try XCTUnwrap(spec["labels"] as? [String: String])
        XCTAssertEqual(labels, [
            "vpn_update": OrbAccountVpn.Labels.vpnUpdate, "router_update": OrbAccountVpn.Labels.routerUpdate,
            "route_unavailable": OrbAccountVpn.Labels.routeUnavailable, "router_unavailable": OrbAccountVpn.Labels.routerUnavailable,
            "router_unconfirmed": OrbAccountVpn.Labels.routerUnconfirmed,
        ])
        let update = OrbAccountVpn.Labels.vpnUpdate
        let unavailable = OrbAccountVpn.Labels.routeUnavailable
        let errors = try XCTUnwrap(spec["read_errors"] as? [[String: Any]])
        XCTAssertFalse(errors.isEmpty)
        for c in errors {
            let name = try XCTUnwrap(c["name"] as? String)
            let status = try XCTUnwrap(c["status"] as? Int)
            let body = try XCTUnwrap(c["body"] as? String)
            let path = try XCTUnwrap(c["path"] as? String)
            let missing = try XCTUnwrap(c["missing_endpoint"] as? Bool)
            XCTAssertEqual(OrbAccountVpn.missingSetting(status: status, body: body, path: path), missing, name)
            let shown = OrbAccountVpn.readError(OrbHTTPError(status: status, detail: body), path: path, update: update, unavailable: unavailable)
            XCTAssertEqual(shown, missing ? update : unavailable, name)
        }
        XCTAssertEqual(OrbAccountVpn.readError(URLError(.timedOut), path: "/api/ai/providers/a/vpn", update: update, unavailable: unavailable), unavailable)
        let access = try XCTUnwrap(spec["router_access"] as? [[String: Any]])
        XCTAssertFalse(access.isEmpty)
        for c in access {
            let payload = try orbJSON(c["payload"])
            XCTAssertEqual(OrbAccountVpn.routerAccess(payload), c["allowed"] as? Bool, "\(c)")
        }
    }
    func testInboxSummaryChoiceMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/inbox-summary-choice.json")
        for c in try XCTUnwrap(spec["cases"] as? [[String: Any]]) {
            var model = try XCTUnwrap(c["initial"] as? String)
            let choices = try XCTUnwrap(c["choices"] as? [String])
            let expected = try XCTUnwrap(c["expected"] as? [[String: Any]])
            for (index, choice) in choices.enumerated() {
                let result = OrbInboxSummaryChoice.apply(model: model, choice: choice)
                XCTAssertEqual(result.aiSummary, expected[index]["aiSummary"] as? Bool)
                XCTAssertEqual(result.model, expected[index]["model"] as? String)
                model = result.model
            }
        }
    }
    func testInboxPolicyMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/inbox-summary-policy.json")
        XCTAssertEqual(OrbInboxPolicy.ecoQuietMs, (spec["ecoQuietMs"] as? NSNumber)?.doubleValue)
        for c in try XCTUnwrap(spec["normalization"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let got = OrbInboxPolicy.normalize(try XCTUnwrap(c["input"] as? [String: Any]))
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            XCTAssertEqual(got.inboxEnabled, expected["inboxEnabled"] as? Bool, name)
            XCTAssertEqual(got.includeAutonomous, expected["includeAutonomous"] as? Bool, name)
            XCTAssertEqual(got.aiSummary, expected["aiSummary"] as? Bool, name)
            XCTAssertEqual(got.summaryMode.rawValue, expected["summaryMode"] as? String, name)
            XCTAssertEqual(got.model, expected["model"] as? String, name)
        }
        for g in try XCTUnwrap(spec["gates"] as? [[String: Any]]) {
            let name = g["name"] as? String ?? "?"
            let prefs = try XCTUnwrap(g["prefs"] as? [String: Any])
            let norm = OrbInboxPolicy.normalize(prefs)
            let got = OrbInboxPolicy.shouldRequestDigest(
                inboxEnabled: norm.inboxEnabled,
                aiSummary: norm.aiSummary,
                summaryMode: norm.summaryMode,
                surface: try XCTUnwrap(g["surface"] as? String),
                isLive: try XCTUnwrap(g["isLive"] as? Bool),
                updatedMs: try XCTUnwrap((g["updatedMs"] as? NSNumber)?.doubleValue),
                nowMs: try XCTUnwrap((g["nowMs"] as? NSNumber)?.doubleValue)
            )
            XCTAssertEqual(got, g["expected"] as? Bool, name)
        }
    }
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
            let got = OrbSettingsSection.attention(bunkerActive: s["bunkerActive"]!, deviceEnrolled: s["deviceEnrolled"]!)
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

        let promax: OrbJSON = .object([
            "codex_plan_type": .string("promax"),
            "codex_primary_used_percent": .number(12),
            "codex_primary_window_minutes": .number(10080),
            "codex_secondary_used_percent": .number(68),
            "codex_secondary_window_minutes": .number(10080),
        ])
        let promaxWindows = OrbProviderQuota.windows(promax)
        XCTAssertEqual(promaxWindows.map(\.0), ["Weekly", "Weekly (secondary)"])
        XCTAssertEqual(promaxWindows[0].1, 0.12, accuracy: 0.0001)
        XCTAssertEqual(promaxWindows[1].1, 0.68, accuracy: 0.0001)

        let named: OrbJSON = .object([
            "codex_plan_type": .string("promax"),
            "codex_primary_used_percent": .number(12),
            "codex_primary_window_minutes": .number(10080),
            "codex_primary_window_label": .string("General"),
            "codex_secondary_used_percent": .number(68),
            "codex_secondary_window_minutes": .number(10080),
            "codex_secondary_window_label": .string("Codex"),
        ])
        XCTAssertEqual(OrbProviderQuota.windows(named).map(\.0), ["General", "Codex"])
    }
    func testUnverifiedAntigravityAccountOpensGoogleVerification() {
        let refused: OrbJSON = .object(["status": .string("needs_verification"), "verification_url": .string("https://accounts.google.com/signin/continue?sarp=1")])
        XCTAssertEqual(OrbProvidersSettings.verificationURL(refused, email: "new@gmail.com").absoluteString, "https://accounts.google.com/signin/continue?sarp=1")
        XCTAssertEqual(OrbProvidersSettings.verificationURL(.null, email: "new@gmail.com").absoluteString, "https://accounts.google.com/AccountChooser?continue=https://antigravity.google/&Email=new@gmail.com")
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
    func testKimiSubscriptionsUseProxyAndLegacyNativeAccountsRemainEditable() {
        XCTAssertFalse(OrbProviderKeyEditor.apiKeyTypes.contains("kimi"))
        XCTAssertTrue(OrbProvidersSettings.subscriptionLogin("kimi").proxy)
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

    func testSubscriptionResetsMatchSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/subscription-resets.json")
        for c in try XCTUnwrap(spec["supports_cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: c["provider"] ?? [:])
            let provider = try JSONDecoder().decode(OrbJSON.self, from: data)
            XCTAssertEqual(OrbProvidersSettings.supportsSubscriptionReset(provider), c["expected"] as? Bool, name)
        }
        for c in try XCTUnwrap(spec["summary_cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let nowSec = try XCTUnwrap((c["nowSec"] as? NSNumber)?.doubleValue)
            let data = try JSONSerialization.data(withJSONObject: c["usage"] ?? [:])
            let usage = try JSONDecoder().decode(OrbJSON.self, from: data)
            let got = OrbSubscriptionResetSummary.from(usage, now: nowSec)
            if let expected = c["expected"] as? [String: Any] {
                XCTAssertEqual(got?.availableCount, expected["availableCount"] as? Int, name)
                XCTAssertEqual(got?.usableNow, expected["usableNow"] as? Bool, name)
                XCTAssertEqual(got?.badge, expected["badge"] as? String, name)
                XCTAssertEqual(got?.detail, expected["detail"] as? String, name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }

    func testProviderLogosMatchSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/provider-logos.json")
        for c in try XCTUnwrap(spec["cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let type = try XCTUnwrap(c["type"] as? String)
            let providerName = c["providerName"] as? String ?? ""
            let expected = c["expected"] as? String
            XCTAssertEqual(OrbProviderLogo.brandKey(type: type, name: providerName), expected, name)
            if let expected {
                let expectedAsset = "provider-\(expected)"
                XCTAssertEqual(OrbProviderLogo.assetName(type: type, name: providerName), expectedAsset, name)
                XCTAssertNotNil(UIImage(named: expectedAsset), "Missing bundled iOS asset \(expectedAsset)")
            } else {
                XCTAssertNil(OrbProviderLogo.assetName(type: type, name: providerName), name)
            }
        }
    }

    func testCustomProviderKeyEditabilityAndCapParsing() {
        let custom = OrbJSON.object([
            "id": .string("eth-1"),
            "provider_type": .string("custom"),
            "name": .string("Ethereum Foundation"),
            "has_api_key": .bool(true),
            "uses_oauth": .bool(false),
            "rpm_limit": .number(300),
            "max_concurrency": .number(8),
        ])
        XCTAssertTrue(OrbProvidersSettings.canEditKey(custom))
        XCTAssertFalse(OrbProvidersSettings.canConnectOAuth(custom))
        XCTAssertEqual(OrbProviderKeyEditor.parseOptionalCap("  ", min: 1, max: 100_000), .ok(nil))
        XCTAssertEqual(OrbProviderKeyEditor.parseOptionalCap("300", min: 1, max: 100_000), .ok(300))
        XCTAssertEqual(OrbProviderKeyEditor.parseOptionalCap("0", min: 1, max: 100_000), .invalid)
        XCTAssertEqual(OrbProviderKeyEditor.parseOptionalCap("100001", min: 1, max: 100_000), .invalid)
    }

    func testMultiUserUnixUsernameAndFailClosedRBAC() {
        XCTAssertTrue(OrbUsersModel.validUnixUsername("orb_alice"))
        XCTAssertTrue(OrbUsersModel.validUnixUsername("_svc01"))
        XCTAssertFalse(OrbUsersModel.validUnixUsername("1bad"))
        XCTAssertFalse(OrbUsersModel.validUnixUsername("Alice"))
        XCTAssertFalse(OrbUsersModel.validUnixUsername(""))
        XCTAssertEqual(OrbUsersModel.defaultUnixUsernameFor("Alice.Dev"), "orb-alice-dev")

        let savedMode = OrbCore.shared.authMode
        let savedUser = OrbCore.shared.currentUser
        defer {
            OrbCore.shared.authMode = savedMode
            OrbCore.shared.currentUser = savedUser
        }
        OrbCore.shared.authMode = .multiUser
        OrbCore.shared.currentUser = nil
        XCTAssertFalse(OrbCore.shared.isAdminUser, "Multi-user mode must fail closed before /api/auth/me resolves")

        OrbCore.shared.currentUser = OrbCore.CurrentUser(
            id: "u1",
            username: "alice",
            role: "member",
            unixUsername: "orb_alice",
            dailySpendCapCents: 1500,
            spentTodayCents: 325
        )
        XCTAssertFalse(OrbCore.shared.isAdminUser)

        OrbCore.shared.currentUser = OrbCore.CurrentUser(
            id: "u0",
            username: "admin",
            role: "admin",
            unixUsername: "orb_admin",
            dailySpendCapCents: nil,
            spentTodayCents: 0
        )
        XCTAssertTrue(OrbCore.shared.isAdminUser)

        XCTAssertTrue(OrbUsersModel.isLegacySingleTenantFallback(status: 404, authMode: "single_tenant"))
        XCTAssertTrue(OrbUsersModel.isLegacySingleTenantFallback(status: 404, authMode: "disabled"))
        XCTAssertFalse(OrbUsersModel.isLegacySingleTenantFallback(status: 404, authMode: "multi_user"))
        XCTAssertFalse(OrbUsersModel.isLegacySingleTenantFallback(status: 502, authMode: "single_tenant"))
        XCTAssertEqual(OrbUsersModel.resetPasswordPath(for: "usr-1"), "/api/admin/users/usr-1/reset-password")

        let synth = OrbAdminUser.singleTenantAdmin()
        XCTAssertEqual(synth.id, "admin")
        XCTAssertEqual(synth.username, "admin")
        XCTAssertEqual(synth.role, "admin")
        XCTAssertFalse(synth.disabled)
    }

    func testAdminOnlyNodeFilteringAndSharedSenderAttribution() {
        let coreNode: OrbJSON = .object(["id": .string("core"), "status": .string("online")])
        let sparkAdmin: OrbJSON = .object(["id": .string("dgx-spark-admin"), "status": .string("online")])
        let labelledAdmin: OrbJSON = .object(["id": .string("gpu-priv"), "status": .string("online"), "labels": .array([.string("admin-only")])])
        let memberNode: OrbJSON = .object(["id": .string("cpu-worker-1"), "status": .string("online")])
        XCTAssertTrue(OrbManaged.isAdminOnlyNode(coreNode))
        XCTAssertTrue(OrbManaged.isAdminOnlyNode(sparkAdmin))
        XCTAssertTrue(OrbManaged.isAdminOnlyNode(labelledAdmin))
        XCTAssertFalse(OrbManaged.isAdminOnlyNode(memberNode))
        XCTAssertEqual(
            OrbSelection.sortedComputeNodes([coreNode, sparkAdmin, labelledAdmin, memberNode], includeAdminNodes: false).map { $0["id"].text },
            ["cpu-worker-1"]
        )

        let events = [
            StoredEvent(
                id: 1,
                missionId: "m1",
                sequence: 1,
                eventType: "user_message",
                timestamp: "2026-11-08T00:00:00Z",
                eventId: "e1",
                toolCallId: nil,
                toolName: nil,
                content: "Can you check the logs?",
                metadata: ["sender_username": AnyCodable("bob")]
            ),
            StoredEvent(
                id: 2,
                missionId: "m1",
                sequence: 2,
                eventType: "assistant_message",
                timestamp: "2026-11-08T00:00:02Z",
                eventId: "e2",
                toolCallId: nil,
                toolName: nil,
                content: "Checking now.",
                metadata: [:]
            ),
        ]
        let model = OrbTranscriptModel()
        model.events = events
        _ = model.rebuildHistory(isCloud: false, turns: [], mission: .object([:]), optimisticPrompt: nil)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.senderByItemID["turn-0-user"], "bob")
    }

    func testMemberProviderPermissionsBaseUrlAndFriendlyWriteErrors() {
        let sharedAcct: OrbJSON = .object([
            "id": .string("p1"),
            "provider_type": .string("custom"),
            "name": .string("Shared Custom"),
            "has_api_key": .bool(true),
            "uses_oauth": .bool(false),
            "added_by_me": .bool(false),
        ])
        let ownAcct: OrbJSON = .object([
            "id": .string("p2"),
            "provider_type": .string("custom"),
            "name": .string("My Custom"),
            "has_api_key": .bool(true),
            "uses_oauth": .bool(false),
            "added_by_me": .bool(true),
        ])
        let legacyOAuth: OrbJSON = .object([
            "id": .string("p3"),
            "provider_type": .string("openai"),
            "name": .string("OpenAI Legacy"),
            "uses_oauth": .bool(true),
            "credential_owner": .string("sandboxed_sh"),
            "added_by_me": .bool(true),
        ])
        let proxyOAuth: OrbJSON = .object([
            "id": .string("p4"),
            "provider_type": .string("openai"),
            "name": .string("OpenAI Proxy"),
            "uses_oauth": .bool(true),
            "credential_owner": .string("cli_proxy"),
            "added_by_me": .bool(true),
        ])

        XCTAssertFalse(OrbProvidersSettings.canManageProvider(sharedAcct, isAdmin: false))
        XCTAssertTrue(OrbProvidersSettings.canManageProvider(ownAcct, isAdmin: false))
        XCTAssertTrue(OrbProvidersSettings.canManageProvider(sharedAcct, isAdmin: true))
        XCTAssertFalse(OrbProvidersSettings.canEditCredentials(sharedAcct, isAdmin: false))
        XCTAssertTrue(OrbProvidersSettings.canEditCredentials(ownAcct, isAdmin: false))
        XCTAssertFalse(OrbProvidersSettings.canEditBaseUrl(sharedAcct, type: "custom", isAdmin: false))
        XCTAssertTrue(OrbProvidersSettings.canEditBaseUrl(ownAcct, type: "custom", isAdmin: false))
        XCTAssertTrue(OrbProvidersSettings.canEditBaseUrl(nil, type: "custom", isAdmin: false))

        XCTAssertNil(OrbProvidersSettings.loginSpec(sharedAcct, isAdmin: false))
        XCTAssertNil(OrbProvidersSettings.loginSpec(legacyOAuth, isAdmin: false))
        XCTAssertNotNil(OrbProvidersSettings.loginSpec(legacyOAuth, isAdmin: true))
        XCTAssertEqual(OrbProvidersSettings.loginSpec(proxyOAuth, isAdmin: false)?.proxy, true)
        XCTAssertFalse(OrbProvidersSettings.availableSubscriptionTypes(isAdmin: false).contains("google"))
        XCTAssertTrue(OrbProvidersSettings.availableSubscriptionTypes(isAdmin: true).contains("google"))

        XCTAssertTrue(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://api.example.com/v1"))
        XCTAssertTrue(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://100.example.com/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("http://api.example.com/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://localhost:8080/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://svc.internal/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://printer.local/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://127.0.0.1/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://10.0.0.1/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://192.168.1.1/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://172.16.0.1/v1"))
        XCTAssertFalse(OrbProvidersSettings.isMemberCustomBaseUrlAllowed("https://100.64.0.1/v1"))
        XCTAssertTrue(OrbProvidersSettings.isCustomBaseUrlAllowed("http://localhost:11434/v1", isAdmin: true))
        XCTAssertFalse(OrbProvidersSettings.isCustomBaseUrlAllowed("http://localhost:11434/v1", isAdmin: false))

        for code in ["not_account_owner", "base_url_not_allowed", "admin_required", "account_disabled"] {
            let err = OrbHTTPError(status: 403, detail: "{\"error\":\"\(code)\"}")
            let msg = OrbProvidersSettings.providerWriteError(err, fallback: "fallback")
            XCTAssertFalse(msg.contains("{"))
            XCTAssertFalse(msg.contains("403"))
            XCTAssertNotEqual(msg, "fallback")
        }
        XCTAssertEqual(OrbProvidersSettings.providerWriteError(OrbHTTPError(status: 500, detail: "boom"), fallback: "fallback"), "fallback")
    }

    func testAirVpnSettingsModelMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/airvpn-settings.json")
        for c in try XCTUnwrap(spec["status"] as? [[String: Any]]) {
            let name = try XCTUnwrap(c["name"] as? String)
            let got = OrbAirVpnModel.parseStatus(try orbJSON(c["input"]))
            if c["expected"] is NSNull || c["expected"] == nil {
                XCTAssertNil(got, name)
            } else {
                let exp = try XCTUnwrap(c["expected"] as? [String: Any], name)
                let unwrapped = try XCTUnwrap(got, name)
                XCTAssertEqual(unwrapped.apiKeyConfigured, exp["apiKeyConfigured"] as? Bool, name)
                XCTAssertEqual(unwrapped.sessionLimit, (exp["sessionLimit"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(unwrapped.activeTunnels.count, (exp["activeTunnelsCount"] as? NSNumber)?.intValue, name)
                let expProfiles = try XCTUnwrap(exp["profiles"] as? [[String: Any]], name).map { p in
                    OrbAirVpnModel.ProfileView(
                        device: p["device"] as? String ?? "",
                        country: p["country"] as? String ?? "",
                        server: p["server"] as? String ?? "",
                        active: p["active"] as? Bool ?? false,
                        exits: p["exits"] as? [String] ?? [],
                        accounts: (p["accounts"] as? NSNumber)?.intValue ?? 0
                    )
                }
                XCTAssertEqual(unwrapped.profiles, expProfiles, name)
            }
        }
        for c in try XCTUnwrap(spec["filename_hints"] as? [[String: Any]]) {
            let filename = try XCTUnwrap(c["filename"] as? String)
            let exp = try XCTUnwrap(c["expected"] as? [String: String])
            XCTAssertEqual(
                OrbAirVpnModel.parseFilenameHint(filename),
                OrbAirVpnModel.FilenameHint(country: exp["country"] ?? "", server: exp["server"] ?? "", device: exp["device"] ?? ""),
                filename
            )
        }
        for c in try XCTUnwrap(spec["session_summaries"] as? [[String: Any]]) {
            let name = try XCTUnwrap(c["name"] as? String)
            let active = (c["activeSessions"] as? NSNumber)?.intValue
            let orb = try XCTUnwrap((c["orbTunnels"] as? NSNumber)?.intValue)
            let limit = try XCTUnwrap((c["sessionLimit"] as? NSNumber)?.intValue)
            XCTAssertEqual(
                OrbAirVpnModel.sessionSummary(activeSessions: active, orbTunnels: orb, sessionLimit: limit),
                c["expected"] as? String,
                name
            )
        }
    }

    func testProviderDirectoryHintMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/provider-directory-hint.json")
        XCTAssertEqual(OrbProviderDirectoryHint.storageKey, spec["storage_key"] as? String)
        XCTAssertEqual(OrbProviderDirectoryHint.defaultEnabled, spec["default_enabled"] as? Bool)
        XCTAssertEqual(OrbProviderDirectoryHint.urlString, spec["url"] as? String)
        XCTAssertEqual(OrbProviderDirectoryHint.copy, spec["copy"] as? String)
        XCTAssertEqual(OrbProviderDirectoryHint.settingTitle, spec["setting_title"] as? String)
        XCTAssertEqual(OrbProviderDirectoryHint.settingDescription, spec["setting_description"] as? String)

        let suiteName = "OrbProviderDirectoryHintTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(OrbProviderDirectoryHint.isEnabled(in: defaults))
        defaults.set(false, forKey: OrbProviderDirectoryHint.storageKey)
        XCTAssertFalse(OrbProviderDirectoryHint.isEnabled(in: defaults))
        defaults.set(true, forKey: OrbProviderDirectoryHint.storageKey)
        XCTAssertTrue(OrbProviderDirectoryHint.isEnabled(in: defaults))
    }

    func testRoutingHealthClassificationAndBuiltinDeleteGuard() {
        let unknownHealthy = OrbJSON.object([
            "account_id": .string("a1"),
            "is_healthy": .null,
            "is_degraded": .bool(false),
            "cooldown_secs_remaining": .number(0),
        ])
        XCTAssertFalse(OrbRoutingSettings.isAttentionHealth(unknownHealthy))
        XCTAssertEqual(OrbRoutingSettings.healthStatusTone(unknownHealthy), "success")
        XCTAssertEqual(OrbRoutingSettings.healthLine(unknownHealthy), "no requests yet")

        let cooling = OrbJSON.object([
            "account_id": .string("a2"),
            "is_healthy": .null,
            "is_degraded": .bool(true),
            "cooldown_secs_remaining": .number(90),
            "parked_reason": .string("usage_limit"),
        ])
        XCTAssertTrue(OrbRoutingSettings.isAttentionHealth(cooling))
        XCTAssertEqual(OrbRoutingSettings.healthStatusTone(cooling), "error")
        XCTAssertEqual(OrbRoutingSettings.cooldownSecs(cooling), 90)
        XCTAssertEqual(OrbRoutingSettings.healthLine(cooling), "cooldown 1m 30s · usage_limit")

        let banned = OrbJSON.object([
            "account_id": .string("a3"),
            "account_state": .string("disabled_by_provider"),
            "disabled_by_provider": .bool(true),
            "disabled_by_provider_message": .string("TOS_VIOLATION"),
        ])
        XCTAssertTrue(OrbRoutingSettings.isAttentionHealth(banned))
        XCTAssertEqual(OrbRoutingSettings.healthStatusTone(banned), "error")
        XCTAssertEqual(OrbRoutingSettings.healthLine(banned), "disabled by provider · TOS_VIOLATION")

        XCTAssertFalse(OrbRoutingSettings.canDeleteChain("builtin/smart"))
        XCTAssertTrue(OrbRoutingSettings.canDeleteChain("custom/fast"))
        XCTAssertFalse(OrbRoutingSettings.canCreateChainID("builtin/spoof"))
        XCTAssertFalse(OrbRoutingSettings.canCreateChainID("   "))
        XCTAssertTrue(OrbRoutingSettings.canCreateChainID("fast-fallback"))
    }

}
