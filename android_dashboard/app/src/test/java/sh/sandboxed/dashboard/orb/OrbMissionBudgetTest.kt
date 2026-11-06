package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbMissionBudgetTest {
    private fun own(budget: Double, maxGrant: Double? = null) = OrbMissionBudget.from(
        OrbJSON.parse(
            """{"mission_id":"m1","own_budget_usd":$budget,"pool_id":"m1","mode":"own","max_grant_usd":${maxGrant ?: "null"},
            "pool":{"budget_usd":$budget,"spent_usd":0.4,"reserved_usd":0.2,"carved_usd":1,"available_usd":${budget - 1.6}},
            "effective_bandwidth":{"source":"none","current_compute_usd_per_hour":2.0,"current_tokens_per_min":48000,"current_vcpu_per_min":16},
            "children":[{"mission_id":"c1","mode":"sub_budget","budget_usd":1,"spent_usd":0.3}]}"""
        )
    )

    @Test fun parsesTheServerView() {
        val v = own(4.0)
        assertEquals("own", v.mode)
        assertEquals(2.4, v.pool!!.available, 1e-9)
        assertEquals("sub_budget", v.children.first().mode)
        assertEquals("none", OrbMissionBudget.from(OrbJSON.parse("""{"mission_id":"x","pool":null,"children":[]}""")).mode)
    }

    @Test fun optimisticMatchesDesktop() {
        assertEquals(4.4, own(4.0).optimistic(6.0).pool!!.available, 1e-9)
        assertEquals("none", own(4.0).optimistic(null).mode)
        assertEquals("pooled", own(4.0, 2.0).optimistic(null).mode)
        assertNull(own(4.0).optimistic(null).pool)
        assertEquals("$2.00", OrbMissionBudget.money(2.0))
        assertEquals(2.5, OrbMissionBudget.parseAmount("$2.5")!!, 1e-9)
        assertNull(OrbMissionBudget.parseAmount("0"))
    }

    @Test fun decodesSharedMissionBudgetFixtureAndVmLimits() {
        val root = OrbSpec.dict("fixtures/mission-budget.json")

        val globalDefault = OrbMissionBudget.from(root["global_default"])
        assertEquals("none", globalDefault.mode)
        assertEquals("global", globalDefault.vmLimitsMode)
        assertEquals("none", globalDefault.bandwidthMode)
        assertNull(globalDefault.ownVmLimits)
        assertNull(globalDefault.ownBandwidthLimits)
        assertEquals(16, globalDefault.effectiveVmLimits?.globalMaxConcurrent)
        assertEquals("Uses the global limit (16 concurrent across Orb).", globalDefault.vmLimitsModeLine)
        assertEquals("Unthrottled. Requests and spawns run at full speed.", globalDefault.bandwidthModeLine)
        assertFalse(globalDefault.showsSubagents)
        assertTrue(globalDefault.children.all { it.isIdlePooled })

        val dedicated = OrbMissionBudget.from(root["dedicated_override"])
        assertEquals("own", dedicated.mode)
        assertEquals("own", dedicated.vmLimitsMode)
        assertEquals("own", dedicated.bandwidthMode)
        assertEquals(6, dedicated.ownVmLimits?.maxConcurrent)
        assertEquals(mapOf("hetzner" to 0, "vastai" to 2), dedicated.ownVmLimits?.providerMaxConcurrent)
        assertEquals("Hetzner: off · Vast.ai: 2", OrbMissionBudget.providerLimitsSummary(dedicated.ownVmLimits))
        assertEquals("120k tok/min · 32 vCPU/min · $2.50/h", OrbMissionBudget.bandwidthLimitsSummary(dedicated.ownBandwidthLimits))
        assertEquals(3, dedicated.effectiveVmLimits?.active)
        assertEquals(2, dedicated.effectiveVmLimits?.providerLimits?.size)
        assertEquals(120_000, dedicated.effectiveBandwidth?.tokensPerMin)
        assertEquals(true, dedicated.effectiveBandwidth?.protectRoot)
        assertTrue(dedicated.showsSubagents)
        assertFalse(dedicated.children[0].isIdlePooled)
        assertTrue(dedicated.children[1].isIdlePooled)

        val cleared = dedicated.optimisticVmLimits(null)
        assertEquals("global", cleared.vmLimitsMode)
        assertNull(cleared.ownVmLimits)
        assertEquals(16, cleared.effectiveVmLimits?.maxConcurrent)

        val clearedBw = dedicated.optimisticBandwidthLimits(null)
        assertEquals("none", clearedBw.bandwidthMode)
        assertNull(clearedBw.ownBandwidthLimits)

        val dailySust = OrbMissionBudget.from(root["daily_sustainable_with_lease_cliff"])
        assertEquals(OrbMissionBudget.BudgetResetPeriod.DAILY, dailySust.ownBudgetResetPeriod)
        assertEquals(920.0, dailySust.pool?.lifetimeSpent ?: 0.0, 1e-9)
        assertEquals(
            "150k tok/min · $18/h LLM · 64 vCPU/min · $10/h",
            OrbMissionBudget.bandwidthLimitsSummary(dailySust.ownBandwidthLimits),
        )
        assertTrue(dailySust.modeLine.contains("Own daily budget"))
        val fc = dailySust.computeRunwayForecast(
            bandwidthEnabled = true,
            budgetEnabled = true,
            nowMs = 1_793_922_300_000L,
        )
        assertTrue(fc.sustainsUntilReset)
        assertEquals(900.0, fc.resetsInSecs ?: 0.0, 1.0)
        assertEquals(0.0, fc.leaseCliffSecs ?: -1.0, 1e-6)
        assertEquals("Sustains until daily reset", fc.headline)
        assertTrue(fc.subline.contains("VM auto-extensions paused ($2.00 < $2.50 30m step)"))
        assertEquals(OrbMissionBudget.RunwayForecast.Tone.WARNING, fc.tone)

        val pooledChild = dailySust.copy(
            ownBudget = null,
            ownBudgetResetPeriod = OrbMissionBudget.BudgetResetPeriod.TOTAL,
            mode = "pooled",
            maxGrant = 2.0,
        )
        val pooledFc = pooledChild.computeRunwayForecast(
            bandwidthEnabled = true,
            nowMs = 1_793_922_300_000L,
        )
        assertEquals(OrbMissionBudget.BudgetResetPeriod.DAILY, pooledFc.resetPeriod)
        assertTrue(pooledFc.sustainsUntilReset)
        assertEquals("Sustains until daily reset", pooledFc.headline)

        val immediateFleetBatch = dailySust.copy(
            pool = dailySust.pool!!.copy(
                liveMachines = 10,
                liveLeases = emptyList(),
                spent = 255.8333,
                carved = 40.0,
                reserved = 1.6667,
                available = 2.5,
            ),
        )
        val immediateFleetFc = immediateFleetBatch.computeRunwayForecast(
            bandwidthEnabled = true,
            budgetEnabled = true,
            nowMs = 1_793_922_300_000L,
        )
        assertTrue(immediateFleetFc.sustainsUntilReset)
        assertEquals(0.0, immediateFleetFc.leaseCliffSecs ?: -1.0, 1e-6)
        assertTrue(immediateFleetFc.subline.contains("VM auto-extensions paused ($2.50 left across 10 VMs)"))

        val staggeredCliff = dailySust.copy(
            pool = dailySust.pool!!.copy(
                liveMachines = 2,
                liveLeases = listOf(
                    OrbMissionBudget.LiveLease(remainingSecs = 900.0, usdPerHour = 5.0),
                    OrbMissionBudget.LiveLease(remainingSecs = 1500.0, usdPerHour = 5.0),
                ),
                spent = 254.1667,
                carved = 40.0,
                reserved = 3.3333,
                available = 2.5,
            ),
        )
        val staggeredFc = staggeredCliff.computeRunwayForecast(
            bandwidthEnabled = true,
            budgetEnabled = true,
            nowMs = 1_793_922_300_000L,
        )
        assertTrue(staggeredFc.sustainsUntilReset)
        assertEquals(900.0, staggeredFc.leaseCliffSecs ?: 0.0, 1.0)
        assertTrue(staggeredFc.subline.contains("VM extensions pause in ~15m"))

        val singleVmStep = dailySust.copy(
            pool = dailySust.pool!!.copy(
                liveMachines = 1,
                liveLeases = listOf(OrbMissionBudget.LiveLease(remainingSecs = 1800.0, usdPerHour = 10.0)),
                spent = 290.0,
                carved = 0.0,
                reserved = 5.0,
                available = 5.0,
            ),
        )
        val singleVmFc = singleVmStep.computeRunwayForecast(
            bandwidthEnabled = true,
            budgetEnabled = true,
            nowMs = 1_793_922_300_000L,
        )
        assertEquals(3_000.0, singleVmFc.leaseCliffSecs ?: 0.0, 1.0)
    }

    @Test fun validatesVmAndBandwidthInputsAndForecast() {
        val ok = OrbMissionBudget.parseVmLimits("8", mapOf("vastai" to "2", "hetzner" to "0")).getOrThrow()
        assertEquals(8, ok.maxConcurrent)
        assertEquals(mapOf("vastai" to 2, "hetzner" to 0), ok.providerMaxConcurrent)

        assertTrue(OrbMissionBudget.parseVmLimits("", emptyMap()).isFailure)
        assertTrue(OrbMissionBudget.parseVmLimits("2", mapOf("vastai" to "4")).isFailure)

        val bw = OrbMissionBudget.parseBandwidthLimits("120k", "32", "$2.5", true).getOrThrow()
        assertEquals(120_000, bw.tokensPerMin)
        assertEquals(32, bw.computeVcpuPerMin)
        assertEquals(2.5, bw.computeUsdPerHour ?: 0.0, 1e-9)
        val bwInf = OrbMissionBudget.parseBandwidthLimits("", "", "", true, inferenceUsdPerHRaw = "$12.5").getOrThrow()
        assertEquals(12.5, bwInf.inferenceUsdPerHour ?: 0.0, 1e-9)
        assertTrue(OrbMissionBudget.parseBandwidthLimits("", "", "", true).isFailure)

        val base10 = own(10.0)
        val unshaped = base10.computeRunwayForecast(budgetEnabled = true)
        assertEquals(15_480.0, unshaped.etaSecs ?: 0.0, 1.0)
        val shaped = base10.computeRunwayForecast(
            draftComputeUsdPerH = "1.0",
            bandwidthEnabled = true,
            budgetEnabled = true,
        )
        assertEquals(30_960.0, shaped.etaSecs ?: 0.0, 1.0)
        assertTrue(shaped.subline.contains("from bandwidth cap"))

        val fullyReserved = OrbMissionBudget.from(
            OrbJSON.parse(
                """{"mission_id":"m1","own_budget_usd":1,"pool_id":"m1","mode":"own",
                "pool":{"budget_usd":1,"spent_usd":0,"reserved_usd":1,"carved_usd":0,"available_usd":0},
                "effective_bandwidth":{"source":"none","current_compute_usd_per_hour":1.0},
                "children":[]}"""
            )
        )
        val freshVm = fullyReserved.computeRunwayForecast(budgetEnabled = true)
        assertEquals(3_600.0, freshVm.etaSecs ?: 0.0, 1.0)
        assertTrue(freshVm.headline.contains("~1h runway left"))
    }
}
