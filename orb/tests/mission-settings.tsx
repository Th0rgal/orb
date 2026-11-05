import { render } from "solid-js/web";
import { createSignal, Show } from "solid-js";
import { MissionSettings } from "../src/MissionSettings";
import { optimisticBandwidthLimits, optimisticVmLimits, type MissionBudget } from "../src/missionBudget";
import type { MissionResourcesResponse } from "../src/api";
import "../src/styles.css";

// Test data: a root agent with a $10 pool, active compute & token telemetry,
// one pooled and one sub-budget subagent, plus idle $0 subagents when `?crowd=1`.
// `?mode=none` starts with budget, bandwidth & machine limit off;
// `?refuse=1` makes every save fail (rollback).
const q = new URLSearchParams(location.search);
if (q.get("theme")) document.documentElement.dataset.theme = q.get("theme")!;
const crowd = q.get("crowd") === "1";

const idleChildren = Array.from({ length: 10 }, (_, i) => ({
  mission_id: `idle-${i + 1}`,
  mode: "pooled" as const,
  budget_usd: null,
  spent_usd: 0,
  reserved_usd: 0,
}));

const titles: Record<string, string> = {
  c1: "CPU probe (small)",
  c2: "Audit lean-native",
  root: "Snark.fast campaign",
  ...Object.fromEntries(idleChildren.map((c, i) => [c.mission_id, `Maxwell Loop ${i + 1}`])),
};

const baseEffectiveBandwidth = {
  source: "none" as const,
  pool_id: null,
  tokens_per_min: null,
  compute_vcpu_per_min: null,
  compute_usd_per_hour: null,
  protect_root: false,
  current_tokens_per_min: 64_000,
  current_vcpu_per_min: 16,
  current_compute_usd_per_hour: 1.5,
  pacing_active: false,
  paced_delay_ms: 0,
  ancestor_tokens_per_min: null,
  ancestor_compute_vcpu_per_min: null,
  ancestor_compute_usd_per_hour: null,
};

let current: MissionBudget = q.get("mode") === "none"
  ? {
    mission_id: "root",
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
    effective_bandwidth: baseEffectiveBandwidth,
    children: crowd ? idleChildren : [],
  }
  : {
    mission_id: "root",
    own_budget_usd: 10,
    pool_id: "root",
    mode: "own",
    max_grant_usd: null,
    pool: { pool_id: "root", budget_usd: 10, spent_usd: 1.6021, reserved_usd: 0.4, carved_usd: 2, available_usd: 5.9979, live_machines: 2 },
    own_vm_limits: null,
    vm_limits_mode: "global",
    vm_limits_pool_id: null,
    effective_vm_limits: {
      source: "global",
      pool_id: null,
      active: 2,
      max_concurrent: 16,
      global_active: 2,
      global_max_concurrent: 16,
      ancestor_max_concurrent: null,
      provider_limits: [],
    },
    own_bandwidth_limits: null,
    bandwidth_mode: "none",
    bandwidth_pool_id: null,
    effective_bandwidth: baseEffectiveBandwidth,
    children: [
      { mission_id: "c1", mode: "pooled", budget_usd: null, spent_usd: 0.031, reserved_usd: 0.018 },
      { mission_id: "c2", mode: "sub_budget", budget_usd: 2, spent_usd: 0.42, reserved_usd: 0.2 },
      ...(crowd ? idleChildren : []),
    ],
  };

const sampleResources: MissionResourcesResponse = {
  as_of: "2026-11-05T00:00:00Z",
  mission: {
    id: "root",
    title: "Snark.fast campaign",
    project: "zk",
    status: "active",
    started_at: "2026-11-04T21:00:00Z",
    elapsed_secs: 10_800,
    eta_remaining_secs: 9_000,
    subagent_count: 2,
    track_count: 2,
  },
  available_horizons: [{ id: "6h", label: "6h", span_secs: 21_600 }],
  active_horizon: "6h",
  flow: { inputs: [], tracks: [], subagents: [], input_to_track: [], track_to_subagent: [] },
  dag: { origin_unix_secs: 0, horizon_secs: 21_600, now_offset_secs: 10_800, bars: [] },
  timeline: {
    offsets_secs: [0, 2700, 5400, 8100, 10800],
    observed_vcpu: [4, 8, 16, 16, 16],
    projected_vcpu: [null, null, null, null, 16],
    observed_compute_usd_per_h: [0.4, 0.9, 1.4, 1.5, 1.5],
    projected_compute_usd_per_h: [null, null, null, null, 1.5],
    observed_b_tok_per_h: [0.001, 0.002, 0.0035, 0.0038, 0.00384],
    projected_b_tok_per_h: [null, null, null, null, 0.00384],
    observed_inference_usd_per_h: [0.2, 0.35, 0.5, 0.55, 0.55],
    projected_inference_usd_per_h: [null, null, null, null, 0.55],
  },
};

const wait = (ms: number) => new Promise(r => setTimeout(r, ms));

function App() {
  const [route, setRoute] = createSignal("ms:root");
  return (
    <div style={{ height: "100vh", display: "flex", "flex-direction": "column", background: "var(--bg)", color: "var(--fg)" }}>
      <Show when={route() === "ms:root"} fallback={<div style={{ padding: "24px" }} data-testid="opened-route">{route()}</div>}>
        <MissionSettings
          missionId="root"
          title={titles.root}
          titleOf={id => titles[id]}
          onOpen={next => setRoute(next)}
          load={async () => {
            await wait(50);
            return current;
          }}
          loadResources={async () => {
            await wait(30);
            return sampleResources;
          }}
          loadStats={async (_id, period) => {
            await wait(40);
            return {
              mission_id: "root",
              period,
              since: null,
              own: {
                vm_usd: 0.62,
                total_usd: period === "today" ? 0.91 : 4.37,
                models: [
                  { provider: "openai", model: "gpt-6.1-sol", requests: 41, input_tokens: 1_840_000, cache_read_tokens: 620_000, cache_write_tokens: 0, output_tokens: 96_000, cost_usd: period === "today" ? 0.21 : 2.95, shadow_priced: false, unpriced: false },
                  { provider: "antigravity", model: "gemini-4-argon", requests: 18, input_tokens: 410_000, cache_read_tokens: 0, cache_write_tokens: 0, output_tokens: 22_000, cost_usd: 0.8, shadow_priced: true, unpriced: false },
                  ...(crowd ? [{ provider: null, model: "", requests: 21, input_tokens: 6_000_000, cache_read_tokens: 107_200_000, cache_write_tokens: 0, output_tokens: 602_000, cost_usd: 0, shadow_priced: false, unpriced: true }] : []),
                ],
              },
              subtree_total_usd: period === "today" ? 1.4 : 6.12,
              children: [
                { mission_id: "c1", title: "CPU probe (small)", total_usd: 0.31 },
                { mission_id: "c2", title: "Audit lean-native", total_usd: 1.44 },
                ...(crowd ? idleChildren.map((c, i) => ({ mission_id: c.mission_id, title: `Maxwell Loop ${i + 1}`, total_usd: 0 })) : []),
              ],
            };
          }}
          save={async (_id, amount) => {
            await wait(150);
            if (q.get("refuse")) throw new Error("sub_budget_exceeds_pool: Sub-budget exceeds what the parent pool can grant ($1.0000 remaining)");
            current = amount == null
              ? { ...current, own_budget_usd: null, mode: "none", pool: null, pool_id: null }
              : {
                ...current,
                own_budget_usd: amount,
                mode: "own",
                pool_id: "root",
                pool: {
                  pool_id: "root",
                  budget_usd: amount,
                  spent_usd: current.pool?.spent_usd ?? 0,
                  reserved_usd: current.pool?.reserved_usd ?? 0,
                  carved_usd: current.pool?.carved_usd ?? 0,
                  available_usd: amount - (current.pool ? current.pool.spent_usd + current.pool.reserved_usd + current.pool.carved_usd : 0),
                  live_machines: 0,
                },
              };
            return current;
          }}
          saveVmLimits={async (_id, limits) => {
            await wait(120);
            if (q.get("refuse")) throw new Error("sub_limit_exceeds_pool: Limit exceeds ancestor pool");
            current = optimisticVmLimits(current, limits);
            return current;
          }}
          saveBandwidthLimits={async (_id, limits) => {
            await wait(120);
            if (q.get("refuse")) throw new Error("sub_bandwidth_exceeds_pool: Bandwidth exceeds ancestor pool");
            current = optimisticBandwidthLimits(current, limits);
            return current;
          }}
        />
      </Show>
    </div>
  );
}

render(() => <App />, document.getElementById("root")!);
