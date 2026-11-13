import { describe, expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { MissionGlyph } from "../src/MissionGlyph";
import { isSettledStatus, missionActivity, missionPresentation, presentedStatus } from "../src/missionStatus";
import type { Mission } from "../src/api";
import type { ContinuationSummary } from "../src/continuations";

const continuation: ContinuationSummary = { count: 1, items: [{ id: "ldgr-wake", state: "scheduled", trigger: "time", next_at: "2026-11-12T23:30:00Z" }] };
const finished = { job_id: "turn", node_id: "ashur", phase: "finished", node_state: "succeeded", exit_code: 0 };
const base = { id: "ldgr", status: "active", title: "ldgr", history: [] } as Mission;

describe("mission status truth event replay", () => {
  it("does not turn green between turn end, child end and wakeup delivery", () => {
    const [mission, update] = createSignal<Mission>(base);
    const view = render(() => <MissionGlyph status={presentedStatus(mission())} continuation={mission().continuation} />);
    const replay: [Partial<Mission>, string][] = [
      [{ continuation }, "active"],
      [{ status: "completed", remote_job: finished, live_children_count: 1 }, "waiting_background"],
      [{ live_children_count: 0 }, "awaiting_wakeup"],
      [{ status: "awaiting_user", terminal_reason: "awaiting_wakeup" }, "awaiting_wakeup"],
      [{ status: "completed", terminal_reason: "completed" }, "awaiting_wakeup"],
    ];
    for (const [event, expected] of replay) {
      update(m => ({ ...m, ...event }));
      expect(presentedStatus(mission())).toBe(expected);
      expect(isSettledStatus(presentedStatus(mission()))).toBe(false);
      expect(view.container.querySelector(".mission-glyph.success")).toBeNull();
      expect(missionPresentation(mission()).tone).not.toBe("success");
    }
    update(m => ({ ...m, continuation: null }));
    expect(presentedStatus(mission())).toBe("completed");
    expect(view.container.querySelector(".mission-glyph.success")).not.toBeNull();
  });

  it.each([
    { status: "awaiting_user", terminal_reason: "awaiting_wakeup" },
    { status: "completed", execution: { terminal_reason: "awaiting_wakeup" } },
    { status: "completed", continuation: { count: 1, items: [] } },
    { status: "active", continuation, remote_job: finished },
    { status: "completed", terminal_reason: "awaiting_wakeup", remote_job: { ...finished, terminal_reason: "awaiting_wakeup" } },
  ])("keeps pending work when the job end arrives first: %j", facts => {
    const mission = { ...base, ...facts };
    expect(presentedStatus(mission)).toBe("awaiting_wakeup");
    expect(missionActivity(mission).working).toBe(false);
  });

  it("shows the known wake-up time without expiring overdue work on the client", () => {
    const shown = missionPresentation({ ...base, status: "completed", continuation });
    expect(shown.label).toBe(`Wake-up scheduled for ${new Date(continuation.items[0].next_at!).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}`);
    expect(shown.tone).toBe("scheduled");
  });

  it("does not animate the parent's startup row for running children", () => {
    const mission = { ...base, status: "completed", live_children_count: 1, remote_job: finished };
    expect(presentedStatus(mission)).toBe("waiting_background");
    expect(missionActivity(mission).working).toBe(false);
    expect(missionPresentation(mission).tone).toBe("running");
  });

  it("distinguishes user input, completion, failure and actual execution", () => {
    expect(missionPresentation({ ...base, status: "awaiting_user" }).tone).toBe("quiet");
    expect(missionPresentation({ ...base, status: "completed" }).tone).toBe("success");
    expect(missionPresentation({ ...base, status: "failed", continuation }).tone).toBe("attention");
    expect(missionPresentation({ ...base, continuation }).tone).toBe("running");
  });
});
