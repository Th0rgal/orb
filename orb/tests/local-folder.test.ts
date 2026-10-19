import { beforeEach, describe, expect, it, vi } from "vitest";
import type { LocalBinding } from "../src/localAgents";

const state = vi.hoisted(() => ({
  bindings: {} as Record<string, LocalBinding>,
  running: new Set<string>(),
  queued: [] as Array<{ mission: string; state: string }>,
}));
vi.mock("../src/localAgents", () => ({
  localBinding: (id: string) => state.bindings[id],
  localRunActive: (id: string) => state.running.has(id),
  localWorkspace: async (slug: string) => `/Users/me/.orb/workspaces/${slug}`,
  rememberBinding: vi.fn(async (id: string, binding: LocalBinding) => { state.bindings[id] = binding; }),
}));
vi.mock("../src/localMessageQueue", () => ({
  queuedLocalMessages: (mission: string) => state.queued.filter(row => row.mission === mission),
}));
const { followProjectFolder, isProjectWorkspace, nextTurnFolder } = await import("../src/localFolder");
const { rememberBinding } = await import("../src/localAgents");

const ROOT = "/Users/me/.orb/workspaces";
const bind = (cwd: string): LocalBinding => ({ harness: "codex", bin: "/bin/codex", cwd, sessionId: "s1" });

beforeEach(() => {
  state.bindings = {}; state.running.clear(); state.queued = [];
  vi.mocked(rememberBinding).mockClear();
});

describe("nextTurnFolder", () => {
  it("follows the new project when the old folder was a project workspace", () => {
    expect(nextTurnFolder(`${ROOT}/alpha`, `${ROOT}/beta`)).toBe(`${ROOT}/beta`);
    expect(nextTurnFolder(`${ROOT}/alpha/`, `${ROOT}/beta`)).toBe(`${ROOT}/beta`);
  });
  it("keeps an explicitly chosen folder", () => {
    expect(nextTurnFolder("/Users/me/code/orb", `${ROOT}/beta`)).toBe("/Users/me/code/orb");
    expect(nextTurnFolder(`${ROOT}/alpha/sub`, `${ROOT}/beta`)).toBe(`${ROOT}/alpha/sub`);
    expect(isProjectWorkspace("/", `${ROOT}/beta`)).toBe(false);
  });
  it("keeps the folder when the project did not change", () => {
    expect(nextTurnFolder(`${ROOT}/beta`, `${ROOT}/beta`)).toBe(`${ROOT}/beta`);
  });
});

describe("followProjectFolder", () => {
  it("rebinds a moved mission to the new project's workspace and keeps its session", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    const binding = await followProjectFolder("m1", "beta");
    expect(binding).toEqual({ ...bind(`${ROOT}/beta`) });
    expect(rememberBinding).toHaveBeenCalledWith("m1", bind(`${ROOT}/beta`));
  });

  it("keeps an explicit folder override", async () => {
    state.bindings.m1 = bind("/Users/me/code/orb");
    expect((await followProjectFolder("m1", "beta"))?.cwd).toBe("/Users/me/code/orb");
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("never changes the folder of a run in progress", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    state.running.add("m1");
    expect((await followProjectFolder("m1", "beta"))?.cwd).toBe(`${ROOT}/alpha`);
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("keeps the folder while follow-ups prepared for it are still queued", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    state.queued = [{ mission: "m1", state: "queued" }];
    expect((await followProjectFolder("m1", "beta"))?.cwd).toBe(`${ROOT}/alpha`);
    state.queued = [{ mission: "m1", state: "accepted" }];
    expect((await followProjectFolder("m1", "beta"))?.cwd).toBe(`${ROOT}/beta`);
  });

  it("does not rebind when a turn starts while the workspace resolves", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    const slow = async (slug: string) => { state.running.add("m1"); return `${ROOT}/${slug}`; };
    expect((await followProjectFolder("m1", "beta", slow))?.cwd).toBe(`${ROOT}/alpha`);
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("returns undefined without a binding on this computer", async () => {
    expect(await followProjectFolder("missing", "beta")).toBeUndefined();
  });
});
