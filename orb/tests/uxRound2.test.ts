import { describe, it, expect } from "vitest";
import { changedFiles, prLink } from "../src/Changes";
import { chaptersOf } from "../src/Chapters";
import { currentStep, formatElapsed, turnStartedAt } from "../src/TurnStatus";
import { applyPendingMoves } from "../src/missionMove";
import { buildTranscript } from "../src/transcriptModel";
import { storedToStream, type StoredEvent } from "../src/stream";

describe("ux round 2", () => {
  it("parses free-form github_pr values", () => {
    expect(prLink("https://github.com/Th0rgal/orb/pull/1132")).toEqual({ label: "Th0rgal/orb#1132", url: "https://github.com/Th0rgal/orb/pull/1132" });
    expect(prLink("lfglabs-dev/verity#2526")?.url).toBe("https://github.com/lfglabs-dev/verity/pull/2526");
    expect(prLink("42")).toEqual({ label: "PR 42" });
    expect(prLink("")).toBeNull();
  });
  it("aggregates edits per file", () => {
    const items = buildTranscript([
      { type: "tool_call", data: { tool_call_id: "a", name: "Edit", args: { file_path: "/r/a.ts", old_string: "x", new_string: "x\ny" } } },
      { type: "tool_result", data: { tool_call_id: "a", name: "Edit", result: "ok" } },
      { type: "tool_call", data: { tool_call_id: "b", name: "Edit", args: { file_path: "/r/a.ts", old_string: "q", new_string: "" } } },
      { type: "tool_result", data: { tool_call_id: "b", name: "Edit", result: "ok" } },
    ]);
    expect(changedFiles(items)).toEqual([{ file: "/r/a.ts", additions: 1, deletions: 1, edits: 2 }]);
  });
  it("derives chapters, turn start and current step", () => {
    const stored: StoredEvent = { id: 1, sequence: 1, event_type: "user_message", timestamp: "2026-10-18T12:00:00Z", content: "Fix the   build please", event_id: "u1" };
    const items = buildTranscript([storedToStream(stored)!, { type: "tool_call", data: { tool_call_id: "t", name: "Bash", args: { command: "make check" } } }]);
    expect(chaptersOf(items)).toEqual([{ key: "user:u1", title: "Fix the build please" }]);
    expect(turnStartedAt(items)).toBe(Date.parse("2026-10-18T12:00:00Z"));
    expect(currentStep(items)).toMatch(/^Bash/);
    expect(formatElapsed(65_000)).toBe("1 min 05 s");
    expect(formatElapsed(3_700_000)).toBe("1 h 01");
  });
  it("keeps an optimistic move until Core catches up", () => {
    expect(applyPendingMoves([{ id: "m", project: "a" }])).toEqual([{ id: "m", project: "a" }]);
  });
});
