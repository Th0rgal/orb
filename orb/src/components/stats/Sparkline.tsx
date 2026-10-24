import { Show } from "solid-js";

/**
 * Tiny trend line for a stat tile: one series, no axes, nulls are gaps.
 * Decorative next to its number (aria-hidden); `title` carries the range.
 */
export function Sparkline(p: { values: (number | null)[]; title?: string; min?: number }) {
  const w = 64, h = 20;
  const points = () => {
    const vals = p.values;
    const present = vals.filter((v): v is number => v != null);
    if (present.length < 2) return [];
    const lo = p.min ?? Math.min(...present), hi = Math.max(...present);
    const span = hi - lo || 1;
    const step = w / Math.max(1, vals.length - 1);
    const segs: string[][] = [[]];
    vals.forEach((v, i) => {
      if (v == null) { if (segs[segs.length - 1].length) segs.push([]); return; }
      segs[segs.length - 1].push(`${(i * step).toFixed(1)},${(h - 1 - ((v - lo) / span) * (h - 2)).toFixed(1)}`);
    });
    return segs.filter(s => s.length);
  };
  return <Show when={points().length} fallback={<span class="st-spark-empty" aria-hidden="true" />}>
    <svg class="st-spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <Show when={p.title}><title>{p.title}</title></Show>
      {points().map(s => <polyline points={s.join(" ")} />)}
    </svg>
  </Show>;
}
