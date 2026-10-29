import { cleanup, fireEvent, render, screen } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Mission } from "../src/api";
import { classifyProcessLaunchFailure, describeError, isNonResumableError } from "../src/ErrorNotice";
import { MissionFailure } from "../src/missionLaunch";
import { executionPhaseLabel } from "../src/missionStatus";
import { storedToStream } from "../src/stream";
import { Transcript } from "../src/Transcript";
import { buildTranscript, visibleTranscript, type StreamItem } from "../src/transcriptModel";
import { TurnRecap } from "../src/TurnRecap";
import * as inboxDigest from "../src/inboxDigest";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const OPENCODE_E2BIG =
  "/srv/sandboxed-storage/workspaces/mission-86d91cc3/.sandboxed-sh-opencode-cmd.sh: 2: opencode: Argument list too long";

describe("process-launch failure classification & recovery", () => {
  it("labels OpenCode E2BIG distinctly from model errors and explains backend update vs direct continuation", () => {
    const info = classifyProcessLaunchFailure(OPENCODE_E2BIG, "opencode");
    expect(info).toMatchObject({
      kind: "arg_list_too_long",
      nonResumable: true,
      title: "OpenCode could not start",
    });
    expect(info?.message).toContain("exceeded the system command-line limit");
    expect(info?.message).toContain("Update the backend");
    expect(info?.message).toContain("without transferring again");
    expect(info?.message).toContain("original conversation");
    expect(isNonResumableError(OPENCODE_E2BIG, "opencode")).toBe(true);
  });

  it("classifies missing binaries and spawn permission failures per harness without affecting inference errors", () => {
    expect(describeError("zsh: command not found: claude", "Mission failed", "claudecode")).toMatchObject({
      title: "Claude Code could not start",
      nonResumable: true,
    });
    expect(describeError("Failed to start Codex CLI: Permission denied (os error 13)", "Mission failed", "codex")).toMatchObject({
      title: "Codex could not start",
      nonResumable: true,
    });
    expect(describeError("Model error", "Mission failed", "opencode").message).not.toContain("Model error");
    expect(isNonResumableError("Our servers are experiencing high traffic right now", "opencode")).toBe(false);
  });
});

describe("single failure card invariant across event orderings", () => {
  const userEv = storedToStream({
    id: 1,
    sequence: 1,
    event_id: "u-1",
    event_type: "user_message",
    timestamp: "",
    content: "Continue transferred conversation",
    metadata: {},
  })!;
  const statusFailedEv = storedToStream({
    id: 2,
    sequence: 2,
    event_id: "s-2",
    event_type: "mission_status_changed",
    timestamp: "",
    content: "Model error",
    metadata: { status: "failed", summary: "Model error" },
  })!;
  const assistantFailedEv = storedToStream({
    id: 3,
    sequence: 3,
    event_id: "a-3",
    event_type: "assistant_message",
    timestamp: "",
    content: OPENCODE_E2BIG,
    metadata: { success: false },
  })!;
  const stderrEv = { type: "error" as const, data: { message: "opencode: Argument list too long" } };

  it.each([
    ["status_then_assistant", [userEv, statusFailedEv, assistantFailedEv]],
    ["assistant_then_status", [userEv, assistantFailedEv, statusFailedEv]],
    ["stderr_then_status_then_assistant", [userEv, stderrEv, statusFailedEv, assistantFailedEv]],
  ])("renders exactly one actionable launch-failure card for %s", (_name, events) => {
    const items = buildTranscript(events);
    const errors = visibleTranscript(items).filter(i => i.kind === "error");
    expect(errors).toHaveLength(1);
    expect(errors[0].kind === "error" && errors[0].text).toBe(OPENCODE_E2BIG);

    const openSource = vi.fn();
    const resume = vi.fn();
    const failedMission: Mission = {
      id: "d65744b9",
      title: "Transferred",
      backend: "opencode",
      model_override: "builtin/smart",
      status: "failed",
      status_message: "Model error",
      tags: ["fork-of:86d91cc3"],
      history: [],
      created_at: "",
      updated_at: "2026-10-29T00:00:00Z",
    };

    const { container } = render(() => (
      <>
        <Transcript
          backend={failedMission.backend}
          items={items}
          onResume={resume}
          onOpenSource={openSource}
        />
        <MissionFailure
          mission={failedMission}
          onResume={resume}
          onOpenSource={openSource}
          failureInTranscript={visibleTranscript(items).some(i => i.kind === "error")}
        />
      </>
    ));

    const cards = container.querySelectorAll(".error-notice");
    expect(cards).toHaveLength(1);
    expect(cards[0].textContent).toContain("OpenCode could not start");
    expect(cards[0].textContent).not.toContain("Model error");
    expect(screen.queryByRole("button", { name: "Resume" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Open original conversation" }));
    expect(openSource).toHaveBeenCalledOnce();
    expect(resume).not.toHaveBeenCalled();
  });
});

describe("unified executionPhaseLabel & TurnRecap", () => {
  it("reports Starting <Harness> until startup is confirmed, then Working", () => {
    const transferred: Mission = {
      id: "d65744b9",
      title: "Transferred",
      backend: "opencode",
      status: "active",
      tags: ["fork-of:86d91cc3"],
      history: [],
      created_at: "",
      updated_at: "",
    };
    expect(executionPhaseLabel(transferred, { activity: false, transferStarting: true })).toBe("Starting OpenCode");
    expect(executionPhaseLabel(transferred, { activity: false })).toBe("Starting OpenCode");
    expect(executionPhaseLabel(transferred, { activity: true })).toBe("Working");
    expect(
      executionPhaseLabel(
        { ...transferred, remote_job: { node_state: "running" } } as Mission,
        { activity: false, transferStarting: false },
      ),
    ).toBe("Working");
    expect(
      executionPhaseLabel(
        { ...transferred, remote_job: { node_state: "queued" } } as Mission,
        { activity: false },
      ),
    ).toBe("Waiting for a free slot");
  });

  it("never renders WAITING or follow-up suggestion chips on a failed launch or failed turn", () => {
    const updatedAt = "2026-10-29T02:00:00Z";
    const updatedMs = Date.parse(updatedAt);
    vi.spyOn(inboxDigest, "getCachedInboxDigest").mockReturnValue({
      missionId: "d65744b9",
      updatedMs,
      schemaVersion: 7,
      verdict: "waiting",
      outcome: "Cached v7 summary",
      suggestions: ["Run test suite", "Deploy now"],
    } as ReturnType<typeof inboxDigest.getCachedInboxDigest>);

    const failedMission: Mission = {
      id: "d65744b9",
      title: "Transferred",
      backend: "opencode",
      status: "failed",
      history: [],
      created_at: updatedAt,
      updated_at: updatedAt,
    };

    // Error-only turn (launch failure): TurnRecap does not render at all.
    const launchFailItems: StreamItem[] = [
      { kind: "user", key: "u", text: "Prompt" },
      { kind: "error", key: "e", text: OPENCODE_E2BIG, terminal: true },
    ];
    const first = render(() => <TurnRecap mission={failedMission} items={launchFailItems} busy={false} onDraft={() => {}} />);
    expect(first.container.querySelector(".turn-recap")).toBeNull();
    first.unmount();

    // Turn with partial prose that ended in failure: header says Failed, never Waiting, and hides suggestion chips.
    const partialFailItems: StreamItem[] = [
      { kind: "user", key: "u", text: "Prompt" },
      { kind: "text", key: "t", text: "Started checking...", live: false },
      { kind: "error", key: "e", text: "Network timeout", terminal: true },
    ];
    const second = render(() => <TurnRecap mission={failedMission} items={partialFailItems} busy={false} onDraft={() => {}} />);
    expect(second.container.querySelector(".turn-recap-head")?.textContent).toBe("Failed");
    expect(second.container.textContent).not.toContain("Waiting");
    expect(second.container.querySelectorAll(".turn-recap-actions button")).toHaveLength(0);
    second.unmount();
  });
});
