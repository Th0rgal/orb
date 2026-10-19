/**
 * The desktop vocabulary must agree with the state table and fixtures the
 * iOS and Android apps load from shared/orb-spec. Labels are not compared:
 * the desktop keeps its own wording ("Running", "Ready for a follow-up").
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { STATUS_CATEGORIES, isFailedStatus, isTerminalStatus, isWorking, statusCategory, statusPresentation, statusSortRank } from "../src/missionStatus";
import { compactAgo } from "../src/time";

const SPEC_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec");
const spec = <T>(path: string): T => JSON.parse(readFileSync(join(SPEC_DIR, path), "utf8")) as T;

type Flags = { live: boolean; terminal: boolean; needsAttention: boolean; unreadResponse: boolean; canRetry: boolean };
type StateSpec = { label: string; category: string; sortRank: number; flags: Flags };
const states = spec<{ categories: string[]; unknown: { category: string; sortRank: number }; states: Record<string, StateSpec> }>("mission-states.json");
const relative = spec<{ cases: Array<{ secondsAgo: number; expected: string }> }>("fixtures/relative-time.json");

describe("shared/orb-spec/mission-states.json", () => {
  it("has the same categories in the same order", () => {
    expect([...STATUS_CATEGORIES]).toEqual(states.categories);
  });

  for (const [status, s] of Object.entries(states.states)) {
    it(`${status}: category ${s.category}, rank ${s.sortRank}`, () => {
      expect(statusCategory(status)).toBe(s.category);
      expect(statusCategory(status.toUpperCase())).toBe(s.category);
      expect(statusSortRank(status)).toBe(s.sortRank);
      // The shared `live` flag covers queued and running: desktop's isWorking.
      expect(isWorking(status)).toBe(s.flags.live);
      expect(isFailedStatus(status)).toBe(s.category === "failed");
      expect(isTerminalStatus(status)).toBe(s.flags.terminal);
      const tone = statusPresentation(status).tone;
      if (s.category === "blocked" || s.category === "failed") expect(tone).toBe("attention");
      if (s.category === "done") expect(tone).toBe("success");
      if (s.category === "live") expect(tone).toBe("running");
    });
  }

  it("classifies unknown statuses like the mobile apps", () => {
    expect(statusCategory("something_new")).toBe(states.unknown.category);
    expect(statusSortRank("something_new")).toBe(states.unknown.sortRank);
    expect(statusSortRank(undefined)).toBe(states.unknown.sortRank);
    expect(isWorking("something_new")).toBe(false);
  });
});

describe("shared/orb-spec/fixtures/relative-time.json", () => {
  const now = Date.UTC(2026, 9, 18, 12);
  for (const c of relative.cases) {
    it(`${c.secondsAgo} s ago → ${c.expected}`, () => {
      expect(compactAgo(now - c.secondsAgo * 1000, now)).toBe(c.expected);
    });
  }
});
