import { For, Show, createMemo } from "solid-js";
import { BreakdownTable, Legend, OutcomeBar, RangeBar, StatTile, StatusPill, type Column } from "./components/stats";
import { ProviderLogo } from "./ProviderLogo";
import { formatMs, formatRate, type ProxyHealth } from "./proxyHealthApi";
import { OUTCOMES, OUTCOME_LABEL, errorLabel, isProblem, outcomeMix, reliabilityRows, type Row } from "./reliability";

const rate = (ok: number, n: number) => (n ? ok / n : null);
const time = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });

/**
 * Router health: compact tiles with sparklines, then one table ranked by
 * impact. Healthy rows fold behind "N healthy · show"; a row opens its error
 * breakdown and recent errors. `health` null renders skeletons.
 */
export function ReliabilityView(p: { health: ProxyHealth | null }) {
  const h = () => p.health;
  const rows = createMemo(() => (h() ? reliabilityRows(h()!.groups) : undefined));
  const series = () => h()?.series ?? [];
  const maxTtft = createMemo(() => Math.max(1000, ...(h()?.groups ?? []).map(g => g.ttft_p95_ms ?? 0)));
  const totalRate = () => h()?.totals.success_rate ?? null;
  const columns: Column<Row>[] = [
    { header: "Provider · model", width: "minmax(180px, 1fr)", narrowWidth: "minmax(0, 1fr)", cell: r => <span class="st-cell-provider">
      <ProviderLogo type={r.group.provider ?? ""} />
      <span class="st-cell-name">
        <strong title={r.name}>{r.group.model ?? r.name}</strong>
        <span title={r.name}>{[r.group.provider, r.account].filter(Boolean).join(" · ")}</span>
      </span>
    </span> },
    { header: "Outcomes", width: "96px", narrowWidth: "48px", cell: r => {
      const mix = outcomeMix(r.group);
      return <OutcomeBar label={r.name} segments={OUTCOMES.map(k => ({ key: k, label: OUTCOME_LABEL[k], value: mix[k] }))} />;
    } },
    { header: "Success", width: "48px", align: "end", cell: r => formatRate(r.group.success_rate) },
    { header: "Attempts", width: "60px", align: "end", hideNarrow: true, cell: r => r.group.requests.toLocaleString() },
    { header: "First token", width: "88px", hideNarrow: true, cell: r =>
      <RangeBar low={r.group.ttft_p50_ms} high={r.group.ttft_p95_ms} max={maxTtft()}
        tone={r.group.flags.includes("slow_first_token") ? "warning" : "neutral"}
        title={`p50 ${formatMs(r.group.ttft_p50_ms)} · p95 ${formatMs(r.group.ttft_p95_ms)}`} /> },
    { header: "Status", width: "140px", narrowWidth: "96px", align: "end", cell: r => <StatusPill tone={r.status.tone} label={r.status.label} short={r.status.short} /> },
  ];
  return <>
    <div class="st-tiles">
      <StatTile label="Router success" value={h() ? formatRate(totalRate()) : undefined}
        tone={totalRate() != null && totalRate()! < 0.9 ? "danger" : totalRate() != null && totalRate()! < 0.99 ? "warning" : "neutral"}
        title={h() ? `${h()!.totals.ok.toLocaleString()} of ${h()!.totals.requests.toLocaleString()} requests` : undefined}
        series={series().map(b => rate(b.ok, b.requests))} />
      <StatTile label="First token p50" value={h() ? formatMs(h()!.totals.ttft_p50_ms) : undefined} series={series().map(b => b.ttft_p50_ms)} seriesMin={0} />
      <StatTile label="First token p95" value={h() ? formatMs(h()!.totals.ttft_p95_ms) : undefined} series={series().map(b => b.ttft_p95_ms)} seriesMin={0} />
      <StatTile label="Retried · fell back" value={h() ? `${h()!.totals.retried.toLocaleString()} · ${h()!.totals.fell_back.toLocaleString()}` : undefined}
        title="Requests retried on the same entry before the first byte · answered by a later chain entry"
        series={series().map(b => b.retried + b.fell_back)} seriesMin={0} />
    </div>
    <BreakdownTable label="Reliability by provider" columns={columns} rows={rows()} rowKey={r => r.key}
      collapse={r => !isProblem(r)} collapsedLabel="healthy" skeletonRows={4} limit={10}
      empty="No router traffic in this window."
      detail={r => <ReliabilityDetail row={r} />} />
    <Show when={rows()?.length}><Legend items={OUTCOMES.map(k => ({ key: k, label: OUTCOME_LABEL[k] }))} /></Show>
  </>;
}

function ReliabilityDetail(p: { row: Row }) {
  const g = () => p.row.group;
  const errors = () => Object.entries(g().errors).sort((a, b) => b[1] - a[1]);
  return <div class="rel-detail">
    <p>
      {g().ok.toLocaleString()} ok of {g().requests.toLocaleString()} attempts · first token {formatMs(g().ttft_p50_ms)} p50, {formatMs(g().ttft_p95_ms)} p95
      {g().retried ? ` · ${g().retried.toLocaleString()} retried` : ""}
      <Show when={p.row.status.until}> · quota resets {time(p.row.status.until!)}. 429s here are expected waiting, not failures.</Show>
    </p>
    <Show when={errors().length}>
      <div class="rel-detail-cols">
        <dl><For each={errors()}>{([k, n]) => <><dt>{errorLabel(k)}</dt><dd>{n.toLocaleString()}</dd></>}</For></dl>
        <Show when={g().recent_errors?.length}>
          <dl aria-label="Recent errors"><For each={g().recent_errors}>{e => <><dt>{time(e.at)}</dt><dd>{errorLabel(e.error)}</dd></>}</For></dl>
        </Show>
      </div>
    </Show>
    <Show when={g().account_id}><p class="rel-detail-id">Account {g().account_label ? `${g().account_label} · ` : ""}{g().account_id!.slice(0, 8)}</p></Show>
  </div>;
}
