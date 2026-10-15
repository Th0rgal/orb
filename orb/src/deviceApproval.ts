import { api, ApiError, getApiUrl } from "./api";

/**
 * Device-signed approvals. Core accepts sensitive operations (approving
 * mission secret requests, revealing or editing secrets, default access) only
 * with a signature from an enrolled device key. On this Mac the key lives in
 * the Secure Enclave and signs only after Touch ID; see `approval_key.rs`.
 */

export type ApprovalMode = "off" | "warn" | "enforce";

export interface ApprovalDevice {
  id: string;
  name: string;
  platform: "macos" | "ios" | "android" | string;
  public_key: string;
  created_at: string;
  last_used_at?: string | null;
}

export interface ApprovalDevices {
  mode: ApprovalMode;
  devices: ApprovalDevice[];
  enrollment_code_pending: boolean;
}

type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
function invoke(): Invoke | null {
  const g = window as unknown as { __TAURI__?: { core?: { invoke?: Invoke } }; __TAURI_INTERNALS__?: { invoke?: Invoke } };
  return g.__TAURI__?.core?.invoke ?? g.__TAURI_INTERNALS__?.invoke ?? null;
}

const deviceKey = () => `orb.approvalDevice.${getApiUrl()}`;
export const enrolledDeviceId = (): string | null => {
  try {
    return localStorage.getItem(deviceKey());
  } catch {
    return null;
  }
};

export const listApprovalDevices = () => api<ApprovalDevices>("/api/approvals/devices", { method: "GET" });

export async function localApprovalKey(): Promise<{ available: boolean; public_key: string | null }> {
  const call = invoke();
  if (!call) return { available: false, public_key: null };
  try {
    return (await call("approval_key_status")) as { available: boolean; public_key: string | null };
  } catch {
    return { available: false, public_key: null };
  }
}

/** Is this Mac's key enrolled on this backend? Repairs the stored device id. */
export async function thisDeviceEnrollment(devices: ApprovalDevice[]): Promise<ApprovalDevice | null> {
  const key = await localApprovalKey();
  const match = key.public_key ? devices.find((d) => d.public_key === key.public_key) ?? null : null;
  try {
    if (match) localStorage.setItem(deviceKey(), match.id);
    else localStorage.removeItem(deviceKey());
  } catch {
    // Storage can be unavailable; signing then falls back to unsigned.
  }
  return match;
}

/**
 * Enroll this Mac. Either another device approves (signed request from the
 * caller's `approve` hook is not possible here), or the one-time code that
 * root created on the Core host is entered.
 */
export async function enrollThisDevice(name: string, enrollmentCode: string): Promise<ApprovalDevice> {
  const call = invoke();
  if (!call) throw new Error("Device approval needs the Orb desktop app");
  let { public_key } = await localApprovalKey();
  if (!public_key) public_key = (await call("approval_key_create")) as string;
  const device = await api<ApprovalDevice>("/api/approvals/devices", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, platform: "macos", public_key, enrollment_code: enrollmentCode.trim() }),
  });
  try {
    localStorage.setItem(deviceKey(), device.id);
  } catch {
    // ignore
  }
  return device;
}

export class ApprovalCancelled extends Error {
  constructor() {
    super("Approval cancelled");
  }
}

/**
 * Send a request that Core protects with a device signature. `summary` is what
 * the Touch ID sheet says. Without an enrolled key the request goes unsigned
 * (accepted only while Core is in warn mode).
 */
export async function signedApi<T>(method: string, path: string, body: unknown, summary: string): Promise<T> {
  const text = body === undefined ? "" : JSON.stringify(body);
  const headers: Record<string, string> = body === undefined ? {} : { "Content-Type": "application/json" };
  const device = enrolledDeviceId();
  const call = invoke();
  if (device && call) {
    const challenge = await api<{ challenge_id: string; payload: string }>("/api/approvals/challenge", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method, path, body: text, summary }),
    });
    let signature: string;
    try {
      signature = (await call("approval_sign", { payload: challenge.payload, reason: summary })) as string;
    } catch (e) {
      if (String(e).includes("cancelled")) throw new ApprovalCancelled();
      throw e instanceof Error ? e : new Error(String(e));
    }
    headers["X-Paloma-Approval"] = `${challenge.challenge_id}.${device}.${signature}`;
  }
  try {
    return await api<T>(path, { method, headers, ...(body === undefined ? {} : { body: text }) });
  } catch (e) {
    if (e instanceof ApiError && e.status === 403 && e.detail.includes("device_approval_required")) {
      throw new Error("Core requires an enrolled device for this. Enroll this Mac in Settings → Secrets → Approval devices.");
    }
    throw e;
  }
}
