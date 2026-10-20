# Send fluidity audit

Measured by `tests/send-fluidity.browser.spec.ts` (Chromium, 1100x900, offline
fixtures `smooth-send.html` / `send-experience.html`), sampling every painted
frame with `requestAnimationFrame` (~16 ms), from the user action for 2.5 s.

- **bounce**: reversals in the screen position of an existing transcript
  paragraph (a move > 2 px followed by a move back), i.e. what the eye sees.
- **jump**: growth of the gap below a bottom-pinned transcript in one frame.
- **CLS**: sum of `layout-shift` entries (no recent input).
- **missing / dup**: frames after first display where the message is in
  neither the queue nor the transcript / in both, or twice.
- **error**: any `[role=alert]`, `.error-notice`, `.error` not on screen before.

Before = `origin/master` e3f54e6c. After = this branch.

| # | Path | Visible (ms) before → after | Bounce | Jump px | CLS | Missing | Dup | Error flash |
|---|------|------|------|------|------|------|------|------|
| 1 | Enter, idle mission | 22 → 34 | 0 → 0 (19 px with 10 ms timer sampling) | 0 → 0 | 0 → 0 | 0 | 0 | none |
| 1b | Enter, idle mission after a failed/interrupted turn (`no-red-flash`) | — | — | — | — | 0 | 0 | **"Remote job stopped" then "Mission failed" → none** |
| 2 | Enter while running (queues) | 21 → 17 | 0 → 0 | 34 → 0 | 0 → 0 | 0 | 0 | none |
| 3 | Send now from the queue | 4 → 7 | **1 (38 px down, 19 px back) → 0** | 0 → 0 | 0 → 0 | 0 | 0 | none |
| 4 | Queued message auto-delivered at turn end | 9 → 14 | **1 → 0** | 0 → 0 | 0.0073 → 0.0073 | 0 | 0 | none |
| 5 | Edit a queued message, then send it | 6 → 3 | **1 → 0** | 0 → 0 | 0 → 0 | 0 | 0 | none |
| 6 | First prompt of a new mission | 97 → 105 | 0 → 0 | 0 → 0 | 0.0039 → 0.0039 | 0 | 0 | none |
| 7 | `/goal` | 7 → 6 | 0 → 0 | 0 → 0 | 0 → 0 | 0 | 0 | none |
| 1c | Enter on a remote mission that needs a replacement session (prod c7592dff → 0db534df, `sidebar-replacement`) | — | — | — | — | — | **sidebar rows titled "Verity": 2 → 1** | none |
| 8 | `/btw` side question | 19 → 14 | 0 → 0 | 0 → 0 | 0 → 0 | n/a | n/a | none |

Time-to-visible differences of a few ms are run-to-run noise (one frame).
The remaining CLS on paths 4 and 6 (under 0.01) comes from the Working row
and the launch banner, not from the message.

## Causes fixed

1. **Red flash (1b).** The stream's `mission_status_changed: active` updated only
   the status and kept the previous turn's ended remote job, so
   `MissionFailure` showed "Remote job stopped". The next mission read then
   joined an in-flight shared GET that started before the send and put the
   failed mission back ("Mission failed"). Now a live status drops an ended
   job, reads triggered by a status are fresh, and a read older than the
   latest stream status is discarded.
2. **Queue → transcript bounce (3, 4, 5).** A new `.user` bubble used
   `content-visibility: auto` with a 40 px intrinsic placeholder: its first
   frame was 19 px too tall, then shrank, so the pinned transcript moved up
   and back. On top of that, the leaving queue row collapsed over 150 ms
   after the bubble had landed, a second move. A pending/sending bubble is now
   laid out for real at once, the placeholder matches one line, and the queue
   row leaves in the same frame the bubble lands (the bubble's `user-arrive`
   fade is the only animation).
3. **Conversation listed twice in the sidebar (1c).** A follow-up to a remote
   session that cannot resume makes Orb create a replacement mission; Core
   archives the original as `superseded_by:<new>`. The replacement was added to
   the sidebar at once (`onFork`) while the original stayed until the next
   project list read, and a read already in flight could bring it back. The
   send now announces `orb:mission-archived` for the original in the same
   batch, the sidebar drops it from every project list at once, and list reads
   in this session keep it out unless it is restored.

## Not consolidated

The six queue modules named in the brief (`localMessageQueue`, `sendQueue`,
`queuedEdit`, `deferredMessages`, `RemoteQueue`, `QueuedMessages`) are all
still imported by live paths (local-runner persistence and crash recovery,
Core's remote queue, in-place edits). Removing them is a separate rewrite with
its own risk. This change removes the second transition (`leaving` rows,
`closing` panel, their timers and keyframes) so every path shares one
queue-to-transcript transition.
