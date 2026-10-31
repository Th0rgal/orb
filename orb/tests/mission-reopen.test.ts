import { afterEach, expect, it, vi } from "vitest";
import { archiveMission, getMission, reopenMission } from "../src/api";

afterEach(() => vi.unstubAllGlobals());

it.each(["completed", "failed", "not_feasible", "interrupted", "acknowledged"])("reopens %s without launching a run", async status => {
  const fetcher = vi.fn()
    .mockResolvedValueOnce(new Response(JSON.stringify({ id: "mission", status })))
    .mockResolvedValueOnce(new Response("{}"));
  vi.stubGlobal("fetch", fetcher);
  await reopenMission("mission");
  expect(fetcher).toHaveBeenCalledTimes(2);
  expect(fetcher.mock.calls[1][0]).toMatch(/\/missions\/mission\/status$/);
  expect(fetcher.mock.calls[1][1].method).toBe("POST");
  expect(JSON.parse(fetcher.mock.calls[1][1].body)).toEqual({ status: "paused" });
});

it("treats reopening an already-paused idle mission as idempotent", async () => {
  const fetcher = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ id: "mission", status: "paused" })));
  vi.stubGlobal("fetch", fetcher);
  await reopenMission("mission");
  expect(fetcher).toHaveBeenCalledTimes(1);
});

it.each([
  { status: "active" },
  { status: "paused", execution: { state: "running" } },
  { status: "completed", execution: { state: "running" } },
])("refuses to reopen a live mission: %j", async mission => {
  const fetcher = vi.fn().mockImplementation(async () => Response.json({ id: "mission", ...mission }));
  vi.stubGlobal("fetch", fetcher);
  await expect(reopenMission("mission")).rejects.toThrow(/no longer finished/);
  expect(fetcher).toHaveBeenCalledTimes(1);
});

it.each(["awaiting_user", "completed", "failed", "not_feasible", "interrupted", "paused", "blocked"])("archives %s", async status => {
  const fetcher = vi.fn()
    .mockResolvedValueOnce(new Response(JSON.stringify({ id: "mission", status })))
    .mockResolvedValueOnce(new Response("{}"));
  vi.stubGlobal("fetch", fetcher);
  await archiveMission("mission");
  expect(fetcher).toHaveBeenCalledTimes(2);
  expect(fetcher.mock.calls[1][0]).toMatch(/\/missions\/mission\/status$/);
  expect(fetcher.mock.calls[1][1].method).toBe("POST");
  expect(JSON.parse(fetcher.mock.calls[1][1].body)).toEqual({ status: "acknowledged" });
});

it("succeeds without re-POSTing when Core parent cascade already archived a child", async () => {
  // Replays the Orb 2 Lean subtree archive race: parent POST /status cascades
  // status=acknowledged to child missions before the child's GET resolves.
  const state: Record<string, string> = { parent: "awaiting_user", child: "completed" };
  let releaseChildGet!: () => void;
  const childGetGate = new Promise<void>(resolve => { releaseChildGet = resolve; });

  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (init?.method === "POST" && url.endsWith("/missions/parent/status")) {
      state.parent = "acknowledged";
      state.child = "acknowledged"; // Core cascades acknowledged to idle children
      releaseChildGet();
      return new Response("{}");
    }
    if (init?.method === "POST" && url.endsWith("/missions/child/status")) {
      return new Response("{}");
    }
    if (url.endsWith("/missions/child")) {
      await childGetGate;
      return Response.json({ id: "child", status: state.child });
    }
    if (url.endsWith("/missions/parent")) {
      return Response.json({ id: "parent", status: state.parent });
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fetcher);

  await Promise.all([archiveMission("parent"), archiveMission("child")]);

  const statusPosts = fetcher.mock.calls.filter(([, init]) => init?.method === "POST");
  expect(statusPosts).toHaveLength(1);
  expect(String(statusPosts[0][0])).toMatch(/\/missions\/parent\/status$/);
});

it("fetches a fresh mission state instead of coalescing onto an in-flight pre-stop GET", async () => {
  let resolveStaleGet!: (res: Response) => void;
  let calls = 0;
  const fetcher = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (init?.method === "POST" && url.endsWith("/missions/mission/status")) {
      return Promise.resolve(new Response("{}"));
    }
    calls++;
    if (calls === 1) {
      return new Promise<Response>(resolve => { resolveStaleGet = resolve; });
    }
    return Promise.resolve(Response.json({ id: "mission", status: "completed" }));
  });
  vi.stubGlobal("fetch", fetcher);

  const staleRead = getMission("mission");
  await archiveMission("mission");
  resolveStaleGet(Response.json({ id: "mission", status: "active", execution: { state: "running" } }));
  await expect(staleRead).resolves.toMatchObject({ status: "active" });
  expect(calls).toBe(2);
});

it.each([
  { status: "active" },
  { status: "pending" },
  { status: "waiting_background" },
  { status: "acknowledged", execution: { state: "running" } },
  { status: "completed", execution: { state: "running" } },
])("refuses to archive a live mission: %j", async mission => {
  const fetcher = vi.fn().mockImplementation(async () => Response.json({ id: "mission", ...mission }));
  vi.stubGlobal("fetch", fetcher);
  await expect(archiveMission("mission")).rejects.toThrow("Wait for the mission to stop before archiving it.");
  expect(fetcher).toHaveBeenCalledTimes(1);
});
