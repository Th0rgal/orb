import { describe, expect, it } from "vitest";
import { ApiError } from "../src/api";
import { machineOwner, reapLine, allowedSizes, budgetLine, managedNodeIds, estimateCost, isManagedNode, liveCost, managedError, minutesLabel, recentMachines, ttlLeft, ttlUrgent, usd, usdPerHour, type ManagedMachine } from "../src/managedMachineModel";
import { ttlChoices } from "../src/ManagedMachines";
import { canExtendMachine } from "../src/managedMachineModel";

const now = Date.parse("2026-10-21T12:00:00Z");
const machine = (over: Partial<ManagedMachine>): ManagedMachine => ({ id: "a", provider: "boat", provider_id: "p", node_id: "managed-a", image: "img", size: "small", cpu: 2, ram_gb: 4,
  state: "online", created_at: "2026-10-21T11:00:00Z", expires_at: "2026-10-21T13:00:00Z", cost_usd: 0.1, usd_per_hour: 0.12, ledger_closed: false, ...over });

describe("managed lifecycle capabilities", () => {
  it("replays ready provider records without granting unsupported actions", () => {
    expect(canStopMachine(machine({ state: "ready", provider: "boat" }))).toBe(true);
    expect(canStopMachine(machine({ state: "ready", provider: "leanci" }))).toBe(false);
    expect(canExtendMachine(machine({ state: "ready", provider: "leanci" }))).toBe(false);
    expect(canExtendMachine(machine({ state: "ready", provider: "colab" }))).toBe(true);
    expect(canExtendMachine(machine({ state: "stopped", provider: "boat" }))).toBe(false);
  });
});

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

import { nodeLabel, rememberNodeNames, nodeSize, nodeProvider, managedFleetLabel, groupManagedNodesByProvider, managedFleetGroupSummary } from "../src/machines/nodes";
import { availabilityLine } from "../src/AntigravityProvider";
import { placeholder } from "../src/ManagedMachines";
import { machineName, stateLabel, isStarting, groupMachinesByProvider, providerGroupSummary } from "../src/managedMachineModel";

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
    expect(providerLabel("colab")).toBe("Google Colab");
    expect(managedSectionTitle([{ provider: "boat", display_name: "boat.dev", configured: true, supports_snapshots: true, supports_free_stop: true, sizes: [] }], [])).toBe("Managed (boat.dev)");
    expect(managedSectionTitle([{ provider: "hetzner", display_name: "Hetzner", configured: true, user_enabled: true, supports_snapshots: false, supports_free_stop: false, sizes: [] }], [])).toBe("Managed cloud");
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
      ["leanci", "lean.ci", true, false, false, false, true],
      ["hetzner", "Hetzner Cloud", true, false, false, false, false],
      ["vastai", "Vast.ai", false, false, false, false, false],
      ["scaleway", "Scaleway", false, false, false, false, false],
      ["colab", "Google Colab", false, false, false, false, false],
    ]);
    expect(resp.providers![0]!.max_concurrent).toBe(100);
    expect(resp.providers![1]!.availability?.status).toBe("degraded");
    expect(resp.providers![1]!.availability?.reason).toBe("pool_memory");
    expect(providerStatusLine(resp.providers![0]!)).toBe("Configured · Bitwarden ••••1234 · up to 100 VMs");
    expect(providerStatusLine(resp.providers![1]!)).toBe("Skipped for your missions");
    expect(providerStatusLine({ ...resp.providers![1]!, user_enabled: true, availability: { status: "saturated", reason: "quota_vcpus" } })).toBe("Configured · At capacity · Settings ••••9012 · proj ws-evm-fast");
    expect(providerStatusLine(resp.providers![2]!)).toBe("Skipped for your missions");
    expect(providerStatusLine(resp.providers![3]!)).toBe("Not configured");
    expect(providerStatusLine(resp.providers![4]!)).toBe("Disabled · Not configured");
    expect(providerStatusLine(resp.providers![5]!)).toBe("Not configured");
    expect(managedSectionTitle(resp.providers, resp.machines)).toBe("Managed cloud");
    expect(canStopMachine(resp.machines[0]!, resp.providers)).toBe(false);
    expect(resp.machines[0]!.size).toBe("cpx42");
    const vastRtx = resp.providers?.find(p => p.provider === "vastai")?.sizes.find(s => s.size === "rtx4090");
    expect(vastRtx?.gpu).toBe("RTX 4090");
    const colabA100 = resp.providers?.find(p => p.provider === "colab")?.sizes.find(s => s.size === "a100");
    expect(colabA100?.gpu).toBe("A100");
    expect(colabA100?.usd_per_hour).toBe(0.675);
    const cax = resp.providers?.find(p => p.provider === "hetzner")?.sizes.find(s => s.size === "cax31");
    expect(cax?.arch).toBe("arm64");
  });
  it("gives every enabled provider a fleet group, even with no machine yet", () => {
    const groups = groupManagedNodesByProvider(
      [{ id: "managed-a", labels: ["managed", "provider=boat"] }],
      ["boat", "leanci", "colab"],
    );
    expect(groups.map(g => g.provider)).toEqual(["boat", "leanci", "colab"]);
    expect(groups.map(g => g.nodes.length)).toEqual([1, 0, 0]);
    expect(managedFleetGroupSummary(groups[1].nodes)).toBe("No machines");
    expect(groupManagedNodesByProvider([], []).length).toBe(0);
  });

  it("groups machines and fleet nodes per provider with compact summaries", () => {
    const providers = [
      { provider: "boat", display_name: "boat.dev" },
      { provider: "hetzner", display_name: "Hetzner Cloud" },
    ];
    const items = [
      machine({ id: "h1", provider: "hetzner", usd_per_hour: 0.12 }),
      machine({ id: "b1", provider: "boat", usd_per_hour: 0.2 }),
      machine({ id: "b2", provider: "", usd_per_hour: 0.072 }),
    ];
    const groups = groupMachinesByProvider(items, providers);
    expect(groups.map(g => [g.provider, g.label, g.machines.map(m => m.id), providerGroupSummary(g.machines)])).toEqual([
      ["boat", "boat.dev", ["b1", "b2"], "2 running · $0.27/h"],
      ["hetzner", "Hetzner Cloud", ["h1"], "1 running · $0.12/h"],
    ]);
    expect(providerGroupSummary([machine({ id: "s1", state: "stopped" }), machine({ id: "s2", state: "stopped" })])).toBe("2 stopped");
    expect(providerGroupSummary([machine({ id: "f1", state: "failed", usd_per_hour: 0 })])).toBe("1 machine");
    const fleet = groupManagedNodesByProvider([
      { id: "spark", status: "online", labels: [] },
      { id: "managed-h1", status: "online", active_jobs: 1, labels: ["managed", "provider=hetzner"] },
      { id: "managed-b1", status: "online", active_jobs: 2, labels: ["managed", "boat"] },
      { id: "managed-b2", status: "offline", active_jobs: 0, labels: ["managed"] },
    ]);
    expect(fleet.map(g => [g.provider, g.label, managedFleetGroupSummary(g.nodes)])).toEqual([
      ["boat", "Managed (boat.dev)", "1/2 online · 2 active"],
      ["hetzner", "Managed (Hetzner)", "1 online · 1 active"],
    ]);
  });
});

import {
  formatAutoManagedTarget,
  isAgentSpawnedManagedNode,
  isAutoManagedTarget,
  isUserManagedNode,
  parseAutoManagedTarget,
  rememberManagedMachines,
} from "../src/machines/nodes";
import { compactSizeSpec, is24hCommitmentSize, machineProviderKey } from "../src/managedMachineModel";
import { managedProviderLabel, normalizeVmLimits, providerLimitsSummary } from "../src/missionBudget";
import { remoteLaunchPreflight } from "../src/missionLaunch";

describe("cloud VM submenus, on-demand targets, and agent-spawned VM collapsing", () => {
  it("uses only the canonical lean.ci provider id for labels and limits", () => {
    expect(providerLabel("leanci")).toBe("lean.ci");
    expect(managedProviderLabel("leanci")).toBe("lean.ci");
    expect(machineProviderKey("lean.ci")).toBe("lean.ci");
    expect(managedProviderLabel("lean.ci")).toBe("lean.ci");
    expect(providerLimitsSummary({ provider_max_concurrent: { "lean.ci": 2 } })).toBe("");
    expect(normalizeVmLimits({ provider_max_concurrent: { "lean.ci": 2 } })).toBe('{"m":null,"p":[]}');
    expect(providerLimitsSummary({ provider_max_concurrent: { leanci: 3 } })).toBe("lean.ci: 3");
  });
  it("parses, formats, and labels auto-managed cloud VM targets", () => {
    expect(formatAutoManagedTarget("boat", "large")).toBe("auto-managed:boat:large");
    expect(isAutoManagedTarget("auto-managed:boat:large")).toBe(true);
    expect(isAutoManagedTarget("auto-managed:hetzner")).toBe(true);
    expect(isAutoManagedTarget("auto-managed")).toBe(true);
    expect(isAutoManagedTarget("managed-abc")).toBe(false);
    expect(isAutoManagedTarget("core")).toBe(false);
    expect(parseAutoManagedTarget("auto-managed:boat:large")).toEqual({ provider: "boat", size: "large" });
    expect(parseAutoManagedTarget("auto-managed:hetzner:default")).toEqual({ provider: "hetzner", size: "default" });
    expect(parseAutoManagedTarget("auto-managed:vastai")).toEqual({ provider: "vastai" });
    expect(parseAutoManagedTarget("auto-managed")).toEqual({});
    expect(parseAutoManagedTarget("managed-abc")).toBeNull();
    expect(nodeLabel("auto-managed:boat:large")).toBe("boat.dev · large");
    expect(nodeLabel("auto-managed:hetzner:default")).toBe("Hetzner · medium");
    expect(nodeLabel("auto-managed:colab:a100")).toBe("Google Colab · a100");
  });

  it("separates user-started VMs from agent-spawned VMs across direct, label, and catalog metadata", () => {
    expect(isAgentSpawnedManagedNode({ id: "managed-m1", labels: ["managed"], owner_kind: "mission" })).toBe(true);
    expect(isUserManagedNode({ id: "managed-m1", labels: ["managed"], owner_kind: "mission" })).toBe(false);
    expect(isUserManagedNode({ id: "managed-u1", labels: ["managed"], owner_kind: "user" })).toBe(true);
    expect(isAgentSpawnedManagedNode({ id: "managed-u1", labels: ["managed"], owner_kind: "user" })).toBe(false);
    expect(isAgentSpawnedManagedNode({ id: "managed-l1", labels: ["managed", "owner=mission"] })).toBe(true);
    expect(isUserManagedNode({ id: "babylon", labels: [] })).toBe(false);

    rememberManagedMachines([
      { id: "req1", node_id: "managed-req1", requested_by_mission_id: "parent-m", owner_kind: "user" },
      { id: "usr2", node_id: "managed-usr2", owner_kind: "user" },
    ]);
    expect(isAgentSpawnedManagedNode({ id: "managed-req1", labels: ["managed"] })).toBe(true);
    expect(isUserManagedNode({ id: "managed-usr2", labels: ["managed"] })).toBe(true);
  });

  it("formats compact size specs and 24h commitment badges", () => {
    expect(compactSizeSpec({ size: "large", cpu: 8, ram_gb: 16, usd_per_hour: 0.288 })).toBe("8 vCPU · 16 GB");
    expect(compactSizeSpec({ size: "a100", cpu: 12, ram_gb: 85, gpu: "A100", usd_per_hour: 0.675 })).toBe("12 vCPU · 85 GB · A100");
    expect(compactSizeSpec({ size: "cax31", cpu: 8, ram_gb: 16, arch: "arm64", usd_per_hour: 0.03 })).toBe("8 vCPU · 16 GB · arm64");
    expect(is24hCommitmentSize({ size: "lean-8", cpu: 8, ram_gb: 24, usd_per_hour: 0.2, min_billing_hours: 24 })).toBe(true);
    expect(is24hCommitmentSize({ size: "large", cpu: 8, ram_gb: 16, usd_per_hour: 0.288 })).toBe(false);
  });

  it("validates remote launch preflight for auto-managed targets without requiring a booted node", () => {
    const fleet = {
      enabled: true,
      nodes: [],
      remote_launch: { typed: true, harnesses: ["claudecode", "codex", "opencode", "antigravity"], proxy_url_configured: true },
      managed_compute: { enabled: true, configured_providers: ["boat"], active_machines: 0, total_machines: 0, queued_spawns: 0 },
    };
    expect(remoteLaunchPreflight(fleet, "auto-managed:boat:large", { backend: "claudecode", model: "claude-opus-5" })).toBeNull();
    expect(remoteLaunchPreflight(fleet, "auto-managed:boat:large", { backend: "grok", model: "grok-4" })).toContain("not supported on managed cloud VMs");
    expect(
      remoteLaunchPreflight(
        { ...fleet, managed_compute: { ...fleet.managed_compute, enabled: false } },
        "auto-managed:boat:large",
        { backend: "claudecode", model: "claude-opus-5" },
      ),
    ).toContain("managed cloud VMs are disabled");
  });
});

import { exceedsBudget, hasFreeMachines, initialManagedProvider, providerGroupSummary, type ManagedProviderInfo } from "../src/managedMachineModel";

describe("zero-price provider (lean.ci)", () => {
  const size = (usd_per_hour: number) => ({ size: "small", cpu: 2, ram_gb: 8, disk_gb: 98, usd_per_hour });
  const prov = (over: Partial<ManagedProviderInfo>): ManagedProviderInfo => ({ provider: "boat", display_name: "boat.dev", configured: true,
    enabled: true, globally_enabled: true, user_enabled: true, effective_enabled: true, supports_snapshots: true, supports_free_stop: true, sizes: [size(0.018)], ...over });
  const leanci = prov({ provider: "leanci", display_name: "lean.ci", is_default: true, supports_free_stop: false, supports_extend: false, sizes: [size(0)] });
  const b = { spent_today_usd: 20, daily_cap_usd: 20, active: 1, max_concurrent: 3, default_ttl_minutes: 60, max_ttl_minutes: 720, default_size: "small", max_size: "xlarge" };

  it("shows a zero price as $0.00, never blank", () => {
    expect(usdPerHour(0)).toBe("$0.00/h");
    expect(costLine(0, 0)).toBe("$0.00 so far · $0.00/h");
    expect(usd(estimateCost(0, 720))).toBe("$0.00");
    expect(liveCost(machine({ provider: "leanci", cost_usd: 0, usd_per_hour: 0 }), now - 3_600_000, now)).toBe(0);
    expect(providerGroupSummary([machine({ provider: "leanci", usd_per_hour: 0 })])).toBe("1 running");
  });
  it("does not let a spent daily budget block a free machine", () => {
    expect(budgetFull(b)).toBe(true);
    expect(budgetFull(b, [prov({})])).toBe(true);
    expect(hasFreeMachines([prov({}), leanci])).toBe(true);
    expect(budgetFull(b, [prov({}), leanci])).toBe(false);
    expect(budgetFull(b, [prov({}), { ...leanci, user_enabled: false }])).toBe(true);
    expect(budgetFull({ ...b, active: 3 }, [leanci])).toBe(true);
    expect(exceedsBudget(0, 0)).toBe(false);
    expect(exceedsBudget(0, -1)).toBe(false);
    expect(exceedsBudget(0.02, 0.01)).toBe(true);
    expect(exceedsBudget(5, null)).toBe(false);
  });
  it("preselects the instance default provider, then boat", () => {
    expect(initialManagedProvider([prov({}), leanci])).toBe("leanci");
    expect(initialManagedProvider([prov({}), { ...leanci, availability: { status: "saturated" } }])).toBe("boat");
    expect(initialManagedProvider([prov({}), { ...leanci, is_default: false }])).toBe("boat");
    expect(initialManagedProvider([{ ...leanci, is_default: false }])).toBe("leanci");
    expect(initialManagedProvider([])).toBe("boat");
  });
});
