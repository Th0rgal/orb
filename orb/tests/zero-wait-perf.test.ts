import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  bootstrapDesktopRuntime,
  clearConnection,
  getApiUrl,
  getJwt,
  getMission,
  noteMissionMutated,
  seedCachedMission,
  setConnection,
  setTransportBridgeEnabled,
} from "../src/api";
import { resetDesktopPrefsForTest } from "../src/desktopPrefs";
import {
  applyLiveEventsToTranscriptCache,
  consumeMissionOpenQueue,
  flushPendingPersistedTranscripts,
  forgetPrefetchPauses,
  hydrateTranscriptFromDisk,
  isMissionDirtyWhileUnfocused,
  loadTranscript,
  peekTranscript,
  putTranscript,
  refreshTranscript,
  transcriptVersion,
} from "../src/missionCache";
import { buildTranscript } from "../src/transcriptModel";
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
              spine_has_more: true,
              spine_next_cursor: 1,
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
    expect(snap.spineComplete).toBe(false);
    expect(snap.spineBefore).toBe(1);
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

  it("rehydrates settledItems with bound TranscriptReducer, invalidates stale settled digests on mid-turn persistence, and preserves contiguous cursor across gapped inbox_answer_push", async () => {
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
    setConnection("http://rehydrate-gap.test", "jwt-rehydrate");
    setMultiplexSyncEnabledForTest(true);

    const stop = streamMission("m-keep-ws-open", () => {}, () => {});
    await vi.waitFor(() => expect(MockWs.instances).toHaveLength(1));
    const ws = MockWs.instances[0];

    // 1. Seed a settled conversation at cursor = 2 and flush to IndexedDB (`settledItems` populated).
    const initialStream: StreamEvent[] = [
      { type: "user_message", sequence: 1, eventId: "u-1", data: { id: "u-1", content: "Turn 1 prompt" } },
      { type: "assistant_message", sequence: 2, eventId: "a-2", data: { id: "a-2", content: "Turn 1 reply", success: true } },
    ];
    putTranscript("m-gap", {
      fromLog: true,
      cursor: 2,
      items: buildTranscript(initialStream),
      stream: initialStream,
    });
    flushPendingPersistedTranscripts();
    // Wait for IndexedDB write
    await new Promise((r) => setTimeout(r, 25));

    // Evict RAM cache and cold-hydrate from IndexedDB `settledItems`
    forgetPrefetchPauses();
    cacheReset();
    const hydrated = await hydrateTranscriptFromDisk("m-gap");
    expect(hydrated?.settledItems).toHaveLength(2);
    expect(hydrated?.cursor).toBe(2);

    // 2. Receive a gapped `inbox_answer_push` (`sequence: 10`, skipping `3..9` user + tools).
    // Must NOT throw ("Transcript must originate from buildTranscript") AND must keep `cursor === 2`!
    ws.onmessage?.({
      data: JSON.stringify({
        type: "inbox_answer_push",
        event_type: "assistant_message",
        mission_id: "m-gap",
        sequence: 10,
        id: "a-10",
        content: "Turn 2 pushed answer",
      }),
    });
    const afterPush = peekTranscript("m-gap");
    expect(afterPush?.cursor).toBe(2);
    expect(isMissionDirtyWhileUnfocused("m-gap")).toBe(true);
    expect(afterPush?.items.some((i) => i.kind === "text" && i.text.includes("Turn 2 pushed answer"))).toBe(true);

    // Reopening / refreshing calls `/open?since_seq=2` (NOT `since_seq=10`) and backfills `3..10` without duplication!
    const fetchUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        fetchUrls.push(url);
        return new Response(
          JSON.stringify({
            protocol: 1,
            mission: {
              id: "m-gap",
              title: "Gap Mission",
              status: "awaiting_user",
              backend: "claudecode",
              history: [],
              created_at: "2026-11-11T07:00:00Z",
              updated_at: "2026-11-11T07:06:00Z",
            },
            events: [
              { id: 3, sequence: 3, event_id: "u-3", event_type: "user_message", content: "Turn 2 prompt", timestamp: "2026-11-11T07:05:10Z" },
              { id: 4, sequence: 4, event_id: "tc-4", event_type: "tool_call", tool_call_id: "c-4", name: "Bash", args: { command: "pwd" }, timestamp: "2026-11-11T07:05:11Z" },
              { id: 5, sequence: 5, event_id: "tr-5", event_type: "tool_result", tool_call_id: "c-4", name: "Bash", result: "/work", timestamp: "2026-11-11T07:05:12Z" },
              { id: 10, sequence: 10, event_id: "a-10", event_type: "assistant_message", content: "Turn 2 pushed answer", timestamp: "2026-11-11T07:05:20Z" },
            ],
            spine: [],
            queue: [],
            max_seq: 10,
            has_more: false,
            next_cursor: 10,
            page_max_seq: 10,
            reset: false,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );

    const reconciled = await refreshTranscript("m-gap");
    expect(fetchUrls).toHaveLength(1);
    expect(fetchUrls[0]).toContain("since_seq=2");
    expect(reconciled.cursor).toBe(10);
    expect(reconciled.items.some((i) => i.kind === "user" && i.text === "Turn 2 prompt")).toBe(true);
    expect(reconciled.items.some((i) => i.kind === "tool" && i.callId === "c-4")).toBe(true);
    expect(reconciled.items.filter((i) => i.kind === "text" && i.text === "Turn 2 pushed answer")).toHaveLength(1);

    // 3. Persist reconciled settled turn (`settledSeq = 10`), cold-hydrate again, then append a new mid-turn `user_message` (`sequence: 11`) + live `text_delta`.
    flushPendingPersistedTranscripts();
    await new Promise((r) => setTimeout(r, 25));
    forgetPrefetchPauses();
    cacheReset();
    const rehydrated2 = await hydrateTranscriptFromDisk("m-gap");
    expect(rehydrated2?.settledSeq).toBe(10);

    // Live mid-turn events apply cleanly on top of hydrated `settledItems` AND invalidate stale `settledItems` on disk!
    applyLiveEventsToTranscriptCache("m-gap", [
      { type: "user_message", sequence: 11, eventId: "u-11", data: { id: "u-11", content: "Turn 3 mid-flight prompt" } },
      { type: "text_delta", data: { mode: "delta", content: "Streaming turn 3..." } },
    ]);
    flushPendingPersistedTranscripts();
    await new Promise((r) => setTimeout(r, 25));

    forgetPrefetchPauses();
    cacheReset();
    const rehydratedMidTurn = await hydrateTranscriptFromDisk("m-gap");
    expect(rehydratedMidTurn?.settledItems).toBeUndefined();
    expect(rehydratedMidTurn?.items.some((i) => i.kind === "user" && i.text === "Turn 3 mid-flight prompt")).toBe(true);
    expect(rehydratedMidTurn?.items.some((i) => i.kind === "text" && i.text.includes("Streaming turn 3..."))).toBe(true);
    stop();
  });

  it("backfills stripped tool activity on refresh after a conversation ages into the warm 33..250 tier", async () => {
    setConnection("http://warm-backfill.test", "jwt-warm");
    // Save 35 settled transcripts with tool calls so `m-warm-0` ages into the warm 33..250 tier (`activityCompacted: true`).
    for (let i = 0; i < 35; i++) {
      const stream: StreamEvent[] = [
        { type: "user_message", sequence: 1, eventId: `u-${i}`, data: { id: `u-${i}`, content: `Prompt ${i}` } },
        { type: "tool_call", sequence: 2, eventId: `tc-${i}`, data: { tool_call_id: `c-${i}`, name: "Bash", args: { command: "ls -la" } } },
        { type: "tool_result", sequence: 3, eventId: `tr-${i}`, data: { tool_call_id: `c-${i}`, name: "Bash", result: "X".repeat(512) } },
        { type: "assistant_message", sequence: 4, eventId: `a-${i}`, data: { id: `a-${i}`, content: `Answer ${i}`, success: true } },
      ];
      putTranscript(`m-warm-${i}`, {
        fromLog: true,
        cursor: 4,
        before: 1,
        hasOlder: false,
        items: buildTranscript(stream),
        stream,
      });
      flushPendingPersistedTranscripts();
      await new Promise((r) => setTimeout(r, 2));
    }
    await new Promise((r) => setTimeout(r, 30));

    forgetPrefetchPauses();
    cacheReset();

    // Frame 0 cold hydration of `m-warm-0` immediately shows compacted settled items AND resets `cursor` for full tail backfill!
    const frame0 = await hydrateTranscriptFromDisk("m-warm-0");
    expect(frame0?.activityCompacted).toBe(true);
    expect(frame0?.cursor).toBeUndefined();
    expect(frame0?.items.some((it) => it.kind === "tool" && it.callId === "c-0")).toBe(true);

    // Refreshing `m-warm-0` fetches `/open` WITHOUT `since_seq`, restoring full raw tool events instead of erasing them!
    const requestedUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        requestedUrls.push(url);
        return new Response(
          JSON.stringify({
            protocol: 1,
            mission: {
              id: "m-warm-0",
              title: "Warm Backfill Mission",
              status: "completed",
              backend: "claudecode",
              history: [],
              created_at: "2026-11-11T07:00:00Z",
              updated_at: "2026-11-11T07:05:00Z",
            },
            events: [
              { id: 1, sequence: 1, event_id: "u-0", event_type: "user_message", content: "Prompt 0", timestamp: "2026-11-11T07:00:01Z" },
              { id: 2, sequence: 2, event_id: "tc-0", event_type: "tool_call", tool_call_id: "c-0", tool_name: "Bash", content: JSON.stringify({ command: "ls -la" }), timestamp: "2026-11-11T07:00:02Z" },
              { id: 3, sequence: 3, event_id: "tr-0", event_type: "tool_result", tool_call_id: "c-0", tool_name: "Bash", content: JSON.stringify("FULL_RESTORED_OUTPUT"), timestamp: "2026-11-11T07:00:03Z" },
              { id: 4, sequence: 4, event_id: "a-0", event_type: "assistant_message", content: "Answer 0", timestamp: "2026-11-11T07:00:04Z" },
            ],
            spine: [],
            queue: [],
            max_seq: 4,
            has_more: false,
            next_cursor: 1,
            page_max_seq: 4,
            reset: false,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );

    const refreshed = await refreshTranscript("m-warm-0");
    expect(requestedUrls).toHaveLength(1);
    expect(requestedUrls[0]).not.toContain("since_seq=");
    expect(refreshed.activityCompacted).toBeUndefined();
    expect(refreshed.cursor).toBe(4);
    const restoredTool = refreshed.items.find((it) => it.kind === "tool" && it.callId === "c-0");
    expect(restoredTool && restoredTool.kind === "tool" ? restoredTool.result : undefined).toBe("FULL_RESTORED_OUTPUT");
  });

  it("rebalances IndexedDB hot/warm tiers when revisiting warm transcripts", async () => {
    const stores = new Map<string, Map<string, Record<string, unknown>>>();
    const getStoreMap = (name: string) => {
      let m = stores.get(name);
      if (!m) {
        m = new Map();
        stores.set(name, m);
      }
      return m;
    };
    const fakeIdb = {
      open: () => {
        const req: Record<string, unknown> = {};
        const db = {
          objectStoreNames: { contains: (n: string) => stores.has(n) },
          createObjectStore: (n: string) => {
            getStoreMap(n);
            return { createIndex: () => {} };
          },
          transaction: (_names: string | string[]) => {
            const tx: Record<string, unknown> = {
              objectStore: (name: string) => {
                const map = getStoreMap(name);
                return {
                  put: (val: Record<string, unknown>) => {
                    const k = String(val.id ?? val.scope);
                    map.set(k, val);
                  },
                  get: (k: string) => {
                    const r: Record<string, unknown> = { result: map.get(k) };
                    queueMicrotask(() => (r.onsuccess as (() => void) | undefined)?.());
                    return r;
                  },
                  delete: (k: string) => {
                    map.delete(k);
                  },
                  clear: () => {
                    map.clear();
                  },
                  index: () => ({
                    getAll: () => {
                      const rows = [...map.values()].sort(
                        (a, b) => Number(a.savedAt ?? 0) - Number(b.savedAt ?? 0),
                      );
                      const r: Record<string, unknown> = { result: rows };
                      queueMicrotask(() => (r.onsuccess as (() => void) | undefined)?.());
                      return r;
                    },
                  }),
                };
              },
            };
            setTimeout(() => (tx.oncomplete as (() => void) | undefined)?.(), 0);
            return tx;
          },
        };
        req.result = db;
        queueMicrotask(() => {
          (req.onupgradeneeded as (() => void) | undefined)?.();
          (req.onsuccess as (() => void) | undefined)?.();
        });
        return req;
      },
    };
    vi.stubGlobal("indexedDB", fakeIdb);

    const scope = "https://orbcore.thomas.md::idb-tier";
    const big = "X".repeat(2048);
    const makeSnap = (i: number) => ({
      fromLog: true,
      cursor: 3,
      items: [
        { kind: "user", key: `u-${i}`, text: `P ${i}` },
        { kind: "work", key: `w-${i}`, entries: [{ kind: "tool", id: `c-${i}`, name: "bash", result: big }] },
        { kind: "text", key: `a-${i}`, text: `A ${i}` },
      ],
      stream: [
        { type: "user_message", sequence: 1, data: { id: `u-${i}`, content: `P ${i}` } },
        { type: "tool_result", sequence: 2, data: { tool_call_id: `c-${i}`, result: big } },
        { type: "assistant_message", sequence: 3, data: { id: `a-${i}`, content: `A ${i}`, success: true } },
      ],
    });

    for (let i = 0; i < 40; i++) {
      await savePersistedTranscript(scope, `m-${i}`, makeSnap(i));
    }
    const txMap = getStoreMap("transcripts");
    expect([...txMap.values()].filter((r) => r.tier === "hot")).toHaveLength(HOT_PERSISTED_TRANSCRIPTS);

    // Revisit warm transcripts `m-0`..`m-7` and rewrite them as hot — IndexedDB hot count must stay bounded at 32!
    for (let i = 0; i < 8; i++) {
      await savePersistedTranscript(scope, `m-${i}`, makeSnap(i));
    }
    const hotRecords = [...txMap.values()].filter((r) => r.tier === "hot");
    const warmRecords = [...txMap.values()].filter((r) => r.tier === "warm");
    expect(hotRecords).toHaveLength(HOT_PERSISTED_TRANSCRIPTS);
    expect(warmRecords).toHaveLength(8);
    expect(txMap.get(`${scope}::m:m-0`)?.tier).toBe("hot");
    expect(txMap.get(`${scope}::m:m-8`)?.tier).toBe("warm");
  });

  it("fences seeded /open mission metadata against newer mission mutations", async () => {
    setConnection("http://open-mission-fence.test", "jwt-fence");
    const fetchCalls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        fetchCalls.push(url);
        return new Response(
          JSON.stringify({
            id: "m-fence",
            status: "active",
            model_override: "fresh-from-server",
            created_at: "2026-11-11T00:00:00Z",
            updated_at: "2026-11-11T00:00:05Z",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );

    const openStartedAt = Date.now() - 50;
    noteMissionMutated("m-fence");
    seedCachedMission(
      {
        id: "m-fence",
        status: "active",
        model_override: "stale-from-open",
        created_at: "2026-11-11T00:00:00Z",
        updated_at: "2026-11-11T00:00:01Z",
      } as never,
      openStartedAt,
    );

    const resolved = await getMission("m-fence", { coreOnly: true });
    expect(resolved.model_override).toBe("fresh-from-server");
    expect(fetchCalls).toHaveLength(1);
    clearConnection({ persist: false });
  });
});
