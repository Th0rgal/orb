import { describe, expect, it } from "vitest";
import { turnAgo, turnDate, turnTiming, workedFor } from "../src/turnTiming";

const end = Date.parse("2026-10-16T05:30:00Z");
describe("turnTiming", () => {
  it("measures from the turn start to completion", () => {
    expect(turnTiming("2026-10-15T17:24:00Z", "2026-10-16T05:30:00Z")).toEqual({ completedAt: end, workedMs: (12 * 60 + 6) * 60_000 });
  });
  it("keeps the completion time when the start is missing, invalid or later", () => {
    expect(turnTiming(undefined, end)).toEqual({ completedAt: end });
    expect(turnTiming("nope", end)).toEqual({ completedAt: end });
    expect(turnTiming(end + 1, end)).toEqual({ completedAt: end });
  });
  it("has nothing to show without a completion", () => {
    expect(turnTiming(end, undefined)).toBeUndefined();
    expect(turnTiming(end, "bad")).toBeUndefined();
  });
});
describe("turnAgo", () => {
  it("steps from just now through minutes, hours and days", () => {
    expect(turnAgo(end, end + 59_000)).toBe("just now");
    expect(turnAgo(end, end - 5_000)).toBe("just now");
    expect(turnAgo(end, end + 5 * 60_000)).toBe("5m ago");
    expect(turnAgo(end, end + 2 * 3600_000 + 59 * 60_000)).toBe("2h ago");
    expect(turnAgo(end, end + 6 * 86_400_000)).toBe("6d ago");
  });
  it("falls back to a short date after a month", () => {
    expect(turnAgo(end, end + 40 * 86_400_000, "en-US")).toBe("Oct 16");
    expect(turnAgo(end, Date.parse("2027-02-01T00:00:00Z"), "en-US")).toBe("Oct 16, 2026");
  });
});
describe("formatting", () => {
  it("prints the absolute local time", () => {
    expect(turnDate(end, "en-US", "UTC")).toBe("Oct 16, 2026, 5:30 AM");
  });
  it("prints compact durations", () => {
    expect(workedFor(42_000)).toBe("42s");
    expect(workedFor(185_000)).toBe("3m 5s");
    expect(workedFor(120_000)).toBe("2m");
    expect(workedFor((12 * 60 + 6) * 60_000)).toBe("12h 6m");
    expect(workedFor(51 * 3600_000)).toBe("2d 3h");
    expect(workedFor(-5)).toBe("0s");
  });
});

import { buildTranscript } from "../src/transcriptModel";
import { storedToStream } from "../src/stream";
describe("completion time in the transcript", () => {
  it("stamps the final text with the stored assistant_message time, not streaming text", () => {
    const row = (sequence: number, event_type: string, content: string, timestamp: string) => storedToStream({ id: sequence, sequence, event_type, content, timestamp })!;
    const items = buildTranscript([
      row(1, "user_message", "Go", "2026-10-16T05:00:00Z"),
      row(2, "text_delta", "Working", "2026-10-16T05:10:00Z"),
      row(3, "assistant_message", "Done", "2026-10-16T05:30:00Z"),
    ]);
    const text = items.find(i => i.kind === "text");
    expect(text).toMatchObject({ text: "Done", live: false, at: "2026-10-16T05:30:00Z" });
    expect(buildTranscript([row(1, "user_message", "Go", "x"), row(2, "text_delta", "Working", "y")]).find(i => i.kind === "text")).toMatchObject({ live: true });
  });
});
