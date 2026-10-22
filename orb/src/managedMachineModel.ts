/** Managed (boat.dev) machines: API client and presentation logic. */
import { api, ApiError } from "./api";

export type ManagedState = "provisioning" | "enrolling" | "online" | "destroying" | "destroyed" | "failed";

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
  reason?: string | null;
  error?: string | null;
  ledger_closed: boolean;
}

export interface ManagedSize { size: string; cpu: number; ram_gb: number; disk_gb: number; usd_per_hour: number }

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

export interface ManagedMachinesResponse { machines: ManagedMachine[]; budget: ManagedBudget; sizes: ManagedSize[]; enabled: boolean }

export interface CreateManagedMachine { wait?: boolean; size?: string; cpu?: number; ram_gb?: number; ttl_minutes?: number; image?: string; reason?: string }

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

export const isLive = (m: Pick<ManagedMachine, "state">) => m.state !== "destroyed" && m.state !== "failed";

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
  : s === "destroying" ? "Destroying…" : s === "destroyed" ? "Destroyed" : s === "failed" ? "Failed" : s;

export const sizeSpec = (s: Pick<ManagedSize, "cpu" | "ram_gb"> & { disk_gb?: number }) =>
  `${s.cpu} vCPU · ${s.ram_gb} GB${s.disk_gb != null ? ` · ${s.disk_gb} GB disk` : ""}`;

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
  return machines.filter(m => !isLive(m)).filter(m => {
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
