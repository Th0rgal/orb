package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbKernelTest {
    @Test
    fun nativeJniLoadedAndSteppersMatchFixtures() {
        assertTrue("OrbKernel JNI library should load on JVM", OrbKernel.nativeLoaded)
        assertEquals("now", OrbKernel.relativeTimeString(0))
        assertEquals("now", OrbKernel.relativeTimeString(44))
        assertEquals("1m", OrbKernel.relativeTimeString(45))
        assertEquals("2h", OrbKernel.relativeTimeString(7200))
        assertEquals("3d", OrbKernel.relativeTimeString(259200))
        assertEquals("2w", OrbKernel.relativeTimeString(1209600))

        assertNull(OrbKernel.usageLimitBadge("allowed", "five_hour", true, 50, false, 0))
        val warn = OrbKernel.usageLimitBadge("allowed_warning", "five_hour", true, 84, false, 0)
        assertEquals(UsageLimitStatus("warning", "Approaching limit · 5h 84%"), warn)
        val rej = OrbKernel.usageLimitBadge("rejected", "five_hour", false, 0, true, 1800)
        assertEquals(UsageLimitStatus("error", "Limit reached · resets in 30m"), rej)

        val wf = OrbKernel.workfoldStep(2, false, true, true, true, false)
        assertTrue(wf.foldItem)
        val tsRaw = OrbKernel.orbTurnSummaryStep(2, 1, 0, 1)
        assertEquals(0x2000102L, tsRaw)

        assertTrue(OrbKernel.gfmPipeRowAdmitted(0, 12, 12, 3, 3, false))
        assertTrue(OrbKernel.richTagAdmitted(0, 24, 5, 14, 24, 1))
        assertEquals(1.toByte(), OrbKernel.leansysSseFrameScan(0, 60, 64, 1, 10, 10))
        val patchRaw = OrbKernel.orbTranscriptPatchStep(10, 10, 1, 128)
        assertEquals(128L, patchRaw and 0xFFFF_FFFFL)
        assertEquals(11L, (patchRaw ushr 32) and 0xFFFF_FFFFL)
    }

    @Test
    fun negativeRowOffsetIsRejected() {
        assertFalse(OrbKernel.gfmPipeRowAdmitted(-1, 12, 12, 3, 3))
        assertFalse(OrbKernel.gfmPipeRowAdmitted(4, 12, 12, 3, 3))
    }

    @Test
    fun tablesAreCappedAt64Columns() {
        assertTrue(OrbKernel.gfmPipeRowAdmitted(0, 200, 200, 64, 64))
        assertFalse(OrbKernel.gfmPipeRowAdmitted(0, 200, 200, 65, 65))
        fun wide(n: Int) = (0 until n).joinToString(" | ") { "c$it" }
        val src65 = "${wide(65)}\n${wide(65)}"
        assertEquals(src65, OrbPipeTables.normalize(src65))
        assertTrue(OrbPipeTables.normalize("${wide(64)}\n${wide(64)}").contains("| --- |"))
    }

    @Test
    fun tagKind4IsRejected() {
        assertTrue(OrbKernel.richTagAdmitted(0, 24, 5, 14, 24, 3))
        assertFalse(OrbKernel.richTagAdmitted(0, 24, 5, 14, 24, 4))
    }

    @Test
    fun utilizationOver100HidesThePercentage() {
        assertEquals(
            UsageLimitStatus("warning", "Approaching limit · 5h"),
            OrbKernel.usageLimitBadge("allowed_warning", "five_hour", true, 150, false, 0)
        )
        assertEquals(
            UsageLimitStatus("warning", "Approaching limit · 5h 100%"),
            OrbKernel.usageLimitBadge("allowed_warning", "five_hour", true, 100, false, 0)
        )
    }

    @Test
    fun wrappingDeltaSaturates() {
        val raw = OrbKernel.orbTranscriptPatchStep(0xFFFF_FFF0.toInt(), 7, 0, 0x20)
        assertEquals(0xFFFF_FFFFL, raw and 0xFFFF_FFFFL)
        assertEquals(8L, (raw ushr 32) and 0xFFFF_FFFFL)
    }

    @Test
    fun unknownEventKindLeavesStateUnchanged() {
        val raw = OrbKernel.orbTranscriptPatchStep(42, 9, 3, 100)
        assertEquals(42L, raw and 0xFFFF_FFFFL)
        assertEquals(9L, (raw ushr 32) and 0xFFFF_FFFFL)
    }

    @Test
    fun wave7DomainGatesAndSteppersMatchLeanSpec() {
        // Scroll policy
        assertEquals(3817L, OrbKernel.orbScrollMaxTop(4442, 625))
        assertEquals(101L, OrbKernel.orbScrollGap(4442, 625, 3716))
        assertEquals(0, OrbKernel.orbScrollShowsJump(0, 4442, 625, 3716, 160))
        assertEquals(1, OrbKernel.orbScrollShowsJump(0, 4442, 625, 2116, 160))
        assertEquals(1, OrbKernel.orbScrollUserStep(4442, 625, 3796, 40))

        // Stream coalescer, fence, commit, and token cost
        assertEquals(10L, OrbKernel.orbStreamCoalescerStep(1, 10, 0, 0))
        assertEquals(1L, OrbKernel.orbStreamCoalescerStep(1, 10, 4, 0) ushr 63)
        assertEquals(1 to 3, OrbKernel.streamFenceStep(1, 3, 2, 3))
        assertEquals(0 to 0, OrbKernel.streamFenceStep(1, 3, 1, 3))
        val commitInFence = OrbKernel.streamCommitStep(false, 1, 3, true, false, 0, 0, 5, 2)
        assertFalse(commitInFence.commits)
        assertEquals(2, commitInFence.commit)
        assertEquals(152L, OrbKernel.streamTokenCostStep(100, 40, 12))

        // Mission state classification & flags
        assertEquals(0, OrbKernel.missionSortRank(11))
        assertEquals(1, OrbKernel.missionSortRank(16))
        assertEquals(2, OrbKernel.missionSortRank(17))
        assertEquals(9, OrbKernel.missionSortRank(99))
        assertEquals(0, OrbKernel.missionInboxSection(0))
        assertEquals(1, OrbKernel.missionInboxSection(11))
        assertEquals(2, OrbKernel.missionInboxSection(22))
        assertEquals(3, OrbKernel.missionInboxSection(23))
        assertEquals(66, OrbKernel.missionFlags(25) and 66)

        // Connection issue triage
        val okConn = OrbKernel.connectionIssueClassify(false, false, true, true, true)
        assertFalse(okConn.showIssue)
        val proxyConn = OrbKernel.connectionIssueClassify(true, false, true, true, true)
        assertTrue(proxyConn.showIssue)
        assertFalse(proxyConn.recommendDefault)
        assertEquals(1, proxyConn.messageKind)
        val lanConn = OrbKernel.connectionIssueClassify(true, false, true, true, false)
        assertTrue(lanConn.recommendDefault)
        assertEquals(2, lanConn.messageKind)

        // Worked duration, turn outcome, numeric cell, file ref span, machine action, send flow
        val dur = OrbKernel.orbWorkedDurationBucket(185)
        assertEquals(1L, dur and 0xFFL)
        assertEquals(5L, (dur ushr 8) and 0xFFL)
        assertEquals(3L, (dur ushr 32) and 0xFFFF_FFFFL)
        assertEquals(1, OrbKernel.orbTurnOutcomeStep(0, 0, 2, 0, 0, 1))
        assertEquals(256, OrbKernel.orbTurnOutcomeStep(1, 0, 2, 0, 1, 1))
        assertTrue(OrbKernel.numericCellAdmitted(true, true, true, true))
        assertFalse(OrbKernel.numericCellAdmitted(true, true, false, true))
        assertEquals(true to 6, OrbKernel.fileRefLineSpan(10, 15, 20))
        assertEquals(false to 0, OrbKernel.fileRefLineSpan(15, 10, 20))
        val online = OrbKernel.machineActionAdmitted(2, false, false)
        assertTrue(online.isLive && online.canAct && online.meterLiveCost)
        val destroying = OrbKernel.machineActionAdmitted(3, false, false)
        assertTrue(destroying.isLive && !destroying.canAct && !destroying.meterLiveCost)
        val send = OrbKernel.sendFlowStep(true, true, true, false, false, 2, 204)
        assertEquals(2, send.tapAction)
        assertTrue(send.canDrain)
        assertEquals(1, send.editOutcome)

        // LeanSys mobile Jetsam and worker budgets
        assertEquals(1, OrbKernel.leansysVerifyIosJetsamBudget(100_000_000L, 16_384L, 1_400_000_000L, 16_383L, 0))
        assertEquals(1, OrbKernel.leansysVerifyWorkerBudget(4L, 6L, 8L, 4096L, 1))
    }

    @Test
    fun wave8PageAlignedBufferTopologyAndIsaGatesMatchLeanSpec() {
        // 4 KB (mask 4095) and 16 KB (mask 16383) page-aligned buffer gate (Android 15 / Pixel 8 4 KB & 16 KB kernels)
        assertTrue(OrbKernel.verifyPageAlignedBuffer(0x10000L, 12_000L, 16_384L, 100_000_000L, 1_400_000_000L, 16_383L))
        assertTrue(OrbKernel.verifyPageAlignedBuffer(0x10000L, 6_000L, 8_192L, 100_000_000L, 1_400_000_000L, 4_095L))
        assertFalse(OrbKernel.verifyPageAlignedBuffer(0x10000L, 6_000L, 8_192L, 100_000_000L, 1_400_000_000L, 16_383L))
        assertFalse(OrbKernel.verifyPageAlignedBuffer(0x10004L, 12_000L, 16_384L, 100_000_000L, 1_400_000_000L, 16_383L))
        assertFalse(OrbKernel.verifyPageAlignedBuffer(0x10000L, 12_000L, 16_384L, 100_000_000L, 1_400_000_000L, 8_191L))

        // 3-tier mobile topology (topologyKind = 2, e.g. Pixel 8 Tensor G3 1+4+4 -> maxWorkers <= 9)
        assertTrue(OrbKernel.verifyWorkerBudget(5L, 9L, 10L, 4096L, 2))
        assertTrue(OrbKernel.verifyWorkerBudget(9L, 9L, 18L, 4096L, 2))
        assertFalse(OrbKernel.verifyWorkerBudget(9L, 10L, 18L, 4096L, 2))
        assertFalse(OrbKernel.verifyWorkerBudget(5L, 7L, 10L, 4096L, 1))

        // ISA runtime dispatch selection & verification (0=Baseline[263], 1=AppleSilicon[775], 2=ApplePro16[799], 3=Armv82Server[895], 4=Armv9Sve2[927])
        assertEquals(4, OrbKernel.selectIsa(927L, 927L, 4, 4))
        assertEquals(0, OrbKernel.selectIsa(775L, 927L, 4, 4))
        assertTrue(OrbKernel.verifyIsaSelection(927L, 927L, 4, 4))
        assertTrue(OrbKernel.verifyIsaSelection(775L, 263L, 0, 4))
        assertFalse(OrbKernel.verifyIsaSelection(775L, 927L, 4, 4))
    }
}
