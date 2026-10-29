package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbManagedMachinesTest {
    private val payload = """
        {"enabled":true,"provider":"boat","machines":[
          {"id":"m1","name":"small-a","node_id":"managed-m1","size":"small","cpu":2,"ram_gb":4,"disk_gb":40,"usd_per_hour":0.06,
           "state":"online","created_at":"2026-10-22T10:00:00Z","expires_at":"2026-10-22T11:00:00Z",
           "destroyed_at":null,"cost_usd":0.5,"cost_is_metered":true,"owner_mission_id":"abcdef1234567",
           "reason":"build","error":null,"ledger_closed":false,"destroy_reason":null},
          {"id":"m2","size":"large","cpu":8,"ram_gb":15.5,"usd_per_hour":0.4,"state":"destroyed",
           "created_at":"2026-10-22T08:00:00Z","expires_at":"2026-10-22T09:00:00Z","destroyed_at":"2026-10-22T09:00:00Z",
           "cost_usd":0.4,"ledger_closed":true,"destroy_reason":"ttl"},
          {"size":"no-id"}
        ],
        "budget":{"spent_today_usd":1.2,"committed_usd":0.3,"daily_cap_usd":20,"active":1,"max_concurrent":3,
          "default_ttl_minutes":60,"max_ttl_minutes":480,"default_size":"small","max_size":"large","image":"x"},
        "sizes":[{"size":"small","cpu":2,"ram_gb":4,"disk_gb":40,"usd_per_hour":0.06}]}
    """.trimIndent()

    private fun parsed() = OrbManagedMachines.parse(OrbJSON.dict(OrbJSON.parse(payload))!!)

    @Test
    fun parsesPayload() {
        val r = parsed()
        assertTrue(r.enabled)
        assertEquals("boat", r.provider)
        assertEquals(2, r.machines.size)
        val m = r.machines[0]
        assertEquals("managed-m1", m.nodeId)
        assertEquals(2, m.cpu)
        assertEquals(4.0, m.ramGb, 0.0)
        assertEquals(40.0, m.diskGb!!, 0.0)
        assertTrue(m.costIsMetered)
        assertEquals("abcdef1234567", m.ownerMissionId)
        assertNull(m.error)
        assertNull(m.destroyedAt)
        val m2 = r.machines[1]
        assertEquals("managed-m2", m2.nodeId)
        assertNull(m2.diskGb)
        assertTrue(m2.ledgerClosed)
        assertEquals("ttl", m2.destroyReason)
        assertEquals(1.2, r.budget.spentTodayUsd, 0.0)
        assertEquals(0.3, r.budget.committedUsd, 0.0)
        assertEquals(3, r.budget.maxConcurrent)
        assertEquals(480, r.budget.maxTtlMinutes)
    }

    @Test
    fun missingFieldsAreSafe() {
        val r = OrbManagedMachines.parse(emptyMap())
        assertFalse(r.enabled)
        assertTrue(r.machines.isEmpty())
        assertEquals("$0.00 spent today · 0 running", OrbManagedMachines.budgetLine(r.budget))
    }

    @Test
    fun liveAndActions() {
        val (online, destroyed) = parsed().machines
        assertTrue(OrbManagedMachines.isLive(online))
        assertTrue(OrbManagedMachines.canAct(online))
        assertFalse(OrbManagedMachines.isLive(destroyed))
        assertFalse(OrbManagedMachines.canAct(online.copy(state = "destroying")))
        assertFalse(OrbManagedMachines.isLive(online.copy(state = "failed")))
    }

    @Test
    fun unsupportedStatuses() {
        assertTrue(OrbManagedMachines.isUnsupported(404))
        assertTrue(OrbManagedMachines.isUnsupported(405))
        assertFalse(OrbManagedMachines.isUnsupported(500))
        assertFalse(OrbManagedMachines.isUnsupported(null))
    }

    @Test
    fun managedNodeDetection() {
        assertTrue(OrbManagedMachines.isManagedNode("managed-abc", null))
        assertTrue(OrbManagedMachines.isManagedNode("ashur", listOf("gpu", "managed")))
        assertFalse(OrbManagedMachines.isManagedNode("ashur", listOf("gpu")))
        assertFalse(OrbManagedMachines.isManagedNode(null, null))
        val row = OrbRow(mapOf("id" to "n", "labels" to listOf("managed", 3)))
        assertEquals(listOf("managed"), OrbManagedMachines.nodeLabels(row))
    }

    @Test
    fun countdown() {
        val exp = "2026-10-22T11:00:00Z"
        val end = OrbManagedMachines.parseTime(exp)!!
        assertEquals("1h 05m", OrbManagedMachines.ttlLeft(exp, end - (65 * 60 + 30) * 1000L))
        assertEquals("4m 09s", OrbManagedMachines.ttlLeft(exp, end - 249_000L))
        assertEquals("Expired", OrbManagedMachines.ttlLeft(exp, end))
        assertEquals("Expired", OrbManagedMachines.ttlLeft(exp, end + 5_000))
        assertEquals("—", OrbManagedMachines.ttlLeft("garbage", end))
        assertEquals("0m 01s", OrbManagedMachines.ttlLeft(exp, end - 1_500))
        assertTrue(OrbManagedMachines.ttlUrgent(exp, end - 9 * 60_000L))
        assertFalse(OrbManagedMachines.ttlUrgent(exp, end - 11 * 60_000L))
        assertFalse(OrbManagedMachines.ttlUrgent("", end))
        assertEquals(end, OrbManagedMachines.parseTime("2026-10-22T13:00:00+02:00"))
    }

    @Test
    fun costFormatting() {
        assertEquals("$0.42", OrbManagedMachines.usd(0.42))
        assertEquals("$12.30", OrbManagedMachines.usd(12.3))
        assertEquals("<$0.01", OrbManagedMachines.usd(0.004))
        assertEquals("$0.00", OrbManagedMachines.usd(0.0))
        assertEquals("—", OrbManagedMachines.usd(null))
        assertEquals("—", OrbManagedMachines.usd(Double.NaN))
        assertEquals("$0.060/h", OrbManagedMachines.usdPerHour(0.06))
        assertEquals("$0.40/h", OrbManagedMachines.usdPerHour(0.4))
        assertEquals("$0.00/h", OrbManagedMachines.usdPerHour(0.0))
    }

    @Test
    fun liveCostExtrapolatesUntilExpiry() {
        val m = parsed().machines[0]
        val end = OrbManagedMachines.parseTime(m.expiresAt)!!
        val fetched = end - 3_600_000L
        assertEquals(0.5, OrbManagedMachines.liveCost(m, fetched, fetched), 1e-9)
        assertEquals(0.53, OrbManagedMachines.liveCost(m, fetched, fetched + 1_800_000L), 1e-9)
        // Capped at expiry.
        assertEquals(0.56, OrbManagedMachines.liveCost(m, fetched, end + 3_600_000L), 1e-9)
        // Destroyed machines keep their final cost.
        assertEquals(0.4, OrbManagedMachines.liveCost(parsed().machines[1], fetched, end), 0.0)
    }

    @Test
    fun budgetAndSpec() {
        val r = parsed()
        assertEquals("$1.20 spent today of $20.00 · 1 of 3 running", OrbManagedMachines.budgetLine(r.budget))
        assertEquals("2 vCPU · 4 GB · 40 GB disk", OrbManagedMachines.sizeSpec(r.machines[0]))
        assertEquals("8 vCPU · 15.5 GB", OrbManagedMachines.sizeSpec(r.machines[1]))
        assertEquals("Online", OrbManagedMachines.stateLabel("online"))
        assertEquals("weird", OrbManagedMachines.stateLabel("weird"))
    }

    @Test
    fun errorMessages() {
        val budget = OrbError("budget_exceeded", 402, """{"error":"budget_exceeded","message":"cap is $20"}""")
        assertEquals("Daily budget reached: cap is $20", OrbManagedMachines.errorMessage(budget))
        val quota = OrbError("quota_exceeded", 429, """{"error":"quota_exceeded"}""")
        assertEquals("Machine limit reached.", OrbManagedMachines.errorMessage(quota))
        val other = OrbError("not_found", 404, """{"error":"not_found","message":"no such machine"}""")
        assertEquals("no such machine", OrbManagedMachines.errorMessage(other))
        assertEquals("HTTP 500", OrbManagedMachines.errorMessage(OrbError("HTTP 500", 500, "")))
        assertEquals("boom", OrbManagedMachines.errorMessage(RuntimeException("boom")))
    }

    @Test
    fun namesAndTitles() {
        val (named, unnamed) = parsed().machines
        assertEquals("small-a", named.name)
        assertEquals("small-a", OrbManagedMachines.title(named))
        assertNull(unnamed.name)
        assertEquals("m2", OrbManagedMachines.title(unnamed))
        val node = OrbRow(mapOf("id" to "managed-mm1", "display_name" to "medium-b"))
        assertEquals("medium-b", OrbManagedMachines.nodeTitle("managed-mm1", node))
        assertEquals("ashur", OrbManagedMachines.nodeTitle("ashur", OrbRow(mapOf("id" to "ashur"))))
    }

    @Test
    fun optimisticDestroyAndRevert() {
        val machines = parsed().machines
        val marked = OrbManagedMachines.markDestroying(machines, "m1")
        assertEquals("destroying", marked[0].state)
        assertEquals("Destroying…", OrbManagedMachines.stateLabel(marked[0].state))
        assertFalse(OrbManagedMachines.canAct(marked[0]))
        assertTrue(OrbManagedMachines.isLive(marked[0]))
        assertEquals(machines[1], marked[1])
        assertEquals(machines, OrbManagedMachines.revert(marked, machines[0]))
    }

    @Test
    fun unlimitedBudget() {
        val b = OrbManagedMachines.parse(OrbJSON.dict(OrbJSON.parse(
            """{"enabled":true,"machines":[],"budget":{"spent_today_usd":0.11,"daily_cap_usd":null,"active":1,"max_concurrent":null}}"""
        ))!!).budget
        assertNull(b.dailyCapUsd)
        assertNull(b.maxConcurrent)
        assertEquals("$0.11 spent today · 1 running", OrbManagedMachines.budgetLine(b))
        assertFalse(OrbManagedMachines.budgetFull(b))
        val idle = b.copy(spentTodayUsd = 0.15, active = 0)
        assertEquals("$0.15 spent today · 0 running", OrbManagedMachines.budgetLine(idle))
        assertFalse(OrbManagedMachines.budgetLine(idle).contains("of"))
        assertFalse(OrbManagedMachines.budgetLine(idle).contains("null"))
        assertEquals("$0.11 spent today of $5.00 · 1 running", OrbManagedMachines.budgetLine(b.copy(dailyCapUsd = 5.0)))
        assertTrue(OrbManagedMachines.budgetFull(b.copy(maxConcurrent = 1)))
        assertTrue(OrbManagedMachines.budgetFull(b.copy(dailyCapUsd = 0.1)))
    }

    @Test
    fun rowLabels() {
        val (m1, m2) = parsed().machines
        assertEquals("medium", OrbManagedMachines.sizeLabel("default"))
        assertEquals("small", OrbManagedMachines.sizeLabel("small"))
        assertEquals("2 vCPU · 4 GB RAM · 40 GB", OrbManagedMachines.specLine(m1))
        assertEquals("8 vCPU · 15.5 GB RAM", OrbManagedMachines.specLine(m2))
        val end = OrbManagedMachines.parseTime(m1.expiresAt)!!
        assertEquals("21 min left", OrbManagedMachines.ttlShort(m1.expiresAt, end - 21 * 60_000L - 30_000))
        assertEquals("1 h 05 min left", OrbManagedMachines.ttlShort(m1.expiresAt, end - 65 * 60_000L))
        assertEquals("<1 min left", OrbManagedMachines.ttlShort(m1.expiresAt, end - 30_000))
        assertEquals("Expired", OrbManagedMachines.ttlShort(m1.expiresAt, end))
        // created 10:00, expires 11:00: at 10:45 a quarter is left.
        assertEquals(0.25f, OrbManagedMachines.ttlFraction(m1, end - 15 * 60_000L)!!, 1e-6f)
        assertEquals(0f, OrbManagedMachines.ttlFraction(m1, end + 1)!!, 0f)
        assertNull(OrbManagedMachines.ttlFraction(m1.copy(createdAt = ""), end))
        val cheap = m1.copy(costUsd = 0.004, usdPerHour = 0.036)
        assertEquals("<$0.01 so far · $0.036/h", OrbManagedMachines.costLine(cheap, end, end))
        assertEquals("$0.40 total", OrbManagedMachines.finalCostLine(m2))
    }

    @Test
    fun missionChipAndTitle() {
        assertEquals("abcdef12", OrbManagedMachines.missionChip("abcdef1234567", null))
        assertEquals("abcdef12", OrbManagedMachines.missionChip("abcdef1234567", "  "))
        assertEquals("Fix login", OrbManagedMachines.missionChip("abc", "Fix login"))
        assertEquals("Refactor the paymen…", OrbManagedMachines.missionChip("abc", "Refactor the payment pipeline", max = 20))
        assertEquals("T", OrbManagedMachines.missionTitle(mapOf("title" to "T")))
        assertEquals("N", OrbManagedMachines.missionTitle(mapOf("mission" to mapOf("title" to "N"))))
        assertNull(OrbManagedMachines.missionTitle(emptyMap()))
    }

    @Test
    fun recentList() {
        val ms = parsed().machines
        val destroyedAt = OrbManagedMachines.parseTime("2026-10-22T09:00:00Z")!!
        assertEquals(listOf("m2"), OrbManagedMachines.recentMachines(ms, destroyedAt + 3_600_000L).map { it.id })
        assertTrue(OrbManagedMachines.recentMachines(ms, destroyedAt + 86_400_001L).isEmpty())
        val failed = ms[0].copy(id = "m3", state = "failed", destroyedAt = "2026-10-22T10:00:00Z")
        assertEquals(listOf("m3", "m2"), OrbManagedMachines.recentMachines(ms + failed, destroyedAt + 3_600_000L).map { it.id })
    }

    @Test
    fun ownerAndReapLine() {
        val base = parsed().machines.first().copy(state = "online", ownerMissionId = null, ownerKind = null)
        assertEquals(OrbManagedMachines.Owner.None, OrbManagedMachines.owner(base))
        assertEquals(OrbManagedMachines.Owner.User, OrbManagedMachines.owner(base.copy(ownerKind = "user")))
        assertEquals(OrbManagedMachines.Owner.Mission("m1"), OrbManagedMachines.owner(base.copy(ownerMissionId = "m1")))
        val now = OrbManagedMachines.parseTime("2026-10-23T12:00:00Z")!!
        assertEquals("Reaps in 5 min (owner completed)", OrbManagedMachines.reapLine(base.copy(reapAt = "2026-10-23T12:04:10Z", reapReason = "owner_completed"), now))
        assertEquals("Reaps in 15 min (idle)", OrbManagedMachines.reapLine(base.copy(reapAt = "2026-10-23T12:15:00Z", reapReason = "working_owner_idle"), now))
        assertEquals(
            "Deletes when 24h lease ends in 22 h 00 min",
            OrbManagedMachines.reapLine(base.copy(reapAt = "2026-10-24T10:00:00Z", deletableAt = "2026-10-24T10:00:00Z", reapReason = "awaiting_deletable_at:owner_completed"), now)
        )
        assertEquals("Reap due (owner interrupted, idle)", OrbManagedMachines.reapLine(base.copy(reapAt = "2026-10-23T11:59:00Z", reapReason = "owner_interrupted_idle"), now))
        assertEquals("Reaps in 1 h 30 min (idle, no owner)", OrbManagedMachines.reapLine(base.copy(reapAt = "2026-10-23T13:30:00Z", reapReason = "idle_no_owner"), now))
        assertTrue(OrbManagedMachines.isStopped(base.copy(state = "stopped")))
        assertTrue(OrbManagedMachines.canResume(base.copy(state = "stopped"), false))
        assertFalse(OrbManagedMachines.canResume(base.copy(state = "stopped"), true))
        assertEquals("Hetzner", OrbManagedMachines.providerLabel("hetzner"))
        assertEquals("Vast.ai", OrbManagedMachines.providerLabel("vastai"))
        assertEquals("Scaleway", OrbManagedMachines.providerLabel("scaleway"))
        assertNull(OrbManagedMachines.reapLine(base.copy(state = "destroyed", reapAt = "2026-10-23T12:04:00Z"), now))
    }

    @Test
    fun parsesSharedMultiProviderResponseFixture() {
        val r = OrbManagedMachines.parse(OrbSpec.dict("fixtures/managed-machines-response.json"))
        assertTrue(r.enabled)
        assertEquals("boat", r.provider)
        assertEquals(listOf("boat", "hetzner", "vastai", "scaleway"), r.providers.map { it.provider })
        assertEquals(listOf("boat.dev", "Hetzner Cloud", "Vast.ai", "Scaleway"), r.providers.map { it.displayName })
        assertEquals(listOf(true, true, false, false), r.providers.map { it.configured })
        assertEquals(listOf(true, false, false, false), r.providers.map { it.supportsFreeStop })
        assertEquals(listOf(true, false, false, false), r.providers.map { it.supportsSnapshots })
        assertEquals("arm64", r.providers[1].sizes.first { it.size == "cax31" }.arch)
        assertEquals("RTX 4090", r.providers[2].sizes.first { it.size == "rtx4090" }.gpu)
        assertEquals(1, r.machines.size)
        assertEquals("hetzner", r.machines[0].provider)
        assertFalse(OrbManagedMachines.canStop(r.machines[0], r.providers))
    }
}
