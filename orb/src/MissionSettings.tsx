import { For, Show, createSignal, onMount } from "solid-js";
import { Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { MissionStatsSection } from "./MissionStatsSection";
import type { getMissionStats } from "./missionStats";
import {
  exceedsGrant, getMissionBudget, modeLine, money, optimisticBudget, parseAmount, putMissionBudget, usedFraction,
  type MissionBudget,
} from "./missionBudget";

/**
 * Per-mission settings sheet, opened from the sidebar's right-click menu
 * ("Mission settings…"). Today it holds the managed-machine budget: off by
 * default; when on, the mission's subtree shares that pool (a child given
 * its own lower budget gets a sub-pool carved from it).
 *
 * Changes apply optimistically and roll back with an inline error and Retry
 * when the server refuses them (for example a sub-budget larger than what the
 * parent pool can grant).
 */
export function MissionSettings(p: {
  missionId: string;
  title: string;
  /** Display name for another mission (children, the pool's owner). */
  titleOf?: (id: string) => string | undefined;
  onClose: () => void;
  /** Injected in tests and the gallery; default to the Core API. */
  load?: (id: string) => Promise<MissionBudget>;
  save?: (id: string, budget: number | null) => Promise<MissionBudget>;
  loadStats?: typeof getMissionStats;
}) {
  const loadBudget = (id: string) => (p.load ?? getMissionBudget)(id);
  const saveBudget = (id: string, budget: number | null) => (p.save ?? putMissionBudget)(id, budget);
  const [view, setView] = createSignal<MissionBudget | null>(null);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const [saveError, setSaveError] = createSignal<string | null>(null);
  const [retry, setRetry] = createSignal<(() => void) | null>(null);
  const [busy, setBusy] = createSignal(false);
  const [draft, setDraft] = createSignal("");
  const [fieldError, setFieldError] = createSignal<string | null>(null);

  const load = async () => {
    setLoadError(null);
    try {
      const v = await loadBudget(p.missionId);
      setView(v);
      setDraft(v.own_budget_usd != null ? String(v.own_budget_usd) : "");
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
    }
  };
  onMount(() => void load());

  /** Optimistic write with rollback. One mutation in flight at a time. */
  const commit = async (amount: number | null) => {
    const before = view();
    if (!before || busy()) return;
    setBusy(true);
    setSaveError(null);
    setRetry(null);
    setView(optimisticBudget(before, amount));
    try {
      const next = await saveBudget(p.missionId, amount);
      setView(next);
      setDraft(next.own_budget_usd != null ? String(next.own_budget_usd) : "");
    } catch (e) {
      setView(before);
      setDraft(before.own_budget_usd != null ? String(before.own_budget_usd) : draft());
      setSaveError(e instanceof Error ? e.message : String(e));
      setRetry(() => () => void commit(amount));
    } finally {
      setBusy(false);
    }
  };

  const enabled = () => view()?.mode === "own";
  const dirty = () => {
    const v = view();
    if (!v || !enabled()) return false;
    return draft().trim() !== String(v.own_budget_usd ?? "");
  };
  const save = () => {
    const v = view();
    if (!v) return;
    const parsed = parseAmount(draft());
    if ("error" in parsed) return setFieldError(parsed.error);
    const over = exceedsGrant(v, parsed.value);
    if (over) return setFieldError(over);
    setFieldError(null);
    void commit(parsed.value);
  };
  const toggle = () => {
    const v = view();
    if (!v || busy()) return;
    if (enabled()) return void commit(null);
    // Default amount: what the parent can grant, else $5.
    const initial = v.max_grant_usd != null ? Math.min(5, Math.floor(v.max_grant_usd * 100) / 100) : 5;
    if (initial <= 0) return setFieldError("The parent pool has nothing left to grant");
    setFieldError(null);
    void commit(initial);
  };
  const childTitle = (id: string) => p.titleOf?.(id) ?? `Agent ${id.slice(0, 8)}`;

  return <Dialog title="Mission settings" description={p.title} size="standard" class="mission-settings" busy={false} dirty={dirty()} onClose={p.onClose}
    footer={close => <>
      <DialogButton onClick={close}>Close</DialogButton>
      <Show when={enabled()}>
        <DialogButton variant="primary" disabled={busy() || !dirty()} onClick={save}>{busy() ? "Saving…" : "Save budget"}</DialogButton>
      </Show>
    </>}>
    <section class="ms-section" aria-labelledby="ms-budget-title">
      <div class="ms-head">
        <div>
          <h4 id="ms-budget-title">Budget</h4>
          <p class="ms-hint">Caps what this agent and its subagents spend on managed machines.</p>
        </div>
        <Show when={view()} fallback={<span class="toggle" aria-hidden="true" />}>
          <button class={`toggle ${enabled() ? "on" : ""}`} role="switch" aria-checked={enabled()} aria-label="Spending budget" disabled={busy()} onClick={toggle} />
        </Show>
      </div>
      <Show when={loadError()}>
        <ErrorNotice error={loadError()!} title="Couldn’t load the budget"><DialogButton onClick={() => void load()}>Retry</DialogButton></ErrorNotice>
      </Show>
      <Show when={view()} fallback={<Show when={!loadError()}><div class="ms-skeleton" aria-hidden="true"><div class="sk-bar" style={{ width: "70%", height: "16px" }} /><div class="sk-bar" style={{ width: "100%", height: "8px" }} /><div class="sk-bar" style={{ width: "100%", height: "44px" }} /></div></Show>}>
        {v => <>
          <p class="ms-mode" data-mode={v().mode}>{modeLine(v(), v().pool_id ? p.titleOf?.(v().pool_id!) : undefined)}</p>
          <Show when={enabled()}>
            <form onSubmit={e => { e.preventDefault(); save(); }}>
              <Field label="Amount (USD)" description={v().max_grant_usd != null ? `Up to ${money(v().max_grant_usd!)} from the parent pool.` : "Includes spend of every subagent without its own sub-budget."} error={fieldError()}>
                <input class="s-input" inputmode="decimal" value={draft()} disabled={busy()} onInput={e => { setDraft(e.currentTarget.value); setFieldError(null); }} />
              </Field>
            </form>
          </Show>
          <Show when={!enabled() && fieldError()}><p class="field-error" role="alert">{fieldError()}</p></Show>
          <Show when={saveError()}>
            <ErrorNotice error={saveError()!} title="Budget not saved" onDismiss={() => setSaveError(null)}>
              <Show when={retry()}>{r => <DialogButton onClick={() => r()()}>Retry</DialogButton>}</Show>
            </ErrorNotice>
          </Show>
          <Show when={v().pool}>
            {pool => <div class="ms-usage">
              <div class="ms-bar" role="meter" aria-label="Budget used" aria-valuemin={0} aria-valuemax={1} aria-valuenow={usedFraction(pool())}>
                <span style={{ width: `${usedFraction(pool()) * 100}%` }} />
              </div>
              <dl class="ms-stats">
                <div><dt>Spent</dt><dd>{money(pool().spent_usd)}</dd></div>
                <div><dt>Reserved</dt><dd>{money(pool().reserved_usd)}</dd></div>
                <div><dt>Sub-budgets</dt><dd>{money(pool().carved_usd)}</dd></div>
                <div><dt>Remaining</dt><dd data-low={pool().available_usd < pool().budget_usd * 0.1 ? "" : undefined}>{money(Math.max(0, pool().available_usd))} of {money(pool().budget_usd)}</dd></div>
              </dl>
              <p class="ms-hint">Reserved holds up to 60 minutes of each running machine; machines extend in 30 minute steps while busy, within the budget.</p>
            </div>}
          </Show>
          <Show when={v().children.length}>
            <h4 class="ms-sub">Subagents</h4>
            <ul class="ms-children" aria-label="Subagent budgets">
              <For each={v().children}>{c => <li>
                <span class="ms-child-title">{childTitle(c.mission_id)}</span>
                <span class="ms-child-mode">{c.mode === "sub_budget" ? `Sub-budget ${money(c.budget_usd ?? 0)}` : "Pooled"}</span>
                <span class="ms-child-spent">{money(c.spent_usd)} spent</span>
              </li>}</For>
            </ul>
          </Show>
        </>}
      </Show>
    </section>
    <MissionStatsSection missionId={p.missionId} titleOf={p.titleOf} load={p.loadStats} />
  </Dialog>;
}
