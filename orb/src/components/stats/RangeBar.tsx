import type { Tone } from "./StatTile";

/**
 * Mini range bar: a band from `low` to `high` (e.g. p50..p95) with a tick at
 * `mark` (default `low`), on a shared 0..`max` scale so rows compare. Pair
 * with the numbers in text; the bar is a visual aid (title has the values).
 */
export function RangeBar(p: { low: number | null; high: number | null; max: number; mark?: number | null; title?: string; tone?: Tone }) {
  const at = (v: number) => `${Math.min(100, Math.max(0, (v / (p.max || 1)) * 100))}%`;
  return <div class="st-range" data-tone={p.tone ?? "neutral"} title={p.title} aria-hidden="true">
    {p.low != null && p.high != null && <i style={{ left: at(p.low), width: `calc(${at(p.high)} - ${at(p.low)})` }} />}
    {(p.mark ?? p.low) != null && <b style={{ left: `calc(${at((p.mark ?? p.low)!)} - 1px)` }} />}
  </div>;
}
