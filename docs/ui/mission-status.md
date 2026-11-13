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

## Mobile gap

Desktop derivation and `live_children_count` consumption are not yet mirrored by
iOS/Android. Port the same precedence and replay fixtures, rather than inventing
platform-specific completion rules.
