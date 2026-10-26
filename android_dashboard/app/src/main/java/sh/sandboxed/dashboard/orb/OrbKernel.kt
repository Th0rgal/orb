package sh.sandboxed.dashboard.orb

import java.io.File

object OrbKernel {
    internal val nativeLoaded: Boolean = runCatching {
        try {
            System.loadLibrary("orb_kernel")
            true
        } catch (_: UnsatisfiedLinkError) {
            val isMac = System.getProperty("os.name").orEmpty().lowercase().contains("mac")
            val ext = if (isMac) "dylib" else "so"
            val candidates = listOf(
                File("app/src/test/resources/jni/liborb_kernel.$ext"),
                File("src/test/resources/jni/liborb_kernel.$ext"),
                File("../android_dashboard/app/src/test/resources/jni/liborb_kernel.$ext"),
                File("app/src/test/resources/jni/liborb_kernel.so"),
                File("src/test/resources/jni/liborb_kernel.so"),
                File("../android_dashboard/app/src/test/resources/jni/liborb_kernel.so")
            )
            val found = candidates.firstOrNull { it.isFile }
            if (found != null) {
                System.load(found.absolutePath)
                true
            } else {
                false
            }
        }
    }.getOrDefault(false)

    @JvmStatic
    external fun orbWorkfoldStep(
        itemKind: Int,
        isCumulative: Int,
        isNonEmpty: Int,
        toolAhead: Int,
        nextIsTool: Int,
        foldHasTool: Int
    ): Long

    @JvmStatic
    external fun orbTaskcardStep(
        turnEnded: Int,
        allClosed: Int,
        turnOutcomeFinished: Int
    ): Long

    @JvmStatic
    external fun orbTurnSummaryStep(
        rawStatus: Int,
        turnEnded: Int,
        allClosed: Int,
        turnOutcomeFinished: Int
    ): Long

    @JvmStatic
    external fun orbUsageLimitStatus(
        statusKind: Int,
        claimKind: Int,
        hasUtilization: Int,
        utilizationPct: Int,
        hasReset: Int,
        resetRemSecs: Long
    ): Long

    @JvmStatic
    external fun orbRelativeTimeBucket(elapsedSecs: Long): Long

    @JvmStatic
    external fun orbTranscriptPatchStep(
        stateLen: Int,
        stateSeq: Int,
        eventKind: Int,
        deltaLen: Int
    ): Long

    @JvmStatic
    external fun orbScrollMaxTop(content: Long, viewport: Long): Long

    @JvmStatic
    external fun orbScrollClampTop(content: Long, viewport: Long, top: Long): Long

    @JvmStatic
    external fun orbScrollGap(content: Long, viewport: Long, top: Long): Long

    @JvmStatic
    external fun orbScrollLayoutStep(pinned: Int, content: Long, viewport: Long, top: Long): Long

    @JvmStatic
    external fun orbScrollUserStep(content: Long, viewport: Long, top: Long, threshold: Long): Int

    @JvmStatic
    external fun orbScrollJumpStep(content: Long, viewport: Long): Long

    @JvmStatic
    external fun orbScrollCorrect(pinned: Int, content: Long, viewport: Long, top: Long): Long

    @JvmStatic
    external fun orbScrollShowsJump(pinned: Int, content: Long, viewport: Long, top: Long, pillThreshold: Long): Int

    @JvmStatic
    external fun orbStreamCoalescerStep(op: Int, shownLen: Int, pendingLen: Int, deltaLen: Int): Long

    @JvmStatic
    external fun orbStreamFenceStep(openKind: Int, openCount: Int, markerKind: Int, markerCount: Int): Long

    @JvmStatic
    external fun orbStreamCommitStep(
        tick: Int,
        openKind: Int,
        openCount: Int,
        lineBlank: Int,
        lineTick: Int,
        markerKind: Int,
        markerCount: Int,
        pos: Int,
        commit: Int
    ): Long

    @JvmStatic
    external fun orbStreamTokenCostStep(prevCost: Long, newAdvance: Long, tailBytes: Long): Long

    @JvmStatic
    external fun orbMissionStateClassify(stateId: Int): Int

    @JvmStatic
    external fun orbMissionSortRank(stateId: Int): Int

    @JvmStatic
    external fun orbMissionFlags(stateId: Int): Int

    @JvmStatic
    external fun orbMissionInboxSection(stateId: Int): Int

    @JvmStatic
    external fun orbConnectionIssueClassify(
        isUnreachable: Int,
        isUsingDefault: Int,
        isPrivateAddr: Int,
        defaultReachable: Int,
        hasExternalProxy: Int
    ): Int

    @JvmStatic
    external fun orbWorkedDurationBucket(seconds: Long): Long

    @JvmStatic
    external fun orbTurnOutcomeStep(
        prevOutcome: Int,
        prevFailed: Int,
        eventKind: Int,
        isNarration: Int,
        isSuccessFalse: Int,
        isTextNonEmpty: Int
    ): Int

    @JvmStatic
    external fun orbNumericCellScan(
        nonEmpty: Int,
        hasLeadingDigitOrSign: Int,
        hasDigit: Int,
        allAllowedChars: Int
    ): Int

    @JvmStatic
    external fun orbFileRefLineSpan(startLine: Int, endLine: Int, totalLines: Int): Long

    @JvmStatic
    external fun orbMachineActionAdmitted(stateKind: Int, isBusy: Int, isMuted: Int): Int

    @JvmStatic
    external fun orbSendFlowStep(
        isBusy: Int,
        hasNonEmptyText: Int,
        canQueue: Int,
        awaitingAck: Int,
        isDraining: Int,
        pendingCount: Int,
        httpStatus: Int
    ): Int

    @JvmStatic
    external fun leansysSseFrameScan(
        frameOff: Long,
        frameLen: Long,
        chunkLen: Long,
        fieldKind: Int,
        nextByte: Int,
        lastByte: Int
    ): Byte

    @JvmStatic
    external fun leansysGfmPipeScan(
        rowOff: Long,
        rowLen: Long,
        bufLen: Long,
        colCount: Int,
        sepCols: Int,
        unterminatedEscape: Int
    ): Byte

    @JvmStatic
    external fun leansysTagScan(
        tagOff: Long,
        tagLen: Long,
        attrOff: Long,
        attrLen: Long,
        bufLen: Long,
        tagKind: Int
    ): Byte

    @JvmStatic
    external fun leansysTranscriptIndex(
        turnOff: Long,
        turnLen: Long,
        bufLen: Long,
        prevDigest: Long,
        blockHash: Long
    ): Long

    @JvmStatic
    external fun leansysVerifyIosJetsamBudget(
        dirtyRssBytes: Long,
        allocBytes: Long,
        maxJetsamBytes: Long,
        pageAlignMask: Long,
        isAppExtension: Int
    ): Int

    @JvmStatic
    external fun leansysVerifyWorkerBudget(
        activeWorkers: Long,
        maxWorkers: Long,
        microChunks: Long,
        totalLen: Long,
        isMobileHetero: Int
    ): Int

    data class WorkfoldVerdict(val foldItem: Boolean, val foldHasToolNext: Boolean)

    fun workfoldStep(
        itemKind: Int,
        isCumulative: Boolean,
        isNonEmpty: Boolean,
        toolAhead: Boolean,
        nextIsTool: Boolean,
        foldHasTool: Boolean
    ): WorkfoldVerdict {
        val raw = if (nativeLoaded) {
            orbWorkfoldStep(
                itemKind,
                if (isCumulative) 1 else 0,
                if (isNonEmpty) 1 else 0,
                if (toolAhead) 1 else 0,
                if (nextIsTool) 1 else 0,
                if (foldHasTool) 1 else 0
            )
        } else {
            when (itemKind) {
                3 -> 257L
                1 -> if (foldHasTool) 257L else 1L
                2 -> if (!isCumulative && isNonEmpty && toolAhead && (foldHasTool || nextIsTool)) {
                    if (foldHasTool) 257L else 1L
                } else 0L
                else -> 0L
            }
        }
        return WorkfoldVerdict(
            foldItem = (raw and 1L) != 0L,
            foldHasToolNext = ((raw ushr 8) and 1L) != 0L
        )
    }

    fun relativeTimeString(elapsedSecs: Long): String {
        val clamped = maxOf(0L, elapsedSecs)
        val raw = if (nativeLoaded) {
            orbRelativeTimeBucket(clamped)
        } else {
            when {
                clamped < 45L -> 0L
                clamped < 3600L -> 1L or (maxOf(1L, clamped / 60L) shl 8)
                clamped < 86_400L -> 2L or ((clamped / 3600L) shl 8)
                clamped < 604_800L -> 3L or ((clamped / 86_400L) shl 8)
                else -> 4L or (minOf(0xFFFF_FFFFL, clamped / 604_800L) shl 8)
            }
        }
        val unit = (raw and 0xFFL).toInt()
        val value = ((raw ushr 8) and 0xFFFF_FFFFL)
        return when (unit) {
            0 -> "now"
            1 -> "${value}m"
            2 -> "${value}h"
            3 -> "${value}d"
            else -> "${value}w"
        }
    }

    internal fun usageLimitBadge(
        status: String,
        claim: String,
        hasUtilization: Boolean,
        utilizationPct: Int,
        hasReset: Boolean,
        resetRemSecs: Long
    ): UsageLimitStatus? {
        val statusKind = when (status) {
            "", "allowed", "ok" -> 0
            "allowed_warning" -> 1
            "rejected" -> 2
            else -> 3
        }
        val claimKind = when (claim) {
            "five_hour" -> 1
            "seven_day" -> 2
            "seven_day_opus" -> 3
            "seven_day_sonnet" -> 4
            else -> 0
        }
        val pct8 = utilizationPct.coerceIn(0, 255)
        val rem = maxOf(0L, resetRemSecs)
        val raw = if (nativeLoaded) {
            orbUsageLimitStatus(
                statusKind,
                claimKind,
                if (hasUtilization) 1 else 0,
                utilizationPct,
                if (hasReset) 1 else 0,
                rem
            )
        } else {
            when (statusKind) {
                0 -> 0L
                1 -> {
                    val win = if (claimKind in 1..4) (claimKind.toLong() shl 8) else 0L
                    val show = if ((claimKind == 1 || claimKind == 2) && hasUtilization && pct8 <= 100) 65536L else 0L
                    val pctBits = if (show != 0L) (pct8.toLong() shl 24) else 0L
                    1L or win or show or pctBits
                }
                2 -> if (hasReset && rem > 0L) {
                    val mins = rem / 60L
                    val hrs = rem / 3600L
                    val days = rem / 86_400L
                    val unit = if (mins < 60L) 1L else if (hrs < 48L) 2L else 3L
                    val v = if (mins < 60L) maxOf(1L, mins) else if (hrs < 48L) hrs else days
                    2L or (unit shl 32) or (minOf(0xFFFFFFL, v) shl 40)
                } else 2L
                else -> 3L
            }
        }
        val tone = (raw and 0xFFL).toInt()
        if (tone == 0) return null
        if (tone == 1) {
            val winKind = ((raw ushr 8) and 0xFFL).toInt()
            val winLabel = when (winKind) {
                1 -> "5h"
                2 -> "weekly"
                3 -> "weekly Opus"
                4 -> "weekly Sonnet"
                else -> return UsageLimitStatus("warning", "Approaching limit")
            }
            val showPct = ((raw ushr 16) and 1L) != 0L
            val pct = ((raw ushr 24) and 0xFFL).toInt()
            val suffix = if (showPct) " ${pct}%" else ""
            return UsageLimitStatus("warning", "Approaching limit · ${winLabel}${suffix}")
        }
        if (tone == 2) {
            val resetUnit = ((raw ushr 32) and 0xFFL).toInt()
            val resetVal = ((raw ushr 40) and 0xFFFFFFL)
            if (resetUnit == 0) return UsageLimitStatus("error", "Limit reached")
            val unitSuffix = when (resetUnit) {
                1 -> "m"
                2 -> "h"
                else -> "d"
            }
            return UsageLimitStatus("error", "Limit reached · resets in ${resetVal}${unitSuffix}")
        }
        return UsageLimitStatus("warning", "Limit status unknown")
    }

    fun gfmPipeRowAdmitted(
        rowOff: Int,
        rowLen: Int,
        bufLen: Int,
        colCount: Int,
        sepCols: Int,
        unterminatedEscape: Boolean = false
    ): Boolean = if (nativeLoaded) {
        leansysGfmPipeScan(
            rowOff.toLong(),
            rowLen.toLong(),
            bufLen.toLong(),
            colCount,
            sepCols,
            if (unterminatedEscape) 1 else 0
        ).toInt() != 0
    } else {
        rowLen > 0 && subsliceOk(rowOff.toLong(), rowLen.toLong(), bufLen.toLong()) &&
            colCount in 1..64 && sepCols == colCount && !unterminatedEscape
    }

    fun richTagAdmitted(
        tagOff: Int,
        tagLen: Int,
        attrOff: Int,
        attrLen: Int,
        bufLen: Int,
        tagKind: Int
    ): Boolean = if (nativeLoaded) {
        leansysTagScan(
            tagOff.toLong(),
            tagLen.toLong(),
            attrOff.toLong(),
            attrLen.toLong(),
            bufLen.toLong(),
            tagKind
        ).toInt() != 0
    } else {
        tagLen > 0 && subsliceOk(tagOff.toLong(), tagLen.toLong(), bufLen.toLong()) && tagOff <= attrOff &&
            subsliceOk((attrOff - tagOff).toLong(), attrLen.toLong(), tagLen.toLong()) && tagKind in 1..3
    }

    private fun subsliceOk(off: Long, len: Long, cap: Long): Boolean =
        off >= 0 && len >= 0 && off <= cap && len <= cap - off

    private fun bInt(v: Boolean): Int = if (v) 1 else 0

    fun missionStateClassify(stateId: Int): Int =
        if (nativeLoaded) orbMissionStateClassify(stateId)
        else when {
            stateId in 0..8 -> 3
            stateId in 9..10 -> 4
            stateId in 11..15 -> 0
            stateId == 16 -> 1
            stateId in 17..21 -> 2
            stateId in 22..23 -> 6
            stateId == 24 -> 5
            stateId in 25..26 -> 7
            stateId in 27..28 -> 8
            else -> 9
        }

    fun missionSortRank(stateId: Int): Int =
        if (nativeLoaded) orbMissionSortRank(stateId) else missionStateClassify(stateId)

    fun missionFlags(stateId: Int): Int =
        if (nativeLoaded) orbMissionFlags(stateId)
        else {
            val cat = missionStateClassify(stateId)
            val base = when (cat) {
                0 -> 4
                1 -> 36
                2 -> 166
                3, 4 -> 1
                7 -> 194
                6, 8 -> 128
                else -> 0
            }
            val extra = when (stateId) {
                11, 12, 24, 25, 26 -> 8
                16, 17, 20, 22 -> 24
                else -> 0
            }
            base or extra
        }

    fun missionInboxSection(stateId: Int): Int =
        if (nativeLoaded) orbMissionInboxSection(stateId)
        else when (val cat = missionStateClassify(stateId)) {
            3, 4 -> 0
            0, 1, 2 -> 1
            7, 5 -> 2
            6 -> if (stateId == 22) 2 else 3
            else -> 3
        }

    data class ConnectionIssueVerdict(
        val showIssue: Boolean,
        val offerUseDefault: Boolean,
        val recommendDefault: Boolean,
        val shouldProbeDefault: Boolean,
        val messageKind: Int
    )

    fun connectionIssueClassify(
        isUnreachable: Boolean,
        isUsingDefault: Boolean,
        isPrivateAddr: Boolean,
        defaultReachable: Boolean,
        hasExternalProxy: Boolean
    ): ConnectionIssueVerdict {
        val raw = if (nativeLoaded) {
            orbConnectionIssueClassify(
                bInt(isUnreachable),
                bInt(isUsingDefault),
                bInt(isPrivateAddr),
                bInt(defaultReachable),
                bInt(hasExternalProxy)
            )
        } else {
            if (!isUnreachable) 0
            else {
                val offer = if (!isUsingDefault) 256 else 0
                val probe = if (!isUsingDefault && isPrivateAddr) 16777216 else 0
                if (hasExternalProxy) 1 or offer or probe or (1 shl 28)
                else {
                    val rec = !isUsingDefault && isPrivateAddr && defaultReachable
                    val recBit = if (rec) 65536 else 0
                    val kind = when {
                        rec -> 2
                        isPrivateAddr -> 3
                        isUsingDefault -> 4
                        else -> 5
                    }
                    1 or offer or recBit or probe or (kind shl 28)
                }
            }
        }
        return ConnectionIssueVerdict(
            showIssue = (raw and 1) != 0,
            offerUseDefault = ((raw ushr 8) and 1) != 0,
            recommendDefault = ((raw ushr 16) and 1) != 0,
            shouldProbeDefault = ((raw ushr 24) and 1) != 0,
            messageKind = (raw ushr 28) and 0xF
        )
    }

    fun numericCellAdmitted(
        nonEmpty: Boolean,
        hasLeadingDigitOrSign: Boolean,
        hasDigit: Boolean,
        allAllowedChars: Boolean
    ): Boolean = if (nativeLoaded) {
        orbNumericCellScan(
            bInt(nonEmpty),
            bInt(hasLeadingDigitOrSign),
            bInt(hasDigit),
            bInt(allAllowedChars)
        ) != 0
    } else {
        nonEmpty && hasLeadingDigitOrSign && hasDigit && allAllowedChars
    }

    fun fileRefLineSpan(startLine: Int, endLine: Int, totalLines: Int = 0): Pair<Boolean, Int> {
        if (startLine < 0 || endLine < 0 || totalLines < 0) return false to 0
        val raw = if (nativeLoaded) {
            orbFileRefLineSpan(startLine, endLine, totalLines)
        } else {
            if (startLine >= 1 && startLine <= endLine && (totalLines == 0 || endLine <= totalLines)) {
                val count = (endLine - startLine + 1).toLong()
                1L or (count shl 32)
            } else 0L
        }
        return ((raw and 1L) != 0L) to ((raw ushr 32) and 0xFFFF_FFFFL).toInt()
    }

    data class MachineActionVerdict(val isLive: Boolean, val canAct: Boolean, val meterLiveCost: Boolean)

    fun machineActionAdmitted(stateKind: Int, isBusy: Boolean = false, isMuted: Boolean = false): MachineActionVerdict {
        val raw = if (nativeLoaded) {
            orbMachineActionAdmitted(stateKind.coerceIn(0, 255), bInt(isBusy), bInt(isMuted))
        } else {
            val live = if (stateKind in 0..3) 1 else 0
            val act = if (stateKind in 0..2 && !isBusy && !isMuted) 256 else 0
            val meter = if (stateKind in 0..2) 65536 else 0
            live or act or meter
        }
        return MachineActionVerdict(
            isLive = (raw and 1) != 0,
            canAct = ((raw ushr 8) and 1) != 0,
            meterLiveCost = ((raw ushr 16) and 1) != 0
        )
    }

    data class SendFlowVerdict(val tapAction: Int, val canDrain: Boolean, val editOutcome: Int)

    fun sendFlowStep(
        isBusy: Boolean = false,
        hasNonEmptyText: Boolean = false,
        canQueue: Boolean = false,
        awaitingAck: Boolean = false,
        isDraining: Boolean = false,
        pendingCount: Int = 0,
        httpStatus: Int = 0
    ): SendFlowVerdict {
        val raw = if (nativeLoaded) {
            orbSendFlowStep(
                bInt(isBusy),
                bInt(hasNonEmptyText),
                bInt(canQueue),
                bInt(awaitingAck),
                bInt(isDraining),
                pendingCount.coerceIn(0, 255),
                maxOf(0, httpStatus)
            )
        } else {
            val tap = if (!hasNonEmptyText) 0 else if (!isBusy) 1 else if (canQueue) 2 else 0
            val drain = if (pendingCount > 0 && !awaitingAck && !isDraining) 256 else 0
            val edit = when {
                httpStatus in 200..299 -> 1
                httpStatus == 404 || httpStatus == 405 -> 2
                httpStatus == 409 -> 3
                else -> 0
            }
            tap or drain or (edit shl 16)
        }
        return SendFlowVerdict(
            tapAction = raw and 0xFF,
            canDrain = ((raw ushr 8) and 1) != 0,
            editOutcome = (raw ushr 16) and 0xFF
        )
    }

    data class StreamCommitVerdict(
        val tick: Boolean,
        val openKind: Int,
        val openCount: Int,
        val commits: Boolean,
        val pos: Int,
        val commit: Int
    )

    fun streamFenceStep(openKind: Int, openCount: Int, markerKind: Int, markerCount: Int): Pair<Int, Int> {
        val raw = if (nativeLoaded) {
            orbStreamFenceStep(openKind, openCount, markerKind, markerCount)
        } else {
            val nk = if (openKind == 0) {
                if ((markerKind == 1 || markerKind == 2) && markerCount >= 3) markerKind else 0
            } else {
                if (markerKind == openKind && openCount <= markerCount && markerCount >= 3) 0 else openKind
            }
            val nc = if (openKind == 0) {
                if ((markerKind == 1 || markerKind == 2) && markerCount >= 3) markerCount else 0
            } else {
                if (markerKind == openKind && openCount <= markerCount && markerCount >= 3) 0 else openCount
            }
            nk.toLong() or (nc.toLong() shl 32)
        }
        return (raw and 0xFFL).toInt() to ((raw ushr 32) and 0xFFFF_FFFFL).toInt()
    }

    fun streamCommitStep(
        tick: Boolean,
        openKind: Int,
        openCount: Int,
        lineBlank: Boolean,
        lineTick: Boolean,
        markerKind: Int,
        markerCount: Int,
        pos: Int,
        commit: Int
    ): StreamCommitVerdict {
        val fence = streamFenceStep(openKind, openCount, markerKind, markerCount)
        val raw = if (nativeLoaded) {
            orbStreamCommitStep(
                bInt(tick),
                openKind,
                openCount,
                bInt(lineBlank),
                bInt(lineTick),
                markerKind,
                markerCount,
                pos,
                commit
            )
        } else {
            val nextTick = if (lineTick) !tick else tick
            val commits = lineBlank && !nextTick && fence.first == 0
            val nextCommit = if (commits) pos + 1 else commit
            val lo = (if (nextTick) 1L else 0L) or ((fence.first.toLong() and 0xFFL) shl 8) or (if (commits) 65536L else 0L)
            lo or (nextCommit.toLong() shl 32)
        }
        return StreamCommitVerdict(
            tick = (raw and 1L) != 0L,
            openKind = ((raw ushr 8) and 0xFFL).toInt(),
            openCount = fence.second,
            commits = ((raw ushr 16) and 1L) != 0L,
            pos = pos + 1,
            commit = ((raw ushr 32) and 0xFFFF_FFFFL).toInt()
        )
    }

    fun streamTokenCostStep(prevCost: Long, newAdvance: Long, tailBytes: Long): Long =
        if (nativeLoaded) orbStreamTokenCostStep(maxOf(0L, prevCost), maxOf(0L, newAdvance), maxOf(0L, tailBytes))
        else prevCost + newAdvance + tailBytes
}
