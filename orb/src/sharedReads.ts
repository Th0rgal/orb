/** In-flight sharing only. Results are never retained after completion. */
const pending = new Map<string, Promise<unknown>>();
export function invalidateReads() { pending.clear(); }
export function sharedRead<T>(key: string, load: () => Promise<T>): Promise<T> {
  const existing = pending.get(key) as Promise<T> | undefined;
  if (existing) return existing;
  let operation: Promise<T>;
  try { operation = load(); } catch (error) { operation = Promise.reject(error); }
  const request = operation.finally(() => {
    if (pending.get(key) === request) pending.delete(key);
  });
  pending.set(key, request);
  return request;
}
