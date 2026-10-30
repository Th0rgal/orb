import { api } from "./api";

/** One pool's derived usage (`crate::managed::budget::PoolUsage`). */
export type PoolUsage = {
  pool_id: string;
  budget_usd: number;
  spent_usd: number;
  reserved_usd: number;
  carved_usd: number;
  available_usd: number;
  live_machines: number;
};

export const MANAGED_PROVIDERS = [
  { id: "boat", label: "boat.dev" },
  { id: "hetzner", label: "Hetzner" },
  { id: "vastai", label: "Vast.ai" },
  { id: "scaleway", label: "Scaleway" },
] as const;

export type ManagedProviderId = (typeof MANAGED_PROVIDERS)[number]["id"];

export const MAX_VM_CONCURRENCY = 128;

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

export type ChildBudget = {
  mission_id: string;
  mode: "pooled" | "sub_budget";
  budget_usd: number | null;
  spent_usd: number;
  reserved_usd: number;
  has_vm_limits?: boolean;
  vm_max_concurrent?: number | null;
  live_machines?: number;
};

/** `GET /api/control/missions/:id/budget`. */
export type MissionBudget = {
  mission_id: string;
  own_budget_usd: number | null;
  pool_id: string | null;
  mode: "own" | "pooled" | "none";
  pool: PoolUsage | null;
  max_grant_usd: number | null;
  own_vm_limits?: VmConcurrencyLimits | null;
  vm_limits_mode?: "own" | "pooled" | "global";
  vm_limits_pool_id?: string | null;
  effective_vm_limits?: EffectiveVmLimits;
  children: ChildBudget[];
};

export const getMissionBudget = (id: string) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, { method: "GET" });

export const putMissionBudget = (id: string, budget_usd: number | null) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ budget_usd }),
  });

export const putMissionVmLimits = (id: string, vm_limits: VmConcurrencyLimits | null) =>
  api<MissionBudget>(`/api/control/missions/${encodeURIComponent(id)}/budget`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ vm_limits }),
  });

export const money = (v: number) => `$${v < 10 ? v.toFixed(2) : v.toFixed(0)}`;

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

export function normalizeVmLimits(limits: VmConcurrencyLimits | null | undefined): string {
  if (!limits) return "null";
  const provEntries = MANAGED_PROVIDERS
    .map(p => [p.id, limits.provider_max_concurrent?.[p.id]] as const)
    .filter(([, v]) => v != null);
  return JSON.stringify({ m: limits.max_concurrent ?? null, p: provEntries });
}

/**
 * What the sheet shows right after a budget change, before the server answers
 * (optimistic). Usage numbers stay as they were; only ownership changes.
 */
export function optimisticBudget(view: MissionBudget, amount: number | null): MissionBudget {
  if (amount == null) {
    const inherited = view.mode === "own" && view.max_grant_usd != null;
    // The parent's pool numbers arrive with the server's answer.
    return { ...view, own_budget_usd: null, mode: inherited ? "pooled" : "none", pool: null, pool_id: null };
  }
  const pool = view.pool && view.mode === "own"
    ? { ...view.pool, budget_usd: amount, available_usd: view.pool.available_usd + (amount - view.pool.budget_usd) }
    : { pool_id: view.mission_id, budget_usd: amount, spent_usd: 0, reserved_usd: 0, carved_usd: 0, available_usd: amount, live_machines: 0 };
  return { ...view, own_budget_usd: amount, mode: "own", pool_id: view.mission_id, pool };
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

/** One line describing where the money comes from. */
export function modeLine(view: MissionBudget, parentTitle?: string): string {
  if (view.mode === "own") {
    return view.max_grant_usd != null
      ? "Own sub-budget, carved from the parent's pool. Its subagents share it."
      : "Own budget. Subagents share it unless you give one a sub-budget.";
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

/** Summary chips text for configured per-provider limits ("Vast.ai: 2 · boat.dev: 8"). */
export function providerLimitsSummary(limits: VmConcurrencyLimits | null | undefined): string {
  const map = limits?.provider_max_concurrent;
  if (!map) return "";
  return MANAGED_PROVIDERS
    .filter(p => map[p.id] != null)
    .map(p => `${p.label}: ${map[p.id] === 0 ? "off" : map[p.id]}`)
    .join(" · ");
}

/** Fraction of the pool used (spent + reserved + sub-budgets), 0..1. */
export function usedFraction(pool: PoolUsage): number {
  if (pool.budget_usd <= 0) return 1;
  return Math.min(1, Math.max(0, (pool.spent_usd + pool.reserved_usd + pool.carved_usd) / pool.budget_usd));
}
