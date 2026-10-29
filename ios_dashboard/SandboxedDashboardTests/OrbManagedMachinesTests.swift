import XCTest
@testable import sandboxed_sh

final class OrbManagedMachinesTests: XCTestCase {
    private let payload = """
    {"enabled":true,"provider":"boat","machines":[
      {"id":"m1","name":"small-a","node_id":"managed-m1","size":"small","cpu":2,"ram_gb":4,"disk_gb":40,"usd_per_hour":0.05,"state":"online",
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

    func testNamesAndOptimisticDestroy() throws {
        let r = try OrbManaged.decode(Data(payload.utf8))
        XCTAssertEqual(OrbManaged.title(r.machines[0]), "small-a")
        XCTAssertEqual(OrbManaged.title(r.machines[1]), "m2")
        XCTAssertEqual(OrbManaged.nodeTitle(.object(["id": .string("managed-mm1"), "display_name": .string("small-a")])), "small-a")
        XCTAssertEqual(OrbManaged.nodeTitle(.object(["id": .string("ashur")])), "ashur")
        let marked = OrbManaged.markDestroying(r, id: "m1")
        XCTAssertEqual(marked.machines[0].state, "destroying")
        XCTAssertEqual(OrbManaged.stateLabel(marked.machines[0].state), "Destroying…")
        XCTAssertEqual(r.machines[0].state, "online")
    }

    func testUnlimitedBudgetLine() {
        let b = OrbManagedBudget(spent_today_usd: 0.11, committed_usd: nil, daily_cap_usd: nil, active: 1, max_concurrent: nil)
        XCTAssertEqual(OrbManaged.budgetLine(b), "$0.11 spent today · 1 running")
        let json = #"{"spent_today_usd":0.11,"daily_cap_usd":null,"active":1,"max_concurrent":null}"#
        XCTAssertEqual(try JSONDecoder().decode(OrbManagedBudget.self, from: Data(json.utf8)), b)
        // Exactly what the live backend sends with unlimited caps.
        let live = #"{"spent_today_usd":0.15,"committed_usd":0,"daily_cap_usd":null,"active":0,"max_concurrent":null,"default_ttl_minutes":120,"max_ttl_minutes":720,"default_size":"small","max_size":"xlarge","image":"orb-node-base"}"#
        XCTAssertEqual(OrbManaged.budgetLine(try JSONDecoder().decode(OrbManagedBudget.self, from: Data(live.utf8))), "$0.15 spent today · 0 running")
    }

    func testRowFormatting() throws {
        var m = try OrbManaged.decode(Data(payload.utf8)).machines[0]
        XCTAssertEqual(OrbManaged.sizeLabel("default"), "medium")
        XCTAssertEqual(OrbManaged.sizeLabel("small"), "small")
        XCTAssertEqual(OrbManaged.specLine(m), "2 vCPU · 4 GB RAM · 40 GB")
        XCTAssertEqual(OrbManaged.costLine(0.004, rate: 0.036), "<$0.01 so far · $0.036/h")
        XCTAssertEqual(OrbManaged.ttlShort(m.expires_at, now: at("2026-10-22T10:44:00Z")), "21 min left")
        XCTAssertEqual(OrbManaged.ttlShort(m.expires_at, now: at("2026-10-22T10:00:00Z")), "1 h 05 min left")
        XCTAssertEqual(OrbManaged.ttlShort(m.expires_at, now: at("2026-10-22T11:05:00Z")), "<1 min left")
        XCTAssertEqual(OrbManaged.ttlShort(m.expires_at, now: at("2026-10-22T12:00:00Z")), "Expired")
        m.created_at = "2026-10-22T10:00:00Z"; m.expires_at = "2026-10-22T11:00:00Z"
        XCTAssertEqual(OrbManaged.ttlFraction(m, now: at("2026-10-22T10:45:00Z")), 0.25, accuracy: 1e-9)
        XCTAssertEqual(OrbManaged.ttlFraction(m, now: at("2026-10-22T12:00:00Z")), 0)
        XCTAssertEqual(OrbManaged.missionLabel(title: "Fix the flaky test", id: "3a510e9b-31f3"), "Fix the flaky test")
        XCTAssertEqual(OrbManaged.missionLabel(title: " ", id: "3a510e9b-31f3"), "3a510e9b")
        XCTAssertEqual(OrbManaged.missionLabel(title: nil, id: "3a510e9b-31f3"), "3a510e9b")
    }

    func testNanosecondTimestamps() {
        XCTAssertNotNil(OrbManaged.date("2026-10-22T00:59:37.924408552Z"))
        XCTAssertEqual(OrbManaged.date("2026-10-22T00:59:37.924408552Z"), OrbManaged.date("2026-10-22T00:59:37.924Z"))
    }

    func testSpendMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/managed-spend.json")
        let raw = try JSONSerialization.data(withJSONObject: spec["cases"] as Any)
        struct Top: Decodable { var ids: [String?]; var more: Int }
        struct Case: Decodable { var name: String; var days: [OrbDailySpend]; var total: Double; var today: Double; var max: Double; var fractions: [Double]; var top: [Top] }
        let cases = try JSONDecoder().decode([Case].self, from: raw)
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let s = OrbManaged.spendSummary(c.days)
            XCTAssertEqual(s.total, c.total, accuracy: 1e-9, c.name)
            XCTAssertEqual(s.today, c.today, accuracy: 1e-9, c.name)
            XCTAssertEqual(s.max, c.max, accuracy: 1e-9, c.name)
            for (i, d) in c.days.enumerated() {
                XCTAssertEqual(OrbManaged.spendFraction(d.usd, max: s.max), c.fractions[i], accuracy: 1e-9, "\(c.name) \(d.day)")
                let top = OrbManaged.topMissions(d)
                XCTAssertEqual(top.ids, c.top[i].ids, c.name); XCTAssertEqual(top.more, c.top[i].more, c.name)
            }
        }
    }

    func testSpendDetailAndDecode() throws {
        let json = payload.replacingOccurrences(of: "\"sizes\":[{", with: "\"daily_spend\":[{\"day\":\"2026-10-22\",\"usd\":1.0,\"missions\":[{\"mission_id\":\"abc\",\"usd\":0.6},{\"mission_id\":null,\"usd\":0.3},{\"mission_id\":\"zzzzzzzz9\",\"usd\":0.1}],\"sizes\":[]}],\"sizes\":[{")
        let r = try OrbManaged.decode(Data(json.utf8))
        let day = try XCTUnwrap(r.daily_spend?.first)
        XCTAssertTrue(OrbManaged.spendDayDetail(day, titles: ["abc": "Fix login"]).hasSuffix(" · $1.00 · Fix login $0.60, No mission $0.30 +1 more"))
        XCTAssertNil(try OrbManaged.decode(Data(payload.utf8)).daily_spend)
        XCTAssertTrue(OrbManaged.spendDayDetail(OrbDailySpend(day: "2026-10-22", usd: 0, missions: [], sizes: []), titles: [:]).hasSuffix(" · no spend"))
        XCTAssertEqual(OrbManaged.runningLine(r.budget), "1 of 3 running")
    }

    func testOwnerAndReapLine() throws {
        var m = try OrbManaged.decode(Data(payload.utf8)).machines[0]
        m.state = "online"
        m.owner_mission_id = nil; m.owner_kind = nil
        XCTAssertEqual(OrbManaged.owner(m), .none)
        m.owner_kind = "user"
        XCTAssertEqual(OrbManaged.owner(m), .user)
        m.owner_mission_id = "m1"
        XCTAssertEqual(OrbManaged.owner(m), .mission("m1"))
        m.reap_at = "2026-10-23T12:04:10Z"; m.reap_reason = "owner_completed"
        XCTAssertEqual(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")), "Reaps in 5 min (owner completed)")
        m.reap_at = "2026-10-23T12:15:00Z"; m.reap_reason = "working_owner_idle"
        XCTAssertEqual(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")), "Reaps in 15 min (idle)")
        m.reap_at = "2026-10-24T10:00:00Z"; m.deletable_at = "2026-10-24T10:00:00Z"; m.reap_reason = "awaiting_deletable_at:owner_completed"
        XCTAssertEqual(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")), "Deletes when 24h lease ends in 22 h 00 min")
        m.deletable_at = nil
        m.reap_at = "2026-10-23T11:59:00Z"; m.reap_reason = "owner_interrupted_idle"
        XCTAssertEqual(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")), "Reap due (owner interrupted, idle)")
        m.reap_at = "2026-10-23T13:30:00Z"; m.reap_reason = "idle_no_owner"
        XCTAssertEqual(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")), "Reaps in 1 h 30 min (idle, no owner)")
        m.state = "stopped"
        XCTAssertTrue(OrbManaged.isStopped(m))
        XCTAssertTrue(OrbManaged.canResume(m, busy: false))
        XCTAssertFalse(OrbManaged.canResume(m, busy: true))
        XCTAssertEqual(OrbManaged.providerLabel("hetzner"), "Hetzner")
        XCTAssertEqual(OrbManaged.providerLabel("vastai"), "Vast.ai")
        XCTAssertEqual(OrbManaged.providerLabel("scaleway"), "Scaleway")
        m.state = "destroyed"
        XCTAssertNil(OrbManaged.reapLine(m, now: at("2026-10-23T12:00:00Z")))
    }

    func testDecodesSharedMultiProviderResponseFixture() throws {
        let data = try Data(contentsOf: OrbSpec.url("fixtures/managed-machines-response.json"))
        let r = try OrbManaged.decode(data)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.provider, "boat")
        let providers = try XCTUnwrap(r.providers)
        XCTAssertEqual(providers.map(\.provider), ["boat", "hetzner", "vastai", "scaleway"])
        XCTAssertEqual(providers.map(\.display_name), ["boat.dev", "Hetzner Cloud", "Vast.ai", "Scaleway"])
        XCTAssertEqual(providers.map(\.configured), [true, true, false, false])
        XCTAssertEqual(providers.map(\.supports_free_stop), [true, false, false, false])
        XCTAssertEqual(providers.map(\.supports_snapshots), [true, false, false, false])
        XCTAssertEqual(providers[1].sizes.first(where: { $0.size == "cax31" })?.arch, "arm64")
        XCTAssertEqual(providers[2].sizes.first(where: { $0.size == "rtx4090" })?.gpu, "RTX 4090")
        XCTAssertEqual(r.machines.count, 1)
        XCTAssertEqual(r.machines[0].provider, "hetzner")
        XCTAssertFalse(OrbManaged.canStop(r.machines[0], providers: providers))
    }
}
