# sandboxed.sh — guide for coding agents

Read this file before changing the repository. For runtime incidents on a
deployed instance, read [DEBUGGING.md](DEBUGGING.md) first: debug on the
server, not locally.

## Principles

These come first. When a change trades one of them away, say so in the PR.

1. **Simplicity and reliability before features.** Prefer the smallest change
   that is obviously correct. Delete code instead of adding a flag, a second
   path, or a special case. If a fix needs a workaround, find the cause first.
2. **One good abstraction over copies.** Before adding a component, store,
   parser or service, look for the existing one and extend it. A behaviour
   implemented twice (two parsers for the same markup, two ways to merge a
   mission, two approval flows) is a bug waiting to happen. Shared logic
   lives in one place per platform, with the same name and the same tests.
3. **State has one owner.** Each piece of client state has a single source of
   truth and a single merge function. A partial, empty or failed response
   never erases data it does not own; removal comes from an explicit event.
4. **Specs before tricky fixes.** For behaviour that has regressed before
   (sidebar hierarchy, streaming, overlays, Inbox), write or update the spec
   in `docs/` and add a test that replays the failing order of events.
5. **Security is not a follow-up.** Never log prompts or secrets, sanitize
   anything rendered from agent output, and keep authorization checks in Core.
   Fix review findings before merging.

## Clients: desktop, iOS, Android

### Feature parity

- **iOS and Android stay at feature parity.** A user-visible feature or fix on
  one ships on the other in the same PR, or in a follow-up PR opened at the
  same time and linked from the first. If a platform genuinely cannot do it,
  write why in the PR.
- **Mobile tracks desktop.** Aim for the same features as Orb desktop,
  adapted to the platform's UX (sheets instead of side panels, long-press
  instead of hover, share sheet instead of file dialogs), not copied pixel for
  pixel. When a desktop feature lands without mobile, note the gap in the PR.
- Platform code mirrors the shared model: when desktop adds a model in
  `orb/src` (for example a parser or a state derivation), the iOS
  (`ios_dashboard/SandboxedDashboard/Orb`) and Android
  (`android_dashboard`) versions use the same names, cases and test fixtures.
  Shared fixtures live in `shared/orb-spec/`.

### UX and performance

The app must feel instant and calm. Treat these as requirements, not polish:

- **No unnecessary redraws.** Use fine-grained updates; never replace a whole
  list or transcript when one row changed. Timers, clocks and streaming text
  update only the nodes that show them. Memoize expensive renders (markdown,
  diagrams, code highlighting) by content.
- **Optimistic feedback where it is safe.** Create, move, archive, destroy,
  send: update the UI immediately, reconcile with the server, and roll back
  visibly with an inline error and Retry on failure. Do not optimistic-update
  anything irreversible that the server may refuse for security reasons.
- **Skeletons, not spinners or blank screens**, for content that is loading,
  sized like the final content so nothing jumps.
- **No layout jumps.** Keep scroll position across updates, never scroll the
  user somewhere they did not ask to go, and reserve space for content that
  will arrive.
- **Lazy-load heavy dependencies** (renderers, viewers) and keep startup and
  transcript open time flat. Measure before and after a performance change
  (trace, frame timings, or a browser test assertion) and put the numbers in
  the PR.
- Check light and dark mode, large text sizes on mobile, and keyboard use on
  desktop.

### Mobile releases

Every change under `ios_dashboard/` or `android_dashboard/` that users can see
ships to testers:

- **iOS:** bump `CURRENT_PROJECT_VERSION` (format `YYYYMMDDNN`) in
  `ios_dashboard/project.yml`, and **always bump `MARKETING_VERSION` (e.g.
  `1.7.0` -> `1.8.0`) when releasing a feature or big change** so it visibly
  surfaces as a new version train in TestFlight instead of staying under the
  old version number. Run `xcodegen generate` (or update `project.pbxproj` in
  lockstep) so the project stays in sync (the iOS Build job checks it). Merging
  to `master` triggers Xcode Cloud, which uploads to TestFlight; confirm the
  build reaches `VALID`. `ios_dashboard/scripts/testflight-local.sh` uploads
  from a Mac when Xcode Cloud is unavailable.
- **Android:** bump `orbVersionCode` (and always bump `orbVersionName` for a
  feature or big change) in `android_dashboard/gradle.properties`. Keep
  `orbVersionName` aligned with the iOS `MARKETING_VERSION`.
- One version bump per PR is enough; do not bump in every commit.

## Repository map

| Path | What it is |
| --- | --- |
| `src/`, `crates/orb-spec/` | Rust backend (`sandboxed-sh` API server, `sandboxed-node` remote runner, MCP binaries in `src/bin/`, `crates/orb-spec` standalone leaf crate & `src/orb_spec.rs` typed C-ABI bindings) |
| `lean/Orb/Kernel.lean`, `lean/Orb/Spec.lean` | Formal Lean 4 orchestration, proxy, mission lifecycle & cross-client projection kernel (`0 import Lean`, `0 sorryAx`, <!-- inventory:orb_spec_summary -->53/53 tight specs, 34 C-ABI exports<!-- /inventory:orb_spec_summary --> compiled to `liborb_spec_cabi.a` with zero hand-written C fallback) |
| `orb/` | Orb desktop client: SolidJS + Vite in `orb/src`, Tauri v2 shell in `orb/src-tauri` |
| `ios_dashboard/` | iOS app (SwiftUI, generated with XcodeGen from `project.yml`); the Orb UI lives in `SandboxedDashboard/Orb` |
| `dashboard/` | Next.js web dashboard (admin console, served by the Docker image) |
| `docs-site/` | Nextra documentation site |
| `android_dashboard/` | Android app |
| `shared/` | Rust sources included by both the backend and `orb/src-tauri` via `#[path]` |
| `catalog/`, `capabilities/` | Model catalog snapshots (compiled in by `build.rs`) and the capability matrix checked in CI |
| `scripts/`, `deploy/`, `docker/` | Operational scripts (some are embedded with `include_str!`), systemd units, Docker entrypoint |
| `docs/` | Reference documentation; `docs/archive/` holds design history |

## Build and test before pushing

CI runs all of these; run the ones for the area you touched.

```bash
cargo fmt --all                                   # CI fails on unformatted Rust
cargo clippy --locked --workspace -- -D clippy::all
cargo test --locked --workspace
scripts/harness_contract_tests.sh
scripts/check-capability-matrix.sh
(cd orb && pnpm install --frozen-lockfile && pnpm build && pnpm test && pnpm test:browser)
(cd dashboard && bun install --frozen-lockfile && bun run test:unit && bun run build)
```

CI enforces formatting (`cargo fmt --check`); run it before pushing.

For mobile changes, also run the iOS unit tests (`xcodebuild test` on the
`SandboxedDashboard` scheme with a simulator) and `./gradlew :app:testDebugUnitTest
:app:assembleDebug` in `android_dashboard/`. Boot simulators or emulators only
for the check and shut them down afterwards.

## Execution architecture

This document describes how Sandboxed.sh executes missions after the per-workspace
harness refactor. The core change: **agent harnesses run inside
the target workspace**, so native bash and file effects are scoped to the correct
environment. The host proxy bash tools are no longer required for normal
missions.

## Local build resource budget

- On Thomas's Mac, prefer dev/debug builds for routine development and
  validation. Use release builds only when the task requires a release artifact
  or measuring optimized runtime behaviour; explain that need before starting.
  The workspace backend deploy rule remains stricter: use debug builds.
- Before starting a heavy Rust build/test or native app build, check for active
  builds across **all worktrees**, not just this checkout. Run one heavy build
  at a time on this 16 GB Mac. Wait for an existing build; do not terminate
  another agent's work or silently offload it remotely.
- Use `cargo check -j 1` for compile-only feedback and targeted
  `cargo test -j 1 --lib <filter>` or `--bin <name>` when execution is needed.
  Run required validation, but avoid duplicate full-workspace builds.
  `-- --test-threads=1` limits test execution, **not compilation**; use `-j 1`
  to limit Cargo build concurrency. A single large rustc process can still
  consume several GB, so this does not replace cross-worktree serialization.
- For routine local validation without debugger requirements, prefer consistent
  `CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0` settings to reduce
  debug-symbol overhead. Preserve symbols when needed for debugging/profiling.
  Changing profile settings can rebuild dependencies: do not alternate settings
  or change a running task's environment in an attempt to recover memory.
- Reuse the checkout's existing build cache. Avoid `cargo clean`, gratuitous
  new target directories, and parallel builds merely to bypass Cargo's lock.
  If memory pressure/swapping is high, defer new heavy builds and report which
  task is holding resources. Keep build ownership and command visible in updates.

## High-level flow

1. User creates a mission with a workspace + agent (backend).
2. Sandboxed.sh prepares a **per-mission workspace directory** and syncs Library
   content (skills/tools/rules).
3. Sandboxed.sh writes **per-workspace config files** (`opencode.json`,
   `.opencode/opencode.json`, `.claude/settings.local.json`, `CLAUDE.md`).
4. The mission runner launches the chosen harness **inside the workspace** using
   a workspace-aware execution layer (host or container).
5. The harness streams JSON events; Sandboxed.sh converts these into a unified
   event stream for the UI.

## Execution model (per-workspace)

Sandboxed.sh uses a workspace execution layer to spawn processes in the correct
execution context:

- **Host workspace**: process runs directly on the host with the mission working
  directory as `cwd`.
- **Container workspace**: process runs inside the container via
  `systemd-nspawn`. This guarantees that built-in bash (OpenCode `bash` / Claude
  Code `Bash`) executes **inside the workspace**. File creation, git operations,
  and shell commands land in the correct workspace without a host-proxy tool.

## Harnesses

### OpenCode

- Runs **per workspace** using the `opencode run` CLI.
- Reads configuration from:
  - `opencode.json` at the workspace root
  - `.opencode/opencode.json`
- Built-in bash is **enabled** in per-workspace configs.

### Claude Code

- Runs **per workspace** using the Claude CLI.
- Configuration is written to each workspace:
  - `.claude/settings.local.json` (MCP servers + permissions)
  - `.claude/skills/<name>/SKILL.md` (native skills with YAML frontmatter)
  - `CLAUDE.md` (general workspace context)
- Auth: when CLIProxyAPI holds a Claude login, the harness is pointed at the
  proxy (`ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`) and no OAuth file is
  written. Otherwise (legacy mode) credentials are copied to the mission's
  `.claude/.credentials.json`. See `docs/CREDENTIAL_OWNERSHIP.md`.
- Built-in `Bash` is **enabled** in the permissions allowlist.

### Codex

- Runs **per workspace** using the Codex CLI/app-server driver.
- Configuration is written to each workspace:
  - `.codex/config.toml` (MCP servers and profile config)
  - `.codex/skills/<name>/SKILL.md` (native skills with YAML frontmatter)
- Auth uses OpenAI API keys or Codex/ChatGPT credentials discovered by the
  backend.

### ChatGPT UI

- Drives the ChatGPT web app through a service-side browser profile pool
  (`src/backend/chatgpt_ui`, `scripts/chatgpt_ui_driver.py`). It is also the
  engine behind ChatGPT cloud agents. See `docs/CHATGPT_UI_HARNESS.md`.

### Antigravity and Grok

- Run **per workspace** using their native CLI backends.
- Antigravity uses `agy`, its execution user's native login, and `agy models`
  for model discovery. Google/OpenCode credentials are not Antigravity credentials.
- Grok uses xAI API keys or the Grok CLI's own login cache.

## Tool policy

- **Built-in bash is the default** for OpenCode and Claude Code.
- Legacy MCP tool namespaces (`workspace_*`, `desktop_*`) are **disabled by
  default** in per-workspace OpenCode configs.
- Desktop/Playwright tools remain available as optional MCPs when needed.

If a mission truly requires MCP tools, re-enable them per workspace or per
backend in configuration. The default is to avoid host-proxy tooling.

## Desktop streaming

- Desktop sessions are Wayland-first: each session runs a compositor whose
  socket lives under the workspace (`.sandboxed-sh/wayland/<display>/`), see
  `src/api/desktop.rs`. Xvfb is only kept as a fallback for legacy sessions.
- Harnesses and MCPs do not get a display unless the mission asks for the
  desktop tools; run such missions on a workspace that has a desktop session.

## Configuration sources

Per-workspace config is generated from three sources:

1. **Library** (git-backed) for agents, skills, tools, rules, and MCP
   definitions.
2. **Backend Settings** (UI) for CLI paths or backend-specific overrides.
3. **Workspace Settings** for env vars and per-workspace overrides.

Files written per mission workspace:

- `opencode.json` and `.opencode/opencode.json`
- `.claude/settings.local.json` (for Claude Code)
- `.claude/skills/<name>/SKILL.md` (native Claude Code skills)
- `CLAUDE.md` (general workspace context)
- `.codex/config.toml` and `.codex/skills/<name>/SKILL.md` (for Codex)

## Observability

Sandboxed.sh streams structured tool events and text deltas from the harnesses.
The UI receives:

- tool calls/results
- thinking deltas
- final completion

This preserves the UI experience while keeping execution isolated per workspace.

## Resource isolation (cgroups: memory + CPU)

Mission work is CPU/RAM-heavy and bursty (a single mission can spawn dozens of
parallel Lean/proof or contract builds). To keep one mission from starving the
host, the API service, or even its own harness's response streaming, every
mission container/exec runs in a **transient systemd scope** under
`missions.slice` — a cgroup *sibling* of the API service (`system.slice`), not a
child. Two tiers of caps apply:

- **Aggregate (slice level, ops-owned).** `missions.slice` carries a drop-in
  with a `CPUWeight` **lower** than `system.slice` (so missions yield CPU to the
  API tier under contention) plus an aggregate `MemoryHigh`/`MemoryMax` and an
  optional `CPUQuota` ceiling. This is the guarantee that the API → SSE → UI
  path stays responsive no matter how hot the missions get. The API service
  itself runs at a high `CPUWeight` within `system.slice`.
- **Per-mission (scope level, code-owned).** `MissionResourceCaps`
  (`workspace_exec.rs`) emits `MemoryMax/High/SwapMax` and `CPUWeight/CPUQuota`
  on each scope via `systemd-run --property`. Sourced from env with a
  per-workspace override: `MISSION_MEMORY_{MAX,HIGH,SWAP_MAX}` and
  `MISSION_CPU_{WEIGHT,QUOTA}` (see `.env.example`). The Resources panel
  (`POST /api/workspaces/:id/resources`) retunes running scopes live via
  `systemctl set-property --runtime` and persists the override.

Gotchas:
- **The harness CLI and the build it spawns share one scope** (the Bash tool's
  child), so cgroups can't separate harness from build *within* a mission — the
  per-mission `CPUQuota` (capping the mission) and the slice tiering (capping
  missions vs the API) are the real levers, not per-process priority.
- **Emitting a CPU property is what delegates the `cpu` controller into
  `missions.slice`.** Without any CPU property, `missions.slice`
  `cgroup.subtree_control` lacks `cpu` and a per-scope `CPUQuota` is silently
  unenforced. Only memory caps had been shipped, so on prod every slice sat at
  the default `cpu.weight=100` and Lean fan-outs oversubscribed all cores.
- Unset env (default) = no scope wrapping at all, so Docker installs without
  systemd PID 1 stay on the direct path.

## Resource isolation (container `/tmp`)

systemd-nspawn mounts a **tmpfs on `/tmp` inside every container**, sized at 10%
of host RAM (6.3G on a 64G box). Mission scratch — multi-GB audit trees, cert
runs, Ask sandbox copies — therefore lands in *RAM*, priced against the same
budget as the caps above. Setting `SANDBOXED_SH_CONTAINER_TMP_ROOT` backs each
container's `/tmp` with a per-workspace directory on a data disk instead
(`container_tmp.rs`, bound in `start_persistent_container_leader`). Retention for
stale scratch is `SANDBOXED_SH_CONTAINER_TMP_RETENTION_HOURS` (default 72); the
sweep rides the mission-workspace GC cadence.

Gotchas:
- **A full container `/tmp` is silent.** Writes get ENOSPC, but tooling that
  doesn't check leaves 0-byte logs and empty directories — no crash, no alert.
  In the 2026-08-05 incident two containers sat at zero bytes free for ~2 days.
- **It is invisible from the host.** Host-side `containers/<ws>/tmp` is an empty
  shadow of the tmpfs, so `df`, the disk watcher, and the workspace GC all
  report healthy numbers. To inspect it you must enter the namespace via the
  nspawn **child** pid (the nspawn pid itself still shows the host fs):
  `p=$(pgrep -f "systemd-nspawn .*--machine=sandboxed-<ws>-"|head -1); c=$(pgrep -P $p|head -1); nsenter -t $c -m -- df -h /tmp`
- **Raising the tmpfs size is not the fix.** Eleven containers at the default
  already oversubscribe a 62G box; disk-backing it is what buys real margin.
- Takes effect only when a container leader next starts (execs `nsenter` into
  the existing leader), so rollout is per-container as they cycle.
- Unset (default) = stock nspawn tmpfs, so shipping this changes nothing until
  the env is set.

## Operational notes

- **No central OpenCode server needed**: Missions spawn per-workspace CLI
  processes.
- **Compute placement is observable**: Hermes/controllers should call
  `get_compute_fleet` before parallel dispatch. Auto placement preserves idle
  GPU nodes for inference while ordinary CPU/Lean nodes have immediate slots,
  then balances by normalized utilization. Only terminal node/job/head receipts
  prove that work was actually distributed.
- **Controllers are piloted from Orb**, not a bound Hermes chat. One-off
  orders are project steers (`add_project_steer` / cron composer). Standing
  authority is still `set_project_grant`. `deliver: project:<slug>` is
  delivery plumbing. See `docs/CONTROLLERS.md`.
- **Dev/prod companion binaries are isolated**: production uses unsuffixed MCP
  and palomactl paths; non-production services use a service suffix (for
  example `assistant-mcp-dev`). A dev deploy must never replace Hermes's
  production connector.
- Agents are loaded from OpenCode built-ins and native `.opencode/agents/*.md` files.
- Per-workspace execution eliminates host-to-container network issues.
- For remote workspaces, SSH execution keeps bash/tooling on the remote host.

## Quick validation

Recommended smoke tests after changes:

1. **Claude Code (isolated)**: create a file and verify it exists inside the
   container workspace directory.
2. **OpenCode (isolated)**: create a file and verify it exists inside the
   container workspace directory.
3. **Codex/Antigravity/Grok (isolated)**: create a file and verify it exists inside
   the container workspace directory.
4. **Claude Code (host)**: create a file in the host workspace.
5. **OpenCode (host)**: create a file in the host workspace.

If files appear in the wrong place, the harness is not running inside the
workspace execution context.

## Formal Orchestration & Node Lifecycle Kernel (`lean/Orb/Kernel.lean`, `lean/Orb/Spec.lean` & `src/orb_spec.rs`)

Orb follows the **"Lean Decides, Rust Does"** boundary across the control plane, LLM proxy, mission lifecycle, managed VM governance, and cross-client UI projections (`lean/Orb/Kernel.lean` and `lean/Orb/Spec.lean`, `0 import Lean`, `0 sorryAx`, pinned by `lean/lean-toolchain` and `lean/lakefile.lean`). Every pure state machine and admission gate compiles directly to `liborb_spec_cabi.a` (`~2.3 ns/call`, zero C++ runtime dependency, zero hand-written C fallback) via `build.rs` and `src/orb_spec.rs`, while Rust owns async Tokio/Axum I/O, SQLite persistence, OS process/cgroup management, strings, and cryptography:

1. **Two-Layer Non-Tautological Specification Architecture (`lean/Orb/Spec.lean`)**:
   - **Layer 0 (`MetaGateSpec`)**: Enforces 4-part non-vacuous tightness (`sound`, `complete`, `posWitness`, `negWitness`) for every boolean admission gate.
   - **Layer I (5 Universal Algebraic Meta-Specs)**:
     1. **`StickyFence` (Irreversible / Monotone Boundary)**: Once a stream or message crosses a commitment boundary (`first_byte_committed`, `durable_run_started`), failover and silent dequeue are permanently disabled (`orb_proxy_step`, `orb_queue_step`, `orb_verify_remote_outbox`, `orb_verify_job_transition`, `orb_admission_step`, `orb_job_ledger_step`).
     2. **`ClockDiscipline` (Independent Monotone Timers & Boot Epochs)**: Heartbeat frames reset only the idle timer and never extend the semantic progress deadline (`orb_stream_deadlines`), provider cooldowns partition transient network faults from account/subscription poison with exponential backoff (`orb_breaker_step`, `orb_account_cooldown_secs`), wake-up arming precedes no-progress stops (`orb_mission_step`), boot-scoped reconciliation fences stale sweeps (`orb_reconcile_step`), and `/proc/<pid>/stat` start-tick verification prevents PID-reuse kills (`orb_proc_liveness_step`).
     3. **`ScopedAuthority` (Capability & Lease Isolation)**: Exclusive writer leases (`orb_verify_writer_reuse`, `orb_verify_lease_mode`, `orb_verify_track_hold`, `orb_verify_repo_disjoint`), constant-time token rotation (`orb_verify_token_rotation`), and zero-oracle cross-mission access control (`orb_access_step`).
     4. **`ConservedResource` (Bounded Capacity & TTL)**: Parallel DAG task-board slot admission (`orb_verify_board_slots`, `orb_verify_board_retry`), workspace bundle and log sliding-window budgets (`orb_verify_bundle_budget`, `orb_verify_log_window` + `lean_sys_cabi::leansys_verify_log_window`), managed VM admission/reaper bounds (`orb_vm_step`), half-up nanodollar token cost rounding (`orb_cost_cents_step`), and bounded stream repetition detection (`orb_stream_loop_step`).
     5. **`ProjectionStability` (Cross-Client UI Determinism)**: Pure steppers for transcript narration folding (`orb_workfold_step`), task card turn-end state (`orb_taskcard_step`), turn summary & task status settling (`orb_turn_summary_step`), sidebar hierarchy/archive visibility (`orb_sidebar_visibility`), Anthropic unified rate-limit status (`orb_usage_limit_status`), compact relative time (`orb_relative_time_bucket`), incremental SSE transcript patching (`orb_transcript_patch_step` with saturating `satAdd32`; theorem `transcript_patch_step_monotone_absorbing`: deltas never shrink the buffer, `turn_boundary` resets it, unknown event kinds leave the packed state unchanged), and deterministic PR merge-readiness priority (`orb_pr_gate_step`), backed by shared cross-client fixtures in `shared/orb-spec/fixtures/projection-invariants.json`.
   - **Layer II (Mathlib4-Style Corollaries)**: Every concrete theorem in `lean/Orb/Spec.lean` is a 1–3 line corollary (`decide`, `omega`, `split <;> simp_all`, `simpa`) of a Layer-I Meta-Spec — never a copy-pasted boolean formula.
2. **34 Unboxed Scalar C-ABI Exports (`lean/Orb/Kernel.lean`, `crates/orb-spec` & `src/orb_spec.rs`)**:
   - **Orchestration, Leases & Bounds (12)**: `orb_verify_writer_reuse`, `orb_verify_lease_mode`, `orb_verify_track_hold`, `orb_verify_repo_disjoint`, `orb_verify_remote_outbox`, `orb_verify_board_slots`, `orb_verify_board_retry`, `orb_verify_job_transition`, `orb_verify_bundle_budget`, `orb_verify_token_rotation`, `orb_verify_log_window`, `orb_mix64_word` (linked alongside the 21 `leansys_*` C-ABI gates and scanners from `lean-sys-cabi`).
   - **Proxy, Mission Lifecycle, VM, Admission, Cost, Liveness & Cross-Client Projections (22)**: `orb_proxy_step` (`src/api/proxy.rs`), `orb_stream_deadlines` (`src/api/proxy.rs`), `orb_breaker_step` (`src/provider_health.rs`), `orb_mission_step` (`src/api/control/host_goal.rs`), `orb_reconcile_step` (`src/api/reconcile.rs`), `orb_queue_step` (`src/api/control/control_queue.rs`), `orb_vm_step` (`src/managed/mod.rs`), `orb_access_step` (`src/api/mission_access.rs`), `orb_workfold_step`, `orb_taskcard_step`, `orb_sidebar_visibility`, `orb_admission_step` (`src/api/control/dispatch_admission.rs`, `src/api/control/disk_admission.rs`), `orb_account_cooldown_secs` (`src/provider_health.rs`), `orb_cost_cents_step` (`src/cost.rs`), `orb_stream_loop_step` (`src/api/runners/stream_guard.rs`), `orb_job_ledger_step` (`src/remote_node/job_ledger.rs`), `orb_proc_liveness_step` (`src/node/runner.rs`), `orb_pr_gate_step` (`src/bin/palomactl.rs`), `orb_turn_summary_step`, `orb_usage_limit_status`, `orb_relative_time_bucket`, `orb_transcript_patch_step`.
3. **Fail-Closed Build & Zero-Trust Audit Gate (`crates/orb-spec/build.rs` & `turbo-lean`)**:
   - `crates/orb-spec/build.rs` compiles `Orb/Kernel.lean` to C, typechecks `Orb/Spec.lean` against `Orb/Kernel.olean`, runs `ld -r --gc-sections` + `strip --strip-unneeded` to eliminate boxed wrappers/initializers, and verifies via `nm` that all <!-- inventory:orb_cabi_exports -->34<!-- /inventory:orb_cabi_exports --> exports are defined (`T`) with `0` undefined symbols.
   - Before modifying `lean/Orb/Kernel.lean`, `lean/Orb/Spec.lean`, or `crates/orb-spec/src/lib.rs`, verify `turbo-lean --json audit-spec lean/Orb/Spec.lean` reports `vacuous_specs == 0`, `trivial_specs == 0`, and `horizontal_packing_warnings == []` (<!-- inventory:orb_tight_specs -->53/53 tight specs<!-- /inventory:orb_tight_specs -->).

## Debugging deployed instances

See **[DEBUGGING.md](DEBUGGING.md)** for service management, logs and
deployment procedures.
