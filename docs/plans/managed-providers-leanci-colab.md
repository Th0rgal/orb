# Managed providers: lean.ci and Google Colab

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
  `LEANCI_API_KEY` (renamed from `BOOST_API_KEY`) and `COLAB_API_TOKEN`.
- The retired Rust clients are the reference: `git show 4199fc06e^:src/managed/boost.rs` (lean.ci) and
  `git show 4199fc06e^:src/managed/colab.rs`, with the orchestration in `src/managed/mod.rs`. The behaviour
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
   No `boost` alias, no `BOOST_*` variable, in code, environment, sealed-secret name, UI or docs.
2. Capacity preflight: `GET /v1/vms/capabilities`, 20 s cache, `?repo=` / `?snapshot_id=` for warm images.
   `online_engines == 0`, `schedulable_vcpus == 0` or no profile fitting `largest_bootable_vm` means
   temporarily unavailable: skipped in unpinned selection, `503 provider_at_capacity` when pinned.
3. Sizes and prices as decided by Thomas: 2 vCPU/8 GiB/50 GB (small, $0.018/h); 4/16/75 (default, medium,
   $0.036/h); 8/32/100 (large, $0.072/h); 16/64/150 (xlarge, $0.20/h); 24/96/175 ($0.30/h); 32/96/200
   (2xlarge, $0.40/h); 32/128/200 (3xlarge, $0.45/h); optional `memory_mib` 4096..=131072 in steps of 1024.
   First live check: which labels the API accepts today (`lean-<n>vcpu-ubuntu-2604` or `boost-...`).
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
