import { describe, expect, it } from "vitest";
import { ApiError } from "../src/api";
import { machineOwner, reapLine, allowedSizes, budgetLine, managedNodeIds, estimateCost, isManagedNode, liveCost, managedError, minutesLabel, recentMachines, ttlLeft, ttlUrgent, usd, usdPerHour, type ManagedMachine } from "../src/managedMachineModel";
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
  it("counts a machine created and destroyed today as recent, not while live", () => {
    const created = machine({ id: "ui", created_at: "2026-10-21T11:58:00Z" });
    expect(recentMachines([created], now)).toEqual([]);
    expect(recentMachines([{ ...created, state: "destroyed", destroyed_at: "2026-10-21T11:59:00Z" }], now).map(m => m.id)).toEqual(["ui"]);
  });
  it("maps a machine to its remote-node ids", () => {
    expect(managedNodeIds({ id: "a", node_id: "managed-a" })).toEqual(["managed-a"]);
    expect(managedNodeIds({ id: "a", node_id: "" })).toEqual(["managed-a"]);
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
    expect(managedError(new ApiError(409, JSON.stringify({ error: "provider_disabled", message: "Hetzner Cloud is disabled" })))).toBe("Provider disabled: Hetzner Cloud is disabled");
    expect(managedError(new ApiError(500, ""))).toBe("Request failed (500)");
    expect(managedError(new ApiError(400, "bad size"))).toBe("bad size");
  });
});

import { nodeLabel, rememberNodeNames, nodeSize, nodeProvider, managedFleetLabel } from "../src/machines/nodes";
import { availabilityLine } from "../src/AntigravityProvider";
import { placeholder } from "../src/ManagedMachines";
import { machineName, stateLabel, isStarting } from "../src/managedMachineModel";

describe("managed machine names and v2 states", () => {
  it("labels nodes by server display name, falling back to the id", () => {
    expect(nodeLabel("managed-mmX")).toBe("managed-mmX");
    rememberNodeNames([{ id: "managed-mmX", display_name: "small-a" }, { id: "spark" }]);
    expect(nodeLabel("managed-mmX")).toBe("small-a");
    expect(nodeLabel("spark")).toBe("spark");
    expect(nodeSize({ id: "x", cpu_total: 4, mem_total_bytes: 8 * 1024 ** 3 })).toBe("4 vCPU · 8 GB");
  });
  it("names machines and collapses start-up states", () => {
    expect(machineName({ id: "mm1", name: "large-b" })).toBe("large-b");
    expect(machineName({ id: "mm1", name: null })).toBe("mm1");
    expect(stateLabel("provisioning")).toBe("Starting…");
    expect(stateLabel("enrolling")).toBe("Starting…");
    expect(stateLabel("destroying")).toBe("Destroying…");
    expect(isStarting({ state: "enrolling" })).toBe(true);
    expect(isStarting({ state: "online" })).toBe(false);
  });
  it("builds an optimistic placeholder that never accrues cost", () => {
    const size = { size: "small", cpu: 2, ram_gb: 4, disk_gb: 40, usd_per_hour: 0.06 };
    const row = placeholder({ key: "pending-1", request: { size: "small", ttl_minutes: 60 }, size });
    expect(row).toMatchObject({ name: "New machine", state: "provisioning", cpu: 2, usd_per_hour: 0.06 });
    expect(liveCost(row, 0, Date.now())).toBe(0);
    expect(placeholder({ key: "pending-1", request: {}, size, error: "Daily budget reached." })).toMatchObject({ state: "failed", error: "Daily budget reached." });
  });
  it("describes Antigravity availability", () => {
    expect(availabilityLine(["Core", "spark"], true, false)).toBe("Available on Core, spark + managed machines");
    expect(availabilityLine(["Core"], false, false)).toBe("Available on Core");
    expect(availabilityLine(["Core"], null, false)).toBe("Available on Core");
    expect(availabilityLine([], true, false)).toBe("Available on managed machines");
    expect(availabilityLine([], null, true)).toBe("Checking machines…");
  });
});

import { budgetFull, budgetLeft, costLine, sizeLabel, specLine, ttlFraction, ttlShort } from "../src/managedMachineModel";

describe("managed row v3 and unlimited budgets", () => {
  const b = { spent_today_usd: 0.11, daily_cap_usd: null, active: 1, max_concurrent: null, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "default", max_size: "large" };
  it("drops the 'of …' parts when caps are unlimited", () => {
    expect(budgetLine(b)).toBe("$0.11 spent today · 1 running");
    expect(budgetLine({ ...b, daily_cap_usd: 5 })).toBe("$0.11 spent today of $5.00 · 1 running");
    expect(budgetLine({ ...b, max_concurrent: 2 })).toBe("$0.11 spent today · 1 of 2 running");
  });
  it("never blocks or warns on null caps", () => {
    expect(budgetFull({ ...b, active: 99, spent_today_usd: 999 })).toBe(false);
    expect(budgetLeft(b)).toBeNull();
    expect(budgetFull({ ...b, max_concurrent: 1 })).toBe(true);
    expect(budgetFull({ ...b, daily_cap_usd: 0.1 })).toBe(true);
    expect(budgetLeft({ ...b, daily_cap_usd: 1 })).toBeCloseTo(0.89);
  });
  it("formats the row's secondary line", () => {
    expect(sizeLabel("default")).toBe("medium");
    expect(sizeLabel("large")).toBe("large");
    expect(specLine({ cpu: 4, ram_gb: 8, disk_gb: 50 })).toBe("4 vCPU · 8 GB RAM · 50 GB");
    expect(specLine({ cpu: 4, ram_gb: 8, disk_gb: null })).toBe("4 vCPU · 8 GB RAM");
    expect(costLine(0.004, 0.036)).toBe("<$0.01 so far · $0.036/h");
  });
  it("shows TTL left and the remaining share", () => {
    expect(ttlShort("2026-10-21T12:21:00Z", now)).toBe("21 min left");
    expect(ttlShort("2026-10-21T13:05:00Z", now)).toBe("1 h 05 min left");
    expect(ttlShort("2026-10-21T11:00:00Z", now)).toBe("Expired");
    expect(ttlShort("", now)).toBe("");
    expect(ttlFraction("2026-10-21T11:00:00Z", "2026-10-21T13:00:00Z", now)).toBeCloseTo(0.5);
    expect(ttlFraction("2026-10-21T11:00:00Z", "2026-10-21T11:30:00Z", now)).toBe(0);
    expect(ttlFraction("x", "y", now)).toBe(0);
  });
});

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { canStopMachine, isProviderEnabled, isProviderUsable, managedSectionTitle, providerLabel, providerStatusLine, type ManagedMachinesResponse } from "../src/managedMachineModel";

describe("ownership and reaping", () => {
  it("classifies the owner", () => {
    expect(machineOwner({ owner_mission_id: "m1", owner_kind: "mission" })).toEqual({ kind: "mission", missionId: "m1" });
    expect(machineOwner({ owner_mission_id: null, owner_kind: "user" })).toEqual({ kind: "user" });
    expect(machineOwner({ owner_mission_id: null })).toEqual({ kind: "none" });
  });
  it("formats the scheduled reap and deferred 24h lease deletion", () => {
    const now = Date.parse("2026-10-23T12:00:00Z");
    expect(reapLine({ state: "online", reap_at: "2026-10-23T12:04:10Z", reap_reason: "owner_completed" }, now)).toBe("Reaps in 5 min (owner completed)");
    expect(reapLine({ state: "online", reap_at: "2026-10-23T12:15:00Z", reap_reason: "working_owner_idle" }, now)).toBe("Reaps in 15 min (idle)");
    expect(reapLine({ state: "online", reap_at: "2026-10-23T11:59:00Z", reap_reason: "owner_interrupted_idle" }, now)).toBe("Reap due (owner interrupted, idle)");
    expect(reapLine({ state: "online", reap_at: "2026-10-23T13:30:00Z", reap_reason: "idle_no_owner" }, now)).toBe("Reaps in 1 h 30 min (idle, no owner)");
    expect(reapLine({ state: "online", reap_at: "2026-10-24T10:00:00Z", deletable_at: "2026-10-24T10:00:00Z", reap_reason: "awaiting_deletable_at:owner_completed" }, now))
      .toBe("Deletes when 24h lease ends in 22 h 00 min");
    expect(reapLine({ state: "destroyed", reap_at: "2026-10-23T12:04:00Z" }, now)).toBeNull();
    expect(reapLine({ state: "online", reap_at: null }, now)).toBeNull();
  });
  it("labels multi-provider badges, section titles, and free-stop capability", () => {
    expect(providerLabel("boat")).toBe("boat.dev");
    expect(providerLabel("hetzner")).toBe("Hetzner");
    expect(providerLabel("vastai")).toBe("Vast.ai");
    expect(providerLabel("scaleway")).toBe("Scaleway");
    expect(managedSectionTitle([{ provider: "boat", display_name: "boat.dev", configured: true, supports_snapshots: true, supports_free_stop: true, sizes: [] }], [])).toBe("Managed (boat.dev)");
    expect(managedSectionTitle([{ provider: "hetzner", display_name: "Hetzner", configured: true, supports_snapshots: false, supports_free_stop: false, sizes: [] }], [])).toBe("Managed cloud");
    expect(managedSectionTitle([
      { provider: "boat", display_name: "boat.dev", configured: true, enabled: true, supports_snapshots: true, supports_free_stop: true, sizes: [] },
      { provider: "hetzner", display_name: "Hetzner", configured: true, enabled: false, supports_snapshots: false, supports_free_stop: false, sizes: [] },
    ], [])).toBe("Managed (boat.dev)");
    expect(nodeProvider({ id: "managed-h1", labels: ["managed", "provider=hetzner"] })).toBe("hetzner");
    expect(managedFleetLabel([{ id: "managed-b1", labels: ["managed", "boat"] }])).toBe("Managed (boat.dev)");
    expect(managedFleetLabel([{ id: "managed-h1", labels: ["managed", "provider=hetzner"] }])).toBe("Managed (Hetzner)");
    expect(managedFleetLabel([{ id: "managed-b1", labels: ["managed", "boat"] }, { id: "managed-h1", labels: ["managed", "provider=hetzner"] }])).toBe("Managed cloud");
    expect(canStopMachine({ state: "online", provider: "boat" })).toBe(true);
    expect(canStopMachine({ state: "online", provider: "hetzner" })).toBe(false);
    expect(canStopMachine({ state: "stopped", provider: "boat" })).toBe(false);
  });
  it("decodes the shared multi-provider managed-machines response fixture", () => {
    const raw = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "managed-machines-response.json"), "utf8");
    const resp = JSON.parse(raw) as ManagedMachinesResponse;
    expect(resp.enabled).toBe(true);
    expect(resp.providers?.map(p => [p.provider, p.display_name, p.configured, isProviderEnabled(p), isProviderUsable(p), p.supports_free_stop, p.supports_snapshots])).toEqual([
      ["boat", "boat.dev", true, true, true, true, true],
      ["hetzner", "Hetzner Cloud", true, true, true, false, false],
      ["vastai", "Vast.ai", false, true, false, false, false],
      ["scaleway", "Scaleway", false, false, false, false, false],
    ]);
    expect(providerStatusLine(resp.providers![0]!)).toBe("Configured · Bitwarden ••••1234");
    expect(providerStatusLine(resp.providers![1]!)).toBe("Configured · Settings ••••5678 · fsn1");
    expect(providerStatusLine(resp.providers![2]!)).toBe("Not configured");
    expect(providerStatusLine(resp.providers![3]!)).toBe("Disabled · Not configured");
    expect(managedSectionTitle(resp.providers, resp.machines)).toBe("Managed cloud");
    expect(canStopMachine(resp.machines[0]!, resp.providers)).toBe(false);
    expect(resp.machines[0]!.size).toBe("cpx42");
    const vastRtx = resp.providers?.find(p => p.provider === "vastai")?.sizes.find(s => s.size === "rtx4090");
    expect(vastRtx?.gpu).toBe("RTX 4090");
    const cax = resp.providers?.find(p => p.provider === "hetzner")?.sizes.find(s => s.size === "cax31");
    expect(cax?.arch).toBe("arm64");
  });
});
