import { describe, expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { missionActivity, presentedStatus, statusPresentation } from "../src/missionStatus";
import { Transcript } from "../src/Transcript";
import type { StreamItem } from "../src/transcriptModel";

const user: StreamItem = { kind: "user", key: "u1", text: "Fix it", messageId: "u1" };
const error: StreamItem = { kind: "error", key: "e1", text: "Remote dispatch failed", terminal: true };
// fe28bb77: status stuck pending after a failed recovery dispatch.
const stuckPending = { status: "pending", remote_node_id: "ashur", remote_job: { phase: "finished", node_state: "failed", terminal_reason: "remote_dispatch_failed" } };
// bc3d61e2: remote opencode on dgx-spark-admin, job running, no output yet.
const remoteRunning = { status: "active", remote_node_id: "dgx-spark-admin", remote_job: { phase: "running", node_state: "running", node_id: "dgx-spark-admin" } };

describe("missionActivity", () => {
  it.each([
    ["repro fe28bb77: finished job with terminal reason", stuckPending, [user, error], { working: false, reason: "failed" }],
    ["repro bc3d61e2: remote job running, no output", remoteRunning, [user], { working: true, reason: "running" }],
    ["finished job, status still active", { status: "active", remote_job: { phase: "finished" } }, [user], { working: false, reason: "idle" }],
    ["terminal lease", { status: "active", remote_job: { phase: "running", lease_state: "expired" } }, [user], { working: false, reason: "idle" }],
    ["error after last user, no live job", { status: "active" }, [user, error], { working: false, reason: "failed" }],
    ["error before last user does not end the new turn", { status: "active" }, [error, user], { working: true, reason: "running" }],
    ["node queue", { status: "active", remote_job: { phase: "accepted", node_state: "queued", node_id: "ashur" } }, [user], { working: true, reason: "queued", label: "Waiting for a free slot on ashur" }],
    ["stopping", { status: "active", execution: { state: "stopping" } }, [user], { working: true, reason: "stopping" }],
    ["starting", { status: "starting" }, [user], { working: true, reason: "starting" }],
    ["core queue", { status: "pending" }, [user], { working: true, reason: "queued" }],
    ["awaiting user", { status: "awaiting_user" }, [user], { working: false, reason: "idle" }],
    ["blocked", { status: "blocked" }, [user], { working: false, reason: "needs_you" }],
    ["failed", { status: "failed" }, [user], { working: false, reason: "failed" }],
  ] as const)("%s", (_name, mission, items, expected) => {
    expect(missionActivity(mission, items as unknown as StreamItem[])).toEqual(expected);
  });
  it("a local run on this computer is working", () => {
    expect(missionActivity({ status: "awaiting_user" }, [], { localRun: true }).working).toBe(true);
  });
});

describe("sidebar and transcript agree", () => {
  it.each([["fe28bb77", stuckPending, [user, error]], ["bc3d61e2", remoteRunning, [user]]] as const)("%s", (_id, mission, items) => {
    const state = missionActivity(mission, items as unknown as StreamItem[]);
    const sidebarSpinner = statusPresentation(presentedStatus(mission, state)).tone === "running";
    const view = render(() => <Transcript items={items as unknown as StreamItem[]} working={state.working} />);
    const workingRow = !!view.container.querySelector(".st-working");
    expect(sidebarSpinner).toBe(state.working);
    expect(workingRow).toBe(state.working);
  });
});
