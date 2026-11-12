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
3. **Compute history.** Nothing writes `compute_rollup_1m`, so Resources compute charts only show the
   live sample. Sample per minute and read it in `buildResourcesOverviewJson`.

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

## 4. Other gaps found

- MCP action receipts report `action_outcome: "rejected"` / `durable_success: false` for actions that
  succeeded (`resume_mission`, `send_message_to_mission`).
- `get_mission_events` ignores `since_seq` and `before_seq` and always returns the first page;
  `get_mission_health` and `get_mission_diagnostics` return only the bare digest.
- `resume_mission` ignores its `content` and sends "Continue.".
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
