import { api } from "./api";
import { signedApi } from "./deviceApproval";

/**
 * Mission access requests: a mission asks to read another mission outside its
 * tree. Approving needs this device's Touch ID signature (Core always
 * requires it); grants are read-only, expire, and can be revoked.
 */
export type AccessState = "pending" | "approved" | "denied" | "expired" | "revoked";

export interface MissionAccessRequest {
  id: string;
  requester_mission_id: string;
  requester_title?: string | null;
  target_mission_id: string;
  target_title?: string | null;
  scope: "read";
  reason: string;
  ttl_hours: number;
  state: AccessState;
  created_at: string;
  decided_at?: string | null;
  expires_at?: string | null;
  revoked_at?: string | null;
}

export interface MissionAccessAudit {
  at: string;
  request_id: string;
  requester_mission_id: string;
  target_mission_id: string;
  action: "requested" | "approved" | "denied" | "expired" | "revoked" | "read" | string;
  detail?: string | null;
}

export interface MissionAccessSnapshot {
  requests: MissionAccessRequest[];
  audit: MissionAccessAudit[];
}

export const getMissionAccess = () => api<MissionAccessSnapshot>("/api/mission-access");

const answered = <T,>(id: string, result: Promise<T>) =>
  result.then((value) => { window.dispatchEvent(new CustomEvent("orb:mission-access-answered", { detail: { id } })); return value; });

export const missionLabel = (title: string | null | undefined, id: string) => title || `Mission ${id.slice(0, 8)}`;

export const approveMissionAccess = (r: MissionAccessRequest, ttlHours?: number) =>
  answered(r.id, signedApi<MissionAccessRequest>(
    "POST",
    `/api/mission-access/${encodeURIComponent(r.id)}/approve`,
    { ttl_hours: ttlHours ?? r.ttl_hours },
    `let ${missionLabel(r.requester_title, r.requester_mission_id)} read ${missionLabel(r.target_title, r.target_mission_id)}`,
  ));

export const denyMissionAccess = (r: MissionAccessRequest) =>
  answered(r.id, signedApi<MissionAccessRequest>(
    "POST",
    `/api/mission-access/${encodeURIComponent(r.id)}/deny`,
    undefined,
    "decline a mission access request",
  ));

export const revokeMissionAccess = (id: string) =>
  answered(id, api<MissionAccessRequest>(`/api/mission-access/${encodeURIComponent(id)}`, { method: "DELETE" }));

/** Approved and not yet expired. */
export const liveGrant = (r: MissionAccessRequest, now = Date.now()) =>
  r.state === "approved" && !!r.expires_at && Date.parse(r.expires_at) > now;
