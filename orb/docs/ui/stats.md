# Stats primitives

Small, calm, data-dense building blocks for numbers in Orb: Settings >
Models & Routing > Reliability uses them first, and the per-mission Stats
section (spend by served model, tokens, VM cost, subagents) must use the
same ones. Code: `orb/src/components/stats/` (import from
`./components/stats`, which also loads `stats.css`).

## Design language

- **Tone** has three values, shared with the quota meters (PR #1286):
  `neutral` (healthy, < 80% used), `warning` (80–99% used, or *expected
  waiting* such as a quota cooldown or a 429 rate limit), `danger`
  (exhausted, down, failing). Colors are the `--warning` / `--danger` tokens;
  never use `--red` for a quota wait.
- **Categorical colors** come from `stats.css` (`--viz-ok`, `--viz-limited`,
  `--viz-client`, `--viz-server`, `--viz-timeout`), in that fixed order. The
  order was validated with the dataviz CVD checker in both themes (adjacent
  CVD dE >= 8.3, normal-vision dE >= 15.6, >= 3:1 on `--bg`). Do not re-sort
  or cycle them. For a new categorical meaning (e.g. spend per model), add
  `data-k` slots to `stats.css` and re-run the validator; past five series,
  fold into "Other".
- Text always wears text tokens (`--fg*`); color marks carry identity, and
  every colored mark has a text equivalent (tooltip, aria-label, legend or pill
  text). Status is never color alone.
- Loading state is a skeleton the size of the final content: pass
  `value={undefined}` / `rows={undefined}`. Keep the previous data on screen
  while refetching (no blanking on window switch).
- Works at 390 px: tiles go 2×2, table columns marked `hideNarrow` drop,
  `narrowWidth` tracks apply, and `StatusPill` shows its `short` label.

## Primitives

| Component | Use |
| --- | --- |
| `StatTile { label, value?, title?, series?, seriesMin?, tone? }` | KPI with an optional 24-point sparkline over the window. Wrap tiles in `<div class="st-tiles">` (4 columns, 2 on phones). |
| `Sparkline { values, min?, title? }` | One-series trend line; `null` is a gap. Decorative next to its number. |
| `OutcomeBar { segments: {key,label,value}[], label?, format? }` | Horizontal stacked bar of a total split into categories. Segment color = `data-k` key. Show one `Legend` below the table. |
| `Legend { items: {key,label}[] }` | One-line legend for `OutcomeBar` keys. |
| `RangeBar { low, high, max, mark?, tone?, title? }` | p50–p95 band on a shared `0..max` scale so rows compare. |
| `StatusPill { tone, label, short?, title? }` | State with a dot: Healthy / Degraded / Down / "Quota cooldown until 14:30". |
| `BreakdownTable<T> { label, columns, rows?, rowKey, detail?, collapse?, collapsedLabel?, skeletonRows?, empty? }` | Ranked rows (sort before passing). `collapse` folds rows behind "N healthy · show"; `detail` makes rows expandable (click / Enter). Columns: `{ header, width, cell, align?, hideNarrow?, narrowWidth? }`. |

## Example: mission spend by served model

```tsx
import { BreakdownTable, OutcomeBar, StatTile, type Column } from "./components/stats";

<div class="st-tiles">
  <StatTile label="Spend" value={formatCost(total)} series={hourly.map(b => b.cost_cents)} seriesMin={0} />
  <StatTile label="Tokens" value={formatTokens(tokens)} series={hourly.map(b => b.tokens)} seriesMin={0} />
  <StatTile label="VM cost" value={vm} />
  <StatTile label="Subagents" value={String(subagents)} />
</div>
<BreakdownTable label="Spend by model" rows={models()} rowKey={m => m.model} columns={[
  { header: "Model", width: "minmax(0, 1fr)", cell: m => m.model },
  { header: "Tokens", width: "96px", cell: m => <OutcomeBar label={m.model} segments={[
      { key: "input", label: "Input", value: m.input_tokens },
      { key: "output", label: "Output", value: m.output_tokens }]} /> },
  { header: "Cost", width: "64px", align: "end", cell: m => formatCost(m) },
] satisfies Column<ModelRow>[]} />
```

## Reliability classification

`orb/src/reliability.ts` (tests: `orb/tests/reliability.test.ts`):

- Outcomes: `client_error:429` → rate limit / quota; other 4xx → client;
  5xx → server; timeout, stalled, empty-before-first-chunk → timeout.
- Status: an active account cooldown from Core (`cooldown.state`,
  `cooldown.until`) with 429s → `Quota cooldown until HH:MM` (warning).
  Out-of-credit / auth cooldown → danger. Hard failures (non-429) >= 50% with
  no success → Down; >= 10% (or auth/credit/stall flags) → Degraded; slow
  first token → Slow (warning); >= 10% 429s without cooldown → Rate limited
  (warning).
- Ranking: impact = hard failures + 0.25 × 429s, then attempts.
- Rows sharing provider·model show their account label.

Core (`GET /api/ai/proxy/health`) supplies per group `account_label`,
`cooldown`, `recent_errors` (5 newest), and `series` (24 buckets of
requests/ok/ttft/retried/fell_back) with `bucket_secs`.

## Validation

`pnpm exec vitest run tests/reliability.test.ts tests/usage.test.tsx` and
`pnpm exec playwright test tests/reliability-viz.browser.spec.ts`
(gallery: `tests/reliability-viz.html`; `ORB_SCREENSHOT_DIR` saves light/dark
× 1100/390 px screenshots).

Mobile: iOS and Android have no reliability view yet. When added, reuse the
same outcome keys, thresholds, tones and palette.
