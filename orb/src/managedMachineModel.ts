/** Managed (boat.dev) machines: API client and presentation logic. */
import { api, ApiError } from "./api";

export type ManagedState = "provisioning" | "enrolling" | "online" | "destroying" | "destroyed" | "failed" | "stopped";

export interface ManagedMachine {
  id: string;
  /** "small-a": unique among live machines. Absent on older backends. */
  name?: string | null;
  provider: string;
  provider_id: string;
  node_id: string;
  image: string;
  size: string;
  cpu: number;
  ram_gb: number;
  state: ManagedState | string;
  created_at: string;
  expires_at: string;
  destroyed_at?: string | null;
  cost_usd: number;
  usd_per_hour: number;
  owner_mission_id?: string | null;
  root_mission_id?: string | null;
  project?: string | null;
  active_mission_ids?: string[];
  /** Mission that rented it for the owner (e.g. a start_mission caller). */
  requested_by_mission_id?: string | null;
  /** "mission" | "user"; absent on legacy rows (shown as "No owner"). */
  owner_kind?: string | null;
  reason?: string | null;
  /** Earliest timestamp when the provider allows deletion (e.g. Scaleway Apple Silicon 24h lease). */
  deletable_at?: string | null;
  has_executed_job?: boolean;
  /** When the lifecycle reaper will destroy it, and the reason it will record. */
  reap_at?: string | null;
  reap_reason?: string | null;
  error?: string | null;
  ledger_closed: boolean;
}

export interface ManagedSize {
  size: string;
  cpu: number;
  ram_gb: number;
  disk_gb: number;
  usd_per_hour: number;
  gpu?: string | null;
  arch?: string | null;
  min_billing_hours?: number | null;
}

export interface ManagedProviderInfo {
  provider: string;
  display_name: string;
  configured: boolean;
  supports_snapshots: boolean;
  supports_free_stop: boolean;
  sizes: ManagedSize[];
}

export interface ManagedBudget {
  spent_today_usd: number;
  /** null: unlimited. */
  daily_cap_usd: number | null;
  active: number;
  /** null: unlimited. */
  max_concurrent: number | null;
  default_ttl_minutes: number;
  max_ttl_minutes: number;
  default_size: string;
  max_size: string;
}

/** One UTC day of spend from Core, oldest first; missions/sizes highest first. */
export interface DailySpend { day: string; usd: number; missions: { mission_id: string | null; usd: number }[]; sizes: { size: string; usd: number }[] }

/** `daily_spend` is absent on Cores that predate the spend chart. */
export interface ManagedMachinesResponse {
  machines: ManagedMachine[];
  budget: ManagedBudget;
  sizes: ManagedSize[];
  providers?: ManagedProviderInfo[];
  enabled: boolean;
  daily_spend?: DailySpend[];
}

export interface CreateManagedMachine {
  wait?: boolean;
  provider?: string;
  size?: string;
  cpu?: number;
  ram_gb?: number;
  gpu?: string;
  arch?: string;
  allow_24h_commitment?: boolean;
  ttl_minutes?: number;
  image?: string;
  reason?: string;
}

/** `null` when the backend predates managed machines (404). */
export async function listManagedMachines(): Promise<ManagedMachinesResponse | null> {
  try {
    return await api<ManagedMachinesResponse>("/api/managed-machines", { method: "GET" });
  } catch (error) {
    if (error instanceof ApiError && (error.status === 404 || error.status === 405)) return null;
    throw error;
  }
}
const json = (body: unknown): RequestInit => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
export const createManagedMachine = (body: CreateManagedMachine) => api<ManagedMachine>("/api/managed-machines", json(body));
export const destroyManagedMachine = (id: string) => api<ManagedMachine>(`/api/managed-machines/${encodeURIComponent(id)}`, { method: "DELETE" });
export const stopManagedMachine = (id: string) => api<ManagedMachine>(`/api/managed-machines/${encodeURIComponent(id)}/stop`, json({}));
export const resumeManagedMachine = (id: string) => api<ManagedMachine>(`/api/managed-machines/${encodeURIComponent(id)}/resume`, json({}));

/** A named snapshot (`GET /api/managed-machines/snapshots?all=true`). */
export type ManagedSnapshot = {
  name: string; label: string; project?: string | null; source_machine_id: string; source_size: string;
  created_at: string; last_used_at?: string | null; status: "saving" | "ready" | "failed" | string;
  size_bytes?: number | null; error?: string | null; monthly_usd: number;
};
export const listManagedSnapshots = () => api<{ snapshots: ManagedSnapshot[] }>(`/api/managed-machines/snapshots?all=true`, { method: "GET" });
export const deleteManagedSnapshot = (s: Pick<ManagedSnapshot, "name" | "project">) =>
  api<{ deleted: string }>(`/api/managed-machines/snapshots/${encodeURIComponent(s.name)}${s.project ? `?project=${encodeURIComponent(s.project)}` : ""}`, { method: "DELETE" });
/** "lean-warm · lean · 3.2 GB · used 2 h ago · free" */
export function snapshotLine(s: ManagedSnapshot, now = Date.now()): string {
  const gb = s.size_bytes ? `${(s.size_bytes / 1e9).toFixed(1)} GB` : "";
  const used = s.last_used_at ? `used ${ago(Date.parse(s.last_used_at), now)}` : `saved ${ago(Date.parse(s.created_at), now)}`;
  const cost = s.monthly_usd > 0 ? `${usd(s.monthly_usd)}/month` : "included";
  return [s.project ?? "no project", gb, used, cost].filter(Boolean).join(" · ");
}
const ago = (t: number, now: number) => {
  if (!Number.isFinite(t)) return "";
  const m = Math.max(0, Math.round((now - t) / 60000));
  return m < 60 ? `${m} min ago` : m < 2880 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} d ago`;
};
export const extendManagedMachine = (id: string, ttl_minutes: number) => api<ManagedMachine>(`/api/managed-machines/${encodeURIComponent(id)}/extend`, json({ ttl_minutes }));

export { isManagedNode } from "./machines/nodes";

/** Remote-node ids a managed machine may appear under in /api/remote-nodes. */
export const managedNodeIds = (m: Pick<ManagedMachine, "id" | "node_id">) => [...new Set([m.node_id, `managed-${m.id}`].filter(Boolean))];

export const machineName = (m: Pick<ManagedMachine, "name" | "id">) => m.name || m.id;
export const isStarting = (m: Pick<ManagedMachine, "state">) => m.state === "provisioning" || m.state === "enrolling";

export interface ManagedSettings { antigravity_on_managed: boolean }
/** `null` when the backend has no settings endpoint. */
export async function getManagedSettings(): Promise<ManagedSettings | null> {
  try { return await api<ManagedSettings>("/api/managed-machines/settings", { method: "GET" }); }
  catch (error) { if (error instanceof ApiError && (error.status === 404 || error.status === 405)) return null; throw error; }
}
export const putManagedSettings = (body: ManagedSettings) =>
  api<ManagedSettings>("/api/managed-machines/settings", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export const isLive = (m: Pick<ManagedMachine, "state">) => m.state !== "destroyed" && m.state !== "failed" && m.state !== "stopped";
/** Stopped: disk kept, nothing billed, resumable within the retention. */
export const isStopped = (m: Pick<ManagedMachine, "state">) => m.state === "stopped";

/** "$0.42", "$12.30", "<$0.01" for tiny non-zero amounts. */
export function usd(amount: number | null | undefined): string {
  if (amount == null || !Number.isFinite(amount)) return "—";
  if (amount > 0 && amount < 0.01) return "<$0.01";
  return `$${amount.toFixed(2)}`;
}
/** "$0.12/h"; three decimals under ten cents so cheap sizes stay distinct. */
export function usdPerHour(rate: number | null | undefined): string {
  if (rate == null || !Number.isFinite(rate)) return "—";
  return `$${rate < 0.1 && rate > 0 ? rate.toFixed(3) : rate.toFixed(2)}/h`;
}

/** Time left until `expiresAt`: "1h 05m", "4m 09s", "Expired". */
export function ttlLeft(expiresAt: string, now = Date.now()): string {
  const end = Date.parse(expiresAt);
  if (!Number.isFinite(end)) return "—";
  const s = Math.floor((end - now) / 1000);
  if (s <= 0) return "Expired";
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  return `${m}m ${String(sec).padStart(2, "0")}s`;
}
/** Under ten minutes left: the countdown is highlighted. */
export const ttlUrgent = (expiresAt: string, now = Date.now()) => {
  const left = Date.parse(expiresAt) - now;
  return Number.isFinite(left) && left < 10 * 60_000;
};

/** "30 min", "1 h", "1 h 30 min". */
export function minutesLabel(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return h && m ? `${h} h ${m} min` : h ? `${h} h` : `${m} min`;
}

/** Cost so far, extrapolated between polls so it ticks with the countdown. */
export function liveCost(m: Pick<ManagedMachine, "cost_usd" | "usd_per_hour" | "state" | "expires_at">, fetchedAt: number, now = Date.now()): number {
  if (m.state !== "online" && m.state !== "enrolling" && m.state !== "provisioning") return m.cost_usd;
  const expires = Date.parse(m.expires_at);
  if (!Number.isFinite(expires)) return m.cost_usd;
  const until = Math.min(now, expires);
  return m.cost_usd + Math.max(0, until - fetchedAt) / 3_600_000 * m.usd_per_hour;
}

export const estimateCost = (usdPerHourRate: number, ttlMinutes: number) => usdPerHourRate * ttlMinutes / 60;

export const stateLabel = (s: string) =>
  s === "provisioning" || s === "enrolling" ? "Starting…" : s === "online" ? "Online"
  : s === "destroying" ? "Destroying…" : s === "destroyed" ? "Destroyed" : s === "failed" ? "Failed" : s === "stopped" ? "Stopped" : s;

export const sizeSpec = (s: Pick<ManagedSize, "cpu" | "ram_gb"> & { disk_gb?: number; gpu?: string | null; arch?: string | null }) =>
  [
    `${s.cpu} vCPU · ${s.ram_gb} GB`,
    s.gpu ? s.gpu : "",
    s.arch && s.arch !== "x86_64" ? s.arch : "",
    s.disk_gb != null && s.disk_gb > 0 ? `${s.disk_gb} GB disk` : "",
  ].filter(Boolean).join(" · ");

export const providerLabel = (provider?: string | null): string => {
  const key = (provider ?? "boat").toLowerCase();
  if (key === "boat") return "boat.dev";
  if (key === "hetzner") return "Hetzner";
  if (key === "vastai") return "Vast.ai";
  if (key === "scaleway") return "Scaleway";
  return provider || "boat.dev";
};

export function managedSectionTitle(providers?: readonly ManagedProviderInfo[], machines?: readonly Pick<ManagedMachine, "provider">[]): string {
  const multiConfigured = (providers ?? []).some(p => p.configured && p.provider !== "boat");
  const multiActive = (machines ?? []).some(m => m.provider && m.provider !== "boat");
  return multiConfigured || multiActive ? "Managed cloud" : "Managed (boat.dev)";
}

export function canStopMachine(m: Pick<ManagedMachine, "state" | "provider">, providers?: readonly ManagedProviderInfo[]): boolean {
  if (m.state !== "online") return false;
  const p = m.provider || "boat";
  const info = providers?.find(x => x.provider === p);
  return info ? info.supports_free_stop : p === "boat";
}

/** "$1.20 spent today of $20.00 · 1 of 3 running"; unlimited caps drop their "of …". */
export const budgetLine = (b: ManagedBudget) =>
  `${usd(b.spent_today_usd)} spent today${b.daily_cap_usd != null ? ` of ${usd(b.daily_cap_usd)}` : ""} · ${b.active}${b.max_concurrent != null ? ` of ${b.max_concurrent}` : ""} running`;

/** Budget still available today; null when there is no daily cap. */
export const budgetLeft = (b: ManagedBudget) => b.daily_cap_usd == null ? null : b.daily_cap_usd - b.spent_today_usd;
/** True when a set cap stops new machines. Null caps never block. */
export const budgetFull = (b: ManagedBudget) =>
  (b.max_concurrent != null && b.active >= b.max_concurrent) || (b.daily_cap_usd != null && b.spent_today_usd >= b.daily_cap_usd);

/** Display name of a size: the provider's "default" size is medium. */
export const sizeLabel = (size: string) => size === "default" ? "medium" : size;
/** "4 vCPU · 8 GB RAM · 50 GB": proportional, for row secondary lines. */
export const specLine = (s: { cpu: number; ram_gb: number; disk_gb?: number | null }) =>
  [s.cpu ? `${s.cpu} vCPU` : "", s.ram_gb ? `${s.ram_gb} GB RAM` : "", s.disk_gb ? `${s.disk_gb} GB` : ""].filter(Boolean).join(" · ");
/** "21 min left", "1 h 05 min left", "Expired". */
export function ttlShort(expiresAt: string, now = Date.now()): string {
  const end = Date.parse(expiresAt);
  if (!Number.isFinite(end)) return "";
  const min = Math.ceil((end - now) / 60_000);
  if (min <= 0) return "Expired";
  if (min < 60) return `${min} min left`;
  return `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")} min left`;
}
/** Remaining share of the TTL window, 0..1. */
export function ttlFraction(createdAt: string, expiresAt: string, now = Date.now()): number {
  const start = Date.parse(createdAt), end = Date.parse(expiresAt);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return 0;
  return Math.min(1, Math.max(0, (end - now) / (end - start)));
}
/** "<$0.01 so far · $0.036/h". */
export const costLine = (cost: number, rate: number) => `${usd(cost)} so far · ${usdPerHour(rate)}`;

/** Machines destroyed or failed during the last 24 hours, newest first. */
export function recentMachines(machines: ManagedMachine[], now = Date.now()): ManagedMachine[] {
  return machines.filter(m => !isLive(m) && !isStopped(m)).filter(m => {
    const t = Date.parse(m.destroyed_at ?? m.created_at);
    return Number.isFinite(t) && now - t <= 86_400_000;
  }).sort((a, b) => Date.parse(b.destroyed_at ?? b.created_at) - Date.parse(a.destroyed_at ?? a.created_at));
}

/** Sizes the budget allows: up to `max_size` in the server's order. */
export function allowedSizes(sizes: ManagedSize[], maxSize?: string): ManagedSize[] {
  const cut = maxSize ? sizes.findIndex(s => s.size === maxSize) : -1;
  return cut >= 0 ? sizes.slice(0, cut + 1) : sizes;
}

/** Human message for a failed managed-machine request. */
export function managedError(error: unknown): string {
  if (!(error instanceof ApiError)) return error instanceof Error ? error.message : String(error);
  let code = "", message = "";
  try { const body = JSON.parse(error.detail); code = body?.error ?? ""; message = body?.message ?? ""; } catch { message = error.detail; }
  const prefix = code === "budget_exceeded" ? "Daily budget reached" : code === "quota_exceeded" ? "Machine limit reached" : "";
  if (prefix) return message ? `${prefix}: ${message}` : `${prefix}.`;
  return message || `Request failed (${error.status})`;
}

/** Totals for the spend chart header: the window's sum, today (the last day) and the tallest bar. */
export function spendSummary(days: readonly DailySpend[]) {
  const total = days.reduce((sum, d) => sum + d.usd, 0);
  return { total, today: days.at(-1)?.usd ?? 0, max: days.reduce((m, d) => Math.max(m, d.usd), 0) };
}

/** Bar height as a 0…1 fraction of the tallest day; zero days stay at 0 (drawn as a baseline). */
export const spendFraction = (usd: number, max: number) => max > 0 && usd > 0 ? Math.max(usd / max, 0.04) : 0;

/** "Mon" for an ISO `YYYY-MM-DD` UTC day. */
export const spendWeekday = (day: string) => new Date(`${day}T00:00:00Z`).toLocaleDateString(undefined, { weekday: "short", timeZone: "UTC" });
/** "Mon 20 Oct" for an ISO `YYYY-MM-DD` UTC day. */
export const spendDayLabel = (day: string) => new Date(`${day}T00:00:00Z`).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });

/** The first `top` mission ids of a day (null = no mission) and how many more there are. */
export const topMissions = (d: DailySpend, top = 2) => ({ ids: d.missions.slice(0, top).map(m => m.mission_id), more: Math.max(0, d.missions.length - top) });

/** "Mon 20 Oct · $0.53 · Fix login $0.50, Mission 1a2b3c4d $0.03 +1 more". */
export function spendDayDetail(d: DailySpend, title: (missionId: string) => string | undefined, top = 2): string {
  if (d.usd <= 0) return `${spendDayLabel(d.day)} · no spend`;
  const name = (id: string | null) => id ? title(id) ?? `Mission ${id.slice(0, 8)}` : "No mission";
  const parts = d.missions.slice(0, top).map(m => `${name(m.mission_id)} ${usd(m.usd)}`);
  const { more } = topMissions(d, top);
  return `${spendDayLabel(d.day)} · ${usd(d.usd)}${parts.length ? ` · ${parts.join(", ")}` : ""}${more > 0 ? ` +${more} more` : ""}`;
}

/** Who owns a machine, for the owner chip (spec: docs/specs/managed-vm-lifecycle.md). */
export type MachineOwner = { kind: "mission"; missionId: string } | { kind: "user" } | { kind: "none" };
export function machineOwner(m: Pick<ManagedMachine, "owner_mission_id" | "owner_kind">): MachineOwner {
  if (m.owner_mission_id) return { kind: "mission", missionId: m.owner_mission_id };
  return m.owner_kind === "user" ? { kind: "user" } : { kind: "none" };
}

/** Human text for a reap reason: "owner_completed" -> "owner completed". */
export const reapReasonLabel = (reason: string) => ({
  ttl_expired: "TTL", idle_no_owner: "idle, no owner", idle_user_owned: "idle",
  working_owner_idle: "idle", owner_missing: "owner deleted",
}[reason] ?? reason.replace(/^owner_/, "owner ").replace(/_idle$/, ", idle").replace(/_/g, " "));

/** "Reaps in 4 min (owner completed)", "Reap due (owner failed)"; null when nothing is scheduled. */
export function reapLine(m: Pick<ManagedMachine, "reap_at" | "reap_reason" | "deletable_at" | "state">, now = Date.now()): string | null {
  if (!isLive(m)) return null;
  if (m.reap_reason?.startsWith("awaiting_deletable_at:")) {
    const raw = m.deletable_at ?? m.reap_at;
    const at = raw ? Date.parse(raw) : NaN;
    if (!Number.isFinite(at)) return null;
    const min = Math.ceil((at - now) / 60_000);
    if (min <= 0) return "24h lease ended · deleting";
    return min < 60 ? `Deletes when 24h lease ends in ${min} min` : `Deletes when 24h lease ends in ${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")} min`;
  }
  if (!m.reap_at) return null;
  const at = Date.parse(m.reap_at);
  if (!Number.isFinite(at)) return null;
  const why = m.reap_reason ? ` (${reapReasonLabel(m.reap_reason)})` : "";
  const min = Math.ceil((at - now) / 60_000);
  if (min <= 0) return `Reap due${why}`;
  return min < 60 ? `Reaps in ${min} min${why}` : `Reaps in ${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")} min${why}`;
}
