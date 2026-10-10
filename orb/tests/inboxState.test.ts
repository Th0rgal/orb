import { beforeEach, expect, it, vi } from "vitest";
const api = vi.hoisted(() => ({ version: 1, token: "test", connected: true }));
vi.mock("../src/api", () => ({ connectionVersion: () => api.version, getApiUrl: () => "https://test.invalid", getJwt: () => api.token, isConnected: () => api.connected }));
beforeEach(() => { vi.resetModules(); api.version++; localStorage.clear(); vi.unstubAllGlobals(); });
it("serializes preference and read writes and fences a late read after a local change", async () => {
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
  writeInboxState("seen/mission", { stamp: 456 });
  release(new Response(JSON.stringify({ "seen:mission": 1 })));
  expect(await reading).toBeUndefined();
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

it("retries an unsent local receipt before importing older server state", async () => {
  const fetcher = vi.fn().mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValue(new Response(null, { status: 204 }));
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("seen/mission", { stamp: -123 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(await readInboxState()).toBeUndefined();
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
  expect(fetcher.mock.calls[1][1].method).toBe("PUT");
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
  const fetcher = vi.fn().mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValue(new Response(null, { status: 204 }));
  vi.stubGlobal("fetch", fetcher);
  const { readInboxState, writeInboxState } = await import("../src/inboxState");
  writeInboxState("preferences", { aiSummary: false, includeAutonomous: true, model: "builtin/fast", clientId: "persisted-client", mutationSeq: 12, expectedVersion: 3 });
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
  await new Promise(resolve => setTimeout(resolve, 0));
  await readInboxState();
  await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
  expect(JSON.parse(fetcher.mock.calls[1][1].body)).toMatchObject({ clientId: "persisted-client", mutationSeq: 12, expectedVersion: 3 });
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
