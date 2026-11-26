import { describe, expect, it } from "vitest";
import { mergeProjectedViewItems } from "../src/mission/MissionView";
import type { StreamItem } from "../src/stream";

describe("mergeProjectedViewItems", () => {
  it("places a newly sent follow-up AFTER the previous turn's finished localLiveText when canonical has not synced yet", () => {
    const turn1User: StreamItem = { kind: "user", key: "u1", messageId: "m1", text: "why not agent-backend then?" };
    const turn2User: StreamItem = { kind: "user", key: "user:m2", messageId: "m2", text: "Secret Naming & Hygiene Suggestions -> go ahead" };
    const turn1Reply = "Yes — using https://agent-backend.thomas.md as Paloma's primary.";

    // Turn 1 finished locally (`runActive: false`), its reply is still in `localLiveText`
    // while Core catches up, and the user immediately sent Turn 2 (`projected`).
    const result = mergeProjectedViewItems({
      canonical: [turn1User],
      projected: [turn2User],
      nativeTools: [],
      live: turn1Reply,
      liveKey: "local:rom-polish",
      runActive: false,
      busy: false,
    });

    expect(result.map((i) => ({ kind: i.kind, text: i.kind === "user" || i.kind === "text" ? i.text : "" }))).toEqual([
      { kind: "user", text: turn1User.text },
      { kind: "text", text: turn1Reply },
      { kind: "user", text: turn2User.text },
    ]);
  });

  it("replaces a stale canonical prefix of the finished turn's reply BEFORE appending the new follow-up", () => {
    const turn1User: StreamItem = { kind: "user", key: "u1", messageId: "m1", text: "First question" };
    const turn1Prefix: StreamItem = { kind: "text", key: "t1", text: "Yes — using" };
    const turn2User: StreamItem = { kind: "user", key: "user:m2", messageId: "m2", text: "Follow-up" };
    const turn1Full = "Yes — using https://agent-backend.thomas.md.";

    const result = mergeProjectedViewItems({
      canonical: [turn1User, turn1Prefix],
      projected: [turn2User],
      nativeTools: [],
      live: turn1Full,
      liveKey: "local:rom-polish",
      runActive: false,
      busy: false,
    });

    expect(result.map((i) => ({ kind: i.kind, text: i.kind === "user" || i.kind === "text" ? i.text : "" }))).toEqual([
      { kind: "user", text: "First question" },
      { kind: "text", text: turn1Full },
      { kind: "user", text: "Follow-up" },
    ]);
  });

  it("places live streaming output AFTER the projected follow-up once the new local run is active", () => {
    const turn1User: StreamItem = { kind: "user", key: "u1", messageId: "m1", text: "First question" };
    const turn1Reply: StreamItem = { kind: "text", key: "t1", text: "First reply" };
    const turn2User: StreamItem = { kind: "user", key: "user:m2", messageId: "m2", text: "Follow-up" };

    const result = mergeProjectedViewItems({
      canonical: [turn1User, turn1Reply],
      projected: [turn2User],
      nativeTools: [],
      live: "Starting on Turn 2...",
      liveKey: "local:rom-polish",
      runActive: true,
      busy: true,
    });

    expect(result.map((i) => ({ kind: i.kind, text: i.kind === "user" || i.kind === "text" ? i.text : "" }))).toEqual([
      { kind: "user", text: "First question" },
      { kind: "text", text: "First reply" },
      { kind: "user", text: "Follow-up" },
      { kind: "text", text: "Starting on Turn 2..." },
    ]);
  });
});
