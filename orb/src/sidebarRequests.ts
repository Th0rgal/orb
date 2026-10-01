type Timing = { requests: number; cacheHits: number; joined: number; totalMs: number; lastMs: number; maxMs: number };
const timings = new Map<string, Timing>();
/** Bounded aggregate diagnostics; no project names, tokens or response bodies. */
export function sidebarTimingSnapshot() {
  return Object.fromEntries([...timings].map(([key, value]) => [key, {...value}]));
}
function timingFor(key: string) {
  const name = key.split(":")[0];
  const category = ["missions", "files", "controller", "crons"].includes(name) ? name : "other";
  if (!timings.has(category)) timings.set(category, {requests:0, cacheHits:0, joined:0, totalMs:0, lastMs:0, maxMs:0});
  return timings.get(category)!;
}

/** Short-lived read cache shared by hover, expansion and polling. Payloads stay
 * in the tree while stale reads refresh. Never cache failures or cross accounts. */
export function createSidebarRequests(ttl = 10_000) {
  const values = new Map<string, {at: number; value: unknown}>();
  const pending = new Map<string, Promise<unknown>>();
  let epoch = 0;
  return {
    clear() { epoch++; values.clear(); pending.clear(); },
    read<T>(key: string, load: () => Promise<T>, force = false): Promise<T> {
      const timing = timingFor(key);
      const active = pending.get(key);
      if (active) { timing.joined++; return active as Promise<T>; }
      const hit = values.get(key);
      if (!force && hit && Date.now() - hit.at < ttl) { timing.cacheHits++; return Promise.resolve(hit.value as T); }
      const generation = epoch;
      const started = performance.now(); timing.requests++;
      const request = Promise.resolve().then(load).then(value => {
        if (generation === epoch) {
          values.delete(key);
          values.set(key, {at: Date.now(), value});
          if (values.size > 128) values.delete(values.keys().next().value!);
        }
        return value;
      }).finally(() => {
        const ms = performance.now() - started;
        timing.lastMs = ms; timing.totalMs += ms; timing.maxMs = Math.max(timing.maxMs, ms);
        if (pending.get(key) === request) pending.delete(key);
      });
      pending.set(key, request);
      return request;
    },
  };
}
