import { For, Show, createSignal, onMount } from "solid-js";
import { Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { MissionStatsSection } from "./MissionStatsSection";
import { BreakdownTable, type Column } from "./components/stats";
import type { getMissionStats } from "./missionStats";
import {
  MANAGED_PROVIDERS,
  exceedsGrant,
  getMissionBudget,
  managedProviderLabel,
  modeLine,
  money,
  normalizeVmLimits,
  optimisticBudget,
  optimisticVmLimits,
  parseAmount,
  parseVmLimits,
  providerLimitsSummary,
  putMissionBudget,
  putMissionVmLimits,
  usedFraction,
  vmLimitsModeLine,
  type ChildBudget,
  type MissionBudget,
  type VmConcurrencyLimits,
} from "./missionBudget";

/**
 * Per-mission settings sheet, opened from the sidebar's right-click menu
 * ("Mission settings…"). Holds:
 * - **Budget**: optional USD spending pool shared by the mission's subtree.
 * - **Machine limit**: optional total and/or per-provider VM concurrency
 *   override that bypasses the global concurrency cap for this subtree.
 * - **Stats**: model and subagent spend breakdowns.
 *
 * Changes apply optimistically and roll back with an inline error and Retry
 * when the server refuses them.
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
  saveVmLimits?: (id: string, limits: VmConcurrencyLimits | null) => Promise<MissionBudget>;
  loadStats?: typeof getMissionStats;
}) {
  const loadBudget = (id: string) => (p.load ?? getMissionBudget)(id);
  const saveBudgetApi = (id: string, budget: number | null) => (p.save ?? putMissionBudget)(id, budget);
  const saveLimitsApi = (id: string, limits: VmConcurrencyLimits | null) =>
    (p.saveVmLimits ?? putMissionVmLimits)(id, limits);

  const [view, setView] = createSignal<MissionBudget | null>(null);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const [saveError, setSaveError] = createSignal<string | null>(null);
  const [retry, setRetry] = createSignal<(() => void) | null>(null);
  const [limitSaveError, setLimitSaveError] = createSignal<string | null>(null);
  const [limitRetry, setLimitRetry] = createSignal<(() => void) | null>(null);
  const [busy, setBusy] = createSignal(false);

  const [draft, setDraft] = createSignal("");
  const [fieldError, setFieldError] = createSignal<string | null>(null);

  const [maxDraft, setMaxDraft] = createSignal("");
  const [provDrafts, setProvDrafts] = createSignal<Record<string, string>>({});
  const [limitFieldError, setLimitFieldError] = createSignal<string | null>(null);
  const [providersOpen, setProvidersOpen] = createSignal(false);

  const syncLimitDrafts = (v: MissionBudget) => {
    const own = v.own_vm_limits;
    setMaxDraft(own?.max_concurrent != null ? String(own.max_concurrent) : "");
    const nextProv: Record<string, string> = {};
    let hasProv = false;
    for (const prov of MANAGED_PROVIDERS) {
      const val = own?.provider_max_concurrent?.[prov.id];
      if (val != null) {
        nextProv[prov.id] = String(val);
        hasProv = true;
      } else {
        nextProv[prov.id] = "";
      }
    }
    setProvDrafts(nextProv);
    if (hasProv) setProvidersOpen(true);
  };

  const load = async () => {
    setLoadError(null);
    try {
      const v = await loadBudget(p.missionId);
      setView(v);
      setDraft(v.own_budget_usd != null ? String(v.own_budget_usd) : "");
      syncLimitDrafts(v);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
    }
  };
  onMount(() => void load());

  /** Optimistic budget write with rollback. */
  const commit = async (amount: number | null) => {
    const before = view();
    if (!before || busy()) return;
    setBusy(true);
    setSaveError(null);
    setRetry(null);
    setView(optimisticBudget(before, amount));
    try {
      const next = await saveBudgetApi(p.missionId, amount);
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

  /** Optimistic VM concurrency override write with rollback. */
  const commitLimits = async (limits: VmConcurrencyLimits | null) => {
    const before = view();
    if (!before || busy()) return;
    setBusy(true);
    setLimitSaveError(null);
    setLimitRetry(null);
    setView(optimisticVmLimits(before, limits));
    try {
      const next = await saveLimitsApi(p.missionId, limits);
      setView(next);
      syncLimitDrafts(next);
    } catch (e) {
      setView(before);
      syncLimitDrafts(before);
      setLimitSaveError(e instanceof Error ? e.message : String(e));
      setLimitRetry(() => () => void commitLimits(limits));
    } finally {
      setBusy(false);
    }
  };

  const enabled = () => view()?.mode === "own";
  const vmLimitsEnabled = () => view()?.vm_limits_mode === "own";

  const budgetDirty = () => {
    const v = view();
    if (!v || !enabled()) return false;
    return draft().trim() !== String(v.own_budget_usd ?? "");
  };

  const currentDraftNormalized = () => {
    const pMap: Record<string, number> = {};
    for (const prov of MANAGED_PROVIDERS) {
      const raw = (provDrafts()[prov.id] ?? "").trim();
      if (raw !== "") pMap[prov.id] = Number(raw);
    }
    const mRaw = maxDraft().trim();
    return normalizeVmLimits({
      max_concurrent: mRaw === "" ? null : Number(mRaw),
      provider_max_concurrent: pMap,
    });
  };

  const vmLimitsDirty = () => {
    const v = view();
    if (!v || !vmLimitsEnabled()) return false;
    return currentDraftNormalized() !== normalizeVmLimits(v.own_vm_limits);
  };

  const anyDirty = () => budgetDirty() || vmLimitsDirty();

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

  const saveLimits = () => {
    const v = view();
    if (!v) return;
    const parsed = parseVmLimits(maxDraft(), provDrafts(), v);
    if ("error" in parsed) return setLimitFieldError(parsed.error);
    setLimitFieldError(null);
    void commitLimits(parsed.value);
  };

  const saveAll = async () => {
    if (budgetDirty()) save();
    else if (vmLimitsDirty()) saveLimits();
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

  const toggleVmLimits = () => {
    const v = view();
    if (!v || busy()) return;
    if (vmLimitsEnabled()) return void commitLimits(null);
    const ancMax = v.effective_vm_limits?.ancestor_max_concurrent;
    if (ancMax != null && ancMax <= 0) {
      return setLimitFieldError("The parent pool does not allow concurrent machines");
    }
    const defaultMax = ancMax != null ? Math.min(4, ancMax) : 4;
    setLimitFieldError(null);
    setMaxDraft(String(defaultMax));
    setProvDrafts({});
    void commitLimits({ max_concurrent: defaultMax, provider_max_concurrent: {} });
  };

  const hasAnyProviderDraft = () =>
    MANAGED_PROVIDERS.some(prov => (provDrafts()[prov.id] ?? "").trim() !== "");

  const draftProviderSummary = () => {
    const parts = MANAGED_PROVIDERS
      .filter(prov => (provDrafts()[prov.id] ?? "").trim() !== "")
      .map(prov => {
        const raw = provDrafts()[prov.id]!.trim();
        return `${prov.label}: ${raw === "0" ? "off" : raw}`;
      });
    return parts.join(" · ");
  };

  const childTitle = (id: string) => p.titleOf?.(id) ?? `Agent ${id.slice(0, 8)}`;

  const showSubagentPoolTable = (v: MissionBudget) =>
    v.children.length > 0 && (
      v.mode !== "none" ||
      (v.vm_limits_mode != null && v.vm_limits_mode !== "global") ||
      v.children.some(c => c.mode === "sub_budget" || c.has_vm_limits)
    );

  const subagentColumns: Column<ChildBudget>[] = [
    {
      header: "Subagent",
      width: "minmax(0, 1fr)",
      cell: c => <span class="ms-child-title" title={childTitle(c.mission_id)}>{childTitle(c.mission_id)}</span>,
    },
    {
      header: "Pool",
      width: "auto",
      hideNarrow: true,
      cell: c => <span class="ms-child-mode">
        {c.mode === "sub_budget" ? `Sub-budget ${money(c.budget_usd ?? 0)}` : "Pooled"}
        <Show when={c.has_vm_limits}>
          {c.vm_max_concurrent != null ? ` · ≤${c.vm_max_concurrent} VMs` : " · own cap"}
        </Show>
      </span>,
    },
    {
      header: "Spent",
      width: "92px",
      align: "end",
      cell: c => <span class="ms-child-spent">{money(c.spent_usd)} spent</span>,
    },
  ];

  return <Dialog title="Mission settings" description={p.title} size="standard" class="mission-settings" busy={false} dirty={anyDirty()} onClose={p.onClose}
    footer={close => <>
      <DialogButton onClick={close}>Close</DialogButton>
      <Show when={enabled() && !vmLimitsDirty()}>
        <DialogButton variant="primary" disabled={busy() || !budgetDirty()} onClick={save}>{busy() ? "Saving…" : "Save budget"}</DialogButton>
      </Show>
      <Show when={vmLimitsEnabled() && (vmLimitsDirty() || !enabled())}>
        <DialogButton variant="primary" disabled={busy() || !anyDirty()} onClick={budgetDirty() && vmLimitsDirty() ? saveAll : saveLimits}>
          {busy() ? "Saving…" : (budgetDirty() && vmLimitsDirty() ? "Save changes" : "Save limit")}
        </DialogButton>
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
        <ErrorNotice error={loadError()!} title="Couldn’t load mission settings"><DialogButton onClick={() => void load()}>Retry</DialogButton></ErrorNotice>
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
        </>}
      </Show>
    </section>

    <Show when={view()}>
      {v => <>
        <section class="ms-section" aria-labelledby="ms-vmlimit-title">
          <div class="ms-head">
            <div>
              <h4 id="ms-vmlimit-title">Machine limit</h4>
              <p class="ms-hint">Overrides the global concurrent VM cap for this agent and its subagents.</p>
            </div>
            <button class={`toggle ${vmLimitsEnabled() ? "on" : ""}`} role="switch" aria-checked={vmLimitsEnabled()} aria-label="Machine limit" disabled={busy()} onClick={toggleVmLimits} />
          </div>
          <div class="ms-mode-row">
            <p class="ms-mode" data-mode={v().vm_limits_mode ?? "global"}>
              {vmLimitsModeLine(v(), v().vm_limits_pool_id ? p.titleOf?.(v().vm_limits_pool_id!) : undefined)}
            </p>
            <Show when={v().effective_vm_limits?.source === "mission"}>
              {(() => {
                const eff = () => v().effective_vm_limits!;
                return <div class="ms-cap-pills">
                  <Show when={eff().max_concurrent != null}>
                    <span class="st-pill" data-tone={eff().active >= eff().max_concurrent! ? "warning" : undefined}>
                      <span>{eff().active} of {eff().max_concurrent} running</span>
                    </span>
                  </Show>
                  <For each={eff().provider_limits}>{pl =>
                    <span class="st-pill" data-tone={pl.active >= pl.max_concurrent ? "warning" : undefined}>
                      <span>{managedProviderLabel(pl.provider)}: {pl.max_concurrent === 0 ? "disabled" : `${pl.active} of ${pl.max_concurrent}`}</span>
                    </span>
                  }</For>
                </div>;
              })()}
            </Show>
          </div>
          <Show when={vmLimitsEnabled()}>
            <form class="ms-limit-form" onSubmit={e => { e.preventDefault(); saveLimits(); }}>
              <Field
                label="Max concurrent machines"
                description={v().effective_vm_limits?.ancestor_max_concurrent != null
                  ? `Up to ${v().effective_vm_limits!.ancestor_max_concurrent} within the parent pool.`
                  : "Across all providers. Leave blank to override specific providers only."}
                error={limitFieldError()}
              >
                <input
                  class="s-input"
                  inputmode="numeric"
                  placeholder={hasAnyProviderDraft() ? "Any (use provider limits)" : "4"}
                  value={maxDraft()}
                  disabled={busy()}
                  onInput={e => { setMaxDraft(e.currentTarget.value); setLimitFieldError(null); }}
                />
              </Field>
              <div class="ms-disclosure-wrap">
                <button
                  type="button"
                  class="ms-disclosure"
                  aria-expanded={providersOpen()}
                  onClick={() => setProvidersOpen(o => !o)}
                >
                  <span class="ms-disclosure-left">
                    <span class="ms-disclosure-chevron" aria-hidden="true">{providersOpen() ? "▾" : "▸"}</span>
                    <span>Per-provider limits</span>
                  </span>
                  <span class="ms-disclosure-meta">{draftProviderSummary() || providerLimitsSummary(v().own_vm_limits) || "Optional"}</span>
                </button>
                <Show when={providersOpen()}>
                  <div class="ms-provider-body">
                    <div class="ms-provider-grid">
                      <For each={MANAGED_PROVIDERS}>{prov =>
                        <label class="ms-provider-field">
                          <span class="ms-provider-label">{prov.label}</span>
                          <input
                            class="s-input"
                            inputmode="numeric"
                            placeholder="Any"
                            aria-label={`${prov.label} limit`}
                            value={provDrafts()[prov.id] ?? ""}
                            disabled={busy()}
                            onInput={e => {
                              const val = e.currentTarget.value;
                              setProvDrafts(prev => ({ ...prev, [prov.id]: val }));
                              setLimitFieldError(null);
                            }}
                          />
                        </label>
                      }</For>
                    </div>
                    <p class="ms-hint">Leave blank to share the mission limit (or the global cap if max concurrent is blank). Enter 0 to block a provider.</p>
                  </div>
                </Show>
              </div>
            </form>
          </Show>
          <Show when={!vmLimitsEnabled() && limitFieldError()}><p class="field-error" role="alert">{limitFieldError()}</p></Show>
          <Show when={limitSaveError()}>
            <ErrorNotice error={limitSaveError()!} title="Machine limit not saved" onDismiss={() => setLimitSaveError(null)}>
              <Show when={limitRetry()}>{r => <DialogButton onClick={() => r()()}>Retry</DialogButton>}</Show>
            </ErrorNotice>
          </Show>
        </section>

        <Show when={showSubagentPoolTable(v())}>
          <section class="ms-section" aria-labelledby="ms-subagents-title">
            <h4 id="ms-subagents-title">Subagent pools</h4>
            <BreakdownTable
              label="Subagent budgets"
              columns={subagentColumns}
              rows={v().children}
              rowKey={c => c.mission_id}
              limit={5}
              collapse={c => c.mode === "pooled" && !c.has_vm_limits && c.spent_usd === 0 && c.reserved_usd === 0}
              collapsedLabel="pooled with $0 spend"
              maxHeight="200px"
            />
          </section>
        </Show>
      </>}
    </Show>

    <MissionStatsSection missionId={p.missionId} titleOf={p.titleOf} load={p.loadStats} />
  </Dialog>;
}
