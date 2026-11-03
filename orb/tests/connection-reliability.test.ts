import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  api,
  candidateApiUrls,
  clearConnection,
  listMissions,
  resolveTransportBase,
  setApiUrl,
  setConnection,
  setTransportBridgeEnabled,
  transportFetch,
} from "../src/api";
import { cachePut, cacheReset } from "../src/pageCache";
import {
  MAX_LIVE_PREFETCH,
  forgetPrefetchPauses,
  peekReadyTranscript,
  prefetchTranscript,
  selectLivePrefetchIds,
} from "../src/missionCache";
import { SOFTWARE_CONCURRENCY, refreshSoftware } from "../src/softwareInventory";

beforeEach(() => {
  localStorage.clear();
  cacheReset();
  forgetPrefetchPauses();
  setTransportBridgeEnabled(false);
  setApiUrl("http://core.test");
});

afterEach(() => {
  clearConnection();
  setTransportBridgeEnabled(false);
  forgetPrefetchPauses();
  delete (window as unknown as { __TAURI__?: unknown }).__TAURI__;
  vi.unstubAllGlobals();
});

describe("connection reliability transport & prefetch bounds", () => {
  it("retries idempotent GET once on transient TypeError(Load failed), never POST", async () => {
    let getCalls = 0;
    let postCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const method = (init?.method ?? "GET").toUpperCase();
        if (method === "POST") {
          postCalls++;
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
    expect(postCalls).toBe(1);
  });

  it("fails over idempotent GET across paired direct and fallback endpoints", async () => {
    expect(candidateApiUrls("https://agent-backend.nico-best-pc-ever.ovh")).toEqual([
      "https://agent-backend.nico-best-pc-ever.ovh",
      "https://agent-backend.thomas.md",
    ]);
    expect(candidateApiUrls("https://agent-backend.thomas.md")).toEqual([
      "https://agent-backend.thomas.md",
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

  it("passes updated_since when explicitly requested on listMissions", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toContain("updated_since=2026-11-03T07%3A00%3A00Z");
      return Response.json([]);
    });
    vi.stubGlobal("fetch", fetchMock);

    await listMissions(200, { updatedSince: "2026-11-03T07:00:00Z" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
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
});
