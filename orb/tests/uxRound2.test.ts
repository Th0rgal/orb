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
    expect(currentStep(items)).toBe("Running a command");
    expect(formatElapsed(65_000)).toBe("1 min 05 s");
    expect(formatElapsed(3_700_000)).toBe("1 h 01");
  });
  it("keeps an optimistic move until Core catches up", () => {
    expect(applyPendingMoves([{ id: "m", project: "a" }])).toEqual([{ id: "m", project: "a" }]);
  });
});
import { shortPath } from "../src/Changes";
describe("shortPath", () => {
  it("drops node workspace roots", () => {
    expect(shortPath("/var/lib/sandboxed-node/d2415091-a5e0-4e38-8582-62f6175ed355/honeypot/src/main.rs")).toBe("honeypot/src/main.rs");
    expect(shortPath("/root/.claude/projects/-var-lib-sandboxed-node-d2415091/memory/notes.md")).toBe("memory/notes.md");
    expect(shortPath("src/a.ts")).toBe("src/a.ts");
  });
});

import { toolActivity } from "../src/TurnStatus";
import { it as itActivity, expect as expectActivity } from "vitest";
itActivity("names the kind of work instead of repeating the transcript step", () => {
  expectActivity(toolActivity("Bash")).toBe("Running a command");
  expectActivity(toolActivity("run_command")).toBe("Running a command");
  expectActivity(toolActivity("replace_file_content")).toBe("Editing files");
  expectActivity(toolActivity("Grep")).toBe("Searching");
  expectActivity(toolActivity("view_file")).toBe("Reading files");
  expectActivity(toolActivity("WebFetch")).toBe("Browsing");
  expectActivity(toolActivity("mcp__sandboxed__get_mission_events")).toBe("Working");
});
