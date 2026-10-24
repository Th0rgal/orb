/**
 * Reliability classification for the router health panel (Settings > Models &
 * Routing). Pure functions over `/api/ai/proxy/health` groups: outcome mix,
 * status (quota cooldown is expected waiting, not a failure), impact ranking.
 * Mobile mirrors these names and thresholds.
 */
import type { ReliabilityGroup } from "./proxyHealthApi";
import { ERROR_LABEL } from "./proxyHealthApi";

export type Outcome = "ok" | "limited" | "client" | "server" | "timeout";
/** Fixed categorical order (validated palette order, never re-sorted). */
export const OUTCOMES: Outcome[] = ["ok", "limited", "client", "server", "timeout"];
export const OUTCOME_LABEL: Record<Outcome, string> = {
  ok: "OK", limited: "Rate limit / quota", client: "Client error", server: "Server error", timeout: "Timeout / stall",
};

/** Error key from Core (`client_error:429`, `timeout`, …) to its outcome bucket. */
export function outcomeOf(key: string): Exclude<Outcome, "ok"> {
  if (key === "client_error:429") return "limited";
  if (key.startsWith("client_error")) return "client";
  if (key.startsWith("server_error")) return "server";
  return "timeout"; // timeout, stalled, empty_before_first_chunk
}

export function outcomeMix(g: Pick<ReliabilityGroup, "ok" | "errors">): Record<Outcome, number> {
  const mix: Record<Outcome, number> = { ok: g.ok, limited: 0, client: 0, server: 0, timeout: 0 };
  for (const [key, n] of Object.entries(g.errors)) mix[outcomeOf(key)] += n;
  return mix;
}

export type Health = "healthy" | "degraded" | "down" | "quota" | "limited";
export interface Status { health: Health; label: string; short?: string; tone: "neutral" | "warning" | "danger"; until?: string }

/** Below this share of hard (non-429) failures a row is Healthy; at or above DOWN it is Down. */
export const DEGRADED_FAILURE_RATE = 0.1;
export const DOWN_FAILURE_RATE = 0.5;
/** Fewer attempts than this never classify worse than Degraded (noise). */
export const MIN_ATTEMPTS = 5;
/** A 429 costs a quarter of a hard failure in the impact ranking: it is expected back-pressure. */
export const LIMITED_WEIGHT = 0.25;

const hhmm = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });

/**
 * Status of one provider·model·account row. 429s are rate limits or quota:
 * with an active quota cooldown the row shows "Quota cooldown until HH:MM"
 * (amber, not red) no matter how many 429s it logged. Hard failures (auth,
 * credit, 5xx, timeouts) drive Degraded / Down.
 */
export function classify(g: ReliabilityGroup, now = Date.now()): Status {
  const mix = outcomeMix(g);
  const hard = mix.client + mix.server + mix.timeout;
  const cooldown = g.cooldown && Date.parse(g.cooldown.until) > now ? g.cooldown : null;
  if (cooldown?.state === "out_of_credit") return { health: "down", label: "Out of credit", tone: "danger" };
  if (cooldown?.state === "auth_failed") return { health: "down", label: "Auth failed", tone: "danger" };
  const hardRate = g.requests ? hard / g.requests : 0;
  if (hard >= MIN_ATTEMPTS && hardRate >= DOWN_FAILURE_RATE && g.ok === 0)
    return { health: "down", label: "Down", tone: "danger" };
  if (cooldown && (cooldown.state === "quota_exhausted" || cooldown.state === "rate_limited" || mix.limited > 0))
    return { health: "quota", label: `${cooldown.state === "rate_limited" ? "Rate limited" : "Quota cooldown"} until ${hhmm(cooldown.until)}`, short: `Until ${hhmm(cooldown.until)}`, tone: "warning", until: cooldown.until };
  if (hard >= MIN_ATTEMPTS && hardRate >= DOWN_FAILURE_RATE) return { health: "down", label: "Down", tone: "danger" };
  if (hard > 0 && (hardRate >= DEGRADED_FAILURE_RATE || g.flags.includes("auth_failed") || g.flags.includes("out_of_credit") || g.flags.includes("stalls")))
    return { health: "degraded", label: "Degraded", tone: "danger" };
  if (g.flags.includes("slow_first_token")) return { health: "degraded", label: "Slow", tone: "warning" };
  if (g.requests && mix.limited / g.requests >= DEGRADED_FAILURE_RATE) return { health: "limited", label: "Rate limited", tone: "warning" };
  return { health: "healthy", label: "Healthy", tone: "neutral" };
}

/** Ranking weight: hard failures count fully, 429s at LIMITED_WEIGHT. */
export function impact(g: ReliabilityGroup): number {
  const mix = outcomeMix(g);
  return mix.client + mix.server + mix.timeout + mix.limited * LIMITED_WEIGHT;
}

export interface Row { key: string; group: ReliabilityGroup; status: Status; impact: number; name: string; account?: string }

/**
 * Rows sorted by impact (desc), then attempts. Rows sharing provider·model get
 * their account label (or short id) so duplicates are told apart.
 */
export function reliabilityRows(groups: ReliabilityGroup[], now = Date.now()): Row[] {
  const name = (g: ReliabilityGroup) => `${g.provider ?? "Unknown provider"}${g.model ? ` · ${g.model}` : ""}`;
  const count = new Map<string, number>();
  for (const g of groups) count.set(name(g), (count.get(name(g)) ?? 0) + 1);
  return groups
    .map(g => ({
      key: `${g.provider}|${g.model}|${g.account_id}`, group: g, status: classify(g, now), impact: impact(g), name: name(g),
      account: (count.get(name(g)) ?? 0) > 1 ? g.account_label || g.account_id?.slice(0, 8) || "No account" : undefined,
    }))
    .sort((a, b) => b.impact - a.impact || b.group.requests - a.group.requests || a.name.localeCompare(b.name));
}

export const isProblem = (r: Row) => r.status.health !== "healthy";

export const errorLabel = (key: string) => ERROR_LABEL[key] ?? key.replace("_error:", " ").replace(/_/g, " ");
