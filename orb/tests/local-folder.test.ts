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
const { followProjectFolder, isProjectWorkspace, nextTurnFolder, seedDelivered, seededPrompt } = await import("../src/localFolder");
const { rememberBinding } = await import("../src/localAgents");

const ROOT = "/Users/me/.orb/workspaces";
const bind = (cwd: string): LocalBinding => ({ harness: "codex", bin: "/bin/codex", cwd, sessionId: "s1" });

beforeEach(() => {
  localStorage.clear();
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
    const next = await followProjectFolder("m1", "beta");
    expect(next).toEqual({ binding: bind(`${ROOT}/beta`) });
    expect(rememberBinding).toHaveBeenCalledWith("m1", bind(`${ROOT}/beta`));
  });

  it("keeps an explicit folder override", async () => {
    state.bindings.m1 = bind("/Users/me/code/orb");
    expect((await followProjectFolder("m1", "beta"))?.binding.cwd).toBe("/Users/me/code/orb");
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("never changes the folder of a run in progress", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    state.running.add("m1");
    expect((await followProjectFolder("m1", "beta"))?.binding.cwd).toBe(`${ROOT}/alpha`);
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("keeps the folder while follow-ups prepared for it are still queued", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    state.queued = [{ mission: "m1", state: "queued" }];
    expect((await followProjectFolder("m1", "beta"))?.binding.cwd).toBe(`${ROOT}/alpha`);
    state.queued = [{ mission: "m1", state: "accepted" }];
    expect((await followProjectFolder("m1", "beta"))?.binding.cwd).toBe(`${ROOT}/beta`);
  });

  it("does not rebind when a turn starts while the workspace resolves", async () => {
    state.bindings.m1 = bind(`${ROOT}/alpha`);
    const slow = async (slug: string) => { state.running.add("m1"); return `${ROOT}/${slug}`; };
    expect((await followProjectFolder("m1", "beta", slow))?.binding.cwd).toBe(`${ROOT}/alpha`);
    expect(rememberBinding).not.toHaveBeenCalled();
  });

  it("returns undefined without a binding on this computer", async () => {
    expect(await followProjectFolder("missing", "beta")).toBeUndefined();
  });
});

describe("cwd-scoped sessions (Claude Code)", () => {
  const claude = (cwd: string): LocalBinding => ({ harness: "claudecode", bin: "/bin/claude", cwd, sessionId: "claude-session" });
  const events = vi.fn(async () => [
    { id: 1, sequence: 1, event_type: "user_message", timestamp: "", content: "Fix the login bug" },
    { id: 2, sequence: 2, event_type: "thinking", timestamp: "", content: "private" },
    { id: 3, sequence: 3, event_type: "assistant_message", timestamp: "", content: "Fixed in auth.ts" },
  ] as never);
  beforeEach(() => events.mockClear());

  it("starts a fresh session in the new folder, seeded with the conversation", async () => {
    state.bindings.m1 = claude(`${ROOT}/alpha`);
    const next = await followProjectFolder("m1", "beta", undefined, events);
    expect(next?.binding.cwd).toBe(`${ROOT}/beta`);
    expect(next?.binding.sessionId).toBeUndefined();
    expect(state.bindings.m1.sessionId).toBeUndefined();
    expect(next?.seed).toContain(`You now work in ${ROOT}/beta`);
    expect(next?.seed).toContain("User: Fix the login bug");
    expect(next?.seed).toContain("Assistant: Fixed in auth.ts");
    expect(next?.seed).not.toContain("private");
    expect(seededPrompt("next step", next?.seed)).toMatch(/<\/conversation>[\s\S]*\n\nnext step$/);
  });

  it("offers the seed again until the follow-up is queued, then stops", async () => {
    state.bindings.m1 = claude(`${ROOT}/alpha`);
    const first = await followProjectFolder("m1", "beta", undefined, events);
    const again = await followProjectFolder("m1", "beta", undefined, events);
    expect(again?.seed).toBe(first?.seed);
    seedDelivered("m1");
    state.bindings.m1 = { ...state.bindings.m1, sessionId: "fresh" };
    expect((await followProjectFolder("m1", "beta", undefined, events))?.seed).toBeUndefined();
  });

  it("keeps the session when a Claude Code folder does not change", async () => {
    state.bindings.m1 = claude("/Users/me/code/orb");
    const next = await followProjectFolder("m1", "beta", undefined, events);
    expect(next).toEqual({ binding: claude("/Users/me/code/orb") });
    expect(events).not.toHaveBeenCalled();
  });

  it("treats OpenCode the same way and resumes Codex threads as is", async () => {
    state.bindings.o = { harness: "opencode", bin: "/bin/opencode", cwd: `${ROOT}/alpha`, sessionId: "ses_1" };
    const open = await followProjectFolder("o", "beta", undefined, events);
    expect(open?.binding.sessionId).toBeUndefined();
    expect(open?.seed).toBeTruthy();
    state.bindings.c = bind(`${ROOT}/alpha`);
    const codex = await followProjectFolder("c", "beta", undefined, events);
    expect(codex).toEqual({ binding: bind(`${ROOT}/beta`) });
  });
});
