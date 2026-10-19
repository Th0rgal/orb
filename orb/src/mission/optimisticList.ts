/**
 * Messages shown before the server confirms them. An entry keeps its id
 * through retries and leaves the list only once its canonical copy is
 * visible (`reconcile`) or its send is settled by the caller (`remove`).
 */
import { createSignal } from "solid-js";

export type OptimisticEntry = { id: string; waiting: boolean; failed?: boolean };

export function createOptimisticList<T extends OptimisticEntry>() {
  const [items, setItems] = createSignal<T[]>([]);
  const has = (id: string) => items().some(item => item.id === id);
  return {
    items,
    first: (): T | null => items()[0] ?? null,
    has,
    find: (id: string) => items().find(item => item.id === id),
    clear: () => setItems([]),
    /** Add `item`, or replace the entry with the same id in place. */
    upsert: (item: T) => setItems(prev => prev.some(x => x.id === item.id) ? prev.map(x => x.id === item.id ? item : x) : [...prev, item]),
    /** Replace the entries with these ids by `next`, appended in order. */
    replaceAll: (next: T[]) => { const ids = new Set(next.map(item => item.id)); setItems(prev => [...prev.filter(item => !ids.has(item.id)), ...next]); },
    remove: (...ids: string[]) => { const drop = new Set(ids); setItems(prev => prev.some(item => drop.has(item.id)) ? prev.filter(item => !drop.has(item.id)) : prev); },
    setFailed: (ids: string | readonly string[], failed: boolean) => {
      const set = new Set(typeof ids === "string" ? [ids] : ids);
      setItems(prev => prev.map(item => set.has(item.id) && !!item.failed !== failed ? { ...item, failed } : item));
    },
    /** Keep only entries that match `keep`. */
    retain: (keep: (item: T) => boolean) => setItems(prev => { const next = prev.filter(keep); return next.length === prev.length ? prev : next; }),
    /** Drop entries whose canonical message (by id) is now visible. Returns whether any were dropped. */
    reconcile: (known: ReadonlySet<string>) => {
      if (!items().some(item => known.has(item.id))) return false;
      setItems(prev => prev.filter(item => !known.has(item.id)));
      return true;
    },
    /** In-flight entries (not yet failed) other than `id`. */
    inFlightOtherThan: (id: string) => items().some(item => item.id !== id && !item.failed),
  };
}
export type OptimisticList<T extends OptimisticEntry> = ReturnType<typeof createOptimisticList<T>>;
