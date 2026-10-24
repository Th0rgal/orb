import { render, fireEvent, screen, waitFor } from "@solidjs/testing-library";
import { afterEach } from "vitest";
import { cleanup } from "@solidjs/testing-library";
afterEach(cleanup);
import { expect, it } from "vitest";
import { MissionSettings } from "../src/MissionSettings";
import { exceedsGrant, modeLine, optimisticBudget, parseAmount, usedFraction, type MissionBudget } from "../src/missionBudget";

const base = (over: Partial<MissionBudget> = {}): MissionBudget => ({
  mission_id: "m1", own_budget_usd: null, pool_id: null, mode: "none", pool: null, max_grant_usd: null, children: [], ...over,
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

it("derives the optimistic view and the mode line", () => {
  const on = optimisticBudget(base(), 5);
  expect(on.mode).toBe("own");
  expect(on.pool?.available_usd).toBe(5);
  const raised = optimisticBudget(own(4), 6);
  expect(raised.pool?.available_usd).toBeCloseTo(4.4);
  expect(optimisticBudget(own(4), null).mode).toBe("none");
  expect(optimisticBudget(own(4, { max_grant_usd: 2 }), null).mode).toBe("pooled");
  expect(modeLine(base({ mode: "pooled", pool_id: "p" }), "Parent")).toContain("Parent");
  expect(modeLine(base())).toContain("daily");
  expect(usedFraction(own(4).pool!)).toBeCloseTo(0.4);
});

it("turns the budget on optimistically and keeps the server's answer", async () => {
  let resolve!: (v: MissionBudget) => void;
  render(() => <MissionSettings missionId="m1" title="Snark" onClose={() => {}}
    load={async () => base()} save={() => new Promise(r => { resolve = r; })} />);
  const toggle = await screen.findByRole("switch", { name: "Spending budget" });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  fireEvent.click(toggle);
  // Optimistic: on before the server answers.
  expect(screen.getByRole("switch").getAttribute("aria-checked")).toBe("true");
  expect(screen.getByText(/of \$5\.00/)).toBeTruthy();
  resolve(own(5));
  await waitFor(() => expect(screen.getByText("$0.40")).toBeTruthy());
});

it("rolls back a refused change with an inline error and Retry", async () => {
  let calls = 0;
  render(() => <MissionSettings missionId="m1" title="Child" onClose={() => {}}
    load={async () => own(2, { max_grant_usd: 10 })}
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

it("lists pooled and sub-budget subagents", async () => {
  render(() => <MissionSettings missionId="m1" title="Root" onClose={() => {}} titleOf={id => ({ c1: "Probe", c2: "Audit" } as Record<string, string>)[id]}
    load={async () => own(10, { children: [
      { mission_id: "c1", mode: "pooled", budget_usd: null, spent_usd: 0.12, reserved_usd: 0 },
      { mission_id: "c2", mode: "sub_budget", budget_usd: 1, spent_usd: 0.3, reserved_usd: 0.1 },
    ] })} />);
  const list = await screen.findByRole("list", { name: "Subagent budgets" });
  expect(list.textContent).toContain("Probe");
  expect(list.textContent).toContain("Pooled");
  expect(list.textContent).toContain("Sub-budget $1.00");
});
