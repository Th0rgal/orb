/** Managed (boat.dev) machines: API client and presentation logic. */
import { api, ApiError } from "./api";

export type ManagedState = "provisioning" | "enrolling" | "online" | "destroying" | "destroyed" | "failed";

export interface ManagedMachine {
  id: string;
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
  daily_cap_usd: number;
  active: number;
  max_concurrent: number;
  default_ttl_minutes: number;
  max_ttl_minutes: number;
  default_size: string;
  max_size: string;
}

export interface ManagedMachinesResponse { machines: ManagedMachine[]; budget: ManagedBudget; sizes: ManagedSize[]; enabled: boolean }

export interface CreateManagedMachine { size?: string; cpu?: number; ram_gb?: number; ttl_minutes?: number; image?: string; reason?: string }

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

/** Remote nodes provisioned by the managed-machine service. */
export const isManagedNode = (node: { id?: string; labels?: string[] | null } | null | undefined) =>
  !!node && (!!node.labels?.includes("managed") || !!node.id?.startsWith("managed-"));

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
  const until = Math.min(now, Date.parse(m.expires_at) || now);
  return m.cost_usd + Math.max(0, until - fetchedAt) / 3_600_000 * m.usd_per_hour;
}

export const estimateCost = (usdPerHourRate: number, ttlMinutes: number) => usdPerHourRate * ttlMinutes / 60;

export const stateLabel = (s: string) =>
  s === "provisioning" ? "Provisioning" : s === "enrolling" ? "Enrolling" : s === "online" ? "Online"
  : s === "destroying" ? "Destroying" : s === "destroyed" ? "Destroyed" : s === "failed" ? "Failed" : s;

export const sizeSpec = (s: Pick<ManagedSize, "cpu" | "ram_gb"> & { disk_gb?: number }) =>
  `${s.cpu} vCPU · ${s.ram_gb} GB${s.disk_gb != null ? ` · ${s.disk_gb} GB disk` : ""}`;

/** "$1.20 spent today of $20.00 · 1 of 3 running". */
export const budgetLine = (b: ManagedBudget) =>
  `${usd(b.spent_today_usd)} spent today of ${usd(b.daily_cap_usd)} · ${b.active} of ${b.max_concurrent} running`;

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
