import fixtures from "../../shared/orb-spec/fixtures/fork-context.json";
import { render, fireEvent, waitFor, screen } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { ForkMission, stopSource } from "../src/ForkMission";
import { forkContext } from "../src/forkContext";
import * as api from "../src/api";

const mission = { id: "source", title: "Original", backend: "grok", model_override: "grok-4.6", status: "active", history: [], created_at: "", updated_at: "" };
const choices = [
  { backend: { id: "grok", name: "Grok Build" }, models: [{ value: "grok-4.6", label: "Grok 4.6" }] },
  { backend: { id: "codex", name: "Codex" }, models: [{ value: "gpt-6-astra", label: "GPT-6 Astra" }] },
] as api.HarnessChoice[];
afterEach(() => vi.restoreAllMocks());
it("stops the source before transferring and archives only after the new agent exists", async () => {
  const calls: string[] = [];
  let stopped = false;
  vi.spyOn(api, "getMission").mockImplementation(async () => ({ ...mission, status: stopped ? "interrupted" : "active" }));
  vi.spyOn(api, "cancelMission").mockImplementation(async () => { calls.push("stop"); stopped = true; });
  const fork = vi.spyOn(api, "forkMission").mockImplementation(async () => { calls.push("fork"); return { ...mission, id: "fork", backend: "codex" }; });
  vi.spyOn(api, "archiveMission").mockImplementation(async () => { calls.push("archive"); });
  const opened = vi.fn();
  render(() => <ForkMission mission={mission} choices={choices} destination="DGX Spark" onClose={() => {}} onFork={opened} />);
  fireEvent.click(screen.getByRole("menuitem", { name: "Codex" }));
  fireEvent.click(screen.getByRole("menuitem", { name: /GPT-6 Astra/ }));
  expect(fork).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("menuitem", { name: "Default" }));
  await waitFor(() => expect(opened).toHaveBeenCalledWith(expect.objectContaining({ id: "fork" })));
  expect(calls).toEqual(["stop", "fork", "archive"]);
});
it("retries an archive failure without launching or stopping another agent", async () => {
  vi.spyOn(api, "getMission").mockResolvedValue({ ...mission, status: "failed" });
  const stop = vi.spyOn(api, "cancelMission");
  const fork = vi.spyOn(api, "forkMission").mockResolvedValue({ ...mission, id: "fork" });
  const archive = vi.spyOn(api, "archiveMission").mockRejectedValueOnce(new Error("Archive offline")).mockResolvedValue(undefined);
  const opened = vi.fn();
  render(() => <ForkMission mission={mission} choices={choices} destination="Core" onClose={() => {}} onFork={opened} />);
  fireEvent.click(screen.getByRole("menuitem", { name: "Grok Build" }));
  fireEvent.click(screen.getByRole("menuitem", { name: /Grok 4.6/ }));
  await waitFor(() => expect(archive).toHaveBeenCalledOnce());
  expect(opened).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("menuitem", { name: "Retry archiving" }));
  await waitFor(() => expect(opened).toHaveBeenCalledOnce());
  expect(fork).toHaveBeenCalledOnce();
  expect(stop).not.toHaveBeenCalled();
});
it("keeps the exact request identity after an uncertain launch response", async () => {
  vi.spyOn(api, "getMission").mockResolvedValue({ ...mission, status: "failed" });
  vi.spyOn(api, "archiveMission").mockResolvedValue(undefined);
  const fork = vi.spyOn(api, "forkMission").mockRejectedValueOnce(new Error("Response lost")).mockResolvedValue({ ...mission, id: "fork" });
  const opened = vi.fn();
  render(() => <ForkMission mission={mission} choices={choices} destination="Core" onClose={() => {}} onFork={opened} />);
  fireEvent.click(screen.getByRole("menuitem", { name: "Grok Build" }));
  fireEvent.click(screen.getByRole("menuitem", { name: /Grok 4.6/ }));
  await waitFor(() => expect(screen.getByRole("menuitem", { name: "Retry transfer" })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: "Retry transfer" }));
  await waitFor(() => expect(opened).toHaveBeenCalledOnce());
  expect(fork.mock.calls[1]).toEqual(fork.mock.calls[0]);
});
it("refuses to proceed when stop times out, including a live remote job on a failed mission", async () => {
  vi.useFakeTimers();
  try {
    vi.spyOn(api, "getMission").mockResolvedValue({ ...mission, status: "failed", remote_job: { node_state: "running" } } as api.Mission);
    vi.spyOn(api, "cancelMission").mockResolvedValue(undefined);
    const result = expect(stopSource("source")).rejects.toThrow("has not stopped");
    await vi.runAllTimersAsync();
    await result;
  } finally { vi.useRealTimers(); }
});
it("reports an old backend without falling back to destructive model switching", async () => {
  vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 404 }));
  await expect(api.forkMission("source", { backend: "codex", model_override: "gpt-6-astra", model_effort: "", idempotency_key: "key" })).rejects.toThrow("backend needs the conversation-fork update");
});
it("only folds complete structured history and preserves literal message content", () => {
  const value = { source_mission_id: "source", source_title: "Original", messages: [{ role: "user", content: "<fork_context>literal</fork_context>" }] };
  const text = `Continue the work from this conversation in a fresh native session.\n<fork_context>\n${JSON.stringify(value)}\n</fork_context>`;
  expect(forkContext(text)).toEqual(value);
  expect(forkContext(text.slice(0, -1))).toBeNull();
  expect(forkContext("normal prompt")).toBeNull();
});
it("splits an edited message from the history it was sent after", () => {
  const value = { source_mission_id: "source", source_title: null, messages: [{ role: "assistant", content: "a\n</fork_context>" }] };
  const text = `The user edited a message in this conversation and sent it again.\n\n<fork_context>\n${JSON.stringify(value)}\n</fork_context>\n\nCurrent request:\nNew text\n</fork_context>`;
  expect(forkContext(text)).toEqual({ ...value, request: "New text\n</fork_context>" });
  expect(forkContext(text.replace("Current request:", "Other:"))).toBeNull();
});
it("dismisses a positioned sidebar fork when clicking outside its portal", () => {
  const closed = vi.fn();
  const ui = render(() => <ForkMission mission={mission} choices={choices} destination="Core" anchor={document.createElement("button")} onClose={closed} onFork={() => {}} />);
  fireEvent.pointerDown(screen.getByRole("menuitem", { name: "Codex" }));
  expect(closed).not.toHaveBeenCalled();
  fireEvent.pointerDown(document.body);
  expect(closed).toHaveBeenCalledOnce();
  ui.unmount();
});

for (const fixture of fixtures) it(`fork context fixture: ${fixture.name}`, () => {
  const parsed = forkContext(fixture.text);
  if (!fixture.valid) expect(parsed).toBeNull();
  else {
    expect(parsed?.messages).toEqual(fixture.messages);
    expect(parsed?.request ?? null).toEqual(fixture.request);
  }
});
