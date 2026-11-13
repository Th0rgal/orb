# Mission status truth

`orb/src/missionStatus.ts` owns mission activity, effective status and presentation.
Sidebar glyphs, accessibility labels and the transcript header consume that owner;
components must not decide that a turn-end receipt means the mission is done.

## Facts and precedence

- A local run or current remote job executing/queued is running/queued. A bounded
  send-now handoff bridges the stop/start gap, never an old successful job.
- A failed job or failed Core status remains failed and visible, not successful.
- `live_children_count > 0` means background work is running, including children
  omitted from the sidebar page. It does not mean the parent's harness is running;
  do not show a parent's startup/progress timer for a child.
- A nonempty continuation summary (including count-only responses), or
  `terminal_reason = awaiting_wakeup` (top-level or execution receipt), means
  waiting for wake-up. Show the scheduled time when `next_at` is available.
  Overdue time is not proof of cancellation: only authoritative removal clears it.
- With no pending work, `awaiting_user` waits on the user; `completed`/`succeeded`
  is done. A turn ending is not sufficient proof of mission completion while
  children or a wake-up remain.
- A finished remote job may override a stale running status, but may not erase
  the mission's pending work. Unknown status is quiet, never green success.

Explicit permission/question requests remain actionable. Wake-up delivery errors
remain attention states. Status derivation does not mutate the Core status, queue,
or stop-button semantics. The glyph occupies the same space for all states and
uses existing light/dark tokens and keyboard-accessible wake-up controls.

## Required replay

Reproduce ldgr: running parent → arm wake-up → parent turn completes while a
child is live → child ends → awaiting_user/awaiting_wakeup arrives → refreshed
completed snapshot still has the continuation → continuation explicitly removed.
Neither the sidebar nor header may show done before the final removal. Repeat
with the job-end event arriving before the mission status event and with only
terminal_reason available. A plain awaiting_user mission without pending work
must not be shown as running. Tests cover the pure owner and rendered glyph;
header tests consume the same derivation.

## Terminal snapshot reconciliation

A mission read (`GET /api/control/missions/:id`, a list row) is a full snapshot.
On desktop, `orb/src/missionSnapshot.ts` (consumed by `mergeIncomingMission` in
`orb/src/mission/MissionView.tsx`) owns snapshot admission and follow-up
reconciliation:

- Fence by `run_generation`, then `state_revision`, then `updated_at`. When
  either side omits `run_generation` (for example a mission list row, which
  carries `state_revision` and `updated_at` without `run_generation`), ordering
  falls through to `state_revision`, then `updated_at`. A snapshot from an older
  run generation, or with a lower state revision in the same (or unrecorded)
  generation, is discarded even when its `updated_at` is equal or newer. A late
  terminal snapshot never ends a newer turn.
- Core emits `status`, `terminal_reason`, `run_generation`, `state_revision`,
  and `updated_at` on mission snapshots (and omits `remote_job`, `queue_wait`,
  `execution`, and `recovery`). An admitted snapshot clears any stale execution
  fields the client still holds (`withOwnedExecution`), so a terminal snapshot
  clears the `"Starting …"` working row and any launch/status banner. The
  network-health Reconnecting chip (`orb/src/networkHealth.ts`) reflects client
  link and poll health rather than mission snapshots, so a mission snapshot
  cannot decide it.
- A follow-up that Core has not acknowledged when an admitted ended snapshot
  (`completed`, `succeeded`, `failed`, `not_feasible`, `error`, `errored`,
  `timed_out`, `cancelled`, `interrupted` — never `READY_STATUSES` such as
  `awaiting_user`, where the turn ended and Core hands over the next queued row)
  newer than the send arrives is shown as **Not sent** with Retry, unless its id
  is still listed in `GET /api/control/queue` or its content was delivered after
  it was posted. A row Core still lists in the queue is real and is never marked
  `not_sent` or `discard`; on an ended mission, listed queue rows are labeled
  as not delivered (`Not delivered`) and Send uses delete-then-send (sending
  only after `DELETE /api/control/queue/:id` returns `200` or `404` with
  `"message not in queue"`).

Required replay (`shared/orb-spec/fixtures/mission-terminal-reconcile.json`):
the 734c3bb7 order from Core-emitted fields (`status`, `terminal_reason`,
`run_generation`, `state_revision`, `updated_at`: running turn, Core restart,
completion from another session, and a stale replay), list-row vs detail-snapshot
ordering when `run_generation` is absent on the list row, a Core restart that
replays an older generation, and a delayed terminal snapshot after a newer turn
started.

## Mobile gap

Desktop derivation and `live_children_count` consumption are not yet mirrored by
iOS/Android. Port the same precedence and replay fixtures, rather than inventing
platform-specific completion rules.
