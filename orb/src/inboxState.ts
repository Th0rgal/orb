import { connectionVersion, getApiUrl, getJwt, isConnected } from "./api";
import { sideQuestionKey } from "./sideQuestionStorage";

export type SharedInboxPreferences = { aiSummary: boolean; includeAutonomous: boolean; model: string };
export type SharedInboxState = Record<string, unknown> & { preferences?: SharedInboxPreferences };
let mutation = 0;
let pending = 0;
let writes: Promise<void> = Promise.resolve();
let loadedKey = "";
let outbox: Record<string, { body: unknown; serial: number }> = {};
function loadOutbox(): string {
  const key = sideQuestionKey("inbox-state:outbox:v1");
  if (key !== loadedKey) {
    loadedKey = key; outbox = {};
    try { const saved = JSON.parse(localStorage.getItem(key) ?? "{}"); if (saved && typeof saved === "object" && !Array.isArray(saved)) outbox = saved; } catch {}
  }
  return key;
}
function persist(): void { try { localStorage.setItem(loadedKey, JSON.stringify(outbox)); } catch {} }

export function writeInboxState(path: string, body: unknown): void {
  const key = loadOutbox(), serial = ++mutation;
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
    if (!response.ok) throw new Error("Inbox state write failed");
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
    return state;
  } catch { return; }
}
