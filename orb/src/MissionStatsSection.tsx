import { For, Show, createResource, createSignal } from "solid-js";
import { ErrorNotice } from "./ErrorNotice";
import { getMissionStats, modelLabel, subagentsUsd, tokens, usd, type MissionStats, type StatsPeriod } from "./missionStats";

/**
 * Stats section of Mission settings: total spend (own + subagents), the
 * served models, VM cost and subagent totals, for today or the mission's
 * lifetime. Kept to plain markup so it can move onto the shared stats
 * primitives (`orb/docs/ui/stats.md`) without changing its data.
 */
export function MissionStatsSection(p: { missionId: string; titleOf?: (id: string) => string | undefined; load?: typeof getMissionStats }) {
  const [period, setPeriod] = createSignal<StatsPeriod>("lifetime");
  const [stats, { refetch }] = createResource(() => [p.missionId, period()] as const, ([id, per]) => (p.load ?? getMissionStats)(id, per));
  // Reading a resource in its error state throws: check the state first.
  const last = (): MissionStats | undefined => (stats.state === "errored" ? undefined : stats.latest);
  return <section class="ms-section" aria-labelledby="ms-stats-title">
    <div class="ms-head">
      <h4 id="ms-stats-title">Stats</h4>
      <div class="ms-period" role="radiogroup" aria-label="Period">
        <For each={[["today", "Today"], ["lifetime", "Lifetime"]] as const}>{([value, label]) =>
          <button type="button" role="radio" aria-checked={period() === value} classList={{ on: period() === value }} onClick={() => setPeriod(value)}>{label}</button>}</For>
      </div>
    </div>
    <Show when={stats.error}><ErrorNotice error={String(stats.error?.message ?? stats.error)} title="Couldn’t load stats"><button class="s-btn sm" onClick={() => void refetch()}>Retry</button></ErrorNotice></Show>
    <Show when={last()} fallback={<Show when={!stats.error}><div class="ms-skeleton" aria-hidden="true"><div class="sk-bar" style={{ width: "100%", height: "44px" }} /><div class="sk-bar" style={{ width: "100%", height: "60px" }} /></div></Show>}>
      {s => <div classList={{ "ms-stale": stats.loading }}>
        <dl class="ms-stats ms-stats-3">
          <div><dt>Total</dt><dd data-testid="stats-total">{usd(s().subtree_total_usd)}</dd></div>
          <div><dt>This agent</dt><dd>{usd(s().own.total_usd)}</dd></div>
          <div><dt>Subagents</dt><dd>{usd(subagentsUsd(s()))}</dd></div>
        </dl>
        <Show when={s().own.models.length || s().own.vm_usd > 0} fallback={<p class="ms-hint">No spend in this period.</p>}>
          <table class="ms-table" aria-label="Spend by served model">
            <thead><tr><th>Model</th><th>Req</th><th>In</th><th>Cache</th><th>Out</th><th>Cost</th></tr></thead>
            <tbody>
              <For each={s().own.models}>{m => <tr>
                <td class="ms-model" title={modelLabel(m)}>{modelLabel(m)}</td>
                <td>{m.requests}</td>
                <td>{tokens(m.input_tokens)}</td>
                <td title={`${m.cache_read_tokens} read · ${m.cache_write_tokens} write`}>{tokens(m.cache_read_tokens + m.cache_write_tokens)}</td>
                <td>{tokens(m.output_tokens)}</td>
                <td>{usd(m.cost_usd)}<Show when={m.shadow_priced}><span class="ms-flag" title="Subscription: shadow price, not billed per use">shadow</span></Show><Show when={m.unpriced}><span class="ms-flag" title="Some requests have no price">unpriced</span></Show></td>
              </tr>}</For>
              <Show when={s().own.vm_usd > 0}><tr><td class="ms-model">Managed VMs (boat)</td><td /><td /><td /><td /><td>{usd(s().own.vm_usd)}</td></tr></Show>
            </tbody>
          </table>
        </Show>
        <Show when={s().children.length}>
          <h4 class="ms-sub">Subagents</h4>
          <ul class="ms-children" aria-label="Subagent spend">
            <For each={s().children}>{c => <li>
              <span class="ms-child-title">{c.title ?? p.titleOf?.(c.mission_id) ?? `Agent ${c.mission_id.slice(0, 8)}`}</span>
              <span class="ms-child-mode" />
              <span class="ms-child-spent">{usd(c.total_usd)}</span>
            </li>}</For>
          </ul>
        </Show>
      </div>}
    </Show>
  </section>;
}
