import type { Tone } from "./StatTile";

/**
 * State label with a dot: neutral (healthy), warning (expected waiting such
 * as a quota cooldown, 80-99% used), danger (down, exhausted, failing).
 * Always carries text, never color alone. `short` replaces `label` below 560px.
 */
export function StatusPill(p: { tone: Tone; label: string; short?: string; title?: string }) {
  return <span class="st-pill" data-tone={p.tone} data-short={p.short ? "" : undefined} title={p.title ?? p.label}>
    <span class="st-pill-long">{p.label}</span>
    {p.short && <span class="st-pill-short">{p.short}</span>}
  </span>;
}
