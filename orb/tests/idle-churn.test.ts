import { afterEach, expect, it, vi } from "vitest";
import { clearConnection, listMissions, setConnection } from "../src/api";
import { collectFollowUps } from "../src/orchestrationModel";
import { buildTranscript, reuseUnchanged, type StreamItem } from "../src/transcriptModel";
import { sameChecklist, sameTaskCardView, taskCardView } from "../src/taskList";

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); vi.useRealTimers(); });

const row = (id: string, parent?: string) => ({ id, parent_mission_id: parent, title: id, status: "active", history: [], created_at: "2026-10-23T00:00:00Z", updated_at: "2026-10-23T00:00:00Z" });

it("reads a parent that fell off the sidebar page once per TTL, not on every poll", async () => {
  setConnection("http://ancestors.test", "token");
  const reads: string[] = [];
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
    const url = new URL(String(input));
    reads.push(url.pathname);
    if (url.pathname === "/api/control/missions") return new Response(JSON.stringify([row("child", "parent")]));
    if (url.pathname === "/api/control/missions/parent") return new Response(JSON.stringify(row("parent")));
    return new Response("[]");
  }));
  for (let poll = 0; poll < 4; poll++) expect((await listMissions()).map(m => m.id)).toEqual(["parent", "child"]);
  expect(reads.filter(path => path === "/api/control/missions/parent")).toHaveLength(1);
});

it("does not parse results of tools that carry no orchestration follow-up", () => {
  const parse = vi.spyOn(JSON, "parse");
  const items: StreamItem[] = Array.from({ length: 50 }, (_, i) => ({ kind: "tool", key: `t${i}`, callId: `c${i}`, name: "Bash", args: '{"command":"ls"}', result: JSON.stringify({ output: "x".repeat(1000) }), done: true }));
  collectFollowUps(items);
  expect(parse).not.toHaveBeenCalled();
  parse.mockRestore();
});

it("keeps row and array identity when a transcript re-read changed nothing", () => {
  const events = [
    { type: "user_message", data: { id: "u1", content: "hello" } },
    { type: "assistant_message", data: { id: "a1", content: "hi there" } },
  ] as Parameters<typeof buildTranscript>[0];
  const first = buildTranscript(events);
  const again = buildTranscript(events);
  expect(again).not.toBe(first);
  expect(reuseUnchanged(first, again)).toBe(first);
  const longer = buildTranscript([...events, { type: "user_message", data: { id: "u2", content: "more" } }] as typeof events);
  const merged = reuseUnchanged(first, longer);
  expect(merged).toHaveLength(3);
  expect(merged[0]).toBe(first[0]);
  expect(merged[1]).toBe(first[1]);
});

it("treats equal task lists and card views as unchanged", () => {
  const tasks = [{ text: "a", status: "completed" as const }, { text: "b", status: "in_progress" as const }];
  expect(sameChecklist({ key: "k", tasks }, { key: "k", tasks: tasks.map(t => ({ ...t })) })).toBe(true);
  expect(sameChecklist({ key: "k", tasks }, { key: "k", tasks: [tasks[0], { text: "b", status: "completed" }] })).toBe(false);
  // A finished turn maps open rows to fresh "stale" objects on every call.
  expect(sameTaskCardView(taskCardView(tasks, true, "finished"), taskCardView(tasks, true, "finished"))).toBe(true);
});
