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

## Account binding (2026-10-29)

Core owns account priority and pre-stream failover. A Codex OAuth attempt sent
through CLIProxyAPI must use a dedicated, uniquely registered account/model
route, at every speed and for both Responses and Chat Completions. A missing,
disabled, ambiguous or unregistered binding fails closed before inference;
it must never fall back to the bare model or the proxy's independent pool.
Other accounts, including credentials not registered with Core, cannot share
the dedicated route. Prefix provisioning must preserve existing bare routes
so active missions are not interrupted. OAuth refresh still belongs to the proxy.

`account_id` in the stored legacy ledger is the *selected* account, not proof
of upstream identity. New `account_bound` receipts distinguish requests with an
account-bound dispatch from historical/unbound requests. Summary `by_account`
contains only bound identities (unbound requests use the unknown bucket);
`by_selected_account` retains the original selections for diagnosis. This is
routing evidence, not an OpenAI billing receipt. No historical row is upgraded
merely because the routing implementation has been fixed.

Required regressions: selecting the second UUID still targets that account;
ordinary and accelerated requests use the same binding implementation; missing
or duplicate routes cannot send inference; disconnected accounts are rejected;
legacy and bound ledger rows conserve tokens but never share a verified account
bucket. Quota failures must retain the selected account and model scope; a
fresh weekly gauge is not evidence that a per-model/capacity rejection may be
ignored. No quota reset or service restart is allowed merely to clear a warning.

Local Codex (including accelerated tiers) uses a revocable model/tier/mission
capability that forwards to this same Core route. It cannot select an API-key
account, forge another mission, or keep working after turn revocation. The
previous separate rotation transport is removed. Native Responses failures
now write attempt receipts and fallback events; completed streams settle their
outcome only when the stream ends.
