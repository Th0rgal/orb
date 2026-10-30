import { render, fireEvent, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it } from "vitest";
import { cleanup } from "@solidjs/testing-library";
afterEach(cleanup);
import { MissionSettings } from "../src/MissionSettings";
import {
  exceedsGrant,
  modeLine,
  optimisticBudget,
  optimisticVmLimits,
  parseAmount,
  parseVmLimits,
  providerLimitsSummary,
  usedFraction,
  vmLimitsModeLine,
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
  children: [],
  ...over,
});
const own = (budget: number, over: Partial<MissionBudget> = {}): MissionBudget => base({
  own_budget_usd: budget, pool_id: "m1", mode: "own",
  pool: { pool_id: "m1", budget_usd: budget, spent_usd: 0.4, reserved_usd: 0.2, carved_usd: 1, available_usd: budget - 1.6, live_machines: 1 },
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
  const capOn = optimisticVmLimits(base(), { max_concurrent: null, provider_max_concurrent: { vastai: 2 } });
  expect(capOn.vm_limits_mode).toBe("own");
  expect(capOn.effective_vm_limits?.provider_limits).toEqual([{ provider: "vastai", active: 0, max_concurrent: 2 }]);
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
  expect(vmLimitsModeLine(globalDefault)).toBe("Uses the global limit (16 concurrent across Orb).");
  expect(providerLimitsSummary(dedicated.own_vm_limits)).toBe("Hetzner: off · Vast.ai: 2");
  expect(optimisticVmLimits(dedicated, null).effective_vm_limits?.max_concurrent).toBe(16);
});
