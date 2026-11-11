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
