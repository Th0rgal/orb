/** Short-lived read cache shared by hover, expansion and polling. Payloads stay
 * in the tree while stale reads refresh. Never cache failures or cross accounts. */
export function createSidebarRequests(ttl = 10_000) {
  const values = new Map<string, {at: number; value: unknown}>();
  const pending = new Map<string, Promise<unknown>>();
  let epoch = 0;
  return {
    clear() { epoch++; values.clear(); pending.clear(); },
    read<T>(key: string, load: () => Promise<T>, force = false): Promise<T> {
      const active = pending.get(key);
      if (active) return active as Promise<T>;
      const hit = values.get(key);
      if (!force && hit && Date.now() - hit.at < ttl) return Promise.resolve(hit.value as T);
      const generation = epoch;
      const request = Promise.resolve().then(load).then(value => {
        if (generation === epoch) {
          values.delete(key);
          values.set(key, {at: Date.now(), value});
          if (values.size > 128) values.delete(values.keys().next().value!);
        }
        return value;
      }).finally(() => {
        if (pending.get(key) === request) pending.delete(key);
      });
      pending.set(key, request);
      return request;
    },
  };
}
