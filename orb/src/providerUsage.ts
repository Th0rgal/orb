import type { AIProvider, ProviderUsage } from "./api";
import type { AccountHealthSnapshot } from "./routingApi";

export function codexWindowLabel(minutes: number | undefined, fallback: string) {
  if (minutes == null) return fallback;
  if (minutes === 10080) return "Weekly";
  if (minutes >= 1440 && minutes % 1440 === 0) return `${minutes / 1440}d`;
  if (minutes >= 60 && minutes % 60 === 0) return `${minutes / 60}h`;
  return `${minutes}m`;
}

/** The array preserves provider-defined windows; scalar fields support older responses. */
export function kimiWindows(u: ProviderUsage) {
  const reported = (u.kimi_windows ?? []).filter(w => w.used_percent != null && Number.isFinite(w.used_percent));
  if (reported.length) return reported;
  const windows: {label: string; used_percent: number; reset_at?: number}[] = [];
  if (u.kimi_5h_used_percent != null) windows.push({label: "5h", used_percent: u.kimi_5h_used_percent, reset_at: u.kimi_5h_reset});
  if (u.kimi_weekly_used_percent != null) windows.push({label: "Weekly", used_percent: u.kimi_weekly_used_percent, reset_at: u.kimi_weekly_reset});
  return windows;
}

export function codingPlanWindows(u: ProviderUsage) {
  const windows: {label: string; used: number; reset?: number}[] = [];
  const add = (label: string, percent: number | undefined, reset?: number, remaining = false) => {
    if (percent != null && Number.isFinite(percent)) windows.push({label, used: Math.min(100, Math.max(0, remaining ? 100 - percent : percent)) / 100, reset});
  };
  if (u.provider_type === "minimax") {
    add("5h", u.minimax_interval_remaining_percent, u.minimax_interval_reset, true);
    add("Weekly", u.minimax_weekly_remaining_percent, u.minimax_weekly_reset, true);
  }
  if (u.provider_type === "muse-code") {
    add("5h", u.muse_5h_used_percent, u.muse_5h_reset);
    add("Weekly", u.muse_weekly_used_percent, u.muse_weekly_reset);
  }
  if (u.provider_type === "antigravity") for (const w of u.antigravity_windows ?? []) add(w.label, w.used_percent, w.reset_at);
  if (u.provider_type === "mistral") add("Monthly", u.mistral_monthly_used_percent, u.mistral_monthly_reset);
  if (u.provider_type === "zai") {
    add("5h", u.zai_5h_used_percent, u.zai_5h_reset);
    add("Weekly", u.zai_weekly_used_percent, u.zai_weekly_reset);
    if (!windows.length) add("Tokens", u.zai_tokens_percentage, u.zai_tokens_reset);
  }
  return windows;
}

export function usageWindows(u: ProviderUsage) {
  const windows: { label: string; used: number }[] = [];
  if (u.unified_5h_utilization != null) windows.push({ label: "5h", used: u.unified_5h_utilization });
  if (u.unified_7d_utilization != null) windows.push({ label: "7d", used: u.unified_7d_utilization });
  if (u.codex_primary_used_percent != null && u.codex_primary_window_minutes !== 0)
    windows.push({ label: codexWindowLabel(u.codex_primary_window_minutes, "Primary"), used: u.codex_primary_used_percent / 100 });
  if (u.codex_secondary_used_percent != null && u.codex_secondary_window_minutes !== 0)
    windows.push({ label: codexWindowLabel(u.codex_secondary_window_minutes, "Secondary"), used: u.codex_secondary_used_percent / 100 });
  if (u.provider_type === "xai" && u.xai_credit_used_percent != null)
    windows.push({ label: u.xai_credit_label || "Credits", used: u.xai_credit_used_percent / 100 });
  if (u.provider_type === "kimi") windows.push(...kimiWindows(u).map(w => ({label: w.label, used: w.used_percent! / 100})));
  windows.push(...codingPlanWindows(u).map(({label, used}) => ({label, used})));
  return windows;
}

export function effectiveProviderStatus(a: AIProvider, usage?: ProviderUsage, health?: AccountHealthSnapshot) {
  // Checked first: the backend skips a disabled account whatever its quota.
  if (a.enabled === false) return "disabled";
  // The router's circuit breaker saw the account fail as a whole (402 / no
  // credit, 401 / 403): it is skipped until its next probe, whatever the
  // saved credential says.
  if (health?.account_state === "out_of_credit") return "out_of_credit";
  if (health?.account_state === "auth_failed") return "auth_failed";
  if (a.status.type === "needs_reauth" || usage?.status === "needs_reauth") return "needs_reauth";
  if (usage?.error) return "error";
  if (usage && usageWindows(usage).some(window => window.used >= 1)) return "quota_exhausted";
  return a.status.type;
}

/** Match the data actually rendered in UsageDetail, not an empty cache object. */
export function hasProviderUsageDetails(u?: ProviderUsage): boolean {
  if (!u) return false;
  return !!(codingPlanWindows(u).length || u.usage_note || u.error || u.status === "needs_reauth" || u.account_email || u.account_name || u.organization || u.unified_status
    || (u.provider_type === "anthropic" && (u.unified_5h_utilization != null || u.unified_7d_utilization != null))
    || (u.provider_type === "openai" && ((u.codex_primary_used_percent != null && u.codex_primary_window_minutes !== 0) || u.requests_limit != null))
    || (u.provider_type === "minimax" && u.model_usage?.length)
    || (u.provider_type === "xai" && (u.xai_plan != null || u.xai_credit_used_percent != null || u.xai_prepaid_usd != null || u.xai_on_demand_used != null))
    || (u.provider_type === "kimi" && (u.kimi_plan != null || kimiWindows(u).length > 0))
    || (u.provider_type === "zai" && u.zai_tokens_percentage != null));
}

export type UsageLimitStatus = { tone: "warning" | "error"; label: string };

const CLAIM_WINDOWS: Record<string, { label: string; key?: "unified_5h_utilization" | "unified_7d_utilization" }> = {
  five_hour: { label: "5h", key: "unified_5h_utilization" },
  seven_day: { label: "weekly", key: "unified_7d_utilization" },
  seven_day_opus: { label: "weekly Opus" },
  seven_day_sonnet: { label: "weekly Sonnet" },
};

function resetsIn(seconds: number): string {
  if (seconds < 3600) return `${Math.max(1, Math.floor(seconds / 60))}m`;
  if (seconds < 48 * 3600) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

/**
 * Anthropic unified rate-limit status as a friendly badge; null means show
 * nothing. Spec: shared/orb-spec/fixtures/usage-limit-status.json (same
 * function on iOS and Android). Never returns a raw snake_case status.
 */
export function usageLimitStatus(u: Pick<ProviderUsage, "unified_status" | "unified_reset" | "unified_representative_claim" | "unified_5h_utilization" | "unified_7d_utilization">, nowSec = Date.now() / 1000): UsageLimitStatus | null {
  const status = (u.unified_status ?? "").trim().toLowerCase();
  if (!status || status === "allowed" || status === "ok") return null;
  if (status === "allowed_warning") {
    const claim = CLAIM_WINDOWS[(u.unified_representative_claim ?? "").trim().toLowerCase()];
    if (!claim) return { tone: "warning", label: "Approaching limit" };
    const used = claim.key ? u[claim.key] : undefined;
    const pct = typeof used === "number" && Number.isFinite(used) ? ` ${Math.round(used * 100)}%` : "";
    return { tone: "warning", label: `Approaching limit · ${claim.label}${pct}` };
  }
  if (status === "rejected") {
    const reset = Number(u.unified_reset);
    const left = Number.isFinite(reset) && u.unified_reset != null ? reset - nowSec : NaN;
    return { tone: "error", label: left > 0 ? `Limit reached · resets in ${resetsIn(left)}` : "Limit reached" };
  }
  return { tone: "warning", label: "Limit status unknown" };
}

/**
 * Organization ids that more than one Anthropic account reports. Accounts in
 * the same organization share one unified limit, so their identical numbers
 * are labelled "Shared organization limit" rather than looking duplicated.
 */
export function sharedAnthropicOrganizations(usages: Record<string, ProviderUsage | undefined>): Set<string> {
  const seen = new Map<string, number>();
  for (const u of Object.values(usages)) {
    const org = u?.provider_type === "anthropic" ? u.organization_id?.trim() : undefined;
    if (org) seen.set(org, (seen.get(org) ?? 0) + 1);
  }
  return new Set([...seen].filter(([, n]) => n > 1).map(([org]) => org));
}
