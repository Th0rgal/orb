import { api } from "./api";

/** One served `(provider, model)` line (`crate::api::mission_stats::ModelLine`). */
export type ModelLine = {
  provider: string | null; model: string; requests: number;
  input_tokens: number; cache_read_tokens: number; cache_write_tokens: number; output_tokens: number;
  cost_usd: number; shadow_priced: boolean; unpriced: boolean;
};
export type MissionStats = {
  mission_id: string; period: "today" | "lifetime"; since: string | null;
  own: { models: ModelLine[]; vm_usd: number; total_usd: number };
  subtree_total_usd: number;
  children: { mission_id: string; title: string | null; total_usd: number }[];
};
export type StatsPeriod = "today" | "lifetime";

export const getMissionStats = (id: string, period: StatsPeriod) =>
  api<MissionStats>(`/api/control/missions/${encodeURIComponent(id)}/stats?period=${period}`, { method: "GET" });

/** "$0.004", "$1.25", "$1,240" */
export function usd(v: number): string {
  if (v === 0) return "$0";
  if (v < 0.01) return `$${v.toFixed(3)}`;
  if (v < 1000) return `$${v.toFixed(2)}`;
  return `$${Math.round(v).toLocaleString("en-US")}`;
}
/** 1234 -> "1.2k", 3_400_000 -> "3.4M" */
export function tokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}
export const modelLabel = (m: Pick<ModelLine, "provider" | "model">) => m.provider ? `${m.provider}/${m.model}` : m.model;
/** Subagents' share = subtree − own (never negative). */
export const subagentsUsd = (s: MissionStats) => Math.max(0, s.subtree_total_usd - s.own.total_usd);
