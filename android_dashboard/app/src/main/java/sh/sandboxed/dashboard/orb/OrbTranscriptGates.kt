package sh.sandboxed.dashboard.orb

import kotlin.math.max
import kotlin.math.min

/**
 * Verified cross-client transcript safety gates (`lean/Orb/Transcript.lean`,
 * checked against `shared/orb-spec/fixtures/transcript-gates.json`).
 */
object OrbTranscriptGates {
    const val MAX_LATEX_SPAN_CHARS = 8192

    data class CandidateKey(val tag: Int, val item: Int)
    data class TurnKey(val tag: Int, val item: Int, val gen: Int)
    data class MountDecision(val admitted: Boolean, val nextActive: Int)

    fun allocTurnKeys(candidates: List<CandidateKey>): List<TurnKey> {
        val seen = HashSet<CandidateKey>(candidates.size)
        var nextGen = 1
        val out = ArrayList<TurnKey>(candidates.size)
        for (c in candidates) {
            if (!seen.add(c)) {
                out.add(TurnKey(c.tag, c.item, nextGen))
                nextGen += 1
            } else {
                out.add(TurnKey(c.tag, c.item, 0))
            }
        }
        return out
    }

    /**
     * Ensures strictly unique, non-empty row IDs (`LazyColumn` / `ForEach` safety)
     * while leaving already-distinct non-empty IDs untouched (`gen == 0`).
     */
    fun ensureUniqueIds(candidates: List<String>): List<String> {
        val seen = HashSet<String>(candidates.size)
        var nextGen = 1
        val out = ArrayList<String>(candidates.size)
        for (raw in candidates) {
            if (raw.isNotEmpty() && seen.add(raw)) {
                out.add(raw)
            } else {
                val base = raw.ifEmpty { "turn" }
                while ("$base#$nextGen" in seen) {
                    nextGen += 1
                }
                val fresh = "$base#$nextGen"
                nextGen += 1
                seen.add(fresh)
                out.add(fresh)
            }
        }
        return out
    }

    fun ensureUniqueTurns(turns: List<OrbTurn>): List<OrbTurn> {
        if (turns.isEmpty()) return turns
        val uniqueIds = ensureUniqueIds(turns.map { it.id })
        var changed = false
        for (i in turns.indices) {
            if (uniqueIds[i] != turns[i].id) {
                changed = true
                break
            }
        }
        if (!changed) return turns
        return turns.mapIndexed { idx, turn ->
            val id = uniqueIds[idx]
            if (id == turn.id) turn
            else when (turn) {
                is OrbTurn.User -> turn.copy(id = id)
                is OrbTurn.Assistant -> turn.copy(id = id)
                is OrbTurn.WorkFold -> turn.copy(id = id)
                is OrbTurn.Wake -> turn.copy(id = id)
            }
        }
    }

    fun latexSpanAdmitted(
        len: Int,
        prevBlocked: Boolean,
        nextDigit: Boolean,
        leadSpace: Boolean,
        trailSpace: Boolean,
        hasNewline: Boolean,
        firstDigit: Boolean,
        internalSpace: Boolean,
        hasMathOp: Boolean
    ): Boolean =
        len in 1..MAX_LATEX_SPAN_CHARS &&
            !prevBlocked &&
            !nextDigit &&
            !leadSpace &&
            !trailSpace &&
            !hasNewline &&
            !(firstDigit && internalSpace && !hasMathOp)

    fun visibleTurnCount(
        total: Int,
        baseLimit: Int,
        expandedSteps: Int,
        stepSize: Int
    ): Int {
        val cap = max(0, baseLimit) + max(0, expandedSteps) * max(0, stepSize)
        return min(max(0, total), cap)
    }

    fun hiddenTurnCount(
        total: Int,
        baseLimit: Int,
        expandedSteps: Int,
        stepSize: Int
    ): Int = max(0, total) - visibleTurnCount(total, baseLimit, expandedSteps, stepSize)

    fun admitMount(active: Int, cap: Int): MountDecision {
        val a = max(0, active)
        val c = max(0, cap)
        return if (a < c) MountDecision(true, a + 1) else MountDecision(false, a)
    }
}

/**
 * Verified cross-client reducers and binary patch framing (`lean/OrbClient/{Spec,Reducers}.lean`,
 * checked against `shared/orb-spec/fixtures/client-core.json`).
 */
object OrbClientCore {
    const val PATCH_MAX_PAYLOAD_BYTES = 65_535
    const val PATCH_HEADER_BYTES = 8
    const val TRANSCRIPT_STABLE_MAX_TURNS = 65_536u

    data class SyncCursorState(val epoch: ULong = 0uL, val seq: ULong = 0uL)
    data class SyncCursorStep(val stepped: Boolean, val state: SyncCursorState)
    data class TranscriptProjection(val visibleEntries: UInt, val thinkingActive: Boolean)
    data class PatchFrame(val schema: Int, val payload: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is PatchFrame && schema == other.schema && payload.contentEquals(other.payload)

        override fun hashCode(): Int = 31 * schema + payload.contentHashCode()
    }

    fun verifyClientSyncCursor(
        localEpoch: ULong,
        incomingEpoch: ULong,
        localSeq: ULong,
        incomingSeq: ULong,
        frameValid: Boolean,
        authOk: Boolean
    ): Boolean =
        frameValid &&
            authOk &&
            incomingEpoch > 0uL &&
            (localEpoch < incomingEpoch || (localEpoch == incomingEpoch && localSeq < incomingSeq))

    fun stepSyncCursor(
        cur: SyncCursorState,
        incomingEpoch: ULong,
        incomingSeq: ULong,
        frameValid: Boolean,
        authOk: Boolean
    ): SyncCursorStep =
        if (verifyClientSyncCursor(cur.epoch, incomingEpoch, cur.seq, incomingSeq, frameValid, authOk)) {
            SyncCursorStep(true, SyncCursorState(incomingEpoch, incomingSeq))
        } else {
            SyncCursorStep(false, cur)
        }

    fun validTranscriptProjInput(userTurns: UInt, toolTurns: UInt): Boolean =
        userTurns <= TRANSCRIPT_STABLE_MAX_TURNS && toolTurns <= TRANSCRIPT_STABLE_MAX_TURNS

    fun projectTranscriptCounts(
        userTurns: UInt,
        toolTurns: UInt,
        thinkingOpen: Boolean,
        @Suppress("UNUSED_PARAMETER") isReplayFromLog: Boolean
    ): TranscriptProjection =
        TranscriptProjection(
            visibleEntries = userTurns + toolTurns,
            thinkingActive = thinkingOpen
        )

    fun verifyBundleBudget(
        eagerBytes: ULong,
        budgetBytes: ULong,
        singleAppEntry: Boolean,
        hasEagerHeavyVendor: Boolean
    ): Boolean =
        singleAppEntry && !hasEagerHeavyVendor && budgetBytes > 0uL && eagerBytes <= budgetBytes

    fun encodeOrbClientPatch(schema: Int, payload: ByteArray): ByteArray? {
        if (schema !in 1..255 || payload.isEmpty() || payload.size > PATCH_MAX_PAYLOAD_BYTES) return null
        val len = payload.size
        val out = ByteArray(PATCH_HEADER_BYTES + len)
        out[0] = 0x4F
        out[1] = 0x52
        out[2] = 0x42
        out[3] = 0x50
        out[4] = ((schema ushr 8) and 0xFF).toByte()
        out[5] = (schema and 0xFF).toByte()
        out[6] = ((len ushr 8) and 0xFF).toByte()
        out[7] = (len and 0xFF).toByte()
        payload.copyInto(out, destinationOffset = PATCH_HEADER_BYTES)
        return out
    }

    fun parseOrbClientPatch(raw: ByteArray): PatchFrame? {
        if (raw.size < 9) return null
        if (raw[0] != 0x4F.toByte() || raw[1] != 0x52.toByte() || raw[2] != 0x42.toByte() || raw[3] != 0x50.toByte()) {
            return null
        }
        val schema = ((raw[4].toInt() and 0xFF) shl 8) or (raw[5].toInt() and 0xFF)
        val payLen = ((raw[6].toInt() and 0xFF) shl 8) or (raw[7].toInt() and 0xFF)
        if (schema in 1..255 && payLen in 1..PATCH_MAX_PAYLOAD_BYTES && PATCH_HEADER_BYTES + payLen == raw.size) {
            return PatchFrame(schema, raw.copyOfRange(PATCH_HEADER_BYTES, PATCH_HEADER_BYTES + payLen))
        }
        return null
    }
}
