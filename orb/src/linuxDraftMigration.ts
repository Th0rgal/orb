// One-time migration of legacy Linux http://127.0.0.1:1431/ orb-composer-drafts
// IndexedDB records (composer drafts, side-question threads, approved plans,
// local message queue) into tauri://localhost/ or orb://localhost/ before the
// application module graph boots.

const DB_NAME = "orb-composer-drafts";
const STORE_NAME = "drafts";
const MIGRATE_BASE = "http://127.0.0.1:1431";
const TIMEOUT_MS = 2500;

function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function decodeMigratedValue(v: unknown): unknown {
  if (!v || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(decodeMigratedValue);
  const rec = v as Record<string, unknown>;
  if (typeof rec.__orb_t === "string") {
    if (rec.__orb_t === "File" && typeof rec.b64 === "string" && typeof rec.name === "string") {
      return new File([base64ToBytes(rec.b64)], rec.name, {
        type: typeof rec.type === "string" ? rec.type : "",
        lastModified: typeof rec.lastModified === "number" ? rec.lastModified : Date.now(),
      });
    }
    if (rec.__orb_t === "Blob" && typeof rec.b64 === "string") {
      return new Blob([base64ToBytes(rec.b64)], { type: typeof rec.type === "string" ? rec.type : "" });
    }
    if (rec.__orb_t === "Uint8Array" && typeof rec.b64 === "string") {
      return base64ToBytes(rec.b64);
    }
    if (rec.__orb_t === "ArrayBuffer" && typeof rec.b64 === "string") {
      return base64ToBytes(rec.b64).buffer;
    }
    if (rec.__orb_t === "Date" && typeof rec.iso === "string") {
      return new Date(rec.iso);
    }
  }
  const out: Record<string, unknown> = {};
  for (const [k, val] of Object.entries(rec)) out[k] = decodeMigratedValue(val);
  return out;
}

export function mergeMigratedRecord(
  key: string,
  legacy: unknown,
  existing: unknown,
): { write: boolean; value: unknown } {
  if (existing === undefined) return { write: true, value: legacy };
  if (
    (key.endsWith(":tombstones") || key.endsWith(":received")) &&
    Array.isArray(legacy) &&
    Array.isArray(existing)
  ) {
    const merged = [...new Set([...legacy, ...existing])];
    return { write: merged.length !== existing.length, value: merged };
  }
  if (
    key.endsWith(":wake-stops") &&
    legacy !== null &&
    typeof legacy === "object" &&
    !Array.isArray(legacy) &&
    existing !== null &&
    typeof existing === "object" &&
    !Array.isArray(existing)
  ) {
    const merged = {
      ...(legacy as Record<string, unknown>),
      ...(existing as Record<string, unknown>),
    };
    return {
      write: Object.keys(merged).length !== Object.keys(existing as object).length,
      value: merged,
    };
  }
  if (
    key.startsWith("thread:") &&
    Array.isArray(legacy) &&
    Array.isArray(existing) &&
    legacy.every(x => x && typeof x === "object" && typeof (x as { id?: unknown }).id === "string") &&
    existing.every(x => x && typeof x === "object" && typeof (x as { id?: unknown }).id === "string")
  ) {
    const seen = new Set(existing.map(x => (x as { id: string }).id));
    const missing = legacy.filter(x => !seen.has((x as { id: string }).id));
    return missing.length > 0
      ? { write: true, value: [...existing, ...missing] }
      : { write: false, value: existing };
  }
  return { write: false, value: existing };
}

async function importIntoDraftsDb(decodedEntries: Array<[string, unknown]>): Promise<void> {
  if (decodedEntries.length === 0) return;
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE_NAME)) {
        req.result.createObjectStore(STORE_NAME);
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    const store = tx.objectStore(STORE_NAME);
    for (const [key, legacyVal] of decodedEntries) {
      const getReq = store.get(key);
      getReq.onsuccess = () => {
        const merged = mergeMigratedRecord(key, legacyVal, getReq.result);
        if (merged.write) store.put(merged.value, key);
      };
    }
    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error);
    };
    tx.onabort = () => {
      db.close();
      reject(tx.error ?? new Error("migration transaction aborted"));
    };
  });
}

export async function migrateLinux1431Drafts(opts?: {
  search?: string;
  replaceUrl?: (cleanPath: string) => void;
  fetchImpl?: typeof fetch;
}): Promise<boolean> {
  const rawSearch = opts?.search ?? location.search;
  const params = new URLSearchParams(rawSearch);
  const nonce = params.get("migrate_1431");
  if (!nonce) return false;
  params.delete("migrate_1431");
  const rest = params.toString();
  const cleanUrl = `${typeof location !== "undefined" ? location.pathname || "/" : "/"}${rest ? `?${rest}` : ""}${typeof location !== "undefined" ? location.hash || "" : ""}`;
  if (opts?.replaceUrl) opts.replaceUrl(cleanUrl);
  else if (typeof history !== "undefined" && typeof history.replaceState === "function") {
    history.replaceState(null, "", cleanUrl);
  }
  if (!/^[0-9a-f]{64}$/.test(nonce)) return false;

  const doFetch = opts?.fetchImpl ?? fetch;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const res = await doFetch(`${MIGRATE_BASE}/__orb_migrate_pull?nonce=${nonce}`, {
      signal: ctl.signal,
    });
    if (!res.ok) return false;
    const payload = (await res.json()) as { entries?: unknown };
    if (!Array.isArray(payload.entries)) return false;
    const decoded: Array<[string, unknown]> = [];
    for (const item of payload.entries) {
      if (Array.isArray(item) && item.length === 2 && typeof item[0] === "string") {
        decoded.push([item[0], decodeMigratedValue(item[1])]);
      }
    }
    await importIntoDraftsDb(decoded);
    const ack = await doFetch(`${MIGRATE_BASE}/__orb_migrate_ack?nonce=${nonce}`, {
      method: "POST",
      signal: ctl.signal,
    });
    return ack.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}
