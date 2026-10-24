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
  /** Account label/name, to tell apart rows of the same provider·model. */
  account_label?: string | null;
  /** Live account cooldown (e.g. quota reset) at response time. */
  cooldown?: { state: "quota_exhausted" | "rate_limited" | "out_of_credit" | "auth_failed" | "cooldown"; until: string } | null;
  /** Latest failures, newest first (at most 5). */
  recent_errors?: { at: string; error: string }[];
}

/** One equal time bucket of the window, oldest first. */
export interface SeriesBucket {
  requests: number; ok: number; ttft_p50_ms: number | null; ttft_p95_ms: number | null; retried: number; fell_back: number;
}

export interface ChainReliability extends ReliabilityStats { chain_id: string }

export interface ProxyHealth {
  window: string;
  since: string | null;
  totals: ReliabilityStats;
  groups: ReliabilityGroup[];
  chains: ChainReliability[];
  series?: SeriesBucket[];
  bucket_secs?: number;
}

export const RELIABILITY_WINDOWS = [{ value: "1h", label: "Last hour" }, { value: "24h", label: "Last 24 hours" }];

export const getProxyHealth = (window: string) =>
  api<ProxyHealth>(`/api/ai/proxy/health?window=${encodeURIComponent(window)}`);

export const ERROR_LABEL: Record<string, string> = {
  "client_error:402": "402 out of credit",
  "client_error:401": "401 auth",
  "client_error:403": "403 auth",
  "client_error:429": "429 rate limit / quota",
  "client_error:400": "400 bad request",
  timeout: "timeout",
  empty_before_first_chunk: "empty before first chunk",
  stalled: "stalled",
};

export function formatRate(rate: number | null): string {
  if (rate == null) return "—";
  const pct = rate * 100;
  return `${pct >= 99.95 || pct === 0 ? pct.toFixed(0) : pct.toFixed(1)}%`;
}

export function formatMs(ms: number | null): string {
  if (ms == null) return "—";
  return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)} s`;
}
