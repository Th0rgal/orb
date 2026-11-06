import { render, fireEvent, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it } from "vitest";
import { cleanup } from "@solidjs/testing-library";
afterEach(cleanup);
import { MissionSettings } from "../src/MissionSettings";
import {
  bandwidthLimitsSummary,
  bandwidthModeLine,
  computeRunwayForecast,
  exceedsGrant,
  formatTokensPerMin,
  modeLine,
  optimisticBandwidthLimits,
  optimisticBudget,
  optimisticVmLimits,
  parseAmount,
  parseBandwidthLimits,
  parseVmLimits,
  providerLimitsSummary,
  usedFraction,
  vmLimitsModeLine,
  type BandwidthLimits,
  type MissionBudget,
  type VmConcurrencyLimits,
} from "../src/missionBudget";
import { modelLabel } from "../src/missionStats";
import missionBudgetFixture from "../../shared/orb-spec/fixtures/mission-budget.json";

const base = (over: Partial<MissionBudget> = {}): MissionBudget => ({
  mission_id: "m1",
  own_budget_usd: null,
  pool_id: null,
  mode: "none",
  pool: null,
  max_grant_usd: null,
  own_vm_limits: null,
  vm_limits_mode: "global",
  vm_limits_pool_id: null,
  effective_vm_limits: {
    source: "global",
    pool_id: null,
    active: 16,
    max_concurrent: 16,
    global_active: 16,
    global_max_concurrent: 16,
    ancestor_max_concurrent: null,
    provider_limits: [],
  },
  own_bandwidth_limits: null,
  bandwidth_mode: "none",
  bandwidth_pool_id: null,
  effective_bandwidth: {
    source: "none",
    pool_id: null,
    tokens_per_min: null,
    compute_vcpu_per_min: null,
    compute_usd_per_hour: null,
    protect_root: false,
    current_tokens_per_min: 48_000,
    current_vcpu_per_min: 16,
    current_compute_usd_per_hour: 2.0,
    pacing_active: false,
    paced_delay_ms: 0,
    ancestor_tokens_per_min: null,
    ancestor_compute_vcpu_per_min: null,
    ancestor_compute_usd_per_hour: null,
  },
  children: [],
  ...over,
});

const own = (budget: number, over: Partial<MissionBudget> = {}): MissionBudget => base({
  own_budget_usd: budget,
  pool_id: "m1",
  mode: "own",
  pool: {
    pool_id: "m1",
    budget_usd: budget,
    spent_usd: 0.4,
    reserved_usd: 0.2,
    carved_usd: 1,
    available_usd: budget - 1.6,
    live_machines: 1,
  },
  ...over,
});

it("parses amounts and refuses sub-budgets above the parent's grant", () => {
  expect(parseAmount("$2.5")).toEqual({ value: 2.5 });
  expect(parseAmount("0")).toHaveProperty("error");
  expect(parseAmount("abc")).toHaveProperty("error");
  expect(exceedsGrant(base({ max_grant_usd: 3 }), 4)).toContain("$3.00");
  expect(exceedsGrant(base({ max_grant_usd: 3 }), 3)).toBeNull();
  expect(exceedsGrant(base(), 1e6)).toBeNull();
});

it("parses total and per-provider machine limits and enforces bounds", () => {
  expect(parseVmLimits("6", { vastai: "2", boat: "" })).toEqual({
    value: { max_concurrent: 6, provider_max_concurrent: { vastai: 2 } },
  });
  expect(parseVmLimits("", { vastai: "2" })).toEqual({
    value: { max_concurrent: null, provider_max_concurrent: { vastai: 2 } },
  });
  expect(parseVmLimits("", { hetzner: "0" })).toEqual({
    value: { max_concurrent: null, provider_max_concurrent: { hetzner: 0 } },
  });
  expect(parseVmLimits("", {})).toHaveProperty("error");
  expect(parseVmLimits("2", { vastai: "4" })).toHaveProperty("error");
  const childView = base({
    effective_vm_limits: {
      source: "mission", pool_id: "root", active: 0, max_concurrent: 3,
      global_active: 0, global_max_concurrent: 16, ancestor_max_concurrent: 3, provider_limits: [],
    },
  });
  expect(parseVmLimits("5", {}, childView)).toHaveProperty("error");
});

it("parses bandwidth limits, shorthand k/M tokens, and enforces ancestor ceilings", () => {
  expect(parseBandwidthLimits("120k", "32", "$2.5", true)).toEqual({
    value: {
      tokens_per_min: 120_000,
      inference_usd_per_hour: null,
      compute_vcpu_per_min: 32,
      compute_usd_per_hour: 2.5,
      protect_root: true,
    },
  });
  expect(parseBandwidthLimits("1.5M", "", "", false)).toEqual({
    value: {
      tokens_per_min: 1_500_000,
      inference_usd_per_hour: null,
      compute_vcpu_per_min: null,
      compute_usd_per_hour: null,
      protect_root: false,
    },
  });
  expect(parseBandwidthLimits("", "", "", true, undefined, "$12.5")).toEqual({
    value: {
      tokens_per_min: null,
      inference_usd_per_hour: 12.5,
      compute_vcpu_per_min: null,
      compute_usd_per_hour: null,
      protect_root: true,
    },
  });
  expect(parseBandwidthLimits("", "", "", true)).toHaveProperty("error");
  expect(parseBandwidthLimits("500", "", "", true)).toHaveProperty("error");
  const childView = base({
    effective_bandwidth: {
      source: "mission",
      pool_id: "root",
      tokens_per_min: 80_000,
      inference_usd_per_hour: 10.0,
      compute_vcpu_per_min: 16,
      compute_usd_per_hour: 1.5,
      protect_root: true,
      current_tokens_per_min: 0,
      current_inference_usd_per_hour: 0,
      current_vcpu_per_min: 0,
      current_compute_usd_per_hour: 0,
      pacing_active: false,
      paced_delay_ms: 0,
      ancestor_tokens_per_min: 80_000,
      ancestor_inference_usd_per_hour: 10.0,
      ancestor_compute_vcpu_per_min: 16,
      ancestor_compute_usd_per_hour: 1.5,
    },
  });
  expect(parseBandwidthLimits("100k", "", "", true, childView)).toHaveProperty("error");
  expect(parseBandwidthLimits("40k", "24", "", true, childView)).toHaveProperty("error");
  expect(parseBandwidthLimits("40k", "8", "2.0", true, childView)).toHaveProperty("error");
  expect(parseBandwidthLimits("40k", "8", "1.0", true, childView, "15.0")).toHaveProperty("error");
});

it("computes runway forecast from unspent pool funds without double-counting live VM reservations", () => {
  // spent = $0.40, carved = $1.00, reserved = $0.20 -> runwayUsd = $8.60, available = $8.40
  // current_compute_usd_per_hour = $2.00/h -> 4.3h (15,480s)
  const b = own(10);
  const unshaped = computeRunwayForecast({ budget: b, budgetEnabled: true });
  expect(unshaped.etaSecs).toBeCloseTo(15_480, 0);
  expect(unshaped.headline).toContain("~4h 18m runway left");
  expect(unshaped.subline).toContain("$8.40 unallocated ($0.20 reserved · $10 cap)");

  const shaped = computeRunwayForecast({
    budget: b,
    budgetEnabled: true,
    bandwidthEnabled: true,
    draftComputeUsdPerH: "1.0",
  });
  expect(shaped.etaSecs).toBeCloseTo(30_960, 0);
  expect(shaped.etaGainSecs).toBeCloseTo(15_480, 0);
  expect(shaped.subline).toContain("from bandwidth cap");
  expect(shaped.chart.unshapedLinePath).toBeTruthy();

  // Fresh $1/h VM on a $1 pool holding a 1-hour ($1.00) reservation has $0 unallocated
  // (`available_usd = 0`) yet still has ~1h (3,600s) of paid runway before exhaustion!
  const fullyReserved = base({
    own_budget_usd: 1,
    pool_id: "m1",
    mode: "own",
    pool: {
      pool_id: "m1",
      budget_usd: 1,
      spent_usd: 0,
      reserved_usd: 1,
      carved_usd: 0,
      available_usd: 0,
      live_machines: 1,
    },
    effective_bandwidth: {
      ...base().effective_bandwidth!,
      current_compute_usd_per_hour: 1.0,
    },
  });
  const freshVmForecast = computeRunwayForecast({ budget: fullyReserved, budgetEnabled: true });
  expect(freshVmForecast.etaSecs).toBeCloseTo(3_600, 0);
  expect(freshVmForecast.headline).toContain("~1h runway left");
  expect(freshVmForecast.headline).not.toContain("Budget exhausted");
});

it("derives the optimistic view, mode lines, and empty model fallback", () => {
  const on = optimisticBudget(base(), 5);
  expect(on.mode).toBe("own");
  expect(on.pool?.available_usd).toBe(5);
  const raised = optimisticBudget(own(4), 6);
  expect(raised.pool?.available_usd).toBeCloseTo(4.4);
  expect(optimisticBudget(own(4), null).mode).toBe("none");
  expect(optimisticBudget(own(4, { max_grant_usd: 2 }), null).mode).toBe("pooled");
  expect(modeLine(base({ mode: "pooled", pool_id: "p" }), "Parent")).toContain("Parent");
  expect(modeLine(base())).toContain("daily");
  expect(vmLimitsModeLine(base())).toContain("16 concurrent");
  expect(bandwidthModeLine(base())).toContain("Unthrottled");
  const capOn = optimisticVmLimits(base(), { max_concurrent: null, provider_max_concurrent: { vastai: 2 } });
  expect(capOn.vm_limits_mode).toBe("own");
  expect(capOn.effective_vm_limits?.provider_limits).toEqual([{ provider: "vastai", active: 0, max_concurrent: 2 }]);
  const bwOn = optimisticBandwidthLimits(base(), { tokens_per_min: 120_000, protect_root: true });
  expect(bwOn.bandwidth_mode).toBe("own");
  expect(bwOn.effective_bandwidth?.tokens_per_min).toBe(120_000);
  expect(formatTokensPerMin(120_000)).toBe("120k tok/min");
  expect(usedFraction(own(4).pool!)).toBeCloseTo(0.4);
  expect(modelLabel({ provider: null, model: "" })).toBe("Unknown model");
  expect(modelLabel({ provider: "openai", model: "" })).toBe("openai/Unknown model");
});

const pendingStats = () => new Promise<never>(() => {});

it("turns the budget on optimistically and keeps the server's answer", async () => {
  let resolve!: (v: MissionBudget) => void;
  render(() => <MissionSettings missionId="m1" title="Snark" onClose={() => {}}
    load={async () => base()} save={() => new Promise(r => { resolve = r; })} loadStats={pendingStats} />);
  const toggle = await screen.findByRole("switch", { name: "Spending budget" });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  fireEvent.click(toggle);
  // Optimistic: on before the server answers.
  expect(screen.getByRole("switch", { name: "Spending budget" }).getAttribute("aria-checked")).toBe("true");
  expect(screen.getByText(/of \$5\.00/)).toBeTruthy();
  resolve(own(5));
  await waitFor(() => expect(screen.getByText("$0.40")).toBeTruthy());
});

it("turns bandwidth limits on, updates live runway preview, and saves pace settings", async () => {
  let savedBw: BandwidthLimits | null = null;
  render(() => <MissionSettings missionId="m1" title="evm.fast" onClose={() => {}}
    load={async () => own(10)}
    loadStats={pendingStats}
    saveBandwidthLimits={async (_id, lim) => { savedBw = lim; return optimisticBandwidthLimits(own(10), lim); }} />);
  const toggle = await screen.findByRole("switch", { name: "Bandwidth limit" });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  expect(screen.getByTestId("mission-forecast-card").textContent).toContain("~4h 18m runway left");

  fireEvent.click(toggle);
  await waitFor(() => expect((screen.getByLabelText("Tokens per minute") as HTMLInputElement).value).toBe("120000"));

  const tpmInput = screen.getByLabelText("Tokens per minute") as HTMLInputElement;
  const infUsdHInput = screen.getByLabelText("Inference burn ceiling ($/h)") as HTMLInputElement;
  const usdHInput = screen.getByLabelText("Compute burn ceiling ($/h)") as HTMLInputElement;
  fireEvent.input(tpmInput, { target: { value: "90k" } });
  fireEvent.input(infUsdHInput, { target: { value: "15" } });
  fireEvent.input(usdHInput, { target: { value: "1.0" } });

  // Forecast card updates live before saving.
  expect(screen.getByTestId("mission-forecast-card").textContent).toContain("~8h 36m runway left");

  fireEvent.click(screen.getByRole("button", { name: "Save bandwidth" }));
  await waitFor(() => expect(savedBw).toEqual({
    tokens_per_min: 90_000,
    inference_usd_per_hour: 15,
    compute_vcpu_per_min: null,
    compute_usd_per_hour: 1,
    protect_root: true,
  }));
});

it("switches budget reset cadence to Daily, previews reset sustainability, and saves reset_period", async () => {
  let savedArgs: { amount: number | null; period?: string } | null = null;
  render(() => (
    <MissionSettings
      missionId="m1"
      title="evm.fast"
      onClose={() => {}}
      load={async () => own(10)}
      loadStats={pendingStats}
      save={async (_id, amount, period) => {
        savedArgs = { amount, period };
        return optimisticBudget(own(amount ?? 10), amount, period);
      }}
    />
  ));
  const dailyRadio = await screen.findByRole("radio", { name: "Daily" });
  expect(dailyRadio.getAttribute("aria-checked")).toBe("false");
  fireEvent.click(dailyRadio);
  expect(dailyRadio.getAttribute("aria-checked")).toBe("true");

  fireEvent.click(screen.getByRole("button", { name: "Save budget" }));
  await waitFor(() => expect(savedArgs).toEqual({ amount: 10, period: "daily" }));
  expect(screen.getByText("Spent today")).toBeTruthy();
});

it("ignores stale background poll responses captured before a settings mutation", async () => {
  let loadCount = 0;
  let resolveStalePoll!: (v: MissionBudget) => void;
  render(() => (
    <MissionSettings
      missionId="m1"
      title="PollRace"
      onClose={() => {}}
      pollIntervalMs={20}
      loadStats={pendingStats}
      load={async () => {
        loadCount += 1;
        if (loadCount === 1) return own(10);
        if (loadCount === 2) {
          return new Promise<MissionBudget>(r => {
            resolveStalePoll = r;
          });
        }
        return own(25);
      }}
      save={async (_id, amount) => own(amount!)}
    />
  ));

  const input = (await screen.findByLabelText("Amount (USD)")) as HTMLInputElement;
  expect(input.value).toBe("10");

  // Wait for the background poll (#2) to be in flight with stale state.
  await waitFor(() => expect(loadCount).toBeGreaterThanOrEqual(2));

  // User saves $25 while poll #2 is still in flight.
  fireEvent.input(input, { target: { value: "25" } });
  fireEvent.click(screen.getByRole("button", { name: "Save budget" }));
  await waitFor(() => expect(screen.getByText(/of \$25(?:\.00)?/)).toBeTruthy());

  // Now resolve the stale poll (#2) with old $10 budget — must NOT overwrite $25!
  resolveStalePoll(own(10));
  await new Promise(r => setTimeout(r, 30));
  expect((screen.getByLabelText("Amount (USD)") as HTMLInputElement).value).toBe("25");
  expect(screen.getByText(/of \$25(?:\.00)?/)).toBeTruthy();
});

it("turns machine limits on, expands per-provider limits, and saves overrides", async () => {
  let savedPayload: VmConcurrencyLimits | null = null;
  render(() => <MissionSettings missionId="m1" title="ecdsa.fail" onClose={() => {}}
    load={async () => base()}
    loadStats={pendingStats}
    saveVmLimits={async (_id, lim) => { savedPayload = lim; return optimisticVmLimits(base(), lim); }} />);
  const toggle = await screen.findByRole("switch", { name: "Machine limit" });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  fireEvent.click(toggle);
  await waitFor(() => expect((screen.getByLabelText("Max concurrent machines") as HTMLInputElement).value).toBe("4"));

  // Expand per-provider limits and set Vast.ai = 2, clearing total max_concurrent.
  fireEvent.click(screen.getByRole("button", { name: /Per-provider limits/ }));
  const maxInput = screen.getByLabelText("Max concurrent machines") as HTMLInputElement;
  const vastInput = screen.getByLabelText("Vast.ai limit") as HTMLInputElement;
  fireEvent.input(maxInput, { target: { value: "" } });
  fireEvent.input(vastInput, { target: { value: "2" } });
  fireEvent.click(screen.getByRole("button", { name: "Save limit" }));
  await waitFor(() => expect(savedPayload).toEqual({ max_concurrent: null, provider_max_concurrent: { vastai: 2 } }));
  expect(screen.getByText("Vast.ai: 0 of 2")).toBeTruthy();
});

it("rolls back a refused change with an inline error and Retry", async () => {
  let calls = 0;
  render(() => <MissionSettings missionId="m1" title="Child" onClose={() => {}}
    load={async () => own(2, { max_grant_usd: 10 })}
    loadStats={pendingStats}
    save={async (_id, amount) => { calls++; if (calls === 1) throw new Error("sub_budget_exceeds_pool: parent has $1 left"); return own(amount!, { max_grant_usd: 10 }); }} />);
  const input = await screen.findByLabelText("Amount (USD)") as HTMLInputElement;
  fireEvent.input(input, { target: { value: "3" } });
  fireEvent.click(screen.getByRole("button", { name: "Save budget" }));
  await waitFor(() => expect(screen.getByText("Budget not saved")).toBeTruthy());
  expect((screen.getByLabelText("Amount (USD)") as HTMLInputElement).value).toBe("2");
  expect(screen.getByText(/of \$2\.00/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(screen.getByText(/of \$3\.00/)).toBeTruthy());
  expect(calls).toBe(2);
});

it("hides duplicate idle subagent pool rows when off and folds $0 rows when on", async () => {
  const children = [
    { mission_id: "c1", mode: "pooled" as const, budget_usd: null, spent_usd: 0.12, reserved_usd: 0 },
    { mission_id: "c2", mode: "sub_budget" as const, budget_usd: 1, spent_usd: 0.3, reserved_usd: 0.1 },
    { mission_id: "c3", mode: "pooled" as const, budget_usd: null, spent_usd: 0, reserved_usd: 0 },
    { mission_id: "c4", mode: "pooled" as const, budget_usd: null, spent_usd: 0, reserved_usd: 0 },
  ];
  const { unmount } = render(() => <MissionSettings missionId="m1" title="RootOff" onClose={() => {}}
    loadStats={pendingStats}
    load={async () => base({ children: children.filter(c => c.spent_usd === 0) })} />);
  await screen.findByRole("switch", { name: "Spending budget" });
  expect(screen.queryByRole("table", { name: "Subagent budgets" })).toBeNull();
  unmount();

  render(() => <MissionSettings missionId="m1" title="Root" onClose={() => {}} titleOf={id => ({ c1: "Probe", c2: "Audit", c3: "Idle A", c4: "Idle B" } as Record<string, string>)[id]}
    loadStats={pendingStats}
    load={async () => own(10, { children })} />);
  const table = await screen.findByRole("table", { name: "Subagent budgets" });
  expect(table.textContent).toContain("Probe");
  expect(table.textContent).toContain("Pooled");
  expect(table.textContent).toContain("Sub-budget $1.00");
  expect(table.textContent).toContain("2 pooled with $0 spend · show");
  expect(table.textContent).not.toContain("Idle A");
  fireEvent.click(screen.getByRole("button", { name: /2 pooled with \$0 spend/ }));
  expect(table.textContent).toContain("Idle A");
});

it("matches the shared cross-client mission-budget fixture", () => {
  const globalDefault = missionBudgetFixture.global_default as MissionBudget;
  const dedicated = missionBudgetFixture.dedicated_override as MissionBudget;
  const dailySust = missionBudgetFixture.daily_sustainable_with_lease_cliff as MissionBudget;
  expect(vmLimitsModeLine(globalDefault)).toBe("Uses the global limit (16 concurrent across Orb).");
  expect(bandwidthModeLine(globalDefault)).toBe("Unthrottled. Requests and spawns run at full speed.");
  expect(providerLimitsSummary(dedicated.own_vm_limits)).toBe("Hetzner: off · Vast.ai: 2");
  expect(bandwidthLimitsSummary(dedicated.own_bandwidth_limits)).toBe("120k tok/min · 32 vCPU/min · $2.50/h");
  expect(bandwidthLimitsSummary(dailySust.own_bandwidth_limits)).toBe("150k tok/min · $18/h LLM · 64 vCPU/min · $10/h");
  expect(modeLine(dailySust)).toContain("Own daily budget");
  expect(optimisticVmLimits(dedicated, null).effective_vm_limits?.max_concurrent).toBe(16);
  expect(optimisticBandwidthLimits(dedicated, null).bandwidth_mode).toBe("none");

  const fc = computeRunwayForecast({
    budget: dailySust,
    budgetEnabled: true,
    bandwidthEnabled: true,
    nowMs: Date.parse("2026-11-05T23:45:00Z"),
  });
  expect(fc.resetPeriod).toBe("daily");
  expect(fc.sustainsUntilReset).toBe(true);
  expect(fc.resetsInSecs).toBe(900);
  expect(fc.leaseCliffSecs).toBe(0);
  expect(fc.headline).toBe("Sustains until daily reset");
  expect(fc.subline).toContain("VM auto-extensions paused ($2.00 < $2.50 30m step)");
  expect(fc.tone).toBe("warning");

  // Pooled child sharing a daily ancestor pool (`max_grant_usd != null`) keeps the ancestor's daily reset cadence.
  const pooledChild: MissionBudget = {
    ...dailySust,
    mission_id: "child-pooled",
    own_budget_usd: null,
    own_budget_reset_period: "total",
    mode: "pooled",
    max_grant_usd: 2.0,
  };
  const pooledFc = computeRunwayForecast({
    budget: pooledChild,
    bandwidthEnabled: true,
    nowMs: Date.parse("2026-11-05T23:45:00Z"),
  });
  expect(pooledFc.resetPeriod).toBe("daily");
  expect(pooledFc.sustainsUntilReset).toBe(true);
  expect(pooledFc.headline).toBe("Sustains until daily reset");

  // Ten $1/h VMs all at 10m remaining (`<= 600s`) with $2.50 available ($0.50 30m step):
  // five VMs extend in the immediate reaper sweep and the sixth is rejected immediately (`0s`).
  const immediateFleetBatch: MissionBudget = {
    ...dailySust,
    pool: {
      ...dailySust.pool!,
      live_machines: 10,
      live_leases: undefined,
      reserved_usd: 1.6667,
      available_usd: 2.5,
      spent_usd: 255.8333,
      carved_usd: 40.0,
    },
  };
  const immediateFleetFc = computeRunwayForecast({
    budget: immediateFleetBatch,
    budgetEnabled: true,
    bandwidthEnabled: true,
    nowMs: Date.parse("2026-11-05T23:45:00Z"),
  });
  expect(immediateFleetFc.sustainsUntilReset).toBe(true);
  expect(immediateFleetFc.leaseCliffSecs).toBe(0);
  expect(immediateFleetFc.subline).toContain("VM auto-extensions paused ($2.50 left across 10 VMs)");

  // Two staggered $5/h VMs with per-VM `live_leases` (15m and 25m remaining) and $2.50 available:
  // VM 0 extends at 5m (300s), consuming the $2.50, and VM 1 hits the cliff at 15m (900s).
  const staggeredCliff: MissionBudget = {
    ...dailySust,
    pool: {
      ...dailySust.pool!,
      live_machines: 2,
      live_leases: [
        { remaining_secs: 900, usd_per_hour: 5.0 },
        { remaining_secs: 1500, usd_per_hour: 5.0 },
      ],
      reserved_usd: 3.3333,
      available_usd: 2.5,
      spent_usd: 254.1667,
      carved_usd: 40.0,
    },
  };
  const staggeredFc = computeRunwayForecast({
    budget: staggeredCliff,
    budgetEnabled: true,
    bandwidthEnabled: true,
    nowMs: Date.parse("2026-11-05T23:45:00Z"),
  });
  expect(staggeredFc.sustainsUntilReset).toBe(true);
  expect(staggeredFc.leaseCliffSecs).toBeCloseTo(900, 0);
  expect(staggeredFc.subline).toContain("VM extensions pause in ~15m");

  // Single $10/h VM, 30m left ($5 reserved), $5 available ($5 30m step):
  // first trigger in 20m (1,200s) is admitted (+1,800s) and the first rejected trigger is at 50m (3,000s).
  const singleVmStep: MissionBudget = {
    ...dailySust,
    pool: {
      ...dailySust.pool!,
      live_machines: 1,
      live_leases: [{ remaining_secs: 1800, usd_per_hour: 10.0 }],
      reserved_usd: 5.0,
      available_usd: 5.0,
      spent_usd: 290.0,
      carved_usd: 0.0,
    },
  };
  const singleVmFc = computeRunwayForecast({
    budget: singleVmStep,
    budgetEnabled: true,
    bandwidthEnabled: true,
    nowMs: Date.parse("2026-11-05T23:45:00Z"),
  });
  expect(singleVmFc.leaseCliffSecs).toBeCloseTo(3000, 0);
});
