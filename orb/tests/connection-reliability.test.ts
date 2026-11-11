import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  api,
  candidateApiUrls,
  clearConnection,
  flushDurableWriteOutbox,
  listMissions,
  markMissionOpened,
  readMissionSyncCursor,
  resolveTransportBase,
  setApiUrl,
  setConnection,
  setTransportBridgeEnabled,
  transportFetch,
  withIdempotencyKey,
} from "../src/api";
import { isPartialList } from "../src/missionHierarchy";
import { cachePut, cacheReset } from "../src/pageCache";
import {
  MAX_LIVE_PREFETCH,
  forgetPrefetchPauses,
  peekReadyTranscript,
  prefetchTranscript,
  putTranscript,
  refreshTranscript,
  selectLivePrefetchIds,
} from "../src/missionCache";
import { createFileClient } from "../src/fileResources";
import {
  networkHealth,
  networkHealthSnapshot,
  recordTransportFailure,
  recordTransportRttSample,
  resetNetworkHealth,
} from "../src/networkHealth";
import { SOFTWARE_CONCURRENCY, refreshSoftware } from "../src/softwareInventory";
import { getMissionEventPage, setMultiplexSyncEnabledForTest, streamMission, type StreamEvent } from "../src/stream";

beforeEach(() => {
  localStorage.clear();
  cacheReset();
  forgetPrefetchPauses();
  setTransportBridgeEnabled(false);
  resetNetworkHealth();
  setApiUrl("http://core.test");
});

afterEach(() => {
  vi.useRealTimers();
  setMultiplexSyncEnabledForTest(false);
  clearConnection();
  setTransportBridgeEnabled(false);
  forgetPrefetchPauses();
  resetNetworkHealth();
  delete (window as unknown as { __TAURI__?: unknown }).__TAURI__;
  vi.unstubAllGlobals();
});

describe("connection reliability transport & prefetch bounds", () => {
  it("fast-retries idempotent GET on single-origin Load failed while leaving caller-owned POST retry state machines intact", async () => {
    let getCalls = 0;
    let rawPostCalls = 0;
    let idemPostCalls = 0;
    const seenIdemKeys: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const method = (init?.method ?? "GET").toUpperCase();
        const headers = (init?.headers ?? {}) as Record<string, string>;
        const idemKey = headers["Idempotency-Key"];
        if (method === "POST") {
          if (idemKey) {
            seenIdemKeys.push(idemKey);
            if (++idemPostCalls === 1) throw new TypeError("Load failed");
            return Response.json({ created: true, attempt: idemPostCalls });
          }
          rawPostCalls++;
          throw new TypeError("Load failed");
        }
        if (++getCalls === 1) {
          throw new TypeError("Load failed");
        }
        return Response.json({ ok: true, attempt: getCalls });
      }),
    );

    await expect(api<{ ok: boolean; attempt: number }>("/api/health", {})).resolves.toEqual({
      ok: true,
      attempt: 2,
    });
    expect(getCalls).toBe(2);

    await expect(api("/api/control/missions", { method: "POST", body: "{}" })).rejects.toThrow("Load failed");
    expect(rawPostCalls).toBe(1);

    // Single-origin POST surfaces lost-reply uncertainty to caller retry UX, then replays the same Idempotency-Key.
    const idemInit = withIdempotencyKey({ method: "POST", body: "{}" }, "idem-fixed-1");
    await expect(api("/api/control/missions", idemInit)).rejects.toThrow("Load failed");
    await expect(api<{ created: boolean; attempt: number }>("/api/control/missions", idemInit)).resolves.toEqual({
      created: true,
      attempt: 2,
    });
    expect(seenIdemKeys).toEqual(["idem-fixed-1", "idem-fixed-1"]);
  });

  it("fails over idempotent GET and Idempotency-Key POST across the 3-way Edge-diverse orbcore failover ring", async () => {
    expect(candidateApiUrls("https://orbcore.thomas.md")).toEqual([
      "https://orbcore.thomas.md",
      "https://agent-backend.thomas.md",
      "https://agent-backend.nico-best-pc-ever.ovh",
    ]);
    expect(candidateApiUrls("https://agent-backend.nico-best-pc-ever.ovh")).toEqual([
      "https://agent-backend.nico-best-pc-ever.ovh",
      "https://agent-backend.thomas.md",
      "https://orbcore.thomas.md",
    ]);
    expect(candidateApiUrls("https://agent-backend.thomas.md")).toEqual([
      "https://agent-backend.thomas.md",
      "https://orbcore.thomas.md",
      "https://agent-backend.nico-best-pc-ever.ovh",
    ]);

    setApiUrl("https://agent-backend.nico-best-pc-ever.ovh");
    const seenUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        seenUrls.push(url);
        if (url.startsWith("https://agent-backend.nico-best-pc-ever.ovh")) {
          throw new TypeError("Load failed");
        }
        return Response.json({ healthy: true });
      }),
    );

    const res = await transportFetch("/api/health");
    expect(await res.json()).toEqual({ healthy: true });
    expect(seenUrls).toEqual([
      "https://agent-backend.nico-best-pc-ever.ovh/api/health",
      "https://agent-backend.thomas.md/api/health",
    ]);

    // Subsequent Idempotency-Key POST skips the cooling-down .ovh endpoint and hits Cloudflare Edge immediately.
    const postRes = await transportFetch(
      "/api/control/missions/m1/opened",
      withIdempotencyKey({ method: "POST" }, "open-m1"),
    );
    expect(await postRes.json()).toEqual({ healthy: true });
    expect(seenUrls[seenUrls.length - 1]).toBe("https://agent-backend.thomas.md/api/control/missions/m1/opened");
  });

  it("routes requests through Tauri loopback transport bridge when available", async () => {
    const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "transport_bridge_configure") {
        expect(args).toEqual({ apiUrl: "https://agent-backend.nico-best-pc-ever.ovh" });
        return {
          proxy_base_url: "http://127.0.0.1:59123/__orb_tx/test-secret",
          configured_target: "https://agent-backend.nico-best-pc-ever.ovh",
        };
      }
      return null;
    });
    (window as unknown as { __TAURI__?: unknown }).__TAURI__ = { core: { invoke } };
    setTransportBridgeEnabled(true);
    setApiUrl("https://agent-backend.nico-best-pc-ever.ovh");

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => Response.json({ url: String(input) }));
    vi.stubGlobal("fetch", fetchMock);

    expect(await resolveTransportBase()).toBe("http://127.0.0.1:59123/__orb_tx/test-secret");
    const out = await api<{ url: string }>("/api/health", {});
    expect(out.url).toBe("http://127.0.0.1:59123/__orb_tx/test-secret/api/health");
    expect(invoke).toHaveBeenCalledTimes(1);
  });

  it("persists updated_since cursor with -2s overlap and marks delta responses as partialList", async () => {
    setConnection("http://cursor.test", "tok");
    let calls = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      calls++;
      const url = String(input);
      if (calls === 1) {
        expect(url).not.toContain("updated_since=");
        return Response.json([
          { id: "m-1", title: "One", status: "active", updated_at: "2026-11-03T07:00:10.000Z" },
        ]);
      }
      expect(url).toContain("updated_since=2026-11-03T07%3A00%3A08.000Z");
      return Response.json([]);
    });
    vi.stubGlobal("fetch", fetchMock);

    const full = await listMissions(200);
    expect(isPartialList(full)).toBe(false);
    const cursor = readMissionSyncCursor();
    expect(cursor?.cursor).toBe("2026-11-03T07:00:08.000Z");
    expect(cursor?.polls).toBe(0);

    const delta = await listMissions(200, { updatedSince: cursor!.cursor });
    expect(isPartialList(delta)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("queues background idempotent writes in durable outbox offline and replays with original key", async () => {
    setConnection("http://outbox.test", "tok");
    let offline = true;
    const seenKeys: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const headers = (init?.headers ?? {}) as Record<string, string>;
        if (headers["Idempotency-Key"]) seenKeys.push(headers["Idempotency-Key"]);
        if (offline) throw new TypeError("Load failed");
        return Response.json({ ok: true });
      }),
    );

    await expect(markMissionOpened("m-offline")).resolves.toBeUndefined();
    expect(seenKeys).toHaveLength(1);
    const originalKey = seenKeys[0];

    offline = false;
    const flushed = await flushDurableWriteOutbox();
    expect(flushed).toBe(1);
    expect(seenKeys).toEqual([originalKey, originalKey]);
    expect(await flushDurableWriteOutbox()).toBe(0);
  });

  it("multiplexes presentation and mission subscriptions over one /api/control/sync WebSocket and falls back to SSE on handshake failure", async () => {
    setConnection("http://sync.test", "secret-jwt");
    setMultiplexSyncEnabledForTest(true);

    class FakeSocket {
      static instances: FakeSocket[] = [];
      static OPEN = 1;
      static failConnect = false;
      readyState = 0;
      sent: Record<string, unknown>[] = [];
      onopen: (() => void) | null = null;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(public url: string, public protocols?: string | string[]) {
        FakeSocket.instances.push(this);
        queueMicrotask(() => {
          if (FakeSocket.failConnect) {
            this.readyState = 3;
            this.onerror?.();
            this.onclose?.();
            return;
          }
          this.readyState = FakeSocket.OPEN;
          this.onopen?.();
        });
      }
      send(payload: string) {
        this.sent.push(JSON.parse(payload) as Record<string, unknown>);
      }
      close() {
        this.readyState = 3;
        this.onclose?.();
      }
    }
    vi.stubGlobal("WebSocket", FakeSocket as unknown as typeof WebSocket);

    const presEvents: StreamEvent[] = [];
    const missionEvents: StreamEvent[] = [];
    const stopPres = streamMission(null, (ev) => presEvents.push(ev), () => {}, undefined, "presentation");
    const stopM1 = streamMission("m-1", (ev) => missionEvents.push(ev), () => {});

    await vi.waitFor(() => expect(FakeSocket.instances).toHaveLength(1));
    const sock = FakeSocket.instances[0];
    expect(sock.url).toBe("ws://sync.test/api/control/sync");
    expect(sock.protocols).toEqual(["orb-sync.v1", "jwt.secret-jwt"]);
    await vi.waitFor(() =>
      expect(sock.sent).toEqual(
        expect.arrayContaining([
          { op: "set_presentation", enabled: true },
          { op: "subscribe", mission_id: "m-1", max_payload: 4096 },
        ]),
      ),
    );

    sock.onmessage?.({
      data: JSON.stringify({ type: "mission_presentation", mission_id: "m-1", activity: "working" }),
    });
    sock.onmessage?.({
      data: JSON.stringify({ type: "mission_status_changed", mission_id: "m-1", sequence: 7, status: "active" }),
    });
    expect(presEvents).toHaveLength(1);
    expect(presEvents[0].type).toBe("mission_presentation");
    expect(missionEvents).toHaveLength(1);
    expect(missionEvents[0].sequence).toBe(7);

    stopM1();
    expect(sock.sent).toContainEqual({ op: "unsubscribe", mission_id: "m-1" });
    stopPres();
    setMultiplexSyncEnabledForTest(false);

    // Verify clean fallback to /api/control/stream SSE when WS upgrade fails across candidates.
    FakeSocket.instances = [];
    FakeSocket.failConnect = true;
    setMultiplexSyncEnabledForTest(true);
    let sseRequested = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (String(input).includes("/api/control/stream")) {
          sseRequested = true;
          return new Response(
            "event: mission_status_changed\ndata: {\"type\":\"mission_status_changed\",\"status\":\"completed\"}\n\n",
            {
              status: 200,
              headers: { "Content-Type": "text/event-stream" },
            },
          );
        }
        return Response.json({});
      }),
    );
    const fallbackEvents: StreamEvent[] = [];
    const stopFallback = streamMission("m-2", (ev) => fallbackEvents.push(ev), () => {});
    await vi.waitFor(() => expect(sseRequested).toBe(true), { timeout: 2500 });
    await vi.waitFor(() => expect(fallbackEvents.some((e) => e.type === "mission_status_changed")).toBe(true));
    stopFallback();
  });

  it("bounds live prefetch selection and pauses evicted transcripts instead of LRU-thrashing", async () => {
    const fleet = Array.from({ length: 50 }, (_, idx) => ({
      id: `m-${idx}`,
      status: "active",
      updated_at: new Date(Date.UTC(2026, 10, 3, 7, 0, idx)).toISOString(),
    }));
    const picked = selectLivePrefetchIds(fleet, (s) => s === "active");
    expect(picked).toHaveLength(MAX_LIVE_PREFETCH);
    expect(picked[0]).toBe("m-49");
    expect(picked[MAX_LIVE_PREFETCH - 1]).toBe(`m-${50 - MAX_LIVE_PREFETCH}`);

    setConnection("http://lru.test", "tok");
    let eventReads = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/queue?")) return Response.json([]);
        if (url.includes("/snapshot?")) return new Response("unavailable", { status: 404 });
        if (url.includes("/events?")) {
          eventReads++;
          return new Response(
            JSON.stringify([
              {
                id: 1,
                sequence: 1,
                event_type: "user_message",
                timestamp: "2026-11-03T07:00:00Z",
                content: "hello",
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
        return Response.json({});
      }),
    );

    prefetchTranscript("evict-me");
    await vi.waitFor(() => expect(peekReadyTranscript("evict-me")).toBeDefined());
    const readsAfterInitial = eventReads;
    expect(readsAfterInitial).toBeGreaterThanOrEqual(1);

    // Overflow pageCache (MAX = 64) so `evict-me:tx` gets evicted by LRU pressure.
    for (let i = 0; i < 70; i++) {
      cachePut(`filler-${i}`, { index: i });
    }
    expect(peekReadyTranscript("evict-me")).toBeUndefined();

    // Immediate speculative re-prefetch must stay paused rather than re-reading event logs every 5s.
    prefetchTranscript("evict-me");
    await new Promise((r) => setTimeout(r, 30));
    expect(eventReads).toBe(readsAfterInitial);
  });

  it("caps concurrent /api/software node queries to SOFTWARE_CONCURRENCY", async () => {
    setConnection("http://software-cap.test", "tok");
    let activeSoftwareCalls = 0;
    let maxObservedConcurrency = 0;

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/api/remote-nodes")) {
          return Response.json({
            nodes: Array.from({ length: 16 }, (_, i) => ({ id: `node-${i}`, status: "online" })),
          });
        }
        if (url.includes("/api/software")) {
          activeSoftwareCalls++;
          maxObservedConcurrency = Math.max(maxObservedConcurrency, activeSoftwareCalls);
          await new Promise((r) => setTimeout(r, 15));
          activeSoftwareCalls--;
          return Response.json({
            checked_at: Date.now(),
            runtime: { name: "node", version: "0.13.0", build: "dev", path: null, restart_required: false },
            components: [],
            jobs: [],
          });
        }
        return Response.json({});
      }),
    );

    await refreshSoftware(true);
    expect(maxObservedConcurrency).toBeGreaterThan(1);
    expect(maxObservedConcurrency).toBeLessThanOrEqual(SOFTWARE_CONCURRENCY);
  });

  it("jumps directly to tail + conversational spine instead of paging unboundedly when >2 pages behind", async () => {
    setConnection("http://tail-jump.test", "tok");
    putTranscript("tool-storm", {
      items: [],
      stream: [
        { type: "user_message", sequence: 10, eventId: "u10", data: { id: "u10", content: "Original prompt" } },
      ],
      fromLog: true,
      cursor: 100,
      before: 10,
      hasOlder: false,
    });

    const eventQueries: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = new URL(String(input));
        if (url.pathname === "/api/control/queue") {
          return Response.json([]);
        }
        if (url.pathname === "/api/control/missions/tool-storm/events") {
          eventQueries.push(url.search);
          const since = url.searchParams.get("since_seq");
          const before = url.searchParams.get("before_seq");
          const view = url.searchParams.get("view");
          if (since === "100") {
            return new Response(
              JSON.stringify([{ id: 101, mission_id: "tool-storm", sequence: 300, event_type: "tool_call", timestamp: "2026-11-03T00:00:00Z", tool_call_id: "t1", tool_name: "bash", content: "{}", metadata: {} }]),
              { status: 200, headers: { "Content-Type": "application/json", "X-Orb-Events-Protocol": "1", "X-Has-More": "true", "X-Next-Cursor": "300", "X-Page-Max-Sequence": "300", "X-Max-Sequence": "95000" } },
            );
          }
          if (since === "300") {
            return new Response(
              JSON.stringify([{ id: 301, mission_id: "tool-storm", sequence: 500, event_type: "tool_result", timestamp: "2026-11-03T00:00:01Z", tool_call_id: "t1", tool_name: "bash", content: "ok", metadata: {} }]),
              { status: 200, headers: { "Content-Type": "application/json", "X-Orb-Events-Protocol": "1", "X-Has-More": "true", "X-Next-Cursor": "500", "X-Page-Max-Sequence": "500", "X-Max-Sequence": "95000" } },
            );
          }
          if (!since && !before && !view) {
            return new Response(
              JSON.stringify([{ id: 94999, mission_id: "tool-storm", sequence: 95000, event_type: "tool_call", timestamp: "2026-11-03T01:00:00Z", tool_call_id: "t999", tool_name: "bash", content: "{}", metadata: {} }]),
              { status: 200, headers: { "Content-Type": "application/json", "X-Orb-Events-Protocol": "1", "X-Has-More": "true", "X-Next-Cursor": "94800", "X-Page-Max-Sequence": "95000", "X-Max-Sequence": "95000" } },
            );
          }
          if (before === "94800" && view === "transcript") {
            return new Response(
              JSON.stringify([
                { id: 10, mission_id: "tool-storm", sequence: 10, event_type: "user_message", timestamp: "2026-11-03T00:00:00Z", event_id: "u10", content: "Original prompt", metadata: {} },
                { id: 50000, mission_id: "tool-storm", sequence: 50000, event_type: "assistant_message", timestamp: "2026-11-03T00:30:00Z", event_id: "a50000", content: "Midway report", metadata: {} },
              ]),
              { status: 200, headers: { "Content-Type": "application/json", "X-Orb-Events-Protocol": "1", "X-Has-More": "false", "X-Next-Cursor": "10", "X-Page-Max-Sequence": "50000", "X-Max-Sequence": "95000" } },
            );
          }
          throw new Error(`Unexpected events query: ${url.search}`);
        }
        return Response.json({});
      }),
    );

    const snap = await refreshTranscript("tool-storm");
    expect(eventQueries).toHaveLength(4);
    expect(snap.cursor).toBe(95000);
    expect(snap.before).toBe(94800);
    expect(snap.hasOlder).toBe(true);
    expect(snap.items.some((i) => i.kind === "text" && i.text.includes("Midway report"))).toBe(true);
  });

  it("requests exclude_content=true when discovering published artifacts on mission open", async () => {
    setConnection("http://artifacts-light.test", "tok");
    let seenUrl = "";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/events?")) {
          seenUrl = url;
          return Response.json([
            {
              metadata: {
                shared_files: [
                  { name: "report.pdf", url: "http://artifacts-light.test/api/fs/download?path=%2Ftmp%2Freport.pdf" },
                ],
              },
            },
          ]);
        }
        return Response.json({ sources: [] });
      }),
    );

    const resolver = createFileClient({
      mission: {
        id: "m-art",
        status: "active",
        title: "Art",
        history: [],
        created_at: "2026-11-03T00:00:00Z",
        updated_at: "2026-11-03T00:00:00Z",
      },
    });
    const roots = await resolver.roots();
    expect(seenUrl).toContain("exclude_content=true");
    expect(roots.some((r) => r.id === "artifacts" && r.available)).toBe(true);
  });

  it("keeps reconnecting /api/control/sync across backend restarts once everReady without exploding into SSE streams", async () => {
    setConnection("https://orbcore.thomas.md", "secret-jwt");
    setMultiplexSyncEnabledForTest(true);

    class RestartingSocket {
      static instances: RestartingSocket[] = [];
      static OPEN = 1;
      static failConnect = false;
      readyState = 0;
      sent: Record<string, unknown>[] = [];
      onopen: (() => void) | null = null;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(public url: string, public protocols?: string | string[]) {
        RestartingSocket.instances.push(this);
        queueMicrotask(() => {
          if (RestartingSocket.failConnect) {
            this.readyState = 3;
            this.onerror?.();
            this.onclose?.();
            return;
          }
          this.readyState = RestartingSocket.OPEN;
          this.onopen?.();
        });
      }
      send(payload: string) {
        this.sent.push(JSON.parse(payload) as Record<string, unknown>);
      }
      close() {
        this.readyState = 3;
        this.onclose?.();
      }
    }
    vi.stubGlobal("WebSocket", RestartingSocket as unknown as typeof WebSocket);
    let sseRequested = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        if (String(input).includes("/api/control/stream")) sseRequested = true;
        return Response.json({});
      }),
    );

    const events: StreamEvent[] = [];
    const stop = streamMission("m-restart", (ev) => events.push(ev), () => {}, undefined, undefined, undefined, undefined, 41);
    await vi.waitFor(() => expect(RestartingSocket.instances).toHaveLength(1));
    const initial = RestartingSocket.instances[0];
    initial.onmessage?.({
      data: JSON.stringify({ type: "mission_status_changed", mission_id: "m-restart", sequence: 42, status: "active" }),
    });
    expect(events).toHaveLength(1);

    // Simulate a backend deploy where 3 consecutive WS handshakes fail before coming back.
    RestartingSocket.failConnect = true;
    initial.close();
    for (let i = 0; i < 3; i++) {
      const prevCount = RestartingSocket.instances.length;
      window.dispatchEvent(new Event("online"));
      await vi.waitFor(() => expect(RestartingSocket.instances.length).toBeGreaterThan(prevCount));
    }
    expect(sseRequested).toBe(false);

    // Backend finishes restarting; next online wake-up reconnects WS and replays from highestSeq=42.
    RestartingSocket.failConnect = false;
    window.dispatchEvent(new Event("online"));
    await vi.waitFor(() => {
      const latest = RestartingSocket.instances[RestartingSocket.instances.length - 1];
      expect(latest.sent).toContainEqual({ op: "subscribe", mission_id: "m-restart", since_seq: 42, max_payload: 4096 });
    });
    expect(sseRequested).toBe(false);
    stop();
  });

  it("routes SSE streams across sharded loopback stream ports so WKWebView REST pool never starves", async () => {
    (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
      invoke: vi.fn(async (cmd: string) => {
        if (cmd === "transport_bridge_configure") {
          return {
            proxy_base_url: "http://127.0.0.1:50000/__orb_tx/tok",
            stream_proxy_base_urls: [
              "http://127.0.0.1:50001/__orb_tx/tok",
              "http://127.0.0.1:50002/__orb_tx/tok",
            ],
            configured_target: "https://orbcore.thomas.md",
          };
        }
        return null;
      }),
    };
    setApiUrl("https://orbcore.thomas.md");
    setTransportBridgeEnabled(true);
    const seenUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        seenUrls.push(String(input));
        return Response.json({ ok: true });
      }),
    );

    await transportFetch("/api/control/missions?limit=20");
    await transportFetch("/api/control/stream?mission=m1", { headers: { Accept: "text/event-stream" } });
    await transportFetch("/api/projects/demo/context/stream");
    await transportFetch("/api/control/stream?mission=m2", { headers: { Accept: "text/event-stream" } });

    expect(seenUrls).toEqual([
      "http://127.0.0.1:50000/__orb_tx/tok/api/control/missions?limit=20",
      "http://127.0.0.1:50001/__orb_tx/tok/api/control/stream?mission=m1",
      "http://127.0.0.1:50002/__orb_tx/tok/api/projects/demo/context/stream",
      "http://127.0.0.1:50001/__orb_tx/tok/api/control/stream?mission=m2",
    ]);
    delete (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
  });

  it("re-arms negative capability latches on server build epoch bump and falls back cleanly after repeated WS failures via orbTransportEpochStep (SM-26)", async () => {
    const {
      currentCapabilityEpochKey,
      getServerBuild,
      recordServerBuild,
    } = await import("../src/api");
    const { classifyConflictError } = await import("../src/conflictClassification");

    setApiUrl("https://orbcore.thomas.md");
    recordServerBuild("build-2026-11-08-a");
    expect(getServerBuild()).toBe("build-2026-11-08-a");
    const scopeA = currentCapabilityEpochKey();
    expect(scopeA).toContain("build-2026-11-08-a");

    expect(recordServerBuild("build-2026-11-08-b")).toBe(true);
    const scopeB = currentCapabilityEpochKey();
    expect(scopeB).not.toBe(scopeA);
    expect(scopeB).toContain("build-2026-11-08-b");

    // Typed 409 classifier distinguishes structured conflict variants deterministically.
    expect(
      classifyConflictError({
        status: 409,
        detail: JSON.stringify({ code: "non_terminal_run" }),
      }),
    ).toEqual({ tag: "non_terminal_run", retryable: true });
    expect(
      classifyConflictError({
        status: 409,
        detail: JSON.stringify({ code: "stale_epoch" }),
      }),
    ).toEqual({ tag: "stale_receipt", retryable: false });
    expect(
      classifyConflictError({
        status: 409,
        detail: JSON.stringify({ code: "already_ended" }),
      }),
    ).toEqual({ tag: "already_ended", retryable: false });
  });

  it("clears networkHealth 'reconnecting' once SSE fallback connects, stays quiet across background WS reprobes, and surfaces genuine SSE drops", async () => {
    setConnection("http://single-core.test", "secret-jwt");
    setMultiplexSyncEnabledForTest(true);

    class FailingSocket {
      static instances: FailingSocket[] = [];
      static OPEN = 1;
      readyState = 0;
      onopen: (() => void) | null = null;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      constructor(public url: string, public protocols?: string | string[]) {
        FailingSocket.instances.push(this);
        queueMicrotask(() => {
          this.readyState = 3;
          this.onerror?.();
          this.onclose?.();
        });
      }
      send() {}
      close() {
        this.readyState = 3;
        this.onclose?.();
      }
    }
    vi.stubGlobal("WebSocket", FailingSocket as unknown as typeof WebSocket);

    let closeSseStream!: () => void;
    let sseOpenCount = 0;
    let failNextSse = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (!url.includes("/api/control/stream")) return Response.json({});
        if (failNextSse) return new Response("Bad Gateway", { status: 502 });
        sseOpenCount++;
        const stream = new ReadableStream<Uint8Array>({
          start(ctrl) {
            ctrl.enqueue(
              new TextEncoder().encode(
                'event: mission_status_changed\ndata: {"mission_id":"m-sse","sequence":7,"status":"active"}\n\n',
              ),
            );
            closeSseStream = () => {
              try {
                ctrl.close();
              } catch {
                /* already closed */
              }
            };
          },
        });
        return new Response(stream, {
          status: 200,
          headers: { "Content-Type": "text/event-stream", "X-Orb-Transport-Rtt-Ms": "42" },
        });
      }),
    );

    const received: StreamEvent[] = [];
    const stop = streamMission("m-sse", (ev) => received.push(ev), () => {});

    // First WS attempt fails -> status enters "reconnecting" while retrying WS.
    await vi.waitFor(() => expect(FailingSocket.instances.length).toBeGreaterThanOrEqual(1));
    expect(networkHealth()).toBe("reconnecting");

    // Second WS failure crosses threshold (2) -> SSE fallback opens and immediately clears "reconnecting"!
    await vi.waitFor(() => expect(sseOpenCount).toBe(1), { timeout: 2500 });
    await vi.waitFor(() => expect(received).toHaveLength(1));
    expect(networkHealth()).toBe("healthy");
    expect(networkHealthSnapshot().wsConnected).toBeNull();

    // Trigger a background WS reprobe (`online` wake event while in mode=1 SSE fallback) -> WS fails again,
    // but SSE fallback is still connected so `networkHealth()` MUST stay "healthy" without flashing "reconnecting"!
    const beforeReprobe = FailingSocket.instances.length;
    window.dispatchEvent(new Event("online"));
    await vi.waitFor(() => expect(FailingSocket.instances.length).toBeGreaterThan(beforeReprobe));
    expect(networkHealth()).toBe("healthy");
    expect(networkHealthSnapshot().wsConnected).toBeNull();

    // Now drop the active SSE stream while the backend is unreachable -> `networkHealth()` surfaces "reconnecting".
    failNextSse = true;
    closeSseStream();
    await vi.waitFor(() => expect(networkHealth()).toBe("reconnecting"));

    stop();
    expect(networkHealthSnapshot().wsConnected).toBeNull();
  });

  it("clears consecutiveFailures on non-RTT-sampled routes without inflating SRTT", async () => {
    setConnection("https://orbcore.thomas.md", "tok-rec");
    recordTransportRttSample(60);
    recordTransportFailure();
    expect(networkHealth()).toBe("reconnecting");
    expect(networkHealthSnapshot().srttMs).toBe(60);

    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "X-Orb-Transport-Rtt-Ms": "9500",
            "X-Orb-Upstream-Origin": "https://orbcore.thomas.md",
          },
        }),
      ),
    );

    // P1 POST route is allowed through while P2 is paused on consecutiveFailures=1,
    // and must clear consecutiveFailures on <500 recovery without polluting SRTT:
    await transportFetch("/api/control/missions/m1/inbox-digest", { method: "POST", body: "{}" });
    expect(networkHealth()).toBe("healthy");
    expect(networkHealthSnapshot().consecutiveFailures).toBe(0);
    expect(networkHealthSnapshot().srttMs).toBe(60);

    // Once consecutiveFailures is 0, P2 compute-bound GETs also run without inflating SRTT:
    recordTransportFailure();
    expect(networkHealth()).toBe("reconnecting");
    await transportFetch("/api/control/missions/m1/opened", { method: "POST", body: "{}" });
    await transportFetch("/api/providers/antigravity-models");
    expect(networkHealth()).toBe("healthy");
    expect(networkHealthSnapshot().srttMs).toBe(60);
  });

  it("fast-retries GET once on mid-body stream reset while keeping malformed JSON non-retryable", async () => {
    let missionCalls = 0;
    let eventCalls = 0;
    let badJsonCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/api/control/missions/m-drop/events")) {
          if (++eventCalls === 1) {
            return {
              ok: true,
              status: 200,
              headers: new Headers({ "X-Orb-Events-Protocol": "1", "X-Has-More": "false" }),
              text: async () => {
                throw new TypeError("Load failed");
              },
            } as unknown as Response;
          }
          return new Response("[]", {
            status: 200,
            headers: {
              "Content-Type": "application/json",
              "X-Orb-Events-Protocol": "1",
              "X-Has-More": "false",
            },
          });
        }
        if (url.endsWith("/api/bad-json")) {
          badJsonCalls++;
          return new Response("<html>not json</html>", { status: 200 });
        }
        if (++missionCalls === 1) {
          return {
            ok: true,
            status: 200,
            headers: new Headers(),
            text: async () => {
              throw new TypeError("Load failed");
            },
          } as unknown as Response;
        }
        return Response.json({ ok: true, calls: missionCalls });
      }),
    );

    await expect(api<{ ok: boolean; calls: number }>("/api/health", {})).resolves.toEqual({
      ok: true,
      calls: 2,
    });
    expect(missionCalls).toBe(2);

    const page = await getMissionEventPage("m-drop");
    expect(page.events).toEqual([]);
    expect(eventCalls).toBe(2);

    await expect(api("/api/bad-json", {})).rejects.toThrow("Couldn’t read the server response");
    expect(badJsonCalls).toBe(1);
  });

  it("does not degrade Core networkHealth when a remote worker node proxy returns 502", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/api/providers/antigravity-models?node_id=ashur")) {
          return new Response(JSON.stringify({ error: "node ashur unreachable" }), {
            status: 502,
            headers: { "Content-Type": "application/json" },
          });
        }
        if (url.includes("/api/providers/antigravity-models?node_id=core")) {
          return new Response(JSON.stringify({ error: "core upstream down" }), {
            status: 502,
            headers: { "Content-Type": "application/json" },
          });
        }
        return Response.json({ ok: true });
      }),
    );

    await transportFetch("/api/health");
    expect(networkHealth()).toBe("healthy");

    const workerRes = await transportFetch("/api/providers/antigravity-models?node_id=ashur");
    expect(workerRes.status).toBe(502);
    expect(networkHealth()).toBe("healthy");
    expect(networkHealthSnapshot().consecutiveFailures).toBe(0);

    const coreRes = await transportFetch("/api/providers/antigravity-models?node_id=core");
    expect(coreRes.status).toBe(502);
    expect(networkHealth()).toBe("reconnecting");

    // Pre-response Core transport failure (DNS/TCP/TLS Load failed) on a worker-model GET
    // still cools down the broken Core origin and fails over to a healthy Core standby.
    resetNetworkHealth();
    setApiUrl("https://orbcore.thomas.md");
    const seenWorkerFailover: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        seenWorkerFailover.push(url);
        if (url.startsWith("https://orbcore.thomas.md")) {
          throw new TypeError("Load failed");
        }
        return Response.json({ models: [{ id: "gemini-2.5-pro" }] });
      }),
    );

    const failoverRes = await transportFetch("/api/providers/antigravity-models?node_id=ashur");
    expect(failoverRes.status).toBe(200);
    expect(seenWorkerFailover).toEqual([
      "https://orbcore.thomas.md/api/providers/antigravity-models?node_id=ashur",
      "https://agent-backend.thomas.md/api/providers/antigravity-models?node_id=ashur",
    ]);
  });
});
