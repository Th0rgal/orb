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
