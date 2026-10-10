import { connectionVersion, getApiUrl, getJwt, isConnected } from "./api";
import { sideQuestionKey } from "./sideQuestionStorage";

export type SharedInboxPreferences = { aiSummary: boolean; includeAutonomous: boolean; model: string };
export type SharedInboxState = Record<string, unknown> & { preferences?: SharedInboxPreferences };
let mutation = 0;
let pending = 0;
let writes: Promise<void> = Promise.resolve();
let loadedKey = "";
let versions: Record<string, number> = {};
let outbox: Record<string, { body: unknown; serial: number }> = {};
function loadOutbox(): string {
  const key = sideQuestionKey("inbox-state:outbox:v1");
  if (key !== loadedKey) {
    loadedKey = key; outbox = {}; versions = {};
    try { const saved = JSON.parse(localStorage.getItem(key) ?? "{}"); if (saved && typeof saved === "object" && !Array.isArray(saved)) outbox = saved; } catch {}
  }
  return key;
}
function persist(): void { try { localStorage.setItem(loadedKey, JSON.stringify(outbox)); } catch {} }

export function writeInboxState(path: string, input: unknown): void {
  const key = loadOutbox(), serial = ++mutation;
  let body = input;
  if (input && typeof input === "object" && !Array.isArray(input)) {
    const fields = { ...input } as Record<string, unknown>;
    delete fields.mutationAt;
    if (!fields.clientId || !fields.mutationSeq) {
      const clientId = localStorage.getItem("orb.inbox.client.v1") ?? crypto.randomUUID();
      const sequence = Number(localStorage.getItem("orb.inbox.sequence.v1") ?? 0) + 1;
      localStorage.setItem("orb.inbox.client.v1", clientId);
      localStorage.setItem("orb.inbox.sequence.v1", String(sequence));
      const entry = path.startsWith("seen/") ? `seen:${decodeURIComponent(path.slice(5))}` : path;
      Object.assign(fields, { clientId, mutationSeq: sequence, expectedVersion: versions[entry] ?? 0 });
    }
    body = fields;
  }
  outbox[path] = { body, serial }; persist();
  if (!isConnected()) return;
  const version = connectionVersion(), base = getApiUrl(), token = getJwt();
  pending++;
  writes = writes.catch(() => {}).then(async () => {
    if (connectionVersion() !== version || loadOutbox() !== key) return;
    const response = await fetch(`${base}/api/control/inbox-state/${path}`, {
      method: "PUT", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(body), signal: AbortSignal.timeout(10_000),
    });
    // Deleted or no-longer-accessible missions cannot receive a read receipt.
    // Drop only that terminal receipt; retain preferences and transient failures.
    if (!response.ok && !(response.status === 404 && path.startsWith("seen/"))) throw new Error("Inbox state write failed");
    if (loadOutbox() === key && outbox[path]?.serial === serial) { delete outbox[path]; persist(); }
  }).catch(() => {}).finally(() => { pending--; });
}

export async function readInboxState(): Promise<SharedInboxState | undefined> {
  if (!isConnected() || pending) return;
  loadOutbox();
  const unsent = Object.entries(outbox);
  if (unsent.length) { for (const [path, entry] of unsent) writeInboxState(path, entry.body); return; }
  const version = connectionVersion(), serial = mutation;
  try {
    const response = await fetch(`${getApiUrl()}/api/control/inbox-state`, {
      headers: { Authorization: `Bearer ${getJwt()}` }, signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return;
    const state = await response.json();
    if (version !== connectionVersion() || serial !== mutation || !state || typeof state !== "object" || Array.isArray(state)) return;
    const remote = state._versions;
    if (remote && typeof remote === "object" && !Array.isArray(remote)) versions = Object.fromEntries(Object.entries(remote).filter(([, value]) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0)) as Record<string, number>;
    return state;
  } catch { return; }
}
