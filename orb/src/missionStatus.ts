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

/* ── One answer to "is this mission working?" ─────────────────────────── */

export type ActivityReason = "running" | "queued" | "starting" | "stopping" | "idle" | "failed" | "needs_you";
export type MissionActivity = { working: boolean; reason: ActivityReason; label?: string };

type ActivityJob = { phase?: string | null; node_state?: string | null; node_id?: string | null; lease_state?: string | null; terminal_reason?: string | null; finished_at?: string | null; exit_code?: number | null } | null | undefined;
type ActivityMission = { status?: string | null; remote_node_id?: string | null; remote_job?: ActivityJob; execution?: { state?: string | null } | null } | null | undefined;
type ActivityItem = { kind: string; queued?: boolean };

const TERMINAL_LEASES = new Set(["released", "expired", "lost", "terminal", "terminated", "finished", "failed", "cancelled", "canceled"]);
const FAILED_JOB_STATES = new Set(["failed", "lost", "cancelled", "canceled"]);

/** A remote job that has ended, whatever the mission status still says. */
export function remoteJobEnded(job: ActivityJob): boolean {
  if (!job) return false;
  return job.phase === "finished" || !!job.finished_at || !!job.terminal_reason || TERMINAL_LEASES.has(job.lease_state ?? "") || FAILED_JOB_STATES.has(job.node_state ?? "");
}

function errorAfterLastUser(items: readonly ActivityItem[]): boolean {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) return false;
    if (item.kind === "error") return true;
  }
  return false;
}

/**
 * Whether the mission is working, and why. Every surface (sidebar glyph,
 * Stop button, transcript Working row, status banner) reads this one
 * answer, so they cannot disagree.
 *
 * - A local run on this computer is working.
 * - A remote job that finished, lost its lease or has a terminal reason is
 *   not working, even while the status still says pending or active.
 * - An error after the last delivered message, with no live job, ends the turn.
 * - A remote job waiting for a node slot is working ("queued").
 */
export function missionActivity(mission: ActivityMission, items: readonly ActivityItem[] = [], opts: { localRun?: boolean; needsYou?: boolean; nodeName?: (id: string) => string } = {}): MissionActivity {
  if (opts.localRun) return { working: true, reason: "running" };
  if (!mission) return { working: false, reason: "idle" };
  const status = mission.status ?? "";
  const job = mission.remote_job;
  if (opts.needsYou && !isFailedStatus(status)) return { working: false, reason: "needs_you" };
  if (job && remoteJobEnded(job)) {
    const failed = !!job.terminal_reason || FAILED_JOB_STATES.has(job.node_state ?? "") || (job.exit_code != null && job.exit_code !== 0) || isFailedStatus(status);
    return { working: false, reason: failed ? "failed" : "idle" };
  }
  if (mission.execution?.state === "stopping") return { working: true, reason: "stopping" };
  const jobLive = !!job && (job.node_state === "running" || job.node_state === "queued");
  if (!jobLive && errorAfterLastUser(items)) return { working: false, reason: "failed" };
  if (job?.node_state === "queued") {
    const node = job.node_id ?? mission.remote_node_id;
    return { working: true, reason: "queued", label: node ? `Waiting for a free slot on ${opts.nodeName?.(node) ?? node}` : "Waiting for a free slot" };
  }
  if (job?.node_state === "running") return { working: true, reason: "running" };
  if (status === "starting" || status === "resuming") return { working: true, reason: "starting" };
  if (isRunning(status)) return { working: true, reason: "running" };
  if (isQueued(status)) return { working: true, reason: "queued" };
  if (isFailedStatus(status)) return { working: false, reason: "failed" };
  if (status === "blocked") return { working: false, reason: "needs_you" };
  return { working: false, reason: "idle" };
}

/** The status a row should present for `mission`, corrected by `missionActivity`:
 * a stale live status whose run already ended reads as failed or idle. */
export function presentedStatus(mission: ActivityMission & { status: string }, activity: MissionActivity = missionActivity(mission)): string {
  if (activity.working) return activity.reason === "queued" ? "queued" : activity.reason === "starting" ? "starting" : isLive(mission.status) ? mission.status : "running";
  if (!isLive(mission.status)) return mission.status;
  return activity.reason === "failed" ? "failed" : "interrupted";
}
