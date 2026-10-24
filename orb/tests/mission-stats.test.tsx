import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it } from "vitest";
import { MissionStatsSection } from "../src/MissionStatsSection";
import { subagentsUsd, tokens, usd, type MissionStats, type StatsPeriod } from "../src/missionStats";
afterEach(cleanup);

const stats = (period: StatsPeriod): MissionStats => ({
  mission_id: "root", period, since: null,
  own: {
    models: [
      { provider: "openai", model: "gpt-6.1-sol", requests: 12, input_tokens: 120_000, cache_read_tokens: 40_000, cache_write_tokens: 0, output_tokens: 9_000, cost_usd: period === "today" ? 0.4 : 3.2, shadow_priced: false, unpriced: false },
      { provider: "antigravity", model: "gemini-4-argon", requests: 4, input_tokens: 2_000, cache_read_tokens: 0, cache_write_tokens: 0, output_tokens: 500, cost_usd: 0.05, shadow_priced: true, unpriced: false },
    ],
    vm_usd: 0.6, total_usd: period === "today" ? 1.05 : 3.85,
  },
  subtree_total_usd: period === "today" ? 1.5 : 5.0,
  children: [{ mission_id: "c1", title: "Probe", total_usd: 1.15 }],
});

it("formats money and tokens", () => {
  expect(usd(0)).toBe("$0");
  expect(usd(0.004)).toBe("$0.004");
  expect(usd(1240)).toBe("$1,240");
  expect(tokens(1234)).toBe("1.2k");
  expect(tokens(3_400_000)).toBe("3.4M");
  expect(subagentsUsd(stats("lifetime"))).toBeCloseTo(1.15);
});

it("shows totals, served models, VM cost, subagents and switches period", async () => {
  const calls: StatsPeriod[] = [];
  render(() => <MissionStatsSection missionId="root" load={async (_id, period) => { calls.push(period); return stats(period); }} />);
  await waitFor(() => expect(screen.getByTestId("stats-total").textContent).toBe("$5.00"));
  const table = screen.getByRole("table", { name: "Spend by served model" });
  expect(table.textContent).toContain("openai/gpt-6.1-sol");
  expect(table.textContent).toContain("shadow");
  expect(table.textContent).toContain("Managed VMs (boat)");
  expect(screen.getByRole("list", { name: "Subagent spend" }).textContent).toContain("Probe$1.15");
  fireEvent.click(screen.getByRole("radio", { name: "Today" }));
  await waitFor(() => expect(screen.getByTestId("stats-total").textContent).toBe("$1.50"));
  expect(calls).toEqual(["lifetime", "today"]);
});

it("reports a load failure with Retry", async () => {
  let fail = true;
  render(() => <MissionStatsSection missionId="root" load={async p => { if (fail) throw new Error("offline"); return stats(p); }} />);
  await waitFor(() => expect(screen.getByText("Couldn’t load stats")).toBeTruthy());
  fail = false;
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(screen.getByTestId("stats-total").textContent).toBe("$5.00"));
});
