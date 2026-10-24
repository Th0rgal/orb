import { describe, expect, it } from "vitest";
import type { ReliabilityGroup } from "../src/proxyHealthApi";
import { classify, impact, outcomeMix, outcomeOf, reliabilityRows } from "../src/reliability";

const NOW = Date.parse("2026-10-24T12:00:00Z");
const g = (over: Partial<ReliabilityGroup>): ReliabilityGroup => ({
  provider: "p", model: "m", account_id: null, flags: [], requests: 0, ok: 0, success_rate: null,
  ttft_p50_ms: null, ttft_p95_ms: null, latency_p50_ms: null, latency_p95_ms: null, retried: 0, fell_back: 0, errors: {}, ...over,
});

describe("reliability classification", () => {
  it("buckets error keys into outcomes", () => {
    expect(outcomeOf("client_error:429")).toBe("limited");
    expect(outcomeOf("client_error:402")).toBe("client");
    expect(outcomeOf("server_error:503")).toBe("server");
    expect(outcomeOf("stalled")).toBe("timeout");
    expect(outcomeMix(g({ ok: 3, errors: { "client_error:429": 2, timeout: 1, empty_before_first_chunk: 1 } })))
      .toEqual({ ok: 3, limited: 2, client: 0, server: 0, timeout: 2 });
  });

  it("shows 429s under an active quota cooldown as amber waiting, not a failure", () => {
    const s = classify(g({ provider: "antigravity", requests: 337, errors: { "client_error:429": 337 }, flags: ["low_success_rate"],
      cooldown: { state: "quota_exhausted", until: "2026-10-24T14:30:00Z" } }), NOW);
    expect(s.health).toBe("quota");
    expect(s.tone).toBe("warning");
    expect(s.label).toMatch(/^Quota cooldown until /);
  });

  it("keeps 429s amber after the cooldown expired, and never Down", () => {
    const s = classify(g({ requests: 337, errors: { "client_error:429": 337 }, cooldown: { state: "quota_exhausted", until: "2026-10-24T11:00:00Z" } }), NOW);
    expect(s).toMatchObject({ health: "limited", tone: "warning" });
  });

  it("classifies hard failures as Down or Degraded", () => {
    expect(classify(g({ requests: 483, errors: { "client_error:402": 483 }, flags: ["out_of_credit"] }), NOW).health).toBe("down");
    expect(classify(g({ requests: 100, ok: 80, errors: { "server_error:503": 20 } }), NOW)).toMatchObject({ health: "degraded", tone: "danger" });
    expect(classify(g({ requests: 100, ok: 98, errors: { timeout: 2 } }), NOW).health).toBe("healthy");
    expect(classify(g({ requests: 3, errors: { timeout: 3 } }), NOW).health).toBe("degraded");
    expect(classify(g({ requests: 10, ok: 0, errors: { "client_error:401": 10 }, cooldown: { state: "auth_failed", until: "2026-10-24T13:00:00Z" } }), NOW).label).toBe("Auth failed");
  });

  it("ranks by weighted impact and labels duplicate provider·model rows by account", () => {
    const quota = g({ provider: "antigravity", model: "opus", account_id: "aaaaaaaa-1", account_label: "Work", requests: 400, errors: { "client_error:429": 400 } });
    const quota2 = g({ provider: "antigravity", model: "opus", account_id: "bbbbbbbb-2", requests: 50, ok: 50 });
    const broken = g({ provider: "zai", model: "glm", requests: 150, ok: 10, errors: { "server_error:500": 140 } });
    const healthy = g({ provider: "openai", model: "gpt", requests: 900, ok: 900 });
    expect(impact(quota)).toBe(100);
    const rows = reliabilityRows([healthy, quota2, quota, broken], NOW);
    expect(rows.map(r => r.name)).toEqual(["zai · glm", "antigravity · opus", "openai · gpt", "antigravity · opus"]);
    expect(rows[1].account).toBe("Work");
    expect(rows[3].account).toBe("bbbbbbbb");
    expect(rows[2].account).toBeUndefined();
  });
});
