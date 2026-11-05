import { api, apiText } from "./api";
import { sha256Hex, signedRawRequest } from "./deviceApproval";
import { nativeInvoke } from "./native";

export interface AuthStatusInfo {
  auth_mode: "disabled" | "single_tenant" | "multi_user" | string;
  password_source: "dashboard" | "environment" | "none" | string;
  password_changed_at?: string | null;
  dev_mode: boolean;
}

export function getAuthStatus(): Promise<AuthStatusInfo> {
  return api<AuthStatusInfo>("/api/auth/status");
}

export async function changeServerPassword(
  currentPassword: string | undefined,
  newPassword: string,
): Promise<void> {
  await api("/api/auth/change-password", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...(currentPassword && currentPassword.trim() ? { current_password: currentPassword } : {}),
      new_password: newPassword,
    }),
  });
}

export interface GitHubIntegrationStatus {
  configured: boolean;
  connected: boolean;
  pending: boolean;
  user_code?: string;
  verification_uri?: string;
  login?: string;
  name?: string | null;
  email?: string | null;
  scopes: string[];
  connected_at?: number;
}

export interface GitHubIntegrationAuthorizeResponse {
  user_code: string;
  verification_uri: string;
  verification_uri_complete?: string;
  interval: number;
  expires_in: number;
}

export async function getGitHubIntegrationStatus(): Promise<GitHubIntegrationStatus> {
  const res = await api<Partial<GitHubIntegrationStatus>>("/api/integrations/github/status");
  return {
    configured: Boolean(res?.configured),
    connected: Boolean(res?.connected),
    pending: Boolean(res?.pending),
    user_code: res?.user_code,
    verification_uri: res?.verification_uri,
    login: res?.login,
    name: res?.name,
    email: res?.email,
    scopes: Array.isArray(res?.scopes) ? res.scopes : [],
    connected_at: res?.connected_at,
  };
}

export function authorizeGitHubIntegration(): Promise<GitHubIntegrationAuthorizeResponse> {
  return api<GitHubIntegrationAuthorizeResponse>("/api/integrations/github/authorize", {
    method: "POST",
  });
}

export async function disconnectGitHubIntegration(): Promise<void> {
  await apiText("/api/integrations/github", { method: "DELETE" });
}

export interface RestoreBackupResponse {
  success: boolean;
  message: string;
  restored_files: string[];
  errors: string[];
}

export function interpretRestoreResponse(res: Partial<RestoreBackupResponse> | null | undefined): {
  ok: boolean;
  message: string;
} {
  const success = res?.success === true;
  const restored = Array.isArray(res?.restored_files)
    ? res!.restored_files.filter((f): f is string => typeof f === "string" && f.length > 0)
    : [];
  const errors = Array.isArray(res?.errors)
    ? res!.errors.filter((e): e is string => typeof e === "string" && e.length > 0)
    : [];
  const rawMessage = typeof res?.message === "string" ? res.message.trim() : "";
  if (!success) {
    const base = rawMessage || "No files were restored. The backup may be empty or invalid.";
    return {
      ok: false,
      message: errors.length ? `${base} (${errors.join("; ")})` : base,
    };
  }
  return {
    ok: true,
    message:
      rawMessage ||
      (restored.length ? `Restored ${restored.length} files (${restored.join(", ")}).` : "Backup restored."),
  };
}

function sanitizeMultipartFileName(raw: string): string {
  const clean = raw.replace(/[\r\n"\\/]/g, "_").trim();
  return clean || "backup.zip";
}

/**
 * Build deterministic `multipart/form-data` bytes for `POST /api/settings/restore`
 * so the exact wire bytes can be SHA-256 signed by `X-Paloma-Approval`.
 */
export function buildRestoreMultipartBody(
  zipBytes: Uint8Array,
  fileName = "backup.zip",
  boundary = `----OrbRestoreBoundary${crypto.randomUUID().replace(/-/g, "")}`,
): { body: Uint8Array; contentType: string; sha256: () => Promise<string> } {
  const safeName = sanitizeMultipartFileName(fileName);
  const enc = new TextEncoder();
  const preamble = enc.encode(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="backup"; filename="${safeName}"\r\n` +
      `Content-Type: application/zip\r\n\r\n`,
  );
  const epilogue = enc.encode(`\r\n--${boundary}--\r\n`);
  const body = new Uint8Array(preamble.byteLength + zipBytes.byteLength + epilogue.byteLength);
  body.set(preamble, 0);
  body.set(zipBytes, preamble.byteLength);
  body.set(epilogue, preamble.byteLength + zipBytes.byteLength);
  return {
    body,
    contentType: `multipart/form-data; boundary=${boundary}`,
    sha256: () => sha256Hex(body),
  };
}

function parseContentDispositionFilename(header: string | null): string {
  if (!header) return `sandboxed-backup-${new Date().toISOString().slice(0, 10)}.zip`;
  const m = /filename="?([^";\r\n]+)"?/i.exec(header);
  return m?.[1]?.trim() || `sandboxed-backup-${new Date().toISOString().slice(0, 10)}.zip`;
}

async function bytesToBase64(bytes: Uint8Array): Promise<string> {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export async function downloadSettingsBackup(): Promise<boolean> {
  const res = await signedRawRequest(
    "GET",
    "/api/settings/backup",
    "Download a backup of backend settings and keys",
  );
  const name = parseContentDispositionFilename(res.headers.get("content-disposition"));
  const buf = await res.arrayBuffer();
  const invoke = nativeInvoke();
  if (invoke) {
    const saved = await invoke<string | null>("save_file_as", {
      name,
      dataBase64: await bytesToBase64(new Uint8Array(buf)),
    });
    return saved !== null;
  }
  const blob = new Blob([buf], { type: "application/zip" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}

export async function restoreSettingsBackup(
  zipBytes: Uint8Array,
  fileName: string,
): Promise<RestoreBackupResponse> {
  const { body, contentType } = buildRestoreMultipartBody(zipBytes, fileName);
  const res = await signedRawRequest(
    "POST",
    "/api/settings/restore",
    "Restore backend settings and keys from a backup",
    { body, contentType },
  );
  return (await res.json()) as RestoreBackupResponse;
}

export function parseCleanupDays(raw: string, min = 1, max = 365): number | null {
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const n = Number(trimmed);
  if (!Number.isSafeInteger(n) || n < min || n > max) return null;
  return n;
}
