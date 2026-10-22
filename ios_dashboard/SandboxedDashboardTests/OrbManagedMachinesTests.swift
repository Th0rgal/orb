import XCTest
@testable import sandboxed_sh

final class OrbManagedMachinesTests: XCTestCase {
    private let payload = """
    {"enabled":true,"provider":"boat","machines":[
      {"id":"m1","node_id":"managed-m1","size":"small","cpu":2,"ram_gb":4,"disk_gb":40,"usd_per_hour":0.05,"state":"online",
       "created_at":"2026-10-22T10:00:00Z","expires_at":"2026-10-22T11:05:09.500Z","destroyed_at":null,"cost_usd":0.004,
       "cost_is_metered":true,"owner_mission_id":null,"reason":"ci","error":null,"ledger_closed":false,"destroy_reason":null},
      {"id":"m2","node_id":"managed-m2","size":"large","cpu":8,"ram_gb":32,"disk_gb":160,"usd_per_hour":0.4,"state":"destroyed",
       "created_at":"2026-10-22T08:00:00Z","expires_at":"2026-10-22T09:00:00Z","destroyed_at":"2026-10-22T09:00:00Z","cost_usd":0.4,
       "cost_is_metered":false,"owner_mission_id":"abc","reason":null,"error":null,"ledger_closed":true,"destroy_reason":"ttl"}],
     "budget":{"spent_today_usd":1.2,"committed_usd":0.5,"daily_cap_usd":20,"active":1,"max_concurrent":3,"default_ttl_minutes":60,
       "max_ttl_minutes":480,"default_size":"small","max_size":"large","image":"ubuntu"},
     "sizes":[{"size":"small","cpu":2,"ram_gb":4,"disk_gb":40,"usd_per_hour":0.05}]}
    """

    private func at(_ s: String) -> Date { OrbManaged.date(s)! }

    func testDecodesPayload() throws {
        let r = try OrbManaged.decode(Data(payload.utf8))
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.provider, "boat")
        XCTAssertEqual(r.machines.map(\.id), ["m1", "m2"])
        XCTAssertEqual(r.machines[0].cpu, 2)
        XCTAssertNil(r.machines[0].destroyed_at)
        XCTAssertEqual(r.machines[1].destroy_reason, "ttl")
        XCTAssertEqual(r.budget.max_concurrent, 3)
        XCTAssertEqual(r.sizes.first?.usd_per_hour, 0.05)
        XCTAssertEqual(r.machines.filter(OrbManaged.isLive).map(\.id), ["m1"])
        let json = try JSONDecoder().decode(OrbJSON.self, from: Data(payload.utf8))
        XCTAssertEqual(try OrbManaged.decode(json), r)
    }

    func testCountdown() {
        let exp = "2026-10-22T11:05:09.500Z"
        XCTAssertEqual(OrbManaged.ttlLeft(exp, now: at("2026-10-22T10:00:00Z")), "1h 05m")
        XCTAssertEqual(OrbManaged.ttlLeft(exp, now: at("2026-10-22T11:01:00Z")), "4m 09s")
        XCTAssertEqual(OrbManaged.ttlLeft(exp, now: at("2026-10-22T11:06:00Z")), "Expired")
        XCTAssertEqual(OrbManaged.ttlLeft("nope"), "—")
        XCTAssertTrue(OrbManaged.ttlUrgent(exp, now: at("2026-10-22T11:01:00Z")))
        XCTAssertFalse(OrbManaged.ttlUrgent(exp, now: at("2026-10-22T10:00:00Z")))
    }

    func testCostFormatting() throws {
        XCTAssertEqual(OrbManaged.usd(0.004), "<$0.01")
        XCTAssertEqual(OrbManaged.usd(12.3), "$12.30")
        XCTAssertEqual(OrbManaged.usd(0), "$0.00")
        XCTAssertEqual(OrbManaged.usd(nil), "—")
        XCTAssertEqual(OrbManaged.usdPerHour(0.05), "$0.050/h")
        XCTAssertEqual(OrbManaged.usdPerHour(0.4), "$0.40/h")
        let m = try OrbManaged.decode(Data(payload.utf8)).machines
        let fetched = at("2026-10-22T10:00:00Z")
        XCTAssertEqual(OrbManaged.liveCost(m[0], fetchedAt: fetched, now: at("2026-10-22T11:00:00Z")), 0.054, accuracy: 1e-9)
        XCTAssertEqual(OrbManaged.liveCost(m[1], fetchedAt: fetched, now: at("2026-10-22T11:00:00Z")), 0.4)
        XCTAssertEqual(OrbManaged.sizeSpec(cpu: 2, ramGB: 4, diskGB: 40), "2 vCPU · 4 GB · 40 GB disk")
    }

    func testBudgetLineAndRecent() throws {
        let r = try OrbManaged.decode(Data(payload.utf8))
        XCTAssertEqual(OrbManaged.budgetLine(r.budget), "$1.20 spent today of $20.00 · 1 of 3 running")
        XCTAssertEqual(OrbManaged.recent(r.machines, now: at("2026-10-22T12:00:00Z")).map(\.id), ["m2"])
        XCTAssertTrue(OrbManaged.recent(r.machines, now: at("2026-10-24T12:00:00Z")).isEmpty)
    }

    func testManagedNodeBadgeAndErrors() {
        XCTAssertTrue(OrbManaged.isManagedNode(.object(["id": .string("managed-x")])))
        XCTAssertTrue(OrbManaged.isManagedNode(.object(["id": .string("n"), "labels": .array([.string("managed")])])))
        XCTAssertFalse(OrbManaged.isManagedNode(.object(["id": .string("ashur"), "labels": .array([.string("gpu")])])))
        XCTAssertTrue(OrbManaged.isUnsupported(OrbHTTPError(status: 404, detail: "")))
        XCTAssertTrue(OrbManaged.isUnsupported(OrbHTTPError(status: 405, detail: "")))
        XCTAssertFalse(OrbManaged.isUnsupported(OrbHTTPError(status: 500, detail: "")))
        XCTAssertEqual(OrbManaged.message(OrbHTTPError(status: 402, detail: #"{"error":"budget_exceeded","message":"cap $20"}"#)), "Daily budget reached: cap $20")
        XCTAssertEqual(OrbManaged.message(OrbHTTPError(status: 500, detail: #"{"error":"x","message":"boom"}"#)), "boom")
    }
}
