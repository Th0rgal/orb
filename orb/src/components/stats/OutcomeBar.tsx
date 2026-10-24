import { For, Show } from "solid-js";

export interface Segment { key: string; label: string; value: number }

/**
 * Horizontal stacked bar of a total split into categories (outcome mix,
 * spend by model). Segment color comes from `data-k` (stats.css palette, in
 * fixed order); identity is never color alone: each segment has a tooltip and
 * the bar has an aria-label, and pages show a `Legend` once.
 */
export function OutcomeBar(p: { segments: Segment[]; label?: string; format?: (n: number) => string }) {
  const total = () => p.segments.reduce((s, x) => s + x.value, 0);
  const fmt = (n: number) => p.format?.(n) ?? n.toLocaleString();
  const pct = (n: number) => `${Math.round((n / (total() || 1)) * 100)}%`;
  const text = () => p.segments.filter(s => s.value > 0).map(s => `${s.label} ${fmt(s.value)} (${pct(s.value)})`).join(", ");
  return <div class="st-outcome" role="img" aria-label={`${p.label ? `${p.label}: ` : ""}${text() || "no data"}`}>
    <Show when={total() > 0}>
      <For each={p.segments.filter(s => s.value > 0)}>{s =>
        <i data-k={s.key} style={{ flex: `${s.value} 1 0` }} title={`${s.label}: ${fmt(s.value)} (${pct(s.value)})`} />
      }</For>
    </Show>
  </div>;
}

/** One-line legend for `OutcomeBar` keys. */
export function Legend(p: { items: { key: string; label: string }[] }) {
  return <div class="st-legend"><For each={p.items}>{i => <span><i data-k={i.key} />{i.label}</span>}</For></div>;
}
