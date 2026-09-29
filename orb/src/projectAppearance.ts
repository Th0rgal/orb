import { createSignal } from "solid-js";
import { api, connectionVersion, getApiUrl } from "./api";

export const projectColors = [
  { name: "Default", value: "" }, { name: "Blue", value: "#8aaed4" },
  { name: "Green", value: "#94b89a" }, { name: "Amber", value: "#c5aa70" },
  { name: "Rose", value: "#cb929f" }, { name: "Purple", value: "#ad9acb" },
] as const;
// Preserve the reactive store when Vite replaces a settings module while the
// sidebar remains mounted; both surfaces must keep the same notification signal.
const revisionStore = import.meta.hot?.data?.projectColorRevision ?? createSignal(0);
if (import.meta.hot?.data) import.meta.hot.data.projectColorRevision = revisionStore;
const [revision, setRevision] = revisionStore as ReturnType<typeof createSignal<number>>;

// The server stores the color by palette name (`POST /api/projects/:slug/appearance`);
// this device keeps the hex value, which is what is shown until the roster
// answers and all there is on a backend without the field.
const key = (slug: string, url = getApiUrl()) => `orb.projectColor:${url}:${slug}`;
/** "1": the server has this device's value. "pending": a change it has not received yet. */
const syncKey = (slug: string, url = getApiUrl()) => `orb.projectColorSync:${url}:${slug}`;
const wireName = (value: string) => projectColors.find(c => c.value === value && c.value)?.name.toLowerCase() ?? null;
const fromWire = (name: string) => projectColors.find(c => c.value && c.name.toLowerCase() === name.trim().toLowerCase())?.value;
const read = (name: string) => { try { return localStorage.getItem(name); } catch { return null; } };
const write = (name: string, value: string | null) => { try { if (value) localStorage.setItem(name, value); else localStorage.removeItem(name); } catch { /* storage unavailable: the server copy still applies */ } };
const stored = (slug: string, url?: string) => projectColors.find(c => c.value && c.value === read(key(slug, url)))?.value ?? "";

/** Backends seen answering without the field: writes to them are skipped. */
const unsupported = new Set<string>();
/** Backends seen answering with it. */
const supported = new Set<string>();
/** Whether the connected backend is known to store colors, so they follow the operator to other devices. */
export function projectColorsSynced(): boolean { revision(); connectionVersion(); return supported.has(getApiUrl()); }
/** Last local change per project, so a roster fetched before it cannot undo it. */
const changedAt = new Map<string, number>();
const sending = new Map<string, Promise<void>>();

export function projectColor(slug: string): string | undefined {
  revision(); connectionVersion();
  return stored(slug) || undefined;
}

export function setProjectColor(slug: string, color: string) {
  if (!projectColors.some(c => c.value === color)) return;
  const url = getApiUrl();
  if (color) localStorage.setItem(key(slug), color); else localStorage.removeItem(key(slug));
  write(syncKey(slug, url), "pending");
  changedAt.set(`${url}:${slug}`, Date.now());
  setRevision(v => v + 1);
  void send(slug, url);
}

/** Write this device's value to the server. A failure keeps it pending for the next roster. */
function send(slug: string, url: string): Promise<void> {
  const id = `${url}:${slug}`;
  if (unsupported.has(url) || url !== getApiUrl()) return Promise.resolve();
  const running = sending.get(id);
  // A change made during a write goes out after it, so the last one wins.
  if (running) return running.then(() => read(syncKey(slug, url)) === "pending" ? send(slug, url) : undefined);
  const value = stored(slug, url);
  const task = api(`/api/projects/${encodeURIComponent(slug)}/appearance`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ color: wireName(value) }),
  }).then(() => {
    changedAt.set(id, Date.now());
    if (stored(slug, url) === value) write(syncKey(slug, url), "1");
  }, () => { /* older backend or offline: the local value keeps working */ })
    .finally(() => { if (sending.get(id) === task) sending.delete(id); });
  sending.set(id, task);
  return task;
}

/** Apply a roster answer: the server value wins, the local one is the fallback. */
export function applyProjectRoster(rows: ReadonlyArray<{ slug: string; color?: string | null }>, fetchedAt = Date.now(), url = getApiUrl()): Promise<void> {
  if (url !== getApiUrl()) return Promise.resolve();
  const known = rows.filter(row => "color" in row);
  if (!known.length) {
    if (rows.length) { unsupported.add(url); if (supported.delete(url)) setRevision(v => v + 1); }
    return Promise.resolve();
  }
  unsupported.delete(url);
  let changed = !supported.has(url);
  supported.add(url);
  const writes: Promise<void>[] = [];
  for (const row of known) {
    const id = `${url}:${row.slug}`, state = read(syncKey(row.slug, url)), local = stored(row.slug, url);
    if (sending.has(id) || (changedAt.get(id) ?? 0) >= fetchedAt) continue;
    if (state === "pending") { writes.push(send(row.slug, url)); continue; }
    const server = typeof row.color === "string" ? fromWire(row.color) : row.color === null ? "" : undefined;
    // A name this build does not know: leave both sides as they are.
    if (server === undefined) continue;
    // First contact with a color chosen before the server stored any: upload it once.
    if (!server && local && state !== "1") { write(syncKey(row.slug, url), "pending"); writes.push(send(row.slug, url)); continue; }
    if (server !== local) { write(key(row.slug, url), server || null); changed = true; }
    if (state !== "1" && server) write(syncKey(row.slug, url), "1");
  }
  if (changed) setRevision(v => v + 1);
  return Promise.all(writes).then(() => undefined);
}

/** Test hook: forget what this session learned about backends and writes. */
export function resetProjectAppearanceSync() { unsupported.clear(); supported.clear(); changedAt.clear(); sending.clear(); }
