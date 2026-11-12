import { api, ApiError } from "./api";
import { signedApi } from "./deviceApproval";
import type { AccessState, RequesterSubject } from "./missionAccessApi";
import { actorLabel } from "./missionAccessApi";

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
  requester_mission_id?: string | null;
  requester?: RequesterSubject | null;
  requester_label?: string | null;
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
  requester_mission_id?: string | null;
  requester?: RequesterSubject | null;
  requester_label?: string | null;
  target_host: string;
  scope: PrivilegeScope;
  action: string;
  detail?: string | null;
}

export interface PrivilegeCommandAudit {
  id: string;
  at: string;
  grant_id: string;
  mission_id?: string | null;
  requester?: RequesterSubject | null;
  requester_label?: string | null;
  mission_title?: string | null;
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

type RawPrivilegeRequest = Partial<PrivilegeRequest> & {
  status?: string;
  mission_id?: string | null;
  allowed_units?: unknown;
  expires_at_epoch?: number | null;
};

type RawPrivilegeGrant = {
  id?: string;
  grant_id?: string;
  mission_id?: string | null;
  revoked?: boolean;
  expires_at?: string | null;
  expires_at_epoch?: number | null;
};

export function normalizePrivilegeRequest(
  raw: RawPrivilegeRequest,
  grants: RawPrivilegeGrant[] = [],
): PrivilegeRequest {
  const rawState = String(raw.state ?? raw.status ?? "pending").trim();
  let state: AccessState =
    rawState === "approved" || rawState === "denied" || rawState === "expired" || rawState === "revoked"
      ? rawState
      : rawState === "rejected"
        ? "denied"
        : "pending";
  const units = Array.isArray(raw.allowed_units)
    ? raw.allowed_units.filter((u): u is string => typeof u === "string" && u.trim().length > 0)
    : [];
  const allowedUnit =
    typeof raw.allowed_unit === "string" && raw.allowed_unit.trim().length > 0
      ? raw.allowed_unit.trim()
      : units[0] ?? null;
  const missionId =
    (typeof raw.requester_mission_id === "string" && raw.requester_mission_id) ||
    (typeof raw.mission_id === "string" && raw.mission_id) ||
    null;
  let expiresAt = typeof raw.expires_at === "string" && raw.expires_at ? raw.expires_at : null;
  if (!expiresAt && typeof raw.expires_at_epoch === "number" && raw.expires_at_epoch > 0) {
    expiresAt = new Date(raw.expires_at_epoch * 1000).toISOString();
  }
  const grantId = (raw as { grant_id?: string }).grant_id;
  const matchedGrant = grantId
    ? grants.find((g) => (g.grant_id || g.id) === grantId)
    : undefined;
  if (!expiresAt && matchedGrant) {
    if (typeof matchedGrant.expires_at === "string" && matchedGrant.expires_at) {
      expiresAt = matchedGrant.expires_at;
    } else if (typeof matchedGrant.expires_at_epoch === "number" && matchedGrant.expires_at_epoch > 0) {
      expiresAt = new Date(matchedGrant.expires_at_epoch * 1000).toISOString();
    }
  }
  let revokedAt = typeof raw.revoked_at === "string" && raw.revoked_at ? raw.revoked_at : null;
  if (matchedGrant?.revoked) {
    state = "revoked";
    if (!revokedAt) revokedAt = raw.decided_at ?? raw.created_at ?? new Date().toISOString();
  }
  const rawScope = String(raw.scope ?? "ops_read");
  const scope: PrivilegeScope =
    rawScope === "systemctl" ? "service_deploy" : (rawScope as PrivilegeScope);
  return {
    id: String(raw.id ?? ""),
    requester_mission_id: missionId,
    requester: raw.requester ?? (missionId ? null : { kind: "external_session", session_id: "external", client_kind: "cli", client_label: "sandboxed-mcp" }),
    requester_label: raw.requester_label ?? null,
    requester_title: raw.requester_title ?? null,
    target_host: String(raw.target_host || "self"),
    scope,
    allowed_unit: allowedUnit,
    reason: String(raw.reason ?? ""),
    session_scoped: typeof raw.session_scoped === "boolean" ? raw.session_scoped : true,
    ttl_minutes: Number(raw.ttl_minutes) || 30,
    state,
    created_at: String(raw.created_at ?? ""),
    decided_at: raw.decided_at ?? null,
    expires_at: expiresAt,
    revoked_at: revokedAt,
  };
}

export const getPrivilegeAccess = async (): Promise<PrivilegeSnapshot> => {
  const snap = await api<Partial<PrivilegeSnapshot> & { grants?: RawPrivilegeGrant[] }>("/api/privilege-access");
  const grants = Array.isArray(snap?.grants) ? snap.grants : [];
  const rawReqs = Array.isArray(snap?.requests) ? (snap.requests as RawPrivilegeRequest[]) : [];
  return {
    bunker_state: Number(snap?.bunker_state ?? 0),
    requests: rawReqs.map((r) => normalizePrivilegeRequest(r, grants)),
    audit: Array.isArray(snap?.audit) ? snap.audit : [],
    command_audit: Array.isArray(snap?.command_audit) ? snap.command_audit : [],
    bunker_incidents: Array.isArray(snap?.bunker_incidents) ? snap.bunker_incidents : [],
  };
};
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
export const requesterLabel = (
  r: Pick<PrivilegeRequest, "requester_title" | "requester_mission_id" | "requester_label" | "requester">,
) => actorLabel(r);
/** "for this session (max 4 h)" or "for 30 min". */
export function lifetimeLabel(r: Pick<PrivilegeRequest, "session_scoped" | "ttl_minutes">): string {
  const m = r.ttl_minutes;
  const span = m >= 60 && m % 60 === 0 ? `${m / 60} h` : `${m} min`;
  return r.session_scoped ? `for this session (max ${span})` : `for ${span}`;
}

const isMissingRoute = (e: unknown): boolean =>
  e instanceof ApiError && (e.status === 404 || e.status === 405);

export const approvePrivilegeAccess = (r: PrivilegeRequest) => {
  const id = encodeURIComponent(r.id);
  const body = { ttl_minutes: r.ttl_minutes, session_scoped: r.session_scoped };
  const summary = `grant ${scopeLabel(r.scope)} on ${hostLabel(r.target_host)} to ${requesterLabel(r)}`;
  return answered(
    r.id,
    signedApi<PrivilegeRequest>("POST", `/api/privilege-access/${id}/approve`, body, summary).catch((e) =>
      isMissingRoute(e)
        ? signedApi<PrivilegeRequest>("POST", `/api/privilege-access/requests/${id}/approve`, body, summary)
        : Promise.reject(e),
    ),
  );
};

export const denyPrivilegeAccess = (r: PrivilegeRequest) => {
  const id = encodeURIComponent(r.id);
  const summary = "decline a privileged access request";
  return answered(
    r.id,
    signedApi<PrivilegeRequest>("POST", `/api/privilege-access/${id}/deny`, undefined, summary).catch((e) =>
      isMissingRoute(e)
        ? signedApi<PrivilegeRequest>("POST", `/api/privilege-access/requests/${id}/reject`, undefined, summary)
        : Promise.reject(e),
    ),
  );
};

export const revokePrivilegeAccess = (id: string) => {
  const enc = encodeURIComponent(id);
  return answered(
    id,
    api<PrivilegeRequest>(`/api/privilege-access/${enc}`, { method: "DELETE" }).catch((e) =>
      isMissingRoute(e)
        ? api<PrivilegeRequest>(`/api/privilege-access/grants/${enc}`, { method: "DELETE" })
        : Promise.reject(e),
    ),
  );
};

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

