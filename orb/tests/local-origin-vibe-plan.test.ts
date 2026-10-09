import { expect, it, vi } from "vitest";

vi.mock("../src/localWakeups", () => ({ replayLocalWakeupStops: vi.fn(async () => {}) }));

it.each([
  { prompt: "/plan Inspect the change", planMode: true },
  { prompt: "Implement the change", planMode: false },
  // An idempotent replay can return a mission whose mode has since changed.
  { prompt: "/plan Inspect the change", planMode: false },
])("refreshes the native origin binding without resetting mode ($prompt, $planMode)", async ({ prompt, planMode }) => {
  vi.resetModules();
  const { startLocalOrigin, localBinding } = await import("../src/localAgents");
  const host = window as any;
  const previousTauri = host.__TAURI__, previousInternals = host.__TAURI_INTERNALS__;
  const binding = { harness: "vibe", bin: "vibe-acp", cwd: "/work", planMode, sessionId: "native-session" };
  const invoke = vi.fn(async (command: string, args?: any) => {
    if (command === "local_origin_launch") return { id: "local-origin", backend: "vibe", working_directory: "/work" };
    if (command === "local_bindings_subscribe") {
      args.onEvent.onmessage({ revision: 0, bindings: {} });
      return 1;
    }
    if (command === "local_bindings_refresh") return { revision: 1, bindings: { "local-origin": binding } };
    if (command === "local_agents_poll") return { done: true, text: "", resumed: true };
    if (command === "local_binding_set") throw Error("Must retain the native binding");
    return 1;
  });
  host.__TAURI__ = { core: { Channel: class { onmessage = (_value: unknown) => {}; } } };
  host.__TAURI_INTERNALS__ = { invoke };
  try {
    await startLocalOrigin({ harness: "vibe", bin: "vibe-acp", cwd: "/work", prompt },
      { key: "draft", title: "test", project: "test", prompt, tags: [] });
    expect(localBinding("local-origin")).toEqual(binding);
    expect(invoke.mock.calls.some(([command]) => command === "local_binding_set")).toBe(false);
  } finally {
    window.dispatchEvent(new Event("pagehide"));
    host.__TAURI__ = previousTauri;
    host.__TAURI_INTERNALS__ = previousInternals;
  }
});
