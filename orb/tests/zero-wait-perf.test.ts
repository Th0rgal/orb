import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  bootstrapDesktopRuntime,
  clearConnection,
  getApiUrl,
  getJwt,
  getMission,
  setConnection,
  setTransportBridgeEnabled,
} from "../src/api";
import { resetDesktopPrefsForTest } from "../src/desktopPrefs";
import {
  consumeMissionOpenQueue,
  forgetPrefetchPauses,
  hydrateTranscriptFromDisk,
  loadTranscript,
  peekTranscript,
  putTranscript,
  transcriptVersion,
} from "../src/missionCache";
import { cacheReset } from "../src/pageCache";
import {
  clearPersistentCache,
  HOT_PERSISTED_TRANSCRIPTS,
  loadPersistedSidebar,
  loadPersistedTranscript,
  MAX_PERSISTED_TRANSCRIPTS,
  savePersistedSidebar,
  savePersistedTranscript,
} from "../src/persistentCache";
import {
  resetMissionOpenCapabilityForTest,
  setMultiplexSyncEnabledForTest,
  streamMission,
  type StreamEvent,
} from "../src/stream";

describe("Zero-Wait Conversation Loading & Two-Tier Answer Cache", () => {
  beforeEach(async () => {
    resetMissionOpenCapabilityForTest();
    setMultiplexSyncEnabledForTest(false);
    resetDesktopPrefsForTest();
    forgetPrefetchPauses();
    cacheReset();
    await clearPersistentCache();
    localStorage.clear();
  });

  afterEach(async () => {
    setMultiplexSyncEnabledForTest(false);
    resetMissionOpenCapabilityForTest();
    resetDesktopPrefsForTest();
    forgetPrefetchPauses();
    cacheReset();
    await clearPersistentCache();
    delete (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("retains 250 transcripts with hot-32 full detail and warm-250 spine compaction", async () => {
    expect(HOT_PERSISTED_TRANSCRIPTS).toBe(32);
    expect(MAX_PERSISTED_TRANSCRIPTS).toBe(250);
    const scope = "https://orbcore.thomas.md::zw";
    const bigToolOutput = "T".repeat(2048);

    for (let i = 0; i < 40; i++) {
      await savePersistedTranscript(scope, `m-${i}`, {
        fromLog: true,
        cursor: 3,
        items: [
          { kind: "user", key: `u-${i}`, text: `Prompt ${i}` },
          {
            kind: "work",
            key: `w-${i}`,
            entries: [{ kind: "tool", id: `tc-${i}`, name: "bash", result: bigToolOutput }],
          },
          { kind: "text", key: `a-${i}`, text: `Answer ${i}` },
        ],
        stream: [
          { type: "user_message", sequence: 1, data: { id: `u-${i}`, content: `Prompt ${i}` } },
          { type: "tool_result", sequence: 2, data: { tool_call_id: `tc-${i}`, result: bigToolOutput } },
          { type: "assistant_message", sequence: 3, data: { id: `a-${i}`, content: `Answer ${i}`, success: true } },
        ],
      });
    }

    // Oldest 8 (`m-0`..`m-7`) were compacted into warm spine tier while keeping prompts + answers!
    const warm0 = await loadPersistedTranscript<{
      items: Array<{ kind: string; text?: string; entries?: Array<{ result?: string; truncated?: boolean }> }>;
      stream: Array<{ type: string }>;
    }>(scope, "m-0");
    expect(warm0).not.toBeNull();
    expect(warm0!.stream.map((e) => e.type)).toEqual(["user_message", "assistant_message"]);
    expect(warm0!.items.find((it) => it.kind === "text")?.text).toBe("Answer 0");
    expect(warm0!.items.find((it) => it.kind === "work")?.entries?.[0]?.result?.length).toBe(256);

    // Hot recent entry (`m-39`) retains full 2048-byte tool output!
    const hot39 = await loadPersistedTranscript<{
      stream: Array<{ type: string }>;
      items: Array<{ kind: string; entries?: Array<{ result?: string }> }>;
    }>(scope, "m-39");
    expect(hot39!.stream.map((e) => e.type)).toEqual(["user_message", "tool_result", "assistant_message"]);
    expect(hot39!.items.find((it) => it.kind === "work")?.entries?.[0]?.result?.length).toBe(2048);

    // Sidebar preserves `projectMissions` across partial sidebar saves
    await savePersistedSidebar(scope, {
      missions: [{ id: "m-39" }],
      projects: [{ slug: "core" }],
      projectMissions: { core: [{ id: "m-39" }] },
    });
    await savePersistedSidebar(scope, {
      missions: [{ id: "m-39" }],
      projects: [{ slug: "core" }],
    });
    const sb = await loadPersistedSidebar(scope);
    expect(sb?.projectMissions).toEqual({ core: [{ id: "m-39" }] });
  });

  it("opens a cold conversation in 1 HTTP roundtrip via /open and seeds mission + queue caches", async () => {
    setConnection("http://open-bundle.test", "jwt-open");
    const fetchCalls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        fetchCalls.push(url);
        if (url.includes("/api/control/missions/m-bundle/open")) {
          return new Response(
            JSON.stringify({
              protocol: 1,
              mission: {
                id: "m-bundle",
                title: "Bundled Mission",
                status: "awaiting_user",
                backend: "claudecode",
                project: "core",
                history: [],
                created_at: "2026-11-11T07:00:00Z",
                updated_at: "2026-11-11T07:05:00Z",
              },
              events: [
                {
                  id: 21,
                  sequence: 21,
                  event_id: "a-21",
                  event_type: "assistant_message",
                  content: "Single-RTT answer!",
                  timestamp: "2026-11-11T07:05:00Z",
                },
              ],
              spine: [
                {
                  id: 1,
                  sequence: 1,
                  event_id: "u-1",
                  event_type: "user_message",
                  content: "Initial prompt above 200-tool gap",
                  timestamp: "2026-11-11T07:00:01Z",
                },
              ],
              queue: [{ id: "q-1", content: "Queued next", source: "remote-queue" }],
              max_seq: 21,
              has_more: true,
              next_cursor: 21,
              page_max_seq: 21,
              reset: false,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        throw new Error(`Unexpected extra HTTP call: ${url}`);
      }),
    );

    const snap = await loadTranscript("m-bundle");
    expect(fetchCalls).toHaveLength(1);
    expect(fetchCalls[0]).toContain("/api/control/missions/m-bundle/open?");
    expect(snap.cursor).toBe(21);
    expect(snap.items.some((i) => i.kind === "user" && i.text.includes("Initial prompt"))).toBe(true);
    expect(snap.items.some((i) => i.kind === "text" && i.text.includes("Single-RTT answer!"))).toBe(true);

    // Concurrent/subsequent `getMission` and `RemoteQueue` resolve in 0 extra HTTP requests!
    const mission = await getMission("m-bundle", { coreOnly: true });
    expect(mission.title).toBe("Bundled Mission");
    expect(consumeMissionOpenQueue("m-bundle")).toEqual([
      { id: "q-1", content: "Queued next", source: "remote-queue" },
    ]);
    expect(fetchCalls).toHaveLength(1);
  });

  it("hydrates pre-digested settled turns synchronously (syncBump) and consolidates desktop_bootstrap into 1 IPC", async () => {
    const invoked: string[] = [];
    (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
      invoke: vi.fn(async (cmd: string) => {
        invoked.push(cmd);
        if (cmd === "desktop_bootstrap") {
          return {
            connection: { api_url: "https://orbcore.thomas.md", token: "tok-boot" },
            prefs: { unchanged: false, rev: "r1", exists: true, prefs: { "orb.theme": "dark" } },
            transport: {
              proxy_base_url: "http://127.0.0.1:49111/__orb_tx/t",
              stream_proxy_base_urls: ["http://127.0.0.1:49112/__orb_tx/t"],
              configured_target: "https://orbcore.thomas.md",
            },
          };
        }
        return null;
      }),
    };
    setTransportBridgeEnabled(true);
    await bootstrapDesktopRuntime();
    expect(invoked).toEqual(["desktop_bootstrap"]);
    expect(getApiUrl()).toBe("https://orbcore.thomas.md");
    expect(getJwt()).toBe("tok-boot");
    expect(localStorage.getItem("orb.theme")).toBe("dark");

    // Persist a settled transcript and verify O(1) `settledItems` + `syncBump` frame-0 hydration!
    vi.useFakeTimers();
    putTranscript("m-settled", {
      fromLog: true,
      cursor: 2,
      items: [
        { kind: "user", key: "u1", text: "Hello" },
        { kind: "text", key: "a1", text: "Instant frame-0 reply" },
      ],
      stream: [
        { type: "user_message", sequence: 1, data: { id: "u1", content: "Hello" } },
        { type: "assistant_message", sequence: 2, data: { id: "a1", content: "Instant frame-0 reply", success: true } },
      ],
    });
    await vi.advanceTimersByTimeAsync(3_600);
    vi.useRealTimers();

    forgetPrefetchPauses();
    cacheReset();
    const vBefore = transcriptVersion();
    const hydrated = await hydrateTranscriptFromDisk("m-settled", { syncBump: true });
    expect(transcriptVersion()).toBeGreaterThan(vBefore);
    expect(hydrated?.items).toHaveLength(2);
    expect(hydrated?.settledItems).toHaveLength(2);
    clearConnection({ persist: false });
  });

  it("ingests inbox_answer_push frames into cache and batches rapid tool_call/tool_result bursts into 1 frame", async () => {
    class MockWs {
      static instances: MockWs[] = [];
      readyState = 1;
      onopen: (() => void) | null = null;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(public url: string, public protocols?: string | string[]) {
        MockWs.instances.push(this);
        queueMicrotask(() => this.onopen?.());
      }
      send(_data: string) {}
      close() {
        this.readyState = 3;
      }
    }
    vi.stubGlobal("WebSocket", MockWs as unknown as typeof WebSocket);
    setConnection("http://sync-push.test", "jwt-sync");
    setMultiplexSyncEnabledForTest(true);

    const batches: StreamEvent[][] = [];
    const stop = streamMission(
      "m-focused",
      (ev) => batches.push([ev]),
      () => {},
      undefined,
      undefined,
      (evs) => batches.push(evs),
    );

    await vi.waitFor(() => expect(MockWs.instances).toHaveLength(1));
    const ws = MockWs.instances[0];

    // Push an unsubscribed background Inbox answer
    ws.onmessage?.({
      data: JSON.stringify({
        type: "inbox_answer_push",
        event_type: "assistant_message",
        mission_id: "m-inbox-bg",
        sequence: 9,
        id: "ans-9",
        content: "Cached before user clicked Inbox!",
      }),
    });
    const bgSnap = peekTranscript("m-inbox-bg");
    expect(bgSnap?.items.some((i) => i.kind === "text" && i.text.includes("Cached before user clicked Inbox!"))).toBe(true);

    // Burst 12 tool_call + tool_result frames in < 1 ms -> must coalesce into ONE 16 ms batch!
    for (let k = 0; k < 6; k++) {
      ws.onmessage?.({
        data: JSON.stringify({
          type: "tool_call",
          mission_id: "m-focused",
          sequence: k * 2 + 1,
          tool_call_id: `c-${k}`,
          name: "Bash",
          args: { command: "ls" },
        }),
      });
      ws.onmessage?.({
        data: JSON.stringify({
          type: "tool_result",
          mission_id: "m-focused",
          sequence: k * 2 + 2,
          tool_call_id: `c-${k}`,
          name: "Bash",
          result: "ok",
        }),
      });
    }
    await vi.waitFor(() => expect(batches.length).toBe(1));
    expect(batches[0]).toHaveLength(12);
    stop();
  });
});
