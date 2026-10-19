import { afterEach, expect, it, vi } from "vitest";
import { deliverInOrder, retry, stillStopping } from "../src/mission/sendQueue";
import type { MessageReceipt, Mission } from "../src/api";

afterEach(() => vi.useRealTimers());
const rows = [{ id: "a", content: "first" }, { id: "b", content: "second" }, { id: "c", content: "third" }];
const receipt = (id: string, extra: Partial<MessageReceipt> = {}): MessageReceipt => ({ id, queued: false, ...extra });
const ids = () => { let n = 0; return () => `id-${++n}`; };

it("reuses one message id for every retry while the previous turn stops", async () => {
  vi.useFakeTimers();
  const send = vi.fn()
    .mockRejectedValueOnce(new Error("409 Conflict: still has a remote job"))
    .mockRejectedValueOnce(new Error("stopping"))
    .mockResolvedValue(receipt("r"));
  const delivered: string[] = [];
  const done = deliverInOrder({ mission: "m", rows: rows.slice(0, 1), attempts: 30, send, attachments: () => [], stale: () => false, newId: ids(), onDelivered: row => delivered.push(row.id) });
  await vi.runAllTimersAsync();
  expect(await done).toEqual({ kind: "delivered" });
  expect(send.mock.calls.map(call => call[3])).toEqual(["id-1", "id-1", "id-1"]);
  expect(delivered).toEqual(["a"]);
});

it("does not retry a definitive rejection", async () => {
  const send = vi.fn().mockRejectedValue(new Error("400 Bad request"));
  await expect(deliverInOrder({ mission: "m", rows, attempts: 30, send, attachments: () => [], stale: () => false, onDelivered: () => {} })).rejects.toThrow("400");
  expect(send).toHaveBeenCalledTimes(1);
});

it("forwards the remaining messages to a replacement in order", async () => {
  const replacement = { id: "new" } as Mission;
  const send = vi.fn(async (mission: string) => mission === "m" ? receipt("r", { replacement }) : receipt("f"));
  const onReplacement = vi.fn();
  const result = await deliverInOrder({ mission: "m", rows, attempts: 1, send, attachments: () => [], stale: () => false, newId: ids(), onDelivered: () => {}, onReplacement });
  expect(result).toEqual({ kind: "replaced", replacement, undelivered: [] });
  expect(send.mock.calls.map(([mission, text]) => `${mission}:${text}`)).toEqual(["m:first", "new:second", "new:third"]);
  expect(onReplacement).toHaveBeenCalledWith(replacement, "first");
});

it("reports a forwarding failure with the messages that did not arrive", async () => {
  const replacement = { id: "new" } as Mission;
  const send = vi.fn(async (mission: string, text: string) => {
    if (mission === "m") return receipt("r", { replacement });
    if (text === "second") throw new Error("offline");
    return receipt("f");
  });
  const result = await deliverInOrder({ mission: "m", rows, attempts: 1, send, attachments: () => [], stale: () => false, onDelivered: () => {} });
  expect(result.kind).toBe("replaced");
  if (result.kind !== "replaced") return;
  expect(String(result.forwardError)).toContain("offline");
  expect(result.undelivered.map(row => row.id)).toEqual(["b", "c"]);
  // Forwarding stops at the first failure so "third" never overtakes "second".
  expect(send.mock.calls.map(call => call[1])).toEqual(["first", "second"]);
});

it("stops when the conversation changes", async () => {
  let stale = false;
  const send = vi.fn(async () => { stale = true; return receipt("r"); });
  expect(await deliverInOrder({ mission: "m", rows, attempts: 1, send, attachments: () => [], stale: () => stale, onDelivered: () => {} })).toEqual({ kind: "stale" });
  expect(send).toHaveBeenCalledTimes(1);
});

it("retry gives up after the last attempt", async () => {
  const run = vi.fn().mockRejectedValue(new Error("stopping"));
  await expect(retry(run, { attempts: 3, delayMs: 0, retryable: stillStopping })).rejects.toThrow("stopping");
  expect(run).toHaveBeenCalledTimes(3);
});
