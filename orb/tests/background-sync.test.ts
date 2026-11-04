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
  noteBtwPresentationHint,
  reconcileBtwServerHistory,
  resetWarmBtwForTest,
} from "../src/btwAgent";
import {
  applyLiveEventsToTranscriptCache,
  attachMissionStream,
  forgetPrefetchPauses,
  isMissionDirtyWhileUnfocused,
  isMissionWarmLive,
  loadTranscript,
  noteMissionPresentationHint,
  peekReadyTranscript,
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
});
