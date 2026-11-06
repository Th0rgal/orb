import { nativeInvoke } from "./native";
import { probeHealth, setConnection, transportFetch } from "./api";

/**
 * Shared-model GitHub OAuth sign-in state machine (mirrors `OrbGitHubSignIn.kt`
 * and `OrbGitHubSignIn.swift`).
 *
 * Binds every callback to the exact server origin and client-generated `state`
 * nonce that initiated it, and verifies the returned JWT against
 * `GET /api/auth/status` before storing credentials.
 */
export const GITHUB_OAUTH_STATE_TTL_MS = 10 * 60 * 1000;
const STORAGE_KEY = "orb.githubOAuthPending";

export interface PendingGitHubOAuthAttempt {
  baseUrl: string;
  state: string | null;
  requireState?: boolean;
  startedAt: number;
}

export type GitHubCallbackOutcome =
  | { ok: true; baseUrl: string; token: string }
  | { ok: false; error: string };

export function normalizeAuthOrigin(rawUrl: string): string | null {
  const clean = rawUrl.trim().replace(/\/+$/, "");
  if (!clean) return null;
  try {
    const parsed = new URL(clean);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
    const path = parsed.pathname === "/" ? "" : parsed.pathname.replace(/\/+$/, "");
    return `${parsed.protocol.toLowerCase()}//${parsed.host.toLowerCase()}${path}`;
  } catch {
    return null;
  }
}

export function generateGitHubOAuthState(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function constantTimeEquals(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  const max = Math.max(ab.length, bb.length);
  for (let i = 0; i < max; i++) {
    diff |= (i < ab.length ? ab[i] : 0) ^ (i < bb.length ? bb[i] : 0);
  }
  return diff === 0;
}

export function beginGitHubOAuthAttempt(
  rawBaseUrl: string,
  clientStateSupported = false,
  nowMs = Date.now(),
): PendingGitHubOAuthAttempt | null {
  const baseUrl = normalizeAuthOrigin(rawBaseUrl);
  if (!baseUrl) return null;
  const attempt: PendingGitHubOAuthAttempt = {
    baseUrl,
    state: generateGitHubOAuthState(),
    requireState: clientStateSupported === true,
    startedAt: nowMs,
  };
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(attempt));
  } catch {
    // sessionStorage can be unavailable in isolated test contexts
  }
  return attempt;
}

export function loadPendingGitHubOAuthAttempt(): PendingGitHubOAuthAttempt | null {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<PendingGitHubOAuthAttempt>;
    if (typeof parsed.baseUrl !== "string" || typeof parsed.startedAt !== "number") return null;
    return {
      baseUrl: parsed.baseUrl,
      state: typeof parsed.state === "string" ? parsed.state : null,
      requireState: parsed.requireState === true,
      startedAt: parsed.startedAt,
    };
  } catch {
    return null;
  }
}

export function clearPendingGitHubOAuthAttempt(): void {
  try {
    sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // ignore
  }
}

export function parseGitHubCallbackParams(callbackUrl: string): {
  validCallbackPath: boolean;
  token: string | null;
  error: string | null;
  state: string | null;
} {
  try {
    const parsed = new URL(callbackUrl);
    const isCustomScheme =
      parsed.protocol === "sandboxed:" &&
      parsed.hostname.toLowerCase() === "auth" &&
      parsed.pathname === "/callback";
    const isHttpCallback =
      (parsed.protocol === "http:" || parsed.protocol === "https:") &&
      parsed.pathname.endsWith("/auth/callback");
    if (!isCustomScheme && !isHttpCallback) {
      return { validCallbackPath: false, token: null, error: null, state: null };
    }
    return {
      validCallbackPath: true,
      token: parsed.searchParams.get("token"),
      error: parsed.searchParams.get("error"),
      state: parsed.searchParams.get("state"),
    };
  } catch {
    return { validCallbackPath: false, token: null, error: null, state: null };
  }
}

export function verifyGitHubOAuthCallback(
  callbackUrl: string,
  attempt: PendingGitHubOAuthAttempt | null,
  currentRawBaseUrl?: string | null,
  nowMs = Date.now(),
): GitHubCallbackOutcome {
  clearPendingGitHubOAuthAttempt();
  if (!attempt) {
    return { ok: false, error: "GitHub sign-in was not started from this app" };
  }
  if (nowMs - attempt.startedAt > GITHUB_OAUTH_STATE_TTL_MS) {
    return { ok: false, error: "GitHub sign-in expired — please try again" };
  }
  if (currentRawBaseUrl) {
    const currentNorm = normalizeAuthOrigin(currentRawBaseUrl);
    if (!currentNorm || currentNorm !== attempt.baseUrl) {
      return { ok: false, error: "Server URL changed during GitHub sign-in — please try again" };
    }
  }
  const params = parseGitHubCallbackParams(callbackUrl);
  if (!params.validCallbackPath) {
    return { ok: false, error: "Invalid GitHub callback URL" };
  }
  const gotState = params.state && params.state.length > 0 ? params.state : null;
  const serverEchoesState = attempt.requireState ?? attempt.state !== null;
  if (gotState !== null || serverEchoesState) {
    if (!attempt.state) {
      return { ok: false, error: "GitHub sign-in state was not recorded — please try again" };
    }
    if (!gotState || !constantTimeEquals(attempt.state, gotState)) {
      return { ok: false, error: "GitHub sign-in state did not match — please try again" };
    }
  }
  if (params.error && params.error.trim()) {
    return { ok: false, error: params.error.trim() };
  }
  const token = params.token?.trim() ?? "";
  if (!token) {
    return { ok: false, error: "GitHub sign-in did not return a token" };
  }
  return { ok: true, baseUrl: attempt.baseUrl, token };
}

export async function verifyIssuedAuthToken(baseUrl: string, token: string): Promise<void> {
  const res = await transportFetch(
    "/api/auth/status",
    {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    },
    baseUrl,
  );
  if (res.status === 401 || res.status === 403) {
    throw new Error("Server rejected GitHub token");
  }
  if (!res.ok) {
    throw new Error(`Could not verify sign-in (${res.status})`);
  }
}

export async function signInWithGitHubDesktop(
  rawBaseUrl: string,
  clientStateSupported?: boolean,
): Promise<boolean> {
  const baseUrl = normalizeAuthOrigin(rawBaseUrl);
  if (!baseUrl) {
    throw new Error("Enter a valid http:// or https:// API URL first");
  }
  let echoesState = clientStateSupported === true;
  if (clientStateSupported === undefined) {
    const health = await probeHealth(baseUrl).catch(() => null);
    echoesState = health?.github_oauth_client_state === true;
  }
  const attempt = beginGitHubOAuthAttempt(baseUrl, echoesState);
  if (!attempt) {
    throw new Error("Enter a valid http:// or https:// API URL first");
  }
  const invoke = nativeInvoke();
  if (!invoke) {
    const redirect = `${window.location.origin}/auth/callback`;
    const qs = new URLSearchParams({ redirect });
    if (attempt.state) qs.set("state", attempt.state);
    window.location.assign(`${attempt.baseUrl}/api/auth/github/start?${qs.toString()}`);
    return false;
  }
  let callbackUrl: string | null;
  try {
    callbackUrl = await invoke<string | null>("github_oauth_sign_in", {
      apiUrl: attempt.baseUrl,
      state: attempt.state,
    });
  } catch (e) {
    clearPendingGitHubOAuthAttempt();
    throw e instanceof Error ? e : new Error(String(e));
  }
  if (!callbackUrl) {
    clearPendingGitHubOAuthAttempt();
    return false;
  }
  const verified = verifyGitHubOAuthCallback(callbackUrl, attempt, rawBaseUrl);
  if (!verified.ok) {
    throw new Error(verified.error);
  }
  await verifyIssuedAuthToken(verified.baseUrl, verified.token);
  setConnection(verified.baseUrl, verified.token);
  return true;
}
