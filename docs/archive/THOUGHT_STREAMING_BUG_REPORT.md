# Thought Streaming Bug Report

Investigation date: 2026-05-27

Dashboard tested: `http://localhost:3001/control`, connected to
`https://agent-backend.thomas.md`.

## Evidence Collected

- Codex mission: `86f05a7d-044f-428b-bf68-650298e6fb18`
  - Prompt asked for visible thinking without file changes.
  - Persisted events included many live `text_delta` frames, then one
    `thinking` event with `done: true`, then a failed assistant message.
  - The `thinking` content was not the same stream as the `text_delta`
    content. It looked like a synthetic/fallback extraction from answer text.
- Codex mission: `cb246dfd-bbbd-4137-8360-11afb5cf4ea3`
  - Prompt required read-only tool inspection.
  - Persisted events included real `tool_call`/`tool_result` activity and
    multiple `thinking(done=true)` events.
  - Several `thinking` rows were progress narration rather than model
    reasoning, and one sentence appeared first as `text_delta` and later as
    `thinking`, showing cross-channel echo inside one turn.
- Grok Build mission: `0cee35db-90c0-48b0-be8d-abc43a462229`
  - Prompt asked for thinking plus a short answer.
  - After more than a minute, persisted history contained only
    `mission_status_changed` and `user_message`; it later completed with
    `text_delta` and `assistant_message`, but no persisted `thinking`.
  - The UI showed a `Thinking 1` / draft panel during the run because the
    side panel includes live `stream` rows created from `text_delta` events.
- Claude Code mission: `3f9c8b01-5d39-4bd7-84ab-122bbcee3b4e`
  - Prompt asked for normal thinking/tool process if needed.
  - Persisted events included only `text_delta` and `assistant_message`, no
    `thinking`, despite the UI showing a `Thinking 1` draft panel for the
    same `stream`-row reason.
  - Server logs again showed the same `text_delta` events delivered to both
    global and per-mission SSE streams.
- Server journal for the Codex mission showed each `text_delta` delivered to
  both a global SSE connection and a per-mission SSE connection:
  - `/api/control/stream?`
  - `/api/control/stream?mission=86f05a7d-044f-428b-bf68-650298e6fb18`

## Confirmed Bugs / Risks

### 1. Synthetic thinking can be emitted from normal answer text

Path: `src/api/mission_runner.rs`

Codex mission `86f05a7d-044f-428b-bf68-650298e6fb18` persisted a final
`thinking(done=true)` event after regular answer `text_delta` events. The
content was a refusal-style answer, not raw streamed reasoning.

Cause: fallback extraction paths promote answer-like text into a `Thinking`
event when no real SSE thinking was seen. Relevant patterns:

- `extract_thought_line(...)` fallback in turn finalization.
- `extract_reasoning(...)` over stored message parts when SSE thinking was not
  emitted.

Impact: the Thinking panel can show duplicated or near-duplicated answer text,
making it look like thought streaming duplicated sentences even when the model
only produced an answer.

### 2. Progress text can be emitted as both `text_delta` and `thinking`

Path: Codex mission runner / Codex event conversion

Codex mission `cb246dfd-bbbd-4137-8360-11afb5cf4ea3` shows the same ordinary
progress sentence crossing channels:

- seq 4 `text_delta`: "The mission context is empty, so I'm widening..."
- seq 26 `thinking(done=true)`: "The mission context is empty, so I'm
  widening..."

It also persisted several thought rows like "I'll inspect the workspace..." and
"The first broad search didn't hit...", which are status/progress narration, not
distinct reasoning streams.

Cause: the backend has multiple routes that can classify model/status text as
`Thinking`: explicit `ExecutionEvent::Thinking`, final `extract_thought_line`
fallbacks, and provider part parsing. When a provider emits user-visible
progress in one channel and the bridge later treats the same content as
thinking, the dashboard receives two authoritative-looking copies.

Impact: even without a frontend append bug, the event store itself can contain
duplicated sentence content across `text_delta` and `thinking`. The Thinking
panel then appears to duplicate sentences that also appeared in the chat stream.

### 3. The dashboard can have both global and mission-scoped SSE streams alive

Path: `dashboard/src/lib/api.ts`, `dashboard/src/app/control/control-client.tsx`

The server journal showed identical Codex `text_delta` events fanned out to a
global stream and a per-mission stream. The same pattern was seen again for
Claude and the later Codex tool mission. The client has filtering and connection
generation guards, but this is a high-risk shape: if a stale global connection
survives a mission switch or reconnect, the same content-bearing event can be
handled twice.

Cause: the control page uses a reconnecting stream effect and mission-switch
reconnect logic. The code intentionally supports both global and per-mission
streams, and relies on teardown/generation checks plus mission ID filtering to
avoid double application.

Impact: duplicated live rows or duplicated sentence fragments can occur if the
old global reader is not aborted before the mission-scoped reader starts, or if
an event lacks `mission_id` and bypasses the client-side drop guard.

### 4. Persisted-history replay has a known duplicate-row failure mode

Path: `dashboard/src/app/control/control-client.tsx`

The code already documents this bug in `reloadMissionHistory`: persisted
`thinking` and `text_delta` events materialize as `event-<id>` rows, while live
SSE rows use synthetic IDs such as `text_delta_latest` and `thinking-*`.

Cause: delta history polling appends by ID, but live streaming rows have
different IDs from persisted events for the same content.

Impact: if the full-reload fallback is missed, history catch-up can append a
second copy of an in-flight thought or stream row. The current mitigation is to
force a full reload when delta events touch streaming types while a live
streaming row exists.

### 5. Delta-vs-snapshot detection still has heuristic fallback paths

Paths:

- `src/opencode/mod.rs`
- `src/api/mission_runner.rs`
- `dashboard/src/lib/stream-continuation.ts`

The current Codex app-server translator has explicit `DeltaSemantics` for
known methods (`item/agentMessage/delta`, `item/reasoning/textDelta`, and
`item/reasoning/summaryTextDelta`), which is the right direction. But several
fallback paths still merge by prefix/overlap:

- `src/opencode/mod.rs` `fold_stream_delta(...)`
- Codex/Gemini unknown-item `merge_stream_fragment(...)`
- Dashboard `mergeStreamFragment(...)` for live `text_delta`/`thinking`
  consolidation

Cause: with repeated content, suffix-prefix overlap can choose the wrong
boundary if a provider emits cumulative snapshots after incremental chunks, or
emits a shorter echo that is not a strict prefix of the local buffer. This is
less likely for known Codex app-server methods now, but still applies to
OpenCode SSE, unknown-item Codex/Gemini events, and frontend replay/merge.

Impact: visible text can become patterns like `NoNo newNo new CI...` or repeated
sentences. Existing tests cover some cumulative cases, but not enough repeated
phrase and provider-shape fixtures.

### 6. The "Thinking" panel also renders answer drafts from `text_delta`

Paths:

- `dashboard/src/app/control/control-client.tsx`

Grok mission `0cee35db-90c0-48b0-be8d-abc43a462229` stayed active with no
persisted events beyond the user message for more than a minute, then completed
with `text_delta` and `assistant_message` only. Claude mission
`3f9c8b01-5d39-4bd7-84ab-122bbcee3b4e` also completed with only `text_delta`
and `assistant_message`.

Cause: `deriveItemViews(...)` adds both `thinking` and `stream` items to
`thinkingItems`; `text_delta` events create/update a `kind: "stream"` item with
ID `text_delta_latest`; the right-side panel is still opened and counted by the
top-level "Thinking" button. Inside the panel, stream rows are labeled
`Draft`/`Streaming`, but the outer affordance reads "Thinking".

Impact: users can reasonably report "buggy thoughts" when they are actually
looking at live assistant draft text. If that draft text later appears as the
final assistant message, it can feel like a thought duplicate even though no
`thinking` event was persisted.

## Areas Still To Verify

- Claude Code extended-thinking with actual `thinking_delta` blocks. The fresh
  Claude run did not persist any `thinking`, so the block-index buffering path
  still needs a targeted reproduction.
- Raw provider event frames. The current evidence uses persisted mission events
  and server journal stream logs. Capturing raw Codex/Grok/Claude JSONL/SSE
  payloads would prove whether any remaining duplicated sentences originate
  upstream. The observed duplicates above are already explainable from
  backend/dashboard events.
- Whether the global and mission-scoped SSE streams are both handled by the same
  browser tab at the same time. Logs prove multiple global and per-mission
  streams were connected; the frontend generation guard should suppress stale
  events, but this needs an instrumented browser-side trace.

## Recommended Fix Direction

1. Do not emit `Thinking` from answer/progress text unless the source is explicitly a
   reasoning/thinking provider field. If fallback extraction remains, tag it in
   metadata and keep it out of the live Thinking panel by default.
2. Add stream IDs/item IDs to `AgentEvent::Thinking` all the way into persisted
   events and the dashboard row IDs. That removes the need to infer continuity
   from text content.
3. Make stream payload semantics explicit: `delta` for append-only fragments,
   `snapshot` for cumulative buffers. Avoid guessing from prefixes where the
   backend already knows the provider shape.
4. Ensure only one content-bearing SSE reader can be active in a control tab.
   Add dev logging for connection generation, abort completion, and dropped
   stale events.
5. Add fixtures for repeated text (`alpha beta gamma alpha beta gamma`), mixed
   delta/snapshot sequences, multiple Codex reasoning `item_id`s, and persisted
   replay over live synthetic rows.
