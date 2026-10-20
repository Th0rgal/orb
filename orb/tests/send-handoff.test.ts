import { afterEach, describe, expect, it, vi } from "vitest";
import { HANDOFF_TIMEOUT_MS, beginHandoff, endHandoff, handoffPending, missionActivity, missionHandoff } from "../src/missionStatus";
import { createHandoffTracker } from "../src/mission/handoff";

afterEach(() => { vi.useRealTimers(); endHandoff("m"); });
const t0 = 1_000_000;
const handoff = { id: "msg", at: t0 };

describe("missionActivity during a Send now handoff", () => {
  it("reads the stop between the old and the new turn as one working handoff", () => {
    for (const status of ["interrupted", "awaiting_user", "cancelled"]) {
      expect(missionActivity({ status }, [], { handoff, now: t0 + 800 })).toEqual({ working: true, reason: "handoff", label: "Sending" });
    }
    // The old job ending (node says cancelled) is not a failure while handing off.
    expect(missionActivity({ status: "interrupted", remote_job: { phase: "finished", node_state: "cancelled" } }, [], { handoff, now: t0 + 800 }).reason).toBe("handoff");
  });
  it("never masks a failure, and shows the real state after the timeout", () => {
    expect(missionActivity({ status: "failed" }, [], { handoff, now: t0 + 800 })).toMatchObject({ working: false, reason: "failed" });
    expect(missionActivity({ status: "interrupted" }, [], { handoff, now: t0 + HANDOFF_TIMEOUT_MS })).toMatchObject({ working: false });
    expect(handoffPending("interrupted", handoff, t0 + HANDOFF_TIMEOUT_MS - 1)).toBe(true);
  });
  it("leaves running turns alone", () => {
    expect(missionActivity({ status: "active" }, [], { handoff, now: t0 })).toEqual({ working: true, reason: "running" });
  });
  it("is shared by every surface through the mission id, and expires on its own", () => {
    vi.useFakeTimers();
    vi.setSystemTime(t0);
    beginHandoff("m", "msg");
    expect(missionActivity({ id: "m", status: "interrupted" }).reason).toBe("handoff");
    expect(missionActivity({ id: "other", status: "interrupted" }).reason).toBe("idle");
    endHandoff("m", "someone-else");
    expect(missionHandoff("m")?.id).toBe("msg");
    vi.advanceTimersByTime(HANDOFF_TIMEOUT_MS + 100);
    expect(missionHandoff("m")).toBeNull();
    expect(missionActivity({ id: "m", status: "interrupted" }).working).toBe(false);
  });
});

describe("handoff tracker", () => {
  it("ends once the mission was seen stopped and then running again", () => {
    const tracker = createHandoffTracker();
    expect(tracker.observe(handoff, { status: "active", remote_job: { job_id: "old", phase: "running", node_state: "running" } })).toBe(false);
    expect(tracker.observe(handoff, { status: "interrupted", remote_job: { job_id: "old", phase: "finished", node_state: "cancelled" } })).toBe(false);
    expect(tracker.observe(handoff, { status: "active", remote_job: { job_id: "new", phase: "running", node_state: "running" } })).toBe(true);
  });
  it("ends when a new job runs even if the stop was never observed", () => {
    const tracker = createHandoffTracker();
    tracker.observe(handoff, { status: "active", remote_job: { job_id: "old", phase: "running", node_state: "running" } });
    expect(tracker.observe(handoff, { status: "active", remote_job: { job_id: "old", phase: "running", node_state: "running" } })).toBe(false);
    expect(tracker.observe(handoff, { status: "active", remote_job: { job_id: "new", phase: "running", node_state: "queued" } })).toBe(true);
  });
  it("ends at once on a failure", () => {
    expect(createHandoffTracker().observe(handoff, { status: "failed" })).toBe(true);
  });
});
