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
    expect(classifyClientRequestPriority("GET", "/api/providers/antigravity-models")).toBe("p2");
    expect(classifyClientRequestPriority("POST", "/api/control/missions/m1/inbox-digest")).toBe("p1");
    expect(classifyClientRequestPriority("POST", "/api/file-resources")).toBe("p1");
    expect(classifyClientRequestPriority("POST", "/api/control/missions/m1/opened")).toBe("p1");
    expect(classifyClientRequestPriority("PUT", "/api/control/inbox-state/seen/m1")).toBe("p1");

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

  it("does not poison SRTT with slow compute-bound POST /inbox-digest or /file-resources handlers", async () => {
    const { transportFetch } = await import("../src/api");
    setConnection("https://orbcore.thomas.md", "tok-rtt");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        const rttHeader = url.includes("/inbox-digest") || url.includes("/file-resources") ? "18000" : "85";
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "X-Orb-Transport-Rtt-Ms": rttHeader,
          },
        });
      }),
    );

    await transportFetch("/api/health");
    expect(networkHealthSnapshot().srttMs).toBe(85);
    expect(networkHealthSnapshot().status).toBe("healthy");

    await transportFetch("/api/control/missions/m1/inbox-digest", { method: "POST", body: "{}" });
    await transportFetch("/api/file-resources", { method: "POST", body: "{}" });
    await transportFetch("/api/providers/antigravity-models");
    await transportFetch("/api/ai/providers/usage");
    await transportFetch("/api/ai/providers/claude/usage?force=true");
    await transportFetch("/api/resources/overview?range=6h");
    await transportFetch("/api/usage/summary?window=24h");
    await transportFetch("/api/proxy-health?window=24h");
    expect(networkHealthSnapshot().srttMs).toBe(85);
    expect(networkHealthSnapshot().status).toBe("healthy");
  });

  it("keeps cached projects in memory when localStorage hits QuotaExceededError and avoids invalidating sharedRead on telemetry flushes", async () => {
    const { api, listProjects, peekCachedProjects } = await import("../src/api");
    const { sharedRead } = await import("../src/sharedReads");
    const { usageTelemetry } = await import("../src/usageTelemetry");
    setConnection("https://orbcore.thomas.md", "tok-quota");

    const origSetItem = Storage.prototype.setItem;
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(function (this: Storage, k: string, v: string) {
      if (k.startsWith("orb.catalog:")) {
        throw new DOMException("QuotaExceededError", "QuotaExceededError");
      }
      return origSetItem.call(this, k, v);
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/api/projects")) {
          return Response.json({
            projects: [{ slug: "omarchnix", title: "Omarchnix", status: "active", updated_at: "2026-11-09T15:00:00Z" }],
          });
        }
        return Response.json({ ok: true });
      }),
    );

    const listed = await listProjects();
    expect(listed.map((p) => p.slug)).toEqual(["omarchnix"]);
    // Even though localStorage.setItem threw QuotaExceededError, in-memory catalogMemory serves synchronous hydration:
    expect(peekCachedProjects()?.map((p) => p.slug)).toEqual(["omarchnix"]);

    // Verify usage-telemetry POST does not wipe in-flight sharedRead entries:
    let resolveInflight!: (val: string) => void;
    const inflight = sharedRead("test:inflight", () => new Promise<string>((r) => { resolveInflight = r; }));
    usageTelemetry.setActive(true);
    const closePage = usageTelemetry.page("settings", "screen", "mission");
    closePage();
    await usageTelemetry.flush();
    const joined = sharedRead("test:inflight", () => Promise.resolve("fresh-after-invalidation"));
    expect(joined).toBe(inflight);
    resolveInflight("original-inflight");
    expect(await joined).toBe("original-inflight");
    usageTelemetry.setActive(false);

    // Clearing connection wipes catalogMemory immediately:
    clearConnection();
    expect(peekCachedProjects()).toBeNull();
  });

  it("hydrates cached projects synchronously via peekCachedProjects and isolates P2 transcript prefetches from foreground P1 opens", async () => {
    const { listProjects, peekCachedProjects } = await import("../src/api");
    const { forgetPrefetchPauses, loadTranscript, prefetchTranscript } = await import("../src/missionCache");
    setConnection("https://orbcore.thomas.md", "tok-prefetch");
    expect(peekCachedProjects()).toBeNull();

    const fetchedUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        fetchedUrls.push(url);
        if (url.endsWith("/api/projects")) {
          return Response.json({
            projects: [
              { slug: "orb", title: "Orb", status: "active", updated_at: "2026-11-09T15:00:00Z" },
              { slug: "old", title: "Old", status: "archived", updated_at: "2026-11-09T15:00:00Z" },
            ],
          });
        }
        if (url.includes("/api/control/queue")) {
          return Response.json({ items: [], revision: 1 });
        }
        if (url.includes("/events")) {
          return new Response(
            JSON.stringify([
              { id: 1, sequence: 1, event_type: "user_message", timestamp: "2026-11-09T15:00:00Z", content: "hi" },
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
        return Response.json({ profile: "presentation", events: [] });
      }),
    );

    const listed = await listProjects();
    expect(listed.map((p) => p.slug)).toEqual(["orb"]);
    expect(peekCachedProjects()?.map((p) => p.slug)).toEqual(["orb"]);

    // Hold a P0 slot so p2Cap === 0 while p1Cap remains open: any P2 prefetch must stay gated
    // (zero wire fetches), proving background transcript prefetches never leak into P1!
    let releaseP0Gate!: () => void;
    const p0Gate = scheduleTransportRequest(
      "p0",
      null,
      () => new Promise<void>((resolve) => { releaseP0Gate = resolve; }),
    );
    expect(currentLinkBudget().p2Cap).toBe(0);
    fetchedUrls.length = 0;
    prefetchTranscript("m-bg-gated");
    await new Promise((r) => setTimeout(r, 20));
    expect(fetchedUrls.some((u) => u.includes("m-bg-gated"))).toBe(false);

    // Opening the mission in the foreground (`loadTranscript`) preempts the gated P2 prefetch
    // and completes immediately on the P1 lane even while P2 is still paused.
    const snap = await loadTranscript("m-bg-gated");
    expect(snap.items.length).toBeGreaterThan(0);
    expect(fetchedUrls.some((u) => u.includes("/missions/m-bg-gated/events"))).toBe(true);

    releaseP0Gate();
    await p0Gate;
    forgetPrefetchPauses();
  });

  it("promotes an already-started P2 prefetch to P1 when adopted after p2Cap drops to 0", async () => {
    const { forgetPrefetchPauses, loadTranscript, prefetchTranscript, refreshTranscript } = await import("../src/missionCache");
    setConnection("https://orbcore.thomas.md", "tok-promote");

    // Fill all active P2 slots so the next prefetch enters `pumpPrefetch()` while `p2Cap > 0`
    // and parks its HTTP requests inside `transportScheduler`'s `p2Queue`.
    const budget = currentLinkBudget();
    expect(budget.p2Cap).toBeGreaterThan(0);
    const releaseBlockers: Array<() => void> = [];
    const blockers = Array.from({ length: budget.p2Cap }, () =>
      scheduleTransportRequest(
        "p2",
        null,
        () => new Promise<void>((resolve) => { releaseBlockers.push(resolve); }),
      ),
    );

    let eventPageCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/api/control/queue")) {
          return Response.json({ items: [], revision: 1 });
        }
        if (url.includes("/snapshot")) {
          return Response.json({ profile: "presentation", events: [] });
        }
        if (url.includes("/events")) {
          eventPageCalls++;
          if (eventPageCalls === 1) {
            return new Response(
              JSON.stringify([
                { id: 1, sequence: 1, event_type: "tool_call", tool_call_id: "tc1", tool_name: "bash", timestamp: "2026-11-09T15:00:00Z", content: "{}" },
              ]),
              {
                status: 200,
                headers: {
                  "Content-Type": "application/json",
                  "X-Orb-Events-Protocol": "1",
                  "X-Has-More": "true",
                  "X-Next-Cursor": "0",
                  "X-Page-Max-Sequence": "1",
                  "X-Max-Sequence": "1",
                },
              },
            );
          }
          return new Response(
            JSON.stringify([
              { id: 0, sequence: 0, event_type: "user_message", timestamp: "2026-11-09T14:59:59Z", content: "hello" },
            ]),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "X-Orb-Events-Protocol": "1",
                "X-Has-More": "false",
                "X-Next-Cursor": "0",
                "X-Page-Max-Sequence": "0",
                "X-Max-Sequence": "1",
              },
            },
          );
        }
        return Response.json({});
      }),
    );

    prefetchTranscript("m-parked-p2");
    await vi.waitFor(() => expect(transportSchedulerStats().p2Queued).toBeGreaterThanOrEqual(2));

    // Now degrade the link (`p2Cap === 0`) via an active P0 request: unpromoted P2 work is frozen,
    // yet adopting via `loadTranscript` / `refreshTranscript` must promote both queued requests and
    // subsequent follow-up pages (`view=transcript` spine fetch) onto P1 and resolve immediately.
    let releaseP0!: () => void;
    const p0Gate = scheduleTransportRequest(
      "p0",
      null,
      () => new Promise<void>((resolve) => { releaseP0 = resolve; }),
    );
    expect(currentLinkBudget().p2Cap).toBe(0);

    const [loaded, refreshed] = await Promise.all([
      loadTranscript("m-parked-p2"),
      refreshTranscript("m-parked-p2"),
    ]);
    expect(loaded).toBe(refreshed);
    expect(eventPageCalls).toBe(2);
    expect(loaded.items.some((i) => i.kind === "user")).toBe(true);
    expect(transportSchedulerStats().p2Queued).toBe(0);

    releaseP0();
    await p0Gate;
    for (const r of releaseBlockers) r();
    await Promise.all(blockers);
    forgetPrefetchPauses();
  });
});
