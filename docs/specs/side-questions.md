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

## 5. Bounded session lifecycle, O(1) continuation preflight & incremental live reconciliation (P0)

Long-running parent campaigns (for example `9409f9a9`, >63,000 events) and
multi-turn `/btw` sessions (`2ac904f3`, 12 turns / 1,022 events / 832K input
tokens) exposed three client/server scaling hazards that made `/btw` appear
blocked:

1. **O(1) tail sequence preflight on idle continuation**:
   - Resuming an idle `/btw` mission needs only its latest sequence number
     (`afterSequence`) and depth, never its full event history.
   - `askBtwAgent` reads a single tail row (`getMissionEvents(id, { limit: 1,
     enough: () => true })`) instead of walking every `before_seq` page before
     calling `sendMissionMessage`.
2. **Bounded parent delta reads (`lazyBtwContext` / `fork.rs`)**:
   - Remote/Core `/btw` context (`lazyBtwContext`) passes
     `include_counts=false&max_payload=4096` (and `since_seq` when advancing an
     existing `ConversationCursor`, falling back to a bounded 200-event tail
     page on first turn or cursor reset), avoiding multi-MB `view=all&limit=1000`
     payloads and `COUNT(*)` table scans on >60k-event parent missions.
   - Core's non-incremental `/btw/agent` path (`src/api/control/fork.rs`, used
     by iOS) reads only a bounded head + tail transcript slice instead of
     scanning 50,001 rows or rejecting >50k-message parents with `413
     Conversation is too large to fork without truncation`.
3. **Incremental live-thread event cache**:
   - While a `/btw` mission is active, `reconcileBtwServerHistory` (desktop),
     `OrbBtwStore` (iOS), and `OrbSideAgentSheet` (Android) retain a
     sequence-keyed in-memory event cache per thread and fetch only
     `since_seq = maxKnownSequence` deltas on periodic polls, falling back to a
     full read only on first load or sequence regression.
4. **Automatic session rotation (`BTW_MAX_SESSION_EVENTS = 400`, `BTW_MAX_SESSION_TURNS = 8`) & explicit `New side session`**:
   - Reusing one `/btw` harness session across a dozen tool-heavy turns bloats
     its context to hundreds of thousands of tokens and triggers multi-minute
     compaction stalls.
   - When the bound `/btw` session is idle (`!active` and no queued follow-ups)
     and either the operator armed **New side session** (`freshSession`) or the
     session reached `>= 8` answered turns or `maxSequence >= 400` events
     (`shouldRotateBtwSession`), the next side question automatically launches a
     fresh `POST /api/control/missions/:id/btw/agent` mission (seeding recent
     `/btw` Q&A in `<main_conversation_update>`) while keeping every earlier
     turn visible in the unified `/btw` transcript.
   - While a side session is actively running or holds queued follow-ups,
     follow-ups continue queueing onto that live mission so `Edit`, `Send now`,
     and `Remove` remain atomic on a single queue.

## 6. Warm-cache single ownership, partial-failure dirty discipline & duplicate-question disambiguation (P0)

During mission `06203bdc-3543-483e-a8c5-3bf20eb5c34a`, the user submitted a
`/btw` question (`1013a4da-ba7a-4628-91a7-0c859b78438c`), switched missions
while it ran, and reopened `06203bdc` after `1013a4da` had completed cleanly on
Core. Background warm sync had already reconciled `1013a4da` (setting
`btwSession.active = false` in `localStorage` and populating `warmBtwByParent`
with all 13 answered turns and `dirty = false`), yet mounting `SideQuestions`
hydrated stale 12-turn IndexedDB `saved.history` + `saved.pending`, overwrote
`warmBtwByParent` with those stale 12 turns (`dirty = false`) from its
persistence effect, short-circuited `reconcileBtwServerHistory` without hitting
Core, and permanently wrote
`"Side question interrupted. Retry to request a complete answer."` into
IndexedDB.

All clients enforce four invariants so cached and warm `/btw` state never
fabricates an interruption or drops completed turns:

1. **Single owner of warm `/btw` state (`btwAgent.ts` / `OrbBtwStore` / `OrbWarmSyncCoordinator`)**:
   - View persistence (`SideQuestionPanel.tsx` writing IndexedDB snapshots)
     **never** writes unverified or disk-hydrated `saved.history` back into
     `warmBtwByParent`, and never marks an unverified entry clean (`dirty: false`).
   - Only `btwAgent.ts` mutates `warmBtwByParent`: starting or queueing onto a
     side session records `latest` and marks `dirty = true`; completing a turn
     appends without erasing prior turns; only an authoritative Core
     reconciliation (`storeWarmBtwResult`) or a caught-up live `/api/control/sync`
     stream with a known turn baseline marks `dirty = false`.
   - `btwAgent.ts` shares `missionCache.ts`'s unified `WarmMissionSub`
     (`attachMissionStream` + `registerWarmBtwTargets`, `since_seq` cursor, and
     `sync_caught_up` fence) for warm `/btw` child missions, reducing live
     `user_message`, `text_delta`, `assistant_message`, and `mission_status_changed`
     frames directly in memory (`reduceLiveBtwStreamEvents`) without debounced
     HTTP crawls. When `mission_status_changed` transitions the `/btw` child out
     of `ACTIVE`, `btwAgent.ts` immediately clears `btwSession(parent).active`
     (and `startedAt`) in `localStorage` and invokes `healSavedSideQuestionFromServer`,
     preventing stale `"Starting side agent… · 1 h 17"` banners on reopen
     (observed on `9409f9a9-d3eb-416a-b5a8-978508bed734`).
   - `sideQuestionStorage.ts` maintains a bounded in-memory write-through cache
     (`peekSavedSideQuestion`) so reopening a mission hydrates the `/btw` dock
     synchronously on frame 0 alongside `MissionView`; if `peekWarmBtwState(parent)`
     is clean and already answers `saved.pending`, any stale `btwSession(parent).active`
     flag is cleared in place instead of entering `watchBtw`.
   - Cold `/btw` reconciliations pass `include_history=false` on metadata/fork
     reads, filter `/events` to `types=user_message,assistant_message,assistant_message_canonical,text_delta`
     (skipping `tool_call`/`tool_result`/`thinking`/`text_op` pages while keeping
     `repairedFinal`), and query Core's partial SQLite index `idx_missions_btw_tags`
     on `?tag=btw-parent:<id>`.
   - On mount, if `peekWarmBtwState(parent)` already holds reconciled turns,
     async `readSideQuestion` preserves those warm turns (merging local
     attachment metadata) instead of rolling `history` back to an older
     IndexedDB snapshot.
   - Whenever `reconcileBtwServerHistory` completes authoritatively, it asks the
     single storage owner (`reconcileSavedSideQuestion` in `sideQuestionStorage.ts`,
     backed by per-key serialization and a single `'readwrite'` IndexedDB
     transaction via `updateSideThread`) to conditionally heal `parent`: only if
     the currently stored `pending` turn (`!notSent`) is still answered by the
     reconciled history does it clear `pending` and write merged history,
     preserving any newer `draft`, `queue`, or subsequent `pending` turn saved
     concurrently by a mounted panel.
2. **Mandatory Core verification for pending, in-flight launch, and previously-interrupted turns**:
   - Mounting with `saved.pending` (unless `peekWarmBtwState` already proves the
     pending turn was answered), settling an unmounted `btwLaunchPending(parent)`
     promise when `launched?.active` is false (for example a fast turn that
     finished while switched away, or a failed pre-send), running event/completion
     `resync()`, or clicking `Retry` on an accepted turn (`!notSent`) passes
     `force: true` so `reconcileBtwServerHistory` never short-circuits on a
     cached entry (nor may `reconcileBtwServerHistory` use its non-forced cache
     while `btwSession(parent)?.active` is true).
   - If `btwLaunchPending(parent)` rejects before Core accepts the question
     (`BtwNotSentError`), `btwLastLaunchError(parent)` surfaces the exact
     `notSent` error on remount instead of fabricating `"Side question interrupted..."`.
   - A persisted `interruptedError` (`!notSent`) is re-verified against Core on
     open (without flashing the stale error banner while reconnecting) and on
     `Retry` (adopting Core's completed answer instead of sending a duplicate
     follow-up if Core already finished the turn).
3. **Partial or failed HTTP reads stay dirty and non-authoritative**:
   - `btwThreadChain` never memoizes a degraded fallback when `getMission` fails
     transiently; any failure in `btwThreadChain`, `?tag=btw-parent:...`, direct
     lookup of known `btwSession(parent).id`, or per-thread `getMissionEvents`
     marks the reconciliation non-authoritative (`authoritative: false` on
     desktop, `markBtwDirty` on iOS, `markClean = false` on Android).
   - `apiRawOnce` (`stream.ts`, backing `getMissionEventPage` / `getMissionEvents`)
     throws typed `ApiError` and `InvalidApiResponseError`, and
     `isTransientNetworkError` covers gateway statuses `502`, `503`, `504`, `522`,
     and `524`, so brief proxy/deploy blips during `watchBtw` or reconciliation
     retry cleanly rather than failing an active side turn.
   - Non-authoritative reconciliations never mark the warm cache clean and never
     transition `awaitingServerPending` into `"Side question interrupted..."`;
     `SideQuestionPanel` keeps `busy = true` (`"Connection interrupted — reconnecting…"`)
     so recovery polling/streaming heals automatically once connectivity returns.
   - Known `btwSession(parent).id` (desktop/iOS/Android) is fetched directly
     (resolving any `superseded_by:` hop) when absent from the
     `?tag=btw-parent:...&limit=50` page so tag-index lag, supersession, or >50
     historical side threads cannot hide the active/latest session.
4. **Pending-turn disambiguation across duplicate question text (`doesTurnAnswerPending`)**:
   - Repeated short prompts (for example asking `"and now?"` multiple times in
     one conversation) must not match an older completed turn against a newly
     submitted pending turn.
   - `doesTurnAnswerPending` matches by exact `userEventId === turnId` when
     present, or by trimmed question text only when the reconciled match count
     exceeds the pre-pending local match count and the latest matching turn's
     timestamp is not older than `startedAt - 5 s`.

## 7. Bounded `/btw` rendering, WebView mount budgeting & conversational terminal loads (P0)

Opening the `/btw` sheet on long-running parent campaigns (`9409f9a9`, 25 `/btw`
missions, 9,992 stored events / 15.5 MB JSON, 251 answered side turns, 28
` ```mermaid ` diagrams) exposed a mobile Jetsam / main-thread watchdog crash
when all turns, raw tool events, and inline `WKWebView` diagrams were mounted
simultaneously:

1. **Bounded `/btw` transcript window (`OrbTranscriptGates.visibleTurnCount`) & cold-load skeleton**:
   - `SideQuestionPanel` (desktop), `OrbSideQuestionSheet` (iOS), and
     `OrbSideAgentSheet` (Android) window rendered `/btw` history to the latest
     `20` turns (`BTW_INITIAL_VISIBLE_TURNS` / `INITIAL_VISIBLE_TURNS = 20`,
     stepping by `20` via a `"Load earlier side questions"` pill or upward scroll
     at top when `hiddenTurnCount > 0`), preserving scroll anchor on expansion and
     avoiding layout jumps when new turns arrive while scrolled up (`pinnedExtraTurns`).
   - While cold local storage or the initial cold Core reconciliation is still in
     flight and no warm turns, pending question, or queued items exist yet,
     `SideQuestionPanel` renders `<SideQuestionSkeleton />` instead of flashing
     premature empty-state copy.
   - Merged `/btw` turn IDs pass through `OrbTranscriptGates.ensureUniqueIds`
     (`lean/Orb/Transcript.lean`) so `ForEach` / `.scrollPosition` never
     encounters duplicate identities even across replayed or legacy cached rows.
2. **Inline diagram WebView mount budget (`OrbTranscriptGates.admitMount`) & shared data store**:
   - Inline Mermaid `WKWebView` mounts (`OrbMermaidBlock` / `OrbMermaidRenderer`)
     enforce `OrbTranscriptGates.admitMount(active, cap = 8)` (`maxInlineDiagramMounts = 8`),
     falling back beyond the cap to a lightweight source preview with an explicit
     **Show diagram** action and releasing mount slots on disappear.
   - Script-disabled SVG display web views (`OrbSVGView`, `OrbSvgView`) share a
     single non-persistent `WKWebsiteDataStore` instead of spawning an isolated
     `WebContent` XPC process per diagram.
3. **Conversational-only terminal thread fetches & zero raw tool-event retention**:
   - For historical terminal (`!live` and non-`latest` resumable) `/btw` missions,
     `reconcileBtwServerHistory` (desktop), `OrbBtwStore` (iOS), and `OrbSideAgent`
     (Android) fetch only conversational message events
     (`types=user_message,assistant_message,assistant_message_canonical`),
     memoize only the parsed `turns`, `delivered` IDs, and `maxSequence`
     (`X-Max-Sequence` / 1-row tail), and avoid retaining raw `StoredEvent` / `OrbRow`
     logs in memory (with bounded 4-way concurrency, live/newest first). Live
     (and on desktop the `latest` resumable) `/btw` missions continue to cache
     incremental `since_seq` deltas for live following and `repairedFinal`.

## 8. Automatic turn recovery continuity & idempotent continuation payloads (P0)

During parent mission `23bad383-5b27-4b83-9a84-d86d34223509` (`/btw` child
`fc153ce6-2a61-43a6-8e2f-e01cbc263661`), a `/btw` turn (`8652b679-ee6e-4b49-9429-b09ec99e08a9`)
was accepted by Core (`200 OK` with `Idempotency-Key: msg:fc153ce6-...:8652b679-...`),
experienced a transient remote `opencode` inference disconnect on `babylon`
(`seq 286`), was automatically resumed by Core's coordinator (`seq 289`,
`metadata.source = "api:usage-limit-replay"`, content `"[Automatic recovery]..."`),
and finished its answer at `seq 301`. Clicking **Retry** later surfaced:

```text
409 {"error":"idempotency_conflict","message":"Idempotency-Key was already used with a different request payload"}
```

Two invariants prevent both the orphaned recovery answer and the `409` conflict:

1. **Coordinator / automatic `user_message` events continue the active `/btw` turn (`isAutomaticUserEvent`)**:
   - Stored or streamed `user_message` events injected by Core (`metadata.source`
     in `{"api:usage-limit-replay", "background-task", "scheduler", "idle-worker-watchdog",
     "transport_auto_resume", "remote-build-terminal", "task-board"}`,
     `metadata.backgroundWake !== undefined`, `metadata.resumePrompt === true`,
     `[Automatic recovery]` / `[Automatic resume after a usage limit]`, or the
     exact resume prompt) **never** open a new `/btw` turn, flush the prior
     user question, reset live streaming state, or register as a delivered
     user follow-up across Desktop (`btwTurnEvents`, `watchBtw`,
     `parseBtwThread`, `reconnectBtwSession`, `reduceLiveBtwStreamEvents`),
     iOS (`OrbBtwThreads.parse`, `OrbBtwStore.deliveredMessages`), and Android
     (`OrbSideAgent.parseTurns`, `OrbSideAgent.parseHistoryFallback`).
   - Consequently, an auto-recovered `/btw` answer stays paired with the user's
     real question (`btw:<mission>:<userSeq>`), allowing `doesTurnAnswerPending`
     and `reconcileSavedSideQuestion` to clear any transient failure banner as
     soon as Core's recovery completes.
2. **Frozen continuation payload per `(sideMissionId, clientMessageId)` & post-acceptance key rotation**:
   - While a `POST /api/control/message` continuation is unaccepted, `askBtwAgent`
     caches `{ logical, prompt, snapshot }` under `(sideId, clientMessageId)` so
     every automatic retry (`BTW_SEND_RETRY_MS`) or manual `Retry` of a genuinely
     unsent (`notSent === true`) turn replays the **exact same JSON body** for
     that `Idempotency-Key`, even if the parent mission emits new events in the
     meantime. Mobile `OrbSideQuestionSheet.ask()` (iOS) and
     `OrbSideAgentSheet.submitQuestion` / `OrbSideAgent.launch` (Android)
     likewise freeze the wrapped prompt and `Idempotency-Key` outside their
     `retrying` loops.
   - Once Core has accepted a turn (`notSent === false`), or if any stale
     persisted key ever receives `409 idempotency_conflict`, `Retry` and
     `askBtwAgent` mint a fresh `crypto.randomUUID()` (and evict any cached
     attempt payload) instead of reusing the consumed `Idempotency-Key`. Legacy
     delete-and-resend `Send now` fallbacks (`sendSideImmediate`) also mint a
     fresh UUID per resent item so edited queue content never collides with the
     original enqueue `Idempotency-Key`.

## Client parity

- **Orb desktop (`orb/`)**: implemented in `orb/src/SideQuestionPanel.tsx`,
  `orb/src/Skeleton.tsx`, `orb/src/btwAgent.ts`, `orb/src/btwContext.ts`,
  `orb/src/RemoteQueue.tsx`, and `orb/src/messagePresentation.ts` (including
  header `New side session` action, `shouldRotateBtwSession`, O(1) tail preflight,
  bounded parent delta reads, bounded 20-turn transcript windowing with
  `Load earlier side questions`, cold-load `SideQuestionSkeleton`, conversational-only
  historical terminal thread fetches, and incremental live `view=history` caching).
- **iOS (`ios_dashboard/SandboxedDashboard/Orb/OrbSideQuestion.swift`, `OrbMermaid.swift`)**:
  `OrbSideQuestionSheet` shares `OrbFollowUpQueue` (`queue_followup: true`,
  `Edit`, `Send now`, `Remove`), toolbar `New side session`, automatic
  `OrbBtwThreads.shouldRotateSession` rotation, bounded 20-turn transcript
  windowing (`btw.loadEarlier`), `admitMount`-budgeted Mermaid `WKWebView`s,
  4-way conversational-only terminal thread loading, incremental `sinceSeq` live
  polling, queued `user_message` isolation, and OpenCode compaction stripping.
- **Android (`android_dashboard/app/src/main/java/sh/sandboxed/dashboard/orb/OrbSideAgent.kt`)**:
  `OrbSideAgentSheet` renders multi-turn `/btw` threads with bounded 20-turn
  windowing (`Load earlier side questions`), 4-way conversational-only terminal
  thread loading without raw tool-event retention, shares `OrbFollowUpQueueView`
  (`queue_followup: true`, `Edit`, `Send now`, `Remove`), header `New`
  side-session action, automatic `OrbSideAgent.shouldRotateSession` rotation,
  incremental `since_seq` live polling, queued `user_message` isolation, and
  OpenCode compaction stripping.
