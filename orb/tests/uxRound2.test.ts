import { describe, it, expect } from "vitest";
import { chaptersOf } from "../src/Chapters";
import { currentStep, formatElapsed, turnStartedAt } from "../src/TurnStatus";
import { applyPendingMoves } from "../src/missionMove";
import { buildTranscript } from "../src/transcriptModel";
import { storedToStream, type StoredEvent } from "../src/stream";

describe("ux round 2", () => {
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
