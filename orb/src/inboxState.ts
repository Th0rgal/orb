import { isRecord, readJson, writeJson } from "./storage";
import { swallow } from "./log";
import * as apiModule from "./api";
import { sideQuestionKey } from "./sideQuestionStorage";
import type { InboxSummaryMode } from "./inboxPolicy";

const { connectionVersion, getApiUrl, getJwt, isConnected } = apiModule;
const record = (value: unknown): value is Record<string, unknown> => isRecord(value);

function doFetch(path: string, init?: RequestInit, explicitBase?: string): Promise<Response> {
  if ("transportFetch" in apiModule && typeof apiModule.transportFetch === "function") {
    return apiModule.transportFetch(path, init, explicitBase);
  }
  const base = (explicitBase ?? getApiUrl()).trim().replace(/\/+$/, "");
  return fetch(`${base}${path}`, init);
}

export type SharedInboxPreferences = {
  inboxEnabled?: boolean;
  aiSummary: boolean;
  summaryMode?: InboxSummaryMode;
  includeAutonomous: boolean;
  model: string;
};
export type SharedInboxState = Record<string, unknown> & { preferences?: SharedInboxPreferences };
type OutboxEntry = { body: unknown; serial: number; minServerVersion: number; rebased?: boolean; conflict?: boolean; failed?: boolean };
function nextMutationSeq(floor = 0): number {
  const stored = Number(localStorage.getItem("orb.inbox.sequence.v1") ?? 0);
  const sequence = Math.max(Number.isSafeInteger(stored) && stored >= 0 ? stored : 0, floor) + 1;
  localStorage.setItem("orb.inbox.sequence.v1", String(sequence));
  return sequence;
}
let mutation = 0;
const writes = new Map<string, Promise<void>>();
let loadedKey = "";
let versions: Record<string, number> = {};
let outbox: Record<string, OutboxEntry> = {};
let local: Record<string, OutboxEntry> = {};
function loadOutbox(): string {
  const key = sideQuestionKey("inbox-state:outbox:v1");
  if (key !== loadedKey) {
    loadedKey = key; outbox = {}; versions = {}; local = {};
    const stored = readJson<Record<string, unknown>>(key, {}, isRecord);
    for (const [path, raw] of Object.entries(stored)) {
      if (!record(raw) || !record(raw.body) || !Number.isSafeInteger(raw.serial) || (raw.serial as number) < 0
        || ![raw.rebased, raw.conflict, raw.failed].every(value => value === undefined || typeof value === "boolean")
        || raw.failed) continue;
      const body = raw.body;
      if (typeof body.clientId !== "string" || !body.clientId || !Number.isSafeInteger(body.mutationSeq) || (body.mutationSeq as number) <= 0
        || !Number.isSafeInteger(body.expectedVersion) || (body.expectedVersion as number) < 0) continue;
      if (path === "preferences") {
        if (typeof body.aiSummary !== "boolean" || typeof body.includeAutonomous !== "boolean" || typeof body.model !== "string") continue;
      } else if (path.startsWith("seen/")) {
        try { decodeURIComponent(path.slice(5)); } catch { continue; }
        if (!Number.isSafeInteger(body.stamp) || body.stamp === 0) continue;
      } else continue;
      const entry = { ...raw, body, serial: raw.serial as number, minServerVersion: (body.expectedVersion as number) + 1 };
      outbox[path] = entry; local[path] = entry;
    }
    persist();
  }
  return key;
}
function persist(): void { writeJson(loadedKey, outbox); }
function entryKey(path: string): string {
  return path.startsWith("seen/") ? `seen:${decodeURIComponent(path.slice(5))}` : path;
}
function updateVersions(state: Record<string, unknown>): void {
  if (!record(state._versions)) return;
  for (const [key, value] of Object.entries(state._versions)) {
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
      versions[key] = Math.max(versions[key] ?? 0, value);
    }
  }
}
async function fetchState(key: string, version: number, base: string, token: string | null): Promise<SharedInboxState | undefined> {
  const response = await doFetch("/api/control/inbox-state", {
    headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000),
  }, base);
  if (!response.ok) return;
  const state: unknown = await response.json();
  if (connectionVersion() !== version || loadOutbox() !== key || !record(state)) return;
  updateVersions(state);
  return state as SharedInboxState;
}
function reconcile(path: string, entry: OutboxEntry, state: SharedInboxState): void {
  const name = entryKey(path), body = entry.body;
  if (!record(body) || !record(state._versions)) return;
  const revision = state._versions[name] ?? 0;
  if (typeof revision !== "number" || !Number.isSafeInteger(revision) || revision < 0) return;
  const remote = state[name];
  const satisfied = path.startsWith("seen/") && typeof body.stamp === "number" && typeof remote === "number"
    && (remote === body.stamp || (body.stamp > 0 && remote >= body.stamp));
  if (satisfied || entry.rebased) {
    entry.failed = true;
    delete outbox[path];
  } else {
    versions[name] = Math.max(versions[name] ?? 0, revision);
    entry.body = { ...body, expectedVersion: versions[name], mutationSeq: nextMutationSeq(typeof body.mutationSeq === "number" ? body.mutationSeq : 0) };
    entry.minServerVersion = versions[name] + 1;
    entry.rebased = true;
    entry.conflict = false;
  }
  persist();
}
function flush(path: string, entry: OutboxEntry): void {
  if (!isConnected()) return;
  const key = loadOutbox(), version = connectionVersion(), base = getApiUrl(), token = getJwt();
  const queueKey = `${version}:${key}:${path}`;
  const current = () => connectionVersion() === version && loadOutbox() === key && outbox[path] === entry;
  const prev = writes.get(queueKey) ?? Promise.resolve();
  const task = prev.catch(() => {}).then(async () => {
    if (!current()) return;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (entry.conflict) {
        const state = await fetchState(key, version, base, token);
        if (!state || !current()) return;
        reconcile(path, entry, state);
        if (!current() || entry.conflict) return;
      }
      const response = await doFetch(`/api/control/inbox-state/${path}`, {
        method: "PUT", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify(entry.body), signal: AbortSignal.timeout(10_000),
      }, base);
      if (response.status === 409) {
        if (!current()) return;
        entry.conflict = true;
        persist();
        let state: unknown;
        try { state = await response.json(); } catch { state = undefined; }
        if (!current()) return;
        if (record(state) && record(state._versions) && typeof state._versions[entryKey(path)] === "number") {
          updateVersions(state);
        } else {
          state = await fetchState(key, version, base, token);
        }
        if (!current() || !record(state)) return;
        reconcile(path, entry, state as SharedInboxState);
        if (!current() || entry.conflict) return;
        continue;
      }
      if (!response.ok) {
        if (response.status === 404 && path.startsWith("seen/")) {
          entry.failed = true;
          if (current()) { delete outbox[path]; persist(); }
          return;
        }
        throw new Error("Inbox state write failed");
      }
      if (current()) { delete outbox[path]; persist(); }
      return;
    }
  }).catch(swallow("inboxState.outbox", { path })).finally(() => {
    if (writes.get(queueKey) === task) writes.delete(queueKey);
  });
  writes.set(queueKey, task);
}

export function writeInboxState(path: string, input: unknown): void {
  loadOutbox();
  const serial = ++mutation;
  let body = input;
  if (record(input)) {
    const fields = { ...input };
    delete fields.mutationAt;
    if (!fields.clientId || !fields.mutationSeq) {
      const clientId = localStorage.getItem("orb.inbox.client.v1") ?? crypto.randomUUID();
      const sequence = nextMutationSeq();
      localStorage.setItem("orb.inbox.client.v1", clientId);
      Object.assign(fields, { clientId, mutationSeq: sequence, expectedVersion: versions[entryKey(path)] ?? 0 });
    }
    body = fields;
  }
  const entry = { body, serial, minServerVersion: (record(body) && typeof body.expectedVersion === "number" ? body.expectedVersion : 0) + 1 };
  outbox[path] = entry; local[path] = entry; persist();
  flush(path, entry);
}

export async function readInboxState(): Promise<SharedInboxState | undefined> {
  if (!isConnected()) return;
  const key = loadOutbox(), version = connectionVersion(), serial = mutation;
  try {
    const state = await fetchState(key, version, getApiUrl(), getJwt());
    if (!state) return;
    for (const [path, entry] of Object.entries(outbox)) {
      if (entry.conflict && !writes.has(`${version}:${key}:${path}`)) reconcile(path, entry, state);
    }
    const overlay = { ...outbox };
    for (const [path, entry] of Object.entries(local)) {
      const revision = record(state._versions) && typeof state._versions[entryKey(path)] === "number" ? state._versions[entryKey(path)] as number : 0;
      if (!entry.failed && (entry.serial > serial || revision < entry.minServerVersion)) overlay[path] = entry;
      if (!outbox[path] && (entry.failed || revision >= entry.minServerVersion)) delete local[path];
    }
    for (const [path, entry] of Object.entries(overlay)) {
      if (!record(entry.body)) continue;
      const { clientId, mutationSeq, expectedVersion, mutationAt, ...value } = entry.body;
      state[entryKey(path)] = path.startsWith("seen/") ? value.stamp : value;
    }
    for (const [path, entry] of Object.entries(outbox)) {
      if (!writes.has(`${version}:${key}:${path}`)) flush(path, entry);
    }
    return state;
  } catch { return; }
}
