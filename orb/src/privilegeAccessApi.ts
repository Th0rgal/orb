import { api } from "./api";
import { signedApi } from "./deviceApproval";
import type { AccessState } from "./missionAccessApi";
import { missionLabel } from "./missionAccessApi";

/**
 * Privileged access requests: a mission asks for root, a service deploy or
 * read-only ops access on a host, usually for the rest of its session.
 * Approving needs this device's Touch ID signature (Core always requires it
 * and decides every command against the grant); grants expire, end with the
 * mission session, and can be revoked.
 */
export type PrivilegeScope = "ops_read" | "service_deploy" | "root_exec";

export interface PrivilegeRequest {
  id: string;
  requester_mission_id: string;
  requester_title?: string | null;
  target_host: string;
  scope: PrivilegeScope;
  allowed_unit?: string | null;
  reason: string;
  session_scoped: boolean;
  ttl_minutes: number;
  state: AccessState;
  created_at: string;
  decided_at?: string | null;
  expires_at?: string | null;
  revoked_at?: string | null;
}

export interface PrivilegeAudit {
  at: string;
  request_id: string;
  requester_mission_id: string;
  target_host: string;
  scope: PrivilegeScope;
  action: string;
  detail?: string | null;
}

export interface PrivilegeCommandAudit {
  id: string;
  at: string;
  grant_id: string;
  mission_id: string;
  target_host: string;
  scope: PrivilegeScope;
  command: string;
  exit_code?: number | null;
  duration_ms?: number | null;
}

export interface PrivilegeSnapshot {
  bunker_state: number;
  requests: PrivilegeRequest[];
  audit: PrivilegeAudit[];
  command_audit: PrivilegeCommandAudit[];
}

export const emptyPrivilegeSnapshot = (): PrivilegeSnapshot => ({ bunker_state: 0, requests: [], audit: [], command_audit: [] });

export const getPrivilegeAccess = () => api<PrivilegeSnapshot>("/api/privilege-access");

const answered = <T,>(id: string, result: Promise<T>) =>
  result.then((value) => { window.dispatchEvent(new CustomEvent("orb:privilege-access-answered", { detail: { id } })); return value; });

const SCOPE_LABEL: Record<PrivilegeScope, string> = {
  ops_read: "Read-only ops",
  service_deploy: "Service deploy",
  root_exec: "Root",
};
const SCOPE_UNLOCKS: Record<PrivilegeScope, string> = {
  ops_read: "logs, status and disk checks as root; no changes",
  service_deploy: "restart and deploy services, including production",
  root_exec: "any command as root",
};
export const scopeLabel = (s: PrivilegeScope) => SCOPE_LABEL[s] ?? s;
export const scopeUnlocks = (r: Pick<PrivilegeRequest, "scope" | "allowed_unit">) =>
  r.scope === "service_deploy" && r.allowed_unit ? `restart and deploy ${r.allowed_unit} only` : SCOPE_UNLOCKS[r.scope] ?? "";
export const hostLabel = (h: string) => (h === "self" ? "its own node" : h);
export const requesterLabel = (r: Pick<PrivilegeRequest, "requester_title" | "requester_mission_id">) =>
  missionLabel(r.requester_title, r.requester_mission_id);
/** "for this session (max 4 h)" or "for 30 min". */
export function lifetimeLabel(r: Pick<PrivilegeRequest, "session_scoped" | "ttl_minutes">): string {
  const m = r.ttl_minutes;
  const span = m >= 60 && m % 60 === 0 ? `${m / 60} h` : `${m} min`;
  return r.session_scoped ? `for this session (max ${span})` : `for ${span}`;
}

export const approvePrivilegeAccess = (r: PrivilegeRequest) =>
  answered(r.id, signedApi<PrivilegeRequest>(
    "POST",
    `/api/privilege-access/${encodeURIComponent(r.id)}/approve`,
    { ttl_minutes: r.ttl_minutes, session_scoped: r.session_scoped },
    `grant ${scopeLabel(r.scope)} on ${hostLabel(r.target_host)} to ${requesterLabel(r)}`,
  ));

export const denyPrivilegeAccess = (r: PrivilegeRequest) =>
  answered(r.id, signedApi<PrivilegeRequest>(
    "POST",
    `/api/privilege-access/${encodeURIComponent(r.id)}/deny`,
    undefined,
    "decline a privileged access request",
  ));

export const revokePrivilegeAccess = (id: string) =>
  answered(id, api<PrivilegeRequest>(`/api/privilege-access/${encodeURIComponent(id)}`, { method: "DELETE" }));

/** Approved and not yet expired (Core still decides every command). */
export const livePrivilegeGrant = (r: PrivilegeRequest, now = Date.now()) =>
  r.state === "approved" && !r.revoked_at && !!r.expires_at && Date.parse(r.expires_at) > now;
