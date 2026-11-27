import { describe, expect, it } from "vitest";
import { GOAL_HARNESSES, HARNESSES, REMOTE_PROXY_HARNESSES, SIDE_QUESTION_HARNESSES, harnessName, isHarness } from "../src/harnesses";
import { normalizeEffort, supportedEfforts } from "../src/effort";
import { CWD_SCOPED_SESSIONS } from "../src/localFolder";

describe("Pi harness desktop wiring (#2258)", () => {
  it("registers Pi with goal, proxy, side-question, and cwd-scoped session support", () => {
    expect(isHarness("pi")).toBe(true);
    expect(harnessName("pi")).toBe("Pi");
    const entry = HARNESSES.find((h) => h.id === "pi");
    expect(entry).toEqual({ id: "pi", name: "Pi", goal: true, remoteNeedsProxy: true });
    expect(GOAL_HARNESSES.has("pi")).toBe(true);
    expect(REMOTE_PROXY_HARNESSES.has("pi")).toBe(true);
    expect(SIDE_QUESTION_HARNESSES).toContain("pi");
    expect(CWD_SCOPED_SESSIONS.has("pi")).toBe(true);
  });

  it("supports Pi thinking levels matching Core MissionSettings", () => {
    expect(supportedEfforts("pi")).toEqual(["low", "medium", "high", "xhigh"]);
    expect(normalizeEffort("high", "pi")).toBe("high");
    expect(normalizeEffort("xhigh", "pi")).toBe("xhigh");
    expect(normalizeEffort("max", "pi")).toBeNull();
  });
});
