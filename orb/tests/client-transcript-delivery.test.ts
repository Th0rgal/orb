import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection, type Mission } from "../src/api";
import {
  deliverAssistantText,
  enqueueClientLinkFrame,
  flushClientLink,
  resetClientLinkStateForTest,
} from "../src/clientLink";
import { withInitialPrompt } from "../src/missionLaunch";
import { reconcileLocalOriginEvents } from "../src/mission/MissionView";

describe("client-placed mission transcript delivery & reconciliation", () => {
  beforeEach(() => {
    resetClientLinkStateForTest();
    setConnection("http://core.test", "test-token");
  });

  afterEach(() => {
    resetClientLinkStateForTest();
    clearConnection();
    delete (window as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("posts assistant client-transcript when client_link never carried frames for the mission", async () => {
    const invoke = vi.fn(async (cmd: string) => {
      // Simulate older orb-locald returning true when connected with 0 unacked frames
      if (cmd === "client_link_flush") return true;
      return null;
    });
    (window as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__ = { core: { invoke } };

    const posted: Array<{ url: string; body: unknown }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        posted.push({ url, body: init?.body ? JSON.parse(String(init.body)) : null });
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      }),
    );

    expect(await flushClientLink("1f3b3ec7-df65-4f77-b30a-47fbda627623")).toBe(false);
    await deliverAssistantText(
      "1f3b3ec7-df65-4f77-b30a-47fbda627623",
      "Implemented, verified, committed, and pushed.",
      { run_id: "d94a8d6b-683c-4d2b-8134-cd6383a07d84", generation: 2 },
      "00000006-1f3b-4ec7-8f77-47fbda627623",
    );

    expect(posted).toHaveLength(1);
    expect(posted[0].url).toContain("/api/control/missions/1f3b3ec7-df65-4f77-b30a-47fbda627623/client-transcript");
    expect(posted[0].body).toMatchObject({
      id: "00000006-1f3b-4ec7-8f77-47fbda627623",
      role: "assistant",
      content: "Implemented, verified, committed, and pushed.",
      run_id: "d94a8d6b-683c-4d2b-8134-cd6383a07d84",
      generation: 2,
    });
  });

  it("skips duplicate HTTP client-transcript when client_link carried and drained frames for the mission", async () => {
    const invoke = vi.fn(async (cmd: string, args?: { action?: string }) => {
      if (cmd === "client_link_flush" && args?.action === "enqueue") {
        return { seq: 1, unacked_count: 1, last_acked_seq: 0, head_seq: 1 };
      }
      if (cmd === "client_link_flush") return true;
      return null;
    });
    (window as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__ = { core: { invoke } };

    const fetchSpy = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchSpy);

    await enqueueClientLinkFrame("m-carried", { delta: "hi" });
    await deliverAssistantText("m-carried", "hi", { run_id: "r1", generation: 1 }, "ev-1");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("retains multi-turn mission.history when event log is empty after awaiting settles", () => {
    const m: Mission = {
      id: "local-1",
      title: "Local",
      status: "awaiting_user",
      history: [
        { role: "user", content: "Check local missions" },
        { role: "assistant", content: "Here are the 5 active sessions." },
      ],
      created_at: "2026-11-26T08:41:32Z",
      updated_at: "2026-11-26T08:45:00Z",
    };
    const rendered = withInitialPrompt([], m, undefined, false);
    expect(rendered.map((i) => `${i.kind}:${"text" in i ? i.text : ""}`)).toEqual([
      "user:Check local missions",
      "text:Here are the 5 active sessions.",
    ]);
  });

  it("reconciles local-origins history when Core stream only recorded follow-up user_message rows", () => {
    const localHistory: Mission["history"] = [
      { role: "user", content: "Turn 1 prompt" },
      { role: "assistant", content: "Turn 1 reply" },
      { id: "u2", role: "user", content: "Turn 2 prompt" },
      { role: "assistant", content: "Turn 2 reply" },
      { id: "u3", role: "user", content: "Turn 3 prompt" },
      { role: "assistant", content: "Turn 3 reply" },
    ];
    const brokenRemoteStream = [
      { type: "user_message" as const, eventId: "u2", sequence: 1, data: { id: "u2", content: "Turn 2 prompt" } },
      { type: "user_message" as const, eventId: "u3", sequence: 2, data: { id: "u3", content: "Turn 3 prompt" } },
      { type: "user_message" as const, eventId: "u3", sequence: 3, data: { id: "u3", content: "Turn 3 prompt" } },
    ];

    const merged = reconcileLocalOriginEvents("1f3b3ec7", brokenRemoteStream, localHistory);
    expect(merged?.map((e) => `${e.type}:${e.data?.content}`)).toEqual([
      "user_message:Turn 1 prompt",
      "assistant_message:Turn 1 reply",
      "user_message:Turn 2 prompt",
      "assistant_message:Turn 2 reply",
      "user_message:Turn 3 prompt",
      "assistant_message:Turn 3 reply",
    ]);

    const completeRemoteStream = merged!.map((e, i) => ({ ...e, sequence: i + 1 }));
    expect(reconcileLocalOriginEvents("1f3b3ec7", completeRemoteStream, localHistory)).toBeNull();
  });
});
