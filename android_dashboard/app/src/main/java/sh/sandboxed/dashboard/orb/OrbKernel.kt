package sh.sandboxed.dashboard.orb

import java.io.File

object OrbKernel {
    internal val nativeLoaded: Boolean = runCatching {
        try {
            System.loadLibrary("orb_kernel")
            true
        } catch (_: UnsatisfiedLinkError) {
            val candidates = listOf(
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
    external fun leansysSseFrameScan(
        frameOff: Long,
        frameLen: Long,
        chunkLen: Long,
        fieldKind: Int,
        nextByte: Int
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
        val clampedPct = utilizationPct.coerceIn(0, 100)
        val rem = maxOf(0L, resetRemSecs)
        val raw = if (nativeLoaded) {
            orbUsageLimitStatus(
                statusKind,
                claimKind,
                if (hasUtilization) 1 else 0,
                clampedPct,
                if (hasReset) 1 else 0,
                rem
            )
        } else {
            when (statusKind) {
                0 -> 0L
                1 -> {
                    val win = if (claimKind in 1..4) (claimKind.toLong() shl 8) else 0L
                    val show = if ((claimKind == 1 || claimKind == 2) && hasUtilization) 65536L else 0L
                    val pctBits = if (show != 0L) (clampedPct.toLong() shl 24) else 0L
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
        colCount >= 1 && sepCols == colCount && !unterminatedEscape && rowLen >= 1 && rowOff + rowLen <= bufLen
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
        tagKind in 1..4 && tagLen >= 3 && attrLen >= 1 && tagOff <= attrOff && attrOff + attrLen <= tagOff + tagLen && tagOff + tagLen <= bufLen
    }
}
