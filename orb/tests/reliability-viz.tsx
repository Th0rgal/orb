import { render } from "solid-js/web";
import { createSignal } from "solid-js";
import { ReliabilityView } from "../src/ReliabilityView";
import type { ProxyHealth, ReliabilityGroup, ReliabilityStats } from "../src/proxyHealthApi";
import "../src/styles.css";
import "../src/usage.css";

// Shaped like the production 24h panel that showed a wall of red cards.
const s = (o: Partial<ReliabilityStats>): ReliabilityStats => ({
  requests: 0, ok: 0, success_rate: null, ttft_p50_ms: null, ttft_p95_ms: null, latency_p50_ms: null, latency_p95_ms: null, retried: 0, fell_back: 0, errors: {}, ...o,
});
const grp = (provider: string, model: string, o: Partial<ReliabilityGroup>): ReliabilityGroup => {
  const base = s(o);
  const failed = Object.values(base.errors).reduce((a, b) => a + b, 0);
  const requests = base.requests || base.ok + failed;
  return { provider, model, account_id: null, flags: [], ...base, ...o, requests, success_rate: requests ? base.ok / requests : null } as ReliabilityGroup;
};
const inTwoHours = new Date(Date.now() + 2 * 3600_000).toISOString();
const ago = (m: number) => new Date(Date.now() - m * 60_000).toISOString();
const health: ProxyHealth = {
  window: "24h", since: ago(24 * 60),
  totals: s({ requests: 4210, ok: 4193, success_rate: 0.996, ttft_p50_ms: 6000, ttft_p95_ms: 51000, retried: 16, fell_back: 987 }),
  groups: [
    grp("antigravity", "gemini-4-argon-high", { errors: { "client_error:429": 337 }, flags: ["low_success_rate"], account_id: "8c1f0a2e-0000-4000-8000-000000000001", account_label: "thomas@", cooldown: { state: "quota_exhausted", until: inTwoHours }, recent_errors: [{ at: ago(3), error: "client_error:429" }, { at: ago(9), error: "client_error:429" }] }),
    grp("antigravity", "claude-opus-5-5-high", { ok: 40, errors: { "client_error:429": 210 }, flags: ["low_success_rate"], account_id: "8c1f0a2e-0000-4000-8000-000000000001", account_label: "thomas@", ttft_p50_ms: 4200, ttft_p95_ms: 18000 }),
    grp("antigravity", "claude-opus-5-5-high", { ok: 512, errors: { timeout: 3 }, account_id: "51d0aa11-0000-4000-8000-000000000002", account_label: "team@", ttft_p50_ms: 3900, ttft_p95_ms: 16000 }),
    grp("minimax", "MiniMax-M3", { errors: { "client_error:402": 96 }, flags: ["low_success_rate", "out_of_credit"], cooldown: { state: "out_of_credit", until: inTwoHours }, recent_errors: [{ at: ago(14), error: "client_error:402" }] }),
    grp("openai", "gpt-6-astra", { ok: 610, errors: { "server_error:503": 61, timeout: 22, stalled: 4 }, flags: ["stalls", "slow_first_token"], account_id: "aa000000-0000-4000-8000-000000000003", account_label: "Personal", ttft_p50_ms: 9000, ttft_p95_ms: 51000, recent_errors: [{ at: ago(2), error: "server_error:503" }, { at: ago(6), error: "timeout" }, { at: ago(21), error: "stalled" }] }),
    grp("openai", "gpt-6-astra", { ok: 980, errors: { "server_error:500": 2 }, account_id: "bb000000-0000-4000-8000-000000000004", account_label: "Work", ttft_p50_ms: 5200, ttft_p95_ms: 22000 }),
    grp("zai", "glm-5.3", { ok: 870, errors: { timeout: 4 }, ttft_p50_ms: 2100, ttft_p95_ms: 9000 }),
    grp("google", "gemini-4-argon-eap", { ok: 640, errors: { empty_before_first_chunk: 3 }, ttft_p50_ms: 7000, ttft_p95_ms: 38000 }),
    grp("xai", "grok-4.7", { ok: 233, ttft_p50_ms: 1400, ttft_p95_ms: 6100 }),
    grp("anthropic", "claude-fable", { ok: 88, ttft_p50_ms: 2600, ttft_p95_ms: 7400 }),
  ],
  chains: [],
  series: Array.from({ length: 24 }, (_, i) => {
    const requests = 120 + Math.round(60 * Math.sin(i / 3));
    return { requests, ok: requests - (i === 17 ? 9 : i % 5 === 0 ? 1 : 0), ttft_p50_ms: 5000 + ((i * 937) % 2500), ttft_p95_ms: 30000 + ((i * 7919) % 25000), retried: i % 4, fell_back: 30 + ((i * 13) % 25) };
  }),
  bucket_secs: 3600,
};

const params = new URLSearchParams(location.search);
if (params.get("theme")) document.documentElement.dataset.theme = params.get("theme")!;
const [h, setH] = createSignal<ProxyHealth | null>(params.has("loading") ? null : health);
(window as unknown as { setHealth: typeof setH }).setHealth = setH;
document.body.style.cssText = "margin:0;background:var(--bg);color:var(--fg);font:13px var(--sans)";
render(() => <main class="s-inner" style={{ padding: "16px", "max-width": "760px", margin: "0 auto" }}>
  <section class="s-sec" aria-label="Reliability"><h3 style={{ margin: 0 }}>Reliability</h3><ReliabilityView health={h()} /></section>
</main>, document.getElementById("root")!);
