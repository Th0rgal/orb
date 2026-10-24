import { Show, createResource, createSignal, For } from "solid-js";
import { ErrorNotice } from "./ErrorNotice";
import { BreakdownTable, StatTile, type Column } from "./components/stats";
import { getMissionStats, modelLabel, subagentsUsd, tokens, usd, type MissionStats, type ModelLine, type StatsPeriod } from "./missionStats";

type ChildRow = MissionStats["children"][number];

/**
 * Stats section of Mission settings, on the shared stats primitives
 * (`orb/docs/ui/stats.md`): total spend (own + subagents), spend by served
 * model, VM cost and subagent totals, for today or the mission's lifetime.
 * The previous data stays on screen while another period loads.
 */
export function MissionStatsSection(p: { missionId: string; titleOf?: (id: string) => string | undefined; load?: typeof getMissionStats }) {
  const [period, setPeriod] = createSignal<StatsPeriod>("lifetime");
  const [stats, { refetch }] = createResource(() => [p.missionId, period()] as const, ([id, per]) => (p.load ?? getMissionStats)(id, per));
  // Reading a resource in its error state throws: check the state first.
  const last = (): MissionStats | undefined => (stats.state === "errored" ? undefined : stats.latest);
  const money = (f: (s: MissionStats) => number) => { const s = last(); return s ? usd(f(s)) : undefined; };
  const modelColumns: Column<ModelLine>[] = [
    { header: "Model", width: "minmax(0, 1fr)", cell: m => <span class="ms-model-name" title={modelLabel(m)}>{modelLabel(m)}</span> },
    { header: "Req", width: "44px", align: "end", hideNarrow: true, cell: m => String(m.requests) },
    { header: "In · cache · out", width: "116px", align: "end", hideNarrow: true,
      cell: m => <span title={`${m.input_tokens} input · ${m.cache_read_tokens} cache read · ${m.cache_write_tokens} cache write · ${m.output_tokens} output`}>
        {tokens(m.input_tokens)} · {tokens(m.cache_read_tokens + m.cache_write_tokens)} · {tokens(m.output_tokens)}</span> },
    { header: "Cost", width: "92px", align: "end", cell: m => <span>{usd(m.cost_usd)}
      <Show when={m.shadow_priced}><span class="ms-flag" title="Subscription: shadow price, not billed per use">shadow</span></Show>
      <Show when={m.unpriced}><span class="ms-flag" title="Some requests have no price">unpriced</span></Show></span> },
  ];
  const childColumns: Column<ChildRow>[] = [
    { header: "Subagent", width: "minmax(0, 1fr)", cell: c => c.title ?? p.titleOf?.(c.mission_id) ?? `Agent ${c.mission_id.slice(0, 8)}` },
    { header: "Spend (with its subagents)", width: "160px", align: "end", cell: c => usd(c.total_usd) },
  ];
  return <section class="ms-section" aria-labelledby="ms-stats-title">
    <div class="ms-head">
      <h4 id="ms-stats-title">Stats</h4>
      <div class="ms-period" role="radiogroup" aria-label="Period">
        <For each={[["today", "Today"], ["lifetime", "Lifetime"]] as const}>{([value, label]) =>
          <button type="button" role="radio" aria-checked={period() === value} classList={{ on: period() === value }} onClick={() => setPeriod(value)}>{label}</button>}</For>
      </div>
    </div>
    <Show when={stats.error}><ErrorNotice error={String(stats.error?.message ?? stats.error)} title="Couldn’t load stats"><button class="s-btn sm" onClick={() => void refetch()}>Retry</button></ErrorNotice></Show>
    <div class="st-tiles" classList={{ "ms-stale": stats.loading && !!last() }}>
      <StatTile label="Total" value={money(s => s.subtree_total_usd)} title="This agent and all its subagents" />
      <StatTile label="This agent" value={money(s => s.own.total_usd)} />
      <StatTile label="Subagents" value={money(subagentsUsd)} />
      <StatTile label="Managed VMs" value={money(s => s.own.vm_usd)} />
    </div>
    <BreakdownTable label="Spend by served model" columns={modelColumns} rows={last()?.own.models} rowKey={m => modelLabel(m)} empty="No model spend in this period." />
    <Show when={last()?.children.length}>
      <BreakdownTable label="Subagent spend" columns={childColumns} rows={last()?.children} rowKey={c => c.mission_id} />
    </Show>
  </section>;
}
