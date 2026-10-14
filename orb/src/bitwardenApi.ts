import { api } from "./api";

export const PALOMA_BITWARDEN_PROJECT_ID = "297f3106-758f-43d5-8a4b-b460007558c8";

export interface BitwardenStatus {
  configured: boolean;
  token_source: string | null;
  token_hint: string | null;
  bws_installed: boolean;
  bws_version: string | null;
  server_url: string | null;
  default_project_id: string;
  project_bindings: Record<string, string>;
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
  api<BitwardenStatus>("/api/bitwarden/config", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

export const listBitwardenProjects = () =>
  api<BitwardenProject[]>("/api/bitwarden/projects");

export const listBitwardenSecrets = (projectId: string) =>
  api<BitwardenSecretSummary[]>(
    `/api/bitwarden/projects/${encodeURIComponent(projectId)}/secrets`,
  );

export const revealBitwardenSecret = (secretId: string) =>
  api<BitwardenSecretDetail>(
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}/reveal`,
  );

export const createBitwardenSecret = (
  projectId: string,
  payload: { key: string; value: string; note?: string },
) =>
  api<BitwardenSecretDetail>(
    `/api/bitwarden/projects/${encodeURIComponent(projectId)}/secrets`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    },
  );

export const updateBitwardenSecret = (
  secretId: string,
  payload: { key?: string; value?: string; note?: string; project_id?: string },
) =>
  api<BitwardenSecretDetail>(
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    },
  );

export const deleteBitwardenSecret = (secretId: string) =>
  api<{ success: boolean }>(
    `/api/bitwarden/secrets/${encodeURIComponent(secretId)}`,
    {
      method: "DELETE",
    },
  );

/** True when the user dismissed the Touch ID / password sheet. */
export const isBiometricCancelled = (e: unknown) =>
  (e instanceof Error ? e.message : String(e)) === "biometric_cancelled";
