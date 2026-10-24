# Mission spend statistics

Statistics only: nothing here limits spend. Limits come later and reuse the
same settle step (see "Planned").

## What is counted

Per mission, in one USD unit:

- **LLM requests** from the usage ledger (`docs/specs/usage-attribution.md`).
  The proxy records the `(provider, model)` of the final successful attempt,
  so requests group by the model that actually **served** them, aggregated
  across chains and routes (the chain name is not a grouping key).
  Harness-reported usage counts only for missions with no proxied traffic
  (the ledger's dedupe rule).
- **Managed VMs** (boat): a machine's cost goes to its owner mission. For
  "today", each machine's cost is spread over the time it ran and today's
  share is kept (same rule as the 7-day spend chart).

## Prices

| Billing | Which requests | Price |
| --- | --- | --- |
| metered | default | the ledger's list price (re-priced from tokens) |
| subscription | providers in `subscription_providers` (default Antigravity, Muse) or accounts in `subscription_accounts` (OAuth logins on a metered provider) | shadow price from `prices` (`provider/model` or `provider`, USD per million input / cache read / cache write / output tokens), else the model's list price; flagged `shadow_priced` |
| local | `local_providers` (default `spark`, `local`) | 0 |

A request with no price at all counts as 0 and is flagged `unpriced`, never
shown as a silent $0. The table lives in `.sandboxed-sh/shadow_prices.json`
(`GET/PUT /api/usage/shadow-prices`).

## API

`GET /api/control/missions/:id/stats?period=today|lifetime` (lifetime starts
at the mission's creation):

```json
{
  "mission_id": "…", "period": "lifetime", "since": "…",
  "own": {
    "models": [{"provider": "openai", "model": "gpt-6.1-sol", "requests": 41,
                "input_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0,
                "output_tokens": 0, "cost_usd": 2.95, "shadow_priced": false, "unpriced": false}],
    "vm_usd": 0.62, "total_usd": 4.37
  },
  "subtree_total_usd": 6.12,
  "children": [{"mission_id": "…", "title": "…", "total_usd": 1.44}]
}
```

Child totals include their own subagents.

## Formal model (`lean/Orb`)

- Kernel export `orb_stats_settle_step(acc, cost, seen) -> u64`: adds a
  request's cost once (`seen = 1` for a replayed request id adds nothing),
  saturating. Rust (`crate::orb_spec::stats_settle_step`) settles every
  ledger row through it, keyed by the row id (`proxy:<id>` / `event:<id>`).
- `statBuckets_conserve` (Spec): when every row's key is listed, the bucket
  totals sum to the total. Instances: mission total = Σ served-model buckets
  + VM bucket; subtree total = own + Σ children (keys = mission ids).
- `statsOutbox : IdempotentOutboxSpec`: the kernel step admits a cost iff the
  request id was not settled yet; `statSettle_replay` and `statSettle_fresh`
  show a replay changes no total and fresh distinct rows settle to the plain
  total.
- Corollary 37: fresh adds, replay adds nothing, saturation.

Rust tests check the same conservation on concrete trees
(`mission_and_subtree_totals_are_conserved_and_replays_count_once`).

## Planned (not implemented)

- `budget_reserve`: admission against a per-mission LLM + VM budget, reusing
  the settle step for the running total.
- `chain_pick`: route choice under a remaining budget.

## Clients

Orb desktop: right-click a mission, **Mission settings…**, Stats section:
total (own + subagents), served-model table (requests, input / cache / output
tokens, cost, shadow/unpriced flags), VM cost, subagent totals, Today /
Lifetime toggle, built on the shared stats primitives (`orb/docs/ui/stats.md`:
`StatTile`, `BreakdownTable`).

iOS and Android: gap. Their Mission settings sheet has the Budget section
only; the Stats section follows with the shared stats primitives.
