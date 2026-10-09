import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, isConnected, markMissionOpened, type Mission } from "./api";

const [unreadVersion, setUnreadVersion] = createSignal(0);
export { unreadVersion };

/**
 * Any non-running terminal or waiting state where the agent has finished a
 * turn, asked a question, or stopped with an error/block is unread until the
 * user opens the conversation (or marks it read/done) after that timestamp.
 */
const UNREAD_RESPONSE_STATUSES = new Set([
  "awaiting_user",
  "waiting_user",
  "completed",
  "succeeded",
  "failed",
  "blocked",
  "not_feasible",
  "paused",
  "interrupted",
]);

let cachedKey = "";
let seenCache: Record<string, number> = {};
let openedVersion = -1;
const openedTurns = new Map<string, number>();

function syncOpened(id: string, turn: number): void {
  if (!isConnected()) return;
  const version = connectionVersion();
  if (openedVersion !== version) {
    openedVersion = version;
    openedTurns.clear();
  }
  // Core broadcasts a status event after an opened receipt. Reposting that
  // receipt on every refreshed snapshot creates an SSE/read/write loop.
  if (openedTurns.get(id) === turn) return;
  openedTurns.set(id, turn);
  void markMissionOpened(id).catch(() => {
    // A failed receipt can retry on the next observation, without forgetting a
    // newer turn or a different connection that completed in the meantime.
    if (openedVersion === version && openedTurns.get(id) === turn) openedTurns.delete(id);
  });
}

function storageKey(): string {
  return `orb.missionSeenV2:${getApiUrl() || "default"}`;
}

function ensureSeenCache(): Record<string, number> {
  const key = storageKey();
  if (cachedKey === key) return seenCache;
  cachedKey = key;
  seenCache = {};
  try {
    const raw = localStorage.getItem(key);
    if (raw) {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      if (parsed && typeof parsed === "object") {
        for (const [k, v] of Object.entries(parsed)) {
          if (typeof v === "number" && Number.isFinite(v)) {
            seenCache[k] = v;
          }
        }
      }
    }
  } catch {
    /* ignore storage errors */
  }
  return seenCache;
}

function persistSeenCache(): void {
  try {
    localStorage.setItem(storageKey(), JSON.stringify(seenCache));
  } catch {
    /* ignore quota/storage errors */
  }
}

export function missionResponseTimestampMs(
  mission: Pick<Mission, "updated_at" | "created_at" | "last_output_at">,
): number {
  const updatedMs = mission.updated_at ? Date.parse(mission.updated_at) : 0;
  const outputMs = mission.last_output_at ? Date.parse(mission.last_output_at) : 0;
  const createdMs = mission.created_at ? Date.parse(mission.created_at) : 0;
  const best = Math.max(
    Number.isFinite(updatedMs) ? updatedMs : 0,
    Number.isFinite(outputMs) ? outputMs : 0,
    Number.isFinite(createdMs) ? createdMs : 0,
  );
  return best;
}

/**
 * Returns true when a mission has produced a response, completed, failed, or
 * is waiting on an interactive prompt that the user has not opened since it
 * happened.
 */
export function isMissionUnread(
  mission: Pick<
    Mission,
    "id" | "status" | "updated_at" | "created_at" | "first_viewed_at" | "last_output_at"
  >,
  selectedMissionId?: string | null,
  hasInteraction = false,
): boolean {
  unreadVersion();
  if (!hasInteraction && !UNREAD_RESPONSE_STATUSES.has(mission.status)) {
    return false;
  }
  if (selectedMissionId && mission.id === selectedMissionId) {
    return false;
  }

  const seen = ensureSeenCache()[mission.id];
  const updatedMs = missionResponseTimestampMs(mission);

  // Explicit negative timestamp means the user manually marked this turn unread.
  if (seen !== undefined && seen < 0) {
    const markedUnreadAtTurnMs = Math.abs(seen);
    if (updatedMs <= 0 || updatedMs <= markedUnreadAtTurnMs + 1000) {
      return true;
    }
  }

  if (mission.first_viewed_at) {
    const viewedMs = Date.parse(mission.first_viewed_at);
    if (!Number.isFinite(viewedMs) || updatedMs <= 0 || viewedMs + 2000 >= updatedMs) {
      return false;
    }
  }

  if (seen !== undefined && seen >= 0) {
    if (updatedMs <= 0 || seen >= updatedMs) {
      return false;
    }
  }

  return true;
}

export function markMissionRead(
  missionOrId:
    | string
    | (Pick<Mission, "id" | "updated_at" | "created_at" | "last_output_at"> & {
        status?: string;
      }),
  syncBackend = true,
  hasInteraction = false,
): void {
  const id = typeof missionOrId === "string" ? missionOrId : missionOrId.id;
  if (!id) return;
  const status = typeof missionOrId === "string" ? undefined : missionOrId.status;
  if (status && !UNREAD_RESPONSE_STATUSES.has(status) && !hasInteraction) {
    return;
  }
  const updatedMs =
    typeof missionOrId === "string" ? 0 : missionResponseTimestampMs(missionOrId);
  const stamp = Math.max(Date.now(), updatedMs);
  const map = ensureSeenCache();
  if (map[id] === undefined || map[id] < 0 || map[id] < updatedMs) {
    map[id] = stamp;
    persistSeenCache();
    setUnreadVersion((v) => v + 1);
  }
  if (
    syncBackend &&
    isConnected() &&
    (!status || UNREAD_RESPONSE_STATUSES.has(status))
  ) {
    syncOpened(id, updatedMs);
  }
}

export function markMissionUnread(
  mission: Pick<Mission, "id" | "updated_at" | "created_at" | "last_output_at">,
): void {
  if (!mission.id) return;
  const map = ensureSeenCache();
  const updatedMs = Math.max(1, missionResponseTimestampMs(mission) || Date.now());
  map[mission.id] = -updatedMs;
  persistSeenCache();
  setUnreadVersion((v) => v + 1);
}

export function markMissionsRead(
  missions: ReadonlyArray<
    Pick<Mission, "id" | "updated_at" | "created_at" | "last_output_at">
  >,
  syncBackend = true,
): void {
  if (!missions.length) return;
  const map = ensureSeenCache();
  const now = Date.now();
  let changed = false;
  for (const m of missions) {
    if (!m.id) continue;
    const turn = missionResponseTimestampMs(m);
    const stamp = Math.max(now, turn);
    if (map[m.id] === undefined || map[m.id] < 0 || map[m.id] < turn) {
      map[m.id] = stamp;
      changed = true;
    }
    if (syncBackend && isConnected()) {
      syncOpened(m.id, turn);
    }
  }
  if (changed) {
    persistSeenCache();
    setUnreadVersion((v) => v + 1);
  }
}
