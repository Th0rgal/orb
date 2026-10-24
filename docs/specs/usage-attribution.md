# Usage attribution

Goal: every LLM token Core sees is attributed to exactly one caller, reliably.

## Problem (prod, 2026-10-24)

- Missions routed through the builtin proxy (internal secret + `x-sandboxed-mission-id`)
  logged `mission_id` but an empty `caller` (Snark.fast, 210M tokens).
- Core's own calls (mission titles, Ask, side questions, inbox digests) logged neither
  (291 non-stream, 2-message, `max_tokens 2048` requests).
- Harnesses that bypass the proxy (native `agy`, Claude Code / Codex with their own login)
  showed 0 tokens in proxy logs, and a proxied mission was counted twice in the summary
  (router row + harness event).

## Record

One usage record per request:

| Field | Notes |
| --- | --- |
| `api_key_id`, `api_key_name` | proxy key, `null` for the internal secret |
| `caller_kind` | closed enum: `mission`, `subagent`, `hermes`, `orb_ui`, `core`, `script`, `unknown` |
| `purpose` | `core` only: `mission_title`, `inbox_summary`, `ask`, `btw`, or `unspecified` |
| `mission_id`, `root_mission_id` | when known; root = top of the `parent_mission_id` chain |
| `route` | `proxy` (`proxy_usage` rows) or `harness_direct` (harness usage from `mission_events`) |
| provider, model | |
| tokens | input (uncached), cache read, cache write, output, reasoning (part of output) |
| cost | list-price estimate; unpriced models are flagged, never shown as $0 |

## Derivation rule

The caller is derived server-side from the authenticated credential (the principal),
never from headers:

| Credential | Principal |
| --- | --- |
| internal proxy secret | `core` |
| `remote-launch:<mission>` key | `mission` (`subagent` if that mission has a parent) |
| `Hermes Assistant …` key | `hermes` |
| any other proxy key | `script` |
| none | `unknown` |

Headers are hints (`x-sandboxed-mission-id`, `x-sandboxed-caller: core:<purpose>` or a
kind). A hint is accepted only inside the principal's scope:

- `core` may name any mission (it launched it) or `core:<purpose>`;
- a mission key may name its own mission or a descendant (a subagent);
- `hermes` / `orb_ui` / `script` may only restate their own kind.

A rejected hint is ignored and the principal's own kind is kept, so `caller_kind` is never
empty, and is `unknown` only when no credential binding exists. User-created keys may not
use the reserved `remote-launch:` / `Hermes Assistant` prefixes.

Core-internal calls must name a typed purpose (`CorePurpose`; `AskClient::new` requires
one). Remote launches of proxy-using harnesses already mint a per-mission
`remote-launch:<mission>` key; remote `agy`/Grok bypass the proxy and are `harness_direct`.

## Dedupe

The proxy is authoritative. Harness-reported usage is counted (`harness_direct`) only for
missions with no `proxy_usage` row; a mission with proxied traffic is billed from the proxy
ledger only. The same request is therefore never counted twice. Known limit: a mission that
switches from a proxied harness to a native one mid-life keeps only its proxied usage.

## Formal spec (`lean/Orb`)

One export, `orb_attribution_step(principalKind, claimedKind, sameMission, isDescendant)`
→ `bits 0..7 = kind`, `bit 8 = accepted`. No new Layer I meta-spec: the properties are
instances of existing ones.

- `attributionMetaGate : MetaGateSpec` — accepted ⇔ the claim is in scope (sound,
  complete, witnesses), stated against a separate Prop `AttributionClaim.InScope`.
- `attributionScopedAuthority : ScopedAuthority` — an accepted hint never escapes the
  credential's scope.
- `attributionTotal : ProjectionStability` ("total attribution") — the kind is in `0..6`
  and is `unknown` iff the principal is.
- Corollary 36 — forged hints keep the principal (script→mission, foreign subagent,
  unbound→core).

Ledger conservation (proxy vs harness) is a SQL rule, not a scalar gate, so it is
covered by the Rust test `proxied_missions_are_not_double_counted_from_harness_events`.

## Surfaces

- `proxy_timing` log: `caller` (key name or `internal`), `caller_kind`, `purpose`.
- `GET /api/ai/usage/summary`: `by_caller_kind`, `by_purpose`, `by_route`,
  `by_root_mission`, plus per-bucket `by_caller_kind` in `by_day` / `by_hour`, and a
  `caller_kind` filter, alongside the existing key / mission / model breakdowns.
- Orb desktop Settings → Usage: group by caller, root mission or Core purpose, filter by
  caller, and an Hour / Day toggle. iOS and Android have no usage view yet (gap).
