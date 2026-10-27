import { api, ApiError } from "./api";
import { approveSecretRequest, getSecretBroker, type SecretAccessRequest } from "./bitwardenApi";
import { signedApi } from "./deviceApproval";
import { approveMissionAccess, getMissionAccess, missionLabel, type MissionAccessRequest } from "./missionAccessApi";
import { approvePrivilegeAccess, getPrivilegeAccess, lifetimeLabel, requestTitle, scopeUnlocks, type PrivilegeRequest, type PrivilegeScope } from "./privilegeAccessApi";

/**
 * Every request a mission raises for the user's approval, of any kind, as
 * Core lists it (`GET /api/approvals/queue`, src/api/approval_queue.rs).
 * Approving signs `{kind, id, digest}` for each item with one device
 * signature; Core admits the batch only when every item is still pending,
 * unchanged and, if critical, confirmed (the Lean `orb_verify_approval` gate).
 * Same names on iOS (OrbApprovalQueue.swift) and Android (OrbApprovalQueue.kt),
 * checked against shared/orb-spec/fixtures/approvals.json.
 */
export type ApprovalKind = "secret" | "privilege" | "mission_access";
export type ApprovalRisk = "routine" | "elevated" | "critical";

export interface ApprovalItem {
  kind: ApprovalKind;
  id: string;
  requester_mission_id: string;
  requester_title?: string | null;
  tier: string;
  target: string;
  risk: ApprovalRisk;
  reason: string;
  created_at: string;
  digest: string;
  /** The kind's own request, for labels. */
  request: Record<string, unknown>;
  /**
   * Built by this client from a per-kind list because Core has no queue yet
   * (it predates /api/approvals). No digest: approved through the kind's own
   * signed route, one request at a time.
   */
  legacy?: boolean;
}

/** Risk of a kind's tier, as Core assigns it (approvals.json `risk`). */
export function riskOf(kind: ApprovalKind, tier: string, request: Record<string, unknown> = {}): ApprovalRisk {
  if (kind === "privilege") return tier === "root_exec" ? "critical" : tier === "service_deploy" ? "elevated" : "routine";
  if (kind === "mission_access") return "elevated";
  if (tier === "delete" || tier === "move") return "critical";
  return tier === "write" || request.all_projects === true ? "elevated" : "routine";
}

/** A per-kind request as a queue item, for a Core without the queue. */
export function legacyItem(kind: ApprovalKind, r: PrivilegeRequest | SecretAccessRequest | MissionAccessRequest): ApprovalItem {
  const request = r as unknown as Record<string, unknown>;
  const tier = kind === "privilege" ? str(request.scope) : kind === "secret" ? str(request.kind) : "read_mission";
  const target = kind === "privilege" ? str(request.target_host) : kind === "mission_access" ? str(request.target_mission_id) : str(request.key) || str(request.project_id) || "*";
  return {
    kind,
    id: r.id,
    requester_mission_id: str(request.requester_mission_id) || str(request.mission_id),
    requester_title: (request.requester_title ?? request.mission_title ?? null) as string | null,
    tier,
    target,
    risk: riskOf(kind, tier, request),
    reason: str(request.reason),
    created_at: str(request.created_at),
    digest: "",
    request,
    legacy: true,
  };
}

/**
 * Every pending approval. A Core that predates the queue answers 404; then
 * the per-kind lists the earlier clients used build the same items, each
 * list on its own so one failure never hides the others' requests.
 */
export async function getApprovalQueue(): Promise<{ items: ApprovalItem[] }> {
  try {
    return await api<{ items: ApprovalItem[] }>("/api/approvals/queue");
  } catch (e) {
    if (!(e instanceof ApiError) || (e.status !== 404 && e.status !== 405)) throw e;
  }
  const [privilege, secrets, missions] = await Promise.allSettled([getPrivilegeAccess(), getSecretBroker(), getMissionAccess()]);
  const items = [
    ...(privilege.status === "fulfilled" ? privilege.value.requests.filter((r) => r.state === "pending").map((r) => legacyItem("privilege", r)) : []),
    ...(secrets.status === "fulfilled" ? secrets.value.requests.filter((r) => r.status === "pending").map((r) => legacyItem("secret", r)) : []),
    ...(missions.status === "fulfilled" ? missions.value.requests.filter((r) => r.state === "pending").map((r) => legacyItem("mission_access", r)) : []),
  ];
  if (!items.length && [privilege, secrets, missions].every((x) => x.status === "rejected")) throw (privilege as PromiseRejectedResult).reason;
  return { items: items.sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0)) };
}

const SECRET_VERB: Record<string, string> = { read: "Read", write: "Store", delete: "Delete", move: "Move" };
const RISK_ORDER: ApprovalRisk[] = ["critical", "elevated", "routine"];
const str = (v: unknown) => (typeof v === "string" ? v : "");

/** What approving does, in a few words ("Root on its own node", "Store DEPLOY_TOKEN"). */
export function itemTitle(i: Pick<ApprovalItem, "kind" | "tier" | "request">): string {
  const r = i.request;
  if (i.kind === "privilege") return requestTitle({ scope: str(r.scope) as PrivilegeScope, target_host: str(r.target_host) });
  if (i.kind === "mission_access") return `Read ${missionLabel(str(r.target_title) || null, str(r.target_mission_id))}`;
  const verb = SECRET_VERB[i.tier] ?? "Read";
  if (r.key) return `${verb} ${str(r.key)}`;
  return r.all_projects ? `${verb} every secret project` : `${verb} a whole secret project`;
}

/** Short project id until the Secrets page has loaded names. */
const shortProject = (id: string) => id.slice(0, 8);

/**
 * The fine print: what it unlocks and for how long, and for secrets the
 * project a write lands in, a delete removes from, or a move goes between.
 */
export function itemDetail(i: Pick<ApprovalItem, "kind" | "tier" | "request">, projectName: (id: string) => string = shortProject): string {
  const r = i.request;
  if (i.kind === "secret") {
    const from = str(r.project_id) ? projectName(str(r.project_id)) : "";
    if (i.tier === "move") return `From ${from || "unknown project"} to ${str(r.target_project_id) ? projectName(str(r.target_project_id)) : "unknown project"}`;
    if (i.tier === "delete") return `From ${from || "unknown project"}`;
    if (i.tier === "write") return from ? `Into ${from}` : "";
    return "";
  }
  if (i.kind === "privilege") {
    const p = { scope: str(r.scope) as PrivilegeScope, allowed_unit: str(r.allowed_unit) || null, session_scoped: r.session_scoped === true, ttl_minutes: Number(r.ttl_minutes) || 0 };
    return `Allows ${scopeUnlocks(p)} · ${lifetimeLabel(p)}`;
  }
  if (i.kind === "mission_access") return `Read only · ${Number(r.ttl_hours) || 0} h · no messages, cancel or resume`;
  return "";
}

export const itemRequester = (i: Pick<ApprovalItem, "requester_title" | "requester_mission_id">) =>
  missionLabel(i.requester_title, i.requester_mission_id);

const uniqSorted = (xs: string[]) => [...new Set(xs)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

/** The "Approve all" line: risks most severe first, then who asks. */
export function queueSummary(items: ApprovalItem[]) {
  return {
    risks: RISK_ORDER
      .map((k) => [k, items.filter((i) => i.risk === k).length] as const)
      .filter(([, n]) => n > 0)
      .map(([k, n]) => `${n} ${k}`)
      .join(" · "),
    missions: uniqSorted(items.map(itemRequester)).join(", "),
    critical: items.filter((i) => i.risk === "critical").length,
  };
}

/** What the device prompt says: every item, critical first (Core's own text is what gets signed). */
export function signingReason(items: ApprovalItem[]): string {
  if (items.length === 1) return `${itemTitle(items[0])} for ${itemRequester(items[0])}`;
  const sorted = [...items].sort((a, b) => RISK_ORDER.indexOf(a.risk) - RISK_ORDER.indexOf(b.risk));
  return `approve ${items.length} requests (${queueSummary(items).risks}): ${sorted.map(itemTitle).join("; ")}`;
}

/** What "Approve all" covers: critical items only when the approver ticked them. */
export const batchApprovable = (items: ApprovalItem[], includeCritical: boolean) =>
  items.filter((i) => includeCritical || i.risk !== "critical");

const answeredEvent: Record<ApprovalKind, string> = {
  secret: "orb:secret-request-answered",
  privilege: "orb:privilege-access-answered",
  mission_access: "orb:mission-access-answered",
};
const answered = (items: Pick<ApprovalItem, "kind" | "id">[]) => {
  for (const i of items) window.dispatchEvent(new CustomEvent(answeredEvent[i.kind], { detail: { id: i.id } }));
};

/**
 * Approve exactly these items with one signature. A single item is its own
 * confirmation; a batch includes critical items only when they were ticked
 * (the caller passes them in `items` only then).
 */
export async function approveItems(items: ApprovalItem[]) {
  if (items.some((i) => i.legacy)) return approveLegacy(items);
  const s = queueSummary(items);
  const out = await signedApi<unknown>(
    "POST",
    "/api/approvals/approve-all",
    { items: items.map((i) => ({ kind: i.kind, id: i.id, digest: i.digest })), confirm_critical: s.critical > 0 },
    signingReason(items),
  );
  answered(items);
  return out;
}

/**
 * A Core without the queue has no batch route: approve each request through
 * its kind's own signed route, with the lifetime it asked for (as the
 * clients before the queue did). Each call dispatches its "answered" event.
 */
async function approveLegacy(items: ApprovalItem[]) {
  for (const i of items) {
    if (i.kind === "privilege") await approvePrivilegeAccess(i.request as unknown as PrivilegeRequest);
    else if (i.kind === "mission_access") await approveMissionAccess(i.request as unknown as MissionAccessRequest);
    else await approveSecretRequest(i.id, undefined, undefined, signingReason([i]));
  }
}

const DENY_PATH: Record<ApprovalKind, (id: string) => string> = {
  secret: (id) => `/api/bitwarden/requests/${encodeURIComponent(id)}/reject`,
  privilege: (id) => `/api/privilege-access/${encodeURIComponent(id)}/deny`,
  mission_access: (id) => `/api/mission-access/${encodeURIComponent(id)}/deny`,
};

export async function denyItem(i: ApprovalItem) {
  const out = await signedApi<unknown>("POST", DENY_PATH[i.kind](i.id), undefined, `decline: ${itemTitle(i)}`);
  answered([i]);
  return out;
}
