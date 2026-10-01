/** In-flight sharing only. Results are never retained after completion. */
const pending = new Map<string, Promise<unknown>>();
let requests = 0, joined = 0, failures = 0, elapsedMs = 0;
export function readStats() { return {requests, joined, failures, elapsedMs, inflight: pending.size}; }
export function invalidateReads() { pending.clear(); }
export function sharedRead<T>(key: string, load: () => Promise<T>): Promise<T> {
  const existing = pending.get(key) as Promise<T> | undefined;
  if (existing) { joined++; return existing; }
  requests++;
  const start = performance.now();
  let operation: Promise<T>;
  try { operation = load(); } catch (error) { operation = Promise.reject(error); }
  const request = operation.catch(error => { failures++; throw error; }).finally(() => {
    elapsedMs += performance.now() - start;
    if (pending.get(key) === request) pending.delete(key);
  });
  pending.set(key, request);
  return request;
}
