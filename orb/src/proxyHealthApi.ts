import { api } from "./api";

/** Reliability of the /v1 router, from `/api/ai/proxy/health`. */
export interface ReliabilityStats {
  requests: number;
  ok: number;
  success_rate: number | null;
  ttft_p50_ms: number | null;
  ttft_p95_ms: number | null;
  latency_p50_ms: number | null;
  latency_p95_ms: number | null;
  retried: number;
  fell_back: number;
  errors: Record<string, number>;
}

export type ReliabilityFlag = "low_success_rate" | "out_of_credit" | "auth_failed" | "slow_first_token" | "stalls";

export interface ReliabilityGroup extends ReliabilityStats {
  provider: string | null;
  model: string | null;
  account_id: string | null;
  flags: ReliabilityFlag[];
}

export interface ChainReliability extends ReliabilityStats { chain_id: string }

export interface ProxyHealth {
  window: string;
  since: string | null;
  totals: ReliabilityStats;
  groups: ReliabilityGroup[];
  chains: ChainReliability[];
}

export const RELIABILITY_WINDOWS = [{ value: "1h", label: "Last hour" }, { value: "24h", label: "Last 24 hours" }];

export const getProxyHealth = (window: string) =>
  api<ProxyHealth>(`/api/ai/proxy/health?window=${encodeURIComponent(window)}`);

export const FLAG_LABEL: Record<ReliabilityFlag, string> = {
  low_success_rate: "Success below 90%",
  out_of_credit: "Out of credit",
  auth_failed: "Auth failed",
  slow_first_token: "Slow first token",
  stalls: "Stalled streams",
};

const ERROR_LABEL: Record<string, string> = {
  "client_error:402": "402 out of credit",
  "client_error:401": "401 auth",
  "client_error:403": "403 auth",
  "client_error:429": "429 rate limit",
  timeout: "timeout",
  empty_before_first_chunk: "empty before first chunk",
  stalled: "stalled",
};

/** Error breakdown, most frequent first: "402 out of credit ×483 · timeout ×2". */
export function errorSummary(errors: Record<string, number>, limit = 3): string {
  return Object.entries(errors)
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([key, n]) => `${ERROR_LABEL[key] ?? key.replace("_error:", " ").replace(/_/g, " ")} ×${n.toLocaleString()}`)
    .join(" · ");
}

export function formatRate(rate: number | null): string {
  if (rate == null) return "—";
  const pct = rate * 100;
  return `${pct >= 99.95 || pct === 0 ? pct.toFixed(0) : pct.toFixed(1)}%`;
}

export function formatMs(ms: number | null): string {
  if (ms == null) return "—";
  return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)} s`;
}

/** A group needs attention when it carries a flag or fails ≥10% of enough requests. */
export const isRedFlag = (g: ReliabilityStats & { flags?: ReliabilityFlag[] }) =>
  (g.flags?.length ?? 0) > 0 || (g.requests >= 5 && (g.success_rate ?? 1) < 0.9);
