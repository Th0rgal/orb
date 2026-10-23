import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { render, fireEvent } from "@solidjs/testing-library";
import { SpendChart } from "../src/ManagedMachines";
import { spendDayDetail, spendFraction, spendSummary, topMissions, type DailySpend, type ManagedBudget } from "../src/managedMachineModel";

const spec = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "managed-spend.json"), "utf8")) as
  { cases: { name: string; days: DailySpend[]; total: number; today: number; max: number; fractions: number[]; top: { ids: (string | null)[]; more: number }[] }[] };
const budget: ManagedBudget = { spent_today_usd: 0.25, daily_cap_usd: null, active: 1, max_concurrent: null, default_ttl_minutes: 60, max_ttl_minutes: 240, default_size: "small", max_size: "large" };
const week = spec.cases.find(c => c.name === "week")!.days;
const titles = (id: string) => ({ m2: "Fix login" } as Record<string, string>)[id];

describe("shared/orb-spec/fixtures/managed-spend.json", () => {
  for (const c of spec.cases) it(c.name, () => {
    const s = spendSummary(c.days);
    expect(s.total).toBeCloseTo(c.total); expect(s.today).toBeCloseTo(c.today); expect(s.max).toBeCloseTo(c.max);
    c.days.forEach((d, i) => { expect(spendFraction(d.usd, s.max)).toBeCloseTo(c.fractions[i]); expect(topMissions(d)).toEqual(c.top[i]); });
  });
});

describe("spend day detail", () => {
  it("names the top missions and counts the rest", () => {
    expect(spendDayDetail(week[1], titles)).toMatch(/18.* · \$1\.00 · Fix login \$0\.60, No mission \$0\.30 \+1 more$/);
    expect(spendDayDetail(week[0], titles)).toMatch(/ · no spend$/);
    expect(spendDayDetail(week[3], titles)).toMatch(/Mission m1 \$0\.01$/);
  });
});

describe("SpendChart", () => {
  it("renders a same-size skeleton while loading", () => {
    const { getByTestId } = render(() => <SpendChart />);
    const el = getByTestId("spend-chart");
    expect(el.getAttribute("aria-busy")).toBe("true");
    expect(el.querySelectorAll(".spend-col")).toHaveLength(7);
    expect(el.querySelectorAll("button")).toHaveLength(0);
  });
  it("shows the week total, today and running, and a day on hover/tap", async () => {
    const { getByTestId, getAllByRole } = render(() => <SpendChart days={week} budget={budget} title={titles} />);
    expect(getByTestId("spend-chart").textContent).toContain("$3.76 last 7 days");
    expect(getByTestId("spend-caption").textContent).toBe("$0.25 today");
    const bars = getAllByRole("button");
    expect(bars).toHaveLength(7);
    expect(bars.filter(b => b.classList.contains("zero"))).toHaveLength(2);
    expect((bars[2].querySelector(".spend-bar") as HTMLElement).style.height).toBe("100%");
    fireEvent.mouseEnter(bars[1]);
    expect(getByTestId("spend-caption").textContent).toContain("Fix login $0.60");
    fireEvent.mouseLeave(getByTestId("spend-chart"));
    expect(getByTestId("spend-caption").textContent).toBe("$0.25 today");
    fireEvent.click(bars[5]);
    expect(bars[5].getAttribute("aria-pressed")).toBe("true");
    expect(getByTestId("spend-caption").textContent).toContain("$0.50");
  });
  it("empty week: every bar is a baseline", () => {
    const days = week.map(d => ({ ...d, usd: 0, missions: [] }));
    const { getAllByRole, getByTestId } = render(() => <SpendChart days={days} budget={{ ...budget, active: 0 }} />);
    expect(getAllByRole("button").every(b => b.classList.contains("zero"))).toBe(true);
    expect(getByTestId("spend-caption").textContent).toBe("$0.00 today");
    expect(getByTestId("spend-running").textContent).toBe("0 running");
  });
});
