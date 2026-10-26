import { For, Show, createMemo, createResource } from "solid-js";
import { chartBuckets, formatTokens, getUsageSummary, type ChartBucket, type UsageFilters, type UsageSummary } from "./usageApi";
import * as R from "./routingApi";

export type Metric = "tokens" | "cost" | "requests";
export type Granularity = "hour" | "day";

/** Color follows the provider, never its rank (dataviz: fixed categorical slots). */
const PROVIDER_SLOT: Record<string, number> = { anthropic: 1, openai: 2, google: 3, antigravity: 3, xai: 4, moonshot: 5, kimi: 5 };
const MAX_SERIES = 5;
export const providerSlot = (key: string) => PROVIDER_SLOT[key.toLowerCase()] ?? 0;

export function metricValue(b: Pick<ChartBucket, "tokens" | "cost_cents" | "requests">, m: Metric) { return m === "tokens" ? b.tokens : m === "cost" ? b.cost_cents : b.requests; }
export function metricText(n: number, m: Metric) { return m === "tokens" ? formatTokens(n) : m === "cost" ? `$${(n / 100).toFixed(2)}` : n.toLocaleString(); }

type Series = { key: string; slot: number; buckets: ChartBucket[] };

/** The summary endpoint has no per-provider time series, so each top provider
 * is one filtered request (in parallel); the rest is "Other". */
async function providerSeries(summary: UsageSummary, filters: UsageFilters, granularity: Granularity, metric: Metric): Promise<Series[]> {
  const total = chartBuckets(summary, new Date(), granularity).buckets;
  if (filters.provider) return [{ key: filters.provider, slot: providerSlot(filters.provider), buckets: total }];
  const top = summary.by_provider.filter(g => g.key).sort((a, b) => metricValue({ tokens: a.input_tokens + a.output_tokens, cost_cents: a.cost_cents ?? 0, requests: a.requests }, metric) < metricValue({ tokens: b.input_tokens + b.output_tokens, cost_cents: b.cost_cents ?? 0, requests: b.requests }, metric) ? 1 : -1).slice(0, MAX_SERIES);
  const series = await Promise.all(top.map(async g => ({
    key: g.key!, slot: providerSlot(g.key!),
    buckets: chartBuckets(await getUsageSummary(summary.window, { ...filters, provider: g.key! }), new Date(), granularity).buckets,
  })));
  const other = total.map((b, i) => {
    const rest = (f: (x: ChartBucket) => number) => Math.max(0, f(b) - series.reduce((n, s) => n + f(s.buckets[i] ?? b), 0));
    return { ...b, tokens: rest(x => x.tokens), cost_cents: rest(x => x.cost_cents), requests: rest(x => x.requests), router_requests: 0 };
  });
  return other.some(b => metricValue(b, metric) > 0) ? [...series, { key: "Other", slot: 0, buckets: other }] : series;
}

/** Spend, tokens or requests over time, stacked by provider. */
export function ProviderStackedChart(p: { summary: UsageSummary; filters: UsageFilters; metric: Metric; granularity: Granularity }) {
  const [series] = createResource(() => ({ s: p.summary, f: p.filters, g: p.granularity, m: p.metric }), ({ s, f, g, m }) => providerSeries(s, f, g, m));
  const buckets = createMemo(() => chartBuckets(p.summary, new Date(), p.granularity).buckets);
  const max = createMemo(() => Math.max(1, ...buckets().map(b => metricValue(b, p.metric))));
  const width = 600, height = 120;
  const step = () => width / Math.max(1, buckets().length);
  const tick = () => Math.max(1, Math.ceil(buckets().length / 6));
  return <figure class="usage-chart" aria-label={`${p.metric} per ${p.granularity} by provider`}>
    <Show when={!series.loading && series()} fallback={<div class="usage-chart-skel spend-skel" aria-busy="true" />}>{list =>
      <>
        <svg viewBox={`0 0 ${width} ${height + 16}`} preserveAspectRatio="none" role="img">
          <For each={buckets()}>{(b, i) => {
            const stack = () => { let y = height; return list().map(s => { const v = metricValue(s.buckets[i()] ?? b, p.metric); const h = (v / max()) * height; y -= h; return { s, v, h, y }; }).filter(x => x.h > 0); };
            return <g>
              <For each={stack()}>{seg =>
                <rect class={`usage-seg-fill series-${seg.s.slot}`} x={i() * step() + 1} width={Math.max(1, step() - 2)} y={seg.y} height={Math.max(0, seg.h - (seg.h > 3 ? 1 : 0))} rx="1">
                  <title>{`${b.label} · ${seg.s.key}: ${metricText(seg.v, p.metric)}`}</title>
                </rect>
              }</For>
              <Show when={i() % tick() === 0}><text class="usage-tick" x={i() * step() + step() / 2} y={height + 12} text-anchor="middle">{b.label}</text></Show>
            </g>;
          }}</For>
        </svg>
        <figcaption class="usage-legend">
          <For each={list()}>{s => <><span class={`usage-swatch series-${s.slot}`} />{s.key}</>}</For>
          <span class="usage-max">Peak {metricText(max(), p.metric)} per {p.granularity}</span>
        </figcaption>
      </>
    }</Show>
  </figure>;
}

/** Requests and fallbacks over time (two charts, one axis each), then the latest events. */
export function FallbackActivity(p: { summary: UsageSummary; granularity: Granularity }) {
  const [events] = createResource(() => p.summary, () => R.listEvents().catch(() => [] as R.FallbackEvent[]));
  const buckets = createMemo(() => chartBuckets(p.summary, new Date(), p.granularity).buckets);
  const counts = createMemo(() => {
    const keyOf = (t: string) => p.granularity === "hour" ? `${t.slice(0, 13)}` : t.slice(0, 10);
    const by = new Map<string, number>();
    for (const e of events() ?? []) by.set(keyOf(e.timestamp), (by.get(keyOf(e.timestamp)) ?? 0) + 1);
    return buckets().map(b => by.get(p.granularity === "hour" ? b.key.slice(0, 13) : b.key.slice(0, 10)) ?? 0);
  });
  const max = createMemo(() => Math.max(1, ...counts()));
  const width = 600, height = 40;
  const step = () => width / Math.max(1, buckets().length);
  const recent = createMemo(() => [...(events() ?? [])].sort((a, b) => b.timestamp.localeCompare(a.timestamp)).slice(0, 8));
  return <>
    <figure class="usage-chart usage-chart-small" aria-label={`Fallbacks per ${p.granularity}`}>
      <Show when={!events.loading} fallback={<div class="usage-chart-skel small spend-skel" aria-busy="true" />}>
        <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img">
          <For each={buckets()}>{(b, i) => {
            const h = () => (counts()[i()] / max()) * height;
            return <rect class="usage-seg-fill fallback" x={i() * step() + 1} width={Math.max(1, step() - 2)} y={height - h()} height={h()} rx="1"><title>{`${b.label}: ${counts()[i()]} fallbacks`}</title></rect>;
          }}</For>
        </svg>
        <figcaption class="usage-legend">Fallbacks (last {(events() ?? []).length} retained by the backend)<span class="usage-max">Peak {max()} per {p.granularity}</span></figcaption>
      </Show>
    </figure>
    <Show when={recent().length} fallback={<Show when={!events.loading}><p class="routing-muted">No fallback events recorded.</p></Show>}>
      <ul class="usage-events" aria-label="Recent fallback events">
        <For each={recent()}>{e => <li>
          <time>{new Date(e.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
          <span class="usage-events-path">{e.from_provider}/{e.from_model} → {e.to_provider || "chain exhausted"}</span>
          <span class="usage-events-reason">{e.reason.replaceAll("_", " ")} · {e.chain_id}</span>
        </li>}</For>
      </ul>
    </Show>
  </>;
}
