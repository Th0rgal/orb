import { beforeEach, expect, it, vi } from "vitest";

const choices = [
  { backend: { id: "codex", name: "Codex" }, models: [{ value: "gpt", label: "GPT" }] },
  { backend: { id: "claudecode", name: "Claude Code" }, models: [{ value: "fable", label: "Fable" }, { value: "opus", label: "Opus" }] },
];
vi.mock("../src/api", async original => ({ ...await original<typeof import("../src/api")>(), listHarnessChoices: vi.fn(async () => choices) }));
beforeEach(() => { vi.resetModules(); localStorage.clear(); });

it("has no pick until the catalog is known", async () => {
  const { effectivePick } = await import("../src/harnessPick");
  expect(effectivePick()).toBeNull();
});

it("falls back to Claude Code's first model, then keeps an explicit pick", async () => {
  const pick = await import("../src/harnessPick");
  await pick.refreshHarnessChoices();
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "fable" });
  pick.setHarnessPick({ backend: "codex", model: "gpt", effort: "high" });
  expect(JSON.parse(localStorage.getItem("orb.harnessPick")!)).toMatchObject({ backend: "codex" });
  expect(pick.effectivePick()?.backend).toBe("codex");
});

it("drops a stored effort the harness never accepted", async () => {
  localStorage.setItem("orb.harnessPick", JSON.stringify({ backend: "claudecode", model: "opus", effort: "not-a-level" }));
  const pick = await import("../src/harnessPick");
  await pick.refreshHarnessChoices();
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "opus", effort: undefined });
});

it("ignores an unreadable stored pick", async () => {
  localStorage.setItem("orb.harnessPick", "{broken");
  const pick = await import("../src/harnessPick");
  await pick.refreshHarnessChoices();
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "fable" });
});

it("migrates retired claude-fable-5-1 stored picks to the harness default while keeping explicit Fable 5.2 / Mythos 5.2 picks", async () => {
  const apiMod = await import("../src/api");
  vi.mocked(apiMod.listHarnessChoices).mockResolvedValueOnce([
    {
      backend: { id: "claudecode", name: "Claude Code" },
      models: [
        { value: "claude-opus-5-5", label: "Claude Opus 5.5" },
        { value: "claude-fable-5-2", label: "Claude Fable 5.2" },
        { value: "claude-mythos-5-2", label: "Claude Mythos 5.2" },
      ],
    },
  ]);
  localStorage.setItem("orb.harnessPick", JSON.stringify({ backend: "claudecode", model: "claude-fable-5-1", effort: "xhigh" }));
  const pick = await import("../src/harnessPick");
  await pick.refreshHarnessChoices();
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "claude-opus-5-5", effort: "xhigh" });

  pick.setHarnessPick({ backend: "claudecode", model: "claude-fable-5-2", effort: "max" });
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "claude-fable-5-2", effort: "max" });

  pick.setHarnessPick({ backend: "claudecode", model: "claude-mythos-5-2", effort: "high" });
  expect(pick.effectivePick()).toEqual({ backend: "claudecode", model: "claude-mythos-5-2", effort: "high" });
});

it("bounds refreshNodeAntigravityModels retries with backoff instead of looping every 15s forever", async () => {
  vi.useFakeTimers();
  try {
    const apiMod = await import("../src/api");
    const spy = vi.spyOn(apiMod, "listNodeAntigravityModels").mockRejectedValue(
      new apiMod.ApiError(502, "remote node unreachable"),
    );
    const pick = await import("../src/harnessPick");

    await pick.refreshNodeAntigravityModels("ashur");
    expect(spy).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(15_000);
    expect(spy).toHaveBeenCalledTimes(2);

    await vi.advanceTimersByTimeAsync(45_000);
    expect(spy).toHaveBeenCalledTimes(3);

    await vi.advanceTimersByTimeAsync(120_000);
    expect(spy).toHaveBeenCalledTimes(4);

    // After the 3 bounded retries (initial + 3 retries = 4 calls), no infinite polling continues:
    await vi.advanceTimersByTimeAsync(600_000);
    expect(spy).toHaveBeenCalledTimes(4);
  } finally {
    vi.useRealTimers();
  }
});

it("maps Core-scoped OpenCode model picks (e.g. builtin/fast) to local provider IDs on this computer without mutating Core's pick", async () => {
  (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
    invoke: vi.fn(async (cmd: string) => {
      if (cmd === "local_agents_scan") {
        return [{ id: "opencode", bin: "opencode", path: "/usr/local/bin/opencode", installed: true, plan_supported: true }];
      }
      if (cmd === "local_opencode_models") {
        return [
          ["orbrouter/builtin/smart", "Routing — Smart"],
          ["orbrouter/builtin/fast", "Routing — Fast"],
        ];
      }
      return [];
    }),
  };
  const apiMod = await import("../src/api");
  vi.mocked(apiMod.listHarnessChoices).mockResolvedValueOnce([
    {
      backend: { id: "opencode", name: "OpenCode", native_plan: true },
      models: [
        { value: "builtin/smart", label: "Routing — smart" },
        { value: "builtin/fast", label: "Routing — fast" },
      ],
    },
  ]);
  localStorage.setItem("orb.harnessPick", JSON.stringify({ backend: "opencode", model: "builtin/fast" }));
  const localMod = await import("../src/localAgents");
  await localMod.refreshLocalAgents(true);
  await new Promise(r => setTimeout(r, 10));
  const pick = await import("../src/harnessPick");
  await pick.refreshHarnessChoices();
  expect(pick.effectivePick("local")).toEqual({ backend: "opencode", model: "orbrouter/builtin/fast", effort: undefined });
  expect(pick.effectivePick("core")).toEqual({ backend: "opencode", model: "builtin/fast", effort: undefined });
  delete (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
});
