import { expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { Transcript } from "../src/Transcript";
import { applyStreamEvent, buildTranscript, visibleTranscript } from "../src/transcriptModel";
import { storedToStream, type StreamEvent } from "../src/stream";

const cancelled = (sequence: number) => storedToStream({
  id: sequence, sequence, event_id: `cancel-${sequence}`, event_type: "assistant_message",
  timestamp: "", content: "Cancelled", metadata: { success: false, resumable: true },
})!;
const resume = (id: string, queued = false): StreamEvent => ({
  type: "user_message", data: { id, content: "You were interrupted, resume your work.", queued },
});

it("replays repeated cancellations with only the current attempt's notice visible", () => {
  const events = [cancelled(49), resume("first"), cancelled(76)];
  const items = buildTranscript(events);
  const { container } = render(() => <Transcript items={items} />);
  expect(container.textContent?.match(/Mission cancelled/g)).toHaveLength(1);
  expect(container.textContent).not.toContain("Mission failed");
  expect(items.filter(item => item.kind === "error")).toHaveLength(2);

  const resumed = applyStreamEvent(items, resume("second"));
  expect(visibleTranscript(resumed).filter(item => item.kind === "error")).toHaveLength(0);
  expect(resumed).toEqual(buildTranscript([...events, resume("second")]));
});

it("dismisses the notice live only when a queued follow-up is delivered", () => {
  const [items, setItems] = createSignal(buildTranscript([cancelled(49)]));
  const { container } = render(() => <Transcript items={items()} />);
  setItems(items => applyStreamEvent(items, resume("retry", true)));
  expect(container.textContent).toContain("Mission cancelled");
  setItems(items => applyStreamEvent(items, resume("retry")));
  expect(container.textContent).not.toContain("Mission cancelled");
});

it("preserves diagnostic errors and labels actual failures correctly", () => {
  const items = buildTranscript([
    { type: "error", data: { message: "Transport unavailable" } },
    resume("retry"),
    { type: "assistant_message", data: { success: false, content: "Build failed" } },
  ]);
  const { container } = render(() => <Transcript items={items} />);
  expect(container.textContent).toContain("Transport unavailable");
  expect(container.textContent).toContain("Mission failed");
  expect(container.textContent).toContain("Build failed");
});

it("renders a local failure below the prompt using the red notice, without a yellow banner", async () => {
  const { LaunchStatus, MissionFailure } = await import("../src/missionLaunch");
  const mission = {status:"failed",terminal_reason:"client_runner"} as import("../src/api").Mission;
  const {container}=render(()=><><LaunchStatus destination="This computer" mission={mission}/><Transcript items={[{kind:"user",key:"u",text:"My prompt"}]}/><MissionFailure mission={mission} error="The local transport was rejected"/></>);
  expect(container.querySelector('.launch-status')).toBeNull();
  const error=container.querySelector('.error-notice')!;
  expect(error.textContent).toContain('The local transport was rejected');
  expect(container.querySelector('.user')!.compareDocumentPosition(error)&Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});
it("does not duplicate a failure already in the transcript and renders Resume inside the transcript error card",async()=>{
 const {MissionFailure}=await import("../src/missionLaunch");
 let resumed = 0;
 const {container}=render(()=><><Transcript items={[{kind:"user",key:"u",text:"My prompt"},{kind:"error",key:"e",text:"CLI error: Antigravity ended without a SUCCESS result; resume this conversation before retrying work"}]} onResume={()=>{resumed++;}}/><MissionFailure mission={{status:"failed"} as import("../src/api").Mission} failureInTranscript onResume={()=>{resumed++;}}/></>);
 const cards=container.querySelectorAll('.error-notice');
 expect(cards).toHaveLength(1);
 const btn=cards[0].querySelector('.error-notice-actions .error-notice-link') as HTMLButtonElement | null;
 expect(btn?.textContent).toBe('Resume');
 btn?.click();
 expect(resumed).toBe(1);
});

it("surfaces stored mission_status_changed failure summaries instead of generic remote dispatch failed", async () => {
  const { MissionFailure } = await import("../src/missionLaunch");
  const events = [
    storedToStream({
      id: 1, sequence: 1, event_id: "u-1", event_type: "user_message",
      timestamp: "", content: "Large prompt", metadata: {},
    })!,
    storedToStream({
      id: 2, sequence: 2, event_id: "s-2", event_type: "mission_status_changed",
      timestamp: "", content: "Antigravity prompts must be at most 16 KiB; put large context in workspace files",
      metadata: { status: "failed", summary: "Antigravity prompts must be at most 16 KiB; put large context in workspace files" },
    })!,
    storedToStream({
      id: 3, sequence: 3, event_id: "s-3", event_type: "mission_status_changed",
      timestamp: "", content: "",
      metadata: { status: "failed", summary: null },
    })!,
  ];
  const items = buildTranscript(events);
  const visible = visibleTranscript(items);
  const failureInTranscript = visible.some(item => item.kind === "error" && !item.resumable && !item.diagnostic);
  expect(failureInTranscript).toBe(true);
  const mission = { status: "failed", terminal_reason: "remote_dispatch_failed" } as import("../src/api").Mission;
  const { container } = render(() => (
    <>
      <Transcript items={items} />
      <MissionFailure mission={mission} failureInTranscript={failureInTranscript} />
    </>
  ));
  const cards = container.querySelectorAll(".error-notice");
  expect(cards).toHaveLength(1);
  expect(cards[0].textContent).toContain("Antigravity prompt exceeds 16 KiB");
  expect(cards[0].textContent).toContain("Antigravity prompts must be at most 16 KiB; put large context in workspace files");
  expect(cards[0].textContent).not.toContain("remote dispatch failed");
});

