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
