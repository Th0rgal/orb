import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import fixtureClientLinkGovernor from "../../shared/orb-spec/fixtures/client-link-governor.json";
import {
  candidateApiUrls,
  clearConnection,
  resetTransportState,
  setConnection,
} from "../src/api";
import {
  currentLinkBudget,
  networkHealthSnapshot,
  recordTransportFailure,
  recordTransportRttSample,
  resetNetworkHealth,
} from "../src/networkHealth";
import {
  MAX_PERSISTED_TRANSCRIPTS,
  clearPersistentCache,
  loadPersistedSidebar,
  loadPersistedTranscript,
  savePersistedSidebar,
  savePersistedTranscript,
} from "../src/persistentCache";
import { SOFTWARE_STARTUP_DELAY_MS, monitorSoftware } from "../src/softwareInventory";
import { setMultiplexSyncEnabledForTest, streamMission } from "../src/stream";
import {
  classifyClientRequestPriority,
  resetTransportSchedulerForTest,
  scheduleTransportRequest,
  transportSchedulerStats,
} from "../src/transportScheduler";

describe("poor-network resilience suite", () => {
  beforeEach(async () => {
    resetTransportState();
    resetTransportSchedulerForTest();
    resetNetworkHealth();
    await clearPersistentCache();
    setMultiplexSyncEnabledForTest(false);
  });

  afterEach(async () => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    setMultiplexSyncEnabledForTest(false);
    resetTransportSchedulerForTest();
    resetNetworkHealth();
    await clearPersistentCache();
  });

  it("matches shared Edge-diverse candidate origin fixtures", () => {
    for (const c of fixtureClientLinkGovernor.candidate_origin_cases) {
      expect(candidateApiUrls(c.configured_url), c.name).toEqual(c.expected);
    }
  });

  it("preempts P2 background sweeps while P0 user mutations or high RTT are active, then drains cleanly", async () => {
    expect(classifyClientRequestPriority("POST", "/api/control/missions")).toBe("p0");
    expect(classifyClientRequestPriority("GET", "/api/health")).toBe("p0");
    expect(classifyClientRequestPriority("GET", "/api/control/missions")).toBe("p1");
    expect(classifyClientRequestPriority("GET", "/api/software?force=false")).toBe("p2");

    let releaseP0!: () => void;
    const p0Promise = scheduleTransportRequest(
      "p0",
      null,
      () => new Promise<string>((resolve) => { releaseP0 = () => resolve("p0-done"); }),
    );
    expect(networkHealthSnapshot().p0InFlight).toBe(1);
    expect(currentLinkBudget().p2Cap).toBe(0);

    let p2Started = false;
    const p2Promise = scheduleTransportRequest("p2", null, async () => {
      p2Started = true;
      return "p2-done";
    });
    expect(p2Started).toBe(false);
    expect(transportSchedulerStats().p2Queued).toBe(1);

    // Simulate loaded 4 Mbps bufferbloat (SRTT > 1200 ms) before P0 finishes: P2 stays paused even after P0 resolves!
    recordTransportRttSample(2400);
    expect(networkHealthSnapshot().srttMs).toBe(2400);
    releaseP0();
    await expect(p0Promise).resolves.toBe("p0-done");
    expect(networkHealthSnapshot().p0InFlight).toBe(0);
    expect(currentLinkBudget().p2Cap).toBe(0);
    expect(p2Started).toBe(false);

    // Once RTT recovers below 1200 ms (or transport failure clears), P2 drains automatically.
    for (let i = 0; i < 10; i++) recordTransportRttSample(350);
    expect(networkHealthSnapshot().srttMs).toBeLessThanOrEqual(1200);
    await expect(p2Promise).resolves.toBe("p2-done");
    expect(p2Started).toBe(true);

    // Consecutive transport failures immediately pause P2 again.
    recordTransportFailure();
    expect(currentLinkBudget().p2Cap).toBe(0);
  });

  it("defers monitorSoftware() initial network sweep by 8000 ms and cancels cleanly", async () => {
    vi.useFakeTimers();
    setConnection("https://orbcore.thomas.md", "tok-test");
    const fetchSpy = vi.fn(async () => Response.json({ nodes: [] }));
    vi.stubGlobal("fetch", fetchSpy);

    const stop = monitorSoftware();
    expect(SOFTWARE_STARTUP_DELAY_MS).toBe(8000);
    expect(fetchSpy).not.toHaveBeenCalled();

    vi.advanceTimersByTime(7900);
    expect(fetchSpy).not.toHaveBeenCalled();

    vi.advanceTimersByTime(200);
    await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalled());
    stop();
  });

  it("scales sync-ws pong deadlines adaptively under slow RTT instead of killing healthy sockets at 2500 ms", async () => {
    vi.useFakeTimers();
    setConnection("http://sync-slow.test", "jwt-slow");
    setMultiplexSyncEnabledForTest(true);

    // Seed loaded slow-Wi-Fi telemetry: SRTT = 2600 ms, RTTVAR = 900 ms -> pongDeadlineMs = 9200 ms.
    recordTransportRttSample(2600);
    expect(currentLinkBudget().pongDeadlineMs).toBeGreaterThanOrEqual(8000);

    class SlowSocket {
      static instances: SlowSocket[] = [];
      static OPEN = 1;
      readyState = 0;
      closedCount = 0;
      sent: Record<string, unknown>[] = [];
      onopen: (() => void) | null = null;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(public url: string) {
        SlowSocket.instances.push(this);
      }
      openNow() {
        this.readyState = SlowSocket.OPEN;
        this.onopen?.();
      }
      send(payload: string) {
        this.sent.push(JSON.parse(payload) as Record<string, unknown>);
      }
      close() {
        this.closedCount++;
        this.readyState = 3;
        this.onclose?.();
      }
    }
    vi.stubGlobal("WebSocket", SlowSocket as unknown as typeof WebSocket);

    const stop = streamMission("m-slow", () => {}, () => {});
    expect(SlowSocket.instances).toHaveLength(1);
    const ws = SlowSocket.instances[0];

    // Takes 5500 ms just to complete TCP+TLS+WS handshake on congested 4 Mbps link (used to die at 5000 ms!).
    vi.advanceTimersByTime(5500);
    expect(ws.closedCount).toBe(0);
    ws.openNow();

    // Advance 10 s to trigger ping, then wait 4500 ms before pong arrives (used to die at 2500 ms!).
    vi.advanceTimersByTime(10_000);
    expect(ws.sent.some((m) => m.op === "ping")).toBe(true);
    vi.advanceTimersByTime(4500);
    expect(ws.closedCount).toBe(0);

    ws.onmessage?.({ data: JSON.stringify({ type: "pong", ts: Date.now() - 4500 }) });
    vi.advanceTimersByTime(5000);
    expect(ws.closedCount).toBe(0);

    stop();
  });

  it("hydrates sidebar & LRU-24 transcripts from persistentCache and wipes immediately on clearConnection()", async () => {
    const scope = "https://orbcore.thomas.md::tokhash";
    await savePersistedSidebar(scope, {
      missions: [{ id: "m-1", title: "Cached mission" }],
      completedMissions: [{ id: "m-done", title: "Done" }],
      projects: [{ id: "p-1", name: "Core" }],
    });
    const sidebar = await loadPersistedSidebar<{ id: string; title: string }, { id: string; name: string }>(scope);
    expect(sidebar?.missions).toEqual([{ id: "m-1", title: "Cached mission" }]);
    expect(sidebar?.projects).toEqual([{ id: "p-1", name: "Core" }]);

    for (let i = 0; i < MAX_PERSISTED_TRANSCRIPTS + 4; i++) {
      await savePersistedTranscript(scope, `m-${i}`, { seq: i });
      // Monotone timestamps for deterministic LRU ordering
      await new Promise((r) => setTimeout(r, 1));
    }
    expect(await loadPersistedTranscript(scope, "m-0")).toBeNull();
    expect(await loadPersistedTranscript(scope, `m-${MAX_PERSISTED_TRANSCRIPTS + 3}`)).toEqual({
      seq: MAX_PERSISTED_TRANSCRIPTS + 3,
    });

    setConnection("https://orbcore.thomas.md", "tok-live");
    clearConnection();
    // Wait a tick for void clearPersistentCache() inside clearConnection()
    await new Promise((r) => setTimeout(r, 10));
    expect(await loadPersistedSidebar(scope)).toBeNull();
    expect(await loadPersistedTranscript(scope, `m-${MAX_PERSISTED_TRANSCRIPTS + 3}`)).toBeNull();
  });
});
