/** A delete held back only because these workers (mission ids) are still running. */
export class RunningWorkers extends Error {
  constructor(public ids: string[]) { super(`${ids.length} worker${ids.length === 1 ? " is" : "s are"} still running`); }
}
const UUID = /[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}/gi;
/** Worker ids from Core's 409 "Cannot delete a running mission or worker (<id>). Cancel it first." */
export function runningWorkerIds(detail: string): string[] {
  if (!/cannot delete a running/i.test(detail)) return [];
  return [...new Set(detail.match(UUID) ?? [])];
}
/** Paused mission ids from Core's 409 "Cannot delete a paused mission (<id>). Resume or cancel it first." */
export function pausedMissionIds(detail: string): string[] {
  if (!/cannot delete a paused mission/i.test(detail)) return [];
  return [...new Set(detail.match(UUID) ?? [])];
}
/** True when Core refused deletion because unloaded/archived descendants require `?include_descendants=true`. */
export function requiresDescendantOptIn(detail: string): boolean {
  return /include_descendants=true/i.test(detail);
}

type Row = { id: string; title?: string | null; status: string; parent_mission_id?: string | null; callback_parent_mission_id?: string | null };
export type DeleteDescendant = { id: string; title: string; running: boolean };
const RUNNING = new Set(["active", "waiting_background"]);
/** Sessions under `targets` (any depth) that deleting them also deletes. */
export function deleteDescendants(targets: readonly string[], known: readonly Row[]): DeleteDescendant[] {
  const included = new Set(targets), out: DeleteDescendant[] = [];
  for (let added = true; added;) {
    added = false;
    for (const m of known) {
      const parent = m.parent_mission_id || m.callback_parent_mission_id;
      if (included.has(m.id) || !parent || !included.has(parent)) continue;
      included.add(m.id); added = true;
      out.push({ id: m.id, title: m.title?.trim() || m.id.slice(0, 8), running: RUNNING.has(m.status) });
    }
  }
  return out;
}
/** "This also deletes 2 sessions: Benchmarks (running), EV Bench · btw." */
export function descendantsSentence(list: readonly DeleteDescendant[], max = 6): string {
  if (!list.length) return "";
  const names = list.slice(0, max).map(d => d.running ? `${d.title} (running)` : d.title);
  const more = list.length - names.length;
  return `This also deletes ${list.length} session${list.length === 1 ? "" : "s"}: ${names.join(", ")}${more > 0 ? `, and ${more} more` : ""}.`;
}
