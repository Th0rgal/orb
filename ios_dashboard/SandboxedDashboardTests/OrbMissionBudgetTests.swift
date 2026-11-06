import XCTest
@testable import sandboxed_sh

final class OrbMissionBudgetTests: XCTestCase {
    private func own(_ budget: Double, maxGrant: Double? = nil) -> OrbMissionBudget {
        var o: [String: OrbJSON] = [
            "mission_id": .string("m1"), "own_budget_usd": .number(budget), "pool_id": .string("m1"), "mode": .string("own"),
            "pool": .object(["budget_usd": .number(budget), "spent_usd": .number(0.4), "reserved_usd": .number(0.2), "carved_usd": .number(1), "available_usd": .number(budget - 1.6)]),
            "effective_bandwidth": .object(["source": .string("none"), "current_compute_usd_per_hour": .number(2.0), "current_tokens_per_min": .number(48_000), "current_vcpu_per_min": .number(16)]),
            "children": .array([.object(["mission_id": .string("c1"), "mode": .string("sub_budget"), "budget_usd": .number(1), "spent_usd": .number(0.3)])]),
        ]
        o["max_grant_usd"] = maxGrant.map { .number($0) } ?? .null
        return OrbMissionBudget(.object(o))
    }

    func testParsesTheServerView() {
        let v = own(4)
        XCTAssertEqual(v.mode, "own")
        XCTAssertEqual(v.pool?.available ?? 0, 2.4, accuracy: 1e-9)
        XCTAssertEqual(v.children.first?.mode, "sub_budget")
        XCTAssertEqual(OrbMissionBudget(.object(["mission_id": .string("x"), "pool": .null, "children": .array([])])).mode, "none")
    }

    func testOptimisticMatchesDesktop() {
        XCTAssertEqual(own(4).optimistic(6).pool?.available ?? 0, 4.4, accuracy: 1e-9)
        XCTAssertEqual(own(4).optimistic(nil).mode, "none")
        XCTAssertEqual(own(4, maxGrant: 2).optimistic(nil).mode, "pooled")
        let fresh = OrbMissionBudget(.object(["mission_id": .string("m"), "mode": .string("none")])).optimistic(5)
        XCTAssertEqual(fresh.pool?.available, 5)
        XCTAssertEqual(OrbMissionBudget.money(2), "$2.00")
    }

    func testDecodesSharedMissionBudgetFixtureAndLimits() throws {
        let data = try Data(contentsOf: OrbSpec.url("fixtures/mission-budget.json"))
        let root = try JSONDecoder().decode(OrbJSON.self, from: data)

        let globalDefault = OrbMissionBudget(root["global_default"])
        XCTAssertEqual(globalDefault.mode, "none")
        XCTAssertEqual(globalDefault.vmLimitsMode, "global")
        XCTAssertEqual(globalDefault.bandwidthMode, "none")
        XCTAssertNil(globalDefault.ownVmLimits)
        XCTAssertNil(globalDefault.ownBandwidthLimits)
        XCTAssertEqual(globalDefault.effectiveVmLimits?.globalMaxConcurrent, 16)
        XCTAssertEqual(globalDefault.vmLimitsModeLine, "Uses the global limit (16 concurrent across Orb).")
        XCTAssertEqual(globalDefault.bandwidthModeLine, "Unthrottled. Requests and spawns run at full speed.")
        XCTAssertFalse(globalDefault.showsSubagents)
        XCTAssertTrue(globalDefault.children.allSatisfy(\.isIdlePooled))

        let dedicated = OrbMissionBudget(root["dedicated_override"])
        XCTAssertEqual(dedicated.mode, "own")
        XCTAssertEqual(dedicated.vmLimitsMode, "own")
        XCTAssertEqual(dedicated.bandwidthMode, "own")
        XCTAssertEqual(dedicated.ownVmLimits?.maxConcurrent, 6)
        XCTAssertEqual(dedicated.ownVmLimits?.providerMaxConcurrent, ["hetzner": 0, "vastai": 2])
        XCTAssertEqual(OrbMissionBudget.providerLimitsSummary(dedicated.ownVmLimits), "Hetzner: off · Vast.ai: 2")
        XCTAssertEqual(OrbMissionBudget.bandwidthLimitsSummary(dedicated.ownBandwidthLimits), "120k tok/min · 32 vCPU/min · $2.50/h")
        XCTAssertEqual(dedicated.effectiveVmLimits?.active, 3)
        XCTAssertEqual(dedicated.effectiveVmLimits?.providerLimits.count, 2)
        XCTAssertEqual(dedicated.effectiveBandwidth?.tokensPerMin, 120_000)
        XCTAssertEqual(dedicated.effectiveBandwidth?.protectRoot, true)
        XCTAssertTrue(dedicated.showsSubagents)
        XCTAssertFalse(dedicated.children[0].isIdlePooled)
        XCTAssertTrue(dedicated.children[1].isIdlePooled)

        let cleared = dedicated.optimisticVmLimits(nil)
        XCTAssertEqual(cleared.vmLimitsMode, "global")
        XCTAssertNil(cleared.ownVmLimits)
        XCTAssertEqual(cleared.effectiveVmLimits?.maxConcurrent, 16)

        let clearedBw = dedicated.optimisticBandwidthLimits(nil)
        XCTAssertEqual(clearedBw.bandwidthMode, "none")
        XCTAssertNil(clearedBw.ownBandwidthLimits)

        let dailySust = OrbMissionBudget(root["daily_sustainable_with_lease_cliff"])
        XCTAssertEqual(dailySust.ownBudgetResetPeriod, .daily)
        XCTAssertEqual(dailySust.pool?.lifetimeSpent ?? 0, 920, accuracy: 1e-9)
        XCTAssertEqual(
            OrbMissionBudget.bandwidthLimitsSummary(dailySust.ownBandwidthLimits),
            "150k tok/min · $18/h LLM · 64 vCPU/min · $10/h"
        )
        XCTAssertTrue(dailySust.modeLine.contains("Own daily budget"))
        let fc = dailySust.computeRunwayForecast(bandwidthEnabled: true, budgetEnabled: true, nowMs: 1_793_908_800_000)
        XCTAssertTrue(fc.sustainsUntilReset)
        XCTAssertEqual(fc.resetsInSecs ?? 0, 14_400, accuracy: 1)
        XCTAssertEqual(fc.leaseCliffSecs ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(fc.headline, "Sustains until daily reset")
        XCTAssertTrue(fc.subline.contains("VM auto-extensions paused ($2.00 < $2.50 30m step)"))
        XCTAssertEqual(fc.tone, .warning)

        var pooledChild = dailySust
        pooledChild.ownBudget = nil
        pooledChild.ownBudgetResetPeriod = .total
        pooledChild.mode = "pooled"
        pooledChild.maxGrant = 2.0
        let pooledFc = pooledChild.computeRunwayForecast(bandwidthEnabled: true, nowMs: 1_793_908_800_000)
        XCTAssertEqual(pooledFc.resetPeriod, .daily)
        XCTAssertTrue(pooledFc.sustainsUntilReset)
        XCTAssertEqual(pooledFc.headline, "Sustains until daily reset")

        var upcomingCliff = dailySust
        upcomingCliff.pool?.liveMachines = 10
        upcomingCliff.pool?.spent = 255.8333
        upcomingCliff.pool?.carved = 40.0
        upcomingCliff.pool?.reserved = 1.6667
        upcomingCliff.pool?.available = 2.5
        let upcomingFc = upcomingCliff.computeRunwayForecast(bandwidthEnabled: true, budgetEnabled: true, nowMs: 1_793_922_300_000)
        XCTAssertTrue(upcomingFc.sustainsUntilReset)
        XCTAssertEqual(upcomingFc.leaseCliffSecs ?? 0, 720, accuracy: 1)
        XCTAssertTrue(upcomingFc.subline.contains("VM extensions pause in ~12m"))
    }

    func testValidatesVmAndBandwidthInputsAndForecast() throws {
        let ok = try OrbMissionBudget.parseVmLimits(
            totalRaw: "8",
            providerRaws: ["vastai": "2", "hetzner": "0"]
        ).get()
        XCTAssertEqual(ok.maxConcurrent, 8)
        XCTAssertEqual(ok.providerMaxConcurrent, ["vastai": 2, "hetzner": 0])
        XCTAssertThrowsError(try OrbMissionBudget.parseVmLimits(totalRaw: "", providerRaws: [:]).get())
        XCTAssertThrowsError(try OrbMissionBudget.parseVmLimits(totalRaw: "2", providerRaws: ["vastai": "4"]).get())

        let bw = try OrbMissionBudget.parseBandwidthLimits(
            tokensPerMinRaw: "120k",
            computeVcpuRaw: "32",
            computeUsdPerHRaw: "$2.5",
            protectRoot: true
        ).get()
        XCTAssertEqual(bw.tokensPerMin, 120_000)
        XCTAssertEqual(bw.computeVcpuPerMin, 32)
        XCTAssertEqual(bw.computeUsdPerHour ?? 0, 2.5, accuracy: 1e-9)
        let bwInf = try OrbMissionBudget.parseBandwidthLimits(
            tokensPerMinRaw: "",
            computeVcpuRaw: "",
            computeUsdPerHRaw: "",
            protectRoot: true,
            inferenceUsdPerHRaw: "$12.5"
        ).get()
        XCTAssertEqual(bwInf.inferenceUsdPerHour ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertThrowsError(try OrbMissionBudget.parseBandwidthLimits(tokensPerMinRaw: "", computeVcpuRaw: "", computeUsdPerHRaw: "", protectRoot: true).get())

        let base10 = own(10)
        let unshaped = base10.computeRunwayForecast(budgetEnabled: true)
        XCTAssertEqual(unshaped.etaSecs ?? 0, 15_480, accuracy: 1)
        let shaped = base10.computeRunwayForecast(draftComputeUsdPerH: "1.0", bandwidthEnabled: true, budgetEnabled: true)
        XCTAssertEqual(shaped.etaSecs ?? 0, 30_960, accuracy: 1)
        XCTAssertTrue(shaped.subline.contains("from bandwidth cap"))

        let fullyReserved = OrbMissionBudget(.object([
            "mission_id": .string("m1"), "own_budget_usd": .number(1), "pool_id": .string("m1"), "mode": .string("own"),
            "pool": .object(["budget_usd": .number(1), "spent_usd": .number(0), "reserved_usd": .number(1), "carved_usd": .number(0), "available_usd": .number(0)]),
            "effective_bandwidth": .object(["source": .string("none"), "current_compute_usd_per_hour": .number(1.0)]),
            "children": .array([]),
        ]))
        let freshVm = fullyReserved.computeRunwayForecast(budgetEnabled: true)
        XCTAssertEqual(freshVm.etaSecs ?? 0, 3_600, accuracy: 1)
        XCTAssertTrue(freshVm.headline.contains("~1h runway left"))
    }
}
