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
