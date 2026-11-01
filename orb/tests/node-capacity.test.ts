import { expect, it } from "vitest";
import { formatNodeSlotBadge, parseNodeCapacityDraft } from "../src/machines/nodes";

it("formats node slot badges with total capacity and queued count when known", () => {
  expect(formatNodeSlotBadge(undefined)).toBeUndefined();
  expect(formatNodeSlotBadge({ active_jobs: null, capacity_total: 4, queued_jobs: 0 })).toBeUndefined();
  expect(formatNodeSlotBadge({ active_jobs: 2, capacity_total: null, queued_jobs: null })).toBe("2 active");
  expect(formatNodeSlotBadge({ active_jobs: 3, capacity_total: 6, queued_jobs: 0 })).toBe("3 / 6 active");
  expect(formatNodeSlotBadge({ active_jobs: 6, capacity_total: 6, queued_jobs: 2 })).toBe("6 / 6 active · 2 queued");
});

it("accepts only integer slot limits within 1..=256", () => {
  expect(parseNodeCapacityDraft("1")).toBe(1);
  expect(parseNodeCapacityDraft(" 8 ")).toBe(8);
  expect(parseNodeCapacityDraft("256")).toBe(256);
  expect(parseNodeCapacityDraft("0")).toBeNull();
  expect(parseNodeCapacityDraft("257")).toBeNull();
  expect(parseNodeCapacityDraft("-2")).toBeNull();
  expect(parseNodeCapacityDraft("3.5")).toBeNull();
  expect(parseNodeCapacityDraft("")).toBeNull();
});
