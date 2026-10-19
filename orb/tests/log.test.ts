import { afterEach, beforeEach, expect, it, vi } from "vitest";

const notes: Array<{ kind: string; data: Record<string, unknown> }> = [];
// The test setup already loaded the real module graph (toast → ErrorNotice → log).
vi.resetModules();
vi.doMock("../src/diagnostics", () => ({ note: (kind: string, data: Record<string, unknown>) => { notes.push({ kind, data }); } }));
const { RATE_MS, errorText, log, resetLogForTests, swallow } = await import("../src/log");

beforeEach(() => { notes.length = 0; resetLogForTests(); vi.useFakeTimers(); vi.setSystemTime(0); });
afterEach(() => vi.useRealTimers());

it("writes scope, level, message and data through diagnostics", () => {
  log.error("queue.tick", "boom", { mission: "m1" });
  expect(notes).toEqual([{ kind: "log.error", data: { scope: "queue.tick", message: "boom", data: { mission: "m1" } } }]);
});

it("keeps one entry per scope per window and counts what it dropped", () => {
  for (let i = 0; i < 5; i++) log.warn("poll.run", `fail ${i}`);
  log.warn("other", "independent");
  expect(notes.map(n => n.data.scope)).toEqual(["poll.run", "other"]);
  vi.setSystemTime(RATE_MS);
  log.warn("poll.run", "again");
  expect(notes.at(-1)?.data).toMatchObject({ scope: "poll.run", message: "again", dropped: 4 });
});

it("swallow settles a rejection to undefined and records it", async () => {
  const value = await Promise.reject(new TypeError("offline")).catch(swallow("composer.saveDraft", { scope: "m:1" }));
  expect(value).toBeUndefined();
  expect(notes[0]).toEqual({ kind: "log.warn", data: { scope: "composer.saveDraft", message: "TypeError: offline", data: { scope: "m:1" } } });
});

it("describes non-Error values", () => {
  expect(errorText("plain")).toBe("plain");
  expect(errorText({ code: 1 })).toBe('{"code":1}');
  expect(errorText(new Error("x".repeat(400))).length).toBe(300);
});
