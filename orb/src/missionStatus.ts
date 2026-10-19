/**
 * One vocabulary for Core mission statuses. Every check that used to carry
 * its own list of status strings asks one of these predicates instead, so a
 * status Core adds is classified in one place.
 */

type Status = string | null | undefined;

const set = (...statuses: string[]) => new Set(statuses);

/** Started on a runner: the turn is executing (or about to resume). */
export const RUNNING_STATUSES = set("active", "running", "starting", "resuming");
/** Accepted by Core, waiting for a runner. */
export const QUEUED_STATUSES = set("pending", "queued");
/** A turn is in flight: queued or running. The composer is busy. */
export const LIVE_STATUSES = set(...RUNNING_STATUSES, ...QUEUED_STATUSES);
/** In flight, or finished its turn with background work still running. */
export const WORKING_STATUSES = set(...LIVE_STATUSES, "waiting_background");
/** PATCH /settings can change the next-turn model. A live turn returns 409. */
export const SETTINGS_IDLE_STATUSES = set("awaiting_user", "acknowledged", "interrupted", "failed", "paused", "blocked");
/** Stopped and safe to archive (acknowledge). */
export const ARCHIVABLE_STATUSES = set("awaiting_user", "blocked", "paused", "interrupted", "failed", "completed", "cancelled");
/** Finished: reopening moves it back to paused for a manual follow-up. */
export const REOPENABLE_STATUSES = set("completed", "failed", "interrupted", "acknowledged", "cancelled");
/** Ended with an error the user should see. */
export const FAILED_STATUSES = set("failed", "not_feasible");
/** The turn ended and the conversation waits for the user. */
export const READY_STATUSES = set("awaiting_user", "waiting_user", "acknowledged");

const has = (statuses: ReadonlySet<string>) => (status: Status) => !!status && statuses.has(status);

export const isRunning = has(RUNNING_STATUSES);
export const isQueued = has(QUEUED_STATUSES);
export const isLive = has(LIVE_STATUSES);
export const isWorking = has(WORKING_STATUSES);
export const isArchivable = has(ARCHIVABLE_STATUSES);
export const isReopenable = has(REOPENABLE_STATUSES);
export const isFailedStatus = has(FAILED_STATUSES);
export const isReady = has(READY_STATUSES);
/** Case-insensitive: settings are offered from any casing Core reports. */
export const isSettingsIdle = (status: Status) => SETTINGS_IDLE_STATUSES.has((status ?? "").toLowerCase());

export type StatusTone = "running" | "quiet" | "attention" | "success";
export type StatusIcon = "loader" | "clock" | "alert" | "pause" | "check" | null;

/** How a bare status reads in a row: idle is not success, and blocked is not failure. */
export function statusPresentation(status: string): { label: string; tone: StatusTone; icon: StatusIcon } {
  if (isRunning(status)) return { label: "Running", tone: "running", icon: "loader" };
  if (isQueued(status)) return { label: "Queued", tone: "quiet", icon: "clock" };
  if (isReady(status)) return { label: "Ready for a follow-up", tone: "quiet", icon: null };
  switch (status) {
    case "waiting_background": return { label: "Background work running", tone: "running", icon: "clock" };
    case "blocked": return { label: "Blocked", tone: "attention", icon: "alert" };
    case "paused": return { label: "Paused", tone: "quiet", icon: "pause" };
    case "completed": return { label: "Completed", tone: "success", icon: "check" };
    case "failed": return { label: "Failed", tone: "attention", icon: "alert" };
    case "not_feasible": return { label: "Not feasible", tone: "attention", icon: "alert" };
    case "interrupted": case "cancelled": return { label: "Interrupted", tone: "quiet", icon: "pause" };
    case "idle": return { label: "Idle", tone: "quiet", icon: null };
    default: return { label: status || "Unknown status", tone: "quiet", icon: null };
  }
}
