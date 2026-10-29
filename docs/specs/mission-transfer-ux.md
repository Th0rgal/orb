# Mission transfer UX & startup lifecycle

Defines the state, error-classification, and UX invariants when transferring a
conversation to another harness (`POST /api/control/missions/:id/fork`).
Complements [`docs/HARNESS_TRANSFER.md`](../HARNESS_TRANSFER.md) and
[`docs/OPENCODE_RUNNER_LIFECYCLE.md`](../OPENCODE_RUNNER_LIFECYCLE.md).

## Background

During a live transfer of a multi-hundred-KB conversation to OpenCode
(`builtin/smart`), an older host runner expanded `.sandboxed-sh-prompt.txt` into
`argv` (`"$(cat ...)"`) and failed before OpenCode started with:

```text
/srv/sandboxed-storage/.../.sandboxed-sh-opencode-cmd.sh: 2: opencode: Argument list too long
```

Core finalized the failed run with `TerminalReason::LlmError`
(`MissionStatusChanged { status: Failed, summary: Some("Model error") }`)
followed by `AssistantMessage { success: false, content: "...opencode: Argument list too long" }`.
On Orb desktop, the source mission had already been archived before destination
startup was known, two error cards rendered (`Model error` plus raw failure),
`TurnRecap` showed `WAITING` from its legacy v7 digest placeholder, and blind
`Resume` was offered for a deterministic process-launch failure.

## 1. Backend prompt transport invariant (P0)

- Host and container OpenCode runs write the prompt to `.sandboxed-sh-prompt.txt`
  and redirect it onto OpenCode's `stdin` inside the PTY wrapper script
  (`opencode run ... < '<prompt_file>'`), keeping `argv` small and constant-size
  while keeping `stdout` attached to the PTY slave.
- Multi-hundred-KB `<fork_context>` envelopes containing multi-byte UTF-8
  (CJK, RTL, emoji, mathematical symbols), shell metacharacters (`'`, `"`,
  `$HOME`, `$(...)`, backticks), and trailing newlines must arrive on OpenCode's
  `stdin` byte-for-byte intact without triggering `E2BIG`.

## 2. Transfer state machine & deferred source archiving (P0)

Harness transfers have one client state owner (`ForkMission.tsx`) keyed by
`sourceId` (and indexed by `destination.id`):

```text
preparing -> source_stopped -> destination_starting -> running
                                                    \> failed
```

| Stage | Entry condition | Allowed effects & UI |
| --- | --- | --- |
| `preparing` | Operator selects target `(backend, model, effort, service_tier)` | Shows `Transferring…`; validates Codex speed support; calls `stopSource(sourceId)` and waits for confirmed stop. |
| `source_stopped` | `stopSource` confirmed; durable receipt `{ sourceId, payload, idempotency_key }` stored | Submits `POST /api/control/missions/:sourceId/fork`. Uncertain network/5xx errors stay in `source_stopped` and retry with the **exact** `payload` and `idempotency_key` (never spawning duplicate writers). |
| `destination_starting` | `POST /fork` returned `destination` | Navigates calmly to `destination` (`Starting <Harness> on <destination>…`). **Does not archive `sourceId` yet.** Both `MissionView` and a background watcher observe `destination`. |
| `running` | `destination` confirms startup: first non-error agent activity (`tool`, `think`, or assistant `text`), live `mission_activity`, or clean `awaiting_user`/`completed` settlement | Atomically transitions `archiveState: idle -> archiving` (at most one `archiveMission(sourceId)` call across SSE, poll, and watcher races), then dispatches `orb:mission-archived`. Archive errors transition to `archiveState: "failed"` with non-destructive `Retry archiving` (never re-forking). |
| `failed` | `destination` enters terminal failure/cancellation (`failed`, `not_feasible`, `interrupted`, `cancelled`, terminal error item, or failed remote job) **before** any agent activity | **Retains `sourceId` unarchived** in Core and the sidebar. Preserves the transfer receipt so selecting the identical broken target opens `destination` rather than spawning a duplicate failed writer, while allowing selection of a different target agent from `sourceId`. |

## 3. Process-launch classification & single failure card (P1)

1. **Distinct launch failure classification (`ErrorNotice.tsx`)**:
   - Command-line overflow (`Argument list too long`, `E2BIG`, `os error 7`),
     missing CLI binaries (`command not found`, `: not found`, spawn `ENOENT`),
     and CLI wrapper/exec permission errors (`Permission denied`, `Exec format error`,
     `Failed to start ... CLI`, `Failed to write ... command script`) classify as
     **process-launch failures** (`"<Harness> could not start"`, e.g.
     `"OpenCode could not start"`), never `"Model error"`.
   - Raw stderr/path details remain available verbatim in `Technical details`
     and `Copy error`.
2. **One failure card per failed turn (`transcriptModel.ts` & `MissionView.tsx`)**:
   - `TranscriptReducer` coalesces `[mission_status_changed("Model error"), assistant_message(success:false, detail)]`,
     its reverse order `[assistant_message(success:false, detail), mission_status_changed(...)]`,
     and overlapping stderr `error` events in the same turn by upgrading the
     turn's existing error item in place rather than appending a second card.
   - When `MissionView` observes a terminal status on SSE or initial load before
     the turn's terminal event is in `items()`, it triggers `resync(true)`
     immediately and withholds generic `"Model error"` fallback rendering while
     initial reconciliation is still in flight.

## 4. Unified execution-derived status & `TurnRecap` invariants (P1)

1. **Single execution phase label (`missionStatus.ts`)**:
   - `executionPhaseLabel(mission, opts)` is the single source of truth for
     `MissionPending` and `Transcript`'s `WorkingRow`.
   - While a mission is in unconfirmed startup (`transferStage === "destination_starting"`,
     `mission.status === "starting"`, or `opencode` / `claudecode` before first
     output and before confirmed remote node execution), it returns
     `"Starting <Harness>"` (`"Starting OpenCode on <destination>…"`), advancing
     to `"Working"` once execution or output is confirmed.
   - As soon as `missionActivity` resolves to `failed` or `idle`, working
     indicators unmount immediately.
2. **No `WAITING` badge or follow-up chips on failed turns (`TurnRecap.tsx`)**:
   - `TurnRecap` only renders when the latest turn contains an actual assistant
     `text` response (never on an error-only failed launch).
   - Its header verdict derives from `mission.status` and terminal turn errors
     rather than v7 digest's legacy `"waiting"` placeholder, so a failed or
     interrupted mission never displays `WAITING` or misleading suggestion chips.

## 5. Cause-appropriate recovery (P1)

- Deterministic process-launch failures (`isNonResumableError(raw) === true`)
  suppress the blind `Resume` button on both `Transcript` and `MissionFailure`.
- For `Argument list too long` (`E2BIG`), the notice explains that the backend
  passed carried history via command-line arguments instead of `stdin`, that the
  workspace and history are preserved, and that after updating the backend the
  operator can continue or send a message in the destination conversation
  directly **without creating another transfer** (or continue immediately in the
  retained original conversation).
- When `forkSource(mission)` is present on a failed destination, the error card
  offers an inline **`Open original conversation`** action that navigates back
  to the retained source mission and expands its version group in the sidebar.

## 6. Calm transition, version disclosure & performance budgets (P2)

- Selecting a transfer target shows `Transferring…` immediately (<100 ms) inside
  the menu without collapsing layout height or losing focus ownership.
- While both `source` and `destination` exist in the sidebar (`fork-of:`),
  `nestMissions` groups them under one conversation row with `earlier` version
  disclosure (`orb/docs/specs/sidebar-hierarchy.md` invariants **F1** and
  **F2**): `onFork(destination)` commits `destination` into `ProjectFiles`
  synchronously on frame 0, `destination` leads immediately without ever
  flickering as a sub-mission (`version`) under `source` while `source` stops
  or archives, and `retryTransferArchive` hides `source` optimistically at the
  start of archiving (rolling back on failure); navigating to an earlier version
  (`Open original conversation`) automatically expands its leader row in
  `ProjectFiles.tsx`.
- Startup JS stays below `orb/scripts/check-bundle.mjs`'s `1150 kB` budget,
  transfer/failure transitions incur zero layout jumps, and main-thread work per
  transition stays under interactive frame budgets.

## Client parity

- **Orb desktop (`orb/`)**: implemented in this change.
- **iOS (`ios_dashboard/`) & Android (`android_dashboard/`)**: tracked gap for
  follow-up parity on deferred source archiving and process-launch error
  classification; backend `stdin` prompt transport (`PR #1406`) already protects
  mobile-initiated OpenCode transfers from `E2BIG` on updated Core servers.
