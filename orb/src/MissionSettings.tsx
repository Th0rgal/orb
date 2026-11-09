import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { getMissionResources, isConnected, type MissionResourcesResponse } from "./api";
import { ErrorToast } from "./toast";
import * as Ic from "./icons";
import { MissionStatsSection } from "./MissionStatsSection";
import { pollWhileVisible } from "./poll";
import { SettingsCard, SettingsRow } from "./SettingsCard";
import { BreakdownTable, Legend, OutcomeBar, type Column } from "./components/stats";
import type { getMissionStats } from "./missionStats";
import {
  MANAGED_PROVIDERS,
  bandwidthLimitsSummary,
  bandwidthModeLine,
  computeRunwayForecast,
  exceedsGrant,
  formatDurationEta,
  formatTokensPerMin,
  getMissionBudget,
  managedProviderLabel,
  modeLine,
  money,
  normalizeBandwidthLimits,
  normalizeVmLimits,
  optimisticBandwidthLimits,
  optimisticBudget,
  optimisticVmLimits,
  parseAmount,
  parseBandwidthLimits,
  parseVmLimits,
  providerLimitsSummary,
  putMissionBandwidthLimits,
  putMissionBudget,
  putMissionVmLimits,
  vmLimitsModeLine,
  type BandwidthLimits,
  type BudgetResetPeriod,
  type ChildBudget,
  type MissionBudget,
  type VmConcurrencyLimits,
} from "./missionBudget";

const BUDGET_LEGEND = [
  { key: "client", label: "Spent" },
  { key: "limited", label: "Reserved" },
  { key: "timeout", label: "Sub-budgets" },
  { key: "ok", label: "Remaining" },
];

/**
 * Full-page per-mission settings view (`ms:<missionId>`), opened from the
 * sidebar right-click menu ("Mission settings") or the conversation titlebar.
 *
 * Composed with `SettingsCard` / `SettingsRow` and topped by a compact Runway &
 * Spend forecast chart that reacts live to draft budget and bandwidth edits:
 * - **Runway forecast**: observed cumulative spend, reserved hold, cap line,
 *   and projected exhaustion ETA with a link to `Resources & DAG`.
 * - **Budget**: optional USD spending pool shared by the mission's subtree.
 * - **Bandwidth & pacing**: optional inference (`tokens/min`) and managed
 *   compute (`vCPU/min`, `$/h`) rate ceilings enforced via pace/delay smoothing.
 * - **Machine concurrency**: optional total and/or per-provider VM concurrency
 *   override that bypasses the global concurrency cap for this subtree.
 * - **Subagent pools & Stats**: subtree pool breakdown and model/subagent spend.
 */
export function MissionSettings(p: {
  missionId: string;
  title: string;
  /** Display name for another mission (children, the pool's owner). */
  titleOf?: (id: string) => string | undefined;
  onClose?: () => void;
  onOpen?: (id: string) => void;
  /** Injected in tests and the gallery; default to the Core API. */
  load?: (id: string) => Promise<MissionBudget>;
  pollIntervalMs?: number;
  loadResources?: (id: string) => Promise<MissionResourcesResponse | null>;
  save?: (id: string, budget: number | null, resetPeriod?: BudgetResetPeriod) => Promise<MissionBudget>;
  saveVmLimits?: (id: string, limits: VmConcurrencyLimits | null) => Promise<MissionBudget>;
  saveBandwidthLimits?: (id: string, limits: BandwidthLimits | null) => Promise<MissionBudget>;
  loadStats?: typeof getMissionStats;
  readOnly?: boolean;
}) {
  const loadBudget = (id: string) => (p.load ?? getMissionBudget)(id);
  const loadResourcesApi = (id: string) =>
    p.loadResources
      ? p.loadResources(id)
      : isConnected()
        ? getMissionResources(id).catch(() => null)
        : Promise.resolve(null);
  const saveBudgetApi = (id: string, budget: number | null, resetPeriod?: BudgetResetPeriod) =>
    (p.save ?? putMissionBudget)(id, budget, resetPeriod);
  const saveLimitsApi = (id: string, limits: VmConcurrencyLimits | null) =>
    (p.saveVmLimits ?? putMissionVmLimits)(id, limits);
  const saveBandwidthApi = (id: string, limits: BandwidthLimits | null) =>
    (p.saveBandwidthLimits ?? putMissionBandwidthLimits)(id, limits);

  const [view, setView] = createSignal<MissionBudget | null>(null);
  const [resources, setResources] = createSignal<MissionResourcesResponse | null>(null);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const [saveError, setSaveError] = createSignal<string | null>(null);
  const [retry, setRetry] = createSignal<(() => void) | null>(null);
  const [limitSaveError, setLimitSaveError] = createSignal<string | null>(null);
  const [limitRetry, setLimitRetry] = createSignal<(() => void) | null>(null);
  const [bwSaveError, setBwSaveError] = createSignal<string | null>(null);
  const [bwRetry, setBwRetry] = createSignal<(() => void) | null>(null);
  const [busy, setBusy] = createSignal(false);
  const locked = () => Boolean(p.readOnly) || busy();

  const [draft, setDraft] = createSignal("");
  const [resetPeriodDraft, setResetPeriodDraft] = createSignal<BudgetResetPeriod>("total");
  const [budgetEdited, setBudgetEdited] = createSignal(false);
  const [fieldError, setFieldError] = createSignal<string | null>(null);

  const [maxDraft, setMaxDraft] = createSignal("");
  const [provDrafts, setProvDrafts] = createSignal<Record<string, string>>({});
  const [vmEdited, setVmEdited] = createSignal(false);
  const [limitFieldError, setLimitFieldError] = createSignal<string | null>(null);
  const [providersOpen, setProvidersOpen] = createSignal(false);

  const [bwTokensDraft, setBwTokensDraft] = createSignal("");
  const [bwInfUsdHDraft, setBwInfUsdHDraft] = createSignal("");
  const [bwVcpuDraft, setBwVcpuDraft] = createSignal("");
  const [bwUsdHDraft, setBwUsdHDraft] = createSignal("");
  const [bwProtectRoot, setBwProtectRoot] = createSignal(true);
  const [bwEdited, setBwEdited] = createSignal(false);
  const [bwFieldError, setBwFieldError] = createSignal<string | null>(null);

  const syncBudgetDrafts = (v: MissionBudget) => {
    setDraft(v.own_budget_usd != null ? String(v.own_budget_usd) : "");
    setResetPeriodDraft(
      v.max_grant_usd != null
        ? "total"
        : (v.own_budget_reset_period ?? v.pool?.reset_period ?? "total"),
    );
    setBudgetEdited(false);
  };

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
    setVmEdited(false);
    if (hasProv) setProvidersOpen(true);
  };

  const syncBandwidthDrafts = (v: MissionBudget) => {
    const own = v.own_bandwidth_limits;
    setBwTokensDraft(own?.tokens_per_min != null ? String(own.tokens_per_min) : "");
    setBwInfUsdHDraft(own?.inference_usd_per_hour != null ? String(own.inference_usd_per_hour) : "");
    setBwVcpuDraft(own?.compute_vcpu_per_min != null ? String(own.compute_vcpu_per_min) : "");
    setBwUsdHDraft(own?.compute_usd_per_hour != null ? String(own.compute_usd_per_hour) : "");
    setBwProtectRoot(own?.protect_root ?? true);
    setBwEdited(false);
  };

  // Monotonic generation bumped on every mutation start/settle so an in-flight
  // background poll never overwrites optimistic or newly saved settings.
  let mutationGen = 0;

  const load = async (background = false) => {
    if (background && busy()) return;
    const genAtStart = mutationGen;
    if (!background) setLoadError(null);
    try {
      const [v, res] = await Promise.all([
        loadBudget(p.missionId),
        loadResourcesApi(p.missionId).catch(() => null),
      ]);
      if (genAtStart !== mutationGen || busy()) return;
      setView(v);
      if (res) setResources(res);
      if (!budgetEdited()) syncBudgetDrafts(v);
      if (!vmEdited()) syncLimitDrafts(v);
      if (!bwEdited()) syncBandwidthDrafts(v);
    } catch (e) {
      if (genAtStart !== mutationGen) return;
      if (!background) setLoadError(e instanceof Error ? e.message : String(e));
    }
  };

  onMount(() => {
    void load(false);
    if (p.pollIntervalMs || (isConnected() && !p.load)) {
      const stop = pollWhileVisible(() => void load(true), p.pollIntervalMs ?? 15_000);
      onCleanup(stop);
    }
  });

  /** Optimistic budget write with rollback. */
  const commit = async (amount: number | null, period?: BudgetResetPeriod) => {
    const before = view();
    if (!before || busy()) return;
    mutationGen += 1;
    setBusy(true);
    setSaveError(null);
    setRetry(null);
    const opt = optimisticBudget(before, amount, period);
    setView(opt);
    syncBudgetDrafts(opt);
    try {
      const next = await saveBudgetApi(p.missionId, amount, period);
      mutationGen += 1;
      setView(next);
      syncBudgetDrafts(next);
    } catch (e) {
      mutationGen += 1;
      setView(before);
      syncBudgetDrafts(before);
      setSaveError(e instanceof Error ? e.message : String(e));
      setRetry(() => () => void commit(amount, period));
    } finally {
      setBusy(false);
    }
  };

  /** Optimistic VM concurrency override write with rollback. */
  const commitLimits = async (limits: VmConcurrencyLimits | null) => {
    const before = view();
    if (!before || busy()) return;
    mutationGen += 1;
    setBusy(true);
    setLimitSaveError(null);
    setLimitRetry(null);
    const opt = optimisticVmLimits(before, limits);
    setView(opt);
    syncLimitDrafts(opt);
    try {
      const next = await saveLimitsApi(p.missionId, limits);
      mutationGen += 1;
      setView(next);
      syncLimitDrafts(next);
    } catch (e) {
      mutationGen += 1;
      setView(before);
      syncLimitDrafts(before);
      setLimitSaveError(e instanceof Error ? e.message : String(e));
      setLimitRetry(() => () => void commitLimits(limits));
    } finally {
      setBusy(false);
    }
  };

  /** Optimistic bandwidth & pacing write with rollback. */
  const commitBandwidth = async (limits: BandwidthLimits | null) => {
    const before = view();
    if (!before || busy()) return;
    mutationGen += 1;
    setBusy(true);
    setBwSaveError(null);
    setBwRetry(null);
    const opt = optimisticBandwidthLimits(before, limits);
    setView(opt);
    syncBandwidthDrafts(opt);
    try {
      const next = await saveBandwidthApi(p.missionId, limits);
      mutationGen += 1;
      setView(next);
      syncBandwidthDrafts(next);
    } catch (e) {
      mutationGen += 1;
      setView(before);
      syncBandwidthDrafts(before);
      setBwSaveError(e instanceof Error ? e.message : String(e));
      setBwRetry(() => () => void commitBandwidth(limits));
    } finally {
      setBusy(false);
    }
  };

  const enabled = () => view()?.mode === "own";
  const vmLimitsEnabled = () => view()?.vm_limits_mode === "own";
  const bandwidthEnabled = () => view()?.bandwidth_mode === "own";

  const budgetDirty = () => {
    const v = view();
    if (!v || !enabled()) return false;
    const serverPeriod: BudgetResetPeriod =
      v.max_grant_usd != null
        ? "total"
        : (v.own_budget_reset_period ?? v.pool?.reset_period ?? "total");
    const periodDirty = v.max_grant_usd == null && resetPeriodDraft() !== serverPeriod;
    return draft().trim() !== String(v.own_budget_usd ?? "") || periodDirty;
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

  const currentBandwidthNormalized = () => {
    const parsed = parseBandwidthLimits(
      bwTokensDraft(),
      bwVcpuDraft(),
      bwUsdHDraft(),
      bwProtectRoot(),
      undefined,
      bwInfUsdHDraft(),
    );
    if ("error" in parsed) {
      return `draft:${bwTokensDraft().trim()}|${bwInfUsdHDraft().trim()}|${bwVcpuDraft().trim()}|${bwUsdHDraft().trim()}|${bwProtectRoot()}`;
    }
    return normalizeBandwidthLimits(parsed.value);
  };

  const bandwidthDirty = () => {
    const v = view();
    if (!v || !bandwidthEnabled()) return false;
    return currentBandwidthNormalized() !== normalizeBandwidthLimits(v.own_bandwidth_limits);
  };

  const save = () => {
    const v = view();
    if (!v) return;
    const parsed = parseAmount(draft());
    if ("error" in parsed) return setFieldError(parsed.error);
    const over = exceedsGrant(v, parsed.value);
    if (over) return setFieldError(over);
    setFieldError(null);
    const period = v.max_grant_usd != null ? undefined : resetPeriodDraft();
    void commit(parsed.value, period);
  };

  const saveLimits = () => {
    const v = view();
    if (!v) return;
    const parsed = parseVmLimits(maxDraft(), provDrafts(), v);
    if ("error" in parsed) return setLimitFieldError(parsed.error);
    setLimitFieldError(null);
    void commitLimits(parsed.value);
  };

  const saveBandwidth = () => {
    const v = view();
    if (!v) return;
    const parsed = parseBandwidthLimits(
      bwTokensDraft(),
      bwVcpuDraft(),
      bwUsdHDraft(),
      bwProtectRoot(),
      v,
      bwInfUsdHDraft(),
    );
    if ("error" in parsed) return setBwFieldError(parsed.error);
    setBwFieldError(null);
    void commitBandwidth(parsed.value);
  };

  const toggle = () => {
    const v = view();
    if (!v || busy()) return;
    if (enabled()) return void commit(null);
    const initial = v.max_grant_usd != null ? Math.min(5, Math.floor(v.max_grant_usd * 100) / 100) : 5;
    if (initial <= 0) return setFieldError("The parent pool has nothing left to grant");
    setFieldError(null);
    void commit(initial, v.max_grant_usd != null ? undefined : "total");
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

  const toggleBandwidth = () => {
    const v = view();
    if (!v || busy()) return;
    if (bandwidthEnabled()) return void commitBandwidth(null);
    const eff = v.effective_bandwidth;
    const ancTpm = eff?.ancestor_tokens_per_min ?? null;
    const defaultTpm = ancTpm != null ? Math.min(120_000, ancTpm) : 120_000;
    setBwFieldError(null);
    setBwTokensDraft(String(defaultTpm));
    setBwInfUsdHDraft("");
    setBwVcpuDraft("");
    setBwUsdHDraft("");
    setBwProtectRoot(true);
    void commitBandwidth({
      tokens_per_min: defaultTpm,
      inference_usd_per_hour: null,
      compute_vcpu_per_min: null,
      compute_usd_per_hour: null,
      protect_root: true,
    });
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

  const forecast = createMemo(() =>
    computeRunwayForecast({
      budget: view(),
      resources: resources(),
      draftBudgetUsd: enabled() ? draft() : undefined,
      draftResetPeriod: enabled() && view()?.max_grant_usd == null ? resetPeriodDraft() : undefined,
      draftInferenceUsdPerH: bandwidthEnabled() ? bwInfUsdHDraft() : undefined,
      draftComputeUsdPerH: bandwidthEnabled() ? bwUsdHDraft() : undefined,
      draftComputeVcpu: bandwidthEnabled() ? bwVcpuDraft() : undefined,
      bandwidthEnabled: bandwidthEnabled() || view()?.effective_bandwidth?.source === "mission",
      budgetEnabled: enabled() || view()?.mode === "pooled",
    }),
  );

  const childTitle = (id: string) => p.titleOf?.(id) ?? `Agent ${id.slice(0, 8)}`;

  const showSubagentPoolTable = (v: MissionBudget) =>
    (v.children?.length ?? 0) > 0 && (
      v.mode !== "none" ||
      (v.vm_limits_mode != null && v.vm_limits_mode !== "global") ||
      (v.bandwidth_mode != null && v.bandwidth_mode !== "none") ||
      v.children.some(c => c.mode === "sub_budget" || c.has_vm_limits || c.has_bandwidth_limits)
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
        <Show when={c.has_bandwidth_limits}>
          {c.tokens_per_min != null ? ` · ${formatTokensPerMin(c.tokens_per_min)}` : " · paced"}
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

  const handleBack = () => {
    if (p.onOpen) p.onOpen(`m:${p.missionId}`);
    else p.onClose?.();
  };

  return (
    <div class="scroll">
      <div class="col ps-page ms-page mission-settings" role="region" aria-label="Mission settings">
        <div class="page-head ms-page-head">
          <div class="ms-page-title">
            <h2>{p.title}</h2>
            <p class="s-lead">Mission settings</p>
          </div>
          <div class="ms-page-actions">
            <Show when={p.onOpen}>
              <button type="button" class="s-btn" onClick={() => p.onOpen!(`rm:${p.missionId}`)}>
                <Ic.ResourcesIcon />
                <span>Resources &amp; DAG</span>
              </button>
            </Show>
            <Show when={p.onOpen || p.onClose}>
              <button type="button" class="s-btn" onClick={handleBack}>
                <Ic.ArrowLeft />
                <span>Conversation</span>
              </button>
            </Show>
          </div>
        </div>

        <ErrorToast error={loadError()} title="Couldn’t load mission settings" background action={{ label: "Retry", run: () => load(false) }} />

        <Show
          when={view()}
          fallback={
            <Show when={!loadError()}>
              <div class="ms-page-skeleton" aria-hidden="true">
                <div class="s-card ms-forecast-card ms-forecast-sk">
                  <div class="sk-bar" style={{ width: "42%", height: "18px" }} />
                  <div class="sk-bar" style={{ width: "68%", height: "13px" }} />
                  <div class="sk-bar" style={{ width: "100%", height: "72px" }} />
                </div>
                <div class="s-card ms-card-sk"><div class="sk-bar" style={{ width: "55%", height: "16px" }} /><div class="sk-bar" style={{ width: "100%", height: "38px" }} /></div>
                <div class="s-card ms-card-sk"><div class="sk-bar" style={{ width: "48%", height: "16px" }} /><div class="sk-bar" style={{ width: "100%", height: "38px" }} /></div>
              </div>
            </Show>
          }
        >
          {v => (
            <>
              <section class="s-sec ms-forecast-sec" aria-label="Runway forecast">
                <div class="s-card ms-forecast-card" data-testid="mission-forecast-card">
                  <div class="ms-forecast-top">
                    <div class="ms-forecast-copy">
                      <div class="ms-forecast-headline" data-tone={forecast().tone}>
                        {forecast().headline}
                      </div>
                      <div class="ms-forecast-sub">{forecast().subline}</div>
                    </div>
                    <div class="ms-forecast-pills">
                      <Show when={forecast().pacingActive}>
                        <span class="st-pill" data-tone="warning">
                          <span>Pacing active</span>
                        </span>
                      </Show>
                      <Show when={forecast().currentTokensPerMin > 0}>
                        <span class="st-pill">
                          <span>{formatTokensPerMin(forecast().currentTokensPerMin)}</span>
                        </span>
                      </Show>
                      <Show when={forecast().currentVcpuPerMin > 0}>
                        <span class="st-pill">
                          <span>{forecast().currentVcpuPerMin} vCPU</span>
                        </span>
                      </Show>
                    </div>
                  </div>
                  <svg
                    class="ms-forecast-svg"
                    viewBox={`0 0 ${forecast().chart.width} ${forecast().chart.height}`}
                    preserveAspectRatio="none"
                    role="img"
                    aria-label={`Runway forecast: ${forecast().headline}`}
                  >
                    <Show when={forecast().chart.capY != null}>
                      <line
                        class="ms-fc-cap"
                        x1={forecast().chart.padLeft}
                        x2={forecast().chart.width - forecast().chart.padRight}
                        y1={forecast().chart.capY!}
                        y2={forecast().chart.capY!}
                      />
                    </Show>
                    <path class="ms-fc-area" d={forecast().chart.observedAreaPath} />
                    <path class="ms-fc-obs" d={forecast().chart.observedLinePath} />
                    <line
                      class="ms-fc-now"
                      x1={forecast().chart.nowX}
                      x2={forecast().chart.nowX}
                      y1={forecast().chart.padTop}
                      y2={forecast().chart.height - forecast().chart.padBottom}
                    />
                    <Show when={forecast().reservedUsd > 0.001}>
                      <line
                        class="ms-fc-reserved"
                        x1={forecast().chart.nowX}
                        x2={forecast().chart.nowX}
                        y1={forecast().chart.nowY}
                        y2={forecast().chart.reservedTopY}
                      />
                    </Show>
                    <Show when={forecast().chart.unshapedLinePath}>
                      {path => <path class="ms-fc-unshaped" d={path()} />}
                    </Show>
                    <path class="ms-fc-proj" data-tone={forecast().tone} d={forecast().chart.projectedLinePath} />
                    <circle class="ms-fc-dot" cx={forecast().chart.nowX} cy={forecast().chart.nowY} r="3" />
                    <Show when={forecast().chart.exhaustionX != null && forecast().chart.capY != null}>
                      <circle
                        class="ms-fc-exhaust-dot"
                        data-tone={forecast().tone}
                        cx={forecast().chart.exhaustionX!}
                        cy={forecast().chart.capY!}
                        r="3.2"
                      />
                    </Show>
                  </svg>
                  <div class="ms-forecast-axis" aria-hidden="true">
                    <span>Start</span>
                    <span>Now</span>
                    <span>{forecast().etaSecs != null ? "Projected runway" : "Projected burn"}</span>
                  </div>
                </div>
              </section>

              <Show when={p.readOnly}>
                <p class="s-lead" role="note">
                  Shared conversation — only the mission owner can change spending or concurrency limits.
                </p>
              </Show>

              <SettingsCard title="Budget">
                <SettingsRow
                  title="Spending budget"
                  desc={modeLine(v(), v().pool_id ? p.titleOf?.(v().pool_id!) : undefined)}
                >
                  <button
                    type="button"
                    class={`toggle ${enabled() ? "on" : ""}`}
                    role="switch"
                    aria-checked={enabled()}
                    aria-label="Spending budget"
                    disabled={locked()}
                    onClick={toggle}
                  />
                </SettingsRow>
                <Show when={enabled()}>
                  <Show when={v().max_grant_usd == null}>
                    <SettingsRow
                      title="Reset cadence"
                      desc={
                        resetPeriodDraft() === "daily"
                          ? "Resets every day at 00:00 UTC while preserving lifetime spend telemetry."
                          : resetPeriodDraft() === "weekly"
                            ? "Resets every Monday at 00:00 UTC while preserving lifetime spend telemetry."
                            : "One-time spending cap across the mission's full lifetime."
                      }
                    >
                      <div class="ms-period" role="radiogroup" aria-label="Reset cadence">
                        <For
                          each={[
                            ["total", "Total"],
                            ["daily", "Daily"],
                            ["weekly", "Weekly"],
                          ] as const}
                        >
                          {([val, label]) => (
                            <button
                              type="button"
                              role="radio"
                              aria-checked={resetPeriodDraft() === val}
                              classList={{ on: resetPeriodDraft() === val }}
                              disabled={locked()}
                              onClick={() => {
                                setBudgetEdited(true);
                                setResetPeriodDraft(val);
                                setFieldError(null);
                              }}
                            >
                              {label}
                            </button>
                          )}
                        </For>
                      </div>
                    </SettingsRow>
                  </Show>
                  <SettingsRow
                    title={<label for="ms-budget-amount">Amount (USD)</label>}
                    desc={
                      v().max_grant_usd != null
                        ? `Up to ${money(v().max_grant_usd!)} from the parent pool.`
                        : "Includes spend of every subagent without its own sub-budget."
                    }
                  >
                    <form
                      class="ms-inline-ctrl"
                      onSubmit={e => {
                        e.preventDefault();
                        save();
                      }}
                    >
                      <input
                        id="ms-budget-amount"
                        aria-label="Amount (USD)"
                        class="s-input ms-num-input"
                        inputmode="decimal"
                        aria-invalid={fieldError() ? "true" : undefined}
                        value={draft()}
                        disabled={locked()}
                        onInput={e => {
                          setBudgetEdited(true);
                          setDraft(e.currentTarget.value);
                          setFieldError(null);
                        }}
                      />
                      <button type="button" class="s-btn primary" disabled={locked() || !budgetDirty()} onClick={save}>
                        {busy() && budgetDirty() ? "Saving…" : "Save budget"}
                      </button>
                    </form>
                  </SettingsRow>
                </Show>
                <Show when={fieldError()}>
                  <div class="ms-card-notice">
                    <p class="field-error" role="alert">{fieldError()}</p>
                  </div>
                </Show>
                <ErrorToast error={saveError()} title="Budget not saved" onDismiss={() => setSaveError(null)} action={retry() ? { label: "Retry", run: () => retry()!() } : undefined} />
                <Show when={v().pool}>
                  {pool => (
                    <div class="ms-pool-block">
                      <OutcomeBar
                        label="Budget allocation"
                        format={money}
                        segments={[
                          { key: "client", label: "Spent", value: Math.max(0, pool().spent_usd) },
                          { key: "limited", label: "Reserved", value: Math.max(0, pool().reserved_usd) },
                          { key: "timeout", label: "Sub-budgets", value: Math.max(0, pool().carved_usd) },
                          { key: "ok", label: "Remaining", value: Math.max(0, pool().available_usd) },
                        ]}
                      />
                      <Legend items={BUDGET_LEGEND} />
                      <dl class="ms-stats">
                        <div>
                          <dt>
                            {pool().reset_period === "daily"
                              ? "Spent today"
                              : pool().reset_period === "weekly"
                                ? "Spent this week"
                                : "Spent"}
                          </dt>
                          <dd>{money(pool().spent_usd)}</dd>
                        </div>
                        <div><dt>Reserved</dt><dd>{money(pool().reserved_usd)}</dd></div>
                        <div><dt>Sub-budgets</dt><dd>{money(pool().carved_usd)}</dd></div>
                        <div>
                          <dt>Remaining</dt>
                          <dd data-low={pool().available_usd < pool().budget_usd * 0.1 ? "" : undefined}>
                            {money(Math.max(0, pool().available_usd))} of {money(pool().budget_usd)}
                          </dd>
                        </div>
                      </dl>
                      <p class="ms-hint">
                        Reserved holds up to 60 minutes of each running machine; machines extend in 30 minute steps while busy, within the budget.
                        <Show when={pool().reset_period && pool().reset_period !== "total"}>
                          {` Lifetime direct spend: ${money(pool().lifetime_spent_usd ?? pool().spent_usd)}${forecast().resetsInSecs != null ? ` · resets in ${formatDurationEta(forecast().resetsInSecs!)}` : ""}.`}
                        </Show>
                      </p>
                    </div>
                  )}
                </Show>
              </SettingsCard>

              <SettingsCard title="Bandwidth &amp; pacing">
                <SettingsRow
                  title="Bandwidth limit"
                  desc={
                    <div class="ms-mode-row">
                      <span>{bandwidthModeLine(v(), v().bandwidth_pool_id ? p.titleOf?.(v().bandwidth_pool_id!) : undefined)}</span>
                      <Show when={v().effective_bandwidth?.source === "mission"}>
                        {(() => {
                          const eff = () => v().effective_bandwidth!;
                          const summary = () => bandwidthLimitsSummary({
                            tokens_per_min: eff().tokens_per_min,
                            inference_usd_per_hour: eff().inference_usd_per_hour,
                            compute_vcpu_per_min: eff().compute_vcpu_per_min,
                            compute_usd_per_hour: eff().compute_usd_per_hour,
                          });
                          return (
                            <div class="ms-cap-pills">
                              <Show when={summary()}>
                                <span class="st-pill" data-tone={eff().pacing_active ? "warning" : undefined}>
                                  <span>{summary()}</span>
                                </span>
                              </Show>
                              <Show when={eff().pacing_active}>
                                <span class="st-pill" data-tone="warning">
                                  <span>Pacing (+{Math.max(1, Math.round(eff().paced_delay_ms / 100) / 10)}s)</span>
                                </span>
                              </Show>
                            </div>
                          );
                        })()}
                      </Show>
                    </div>
                  }
                >
                  <button
                    type="button"
                    class={`toggle ${bandwidthEnabled() ? "on" : ""}`}
                    role="switch"
                    aria-checked={bandwidthEnabled()}
                    aria-label="Bandwidth limit"
                    disabled={locked()}
                    onClick={toggleBandwidth}
                  />
                </SettingsRow>
                <Show when={bandwidthEnabled()}>
                  <SettingsRow
                    title={<label for="ms-bw-tpm">Tokens per minute</label>}
                    desc={
                      v().effective_bandwidth?.ancestor_tokens_per_min != null
                        ? `Up to ${formatTokensPerMin(v().effective_bandwidth!.ancestor_tokens_per_min!)} within the parent pool. Paces bursts smoothly.`
                        : "Inference throughput ceiling (e.g. 120k or 1.5M). Bursts pace smoothly instead of failing."
                    }
                  >
                    <input
                      id="ms-bw-tpm"
                      aria-label="Tokens per minute"
                      class="s-input ms-num-input"
                      autocapitalize="off"
                      autocorrect="off"
                      spellcheck={false}
                      placeholder="120000"
                      value={bwTokensDraft()}
                      disabled={locked()}
                      onInput={e => {
                        setBwEdited(true);
                        setBwTokensDraft(e.currentTarget.value);
                        setBwFieldError(null);
                      }}
                      onKeyDown={e => e.key === "Enter" && saveBandwidth()}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title={<label for="ms-bw-inf-usdh">Inference burn ceiling ($/h)</label>}
                    desc={
                      v().effective_bandwidth?.ancestor_inference_usd_per_hour != null
                        ? `Up to ${money(v().effective_bandwidth!.ancestor_inference_usd_per_hour!)}/h within the parent pool.`
                        : "Caps hourly LLM spend rate across model calls; bursts pace smoothly instead of failing."
                    }
                  >
                    <input
                      id="ms-bw-inf-usdh"
                      aria-label="Inference burn ceiling ($/h)"
                      class="s-input ms-num-input"
                      inputmode="decimal"
                      placeholder="Optional"
                      value={bwInfUsdHDraft()}
                      disabled={locked()}
                      onInput={e => {
                        setBwEdited(true);
                        setBwInfUsdHDraft(e.currentTarget.value);
                        setBwFieldError(null);
                      }}
                      onKeyDown={e => e.key === "Enter" && saveBandwidth()}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title={<label for="ms-bw-vcpu">Compute per minute (vCPU)</label>}
                    desc={
                      v().effective_bandwidth?.ancestor_compute_vcpu_per_min != null
                        ? `Up to ${v().effective_bandwidth!.ancestor_compute_vcpu_per_min} vCPU/min within the parent pool.`
                        : "Active managed-machine vCPU/min ceiling; new spawns queue briefly when saturated."
                    }
                  >
                    <input
                      id="ms-bw-vcpu"
                      aria-label="Compute per minute (vCPU)"
                      class="s-input ms-num-input"
                      inputmode="numeric"
                      placeholder="Optional"
                      value={bwVcpuDraft()}
                      disabled={locked()}
                      onInput={e => {
                        setBwEdited(true);
                        setBwVcpuDraft(e.currentTarget.value);
                        setBwFieldError(null);
                      }}
                      onKeyDown={e => e.key === "Enter" && saveBandwidth()}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title={<label for="ms-bw-usdh">Compute burn ceiling ($/h)</label>}
                    desc={
                      v().effective_bandwidth?.ancestor_compute_usd_per_hour != null
                        ? `Up to ${money(v().effective_bandwidth!.ancestor_compute_usd_per_hour!)}/h within the parent pool.`
                        : "Caps hourly managed-VM spend rate to stretch budget runway."
                    }
                  >
                    <input
                      id="ms-bw-usdh"
                      aria-label="Compute burn ceiling ($/h)"
                      class="s-input ms-num-input"
                      inputmode="decimal"
                      placeholder="Optional"
                      value={bwUsdHDraft()}
                      disabled={locked()}
                      onInput={e => {
                        setBwEdited(true);
                        setBwUsdHDraft(e.currentTarget.value);
                        setBwFieldError(null);
                      }}
                      onKeyDown={e => e.key === "Enter" && saveBandwidth()}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title="Prioritize root agent"
                    desc="Keep this agent unthrottled while pooled subagents absorb pacing delays first."
                  >
                    <button
                      type="button"
                      class={`toggle ${bwProtectRoot() ? "on" : ""}`}
                      role="switch"
                      aria-checked={bwProtectRoot()}
                      aria-label="Prioritize root agent"
                      disabled={locked()}
                      onClick={() => {
                        setBwEdited(true);
                        setBwProtectRoot(x => !x);
                      }}
                    />
                  </SettingsRow>
                  <div class="ms-card-actions">
                    <Show when={bwFieldError()}>
                      <p class="field-error" role="alert">{bwFieldError()}</p>
                    </Show>
                    <button type="button" class="s-btn primary" disabled={locked() || !bandwidthDirty()} onClick={saveBandwidth}>
                      {busy() && bandwidthDirty() ? "Saving…" : "Save bandwidth"}
                    </button>
                  </div>
                </Show>
                <Show when={!bandwidthEnabled() && bwFieldError()}>
                  <div class="ms-card-notice">
                    <p class="field-error" role="alert">{bwFieldError()}</p>
                  </div>
                </Show>
                <ErrorToast error={bwSaveError()} title="Bandwidth limit not saved" onDismiss={() => setBwSaveError(null)} action={bwRetry() ? { label: "Retry", run: () => bwRetry()!() } : undefined} />
              </SettingsCard>

              <SettingsCard title="Machine concurrency">
                <SettingsRow
                  title="Machine limit"
                  desc={
                    <div class="ms-mode-row">
                      <span>{vmLimitsModeLine(v(), v().vm_limits_pool_id ? p.titleOf?.(v().vm_limits_pool_id!) : undefined)}</span>
                      <Show when={v().effective_vm_limits?.source === "mission"}>
                        {(() => {
                          const eff = () => v().effective_vm_limits!;
                          return (
                            <div class="ms-cap-pills">
                              <Show when={eff().max_concurrent != null}>
                                <span class="st-pill" data-tone={eff().active >= eff().max_concurrent! ? "warning" : undefined}>
                                  <span>{eff().active} of {eff().max_concurrent} running</span>
                                </span>
                              </Show>
                              <For each={eff().provider_limits}>
                                {pl => (
                                  <span class="st-pill" data-tone={pl.active >= pl.max_concurrent ? "warning" : undefined}>
                                    <span>{managedProviderLabel(pl.provider)}: {pl.max_concurrent === 0 ? "disabled" : `${pl.active} of ${pl.max_concurrent}`}</span>
                                  </span>
                                )}
                              </For>
                            </div>
                          );
                        })()}
                      </Show>
                    </div>
                  }
                >
                  <button
                    type="button"
                    class={`toggle ${vmLimitsEnabled() ? "on" : ""}`}
                    role="switch"
                    aria-checked={vmLimitsEnabled()}
                    aria-label="Machine limit"
                    disabled={locked()}
                    onClick={toggleVmLimits}
                  />
                </SettingsRow>
                <Show when={vmLimitsEnabled()}>
                  <SettingsRow
                    title={<label for="ms-vm-max">Max concurrent machines</label>}
                    desc={
                      v().effective_vm_limits?.ancestor_max_concurrent != null
                        ? `Up to ${v().effective_vm_limits!.ancestor_max_concurrent} within the parent pool.`
                        : "Across all providers. Leave blank to override specific providers only."
                    }
                  >
                    <form
                      class="ms-inline-ctrl"
                      onSubmit={e => {
                        e.preventDefault();
                        saveLimits();
                      }}
                    >
                      <input
                        id="ms-vm-max"
                        aria-label="Max concurrent machines"
                        class="s-input ms-num-input"
                        inputmode="numeric"
                        placeholder={hasAnyProviderDraft() ? "Any" : "4"}
                        value={maxDraft()}
                        disabled={locked()}
                        onInput={e => {
                          setVmEdited(true);
                          setMaxDraft(e.currentTarget.value);
                          setLimitFieldError(null);
                        }}
                      />
                      <button type="button" class="s-btn primary" disabled={locked() || !vmLimitsDirty()} onClick={saveLimits}>
                        {busy() && vmLimitsDirty() ? "Saving…" : "Save limit"}
                      </button>
                    </form>
                  </SettingsRow>
                  <div class="ms-card-disclosure">
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
                      <span class="ms-disclosure-meta">
                        {draftProviderSummary() || providerLimitsSummary(v().own_vm_limits) || "Optional"}
                      </span>
                    </button>
                    <Show when={providersOpen()}>
                      <div class="ms-provider-body">
                        <div class="ms-provider-grid">
                          <For each={MANAGED_PROVIDERS}>
                            {prov => (
                              <label class="ms-provider-field">
                                <span class="ms-provider-label">{prov.label}</span>
                                <input
                                  class="s-input"
                                  inputmode="numeric"
                                  placeholder="Any"
                                  aria-label={`${prov.label} limit`}
                                  value={provDrafts()[prov.id] ?? ""}
                                  disabled={locked()}
                                  onInput={e => {
                                    const val = e.currentTarget.value;
                                    setVmEdited(true);
                                    setProvDrafts(prev => ({ ...prev, [prov.id]: val }));
                                    setLimitFieldError(null);
                                  }}
                                  onKeyDown={e => e.key === "Enter" && saveLimits()}
                                />
                              </label>
                            )}
                          </For>
                        </div>
                        <p class="ms-hint">
                          Leave blank to share the mission limit (or the global cap if max concurrent is blank). Enter 0 to block a provider.
                        </p>
                      </div>
                    </Show>
                  </div>
                </Show>
                <Show when={limitFieldError()}>
                  <div class="ms-card-notice">
                    <p class="field-error" role="alert">{limitFieldError()}</p>
                  </div>
                </Show>
                <ErrorToast error={limitSaveError()} title="Machine limit not saved" onDismiss={() => setLimitSaveError(null)} action={limitRetry() ? { label: "Retry", run: () => limitRetry()!() } : undefined} />
              </SettingsCard>

              <Show when={showSubagentPoolTable(v())}>
                <section class="s-sec" aria-labelledby="ms-subagents-title">
                  <h3 id="ms-subagents-title">Subagent pools</h3>
                  <BreakdownTable
                    label="Subagent budgets"
                    columns={subagentColumns}
                    rows={v().children}
                    rowKey={c => c.mission_id}
                    limit={6}
                    collapse={c => c.mode === "pooled" && !c.has_vm_limits && !c.has_bandwidth_limits && c.spent_usd === 0 && c.reserved_usd === 0}
                    collapsedLabel="pooled with $0 spend"
                    maxHeight="240px"
                  />
                </section>
              </Show>
            </>
          )}
        </Show>

        <MissionStatsSection missionId={p.missionId} titleOf={p.titleOf} load={p.loadStats} />
      </div>
    </div>
  );
}
