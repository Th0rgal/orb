import { expect, it } from "vitest";
import { createRoot } from "solid-js";
import { createOptimisticList } from "../src/mission/optimisticList";

type Row = { id: string; text: string; waiting: boolean; failed?: boolean };
const list = () => createRoot(() => createOptimisticList<Row>());

it("keeps one entry per id and replaces it in place", () => {
  const l = list();
  l.upsert({ id: "a", text: "one", waiting: false });
  l.upsert({ id: "b", text: "two", waiting: true });
  l.upsert({ id: "a", text: "one, edited", waiting: false });
  expect(l.items().map(r => `${r.id}:${r.text}`)).toEqual(["a:one, edited", "b:two"]);
  expect(l.first()?.id).toBe("a");
});

it("drops entries only once their canonical id is visible", () => {
  const l = list();
  l.upsert({ id: "a", text: "one", waiting: false });
  l.upsert({ id: "b", text: "two", waiting: false });
  const before = l.items();
  expect(l.reconcile(new Set(["x"]))).toBe(false);
  expect(l.items()).toBe(before);
  expect(l.reconcile(new Set(["a"]))).toBe(true);
  expect(l.items().map(r => r.id)).toEqual(["b"]);
});

it("marks failures and retains failed entries after a batch settles", () => {
  const l = list();
  l.replaceAll([{ id: "a", text: "one", waiting: false }, { id: "b", text: "two", waiting: false }]);
  l.setFailed(["b"], true);
  const sent = new Set(["a", "b"]);
  l.retain(r => !sent.has(r.id) || !!r.failed);
  expect(l.items()).toEqual([{ id: "b", text: "two", waiting: false, failed: true }]);
  expect(l.inFlightOtherThan("b")).toBe(false);
  l.setFailed("b", false);
  expect(l.inFlightOtherThan("x")).toBe(true);
});
