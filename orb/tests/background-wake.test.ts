import { describe, expect, it } from "vitest";
import { backgroundWake } from "../src/backgroundWake";

// Verbatim from mission e19e93c0.
const killed = "Background task `bjikajbtt` (`until timeout 20 ssh th0rgal@100.77.4.93 'test -f ~/work/x/exit.json'; do sleep 60; done; grep -nE \"^error|: error|✖\" build.log | head -30`) finished. Output:\n\n```\n\n\n[killed]\n```\n\nContinue from here.";

describe("backgroundWake", () => {
  it("recognizes the coordinator's wake, including legacy events without a source", () => {
    const wake = backgroundWake(killed)!;
    expect(wake.task).toBe("bjikajbtt");
    expect(wake.command).toContain("until timeout 20 ssh");
    expect(wake.killed).toBe(true);
    expect(backgroundWake(killed, "background-task")?.task).toBe("bjikajbtt");
  });
  it("keeps output, missing output and the watcher-timeout note", () => {
    expect(backgroundWake("Background task `b1` (`make`) finished. Output:\n\n```\nok\n```\n\nContinue from here.")).toMatchObject({ output: "ok", killed: false, note: "" });
    expect(backgroundWake("Background task `b2` (`make`) finished. (No captured output was available.) (reported finished after the 30-minute watcher timeout; it may still be running.)\n\nContinue from here.")).toMatchObject({ output: "", note: "reported finished after the 30-minute watcher timeout; it may still be running." });
    expect(backgroundWake("Background task `b3` (`make`) finished. Output:\n\n```\nok\n```\n\n(Note: reported as finished after the 30-minute watcher timeout; it may still be running.)\n\nContinue from here.")?.note).toBe("reported as finished after the 30-minute watcher timeout; it may still be running.");
  });
  it("leaves what a person wrote alone", () => {
    expect(backgroundWake("Background task `b1` (`make`) finished. Output:\n\n```\nok\n```\n\nContinue from here.", "api:thomas")).toBeNull();
    expect(backgroundWake("Background task `b1` finished, can you check it?")).toBeNull();
  });
});
