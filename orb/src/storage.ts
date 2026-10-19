/**
 * localStorage that never throws. Reads are parsed once and kept in memory
 * keyed by the stored text, so a hot path does not re-parse JSON; writes go
 * to memory first and then through to storage. When storage refuses a write
 * (quota, private mode) the value still lives in memory for this session.
 *
 * Values returned by `readJson` may be shared with later readers: copy before
 * mutating unless the result is written back with `writeJson`.
 */
import { createSignal, type Accessor } from "solid-js";
import { log } from "./log";

type Entry = { raw: string | null; value: unknown; unsaved?: boolean };
const memory = new Map<string, Entry>();

function storage(): Storage | undefined {
  try { return typeof localStorage === "undefined" ? undefined : localStorage; } catch { return undefined; }
}

/** The stored text, or `null`. Never throws. */
export function readString(key: string): string | null {
  const held = memory.get(key);
  if (held?.unsaved) return typeof held.value === "string" ? held.value : held.raw;
  try { return storage()?.getItem(key) ?? null; } catch { return held?.raw ?? null; }
}

/** Store text. Returns false when storage refused it (the value is kept in memory). */
export function writeString(key: string, value: string): boolean {
  try {
    const store = storage();
    if (!store) throw new Error("localStorage is unavailable");
    store.setItem(key, value);
    memory.delete(key);
    return true;
  } catch (error) {
    memory.set(key, { raw: value, value, unsaved: true });
    log.warn("storage.write", error instanceof Error ? error.message : String(error), { key });
    return false;
  }
}

export function removeKey(key: string): void {
  memory.delete(key);
  try { storage()?.removeItem(key); } catch { /* nothing stored to forget */ }
}

/**
 * Parsed JSON at `key`, or `fallback` when it is missing, malformed or
 * rejected by `valid`.
 */
export function readJson<T>(key: string, fallback: T, valid?: (value: unknown) => boolean): T {
  const held = memory.get(key);
  if (held?.unsaved) return held.value as T;
  let raw: string | null;
  try { raw = storage()?.getItem(key) ?? null; } catch { raw = held?.raw ?? null; }
  if (raw === null) return fallback;
  if (held && held.raw === raw) return (held.value === undefined ? fallback : held.value) as T;
  let value: unknown;
  try { value = JSON.parse(raw); } catch { value = undefined; }
  if (value === null || (valid && !valid(value))) value = undefined;
  memory.set(key, { raw, value });
  return (value === undefined ? fallback : value) as T;
}

/** Store `value` as JSON. Never throws; returns false when storage refused it. */
export function writeJson(key: string, value: unknown): boolean {
  let raw: string;
  try { raw = JSON.stringify(value); } catch (error) { log.warn("storage.serialize", String(error), { key }); return false; }
  try {
    const store = storage();
    if (!store) throw new Error("localStorage is unavailable");
    store.setItem(key, raw);
    memory.set(key, { raw, value });
    return true;
  } catch (error) {
    memory.set(key, { raw, value, unsaved: true });
    log.warn("storage.write", error instanceof Error ? error.message : String(error), { key });
    return false;
  }
}

/** A signal persisted as JSON at `key`. */
export function jsonSignal<T>(key: string, fallback: T, valid?: (value: unknown) => boolean): [Accessor<T>, (next: T) => void] {
  const [value, setValue] = createSignal<T>(readJson(key, fallback, valid));
  return [value, (next: T) => { setValue(() => next); writeJson(key, next); }];
}

/** Test hook: drop the in-memory copies. */
export function resetStorageCache(): void { memory.clear(); }

/** A plain JSON object (not an array). */
export const isRecord = (value: unknown): boolean => !!value && typeof value === "object" && !Array.isArray(value);
