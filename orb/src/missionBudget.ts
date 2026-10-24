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

export type ChildBudget = {
  mission_id: string;
  mode: "pooled" | "sub_budget";
  budget_usd: number | null;
  spent_usd: number;
  reserved_usd: number;
};

/** `GET /api/control/missions/:id/budget`. */
export type MissionBudget = {
  mission_id: string;
  own_budget_usd: number | null;
  pool_id: string | null;
  mode: "own" | "pooled" | "none";
  pool: PoolUsage | null;
  max_grant_usd: number | null;
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

export const money = (v: number) => `$${v < 10 ? v.toFixed(2) : v.toFixed(0)}`;

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

/**
 * What the sheet shows right after a change, before the server answers
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

/** Fraction of the pool used (spent + reserved + sub-budgets), 0..1. */
export function usedFraction(pool: PoolUsage): number {
  if (pool.budget_usd <= 0) return 1;
  return Math.min(1, Math.max(0, (pool.spent_usd + pool.reserved_usd + pool.carved_usd) / pool.budget_usd));
}
