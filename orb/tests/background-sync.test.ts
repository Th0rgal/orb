import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection } from "../src/api";
import {
  createBackgroundSyncMonitorState,
  evaluateBackgroundSync,
  normalizeBackgroundSyncMode,
  resetBackgroundSyncMonitorForTest,
  selectWarmMissionIds,
  setBackgroundSyncMode,
  stepBackgroundSyncMonitor,
  type BackgroundSyncEvent,
  type BackgroundSyncMode,
} from "../src/backgroundSync";
import {
  btwSession,
  noteBtwPresentationHint,
  peekWarmBtwState,
  reconcileBtwServerHistory,
  resetWarmBtwForTest,
  watchBtw,
} from "../src/btwAgent";
import { sideQuestionKey } from "../src/sideQuestionStorage";
import {
  applyLiveEventsToTranscriptCache,
  applyWarmMissionPatch,
  attachMissionStream,
  clearWarmMissionSettingsPatch,
  forgetPrefetchPauses,
  isMissionDirtyWhileUnfocused,
  isMissionWarmLive,
  loadTranscript,
  noteMissionPresentationHint,
  peekReadyTranscript,
  peekWarmMissionPatch,
  retainTranscript,
} from "../src/missionCache";
import { cacheReset } from "../src/pageCache";
import { setMultiplexSyncEnabledForTest } from "../src/stream";

type PolicyFixture = {
  normalization: Array<{ input: unknown; expected: BackgroundSyncMode }>;
  stateTransitions: Array<{
    name: string;
    mode: BackgroundSyncMode;
    events: BackgroundSyncEvent[];
    expected: { active: boolean; reason: string };
  }>;
  warmSelection: Array<{
    name: string;
    backgroundActive: boolean;
    maxWarm: number;
    focusedIds: string[];
    recentIds: string[];
    btwByParent?: Record<string, string>;
    openBtwParentIds?: string[];
    expectedMissionIds: string[];
  }>;
};

const fixturePath = resolve(__dirname, "../../shared/orb-spec/fixtures/background-sync-policy.json");
const policyFixture = JSON.parse(readFileSync(fixturePath, "utf8")) as PolicyFixture;

class FakeSyncSocket {
  static instances: FakeSyncSocket[] = [];
  static OPEN = 1;
  readyState = 0;
  sent: Record<string, unknown>[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;

  constructor(public url: string, public protocols?: string | string[]) {
    FakeSyncSocket.instances.push(this);
    queueMicrotask(() => {
      this.readyState = FakeSyncSocket.OPEN;
      this.onopen?.();
    });
  }

  send(payload: string) {
    const parsed = JSON.parse(payload) as Record<string, unknown>;
    this.sent.push(parsed);
    if (parsed.op === "subscribe" && typeof parsed.mission_id === "string") {
      const mid = parsed.mission_id;
      const sinceSeq = typeof parsed.since_seq === "number" ? parsed.since_seq : null;
      queueMicrotask(() => {
        this.onmessage?.({ data: JSON.stringify({ type: "subscribed", mission_id: mid }) });
        this.onmessage?.({
          data: JSON.stringify({
            type: "sync_caught_up",
            mission_id: mid,
            replayed: 0,
            cursor: sinceSeq,
          }),
        });
      });
    }
  }

  close() {
    this.readyState = 3;
    this.onclose?.();
  }
}

beforeEach(() => {
  localStorage.clear();
  cacheReset();
  forgetPrefetchPauses();
  resetWarmBtwForTest();
  setBackgroundSyncMode("auto");
  resetBackgroundSyncMonitorForTest();
  FakeSyncSocket.instances = [];
});

afterEach(() => {
  forgetPrefetchPauses();
  resetWarmBtwForTest();
  setMultiplexSyncEnabledForTest(false);
  clearConnection();
  setBackgroundSyncMode("auto");
  resetBackgroundSyncMonitorForTest();
  vi.unstubAllGlobals();
});

describe("shared background-sync-policy.json conformance", () => {
  it("normalizes modes identically to shared fixture", () => {
    for (const c of policyFixture.normalization) {
      expect(normalizeBackgroundSyncMode(c.input)).toBe(c.expected);
    }
  });

  for (const tc of policyFixture.stateTransitions) {
    it(`state transition: ${tc.name}`, () => {
      let state = createBackgroundSyncMonitorState(tc.mode);
      for (const ev of tc.events) {
        state = stepBackgroundSyncMonitor(state, ev);
      }
      const verdict = evaluateBackgroundSync(state);
      expect({ active: verdict.active, reason: verdict.reason }).toEqual(tc.expected);
    });
  }

  for (const wc of policyFixture.warmSelection) {
    it(`warm selection: ${wc.name}`, () => {
      expect(
        selectWarmMissionIds({
          backgroundActive: wc.backgroundActive,
          maxWarm: wc.maxWarm,
          focusedIds: wc.focusedIds,
          recentIds: wc.recentIds,
          btwByParent: wc.btwByParent,
          openBtwParentIds: wc.openBtwParentIds,
        }),
      ).toEqual(wc.expectedMissionIds);
    });
  }
});

describe("warm background sync & off-mode quickness", () => {
  it("keeps unfocused missions WarmLive in Auto mode and sheds them automatically on high RTT", async () => {
    setConnection("http://warm.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);

    let eventHttpFetches = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes("/events?")) {
          eventHttpFetches++;
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: "m-warm",
                sequence: 10,
                event_type: "user_message",
                event_id: "u-1",
                timestamp: "2026-11-04T00:00:00Z",
                content: "First question",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "10",
                "X-Page-Max-Sequence": "10",
                "X-Max-Sequence": "10",
              },
            },
          );
        }
        return Response.json({});
      }),
    );

    const releaseMount1 = retainTranscript("m-warm");
    await loadTranscript("m-warm");
    const detachView1 = attachMissionStream("m-warm", {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });

    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];
    await vi.waitFor(() => expect(isMissionWarmLive("m-warm")).toBe(true));
    const fetchesAfterInitialOpen = eventHttpFetches;
    expect(fetchesAfterInitialOpen).toBeGreaterThan(0);

    // Unmount view (user switches to another mission): subscription stays alive in Auto mode!
    detachView1();
    releaseMount1();
    expect(sock.sent.some((m) => m.op === "unsubscribe" && m.mission_id === "m-warm")).toBe(false);
    expect(isMissionWarmLive("m-warm")).toBe(true);

    // Emit a live assistant reply while the mission is unfocused.
    sock.onmessage?.({
      data: JSON.stringify({
        type: "assistant_message",
        mission_id: "m-warm",
        id: "a-11",
        sequence: 11,
        content: "Instant background reply!",
        success: true,
      }),
    });

    // Reopen mission: already up-to-date in memory with zero additional HTTP event fetches!
    const snapOnReopen = peekReadyTranscript("m-warm");
    expect(snapOnReopen?.cursor).toBe(11);
    expect(snapOnReopen?.items.some((i) => i.kind === "text" && i.text.includes("Instant background reply!"))).toBe(
      true,
    );
    expect(eventHttpFetches).toBe(fetchesAfterInitialOpen);

    // Simulate 2 consecutive slow pongs (>750ms): Auto pauses and immediately unsubscribes unfocused mission!
    const now = Date.now();
    sock.onmessage?.({ data: JSON.stringify({ type: "pong", ts: now - 900 }) });
    sock.onmessage?.({ data: JSON.stringify({ type: "pong", ts: now - 950 }) });
    expect(sock.sent).toContainEqual({ op: "unsubscribe", mission_id: "m-warm" });
    expect(isMissionWarmLive("m-warm")).toBe(false);
  });

  it("retains live events in cache and avoids redundant /btw HTTP crawls in Off mode", async () => {
    setConnection("http://off-mode.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    setBackgroundSyncMode("off");
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);

    let btwTagQueries = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes("tag=btw-parent")) {
          btwTagQueries++;
          return Response.json([]);
        }
        if (url.includes("/events?")) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: "m-off",
                sequence: 5,
                event_type: "user_message",
                event_id: "u-5",
                timestamp: "2026-11-04T00:00:00Z",
                content: "Initial prompt",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "5",
                "X-Page-Max-Sequence": "5",
                "X-Max-Sequence": "5",
              },
            },
          );
        }
        return Response.json({ id: "m-off", tags: [] });
      }),
    );

    const release = retainTranscript("m-off");
    await loadTranscript("m-off");
    const detach = attachMissionStream("m-off", {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });
    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];
    await vi.waitFor(() => expect(isMissionWarmLive("m-off")).toBe(true));

    // Live reply arrives while open in Off mode — must stay in peekReadyTranscript!
    applyLiveEventsToTranscriptCache("m-off", [
      {
        type: "assistant_message",
        eventId: "a-live",
        data: { id: "a-live", content: "Watched while open", success: true, at: "2026-11-04T00:00:02Z" },
      },
    ]);

    // First /btw reconcile checks server once.
    await reconcileBtwServerHistory("m-off", []);
    expect(btwTagQueries).toBe(1);

    // User switches away in Off mode: immediately unsubscribes on WS, keeps live reply & clean flag!
    detach();
    release();
    expect(sock.sent).toContainEqual({ op: "unsubscribe", mission_id: "m-off" });
    expect(isMissionDirtyWhileUnfocused("m-off")).toBe(false);
    expect(peekReadyTranscript("m-off")?.items.some((i) => i.kind === "text" && i.text.includes("Watched while open"))).toBe(
      true,
    );

    // Returning in Off mode while clean skips /btw HTTP crawl completely!
    await reconcileBtwServerHistory("m-off", []);
    expect(btwTagQueries).toBe(1);

    // When a presentation hint marks /btw dirty (e.g. another device started a /btw), next open reconciles!
    noteBtwPresentationHint("m-off", "btw-child-1");
    noteMissionPresentationHint("m-off", "assistant_message");
    expect(isMissionDirtyWhileUnfocused("m-off")).toBe(true);
    await reconcileBtwServerHistory("m-off", []);
    expect(btwTagQueries).toBe(2);
  });

  it("reduces live /btw events in memory, clears stale localStorage active on completion, and skips tool pages on cold /btw crawl", async () => {
    setConnection("http://unified.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);

    const parentId = "9409f9a9-d3eb-416a-b5a8-978508bed734";
    const childId = "btw-child-9409";
    const fetchedUrls: string[] = [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        fetchedUrls.push(url);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes("tag=btw-parent")) {
          return Response.json([
            {
              id: childId,
              status: "active",
              backend: "opencode",
              model_override: "builtin/smart",
              tags: [`btw-parent:${parentId}`],
              created_at: "2026-11-06T05:00:00Z",
              updated_at: "2026-11-06T05:00:01Z",
            },
          ]);
        }
        if (url.includes(`/missions/${childId}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: childId,
                sequence: 4,
                event_type: "user_message",
                event_id: "u-btw-1",
                timestamp: "2026-11-06T05:00:01Z",
                content:
                  "You are the independent /btw agent sharing the main agent's working folder.\n\nCurrent request:\npropose a clean plan to update files\n",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "4",
                "X-Page-Max-Sequence": "4",
                "X-Max-Sequence": "4",
              },
            },
          );
        }
        if (url.includes(`/missions/${parentId}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: parentId,
                sequence: 10,
                event_type: "user_message",
                event_id: "u-main-1",
                timestamp: "2026-11-06T04:55:00Z",
                content: "Main goal prompt",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "10",
                "X-Page-Max-Sequence": "10",
                "X-Max-Sequence": "10",
              },
            },
          );
        }
        return Response.json({ id: parentId, tags: [] });
      }),
    );

    const releaseParent = retainTranscript(parentId);
    await loadTranscript(parentId);
    const detachParent = attachMissionStream(parentId, {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });

    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];

    // Initial cold /btw reconciliation uses include_history=false on fork lookup and types=... on /events:
    const initialBtw = await reconcileBtwServerHistory(parentId, []);
    expect(initialBtw.activeSession?.active).toBe(true);
    expect(btwSession(parentId)?.active).toBe(true);
    expect(fetchedUrls.some((u) => u.includes(`/missions/${parentId}?include_history=false`))).toBe(true);
    expect(
      fetchedUrls.some(
        (u) =>
          u.includes(`/missions/${childId}/events?`) &&
          u.includes("types=user_message%2Cassistant_message%2Cassistant_message_canonical%2Ctext_delta"),
      ),
    ).toBe(true);

    // Wait for the unified WarmMissionSub on childId to subscribe & catch up over /api/control/sync:
    await vi.waitFor(() =>
      expect(sock.sent).toContainEqual(
        expect.objectContaining({ op: "subscribe", mission_id: childId, since_seq: 4 }),
      ),
    );

    // User switches away from parentId while /btw childId is still running:
    detachParent();
    releaseParent();
    const urlCountBeforeUnfocusedCompletion = fetchedUrls.length;

    // Unfocused main mission receives streaming delta, settings update, and terminal status:
    sock.onmessage?.({
      data: JSON.stringify({
        type: "text_delta",
        mission_id: parentId,
        sequence: 11,
        content: "Streaming main text...",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_settings_updated",
        mission_id: parentId,
        model_override: "openai/gpt-5.4",
        model_effort: "high",
        updated_at: "2026-11-06T05:02:00Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_status_changed",
        mission_id: parentId,
        status: "completed",
      }),
    });

    // Unfocused /btw child mission finishes on WS:
    sock.onmessage?.({
      data: JSON.stringify({
        type: "assistant_message",
        mission_id: childId,
        id: "a-btw-5",
        sequence: 5,
        content: "Here is the clean 5-step plan for ethlib.",
        success: true,
        at: "2026-11-06T05:01:30Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_status_changed",
        mission_id: childId,
        status: "completed",
      }),
    });

    await new Promise((r) => setTimeout(r, 30));

    // 1) Zero debounced HTTP /events or ?tag=btw-parent crawls occurred!
    expect(fetchedUrls.length).toBe(urlCountBeforeUnfocusedCompletion);

    // 2) Warm /btw state is clean, has the completed turn, and localStorage `btwSession(parent).active` is false!
    const warmAfter = peekWarmBtwState(parentId);
    expect(warmAfter?.clean).toBe(true);
    expect(warmAfter?.activeSession).toBeUndefined();
    expect(warmAfter?.history).toHaveLength(1);
    expect(warmAfter?.history[0]?.answer).toBe("Here is the clean 5-step plan for ethlib.");
    expect(btwSession(parentId)?.active).toBe(false);
    expect(btwSession(parentId)?.startedAt).toBeUndefined();

    // 3) Reopening /btw reconcile returns immediately from warm memory with zero HTTP requests:
    const reopenBtw = await reconcileBtwServerHistory(parentId, []);
    expect(reopenBtw.history[0]?.answer).toBe("Here is the clean 5-step plan for ethlib.");
    expect(fetchedUrls.length).toBe(urlCountBeforeUnfocusedCompletion);

    // 4) Unfocused main mission closed its streaming bubble and cached its settings + status patch:
    const mainSnap = peekReadyTranscript(parentId);
    const mainTextItem = mainSnap?.items.find((i) => i.kind === "text");
    expect(mainTextItem && mainTextItem.kind === "text" ? mainTextItem.live : undefined).toBe(false);
    expect(peekWarmMissionPatch(parentId)).toMatchObject({
      status: "completed",
      model_override: "openai/gpt-5.4",
      model_effort: "high",
    });
  });

  it("preserves repairedFinal answers on prior turns when a subsequent /btw turn streams live", async () => {
    setConnection("http://repaired.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);

    const parentId = "repaired-parent-01";
    const childId = "repaired-side-01";
    const closingLine = "Everything has been explained.";
    const fullTurn1Answer =
      "Detailed explanation covering root cause, reproduction steps, invariant proof, and rollout checklist across every client platform in full detail.\n\n" +
      "Additional verification details ensuring the delta exceeds the 200-char and 3x threshold required by repairedFinal.\n\n" +
      closingLine;

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes("tag=btw-parent")) {
          return Response.json([
            {
              id: childId,
              status: "awaiting_user",
              created_at: "2026-11-06T11:00:00Z",
              updated_at: "2026-11-06T11:05:00Z",
              backend: "opencode",
              model_override: "builtin/smart",
              tags: [`btw-parent:${parentId}`],
              history: [],
              title: null,
            },
          ]);
        }
        if (url.includes(`/missions/${childId}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: childId,
                sequence: 1,
                event_type: "user_message",
                event_id: "u1",
                content: "Explain the bug",
                timestamp: "2026-11-06T11:00:01Z",
                metadata: {},
              },
              {
                id: 2,
                mission_id: childId,
                sequence: 2,
                event_type: "text_delta",
                event_id: "server-delta-turn-1",
                content: fullTurn1Answer,
                timestamp: "2026-11-06T11:00:10Z",
                metadata: {},
              },
              {
                id: 3,
                mission_id: childId,
                sequence: 3,
                event_type: "assistant_message",
                event_id: "a1",
                content: closingLine,
                timestamp: "2026-11-06T11:00:11Z",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "3",
                "X-Page-Max-Sequence": "3",
                "X-Max-Sequence": "3",
              },
            },
          );
        }
        if (url.includes(`/missions/${parentId}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: parentId,
                sequence: 1,
                event_type: "user_message",
                event_id: "u-main-1",
                content: "Parent turn",
                timestamp: "2026-11-06T10:55:00Z",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "1",
                "X-Page-Max-Sequence": "1",
                "X-Max-Sequence": "1",
              },
            },
          );
        }
        return Response.json({ id: parentId, tags: [] });
      }),
    );

    const releaseParent = retainTranscript(parentId);
    await loadTranscript(parentId);
    const detachParent = attachMissionStream(parentId, {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });

    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];

    const initial = await reconcileBtwServerHistory(parentId, []);
    expect(initial.history).toHaveLength(1);
    expect(initial.history[0]?.answer).toBe(fullTurn1Answer);

    await vi.waitFor(() =>
      expect(sock.sent).toContainEqual(
        expect.objectContaining({ op: "subscribe", mission_id: childId, since_seq: 3 }),
      ),
    );

    detachParent();
    releaseParent();

    // Now Turn 2 streams live on the same side mission (user_message -> text_delta -> assistant_message):
    sock.onmessage?.({
      data: JSON.stringify({
        type: "user_message",
        mission_id: childId,
        id: "u2",
        sequence: 4,
        content: "Any follow-up?",
        at: "2026-11-06T11:06:00Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "text_delta",
        mission_id: childId,
        sequence: 5,
        content: "Short follow-up answer.",
        at: "2026-11-06T11:06:02Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "assistant_message",
        mission_id: childId,
        id: "a2",
        sequence: 6,
        content: "Short follow-up answer.",
        success: true,
        at: "2026-11-06T11:06:03Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_status_changed",
        mission_id: childId,
        status: "awaiting_user",
      }),
    });

    await new Promise((r) => setTimeout(r, 20));

    const warmAfterTurn2 = peekWarmBtwState(parentId);
    expect(warmAfterTurn2?.clean).toBe(true);
    expect(warmAfterTurn2?.history).toHaveLength(2);
    // Turn 1's repairedFinal answer MUST remain intact (never shrunk back to `closingLine`):
    expect(warmAfterTurn2?.history[0]?.answer).toBe(fullTurn1Answer);
    expect(warmAfterTurn2?.history[1]?.answer).toBe("Short follow-up answer.");
  });

  it("does not duplicate turns when watchBtw completes over HTTP before the warm stream delivers terminal events", async () => {
    setConnection("http://dedup.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);
    setBackgroundSyncMode("auto");
    const parentId = "m-parent-dedup";
    const childId = "m-btw-dedup";
    let childStatus = "active";

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes("/api/control/missions?tag=")) {
          return Response.json([
            {
              id: childId,
              status: childStatus,
              backend: "opencode",
              model_override: "builtin/smart",
              tags: [`btw-parent:${parentId}`],
              created_at: "2026-11-06T12:00:00Z",
              updated_at: "2026-11-06T12:00:10Z",
              history: [],
              title: null,
            },
          ]);
        }
        if (url.includes(`/missions/${childId}/events?`)) {
          const rows =
            childStatus === "awaiting_user"
              ? [
                  {
                    id: 10,
                    mission_id: childId,
                    sequence: 10,
                    event_type: "user_message",
                    event_id: "u-dedup-1",
                    content: "Check status",
                    timestamp: "2026-11-06T12:00:01Z",
                    metadata: {},
                  },
                  {
                    id: 15,
                    mission_id: childId,
                    sequence: 15,
                    event_type: "assistant_message",
                    event_id: "a-dedup-1",
                    content: "Status is healthy.",
                    timestamp: "2026-11-06T12:00:05Z",
                    metadata: {},
                  },
                ]
              : [
                  {
                    id: 10,
                    mission_id: childId,
                    sequence: 10,
                    event_type: "user_message",
                    event_id: "u-dedup-1",
                    content: "Check status",
                    timestamp: "2026-11-06T12:00:01Z",
                    metadata: {},
                  },
                ];
          const maxSeq = String(rows.at(-1)?.sequence ?? 10);
          return new Response(JSON.stringify(rows), {
            status: 200,
            headers: {
              "Content-Type": "application/json",
              "X-Orb-Events-Protocol": "1",
              "X-Has-More": "false",
              "X-Next-Cursor": maxSeq,
              "X-Page-Max-Sequence": maxSeq,
              "X-Max-Sequence": maxSeq,
            },
          });
        }
        if (url.includes(`/missions/${childId}`)) {
          return Response.json({
            id: childId,
            status: childStatus,
            backend: "opencode",
            model_override: "builtin/smart",
            tags: [`btw-parent:${parentId}`],
            created_at: "2026-11-06T12:00:00Z",
            updated_at: "2026-11-06T12:00:10Z",
            history: [],
            title: null,
          });
        }
        if (url.includes(`/missions/${parentId}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: parentId,
                sequence: 1,
                event_type: "user_message",
                event_id: "u-parent-1",
                content: "Main work",
                timestamp: "2026-11-06T11:59:00Z",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "1",
                "X-Page-Max-Sequence": "1",
                "X-Max-Sequence": "1",
              },
            },
          );
        }
        return Response.json({ id: parentId, tags: [] });
      }),
    );

    const releaseParent = retainTranscript(parentId);
    await loadTranscript(parentId);
    const detachParent = attachMissionStream(parentId, {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });

    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];

    // Seed warm entry while the side turn is still active:
    await reconcileBtwServerHistory(parentId, []);
    await vi.waitFor(() =>
      expect(sock.sent).toContainEqual(
        expect.objectContaining({ op: "subscribe", mission_id: childId }),
      ),
    );

    // Simulate watchBtw observing terminal HTTP state before the warm stream delivers it:
    childStatus = "awaiting_user";
    localStorage.setItem(
      "agent:" + sideQuestionKey(parentId),
      JSON.stringify({
        id: childId,
        question: "Check status",
        harness: "opencode",
        model: "builtin/smart",
        local: false,
        active: true,
        baseline: 0,
      }),
    );
    const watchEvents: Array<{ type: string; answer?: string }> = [];
    await watchBtw(parentId, new AbortController().signal, (ev) => watchEvents.push(ev));
    expect(watchEvents.at(-1)).toEqual({ type: "done", answer: "Status is healthy." });
    expect(peekWarmBtwState(parentId)?.history).toHaveLength(1);
    expect(peekWarmBtwState(parentId)?.history[0]?.id).toBe(`btw:${childId}:10`);

    detachParent();
    releaseParent();

    // Now the warm WebSocket stream delivers the same turn's events & terminal status:
    sock.onmessage?.({
      data: JSON.stringify({
        type: "user_message",
        mission_id: childId,
        id: "u-dedup-1",
        sequence: 10,
        content: "Check status",
        at: "2026-11-06T12:00:01Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "assistant_message",
        mission_id: childId,
        id: "a-dedup-1",
        sequence: 15,
        content: "Status is healthy.",
        success: true,
        at: "2026-11-06T12:00:05Z",
      }),
    });
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_status_changed",
        mission_id: childId,
        status: "awaiting_user",
      }),
    });

    await new Promise((r) => setTimeout(r, 20));

    const finalWarm = peekWarmBtwState(parentId);
    expect(finalWarm?.clean).toBe(true);
    expect(finalWarm?.history).toHaveLength(1);
    expect(finalWarm?.history[0]).toMatchObject({
      id: `btw:${childId}:10`,
      question: "Check status",
      answer: "Status is healthy.",
    });
  });

  it("never overwrites newer mission settings or disconnected subscriptions when applying warm patches", async () => {
    setConnection("http://patch-fresh.test", "jwt-tok");
    setMultiplexSyncEnabledForTest(true);
    vi.stubGlobal("WebSocket", FakeSyncSocket as unknown as typeof WebSocket);
    setBackgroundSyncMode("auto");

    const mid = "m-patch-freshness";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("none", { status: 404 });
        if (url.includes(`/missions/${mid}/events?`)) {
          return new Response(
            JSON.stringify([
              {
                id: 1,
                mission_id: mid,
                sequence: 1,
                event_type: "user_message",
                event_id: "u1",
                content: "Hello",
                timestamp: "2026-11-06T12:00:00Z",
                metadata: {},
              },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "1",
                "X-Page-Max-Sequence": "1",
                "X-Max-Sequence": "1",
              },
            },
          );
        }
        return Response.json({ id: mid, tags: [] });
      }),
    );

    const release = retainTranscript(mid);
    await loadTranscript(mid);
    const detach = attachMissionStream(mid, {
      onEvent: () => {},
      onBatch: () => {},
      onLagged: () => {},
      onReady: () => {},
      onDisconnected: () => {},
    });

    await vi.waitFor(() => expect(FakeSyncSocket.instances).toHaveLength(1));
    const sock = FakeSyncSocket.instances[0];
    await vi.waitFor(() => expect(isMissionWarmLive(mid)).toBe(true));

    // Stream delivers a settings update at T1:
    sock.onmessage?.({
      data: JSON.stringify({
        type: "mission_settings_updated",
        mission_id: mid,
        sequence: 2,
        model_override: "openai/gpt-5.2",
        model_effort: "medium",
        updated_at: "2026-11-06T12:05:00Z",
      }),
    });

    const staleMission = {
      id: mid,
      status: "awaiting_user",
      title: null,
      history: [],
      backend: "opencode",
      model_override: "openai/gpt-5.0",
      model_effort: "low",
      created_at: "2026-11-06T12:00:00Z",
      updated_at: "2026-11-06T12:01:00Z",
    };
    // Older mission row IS upgraded to the T1 stream patch:
    expect(applyWarmMissionPatch(staleMission)?.model_override).toBe("openai/gpt-5.2");

    // Newer optimistic/HTTP mission row (T2 > T1) is NOT overwritten by the T1 stream patch:
    const newerMission = {
      ...staleMission,
      model_override: "anthropic/claude-opus-4-6",
      model_effort: "high",
      updated_at: "2026-11-06T12:06:00Z",
    };
    expect(applyWarmMissionPatch(newerMission)?.model_override).toBe("anthropic/claude-opus-4-6");
    expect(applyWarmMissionPatch(newerMission)?.model_effort).toBe("high");

    // In-flight settings guard (`preserveSettings: true`) also keeps existing settings:
    expect(
      applyWarmMissionPatch(staleMission, { preserveSettings: true })?.model_override,
    ).toBe("openai/gpt-5.0");

    // Disconnecting clears unhealthy warm patches so stale stream state never lingers:
    sock.onclose?.();
    expect(peekWarmMissionPatch(mid)).toBeUndefined();
    expect(applyWarmMissionPatch(staleMission)?.model_override).toBe("openai/gpt-5.0");

    clearWarmMissionSettingsPatch(mid);
    detach();
    release();
  });
});
