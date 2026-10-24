import { api } from "./api";

export type UsageSource = "harness" | "router";
export type CostStatus = "known" | "partial" | "unknown";

export interface UsageTotals {
  requests: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_tokens: number;
  cache_read_tokens: number;
  reasoning_tokens?: number;
  cost_cents: number;
  unknown_cost_requests: number;
}

export interface ModelUsage extends UsageTotals {
  model: string;
  provider: string | null;
  source: UsageSource;
  cost_status: CostStatus;
}

export interface UsageGroup extends UsageTotals {
  key: string | null;
  label: string | null;
  cost_status: CostStatus;
}

export interface DayUsage extends UsageTotals { day: string; router_requests: number; by_caller_kind?: Record<string, number> }
export interface HourUsage extends UsageTotals { hour: string; router_requests: number; by_caller_kind?: Record<string, number> }

/** Closed caller-kind enum from Core (`docs/specs/usage-attribution.md`). */
export const CALLER_KINDS = ["mission", "subagent", "hermes", "orb_ui", "core", "script", "unknown"] as const;
export const CALLER_KIND_LABEL: Record<string, string> = {
  mission: "Mission", subagent: "Subagent", hermes: "Hermes", orb_ui: "Orb UI", core: "Core", script: "Script / API key", unknown: "Unknown",
};

export interface UsageSummary {
  window: string;
  since: string | null;
  cost_status: CostStatus;
  totals: UsageTotals;
  by_model: ModelUsage[];
  by_provider: UsageGroup[];
  by_source: UsageGroup[];
  by_route?: UsageGroup[];
  by_caller_kind?: UsageGroup[];
  by_purpose?: UsageGroup[];
  by_backend: UsageGroup[];
  by_mission: UsageGroup[];
  by_root_mission?: UsageGroup[];
  by_api_key: UsageGroup[];
  by_account: UsageGroup[];
  by_day: DayUsage[];
  by_hour: HourUsage[];
}

export interface UsageFilters {
  source?: string;
  provider?: string;
  backend?: string;
  mission?: string;
  api_key?: string;
  model?: string;
  caller_kind?: string;
}

export const USAGE_WINDOWS = [
  { value: "1h", label: "1 hour" },
  { value: "5h", label: "5 hours" },
  { value: "24h", label: "24 hours" },
  { value: "7d", label: "7 days" },
  { value: "30d", label: "30 days" },
  { value: "90d", label: "90 days" },
  { value: "all", label: "All time" },
] as const;

export function usageQuery(window: string, filters: UsageFilters = {}) {
  const params = new URLSearchParams({ window });
  for (const [key, value] of Object.entries(filters)) if (value) params.set(key, value);
  return `/api/ai/usage/summary?${params}`;
}

export const getUsageSummary = (window: string, filters: UsageFilters = {}) =>
  api<UsageSummary>(usageQuery(window, filters));

export const totalTokens = (t: UsageTotals) =>
  t.input_tokens + t.output_tokens + t.cache_creation_tokens + t.cache_read_tokens;

export function formatTokens(n: number) {
  if (n >= 1e9) return `${(n / 1e9).toFixed(n >= 1e10 ? 0 : 1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}K`;
  return String(n);
}

/** Cost is never shown as $0 when part of it is unpriced. */
export function formatCost(t: Pick<UsageTotals, "cost_cents" | "unknown_cost_requests" | "requests">) {
  if (t.requests > 0 && t.unknown_cost_requests === t.requests) return "Unknown";
  const dollars = t.cost_cents / 100;
  const text = dollars >= 100 ? `$${Math.round(dollars).toLocaleString()}` : `$${dollars.toFixed(2)}`;
  return t.unknown_cost_requests > 0 ? `${text}+` : text;
}

export function costTitle(t: UsageTotals) {
  if (!t.unknown_cost_requests) return undefined;
  return `${t.unknown_cost_requests.toLocaleString()} of ${t.requests.toLocaleString()} requests use a model without a list price; their cost is not included.`;
}

export interface ChartBucket { key: string; label: string; tokens: number; cost_cents: number; requests: number; router_requests: number }

const WINDOW_HOURS: Record<string, number> = { "1h": 1, "5h": 5, "24h": 24, "7d": 168, "30d": 720, "90d": 2160 };

export function windowHours(window: string): number | null {
  if (window in WINDOW_HOURS) return WINDOW_HOURS[window];
  const m = /^(\d+)([hdw])$/.exec(window);
  if (!m) return null;
  return Number(m[1]) * (m[2] === "h" ? 1 : m[2] === "d" ? 24 : 168);
}

const pad = (n: number) => String(n).padStart(2, "0");
const hourKey = (d: Date) => `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}`;
const dayKey = (d: Date) => hourKey(d).slice(0, 10);

/**
 * Contiguous chart buckets for the window: hourly up to 7 days, daily beyond.
 * Missing buckets are zero so quiet hours are visible, not skipped.
 */
/** Hourly buckets are available for windows up to 7 days. */
export function hourlyAvailable(window: string) {
  const hours = windowHours(window);
  return hours !== null && hours <= 168;
}

export function chartBuckets(s: UsageSummary, now = new Date(), prefer: "hour" | "day" = "hour"): { granularity: "hour" | "day"; buckets: ChartBucket[] } {
  const hours = windowHours(s.window);
  const hourly = prefer === "hour" && hourlyAvailable(s.window);
  const rows = new Map<string, UsageTotals & { router_requests: number }>();
  for (const r of hourly ? s.by_hour : s.by_day) rows.set("hour" in r ? r.hour : r.day, r);
  const keys: string[] = [];
  if (hourly) {
    const end = new Date(now); end.setUTCMinutes(0, 0, 0);
    for (let i = hours! - 1; i >= 0; i--) keys.push(hourKey(new Date(end.getTime() - i * 3_600_000)));
  } else {
    const first = s.by_day[0]?.day;
    const days = hours !== null ? Math.max(1, Math.ceil(hours / 24)) : first ? Math.max(1, Math.round((Date.parse(dayKey(now)) - Date.parse(first)) / 86_400_000) + 1) : 0;
    const end = Date.parse(dayKey(now));
    for (let i = days - 1; i >= 0; i--) keys.push(dayKey(new Date(end - i * 86_400_000)));
  }
  const buckets = keys.map(key => {
    const r = rows.get(key);
    const label = hourly ? `${key.slice(11)}:00` : key.slice(5);
    return { key, label, tokens: r ? totalTokens(r) : 0, cost_cents: r?.cost_cents ?? 0, requests: r?.requests ?? 0, router_requests: r?.router_requests ?? 0 };
  });
  return { granularity: hourly ? "hour" : "day", buckets };
}
