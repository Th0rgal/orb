import { render, screen, fireEvent, waitFor, within } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { UsageSettings } from "../src/UsageSettings";
import { setConnection } from "../src/api";
import { chartBuckets, formatCost, usageQuery, windowHours, type UsageSummary, type UsageTotals } from "../src/usageApi";
import { formatMs, formatRate, type ProxyHealth, type ReliabilityStats } from "../src/proxyHealthApi";

const stats = (over: Partial<ReliabilityStats> = {}): ReliabilityStats => ({
  requests: 0, ok: 0, success_rate: null, ttft_p50_ms: null, ttft_p95_ms: null, latency_p50_ms: null, latency_p95_ms: null, retried: 0, fell_back: 0, errors: {}, ...over,
});

export function proxyHealth(window = "24h"): ProxyHealth {
  return {
    window, since: "2026-10-19T12:00:00+00:00",
    totals: stats({ requests: 400, ok: 380, success_rate: 0.95, ttft_p50_ms: 1200, ttft_p95_ms: 8400, retried: 12, fell_back: 30 }),
    groups: [
      { provider: "minimax", model: "MiniMax-M3", account_id: "15d3c9ef-573e-447d-bebe-cfcd8097343d", flags: ["low_success_rate", "out_of_credit"], ...stats({ requests: 483, ok: 0, success_rate: 0, errors: { "client_error:402": 483 } }) },
      { provider: "google", model: "gemini-4-argon-eap", account_id: null, flags: [], ...stats({ requests: 330, ok: 320, success_rate: 320 / 330, ttft_p50_ms: 900, ttft_p95_ms: 4000, errors: { empty_before_first_chunk: 10 } }) },
    ],
    chains: [{ chain_id: "builtin/smart", ...stats({ requests: 400, ok: 380, success_rate: 0.95 }) }],
  };
}

const totals = (over: Partial<UsageTotals> = {}): UsageTotals => ({
  requests: 0, input_tokens: 0, output_tokens: 0, cache_creation_tokens: 0, cache_read_tokens: 0, cost_cents: 0, unknown_cost_requests: 0, ...over,
});

export function summary(window = "24h"): UsageSummary {
  const argon = totals({ requests: 250, input_tokens: 2_000_000, output_tokens: 100_000, cost_cents: 520 });
  const mystery = totals({ requests: 4, input_tokens: 400, unknown_cost_requests: 4 });
  const harness = totals({ requests: 10, input_tokens: 50_000, output_tokens: 5_000, cache_read_tokens: 200_000, cost_cents: 90 });
  const all = totals({ requests: 264, input_tokens: 2_050_400, output_tokens: 105_000, cache_read_tokens: 200_000, cost_cents: 610, unknown_cost_requests: 4 });
  return {
    window, since: "2026-10-19T12:00:00+00:00", cost_status: "partial", totals: all,
    by_model: [
      { model: "gemini-4-argon", provider: "google", source: "router", cost_status: "known", ...argon },
      { model: "claude-opus-5-5", provider: "anthropic", source: "harness", cost_status: "known", ...harness },
      { model: "mystery-model", provider: null, source: "router", cost_status: "unknown", ...mystery },
    ],
    by_provider: [{ key: "google", label: null, cost_status: "known", ...argon }, { key: "anthropic", label: null, cost_status: "known", ...harness }],
    by_source: [{ key: "router", label: null, cost_status: "partial", ...totals({ requests: 254, cost_cents: 520, unknown_cost_requests: 4 }) }, { key: "harness", label: null, cost_status: "known", ...harness }],
    by_backend: [{ key: "claudecode", label: null, cost_status: "known", ...harness }],
    by_mission: [{ key: "m-1", label: "Fix login", cost_status: "known", ...harness }],
    by_api_key: [{ key: "key-argon", label: "Nightly bot", cost_status: "known", ...argon }],
    by_account: [],
    by_caller_kind: [
      { key: "script", label: null, cost_status: "partial", ...totals({ requests: 254, input_tokens: 2_000_400, output_tokens: 100_000, cost_cents: 520, unknown_cost_requests: 4 }) },
      { key: "subagent", label: null, cost_status: "known", ...harness },
    ],
    by_purpose: [],
    by_day: [{ day: "2026-10-20", router_requests: 254, ...all }],
    by_hour: [{ hour: "2026-10-20T09", router_requests: 250, ...argon }, { hour: "2026-10-20T11", router_requests: 4, ...harness }],
  };
}

describe("usage helpers", () => {
  it("builds queries with only set filters", () => {
    expect(usageQuery("5h", { provider: "google", backend: "" })).toBe("/api/ai/usage/summary?window=5h&provider=google");
  });
  it("never shows unpriced usage as $0", () => {
    expect(formatCost(totals({ requests: 3, unknown_cost_requests: 3 }))).toBe("Unknown");
    expect(formatCost(totals({ requests: 3, unknown_cost_requests: 1, cost_cents: 250 }))).toBe("$2.50+");
    expect(formatCost(totals({ requests: 3, cost_cents: 12_345 }))).toBe("$123");
  });
  it("parses windows and fills empty chart buckets", () => {
    expect(windowHours("5h")).toBe(5);
    expect(windowHours("2w")).toBe(336);
    expect(windowHours("all")).toBeNull();
    const now = new Date("2026-10-20T11:40:00Z");
    const hourly = chartBuckets(summary("5h"), now);
    expect(hourly.granularity).toBe("hour");
    expect(hourly.buckets.map(b => b.key)).toEqual(["2026-10-20T07", "2026-10-20T08", "2026-10-20T09", "2026-10-20T10", "2026-10-20T11"]);
    expect(hourly.buckets[2].requests).toBe(250);
    expect(hourly.buckets[3].tokens).toBe(0);
    const daily = chartBuckets(summary("30d"), now);
    expect(daily.granularity).toBe("day");
    expect(daily.buckets).toHaveLength(30);
    expect(daily.buckets.at(-1)!.key).toBe("2026-10-20");
    const forcedDaily = chartBuckets(summary("24h"), now, "day");
    expect(forcedDaily.granularity).toBe("day");
    expect(forcedDaily.buckets.map(b => b.key)).toEqual(["2026-10-20"]);
  });
});

describe("Usage page", () => {
  let requests: string[];
  beforeEach(() => {
    requests = [];
    setConnection("https://usage.test", "fixture");
    vi.stubGlobal("fetch", vi.fn(async (input: string) => {
      const url = new URL(input);
      requests.push(url.pathname + url.search);
      if (url.pathname === "/api/ai/usage/summary") return new Response(JSON.stringify(summary(url.searchParams.get("window") ?? "all")));
      if (url.pathname === "/api/ai/proxy/health") return new Response(JSON.stringify(proxyHealth(url.searchParams.get("window") ?? "24h")));
      throw Error(url.pathname);
    }));
  });
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("shows totals, router attribution and unknown costs, and filters by key", async () => {
    render(() => <UsageSettings />);
    await screen.findByText("gemini-4-argon");
    expect(screen.getByText("$6.10+")).toBeTruthy();
    expect(screen.getByText("96%")).toBeTruthy();
    expect(within(screen.getByRole("table", { name: "Usage by model" })).getByText("Unknown")).toBeTruthy();
    expect(screen.getByText("Router · google")).toBeTruthy();
    expect(requests.find(r => r.startsWith("/api/ai/usage/"))).toBe("/api/ai/usage/summary?window=24h");

    const groupBy = screen.getByLabelText("Group by") as HTMLSelectElement;
    groupBy.value = "api_key";
    fireEvent.change(groupBy);
    fireEvent.click(await screen.findByRole("button", { name: "Nightly bot" }));
    await waitFor(() => expect(requests).toContain("/api/ai/usage/summary?window=24h&api_key=key-argon"));
    expect(await screen.findByRole("button", { name: "Clear api_key filter" })).toBeTruthy();

    const window = screen.getByLabelText("Time window") as HTMLSelectElement;
    window.value = "5h";
    fireEvent.change(window);
    await waitFor(() => expect(requests).toContain("/api/ai/usage/summary?window=5h&api_key=key-argon"));
  });

  it("breaks usage down by caller kind, filters by caller and toggles day/hour", async () => {
    render(() => <UsageSettings />);
    await screen.findByText("gemini-4-argon");
    const groupBy = screen.getByLabelText("Group by") as HTMLSelectElement;
    groupBy.value = "caller_kind";
    fireEvent.change(groupBy);
    expect(await screen.findByRole("button", { name: "Script / API key" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Subagent" }));
    await waitFor(() => expect(requests).toContain("/api/ai/usage/summary?window=24h&caller_kind=subagent"));
    await waitFor(() => expect((screen.getByLabelText("Caller") as HTMLSelectElement).value).toBe("subagent"));

    const chart = () => screen.getByRole("figure");
    expect(chart().getAttribute("aria-label")).toBe("tokens per hour");
    fireEvent.click(screen.getByRole("radio", { name: "Day" }));
    await waitFor(() => expect(chart().getAttribute("aria-label")).toBe("tokens per day"));
    const window = screen.getByLabelText("Time window") as HTMLSelectElement;
    window.value = "30d";
    fireEvent.change(window);
    await waitFor(() => expect((screen.getByRole("radio", { name: "Hour" }) as HTMLButtonElement).disabled).toBe(true));
  });

  it("shows router reliability ranked by impact and switches the window", async () => {
    render(() => <UsageSettings />);
    const section = await screen.findByRole("region", { name: "Reliability" });
    await waitFor(() => expect(section.textContent).toContain("95.0%"));
    expect(section.textContent).toContain("1.2 s");
    expect(section.textContent).toContain("8.4 s");
    expect(section.textContent).toContain("12 · 30");
    const rows = screen.getByRole("table", { name: "Reliability by provider" });
    expect(rows.textContent).toContain("minimax · MiniMax-M3");
    expect(rows.textContent).toContain("Down");
    // Healthy rows fold behind a toggle.
    expect(rows.textContent).not.toContain("gemini");
    fireEvent.click(within(rows).getByRole("button", { name: "1 healthy · show" }));
    expect(rows.textContent).toContain("97.0%");
    fireEvent.click(within(rows).getByText("minimax · MiniMax-M3"));
    expect(rows.textContent).toContain("402 out of credit");
    expect(requests).toContain("/api/ai/proxy/health?window=24h");
    fireEvent.click(screen.getByRole("radio", { name: "1h" }));
    await waitFor(() => expect(requests).toContain("/api/ai/proxy/health?window=1h"));
  });

  it("keeps usage visible when an older core has no reliability endpoint", async () => {
    vi.stubGlobal("fetch", vi.fn(async (input: string) => {
      const url = new URL(input);
      if (url.pathname === "/api/ai/usage/summary") return new Response(JSON.stringify(summary()));
      return new Response("not found", { status: 404 });
    }));
    render(() => <UsageSettings />);
    await screen.findByText("gemini-4-argon");
    await waitFor(() => expect(screen.getByRole("region", { name: "Reliability" }).textContent).toContain("unavailable"));
  });
});

describe("reliability helpers", () => {
  it("formats rates and latencies", () => {
    expect(formatRate(null)).toBe("—");
    expect(formatRate(1)).toBe("100%");
    expect(formatRate(0.8467)).toBe("84.7%");
    expect(formatMs(450)).toBe("450 ms");
    expect(formatMs(45_000)).toBe("45 s");
  });
});
