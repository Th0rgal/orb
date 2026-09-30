# Scheduled continuations

Core owns wake-up delivery. An idle turn with a pending continuation is not a
completed mission. Orb renders a small ticking clock, preserves the running
spinner and permission/error priority, and disables animation for reduced motion.
The clock opens the pending wake-ups with their reason, local date/time and
Resume now / Cancel actions. Folder badges prefer running work over scheduled work.

## Contract

Mission list and detail responses add optional `continuation: {count, items}`.
Each item has `id`, `state`, `next_at`, `trigger`, `reason` and optional `error`.
States are `scheduled`, `queued`, `waiting_for_client`, `error`; local requests
not yet acknowledged by Core use `pending_sync`. `scheduling` describes the
integration's transport and native support; it is not a probe of the installed CLI.

`POST /api/control/automations/:id/action` accepts `{"action":"resume"}` or
`{"action":"cancel"}` for one-shot wake-ups. A cancel that loses the race to
delivery returns 409. `POST /api/control/missions/:id/continuations/cancel`
revokes future wake-ups and undelivered server outbox entries for that mission.
Stopping a hosted mission or explicitly stopping a local mission invokes this
revocation. Reporting an interrupted local process preserves its wake-ups so
queue advancement and machine transfer can continue safely.
An ordinary follow-up does not cancel the next wake-up.

Requests may include `variables.__wakeup_request_id`. Its mission-scoped UUID is
stable across retries; retrying returns the original automation. A replacement
wall-clock wake-up disables the previous timer and cancels its not-yet-dispatched
execution in the same SQLite transaction. Job-terminal watchers replace only a
watcher for the same job; they remain independent of wall-clock wake-ups.

Due one-shot wake-ups are staged transactionally in `automation_executions`, with
`trigger_source=durable_schedule`, a stable occurrence/message ID and the resolved
prompt. Admission retries reuse that ID; the normal message queue handles replay.
The record remains retryable until acknowledgement, including if completion raced
with acknowledgement. Delivery errors back off to five minutes. This is durable
at-least-once admission with message deduplication, not an exactly-once guarantee
for arbitrary external actions executed by the agent. General recurring
non-wake-up automations keep their existing scheduler behavior.

## Backend integration

| Execution mode | Transport |
|---|---|
| Hosted Claude print mode | Native `ScheduleWakeup` receipt awaited by the adapter; MCP also available |
| Hosted Codex / OpenCode | Common sandboxed MCP with mission-scoped action receipts and idempotency keys |
| Hosted Grok ACP | Common sandboxed MCP injected by the native launcher on session/new and session/load; legacy automation-manager fallback |
| Local Claude / Codex / OpenCode | Per-run orb-wakeups stdio MCP |
| Local Claude print mode | Successful native `ScheduleWakeup` also enters the local outbox |
| Local Grok | Same local transport via a credential-free Python command |

Native cron ownership is deliberately not advertised. Claude CronCreate/Delete/List
are disabled in managed print-mode runs so they cannot introduce an independent
scheduler. Grok native timers and its legacy hosted streaming transport are not
bridged; ACP MCP is the supported hosted path. Live CLI compatibility still needs
a smoke test against the versions deployed on each machine. Python 3 is required
for the local MCP/helper. Existing native timers created outside this integration
are not imported or cancelled.

The common MCP exposes `schedule_wakeup` and `schedule_job_wakeup` to executors.
The target mission comes from the authenticated session, never tool arguments.
Mutations return the standard durable action receipt; inspect `get_action` before
claiming registration succeeded. Job wake-ups enforce the existing job ownership
checks. The legacy automation-manager binary remains compatible.

## Local durability

Requests live in `~/.orb/wakeups/<account digest>/<mission>/`. The account digest
includes Core URL and JWT subject; no credentials are written into request files
or passed to the MCP process. A successful local tool response explicitly says
`pending_sync`. Orb syncs while open; Core alone decides when the wake-up is due.
An absolute UTC due time preserves the original deadline across offline periods.
Delivery back to the originating computer uses the existing durable client inbox
and local message queue. Neither another computer nor the API host executes it.
The computer must reconnect before local execution can start.

Acked and cancelled request files are deduplication tombstones. Do not delete them
while an originating tool request could still be replayed. Stop also saves an
outgoing cancellation offline and removes queued local scheduled messages; an
already-dispatching message is governed by the existing local launch/stop fence.

## Validation

Focused Rust tests cover competing staging, restart recovery, replacement,
completion/acknowledgement races and cancellation of a client outbox entry.
Orb tests cover clock/spinner/attention precedence, the details dialog, folder
precedence and the existing local queue. `orb/tests/wakeup_mcp_test.py` exercises
actual independent helper processes, request deduplication, MCP receipts and
invalid requests. No deployment or live provider invocation is part of these tests.

ACP wire format reference: https://agentclientprotocol.com/protocol/v1/session-setup

Opt-in native checks in `orb/src-tauri/src/live_mcp_tests.rs` use a private
`ORB_MCP_LIVE_CONNECTION_FILE` and dedicated `local-runs` directory. Set
`ORB_MCP_LIVE_WAKEUP=1` for `live_native_mcp_roundtrip` to exercise the real CLI's
wake-up MCP, synchronize its receipt and cancel the timer. The separate
`live_native_wakeup_transport` check reuses that dedicated test mission to verify
the Python helper → native sync → Core → cancellation path without a provider.
Both tests are ignored by default and require an explicitly configured test Core.
