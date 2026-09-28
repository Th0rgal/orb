# Streaming contract

The control plane emits agent activity to dashboard and iOS clients via
SSE (`GET /api/control/stream`), WebSocket (`GET /api/control/ws`), and
a database-backed event log (`GET /api/control/missions/:id/events`).
This document is the canonical contract for what each
backend emits and what each client expects. It exists because two
incidents (the iOS replay-text-delta bug, the duplicated-thoughts freeze)
traced back to drift between live transport and historical replay.

## SSE channel

`GET /api/control/stream?mission=<uuid>`

| Param | Meaning |
| --- | --- |
| `mission` | When present, the server only emits events whose `mission_id` matches. `status` and `stream_lagged` (connection-scoped) always pass. Omit the param to receive every event the authenticated user can see (used by the mission list and the `?debug=perf` overlay). |
Each line is one of:

- `event: status\ndata: <json>\n\n` — connection-scoped run state +
  queue length. The client uses this as a keepalive heartbeat.
- `event: stream_lagged\ndata: {"dropped": N}\n\n` — the broadcast
  cursor fell behind by `N` events. Client refetches via `?since_seq`
  rather than treating this as fatal.
- `event: <type>\ndata: <json>\n\n` — a single `AgentEvent`. See the
  type list below.

## WebSocket channel

`GET /api/control/ws?mission=<uuid>`

The WebSocket stream carries the same JSON `AgentEvent` payloads as SSE,
including the `type` discriminator. The dashboard does not prefer this
channel by default yet: browser-created WebSockets cannot attach the same
Bearer header as SSE, so `dashboard/src/lib/api.ts` only tries WS when
`preferWebSocket` is explicitly set. Normal web and iOS control streams use
SSE until control WS auth is wired through a JWT subprotocol.

Additional WebSocket-only messages:

- Server heartbeat every 15s: `{"seq": N}` where `N` is the latest stored
  event sequence for the filtered mission, or `0` without a mission filter.
- Client resume request: `{"type":"resume","since_seq": N}`. When the
  socket has a `mission=<uuid>` filter, the server fetches stored events
  with `sequence > N`, converts known rows back into `AgentEvent` shape,
  and sends them before continuing live broadcast delivery.

When `mission=<uuid>` is present, WebSocket uses the same per-mission
broadcast channel as SSE. Connection-scoped `status` and FIDO events still
come from the global channel.

### Event types

All events carry `mission_id` (optional for connection-scoped events).
Listed with the backends that emit them.

| Type | Emitted by | Payload sketch | Notes |
| --- | --- | --- | --- |
| `status` | server | `{state, queue_len, mission_id?}` | Connection-scoped; sent on connect + after every state change. |
| `user_message` | server | `{id, mission_id, content, queued}` | Echoes the user message back after persisting. |
| `assistant_message` | server | `{id, mission_id, content, success, cost_cents?, cost_source?, model?, shared_files?}` | One per completed agent turn. **Cumulative content** — the message is the final consolidated text. |
| `text_delta` | grok, codex | `{mission_id, content, event_id?}` | **Cumulative buffer** — the `content` field contains the *entire* text so far, not the new tokens. Clients must consolidate by replacing, not appending. See "Continuation rule". |
| `text_op` | streaming backends | `{mission_id, bubble_id, ops}` | CRDT-style delta stream. `ops` entries are `insert`, `replace`, or `finalize`; clients apply them to a local buffer keyed by `bubble_id`. Control live transports always convert cumulative `text_delta` payloads to this shape for current clients. |
| `thinking` | grok, codex | `{mission_id, content, done, goal_role?, event_id?}` | Cumulative buffer. `done: true` finalises the current thought; subsequent non-prefix payloads start a new thought. |
| `tool_call` | all | `{mission_id, tool_call_id, name, args}` | One per tool invocation. |
| `tool_result` | all | `{mission_id, tool_call_id, name, result}` | Pairs with `tool_call` via `tool_call_id`. |
| `error` | server | `{message, mission_id, resumable}` | Treated as fatal by clients (toast + system error row). |
| `mission_status_changed` | server | `{mission_id, status}` | New status enum from `MissionStatus`. |
| `agent_phase` | server | `{mission_id, phase, detail?, agent?}` | Coarse-grained phase pill ("Working", "Searching"). |
| `agent_tree` | server | `{mission_id, tree}` | Subagent hierarchy; pushed on shape change. |
| `progress` | server | `{mission_id, total_subtasks, completed_subtasks, current_subtask?, depth}` | For subtask progress chips. |
| `session_id_update` | server | `{mission_id, session_id}` | Some backends rotate session ids mid-mission. |
| `mission_activity` | server | `{mission_id, ...}` | Stale-watchdog signal. |
| `mission_title_changed` | server | `{mission_id, title}` | Metadata change pushed live. |
| `mission_metadata_updated` | server | `{mission_id, ...}` | Same shape as the persisted `mission_metadata_updated` event row. |
| `mission_settings_updated` | server | `{mission_id, ...}` | Backend / agent / model override changes. |
| `fido_sign_request` | server | `{...}` | Connection-scoped; not filtered by `mission` query param. |
| `goal_iteration` | server | `{mission_id, iteration, objective}` | Emitted when a `/goal` loop bumps. |
| `goal_status` | server | `{mission_id, status, ...}` | Terminal `/goal` outcome. |

## Continuation rule (the "NoNo newNo new CI…" bug)

Both `text_delta` and `thinking` are **cumulative** — every event
re-sends the entire buffer. Consolidation rule:

```
isContinuation(prev, next) := prev == next
                              || next.startsWith(prev)
                              || prev.startsWith(next)
                              || trimEnd(next).startsWith(trimEnd(prev))
                              || trimEnd(prev).startsWith(trimEnd(next))
                              || shorter == longer up to TAIL_TOLERANCE trailing chars
```

`trimEnd` strips `\s.,!?;:'")]}…—–-`. `TAIL_TOLERANCE` is 6.

Without the tail tolerance, grok / codex sometimes emit the same buffer
twice with one punctuation character of drift, and the strict prefix
check classifies the second copy as a new thought. The chat then
shows duplicated tokens that grow quadratically with stream length.

The dashboard implements this in `dashboard/src/lib/stream-continuation.ts`.
The iOS app mirrors the same rule in `ControlView.isStreamContinuation`.

## Database event log

The persisted event log is a superset of the SSE stream — every
broadcast event lands in the `mission_events` table (with a few
exceptions noted below). Clients reading historical missions consume
the log through the unified cursor endpoint:

- `GET /api/control/missions/:id/events` (P3-#18) is the canonical
  cursor endpoint. Query params:
  - `since_seq=N` — return events strictly after sequence N (forward
    delta). Use this for SSE reconnect — keep the highest sequence
    seen and pass it on resume.
  - `before_seq=N` — page backwards (oldest-first within the page).
    For "load older messages" UI.
  - `types=user_message,assistant_message,…` — filter to an explicit subset.
  - `view=transcript|trace|history|all` — named type presets. `history`
    is the default client view for chat replay.
  - `limit=N` — page size; default 5000.

- `GET /api/control/missions/:id/snapshot` is the first-paint endpoint.
  It returns mission metadata, the latest `history` event tail, event
  counts, max sequence, child missions, and the running state.

The historical reducer (`eventsToItems` in dashboard, and the Swift replay
path in `ControlView`) walks events in `sequence` order and must:

1. Apply the same continuation rule above when consolidating
   `text_delta` and `thinking`.
2. Pair `tool_result` with the most recent `tool_call` sharing the
   same `tool_call_id`.
3. Treat `event_id` as the deduplication key when present (it survives
   reorder); fall back to `event-<id>` otherwise.
4. Promote a finished `thinking` block marked `goal_role: deliverable`
   into a synthetic `assistant_message` only when (a) the mission is
   in goal mode and (b) no existing assistant message already carries
   the same trimmed content.

Events NOT persisted:

- `status`, `stream_lagged`, `fido_sign_request` — connection-scoped.
- `mission_activity` — diagnostic only, intentionally not stored.

For `text_op` streams, in-flight ops persist as `text_op` rows. When a
`finalize` op arrives, the mission store applies the full op log for that
`bubble_id`, deletes those delta rows, and writes one
`assistant_message_canonical` row. Future `/events` fetches return the
canonical row rather than the op log.

## Client expectations

### Dashboard (`dashboard/src/app/control/control-client.tsx`)

- Uses `/snapshot` for first paint and `/events` for pagination/resume.
- Connects with `?mission=<id>` when viewing a specific mission.
- Prefers SSE for control streaming; WS is opt-in only until browser auth is
  correct.
- Reconnects whenever the viewing mission changes.
- Coalesces `text_delta` and `thinking` re-renders via
  `requestAnimationFrame` — at most one React commit per frame.
- Caps markdown rendering for messages >50 KB (`<pre>` + opt-in button).
- Lazy-mounts the markdown pipeline for off-screen bubbles via
  `IntersectionObserver`.
- Skips the 15s `/events` refetch poll while SSE is fresh (<30s since
  last event).

### iOS (`ios_dashboard/SandboxedDashboard/Views/Control/ControlView.swift`)

- Uses `/snapshot` for first paint and `/events` for pagination/resume.
- Live SSE connects with `?mission=<id>` for the viewed mission.
- Historical replay is gated on `mission.goalMode` for goal-role inference.
- Preserves `goalRole` through finalize-thinking transitions.

## Per-backend notes

- **Grok Build**: emits `thinking` deltas one token at a time. Each
  delta carries the *cumulative* content. Final thought ends with
  `done: true`.
- **Codex**: same shape; bursts can be sub-10ms tight. The rAF
  coalescing on the dashboard depends on this — without it every
  delta would be a React commit.
- **Claude Code**: emits `assistant_message` only (no inline text
  deltas via SSE). Tool calls flow normally.
- **Gemini, OpenCode**: tool calls + assistant messages; no streaming
  text deltas in the current build.

## Adding a new backend

1. Pick a `backend_id` and emit `AgentEvent::*` via the shared
   `events_tx` channel.
2. Always populate `mission_id` (the `?mission=<uuid>` filter drops
   events without it).
3. For streaming text, send cumulative buffers in `text_delta`; the control
   transport converts them to `text_op` for clients.
4. Update this file with the per-backend notes.

## Where this document is enforced

- `dashboard/src/lib/stream-continuation.ts` (+ unit tests) is the
  reference implementation of the continuation rule.
- `src/api/control_metrics.rs` records p50/p99 SSE chunk sizes so we
  can spot regressions in the streaming contract.
- `src/api/control/mod.rs::stream()` is the server-side mission filter.
