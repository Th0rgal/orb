# Usage telemetry

Opt-in usage telemetry tells the owner which Orb pages and features they use,
how they approve things, and what their turns cost, so Orb can be simplified.
It is **off by default** and goes only to the owner's own namespace on the
telemetry hub (`Th0rgal/telemetry-hub`, `https://telemetry.thomas.md`), never
to `community`. The hub rejects `orb.*` events in `community` as well.

## Flow

```
desktop / iOS / Android ──POST /api/usage-telemetry/events──▶ Core ──POST /v2/ns/<ns>/ingest──▶ hub
                                     Core (control events) ──┘
```

- Clients ask `GET /api/usage-telemetry` and queue nothing unless `active`.
  They batch (50 events or 30 s, and when the app is hidden), keep events on
  a failed flush (500 max) and retry on the next one.
- Core (`src/api/usage_telemetry.rs`) drops everything while off, reduces each
  event to its allowlisted fields, and sends batches of 200 with the owner's
  `tl_live_` token. A 5xx, 408, 429 or network error keeps the batch and backs
  off (30 s doubling to 10 min); any other 4xx drops it. Turning telemetry
  off discards the queue.
- The token is stored AES-256-GCM encrypted in `settings.json` (the same
  `env_crypto` key as Bitwarden), is never returned by the API and never logged.

## Settings

Settings → Account → Usage telemetry, or `PUT /api/usage-telemetry/config`:

| field | meaning |
| --- | --- |
| `enabled` | send `orb.*` events (default `false`) |
| `prompts_enabled` | also send prompt text (separate opt-in, default `false`) |
| `namespace` | the owner's hub namespace; `community` is refused |
| `hub_url` | default `https://telemetry.thomas.md` |
| `token` | write-only `tl_live_` token; `""` clears it |

## Events

The schemas, fields and enums are in
[`shared/orb-spec/fixtures/usage-telemetry.json`](../shared/orb-spec/fixtures/usage-telemetry.json).
Core embeds that file as its allowlist, and desktop, iOS and Android test their
builders against it. Every event has `schema`, `event_id`, `ts`, `client`.
String values must be identifiers (`ident_pattern`), so free text cannot ride
along.

| schema | sent by | fields |
| --- | --- | --- |
| `orb.approval.v1` | clients | `kind` (tool, command_class, grant, payment), `decision`, `method` (face_id, touch_id, passcode, desktop_click), `wait_ms` |
| `orb.page.v1` | clients | `screen`, `surface` (screen, sheet, pane), `dwell_ms`, `entry_point`; Core adds `quick_close` (dwell under 2 s) |
| `orb.action.v1` | clients | `action` (sidebar_move, btw, fork, queue, file_viewer_open, inbox_*, message_edit, message_resend), `count`, `surface` |
| `orb.turn.v1` | Core | `model`, `harness`, tokens, `cost_cents`, `latency_ms`, `interrupted`, `resent` |
| `orb.prompt.v1` | Core, prompts opt-in | `prompt_digest`, `chars`; the scrubbed text goes in `blobs` under the digest |

Approvals never include the payload, command or secret. Pages use page ids,
never mission ids or titles (`m:<uuid>` becomes `mission`). Prompts pass
through `scrub_secrets` (API keys, `tl_live_`/GitHub/AWS/Slack/Google tokens,
bearer tokens, JWTs, `*_KEY=`/`password:` values, URL credentials, private
keys) before they leave Core; the cases are in the fixture's `scrub` list.

## Reading the data

```bash
curl -H "Authorization: Bearer $TOKEN" "https://telemetry.thomas.md/v2/ns/<ns>/events?stream=orb&limit=500"
curl -H "Authorization: Bearer $TOKEN" "https://telemetry.thomas.md/v2/ns/<ns>/export?stream=orb" > orb.ndjson
```
