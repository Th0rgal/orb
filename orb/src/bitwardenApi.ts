import { api } from "./api";
import { signedApi } from "./deviceApproval";

export interface BitwardenStatus {
  configured: boolean;
  token_source: string | null;
  token_hint: string | null;
  bws_installed: boolean;
  bws_version: string | null;
  server_url: string | null;
  default_project_id: string;
  project_bindings: Record<string, string>;
  default_access?: Record<string, string[]>;
  pending_requests?: number;
}

export interface BitwardenProject {
  id: string;
  name: string;
  organizationId?: string;
  creationDate?: string;
  revisionDate?: string;
}

export interface BitwardenSecretSummary {
  id: string;
  key: string;
  note: string;
  projectId?: string;
  organizationId?: string;
  creationDate?: string;
  revisionDate?: string;
}

export interface BitwardenSecretDetail extends BitwardenSecretSummary {
  value: string;
}

export interface UpdateBitwardenConfigPayload {
  access_token?: string;
  server_url?: string;
  default_project_id?: string;
  project_bindings?: Record<string, string>;
  skip_validation?: boolean;
}

export interface BiometricStatus {
  available: boolean;
  kind: "touch_id" | "passcode" | "none" | string;
  label: string;
}

type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

function tauriInvoke(): Invoke | null {
  if (typeof window === "undefined") return null;
  const g = window as unknown as {
    __TAURI__?: { core?: { invoke?: Invoke } };
    __TAURI_INTERNALS__?: { invoke?: Invoke };
  };
  return g.__TAURI__?.core?.invoke ?? g.__TAURI_INTERNALS__?.invoke ?? null;
}

export async function getBiometricStatus(): Promise<BiometricStatus> {
  const invoke = tauriInvoke();
  if (!invoke) {
    return { available: false, kind: "none", label: "Touch ID" };
  }
  try {
    return (await invoke("biometric_status")) as BiometricStatus;
  } catch {
    return { available: false, kind: "none", label: "Touch ID" };
  }
}

export async function authenticateBiometric(reason: string): Promise<void> {
  const invoke = tauriInvoke();
  if (!invoke) return;
  await invoke("biometric_authenticate", { reason });
}

export const getBitwardenStatus = () =>
  api<BitwardenStatus>("/api/bitwarden/status");

export const updateBitwardenConfig = (payload: UpdateBitwardenConfigPayload) =>
  signedApi<BitwardenStatus>("PUT", "/api/bitwarden/config", payload, "change the Bitwarden connection");

export const listBitwardenProjects = () =>
  api<BitwardenProject[]>("/api/bitwarden/projects");

export const listBitwardenSecrets = (projectId: string) =>
  api<BitwardenSecretSummary[]>(
    `/api/bitwarden/projects/${encodeURIComponent(projectId)}/secrets`,
  );

export const revealBitwardenSecret = (secretId: string, name = "a secret") =>
  signedApi<BitwardenSecretDetail>(
    "GET",
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}/reveal`,
    undefined,
    `reveal ${name}`,
  );

export const createBitwardenSecret = (
  projectId: string,
  payload: { key: string; value: string; note?: string },
) =>
  signedApi<BitwardenSecretDetail>(
    "POST",
    `/api/bitwarden/projects/${encodeURIComponent(projectId)}/secrets`,
    payload,
    `create secret ${payload.key}`,
  );

export const updateBitwardenSecret = (
  secretId: string,
  payload: { key?: string; value?: string; note?: string; project_id?: string },
) =>
  signedApi<BitwardenSecretDetail>(
    "PUT",
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}`,
    payload,
    `edit secret ${payload.key ?? ""}`.trim(),
  );

export const deleteBitwardenSecret = (secretId: string, name = "a secret") =>
  signedApi<{ success: boolean }>(
    "DELETE",
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}`,
    undefined,
    `delete ${name}`,
  );

/** True when the user dismissed the Touch ID / password sheet. */
export const isBiometricCancelled = (e: unknown) =>
  (e instanceof Error ? e.message : String(e)) === "biometric_cancelled";

export interface BitwardenSecretWithProject extends BitwardenSecretSummary {
  projectName?: string | null;
}

export type SecretGrantScope =
  | { kind: "secret"; key: string }
  | { kind: "project"; project_id: string }
  | { kind: "all" };

export interface SecretGrant {
  id: string;
  mission_id: string;
  mission_title?: string | null;
  paloma_project?: string | null;
  scope: SecretGrantScope;
  created_at: string;
  expires_at: string;
}

export interface SecretAccessRequest {
  id: string;
  kind: "read" | "write" | "delete" | "move";
  status: "pending" | "approved" | "rejected" | "expired";
  mission_id: string;
  mission_title?: string | null;
  paloma_project?: string | null;
  key?: string | null;
  project_id?: string | null;
  all_projects: boolean;
  reason: string;
  note?: string | null;
  /** Destination project of a move. */
  target_project_id?: string | null;
  created_at: string;
  resolved_at?: string | null;
  error?: string | null;
}

/** Button verb for a request that changes Bitwarden, or null for a read. */
export function secretChangeVerb(r: Pick<SecretAccessRequest, "kind">): "Store" | "Delete" | "Move" | null {
  return r.kind === "write" ? "Store" : r.kind === "delete" ? "Delete" : r.kind === "move" ? "Move" : null;
}

export interface SecretAuditEntry {
  at: string;
  mission_id: string;
  paloma_project?: string | null;
  key: string;
  project_id?: string | null;
  via: "default" | "grant" | "write" | "delete" | "move" | string;
}

export interface SecretBrokerSnapshot {
  requests: SecretAccessRequest[];
  grants: SecretGrant[];
  audit: SecretAuditEntry[];
}

export const listAllBitwardenSecrets = () =>
  api<BitwardenSecretWithProject[]>("/api/bitwarden/secrets");

export const getSecretBroker = () =>
  api<SecretBrokerSnapshot>("/api/bitwarden/broker");

/** Tell the app a request was answered, so badges update now (the poll pauses in the background). */
const answered = <T,>(id: string, result: Promise<T>) =>
  result.then((value) => { window.dispatchEvent(new CustomEvent("orb:secret-request-answered", { detail: { id } })); return value; });

export const approveSecretRequest = (
  id: string,
  scope?: "secret" | "project" | "all",
  ttlHours?: number,
  summary = "approve a mission's secret request",
) =>
  answered(id, signedApi<SecretAccessRequest>(
    "POST",
    `/api/bitwarden/requests/${encodeURIComponent(id)}/approve`,
    { scope, ttl_hours: ttlHours },
    summary,
  ));

export const rejectSecretRequest = (id: string) =>
  answered(id, signedApi<SecretAccessRequest>(
    "POST",
    `/api/bitwarden/requests/${encodeURIComponent(id)}/reject`,
    undefined,
    "decline a mission's secret request",
  ));

export const revokeSecretGrant = (id: string) =>
  api<{ success: boolean }>(`/api/bitwarden/grants/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });

export const setSecretDefaultAccess = (slug: string, projectIds: string[]) =>
  signedApi<BitwardenStatus>(
    "PUT",
    `/api/bitwarden/default-access/${encodeURIComponent(slug)}`,
    { project_ids: projectIds },
    `change default secret access for ${slug}`,
  );

/** Group secret names by their first `_` segment (`CLOUDFLARE_API_TOKEN` → `CLOUDFLARE`). */
export function secretPrefix(key: string): string {
  const i = key.indexOf("_");
  return i > 0 ? key.slice(0, i) : key;
}

/**
 * Project → prefix → secrets. A prefix shared by a single secret is folded
 * into an "Other" group so the tree does not fill with one-item folders.
 */
export function groupSecrets<T extends { key: string; projectId?: string; projectName?: string | null }>(
  secrets: T[],
): { projectId: string; projectName: string; groups: { prefix: string; items: T[] }[] }[] {
  const byProject = new Map<string, { name: string; items: T[] }>();
  for (const s of secrets) {
    const id = s.projectId ?? "";
    const entry = byProject.get(id) ?? { name: s.projectName || (id ? id.slice(0, 8) : "No project"), items: [] };
    entry.items.push(s);
    byProject.set(id, entry);
  }
  return [...byProject.entries()]
    .sort((a, b) => a[1].name.localeCompare(b[1].name))
    .map(([projectId, { name, items }]) => {
      const byPrefix = new Map<string, T[]>();
      for (const s of items) {
        const prefix = secretPrefix(s.key);
        byPrefix.set(prefix, [...(byPrefix.get(prefix) ?? []), s]);
      }
      const groups: { prefix: string; items: T[] }[] = [];
      const other: T[] = [];
      for (const [prefix, list] of [...byPrefix.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
        if (list.length > 1) groups.push({ prefix, items: list.sort((a, b) => a.key.localeCompare(b.key)) });
        else other.push(...list);
      }
      if (other.length) groups.push({ prefix: "Other", items: other.sort((a, b) => a.key.localeCompare(b.key)) });
      return { projectId, projectName: name, groups };
    });
}
