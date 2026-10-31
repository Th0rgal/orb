import { createSignal } from "solid-js";
import { harnessName } from "./harnesses";
/**
 * One vocabulary for Core mission statuses. Every check that used to carry
 * its own list of status strings asks one of these predicates instead, so a
 * status Core adds is classified in one place.
 */

type Status = string | null | undefined;

const set = (...statuses: string[]) => new Set(statuses);

/** Started on a runner: the turn is executing (or about to resume). */
export const RUNNING_STATUSES = set("active", "running", "starting", "resuming", "working", "in_progress", "processing", "streaming");
/** Accepted by Core, waiting for a runner. */
export const QUEUED_STATUSES = set("pending", "queued");
/** A turn is in flight: queued or running. The composer is busy. */
export const LIVE_STATUSES = set(...RUNNING_STATUSES, ...QUEUED_STATUSES);
/** In flight, or finished its turn with background work still running. */
export const WORKING_STATUSES = set(...LIVE_STATUSES, "waiting_background");
/** PATCH /settings can change the next-turn model. A live turn returns 409. */
export const SETTINGS_IDLE_STATUSES = set("awaiting_user", "acknowledged", "interrupted", "failed", "not_feasible", "paused", "blocked");
/** Ended with an error the user should see. */
export const FAILED_STATUSES = set("failed", "not_feasible", "error", "errored", "timed_out");
/** The turn ended and the conversation waits for the user. */
export const READY_STATUSES = set("awaiting_user", "waiting_user", "waiting_for_user", "needs_input", "awaiting_approval", "acknowledged");
/** Finished its work successfully. */
export const DONE_STATUSES = set("completed", "succeeded");
/** Archived: acknowledged by the user (or auto-archived by Core). */
export const ARCHIVED_STATUSES = set("acknowledged", "archived");
/** Stopped and safe to archive (acknowledge). */
export const ARCHIVABLE_STATUSES = set(
  ...[...READY_STATUSES].filter(s => !ARCHIVED_STATUSES.has(s)),
  ...FAILED_STATUSES,
  ...DONE_STATUSES,
  "blocked",
  "paused",
  "interrupted",
  "cancelled",
);
/** Finished: reopening moves it back to paused for a manual follow-up. */
export const REOPENABLE_STATUSES = set(...DONE_STATUSES, ...FAILED_STATUSES, ...ARCHIVED_STATUSES, "interrupted", "cancelled");

const has = (statuses: ReadonlySet<string>) => (status: Status) => !!status && statuses.has(status);

export const isRunning = has(RUNNING_STATUSES);
export const isQueued = has(QUEUED_STATUSES);
export const isLive = has(LIVE_STATUSES);
export const isWorking = has(WORKING_STATUSES);
export const isArchivable = has(ARCHIVABLE_STATUSES);
export const isArchived = has(ARCHIVED_STATUSES);
export const isReopenable = has(REOPENABLE_STATUSES);
export const isFailedStatus = has(FAILED_STATUSES);
export const isReady = has(READY_STATUSES);
/** Case-insensitive: settings are offered from any casing Core reports. */
export const isSettingsIdle = (status: Status) => SETTINGS_IDLE_STATUSES.has((status ?? "").toLowerCase());

/**
 * The state categories shared with the iOS and Android apps
 * (shared/orb-spec/mission-states.json), in list order: a lower rank sorts first.
 */
export const STATUS_CATEGORIES = ["waiting", "blocked", "failed", "live", "queued", "paused", "stopped", "done", "archived"] as const;
export type StatusCategory = typeof STATUS_CATEGORIES[number] | "unknown";

/** Shared category of a Core status string (case-insensitive). */
export function statusCategory(status: Status): StatusCategory {
  const s = (status ?? "").toLowerCase();
  if (ARCHIVED_STATUSES.has(s)) return "archived";
  if (READY_STATUSES.has(s)) return "waiting";
  if (s === "blocked") return "blocked";
  if (FAILED_STATUSES.has(s)) return "failed";
  if (RUNNING_STATUSES.has(s) || s === "waiting_background") return "live";
  if (QUEUED_STATUSES.has(s)) return "queued";
  if (s === "paused") return "paused";
  if (s === "interrupted" || s === "cancelled") return "stopped";
  if (DONE_STATUSES.has(s)) return "done";
  return "unknown";
}

/** Sort rank of a status: its category's index, unknown statuses last. */
export function statusSortRank(status: Status): number {
  const index = STATUS_CATEGORIES.indexOf(statusCategory(status) as typeof STATUS_CATEGORIES[number]);
  return index < 0 ? STATUS_CATEGORIES.length : index;
}

/** The run ended for good: failed or completed (not paused, stopped or waiting). */
export const isTerminalStatus = (status: Status) => ["failed", "done"].includes(statusCategory(status));

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
    case "completed": case "succeeded": return { label: "Completed", tone: "success", icon: "check" };
    case "failed": case "error": case "errored": return { label: "Failed", tone: "attention", icon: "alert" };
    case "timed_out": return { label: "Timed out", tone: "attention", icon: "alert" };
    case "not_feasible": return { label: "Not feasible", tone: "attention", icon: "alert" };
    case "interrupted": case "cancelled": return { label: "Interrupted", tone: "quiet", icon: "pause" };
    case "idle": return { label: "Idle", tone: "quiet", icon: null };
    default: return { label: status || "Unknown status", tone: "quiet", icon: null };
  }
}

/* ── One answer to "is this mission working?" ─────────────────────────── */

/** A follow-up the user sent now (or promoted from the queue) that has not
 * started its turn yet. `at` is when it was sent (ms). */
export type Handoff = { id: string; at: number };

/** After this long the real mission state shows again, whatever happened. */
export const HANDOFF_TIMEOUT_MS = 30_000;

/** Statuses a send-now handoff passes through: the stopped old turn and the
 * not-yet-started new one. A failure is never masked. */
const HANDOFF_STATUSES = set("interrupted", "cancelled", "paused", ...READY_STATUSES, "completed", "idle", "");

const [handoffs, setHandoffs] = createSignal<Readonly<Record<string, Handoff>>>({});

/** Start a handoff for `mission`: every surface (sidebar, Stop button, Working
 * row, banner) keeps reading "working" until the new turn starts, the message
 * is withdrawn, or {@link HANDOFF_TIMEOUT_MS} passes. */
export function beginHandoff(mission: string, id: string, at = Date.now()): void {
  setHandoffs(all => ({ ...all, [mission]: { id, at } }));
  setTimeout(() => endHandoff(mission, id), HANDOFF_TIMEOUT_MS + 50);
}

/** End `mission`'s handoff (only the one for message `id`, when given). */
export function endHandoff(mission: string, id?: string): void {
  setHandoffs(all => {
    const current = all[mission];
    if (!current || (id && current.id !== id)) return all;
    const next = { ...all };
    delete next[mission];
    return next;
  });
}

export const missionHandoff = (mission: string | null | undefined): Handoff | null => (mission ? handoffs()[mission] ?? null : null);

export function handoffPending(status: Status, handoff: Handoff | null | undefined, now = Date.now()): boolean {
  if (!handoff || now - handoff.at >= HANDOFF_TIMEOUT_MS || now < handoff.at - 1000) return false;
  return HANDOFF_STATUSES.has((status ?? "").toLowerCase());
}

export type ActivityReason = "running" | "queued" | "starting" | "stopping" | "handoff" | "idle" | "failed" | "needs_you";
export type MissionActivity = { working: boolean; reason: ActivityReason; label?: string };

type ActivityJob = { phase?: string | null; node_state?: string | null; node_id?: string | null; lease_state?: string | null; terminal_reason?: string | null; finished_at?: string | null; exit_code?: number | null } | null | undefined;
type ActivityQueueWait = { reason?: string; slots_used?: number; slots_max?: number } | null | undefined;
type ActivityMission = { id?: string; status?: string | null; remote_node_id?: string | null; remote_job?: ActivityJob; queue_wait?: ActivityQueueWait; execution?: { state?: string | null } | null } | null | undefined;
type ActivityItem = { kind: string; queued?: boolean };

/** "Waiting for a free slot (1/1 in use)" while Core has no parallel slot for a pending mission. */
export function queueWaitLabel(mission: { status?: string | null; queue_wait?: ActivityQueueWait } | null | undefined): string | null {
  const wait = mission?.queue_wait;
  if (!isQueued(mission?.status) || wait?.reason !== "waiting_for_slot") return null;
  return wait.slots_max ? `Waiting for a free slot (${wait.slots_used ?? wait.slots_max}/${wait.slots_max} in use)` : "Waiting for a free slot";
}

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
 * - A pending mission waiting for a Core parallel slot says so, with usage.
 */
export function missionActivity(mission: ActivityMission, items: readonly ActivityItem[] = [], opts: { localRun?: boolean; needsYou?: boolean; nodeName?: (id: string) => string; handoff?: Handoff | null; now?: number } = {}): MissionActivity {
  if (opts.localRun) return { working: true, reason: "running" };
  if (!mission) return { working: false, reason: "idle" };
  const status = mission.status ?? "";
  const job = mission.remote_job;
  if (opts.needsYou && !isFailedStatus(status)) return { working: false, reason: "needs_you" };
  // Send now = stop, then a new turn. Between the two the mission briefly reads
  // `interrupted` (or idle) and its old job ends: that is the handoff, not a stop.
  const handoff = opts.handoff !== undefined ? opts.handoff : missionHandoff(mission.id);
  if (handoffPending(status, handoff, opts.now)) return { working: true, reason: "handoff", label: "Sending" };
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
  if (isQueued(status)) {
    const label = queueWaitLabel(mission);
    return label ? { working: true, reason: "queued", label } : { working: true, reason: "queued" };
  }
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

/**
 * Single execution-derived phase label for `MissionPending` and `WorkingRow`.
 * Reports `"Starting <Harness>"` while startup is unconfirmed (`destination_starting`
 * transfer, `status === "starting"`, or host CLI startup before first output),
 * and `"Working"` once execution or output is confirmed.
 */
export function executionPhaseLabel(
  mission: (ActivityMission & { backend?: string | null; tags?: readonly string[] | null }) | null | undefined,
  opts: {
    activity?: boolean;
    handoff?: boolean;
    stopping?: boolean;
    transferStarting?: boolean;
  } = {},
): string {
  if (opts.handoff) return "Sending";
  if (opts.stopping) return "Stopping the current turn…";
  if (mission?.remote_job?.node_state === "queued") return "Waiting for a free slot";
  const slotWait = queueWaitLabel(mission);
  if (slotWait) return slotWait;
  const backend = mission?.backend?.trim();
  const harness = backend ? harnessName(backend).replace(/\s+CLI$/, "") : "";
  const remoteConfirmedRunning = mission?.remote_job?.node_state === "running";
  const isTransferred = !!mission?.tags?.some(tag => tag.startsWith("fork-of:"));
  if (!opts.activity) {
    if (opts.transferStarting || mission?.status === "starting" || (isTransferred && !remoteConfirmedRunning)) {
      return harness ? `Starting ${harness}` : "Starting";
    }
    if ((backend === "opencode" || backend === "claudecode") && !remoteConfirmedRunning && !mission?.remote_job) {
      return `Starting ${harness}`;
    }
  }
  return "Working";
}
