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

export interface BunkerIncident {
  id: string;
  at: string;
  source: string;
  peer_name?: string | null;
  canary_kind?: string | null;
  previous_bunker_state: number;
  new_bunker_state: number;
  epoch: number;
  dry_run: boolean;
  reason: string;
  pid?: number | null;
  uid?: number | null;
  cgroup?: string | null;
  cmdline?: string | null;
  detail_sha256_hex?: string | null;
  alert_delivered: boolean;
  alert_channels: string[];
  alert_error?: string | null;
}

export interface PrivilegeSnapshot {
  bunker_state: number;
  requests: PrivilegeRequest[];
  audit: PrivilegeAudit[];
  command_audit: PrivilegeCommandAudit[];
  bunker_incidents?: BunkerIncident[];
}

export interface MeshStatusSnapshot {
  epoch: number;
  bunker_state: number;
  last_heartbeat_at: number;
  formal_verified: boolean;
}

export const emptyPrivilegeSnapshot = (): PrivilegeSnapshot => ({
  bunker_state: 0,
  requests: [],
  audit: [],
  command_audit: [],
  bunker_incidents: [],
});

export const getPrivilegeAccess = () => api<PrivilegeSnapshot>("/api/privilege-access");
export const getMeshStatus = () => api<MeshStatusSnapshot>("/api/mesh/status");

const BUNKER_LABELS: Record<number, string> = {
  0: "Normal",
  1: "Soft Quarantine",
  2: "Hard Lockdown",
  3: "Sovereign Dead-Man Tripped",
};
export const bunkerStateLabel = (state: number): string =>
  BUNKER_LABELS[state] ?? `Locked (${state})`;

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
export const requestTitle = (r: Pick<PrivilegeRequest, "scope" | "target_host">) => `${scopeLabel(r.scope)} on ${hostLabel(r.target_host)}`;
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

export const triggerBunker = (
  level: 1 | 2 = 2,
  reason = "Operator manual Fleet Bunker lockdown",
) =>
  answered(
    "bunker",
    signedApi<{ status: string; bunker_state: number }>(
      "POST",
      "/api/privilege-access/bunker",
      {
        level,
        reason,
        canary_tripped: level >= 2,
        auth_failure_burst: level === 1,
      },
      level >= 2
        ? "enter Hard Bunker Lockdown across the fleet"
        : "enter Soft Quarantine across the fleet",
    ),
  );

export const unbunkerFleet = () =>
  answered(
    "unbunker",
    signedApi<{ status: string; bunker_state: number }>(
      "POST",
      "/api/privilege-access/unbunker",
      undefined,
      "exit Fleet Bunker Mode",
    ),
  );

/** Approved and not yet expired (Core still decides every command). */
export const livePrivilegeGrant = (r: PrivilegeRequest, now = Date.now()) =>
  r.state === "approved" && !r.revoked_at && !!r.expires_at && Date.parse(r.expires_at) > now;

/** Highest tier first, so a root grant leads every batch summary. */
const TIER_ORDER: PrivilegeScope[] = ["root_exec", "service_deploy", "ops_read"];
const uniqSorted = (xs: string[]) => [...new Set(xs)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

/** What one "Approve all" would grant: count per tier, hosts and missions. */
export function batchSummary(rs: PrivilegePick[]) {
  const tiers = TIER_ORDER
    .map((s) => [s, rs.filter((r) => r.scope === s).length] as const)
    .filter(([, n]) => n > 0)
    .map(([s, n]) => `${n} ${scopeLabel(s)}`)
    .join(" · ");
  return {
    tiers,
    hosts: uniqSorted(rs.map((r) => r.target_host)).map(hostLabel).join(", "),
    missions: uniqSorted(rs.map(requesterLabel)).join(", "),
    root: rs.filter((r) => r.scope === "root_exec").length,
  };
}
type PrivilegePick = Pick<PrivilegeRequest, "scope" | "target_host" | "requester_title" | "requester_mission_id">;

/**
 * The requests "Approve all" covers. Root is left out unless the approver
 * ticked it: one fingerprint should never grant root by accident. Core
 * enforces the same rule (`confirm_root`).
 */
export const batchApprovable = <T extends Pick<PrivilegeRequest, "scope">>(rs: T[], includeRoot: boolean) =>
  rs.filter((r) => includeRoot || r.scope !== "root_exec");

/** One signature for exactly these requests, as shown; Core refuses the whole batch if any changed. */
export const approveAllPrivilegeAccess = (rs: PrivilegeRequest[]) => {
  const s = batchSummary(rs);
  return signedApi<PrivilegeRequest[]>(
    "POST",
    "/api/privilege-access/approve-all",
    {
      items: rs.map((r) => ({
        id: r.id,
        requester_mission_id: r.requester_mission_id,
        target_host: r.target_host,
        scope: r.scope,
        allowed_unit: r.allowed_unit ?? null,
        ttl_minutes: r.ttl_minutes,
        session_scoped: r.session_scoped,
      })),
      confirm_root: s.root > 0,
    },
    `grant ${rs.length} privileged requests (${s.tiers}) on ${s.hosts}`,
  ).then((out) => {
    for (const r of rs) window.dispatchEvent(new CustomEvent("orb:privilege-access-answered", { detail: { id: r.id } }));
    return out;
  });
};
