# Side question (`/btw`) client state & reconciliation

Defines the client state ownership, persistence, and server-reconciliation
invariants for Orb side agents (`POST /api/control/missions/:id/btw/agent`).
Complements [`docs/ORB_BTW.md`](../ORB_BTW.md).

## Background

During mission `0c532a32-2fb5-4fd6-ba6b-b9820d12c097`, the user submitted a
long-running `/btw` side question (`634505a6-4371-4fa1-91c2-7bbcc62bdb6f`),
switched missions, and reopened `0c532a32`. Although `634505a6` remained healthy
and `active` on Core, the side panel rendered:

```text
Couldn’t complete side question
Side question interrupted. Retry to request a complete answer.
```

Four interacting client flaws produced and pinned that false error:

1. **Legacy SSE mount assumption (`SideQuestionPanel.tsx`)**: While a side
   question was running (`busy() === true`), the panel persisted
   `pending: { question, answer, error: "" }` in IndexedDB. On remount, if
   `btwSession(parent)` in `localStorage` was missing or stale (`active: false`),
   `SideQuestionPanel` assumed the legacy HTTP POST stream (`askSide`) had been
   aborted by unmount, immediately fabricated
   `"Side question interrupted. Retry to request a complete answer."`, and wrote
   that fabricated error back to IndexedDB.
2. **Sequential uncached fork-chain waterfall (`btwAgent.ts`)**: `0c532a32`
   continued two earlier harness-transfer forks (`97399f01`, `52bbf658`) with 11
   `/btw` threads totaling 2,590 events. `reconcileBtwServerHistory` paged every
   historical `/btw` mission sequentially from oldest to newest (`for (const m of sorted)`)
   with zero caching and re-triggered every 15 s (`setInterval`), causing
   65–145 s waterfalls that repeatedly invalidated earlier reads (`mine !== generation`)
   before reaching the newest active mission (`634505a6`).
3. **Single-poll transient failure in `watchBtw` (`btwAgent.ts`)**: A single
   30 s `RequestTimeoutError` or transient network blip during `watchBtw`'s 5 s
   status/events poll rejected `watchBtw` immediately, dropping `busy` to `false`
   and surfacing a fatal error banner while the remote side agent kept running.
4. **Refusing `Retry` on an already-running question (`btwAgent.ts`)**: Clicking
   `Retry` on a stale error banner while Core's side mission was still `active`
   for that exact question threw `'The side agent is still running. Stop it before sending another question.'`
   instead of reattaching `watchBtw`.

## 1. Single authority for accepted side turns (P0)

Once Core accepts a `/btw` turn (`POST /api/control/missions/:id/btw/agent` or
`POST /api/control/message`), Core owns execution of the side turn:

- Closing the side panel, switching missions, or reloading Orb aborts only the
  view's `AbortController` (`signal`), **never** the Core run (`launchSignal` /
  `stopBtw`).
- A persisted `saved.pending` entry with `error === ""` and `!notSent` means the
  turn was in flight when the view last wrote state — **not** that the turn
  failed.
- When `reconcileBtwServerHistory` is available (`/btw/agent` runtime), mounting
  with `saved.pending` and `!saved.pending.error`:
  1. Attaches `watchBtw` immediately when `btwSession(parent)?.active` is true
     (or awaits `btwLaunchPending(parent)`).
  2. Otherwise keeps the turn in reconcilable working state (`busy = true`,
     `runStatus = "Reconnecting…"`, `error = ""`) until the initial Core
     reconciliation settles:
     - **Active on Core (`reconciled.activeSession`)**: attaches `watchBtw` to
       `reconciled.activeSession` (clearing any stale `error` or `notSent` flag,
       even if an earlier build had persisted `"Side question interrupted..."`).
     - **Answered on Core (`reconciled.history` contains `pendingQ`)**: clears
       the pending turn and renders Core's recorded answer.
     - **Neither active nor answered on Core**: transitions `busy` to `false`
       and surfaces `'Side question interrupted. Retry to request a complete answer.'`
       so genuinely interrupted turns (e.g. an aborted pre-acceptance stream or
       a vanished run) remain recoverable via `Retry`.

## 2. Fast, cached, non-livelocking server reconciliation (P0)

`reconcileBtwServerHistory(parent, localHistory)` reconciles `/btw` turns across
`btwThreadChain(parent)` under three performance and liveness guarantees:

1. **Terminal thread memoization**: Completed/terminal `/btw` missions
   (`!ACTIVE.includes(m.status)`) cache their parsed turns in memory keyed by
   `(connectionVersion, mission.id)` and stamped with
   `${activity(m)}\u0000${m.status}` (matching iOS `OrbBtwStore.eventCache`).
   Subsequent 15 s polls and mission switches skip `getMissionEvents` for
   unchanged terminal threads (`O(1)` lookup, zero network pages).
2. **Newest-first bounded concurrency**: Uncached `/btw` missions load their
   event pages with bounded concurrency (up to 4 threads in parallel, starting
   from the most recently active missions), preventing multi-minute head-of-line
   blocking behind old 800-event threads in a `fork-of:` chain.
3. **Non-overlapping periodic sync**: The 15 s background `setInterval` skips
   starting a new `sync()` while a previous `sync()` for the same panel key is
   still in flight, eliminating self-cancelling `generation` livelocks on high-latency
   links while preserving immediate event-driven resyncs (`streamMission` /
   `watchBtw` completion).

## 3. Transient network resilience in `watchBtw` & idempotent `Retry` (P1)

1. **Transient poll retry in `watchBtw`**:
   - Inside `watchBtw`'s remote poll loop (`currentSide` + `getMissionEvents`),
     if a poll throws `isTransientNetworkError(error)` while `!signal.aborted`
     and `connectionVersion() === version`, `watchBtw` does **not** fail the
     turn or clear `busy`.
   - Instead, it emits `{ type: "status", text: "Connection interrupted — reconnecting…" }`,
     logs a diagnostic note, waits the 5 s poll interval (woken early by `signal`
     abort or live SSE status events), and retries until Core responds with the
     authoritative mission state.
2. **Idempotent `Retry` reattachment in `askBtwAgent`**:
   - In `askBtwAgent`, when `currentSide` reports `ACTIVE.includes(current.status)`
     and the stored session is already running the **same** trimmed question
     (`s.question.trim() === question.trim()`), `askBtwAgent` marks `s.active = true`
     and falls directly through to `watchBtw(parent, signal, receive)` without
     sending a duplicate message or throwing `'The side agent is still running'`.
   - Distinct questions sent while `current` is active continue to throw
     `'The side agent is still running. Stop it before sending another question.'`
     when `askBtwAgent` is invoked directly, while `queueBtwFollowUp` (used by
     `SideQuestionPanel`) submits follow-ups into Core's durable queue (`POST
     /api/control/message` with `queue_followup: true`) or the local queue worker.

## 4. Unified follow-up queue & multi-turn stream hygiene (P0)

Side conversations use the **same durable follow-up queue** as the main
conversation rather than an isolated browser-only draft array:

1. **Server-backed queueing (`queue_followup: true`)**:
   - Submitting a `/btw` follow-up while the side session is running (or still
     launching its child mission) stages incremental `<main_conversation_update>`
     context (`queuedCursor ?? pendingCursor ?? conversationCursor`) and posts to
     `POST /api/control/message` with `queue_followup: true` and a stable
     `client_message_id` (or `enqueueLocalMessage` when the side session is
     client-placed locally).
   - Queued rows render through the shared `RemoteQueue` / `QueuedMessages` (desktop),
     `OrbFollowUpQueue` (iOS), and `OrbFollowUpQueueView` (Android) components,
     supporting **Edit**, **Send now** (`POST /api/control/queue/:id/send-now?interrupt=true`),
     and **Remove** (`DELETE /api/control/queue/:id`).
   - Because Core stores the wrapped `/btw` prompt (`<main_conversation_update> …
     Current request:\n<question>`), queue display and composer editing extract
     the user question (`extractBtwUserQuestion`), while in-place `PATCH
     /api/control/queue/:id` edits replace only the `Current request:` body
     (`replaceBtwUserQuestion`), preserving the incremental context wrapper and
     any `Attachment:` lines.
2. **Queued `user_message` isolation & seamless Turn N -> Turn N+1 handoff**:
   - Pre-submitted `user_message` events carrying `metadata.queued === true`
     never close or truncate the active `/btw` turn (`btwTurnEvents`,
     `parseBtwThread`, `OrbBtwThreads.parse`, `OrbSideAgent.parseTurns`).
   - When Core finishes Turn N and immediately dispatches queued Turn N+1 on the
     same child mission (emitting a non-queued `user_message` with
     `sequence > activeUserSequence`), `watchBtw` emits the completed Turn N
     exchange, advances to Turn N+1's question and sequence cursor, and
     incrementally polls forward (`since` last seen sequence) rather than
     re-paging the entire child event history on every 5 s poll.
   - Legacy browser-only `saved.queue` entries from older builds are deduplicated
     against Core's answered/active `/btw` history on mount before migrating any
     genuinely unsent item into the durable queue.
3. **Live working status & OpenCode auto-compaction filtering**:
   - While `busy` is true, the panel keeps the live working status indicator
     (`Working… · Ns`) visible below partial streamed narration/text so long
     multi-tool turns never look frozen.
   - OpenCode auto-compaction checkpoints (`## Objective` … `## Work State` /
     `## Progress` … `## Next Move` … `## Relevant Files`, with or without a
     trailing `compaction_continue` synthetic message) are suppressed both in
     Core's OpenCode stream parser (`remote_grok.rs`) and in client `/btw`
     parsers across desktop, iOS, and Android.

## Client parity

- **Orb desktop (`orb/`)**: implemented in `orb/src/SideQuestionPanel.tsx`,
  `orb/src/btwAgent.ts`, `orb/src/RemoteQueue.tsx`, and `orb/src/messagePresentation.ts`.
- **iOS (`ios_dashboard/SandboxedDashboard/Orb/OrbSideQuestion.swift`)**:
  `OrbSideQuestionSheet` shares `OrbFollowUpQueue` (`queue_followup: true`,
  `Edit`, `Send now`, `Remove`), caches finished threads by `(activity, status)`
  stamp, ignores queued `user_message` events, and strips OpenCode compaction
  checkpoints.
- **Android (`android_dashboard/app/src/main/java/sh/sandboxed/dashboard/orb/OrbSideAgent.kt`)**:
  `OrbSideAgentSheet` renders multi-turn `/btw` threads, shares
  `OrbFollowUpQueueView` (`queue_followup: true`, `Edit`, `Send now`, `Remove`),
  ignores queued `user_message` events, and strips OpenCode compaction
  checkpoints.
