# Remote Replay Rollback & Stranded-Pending Recovery

Formal state machine: `lean/Orb/Kernel.lean` (`orb_activation_rollback_admit`,
`orb_remote_replay_step`), `lean/Orb/Spec.lean` (`activationRollbackMetaGate`,
`activationRollbackScopedAuthority`, `activationRollbackArchiveStickyFence`,
`remoteReplayMetaGate`, `remoteReplayRetryResource`,
`ashur_9409f9a9_enospc_replay_recovery_witness`), and pure-Lean `OrbCore`
(`lean/OrbCore/OrbCore/Spec.lean`: `verifyRemoteReplaySupersession`,
`remoteReplaySupersessionMetaGate`, `remoteReplaySupersessionFence`;
`lean/OrbCore/OrbCore/MutantSuite.lean`: `remote_replay_supersession_kills_manual_override_mutant`;
`lean/OrbCore/OrbCore/Store.lean`: `restoreMissionStatus`, `armRemoteMissionWait`,
`stepRemoteMissionReplay`, `reconcileStrandedPendingMissions`;
`lean/OrbCore/OrbCore/Control.lean`: `/api/control/missions/:id/remote-wait`,
`/api/control/missions/:id/remote-replay`, `/api/control/missions/reconcile-pending`).

## Incident Context (`9409f9a9-d3eb-416a-b5a8-978508bed734` on `ashur`)

A remote OpenCode mission (`evm.fast (claude takeover)`) with an active 600 s
durable schedule encountered temporary disk exhaustion (`ENOSPC`, OS error 28)
on remote node `ashur`:

1. Scheduled wakeup job `bee05799` failed with `No space left on device (os error 28)`.
   `finalize_remote_mission` transitioned the mission to `Interrupted`
   (`terminal_reason = "usage_limit_wait"`, summary `"Remote node 'ashur' paused; automatic recovery is scheduled"`)
   and armed a 90 s `RemoteWait`.
2. When the 90 s replay fired, `continue_inner` captured `MissionStatusSnapshot`
   (`Interrupted`), moved the mission through transitional `Pending`, bound the
   running `automation_executions` row's `__remote_job_id` to new job `9b22bf33`,
   and submitted `POST /jobs` to `ashur`.
3. `ashur` returned definitive HTTP 500 (`No space left on device (os error 28)`).
   Four bugs then chained together:
   - `restore_mission_status` checked `status == 'active' || status == snapshot.status`,
     rejecting `Pending` (`500 INTERNAL_SERVER_ERROR: mission status changed during rejected activation`)
     and leaving the mission permanently stranded in `Pending` (`stuck_queued`).
   - `replay_remote_mission_after_usage_limit` saw `status != Interrupted`,
     skipped scheduling a retry, and deleted `RemoteWait` on the next 30 s tick.
   - `continue_inner` wrapped every `dispatch_remote_job` failure in `409 CONFLICT`,
     which `after_replay_failure` treated as non-transient (`GiveUp`).
   - `dispatch_remote_job` cleared `queue_delivery` on definitive rejection but
     did not roll `__remote_job_id` back to `previous_job`, leaving the
     `durable_schedule` execution bound to rejected `9b22bf33`.
   - When `dispatch_remote_job` acquired and closed a tentative `MissionRun`
     (`terminal_reason = "remote_dispatch_failed"`), `placement()` updated its
     returned `job_id` to that aborted run while `RemoteWait.failed_job_id`
     remained pinned to `previous_job`, causing the next retry to fail with
     `409 Scheduled recovery was superseded`. `replay_remote_mission_after_usage_limit`
     now advances `RemoteWait.failed_job_id` iff the latest `MissionRun` is
     terminal with `remote_dispatch_failed`, preserving the manual-resume
     supersession fence.

## Kernel Gates & Invariants

### 1. `orb_activation_rollback_admit(currentStatus, snapshotStatus, hasActiveRun)`

- **Domain**: `MissionLifecycleStatusCode` (`0..=10`:
  `0 = Pending`, `1 = Active`, `2 = AwaitingUser`, `3 = Acknowledged`,
  `4 = WaitingBackground`, `5 = Completed`, `6 = Failed`, `7 = Interrupted`,
  `8 = Blocked`, `9 = NotFeasible`, `10 = Paused`).
- **ScopedAuthority (`activationRollbackScopedAuthority`)**: Admits rollback (`1`)
  iff `hasActiveRun == 0`, `currentStatus <= 10`, `snapshotStatus <= 10`,
  `currentStatus != 3`, and `currentStatus` is either transitional `Pending (0)`,
  transitional `Active (1)`, or idempotently equal to `snapshotStatus`.
- **StickyFence (`activationRollbackArchiveStickyFence`)**: Once a mission enters
  `Acknowledged (3)`, rollback is permanently fenced (`0`) so a stale activation
  snapshot can never un-archive an operator-archived mission.
- **Live-Run Fence**: Any non-terminal `mission_runs` row (`hasActiveRun != 0`) fences
  rollback in `OrbCore.Store.restoreMissionStatus`.

### 3. `orb_core_verify_remote_replay_supersession` (`OrbCore.Spec`)

- **Domain Model (`ReplayLineageKind`)**:
  - `.exactFailedJob`: `placement_job_id` equals `mission_remote_waits.failed_job_id`.
  - `.abortedPreDispatchChain`: an earlier scheduled replay bound a tentative
    `placement_job_id` that terminated pre-dispatch (`execution_state = 'terminal'`,
    `terminal_reason = 'remote_dispatch_failed'`, `remote_job_id = placement_job_id`).
- **StickyFence (`remoteReplaySupersessionFence`)**: Any manual/user resume or live
  run breaks both lineages, clears `mission_remote_waits`, and returns `409 scheduled_recovery_superseded`.

### 2. `orb_remote_replay_step`

- **`op = 0` (`replay_outcome`)**:
  - Pre-dispatch checks emit `clear_wait_superseded (1)` when the mission is no
    longer waiting for remote recovery, or `fail_deadline (2)` when its scheduling
    deadline has passed.
  - Successful dispatch (`dispatchOutcome = 0`) emits `mark_replayed (3)`.
  - Transient node/storage/transport/still-running dispatch failures
    (`dispatchOutcome = 1`: HTTP 5xx/429, `ENOSPC`/disk-full/SQLite-locked,
    connect/request transport failures, ambiguous submit cancellation, or
    `REMOTE_JOB_STILL_RUNNING`) emit `retry_wait (4)` while
    `retries < maxRetries` and `retryFitsDeadline == 1` (`ConservedResource`:
    `remoteReplayRetryResource`), and `give_up_fail (5)` once retry budget or
    deadline is exhausted.
  - Every failed replay sets `rollbackStatus` (`bit 9 = 512`), and sets
    `restoreScheduledOrigin` (`bit 10 = 1024`) iff `hasRecoveryHandle == 0`
    (definitive preflight or node HTTP rejection), preserving scheduled job
    bindings on ambiguous transport failures (`hasRecoveryHandle == 1`).
- **`op = 1` (`stranded_pending_check`)**:
  - Emits `interrupt_stranded_pending (6) | admitted (256) = 262` iff the mission
    is `Pending`, not client-placed or running in the local actor, holds neither
    a non-terminal `MissionRun` nor a `deferred_goal` (fail-closed on store
    errors), and its latest run ended with `remote_dispatch_failed` past the
    grace window.
  - Invoked both at boot/manual `reconcile::run` and periodically by the remote
    wait replayer (`sweep_stranded_pending_missions`) so crash-window stranded
    `pending` rows self-heal without requiring a service restart.
