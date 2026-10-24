import { Show } from "solid-js";
import { Sparkline } from "./Sparkline";

export type Tone = "neutral" | "warning" | "danger";

/**
 * Compact KPI tile: label, value, optional sparkline over the window.
 * `value` undefined renders a same-size skeleton (no layout jump on load).
 * Tone follows the quota language: neutral, warning (80-99% / expected
 * waiting), danger (exhausted / failing). Wrap tiles in `.st-tiles`.
 */
export function StatTile(p: { label: string; value?: string; title?: string; series?: (number | null)[]; seriesMin?: number; tone?: Tone }) {
  return <div class="st-tile" title={p.title}>
    <span class="st-tile-label">{p.label}</span>
    <Show when={p.value !== undefined} fallback={<span class="st-sk" aria-label="Loading" />}>
      <strong class="st-tile-value" data-tone={p.tone ?? "neutral"}>{p.value}</strong>
    </Show>
    <Show when={p.series} fallback={<span class="st-spark-empty" aria-hidden="true" />}>
      <Sparkline values={p.series!} min={p.seriesMin} />
    </Show>
  </div>;
}
