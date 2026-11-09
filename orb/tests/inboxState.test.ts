import { beforeEach, expect, it, vi } from "vitest";
const api = vi.hoisted(() => ({ version: 1, token: "test", connected: true }));
vi.mock("../src/api", () => ({ connectionVersion: () => api.version, getApiUrl: () => "https://test.invalid", getJwt: () => api.token, isConnected: () => api.connected }));
beforeEach(() => { vi.resetModules(); api.version++; api.connected = true; localStorage.clear(); vi.unstubAllGlobals(); });
it("serializes writes for a key and overlays a local change on a late read without discarding unrelated server state", async () => {
  let release!: (r: Response) => void;
  const calls: string[] = [];
  vi.stubGlobal("fetch", vi.fn((url: string, init?: RequestInit) => {
    calls.push(`${init?.method ?? "GET"} ${url}`);
    if (!init?.method) return new Promise<Response>(r => { release = r; });
    return Promise.resolve(new Response(null, { status: 204 }));
  }));
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  const reading = readInboxState();
  writeInboxState("seen/mission", { stamp: -123 });
  writeInboxState("preferences", { aiSummary: false, includeAutonomous: true, model: "builtin/fast" });
  release(new Response(JSON.stringify({ "seen:mission": 1, "seen:other": 99 })));
  expect(await reading).toMatchObject({ "seen:mission": -123, "seen:other": 99 });
  await vi.waitFor(() => expect(calls.filter(c => c.startsWith("PUT"))).toHaveLength(2));
});
it("rejects a late response from a previous connection", async () => {
  let release!: (r: Response) => void;
  vi.stubGlobal("fetch", () => new Promise<Response>(r => { release = r; }));
  const { readInboxState } = await import("../src/inboxState");
  const reading = readInboxState(); api.version++;
  release(new Response(JSON.stringify({ preferences: { includeAutonomous: true } })));
  expect(await reading).toBeUndefined();
});

it("overlays an unsent local receipt on read while retrying it and still importing other server entries", async () => {
  const fetcher = vi.fn(async (_url: string, init?: RequestInit) => {
    if (init?.method === "PUT") {
      return fetcher.mock.calls.filter(c => c[1]?.method === "PUT").length === 1
        ? new Response(null, { status: 503 })
        : new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({ "seen:mission": 100, "seen:other": 777, _versions: { "seen:mission": 2, "seen:other": 4 } }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("seen/mission", { stamp: -123 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(await readInboxState()).toMatchObject({ "seen:mission": -123, "seen:other": 777 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3));
  expect(fetcher.mock.calls[2][1]?.method).toBe("PUT");
});

it("reads fresh server updates and _versions for entry B while entry A is still in-flight", async () => {
  let releasePut!: (r: Response) => void;
  const fetcher = vi.fn((url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/seen/a")) return new Promise<Response>(r => { releasePut = r; });
    if (init?.method === "PUT") return Promise.resolve(new Response(null, { status: 204 }));
    return Promise.resolve(new Response(JSON.stringify({
      "seen:a": 10,
      "seen:b": 500,
      preferences: { aiSummary: false, includeAutonomous: true, model: "builtin/fast" },
      _versions: { "seen:a": 1, "seen:b": 7, preferences: 3 },
    })));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("seen/a", { stamp: 200 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));

  const state = await readInboxState();
  expect(state).toMatchObject({
    "seen:a": 200,
    "seen:b": 500,
    preferences: { aiSummary: false, includeAutonomous: true, model: "builtin/fast" },
  });

  writeInboxState("seen/b", { stamp: 600 });
  await vi.waitFor(() => expect(fetcher.mock.calls.some(c => String(c[0]).endsWith("/seen/b") && c[1]?.method === "PUT")).toBe(true));
  const putB = fetcher.mock.calls.find(c => String(c[0]).endsWith("/seen/b") && c[1]?.method === "PUT")!;
  expect(JSON.parse(putB[1]!.body as string).expectedVersion).toBe(7);

  releasePut(new Response(null, { status: 204 }));
});

it("refreshes _versions on 409 conflict, rebases entry A once, and converges without starving reads or entry B", async () => {
  let serverVersionA = 4;
  let serverStampA = 100;
  let putACount = 0;
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/seen/a")) {
      putACount++;
      const body = JSON.parse(init.body as string);
      if (body.expectedVersion !== serverVersionA) {
        return new Response(null, { status: 409 });
      }
      serverVersionA++;
      serverStampA = body.stamp;
      return new Response(null, { status: 204 });
    }
    if (init?.method === "PUT" && url.endsWith("/preferences")) {
      return new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({
      "seen:a": serverStampA,
      "seen:b": 321,
      _versions: { "seen:a": serverVersionA, "seen:b": 6, preferences: 2 },
    }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  writeInboxState("seen/a", { stamp: 250 });
  writeInboxState("preferences", { aiSummary: true, includeAutonomous: false, model: "builtin/smart" });

  await vi.waitFor(() => expect(putACount).toBe(2));
  await vi.waitFor(() => expect(fetcher.mock.calls.some(c => String(c[0]).endsWith("/preferences") && c[1]?.method === "PUT")).toBe(true));
  await new Promise(resolve => setTimeout(resolve, 0));

  const putACalls = fetcher.mock.calls.filter(c => String(c[0]).endsWith("/seen/a") && c[1]?.method === "PUT");
  expect(JSON.parse(putACalls[0][1]!.body as string).expectedVersion).toBe(0);
  expect(JSON.parse(putACalls[1][1]!.body as string).expectedVersion).toBe(4);

  const callsAfterConverge = fetcher.mock.calls.length;
  const latest = await readInboxState();
  expect(latest).toMatchObject({ "seen:a": 250, "seen:b": 321 });
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(fetcher.mock.calls.length).toBe(callsAfterConverge + 1);
  expect(putACount).toBe(2);
});

it("keeps overlaying a committed local write over a stale in-flight GET until server _versions catches up", async () => {
  let releaseGet!: (r: Response) => void;
  let serverVersion = 3;
  let serverStamp = 100;
  const fetcher = vi.fn((url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/seen/m")) {
      serverVersion = 4;
      serverStamp = 900;
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    if (!init?.method && fetcher.mock.calls.filter(c => !c[1]?.method).length === 2) {
      return new Promise<Response>(r => { releaseGet = r; });
    }
    return Promise.resolve(new Response(JSON.stringify({
      "seen:m": serverStamp,
      "seen:other": 55,
      _versions: { "seen:m": serverVersion, "seen:other": 2 },
    })));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  await readInboxState();
  writeInboxState("seen/m", { stamp: 900 });
  const staleReading = readInboxState();

  await vi.waitFor(() => expect(fetcher.mock.calls.some(c => c[1]?.method === "PUT")).toBe(true));
  await new Promise(resolve => setTimeout(resolve, 0));

  releaseGet(new Response(JSON.stringify({
    "seen:m": 100,
    "seen:other": 55,
    _versions: { "seen:m": 3, "seen:other": 2 },
  })));
  expect(await staleReading).toMatchObject({ "seen:m": 900, "seen:other": 55 });

  serverVersion = 5;
  serverStamp = 1200;
  expect(await readInboxState()).toMatchObject({ "seen:m": 1200, "seen:other": 55 });
});

it("discards malformed, null, or non-object localStorage outbox entries without throwing", async () => {
  const { sideQuestionKey } = await import("../src/sideQuestionStorage");
  localStorage.setItem(sideQuestionKey("inbox-state:outbox:v1"), JSON.stringify({
    "seen/null-entry": null,
    "seen/primitive": "corrupt",
    "seen/array": [1, 2, 3],
    "seen/bad-flags": { body: { stamp: 10, clientId: "00000000-0000-0000-0000-000000000001", mutationSeq: 1, expectedVersion: 0 }, serial: 1, conflict: "yes" },
    "seen/zero-stamp": { body: { stamp: 0, clientId: "00000000-0000-0000-0000-000000000001", mutationSeq: 1, expectedVersion: 0 }, serial: 1 },
    "unknown/path": { body: { stamp: 10, clientId: "00000000-0000-0000-0000-000000000001", mutationSeq: 1, expectedVersion: 0 }, serial: 1 },
    preferences: { body: { aiSummary: "invalid", includeAutonomous: false, model: "builtin/fast", clientId: "00000000-0000-0000-0000-000000000001", mutationSeq: 1, expectedVersion: 0 }, serial: 1 },
    "seen/valid": {
      body: { stamp: 777, clientId: "00000000-0000-0000-0000-000000000001", mutationSeq: 2, expectedVersion: 1 },
      serial: 2,
    },
  }));
  const puts: string[] = [];
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT") {
      puts.push(url);
      return new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({ "seen:valid": 100, _versions: { "seen:valid": 1 } }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState } = await import("../src/inboxState");

  const state = await readInboxState();
  expect(state).toMatchObject({ "seen:valid": 777 });
  await vi.waitFor(() => expect(puts).toHaveLength(1));
  expect(puts[0]).toContain("/seen/valid");
});

it("generates a fresh mutationSeq when rebasing on 409 so shared multi-tab clientId never drops the retry", async () => {
  localStorage.setItem("orb.inbox.client.v1", "00000000-0000-0000-0000-000000000009");
  localStorage.setItem("orb.inbox.sequence.v1", "1");
  let serverVersion = 2;
  let serverSeq = 5;
  let serverModel = "builtin/fast";
  let putCount = 0;
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/preferences")) {
      putCount++;
      const body = JSON.parse(init.body as string);
      if (putCount === 1) {
        localStorage.setItem("orb.inbox.sequence.v1", String(serverSeq));
        return new Response(JSON.stringify({
          preferences: { aiSummary: false, includeAutonomous: true, model: serverModel },
          _versions: { preferences: serverVersion },
        }), { status: 409, headers: { "Content-Type": "application/json" } });
      }
      if (body.expectedVersion !== serverVersion) {
        return new Response(JSON.stringify({ _versions: { preferences: serverVersion } }), { status: 409 });
      }
      if (body.mutationSeq > serverSeq) {
        serverVersion++;
        serverSeq = body.mutationSeq;
        serverModel = body.model;
      }
      return new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({
      preferences: { aiSummary: true, includeAutonomous: false, model: serverModel },
      _versions: { preferences: serverVersion },
    }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  writeInboxState("preferences", { aiSummary: true, includeAutonomous: false, model: "builtin/smart" });
  await vi.waitFor(() => expect(putCount).toBe(2));
  await new Promise(resolve => setTimeout(resolve, 0));

  const puts = fetcher.mock.calls.filter(c => String(c[0]).endsWith("/preferences") && c[1]?.method === "PUT");
  const firstBody = JSON.parse(puts[0][1]!.body as string);
  const rebasedBody = JSON.parse(puts[1][1]!.body as string);
  expect(firstBody).toMatchObject({ expectedVersion: 0, mutationSeq: 2 });
  expect(rebasedBody).toMatchObject({ expectedVersion: 2, mutationSeq: 6 });
  expect(serverModel).toBe("builtin/smart");
  expect((await readInboxState())?.preferences?.model).toBe("builtin/smart");
});

it("retires a subsumed monotonic seen update on 409 without redundant write loops", async () => {
  let putCount = 0;
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/seen/a")) {
      putCount++;
      return new Response(JSON.stringify({
        "seen:a": 500,
        _versions: { "seen:a": 8 },
      }), { status: 409, headers: { "Content-Type": "application/json" } });
    }
    return new Response(JSON.stringify({
      "seen:a": 500,
      _versions: { "seen:a": 8 },
    }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  writeInboxState("seen/a", { stamp: 300 });
  await vi.waitFor(() => expect(putCount).toBe(1));
  await new Promise(resolve => setTimeout(resolve, 0));

  const state = await readInboxState();
  expect(state).toMatchObject({ "seen:a": 500 });
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(putCount).toBe(1);
});

it("bounds 409 conflict rebase to at most one retry and adopts server state on repeated conflict", async () => {
  let putCount = 0;
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/preferences")) {
      putCount++;
      return new Response(null, { status: 409 });
    }
    return new Response(JSON.stringify({
      preferences: { inboxEnabled: true, aiSummary: false, summaryMode: "eco", includeAutonomous: true, model: "builtin/fast" },
      _versions: { preferences: 10 + putCount },
    }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  writeInboxState("preferences", { aiSummary: true, includeAutonomous: false, model: "builtin/smart" });
  await vi.waitFor(() => expect(putCount).toBe(2));
  await new Promise(resolve => setTimeout(resolve, 0));

  const state = await readInboxState();
  expect(state?.preferences?.model).toBe("builtin/fast");
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(putCount).toBe(2);
});

it("rebases an explicit negative seen stamp (mark unread) on 409 even when server has a newer positive stamp", async () => {
  let serverVersion = 5;
  let putCount = 0;
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "PUT" && url.endsWith("/seen/a")) {
      putCount++;
      const body = JSON.parse(init.body as string);
      if (body.expectedVersion !== serverVersion) return new Response(null, { status: 409 });
      serverVersion++;
      return new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({ "seen:a": 999, _versions: { "seen:a": serverVersion } }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { writeInboxState } = await import("../src/inboxState");

  writeInboxState("seen/a", { stamp: -500 });
  await vi.waitFor(() => expect(putCount).toBe(2));
  const puts = fetcher.mock.calls.filter(c => String(c[0]).endsWith("/seen/a") && c[1]?.method === "PUT");
  expect(JSON.parse(puts[1][1]!.body as string)).toMatchObject({ stamp: -500, expectedVersion: 5 });
});

it("does not let a deleted mission receipt block later shared-state reads", async () => {
  const fetcher = vi.fn().mockResolvedValueOnce(new Response(null, { status: 404 })).mockResolvedValue(new Response(JSON.stringify({ preferences: { aiSummary: false, includeAutonomous: true, model: "builtin/fast" } })));
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("seen/deleted-mission", { stamp: 123 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));
  expect((await readInboxState())?.preferences?.model).toBe("builtin/fast");
  expect(fetcher.mock.calls[1][1].method).toBeUndefined();
});

it("preserves an offline mutation identity and base revision when retrying", async () => {
  const fetcher = vi.fn(async (_url: string, init?: RequestInit) => {
    if (init?.method === "PUT") {
      return fetcher.mock.calls.filter(c => c[1]?.method === "PUT").length === 1
        ? new Response(null, { status: 503 })
        : new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify({ _versions: { preferences: 3 } }));
  });
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("preferences", { aiSummary: false, includeAutonomous: true, model: "builtin/fast", clientId: "persisted-client", mutationSeq: 12, expectedVersion: 3 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));
  await readInboxState();
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3));
  expect(JSON.parse(fetcher.mock.calls[2][1]!.body as string)).toMatchObject({ clientId: "persisted-client", mutationSeq: 12, expectedVersion: 3 });
});

it("uses Core revisions and keeps a monotonic device identity across module reloads", async () => {
  const fetcher = vi.fn(async (_url: string, init?: RequestInit) => init?.method
    ? new Response(null, { status: 204 })
    : new Response(JSON.stringify({ _versions: { preferences: 9, "seen:mission": 5 } })));
  vi.stubGlobal("fetch", fetcher);
  let state = await import("../src/inboxState");
  await state.readInboxState();
  state.writeInboxState("preferences", { aiSummary: true, includeAutonomous: false, model: "builtin/smart" });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
  await new Promise(resolve => setTimeout(resolve, 0));
  const first = JSON.parse(fetcher.mock.calls[1][1]!.body as string);
  expect(first.expectedVersion).toBe(9);
  state.writeInboxState("seen/mission", { stamp: 123 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3));
  await new Promise(resolve => setTimeout(resolve, 0));
  const second = JSON.parse(fetcher.mock.calls[2][1]!.body as string);
  expect(second.expectedVersion).toBe(5);
  expect(second.clientId).toBe(first.clientId);
  expect(second.mutationSeq).toBeGreaterThan(first.mutationSeq);
  vi.resetModules(); state = await import("../src/inboxState");
  state.writeInboxState("seen/mission", { stamp: 456 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(4));
  const restored = JSON.parse(fetcher.mock.calls[3][1]!.body as string);
  expect(restored.clientId).toBe(first.clientId);
  expect(restored.mutationSeq).toBeGreaterThan(second.mutationSeq);
});

// Inbox settings migrate into the shared inbox state.
it("seeds empty Core preferences from existing settings and imports existing remote choices without echoing", async () => {
  const write = vi.fn();
  vi.doMock("../src/inboxState", () => ({ writeInboxState: write }));
  const { inboxConfig, saveInboxConfig, applySharedInboxPreferences } = await import("../src/inboxSettings");
  const legacyLocal = { aiSummary: false, includeAutonomous: true, model: "builtin/fast" };
  const expectedLocal = {
    ...legacyLocal,
    inboxEnabled: true,
    summaryMode: "standard" as const,
  };
  saveInboxConfig(legacyLocal, false);
  applySharedInboxPreferences(undefined);
  expect(inboxConfig()).toEqual(expectedLocal);
  expect(write).toHaveBeenCalledWith("preferences", expectedLocal);
  write.mockClear();
  const remote = {
    inboxEnabled: false,
    aiSummary: true,
    includeAutonomous: false,
    model: "builtin/reasoning",
    summaryMode: "eco" as const,
  };
  applySharedInboxPreferences(remote);
  expect(inboxConfig()).toEqual(remote);
  expect(write).not.toHaveBeenCalled();
  vi.doUnmock("../src/inboxState");
});

it("retires repeatedly failing outbox entries so a stuck pending write never starves readInboxState", async () => {
  const fetcher = vi.fn(async (_url: string, init?: RequestInit) => init?.method
    ? new Response("upstream down", { status: 503 })
    : new Response(JSON.stringify({ "seen:mission": 777, _versions: { "seen:mission": 4 } })));
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");

  writeInboxState("seen/mission", { stamp: 100 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));

  const firstRead = await readInboxState();
  expect(firstRead?.["seen:mission"]).toBe(100);
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3));
  await new Promise(resolve => setTimeout(resolve, 0));

  await readInboxState();
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(5));
  await new Promise(resolve => setTimeout(resolve, 0));

  const converged = await readInboxState();
  expect(converged?.["seen:mission"]).toBe(777);
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(fetcher).toHaveBeenCalledTimes(6);
});

it("caps persisted outbox JSON at 512 KiB and survives SecurityError storage failures", async () => {
  vi.doUnmock("../src/inboxState");
  const fetcher = vi.fn(() => new Promise<Response>(() => {}));
  vi.stubGlobal("fetch", fetcher);
  const { MAX_INBOX_OUTBOX_BYTES, writeInboxState } = await import("../src/inboxState");
  const { sideQuestionKey } = await import("../src/sideQuestionStorage");
  const key = sideQuestionKey("inbox-state:outbox:v1");

  writeInboxState("seen/small", { stamp: 100 });
  const baseline = localStorage.getItem(key);
  expect(baseline).toBeTruthy();

  writeInboxState("preferences", {
    aiSummary: true,
    includeAutonomous: false,
    model: "x".repeat(MAX_INBOX_OUTBOX_BYTES + 1024),
  });
  expect(localStorage.getItem(key)).toBe(baseline);

  const spyGet = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
    throw new DOMException("Blocked", "SecurityError");
  });
  const spySet = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
    throw new DOMException("Blocked", "SecurityError");
  });
  try {
    expect(() => writeInboxState("seen/no-storage", { stamp: 200 })).not.toThrow();
  } finally {
    spyGet.mockRestore();
    spySet.mockRestore();
  }
});
