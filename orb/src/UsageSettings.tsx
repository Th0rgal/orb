import { For, Show, createEffect, createMemo, createSignal, on } from "solid-js";
import "./usage.css";
import { connectionVersion, isConnected } from "./api";
import { ErrorNotice } from "./ErrorNotice";
import { Select } from "./Select";
import {
  CALLER_KINDS, CALLER_KIND_LABEL, USAGE_WINDOWS, chartBuckets, costTitle, formatCost, formatTokens,
  getUsageSummary, hourlyAvailable, totalTokens,
  type UsageFilters, type UsageSummary, type UsageTotals,
} from "./usageApi";
import { RELIABILITY_WINDOWS, getProxyHealth, type ProxyHealth } from "./proxyHealthApi";
import { ReliabilityView } from "./ReliabilityView";
import { FallbackActivity, ProviderStackedChart, type Granularity, type Metric } from "./UsageCharts";

type GroupBy = "caller_kind" | "model" | "provider" | "source" | "mission" | "root_mission" | "api_key" | "backend" | "purpose";

const GROUPS: { value: GroupBy; label: string }[] = [
  { value: "caller_kind", label: "Caller" },
  { value: "model", label: "Model" },
  { value: "provider", label: "Provider" },
  { value: "source", label: "Source" },
  { value: "mission", label: "Mission" },
  { value: "root_mission", label: "Root mission" },
  { value: "api_key", label: "API key" },
  { value: "backend", label: "Harness" },
  { value: "purpose", label: "Core purpose" },
];
const SOURCE_LABEL: Record<string, string> = { harness: "Harness", router: "Router" };

interface Row extends UsageTotals { id: string; name: string; detail?: string; filter?: Partial<UsageFilters> }

function rowsFor(s: UsageSummary, by: GroupBy): Row[] {
  if (by === "model") return s.by_model.map(m => ({
    ...m, id: `${m.source}:${m.model}`, name: m.model || "Unrecorded model",
    detail: [SOURCE_LABEL[m.source], m.provider].filter(Boolean).join(" · "),
    filter: m.model ? { model: m.model, source: m.source } : undefined,
  }));
  const groups = {
    caller_kind: s.by_caller_kind, provider: s.by_provider, source: s.by_source, mission: s.by_mission,
    root_mission: s.by_root_mission, api_key: s.by_api_key, backend: s.by_backend, purpose: s.by_purpose,
  }[by] ?? [];
  const empty = {
    caller_kind: "Unknown", provider: "Unknown provider", source: "", mission: "No mission", root_mission: "No mission",
    api_key: "Internal proxy secret", backend: "No harness", purpose: "Unspecified",
  }[by];
  // Root missions and purposes have no matching server filter.
  const filterKey = by === "root_mission" || by === "purpose" ? undefined : by;
  return groups.map(g => ({
    ...g, id: g.key ?? "none",
    name: by === "source" ? SOURCE_LABEL[g.key ?? ""] ?? g.key ?? ""
      : by === "caller_kind" ? CALLER_KIND_LABEL[g.key ?? "unknown"] ?? g.key ?? empty
      : by === "purpose" ? `core:${g.key ?? "unspecified"}`
      : g.label || g.key || empty,
    detail: g.label && g.key && by !== "source" ? g.key.slice(0, 8) : undefined,
    filter: g.key && filterKey ? { [filterKey]: g.key } : undefined,
  }));
}

function Tile(p: { label: string; value: string; title?: string }) {
  return <div class="usage-tile" title={p.title}><span>{p.label}</span><strong>{p.value}</strong></div>;
}

/** Router reliability: success, first token and failures per provider·model·account, ranked by impact. */
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
  return <section class="s-sec" aria-label="Reliability">
    <div class="routing-heading usage-section-head">
      <h3>Reliability</h3>
      <div class="usage-seg" role="radiogroup" aria-label="Reliability window">
        <For each={RELIABILITY_WINDOWS}>{w =>
          <button role="radio" aria-checked={window() === w.value} class={window() === w.value ? "on" : ""} onClick={() => setWindow(w.value)}>{w.value}</button>
        }</For>
      </div>
    </div>
    <Show when={error()} fallback={<ReliabilityView health={isConnected() ? health() : null} />}>
      <p class="routing-muted">Router reliability is unavailable: {error()}</p>
    </Show>
  </section>;
}

export function UsageSettings() {
  const [window, setWindow] = createSignal("24h");
  const [filters, setFilters] = createSignal<UsageFilters>({});
  const [groupBy, setGroupBy] = createSignal<GroupBy>("mission");
  const [metric, setMetric] = createSignal<Metric>("cost");
  const [granularity, setGranularity] = createSignal<Granularity>("hour");
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
  // Top missions and callers by cost first.
  const rows = createMemo(() => summary() ? rowsFor(summary()!, groupBy()).sort((a, b) => b.cost_cents - a.cost_cents) : []);
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
    const name = key === "api_key" ? "key" : key === "caller_kind" ? "caller" : key;
    return `${name}: ${group?.find(g => g.key === value)?.label ?? SOURCE_LABEL[value] ?? CALLER_KIND_LABEL[value] ?? value}`;
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
      <Show when={!isConnected()}><p class="routing-muted">Connect to Core in General settings to see usage.</p></Show>
      <Show when={error()}><ErrorNotice error={`Could not load usage: ${error()}`} /></Show>

      <div class="usage-filters">
        <Select aria-label="Source" value={filters().source ?? ""} onChange={e => setFilter("source", e.currentTarget.value)}>
          <option value="">All sources</option><option value="harness">Harness</option><option value="router">Router</option>
        </Select>
        <Select aria-label="Caller" value={filters().caller_kind ?? ""} onChange={e => setFilter("caller_kind", e.currentTarget.value)}>
          <option value="">All callers</option>
          <For each={CALLER_KINDS}>{k => <option value={k}>{CALLER_KIND_LABEL[k]}</option>}</For>
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
          <Tile label="Cost" value={formatCost(s().totals)} title={`${costTitle(s().totals)}\nEstimated list price from mission harnesses and the /v1 router. + or Unknown: models without a published price.`} />
          <Tile label="Via router" value={routerShare()} />
        </div>

        <section class="s-sec">
          <div class="routing-heading usage-section-head">
            <h3>Over time by provider</h3>
            <div class="usage-seg" role="radiogroup" aria-label="Chart granularity">
              <For each={["hour", "day"] as Granularity[]}>{g =>
                <button role="radio" aria-checked={(hourlyAvailable(window()) ? granularity() : "day") === g}
                  class={(hourlyAvailable(window()) ? granularity() : "day") === g ? "on" : ""}
                  disabled={g === "hour" && !hourlyAvailable(window())}
                  title={g === "hour" && !hourlyAvailable(window()) ? "Hourly data covers windows up to 7 days" : undefined}
                  onClick={() => setGranularity(g)}>{g === "hour" ? "Hour" : "Day"}</button>
              }</For>
            </div>
            <div class="usage-seg" role="radiogroup" aria-label="Chart metric">
              <For each={["tokens", "cost", "requests"] as Metric[]}>{m =>
                <button role="radio" aria-checked={metric() === m} class={metric() === m ? "on" : ""} onClick={() => setMetric(m)}>{m[0].toUpperCase() + m.slice(1)}</button>
              }</For>
            </div>
          </div>
          <div class="s-card usage-chart-card"><ProviderStackedChart summary={s()} filters={filters()} metric={metric()} granularity={hourlyAvailable(window()) ? granularity() : "day"} /></div>
        </section>

        <section class="s-sec">
          <div class="routing-heading usage-section-head"><h3>Fallbacks</h3></div>
          <div class="s-card usage-chart-card"><FallbackActivity summary={s()} granularity={hourlyAvailable(window()) ? granularity() : "day"} /></div>
        </section>

        <section class="s-sec">
          <div class="routing-heading usage-section-head">
            <h3>Top spenders</h3>
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
