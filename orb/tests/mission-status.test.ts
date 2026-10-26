import { expect, it } from "vitest";
import { isArchivable, isFailedStatus, isLive, isQueued, isReopenable, isRunning, isSettingsIdle, isWorking, missionActivity, queueWaitLabel, statusPresentation } from "../src/missionStatus";

const STATUSES = ["active", "running", "starting", "resuming", "pending", "queued", "waiting_background", "awaiting_user", "waiting_user", "acknowledged", "blocked", "paused", "completed", "failed", "not_feasible", "interrupted", "cancelled"] as const;
// status:   running queued live working archivable reopenable failed settingsIdle label
const TABLE: Record<(typeof STATUSES)[number], [boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, string]> = {
  active:             [true,  false, true,  true,  false, false, false, false, "Running"],
  running:            [true,  false, true,  true,  false, false, false, false, "Running"],
  starting:           [true,  false, true,  true,  false, false, false, false, "Running"],
  resuming:           [true,  false, true,  true,  false, false, false, false, "Running"],
  pending:            [false, true,  true,  true,  false, false, false, false, "Queued"],
  queued:             [false, true,  true,  true,  false, false, false, false, "Queued"],
  waiting_background: [false, false, false, true,  false, false, false, false, "Background work running"],
  awaiting_user:      [false, false, false, false, true,  false, false, true,  "Ready for a follow-up"],
  waiting_user:       [false, false, false, false, false, false, false, false, "Ready for a follow-up"],
  acknowledged:       [false, false, false, false, false, true,  false, true,  "Ready for a follow-up"],
  blocked:            [false, false, false, false, true,  false, false, true,  "Blocked"],
  paused:             [false, false, false, false, true,  false, false, true,  "Paused"],
  completed:          [false, false, false, false, true,  true,  false, false, "Completed"],
  failed:             [false, false, false, false, true,  true,  true,  true,  "Failed"],
  not_feasible:       [false, false, false, false, false, false, true,  false, "Not feasible"],
  interrupted:        [false, false, false, false, true,  true,  false, true,  "Interrupted"],
  cancelled:          [false, false, false, false, true,  true,  false, false, "Interrupted"],
};

it.each(STATUSES)("%s", status => {
  const [running, queued, live, working, archivable, reopenable, failed, idle, label] = TABLE[status];
  expect([isRunning(status), isQueued(status), isLive(status), isWorking(status), isArchivable(status), isReopenable(status), isFailedStatus(status), isSettingsIdle(status), statusPresentation(status).label])
    .toEqual([running, queued, live, working, archivable, reopenable, failed, idle, label]);
});

it("treats missing and unknown statuses as idle", () => {
  for (const status of [null, undefined, "", "mystery"]) expect([isLive(status), isRunning(status), isWorking(status)]).toEqual([false, false, false]);
  expect(isSettingsIdle("AWAITING_USER")).toBe(true);
  expect(statusPresentation("mystery").label).toBe("mystery");
});

it("a pending mission waiting for a Core slot says so instead of a bare Queued", () => {
  const queue_wait = { reason: "waiting_for_slot", slots_used: 1, slots_max: 1, running_mission_ids: ["6d25e770"] };
  expect(queueWaitLabel({ status: "pending", queue_wait })).toBe("Waiting for a free slot (1/1 in use)");
  expect(missionActivity({ status: "pending", queue_wait })).toEqual({ working: true, reason: "queued", label: "Waiting for a free slot (1/1 in use)" });
  // No capacity data, or the mission already started: nothing changes.
  expect(queueWaitLabel({ status: "pending" })).toBeNull();
  expect(queueWaitLabel({ status: "active", queue_wait })).toBeNull();
  expect(missionActivity({ status: "pending" })).toEqual({ working: true, reason: "queued" });
});
