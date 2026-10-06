/** In-memory LRU for page payloads. First paint reads here; network
 * refreshes in the background and joins in-flight work so open + prefetch
 * share one request. */
const MAX = 64;
const MAX_BYTES = 32 * 1024 * 1024;
let bytes = 0;
let generation = 0;
let loads = 0, shared = 0, evictions = 0;
/** Conservative payload estimate, not a measurement of the JS heap. No serialization. */
export function estimateCacheBytes(value: unknown): number {
  const seen = new WeakSet<object>();
  const pending: unknown[] = [value];
  let size = 0;
  while (pending.length && size <= MAX_BYTES) {
    const item = pending.pop();
    if (typeof item === "string") size += item.length * 2;
    else if (item && typeof item === "object" && !seen.has(item)) {
      seen.add(item); size += 32;
      for (const [key, child] of Object.entries(item)) { size += key.length * 2 + 8; pending.push(child); }
    } else size += 8;
  }
  return size;
}
export function cacheStats() { return {entries: store.size, estimatedBytes: bytes, budgetBytes: MAX_BYTES, inflight: inflight.size, queued: queue.length, loads, shared, evictions}; }
function remove(key: string) { const entry = store.get(key); if (entry) bytes -= entry.bytes; store.delete(key); }
const recentsKey = "orb.recentPages";

type Entry<T> = { value: T; at: number; bytes: number };
const store = new Map<string, Entry<unknown>>();
const inflight = new Map<string, Promise<unknown>>();
let recents: string[] = loadRecents();

function loadRecents(): string[] {
  try {
    const raw = sessionStorage.getItem(recentsKey);
    const parsed = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function saveRecents() {
  try {
    sessionStorage.setItem(recentsKey, JSON.stringify(recents.slice(0, 12)));
  } catch {
    /* quota */
  }
}

export function cachePeek<T>(key: string): T | undefined {
  const hit = store.get(key) as Entry<T> | undefined;
  if (!hit) return undefined;
  store.delete(key);
  store.set(key, hit);
  return hit.value;
}

export function cacheDelete(key:string){remove(key);}

export function cacheAge(key: string): number | undefined {
  const hit = store.get(key);
  return hit ? Date.now() - hit.at : undefined;
}

export function cachePut<T>(key: string, value: T): T {
  remove(key);
  const size = estimateCacheBytes(value);
  // Oversized snapshots remain owned by the mounted view, not the cache.
  if (size > MAX_BYTES) return value;
  store.set(key, { value, at: Date.now(), bytes: size });
  bytes += size;
  while (store.size > MAX || bytes > MAX_BYTES) {
    const oldest = store.keys().next().value;
    if (oldest === undefined) break;
    remove(oldest); evictions++;
  }
  return value;
}

/** Deduped fetch that fills the cache. On failure, keep a prior hit. */
export function cacheLoad<T>(key: string, load: () => Promise<T>, allowStale = false): Promise<T> {
  const version = generation;
  let request = inflight.get(key) as Promise<T> | undefined;
  if (request) shared++;
  else {
    loads++;
    const previous = store.get(key);
    let operation: Promise<T>;
    try { operation = load(); } catch (error) { operation = Promise.reject(error); }
    const current = operation.then(value => {
      if (generation !== version) throw new Error("Connection changed");
      // A direct live update published after this read started wins the cache.
      if (store.get(key) === previous) cachePut(key, value);
      return value;
    }).finally(() => { if (inflight.get(key) === current) inflight.delete(key); });
    inflight.set(key, current);
    request = current;
  }
  if (!allowStale) return request;
  return request.catch(error => {
    if (generation !== version) throw error;
    const hit = cachePeek<T>(key);
    if (hit !== undefined) return hit;
    throw error;
  });
}

export function cacheBusy(key: string): boolean {
  return inflight.has(key);
}

export function cacheRemember(key: string) {
  recents = [key, ...recents.filter((k) => k !== key)].slice(0, 12);
  saveRecents();
}

export function cacheRecents(): string[] {
  return recents.slice();
}

export function cacheCanPrefetch(): boolean {
  if (typeof document !== "undefined" && document.visibilityState === "hidden") return false;
  const mem = (navigator as { deviceMemory?: number }).deviceMemory;
  if (mem != null && mem < 2) return false;
  return true;
}

/** How many project trees to warm on connect. 0 when the machine is tight. */
export function prefetchProjectLimit(): number {
  if (!cacheCanPrefetch()) return 0;
  const mem = (navigator as { deviceMemory?: number }).deviceMemory;
  if (mem != null && mem < 4) return 2;
  if (mem != null && mem < 8) return 4;
  return 4;
}

type Job = { key: string; run: () => Promise<unknown> };
const queue: Job[] = [];
let active = 0;

function pump() {
  if (active > 0 || queue.length === 0 || !cacheCanPrefetch()) return;
  const job = queue.shift();
  if (!job) return;
  if (store.has(job.key) || inflight.has(job.key)) {
    pump();
    return;
  }
  active++;
  void Promise.resolve().then(job.run).catch(() => {}).finally(() => {
    active--;
    pump();
  });
}

function idle(cb: () => void) {
  const w = window as Window & { requestIdleCallback?: (fn: () => void, opts?: { timeout: number }) => number };
  if (typeof w.requestIdleCallback === "function") w.requestIdleCallback(cb, { timeout: 2500 });
  else window.setTimeout(cb, 160);
}

/** Low-priority fill. No-ops when the key is warm, in flight, or the machine is tight. */
export function cachePrefetch(key: string, run: () => Promise<unknown>) {
  if (!cacheCanPrefetch() || store.has(key) || inflight.has(key)) return;
  if (queue.some((j) => j.key === key)) return;
  queue.push({ key, run });
  if (queue.length > 8) queue.shift();
  idle(pump);
}

/** Test hook. */
export function cacheReset() {
  generation++;
  bytes = 0;
  store.clear();
  inflight.clear();
  queue.length = 0;
  recents = [];
}

if (typeof document !== "undefined") document.addEventListener("visibilitychange", () => { if (!document.hidden) pump(); });
