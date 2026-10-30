import XCTest
@testable import sandboxed_sh

final class OrbMissionBudgetTests: XCTestCase {
    private func own(_ budget: Double, maxGrant: Double? = nil) -> OrbMissionBudget {
        var o: [String: OrbJSON] = [
            "mission_id": .string("m1"), "own_budget_usd": .number(budget), "pool_id": .string("m1"), "mode": .string("own"),
            "pool": .object(["budget_usd": .number(budget), "spent_usd": .number(0.4), "reserved_usd": .number(0.2), "carved_usd": .number(1), "available_usd": .number(budget - 1.6)]),
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

    func testDecodesSharedMissionBudgetFixtureAndVmLimits() throws {
        let data = try Data(contentsOf: OrbSpec.url("fixtures/mission-budget.json"))
        let root = try JSONDecoder().decode(OrbJSON.self, from: data)

        let globalDefault = OrbMissionBudget(root["global_default"])
        XCTAssertEqual(globalDefault.mode, "none")
        XCTAssertEqual(globalDefault.vmLimitsMode, "global")
        XCTAssertNil(globalDefault.ownVmLimits)
        XCTAssertEqual(globalDefault.effectiveVmLimits?.globalMaxConcurrent, 16)
        XCTAssertEqual(globalDefault.vmLimitsModeLine, "Uses the global limit (16 concurrent across Orb).")
        XCTAssertFalse(globalDefault.showsSubagents)
        XCTAssertTrue(globalDefault.children.allSatisfy(\.isIdlePooled))

        let dedicated = OrbMissionBudget(root["dedicated_override"])
        XCTAssertEqual(dedicated.mode, "own")
        XCTAssertEqual(dedicated.vmLimitsMode, "own")
        XCTAssertEqual(dedicated.ownVmLimits?.maxConcurrent, 6)
        XCTAssertEqual(dedicated.ownVmLimits?.providerMaxConcurrent, ["hetzner": 0, "vastai": 2])
        XCTAssertEqual(OrbMissionBudget.providerLimitsSummary(dedicated.ownVmLimits), "Hetzner: off · Vast.ai: 2")
        XCTAssertEqual(dedicated.effectiveVmLimits?.active, 3)
        XCTAssertEqual(dedicated.effectiveVmLimits?.providerLimits.count, 2)
        XCTAssertTrue(dedicated.showsSubagents)
        XCTAssertFalse(dedicated.children[0].isIdlePooled)
        XCTAssertTrue(dedicated.children[1].isIdlePooled)

        let cleared = dedicated.optimisticVmLimits(nil)
        XCTAssertEqual(cleared.vmLimitsMode, "global")
        XCTAssertNil(cleared.ownVmLimits)
        XCTAssertEqual(cleared.effectiveVmLimits?.maxConcurrent, 16)
    }

    func testValidatesVmLimitsInputs() throws {
        let ok = try OrbMissionBudget.parseVmLimits(
            totalRaw: "8",
            providerRaws: ["vastai": "2", "hetzner": "0"]
        ).get()
        XCTAssertEqual(ok.maxConcurrent, 8)
        XCTAssertEqual(ok.providerMaxConcurrent, ["vastai": 2, "hetzner": 0])

        let empty = OrbMissionBudget.parseVmLimits(totalRaw: "", providerRaws: [:])
        XCTAssertThrowsError(try empty.get())

        let exceedsTotal = OrbMissionBudget.parseVmLimits(totalRaw: "2", providerRaws: ["vastai": "4"])
        XCTAssertThrowsError(try exceedsTotal.get())
    }
}
