# Explicit State Machines, Authoritative Formal Models & Race-Free Effects (`Th0rgal/orb`)

Status: executable campaign plan grounded in `AGENTS.md`, `docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md`, `docs/AGENT_CONTROL_PLANE.md`, `docs/AGENT_NATIVE_ROADMAP.md`, `docs/validation-campaigns.md`, and the Orb Library methodology derived from Thomas's Hindsight notes (`formal-spec` `kp-47c739bec662419d8d05f283de607b9e` / `kp-b85c9e90ebed458d82afcb5455300020`, `maxwell` `kp-18069005e3c748649d5eeec34b2b343a`, `orchestration`, `managed-compute`, `lean-builds`, `orb-control`, `github-workflow`).

---

## 0. Campaign Mandate & Constraints

### Primary objective
Eliminate split-brain state, ad-hoc flag/string protocols, TOCTOU races, and shadow-only formalization across `Th0rgal/orb` (`src/`, `crates/orb-spec/`, `lean/Orb/`, `orb/`, `orb/src-tauri/`, `ios_dashboard/`, `android_dashboard/`) by establishing:

1. **One canonical owner per state** (no competing in-memory maps, duplicate runners, or magic string tags acting as authority).
2. **One authoritative pure transition function** (`Lean Decides, Rust/Client Does` where pure protocol logic applies; clean single-owner Rust/platform adapters for pure I/O mechanics).
3. **Recoverable, generation-fenced execution of every external effect** (no silent retries across uncertainty, no stale-epoch mutations, no pre-commit external side effects).

### Execution constraints for this campaign
- **Model & backend discipline:** Every coordinator, worker, reviewer, conflict-resolver, and certifier mission in this campaign MUST run `backend: "opencode"` with `model_override: "builtin/smart"`. Because all subagents share one model route (`builtin/smart`), multi-family quorum rules record `quorum: single-family-mandate (opencode + builtin/smart)` and rely on **disjoint `writer: false` adversarial reviewers + mechanical Maxwell / `turbo-lean` / test / mutant oracles** rather than cross-provider voting.
- **Managed compute & DAG parallelism:** Parallelize across `boat` managed VMs (`managed-compute` + `orchestration` + `lean-builds`) organized as an explicit dependency DAG (`plan_tasks` / `get_fleet_sweep` / `schedule_wakeup`), preloading each wave's dependency cone once into a SHA-named warm Boat snapshot (`state-plan-<sha7>-warm`) before fanning out short-TTL leaf workers.
- **Maxwell gates where relevant, ordinary engineering gates elsewhere:** Apply Maxwell + `formal-spec` 4-layer discipline strictly to Lean 4 specifications, kernel C-ABI/WASM exports, mutant suites, and state-machine proofs (`lean/Orb/`, `crates/orb-spec/`, `shared/orb-spec/`). Do **not** wrap pure UI/CSS/platform plumbing in ceremonial research overhead; validate those with deterministic replay/unit/browser/platform tests.
- **Continuous Git integration:** Commit, push, open/update PRs, resolve rebase/merge conflicts, verify exact-head green CI, and merge at the end of every bounded DAG step/wave—never accumulate unpushed local state on ephemeral VMs or giant unmerged mega-branches.

---

## 1. Architecture & Assurance Contract

### 1.1 Ownership boundary (`Lean Decides, Rust & Clients Do`)

#### Belongs in Lean (`lean/Orb/*.lean` -> `orb_kernel_unboxed.c` / `liborb_spec_cabi.a` / `orb_kernel.wasm`)
- Mission, run, queue-entry, continuation, cancellation, and supersession state transitions.
- Admission, ownership, leases, `owner_epoch` / `run_generation` / `node_boot_epoch` fencing, and stale-event rejection.
- Submission uncertainty (`Submitting -> Accepted | Uncertain`), crash reconciliation, retry eligibility, and irreversible `StickyFence` commitment boundaries.
- Managed VM lifecycle, claim/reap/minimum-lease (`deletable_at`) eligibility, remote job ledger transitions, and `/proc` `(pid, start_ticks)` liveness checks.
- Cross-client follow-up queue reconciliation, optimistic send retirement by `(id, seq)`, transport epoch/fallback state, transcript patching, scroll policy, and stream block commit.
- Resource conservation (`ConservedResource`), clock discipline (`ClockDiscipline`), scoped authority (`ScopedAuthority`), and cross-client determinism (`ProjectionStability`).

#### Stays in Rust & platform adapters (`src/`, `orb/`, `orb/src-tauri/`, `ios_dashboard/`, `android_dashboard/`)
- SQLite transactions, WAL checkpoints, schema migrations, and CAS queries.
- Filesystem `fsync`/atomic rename, `flock`, process spawning, `systemd-run`/`systemd-nspawn` scopes, and signals.
- HTTP/WS/SSE sockets, upstream LLM/cloud-provider requests, Bitwarden/OAuth/FIDO/crypto I/O.
- SolidJS, SwiftUI, and Jetpack Compose rendering, layout measurement, IME/focus, and platform media APIs.

**Honesty boundary:** Lean proves protocol invariants under explicit environmental and adapter assumptions (`0 import Lean`, `0 sorryAx`). Lean alone does **not** prove SQLite SQL text, OS signal delivery, or third-party provider idempotency; adapters require concurrency, crash-injection, and exact-head integration tests. Keep `ORB_KERNEL_BACKEND=stock-c` decoupled from `LeanNative` compiler-backend switching (`P3` in `docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md` remains a separate track).

### 1.2 Standard transition & durable effect contract

Every stateful workflow must converge on one conceptual step signature:

```text
transition(state, event) -> (next_state, effect_intents, decision)
```

Every durable mutation with external side effects executes as:

```text
1. Read canonical (state, state_revision, owner_epoch / run_generation)
2. Compute pure transition(state, event)
3. Atomically commit (next_state, state_revision + 1, durable effect_intents) via SQLite CAS
   - If CAS fails: abort without executing any external effect
4. Execute committed effect_intents carrying stable (operation_id, idempotency_key, owner_epoch)
5. Record external outcome as a new typed observation event:
   - Confirmed success -> Accepted(external_handle)
   - Confirmed rejection (pre-commit) -> Rejected(reason)
   - Timeout / transport drop / 5xx after send -> Uncertain(attempt_id)  [NEVER silent fresh retry]
```

**Six non-negotiable invariants:**
1. **No external effect before admission commits.**
2. **Stale owners (`epoch < current_epoch`) cannot commit state or dispatch effects.**
3. **Ambiguous external outcomes transition to `Uncertain` / `reconciliation_required`, never silent re-execution under a new key.**
4. **Missing or uncollected observations count as `Unobserved`, never `ExactMatch` or success.**
5. **Read views (`ControlState`, HTTP digests, UI badges) are pure projections of canonical state, never independent state machines.**
6. **Retries preserve logical `operation_id` and `idempotency_key` end-to-end.**

---

## 2. Hindsight / Memory Delegation, Boat VM Fleet & Maxwell Protocol

### 2.1 Coordinator vs. Boat worker topology

1. **Thin Coordinator (`orchestrator-boss` + `orchestration` + `orb-control`):**
   - The coordinator decomposes waves, maintains the open-file ownership ledger, dispatches Boat missions, runs `get_fleet_sweep`, schedules durable wakeups (`schedule_wakeup`), reviews diffs/receipts, and triggers integration merges.
   - **Hard rule:** Never turn the coordinator into a single-threaded bottleneck editing implementation files or running heavy `cargo`/`turbo-lean` builds while 0 workers run.
   - **Never tight-poll or `sleep` in bash:** Register tasks (`plan_tasks` when applicable or `start_mission` + `wait_actions` for immediate launch receipts), arm `schedule_wakeup(delay_seconds=...)`, and **end the turn immediately**.
   - **Diagnostics hygiene:** Check `get_fleet_sweep` / `get_mission_health` first. Never call `get_mission_events(view="all")` or loop `get_mission_diagnostics` on healthy workers (prevents multi-MB trace dumps and node `ENOSPC`).

2. **Warm Boat Snapshot Preloading (`managed-compute` + `lean-builds`):**
   - Check `get_budget`, `list_managed_machines`, and `list_managed_snapshots` at wave start; never request raw cloud keys (`BOAT_API_KEY`, etc., are `CoreReserved`).
   - Rent one coordinator-owned builder VM via `spawn_managed_machine(provider="boat", size="xlarge", ttl_minutes=90, reason="wave-<N>-warm-snapshot")`.
   - Inside Boat (`HOME=/var/lib/orb-node`, user `orbnode`), materialize repo + Cargo target cache + Lean `.lake` / `turbo-lean` caches strictly under `/var/lib/orb-node/work/caches/...` (**never** `/tmp` or `~/.cache`, which Boat snapshots omit).
   - Scrub any `.git/config` credentials, run `sync`, call `snapshot_managed_machine(machine_id=..., name="orb-state-<sha7>-warm")` while the builder is online, poll `list_managed_snapshots` until `status == "ready"` and verify `size_bytes` reflects compiled caches, then `stop_managed_machine` or `destroy_managed_machine` the builder.
   - Refuse to launch wave leaf workers until `orb-state-<sha7>-warm` is `ready`. Refresh the snapshot whenever `Cargo.lock`, `pnpm-lock.yaml`, `lean-toolchain`, or frozen `lean/Orb/*.lean` hubs change.

3. **Role-based Boat VM sizing & TTLs:**
   - **Snapshot builder / Wave integrator / Full CI certifier:** `boat:xlarge` (16 vCPU / 32 GiB RAM), TTL 60–90 min (auto-extended while busy).
   - **Rust / Lean / Client shard workers:** `boat:large` (8 vCPU / 16 GiB RAM), short initial TTL (30–45 min), launched via `start_mission(backend="opencode", model_override="builtin/smart", remote_node_id="auto-managed:boat:large", managed_from_snapshot="orb-state-<sha7>-warm", writer=true, ...)`.
   - **Read-only adversarial spec/diff reviewers (`writer: false`):** `boat:default` or `boat:large` (each on its **own distinct `track`** so Core never auto-cancels sibling reviewers!).
   - **Build serialization per VM/worktree:** Never share one `CARGO_TARGET_DIR` or `.lake/build` across concurrent writers. Set `CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0` for routine dev/test builds, pass `--jobs 1` / `--max-memory-mb 6144` on `turbo-lean`, and verify installed CLI flags with `--version` / `--help` before referencing them in worker prompts.

4. **Build the lever & 1-unit canary before fan-out:**
   - Before spawning $\ge 4$ parallel shard workers for a repetitive migration, complete **1 vertical canary unit** end-to-end (spec -> implementation -> test -> CI -> merge). If a deterministic script/codemod can perform the remaining $N-1$ edits safely, ship and verify the script instead of fanning out $N$ LLM workers.
   - Keep worker launch prompts concise ($< 4{,}000$ Unicode characters): commit frozen task contracts/specs (`docs/specs/...` or wave blueprints) to git and pass exact `(branch, base_sha, owned_paths, verification_command)`.

5. **Open-file ownership ledger & pre-TTL push discipline:**
   - On every coordinator sweep, maintain a strict table: `(owned_paths, owner_mission_id, branch, last_pushed_sha)`. Two concurrent writers touching overlapping files is an orchestration bug—retask or serialize on that same sweep.
   - **Progress = pushed git SHA + oracle receipt**, never `"healthy"` status prose. Every writer must commit and `git push` verified progress immediately upon passing its local verification command and always before VM TTL expiry.
   - Retask on stall signals (same failing command $3\times$, exit 1 loop, or 2 failed attempts on one assumption -> write the 1-sentence shared premise and falsify it before a 3rd attempt). Destroy or stop Boat VMs only after confirming their branch/SHA is on `origin`.

### 2.2 Maxwell & `formal-spec` gates (for Lean / Kernel / ABI work)

Whenever a task adds or modifies a formal state machine in `lean/Orb/` or `crates/orb-spec/`:

1. **4-Layer Specification (`formal-spec`):**
   - **Layer 1 (Core Spec + 30-second Human Spec Brief):** Specify observable state quotients (`ObsQuotient`) and atomic rollback (`SpecM`), never copying Rust/Lean `if/else` implementation branches verbatim as `Prop`. Include in PR description: (a) 1-sentence guarantee & concrete user harm if violated, (b) explicit adapter/trust boundary & non-goals, (c) 1 positive reachable trace. Pin `(sync_commit, covered_files)`.
   - **Layer 2 (Composable `SpecBlock` footprints):** Factor orthogonal state slices (`Mission`, `Run`, `Queue`, `Lease`, `VM`, `Transport`) and discharge cross-slice frame preservation via disjoint footprints instead of $O(N^2)$ case splits.
   - **Layer 3 (Two-Sided Bug/CVE Subspecs):** Encode each audited split-brain/race bug fixed by the model as both: (a) deductive prevention (`CoreSpec -> ¬ HazardReachable`) and (b) executable mutant refutation in `lean/Orb/MutantSuite.lean` or `StatefulMutantSuite.lean` ($\ge 3$ killed mutants per spec family).
   - **Layer 4 (`MetaGateSpec` & mechanical audit):** Every boolean/action gate carries `sound`, `complete`, `posWitness`, and `negWitness`.
2. **Frozen spec before implementation fan-out:**
   - Wire and freeze the Lean signature + spec + C-ABI/WASM bindings on the wave staging branch first. Leaf Rust/TS/Swift/Kotlin workers **never** edit or weaken their own frozen Lean judge (`ControlledSpecRelaxation` requires explicit soundness + mutant survival + `writer: false` adversarial review).
3. **Required mechanical Maxwell oracle commands:**
   - Inner loop: `turbo-lean check <file.lean> --decl <Full.Name> --max-memory-mb 6144 --no-auto-worktree-link`
   - Spec tightness: `turbo-lean --json audit-spec lean/Orb/Spec.lean` -> must report `vacuous_specs == 0`, `trivial_specs == 0`, `droppable_hypotheses == []`, `horizontal_packing_warnings == []`, `0 sorryAx`.
   - Kernel verify: `turbo-lean ci-verify --project-dir lean`
   - Artifact regeneration & parity: `python3 scripts/gen_orb_kernel_unboxed.py && python3 scripts/gen_kernel_bindings.py --check` (plus fixture generators `--check` for scroll/stream/projections).
   - Project validation DAG: update/run `.sandboxed/validation.toml` (`orb_validation_dag_step`) where applicable so certifying gates require `exact_head` receipts.

### 2.3 Git, PR, Conflict-Resolution & Merge Cadence (Every Step)

At the boundary of **every** task and wave:
1. **Worker branch:** Branch off current `origin/master` as `feat/state-<wave>-<shard>`. Commit logically scoped changes (`cargo fmt --all` clean, zero secrets/logs). Push immediately (`git push -u origin feat/state-<wave>-<shard>`).
2. **Pre-PR rebase & conflict resolution:** Fetch `origin/master`; if `origin/master` advanced, rebase (or merge) onto exact `origin/master`, resolve conflicts cleanly, and re-run the shard's `verification_command` on the resolved head.
3. **Adversarial review (`writer: false`):** Dispatch an independent `opencode` (`builtin/smart`) read-only reviewer on a distinct track against the exact PR head SHA + diff. Address every concrete finding on the branch and re-verify.
4. **Integrator merge:** Open PR against `master` (`gh pr create`), wait for **all** required GitHub checks to turn green (`pending` is not green; regenerate `ios_dashboard` with pinned `xcodegen` 2.46.0 and bump mobile versions once per user-visible mobile PR per `AGENTS.md`), merge cleanly (`gh pr merge --squash` or repo convention), pull fresh `master`, refresh warm snapshot if dependencies/hubs changed, and immediately unlock dependent DAG nodes.

---

## 3. Master Audit Inventory (All 27 Implicit State Machine Families)

Every item below must be tracked in `docs/specs/state-machine-inventory.md` (created in **R0**) until its legacy competing state is deleted:

| ID | Subsystem & Exact Locations | Current Implicit Encoding | Primary Split-Brain / Race Hazard | Target Phase |
|---|---|---|---|---|
| **SM-01** | Mission Row & Health Verdicts (`src/api/mission_store/mod.rs:33-95,588-920`, `sqlite/missions.rs:753-790,1312-1475`, `sqlite/migrations.rs:1023-1030`, `control/http_util.rs:100-231`) | 11 `status` values $\times$ `awaiting_kind`, `resumable`, `paused_at`, `interrupted_at`, `terminal_reason`, `not_before`, `deferred_goal`, side table `mission_terminal_evidence`, 11 `health_verdict` strings | `list_missions` omits `mission_terminal_evidence` join; `create_mission_store` silently falls back to `InMemoryMissionStore` on DB open error; HTTP `health_verdict` diverges from `MissionRunner::check_health` | R2, R3 |
| **SM-02** | Untyped `missions.tags` Authority (`sqlite/missions.rs:1636-1661`, `mission_horizon.rs:45-105`, `disk_admission.rs:165-180`, `control/client_link.rs:1-60`) | JSON string array (`"pr-writer"`, `"pr-readonly"`, `"placement:client"`, `"superseded_by:<id>"`, `"orphaned"`, `"host-state:own"`, `disk-gib:*`) | Non-CAS read-modify-write on JSON array clobbers concurrent disk-reservation release / supersession updates and allows contradictory writer/readonly tags | R2, R3 |
| **SM-03** | Dual In-Memory Runners (`src/api/mission_runner.rs:3045-3939`, `control/actor.rs:597-663,7640-7665`, `control/hub.rs:362-400`) | `MissionRunner` (14 fields, 0 `orb_spec` calls) + `actor.rs` (~16 `running_*` locals) + `ControlState` mirrors | Substring completion (`"Mission marked as"` / `"complete_mission"` at `3857`); missing `ToolResult` wedges `active_tool_calls > 0` (`SteerBetweenTools`); `poll_completion` (`3886`) returns `mission_id` as `message_id` on panic | R3 |
| **SM-04** | Control Queue & `inflight` Tombstones (`control/control_queue.rs:127-485,620-665,714-805`, `control/types.rs:104-123`) | Single-row JSON blob debounced by string equality + `QueuedMessage.inflight` dual-meaning + RAM-only `accepted_user_message_ids` | `outbox_crash_reconcile_step` is shadow-only; RAM accepted IDs vanish on restart; whole-blob persistence races queue mutations | R2, R3 |
| **SM-05** | Prompt-Trailer Deferred Batches (`control/deferred_messages.rs:1-87`) | `<!-- sandboxed:messages:v1:<base64> -->` appended inside `missions.deferred_goal` | Unpacked only when `source == Some("scheduler")` (`73-84`); other replay paths send raw HTML comment payload to the LLM | R3 |
| **SM-06** | Asymmetric Rate-Limit Waiting (`control/usage_limit_wait.rs:1-90`) | Local -> `Pending` + `not_before` + `deferred_goal`; Remote -> `Interrupted` (`46-48`) | Divergent status, UI badge, and resume semantics for identical provider quota events | R3 |
| **SM-07** | Wakeups Multiplexed on Automations (`control/continuations.rs:1-90`, `sqlite/queue.rs:6-206`) | `automations` + `automation_executions.variables_used` JSON `__wakeup_*` keys + `mission_wakeup_fences` | Hidden coupling between user cron automations and one-shot durable mission continuations | R3 |
| **SM-08** | Cross-DB Dispatch Admission & Leases (`control/dispatch_admission.rs:1-225`, `track_leases.rs:1-90`, `projects_store.rs:280-315`) | `projects.db` + `missions.db` + 2 process mutexes + 2 `flock` files + JSON journal phases | Non-atomic cross-DB commits rely on lazy recovery and 6h TTLs after mid-flight crash | R2, R3 |
| **SM-09** | Five Reconcilers & Volatile Supervision (`reconcile.rs:280-365`, `supervision.rs:1-45`, `bg_autoresume.rs:22-40`, `control/goal.rs:10-23`) | Durable `waiting_background` vs. RAM `BackgroundTaskRegistry` & `STALL_GUARD_CONSECUTIVE_ARMS`; dual partial `reconcile_step` calls | Core restart strands `waiting_background` missions and resets consecutive stall-arm counters | R3 |
| **SM-10** | Durable Runs & Provisional Tool Claims (`sqlite/runs.rs:58-60,227-457`) | `mission_runs`, `mission_tool_executions` (`provisional|running`, 120s grace), `mission_native_prompt_*`, `"orb-client:"` prefix check | Prefix-dependent status mutation in `begin_mission_run`; multi-table liveness drift | R2, R3 |
| **SM-11** | `FrontendToolHub` Interactive Slots (`control/hub.rs:37-241`) | RAM `Waiting` (250ms ack) vs `Early` (60s TTL, 256 cap) + `"native-"` prefix bypass | Eviction under bursty tool calls; volatile slot loss across reconnect/restart | R7 |
| **SM-12** | HTTP Idempotency Guard (`src/api/idempotency.rs:80-289,433-460`) | RAM `inflight` (`Notify`, 25s -> 409) + async `Drop` `LeaderGuard` + SQLite `http_idempotency_keys` (512 KiB cap) | **Critical bug (`450-458`):** `2xx` response $> 512$ KiB after committed mutation calls `guard.complete(None)` and returns `500`, allowing duplicate mutation on retry | **R1**, R2 |
| **SM-13** | Project Decisions & Cross-DB Roadmap (`projects_store.rs:373-420`, `control/board.rs:1-145`) | Dual `answered: INTEGER` + `status: TEXT`; cross-DB union of `project_roadmap_proposals` + `mission_board_tasks` | Dual-column drift on `project_decisions`; cross-DB `task_key` shadowing | R3, R7 |
| **SM-14** | Cloud Agent Turn Protocols (`cloud_agents/grok.rs:337-424`, `hermes.rs:420-485`, `worker.rs:78-157`) | Grok branches on `Turn.detail` prose (`"reconnect_required"`, cancellation text); Hermes overloads `Turn.cursor` (`"submission:<ts>"` vs `u64`); Cursor follow-ups lack idempotency key | Localization/copy edit breaks Grok state transitions; Cursor turn $>0$ timeout locks mission in `SubmissionUncertain` without recovery flow | R4 |
| **SM-15** | Claude Code Warm Process Loop (`runners/claudecode.rs:14-115,1660-1850,3000-3035`, `live_session.rs:18-45`) | ~12 manual booleans/options + global `PARKED`/`MIDTURN`/`EFFORT`/`HARNESS_PIDS` maps | Flag reset omission across warm turns corrupts turn boundary or leaks parked child PIDs | R4 |
| **SM-16** | OpenCode SSE + CLI Dual Channel (`runners/opencode.rs:895-965,1825-1855,2382-2420`, `src/opencode/mod.rs:880-930`) | `sse_complete_seen`, `session_idle_seen`, `had_meaningful_work`, `/proc` child scan, `SseState` maps | Race between SSE sidecar idle frame and CLI stdout exit misclassifies turn completion/timeout | R4 |
| **SM-17** | Codex Continuity & Grok/Vibe Prompt Claims (`backend/codex/app_server.rs:30-145`, `continuity.rs:1-120`, `runners/grok.rs:535-615`, `vibe.rs:14-145`) | SQLite `continuity` + Codex CLI DB + `ToolCallJournal` + `SESSION_UPDATE_RUN` `task_local!` + `try_lock()` drop kill | Contended `child.try_lock()` in `Drop` skips process kill; split continuity journals require manual reconciliation | R4 |
| **SM-18** | Ask Sidecar, Midturn Notes & Inbox CAS (`ask/mod.rs:81-103,154-390,970-1089,1616-1759`, `runners/midturn.rs:8-55`, `ask/inbox.rs:103-175,275-310`) | Lazy `ASK_STORE: OnceCell`; `midturn` pre-RPC `flushed_at` + new-UUID reinsert; imperative `/tmp/ask-sandbox-*` cleanup; hybrid `inbox_state` CAS | Pre-restart `operator_notes` undrained until HTTP hit; failed midturn injection reorders/duplicates note ID; crashed Ask leaks `/tmp` worktrees | **R1**, R4 |
| **SM-19** | Managed VM Registry, Lifecycle & Providers (`src/managed/mod.rs:680-890,1351-1376,2807-2850,5936-6255`, `snapshots.rs:459-520`, `relay.rs:36-140`, `raw_operations.rs:144-200`) | 3 JSON files + leaked static maps + `registry_authoritative` + `deletable_at` + reused `node_id` across stop/resume + provider tuple synthesis | Crash between 3 JSON files desyncs reservations/secrets/machines; stop/resume reuses `node_id` without boot-epoch fence; at-most-once relay pop drops unacked command on disconnect | R5 |
| **SM-20** | Remote Node Ledger, Scratch & `nspawn` Leaders (`remote_node/job_ledger.rs:168-370`, `node/runner.rs:95-137,860-915`, `node/scratch.rs:25-155`, `durable_jobs_remote.rs:115-298`, `workspace_exec.rs:28-555`) | `DirLedger`, `TrackedJob` (`start_ticks` + `dead_since`), `(dev, ino)` scratch retirement, `submission.claim` `flock`, `/proc` scan for `nspawn` leaders | Unfenced reconnect during remote spawn leaves `Unknown`; container leader discovery depends on ambient `/proc` environment strings | R5 |
| **SM-21** | Proxy Pre-Commit, CLIProxy Diff & OAuth Sidecar (`proxy.rs:525-715,3410-4075`, `provider_health.rs:21-216`, `account_limits.rs:26-216`, `cli_proxy_login.rs:18-650`, `oauth_reconcile.rs:73-165`, `concurrency.rs:295-315`) | `first_byte_locked` + 3 health/cooldown layers + directory set-diff login + unlocked `anthropic_rotation_pending.json` + `CoalescedAsyncWriter` | **Critical bugs:** `oauth_reconcile::drain_pending` unlinks newly written rotation file across `await`; `CoalescedAsyncWriter` drops `dirty` flag on transient I/O error; concurrent CLIProxy logins misattribute accounts | **R1**, R4 |
| **SM-22** | Uploads, Workspaces, MCP Registry, Control MCP & Brokers (`uploads.rs:456-530`, `workspaces.rs:920-961`, `mcp/registry.rs:246-360,1291-1425`, `control_mcp/actions.rs:10-232,531-615`, `approvals.rs`, `secret_broker.rs`, `system.rs:3455-3614`) | Unlocked upload finalization; `ArcSwap` build check-then-set; `McpRegistry` `stdio_processes` vs `states`; `mcp_actions_v1` `reconciliation_required` | **Critical bugs:** `uploads.rs:509-529` deletes `payload.part`/`bitmap.bin` before durable `meta.json`; `workspaces.rs:920-961` TOCTOU admits duplicate builds; `mcp/registry.rs` leaves dead stdio servers `Connected` and leaks children on `tools/list` error | **R1**, R7 |
| **SM-23** | Desktop Durable Local Message Queue (`orb/src/localMessageQueue.ts:15-95,120-555`) | IndexedDB `QueuedLocalMessage` (`4` states $\times$ 14 optional flags) + tab-local `optimisticallyRemoved` + `WakeupFence` + regex `CONNECTION` retry | Tab-local `optimisticallyRemoved` diverges across multi-window/reload; composite optional flags permit unreachable/stuck combinations | R6 |
| **SM-24** | Cross-Client Follow-Up Queue & Send Flow (`orb/src/RemoteQueue.tsx:200-251`, `MissionView.tsx:858-869,1085-1280`, `CloudAgents.tsx:226-290`, `OrbSendFlow.swift:35-105`, `OrbSendFlow.kt:26-91`) | Server queue merged with client `pending`/`edits`/`hidden`/`delivered`; 3050ms handover timer; turn-count cloud retirement | **Critical bugs:** `RemoteQueue.tsx:226-244` `DELETE`s tail rows before re-POSTing (data loss on disconnect); `OrbSendFlow.kt` lacks `postedAt`/`seenAfter` guard so `"yes"`/`"continue"` prematurely retires against old turns | **R1**, R6 |
| **SM-25** | Transcript Reducer & Streaming Renderers (`orb/src/transcriptModel.ts:32-65,285-425`, `missionCache.ts:24-697`, `OrbStreamText.swift`, `OrbStreamText.kt:341-468`) | `WeakMap<StreamItem[], TranscriptReducer>`; dual `pendingReplace`+`pending` in Kotlin (legacy `dashboard/` retired in #1559) | Cloning `StreamItem[]` silently resets reducer dedup/tool state; dual Kotlin stream buffers risk out-of-order block replacement | R6 |
| **SM-26** | Sticky Client Transport & Tauri Link Latches (`orb/src/stream.ts:349,565`, `orb/src-tauri/src/client_link.rs:94,404,668`, `local_origin.rs:43,312`, `OrbClient.swift:370-423`, `OrbCore.kt:2085,2280-2285`) | 3-strike permanent mobile WS disable; desktop `everReady` WS lock; Tauri process-lifetime `unsupported` & 256-frame ring drop | Transient captive portal/restart permanently disables mobile WS or Tauri journaling until app kill; `local_origin` matches `"409"` prose | R6 |
| **SM-27** | Inbox Outbox, Dictation, FIDO & UI Overlays (`orb/src/inboxState.ts:41-91`, `NativeInteraction.tsx:26-86`, `overlayLayer.ts:6-45`, `OrbDictation.kt:95-129`, `OrbFido.kt:154-165`) | Serialized localStorage outbox (`pending` blocks `readInboxState`); unjoined `OrbDictation` thread; `OrbFido` unconditional `finally { resolve }`; flat `inerted` map | **Critical bugs:** `inboxState.ts` 409 starves `_versions` refresh; `OrbFido.kt:163` drops unanswered FIDO request on transient network error; `OrbDictation.kt:126` races shared `pcm` buffer on restart | **R1**, R6 |

---

## 4. Phased Execution DAG (`R0` -> `R8`)

```text
                       ┌──────────────────────────────────┐
                       │ R0: Executable Inventory &       │
                       │     Validation Campaign Harness  │
                       └────────┬─────────────────┬───────┘
                                │                 │
          ┌─────────────────────▼──────┐   ┌──────▼───────────────────────────┐
          │ R1: Immediate Containment  │   │ R2: Transactional State/Effect   │
          │     (10 Disjoint Bug PRs)  │   │     & Lean Kernel Foundations    │
          └─────────────────────┬──────┘   └──────┬───────────────────────────┘
                                │                 │
                                └────────┬────────┘
                                         │ (Warm Snapshot Refresh)
            ┌────────────────────────────┼────────────────────────────┬───────────────────────────┐
            ▼                            ▼                            ▼                           ▼
┌───────────────────────┐  ┌──────────────────────────┐  ┌─────────────────────────┐  ┌───────────────────────┐
│ R3: Mission, Queue,   │  │ R4: Harnesses, Cloud     │  │ R5: Managed VMs,        │  │ R6: Cross-Client      │
│     Runner & Leases   │  │     Turns, Ask & Auth    │  │     Remote Nodes & Jobs │  │     Sync & Transport  │
└───────────┬───────────┘  └─────────────┬────────────┘  └────────────┬────────────┘  └───────────┬───────────┘
            │                            │                            │                           │
            └────────────────────────────┴──────────────┬─────────────┴───────────────────────────┘
                                                        ▼
                                        ┌───────────────────────────────┐
                                        │ R7: Brokers, MCP, Paloma,     │
                                        │     Deploys & Remaining Hubs  │
                                        └───────────────┬───────────────┘
                                                        ▼
                                        ┌───────────────────────────────┐
                                        │ R8: Legacy Deletion, Full     │
                                        │     Conformance & Sign-Off    │
                                        └───────────────────────────────┘
```

---

### Phase R0 — Executable Obligation Inventory & Validation Harness

**Goal:** Turn all 27 audited implicit state machine families into tracked, machine-checked obligations and wire project-level validation gates before code fan-out.

- **Tasks (2 parallel Boat workers -> 1 merge):**
  - `R0-A` (`docs/specs/state-machine-inventory.md`): Create the canonical registry mapping `SM-01..SM-27` with columns `(id, title, canonical_owner, current_files, current_encoding, primary_hazard, lean_target_or_adapter_rationale, target_phase, status, reproducer_or_gate, closing_pr)`. Cross-link `G-ORB-1..8` from `docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md`.
  - `R0-B` (`scripts/check_state_inventory.py` + `.sandboxed/validation.toml` if absent/extended): Add a deterministic checker verifying every `SM-*` entry has valid file references and non-empty disposition, plus wave gate definitions compatible with `orb_validation_dag_step`.
- **Merge checkpoint:** Rebase, review (`writer: false`), green CI, merge R0 PR, build initial warm Boat snapshot `orb-state-<sha7>-warm`.

---

### Phase R1 — Immediate Safety Repairs (10 Parallel Disjoint Boat Shards)

**Goal:** Immediately eliminate confirmed data-loss, duplicate-mutation, orphan-process, and wedged-UI bugs in small, independent PRs without waiting on R2–R7 refactors.

All 10 shards below touch **disjoint file footprints** and can run concurrently on `boat:large` workers from `orb-state-<sha7>-warm` (merged sequentially or in small batches as each turns green):

| Shard | Owned Files | Repair Contract | Required Failing-Before / Passing-After Regression |
|---|---|---|---|
| **R1-01** (`SM-12`) | `src/api/idempotency.rs` | Never call `guard.complete(None)` after a committed `2xx` handler response exceeds `MAX_BODY_BYTES` (`450-458`). Persist a durable `committed_oversize` sentinel + status/hash (or stream-safe receipt) so retries return deterministic `409/202` or stored receipt metadata instead of re-executing the POST. | Handler increments counter once and returns 600 KiB `200 OK`; retry with same `Idempotency-Key` does **not** increment counter a second time. |
| **R1-02** (`SM-21a`) | `src/api/oauth_reconcile.rs` | Replace unlocked read -> `await` -> unconditional `remove_file` (`73-93,148-165`) with generation/UUID-tagged rotation records under `flock` (or SQLite table) so `drain_pending` deletes/marks only the exact generation(s) durably applied. | Inject concurrent `record_pending_rotation(gen=2)` while `drain_pending(gen=1)` awaits store write; `gen=2` survives and reconciles on next pass. |
| **R1-03** (`SM-21b`) | `src/concurrency.rs`, `src/account_limits.rs` | Fix `CoalescedAsyncWriter` (`295-315`) so `dirty` / `flushed_seq` advances **only** after `fsync`+rename succeeds, retains dirty state with bounded backoff on transient error, and never silently drops flushes outside Tokio. | Simulated write failure preserves dirty generation and flushes cleanly on next trigger. |
| **R1-04** (`SM-22a`) | `src/uploads.rs` | Add per-session finalization mutex/`flock` in `complete_session` (`509-529`); atomically stage/rename final payload and `fsync`-write `meta.json` (`completed`) **before** unlinking `payload.part` and `bitmap.bin`; recover idempotently if already finalized. | Fault injection before `meta.json` commit + retry completes upload without `"received 0/N chunks"`; concurrent `complete` calls return identical receipt. |
| **R1-05** (`SM-22b`) | `src/api/workspaces.rs` | Replace `ArcSwap` read-check-write TOCTOU in workspace build admission (`920-961`) with a single mutex/CAS build-generation claim + cross-process lock guard. | Two simultaneous `POST /api/workspaces/:id/build` calls admit exactly 1 build and reject the second with `409`. |
| **R1-06** (`SM-22c`) | `src/mcp/registry.rs` | On unexpected stdio child exit (`246-360`), transition `states[id]` to `Disconnected`/`Error` if the exiting process matches the active generation; in `refresh_stdio` (`1317-1375`), kill and remove `stdio_processes[id]` when `tools/list` or parse fails. | Killed MCP child updates status immediately; failing `tools/list` leaves 0 orphan child processes and 0 stale `stdio_processes` entries. |
| **R1-07** (`SM-18a`) | `src/api/ask/mod.rs`, `src/api/runners/midturn.rs` | Eagerly initialize `ASK_STORE` on Core startup (`ask/mod.rs:81-103`) and add startup GC for orphaned `/tmp/ask-sandbox-*` worktrees; in `midturn.rs:8-55`, mark `flushed_at` **after** confirmed injection (preserving original note UUID/timestamp on failure). | Pre-restart queued `operator_notes` drain on first runner turn without prior HTTP Ask hit; failed RPC injection preserves note ID and ordering. |
| **R1-08** (`SM-24a`) | `src/api/control/` (atomic queue edit endpoint), `orb/src/RemoteQueue.tsx`, `ios_dashboard/.../OrbSendFlow.swift`, `android_dashboard/.../OrbSendFlow.kt` | Add/wire atomic server-side in-place queue edit/reorder with revision check so `RemoteQueue.tsx:226-244` never `DELETE`s trailing rows before re-sending; port `postedAt`/`seenAfter` sequence guard to `OrbSendFlow.kt:26-91` for iOS/Android parity. | Network drop mid-edit loses 0 trailing queued messages; sending `"yes"` on Android while history already contains `"yes"` keeps row pending until a post-send turn arrives (shared fixture). |
| **R1-09** (`SM-27a`) | `orb/src/inboxState.ts` | Decouple authoritative `readInboxState()` `_versions` refresh from non-conflicting outbox retries; on `409`, refresh `_versions` and rebase/resolve per entry instead of permanently starving `readInboxState()`. | Forced `409` on one preference/seen entry refreshes `_versions` and converges on next cycle without blocking reads. |
| **R1-10** (`SM-27b`) | `android_dashboard/.../OrbFido.kt`, `android_dashboard/.../OrbDictation.kt` (plus iOS parity check) | In `OrbFido.kt:154-165`, call `resolve(requestId)` only on `2xx` or terminal `404/410` (keep prompt retryable on network/5xx error); in `OrbDictation.kt:95-129`, allocate per-session `ByteArrayOutputStream` + generation token and `join` worker thread on `cancel()`. | Offline FIDO tap keeps approval card actionable for retry; rapid cancel+restart dictation never interleaves audio bytes. |

- **Maxwell / CI Gate for R1:** Every R1 PR includes its deterministic regression test, passes `cargo fmt --check`, `cargo clippy --locked --workspace -- -D clippy::all`, targeted + workspace tests, `orb` vitest/playwright or Android/iOS unit tests as applicable, merges cleanly to `master`, and updates `docs/specs/state-machine-inventory.md`.

---

### Phase R2 — Transactional State/Effect & Lean Kernel Foundations

**Goal:** Build the reusable Rust + SQLite + Lean primitives so phases R3–R7 compose one small set of verified abstractions rather than inventing 20 new bespoke schemas.

- **DAG Shards:**
  - **R2-A (Lean Kernel & Spec Primitives — Maxwell Gate):**
    - Audit existing 162 public exports in `lean/Orb/Kernel.lean` & `lean/Orb/Spec.lean` first (`102 partial / 61 unconnected` in `coverage_evidence.json`) so existing gates are wired before adding new ones.
    - Define composable `SpecBlock` footprints and pure unboxed/slice steppers for:
      1. `EpochFence` (`(owner_epoch, run_generation, node_boot_epoch, state_revision)` monotone CAS & stale-actor rejection).
      2. `EffectOutboxStep` (`Planned -> Claimed -> Accepted | RejectedPreCommit | Uncertain -> Reconciled`, proving `StickyFence` no-fresh-retry-on-uncertain and conservation).
      3. Fix `G-ORB-2` & `G-ORB-5` (`docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md:206,209`): strengthen single-step assumptions into persistent+volatile crash-boundary invariants and remove circular shadow post-state comparisons.
    - **Maxwell oracle:** `turbo-lean --json audit-spec lean/Orb/Spec.lean` (`0 vacuous`, `0 trivial`, `0 horizontal_packing_warnings`, `0 sorryAx`), $\ge 3$ killed mutants per new/updated family in `MutantSuite.lean` / `StatefulMutantSuite.lean`, `gen_orb_kernel_unboxed.py`, `gen_kernel_bindings.py --check`, WASM rebuild (`orb_kernel.wasm`).
  - **R2-B (Typed SQLite Columns & Fail-Closed Store Bootstrap — depends on R2-A):**
    - Add additive SQLite migrations replacing magic correctness tags in `missions.tags` (`SM-02`) with typed columns + `state_revision`: `authority_mode` (`readonly | writer`), `placement_kind`, `superseded_by_mission_id`, `orphaned_at`, `reserved_disk_gib`. Keep `tags` strictly as a read-compatibility projection during R3–R7.
    - Remove silent `InMemoryMissionStore` fallback in `create_mission_store` (`sqlite/migrations.rs:1023-1030`, `SM-01`): fail closed on persistent store open/migration failure unless explicit `Memory` test config is requested.
  - **R2-C (Durable Effect Outbox & Cross-DB Lease Protocol — depends on R2-A, parallel with R2-B):**
    - Provide one reusable SQLite transactional `commit_transition_with_intents(expected_rev, next_state, intents)` helper in `mission_store` and unify cross-DB (`missions.db` $\leftrightarrow$ `projects.db`) writer/track admission (`SM-08`) around a durable two-phase reservation row with deterministic startup recovery (replacing reliance on ambient process mutexes + 6h TTL expiry).
- **Merge checkpoint:** Merge R2-A -> (R2-B, R2-C), rebase, verify all CI checks, refresh warm Boat snapshot `orb-state-<sha7>-warm`.

---

### Phase R3 — Unify Mission Execution, Queue, Continuations & Supervision

**Goal:** Eliminate the dual-runner split-brain (`MissionRunner` vs `actor.rs` vs `ControlState`) and make every mission/run/queue/wakeup transition flow through authoritative Lean steppers + R2 CAS transactions.

- **DAG Shards (fanned out from R2 snapshot):**
  - **R3-A (Lean Mission/Run/Queue/Cancel/Continuation Composition — Maxwell Gate):**
    - Formalize coordinated orthogonal slices (`MissionLifecycle`, `RunLifecycle`, `QueueItemLifecycle`, `CancelProtocol`, `WakeupContinuation`) in `lean/Orb/`.
    - Prove: completed runs never re-enter `Running` without `run_generation + 1`; acknowledged queue items cannot replay; `CancelRequested` never transitions to `Cancelled` until runner/provider termination receipt; superseded owners cannot claim runs.
  - **R3-B (Single Runner Coordinator & Authoritative `orb_spec` Wiring — depends on R3-A):**
    - Collapse duplicate lifecycle state between `src/api/mission_runner.rs` (`0` `orb_spec` calls today) and `src/api/control/actor.rs` (`running_*` locals) into **one** authoritative `RunCoordinator` state machine backed by R3-A.
    - Replace substring completion detection (`"Mission marked as"` / `"complete_mission"`, `mission_runner.rs:3857`) with structured tool-execution receipts.
    - Fix `poll_completion` (`3886`) panic-path tuple return (`message_id` vs `mission_id`), bound `active_tool_calls` reconciliation when a harness omits a `ToolResult`, and turn `ControlState` (`hub.rs`) into a pure read projection.
  - **R3-C (Transactional Queue, Structured Deferred Batches & Unified Rate-Limit Wait — depends on R3-A):**
    - Promote `control_queue` (`SM-04`) from whole-JSON string-debounced snapshots + RAM `accepted_user_message_ids` to row-level transactional queue entries (`Queued | Claimed(run_gen) | Delivered(seq) | CrashTombstone`) with authoritative `orb_queue_step` / `outbox_crash_reconcile_step`.
    - Replace HTML comment prompt trailers (`<!-- sandboxed:messages:v1:... -->`, `SM-05`) with a structured SQLite deferred-batch table unpacked uniformly regardless of `source`.
    - Unify local vs. remote provider rate-limit parking (`SM-06`, `usage_limit_wait.rs`) onto one semantic `WaitingRateLimit { not_before, resume_intent }` state.
  - **R3-D (Explicit Wakeups, Unified Reconciler & Normalized Store Projections — depends on R3-A):**
    - Extract one-shot mission wakeups (`SM-07`) out of magic `$.__wakeup_*` JSON keys in `automation_executions` into explicit typed `mission_continuations` rows with `run_generation` fencing.
    - Consolidate the 5 overlapping reconcilers + HTTP `health_verdict` (`SM-01`, `SM-09`) onto one canonical Lean-backed health/reconcile derivation; persist `BackgroundTaskRegistry` (`bg_autoresume.rs`) and `STALL_GUARD_CONSECUTIVE_ARMS` (`goal.rs`) in SQLite so Core restarts never strand `waiting_background` missions.
    - Join `mission_terminal_evidence` consistently in `list_missions` and `get_mission` (`SM-01`), remove client-prefix status branching in `begin_mission_run` (`SM-10`), and normalize `project_decisions` (`answered` derived from `status`, `SM-13`).
- **Merge checkpoint:** Each shard lands with concurrency + crash-between-claim-and-spawn tests, adversarial review, green CI, and snapshot refresh.

---

### Phase R4 — Harnesses, Cloud Agents, Ask Sidecar & Auth/Proxy Protocols

**Goal:** Replace brittle prose-matching, overloaded cursors, and 12-boolean harness loops with typed session/turn state machines and generation-fenced credential handling.

- **DAG Shards (parallel across `boat:large` workers after R2; integrates cleanly with R3):**
  - **R4-A (Lean Provider Attempt, Cloud Submission & Harness Session Specs — Maxwell Gate):**
    - Extend `orb_proxy_step`, `orb_breaker_step`, and `orb_auth_refresh_step` with typed cloud-turn submission/cancellation steppers (`Queued -> Submitting(ts) -> Running(provider_id, cursor) | WaitingApproval(req_id) | Uncertain(attempt_id) -> CancelRequested -> Terminal`) and harness warm-session state (`Starting -> Ready -> InTurn(tool_depth, steer_pending) -> Parked -> Terminating -> Dead`).
  - **R4-B (Cloud Agents Refactor: Grok, Hermes, Cursor Cloud — `SM-14`, depends on R4-A):**
    - `cloud_agents/grok.rs:337-424`: Replace `Turn.detail` human-prose branching (`"reconnect_required"`, `"Cancellation sent..."`) with typed `TurnPhase` / `SubmissionErrorKind` / `CancelState` fields.
    - `cloud_agents/hermes.rs:420-485`: Split overloaded `Turn.cursor` (`"submission:<ts>"` vs `u64` offset) into `submitted_at_ms: Option<i64>` + `event_cursor: Option<u64>`, and lift `WaitingUser` approvals out of untyped `artifacts` JSON.
    - `cloud_agents/worker.rs:78-157`: Add explicit operator/controller reconciliation actions (`inspect_provider_turns`, `confirm_not_delivered_retry`, `bind_existing_turn`) for Cursor Cloud follow-up `SubmissionUncertain` turns so missions never deadlock permanently.
  - **R4-C (Claude Code, OpenCode, Codex, Grok & Vibe Session Registry — `SM-15, SM-16, SM-17`, depends on R4-A):**
    - Replace scattered `PARKED`/`MIDTURN`/`EFFORT`/`HARNESS_PIDS` maps (`live_session.rs`) and Claude's 12 manual turn booleans (`claudecode.rs`) with a single generation-owned `HarnessSessionHandle` per active run.
    - Unify OpenCode SSE sidecar + CLI process exit coordination (`opencode.rs`) via typed events into the R4-A session stepper.
    - Fix `AppServerSession::drop` (`backend/codex/app_server.rs`) so process teardown never silently skips kill when `child.try_lock()` is contended (use dedicated kill handle / PID-tick reaper), and formalize `(session_id, prompt_claim, tool_journal)` reconciliation across Codex/Grok/Vibe.
  - **R4-D (Proxy Commitment, Account Cooldowns & Attempt-Bound CLIProxy Login — `SM-21`, depends on R4-A):**
    - Bind `cli_proxy_login.rs` auth discovery to an explicit login-attempt nonce/session directory rather than ambient `CLI_PROXY_AUTH_DIR` set-diffing against `previous_accounts`.
    - Consolidate the 3 overlapping health/cooldown trackers (`proxy.rs`, `provider_health.rs`, `account_limits.rs`) behind authoritative `orb_proxy_step` + `orb_breaker_step` + `orb_account_cooldown_secs`.
- **Merge checkpoint:** Replay duplicate/reordered/dropped SSE & cloud-turn traces, verify `scripts/harness_contract_tests.sh`, review, merge to `master`.

---

### Phase R5 — Managed Compute, Remote Nodes & Container Execution

**Goal:** Make VM provisioning, stop/resume boot epochs, remote job claims, and container leaders crash-recoverable and immune to stale-boot / orphan-reap races.

- **DAG Shards (parallel with R4 after R2):**
  - **R5-A (Lean VM Lifecycle, Boot-Epoch & Remote Job Ledger Extensions — Maxwell Gate):**
    - Extend `orb_vm_lifecycle_step`, `orb_vm_claim_step`, `orb_verify_remote_outbox`, `orb_job_ledger_step`, and `orb_proc_liveness_step` to incorporate `node_boot_epoch` (incremented on every VM `resume` or replacement), `deletable_at` minimum-lease retention vs. active-compute eligibility, and relay command ack fencing.
  - **R5-B (Transactional Managed VM Store & Provider Observation Adapters — `SM-19`, depends on R5-A):**
    - Replace multi-file JSON desync across `managed_machines.json` + `managed_dispatch_reservations.json` + leaked static `NODES`/`TOKENS` maps with one transactional SQLite authority (`managed_compute.db` or `missions.db` tables) while keeping encrypted provider credentials confined in `0600` AES-256-GCM storage (`CoreReserved`).
    - Increment `node_boot_epoch` on every `stop -> resume` cycle so delayed frames or zombie jobs from a pre-stop boot cannot mutate current runs.
    - Replace destructive pop-before-ack in `managed/relay.rs:36-140` with leased delivery + explicit guest ack (`raw_operations.rs` `Pending -> Accepted | Uncertain`).
    - Restrict provider adapters (`boat`, `leanci`, `hetzner`, `vastai`, `scaleway`, `colab`) to emitting pure `ProviderObservation` records; only the R5-A reducer closes cost ledgers or marks orphans.
  - **R5-C (Remote Node Durable Claims, Scratch Retirement & `nspawn` Leader Registry — `SM-20`, depends on R5-A):**
    - Unify `remote_node/job_ledger.rs`, `node/runner.rs`, and `durable_jobs_remote.rs` around durable pre-launch claims keyed by `(operation_id, node_boot_epoch)` and `(pid, start_ticks)` verification before ` SIGTERM/SIGKILL`.
    - Persist container leader `(workspace_id, machine_name, leader_pid, start_ticks)` in a local runtime ledger (`workspace_exec.rs`) verified via `orb_proc_liveness_step` instead of discovering leaders solely by scanning `/proc/*/environ`.
- **Merge checkpoint:** Fault-inject provider create timeouts, Core restarts mid-enrollment, stop/resume with identical `node_id`, and PID reuse; review and merge to `master`.

---

### Phase R6 — Cross-Client Reconciliation, Transport & Shared WASM/C-ABI Projections

**Goal:** Converge Orb Desktop (`orb/`), Tauri (`orb/src-tauri/`), iOS (`ios_dashboard/`), and Android (`android_dashboard/`) onto single-owner state models backed by shared Lean kernel exports and cross-platform fixtures in `shared/orb-spec/fixtures/` (note: legacy Next.js `dashboard/` was retired on `master` in #1559).

- **DAG Shards (parallel after R1 + R2):**
  - **R6-A (Lean Client Queue, Transport Epoch & Transcript Fold Specs + `P2` WASM Dedup — Maxwell Gate):**
    - Complete `G-ORB-1`, `G-ORB-3`, `G-ORB-6`, and `G-ORB-8` (`docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md:205-212`):
      1. Ensure `orb/src/orbKernel.ts` has zero handwritten behavioral duplicates of `orb_kernel.wasm` exports.
      2. Add pure Lean steppers + shared JSON fixtures (`shared/orb-spec/fixtures/`) for **Follow-Up Queue Reconciliation** (server revision + optimistic `(client_msg_id, posted_after_seq)` retirement) and **Connection Transport Epoch** (WS failure streak -> SSE fallback with `since_seq` preservation + cooldown WS reprobe, distinguishing transient network failure from permanent `404/501` unsupported protocol).
      3. Add checkpointed open-fence tail cap (`G-ORB-6`) so giant unclosed code fences stay $O(1)$ per frame.
  - **R6-B (Desktop & Tauri Local Queue + Client-Link Journal Recovery — `SM-23, SM-26`, depends on R6-A):**
    - Refactor `orb/src/localMessageQueue.ts` (`QueuedLocalMessage`) from 14 coupled optional flags + tab-local `optimisticallyRemoved` into an explicit discriminated union persisted in IndexedDB with cross-tab lock/broadcast fencing; remove `3050ms` magic `queueHandover` timer (`MissionView.tsx:858-869`) and turn-count cloud retirement (`CloudAgents.tsx:226-234`) in favor of `client_msg_id` receipts.
    - Fix `orb/src/stream.ts:565` so WS drops after `everReady === true` can fall back to cursor-preserving SSE and reprobe WS.
    - Fix `orb/src-tauri/src/client_link.rs` (`404,668`) & `local_origin.rs` (`43`): scope `unsupported` to `(endpoint, server_build)` rather than process lifetime, replace silent 256-frame `outbound` ring eviction with explicit backpressure + resync handshake, and replace `"409"` string-prefix matching with typed error codes.
  - **R6-C (iOS & Android Parity: Transport Reprobe, Queue Fixtures & Stream Reducer — `SM-24, SM-25, SM-26`, depends on R6-A):**
    - Ship iOS + Android in lockstep (`AGENTS.md` feature-parity & single version bump rule + `xcodegen` 2.46.0 check):
      - Replace permanent session-long 3-strike WS disable (`OrbClient.swift:370-423`, `OrbCore.kt:2085,2280-2285`) with the R6-A cooldown reprobe stepper.
      - Wire `OrbSendFlow.swift` and `OrbSendFlow.kt` against the shared R6-A queue-reconciliation fixture suite.
      - Collapse `OrbStreamText.kt`'s dual `pendingReplace` + `pending` buffers into one canonical state transitions tested against `stream-commit.json` and `stream-cost.json`.
  - **R6-D (Transcript Identity, Native Prompts & UI Overlays — `SM-25, SM-27`, depends on R6-A):**
    - Key `TranscriptReducer` (`orb/src/transcriptModel.ts:32`) by stable conversation/session key rather than `WeakMap<StreamItem[], ...>` array reference identity.
    - Persist answered native-interaction IDs per `(mission_id, tool_call_id)` (`NativeInteraction.tsx:40`) and make `overlayLayer.ts` (`inerted`) stack/ref-counted across nested modals (`tests/overlays.html` + `playwright.overlays.config.ts`).
- **Merge checkpoint:** Run `orb` (`pnpm build && pnpm test && pnpm test:browser`), Android (`./gradlew :app:testDebugUnitTest :app:assembleDebug`), and iOS checks (or document `BLOCKED_HOST_UNREACHABLE` / CI Xcode check honestly if running on Linux Boat workers, letting GitHub Actions macOS CI gate the PR before merge).

---

### Phase R7 — Remaining Hubs, Brokers, MCP, Paloma & Deploys

**Goal:** Close all remaining secondary state machines using R2's epoch-fencing and durable-intent primitives.

- **DAG Shards (parallel `boat:large` workers after R2–R5):**
  - **R7-A (`FrontendToolHub` & Grok Tool Bridge — `SM-11`):** Replace silent 256-entry `Early` eviction and `"native-"` string bypass in `control/hub.rs` with bounded Run-scoped tool-slot state + explicit backpressure; add session-epoch & request-id deduplication to `grok_tool_bridge/registry.rs`.
  - **R7-B (Control MCP Receipts & External MCP Session Lifecycle — `SM-22`):** Separate `receipt_settled` (`wait_actions` wake condition) from `action_outcome` (`Accepted | Rejected | UncertainReconciliationRequired`) in `src/control_mcp/actions.rs` so callers never mistake `reconciliation_required` for success; complete generation-fenced reconnect & health transitions in `src/mcp/registry.rs`.
  - **R7-C (Approvals, Secret/Privilege Brokers & Governed Deploys — `SM-22`):** Ensure `approvals.rs`, `secret_broker.rs`, `privilege_broker.rs` (`orb_privilege_step`, `orb_bunker_step`), and `system.rs` (`run_deploy`, `orb_deploy_gate_step`) bind `observe -> gate -> execute` (`G-ORB-7`) to fresh lease tokens verified at execution time with durable rollback receipts.
  - **R7-D (Paloma Planner, Controllers & Cross-DB Board Convergence — `SM-13`):** Unify `project_roadmap_proposals` (`projects.db`) and `mission_board_tasks` (`missions.db`) behind explicit canonical track/attempt references (`docs/AGENT_CONTROL_PLANE.md`) and fence Paloma digest/planner cooldown claims durably in SQLite.
- **Merge checkpoint:** Rebase, review, green CI, merge all R7 PRs.

---

### Phase R8 — Legacy Deletion, Coverage Evidence Promotion & Final Qualification

**Goal:** Delete obsolete shadow/legacy state paths, verify zero remaining unowned implicit state machines, and produce honest repository-wide conformance receipts.

- **Tasks:**
  1. **Delete legacy dual-writes & dead flags (`AGENTS.md` Principle 1 — delete code instead of keeping second paths):**
     - Remove legacy `missions.tags` authority readers once all callers read typed R2 columns.
     - Remove legacy HTML `<!-- sandboxed:messages:v1:... -->` trailer writer, legacy `actor.rs` duplicate runner locals, string-matched Grok `Turn.detail` branches, and dead compatibility shims.
  2. **Promote `shared/orb-spec/coverage_evidence.json` & inventory closure:**
     - Update `coverage_evidence.json` and `docs/specs/state-machine-inventory.md` so every `SM-01..SM-27` row is `COMPLETED` with exact closing commit/PR SHA, authoritative production caller link, proof declaration, mutant-kill receipt, and integration test.
  3. **Full end-to-end validation sweep on `boat:xlarge`:**
     - `turbo-lean --json audit-spec lean/Orb/Spec.lean` (`0 vacuous`, `0 trivial`, `0 sorryAx`, `horizontal_packing_warnings == []`)
     - `turbo-lean ci-verify --project-dir lean`
     - `python3 scripts/gen_orb_kernel_unboxed.py && python3 scripts/gen_kernel_bindings.py --check`
     - `cargo fmt --all -- --check`
     - `cargo clippy --locked --workspace -- -D clippy::all`
     - `cargo test --locked --workspace`
     - `scripts/harness_contract_tests.sh && scripts/check-capability-matrix.sh`
     - `(cd orb && pnpm install --frozen-lockfile && pnpm build && pnpm test && pnpm test:browser)`
     - Android unit + debug assemble (`./gradlew :app:testDebugUnitTest :app:assembleDebug`) and GitHub Actions iOS build/test green on exact `master` HEAD (preserving honest `BLOCKED_PHYSICAL_DEVICE` notes where physical hardware is unattached).
  4. **Fleet cleanup:** Destroy all remaining campaign Boat VMs (`destroy_managed_machine`) and prune temporary snapshots once `master` is merged and green.

---

## 5. Summary of Exit Criteria (Definition of Done)

The campaign is complete **only** when all of the following hold simultaneously on `origin/master`:

1. **100% of `SM-01..SM-27` closed:** Every implicit state machine and split-brain/race bug cataloged in §3 has merged to `master` with a deterministic regression test and zero remaining competing state owners.
2. **Authoritative formalization where pure decisions exist:** All pure protocol/lifecycle steppers live in `lean/Orb/` (`0 import Lean`, `0 sorryAx`), pass `turbo-lean --json audit-spec` with zero warnings/vacuity, kill $\ge 3$ mutants per spec family, compile cleanly to `liborb_spec_cabi.a` and `orb_kernel.wasm`, and are called **authoritatively** (not shadow-only) by Rust and client adapters.
3. **Durable fenced effects everywhere else:** Every external side effect commits its claim/intent via revision/epoch CAS before execution and records ambiguous delivery as `Uncertain` / `reconciliation_required` rather than silently re-running under a new identity.
4. **Clean `master` & zero orphaned compute:** Every wave PR has been rebased, conflict-resolved, independently reviewed (`writer: false`, `opencode` + `builtin/smart`), and merged with 100% green CI, and `list_managed_machines` shows zero leftover campaign VMs.
