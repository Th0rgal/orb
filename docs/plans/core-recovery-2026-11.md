# Core recovery plan (November 2026)

Prod switched from the Rust server to the Lean `orb-core` on 2026-11-12 at 07:14 UTC. This plan lists
what that cutover left broken or missing, in priority order. Work top to bottom; each numbered item is
one PR-sized change merged to `master` when its checks pass.

References:

- Managed VM behaviour: `docs/specs/managed-vm-lifecycle.md`.
- The retired Rust implementation is in git history at `4199fc06e^` (`git show 4199fc06e^:src/managed/mod.rs`).
  Provider clients: `src/managed/boat.rs`, `src/managed/boost.rs` (this is lean.ci), `snapshots.rs`,
  `lifecycle.rs`, `raw_operations.rs`, `budget.rs`; REST surface `src/api/managed_machines.rs`.
- Build and test on the server: see "Build and test before pushing" in `AGENTS.md`. The Core self-test
  must be run from the repository root.

## Operator update (2026-11-12, 15:05 UTC)

- Recovery owns Boat restore/lifecycle and fleet reconciliation. Immediate priority:
  backfill existing Boat IDs by exact sandbox name, observe archived guests as stopped,
  then resume by fork/bootstrap under the same Core machine/node ID. evm.fast and
  Pareto are blocked on this. Scoped snapshots/restore, fork, extend and automatic
  placement through `start_mission` follow.
- Mission `2bf5e847` owns the provider registry, key sealing, availability, prompt spawn
  receipts, transport error retention, lean.ci and Colab. Its plan is
  `docs/plans/managed-providers-leanci-colab.md`; do not duplicate that work here.
- Mission `68e2a387` owns the Rust/Lean documentation audit. All three missions are
  in Refinery. Pull/rebase before every push because shared Lean files overlap.
- The operator deploys master to dev/prod and verifies live results. Recovery does
  not need SSH or deploy access. Read `/api/health`'s `build` to identify deployments.
- End the turn at every milestone so queued operator notes can be delivered.

## 0. Prerequisites

1. Hindsight is unreachable from Core (`HINDSIGHT_API_KEY` / `SPARK_MEMORY_API_TOKEN` are not in Core's
   environment, so `memory_search_knowledge` fails with `memory_tool_denied`). Restore that first, then
   read the lean.ci infrastructure context before designing its client.
2. The last Rust prod binary is still on the server as
   `/usr/local/bin/sandboxed-sh-prod.pre-deploy-969a35261997`. Do not delete it until item 1 is live.

## 1. Managed VMs: Boat first, then lean.ci

Today `spawn_managed_machine` (`lean/OrbCore/OrbCore/McpGateway.lean`) posts a name, size and TTL to
Boat and stops: no snapshot restore, no node agent install, no enrolment. For any other provider it only
writes a database row. `auto-managed:*` placement, fork and snapshots cannot work either.

1. **One provider interface.** A single Lean abstraction for spawn, get, list, destroy, stop, resume,
   fork and snapshots, with one implementation per provider. No per-tool special cases.
2. **Boat client.** Port `boat.rs`: `/sandboxes` (with `from` for a saved snapshot), stop/start, fork,
   `/saved-snapshots`, paged list, retryable stop failures, ready/stopped state mapping.
3. **Bootstrap and enrolment.** After spawn: install the node agent on the machine
   (`orb-node-provision.sh`, `GET /api/managed-machines/bootstrap-binary/:id`), mint and deliver the
   enrolment token, wait for the first relay poll inside the readiness deadline (360 s for Boat),
   destroy the machine on timeout. `status` moves `provisioning -> ready` only on a real poll.
4. **Wire every entry point to it:** `spawn_managed_machine`, `fork_managed_machine`,
   `snapshot_managed_machine`, `list_managed_snapshots`, `stop/resume/destroy/extend_managed_machine`
   (extend must extend at the provider too), `start_mission` with `remote_node_id: auto-managed[:size]`
   and `managed_from_snapshot`, and the REST routes `/api/managed-machines/{settings,providers,snapshots}`
   that currently return 404.
5. **lean.ci client.** Port `boost.rs` under the name `leanci` only: sizes
   (`lean-2vcpu-ubuntu-2604` ...), `GET /v1/vms/capabilities`, reverse-relay bootstrap with the 480 s
   deadline, guest `LEANCI_*` variables including the VM-scoped cache token. Drop the `boost` /
   `boost.ci` names everywhere: provider aliases, `BOOST_*` environment variables, sealed-secret file
   name and AAD, UI labels, docs. Migrate existing rows (`provider='boost'`) and the sealed secret once.
6. **Tests.** Mock provider transport in the Core self-test for each provider: spawn, bootstrap timeout,
   destroy, snapshot round trip. Then a live smoke per provider: spawn the smallest size, run a command
   through the relay, snapshot, fork, destroy, and confirm the provider no longer lists the machine.

Done when a mission can be started on `auto-managed:xlarge` from a saved snapshot on Boat and on
lean.ci, and the blocked missions (evm.fast, ldgr workers) can get machines again.

## 2. Fleet state that reflects reality

1. **Reconciler and reaper.** A periodic task lists machines at each provider and feeds
   `observeProviderPayload` / `applyProviderObservation` (they exist and are unused), so machines that
   expired or were destroyed stop showing as `ready`. Enforce TTL, destroy orphans, close cost ledgers.
   At the time of writing 18 machines are `ready` in the database and none answers through the relay.
2. **Real node liveness.** `/api/remote-nodes` reports every node `online` with one shared timestamp.
   Derive it from heartbeats and relay polls, and cache each node's CPU and RAM so capacity is real.
   *Done on master:* a managed node is `online` only while its authenticated relay poll (in memory or
   persisted) is under 90 seconds old, `last_seen` is that poll, and CPU, memory, disk and hourly price
   come from the provider's declared size. A static node that does not answer keeps the contact time
   and size of its last successful heartbeat (`node_heartbeats.json`), marked `capacity_cached`.
3. **Compute history.** Nothing writes `compute_rollup_1m`, so Resources compute charts only show the
   live sample. Sample per minute and read it in `buildResourcesOverviewJson`.
   *Done on master:* Core's maintenance loop writes one row per machine class each minute
   (`sampleComputeRollup`), keeps eight days, and the overview's `series_vcpu` is the mean of those
   samples per chart bucket with the live reading last. History starts when this version is deployed;
   earlier buckets stay zero. Cost history (`series_usd_per_h`) is still not sampled.

## 3. Desktop UI bugs

1. **`/btw` panel when space is short.** The side panel is drawn over the transcript with a
   see-through background, so both texts are readable at once, and its header controls overlap the
   mission header. It needs an opaque surface and a layout rule for narrow windows (take the full
   width, or push the transcript, never overlap). Look at `orb/src/SideQuestionPanel.tsx` and the
   surface transparency change in #1673.
2. **Spacing in the transcript.** A "Mission failed" card and the following "Continue." message touch
   with no gap, and spacing between tool groups, text and cards is uneven. Give transcript blocks one
   shared vertical rhythm instead of per-component margins.
3. Add a browser test for each that replays the failing layout (narrow viewport with `/btw` open;
   error card followed by a user message). Check light and dark mode. Mobile parity per `AGENTS.md`.
4. **Linux hybrid native chrome:** the header toolbar is rendered twice (sidebar, search,
   back/forward icons). Keep one toolbar owner and add a hybrid-shell regression test.

*Done on master:* 1 (`btw-narrow-layout.browser.spec.ts`: full content area, opaque, scroll thumb no
longer drawn over the panel), 2 (`transcript-rhythm.browser.spec.ts`: 22px above every turn, 12px
between blocks; the failed-card case itself was fixed earlier in #1703), 3 (both specs run in light
and dark), 4 (`native-chrome-toolbar.browser.spec.ts`). Verified in Chromium only; the GTK shell and
WebKit were not available on the build node. These are desktop window-layout fixes with no mobile
counterpart.

## 4. Other gaps found

- MCP action receipts report `action_outcome: "rejected"` / `durable_success: false` for actions that
  succeeded (`resume_mission`, `send_message_to_mission`).
- `get_mission_events` ignores `since_seq` and `before_seq` and always returns the first page;
  `get_mission_health` and `get_mission_diagnostics` return only the bare digest.
- `resume_mission`'s `content`/title handling was fixed by the operator in `5dd9753ce`;
  preserve that fix rather than implementing it again.
- Some missions have `updated_at` stored as a bare epoch string instead of ISO-8601.
- The harness nudge text "Continue if you have next steps, or stop and ask..." leaks into assistant
  messages.
- Usage cost is one blended price. Add a per-model price table (the kernel already has
  `orb_cost_cents_step`) and feed the per-user spend cap from the same figure, including streams.
- The TLS upstream path (`httpsRequest`) should be checked for the same quiet-socket bug fixed in the
  plaintext path in #1699.
- `DEBUGGING.md` and `AGENTS.md` still document the Rust deploy flow and `src/*.rs` paths. Document the
  real build and deploy procedure, and give `orb-core deploy` a build-install-health-rollback path so
  deploys stop being hand-run shell.
- A single failed model call ends the harness turn and fails the mission. Decide where transient
  upstream errors are retried (proxy or harness) and make it one place.

### Additional operator findings (2026-11-12)

- Secret audit logging stopped at the cutover; the last append is `2026-11-11T23:59Z`.
- Queue: add `DELETE /api/control/queue/:id`; send-now must deliver into the running
  turn between tools, not merely reorder queued messages (as the Rust server did).
- `start_workspace_job` and related tools report completed without executing work.
- `sandboxed-worker-rolling-upgrade` fails every minute. The deployed
  `/opt/sandboxed-sh/vaduz-v1/scripts/rolling_upgrade_nodes.py` searches for the old
  binary name; the repository version also matches `orb-core-dev`. Use the unit's
  `MainPID`, and inspect which nodes/jobs it would upgrade before deploying it.
- `sandboxed-development-identity` fails for Babylon and Nippur;
  `sandboxed-harness-update` fails its Vibe CLI probe.
- `/var/lib` on agent-core was incorrectly mode `0700` on November 11 and is now
  restored to `0755`. If it is changed again, find and fix the writer.
- The manually added `claude-fable-5-2` entry in
  `/etc/cli-proxy-api/models.local.json` must be generated from `catalog/`.
- Automatic placement must honor mission exclusions: a Pareto worker was placed
  on Ashur although that mission excludes it.
- Preserve operator fixes already on master: Bitwarden stored-field names
  (`f0435a193`), mission status POST (`49a2761be`), Hindsight credentials/tool names
  and health build ID (`904913331`), verified TLS/relay size (`3f3eb3b93`), and Boat
  file upload PUT (`f61f816e0`). Opening a mission no longer rewrites `updated_at`
  (`0ff162c2b`); verify any remaining legacy epoch-string data separately.

### Recovery handoff (2026-11-13, OpenCode session)

Operator priority: shared REST/MCP backend settings, build survival between turns, event cursors,
REST snapshots/auto-managed creation, then queue delete/resume content/workspace jobs. Operator
sessions act for Thomas as admin; mission authority stays lineage-only. Dev deploy only.

- PR https://github.com/Th0rgal/orb/pull/1717 opened; branch `recovery/managed-provider`
  rebased onto `bf3c7b527`. Commits `a0ee67bf4` (settings + event cursors), `07f91d130` (Boat archive
  recovery). Not merged/deployed. Full CI-parity build and Core self-test passed BEFORE rebase;
  rerun after rebase and await green GitHub checks before merging. `turbo-lean --json audit-spec
  lean/Orb/Spec.lean` exited 0. OpenSSL headers missing on node: extracted libssl-dev under
  `/tmp/opencode/boat-recovery`, build with CPATH pointing to its usr/include and
  usr/include/x86_64-linux-gnu, LIBRARY_PATH to usr/lib/x86_64-linux-gnu. Run self-test without
  LIBRARY_PATH (env -u LIBRARY_PATH), since runtime skill Library uses that same variable name.
  Build/self-test logs and gate script under `/tmp/opencode/boat-recovery`. Initial settings
  test mismatch fixed (self-edit intentionally increments revision; compare null-clear fields).
  Post-rebase CI-parity build passed (299 jobs), and full self-test passed (11 spec gates,
  10 harness contracts, 101 host tests). Log: /tmp/opencode/boat-recovery/post-rebase-selftest.log.
  GitHub Core Test, Docker, harnesses, browsers, mobile and desktop passed; kernel-abi pending.
  Orb unit failed because effort.test.ts scanned the old Control definition. Updated it to scan
  shared MissionSettings and grouped Lean match arms. No node/npm/pnpm installed locally, so
  focused Vitest could not run; await CI for this test-only correction before merge.
  Current pushed head f27fdaed3: Orb unit now passes, Core Test/kernel-abi still pending at
  last check. Independent source review found three gaps; UNCOMMITTED fixes/tests now in
  Control, Managed, ManagedProvisioning, ManagedResumeTests, ManagedTtlTests,
  RemoteFleetAndRelay: replay completed/pending resume intents before provider calls; normalize
  confirmed stopped phase-zero machines; include all-destroyed Boat fleet in maintenance even
  when disabled, remembering confirmed-missing destroyed records to avoid repeated scans.
  Follow-up fixes now pass CI-parity build (299 jobs) and full Core self-test
  (11 spec gates, 10 harness contracts, 101 host tests); log reviewfix-selftest.log under
  /tmp/opencode/boat-recovery. Fixed missing sandboxName fields in the added test fixture.
  Commit/push corrections, then wait for new exact-head CI before merge.
  Background-build survival exploration found a wider ownership boundary: PrivdMain around862
  also stops completed scopes and Runner cancel around2071 ignores terminal jobs. Safe fix needs
  reparent-safe process ownership/supervision across both paths, not just skipping normal cleanup.
  No node code edited yet.
  Sections below describe the original handoff; implemented items are now in these commits.
- Uncommitted `MissionSettings.lean` shares validation and persistence between REST settings and
  MCP. Actual backend changes clear `session_id`/`resumable`; model-only and same-backend changes
  retain them. MCP mutations require trusted operator identity or owner/project-matched lineage.
  `MissionSettingsTests.lean` exercises both entry points, invalid effort, placement revisions,
  null clears and authority denial. Registered in `SelfTest.lean`. NOT compiled yet.
- Prior-session pagination edits in `McpGateway.lean` and `MissionEventsToolTests.lean` retained;
  they implement newest-page default, since/before cursors and view filtering. NOT compiled yet.
- Build gate: another mission's `lake build orb-core orb-core-test orb-spec-runner --
  -DwarningAsError=true` was running on this host (PID 400688, checkout `68e2a387.../orb`).
  Wait for it; do not terminate it. Run that same CI-parity command in `lean/OrbCore`, then run
  `lean/OrbCore/.lake/build/bin/orb-core-test` from repo root before committing.
- Operator escalation, next after settings validation: Core UUID
  `a6fed7e9-950b-40e8-ad83-4c599ceee4b4`, Boat `bx_xcew9qru`, was falsely destroyed while
  Boat retained an archived disk. `ManagedProviderBoat.boatDestroy` returns `boatStop` after
  non-404 DELETE errors; remove that false-success fallback. Inventory reconciliation skips
  destroyed rows (`RemoteFleetAndRelay` around 1021) and only applies archived observations to
  ready rows; resume refresh around 1148 excludes destroyed bound rows. Add provider-confirmed
  archived-to-stopped correction without reviving old credentials, and refresh before resume.
  TTL phase-0 archived branch also marks destroyed without delete (`ManagedTtl` around 224–235).
  Resume pipeline already uses `effectiveProviderId` through intent.oldProviderId; DB column 17
  is zero-based index 16 (index 17 is created_at_sec). Regression must assert fork uses
  `bx_xcew9qru`, never Core UUID. Old `mm5xvnw6ha`, `mm3dagt4ua`, `mmp2t4xd94` truly return
  Boat 404 and must stay destroyed. Replace provider test blessing DELETE409→STOP success,
  add destroyed/archived recovery and 404 tests to ManagedResumeTests/ManagedTtlTests, update
  lifecycle spec which currently documents the bad fallback. No code changed for this yet.
- Read-only build-lifetime investigation: `OrbNode/Runner.lean` normal harness-exit path around
  lines 1906–1916 calls `terminateVerifiedPgrp` and `teardownJobResourcesAsync`, killing background
  builds (143/137). Core messages queue rather than cancel. Fix must retain tracked mission-owned
  processes/scopes across normal turn completion while keeping explicit cancellation/deadlines
  effective; do not simply remove cleanup and leak resources. Node regression needed.

## 5. Main checkout clean-up

The uncommitted work that sat in the main checkout is saved on the branch
`backup/main-checkout-2026-11-12` (one commit on top of `cec17d008`, 71 files). A trial three-way apply
onto master left 31 conflicted files and about 3,900 lines that are not on master. Twelve files were
already identical to master.

1. Split it by feature: MacTether (`lean/OrbCore/OrbCore/MacTether.lean`, about 870 lines), mesh CLI
   (`MeshCli.lean`, `MeshMain.lean`), privd, `SandboxedMcpMain` / `McpCatalog`, Linux shell
   (`linux_shell/main.c`), desktop commands (`orb/src/desktopCommands.ts` and test), Providers skeleton
   and inference loading test, Nix packaging, the remaining small UI edits.
2. For each group: check whether master already has an equivalent, port what is still wanted onto a
   branch from master with its tests, and drop the rest. Anything whose intent is unclear is listed for
   the operator instead of being merged or deleted.
3. When every group is merged or explicitly dropped, delete the backup branch and the stale worktrees.
