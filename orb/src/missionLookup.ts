import { createSignal } from "solid-js";
import { getMission, type Mission } from "./api";
import { isWorking } from "./missionStatus";

/** Subagent cards read their child's status from the sidebar list, which only
 * holds recent and open missions. A child missing from it kept the status of
 * its launch receipt forever ("Running", with a shimmer animating off screen)
 * after it had finished. Read such a child by id once, and again at most once
 * a minute while it is still working. */
export const MISSION_LOOKUP_TTL_MS = 60_000;
const [known, setKnown] = createSignal<ReadonlyMap<string, Mission>>(new Map());
const readAt = new Map<string, number>();

export function seedKnownMissions(rows: ReadonlyArray<Mission>, now = Date.now()): void {
  if (!rows.length) return;
  let next: Map<string, Mission> | undefined;
  const current = known();
  for (const row of rows) {
    if (!row?.id) continue;
    const prev = (next ?? current).get(row.id);
    const prevTs = prev ? (Date.parse(prev.updated_at || prev.created_at || "") || 0) : -1;
    const nextTs = Date.parse(row.updated_at || row.created_at || "") || 0;
    if (!prev || nextTs >= prevTs) {
      if (!next) next = new Map(current);
      next.set(row.id, prev?.history?.length && !row.history?.length ? { ...prev, ...row, history: prev.history } : row);
      readAt.set(row.id, now);
    }
  }
  if (next) setKnown(next);
}

export function lookupMissionById(id: string, now = Date.now()): Mission | undefined {
  const row = known().get(id);
  const stale = now - (readAt.get(id) ?? -Infinity) >= MISSION_LOOKUP_TTL_MS;
  if ((!row || isWorking(row.status)) && stale) {
    readAt.set(id, now);
    void getMission(id, { includeHistory: false }).then(mission => setKnown(prev => new Map(prev).set(id, mission)), () => {});
  }
  return row;
}

/** Tests and connection resets. */
export function resetMissionLookup() { readAt.clear(); setKnown(new Map()); }
