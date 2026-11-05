import { api, type MissionResourcesResponse } from "./api";

export type BudgetResetPeriod = "total" | "daily" | "weekly";

/** One pool's derived usage (`crate::managed::budget::PoolUsage`). */
export type PoolUsage = {
  pool_id: string;
  budget_usd: number;
  spent_usd: number;
  lifetime_spent_usd?: number;
  reserved_usd: number;
  carved_usd: number;
  available_usd: number;
  live_machines: number;
  reset_period?: BudgetResetPeriod;
  period_started_at?: string | null;
  period_resets_at?: string | null;
};

export const MANAGED_PROVIDERS = [
  { id: "boat", label: "boat.dev" },
  { id: "boost", label: "boost.ci" },
  { id: "hetzner", label: "Hetzner" },
  { id: "vastai", label: "Vast.ai" },
  { id: "scaleway", label: "Scaleway" },
  { id: "colab", label: "Google Colab" },
] as const;

export type ManagedProviderId = (typeof MANAGED_PROVIDERS)[number]["id"];

export const MAX_VM_CONCURRENCY = 128;
export const MIN_TOKENS_PER_MIN = 1_000;
export const MAX_TOKENS_PER_MIN = 100_000_000;
export const MIN_INFERENCE_USD_PER_HOUR = 0.01;
export const MAX_INFERENCE_USD_PER_HOUR = 10_000;
export const MAX_COMPUTE_VCPU_PER_MIN = 4_096;
export const MIN_COMPUTE_USD_PER_HOUR = 0.01;
export const MAX_COMPUTE_USD_PER_HOUR = 10_000;

export type VmConcurrencyLimits = {
  max_concurrent?: number | null;
  provider_max_concurrent?: Record<string, number>;
};

export type ProviderCapUsage = {
  provider: string;
  active: number;
  max_concurrent: number;
};

export type EffectiveVmLimits = {
  source: "mission" | "global";
  pool_id: string | null;
  active: number;
  max_concurrent: number | null;
  global_active: number;
  global_max_concurrent: number | null;
  ancestor_max_concurrent: number | null;
  provider_limits: ProviderCapUsage[];
};

export type BandwidthLimits = {
  tokens_per_min?: number | null;
  inference_usd_per_hour?: number | null;
  compute_vcpu_per_min?: number | null;
  compute_usd_per_hour?: number | null;
  protect_root?: boolean;
};

export type EffectiveBandwidth = {
  source: "mission" | "none";
  pool_id: string | null;
  tokens_per_min: number | null;
  inference_usd_per_hour?: number | null;
  compute_vcpu_per_min: number | null;
  compute_usd_per_hour: number | null;
  protect_root: boolean;
  current_tokens_per_min: number;
  current_inference_usd_per_hour?: number;
  current_vcpu_per_min: number;
  current_compute_usd_per_hour: number;
  pacing_active: boolean;
  paced_delay_ms: number;
  ancestor_tokens_per_min: number | null;
  ancestor_inference_usd_per_hour?: number | null;
  ancestor_compute_vcpu_per_min: number | null;
  ancestor_compute_usd_per_hour: number | null;
};

export type ChildBudget = {
  mission_id: string;
  mode: "pooled" | "sub_budget";
  budget_usd: number | null;
  spent_usd: number;
  reserved_usd: number;
  has_vm_limits?: boolean;
  vm_max_concurrent?: number | null;
  has_bandwidth_limits?: boolean;
  tokens_per_min?: number | null;
  live_machines?: number;
};

/** `GET /api/control/missions/:id/budget`. */
export type MissionBudget = {
  mission_id: string;
  own_budget_usd: number | null;
  own_budget_reset_period?: BudgetResetPeriod;
  pool_id: string | null;
  mode: "own" | "pooled" | "none";
  pool: PoolUsage | null;
  max_grant_usd: number | null;
  own_vm_limits?: VmConcurrencyLimits | null;
  vm_limits_mode?: "own" | "pooled" | "global";
  vm_limits_pool_id?: string | null;
  effective_vm_limits?: EffectiveVmLimits;
  own_bandwidth_limits?: BandwidthLimits | null;
  bandwidth_mode?: "own" | "pooled" | "none";
  bandwidth_pool_id?: string | null;
  effective_bandwidth?: EffectiveBandwidth;
  children: ChildBudget[];
};

export const getMissionBudget = (id: string) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, { method: "GET" });

export const putMissionBudget = (
  id: string,
  budget_usd: number | null,
  budget_reset_period?: BudgetResetPeriod,
) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      budget_usd != null && budget_reset_period != null
        ? { budget_usd, budget_reset_period }
        : { budget_usd },
    ),
  });

export const putMissionVmLimits = (id: string, vm_limits: VmConcurrencyLimits | null) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ vm_limits }),
  });

export const putMissionBandwidthLimits = (id: string, bandwidth_limits: BandwidthLimits | null) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ bandwidth_limits }),
  });

export const money = (v: number) => `$${v < 10 ? v.toFixed(2) : v.toFixed(0)}`;

export const formatTokensPerMin = (v: number): string => {
  if (v >= 1_000_000) {
    const m = v / 1_000_000;
    return `${Number.isInteger(m) ? m.toFixed(0) : m.toFixed(1)}M tok/min`;
  }
  if (v >= 1_000) {
    const k = v / 1_000;
    return `${Number.isInteger(k) ? k.toFixed(0) : k.toFixed(1)}k tok/min`;
  }
  return `${Math.round(v)} tok/min`;
};

export const formatDurationEta = (secs: number): string => {
  if (!Number.isFinite(secs) || secs <= 0) return "0m";
  if (secs < 60) return "<1m";
  const totalMins = Math.round(secs / 60);
  if (totalMins < 60) return `~${totalMins}m`;
  const hours = Math.floor(totalMins / 60);
  const mins = totalMins % 60;
  if (hours < 48) return mins > 0 ? `~${hours}h ${mins}m` : `~${hours}h`;
  const days = Math.floor(hours / 24);
  const remHours = hours % 24;
  return remHours > 0 ? `~${days}d ${remHours}h` : `~${days}d`;
};

export const managedProviderLabel = (id: string) =>
  MANAGED_PROVIDERS.find(p => p.id === id)?.label ?? id;

/** Parse the amount field: a positive number of dollars, or an error. */
export function parseAmount(raw: string): { value: number } | { error: string } {
  const text = raw.trim().replace(/^\$/, "");
  if (!text) return { error: "Enter an amount in dollars" };
  const value = Number(text);
  if (!Number.isFinite(value) || value <= 0) return { error: "Enter a positive amount" };
  if (value > 100000) return { error: "At most $100000" };
  return { value: Math.round(value * 10000) / 10000 };
}

/** Is `amount` above what the parent pool can grant (sub-budgets only)? */
export function exceedsGrant(view: MissionBudget, amount: number): string | null {
  if (view.max_grant_usd == null || amount <= view.max_grant_usd + 1e-9) return null;
  return `The parent pool has ${money(view.max_grant_usd)} left to grant`;
}

function parseWholeInt(raw: string, min: number, max: number, label: string): { value: number } | { error: string } {
  if (!/^\d+$/.test(raw)) return { error: `${label} must be a whole number` };
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    return { error: `${label} must be between ${min} and ${max}` };
  }
  return { value };
}

function parseTokenRateInput(raw: string): { value: number } | { error: string } {
  const cleaned = raw.trim().replace(/,/g, "").replace(/_/g, "");
  const m = /^(\d+(?:\.\d+)?)\s*([kKmM])?$/.exec(cleaned);
  if (!m) return { error: "Tokens per minute must be a number (for example 120000 or 120k)" };
  const mult = m[2]?.toLowerCase() === "m" ? 1_000_000 : m[2]?.toLowerCase() === "k" ? 1_000 : 1;
  const value = Math.round(Number(m[1]) * mult);
  if (!Number.isFinite(value) || value < MIN_TOKENS_PER_MIN || value > MAX_TOKENS_PER_MIN) {
    return { error: `Tokens per minute must be between ${MIN_TOKENS_PER_MIN.toLocaleString()} and ${MAX_TOKENS_PER_MIN.toLocaleString()}` };
  }
  return { value };
}

/** Parse total + per-provider concurrency inputs into `VmConcurrencyLimits`. */
export function parseVmLimits(
  totalRaw: string,
  providerRaws: Record<string, string>,
  view?: MissionBudget,
): { value: VmConcurrencyLimits } | { error: string } {
  const ancestorMax = view?.effective_vm_limits?.ancestor_max_concurrent ?? null;
  const totalTrimmed = totalRaw.trim();
  let max_concurrent: number | null = null;
  if (totalTrimmed) {
    const parsed = parseWholeInt(totalTrimmed, 1, MAX_VM_CONCURRENCY, "Max concurrent");
    if ("error" in parsed) return parsed;
    if (ancestorMax != null && parsed.value > ancestorMax) {
      return { error: `The parent agent limits concurrent machines to ${ancestorMax}` };
    }
    max_concurrent = parsed.value;
  }
  const provider_max_concurrent: Record<string, number> = {};
  for (const p of MANAGED_PROVIDERS) {
    const text = (providerRaws[p.id] ?? "").trim();
    if (!text) continue;
    const parsed = parseWholeInt(text, 0, MAX_VM_CONCURRENCY, p.label);
    if ("error" in parsed) return parsed;
    if (max_concurrent != null && parsed.value > max_concurrent) {
      return { error: `${p.label} limit (${parsed.value}) cannot exceed max concurrent (${max_concurrent})` };
    }
    if (ancestorMax != null && parsed.value > ancestorMax) {
      return { error: `${p.label} limit (${parsed.value}) cannot exceed the parent limit (${ancestorMax})` };
    }
    provider_max_concurrent[p.id] = parsed.value;
  }
  if (max_concurrent == null && Object.keys(provider_max_concurrent).length === 0) {
    return { error: "Enter a max concurrent limit or at least one provider limit" };
  }
  return { value: { max_concurrent, provider_max_concurrent } };
}

/** Parse inference & compute bandwidth inputs into `BandwidthLimits`. */
export function parseBandwidthLimits(
  tokensPerMinRaw: string,
  computeVcpuRaw: string,
  computeUsdPerHRaw: string,
  protectRoot: boolean,
  view?: MissionBudget,
  inferenceUsdPerHRaw: string = "",
): { value: BandwidthLimits } | { error: string } {
  const eff = view?.effective_bandwidth;
  const ancTpm = eff?.ancestor_tokens_per_min ?? null;
  const ancInfUsdH = eff?.ancestor_inference_usd_per_hour ?? null;
  const ancVcpu = eff?.ancestor_compute_vcpu_per_min ?? null;
  const ancUsdH = eff?.ancestor_compute_usd_per_hour ?? null;

  let tokens_per_min: number | null = null;
  if (tokensPerMinRaw.trim()) {
    const parsed = parseTokenRateInput(tokensPerMinRaw);
    if ("error" in parsed) return parsed;
    if (ancTpm != null && parsed.value > ancTpm) {
      return { error: `Tokens per minute cannot exceed the parent pool (${formatTokensPerMin(ancTpm)})` };
    }
    tokens_per_min = parsed.value;
  }

  let inference_usd_per_hour: number | null = null;
  const infUsdTrim = inferenceUsdPerHRaw.trim().replace(/^\$/, "");
  if (infUsdTrim) {
    const num = Number(infUsdTrim);
    if (!Number.isFinite(num) || num < MIN_INFERENCE_USD_PER_HOUR || num > MAX_INFERENCE_USD_PER_HOUR) {
      return { error: `Inference burn ceiling must be between $${MIN_INFERENCE_USD_PER_HOUR} and $${MAX_INFERENCE_USD_PER_HOUR}/h` };
    }
    const rounded = Math.round(num * 10000) / 10000;
    if (ancInfUsdH != null && rounded > ancInfUsdH + 1e-9) {
      return { error: `Inference burn ceiling cannot exceed the parent pool (${money(ancInfUsdH)}/h)` };
    }
    inference_usd_per_hour = rounded;
  }

  let compute_vcpu_per_min: number | null = null;
  if (computeVcpuRaw.trim()) {
    const parsed = parseWholeInt(computeVcpuRaw.trim(), 1, MAX_COMPUTE_VCPU_PER_MIN, "Compute vCPU/min");
    if ("error" in parsed) return parsed;
    if (ancVcpu != null && parsed.value > ancVcpu) {
      return { error: `Compute vCPU/min cannot exceed the parent pool (${ancVcpu} vCPU/min)` };
    }
    compute_vcpu_per_min = parsed.value;
  }

  let compute_usd_per_hour: number | null = null;
  const usdTrim = computeUsdPerHRaw.trim().replace(/^\$/, "");
  if (usdTrim) {
    const num = Number(usdTrim);
    if (!Number.isFinite(num) || num < MIN_COMPUTE_USD_PER_HOUR || num > MAX_COMPUTE_USD_PER_HOUR) {
      return { error: `Compute burn ceiling must be between $${MIN_COMPUTE_USD_PER_HOUR} and $${MAX_COMPUTE_USD_PER_HOUR}/h` };
    }
    const rounded = Math.round(num * 10000) / 10000;
    if (ancUsdH != null && rounded > ancUsdH + 1e-9) {
      return { error: `Compute burn ceiling cannot exceed the parent pool (${money(ancUsdH)}/h)` };
    }
    compute_usd_per_hour = rounded;
  }

  if (
    tokens_per_min == null &&
    inference_usd_per_hour == null &&
    compute_vcpu_per_min == null &&
    compute_usd_per_hour == null
  ) {
    return { error: "Enter at least one bandwidth limit (tokens/min, LLM $/h, vCPU/min, or VM $/h)" };
  }

  return {
    value: {
      tokens_per_min,
      inference_usd_per_hour,
      compute_vcpu_per_min,
      compute_usd_per_hour,
      protect_root: protectRoot,
    },
  };
}

export function normalizeVmLimits(limits: VmConcurrencyLimits | null | undefined): string {
  if (!limits) return "null";
  const provEntries = MANAGED_PROVIDERS
    .map(p => [p.id, limits.provider_max_concurrent?.[p.id]] as const)
    .filter(([, v]) => v != null);
  return JSON.stringify({ m: limits.max_concurrent ?? null, p: provEntries });
}

export function normalizeBandwidthLimits(limits: BandwidthLimits | null | undefined): string {
  if (!limits) return "null";
  if (
    limits.tokens_per_min == null &&
    limits.inference_usd_per_hour == null &&
    limits.compute_vcpu_per_min == null &&
    limits.compute_usd_per_hour == null
  ) {
    return "null";
  }
  return JSON.stringify({
    t: limits.tokens_per_min ?? null,
    i: limits.inference_usd_per_hour != null ? Math.round(limits.inference_usd_per_hour * 10000) / 10000 : null,
    v: limits.compute_vcpu_per_min ?? null,
    u: limits.compute_usd_per_hour != null ? Math.round(limits.compute_usd_per_hour * 10000) / 10000 : null,
    p: Boolean(limits.protect_root),
  });
}

/**
 * What the sheet shows right after a budget change, before the server answers
 * (optimistic). Usage numbers stay as they were; only ownership changes.
 */
export function optimisticBudget(
  view: MissionBudget,
  amount: number | null,
  resetPeriod?: BudgetResetPeriod,
): MissionBudget {
  if (amount == null) {
    const inherited = view.mode === "own" && view.max_grant_usd != null;
    // The parent's pool numbers arrive with the server's answer.
    return {
      ...view,
      own_budget_usd: null,
      own_budget_reset_period: "total",
      mode: inherited ? "pooled" : "none",
      pool: null,
      pool_id: null,
    };
  }
  const effectivePeriod: BudgetResetPeriod =
    view.max_grant_usd != null
      ? "total"
      : (resetPeriod ?? view.own_budget_reset_period ?? view.pool?.reset_period ?? "total");
  const pool: PoolUsage = view.pool && view.mode === "own"
    ? {
        ...view.pool,
        budget_usd: amount,
        available_usd: view.pool.available_usd + (amount - view.pool.budget_usd),
        reset_period: effectivePeriod,
      }
    : {
        pool_id: view.mission_id,
        budget_usd: amount,
        spent_usd: 0,
        lifetime_spent_usd: 0,
        reserved_usd: 0,
        carved_usd: 0,
        available_usd: amount,
        live_machines: 0,
        reset_period: effectivePeriod,
      };
  return {
    ...view,
    own_budget_usd: amount,
    own_budget_reset_period: effectivePeriod,
    mode: "own",
    pool_id: view.mission_id,
    pool,
  };
}

/** Optimistic projection right after a machine-limit change. */
export function optimisticVmLimits(view: MissionBudget, limits: VmConcurrencyLimits | null): MissionBudget {
  const prev = view.effective_vm_limits;
  const globalActive = prev?.global_active ?? 0;
  const globalMax = prev?.global_max_concurrent ?? null;
  const ancestorMax = prev?.ancestor_max_concurrent ?? null;
  if (limits == null) {
    const inherited = view.vm_limits_mode === "own" && ancestorMax != null;
    return {
      ...view,
      own_vm_limits: null,
      vm_limits_mode: inherited ? "pooled" : "global",
      vm_limits_pool_id: null,
      effective_vm_limits: {
        source: inherited ? "mission" : "global",
        pool_id: null,
        active: globalActive,
        max_concurrent: inherited ? ancestorMax : globalMax,
        global_active: globalActive,
        global_max_concurrent: globalMax,
        ancestor_max_concurrent: ancestorMax,
        provider_limits: [],
      },
    };
  }
  const active = prev?.source === "mission" ? prev.active : 0;
  const provMap = limits.provider_max_concurrent ?? {};
  const provider_limits: ProviderCapUsage[] = MANAGED_PROVIDERS
    .filter(p => provMap[p.id] != null)
    .map(p => ({
      provider: p.id,
      active: prev?.provider_limits.find(x => x.provider === p.id)?.active ?? 0,
      max_concurrent: provMap[p.id]!,
    }));
  const maxC = limits.max_concurrent != null && ancestorMax != null
    ? Math.min(limits.max_concurrent, ancestorMax)
    : (limits.max_concurrent ?? ancestorMax);
  return {
    ...view,
    own_vm_limits: limits,
    vm_limits_mode: "own",
    vm_limits_pool_id: view.mission_id,
    effective_vm_limits: {
      source: "mission",
      pool_id: view.mission_id,
      active,
      max_concurrent: maxC,
      global_active: globalActive,
      global_max_concurrent: globalMax,
      ancestor_max_concurrent: ancestorMax,
      provider_limits,
    },
  };
}

/** Optimistic projection right after a bandwidth-limit change. */
export function optimisticBandwidthLimits(view: MissionBudget, limits: BandwidthLimits | null): MissionBudget {
  const prev = view.effective_bandwidth;
  const ancTpm = prev?.ancestor_tokens_per_min ?? null;
  const ancInfUsdH = prev?.ancestor_inference_usd_per_hour ?? null;
  const ancVcpu = prev?.ancestor_compute_vcpu_per_min ?? null;
  const ancUsdH = prev?.ancestor_compute_usd_per_hour ?? null;
  const curTpm = prev?.current_tokens_per_min ?? 0;
  const curInfUsdH = prev?.current_inference_usd_per_hour ?? 0;
  const curVcpu = prev?.current_vcpu_per_min ?? 0;
  const curUsdH = prev?.current_compute_usd_per_hour ?? 0;

  if (limits == null) {
    const inherited =
      view.bandwidth_mode === "own" &&
      (ancTpm != null || ancInfUsdH != null || ancVcpu != null || ancUsdH != null);
    return {
      ...view,
      own_bandwidth_limits: null,
      bandwidth_mode: inherited ? "pooled" : "none",
      bandwidth_pool_id: null,
      effective_bandwidth: {
        source: inherited ? "mission" : "none",
        pool_id: null,
        tokens_per_min: ancTpm,
        inference_usd_per_hour: ancInfUsdH,
        compute_vcpu_per_min: ancVcpu,
        compute_usd_per_hour: ancUsdH,
        protect_root: false,
        current_tokens_per_min: curTpm,
        current_inference_usd_per_hour: curInfUsdH,
        current_vcpu_per_min: curVcpu,
        current_compute_usd_per_hour: curUsdH,
        pacing_active: false,
        paced_delay_ms: 0,
        ancestor_tokens_per_min: ancTpm,
        ancestor_inference_usd_per_hour: ancInfUsdH,
        ancestor_compute_vcpu_per_min: ancVcpu,
        ancestor_compute_usd_per_hour: ancUsdH,
      },
    };
  }

  const effTpm = limits.tokens_per_min != null && ancTpm != null
    ? Math.min(limits.tokens_per_min, ancTpm)
    : (limits.tokens_per_min ?? ancTpm);
  const effInfUsdH = limits.inference_usd_per_hour != null && ancInfUsdH != null
    ? Math.min(limits.inference_usd_per_hour, ancInfUsdH)
    : (limits.inference_usd_per_hour ?? ancInfUsdH);
  const effVcpu = limits.compute_vcpu_per_min != null && ancVcpu != null
    ? Math.min(limits.compute_vcpu_per_min, ancVcpu)
    : (limits.compute_vcpu_per_min ?? ancVcpu);
  const effUsdH = limits.compute_usd_per_hour != null && ancUsdH != null
    ? Math.min(limits.compute_usd_per_hour, ancUsdH)
    : (limits.compute_usd_per_hour ?? ancUsdH);

  return {
    ...view,
    own_bandwidth_limits: limits,
    bandwidth_mode: "own",
    bandwidth_pool_id: view.mission_id,
    effective_bandwidth: {
      source: "mission",
      pool_id: view.mission_id,
      tokens_per_min: effTpm,
      inference_usd_per_hour: effInfUsdH,
      compute_vcpu_per_min: effVcpu,
      compute_usd_per_hour: effUsdH,
      protect_root: Boolean(limits.protect_root),
      current_tokens_per_min: curTpm,
      current_inference_usd_per_hour: curInfUsdH,
      current_vcpu_per_min: curVcpu,
      current_compute_usd_per_hour: curUsdH,
      pacing_active: prev?.pacing_active ?? false,
      paced_delay_ms: prev?.paced_delay_ms ?? 0,
      ancestor_tokens_per_min: ancTpm,
      ancestor_inference_usd_per_hour: ancInfUsdH,
      ancestor_compute_vcpu_per_min: ancVcpu,
      ancestor_compute_usd_per_hour: ancUsdH,
    },
  };
}

/** One line describing where the money comes from. */
export function modeLine(view: MissionBudget, parentTitle?: string): string {
  if (view.mode === "own") {
    if (view.max_grant_usd != null) {
      return "Own sub-budget, carved from the parent's pool. Its subagents share it.";
    }
    const period = view.own_budget_reset_period ?? view.pool?.reset_period ?? "total";
    if (period === "daily") {
      return "Own daily budget (resets 00:00 UTC). Subagents share it unless you give one a sub-budget.";
    }
    if (period === "weekly") {
      return "Own weekly budget (resets Mon 00:00 UTC). Subagents share it unless you give one a sub-budget.";
    }
    return "Own budget. Subagents share it unless you give one a sub-budget.";
  }
  if (view.mode === "pooled") return `Shares the pool of ${parentTitle ?? "an ancestor agent"}.`;
  return "No budget. Only the daily managed-machine cap applies.";
}

/** One line describing which concurrency cap governs this mission. */
export function vmLimitsModeLine(view: MissionBudget, parentTitle?: string): string {
  const mode = view.vm_limits_mode ?? "global";
  const eff = view.effective_vm_limits;
  if (mode === "own") {
    return eff?.ancestor_max_concurrent != null
      ? `Own sub-limit within the parent pool (up to ${eff.ancestor_max_concurrent} concurrent).`
      : "Dedicated cap for this agent and its subagents (bypasses the global limit).";
  }
  if (mode === "pooled") {
    return `Shares the machine limit of ${parentTitle ?? "an ancestor agent"}.`;
  }
  if (eff?.global_max_concurrent != null) {
    return `Uses the global limit (${eff.global_max_concurrent} concurrent across Orb).`;
  }
  return "Uses the global machine limit.";
}

/** One line describing which bandwidth/pacing policy governs this mission. */
export function bandwidthModeLine(view: MissionBudget, parentTitle?: string): string {
  const mode = view.bandwidth_mode ?? "none";
  if (mode === "own") {
    const prot = view.own_bandwidth_limits?.protect_root;
    return prot
      ? "Smooths bursts by pacing subagent calls and spawns while keeping this root agent unthrottled."
      : "Smooths inference and machine spawn bursts with pace delays instead of hard errors.";
  }
  if (mode === "pooled") {
    return `Shares the bandwidth pace pool of ${parentTitle ?? "an ancestor agent"}.`;
  }
  return "Unthrottled. Requests and spawns run at full speed.";
}

/** Summary chips text for configured per-provider limits ("Vast.ai: 2 · boat.dev: 8"). */
export function providerLimitsSummary(limits: VmConcurrencyLimits | null | undefined): string {
  const map = limits?.provider_max_concurrent;
  if (!map) return "";
  return MANAGED_PROVIDERS
    .filter(p => map[p.id] != null)
    .map(p => `${p.label}: ${map[p.id] === 0 ? "off" : map[p.id]}`)
    .join(" · ");
}

/** Summary string for configured bandwidth limits. */
export function bandwidthLimitsSummary(limits: BandwidthLimits | null | undefined): string {
  if (!limits) return "";
  const parts: string[] = [];
  if (limits.tokens_per_min != null) parts.push(formatTokensPerMin(limits.tokens_per_min));
  if (limits.inference_usd_per_hour != null) parts.push(`${money(limits.inference_usd_per_hour)}/h LLM`);
  if (limits.compute_vcpu_per_min != null) parts.push(`${limits.compute_vcpu_per_min} vCPU/min`);
  if (limits.compute_usd_per_hour != null) parts.push(`${money(limits.compute_usd_per_hour)}/h`);
  return parts.join(" · ");
}

/** Next UTC reset boundary in epoch milliseconds (`00:00Z` daily or ISO Monday `00:00Z` weekly). */
export function nextBudgetResetMs(period: BudgetResetPeriod, nowMs: number = Date.now()): number | null {
  if (period === "total") return null;
  const d = new Date(nowMs);
  const y = d.getUTCFullYear();
  const m = d.getUTCMonth();
  const day = d.getUTCDate();
  if (period === "daily") {
    return Date.UTC(y, m, day + 1, 0, 0, 0, 0);
  }
  const daysSinceMonday = (d.getUTCDay() + 6) % 7;
  return Date.UTC(y, m, day + (7 - daysSinceMonday), 0, 0, 0, 0);
}

/** Fraction of the pool used (spent + reserved + sub-budgets), 0..1. */
export function usedFraction(pool: PoolUsage): number {
  if (pool.budget_usd <= 0) return 1;
  return Math.min(1, Math.max(0, (pool.spent_usd + pool.reserved_usd + pool.carved_usd) / pool.budget_usd));
}

export type RunwayForecast = {
  hasBudget: boolean;
  capUsd: number | null;
  spentUsd: number;
  reservedUsd: number;
  carvedUsd: number;
  availableUsd: number;
  observedComputeBurnUsdPerH: number;
  shapedComputeBurnUsdPerH: number;
  observedInferenceBurnUsdPerH: number;
  shapedInferenceBurnUsdPerH: number;
  currentTokensPerMin: number;
  currentVcpuPerMin: number;
  pacingActive: boolean;
  resetPeriod: BudgetResetPeriod;
  resetsInSecs: number | null;
  sustainsUntilReset: boolean;
  leaseCliffSecs: number | null;
  etaSecs: number | null;
  unshapedEtaSecs: number | null;
  etaGainSecs: number | null;
  missionEtaSecs: number | null;
  exhaustsBeforeMissionEta: boolean;
  tone: "ok" | "warning" | "danger";
  headline: string;
  subline: string;
  chart: {
    width: number;
    height: number;
    padLeft: number;
    padRight: number;
    padTop: number;
    padBottom: number;
    nowX: number;
    nowY: number;
    capY: number | null;
    reservedTopY: number;
    exhaustionX: number | null;
    observedAreaPath: string;
    observedLinePath: string;
    projectedLinePath: string;
    unshapedLinePath: string | null;
  };
};

function latestNonNull(arr: Array<number | null> | undefined): number | null {
  if (!arr) return null;
  for (let i = arr.length - 1; i >= 0; i--) {
    const v = arr[i];
    if (v != null && Number.isFinite(v)) return v;
  }
  return null;
}

/**
 * Pure forecast derivation for the compact Runway & Spend chart at the top of
 * Mission Settings. Reacts live to draft budget and bandwidth edits so the user
 * immediately sees how constraints extend or bound the runway.
 */
export function computeRunwayForecast(opts: {
  budget: MissionBudget | null;
  resources?: MissionResourcesResponse | null;
  draftBudgetUsd?: string;
  draftResetPeriod?: BudgetResetPeriod;
  draftInferenceUsdPerH?: string;
  draftComputeUsdPerH?: string;
  draftComputeVcpu?: string;
  bandwidthEnabled?: boolean;
  budgetEnabled?: boolean;
  nowMs?: number;
}): RunwayForecast {
  const b = opts.budget;
  const pool = b?.pool ?? null;
  const effBw = b?.effective_bandwidth;
  const res = opts.resources ?? null;

  const budgetOn = opts.budgetEnabled ?? (b?.mode === "own" || b?.mode === "pooled");
  let capUsd: number | null = pool?.budget_usd ?? b?.own_budget_usd ?? null;
  if (opts.budgetEnabled && opts.draftBudgetUsd != null) {
    const parsed = parseAmount(opts.draftBudgetUsd);
    if ("value" in parsed) capUsd = parsed.value;
  }
  if (!budgetOn) capUsd = null;

  let resetPeriod: BudgetResetPeriod = "total";
  if (capUsd != null && b?.max_grant_usd == null) {
    if (opts.budgetEnabled && opts.draftResetPeriod != null) {
      resetPeriod = opts.draftResetPeriod;
    } else {
      resetPeriod = pool?.reset_period ?? b?.own_budget_reset_period ?? "total";
    }
  }

  const nowMs = opts.nowMs ?? Date.now();
  let resetsInSecs: number | null = null;
  if (capUsd != null && resetPeriod !== "total") {
    const serverResetMs =
      pool?.reset_period === resetPeriod && pool?.period_resets_at
        ? Date.parse(pool.period_resets_at)
        : NaN;
    const targetMs = Number.isFinite(serverResetMs)
      ? serverResetMs
      : nextBudgetResetMs(resetPeriod, nowMs);
    if (targetMs != null) {
      resetsInSecs = Math.max(0, (targetMs - nowMs) / 1000);
    }
  }

  const spentUsd = pool?.spent_usd ?? 0;
  const reservedUsd = pool?.reserved_usd ?? 0;
  const carvedUsd = pool?.carved_usd ?? 0;
  const committedPreReserved = spentUsd + carvedUsd;
  const committedTotal = committedPreReserved + reservedUsd;
  const availableUsd = capUsd != null ? Math.max(0, capUsd - committedTotal) : 0;
  // `reservedUsd` holds up to 60 minutes of future runtime for live machines,
  // not incurred spend. Use `runwayUsd` (`cap - spent - carved`) when dividing
  // by live burn so active VM reservations are not counted twice against ETA.
  const runwayUsd = capUsd != null ? Math.max(0, capUsd - committedPreReserved) : 0;

  const timelineObsCompute = latestNonNull(res?.timeline.observed_compute_usd_per_h);
  const observedComputeBurnUsdPerH = Math.max(
    0,
    effBw?.current_compute_usd_per_hour ?? timelineObsCompute ?? 0,
  );
  const observedInferenceBurnUsdPerH = Math.max(
    0,
    effBw?.current_inference_usd_per_hour ?? latestNonNull(res?.timeline.observed_inference_usd_per_h) ?? 0,
  );
  const currentTokensPerMin = effBw?.current_tokens_per_min ?? Math.round(((latestNonNull(res?.timeline.observed_b_tok_per_h) ?? 0) * 1_000_000_000) / 60);
  const currentVcpuPerMin = effBw?.current_vcpu_per_min ?? Math.round(latestNonNull(res?.timeline.observed_vcpu) ?? 0);

  let shapedComputeBurnUsdPerH = observedComputeBurnUsdPerH;
  let shapedInferenceBurnUsdPerH = observedInferenceBurnUsdPerH;
  const bwOn = opts.bandwidthEnabled ?? (effBw?.source === "mission");
  if (bwOn) {
    let infCap = effBw?.inference_usd_per_hour ?? null;
    if (opts.draftInferenceUsdPerH !== undefined) {
      const raw = opts.draftInferenceUsdPerH.trim().replace(/^\$/, "");
      const n = raw ? Number(raw) : NaN;
      infCap = Number.isFinite(n) && n > 0 ? n : null;
    }
    if (infCap != null && shapedInferenceBurnUsdPerH > infCap) {
      shapedInferenceBurnUsdPerH = infCap;
    }
    let usdCap = effBw?.compute_usd_per_hour ?? null;
    if (opts.draftComputeUsdPerH !== undefined) {
      const raw = opts.draftComputeUsdPerH.trim().replace(/^\$/, "");
      const n = raw ? Number(raw) : NaN;
      usdCap = Number.isFinite(n) && n > 0 ? n : null;
    }
    if (usdCap != null && shapedComputeBurnUsdPerH > usdCap) {
      shapedComputeBurnUsdPerH = usdCap;
    }
    let vcpuCap = effBw?.compute_vcpu_per_min ?? null;
    if (opts.draftComputeVcpu !== undefined) {
      const raw = opts.draftComputeVcpu.trim();
      const n = raw && /^\d+$/.test(raw) ? Number(raw) : NaN;
      vcpuCap = Number.isInteger(n) && n > 0 ? n : null;
    }
    if (vcpuCap != null && currentVcpuPerMin > vcpuCap && currentVcpuPerMin > 0) {
      shapedComputeBurnUsdPerH = Math.min(
        shapedComputeBurnUsdPerH,
        observedComputeBurnUsdPerH * (vcpuCap / currentVcpuPerMin),
      );
    }
  }

  const etaSecs =
    capUsd != null && runwayUsd > 0 && shapedComputeBurnUsdPerH > 0.005
      ? (runwayUsd / shapedComputeBurnUsdPerH) * 3600
      : capUsd != null && runwayUsd <= 0
        ? 0
        : null;

  const sustainsUntilReset = Boolean(
    capUsd != null &&
      resetPeriod !== "total" &&
      resetsInSecs != null &&
      runwayUsd > 0 &&
      (etaSecs == null || etaSecs >= resetsInSecs),
  );

  const leaseCliffSecs =
    capUsd != null &&
    runwayUsd > 0 &&
    reservedUsd > 0.005 &&
    shapedComputeBurnUsdPerH > 0.005 &&
    availableUsd < runwayUsd - 0.005
      ? availableUsd <= 0
        ? 0
        : (availableUsd / shapedComputeBurnUsdPerH) * 3600
      : null;

  const unshapedEtaSecs =
    capUsd != null && runwayUsd > 0 && observedComputeBurnUsdPerH > 0.005
      ? (runwayUsd / observedComputeBurnUsdPerH) * 3600
      : null;

  const etaGainSecs =
    etaSecs != null && unshapedEtaSecs != null && etaSecs > unshapedEtaSecs + 120
      ? etaSecs - unshapedEtaSecs
      : null;

  const missionEtaSecs = res?.mission.eta_remaining_secs ?? null;
  const exhaustsBeforeMissionEta =
    !sustainsUntilReset &&
    etaSecs != null &&
    missionEtaSecs != null &&
    missionEtaSecs > 0 &&
    etaSecs < missionEtaSecs;

  let tone: "ok" | "warning" | "danger" = "ok";
  if (capUsd != null) {
    if (runwayUsd <= 0 || (!sustainsUntilReset && etaSecs != null && etaSecs < 1800) || exhaustsBeforeMissionEta) {
      tone = "danger";
    } else if (
      (!sustainsUntilReset && ((etaSecs != null && etaSecs < 7200) || (capUsd > 0 && runwayUsd < capUsd * 0.15))) ||
      (leaseCliffSecs != null && leaseCliffSecs < 3600)
    ) {
      tone = "warning";
    }
  }

  let headline: string;
  let subline: string;
  if (capUsd != null) {
    if (runwayUsd <= 0) {
      headline = "Budget exhausted";
      const parts = [`${money(committedPreReserved)} spent of ${money(capUsd)} pool`];
      if (resetPeriod !== "total" && resetsInSecs != null) {
        parts.push(`resets in ${formatDurationEta(resetsInSecs)}`);
      }
      subline = parts.join(" · ");
    } else if (etaSecs != null) {
      headline = sustainsUntilReset
        ? `Sustains until ${resetPeriod} reset`
        : `${formatDurationEta(etaSecs)} runway left`;
      const parts = [
        `${money(shapedComputeBurnUsdPerH)}/h compute burn`,
        reservedUsd > 0.005
          ? `${money(availableUsd)} unallocated (${money(reservedUsd)} reserved · ${money(capUsd)} cap)`
          : `${money(availableUsd)} left (${money(capUsd)} cap)`,
      ];
      if (resetPeriod !== "total" && resetsInSecs != null) {
        if (sustainsUntilReset) {
          parts.push(`resets in ${formatDurationEta(resetsInSecs)} (${formatDurationEta(etaSecs)} runway)`);
        } else {
          parts.push(`exhausts ${formatDurationEta(resetsInSecs - etaSecs)} before ${resetPeriod} reset`);
        }
      }
      if (leaseCliffSecs != null && leaseCliffSecs < 3600) {
        parts.push(
          leaseCliffSecs <= 0
            ? "VM auto-extensions paused (0 unallocated)"
            : `VM extensions pause in ${formatDurationEta(leaseCliffSecs)}`,
        );
      }
      if (etaGainSecs != null) parts.push(`+${formatDurationEta(etaGainSecs).replace(/^~/, "")} from bandwidth cap`);
      if (exhaustsBeforeMissionEta && missionEtaSecs != null) {
        parts.push(`exhausts before ${formatDurationEta(missionEtaSecs)} task ETA`);
      }
      subline = parts.join(" · ");
    } else {
      headline = sustainsUntilReset
        ? `Sustains until ${resetPeriod} reset`
        : `${money(availableUsd)} available (${money(capUsd)} cap)`;
      const baseSub = pool && pool.live_machines > 0
        ? `${pool.live_machines} active machine${pool.live_machines === 1 ? "" : "s"} · waiting for burn sample`
        : "No active managed-machine burn right now";
      subline =
        resetPeriod !== "total" && resetsInSecs != null
          ? `${baseSub} · resets in ${formatDurationEta(resetsInSecs)}`
          : baseSub;
    }
  } else {
    headline = observedComputeBurnUsdPerH > 0.005
      ? `${money(observedComputeBurnUsdPerH)}/h current compute burn`
      : "No spending cap";
    const parts = ["Only the daily managed-machine cap applies"];
    if (currentTokensPerMin > 0) parts.push(formatTokensPerMin(currentTokensPerMin));
    subline = parts.join(" · ");
  }

  // Compact SVG geometry (560x96 viewBox).
  const width = 560;
  const height = 96;
  const padLeft = 8;
  const padRight = 8;
  const padTop = 10;
  const padBottom = 10;
  const plotW = width - padLeft - padRight;
  const plotH = height - padTop - padBottom;
  const nowX = Math.round(padLeft + plotW * 0.42);

  const projHorizonSecs = Math.min(
    Math.max(etaSecs ?? resetsInSecs ?? missionEtaSecs ?? 7200, 1800),
    86_400,
  );
  const projectedEnd = committedPreReserved + shapedComputeBurnUsdPerH * (projHorizonSecs / 3600);
  const unshapedEnd = committedPreReserved + observedComputeBurnUsdPerH * (projHorizonSecs / 3600);
  const maxVal = Math.max(
    capUsd ?? 0,
    committedTotal,
    projectedEnd,
    unshapedEnd,
    1,
  ) * 1.08;

  const yOf = (usdVal: number) => {
    const clamped = Math.max(0, Math.min(maxVal, usdVal));
    return Math.round((padTop + plotH * (1 - clamped / maxVal)) * 10) / 10;
  };

  // Build observed cumulative curve from padLeft..nowX.
  const obsPoints: Array<[number, number]> = [];
  const tl = res?.timeline;
  if (tl && tl.offsets_secs.length >= 2) {
    const rates = tl.observed_compute_usd_per_h;
    const deltas: number[] = [0];
    for (let i = 1; i < tl.offsets_secs.length; i++) {
      const dt = Math.max(0, tl.offsets_secs[i]! - tl.offsets_secs[i - 1]!);
      const r = rates[i] ?? rates[i - 1] ?? 0;
      deltas.push(deltas[deltas.length - 1]! + Math.max(0, r) * (dt / 3600));
    }
    const totalDelta = deltas[deltas.length - 1] || 0;
    const scale = totalDelta > 0 ? committedPreReserved / totalDelta : 0;
    const t0 = tl.offsets_secs[0]!;
    const tSpan = Math.max(1, tl.offsets_secs[tl.offsets_secs.length - 1]! - t0);
    for (let i = 0; i < tl.offsets_secs.length; i++) {
      const frac = (tl.offsets_secs[i]! - t0) / tSpan;
      const x = Math.round((padLeft + (nowX - padLeft) * frac) * 10) / 10;
      const val = totalDelta > 0 ? deltas[i]! * scale : committedPreReserved * frac;
      obsPoints.push([x, yOf(val)]);
    }
  } else {
    obsPoints.push([padLeft, yOf(0)]);
    obsPoints.push([Math.round((padLeft + (nowX - padLeft) * 0.55) * 10) / 10, yOf(committedPreReserved * 0.48)]);
    obsPoints.push([nowX, yOf(committedPreReserved)]);
  }

  const nowY = yOf(committedPreReserved);
  const reservedTopY = yOf(committedTotal);
  const capY = capUsd != null ? yOf(capUsd) : null;
  const endX = width - padRight;
  const projEndY = yOf(Math.min(maxVal, projectedEnd));

  const observedLinePath = obsPoints
    .map(([x, y], i) => `${i === 0 ? "M" : "L"}${x},${y}`)
    .join(" ");
  const baselineY = yOf(0);
  const observedAreaPath = `${observedLinePath} L${nowX},${baselineY} L${padLeft},${baselineY} Z`;

  let exhaustionX: number | null = null;
  if (capUsd != null && runwayUsd > 0 && shapedComputeBurnUsdPerH > 0.005 && etaSecs != null && etaSecs <= projHorizonSecs) {
    const frac = Math.max(0, Math.min(1, etaSecs / projHorizonSecs));
    exhaustionX = Math.round((nowX + (endX - nowX) * frac) * 10) / 10;
  }

  const projectedLinePath = exhaustionX != null && capY != null
    ? `M${nowX},${nowY} L${exhaustionX},${capY} L${endX},${capY}`
    : `M${nowX},${nowY} L${endX},${projEndY}`;

  let unshapedLinePath: string | null = null;
  if (shapedComputeBurnUsdPerH + 0.01 < observedComputeBurnUsdPerH) {
    const unshapedEndY = yOf(Math.min(maxVal, unshapedEnd));
    unshapedLinePath = `M${nowX},${nowY} L${endX},${unshapedEndY}`;
  }

  return {
    hasBudget: capUsd != null,
    capUsd,
    spentUsd,
    reservedUsd,
    carvedUsd,
    availableUsd,
    observedComputeBurnUsdPerH,
    shapedComputeBurnUsdPerH,
    observedInferenceBurnUsdPerH,
    shapedInferenceBurnUsdPerH,
    currentTokensPerMin,
    currentVcpuPerMin,
    pacingActive: Boolean(effBw?.pacing_active),
    resetPeriod,
    resetsInSecs,
    sustainsUntilReset,
    leaseCliffSecs,
    etaSecs,
    unshapedEtaSecs,
    etaGainSecs,
    missionEtaSecs,
    exhaustsBeforeMissionEta,
    tone,
    headline,
    subline,
    chart: {
      width,
      height,
      padLeft,
      padRight,
      padTop,
      padBottom,
      nowX,
      nowY,
      capY,
      reservedTopY,
      exhaustionX,
      observedAreaPath,
      observedLinePath,
      projectedLinePath,
      unshapedLinePath,
    },
  };
}
