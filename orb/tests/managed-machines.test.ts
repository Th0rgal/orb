import { describe, expect, it } from "vitest";
import { ApiError } from "../src/api";
import { allowedSizes, budgetLine, estimateCost, isManagedNode, liveCost, managedError, minutesLabel, recentMachines, ttlLeft, ttlUrgent, usd, usdPerHour, type ManagedMachine } from "../src/managedMachineModel";
import { ttlChoices } from "../src/ManagedMachines";

const now = Date.parse("2026-10-21T12:00:00Z");
const machine = (over: Partial<ManagedMachine>): ManagedMachine => ({ id: "a", provider: "boat", provider_id: "p", node_id: "managed-a", image: "img", size: "small", cpu: 2, ram_gb: 4,
  state: "online", created_at: "2026-10-21T11:00:00Z", expires_at: "2026-10-21T13:00:00Z", cost_usd: 0.1, usd_per_hour: 0.12, ledger_closed: false, ...over });

describe("managed machine formatting", () => {
  it("formats money", () => {
    expect(usd(0)).toBe("$0.00"); expect(usd(0.004)).toBe("<$0.01"); expect(usd(12.3)).toBe("$12.30"); expect(usd(undefined)).toBe("—");
    expect(usdPerHour(0.045)).toBe("$0.045/h"); expect(usdPerHour(1.2)).toBe("$1.20/h");
  });
  it("counts down the TTL", () => {
    expect(ttlLeft("2026-10-21T13:05:00Z", now)).toBe("1h 05m");
    expect(ttlLeft("2026-10-21T12:04:09Z", now)).toBe("4m 09s");
    expect(ttlLeft("2026-10-21T11:59:00Z", now)).toBe("Expired");
    expect(ttlLeft("nope", now)).toBe("—");
    expect(ttlUrgent("2026-10-21T12:09:00Z", now)).toBe(true);
    expect(ttlUrgent("2026-10-21T12:30:00Z", now)).toBe(false);
  });
  it("labels durations and TTL choices", () => {
    expect(minutesLabel(90)).toBe("1 h 30 min"); expect(minutesLabel(60)).toBe("1 h"); expect(minutesLabel(45)).toBe("45 min");
    expect(ttlChoices(90, 240)).toEqual([15, 30, 60, 90, 120, 240]);
  });
  it("extrapolates cost between polls, capped at expiry, only while running", () => {
    const fetched = now - 30 * 60_000;
    expect(liveCost(machine({}), fetched, now)).toBeCloseTo(0.16);
    expect(liveCost(machine({ expires_at: "2026-10-21T11:45:00Z" }), fetched, now)).toBeCloseTo(0.13);
    expect(liveCost(machine({ state: "destroyed" }), fetched, now)).toBe(0.1);
    expect(estimateCost(0.12, 90)).toBeCloseTo(0.18);
  });
  it("summarises the budget", () => {
    expect(budgetLine({ spent_today_usd: 1.2, daily_cap_usd: 20, active: 1, max_concurrent: 3, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "small", max_size: "large" }))
      .toBe("$1.20 spent today of $20.00 · 1 of 3 running");
  });
  it("lists recent destroyed machines from the last 24 h, newest first", () => {
    const rows = [machine({ id: "live" }), machine({ id: "old", state: "destroyed", destroyed_at: "2026-10-20T10:00:00Z" }),
      machine({ id: "b", state: "destroyed", destroyed_at: "2026-10-21T09:00:00Z" }), machine({ id: "c", state: "failed", destroyed_at: "2026-10-21T10:00:00Z" })];
    expect(recentMachines(rows, now).map(m => m.id)).toEqual(["c", "b"]);
  });
  it("caps sizes at the budget maximum", () => {
    const sizes = ["small", "medium", "large", "xl"].map((size, i) => ({ size, cpu: 2 << i, ram_gb: 4 << i, disk_gb: 40, usd_per_hour: i + 0.1 }));
    expect(allowedSizes(sizes, "large").map(s => s.size)).toEqual(["small", "medium", "large"]);
    expect(allowedSizes(sizes, "unknown")).toHaveLength(4);
  });
  it("recognises managed nodes", () => {
    expect(isManagedNode({ id: "x", labels: ["managed"] })).toBe(true);
    expect(isManagedNode({ id: "managed-1", labels: [] })).toBe(true);
    expect(isManagedNode({ id: "spark", labels: [] })).toBe(false);
  });
  it("explains budget and quota refusals", () => {
    expect(managedError(new ApiError(402, JSON.stringify({ error: "budget_exceeded", message: "$20.00 cap reached" })))).toBe("Daily budget reached: $20.00 cap reached");
    expect(managedError(new ApiError(429, JSON.stringify({ error: "quota_exceeded" })))).toBe("Machine limit reached.");
    expect(managedError(new ApiError(500, ""))).toBe("Request failed (500)");
    expect(managedError(new ApiError(400, "bad size"))).toBe("bad size");
  });
});
