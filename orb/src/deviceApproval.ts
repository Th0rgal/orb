import { nativeInvoke } from "./native";
import { createSignal } from "solid-js";
import { api, ApiError, clearConnection, connectionVersion, getApiUrl, getJwt, REQUEST_TIMEOUT_MS, transportFetch } from "./api";
import { invalidateReads } from "./sharedReads";
import { usageTelemetry, type ApprovalDecision, type ApprovalKind, type ApprovalMethod } from "./usageTelemetry";

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
  return nativeInvoke() ?? null;
}

const deviceKey = (targetBase = getApiUrl()) => `orb.approvalDevice.${targetBase.trim().replace(/\/+$/, "")}`;
export const enrolledDeviceId = (targetBase = getApiUrl()): string | null => {
  try {
    return localStorage.getItem(deviceKey(targetBase));
  } catch {
    return null;
  }
};

export const listApprovalDevices = (targetBase?: string) =>
  api<ApprovalDevices>("/api/approvals/devices", { method: "GET" }, targetBase);

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
export async function thisDeviceEnrollment(devices: ApprovalDevice[], targetBase = getApiUrl()): Promise<ApprovalDevice | null> {
  const key = await localApprovalKey();
  const match = key.public_key ? devices.find((d) => d.public_key === key.public_key) ?? null : null;
  try {
    if (match) localStorage.setItem(deviceKey(targetBase), match.id);
    else localStorage.removeItem(deviceKey(targetBase));
  } catch {
    // Storage can be unavailable; signing then falls back to unsigned.
  }
  return match;
}

let signMutex: Promise<void> = Promise.resolve();
function serializeSign<T>(run: () => Promise<T>): Promise<T> {
  const next = signMutex.then(run, run);
  signMutex = next.then(() => undefined, () => undefined);
  return next;
}

async function resolveOrRepairDeviceId(targetBase: string, forceRefresh = false): Promise<string | null> {
  if (!forceRefresh) {
    const cached = enrolledDeviceId(targetBase);
    if (cached) return cached;
  }
  const key = await localApprovalKey();
  if (!key.public_key) return null;
  try {
    const { devices } = await listApprovalDevices(targetBase);
    const match = await thisDeviceEnrollment(devices, targetBase);
    return match?.id ?? null;
  } catch {
    return forceRefresh ? null : enrolledDeviceId(targetBase);
  }
}

function isDeviceAuthMismatch(status: number, detail: string): boolean {
  return (
    status === 403 &&
    (detail.includes("device_approval_required") ||
      detail.includes("Unknown approval device") ||
      detail.includes("Device signature does not verify"))
  );
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

/** Make a new Secure Enclave key (the old one may be invalidated by Touch ID changes). */
export async function replaceLocalKey(): Promise<void> {
  const call = invoke();
  if (!call) throw new Error("Device approval needs the Orb desktop app");
  await call("approval_key_create");
  try {
    localStorage.removeItem(deviceKey());
  } catch {
    // ignore
  }
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
  const decided = approvalDecisionPath(path);
  const started = Date.now();
  const report = (decision: ApprovalDecision, method: ApprovalMethod, result?: unknown) => {
    if (!decided) return;
    const created = Date.parse(String((result as { created_at?: unknown } | undefined)?.created_at ?? ""));
    usageTelemetry.approval({ kind: decided.kind, decision, method, waitMs: Date.now() - (Number.isFinite(created) ? created : started) });
  };
  try {
    const result = await signedApiInner<T>(method, path, body, summary);
    report(decided?.decision ?? "approved", enrolledDeviceId() && invoke() ? "touch_id" : "desktop_click", result);
    return result;
  } catch (e) {
    if (e instanceof ApprovalCancelled) report("dismissed", "touch_id");
    throw e;
  }
}

/** Approval decisions on mission requests: `kind` and `decision` from the
 * route, never from the request payload. */
export function approvalDecisionPath(path: string): { kind: ApprovalKind; decision: ApprovalDecision } | null {
  const m = /^\/api\/(privilege-access|mission-access|bitwarden\/requests|payments?)\/[^/]+\/(approve|deny|reject)$/.exec(path);
  if (!m) return null;
  const kind: ApprovalKind = m[1] === "privilege-access" ? "command_class" : m[1].startsWith("payment") ? "payment" : "grant";
  return { kind, decision: m[2] === "approve" ? "approved" : "denied" };
}

const CONNECTION_CHANGED_ERROR =
  "Server connection changed during device approval. Retry on the selected server.";

function captureOriginConnection(): {
  version: number;
  targetBase: string;
  jwt: string | null;
  ensureUnchanged: () => void;
} {
  const version = connectionVersion();
  const targetBase = getApiUrl().trim().replace(/\/+$/, "");
  const jwt = getJwt();
  if (!targetBase) throw new Error("Not connected to a Core server.");
  const ensureUnchanged = () => {
    if (
      connectionVersion() !== version ||
      getApiUrl().trim().replace(/\/+$/, "") !== targetBase ||
      getJwt() !== jwt
    ) {
      throw new Error(CONNECTION_CHANGED_ERROR);
    }
  };
  return { version, targetBase, jwt, ensureUnchanged };
}

async function signChallengePayload(call: Invoke, payload: string, summary: string): Promise<string> {
  return serializeSign(async () => {
    try {
      await call("set_approval_grace", { secs: approvalGraceSecs() }).catch(() => undefined);
      const signature = (await call("approval_sign", { payload, reason: summary })) as string;
      void refreshGrace(call);
      return signature;
    } catch (e) {
      void refreshGrace(call);
      if (String(e).includes("cancelled")) throw new ApprovalCancelled();
      throw e instanceof Error ? e : new Error(String(e));
    }
  });
}

async function signedApiInner<T>(method: string, path: string, body: unknown, summary: string): Promise<T> {
  const origin = captureOriginConnection();
  const text = body === undefined ? "" : JSON.stringify(body);
  const call = invoke();
  let device = call ? await resolveOrRepairDeviceId(origin.targetBase, false) : null;

  const attemptWithDevice = async (devId: string | null): Promise<T> => {
    origin.ensureUnchanged();
    const headers: Record<string, string> = {
      ...(origin.jwt ? { Authorization: `Bearer ${origin.jwt}` } : {}),
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    };
    if (devId && call) {
      const challenge = await api<{ challenge_id: string; payload: string }>(
        "/api/approvals/challenge",
        {
          method: "POST",
          headers: {
            ...(origin.jwt ? { Authorization: `Bearer ${origin.jwt}` } : {}),
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ method, path, body: text, summary }),
        },
        origin.targetBase,
      );
      origin.ensureUnchanged();
      const signature = await signChallengePayload(call, challenge.payload, summary);
      origin.ensureUnchanged();
      headers["X-Paloma-Approval"] = `${challenge.challenge_id}.${devId}.${signature}`;
    }
    origin.ensureUnchanged();
    return api<T>(path, { method, headers, ...(body === undefined ? {} : { body: text }) }, origin.targetBase);
  };

  try {
    return await attemptWithDevice(device);
  } catch (e) {
    if (e instanceof ApiError && call && isDeviceAuthMismatch(e.status, e.detail)) {
      const repaired = await resolveOrRepairDeviceId(origin.targetBase, true);
      if (repaired && repaired !== device) {
        device = repaired;
        return await attemptWithDevice(repaired);
      }
      if (!repaired && e.detail.includes("device_approval_required")) {
        throw new Error("Core requires an enrolled device for this. Enroll this Mac in Settings → Security → Approval devices.");
      }
    }
    if (e instanceof ApiError && e.status === 403 && e.detail.includes("device_approval_required")) {
      throw new Error("Core requires an enrolled device for this. Enroll this Mac in Settings → Security → Approval devices.");
    }
    throw e;
  }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const buf = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buf).set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Send a raw/binary request protected by a device signature (e.g. `.zip` backup
 * download or multipart restore). Binds exact `body_sha256` in the challenge.
 */
export async function signedRawRequest(
  method: string,
  path: string,
  summary: string,
  options?: { body?: Uint8Array; contentType?: string },
): Promise<Response> {
  const origin = captureOriginConnection();
  const call = invoke();
  let device = call ? await resolveOrRepairDeviceId(origin.targetBase, false) : null;
  const bodyHash = options?.body ? await sha256Hex(options.body) : undefined;

  const attemptRaw = async (devId: string | null): Promise<Response> => {
    origin.ensureUnchanged();
    const headers: Record<string, string> = {
      ...(origin.jwt ? { Authorization: `Bearer ${origin.jwt}` } : {}),
      ...(options?.contentType ? { "Content-Type": options.contentType } : {}),
    };
    if (devId && call) {
      const challenge = await api<{ challenge_id: string; payload: string }>(
        "/api/approvals/challenge",
        {
          method: "POST",
          headers: {
            ...(origin.jwt ? { Authorization: `Bearer ${origin.jwt}` } : {}),
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            method,
            path,
            ...(bodyHash ? { body_sha256: bodyHash } : { body: "" }),
            summary,
          }),
        },
        origin.targetBase,
      );
      origin.ensureUnchanged();
      const signature = await signChallengePayload(call, challenge.payload, summary);
      origin.ensureUnchanged();
      headers["X-Paloma-Approval"] = `${challenge.challenge_id}.${devId}.${signature}`;
    }

    let bodyInit: BodyInit | undefined;
    if (options?.body) {
      const copy = new ArrayBuffer(options.body.byteLength);
      new Uint8Array(copy).set(options.body);
      bodyInit = copy;
    }

    origin.ensureUnchanged();
    if (method.toUpperCase() !== "GET") invalidateReads();
    return transportFetch(
      path,
      {
        method,
        headers,
        ...(bodyInit !== undefined ? { body: bodyInit } : {}),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      },
      origin.targetBase,
    );
  };

  let res = await attemptRaw(device);
  if (res.status === 401) {
    if (connectionVersion() === origin.version) clearConnection();
    throw new Error("401 Unauthorized — reconnect in Settings → Account");
  }
  if (!res.ok) {
    let detail = (await res.text().catch(() => "")).trim();
    if (call && isDeviceAuthMismatch(res.status, detail)) {
      const repaired = await resolveOrRepairDeviceId(origin.targetBase, true);
      if (repaired && repaired !== device) {
        device = repaired;
        res = await attemptRaw(repaired);
        if (res.status === 401) {
          if (connectionVersion() === origin.version) clearConnection();
          throw new Error("401 Unauthorized — reconnect in Settings → Account");
        }
        if (res.ok) return res;
        detail = (await res.text().catch(() => "")).trim();
      }
    }
    if (res.status === 403 && detail.includes("device_approval_required")) {
      throw new Error("Core requires an enrolled device for this. Enroll this Mac in Settings → Security → Approval devices.");
    }
    throw new ApiError(res.status, detail || res.statusText);
  }
  return res;
}

const GRACE_KEY = "orb.approvalGraceSecs";
function storedGrace(): number {
  try {
    const v = Number(localStorage.getItem(GRACE_KEY));
    return localStorage.getItem(GRACE_KEY) !== null && Number.isFinite(v) ? v : 300;
  } catch {
    return 300;
  }
}
const [approvalGraceSecs, setGraceSecs] = createSignal(storedGrace());
/** How long one Touch ID covers further secret-request decisions (0: always ask). */
export { approvalGraceSecs };
export function setApprovalGraceSecs(secs: number) {
  setGraceSecs(secs);
  try {
    localStorage.setItem(GRACE_KEY, String(secs));
  } catch {
    /* per-device convenience only */
  }
  const call = invoke();
  if (call) void call("set_approval_grace", { secs }).then(() => refreshGrace(call)).catch(() => undefined);
}

const [graceUntilSecs, setGraceUntil] = createSignal(0);
/** Unix seconds until which secret-request decisions skip Touch ID (0: none). */
export const graceUntil = graceUntilSecs;
async function refreshGrace(call: Invoke) {
  try {
    setGraceUntil(Number(await call("approval_grace_until")) || 0);
  } catch {
    setGraceUntil(0);
  }
}
