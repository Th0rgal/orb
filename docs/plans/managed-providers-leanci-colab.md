# Managed providers: lean.ci and Google Colab

## Handoff 2026-11-13

PR #1720 is merged at `6f1573fa8fb1799c5bc40c8269b5a1e7bb0e07f4`. This is a
source-level handoff, not evidence that this revision is deployed or that every UI
works against a live provider. The operator waived the final CI wait; do not infer
that all final-head CI jobs passed. The merged feature branch passed the CI-parity
Core build, full Core self-test (101 host tests) and spec fixtures (5 tests).

### What is implemented, and what is actually proven

| Surface | Active VM list | Spawn | Stop / extend / destroy | Cost display |
| --- | --- | --- | --- | --- |
| Core REST API | Authenticated, owner-filtered managed-machine list and provider catalog; this is Core's inventory, not an unrestricted upstream account inventory | Provider/size/TTL, async action receipt by default; `wait:true` for blocking use | Stop/resume and destroy routes exist. Stop/resume is Boat-only. No REST `/:id/extend` route was found on this master | Machine quote/rate and reserved spend fields; not audited provider invoices. Authenticated historical `daily_spend` is currently empty |
| MCP | `list_managed_machines` includes providers/catalog; default hides destroyed rows | `spawn_managed_machine(provider: boat | leanci | colab)`; sizes resolved from catalog, including `leanci:2xlarge` (32 vCPU/96 GiB), `colab:t4`; `start_mission` accepts `auto-managed:<provider>:<size>` and old Boat shorthand | Destroy and extension use the shared lifecycle. lean.ci supports neither stop/resume nor extend. Colab supports neither stop/resume; its extension changes Core's TTL only, not Google's runtime lifetime | Machine rates, reservation estimates and budget receipts |
| Established desktop (SolidJS) | Provider-grouped list is wired | Provider/size/TTL dialog is wired; personal opt-in switch separate from global enablement | Destroy wired; stop capability-gated. Extend UI exists but calls the missing REST route, so it is not working end to end | Rates, estimated spend/budgets and chart UI exist; live accounting/chart correctness not demonstrated |
| iOS | Provider-grouped list is wired | Provider/size/TTL sheet and personal opt-in are wired | Destroy wired; stop capability-gated. Extend has the same missing REST route and is not working end to end | Rate/spend/budget views implemented; live correctness not demonstrated |
| Android | Provider-grouped list is wired | Provider/size/TTL dialog and personal opt-in are wired | Destroy wired; stop capability-gated. Extend has the same missing REST route and is not working end to end | Rate/spend/budget views implemented; live correctness not demonstrated |

Both non-Boat providers default to **off per user**. Explicit preferences are
preserved; a one-time migration preserves prior provider usage. Thomas's existing
opt-ins must remain on. MCP checks the owning user's preference for spawn and
reuse, including operator sessions. Core's sealed keys are never delivered to a
guest or mission. lean.ci uses `https://api.lean.ci/v1`; Colab uses the host's
`colab-api` plus each runtime's tunneled worker. Availability observations do not
mutate global toggles. lean.ci catalog filtering uses live capabilities with a
20-second cache and conservative fallback, excludes 128-GiB profiles, and retains
32-vCPU/96-GiB `2xlarge`. `small` measured only about 14 GB free: do not choose it
for substantial Lean builds without checking disk requirements.

**Live evidence inherited from the operator:** keys sealed, global providers
enabled, Thomas opted in; a lean.ci small guest and a Colab T4 guest successfully
provisioned/enrolled and were destroyed on production before this handoff. This
is not a live test of the newly corrected MCP schemas or any client UI. Mock
contracts now rent every implemented provider/catalog size through MCP, exercise
qualified auto-managed placement/reuse, and reject fresh users until opt-in.

### Not at Boat parity / client gaps

- **Provider/API/MCP:** lean.ci has snapshot save/list/delete and snapshot-based
  spawn implemented, but no stop/resume, lease extension or running-VM fork.
  Colab has none of stop/resume, snapshots/restore or fork. Its quoted costs are
  shadow prices (half corresponding Vast.ai rates), not Google billing. Colab
  TTL extension cannot prevent Google reclaiming a runtime. No automatic busy
  extension is promised; the Core lifetime ceiling is 720 minutes from boot.
- **Desktop:** lean.ci/Colab do not acquire Boat-only operations merely because
  controls are shared. Clients do not yet gate Extend using `supports_extend`.
  Snapshot inventory/delete UI exists but the corresponding REST list/delete
  routes were not found; there is no snapshot save, restore picker or fork UI.
  Spawn action failure reasons now project into the desktop transcript.
- **iOS:** same stop/extend limitations; no snapshot management, restore picker
  or fork UI. Spawn action failure details are implemented. No installed-app or
  live-provider settings/spawn/action smoke test was performed.
- **Android:** same stop/extend limitations; no snapshot management, restore
  picker or fork UI. No equivalent transcript action-polling projection was
  found, so desktop/iOS spawn-failure detail parity is not established. No
  installed-app or live-provider settings/spawn/action smoke test was performed.
- **Cross-client wire contract still needs a live replay:** Core emits `ready`,
  `created_at_sec` and `expires_at_sec`; client models also reference `online`
  and ISO timestamp fields. Status/countdowns/action enablement must be verified
  against real REST responses rather than inferred from fixture tests.
- The newly merged **experimental LeanUI desktop is not the SolidJS client**:
  its fleet view uses seeded data and a rendered spawn control without managed
  lifecycle API wiring found in this audit. It is not provider UI parity evidence.

### Never verified live by this mission

No final-head live MCP rent/auto-managed/reuse test, fresh-user opt-in rejection,
client list/spawn/destroy workflow, cost/countdown reconciliation, or provider
saturation/fallback test was performed. lean.ci snapshots, warm-image restore,
large profiles (including 32/96), custom memory, larger-profile free disk and
capacity-race behavior were not live-verified. Colab accelerators other than T4,
Core-only extension, runtime reclaim/reconnect and GPU workload execution were
not established by this handoff. Do not mark the original snapshot/warm-build or
`nvidia-smi` acceptance steps below complete without their own receipts.

### Dev verification for the new owner

1. Use the dev instance only (`sandboxed-sh-dev`, port 3002, data
   `/var/lib/sandboxed-sh-dev`). Deploy an exact reviewed SHA through
   `orb-deploy <sha> --dev-only`; never replace binaries or restart production.
   Check `/api/health` reports that SHA. Dev credentials/settings are separate;
   use the approved sealing/operator workflow, never copy secrets into prompts.
2. Confirm global provider enablement and Thomas's personal opt-ins. With a
   fresh test user, list the catalog and try explicit lean.ci/Colab rentals:
   expect `provider_disabled_for_user` and no new upstream VM. Enable just one
   personal switch and verify only that provider becomes rentable via REST/MCP.
3. Read `list_managed_machines` and its live provider sizes. Rent lean.ci
   `small` and Colab `t4` one at a time with a unique idempotency key and short
   TTL. Poll `get_action` to terminal success/failure; retain the actual failure
   reason. Verify relay enrolment, a trivial guest command, and Colab
   `nvidia-smi`. Check the upstream provider also lists the resource.
4. Point each established client at dev. Exercise list, personal switch,
   UI spawn, action failure, cost/rate, timestamps/countdown and destroy. Record
   platform/version and real response shapes. Verify unsupported stop is absent;
   treat Extend as a known gap until its REST route/capability gating is fixed.
5. Exercise qualified `auto-managed:leanci:<available-size>` and
   `auto-managed:colab:t4`; verify the returned provider/size and reuse ownership.
   Test 32/96 only with explicit budget approval and live capacity; inspect
   `df -h` before any Lean build. Separately test lean.ci snapshots/restore.
6. Destroy every test resource even after partial failure. Confirm provider-side
   absence, terminal Core state, closed cost ledger and no lingering notebook.
   Dev uses real shared provider accounts and incurs real costs. Save receipts
   before calling any untested capability done.

The original plan below is historical/task context, not a completed checklist.

Goal: missions can rent machines on lean.ci and on Google Colab through Core, the same way they can on
Boat since 2026-11-12. This plan is a child of `docs/plans/core-recovery-2026-11.md` (section 1, items 5
and 6) and is owned by its own mission; the recovery mission keeps the Boat lifecycle (snapshots, fork,
restore, automatic placement) and fleet reconciliation.

## Facts at the start (2026-11-12, 14:30 UTC)

- Boat works end to end in prod for spawn, enrol, relay, mission, destroy. The shared path is
  `spawnConfiguredManagedWorker` in `lean/OrbCore/OrbCore/RemoteFleetAndRelay.lean`, the provider interface
  is `ManagedProvider.Provider` in `lean/OrbCore/OrbCore/ManagedProvider.lean`, guest bootstrap is
  `lean/OrbCore/OrbCore/ManagedProvisioning.lean` plus `scripts/orb-node-provision.sh`.
- `resolveManagedProvider` and `quoteManagedSpawnCents` know only `boat`; everything else returns
  `managed_provider_not_implemented`.
- `https://api.lean.ci/v1` answers (401 without a key). The `colab-api` service listens on agent-core at
  `127.0.0.1:8790` (401 without a token).
- Prod has only Boat's key sealed (`/root/.sandboxed-sh/managed-secrets/boat.aead`). Bitwarden holds
  `LEANCI_API_KEY` and `COLAB_API_TOKEN`.
- The retired Rust provider clients at `4199fc06e^` are historical references only, with the
  orchestration in `src/managed/mod.rs`. The behaviour
  spec is `docs/specs/managed-vm-lifecycle.md`.
- lean.ci context is in Hindsight, page `kp-7660c626095640c08f6742f9e60c2946`, section 3.

## Step 0: shared groundwork

1. **Provider registry.** Replace the Boat-only lookup with a table. Each provider declares its sizes and
   prices, readiness deadline, bootstrap mode, and whether it supports stop/resume, snapshots and extend.
   One file per provider, so providers do not edit shared code.
2. **Key sealing.** Core obtains and seals `LEANCI_API_KEY` and `COLAB_API_TOKEN` through its reserved
   path, as for Boat. The secret broker refuses every provider key to missions (`BOAT_API_KEY`,
   `LEANCI_API_KEY`, `COLAB_API_TOKEN`, `HETZNER_CLOUD_APIKEY`, `SCALEWAY_KEY_ID`, `SCALEWAY_SECRET_KEY`,
   `VASTAI_API_KEY`); today it hands them to any approved session.
3. **Availability.** Add "is this provider usable now" to the interface. Temporary unavailability never
   changes the operator's persisted `enabled` toggle.
4. **Spawn returns promptly.** `spawn_managed_machine` and the REST create route return an action receipt
   at once; readiness is polled. Today the call blocks until the node is ready and callers time out with
   "acceptance unknown" even on success.
5. **Keep transport errors.** `httpTransport` discards the cause of a failed provider call; log it.

## lean.ci

1. Client under the name `leanci` only, against `https://api.lean.ci/v1`: `POST /vms`, `GET /vms/:id`,
   list, `DELETE`, `/vms/:id/exec`, `/vms/:id/files`, `/vms/:id/snapshots`, `/vms/snapshots`.
   No retired provider alias or credential prefix in code, environment, sealed-secret name, UI or docs.
2. Capacity preflight: `GET /v1/vms/capabilities`, 20 s cache, `?repo=` / `?snapshot_id=` for warm images.
   `online_engines == 0`, `schedulable_vcpus == 0` or no profile fitting `largest_bootable_vm` means
   temporarily unavailable: skipped in unpinned selection, `503 provider_at_capacity` when pinned.
3. Sizes and prices: 2 vCPU/8 GiB/98 GB root (small, $0.018/h); 4/16/75 (default, medium,
   $0.036/h); 8/32/100 (large, $0.072/h); 16/64/150 (xlarge, $0.20/h); 24/96/175 ($0.30/h); 32/96/200
   (2xlarge, $0.40/h). Labels are `lean-<n>vcpu-ubuntu-2604`; the 32-vCPU label defaults to 96 GiB.
   The live service reports 3 online engines, 96 schedulable vCPUs, 323796 MiB schedulable memory,
   and 107520 MiB largest bootable memory. Aggregate pool memory is not a per-VM limit. Remove the
   impossible 128 GiB size; keep 32 vCPU/96 GiB. Optional `memory_mib` is 4096..=107520 in steps of
   1024, further bounded by live capacity. Filter catalog profiles against the capabilities endpoint
   where possible; on lookup failure retain only the conservative declared sizes. `small` has only
   about 14 GB free on a fresh guest: use a larger, capacity-checked profile for Lean builds and check
   actual free disk first; larger disk figures still need live verification.
4. Bootstrap by exec, reusing the Boat path, with the 480 s deadline. Guest gets its `LEANCI_*` cache
   variables. Native TTL 60 s to 86,400 s; Orb caps at 720 min. Snapshots yes; stop/resume no.
5. Live test on dev: smallest size; spawn, enrol, mission, snapshot, destroy, provider no longer lists it.
   Then one `xlarge` from a warm image.

## Google Colab

1. Client for `colab-api` (`GET /v1/accounts`, `GET /v1/accelerators`, `GET|POST /v1/notebooks`,
   `POST /v1/notebooks/:id/delete`) and for each runtime's worker over its tunnel (`GET /info`,
   `POST /exec`, `PUT /files/<rel>`).
2. Sizes `colab-auto`, `t4`, `l4`, `a100`, `h100`, `v5e1`, `v6e1`, shadow-priced at half the Vast.ai rate.
   No snapshots, no stop/resume.
3. Bootstrap: a Colab runtime has no systemd, so the node cannot be installed as a service. Start it as
   a supervised background process through the worker. Prove this on a T4 before anything else.
4. Live test on dev: T4, enrol, `nvidia-smi` as a mission, delete the notebook, `colab-api` shows it gone.

## Rules

- Test on the dev deployment only (`sandboxed-sh-dev`, `/usr/local/bin/orb-core-dev`, port 3002, data in
  `/var/lib/sandboxed-sh-dev`). Do not install to or restart prod. Prod deploys are done by the operator
  session after it has verified the result.
- One heavy Lean build at a time. The warm tree `agent-core:/var/tmp/orbcore-lean-build` is shared with
  the operator session; say so before using it.
- Live tests use the smallest size and destroy the machine afterwards.
- Mock-transport tests for every provider call, plus the live tests above. A mock that accepts what the
  real API rejects is a test bug (Boat's file upload was POST in the mock and PUT in reality).
