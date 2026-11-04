/**
 * Verified cross-client transcript safety gates (`lean/Orb/Transcript.lean`,
 * checked against `shared/orb-spec/fixtures/transcript-gates.json`).
 *
 * Mirrored on iOS (`OrbTranscriptGates` in `OrbPipeTables.swift`) and Android
 * (`OrbTranscriptGates.kt`).
 */

export const MAX_LATEX_SPAN_CHARS = 8192;

export type CandidateKey = { tag: number; item: number };
export type TurnKey = { tag: number; item: number; gen: number };
export type LatexSpanInput = {
  len: number;
  prevBlocked: boolean;
  nextDigit: boolean;
  leadSpace: boolean;
  trailSpace: boolean;
  hasNewline: boolean;
  firstDigit: boolean;
  internalSpace: boolean;
  hasMathOp: boolean;
};

export function allocTurnKeys(candidates: readonly CandidateKey[]): TurnKey[] {
  const seen = new Set<string>();
  let nextGen = 1;
  const out: TurnKey[] = [];
  for (const c of candidates) {
    const k = `${c.tag}:${c.item}`;
    if (seen.has(k)) {
      out.push({ tag: c.tag, item: c.item, gen: nextGen });
      nextGen += 1;
    } else {
      seen.add(k);
      out.push({ tag: c.tag, item: c.item, gen: 0 });
    }
  }
  return out;
}

export function ensureUniqueIds(candidates: readonly string[]): string[] {
  const seen = new Set<string>();
  let nextGen = 1;
  const out: string[] = [];
  for (const raw of candidates) {
    if (raw.length > 0 && !seen.has(raw)) {
      seen.add(raw);
      out.push(raw);
    } else {
      const base = raw.length > 0 ? raw : "turn";
      while (seen.has(`${base}#${nextGen}`)) {
        nextGen += 1;
      }
      const fresh = `${base}#${nextGen}`;
      nextGen += 1;
      seen.add(fresh);
      out.push(fresh);
    }
  }
  return out;
}

export function latexSpanAdmitted(x: LatexSpanInput): boolean {
  return (
    x.len > 0 &&
    x.len <= MAX_LATEX_SPAN_CHARS &&
    !x.prevBlocked &&
    !x.nextDigit &&
    !x.leadSpace &&
    !x.trailSpace &&
    !x.hasNewline &&
    !(x.firstDigit && x.internalSpace && !x.hasMathOp)
  );
}

export function visibleTurnCount(
  total: number,
  baseLimit: number,
  expandedSteps: number,
  stepSize: number,
): number {
  const cap = Math.max(0, baseLimit) + Math.max(0, expandedSteps) * Math.max(0, stepSize);
  return Math.min(Math.max(0, total), cap);
}

export function hiddenTurnCount(
  total: number,
  baseLimit: number,
  expandedSteps: number,
  stepSize: number,
): number {
  return Math.max(0, total) - visibleTurnCount(total, baseLimit, expandedSteps, stepSize);
}

export function admitMount(
  active: number,
  cap: number,
): { admitted: boolean; nextActive: number } {
  const a = Math.max(0, active);
  const c = Math.max(0, cap);
  return a < c ? { admitted: true, nextActive: a + 1 } : { admitted: false, nextActive: a };
}
