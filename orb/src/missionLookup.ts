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

export function lookupMissionById(id: string, now = Date.now()): Mission | undefined {
  const row = known().get(id);
  const stale = now - (readAt.get(id) ?? -Infinity) >= MISSION_LOOKUP_TTL_MS;
  if ((!row || isWorking(row.status)) && stale) {
    readAt.set(id, now);
    void getMission(id).then(mission => setKnown(prev => new Map(prev).set(id, mission)), () => {});
  }
  return row;
}

/** Tests and connection resets. */
export function resetMissionLookup() { readAt.clear(); setKnown(new Map()); }
