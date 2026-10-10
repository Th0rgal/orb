import { beforeEach, expect, it, vi } from "vitest";
const write = vi.hoisted(() => vi.fn());
vi.mock("../src/inboxState", () => ({ writeInboxState: write }));
beforeEach(() => { localStorage.clear(); write.mockClear(); });
it("seeds empty Core preferences from existing settings and imports existing remote choices without echoing", async () => {
  const { inboxConfig, saveInboxConfig, applySharedInboxPreferences } = await import("../src/inboxSettings");
  const local = { aiSummary: false, includeAutonomous: true, model: "builtin/fast" };
  saveInboxConfig(local, false);
  applySharedInboxPreferences(undefined);
  expect(inboxConfig()).toEqual(local);
  expect(write).toHaveBeenCalledWith("preferences", local);
  write.mockClear();
  const remote = { aiSummary: true, includeAutonomous: false, model: "builtin/reasoning" };
  applySharedInboxPreferences(remote);
  expect(inboxConfig()).toEqual(remote);
  expect(write).not.toHaveBeenCalled();
});
