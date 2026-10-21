import { For, Show, createEffect, createMemo, createSignal, on } from "solid-js";
import "./usage.css";
import { connectionVersion, isConnected } from "./api";
import { ErrorNotice } from "./ErrorNotice";
import { Select } from "./Select";
import {
  USAGE_WINDOWS, chartBuckets, costTitle, formatCost, formatTokens, getUsageSummary, totalTokens,
  type ChartBucket, type UsageFilters, type UsageSummary, type UsageTotals,
} from "./usageApi";
import {
  FLAG_LABEL, RELIABILITY_WINDOWS, errorSummary, formatMs, formatRate, getProxyHealth, isRedFlag,
  type ProxyHealth,
} from "./proxyHealthApi";

type Metric = "tokens" | "cost" | "requests";
type GroupBy = "model" | "provider" | "source" | "mission" | "api_key" | "backend";

const GROUPS: { value: GroupBy; label: string }[] = [
  { value: "model", label: "Model" },
  { value: "provider", label: "Provider" },
  { value: "source", label: "Source" },
  { value: "mission", label: "Mission" },
  { value: "api_key", label: "API key" },
  { value: "backend", label: "Harness" },
];
const SOURCE_LABEL: Record<string, string> = { harness: "Harness", router: "Router" };

interface Row extends UsageTotals { id: string; name: string; detail?: string; filter?: Partial<UsageFilters> }

function rowsFor(s: UsageSummary, by: GroupBy): Row[] {
  if (by === "model") return s.by_model.map(m => ({
    ...m, id: `${m.source}:${m.model}`, name: m.model || "Unrecorded model",
    detail: [SOURCE_LABEL[m.source], m.provider].filter(Boolean).join(" · "),
    filter: m.model ? { model: m.model, source: m.source } : undefined,
  }));
  const groups = { provider: s.by_provider, source: s.by_source, mission: s.by_mission, api_key: s.by_api_key, backend: s.by_backend }[by];
  const empty = { provider: "Unknown provider", source: "", mission: "No mission", api_key: "Internal proxy secret", backend: "No harness" }[by];
  return groups.map(g => ({
    ...g, id: g.key ?? "none",
    name: by === "source" ? SOURCE_LABEL[g.key ?? ""] ?? g.key ?? "" : g.label || g.key || empty,
    detail: g.label && g.key && by !== "source" ? g.key.slice(0, 8) : undefined,
    filter: g.key ? { [by]: g.key } : undefined,
  }));
}

function metricValue(b: ChartBucket, m: Metric) { return m === "tokens" ? b.tokens : m === "cost" ? b.cost_cents : b.requests; }
function metricText(n: number, m: Metric) { return m === "tokens" ? formatTokens(n) : m === "cost" ? `$${(n / 100).toFixed(2)}` : n.toLocaleString(); }

export function UsageChart(p: { summary: UsageSummary; metric: Metric }) {
  const data = createMemo(() => chartBuckets(p.summary));
  const max = createMemo(() => Math.max(1, ...data().buckets.map(b => metricValue(b, p.metric))));
  const width = 600, height = 120;
  const step = () => width / Math.max(1, data().buckets.length);
  const tick = () => Math.max(1, Math.ceil(data().buckets.length / 6));
  return <figure class="usage-chart" aria-label={`${p.metric} per ${data().granularity}`}>
    <svg viewBox={`0 0 ${width} ${height + 16}`} preserveAspectRatio="none" role="img">
      <For each={data().buckets}>{(b, i) => {
        const v = () => metricValue(b, p.metric);
        const h = () => (v() / max()) * height;
        const routerShare = () => b.requests ? b.router_requests / b.requests : 0;
        return <g>
          <title>{`${b.key}: ${metricText(v(), p.metric)} · ${b.requests.toLocaleString()} requests (${b.router_requests.toLocaleString()} router)`}</title>
          <rect class="usage-bar" x={i() * step() + 1} width={Math.max(1, step() - 2)} y={height - h()} height={h()} rx="1.5" />
          <Show when={routerShare() > 0 && h() > 0}>
            <rect class="usage-bar router" x={i() * step() + 1} width={Math.max(1, step() - 2)} y={height - h()} height={h() * routerShare()} rx="1.5" />
          </Show>
          <Show when={i() % tick() === 0}>
            <text class="usage-tick" x={i() * step() + step() / 2} y={height + 12} text-anchor="middle">{b.label}</text>
          </Show>
        </g>;
      }}</For>
    </svg>
    <figcaption class="usage-legend"><span class="usage-swatch" />Harness<span class="usage-swatch router" />Router share of requests<span class="usage-max">Peak {metricText(max(), p.metric)} per {data().granularity}</span></figcaption>
  </figure>;
}

function Tile(p: { label: string; value: string; title?: string }) {
  return <div class="usage-tile" title={p.title}><span>{p.label}</span><strong>{p.value}</strong></div>;
}

/** Router reliability: success rate, time to first token and failures per provider/model/account. */
export function ReliabilitySection() {
  const [window, setWindow] = createSignal("24h");
  const [health, setHealth] = createSignal<ProxyHealth | null>(null);
  const [error, setError] = createSignal("");
  let request = 0;
  async function load() {
    const id = ++request;
    if (!isConnected()) { setHealth(null); return; }
    try {
      const next = await getProxyHealth(window());
      if (id === request) { setHealth(next); setError(""); }
    } catch (e) {
      if (id === request) { setHealth(null); setError(e instanceof Error ? e.message : String(e)); }
    }
  }
  createEffect(on([connectionVersion, window], () => void load()));
  const flagged = createMemo(() => health()?.groups.filter(isRedFlag) ?? []);
  return <section class="s-sec" aria-label="Reliability">
    <div class="routing-heading usage-section-head">
      <h3>Reliability</h3>
      <div class="usage-seg" role="radiogroup" aria-label="Reliability window">
        <For each={RELIABILITY_WINDOWS}>{w =>
          <button role="radio" aria-checked={window() === w.value} class={window() === w.value ? "on" : ""} onClick={() => setWindow(w.value)}>{w.value}</button>
        }</For>
      </div>
    </div>
    <Show when={error()}><p class="routing-muted">Router reliability is unavailable: {error()}</p></Show>
    <Show when={health()}>{h => <>
      <div class="usage-tiles">
        <Tile label="Router success" value={formatRate(h().totals.success_rate)} title={`${h().totals.ok.toLocaleString()} of ${h().totals.requests.toLocaleString()} requests`} />
        <Tile label="First token p50" value={formatMs(h().totals.ttft_p50_ms)} />
        <Tile label="First token p95" value={formatMs(h().totals.ttft_p95_ms)} />
        <Tile label="Retried · fell back" value={`${h().totals.retried.toLocaleString()} · ${h().totals.fell_back.toLocaleString()}`} title="Requests retried on the same entry before the first byte · answered by a later chain entry" />
      </div>
      <Show when={flagged().length}>
        <ul class="usage-flags" aria-label="Reliability problems">
          <For each={flagged()}>{g => <li class="usage-flag">
            <strong>{g.provider ?? "Unknown provider"}{g.model ? ` · ${g.model}` : ""}</strong>
            <span>{g.flags.length ? g.flags.map(f => FLAG_LABEL[f]).join(", ") : FLAG_LABEL.low_success_rate} — {formatRate(g.success_rate)} of {g.requests.toLocaleString()} attempts{Object.keys(g.errors).length ? ` (${errorSummary(g.errors)})` : ""}</span>
          </li>}</For>
        </ul>
      </Show>
      <Show when={h().groups.length} fallback={<p class="routing-muted">No router traffic in this window.</p>}>
        <div class="s-card usage-table" role="table" aria-label="Reliability by provider">
          <div class="usage-tr usage-rel-tr usage-th" role="row">
            <span role="columnheader">Provider · model</span><span role="columnheader">Attempts</span><span role="columnheader">Success</span><span role="columnheader">TTFT p50 / p95</span>
          </div>
          <For each={h().groups}>{g => <div class="usage-tr usage-rel-tr" role="row" classList={{ "usage-red": isRedFlag(g) }}>
            <span role="cell" class="usage-name">
              <strong>{g.provider ?? "Unknown provider"}{g.model ? ` · ${g.model}` : ""}</strong>
              <Show when={g.account_id}><span>{g.account_id!.slice(0, 8)}</span></Show>
              <Show when={Object.keys(g.errors).length}><span class="usage-errors">{errorSummary(g.errors)}</span></Show>
            </span>
            <span role="cell">{g.requests.toLocaleString()}</span>
            <span role="cell" class="usage-rate">{formatRate(g.success_rate)}</span>
            <span role="cell">{formatMs(g.ttft_p50_ms)} / {formatMs(g.ttft_p95_ms)}</span>
          </div>}</For>
        </div>
      </Show>
    </>}</Show>
  </section>;
}

export function UsageSettings() {
  const [window, setWindow] = createSignal("24h");
  const [filters, setFilters] = createSignal<UsageFilters>({});
  const [groupBy, setGroupBy] = createSignal<GroupBy>("model");
  const [metric, setMetric] = createSignal<Metric>("tokens");
  const [summary, setSummary] = createSignal<UsageSummary | null>(null);
  const [options, setOptions] = createSignal<UsageSummary | null>(null);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal("");
  let request = 0;

  async function load() {
    const id = ++request;
    if (!isConnected()) { setSummary(null); return; }
    setLoading(true); setError("");
    try {
      const f = filters();
      const [next, unfiltered] = await Promise.all([
        getUsageSummary(window(), f),
        // Filter choices come from the whole window so a filter never hides its own alternatives.
        Object.values(f).some(Boolean) ? getUsageSummary(window()) : Promise.resolve(null),
      ]);
      if (id !== request) return;
      setSummary(next); setOptions(unfiltered ?? next);
    } catch (e) {
      if (id === request) setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (id === request) setLoading(false);
    }
  }
  createEffect(on([connectionVersion, window, filters], () => void load()));

  const setFilter = (key: keyof UsageFilters, value: string) => setFilters(f => ({ ...f, [key]: value || undefined }));
  const rows = createMemo(() => summary() ? rowsFor(summary()!, groupBy()) : []);
  const maxRow = createMemo(() => Math.max(1, ...rows().map(r => totalTokens(r))));
  const routerShare = () => {
    const s = summary(); if (!s?.totals.requests) return "—";
    const router = s.by_source.find(g => g.key === "router")?.requests ?? 0;
    return `${Math.round((router / s.totals.requests) * 100)}%`;
  };
  const activeFilters = () => Object.entries(filters()).filter(([, v]) => v) as [keyof UsageFilters, string][];
  const filterLabel = (key: keyof UsageFilters, value: string) => {
    const o = options();
    const group = key === "mission" ? o?.by_mission : key === "api_key" ? o?.by_api_key : undefined;
    return `${key === "api_key" ? "key" : key}: ${group?.find(g => g.key === value)?.label ?? SOURCE_LABEL[value] ?? value}`;
  };

  return <div class="s-body settings-body" aria-label="Usage">
    <div class="s-inner usage-page">
      <div class="routing-heading">
        <h2>Usage</h2>
        <div class="routing-actions">
          <Select aria-label="Time window" value={window()} onChange={e => setWindow(e.currentTarget.value)}>
            <For each={USAGE_WINDOWS}>{w => <option value={w.value}>{w.label}</option>}</For>
          </Select>
          <button class="s-btn" disabled={loading()} onClick={() => void load()}>{loading() ? "Refreshing…" : "Refresh"}</button>
        </div>
      </div>
      <p class="routing-muted usage-intro">Tokens and estimated list-price cost from mission harnesses and the /v1 router. Costs marked + or Unknown include models without a published price.</p>
      <Show when={!isConnected()}><p class="routing-muted">Connect to Core in General settings to see usage.</p></Show>
      <Show when={error()}><ErrorNotice error={`Could not load usage: ${error()}`} /></Show>

      <div class="usage-filters">
        <Select aria-label="Source" value={filters().source ?? ""} onChange={e => setFilter("source", e.currentTarget.value)}>
          <option value="">All sources</option><option value="harness">Harness</option><option value="router">Router</option>
        </Select>
        <Select aria-label="Provider" value={filters().provider ?? ""} onChange={e => setFilter("provider", e.currentTarget.value)}>
          <option value="">All providers</option>
          <For each={(options()?.by_provider ?? []).filter(g => g.key)}>{g => <option value={g.key!}>{g.key}</option>}</For>
        </Select>
        <Select aria-label="Harness" value={filters().backend ?? ""} onChange={e => setFilter("backend", e.currentTarget.value)}>
          <option value="">All harnesses</option>
          <For each={(options()?.by_backend ?? []).filter(g => g.key)}>{g => <option value={g.key!}>{g.key}</option>}</For>
        </Select>
        <For each={activeFilters().filter(([k]) => k === "mission" || k === "api_key" || k === "model")}>{([key, value]) =>
          <button class="usage-chip" aria-label={`Clear ${key} filter`} onClick={() => setFilter(key, "")}>{filterLabel(key, value)} ×</button>
        }</For>
      </div>

      <Show when={summary()}>{s => <>
        <div class="usage-tiles">
          <Tile label="Requests" value={s().totals.requests.toLocaleString()} />
          <Tile label="Tokens" value={formatTokens(totalTokens(s().totals))} title={`${s().totals.input_tokens.toLocaleString()} input · ${s().totals.output_tokens.toLocaleString()} output · ${s().totals.cache_read_tokens.toLocaleString()} cache read · ${s().totals.cache_creation_tokens.toLocaleString()} cache write`} />
          <Tile label="Cost" value={formatCost(s().totals)} title={costTitle(s().totals)} />
          <Tile label="Via router" value={routerShare()} />
        </div>

        <section class="s-sec">
          <div class="routing-heading usage-section-head">
            <h3>Over time</h3>
            <div class="usage-seg" role="radiogroup" aria-label="Chart metric">
              <For each={["tokens", "cost", "requests"] as Metric[]}>{m =>
                <button role="radio" aria-checked={metric() === m} class={metric() === m ? "on" : ""} onClick={() => setMetric(m)}>{m[0].toUpperCase() + m.slice(1)}</button>
              }</For>
            </div>
          </div>
          <div class="s-card usage-chart-card"><UsageChart summary={s()} metric={metric()} /></div>
        </section>

        <section class="s-sec">
          <div class="routing-heading usage-section-head">
            <h3>Breakdown</h3>
            <Select aria-label="Group by" value={groupBy()} onChange={e => setGroupBy(e.currentTarget.value as GroupBy)}>
              <For each={GROUPS}>{g => <option value={g.value}>{g.label}</option>}</For>
            </Select>
          </div>
          <Show when={rows().length} fallback={<p class="routing-muted">No usage in this window.</p>}>
            <div class="s-card usage-table" role="table" aria-label={`Usage by ${groupBy()}`}>
              <div class="usage-tr usage-th" role="row">
                <span role="columnheader">{GROUPS.find(g => g.value === groupBy())?.label}</span>
                <span role="columnheader">Requests</span><span role="columnheader">Tokens</span><span role="columnheader">Cost</span>
              </div>
              <For each={rows()}>{r => <div class="usage-tr" role="row">
                <span role="cell" class="usage-name">
                  <Show when={r.filter} fallback={<strong>{r.name}</strong>}>
                    <button class="usage-link" title="Filter to this" onClick={() => setFilters(f => ({ ...f, ...r.filter }))}>{r.name}</button>
                  </Show>
                  <Show when={r.detail}><span>{r.detail}</span></Show>
                  <i class="usage-meter" style={{ width: `${(totalTokens(r) / maxRow()) * 100}%` }} />
                </span>
                <span role="cell">{r.requests.toLocaleString()}</span>
                <span role="cell" title={`${r.input_tokens.toLocaleString()} in · ${r.output_tokens.toLocaleString()} out · ${r.cache_read_tokens.toLocaleString()} cached`}>{formatTokens(totalTokens(r))}</span>
                <span role="cell" title={costTitle(r)} classList={{ "usage-unknown": r.unknown_cost_requests > 0 }}>{formatCost(r)}</span>
              </div>}</For>
            </div>
          </Show>
        </section>
      </>}</Show>
      <ReliabilitySection />
    </div>
  </div>;
}
