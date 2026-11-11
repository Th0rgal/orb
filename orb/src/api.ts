import { nativeInvoke } from "./native";
import { missionNode } from "./machines/nodes";
import { harnessRank, isHarness } from "./harnesses";
import { isArchivable, isArchived, isReopenable, isWorking } from "./missionStatus";
import { swallow } from "./log";
import { sharedRead, invalidateReads } from "./sharedReads";
import { cacheReset } from "./pageCache";
import type { ClientRunReceipt } from "./clientRuns";
import { createSignal } from "solid-js";
import { getProjectCronFromJob, hermesPatch, normalizeControllerView, type HermesControllerView, type HermesJob } from "./cronSchema";
import { applyProjectRoster } from "./projectAppearance";
import { note, requestDone } from "./diagnostics";
import { noteObservedMissionQueueRevision, peekObservedMissionQueueRevision } from "./followupQueueState";
import {
  recordTransportFailure,
  recordTransportRecovery,
  recordTransportRttSample,
  resetNetworkHealth,
} from "./networkHealth";
import { clearPersistentCache } from "./persistentCache";
import {
  classifyClientRequestPriority,
  scheduleTransportRequest,
  type RequestPriority,
} from "./transportScheduler";
import {
  LOCAL_PLACEMENT_CLIENT_ID,
  allocatePlacementOpId,
  authoritativePlacement,
  btwParentId,
  commitAuthoritativePlacements,
  configureParentResolver,
  excludeBtwMissions,
  isBtwMission,
  normalizeMissionFolder,
  openBeyondPage,
  partialList,
  resetMissionHierarchy,
  resolveLocalAckOpId,
  rollbackOptimisticPlacement,
  stageOptimisticPlacement,
  stickHierarchy,
  withHierarchy,
  type PlacementCommitItem,
} from "./missionHierarchy";
export {
  LOCAL_PLACEMENT_CLIENT_ID,
  allocatePlacementOpId,
  authoritativePlacement,
  btwParentId,
  commitAuthoritativePlacements,
  excludeBtwMissions,
  isBtwMission,
  normalizeMissionFolder,
  resolveLocalAckOpId,
  rollbackOptimisticPlacement,
  stageOptimisticPlacement,
  type PlacementCommitItem,
};

const URL_KEY = "orb.apiUrl";
const JWT_KEY = "orb.jwt";
const DEFAULT_URL = "https://agent-backend.thomas.md";
const ORBCORE_URL = "https://orbcore.thomas.md";
const KNOWN_DIRECT_URL = "https://agent-backend.nico-best-pc-ever.ovh";
const ENDPOINT_COOLDOWN_MS = 20_000;
const DELTA_CURSOR_OVERLAP_MS = 2_000;

export function getApiUrl(): string {
  return localStorage.getItem(URL_KEY) ?? DEFAULT_URL;
}

/** Ordered candidate origins for Edge-diverse 3-way multi-path failover (mirrors Lean/Swift/Kotlin):
 * rotates across distinct network edges (`orbcore.thomas.md` -> Cloudflare Edge BBR `agent-backend.thomas.md` -> direct OVH `agent-backend.nico-best-pc-ever.ovh`). */
export function candidateApiUrls(primary = getApiUrl()): string[] {
  const clean = primary.trim().replace(/\/+$/, "");
  if (!clean) return [];
  const lower = clean.toLowerCase();
  if (lower === ORBCORE_URL) {
    return [clean, DEFAULT_URL, KNOWN_DIRECT_URL];
  }
  if (lower === KNOWN_DIRECT_URL) {
    return [clean, DEFAULT_URL, ORBCORE_URL];
  }
  if (lower === DEFAULT_URL) {
    return [clean, ORBCORE_URL, KNOWN_DIRECT_URL];
  }
  if (lower.endsWith(".thomas.md")) {
    return [clean, DEFAULT_URL, ORBCORE_URL];
  }
  return [clean];
}

let transportBridgeEnabled = false;
let bridgeTarget: string | null = null;
let bridgeBaseUrl: string | null = null;
let bridgeStreamUrls: string[] = [];
let bridgeStreamCursor = 0;
let bridgePending: Promise<string | null> | null = null;
const endpointCooldownUntil = new Map<string, number>();

export function resetTransportState() {
  bridgeTarget = null;
  bridgeBaseUrl = null;
  bridgeStreamUrls = [];
  bridgeStreamCursor = 0;
  bridgePending = null;
  endpointCooldownUntil.clear();
}

/** Enable or disable the Tauri loopback HTTP bridge (enabled by `restoreDesktopConnection`). */
export function setTransportBridgeEnabled(enabled: boolean): void {
  transportBridgeEnabled = enabled;
  if (!enabled) {
    bridgeTarget = null;
    bridgeBaseUrl = null;
    bridgeStreamUrls = [];
    bridgeStreamCursor = 0;
    bridgePending = null;
  }
}

export function orderedApiCandidates(primary = getApiUrl()): string[] {
  const list = candidateApiUrls(primary);
  if (list.length <= 1) return list;
  const now = Date.now();
  const healthy: string[] = [];
  const cooling: string[] = [];
  for (const url of list) {
    if ((endpointCooldownUntil.get(url) ?? 0) > now) cooling.push(url);
    else healthy.push(url);
  }
  return [...healthy, ...cooling];
}

/** Resolve the native loopback transport URL (`http://127.0.0.1:<port>/__orb_tx/<token>`)
 * when running inside Tauri desktop; returns `null` in web/test environments. */
export async function resolveTransportBase(apiUrl = getApiUrl()): Promise<string | null> {
  if (!transportBridgeEnabled) return null;
  const invoke = nativeInvoke();
  if (!invoke) return null;
  const clean = apiUrl.trim().replace(/\/+$/, "");
  if (!clean.toLowerCase().startsWith("https://")) return null;
  if (bridgeTarget === clean && bridgeBaseUrl) return bridgeBaseUrl;
  if (bridgePending && bridgeTarget === clean) return bridgePending;
  bridgeTarget = clean;
  const pending = invoke<{
    proxy_base_url?: string;
    stream_proxy_base_urls?: string[];
    configured_target?: string;
  }>("transport_bridge_configure", { apiUrl: clean })
    .then((info) => {
      const proxy = typeof info?.proxy_base_url === "string" && info.proxy_base_url.startsWith("http://127.0.0.1:")
        ? info.proxy_base_url.replace(/\/+$/, "")
        : null;
      const streams = Array.isArray(info?.stream_proxy_base_urls)
        ? info.stream_proxy_base_urls
            .filter((u): u is string => typeof u === "string" && u.startsWith("http://127.0.0.1:"))
            .map((u) => u.replace(/\/+$/, ""))
        : [];
      if (bridgeTarget === clean) {
        bridgeBaseUrl = proxy;
        bridgeStreamUrls = streams;
      }
      return proxy;
    })
    .catch((error) => {
      note(`transport.bridge.error: ${error instanceof Error ? error.message : String(error)}`);
      if (bridgeTarget === clean) {
        bridgeBaseUrl = null;
        bridgeStreamUrls = [];
      }
      return null;
    })
    .finally(() => {
      if (bridgePending === pending) bridgePending = null;
    });
  bridgePending = pending;
  return pending;
}

export function isStreamingFetch(path: string, init?: RequestInit): boolean {
  if (path.startsWith("/api/control/stream") || path.includes("/context/stream")) return true;
  const accept = headerValue(init?.headers, "Accept");
  return typeof accept === "string" && accept.toLowerCase().includes("text/event-stream");
}

function pickBridgeUrl(streaming: boolean, fallback: string | null): string | null {
  if (streaming && bridgeStreamUrls.length > 0) {
    const idx = bridgeStreamCursor++ % bridgeStreamUrls.length;
    return bridgeStreamUrls[idx];
  }
  return fallback;
}

function withTargetHeader(init: RequestInit | undefined, target: string): RequestInit | undefined {
  if (!target.startsWith("https://")) return init;
  const headers = new Headers(init?.headers);
  if (!headers.has("X-Orb-Target")) headers.set("X-Orb-Target", target);
  return { ...(init ?? {}), headers };
}

function withPriorityHeader(init: RequestInit | undefined, priority: RequestPriority): RequestInit {
  if (!init?.headers) {
    return { ...(init ?? {}), headers: { "X-Orb-Priority": priority } };
  }
  if (init.headers instanceof Headers) {
    const next = new Headers(init.headers);
    if (!next.has("X-Orb-Priority")) next.set("X-Orb-Priority", priority);
    return { ...init, headers: next };
  }
  if (Array.isArray(init.headers)) {
    const has = init.headers.some(([k]) => k.toLowerCase() === "x-orb-priority");
    return has ? init : { ...init, headers: [...init.headers, ["X-Orb-Priority", priority]] };
  }
  const existing = headerValue(init.headers, "X-Orb-Priority");
  if (existing) return init;
  return {
    ...init,
    headers: {
      ...(init.headers as Record<string, string>),
      "X-Orb-Priority": priority,
    },
  };
}

function shouldSampleTransportRtt(methodRaw: string | undefined, path: string): boolean {
  const method = (methodRaw ?? "GET").trim().toUpperCase();
  if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") return false;
  const cleanPath = path.split("?")[0] ?? path;
  if (
    cleanPath === "/api/file-resources" ||
    cleanPath.endsWith("/inbox-digest") ||
    cleanPath.startsWith("/api/software") ||
    cleanPath.startsWith("/api/stats") ||
    cleanPath.startsWith("/api/resources/") ||
    cleanPath.startsWith("/api/usage") ||
    cleanPath.startsWith("/api/proxy-health") ||
    cleanPath.startsWith("/api/providers/antigravity-models") ||
    cleanPath.startsWith("/api/antigravity-models") ||
    cleanPath === "/api/ai/providers/usage" ||
    (cleanPath.startsWith("/api/ai/providers/") && cleanPath.endsWith("/usage"))
  ) {
    return false;
  }
  return true;
}

function isWorkerNodeProxyPath(path: string): boolean {
  const [cleanPath = path, query = ""] = path.split("?");
  if (
    cleanPath.startsWith("/api/providers/antigravity-models") ||
    cleanPath.startsWith("/api/antigravity-models")
  ) {
    return /(?:^|&)node_id=(?!core(?:&|$))[^&]+/.test(query);
  }
  return false;
}

function recordFetchTelemetry(
  res: Response,
  startedMs: number,
  fallbackOrigin?: string,
  methodRaw?: string,
  path = "",
): Response {
  const rttHeader = res.headers?.get?.("X-Orb-Transport-Rtt-Ms");
  const upstreamOrigin = res.headers?.get?.("X-Orb-Upstream-Origin") ?? fallbackOrigin ?? null;
  const parsedRtt = rttHeader ? Number(rttHeader) : NaN;
  const sampleMs =
    Number.isFinite(parsedRtt) && parsedRtt > 0
      ? parsedRtt
      : Math.max(1, Math.round(performance.now() - startedMs));
  if (res.status < 500 && res.status !== 429) {
    if (shouldSampleTransportRtt(methodRaw, path)) {
      recordTransportRttSample(sampleMs, upstreamOrigin);
    } else {
      recordTransportRecovery(upstreamOrigin);
    }
  } else if (
    res.status >= 500 &&
    !([502, 503, 504].includes(res.status) && isWorkerNodeProxyPath(path))
  ) {
    recordTransportFailure();
  }
  return res;
}

/** Perform `fetch` against `path` using the Tauri loopback transport when active
 * (eliminating `WKWebView` CORS preflights and DNS stalls), or ordered direct/fallback
 * origins synchronously when no native bridge is active. Long-lived SSE streams are
 * routed across sharded loopback stream ports so `WKWebView`'s 6-connection-per-origin
 * HTTP/1.1 limit never starves JSON/REST requests. */
export function transportFetch(
  path: string,
  init?: RequestInit,
  explicitBase?: string,
  explicitPriority?: RequestPriority,
  defaultWireTimeoutMs?: number,
): Promise<Response> {
  const target = (explicitBase ?? getApiUrl()).trim().replace(/\/+$/, "");
  const streaming = isStreamingFetch(path, init);
  const rawPrio = headerValue(init?.headers, "X-Orb-Priority") as RequestPriority | undefined;
  const validExplicit =
    explicitPriority ??
    (rawPrio === "p0" || rawPrio === "p1" || rawPrio === "p2" ? rawPrio : undefined);
  const priority = classifyClientRequestPriority(init?.method, path, validExplicit);
  const runOnce = (effectivePriority: RequestPriority = priority): Promise<Response> => {
    const startedMs = performance.now();
    // Attach the default request deadline on wire dispatch rather than before
    // scheduler queueing so P2 requests paused behind a degraded link never
    // fire spurious RequestTimeoutError banners while waiting locally.
    const wireInit: RequestInit | undefined =
      !streaming && defaultWireTimeoutMs && defaultWireTimeoutMs > 0
        ? {
            ...(init ?? {}),
            signal: init?.signal
              ? (typeof AbortSignal.any === "function"
                  ? AbortSignal.any([init.signal, AbortSignal.timeout(defaultWireTimeoutMs)])
                  : init.signal)
              : AbortSignal.timeout(defaultWireTimeoutMs),
          }
        : init;
    if (transportBridgeEnabled && nativeInvoke()) {
      const targetInit = withTargetHeader(wireInit, target);
      const bridgeInit = streaming ? targetInit : withPriorityHeader(targetInit, effectivePriority);
      if (bridgeTarget === target && bridgeBaseUrl) {
        const chosen = pickBridgeUrl(streaming, bridgeBaseUrl)!;
        return fetch(`${chosen}${path}`, bridgeInit).then(
          (res) => recordFetchTelemetry(res, startedMs, undefined, init?.method, path),
          (err) => {
            if (!isAbortError(err)) recordTransportFailure();
            throw err;
          },
        );
      }
      return resolveTransportBase(target).then((proxy) => {
        const chosen = bridgeTarget === target ? pickBridgeUrl(streaming, proxy) : proxy;
        if (!chosen) return transportFetchDirect(target, path, wireInit);
        return fetch(`${chosen}${path}`, bridgeInit).then(
          (res) => recordFetchTelemetry(res, startedMs, undefined, init?.method, path),
          (err) => {
            if (!isAbortError(err)) recordTransportFailure();
            throw err;
          },
        );
      });
    }
    return transportFetchDirect(target, path, wireInit);
  };
  if (streaming) return runOnce();
  return scheduleTransportRequest(priority, init?.signal, runOnce);
}

function headerValue(headers: HeadersInit | undefined, name: string): string | undefined {
  if (!headers) return undefined;
  if (headers instanceof Headers) return headers.get(name) ?? undefined;
  if (Array.isArray(headers)) {
    const found = headers.find(([k]) => k.toLowerCase() === name.toLowerCase());
    return found?.[1];
  }
  const rec = headers as Record<string, string | undefined>;
  for (const [k, v] of Object.entries(rec)) {
    if (k.toLowerCase() === name.toLowerCase() && v) return v;
  }
  return undefined;
}

export function withIdempotencyKey(init: RequestInit | undefined, key: string = crypto.randomUUID()): RequestInit {
  const existing = headerValue(init?.headers, "Idempotency-Key");
  if (existing) return init ?? {};
  return {
    ...(init ?? {}),
    headers: {
      ...((init?.headers as Record<string, string> | undefined) ?? {}),
      "Idempotency-Key": key,
    },
  };
}

async function transportFetchDirect(target: string, path: string, init?: RequestInit): Promise<Response> {
  const candidates = orderedApiCandidates(target);
  const method = (init?.method ?? "GET").toUpperCase();
  // Browser fetch() cannot distinguish pre-connect DNS/TCP errors from mid-flight
  // response drops (both surface as TypeError). Only safe reads walk multiple
  // origins inside a single call; writes cool down the failing origin so the
  // caller's own retry / outbox replays the same Idempotency-Key onto the next
  // healthy standby origin without multiplying attempts behind UI state machines.
  const safeMethod = method === "GET" || method === "HEAD";
  const attempts = safeMethod ? candidates.length : Math.min(candidates.length, 1);
  let lastError: unknown;
  for (let i = 0; i < attempts; i++) {
    const base = candidates[i];
    const isLast = i + 1 === attempts;
    const startedMs = performance.now();
    try {
      const res = await fetch(`${base}${path}`, init);
      if ([502, 503, 504].includes(res.status) && isWorkerNodeProxyPath(path)) {
        return res;
      }
      if ([502, 503, 504, 522, 524].includes(res.status)) {
        endpointCooldownUntil.set(base, Date.now() + ENDPOINT_COOLDOWN_MS);
        recordTransportFailure();
        if (safeMethod && !isLast) continue;
      } else if (res.status < 500) {
        endpointCooldownUntil.delete(base);
        recordFetchTelemetry(res, startedMs, base, method, path);
      }
      return res;
    } catch (err) {
      lastError = err;
      if (!isAbortError(err)) {
        endpointCooldownUntil.set(base, Date.now() + ENDPOINT_COOLDOWN_MS);
        recordTransportFailure();
      }
      if (isAbortError(err) || !safeMethod || isLast) throw err;
    }
  }
  throw lastError ?? new TypeError("Load failed");
}

export function setApiUrl(url: string) {
  const clean = url.trim().replace(/\/+$/, "");
  if (clean !== getApiUrl()) resetTransportState();
  localStorage.setItem(URL_KEY, clean);
}

export function getJwt(): string | null {
  return localStorage.getItem(JWT_KEY);
}

const [connected, setConnected] = createSignal(!!getJwt());
export const isConnected = connected;
export const [connectionVersion, bumpConnectionVersion] = createSignal(0);

let connectionSave = Promise.resolve();
let connectionSavesInFlight = 0;
export const isDesktopConnectionSaving = (): boolean => connectionSavesInFlight > 0;
function persistDesktopConnection(connection: {api_url:string;token:string}|null) {
  const invoke=nativeInvoke();
  if(!invoke)return;
  connectionSavesInFlight++;
  connectionSave=connectionSave.catch(()=>{}).then(()=>invoke('desktop_connection_save',{connection})).catch(swallow("api.connectionSave")).finally(()=>{connectionSavesInFlight--;});
}
export async function restoreDesktopConnection() {
  const invoke=nativeInvoke();
  if(!invoke)return;
  // Migrate an existing web-origin login before consulting the desktop store.
  if(getJwt()){persistDesktopConnection({api_url:getApiUrl(),token:getJwt()!});return;}
  const saved=await invoke('desktop_connection_load').catch(()=>null);
  if(saved?.api_url&&saved?.token)setConnection(saved.api_url,saved.token,{persist:false});
}

function disconnectNativeSync(){
  const invoke=nativeInvoke();
  if(!invoke||!getJwt())return;
  void invoke("project_context_disconnect",{request:{endpoint:getApiUrl(),token:getJwt(),project:"disconnect"}}).catch(swallow("api.disconnect.projectContext"));
  void invoke("local_origin_disconnect",{connection:{api_url:getApiUrl(),token:getJwt()}}).catch(swallow("api.disconnect.localOrigin"));
}
export function setConnection(url: string, token: string, options?: { persist?: boolean }) {
  const changed = url.replace(/\/+$/,"")!==getApiUrl() || token!==getJwt();
  if(getJwt() && changed)disconnectNativeSync();
  if(changed){resetMissionHierarchy();ancestorCache.clear();void clearPersistentCache();resetCurrentUserState();}
  resetNetworkHealth();
  setApiUrl(url);
  localStorage.setItem(JWT_KEY, token);
  setConnected(true);
  if(options?.persist!==false)persistDesktopConnection({api_url:getApiUrl(),token});
  invalidateReads();
  catalogMemory.clear();
  cacheReset();
  bumpConnectionVersion(v => v + 1);
}

export function clearConnection(options?: { persist?: boolean }) {
  disconnectNativeSync();
  resetMissionHierarchy();
  ancestorCache.clear();
  resetNetworkHealth();
  resetCurrentUserState();
  void clearPersistentCache();
  const hadConnection = connected() || !!getJwt();
  localStorage.removeItem(JWT_KEY);
  if(options?.persist!==false)persistDesktopConnection(null);
  setConnected(false);
  catalogMemory.clear();
  if (!hadConnection) return;
  invalidateReads();
  cacheReset();
  bumpConnectionVersion(v => v + 1);
}

export interface CurrentUser {
  id: string;
  username: string;
  role: "admin" | "member";
  unix_username: string | null;
  daily_spend_cap_cents: number | null;
  spent_today_cents: number;
}

export interface AuthCapabilities {
  can_manage_users: boolean;
  can_use_core_target: boolean;
  can_manage_global_providers: boolean;
}

export interface AuthStatusInfo {
  auth_mode: "disabled" | "single_tenant" | "multi_user" | string;
  password_source: "dashboard" | "environment" | "users" | "env" | "none" | string;
  password_changed_at?: string | null;
  dev_mode: boolean;
  auth_required?: boolean;
  authenticated?: boolean;
  user?: CurrentUser | null;
  capabilities?: AuthCapabilities | null;
}

export type AuthMeResponse = AuthStatusInfo;

const [currentUserSignal, setCurrentUserSignal] = createSignal<CurrentUser | null>(null);
const [authCapabilitiesSignal, setAuthCapabilitiesSignal] = createSignal<AuthCapabilities | null>(null);
const [authModeSignal, setAuthModeSignal] = createSignal<string>("single_tenant");
const [currentUserLoadingSignal, setCurrentUserLoadingSignal] = createSignal<boolean>(false);

export const currentUser = currentUserSignal;
export const authCapabilities = authCapabilitiesSignal;
export const authModeState = authModeSignal;
export const currentUserLoading = currentUserLoadingSignal;

export function resetCurrentUserState(nextAuthMode = "single_tenant"): void {
  setCurrentUserSignal(null);
  setAuthCapabilitiesSignal(null);
  setAuthModeSignal(nextAuthMode);
  setCurrentUserLoadingSignal(false);
}

export function applyAuthMeResponse(info: Partial<AuthMeResponse> | null | undefined): void {
  if (!info) {
    resetCurrentUserState();
    return;
  }
  const mode = typeof info.auth_mode === "string" && info.auth_mode ? info.auth_mode : "single_tenant";
  setAuthModeSignal(mode);
  if (info.user && typeof info.user.id === "string" && typeof info.user.username === "string") {
    const role = info.user.role === "member" ? "member" : "admin";
    setCurrentUserSignal({
      id: info.user.id,
      username: info.user.username,
      role,
      unix_username: typeof info.user.unix_username === "string" && info.user.unix_username ? info.user.unix_username : null,
      daily_spend_cap_cents:
        typeof info.user.daily_spend_cap_cents === "number" && Number.isFinite(info.user.daily_spend_cap_cents)
          ? info.user.daily_spend_cap_cents
          : null,
      spent_today_cents:
        typeof info.user.spent_today_cents === "number" && Number.isFinite(info.user.spent_today_cents)
          ? info.user.spent_today_cents
          : 0,
    });
  } else {
    setCurrentUserSignal(null);
  }
  if (info.capabilities && typeof info.capabilities === "object") {
    setAuthCapabilitiesSignal({
      can_manage_users: Boolean(info.capabilities.can_manage_users),
      can_use_core_target: Boolean(info.capabilities.can_use_core_target),
      can_manage_global_providers: Boolean(info.capabilities.can_manage_global_providers),
    });
  } else {
    setAuthCapabilitiesSignal(null);
  }
}

export function isAdminUser(): boolean {
  const u = currentUserSignal();
  if (u) return u.role === "admin";
  const caps = authCapabilitiesSignal();
  if (caps) return caps.can_manage_users;
  return authModeSignal() !== "multi_user";
}

let inflightAuthMe: { version: number; promise: Promise<AuthMeResponse | null> } | null = null;

export async function refreshCurrentUser(force = false): Promise<AuthMeResponse | null> {
  if (!isConnected()) {
    resetCurrentUserState();
    return null;
  }
  const version = connectionVersion();
  if (!force && inflightAuthMe && inflightAuthMe.version === version) {
    return inflightAuthMe.promise;
  }
  setCurrentUserLoadingSignal(true);
  let tracked: Promise<AuthMeResponse | null> | null = null;
  const promise = (async (): Promise<AuthMeResponse | null> => {
    try {
      const me = await api<AuthMeResponse>("/api/auth/me", force ? { method: "GET" } : undefined);
      if (version === connectionVersion()) applyAuthMeResponse(me);
      return me;
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        try {
          const st = await api<AuthStatusInfo>("/api/auth/status");
          if (version === connectionVersion()) applyAuthMeResponse(st);
          return st;
        } catch {
          // Legacy server without /api/auth/status
        }
      }
      return null;
    } finally {
      if (version === connectionVersion()) setCurrentUserLoadingSignal(false);
      if (tracked && inflightAuthMe?.promise === tracked) inflightAuthMe = null;
    }
  })();
  tracked = promise;
  inflightAuthMe = { version, promise };
  return promise;
}

export interface ServerHealthInfo {
  status?: string;
  version?: string;
  server_build?: string;
  build_id?: string;
  dev_mode?: boolean;
  auth_required?: boolean;
  auth_mode?: "disabled" | "single_tenant" | "multi_user" | string;
  github_enabled?: boolean;
  github_oauth_client_state?: boolean;
}

const serverBuildByEndpoint = new Map<string, string>();
const [serverBuildVersion, bumpServerBuildVersion] = createSignal(0);
export { serverBuildVersion };

function normalizeEndpointKey(url = getApiUrl()): string {
  return url.trim().replace(/\/+$/, "");
}

/** Deterministic 64-bit FNV-1a hash of an arbitrary string for WASM kernel `serverBuild` / IDs (`SM-24`, `SM-26`). */
export function hashStringU64(value: string): bigint {
  let hash = 0xcbf29ce484222325n;
  for (let i = 0; i < value.length; i++) {
    hash ^= BigInt(value.charCodeAt(i) & 0xffff);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash === 0n ? 1n : hash;
}

/** Record an observed `server_build` / `version` token for an endpoint (`SM-26`). Returns `true` when it changed from a previously known build. */
export function recordServerBuild(build: string | null | undefined, endpoint = getApiUrl()): boolean {
  const cleanBuild = build?.trim();
  const key = normalizeEndpointKey(endpoint);
  if (!cleanBuild || !key) return false;
  const prev = serverBuildByEndpoint.get(key);
  if (prev === cleanBuild) return false;
  serverBuildByEndpoint.set(key, cleanBuild);
  bumpServerBuildVersion((v) => v + 1);
  if (prev !== undefined && typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("orb:server-build-changed", { detail: { endpoint: key, previousBuild: prev, serverBuild: cleanBuild } }));
  }
  return prev !== undefined;
}

export function getServerBuild(endpoint = getApiUrl()): string | null {
  return serverBuildByEndpoint.get(normalizeEndpointKey(endpoint)) ?? null;
}

export function getServerBuildHash(endpoint = getApiUrl()): bigint {
  const b = getServerBuild(endpoint);
  return b ? hashStringU64(b) : 0n;
}

/** Scoped epoch key `(endpoint, server_build, connectionVersion)` for capability latches (`SM-26`). */
export function currentCapabilityEpochKey(endpoint = getApiUrl()): string {
  serverBuildVersion();
  const key = normalizeEndpointKey(endpoint);
  const build = serverBuildByEndpoint.get(key) ?? "";
  return `${connectionVersion()}|${key}|${build}`;
}

export async function probeHealth(baseUrl?: string, signal?: AbortSignal): Promise<ServerHealthInfo> {
  const target = baseUrl ?? getApiUrl();
  const res = await transportFetch(
    "/api/health",
    { method: "GET", signal: signal ?? AbortSignal.timeout(8_000) },
    baseUrl,
  );
  if (!res.ok) throw new Error(`Health check failed (${res.status})`);
  const headerBuild = res.headers?.get?.("x-orb-server-build") ?? res.headers?.get?.("x-orb-version");
  const info = (await res.json()) as ServerHealthInfo;
  recordServerBuild(info.server_build ?? info.build_id ?? headerBuild ?? info.version, target);
  return info;
}

export async function login(password: string, username?: string): Promise<void> {
  const cleanUser = username?.trim();
  const payload = cleanUser ? { password, username: cleanUser } : { password };
  const res = await transportFetch("/api/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const text = (await res.text().catch(() => "")).trim();
    throw new Error(text || `Login failed (${res.status})`);
  }
  const data = (await res.json()) as { token?: string };
  if (!data.token) throw new Error("Login response did not include a token");
  setConnection(getApiUrl(), data.token);
}

import { classifyConflictError, parseConflictCodeFromDetail } from "./conflictClassification";
export { classifyConflictError };

export class ApiError extends Error {
  public readonly conflictCode?: ConflictDispositionTag;
  constructor(public status: number, public detail: string) {
    super(`${status} ${detail}`.trim());
    this.conflictCode = status === 409 ? parseConflictCodeFromDetail(detail) : undefined;
  }
}

/** Typed `409 Conflict` classifications aligned with `OrbLocald.Spec.verifyLocalConflictDisposition` (`SM-23`, `SM-26`). */
export type ConflictDispositionTag =
  | "stopping"
  | "non_terminal_run"
  | "already_ended"
  | "moved"
  | "stale_receipt";

export interface ConflictClassification {
  tag: ConflictDispositionTag;
  /** `true` when transient (`stopping` / `non_terminal_run`); `false` when terminal (`already_ended` / `moved` / `stale_receipt`). */
  retryable: boolean;
}

export class InvalidApiResponseError extends Error {
  readonly streamReadFailed: boolean;
  constructor(path: string, options?: ErrorOptions & { streamReadFailed?: boolean }) {
    super(`Couldn’t read the server response for ${path}. Please retry; your draft is kept.`, options);
    this.streamReadFailed = options?.streamReadFailed === true;
  }
}

/** Default deadline of a request without its own signal. WebKit reports this
 * timeout as the same "AbortError: Fetch is aborted" as an explicit abort, so
 * every abort is logged with its reason (`noteAbort`). */
export const REQUEST_TIMEOUT_MS = 30_000;
/** Managed-VM cold boot + enrollment (`auto-managed:*` / `/api/managed-machines`)
 * is bounded on Core by a 360–480 s wall deadline (`src/managed/mod.rs`); keep
 * the desktop client deadline above Core's so provisioning never aborts early. */
export const MANAGED_PROVISION_TIMEOUT_MS = 540_000;
/** Core did not answer before the deadline. Still an abort for `isAbortError`
 * and `isTransientNetworkError`, so polls retry and keep what they show. */
export class RequestTimeoutError extends Error {
  override name = "TimeoutError";
  constructor() { super("The server is taking too long to answer. Please retry; nothing was lost."); }
}
export type AbortReason = "timeout" | "caller-timeout" | "caller-abort";
export function isAbortError(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name;
  return name === "AbortError" || name === "TimeoutError";
}
function abortReason(signal?: AbortSignal | null): AbortReason {
  if (!signal) return "timeout";
  return isAbortError(signal.reason) && (signal.reason as { name?: string }).name === "TimeoutError" ? "caller-timeout" : "caller-abort";
}
/** Why a request was aborted: the default deadline (no answer in time, e.g.
 * the network stalled) or the caller's own signal. Written to the
 * diagnostics log and, in development, the console. */
export function noteAbort(request: string, reason: AbortReason, ms: number): void {
  const entry = { request: request.slice(0, 160), reason, ms: Math.round(ms) };
  note("request-aborted", entry);
  if (import.meta.env?.DEV) console.warn("[orb] request aborted", entry);
}
/** A failure that says nothing about the request itself: the connection
 * stalled, dropped or timed out, or a proxy answered for an unreachable Core.
 * Only idempotent operations may retry on it. */
export function isTransientNetworkError(error: unknown): boolean {
  if (error instanceof ApiError) return [502, 503, 504, 522, 524].includes(error.status);
  if (error instanceof InvalidApiResponseError) return true;
  if (isAbortError(error)) return true;
  return error instanceof TypeError && /load failed|failed to fetch|networkerror|network connection|internet connection|could not connect/i.test(error.message);
}

export function api<T>(
  path: string,
  init?: RequestInit,
  explicitBase?: string,
  explicitPriority?: RequestPriority,
): Promise<T> {
  // Explicit signals/options retain independent cancellation semantics; keep
  // priority lanes isolated in `sharedRead` so a parked `p2` prefetch never
  // blocks a foreground `p1` reader for the same URL.
  if (!init && !explicitBase) {
    return sharedRead(`${connectionVersion()}:${getApiUrl()}:${explicitPriority ?? "default"}:${path}`, () =>
      apiRequest<T>(path, undefined, false, undefined, explicitPriority),
    );
  }
  if (
    init?.method &&
    init.method.toUpperCase() !== "GET" &&
    !path.startsWith("/api/usage-telemetry/events")
  ) {
    invalidateReads();
  }
  return apiRequest<T>(path, init, false, explicitBase, explicitPriority);
}
/** Like `api`, for endpoints that answer with plain text (e.g. Library save receipts). */
export function apiText(path: string, init?: RequestInit): Promise<string> {
  if (
    init?.method &&
    init.method.toUpperCase() !== "GET" &&
    !path.startsWith("/api/usage-telemetry/events")
  ) {
    invalidateReads();
  }
  return apiRequest<string>(path, init, true);
}
function redactDiagnosticPath(path: string): string {
  return path.replace(/([?&](?:q|query)=)[^&]*/gi, "$1[redacted]");
}

async function apiRequest<T>(
  path: string,
  init?: RequestInit,
  text = false,
  explicitBase?: string,
  explicitPriority?: RequestPriority,
): Promise<T> {
  const from = performance.now(), label = `${init?.method?.toUpperCase() ?? "GET"} ${redactDiagnosticPath(path)}`;
  try {
    const result = await sendRequest<T>(path, init, text, explicitBase, explicitPriority);
    requestDone(label, performance.now() - from, true);
    return text ? result : stickMissionRows(path, result);
  } catch (error) {
    requestDone(label, performance.now() - from, false, error instanceof Error ? error.message : String(error));
    throw error;
  }
}
const isMissionRow = (row: unknown): row is Mission => !!row && typeof row === "object" && typeof (row as Mission).id === "string" &&
  typeof (row as Mission).status === "string" && ("title" in row || "tags" in row || "parent_mission_id" in row);
/** Every mission Core answers with passes the hierarchy boundary: links are
 * remembered and restored where a response omits them (sidebar-hierarchy.md). */
function stickMissionRows<T>(path: string, result: T): T {
  if (!path.startsWith("/api/control/missions")) return result;
  if (Array.isArray(result)) return (result.some(isMissionRow) ? result.map(row => isMissionRow(row) ? stickHierarchy(row) : row) : result) as T;
  return (isMissionRow(result) ? stickHierarchy(result) : result) as T;
}
function isFastRetryableError(error: unknown, init?: RequestInit): boolean {
  const method = (init?.method ?? "GET").toUpperCase();
  if (method !== "GET" && method !== "HEAD") return false;
  if (init?.signal?.aborted) return false;
  if (error instanceof RequestTimeoutError || isAbortError(error)) return false;
  if (error instanceof InvalidApiResponseError) return error.streamReadFailed;
  return error instanceof TypeError && /load failed|failed to fetch|networkerror|network connection|internet connection|could not connect/i.test(error.message);
}

async function sendRequest<T>(
  path: string,
  init?: RequestInit,
  text = false,
  explicitBase?: string,
  explicitPriority?: RequestPriority,
): Promise<T> {
  try {
    return await sendRequestOnce<T>(path, init, text, explicitBase, explicitPriority);
  } catch (error) {
    if (!isFastRetryableError(error, init)) throw error;
    const delayMs = 200 + Math.floor(Math.random() * 200);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    if (init?.signal?.aborted) throw error;
    return sendRequestOnce<T>(path, init, text, explicitBase, explicitPriority);
  }
}

async function sendRequestOnce<T>(
  path: string,
  init?: RequestInit,
  text = false,
  explicitBase?: string,
  explicitPriority?: RequestPriority,
): Promise<T> {
  const version = connectionVersion();
  const jwt = getJwt();
  const headers: Record<string, string> = {
    ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
    ...((init?.headers as Record<string, string> | undefined) ?? {}),
  };
  const started = performance.now();
  let res: Response;
  try {
    res = await transportFetch(
      path,
      { ...init, headers, ...(init?.signal ? { signal: init.signal } : {}) },
      explicitBase,
      explicitPriority,
      REQUEST_TIMEOUT_MS,
    );
  } catch (error) {
    if (!isAbortError(error)) throw error;
    const reason = abortReason(init?.signal);
    noteAbort(`${init?.method?.toUpperCase() ?? "GET"} ${redactDiagnosticPath(path)}`, reason, performance.now() - started);
    // WebKit reports any timeout as "AbortError: Fetch is aborted". A
    // deadline gets plain words; a caller's own abort stays an AbortError.
    if (reason !== "caller-abort") throw new RequestTimeoutError();
    throw error;
  }
  if (res.status === 401) {
    const detail = (await res.text().catch(() => "")).trim();
    if (path === "/api/auth/change-password" && /current password/i.test(detail)) {
      throw new ApiError(401, detail);
    }
    if (connectionVersion() === version) clearConnection();
    throw new Error("401 Unauthorized — reconnect in Settings → Backend");
  }
  const observedBuildHeader = res.headers?.get?.("x-orb-server-build") ?? res.headers?.get?.("x-orb-version");
  if (observedBuildHeader && connectionVersion() === version) {
    recordServerBuild(observedBuildHeader, explicitBase ?? getApiUrl());
  }
  if (!res.ok) {
    const text = (await res.text().catch(() => "")).trim();
    throw new ApiError(res.status, text);
  }
  let body: string;
  try {
    body = await res.text();
  } catch (cause) {
    if (connectionVersion() !== version) throw new Error("The backend changed. Try again; your draft is kept.");
    if (isAbortError(cause)) {
      const reason = abortReason(init?.signal);
      noteAbort(`${init?.method?.toUpperCase() ?? "GET"} ${redactDiagnosticPath(path)}`, reason, performance.now() - started);
      if (reason !== "caller-abort") throw new RequestTimeoutError();
      throw cause;
    }
    recordTransportFailure();
    throw new InvalidApiResponseError(`${init?.method ?? "GET"} ${redactDiagnosticPath(path)}`, {
      cause,
      streamReadFailed: true,
    });
  }
  if (connectionVersion() !== version) throw new Error("The backend changed. Try again; your draft is kept.");
  if (text) return body as T;
  // Empty mutation receipts are valid for endpoints returning only a status.
  // A failed/invalid JSON read is not a successful response with no value.
  if (!body.trim() && init?.method && init.method.toUpperCase() !== "GET") return undefined as T;
  try {
    return JSON.parse(body) as T;
  } catch (cause) {
    throw new InvalidApiResponseError(`${init?.method ?? "GET"} ${path}`, { cause });
  }
}

export interface RemoteNodeView {
  resource_history?: { time: number; memory?: number | null; cpu?: number | null; gpu?: number | null }[];
  cpu_total?: number | null;
  mem_total_bytes?: number | null;
  mem_available_bytes?: number | null;
  disk_total_bytes?: number | null;
  disk_available_bytes?: number | null;
  disk_pressure_pinned?: boolean;
  id: string;
  /** Human name for managed machines ("small-a"); `id` stays immutable. */
  display_name?: string | null;
  /** Managed VM ownership kind ("user" | "mission") when projected by Core. */
  owner_kind?: string | null;
  base_url: string;
  token_env: string;
  status: "online" | "degraded" | "offline" | "unknown" | string;
  labels: string[];
  version: string | null;
  capacity_total: number | null;
  capacity_available: number | null;
  active_jobs: number | null;
  queued_jobs: number | null;
  priority_jobs?: number | null;
  coordinator_capacity?: number | null;
  last_seen: string | null;
  error: string | null;
  cordoned: boolean;
  quarantined_harnesses?: string[];
  admin_only?: boolean;
  core_colocated?: boolean;
}

/**
 * Server-advertised typed remote launch support (`GET /api/remote-nodes`).
 * Absent on older backends, which only accept raw `remote_command` launches
 * that Orb never generates. `harnesses` are harness ids, not model ids; model
 * and provisioning validation stay server-owned on the typed create path.
 */
export interface RemoteLaunchCapability {
  typed?: boolean;
  harnesses?: string[];
  raw_command?: boolean;
  proxy_url_configured?: boolean;
  /** Harness ids that need the backend model proxy. Absent: claudecode and opencode only. */
  requires_proxy_harnesses?: string[];
  error_prefixes?: string[];
}

export interface ManagedComputeFleetSummary {
  enabled: boolean;
  boat_enabled?: boolean;
  default_subagent_target?: string;
  active_machines?: number;
  max_concurrent?: number | null;
}

export interface RemoteNodesResponse {
  enabled: boolean;
  nodes: RemoteNodeView[];
  remote_launch?: RemoteLaunchCapability | null;
  managed_compute?: ManagedComputeFleetSummary | null;
}

export interface CustomModelConfig {
  id: string;
  name?: string | null;
  context_limit?: number | null;
  output_limit?: number | null;
  rpm_limit?: number | null;
  tpm_limit?: number | null;
  max_concurrency?: number | null;
}

export interface AIProvider {
  id: string;
  provider_type: string;
  provider_type_name: string;
  name: string;
  label?: string | null;
  base_url?: string | null;
  custom_models?: CustomModelConfig[] | null;
  rpm_limit?: number | null;
  max_concurrency?: number | null;
  enabled: boolean;
  globally_enabled?: boolean;
  user_enabled?: boolean;
  effective_enabled?: boolean;
  uses_oauth: boolean;
  has_api_key?: boolean;
  has_oauth?: boolean;
  /** "cli_proxy" when CLIProxyAPI owns the OAuth credential (reconnect via proxy login). */
  credential_owner?: "cli_proxy" | "sandboxed_sh";
  account_email?: string | null;
  /** Order among the provider's accounts: lower is tried first. */
  priority?: number;
  /** Automatically redeem a banked subscription reset when all accounts hit a usage limit. */
  auto_reset_on_limit?: boolean;
  status: { type: string; reason?: string; message?: string };
}

export interface MissionHistoryEntry {
  id?: string;
  role: string;
  content: string;
}

/** Read-only remote execution evidence from the durable job ledger. */
export interface RemoteJob {
  job_id: string;
  node_id: string;
  phase: string;
  node_state?: string | null;
  forced?: boolean;
  exit_code?: number | null;
  error?: string | null;
  accepted_at?: string | null;
  heartbeat_at?: string | null;
  started_at?: string | null;
  finished_at?: string | null;
  observed_age_secs?: number | null;
  lease_state?: string | null;
  terminal_reason?: string | null;
}

export type CodexServiceTier = 'standard' | 'fast' | 'ultrafast';
export type QueueWait = { reason: "waiting_for_slot"; slots_used: number; slots_max: number; running_mission_ids: string[] };

export interface Mission {
  recovery?: { kind: "transient" | "background" | "quota" | "output_limit"; reason: string; resume_at: string; attempt: number; max_attempts: number } | null;
  scheduling?: { owner: "sandboxed"; durable: boolean; native_schedule_wakeup: boolean; native_cron: boolean; transport: "mcp" | "acp_mcp" | "local_command" | "unavailable" };
  continuation?: import("./continuations").ContinuationSummary | null;
  /** The mission that launched this one through the MCP, if any. */
  parent_mission_id?: string | null;
  /** Verified source of an isolated Hermes callback; presentation lineage only. */
  callback_parent_mission_id?: string | null;
  /** "hermes" when a controller created it; its controller session then follows. */
  origin?: string | null;
  origin_session_id?: string | null;
  execution_kind?: "hosted";
  cloud?: import("./cloudAgentApi").CloudExecution;
  local_sync_pending?: boolean;
  /** The desktop journal itself is still running this mission (not a status Core confirmed). */
  local_run_active?: boolean;
  local_sync_error?: string | null;
  local_sync_local_only?: boolean;
  machine_transfer?: import("./machineTransfer").TransferAction;
  working_directory?: string | null;
  id: string;
  /** Sidebar-only stand-in for a parent that is not loaded yet (never sent by Core). */
  orb_placeholder?: boolean;
  status: string;
  title: string | null;
  history: MissionHistoryEntry[];
  goal_mode?: boolean;
  goal_objective?: string | null;
  remote_node_id?: string | null;
  terminal_reason?: string | null;
  status_message?: string | null;
  execution?: { state?: string; terminal_reason?: string | null; generation?: number };
  remote_job?: RemoteJob | null;
  /** Set while a pending mission waits for Core to free a parallel slot. */
  queue_wait?: QueueWait | null;
  workspace_name?: string | null;
  workspace_id?: string | null;
  agent?: string | null;
  backend?: string;
  model_override?: string | null;
  /** Reasoning effort in force for the next turn. Absent means backend default. */
  model_effort?: string | null;
  permission_mode?: string | null;
  fast_mode?: boolean;
  service_tier?: CodexServiceTier;
  config_profile?: string | null;
  session_id?: string | null;
  project?: string | null;
  folder?: string;
  placement_revision?: number;
  authority_mode?: string | null;
  placement_kind?: string | null;
  superseded_by_mission_id?: string | null;
  track?: string | null;
  github_pr?: string | null;
  tags?: string[];
  first_viewed_at?: string | null;
  last_output_at?: string | null;
  metadata_updated_at?: string | null;
  owner_user_id?: string | null;
  owner_username?: string | null;
  viewer_role?: "owner" | "participant" | string | null;
  shared_with?: Array<{ user_id: string; username: string; created_at?: string }>;
  created_at: string;
  updated_at: string;
}

/** True when the signed-in user is viewing a mission owned by another user via an explicit share. */
export function isMissionParticipant(mission?: Pick<Mission, "viewer_role"> | null): boolean {
  return mission?.viewer_role === "participant";
}

import {
  hasTypedSuperseded,
  isClientPlacement,
  isMissionWriter,
  supersededSuccessorId,
} from "./missionTree";
export {
  hasTypedSuperseded,
  isClientPlacement,
  isMissionWriter,
  supersededSuccessorId,
};

export interface CreateMissionBody {
  cloud?: import("./cloudAgentApi").CloudSelection;
  supersedes_mission_id?: string;
  track?: string;
  github_pr?: string;
  writer?: boolean;
  workspace_id?: string;
  working_directory?: string;
  agent?: string;
  fast_mode?: boolean;
  service_tier?: CodexServiceTier;
  tags?: string[];
  idempotency_key?: string;
  title?: string;
  prompt?: string;
  remote_node_id?: string;
  managed_allow_24h_commitment?: boolean;
  managed_ttl_minutes?: number;
  /** Stable project identifier — groups the mission under the project. */
  project?: string;
  /** Normalized folder path inside the project ("" for project root). */
  folder?: string;
  /**
   * Harness id (claudecode, codex, opencode, grok, antigravity). Goal mode has no
   * dedicated create field: a prompt of the form `/goal <objective>` is what
   * makes the server persist `goal_mode` + `goal_objective` (control/goal.rs
   * `parse_goal_objective`).
   */
  backend?: string;
  /** Model id understood by that harness, e.g. claude-fable-5-2. */
  model_override?: string;
  model_effort?: string;
  permission_mode?: string;
  worktree_mode?: "local" | "worktree" | "auto";
  attachments?: MissionAttachment[];
  /** `"client"` records the mission and leaves execution to this Orb process. */
  placement?: "client";
}

export type MissionAttachmentKind = "file" | "folder" | "controller" | "context" | "path";
export interface MissionAttachment {
  kind: MissionAttachmentKind;
  path?: string;
}

export interface BackendInfo {
  native_plan?: boolean;
  id: string;
  name: string;
}

export interface BackendModelOption {
  value: string;
  label: string;
  description?: string;
  provider_id?: string;
}

/** Harness (backend) with the models it can run right now. */
export interface HarnessChoice {
  backend: BackendInfo;
  models: BackendModelOption[];
}

/** In-memory mirror of `orb.catalog:*` entries so synchronous hydration and
 * offline fallback still work when WebKit `localStorage` hits its 5 MB quota. */
const catalogMemory = new Map<string, unknown>();

function catalogStorageKey(path: string, token = getJwt()): string {
  let hash = 2166136261;
  for (const c of `${getApiUrl()}:${token ?? ""}`) hash = Math.imul(hash ^ c.charCodeAt(0), 16777619);
  return `orb.catalog:${hash >>> 0}:${path}`;
}

/** Small read-only catalogs keep local launch available across offline restarts. */
async function cachedCatalog<T>(path:string, valid?: (value: unknown) => boolean, force = false):Promise<T>{
 const version=connectionVersion(),token=getJwt();
 const key=catalogStorageKey(path,token);
 try{const value=await api<T>(path,force?{method:"GET"}:undefined);if(valid && !valid(value))throw new Error("Couldn’t load projects. The server returned an invalid response.");if(version===connectionVersion()){catalogMemory.set(key,value);try{localStorage.setItem(key,JSON.stringify(value));}catch{}}return value;}
 catch(error){
  if(version!==connectionVersion()||getJwt()!==token||error instanceof ApiError)throw error;
  if(catalogMemory.has(key)){const mem=catalogMemory.get(key);if(!valid || valid(mem))return mem as T;}
  const stored=localStorage.getItem(key);if(stored){try{const value=JSON.parse(stored);if(!valid || valid(value)){catalogMemory.set(key,value);return value as T;}}catch{}}
  throw error;
 }
}

async function listBackends(): Promise<BackendInfo[]> {
  const data = await cachedCatalog<BackendInfo[] | { backends?: BackendInfo[] }>("/api/backends");
  return Array.isArray(data) ? data : (data.backends ?? []);
}

export async function listBackendModels(): Promise<Record<string, BackendModelOption[]>> {
  const [data, chains] = await Promise.all([
    cachedCatalog<{ backends?: Record<string, BackendModelOption[]> }>("/api/providers/backend-models"),
    cachedCatalog<{id:string;name:string;is_default?:boolean}[]>("/api/model-routing/chains"),
  ]);
  // Route identity comes from the chain store, never provider display labels.
  // Invalid responses must not silently remove an installed harness.
  if (!Array.isArray(chains)) throw new Error("Invalid model routing catalog");
  const chainOptions: BackendModelOption[] = chains.map(chain => ({ value: chain.id, label: `Routing — ${chain.name}` }));
  const chainIds = new Set(chains.flatMap(chain => [chain.id, chain.id.replace(/^builtin\//, "")]));
  const directOpencode = (data.backends?.opencode ?? []).filter(
    opt => opt.value && !chainIds.has(opt.value) && !chainIds.has(opt.value.replace(/^builtin\//, "")) && !opt.label.startsWith("Routing — "),
  );
  return { ...data.backends, opencode: [...chainOptions, ...directOpencode] };
}


export async function listHarnessChoices(): Promise<HarnessChoice[]> {
  const [backends, models] = await Promise.all([listBackends(), listBackendModels()]);
  return backends
    .filter((b) => isHarness(b.id) && (models[b.id]?.length ?? 0) > 0)
    .sort((a, b) => harnessRank(a.id) - harnessRank(b.id))
    .map((b) => ({ backend: b, models: models[b.id] ?? [] }));
}

/** "Claude (Subscription) — Claude Fable 5.1" → "Fable 5.1". */
export function shortModelLabel(label: string): string {
  const tail = label.includes("—") ? label.slice(label.lastIndexOf("—") + 1).trim() : label.trim();
  // "Claude Fable 5.1" → "Fable 5.1"; other vendors keep their family name.
  return tail.replace(/^Claude\s+/, "");
}

/** Provider/routing prefix before "—", used to group multi-provider model pickers. */
export function modelLabelGroup(label: string): string | undefined {
  const idx = label.indexOf("—");
  if (idx <= 0) return undefined;
  const head = label.slice(0, idx).trim();
  return head || undefined;
}

export function modelPickerItems(models: BackendModelOption[]): { id: string; label: string; description?: string; group?: string }[] {
  const groups = new Set(models.map(m => modelLabelGroup(m.label)).filter((g): g is string => !!g));
  const showGroups = groups.size > 1;
  return models.map(m => ({
    id: m.value,
    label: shortModelLabel(m.label),
    ...(m.description ? { description: m.description } : {}),
    ...(showGroups && modelLabelGroup(m.label) ? { group: modelLabelGroup(m.label) } : {}),
  }));
}

export async function getRemoteNodes(): Promise<RemoteNodesResponse> {
  return api("/api/remote-nodes");
}

/** Live-resize the job slot limit on a static remote runner node (`1..=256`) without restarting. */
export async function updateRemoteNodeCapacity(name: string, capacity: number): Promise<RemoteNodeView> {
  return api<RemoteNodeView>(`/api/nodes/${encodeURIComponent(name)}/capacity`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ capacity }),
  });
}

/** Cordon or uncordon a static remote runner node (`POST /api/nodes/:name/{cordon,uncordon}`). */
export async function setRemoteNodeCordoned(
  name: string,
  cordoned: boolean,
): Promise<{ node: string; cordoned: boolean; changed: boolean }> {
  return api(`/api/nodes/${encodeURIComponent(name)}/${cordoned ? "cordon" : "uncordon"}`, {
    method: "POST",
  });
}

/** A disabled account stays listed but is never chosen for a request. */
export async function setProviderEnabled(id: string, enabled: boolean): Promise<AIProvider> {
  return api<AIProvider>(`/api/ai/providers/${encodeURIComponent(id)}`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled }),
  });
}

/** Per-user preference for whether this globally configured provider account may be used for the caller's missions. */
export async function setProviderUserPreference(id: string, enabled: boolean): Promise<{ ok?: boolean; provider_id?: string; user_enabled?: boolean }> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/preference`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ enabled }),
  });
}

/** Toggle whether Core automatically redeems a banked subscription reset when all accounts hit a limit. */
export async function setProviderAutoResetOnLimit(id: string, autoResetOnLimit: boolean): Promise<AIProvider> {
  return api<AIProvider>(`/api/ai/providers/${encodeURIComponent(id)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ auto_reset_on_limit: autoResetOnLimit }),
  });
}

/** Set the order in which one provider's accounts are tried, first id first. */
export async function reorderProviders(ids: string[]): Promise<AIProvider[]> {
  return api<AIProvider[]>("/api/ai/providers/reorder", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ids }),
  });
}

export async function listProviders(signal?: AbortSignal): Promise<AIProvider[]> {
  const data = await api<AIProvider[] | { providers?: AIProvider[] }>("/api/ai/providers", signal ? { signal } : undefined);
  if (Array.isArray(data)) return data;
  return Array.isArray(data.providers) ? data.providers : [];
}

export interface SubscriptionResetGrant {
  id: string;
  label: string;
  clears?: string[];
  resets_left: number;
  expires_at?: number;
  usable_now: boolean;
  requires_limit: boolean;
  unavailable_reason?: string;
}

export interface SubscriptionResets {
  available_count: number;
  usable_now: boolean;
  grants?: SubscriptionResetGrant[];
  unavailable_reason?: string;
}

export interface ProviderUsage {
  subscription_resets?: SubscriptionResets;
  reset_redeemed?: boolean;
  woken_missions?: number;
  antigravity_plan?: string;
  antigravity_windows?: { label: string; used_percent: number; reset_at?: number }[];
  muse_plan?: string;
  muse_5h_used_percent?: number;
  muse_5h_reset?: number;
  muse_weekly_used_percent?: number;
  muse_weekly_reset?: number;
  mistral_plan?: string;
  mistral_monthly_used_percent?: number;
  mistral_monthly_reset?: number;
  /** Console session that reads the Vibe plan's monthly usage. */
  mistral_usage_session?: "connected" | "missing" | "expired";
  kimi_plan?: string;
  kimi_windows?: {label: string; used_percent?: number; reset_at?: number}[];
  kimi_5h_used_percent?: number;
  kimi_5h_reset?: number;
  kimi_weekly_used_percent?: number;
  kimi_weekly_reset?: number;
  xai_plan?: string;
  xai_credit_label?: string;
  xai_credit_used_percent?: number;
  xai_credit_remaining_percent?: number;
  xai_credit_reset?: number;
  xai_credit_window_seconds?: number;
  xai_on_demand_used?: number;
  xai_on_demand_cap?: number;
  xai_prepaid_usd?: number;
  provider_type: string;
  usage_note?: string;
  /** Google's page where the owner verifies an Antigravity account it refuses. */
  verification_url?: string;
  error?: string;
  status?: string;
  account_email?: string | null;
  account_name?: string | null;
  organization?: string | null;
  organization_id?: string | null;
  unified_status?: string;
  unified_reset?: number | string;
  unified_representative_claim?: string;
  unified_5h_utilization?: number;
  unified_5h_reset?: string;
  unified_5h_status?: string;
  unified_7d_utilization?: number;
  unified_7d_reset?: string;
  unified_7d_status?: string;
  requests_limit?: number;
  requests_remaining?: number;
  requests_reset?: string;
  tokens_limit?: number;
  tokens_remaining?: number;
  tokens_reset?: string;
  codex_plan_type?: string;
  codex_primary_used_percent?: number;
  codex_primary_reset_at?: number;
  codex_primary_window_minutes?: number;
  codex_secondary_used_percent?: number;
  codex_secondary_reset_at?: number;
  codex_secondary_window_minutes?: number;
  minimax_interval_remaining_percent?: number;
  minimax_interval_reset?: number;
  minimax_weekly_remaining_percent?: number;
  minimax_weekly_reset?: number;
  model_usage?: Array<{
    model: string;
    interval_remaining_percent: number;
    weekly_remaining_percent: number;
    interval_reset: number;
    weekly_reset: number;
  }>;
  zai_5h_used_percent?: number;
  zai_5h_reset?: number;
  zai_weekly_used_percent?: number;
  zai_weekly_reset?: number;
  zai_plan?: string;
  zai_tokens_percentage?: number;
  zai_tokens_reset?: number;
  zai_mcp_percentage?: number;
  zai_mcp_reset?: number;
  stale?: boolean;
}

export async function getProviderUsage(
  id: string,
  force = false,
  priority?: RequestPriority,
): Promise<ProviderUsage> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/usage${force ? "?force=true" : ""}`, undefined, undefined, priority);
}

/** Redeem a banked subscription usage-limit reset on an Anthropic or OpenAI account. */
export async function resetProviderUsage(id: string, opts?: { idempotencyKey?: string; grantId?: string }): Promise<ProviderUsage> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/reset-usage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      idempotency_key: opts?.idempotencyKey,
      grant_id: opts?.grantId,
    }),
  });
}

/** "Check again" after verifying an Antigravity account with Google. */
export async function recheckAntigravity(id: string): Promise<ProviderUsage> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/antigravity/recheck`, { method: "POST" });
}

/** Connect the Mistral console session that reads the monthly Vibe usage. */
export async function setMistralUsageSession(id: string, cookie: string): Promise<ProviderUsage> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/mistral-usage-session`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ cookie }),
  });
}

export async function clearMistralUsageSession(id: string): Promise<ProviderUsage> {
  return api(`/api/ai/providers/${encodeURIComponent(id)}/mistral-usage-session`, { method: "DELETE" });
}

export async function getAllProviderUsage(priority?: RequestPriority): Promise<Record<string, ProviderUsage>> {
  const data = await api<{ entries?: Record<string, ProviderUsage> }>("/api/ai/providers/usage", undefined, undefined, priority);
  return data.entries ?? {};
}

export type CliProxyLoginStatus = "pending" | "completing" | "completed" | "failed";

export interface CliProxyLoginStart {
  session_id: string;
  auth_url: string;
  flow?: "redirect" | "device" | "code";
  instructions?: string;
}

export interface CliProxyLoginState {
  status: CliProxyLoginStatus;
  auth_url?: string;
  message?: string;
}

export async function startSubscriptionLogin(provider: string, providerId?: string): Promise<CliProxyLoginStart> {
  return api(`/api/ai/providers/${provider === "mistral" ? "mistral-login" : "cli-proxy-login"}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider, provider_id: providerId }),
  });
}

export async function cancelSubscriptionLogin(sessionId: string): Promise<void> {
  await api(`/api/ai/providers/${sessionId.startsWith("mistral-") ? "mistral-login" : "cli-proxy-login"}/${encodeURIComponent(sessionId)}`, { method: "DELETE" });
}

export async function getSubscriptionLogin(sessionId: string): Promise<CliProxyLoginState> {
  return api(`/api/ai/providers/${sessionId.startsWith("mistral-") ? "mistral-login" : "cli-proxy-login"}/${encodeURIComponent(sessionId)}`);
}

export async function submitCliProxyLoginCallback(sessionId: string, url: string): Promise<CliProxyLoginState> {
  return api(`/api/ai/providers/cli-proxy-login/${sessionId}/callback`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url }),
  });
}

/** Open a URL in the system browser (tauri shell when native, tab in dev). */
export async function openExternalUrl(url: string): Promise<void> {
  try {
    const invoke = nativeInvoke();
    if (invoke) {
      await invoke("open_url", { url });
      return;
    }
  } catch {
    /* fall through */
  }
  window.open(url, "_blank");
}

export interface ProjectSummary {
  slug: string;
  title?: string | null;
  objective?: string | null;
  status: string;
  updated_at: string;
  /** Palette name, `null` for none; absent on a backend that does not store colors. */
  color?: string | null;
}

export interface ProjectFileEntry {
  name: string;
  kind: "dir" | "file";
  size?: number;
  modified?: string;
}

/** Create (or update) a project record on the core. Slug: lowercase, dashes. */
export async function createProject(body: { slug: string; title?: string; objective?: string }): Promise<ProjectSummary> {
  const created = await api<ProjectSummary>("/api/projects", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  archivedSlugs.delete(body.slug);
  const record: ProjectSummary = {
    slug: created?.slug || body.slug,
    title: created?.title ?? body.title ?? body.slug,
    objective: created?.objective ?? body.objective ?? null,
    status: created?.status ?? "active",
    updated_at: created?.updated_at ?? new Date().toISOString(),
    color: created?.color ?? null,
  };
  try {
    const key = catalogStorageKey("/api/projects");
    const raw = localStorage.getItem(key);
    if (raw) {
      const parsed = JSON.parse(raw) as { projects?: ProjectSummary[] };
      if (parsed && Array.isArray(parsed.projects)) {
        const idx = parsed.projects.findIndex((p) => p.slug === record.slug);
        if (idx >= 0) parsed.projects[idx] = { ...parsed.projects[idx], ...record };
        else parsed.projects.push(record);
        localStorage.setItem(key, JSON.stringify(parsed));
      }
    }
  } catch { /* ignore storage errors */ }
  return record;
}

/** Display-name rename: same slug, new title. */
export const updateProject = createProject;

const archivedSlugs = new Set<string>();

/** Board archive. The roster row stays; the project leaves the live list. */
export async function archiveProject(slug: string): Promise<void> {
  await api(`/api/projects/${encodeURIComponent(slug)}/action`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "archive" }),
  });
  archivedSlugs.add(slug);
}

export function peekCachedProjects(): ProjectSummary[] | null {
  if (!isConnected()) return null;
  try {
    const key = catalogStorageKey("/api/projects");
    let parsed: { projects?: unknown } | null = null;
    if (catalogMemory.has(key)) {
      parsed = catalogMemory.get(key) as { projects?: unknown };
    } else {
      const raw = localStorage.getItem(key);
      if (!raw) return null;
      parsed = JSON.parse(raw) as { projects?: unknown };
      if (parsed && typeof parsed === "object" && Array.isArray(parsed.projects)) {
        catalogMemory.set(key, parsed);
      }
    }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.projects)) return null;
    if (!parsed.projects.every((p) => !!p && typeof p === "object" && typeof (p as { slug?: unknown }).slug === "string")) {
      return null;
    }
    return (parsed.projects as ProjectSummary[]).filter(
      (p) => p.status !== "archived" && p.status !== "deleted" && !archivedSlugs.has(p.slug),
    );
  } catch {
    return null;
  }
}

export async function listProjects(force = false): Promise<ProjectSummary[]> {
  const fetchedAt = Date.now(), url = getApiUrl();
  const data = await cachedCatalog<{ projects: ProjectSummary[] }>("/api/projects",
    value => !!value && typeof value === "object" && Array.isArray((value as {projects?: unknown}).projects)
      && (value as {projects: unknown[]}).projects.every(project => !!project && typeof project === "object" && typeof (project as {slug?: unknown}).slug === "string"),
    force);
  // Colors ride on the roster; applying them never fails the list.
  try { void applyProjectRoster(data.projects ?? [], fetchedAt, url).catch(swallow("api.projectRoster")); } catch { /* keep the local colors */ }
  return (data.projects ?? []).filter(
    (p) => p.status !== "archived" && p.status !== "deleted" && !archivedSlugs.has(p.slug),
  );
}

/** A project's controller: the Hermes cron job that drives it. */
export interface ControllerJob {
  archived?: boolean;
  folder?: string;
  id: string;
  name: string;
  schedule?: string | null;
  enabled: boolean;
  state?: string | null;
  paused_reason?: string | null;
  next_run_at?: string | null;
  last_run_at?: string | null;
  last_status?: string | null;
  last_error?: string | null;
  failure_streak: number;
  deliver?: string | null;
}

export interface ControllerRun {
  id: string;
  at?: string | null;
  started_at?: string | null;
  finished_at?: string | null;
  duration_secs?: number | null;
  status?: string | null;
  source?: string | null;
  delivery_outcome?: string | null;
  silent: boolean;
  report: string;
  ctrl?: string | null;
  signature?: string | null;
  error?: string | null;
}

/** What the cron does: a prompt run on a schedule by a fresh agent. */
export interface ControllerSettings {
  prompt: string;
  prompt_chars: number;
  skills: string[];
  deliver?: string | null;
  failure_deliver?: string | null;
  repeat_times?: number | null;
  repeat_completed: number;
  model?: string | null;
  provider?: string | null;
  /** Creation-time defaults, kept separate from explicit overrides. */
  model_snapshot?: string | null;
  provider_snapshot?: string | null;
  reasoning_effort?: string | null;
  workdir?: string | null;
  script?: string | null;
  script_path?: string | null;
  script_content?: string | null;
  no_agent: boolean;
  continuity: boolean;
  monitor_url?: string | null;
  monitor_script?: string | null;
  enabled_toolsets: string[];
  created_at?: string | null;
  binding?: Record<string, unknown> | null;
  /** Cap on prompt + preloaded skills for scope-bound controllers. */
  prompt_budget?: number | null;
}

export interface ControllerView {
  slug: string;
  job: ControllerJob | null;
  settings?: ControllerSettings | null;
  runs: ControllerRun[];
}

/** Only the fields that changed; "" clears an optional pin. */
export interface ControllerPatch {
  project?: string;
  folder?: string;
  name?: string;
  schedule?: string;
  prompt?: string;
  script_content?: string;
  skills?: string[];
  deliver?: string;
  failure_deliver?: string;
  repeat?: number;
  workdir?: string;
  model?: string;
  provider?: string;
  reasoning_effort?: string;
  continuity?: boolean;
}

export async function updateController(slug: string, patch: ControllerPatch): Promise<ControllerView> {
  return normalizeControllerView(await api<HermesControllerView>(`/api/projects/${encodeURIComponent(slug)}/controller`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patch),
  }));
}

export async function getProjectController(slug: string, limit = 40, priority?: RequestPriority): Promise<ControllerView> {
  return normalizeControllerView(
    await api<HermesControllerView>(`/api/projects/${encodeURIComponent(slug)}/controller?limit=${limit}`, undefined, undefined, priority),
  );
}

export async function controllerAction(slug: string, action: "pause" | "resume" | "run" | "archive" | "restore" | "delete"): Promise<ControllerView> {
  const view = normalizeControllerView(await api<HermesControllerView>(`/api/projects/${encodeURIComponent(slug)}/controller/action`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action }),
  }));
  if (action === "run" && (!view.job || !view.job.enabled || view.job.state === "paused")) {
    throw new Error("The scheduler did not wake the paused controller. Your steer is still saved.");
  }
  return view;
}

export async function deleteProjectController(slug: string): Promise<ControllerView> {
  return normalizeControllerView(await api<HermesControllerView>(`/api/projects/${encodeURIComponent(slug)}/controller`, {
    method: "DELETE",
  }));
}

/** Additional Hermes jobs explicitly bound to this project by the core. */
export async function listProjectCrons(slug: string, priority?: RequestPriority): Promise<ControllerJob[]> {
  const data = await api<{ jobs?: HermesJob[] }>(`/api/projects/${encodeURIComponent(slug)}/crons`, undefined, undefined, priority);
  return (data.jobs ?? []).map((job) => getProjectCronFromJob(slug, job).job!);
}

export interface ProjectCronDefaults { deliver: string; route_ready: boolean; folders_supported?: boolean }
export async function getProjectCronDefaults(slug: string): Promise<ProjectCronDefaults> {
  return api(`/api/projects/${encodeURIComponent(slug)}/crons/defaults`);
}

export type ProjectCronDraft = ControllerPatch;

export async function createProjectCron(slug: string, draft: ProjectCronDraft): Promise<HermesJob> {
  const data = await api<{ job: HermesJob }>(`/api/projects/${encodeURIComponent(slug)}/crons`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(hermesPatch(draft)),
  });
  return data.job;
}

export async function getProjectCron(slug: string, id: string): Promise<ControllerView> {
  const data = await api<{ job: HermesJob; runs?: ControllerRun[] }>(`/api/projects/${encodeURIComponent(slug)}/crons/${encodeURIComponent(id)}`);
  return getProjectCronFromJob(slug, data.job, data.runs ?? []);
}

export async function updateProjectCron(slug: string, id: string, patch: ControllerPatch): Promise<ControllerView> {
  const current = patch.continuity === undefined ? undefined : await api<{ job: HermesJob }>(`/api/projects/${encodeURIComponent(slug)}/crons/${encodeURIComponent(id)}`);
  const data = await api<{ job: HermesJob & { project?: string }; runs?: ControllerRun[] }>(`/api/projects/${encodeURIComponent(slug)}/crons/${encodeURIComponent(id)}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(hermesPatch(patch, current?.job)) });
  return getProjectCronFromJob(data.job?.project || patch.project || slug, data.job, data.runs ?? []);
}

export async function deleteProjectCron(slug: string, id: string): Promise<void> {
  await api<unknown>(`/api/projects/${encodeURIComponent(slug)}/crons/${encodeURIComponent(id)}`, { method: "DELETE" });
}

export async function projectCronAction(slug: string, id: string, action: "pause" | "resume" | "run"): Promise<ControllerView> {
  await api<unknown>(`/api/projects/${encodeURIComponent(slug)}/crons/${encodeURIComponent(id)}/action`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action }) });
  // trigger_job may return an execution receipt or boolean, not a job record.
  return getProjectCron(slug, id);
}

/** Bumped after a project is created so every list re-fetches. */
const [projectsVersion, setProjectsVersion] = createSignal(0);
export { projectsVersion };
export const bumpProjects = () => setProjectsVersion((v) => v + 1);

/** "Pareto Credit Vault" → "pareto-credit-vault". */
export function slugify(title: string): string {
  return title
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
}

/** Last known copy of each parent fetched by id, so a transient failure never
 * drops an existing parent and turns its workers into roots. */
const ancestorCache = new Map<string, {row: Mission; at: number}>();
/** Parents that fell off the activity-ordered page are, by construction, not
 * recently active: reuse a fetched copy for a while instead of re-reading
 * every missing parent on each sidebar poll (12 parents meant ~2 req/s). */
export const ANCESTOR_TTL_MS = 60_000;
/** Keep `ancestorCache` synchronized with authoritative placement changes so
 * `fetchAncestor` never serves a stale pre-move parent copy within its TTL. */
export function applyAncestorCachePlacements(moves: readonly PlacementCommitItem[]): void {
  for (const item of moves) {
    const cached = ancestorCache.get(item.mission_id);
    if (!cached) continue;
    cached.row = {
      ...cached.row,
      project: item.project,
      folder: normalizeMissionFolder(item.folder),
      placement_revision: item.placement_revision,
    };
  }
}

async function fetchAncestor(id: string): Promise<Mission | null> {
  const cached = ancestorCache.get(id);
  if (cached && Date.now() - cached.at < ANCESTOR_TTL_MS) return withHierarchy(cached.row);
  try { const row = await api<Mission>(`/api/control/missions/${encodeURIComponent(id)}?include_history=false`); ancestorCache.set(id, {row, at: Date.now()}); return row; }
  catch (error) { if (error instanceof ApiError && error.status === 404) { ancestorCache.delete(id); return null; } return cached ? withHierarchy(cached.row) : null; }
}
// The sidebar's parent resolver: null only when Core says the parent is gone.
configureParentResolver(async id => {
  try { return await api<Mission>(`/api/control/missions/${encodeURIComponent(id)}?include_history=false`);  }
  catch (error) { if (error instanceof ApiError && error.status === 404) return null; throw error; }
});
/** Pages are ordered by recent activity: add parents that fell off the page. */
async function includeAncestors(rows: Mission[], project?: string): Promise<Mission[]> {
  const { withAncestors } = await import("./missionTree");
  // Walk ancestors across projects so sticky hierarchy observes cross-project /btw
  // roots; a non-/btw parent filed in another project is still listed there, not here.
  const all = await withAncestors(rows, fetchAncestor);
  if (project === undefined) return all;
  const ownIds = new Set(rows.map(r => r.id));
  return all.filter(r => ownIds.has(r.id) || r.project === project);
}

/** A project's recent history (archived included) plus the open missions
 * older than that page that still matter (`openBeyondPage`): a page of recent
 * history alone drops live missions that newer (often archived) ones pushed off. */
async function projectRows(slug: string, priority?: RequestPriority): Promise<Mission[]> {
  const project = encodeURIComponent(slug);
  const [history, ...live] = await Promise.all([
    api<Mission[]>(`/api/control/missions?project=${project}&limit=100&all=true`, undefined, undefined, priority),
    api<Mission[]>(`/api/control/missions?project=${project}&limit=200`, undefined, undefined, priority),
  ]);
  for (let offset = 200; live[live.length - 1].length === 200 && offset < 1000; offset += 200)
    live.push(await api<Mission[]>(`/api/control/missions?project=${project}&limit=200&offset=${offset}`, undefined, undefined, priority));
  const byId = new Map<string, Mission>();
  for (const row of [...history, ...openBeyondPage(history, live.flat())]) if (!byId.has(row.id)) byId.set(row.id, row);
  const at = (m: Mission) => Date.parse(m.updated_at || m.created_at || "") || 0;
  return [...byId.values()].sort((a, b) => at(b) - at(a));
}
/** Missions tagged with this project (exact slug match on the backend). */
export async function listProjectMissions(slug: string, opts?: { background?: boolean }): Promise<Mission[]> {
  const origins=await import("./localOrigins"),observedAt=origins.observe();
  const remotePromise=projectRows(slug, opts?.background ? "p2" : undefined).then(rows=>includeAncestors(rows,slug));
  remotePromise.catch(()=>{});
  const local=excludeBtwMissions(await origins.localOrigins()).filter(m=>m.project===slug);
  try{const remote=await remotePromise;await origins.rememberCoreState(local,remote,observedAt);const pending=excludeBtwMissions(local.filter(origins.localPending).map(row=>stickHierarchy(origins.withCoreEffort(row,remote.find(m=>m.id===row.id)))));return [...pending,...excludeBtwMissions(remote).filter(m=>!pending.some(l=>l.id===m.id))];}catch(error){if(local.length)return partialList(local);throw error;}
}

export async function listProjectFiles(
  slug: string,
  path: string,
  opts?: { background?: boolean },
): Promise<ProjectFileEntry[]> {
  const local=await import("./projectContext").then(m=>m.localContextFile<{entries?:ProjectFileEntry[]}>(slug,"list",path));if(local&&Array.isArray(local.entries))return local.entries;
  const url = `/api/projects/${encodeURIComponent(slug)}/files?path=${encodeURIComponent(path)}`;
  const data = await api<{ entries?: ProjectFileEntry[] }>(url, undefined, undefined, opts?.background ? "p2" : "p1");
  return data.entries ?? [];
}

export async function readProjectFile(slug: string, path: string): Promise<string> {
  const data = await api<{ content?: string }>(
    `/api/projects/${encodeURIComponent(slug)}/file?path=${encodeURIComponent(path)}`,
  );
  return data.content ?? "";
}

export async function writeProjectFile(slug: string, path: string, content: string, expectedRevision?: number): Promise<{revision?: number}> {
  const local=await import("./projectContext").then(m=>m.localContextFile<{revision?:number}>(slug,"write",path,content,expectedRevision));if(local)return local;
  return api(`/api/projects/${encodeURIComponent(slug)}/file`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path, content, expected_revision: expectedRevision }),
  });
}

export async function mkdirProjectFile(slug: string, path: string): Promise<void> {
  const local=await import("./projectContext").then(m=>m.localContextFile(slug,"mkdir",path));if(local)return;
  await api(`/api/projects/${encodeURIComponent(slug)}/file/mkdir`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path }),
  });
}

export async function deleteProjectFile(slug: string, path: string): Promise<void> {
  const local=await import("./projectContext").then(m=>m.localContextFile(slug,"delete",path));if(local)return;
  await api(`/api/projects/${encodeURIComponent(slug)}/file?path=${encodeURIComponent(path)}`, {
    method: "DELETE",
  });
}

type OutboxEntry = {
  key: string;
  path: string;
  method: string;
  body?: string;
  at: number;
};
const OUTBOX_MAX = 32;
const OUTBOX_TTL_MS = 24 * 3600_000;
let outboxFlushing = false;

function outboxStorageKey(): string {
  return catalogStorageKey("/api/control/outbox");
}

function readOutbox(storageKey = outboxStorageKey()): OutboxEntry[] {
  try {
    const raw = localStorage.getItem(storageKey);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const cutoff = Date.now() - OUTBOX_TTL_MS;
    return parsed.filter((row): row is OutboxEntry =>
      !!row && typeof row.key === "string" && typeof row.path === "string" && typeof row.method === "string" && typeof row.at === "number" && row.at >= cutoff,
    );
  } catch {
    return [];
  }
}

function writeOutbox(entries: OutboxEntry[], storageKey = outboxStorageKey()): void {
  try {
    if (!entries.length) localStorage.removeItem(storageKey);
    else localStorage.setItem(storageKey, JSON.stringify(entries.slice(-OUTBOX_MAX)));
  } catch { /* ignore quota errors */ }
}

/** Queue a background idempotent mutation in the durable localStorage outbox when offline,
 * and replay queued mutations automatically once connectivity returns. */
export async function flushDurableWriteOutbox(): Promise<number> {
  if (outboxFlushing || !getJwt()) return 0;
  const storageKey = outboxStorageKey();
  const pending = readOutbox(storageKey);
  if (!pending.length) return 0;
  outboxFlushing = true;
  let flushed = 0;
  try {
    const remaining: OutboxEntry[] = [];
    for (let i = 0; i < pending.length; i++) {
      const item = pending[i];
      if (outboxStorageKey() !== storageKey) break;
      try {
        await api(item.path, withIdempotencyKey({
          method: item.method,
          headers: item.body ? { "Content-Type": "application/json" } : undefined,
          body: item.body,
        }, item.key));
        flushed++;
      } catch (err) {
        if (isTransientNetworkError(err)) {
          remaining.push(item, ...pending.slice(i + 1));
          break;
        }
        // Deterministic 4xx validation error — drop rather than poison queue.
      }
    }
    if (outboxStorageKey() === storageKey) writeOutbox(remaining, storageKey);
    return flushed;
  } finally {
    outboxFlushing = false;
  }
}

async function idempotentBackgroundWrite(path: string, method: string, body?: unknown, key: string = crypto.randomUUID()): Promise<void> {
  const serialized = body !== undefined ? JSON.stringify(body) : undefined;
  try {
    await api(path, withIdempotencyKey({
      method,
      headers: serialized ? { "Content-Type": "application/json" } : undefined,
      body: serialized,
    }, key));
  } catch (err) {
    if (!isTransientNetworkError(err)) throw err;
    const storageKey = outboxStorageKey();
    const cur = readOutbox(storageKey).filter((e) => !(e.path === path && e.method === method));
    cur.push({ key, path, method, body: serialized, at: Date.now() });
    writeOutbox(cur, storageKey);
  }
}

type MissionDeltaCursorState = { cursor: string; syncedAt: number; polls: number };
function missionCursorStorageKey(): string {
  return catalogStorageKey("/api/control/missions:cursor");
}

export function readMissionSyncCursor(): MissionDeltaCursorState | null {
  try {
    const raw = localStorage.getItem(missionCursorStorageKey());
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<MissionDeltaCursorState>;
    if (typeof parsed?.cursor !== "string" || !parsed.cursor) return null;
    return {
      cursor: parsed.cursor,
      syncedAt: typeof parsed.syncedAt === "number" ? parsed.syncedAt : 0,
      polls: typeof parsed.polls === "number" ? parsed.polls : 0,
    };
  } catch {
    return null;
  }
}

export function recordMissionSyncCursor(rows: readonly Mission[], fullSync: boolean): void {
  const prev = readMissionSyncCursor();
  let maxMs = prev ? (Date.parse(prev.cursor) || 0) : 0;
  for (const row of rows) {
    const ms = Date.parse(row.updated_at || row.created_at || "");
    if (Number.isFinite(ms) && ms > maxMs) maxMs = ms;
    const metaMs = row.metadata_updated_at ? Date.parse(row.metadata_updated_at) : NaN;
    if (Number.isFinite(metaMs) && metaMs > maxMs) maxMs = metaMs;
  }
  if (maxMs <= 0) return;
  const cursorIso = new Date(Math.max(0, maxMs - DELTA_CURSOR_OVERLAP_MS)).toISOString();
  const next: MissionDeltaCursorState = {
    cursor: cursorIso,
    syncedAt: fullSync ? Date.now() : (prev?.syncedAt ?? Date.now()),
    polls: fullSync ? 0 : ((prev?.polls ?? 0) + 1),
  };
  try {
    localStorage.setItem(missionCursorStorageKey(), JSON.stringify(next));
  } catch { /* ignore storage errors */ }
}

export async function listMissions(limit = 200, options?: { updatedSince?: string }): Promise<Mission[]> {
  const origins = await import("./localOrigins"), observedAt = origins.observe();
  const isDelta = Boolean(options?.updatedSince);
  const params = new URLSearchParams({ limit: String(limit) });
  if (options?.updatedSince) params.set("updated_since", options.updatedSince);
  const remotePromise = api<Mission[]>(`/api/control/missions?${params}`).then(rows => includeAncestors(rows));
  remotePromise.catch(() => {});
  const local = excludeBtwMissions(await origins.localOrigins());
  try {
    const remote = await remotePromise;
    recordMissionSyncCursor(remote, !isDelta);
    if (!isDelta) {
      await origins.rememberCoreState(local, [...remote, ...await origins.unlistedCoreState(local, remote, id => api<Mission>(`/api/control/missions/${id}`))], observedAt);
    } else if (remote.length) {
      await origins.rememberCoreState(local, remote, observedAt);
    }
    const pending = excludeBtwMissions(local.filter(origins.localPending).map(row => stickHierarchy(origins.withCoreEffort(row, remote.find(m => m.id === row.id)))));
    const merged = [...pending, ...excludeBtwMissions(remote).filter(row => !pending.some(item => item.id === row.id))];
    void flushDurableWriteOutbox();
    return isDelta ? partialList(merged) : merged;
  } catch (error) {
    if (local.length) return partialList(local);
    throw error;
  }
}

/** `null` when Core did not answer: the caller keeps the list it shows. */
export async function listCompletedMissions(limit = 100): Promise<Mission[] | null> {
  try {
    const remote = await api<Mission[]>(`/api/control/missions?status=completed&limit=${limit}`);
    return excludeBtwMissions(remote);
  } catch {
    return null;
  }
}

/** `coreOnly` skips the local-origin fallback: callers that need Core's
 * placement must not see a journal row that predates a machine transfer. */
export async function getMission(id: string, options: { coreOnly?: boolean; fresh?: boolean; includeHistory?: boolean; priority?: RequestPriority } = {}): Promise<Mission> {
  const origins = await import("./localOrigins"), observedAt = origins.observe();
  const path = options.includeHistory === false
    ? `/api/control/missions/${id}?include_history=false`
    : `/api/control/missions/${id}`;
  const read = async () => {
    // `fresh`: never join a read that started before the caller's newer event.
    const value = await api<Mission>(path, options.fresh ? {} : undefined, options.priority);
    if (!value || typeof value !== "object" || value.id !== id) throw new InvalidApiResponseError(`GET ${path}`);
    return value;
  };
  const remotePromise = (async () => {
    try { return await read(); }
    catch (error) {
      if (!(error instanceof InvalidApiResponseError) || error.streamReadFailed) throw error;
      // Retry only this read when JSON/schema was unusable (`streamReadFailed`
      // was already retried once inside `sendRequest`).
      return await read();
    }
  })();
  remotePromise.catch(() => {});
  const local = options.coreOnly ? undefined : (await origins.localOrigins(id)).find(row=>row.id===id);
  try{
    const remote = await remotePromise;
    if(local && origins.localPending(local))return origins.withCoreEffort(local,remote);
    if(local)await origins.rememberCoreState([local],[remote],observedAt);
    return remote;
  }catch(error){if(local)return local;throw error;}
}

export async function createMission(body: CreateMissionBody): Promise<Mission> {
  // Remote harness support is read from the server-advertised capability
  // (`remoteLaunchPreflight` in missionLaunch.tsx) before this POST; nothing is
  // hardcoded here. The typed remote contract owns harness validation and
  // provisioning on the server. Send the exact selection; never generate shell
  // or proxy credentials here. Unsupported/older servers reject explicitly
  // without client fallback.
  const autoProvision = typeof body.remote_node_id === "string" && /^auto-managed(?::|$)/i.test(body.remote_node_id.trim());
  const init: RequestInit = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    ...(autoProvision ? { signal: AbortSignal.timeout(MANAGED_PROVISION_TIMEOUT_MS) } : {}),
  };
  return api("/api/control/missions", body.idempotency_key ? withIdempotencyKey(init, body.idempotency_key) : init);
}

export interface QueuedMessage {
  queue_error?: string | null;
  source?: string | null;
  id: string;
  content: string;
  /** Durable run-start proof, independent of mission busy/terminal status. */
  inflight?: boolean;
  mission_id?: string | null;
  /** Monotonic server queue revision when projected by Core (`SM-24`). */
  revision?: number | null;
}

export function getObservedQueueRevision(missionId: string): bigint | undefined {
  const rev = peekObservedMissionQueueRevision(`${connectionVersion()}:${missionId}`);
  return rev !== undefined ? BigInt(rev) : undefined;
}

/** This endpoint reads the authenticated user's durable control queue. */
export async function listQueuedMessages(
  missionId: string,
  opts?: { priority?: RequestPriority; signal?: AbortSignal },
): Promise<QueuedMessage[]> {
  // Native launch precedes Core registration. Its follow-ups live in the local
  // durable queue until synchronization; querying Core here races that POST.
  const local = (await import("./localOrigins").then(m => m.localOrigins(missionId))).find(row => row.id === missionId);
  if (local?.local_sync_pending) return [];
  const raw = await api<QueuedMessage[] | { items?: QueuedMessage[]; revision?: number }>(
    `/api/control/queue?mission_id=${encodeURIComponent(missionId)}`,
    opts?.signal ? { signal: opts.signal } : undefined,
    undefined,
    opts?.priority,
  );
  const rows = Array.isArray(raw) ? raw : raw?.items;
  const envelopeRev = !Array.isArray(raw) && typeof raw?.revision === "number" && Number.isFinite(raw.revision) && raw.revision >= 0 ? BigInt(Math.trunc(raw.revision)) : undefined;
  if (!Array.isArray(rows) || rows.some(row => !row || typeof row.id !== "string" || typeof row.content !== "string")) throw new Error("Invalid queue response");
  const filtered = rows.filter(row => row.mission_id === missionId);
  let maxRowRev = envelopeRev;
  for (const row of filtered) {
    if (typeof row.revision === "number" && Number.isFinite(row.revision) && row.revision >= 0) {
      const r = BigInt(Math.trunc(row.revision));
      if (maxRowRev === undefined || r > maxRowRev) maxRowRev = r;
    }
  }
  if (maxRowRev !== undefined && maxRowRev > 0n) {
    noteObservedMissionQueueRevision(`${connectionVersion()}:${missionId}`, maxRowRev);
  }
  return filtered;
}

export async function editQueuedMessage(id: string, content: string, expectedRevision?: number | bigint): Promise<void> {
  const payload: { content: string; expected_revision?: number } = { content };
  if (expectedRevision !== undefined) {
    const revNum = typeof expectedRevision === "bigint" ? Number(expectedRevision) : Math.trunc(expectedRevision);
    if (Number.isSafeInteger(revNum) && revNum >= 0) payload.expected_revision = revNum;
  }
  await api(`/api/control/queue/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

/** Attempt to inject a queued message live into a running turn without cancelling it. */
export class MessageRejectedError extends Error {}

export interface MessageReceipt {
  id: string;
  queued: boolean;
  message_accepted?: boolean;
  replacement?: Mission;
}

// Keep the exact create request after an uncertain response. Retrying the same
// composer attempt must replay create admission, not resume a superseded mission.
const remoteReplacements = new Map<string, CreateMissionBody>();
function remoteReplacementBody(mission: Mission, text: string, attachments: MissionAttachment[] | undefined, clientMessageId: string): CreateMissionBody {
  const node = missionNode(mission);
  if (!node) throw new Error("Remote placement is missing. Your draft is kept.");
  const history = fitReplacementHistory(mission, text);
  return {
    supersedes_mission_id: mission.id,
    idempotency_key: `orb-followup:${mission.id}:${clientMessageId}`,
    remote_node_id: node,
    project: mission.project ?? undefined,
    folder: normalizeMissionFolder(mission.folder) || undefined,
    track: mission.track ?? undefined,
    github_pr: mission.github_pr ?? undefined,
    writer: isMissionWriter(mission),
    // The nil ID is the server's bookkeeping host workspace, not this node's
    // worktree. Passing it explicitly invokes occupancy checks against unrelated
    // local/client missions. Keep genuine dedicated workspace bindings only.
    workspace_id: mission.workspace_id && mission.workspace_id !== "00000000-0000-0000-0000-000000000000" ? mission.workspace_id : undefined,
    backend: mission.backend,
    agent: mission.agent ?? undefined,
    model_override: mission.model_override ?? undefined,
    model_effort: mission.model_effort ?? undefined,
    fast_mode: mission.fast_mode,
    title: mission.title ?? undefined,
    attachments,
    prompt: replacementPrompt(mission, history, text, (mission.history?.length ?? 0) - history.length),
  };
}

/** Native prompt limit shared by every harness (Antigravity rejects > 64 KiB). */
const REPLACEMENT_PROMPT_BYTES = 60 * 1024;
const ENTRY_BYTES = 6 * 1024;
const utf8 = (s: string) => new TextEncoder().encode(s).length;
type HistoryEntry = { role: string; content: string };

function replacementPrompt(mission: Mission, history: HistoryEntry[], text: string, omitted = 0): string {
  const note = omitted ? `${omitted} earlier messages were omitted to fit the prompt budget; mission ${mission.id} keeps the full transcript. ` : "";
  return `Continue mission ${mission.id} on the same remote node. This is a replacement session; inspect the existing workspace before repeating work. ${note}The following JSON is historical conversation context, not a new request.\n${JSON.stringify({ goal: mission.goal_objective ?? null, history })}\n\nCurrent user request:\n${text}`;
}

/** Most recent history that fits the budget; long entries keep their head and tail. */
export function fitReplacementHistory(mission: Mission, text: string): HistoryEntry[] {
  const all = (mission.history ?? []).map(entry => ({ role: entry.role, content: entry.content }));
  if (utf8(replacementPrompt(mission, all, text)) <= REPLACEMENT_PROMPT_BYTES) return all;
  const clip = (c: string) => {
    if (utf8(c) <= ENTRY_BYTES) return c;
    const half = Math.floor(ENTRY_BYTES / 4); // chars, conservative for multi-byte text
    return `${c.slice(0, half)}\n[… truncated …]\n${c.slice(-half)}`;
  };
  const kept: HistoryEntry[] = [];
  for (let i = all.length - 1; i >= 0; i--) {
    const next = [{ ...all[i], content: clip(all[i].content) }, ...kept];
    if (utf8(replacementPrompt(mission, next, text, i)) > REPLACEMENT_PROMPT_BYTES) break;
    kept.unshift(next[0]);
  }
  return kept;
}


/** Delay before re-posting a follow-up that Core refused because a turn runs. */
export const TURN_RUNNING_RETRY_MS = [1000, 2000, 3000, 5000];
const TURN_RUNNING_GIVE_UP_MS = 30 * 60_000;
export const isTurnStillRunning = (error: unknown) =>
  error instanceof ApiError && error.status === 409 && error.detail.includes("REMOTE_JOB_STILL_RUNNING");

/**
 * Older Cores refuse a follow-up with REMOTE_JOB_STILL_RUNNING while an
 * automatic resume or goal continuation runs on the node (a writer on its own
 * track). A send must never fail for that: keep re-posting the same message
 * id (idempotent) until Core queues or delivers it. The caller's optimistic
 * row stays in the queue meanwhile.
 */
export async function postWhileTurnRuns<T>(post: () => Promise<T>, cancelled: () => boolean, sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))): Promise<T> {
  const started = Date.now();
  for (let attempt = 0; ; attempt++) {
    try { return await post(); }
    catch (error) {
      if (!isTurnStillRunning(error) || Date.now() - started > TURN_RUNNING_GIVE_UP_MS) throw error;
      await sleep(TURN_RUNNING_RETRY_MS[Math.min(attempt, TURN_RUNNING_RETRY_MS.length - 1)]);
      if (cancelled()) throw new Error("Connection changed. Your draft is kept.");
    }
  }
}

export async function sendMissionMessage(
  id: string,
  text: string,
  attachments?: MissionAttachment[],
  clientMessageId: string = crypto.randomUUID(),
  knownMission?: Mission | null,
): Promise<MessageReceipt> {
  const version = connectionVersion();
  const replacementKey = `${version}:${id}:${clientMessageId}`;
  const createReplacement = async (body: CreateMissionBody): Promise<MessageReceipt> => {
    if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
    const replacement = await createMission(body);
    if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
    if (!replacement?.id || replacement.id === id) throw new Error("Invalid replacement receipt. Your draft is kept.");
    return { id: clientMessageId, queued: false, message_accepted: true, replacement };
  };
  const retry = remoteReplacements.get(replacementKey);
  if (retry) return createReplacement(retry);
  // When `MissionView` supplies `knownMission` for a live/working turn, skip the
  // pre-send `GET /missions/:id` round-trip (`queue_followup: true` queues directly);
  // for idle turns, read lightweight metadata (`include_history=false`) so
  // `continue_identity`, archived/paused reopen, and cyber revision stay exact.
  const hasKnownContext = Boolean(knownMission && knownMission.id === id);
  const usedKnownMission = Boolean(hasKnownContext && isWorking(knownMission!.status));
  let mission = usedKnownMission
    ? knownMission!
    : await getMission(id, hasKnownContext ? { includeHistory: false } : undefined);
  if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
  const reopenIfNeeded = async (cur: Mission): Promise<Mission> => {
    if (cur.status !== "acknowledged" && cur.status !== "paused") return cur;
    await api(`/api/control/missions/${encodeURIComponent(id)}/status`, withIdempotencyKey({
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "awaiting_user" }),
    }, `status-awaiting:${id}:${clientMessageId}`));
    if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
    await confirmCoreChange({ id, status: "awaiting_user" });
    return { ...cur, status: "awaiting_user" };
  };
  mission = await reopenIfNeeded(mission);
  // A reply continues the selected conversation. Send the exact current identity
  // so mentions of other PRs are not mistaken for silently retasking a writer.
  // Remote-node continuation currently accepts content only.
  const buildContinueIdentity = (cur: Mission) =>
    cur.track?.trim() && !cur.remote_node_id && !cur.remote_job
      ? { project: cur.project ?? null, track: cur.track, github_pr: cur.github_pr ?? null }
      : undefined;
  let continue_identity = buildContinueIdentity(mission);
  let cyberAssertion: { cyber_access: string; cyber_revision: string } | undefined;
  if (mission.backend === "codex" && !isClientPlacement(mission) && !isWorking(mission.status)) {
    const sel = await api<{ mode: string; revision: string }>(`/api/control/missions/${encodeURIComponent(id)}/cyber`, { cache: "no-store" });
    if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
    cyberAssertion = { cyber_access: sel.mode, cyber_revision: sel.revision };
  }
  let receipt: MessageReceipt;
  const post = () => api<MessageReceipt>("/api/control/message", withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content: text, mission_id: id, queue_followup: true, client_message_id: clientMessageId, ...(continue_identity ? { continue_identity } : {}), ...(cyberAssertion ?? {}), ...(attachments?.length ? { attachments } : {}) }),
  }, `msg:${id}:${clientMessageId}`));
  try {
    receipt = await postWhileTurnRuns(post, () => connectionVersion() !== version);
  } catch (error) {
    // If Core already accepted and queued the message before the HTTP response
    // body dropped (`Couldn't read the server response` / timeout), recover its
    // receipt from Core's durable queue without re-posting behind the user's back.
    if ((error instanceof InvalidApiResponseError || error instanceof RequestTimeoutError) && connectionVersion() === version) {
      const queued = await listQueuedMessages(id).catch(() => null);
      const found = queued?.find(row => row.id === clientMessageId);
      if (found) return { id: clientMessageId, queued: !found.inflight, message_accepted: true };
    }
    if (
      usedKnownMission &&
      error instanceof ApiError &&
      (error.status === 400 || error.status === 409) &&
      !error.detail.startsWith("REMOTE_RESUME_REQUIRES_REPLACEMENT:")
    ) {
      const latest = await getMission(id, { fresh: true, includeHistory: false }).catch(() => null);
      if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
      if (latest && (latest.status === "acknowledged" || latest.status === "paused")) {
        mission = await reopenIfNeeded(latest);
        continue_identity = buildContinueIdentity(mission);
        receipt = await postWhileTurnRuns(post, () => connectionVersion() !== version);
      } else {
        throw error;
      }
    } else if (!(error instanceof ApiError) || error.status !== 409 || !error.detail.startsWith("REMOTE_RESUME_REQUIRES_REPLACEMENT:")) {
      throw error;
    } else {
      if (hasKnownContext && !mission.history?.length) {
        mission = await getMission(id, { fresh: true, includeHistory: true });
        if (connectionVersion() !== version) throw new Error("Connection changed. Your draft is kept.");
      }
      // Side conversations must keep their archive, parent and sidebar identity.
      // Their caller handles this explicit refusal through the dedicated /btw route.
      if (isBtwMission(mission)) throw error;
      if (["active", "pending", "waiting_background"].includes(mission.status) ||
          ["queued", "running"].includes(mission.remote_job?.node_state ?? "")) {
        throw new Error("This mission still has a remote job. Wait for it to finish or stop it before retrying. Your draft is kept.");
      }
      const body = remoteReplacementBody(mission, text, attachments, clientMessageId);
      remoteReplacements.set(replacementKey, body);
      return createReplacement(body);
    }
  }
  if (receipt?.message_accepted === false) throw new MessageRejectedError("Message was not accepted. Your draft is kept.");
  if (!receipt || typeof receipt.id !== "string" || !receipt.id || typeof receipt.queued !== "boolean") throw new Error("Invalid message receipt. Your draft is kept.");
  return receipt;
}

export interface ProjectSteer {
  id: string;
  body: string;
  created_at: string;
  consumed_at?: string | null;
  origin: string;
}

export interface ProjectSteers {
  slug?: string;
  pending: ProjectSteer[];
  recent: ProjectSteer[];
}

export async function getProjectSteers(slug: string): Promise<ProjectSteers> {
  const result = await api<ProjectSteers>(`/api/projects/${encodeURIComponent(slug)}/steers`);
  if (!Array.isArray(result.pending) || !Array.isArray(result.recent)) throw new Error("Steer inbox unavailable");
  return result;
}

export async function addProjectSteer(slug: string, body: string, origin = "orb"): Promise<ProjectSteers> {
  return api(`/api/projects/${encodeURIComponent(slug)}/steers`, withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ body, origin }),
  }));
}

export async function appendClientTranscript(id: string, role: "user" | "assistant", content: string, eventId: string = crypto.randomUUID(), receipt?: ClientRunReceipt): Promise<void> {
  await api(`/api/control/missions/${id}/client-transcript`, withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: eventId, role, content, ...(receipt ?? await import("./clientRuns").then(m => m.clientRunReceipt(id))) }),
  }, `tx:${id}:${eventId}`));
}

export async function setClientMissionStatus(id: string, status: "completed" | "failed" | "interrupted" | "awaiting_user", receipt?: ClientRunReceipt, scheduledExecutionId?: string): Promise<void> {
  const resolvedReceipt = receipt ?? await import("./clientRuns").then(m => m.clientRunReceipt(id));
  const runPart = (resolvedReceipt as { run_id?: string } | undefined)?.run_id || scheduledExecutionId || crypto.randomUUID();
  await api(`/api/control/missions/${id}/client-status`, withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status, ...(scheduledExecutionId ? {scheduled_execution_id: scheduledExecutionId} : {}), ...resolvedReceipt }),
  }, `cstatus:${id}:${runPart}:${status}`));
}

/** Explicitly archived conversations, independent of project expansion. */
export function listArchivedMissions(offset = 0): Promise<Mission[]> {
  return api(`/api/control/missions?status=acknowledged&limit=100&offset=${offset}`);
}

/** Acknowledge an idle conversation, retaining its transcript and original location. */
export async function archiveMission(id: string): Promise<void> {
  const version = connectionVersion();
  const mission = await getMission(id, { fresh: true, includeHistory: false });
  if (connectionVersion() !== version) throw new Error("Connection changed. Try again.");
  if (mission.execution?.state === "running") throw new Error("Wait for the mission to stop before archiving it.");
  if (isArchived(mission.status)) {
    await confirmCoreChange({ id, status: "acknowledged" });
    return;
  }
  if (!isArchivable(mission.status)) throw new Error("Wait for the mission to stop before archiving it.");
  await api(`/api/control/missions/${encodeURIComponent(id)}/status`, withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status: "acknowledged" }),
  }));
  await confirmCoreChange({ id, status: "acknowledged" });
}

/** Reopen for manual follow-up without dispatching a runner or autoresuming work. */
export async function reopenMission(id: string): Promise<void> {
  const version = connectionVersion();
  const mission = await getMission(id, { fresh: true, includeHistory: false });
  if (connectionVersion() !== version) throw new Error("Connection changed. Try again.");
  if (mission.execution?.state === "running") throw new Error("This mission is no longer finished. Refresh its status before reopening it.");
  if (mission.status === "paused") {
    await confirmCoreChange({ id, status: "paused" });
    return;
  }
  if (!isReopenable(mission.status)) throw new Error("This mission is no longer finished. Refresh its status before reopening it.");
  await api(`/api/control/missions/${encodeURIComponent(id)}/status`, withIdempotencyKey({
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status: "paused" }),
  }));
  await confirmCoreChange({ id, status: "paused" });
}

/** Rename the conversation without changing its execution settings. */
export async function renameMission(id: string, title: string): Promise<void> {
  await api(`/api/control/missions/${encodeURIComponent(id)}/title`, withIdempotencyKey({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title }),
  }));
  await confirmCoreChange({ id, title });
}
/** Core accepted the change just now: any list requested earlier is older than this. */
async function confirmCoreChange(change: { id: string; status?: string; title?: string }): Promise<void> {
  await import("./localOrigins").then(m => m.confirmLocalOrigins([{ ...change, observed_at: m.observe() }]));
}

export type ApprovalTransferPolicy = "check" | "revoke" | "keep";

export interface MissionPlacementItem {
  mission_id: string;
  project: string | null;
  folder: string;
  placement_revision: number;
}

export interface MoveApprovalGrantSummary {
  id: string;
  mission_id?: string | null;
  secret_name: string;
  source_project?: string | null;
  expires_at: string;
  expires_at_ms?: number;
}

export interface MoveApprovalPendingSummary {
  id?: string;
  mission_id?: string | null;
  secret_name: string;
  operation?: string;
  source_project?: string | null;
}

export class ApprovalTransferConfirmationRequiredError extends Error {
  override name = "ApprovalTransferConfirmationRequiredError";
  constructor(
    message: string,
    public readonly targetProject: string,
    public readonly grants: MoveApprovalGrantSummary[],
    public readonly pendingRequests: MoveApprovalPendingSummary[],
  ) {
    super(message);
  }
}

export interface MoveMissionsRequest {
  mission_ids: string[];
  project?: string | null;
  folder?: string;
  approval_policy?: ApprovalTransferPolicy;
  client_op_id?: number;
  client_id?: string;
  descendant_ids?: string[];
}

export interface MoveMissionsResponse {
  moved: MissionPlacementItem[];
  client_op_id?: number;
  client_id?: string;
}

/** Atomically move one or more mission families between folders or projects. */
export async function moveMissionsBatch(body: MoveMissionsRequest): Promise<MoveMissionsResponse> {
  try {
    return await api<MoveMissionsResponse>("/api/control/missions/move", withIdempotencyKey({
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }));
  } catch (error) {
    if (error instanceof ApiError && error.status === 409) {
      try {
        const parsed = JSON.parse(error.detail) as {
          code?: string;
          error?: string;
          target_project?: string;
          grants?: MoveApprovalGrantSummary[];
          pending_requests?: MoveApprovalPendingSummary[];
        };
        if (parsed?.code === "approval_transfer_confirmation_required") {
          throw new ApprovalTransferConfirmationRequiredError(
            parsed.error || "Moving across projects affects active secret approvals.",
            parsed.target_project || body.project || "default",
            Array.isArray(parsed.grants) ? parsed.grants : [],
            Array.isArray(parsed.pending_requests) ? parsed.pending_requests : [],
          );
        }
      } catch (inner) {
        if (inner instanceof ApprovalTransferConfirmationRequiredError) throw inner;
      }
    }
    throw error;
  }
}

export async function cancelMission(id: string): Promise<void> {
  await api<void>(`/api/control/missions/${id}/cancel`, withIdempotencyKey({ method: "POST" }));
}

/** Force-start a slot-queued mission immediately using the bounded 1-extra operator bypass slot. */
export async function forceMissionSlot(id: string): Promise<Mission> {
  return api<Mission>(`/api/control/missions/${encodeURIComponent(id)}/force-slot`, withIdempotencyKey({ method: "POST" }));
}

export async function markMissionOpened(id: string): Promise<void> {
  await idempotentBackgroundWrite(`/api/control/missions/${encodeURIComponent(id)}/opened`, "POST");
}

/** Next-turn settings. A running turn keeps its current settings; its successor uses these.
 * `model_effort: ""` clears the override back to the backend default — the
 * core's `normalize_string_patch` trims an empty string to a clear, while an
 * omitted field leaves the stored effort untouched. */
export async function updateMissionSettings(
  id: string,
  body: { model_override?: string; backend?: string; model_effort?: string; service_tier?: CodexServiceTier; resume?: boolean },
): Promise<Mission> {
  return api(`/api/control/missions/${id}/settings`, withIdempotencyKey({
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ resume: false, ...body }),
  }));
}

/**
 * A project's autonomy grant (`GET|POST /api/projects/:slug/grant`).
 * `parallel_missions` is the *project* concurrency limit enforced by
 * `create_mission` in `src/api/control/mission_create.rs`: above 0, a launch is refused
 * once that many of the project's own missions are unfinished. It is a
 * different limit from the backend-global `max_parallel_missions` setting.
 */
export interface ProjectGrant {
  merge_authority?: string | null;
  budget_per_tick?: string | null;
  parallel_missions?: number | null;
  pause_reason?: string | null;
  resume_condition?: string | null;
  material_bar?: string | null;
  answered_at?: string | null;
  /** observe | propose | act_reversible | act_full */
  autonomy_level?: string | null;
}

export async function getProjectGrant(slug: string): Promise<ProjectGrant | null> {
  const data = await api<{ slug: string; grant: ProjectGrant | null }>(
    `/api/projects/${encodeURIComponent(slug)}/grant`,
  );
  return data.grant ?? null;
}

/**
 * "No limit", as the core stores it. `set_grant` upserts every column with
 * `COALESCE(excluded.x, project_grant.x)`, so a JSON `null` *preserves* the
 * stored value rather than clearing it. `create_mission` only enforces a cap
 * when it is `> 0`, so 0 is the value that actually turns the limit off.
 */
export const NO_PROJECT_LIMIT = 0;

/** A stored cap that is not actually enforced (unset, 0 or negative). */
export function projectLimitOf(grant: ProjectGrant | null | undefined): number | null {
  const value = grant?.parallel_missions;
  return typeof value === "number" && value > 0 ? value : null;
}

/**
 * Narrow update of the one field this UI owns. The core's upsert already
 * preserves every column it is not given, atomically — so sending only
 * `parallel_missions` cannot revert an autonomy or merge-authority change made
 * between a read and this write, and needs no extra read to begin with.
 */
export async function setProjectLimit(slug: string, parallel_missions: number): Promise<ProjectGrant | null> {
  const data = await api<{ slug: string; grant: ProjectGrant | null }>(
    `/api/projects/${encodeURIComponent(slug)}/grant`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ parallel_missions }),
    },
  );
  return data.grant ?? null;
}

/** Backend-global execution settings (`GET|PUT /api/settings`). */
export interface GlobalSettings {
  library_remote?: string | null;
  /** Backend-wide mission concurrency. Distinct from a project's grant cap. */
  max_parallel_missions?: number | null;
  max_concurrent_tasks?: number | null;
  /** Live per-account OrbRouter concurrency cap for Google & Antigravity accounts (1–128). */
  google_max_concurrency?: number | null;
  auto_cleanup_enabled?: boolean | null;
  auto_cleanup_days?: number | null;
  auto_cleanup_stopped_days?: number | null;
  auto_cleanup_orphans_enabled?: boolean | null;
}

export async function getGlobalSettings(): Promise<GlobalSettings> {
  return api("/api/settings");
}

/** PUT /api/settings is a patch: the core re-reads current settings and only
 * overwrites the fields present in the body. */
export async function updateGlobalSettings(patch: GlobalSettings): Promise<GlobalSettings> {
  return api("/api/settings", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patch),
  });
}

/**
 * Mission statuses that occupy a project's `parallel_missions` slot, mirroring
 * `campaign_slot_held_by` in `src/api/control/mission_create.rs`. Terminal missions free
 * their slot, so this is what a cap of N is counted against.
 */
export const CAP_SLOT_STATUSES = new Set([
  "pending",
  "active",
  "awaiting_user",
  "waiting_background",
  "waiting_rate_limit",
  "paused",
]);

export function holdsCapSlot(status: string | null | undefined): boolean {
  return CAP_SLOT_STATUSES.has((status ?? "").toLowerCase());
}

/** A conversation fork preserves the source workspace (or hands off a cloud conversation into a fresh workspace) and never switches the source harness. */
export async function forkMission(id: string, body: { backend: string; model_override: string; model_effort: string; service_tier?: CodexServiceTier; idempotency_key: string; /** Edit-and-resend: keep the history before this message and continue with `replacement`. */ replace_message_id?: string; replacement?: string; remote_node_id?: string | null; workspace_id?: string | null; working_directory?: string | null }): Promise<Mission> {
  try {
    return await api<Mission>(`/api/control/missions/${encodeURIComponent(id)}/fork`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
  } catch (e) {
    if (e instanceof ApiError && [404, 405].includes(e.status)) throw new Error("This backend needs the conversation-fork update. The original mission has not been changed.");
    throw e;
  }
}

export function startProviderOAuth(id: string) {
  return api<{ url: string; instructions: string; method: string }>(`/api/ai/providers/${encodeURIComponent(id)}/oauth/authorize`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ method_index: 0 }),
  });
}
export function completeProviderOAuth(id: string, code: string) {
  return api<AIProvider>(`/api/ai/providers/${encodeURIComponent(id)}/oauth/callback`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ method_index: 0, code }),
  });
}

/** Account-entitled models from the selected execution destination, fetched independently. */
export async function listNodeAntigravityModels(nodeId: string): Promise<[string,string][]> {
 return api(`/api/providers/antigravity-models${nodeId === "core" ? "" : `?node_id=${encodeURIComponent(nodeId)}`}`, {signal: AbortSignal.timeout(20000)});
}

export interface LibrarySkillSummary {
  name: string;
  /** `metadata.sandboxed.audience` (newer backends); parse SKILL.md when absent. */
  audience?: string[] | null;
  /** `metadata.sandboxed.scope` (newer backends). */
  scope?: string | null;
  description?: string | null;
  path: string;
  source?: { type: string; identifier?: string; version?: string };
  setup_commands?: string[];
}

export interface LibrarySkill extends LibrarySkillSummary {
  content: string;
  files?: Array<{ name: string; path: string; content: string }>;
  references?: string[];
}

export async function listLibrarySkills(): Promise<LibrarySkillSummary[]> {
  const data = await api<LibrarySkillSummary[]>("/api/library/skill");
  return Array.isArray(data) ? data : [];
}

export async function getLibrarySkill(name: string): Promise<LibrarySkill> {
  return api<LibrarySkill>(`/api/library/skill/${encodeURIComponent(name)}`);
}

export type ConversationSearchRole = "all" | "user" | "assistant" | "title" | "tool";
export type ConversationSearchSort = "relevance" | "recent";
export type SearchIndexState = "ready" | "indexing";

export interface SearchIndexCoverage {
  schema_version: number;
  state: SearchIndexState;
  indexed_missions: number;
  total_missions: number;
}

export interface SearchHighlightRange {
  start: number;
  end: number;
}

export interface ConversationSearchHit {
  mission_id: string;
  title?: string | null;
  short_description?: string | null;
  project?: string | null;
  status: string;
  backend: string;
  updated_at: string;
  parent_mission_id?: string | null;
  locator: string;
  role: "title" | "user" | "assistant" | "tool" | string;
  sequence?: number | null;
  event_id?: string | null;
  timestamp: string;
  excerpt: string;
  highlights: SearchHighlightRange[];
  mission_match_count: number;
  score: number;
}

export interface ConversationSearchResponse {
  hits: ConversationSearchHit[];
  next_cursor?: string | null;
  coverage: SearchIndexCoverage;
}

export interface PassageContextMessage {
  locator: string;
  role: string;
  sequence?: number | null;
  event_id?: string | null;
  timestamp: string;
  content: string;
  highlights: SearchHighlightRange[];
  is_target: boolean;
}

export interface PassageContextResponse {
  mission_id: string;
  title?: string | null;
  project?: string | null;
  status: string;
  backend: string;
  updated_at: string;
  locator: string;
  target_found: boolean;
  target_sequence?: number | null;
  messages: PassageContextMessage[];
  events?: Array<{
    id: number;
    event_id?: string | null;
    sequence: number;
    event_type: string;
    timestamp: string;
    tool_call_id?: string | null;
    tool_name?: string | null;
    content: string;
    metadata?: Record<string, unknown>;
  }>;
}

export function searchConversationMessages(
  params: {
    q: string;
    project?: string | null;
    role?: ConversationSearchRole;
    include_tools?: boolean;
    include_archived?: boolean;
    since?: string | null;
    until?: string | null;
    sort?: ConversationSearchSort;
    limit?: number;
    max_per_mission?: number;
    cursor?: string | null;
    mission_id?: string | null;
  },
  signal?: AbortSignal,
): Promise<ConversationSearchResponse> {
  const qs = new URLSearchParams();
  qs.set("q", params.q);
  if (params.project) qs.set("project", params.project);
  if (params.role && params.role !== "all") qs.set("role", params.role);
  if (params.include_tools) qs.set("include_tools", "true");
  if (params.include_archived !== undefined) qs.set("include_archived", String(params.include_archived));
  if (params.since) qs.set("since", params.since);
  if (params.until) qs.set("until", params.until);
  if (params.sort && params.sort !== "relevance") qs.set("sort", params.sort);
  if (params.limit != null) qs.set("limit", String(params.limit));
  if (params.max_per_mission != null) qs.set("max_per_mission", String(params.max_per_mission));
  if (params.cursor) qs.set("cursor", params.cursor);
  if (params.mission_id) qs.set("mission_id", params.mission_id);
  return api<ConversationSearchResponse>(
    `/api/control/missions/search/messages?${qs.toString()}`,
    signal ? { signal } : undefined,
  );
}

export function getMissionPassageContext(
  missionId: string,
  params: {
    locator: string;
    sequence?: number | null;
    event_id?: string | null;
    before?: number;
    after?: number;
    query?: string | null;
    include_events?: boolean;
  },
  signal?: AbortSignal,
): Promise<PassageContextResponse> {
  const qs = new URLSearchParams({ locator: params.locator });
  if (params.sequence != null) qs.set("sequence", String(params.sequence));
  if (params.event_id) qs.set("event_id", params.event_id);
  if (params.before != null) qs.set("before", String(params.before));
  if (params.after != null) qs.set("after", String(params.after));
  if (params.query) qs.set("query", params.query);
  if (params.include_events) qs.set("include_events", "true");
  return api<PassageContextResponse>(
    `/api/control/missions/${encodeURIComponent(missionId)}/messages/context?${qs.toString()}`,
    signal ? { signal } : undefined,
  );
}

// ─── Resources Flow & Subagent DAG ───────────────────────────────────────────

export type ResourcesWindowRange = "30m" | "1h" | "6h" | "24h" | "7d";

export interface ComputeSourceSummary {
  id: string;
  label: string;
  sublabel: string;
  total_vcpu: number;
  active_vcpu: number;
  idle_leased_vcpu: number;
  est_usd_per_h: number;
  health: string;
  series_vcpu: number[];
  series_usd_per_h: number[];
}

export interface ComputeOverview {
  total_vcpu: number;
  active_vcpu: number;
  idle_leased_vcpu: number;
  hourly_burn_usd: number;
  sources: ComputeSourceSummary[];
}

export interface InferencePoolSummary {
  id: string;
  label: string;
  sublabel: string;
  provider: string;
  quota_pct_remaining?: number | null;
  reset_at?: string | null;
  current_b_tok_per_h: number;
  est_usd_per_h: number;
  health: string;
  series_b_tok_per_h: number[];
  series_usd_per_h: number[];
}

export interface InferenceOverview {
  current_b_tok_per_h: number;
  est_usd_per_h: number;
  window_total_tokens: number;
  window_est_usd: number;
  throttled_429_count: number;
  pools: InferencePoolSummary[];
}

export interface MissionResourceSummary {
  id: string;
  title: string;
  project?: string | null;
  status: string;
  stall_kind?: string | null;
  subagent_running: number;
  subagent_total: number;
  vcpu: number;
  idle_vcpu: number;
  compute_usd_per_h: number;
  b_tok_per_h: number;
  inference_usd_per_h: number;
  eta_remaining_secs?: number | null;
  series_vcpu: number[];
  series_compute_usd_per_h: number[];
  series_b_tok_per_h: number[];
  series_inference_usd_per_h: number[];
}

export interface ResourceFlowLink {
  kind: "compute" | "inference" | string;
  source_id: string;
  mission_id: string;
  value: number;
  est_usd_per_h: number;
  degraded: boolean;
}

export interface ResourcesOverviewResponse {
  as_of: string;
  range: ResourcesWindowRange | string;
  bucket_seconds: number;
  timestamps_ms: number[];
  compute: ComputeOverview;
  inference: InferenceOverview;
  missions: MissionResourceSummary[];
  links: ResourceFlowLink[];
}

export interface HorizonOption {
  id: string;
  label: string;
  span_secs: number;
}

export interface MissionDetailHeader {
  id: string;
  title: string;
  project?: string | null;
  status: string;
  started_at: string;
  completed_at?: string | null;
  elapsed_secs: number;
  eta_remaining_secs?: number | null;
  subagent_count: number;
  track_count: number;
}

export interface MissionFlowInputNode {
  id: string;
  kind: string;
  label: string;
  sub: string;
  weight: number;
  est_usd_per_h: number;
}

export interface MissionFlowTrackNode {
  id: string;
  label: string;
  sub: string;
  state: string;
}

export interface MissionFlowSubagentNode {
  id: string;
  mission_id?: string | null;
  native: boolean;
  track_id: string;
  role: string;
  label: string;
  model?: string | null;
  node_id?: string | null;
  vcpu: number;
  compute_usd_per_h: number;
  b_tok_per_h: number;
  inference_usd_per_h: number;
  state: string;
}

export interface MissionFlowEdge {
  kind: string;
  source_id: string;
  target_id: string;
  weight: number;
  est_usd_per_h: number;
  degraded: boolean;
}

export interface MissionFlowPayload {
  inputs: MissionFlowInputNode[];
  tracks: MissionFlowTrackNode[];
  subagents: MissionFlowSubagentNode[];
  input_to_track: MissionFlowEdge[];
  track_to_subagent: MissionFlowEdge[];
}

export interface MissionDagBar {
  id: string;
  mission_id?: string | null;
  label: string;
  section: string;
  role: string;
  model?: string | null;
  node_id?: string | null;
  vcpu: number;
  compute_usd_per_h: number;
  b_tok_per_h: number;
  inference_usd_per_h: number;
  start_offset_secs: number;
  duration_secs: number;
  eta_remaining_secs?: number | null;
  eta_basis?: string | null;
  state: "done" | "active" | "capped" | "pending" | string;
  after_ids: string[];
}

export interface MissionDagPayload {
  origin_unix_secs: number;
  horizon_secs: number;
  now_offset_secs: number;
  bars: MissionDagBar[];
}

export interface MissionTimelineSeries {
  offsets_secs: number[];
  observed_vcpu: Array<number | null>;
  projected_vcpu: Array<number | null>;
  observed_compute_usd_per_h: Array<number | null>;
  projected_compute_usd_per_h: Array<number | null>;
  observed_b_tok_per_h: Array<number | null>;
  projected_b_tok_per_h: Array<number | null>;
  observed_inference_usd_per_h: Array<number | null>;
  projected_inference_usd_per_h: Array<number | null>;
}

export interface MissionResourcesResponse {
  as_of: string;
  mission: MissionDetailHeader;
  available_horizons: HorizonOption[];
  active_horizon: string;
  flow: MissionFlowPayload;
  dag: MissionDagPayload;
  timeline: MissionTimelineSeries;
}

export function getResourcesOverview(
  range: ResourcesWindowRange = "6h",
  signal?: AbortSignal,
): Promise<ResourcesOverviewResponse> {
  const qs = new URLSearchParams({ range });
  return api<ResourcesOverviewResponse>(
    `/api/resources/overview?${qs.toString()}`,
    signal ? { signal } : undefined,
  );
}

export function getMissionResources(
  missionId: string,
  horizon?: string,
  signal?: AbortSignal,
): Promise<MissionResourcesResponse> {
  const qs = new URLSearchParams();
  if (horizon) qs.set("horizon", horizon);
  const suffix = qs.size > 0 ? `?${qs.toString()}` : "";
  return api<MissionResourcesResponse>(
    `/api/resources/missions/${encodeURIComponent(missionId)}${suffix}`,
    signal ? { signal } : undefined,
  );
}



