import { api } from "./api";
import { signedApi } from "./deviceApproval";

/**
 * Mission access requests: a mission asks to read another mission outside its
 * tree. Approving needs this device's Touch ID signature (Core always
 * requires it); grants are read-only, expire, and can be revoked.
 */
export type AccessState = "pending" | "approved" | "denied" | "expired" | "revoked";
export type ExternalClientKind = "local_mcp" | "cli" | "ci" | "webhook";

export type RequesterSubject =
  | { kind: "mission"; mission_id: string }
  | {
      kind: "external_session";
      session_id: string;
      client_kind?: ExternalClientKind;
      client_label: string;
      host_hint?: string | null;
    };

export interface MissionAccessRequest {
  id: string;
  requester_mission_id?: string | null;
  requester?: RequesterSubject | null;
  requester_label?: string | null;
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
  requester_mission_id?: string | null;
  requester?: RequesterSubject | null;
  requester_label?: string | null;
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

const stripControls = (s: string) => s.replace(/[\u0000-\u001F\u007F-\u009F]/g, "").trim();

export function externalRequesterLabel(subject?: RequesterSubject | null): string | null {
  if (!subject || subject.kind !== "external_session") return null;
  const fallback = subject.client_kind || "local_mcp";
  const label = Array.from(stripControls(subject.client_label || "")).slice(0, 80).join("") || fallback;
  const host = Array.from(stripControls(subject.host_hint || "")).slice(0, 80).join("");
  return host ? `External · ${host} (${label})` : `External · ${label}`;
}

export function subjectKey(subject?: RequesterSubject | null, missionId?: string | null, label?: string | null): string {
  if (subject?.kind === "external_session") return `session:${subject.session_id}`;
  if (subject?.kind === "mission") return `mission:${subject.mission_id}`;
  if (missionId) return `mission:${missionId}`;
  return label ? `external:${label}` : "mission:";
}

async function sha256Hex(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function canonicalSubjectId(subject: RequesterSubject): Promise<string> {
  if (subject.kind === "mission") return `mission:${subject.mission_id}`;
  const kind = subject.client_kind || "local_mcp";
  const label = (subject.client_label || "").trim();
  const host = (subject.host_hint || "").trim();
  const labelHash = (await sha256Hex(`${label}\n${host}`)).slice(0, 16);
  return `session:${subject.session_id}:${kind}:${labelHash}`;
}

export async function approvalDigest(
  kind: string,
  id: string,
  subject: RequesterSubject,
  fields: string[],
): Promise<string> {
  const head =
    subject.kind === "mission"
      ? `orb-approval-v1\n${kind}\n${id}\n${subject.mission_id}`
      : `orb-approval-v2\n${kind}\n${id}\n${await canonicalSubjectId(subject)}`;
  return sha256Hex([head, ...fields].join("\n"));
}

export const missionLabel = (title: string | null | undefined, id: string | null | undefined) =>
  title || `Mission ${(id ?? "").slice(0, 8)}`;

export function actorLabel(r: {
  requester_label?: string | null;
  requester_subject?: RequesterSubject | null;
  requester?: RequesterSubject | null;
  requester_title?: string | null;
  mission_title?: string | null;
  requester_mission_id?: string | null;
  mission_id?: string | null;
}): string {
  if (r.requester_label) return r.requester_label;
  const ext = externalRequesterLabel(r.requester_subject ?? r.requester);
  if (ext) return ext;
  const title = r.requester_title || r.mission_title;
  if (title) return title;
  const subject = r.requester_subject ?? r.requester;
  const missionId = r.requester_mission_id || r.mission_id || (subject?.kind === "mission" ? subject.mission_id : "");
  return missionLabel(null, missionId);
}

export const approveMissionAccess = (r: MissionAccessRequest, ttlHours?: number) =>
  answered(r.id, signedApi<MissionAccessRequest>(
    "POST",
    `/api/mission-access/${encodeURIComponent(r.id)}/approve`,
    { ttl_hours: ttlHours ?? r.ttl_hours },
    `let ${actorLabel(r)} read ${missionLabel(r.target_title, r.target_mission_id)}`,
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
