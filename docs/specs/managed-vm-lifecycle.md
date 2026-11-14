# Managed VM lifecycle

Goal: no managed VM (`boat`, `leanci`, `hetzner`, `vastai`, `scaleway`, `colab`) keeps running in
the void, and no agent ever needs raw cloud API keys in shell. Every VM has an
owner whose lifetime and activity govern it, and a reaper plus a per-provider
reconciler enforce that.
Code: `src/managed/lifecycle.rs` (pure decision backed by
`orb_vm_lifecycle_step`), `src/managed/mod.rs` (`reap_once`, `reconcile_once`,
`claim_for_mission` backed by `orb_vm_claim_step`), and
`src/api/secret_broker.rs` (`orb_compute_secret_gate`).

## Client lifecycle wire contract

`GET /api/managed-machines` retains Core's `ready` state; all established
clients treat `ready` and legacy `online` as running for status, cost and actions.
Machine records expose `created_at` and `expires_at` as UTC ISO-8601 strings,
while retaining `created_at_sec` and `expires_at_sec` for epoch-based callers.
`deletable_at` is a UTC ISO-8601 string, or null when no minimum-lease bound is
set (`deletable_at_sec == 0`); `deletable_at_sec` always carries the epoch value.

`POST /api/managed-machines/:id/extend` uses the same owner-filtered lifecycle
and budget gate as MCP, accepts `ttl_minutes`, and honors `Idempotency-Key`.
Controls follow provider capabilities: lean.ci has no extend or stop/resume;
Colab has no stop/resume and extension changes only Core's TTL, never Google's
runtime lifetime. Unknown capabilities must not grant non-Boat stop/resume.
Regression replay: a real-shaped `ready` list record must render its countdown
and supported actions; extending then refreshing must preserve those contracts.

## Providers & Secret Confinement

| Provider (`provider`) | Workloads | Bootstrap | `supports_free_stop` | `supports_snapshots` | Minimum lease |
| --- | --- | --- | --- | --- | --- |
| `boat` (default) | Fast ephemeral Linux x86\_64 workers (`small`..`xlarge`) & raw sandboxes | Provider file/exec API | Yes (14d disk retention, \$0) | Yes (named + fork) | Per-second |
| `leanci` (`lean.ci`) | Warm Cloud Hypervisor Linux x86\_64 microVMs (`lean-2vcpu-ubuntu-2604`..`lean-32vcpu-ubuntu-2604`, up to 96 GiB) with optional CoW `.olean` overlays (`repo`/`base_key`/`lean_mode`) & `turbo-lean` | Provider file/exec API -> reverse relay | No | Yes (named + fork, engine-pinned CoW) | Per-second (60s..24h fixed TTL; no live extend) |
| `hetzner` | Larger x86\_64 / ARM64 CPU & RAM instances (`cpx22`..`ccx43`, `cax31`; legacy `cpx21`..`cpx51` aliases map to `cpx22`..`cpx62` with EU location fallback `fsn1` -> `hel1` -> `nbg1`) | Cloud-init `user_data` -> reverse relay | No (stopped servers still bill) | No | Hourly / per-minute |
| `vastai` | Ephemeral CUDA GPUs (`rtx4090`, `a100`, `h100`, or explicit `gpu` filter) | Offer `onstart` -> reverse relay | No (stopped instances bill storage/GPU) | No | On-demand |
| `scaleway` | EU Linux/GPU Instances (`DEV1-*`, `PRO2-*`, `L4-*`, `H100-*`) & Apple Silicon Mac minis (`M1-M`, `M2-M`, `M2-PRO`, `M4-M`) | Cloud-init / SSH -> reverse relay | No | No | Instances: per-minute; Apple Silicon: **24h (`deletable_at`)** |
| `colab` (`Google Colab`) | Pooled Google Colab CUDA GPUs (`colab-auto`, `t4`, `l4`, `a100`, `h100`) & TPUs (`v5e1`, `v6e1`) via `colab-api`, shadow-priced at ½ Vast.ai | Worker file/exec API -> reverse relay | No | No | On-demand (shadow-metered at ½ Vast.ai; explicit-only) |

Provider credentials (`BOAT_API_KEY`, `LEANCI_API_KEY`, `HETZNER_CLOUD_APIKEY`, `VASTAI_API_KEY`,
`SCALEWAY_SECRET_KEY`, `SCALEWAY_KEY_ID`, `COLAB_API_TOKEN`, etc.) are resolved inside Core from
operator settings (`.sandboxed-sh/managed_providers.json`, `0600`, AES-256-GCM
via `env_crypto`), environment variables, or Bitwarden Secrets Manager
(`bitwarden.rs`) and are classified as `CoreReserved` in `secret_broker.rs`
(`orb_compute_secret_gate`). Startup Bitwarden vault discovery runs only when
the Core instance has opted into managed compute (`SANDBOXED_MANAGED_ENABLED=true`,
at least one direct provider env key, a saved `managed_providers.json` key, or an
existing `.sandboxed-sh/managed_machines.json` registry; `SANDBOXED_MANAGED_ENABLED=false`
always disables it) so a companion dev/staging Core process sharing the same
Bitwarden vault cannot silently activate the reconciler and reap production's
`orb-managed-*` VMs as orphans:

1. Agents cannot read `CoreReserved` cloud provider keys via `secret_get` or
   `secret_request`, and `secret_list` omits them from `accessible`. Agents must
   rent VMs through `spawn_managed_machine` or
   `start_mission(remote_node_id="auto-managed[:provider[:size]]")`.
2. Callers executing on untrusted `managed-*` remote nodes are denied all
   non-allowlisted vault secrets (`orb_compute_secret_gate`); only worker-safe
   repository tokens (`GITHUB_TOKEN` / `GH_TOKEN`) may cross to `managed-*` VMs,
   and projects with the `development-identity` skill receive default read
   access to those two keys without per-subagent Touch ID prompts.
3. Operators can inspect, configure, and individually enable/disable each
   provider via `GET /api/managed-machines/providers` and
   `PUT /api/managed-machines/providers/:provider` (`disabled_providers` in
   `managed_settings.json`, plus optional per-provider `max_concurrent` in
   `managed_providers.json`; `boat` defaults to `100` via
   `SANDBOXED_MANAGED_BOAT_MAX_CONCURRENT`, matching the `100`-VM default of
   `SANDBOXED_MANAGED_MAX_CONCURRENT`). Disabling a provider refuses new `spawn`, `fork`,
   `resume`, and sibling reuse (`409 provider_disabled`) while keeping the
   reaper and reconciler active so any already-live VMs are still metered and
   destroyed cleanly.
4. Providers with live pool/quota introspection (`leanci` via `GET /v1/vms/capabilities`,
   `colab` via `GET /v1/accounts` + `GET /v1/notebooks`) surface non-persistent
   `availability` (`available`, `degraded`, `saturated`) on
   `ProviderCatalogEntry` without mutating operator `enabled`: unpinned
   `default_provider()` / `auto-managed` fallback skips `saturated` providers, and
   explicit spawns whose requested profile or snapshot cannot currently fit fail
   fast in `quote_spawn` with `503 provider_at_capacity` before creating any DB row
   or queued orphan VM.

### Operator-triggered reserved key sealing

`POST /api/managed-machines/providers/:provider/seal` accepts only canonical
`boat`, `leanci` and `colab`. It requires a live `orb-jwt-v2` administrator
session on an authentication-enforced Core instance with strong configured
secrets. It rejects open `DEV_MODE=true`, fallback signing keys, legacy JWTs,
raw passwords and mission/node credentials. A dev *deployment* with normal
authentication (`DEV_MODE=false`) is supported. Core resolves `BOAT_API_KEY`, `LEANCI_API_KEY`
or `COLAB_API_TOKEN` from its own environment or an unambiguous Bitwarden entry,
then seals it under `<Core data root>/managed-secrets` (0700, files 0600).
The request contains no key and the response is only `{provider, sealed: true}`.
No key is delivered to the calling mission, no provider API is called, and no
operator enabled toggle is changed. Lookup failures return a stable 503 without
vault output. An advisory file lock fences concurrent master-key creation;
contention fails closed without replacing an existing key.

The same sealing is available without HTTP as `orb-core[-dev] seal-provider
<boat|leanci|colab>`, run on the Core host in the service's environment. Its
authority is ownership of Core's data root by the invoking user; it has no login,
so dev-mode sessions and fallback signing keys cannot reach it, and a process
carrying a mission identity (`SANDBOXED_MISSION_ID`, `SANDBOXED_JOB_ID`) is
refused. It prints only `{provider, sealed}`. The running service picks the key
up on its next provider call; no restart is needed.

**Spec Card** (`Th0rgal/orb@31f24317b`, `Orb.ManagedProviderPolicy`,
`ManagedProviderSealing.lean`, the Control seal route): `seal_authority_iff`
connects the pure gate to authenticated operator / non-mission / non-managed
flags. Positive trace: operator seals a synthetic lean.ci key, and only Core can
open it. The pure theorem does not verify HTTP credential classification,
Bitwarden, filesystem primitives or AEAD; route and synthetic-vault tests cover
those integrations. No live vault result is evidence from the self-test.

### Availability and persisted operator intent

Each adapter exposes read-only `Provider.availability`. `available` and `degraded`
may pass admission; `saturated` returns `provider_at_capacity` (REST 503) and
`unknown`/observation failures fail closed before a VM reservation or rental.
Availability is independent of the operator toggle in `managed_provider_settings`.
Only explicit operator configuration writes that table; Boat retains its existing
`managed_fleet_state.boat_enabled` as its sole toggle owner. Adapter availability
defaults to unknown. Boat explicitly admits attempts with `capacity_not_exposed`,
since its supported API offers no pool preflight; it makes no capacity guarantee.
Admission rechecks the
toggle in the reservation transaction, including resume and extend cost admission.
Catalog responses expose `availability` separately and never change `enabled`
because a provider is full or unreachable. Existing idempotent completed creates
replay before capacity preflight; an observation does not revoke a prior receipt.

**Spec Card** (`Th0rgal/orb@1349b797f`, `Orb.ManagedProviderAvailability`,
`ManagedProvisioning.preflightAvailability`): `admission_iff` captures the enabled
and usable-status conjunction; positive available/degraded traces and saturated /
disabled rejection theorems are kernel checked. Deliberate capacity mutants live
separately. HTTP decoding, caches, database transactions and capacity races remain
the I/O TCB, covered by mock-transport and persistence regressions, not this theorem.
A successful preflight does not promise the subsequent provider create succeeds.
Transport failures keep a bounded, credential-redacted, single-line cause in the
Core log while the returned provider error remains a stable uncertain-outcome code.

### Prompt spawn receipt

Readiness takes minutes, so creation no longer holds the caller's connection.

- `spawn_managed_machine` (MCP) with an `idempotency_key` returns an action
  receipt at once (`state: accepted`). `get_action` returns `running`, then
  `succeeded` with the machine, or `failed` / `uncertain` with the error.
- `POST /api/managed-machines` returns 202 with the provisioning machine plus
  `action_id`, `action_state` and `poll_url`
  (`GET /api/managed-machines/actions/:id`). `"wait": true` keeps the blocking
  201 contract for callers that need a ready node (Change machine).
- The receipt lives in `mcp_actions_v1`, keyed by the caller (user and owning
  mission) and the idempotency key. One insert wins; a retry with the same key
  and arguments returns the same receipt and never provisions again, and
  different arguments under the same key are a conflict.
- A receipt is readable only by its owner (user, and for MCP the same mission)
  or an operator. Others get not-found.
- Arguments that can never be admitted (unknown size, bad TTL) are refused
  before a receipt exists.
- A transport failure or an unfinished cleanup settles as `uncertain`, which is
  never retried automatically. On start, Core marks receipts left `accepted` or
  `running` by a previous process as `uncertain`
  (`core_restarted_during_managed_spawn`); the reservation row stays for
  reconciliation.

**Spec Card** (`Orb.ManagedSpawnPolicy`, `ManagedSpawnActions.lean`):
`receipt_execute_iff` proves only the request whose fresh ID equals the stored
winner with the same digest may provision; `receipt_retry_replays` and
`receipt_missing_never_executes` cover retries and a missing row, and a mutant
that drops the inserter identity is shown to dispatch twice. SQLite uniqueness,
UUID freshness and the authenticated scope are the I/O boundary, covered by the
native tests (concurrent submit, changed arguments, tenant and mission
isolation, uncertain replay), not by the theorem.

### lean.ci adapter

The only accepted provider name is `leanci`. Retired aliases and credential
prefixes are not accepted. One-time startup migrations rename historical rows
and reseal the historical key as `leanci.aead` (the name is bound into the AEAD,
so the file cannot simply be renamed). An unreadable historical file is kept
and reported, never deleted. Credential denial is not a provider alias.

`ManagedProviderLeanci.lean` is the `leanci` client for `https://api.lean.ci/v1`
(`LEANCI_API_URL` overrides the base, `LEANCI_API_KEY` is sealed in Core). Its wire
contract was read from the server source (`lfglabs-dev/lean.ci`,
`crates/leanci-ctrl/src/vms.rs`), not from the retired client:

- Create is `POST /vms` (202, `{vm}`) with `name`, `runner_label`, `ttl_secs` and
  optional `memory_mib`, `repo`, `snapshot_id`. Sizes map to
   `lean-<n>vcpu-ubuntu-2604`; the 32-vCPU size sends explicit 98304 MiB memory,
   matching the label's 96 GiB default. No 128 GiB size is advertised or accepted.
   Orb caps the lease at 720 minutes.
- Only `running` is ready. `stopped`, `failed` and `reaped` are terminal. There is
  no stop/resume and no live TTL extension; those calls fail, they are not faked.
- Guest commands are `POST /vms/:id/exec` with an argv array, run as root; files
  are `PUT /vms/:id/files` with base64 content, mode 0600. A reply that is not
  `ok` and has no exit code is a failure. The client waits longer than the
  server's own guest wait so an answer is not reported as uncertain.
- Snapshots are identified by ID and labelled; labels are not unique and failed
  saves stay listed. Lookup prefers a `ready` entry, delete removes every entry
  with the label, and a spawn from a label resolves it to a ready snapshot's ID
  or rents nothing.
- Availability is `GET /vms/capabilities` (`?repo=` / `?snapshot_id=`), cached
  20 s. No online engine, insufficient schedulable CPU/memory, a profile above
  `largest_bootable_vm` or `max_launchable_now == 0` is `saturated`; a reply the
  client cannot interpret is `unknown`. Both reject before any reservation.
  The observed service has 3 online engines, 96 schedulable vCPUs, 323796 MiB
  schedulable memory and 107520 MiB largest bootable memory. Pool totals must
  never be used as single-VM capacity. Catalog filtering uses the same profile
  check when capabilities are available; failed lookups retain the conservative
  six-size declaration. Explicit memory is aligned to 1024 MiB and bounded by
  4096..=107520 MiB and live capacity. `2xlarge` remains 32 vCPU/96 GiB.

Its mock transport uses UUID identifiers and the server's status codes, and
rejects what the server rejects (POST uploads, string commands, unknown labels).
Verified on the dev deployment on 2026-11-13: a `small` VM is created, enrols
about 26 s after the request, and is destroyed and gone at the provider. It has
2 vCPU, 8 GiB and a 98 GB root filesystem of which only about 14 GB is free on a
fresh VM (`/workspace` is on the same filesystem). Do not select `small` for
Lean builds: choose a larger capacity-checked profile and inspect actual free
disk before building. Not yet verified: the disk of the larger sizes, a mission on the VM,
snapshots, a warm image, and the guest's `LEANCI_*` cache variables.

## Lean provider transport contract

`lean/OrbCore/OrbCore/ManagedProvider.lean` defines the shared provider I/O
boundary. Its Boat adapter is checked with injected transport and sleep functions
by `ManagedProviderTests.run` in the Core self-test; these tests rent no machines.
This boundary is separate from admission, persistence, bootstrap and relay readiness.
`ManagedProviderRegistry.lean` owns the table of implemented providers; each adapter
and its declaration live in a separate file (`ManagedProviderBoat.lean`, etc.).
Declarations own sizes, integer milli-cent hourly prices, bootstrap mode, readiness
deadline and stop/resume, snapshot and extend capabilities. Resolution and quoting
use that same table. A known but unimplemented provider is not usable and must not
advertise capabilities. Catalog metadata is not evidence of live availability or
relay readiness. The registry refactor preserves Boat's size, quote and wire contracts;
provider contract tests check both registry lookup and adapter requests.

- Creation and fork require a stable idempotency key before any provider call.
  Boat receives `type`, `name`, `ttlSeconds`, `noEnv: true` and optional `from`
  (a saved snapshot). Never inherit the Boat account's environment into a guest.
- A successful response must contain a nonempty machine ID, either at the top
  level or under `sandbox`. Transport errors, malformed JSON and non-2xx status
  never manufacture a machine or a successful snapshot.
- List pagination encodes cursors and rejects malformed pages, repeated cursors
  and exhausted page limits. An incomplete list is an error, not evidence that
  unobserved machines disappeared.
- Boat guest-command readiness includes `ready`, `idle`, `running`, `busy`;
  nonbilling states include `archived`, `stopped`, `deleted`, `error`, `archiving`.
  Provider readiness alone must never mark a managed worker ready for dispatch:
  bootstrap and its first authenticated relay poll must complete within 360 s.
- Resume uses Boat fork, not `/start`; the returned provider identity may change
  without changing Core's managed identity. Core must fence the new boot epoch.
- Destroy succeeds only on DELETE 2xx or 404. Every other DELETE failure propagates;
  STOP is never a fallback or evidence of destruction. Explicit stop's `stop_failed`
  retries are bounded (3, 6, 9, 12 seconds). Extend PATCHes
  `ttlSeconds` at the provider, not just in SQLite.
- Named snapshots use `/saved-snapshots` and encoded names. Saving is distinct
  from observing `ready`. Errors omit upstream bodies and credentials.

### Reservation, guest bootstrap and observed readiness

`ManagedProvisioning.spawnManagedWorker` is the shared REST/MCP create pipeline.
It validates bootstrap configuration before renting, then atomically rechecks
capacity and spend and inserts a `provisioning` reservation before provider I/O.
The immutable Core ID is separate from `provider_id`; boot-specific credentials
and relay routing always use the Core ID. Request keys are scoped to the owning
user/mission and persisted uniquely, so retries cannot rent or claim a second VM.
A changed size, TTL, owner or image under an existing key is a conflict.
Creation uses the provider's size/TTL quote, rounded up to reserve the entire
lease; `estimated_cents` is not trusted. User-cap admission includes pending
reservations under the same transaction, and replaying a completed request does
not add another user spend charge.

Configured entry points accept the allowlisted base images (`orb-node-base`,
`provider-default`) or a saved snapshot of the caller's own project. Arbitrary image
names fail before reservation.

**Saved snapshots are project-scoped** (`ManagedSnapshotCatalog`). The provider's
`/saved-snapshots` list is the only evidence that one exists. A snapshot named
`orb-snap-<project>-<label>-<suffix>` belongs to the project its pre-cutover registry
record (`managed_snapshots.json`) names, otherwise to the longest known project slug its
name starts with. `list_managed_snapshots` returns the caller's project's snapshots;
`spawn_managed_machine(from_snapshot=...)` accepts a provider name or label, resolves it
inside that project, and refuses a missing, still-saving or ambiguous one. An unresolved
label never reaches the provider. Only an admin's operator session may name another
project. A failed provider list is an error, not an empty list.

The same resolution serves `start_mission(remote_node_id="auto-managed[:size]",
managed_from_snapshot=..., managed_ttl_minutes=...)` and the REST create route. For
`start_mission`, Core rents one Boat machine through the shared spawn path before creating
the child, then makes the child its owner and records the caller as requester; if the child
cannot be created or dispatched the machine is destroyed. `managed_from_snapshot` without
`auto-managed` is refused. On REST the project is the owning mission's when the caller
owns that mission; an admin may pass `project`. The call is synchronous: it returns once
the machine has made its first relay poll. Reuse of an idle sibling machine and the
fleet-wide `auto` scheduler are not implemented here.
Stop and destroy require provider success before committing local state. Resume
uses an archived Boat sandbox as a fork source, bootstraps a successor, and keeps
the same Core machine/node ID.

### TTL: explicit extension, expiry cleanup, operator probe (Lean Core)

The Lean Core implements a **fixed TTL with explicit extension only**. The retired
Rust server's busy auto-extension (`SANDBOXED_MANAGED_AUTO_EXTEND_MINUTES`, the
`auto_extended` ledger event, described further below) is **not implemented**; the MCP
tool text says so. A busy machine still stops at its TTL.

- **Extend** (`extend_managed_machine`, `POST /api/managed-machines/:id/extend`, legacy
  alias `/api/managed/machines/...`): `ttl_minutes`/`minutes` is an integer 5..=720 added
  to the current deadline, capped at 720 minutes after the current boot started (creation,
  or the resume that produced this boot). Core reserves the fixed target and the price
  difference under the admission transaction, then sends the provider the remaining seconds
  (`PATCH ttlSeconds` on Boat). Only a provider acknowledgement moves `expires_at_sec`.
  A definitive refusal releases the reservation; an uncertain outcome stays pending and is
  retried against the same absolute target, so a retry never adds the duration twice.
- **Who may extend through MCP:** the owning mission, its ancestors and its descendants
  (same tenant and project; not siblings), an external session of the owning user, and a
  Core-authenticated operator call whose verified user owns the machine. Role labels and
  request-body identities grant nothing. Both `<id>` and `managed-<id>` are accepted;
  anything else answers `not_found`.
- **Expiry** (`ManagedTtl.tick`, every 30 s): the owner mission gets a
  `managed_machine_expiring` event 20 minutes and again 5 minutes before the deadline
  (`minutes_before` in the payload), once each per deadline, so an extension re-arms both.
  The 20-minute event is skipped for a machine whose whole lifetime is shorter, and is not
  sent late if Core was down across it. These are mission events: they appear in the
  mission's event stream and are not injected into a running agent's context. At the deadline Core claims the expiry
  (which fences extensions, heartbeats and resume), emits `managed_machine_expired`, reads
  the provider's state and usage, destroys a still-billable guest, and only then closes the
  row and emits `managed_machine_expiry_cleaned`. An already archived, nonbilling disk is
  kept for recovery and the row becomes `stopped`. Provider errors leave the cleanup
  `pending` (row shown as `destroying`) and it is retried; nothing is marked done on
  silence. Spend is the provider's metered figure when it reports one, otherwise the lease
  reservation, labelled `lease_reservation_estimate`. Events are deduplicated per boot.
- **No live machine without a deadline:** a `ready` or `provisioning` row with
  `expires_at_sec = 0` (written before deadlines existed) gets creation time plus TTL,
  or one TTL from discovery when the creation time is unknown, and then follows the
  normal expiry path. An expired row never bound to a provider id is matched by exact
  sandbox name in the complete inventory: found once, it is bound and cleaned up on the
  next pass; absent, the row is closed without a provider call.
- **Operator authority:** a non-external session with role `operator` acts with the
  authority of the user who minted it (`mcp_sessions_v1.owner`, or the Core-authenticated
  caller): an admin's operator session manages any machine, another user's only that
  user's. The role label alone grants nothing, and external sessions cannot hold it.
  For a direct call (a Core login token, not a mission token) Core passes its own verdict
  that the caller is an administrator; the single-tenant administrator has no user id, so
  the verdict, not an id lookup, decides. A mission's own MCP token always carries the
  role `executor`: a mission reaches only its lineage's machines, whoever owns the mission.
- **Legacy owners:** pre-cutover rows may carry a tenant label (`prod`) in
  `owner_user_id`. At startup `repairManagedMachineOwners` replaces it with the owning
  mission's user when that user exists; other rows are left alone. For a mission-owned
  machine the owning mission's user decides lineage access. A missing owner is reported as
  `managed_user_missing:<id>`.
- **Operator probe:** `orb-core managed-inspect <id|managed-<id>|unique-prefix>...` prints,
  per machine, Core's row beside the provider's state (`provider_exists`, `provider_state`,
  `provider_billable`, `provider_usage_cents`). It is read-only.

### Existing Boat machines and resume

At startup and every 120 seconds, Core lists Boat inventory and reconciles only
registered machines. Pre-cutover empty `provider_id` values are backfilled by
exact sandbox name (`orb-managed-<Core id>` in prod). Ambiguous names are never
guessed. `archived`/`archiving` observations move a previously ready record to
stopped. A confirmed Boat `archived` observation also corrects falsely destroyed
or still-provisioning rows to stopped, under matching provider-ID and boot fences,
revoking enrollment/node credentials and clearing the old poll without enabling
compute or advancing the boot. This is an observation correction, not admission of
a destroyed-to-resume command; ordinary resume still requires the stopped phase.
Provider-ready observations never manufacture relay readiness or erase an
unreported cost. An unbound timed-out provisioning reservation can close only
against a complete inventory with no matching sandbox. Every Boat resume observes
the bound provider ID (including locally destroyed rows); unbound legacy rows first
repair identity through inventory. A genuine 404 remains destroyed and never forks.
The recovery regression uses Core `a6fed7e9-950b-40e8-ad83-4c599ceee4b4` and Boat
`bx_xcew9qru`: fork must use the Boat ID while retaining Core/node identity.
`mm5xvnw6ha`, `mm3dagt4ua`, and `mmp2t4xd94` are genuine missing-source regressions.
TTL likewise retains a phase-zero archived disk as stopped, never falsely destroyed.

A resume reserves capacity/cost and revokes the old credential before provider
I/O. A durable intent holds the source identity and successor boot. Only the
successor's authenticated poll atomically advances the boot epoch, marks ready,
and completes the intent. Retries cannot rent another successor. Stale inventory
observations are fenced by provider ID and boot epoch. Timeout cleanup first
fences late polls, destroys only the successor, then restores the retained stopped
source; old credentials never revive. Unknown provider outcomes remain pending
for reconciliation rather than claiming success or deleting the source.

The Core self-test replays archived pre-cutover rows, exact/ambiguous name
matching, missing and fresh reservations, on-demand legacy resume, preserved
machine/node identity, stale source observations, REST/MCP retry parity, old-token
and old-command rejection, and deadline/cleanup races.

The guest receives a one-use enrollment token through a private file, not a
command argument. `scripts/orb-node-provision.sh` installs the current node,
clears inherited node credentials and projected mission secrets, starts its
unprivileged systemd service, and enables its user bus for remote jobs.
Enrollment alone never changes readiness: the first authenticated relay poll
atomically commits the verified provision transition and `last_poll_sec`.
Unauthenticated and stale-boot polls cannot do so. Per-machine poll timestamps
survive Core restarts.

Bootstrap timeout destroys the provider VM before applying the ordinary verified
destroy transition, including cost-ledger closure. Phase-0 reservations are
eligible for destroy under the same boot, owner, idle and minimum-lease guards
as other live phases. Uncertain provider creation or cleanup remains visible as
a reservation for reconciliation; it is never reported ready or silently lost.

Before enabling managed creates, install `scripts/orb-node-provision.sh` as a
root-owned, non-writable asset at `/usr/local/lib/orb/orb-node-provision.sh`
(or set `ORB_NODE_PROVISION_SCRIPT`). Configure `SANDBOXED_MANAGED_CORE_URL`
(or `SANDBOXED_PUBLIC_URL`) to the public HTTPS Core origin reachable by guests.
Missing configuration rents nothing. Tests run from the repository root may use
the repository script as a fallback. The virtual-time Core self-test replays
successful enrollment/poll, the 360-second timeout, cleanup, provider rejection,
uncertain creation, retry conflicts, and admission before provider I/O.

## Ownership & Lineage

| Field | Meaning |
| --- | --- |
| `owner_mission_id` | The mission the VM serves. Its lifetime governs the VM. |
| `requested_by_mission_id` | The mission that rented it for the owner (e.g. the caller of `start_mission(remote_node_id="auto-managed")`). Informational: it never keeps the VM alive. |
| `root_mission_id` | Root ancestor mission of the owner tree, resolved server-side at spawn/claim. |
| `project` | Project slug of the owning mission, used for UI attribution and snapshot scoping. |
| `active_mission_ids` | Live worker missions currently executing remote jobs or holding leases on `node_id`. |
| `has_executed_job` | Monotone sticky flag set once the node has executed at least one remote job/lease. |
| `deletable_at` | Optional provider minimum-lease timestamp (e.g. Scaleway Apple Silicon 24h `deletable_at`) before which provider deletion is forbidden. |
| `owner_kind` | `mission` or `user` (created from Orb/API without a mission). Absent = legacy row, shown as "No owner". |
| `owner_user_id` | Tenant whose mission store holds the owner. Set from the authenticated caller, never from a body. |

Provider choice (`chooseManagedProvider`, one function for every MCP spawn path):

| Request | Provider used |
| --- | --- |
| Names a provider (`provider=`, `auto-managed:<provider>[:<size>]`) | That provider, never replaced; its refusal is the caller's error. |
| Names none, instance default can take it | The instance default (`SANDBOXED_MANAGED_DEFAULT_PROVIDER`, else `boat`). |
| Names none, default cannot take it now, `boat` can | `boat`; the result carries `provider_fallback: {from, to, reason}`. |
| Names none, neither can | The default; the caller gets the default's own error. Nothing is rented. |
| Names none, with a snapshot, or a fork | The default (a snapshot or a source disk lives at one provider). |

"Cannot take it" is `managedSpawnRefusal`: the user has not enabled the provider, it is
not configured, the operator disabled it, the size (same name) is not offered now, spend
or concurrency admission refuses, or the availability preflight reports no capacity. A
retry with the same idempotency key stays on the provider its first attempt reserved on.
`POST /api/managed-machines` is an explicit choice from a client and keeps its own rule:
no `provider` means `boat`, `auto` means the instance default if the user enabled it,
else the first provider they enabled.

lean.ci sizes are priced at zero: quote, recorded cost and daily spend add nothing, and
neither the global nor a user's daily cap refuses a zero-cost machine (concurrency, TTL
and the fleet switch still apply). Extension is per provider (`supports_extend`); the
lean.ci switch is `leanciDeclaration.supportsExtend`.

Creation paths:

- `spawn_managed_machine` (gateway): owner = calling mission.
- Child / subagent default placement (`start_mission`, `consult_model`, and
  direct `POST /api/control/missions` with `parent_mission_id`, no `cloud`, and
  no `placement`):
  - Omitting `remote_node_id` defaults to Boat (`"auto-managed:boat"`), **not**
    the parent's machine, so waiting parents never starve their own host slots.
  - When `remote_node_id` was omitted and Boat provisioning is disabled or the
    child's effective backend fails `managed_backend_auth_precheck` (`grok` has
    no login on `orb-node-base`; `vibe` lacks `vibe-acp` on `orb-node-base`;
    `antigravity` requires `antigravity_on_managed` + an allowed owner), Core
    falls back cleanly to `"auto"` (fleet-wide least-loaded static scheduler),
    never pinning to the parent's node.
  - Explicit `remote_node_id = "auto-managed[:provider[:size]]"` keeps
    fail-closed `400 Bad Request` validation when Boat or managed harness auth
    is unavailable.
  - Explicit `remote_node_id = "same"` preserves parent co-location
    (`fork-workspace:<parent_id>`, `working_directory`, or `worker-client:<owner>`
    for `placement:client` parents) when the child must inspect uncommitted
    local files in place.
- Server-side `auto-managed` resolution (`POST /api/control/missions`): Core
  validates the launch first (`validate_only` or full admission: model, harness
  auth precheck, project caps, sub-budget). A rejection rents nothing. Under
  `worker_location::dispatch_lock`, Core reuses an unclaimed retry reservation
  keyed by `(tenant, parent_mission_id, idempotency_key)` if an earlier attempt
  timed out before claim, else reuses an idle sibling VM of the same
  provider/size/image (`reuse_idle`), else spawns a fresh VM in light mode
  (clean `orb-node-base` image with no snapshot files restored by default; a
  warm Boat project snapshot is restored only when `managed_from_snapshot`
  explicitly names a snapshot or `"latest"`). Once
  the child mission is created, Core atomically claims the VM for the child
  (`owner_mission_id = child`, `requested_by_mission_id = parent`); if mission
  creation fails, the rented VM is destroyed (`requested: launch_failed`).
- A child that targets or extends a VM rented by an ancestor is a tenant:
  `extend_managed_machine` adopts the VM only when the current owner is a
  descendant of the caller, never an ancestor, so a parent's shared VM is not
  released when a child completes.
- A mission whose harness is Hermes calls `start_mission` through the
  assistant connector with `origin_session_id = orb_<mission uuid>`. Core
  makes that mission the parent when it exists in the caller's store (an
  `orb_<id>` session belongs to exactly one mission; shared chat sessions do
  not create lineage).
- Orb/API create without a mission: `owner_kind = user`, with the TTL the user
  chose.
- `POST /api/managed-machines/:id/owner {owner_mission_id}`: backfill. Only an
  unowned machine of the caller's own tenant, for a mission in the caller's
  store.

Claim rules (`claim_for_mission`): 403 when the machine belongs to another
tenant; 409 unless the machine has no owner or is owned by the requester; the
requester comes from server-resolved lineage, never from a request body.

## Decision table

Evaluated every reaper pass (30 s, or immediately when a mission or remote job
transitions) for each online VM via `orb_vm_lifecycle_step`. `busy` = the node
reports active jobs, leases or queued jobs (any mission). `idle` = time since
`last_busy_at` (set to `now` whenever `busy` is observed, along with sticky
`has_executed_job = true`).

| # | Condition | Decision | `destroy_reason` |
| --- | --- | --- | --- |
| 1 | `now >= expires_at` | destroy (even if busy), or defer to `deletable_at` when `now < deletable_at` | `ttl_expired` (`awaiting_deletable_at:ttl_expired` while deferred) |
| 2 | busy | keep, clear any schedule | |
| 3 | owner terminal (completed, failed, not\_feasible, cancelled, acknowledged, archived) | destroy after `owner_grace` from first observation (or defer to `deletable_at`) | `owner_<status>` |
| 4 | owner deleted | destroy after `owner_grace` (or defer to `deletable_at`) | `owner_missing` |
| 5 | owner interrupted / awaiting\_user / blocked / paused since `t` | **stop** (`supports_free_stop == true`) or **destroy** (`false`) at `max(t + waiting_grace, last_busy + idle)` | `owner_<status>_idle` |
| 6 | owner working (pending, active, waiting\_background) | destroy when idle > `post_job_working_idle` (`has_executed_job`) else `working_idle` (`0` = keep) | `working_owner_idle` |
| 7 | owner state unknown (neither loaded nor persisted offline store knows tenant) | keep | |
| 8 | user-owned | destroy when idle > `idle` (or defer to `deletable_at`) | `idle_user_owned` |
| 9 | no owner (legacy) | destroy when idle > `idle` (or defer to `deletable_at`) | `idle_no_owner` |

A rule whose due time is in the future (or gated by `now < deletable_at`) is
persisted as `reap_at` / `reap_reason`; clients show "Reaps in X (reason)".

Defaults (env): `SANDBOXED_MANAGED_IDLE_MINUTES` 15,
`SANDBOXED_MANAGED_WORKING_IDLE_MINUTES` 15,
`SANDBOXED_MANAGED_POST_JOB_IDLE_MINUTES` 10,
`SANDBOXED_MANAGED_OWNER_GRACE_MINUTES` 2,
`SANDBOXED_MANAGED_WAITING_GRACE_MINUTES` 15,
`SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES` 60 with
`SANDBOXED_MANAGED_AUTO_EXTEND_MINUTES` 30 (a busy VM within 10 minutes of
its TTL is extended by one chunk if its budget pool and the daily cap allow),
`SANDBOXED_MANAGED_ORPHAN_GRACE_MINUTES` 10,
`SANDBOXED_MANAGED_RECONCILE_SECS` 120.

`owner_probe` inspects both loaded in-memory mission stores and persisted
offline SQLite stores (`persisted_mission_store`), so a Core restart never
leaves terminal or waiting owners permanently unknown.

Owner death cascades through the tree: a descendant still running on the VM
holds a lease, so rule 2 protects it; once nothing runs there, rule 3 or rule 6
applies.

## Budgets (optional, off by default)

A mission may carry `budget_usd` (Orb: right-click a mission, "Mission
settings…"; agents: `start_mission(budget_usd=…)` for a child, `get_budget`).
It is a pool shared by the mission's subtree. A descendant given its own
budget gets a sub-pool carved from the nearest ancestor pool; the grant must
not exceed that pool's remaining amount (`sub_budget_exceeds_pool`). Without
any pool in its lineage a mission is limited by the shared global daily cap
(`daily_cap_usd`). When a mission draws from an active mission budget pool
(`mode = "own"` or `"pooled"`), that pool **overrides (bypasses) the shared
global `daily_cap_usd`**, and spend/commitments charged to a mission budget
pool do not consume `daily_cap_usd` for un-budgeted missions.

Each VM records `budget_pool_id` at create (the pool of its owner, or of the
child it is claimed for). Per pool, derived from the registry
(`src/managed/budget.rs`):

- `spent` = metered (or estimated so far) cost of its VMs within the pool's
  active window (`total` = lifetime, `daily` = `[00:00 UTC, +24h)`, `weekly` =
  `[ISO Monday 00:00 UTC, +7d)`, attributed per ownership/run segment in
  `billed_segments` so pool transfers and stopped idle gaps never leak across
  reset boundaries; `lifetime_spent_usd` always reports cumulative all-time pool spend);
- `reserved` = for each live VM, `min(remaining TTL, 60 min) × usd_per_hour`;
- `carved` = each child pool's budget while its owner runs, and once the owner
  is terminal only what that child used inside the parent pool's active window
  (unused money — and prior-period spend on daily/weekly root pools — returns);
- `available = budget − spent − reserved − carved`.

Root budget pools (`parent_pool_id = None`) may set `budget_reset_period` to
`"total"` (default), `"daily"`, or `"weekly"`. Sub-budgets carved from an
ancestor pool (`parent_pool_id = Some(_)`) must use `"total"` so a child grant
cannot reset independently and overdraw its parent pool.

Checked under the admission lock at `spawn_managed_machine`, marketplace
fallback offer re-quotes, `resume`, `start_mission` auto-managed (before
renting), `extend_managed_machine` and auto-extend (each needs
`min(minutes, 60) × price`), and sub-budget grants. Refusals are
`402 budget_exceeded` with the remaining amount. Missions without an active
pool in their lineage (`mode = "none"`) are bounded by the shared global daily
cap (`none` = unlimited), counting only un-pooled spend and commitments.
`list_managed_machines` surfaces `mission_budget` alongside
`effective_vm_limits` so coordinators see their active mission budget pool even
when `budget.daily_cap_usd` is lower. Budgets persist in
`.sandboxed-sh/mission_budgets.json`; ledger events
(`budget_pool_set`, `auto_extended`, `reused_idle`) go to the managed ledger.

## Mission concurrency overrides (`vm_limits`, optional, off by default)

Operators can configure `vm_limits` on any mission via `PUT
/api/control/missions/:id/budget` (dashboard JWT only; `mcp1.*` agent tokens
are rejected with `403`, and agents can only read via `get_budget` and
`list_managed_machines`). Persisted alongside `BudgetPool` in
`.sandboxed-sh/mission_budgets.json` (independent of whether `budget_usd` is
set):

- `max_concurrent`: optional subtree concurrent VM limit (`1..=128`);
- `provider_max_concurrent`: optional map of canonical provider (`boat`, `leanci`,
  `hetzner`, `vastai`, `scaleway`) to concurrent limit (`0..=128`; `0` blocks
  that provider for the subtree). At least one of `max_concurrent` or a
  provider entry must be present when `vm_limits` is enabled.

Scoped vs. shared pool accounting (`orb_vm_cap_admit`):

1. Resolve the nearest mission `L` in the target mission's lineage (`self` then
   ancestors, same tenant) that defines `vm_limits`.
2. If `L` covers `provider` (`L.max_concurrent.is_some()` or
   `L.provider_max_concurrent.contains_key(provider)`), the VM is admitted into
   **`L`'s dedicated cap pool** (`cap_pool_id = Some(L)`):
   - checks `L`'s live count on `provider` `< provider_max` (when set) and `L`'s
     live overridden count `< max_concurrent` (when set);
   - checks every higher ancestor pool in the lineage that also covers
     `provider`, so a child override can restrict a subtree (`<=` parent) but
     never amplify an ancestor's cap;
   - **bypasses the shared global `max_concurrent`**, and VMs with
     `cap_pool_id.is_some()` do not consume slots in `shared_global_active`
     when un-overridden missions spawn.
3. Otherwise (`cap_pool_id = None`), admission checks
   `shared_global_active < global.max_concurrent`.
4. Enforced identically across `spawn` (fresh + `fork`), `resume`,
   `take_idle_sibling_for_provider`, and `claim_for_mission`. Removing or
   editing `vm_limits` re-attaches live VMs' `cap_pool_id` to the nearest
   covering ancestor (or `None`).
5. `GET /api/control/missions/:id/budget` and MCP `list_managed_machines`
   surface `effective_vm_limits` (`mode`, `max_concurrent`, `active`, and
   per-provider `active`/`max_concurrent`) so orchestrators see their dedicated
   slots even when the shared global pool is full.

## Mission bandwidth & pacing (`bandwidth_limits`, optional, off by default)

Operators can configure `bandwidth_limits` on any mission via
`PUT /api/control/missions/:id/budget` (dashboard JWT only; persisted alongside
`BudgetPool` in `.sandboxed-sh/mission_budgets.json`, independent of `budget_usd`
and `vm_limits`):

- `tokens_per_min`: optional LLM throughput ceiling (`1_000..=100_000_000`
  tokens/min across uncached + cached input + output tokens; reasoning tokens
  are already included in output and never double-counted) for the pool's subtree;
- `inference_usd_per_hour`: optional LLM dollar burn ceiling (`0.01..=10_000.0`
  USD/hour estimated from model token pricing, including cache read/write rates)
  for the pool's subtree;
- `compute_vcpu_per_min`: optional active managed-VM vCPU bandwidth ceiling
  (`1..=4_096` vCPU-min/min, i.e., active vCPU across live VMs in the pool);
- `compute_usd_per_hour`: optional active managed-VM dollar burn rate ceiling
  (`0.01..=10_000.0` USD/hour across live VMs in the pool);
- `protect_root`: boolean (`false` by default). When `true`, VMs directly owned
  by the pool's root mission (`owner_mission_id == pool_id`) bypass transient
  pacing delays while pooled child missions (including auto-managed child spawns
  with `owner_mission_id = None` and `requested_by_mission_id = parent`) absorb
  the smoothing delay.

Hierarchical inheritance & pace/delay enforcement:

1. **Ancestor monotonicity:** A child mission's `bandwidth_limits` cannot exceed
   any ancestor bandwidth pool's configured `tokens_per_min`,
   `inference_usd_per_hour`, `compute_vcpu_per_min`, or `compute_usd_per_hour`
   (`sub_bandwidth_exceeds_pool`). Removing or editing `bandwidth_limits`
   re-attaches descendant bandwidth pools and live VMs' `bandwidth_pool_id` to
   the nearest ancestor bandwidth pool, and immediately wakes any in-flight
   paced requests.
2. **Inference token & dollar pacing (`src/managed/pacing.rs` & `src/api/proxy.rs`):**
   Every routed LLM proxy request (`/v1/chat/completions`, `/v1/responses`,
   `/v1/messages`) attributed to a mission checks all bandwidth pools in its
   lineage (skipping a pool whose `pool_id == mission_id` when `protect_root` is
   `true`). Each pool maintains continuous-refill token and USD debt ledgers
   charged on response/stream completion (`record_proxy_usage`). When a pool's
   token or inference-USD debt is positive, incoming requests sleep transparently
   before upstream dispatch (`delay_ms = min(max(token_delay, usd_delay), 30_000 ms)`)
   while keeping `proxy_liveness` active so stall watchdogs never misclassify
   intentional pacing as a hung CLI. No synthetic `429` is returned to the harness.
3. **Managed compute bandwidth pacing (`ManagedManager::spawn` & `resume`):**
   Before acquiring the final admission lock, if the mission's governing
   bandwidth pool sets `compute_vcpu_per_min` or `compute_usd_per_hour`:
   - if the single requested VM alone exceeds the pool's entire ceiling
     (`effective_cpu > compute_vcpu_per_min` or
     `effective_usd_per_hour > compute_usd_per_hour`), Core fails fast with
     `429 bandwidth_exceeded` since waiting can never admit it;
   - otherwise, while active subtree compute + the requested VM exceeds the
     ceiling (unless `protect_root` exempts a VM with `owner_mission_id == pool_id`),
     Core paces outside `self.admission` (up to `45s`) and atomically re-verifies
     compute capacity under `self.admission` (looping back to pace if a concurrent
     admission consumed capacity), as well as re-evaluating marketplace fallback
     offers before accepting higher CPU or hourly burn.
4. **Surface & runway forecast:** `GET /api/control/missions/:id/budget` and MCP
   `list_managed_machines` return `own_budget_reset_period`, `own_bandwidth_limits`,
   `bandwidth_mode` (`"own" | "pooled" | "none"`), `bandwidth_pool_id`, and
   `effective_bandwidth` (including live `current_tokens_per_min`,
   `current_inference_usd_per_hour`, `current_vcpu_per_min`,
   `current_compute_usd_per_hour`, `pacing_active`, and `paced_delay_ms`). Orb
   renders Mission Settings as a full-page view (`ms:<id>`) with a top compact
   spend/runway forecast chart showing observed burn, `now`, reserved hold, cap
   line, estimated time until budget exhaustion (`max(0, cap_usd - spent_usd - carved_usd)`),
   periodic reset sustainability when `eta_secs >= resets_in_secs` (inherited by
   `pooled` child missions sharing a daily/weekly ancestor pool), and live VM
   lease-extension cliff based on the `30m` auto-extend reservation threshold
   (`extension_step_usd = 0.5h × per_vm_usd_per_h` at `<= 10m` remaining lease)
   when active reservations or insufficient unallocated headroom will pause
   auto-extensions before unspent funds hit zero.

## Provisioning

`scripts/orb-node-provision.sh` is the one guest script for every provider. Core
delivers it with a private `enroll.env` through the provider's file call and runs
it as root; Core serves the installed copy
(`/usr/local/lib/orb/orb-node-provision.sh`, or `ORB_NODE_PROVISION_SCRIPT`, which
lets a dev instance use its own copy without touching the one prod serves).

In order, the script:

- creates the `orbnode` user and its work directory, and installs `enroll.env` as
  `/etc/orb/enroll.env` (root, 0600);
- removes a cached node identity and delivered mission secrets, so a fork or a
  restored snapshot never reuses its parent's;
- downloads the node from `GET /api/managed-machines/bootstrap-binary/:id` and
  refuses anything that is not an x86_64 ELF (checked with `od`, so a minimal
  image without Python can still enrol). It sets the mode of every directory on
  the binary's path explicitly, because the script runs with umask 077 and some
  coreutils builds create missing parents with the umask; then it checks, as
  `orbnode`, that the binary is executable and fails with the path's
  permissions and mount options if it is not (first seen on lean.ci, where the
  unit restarted with 203/EXEC "Permission denied" until the deadline);
- on a lean.ci guest, copies the provider's `LEANCI_*` settings, including the
  VM-scoped cache token, to `/etc/orb/leanci-env` (root:orbnode, 0640), sourced by
  `orbnode` login shells. lean.ci writes them only for its own `runner` user, in
  provider-owned profile and environment files.
  The token exists only when the VM was created with a `repo`, and expires an
  hour after the VM's TTL. lean.ci blanks its own files before a snapshot but not
  this copy, so a snapshot taken through Core must remove `/etc/orb/leanci-env`
  first;
- starts the node. With systemd it writes the `orb-node` unit and its enrolment
  drop-in (including `SSL_CERT_FILE`, without which the node's static OpenSSL
  cannot verify Core), enables the user bus for remote jobs and starts the unit.
  **Without systemd** (a Colab runtime) it starts
  `/opt/orb/bin/orb-node-supervise` in its own session, detached from the
  provider's exec call: a restart loop that runs the node as `orbnode` with a
  minimal environment (the enrolment values, `SSL_CERT_FILE`, and only the
  accelerator variables `NVIDIA_*`, `CUDA_*`, `TPU_*`, `PJRT_*`,
  `LD_LIBRARY_PATH`, `COLAB_GPU` from the runtime), handed over through the
  environment and never on a command line. The enrolment file is read without
  being evaluated by a shell. A second run stops the previous loop first, after
  checking that the recorded PID still is one. Output goes to
  `/var/log/orb-node.log`, which only root can create.

Every bootstrap also logs what the provider delivered: one guest line with the
CPU count, memory, root and `/workspace` disk sizes and the GPU name, next to the
requested size, so the catalog can be checked against real machines.

A bootstrap that fails says where. Core logs one `[managed-bootstrap]` line per
stage (provider ready, files delivered, script finished) with the machine ID and
elapsed time, and the failure is one of:
`managed_bootstrap_timeout_provider_not_ready` (the provider never reported the
machine ready; the last state it gave is logged),
`managed_bootstrap_timeout_during_delivery`, `managed_bootstrap_launch_failed`
(the script exited with an error; its output is logged), or
`managed_bootstrap_timeout_no_relay_poll`. In the last case Core asks the guest,
before destroying it, for PID 1 and architecture, the permissions and mount of the
node binary's path, the unit's user and command, the unit state, the node process count, whether
it can reach Core's `/api/health`, and the tail of the node's log. Guest text is
logged with the enrolment token removed, control characters dropped, bounded to
4000 characters, and one prefixed line per guest line. None of it goes into the
action receipt.

Starting the node is not readiness: only the first authenticated relay poll,
inside the provider's deadline (360 s Boat, 480 s lean.ci, 900 s Colab), marks
the machine ready; otherwise Core destroys it.

### Google Colab adapter

`ManagedProviderColab.lean` is the `colab` client for the `colab-api` service on
the Core host (`http://127.0.0.1:8790/v1`, `COLAB_API_URL`, token
`COLAB_API_TOKEN` sealed in Core). Its wire contract was read from the service
source (`Th0rgal/colab-api`):

- The control API speaks GET and POST only. Create is `POST /notebooks` with the
  machine name (the service is idempotent on the name), the accelerator
  candidates for the size and `worker: true`. Delete is
  `POST /notebooks/:id/delete`. IDs contain `~` and `@` and are percent-encoded.
- The service tries each requested accelerator in turn before it answers, so
  the per-candidate wait is divided to keep the whole create call near seven
  minutes; the 900 s readiness deadline, which starts before the call, covers it.
- A runtime is ready for commands only once its worker tunnel URL is published;
  a record that is connected but has no tunnel URL yet is not ready.
  The worker is called at that URL with a per-runtime token from the notebook
  record; a URL that is not HTTPS is refused.
- Commands are `POST /exec` on the worker (`bash -lc`, working directory
  `/content`). A timed-out command has no exit code and is a failure. An answer
  from the tunnel edge (502, 503, 530) is retried once after re-reading the
  record; a lost connection is not, since the command may have run. The worker's
  upload route cannot leave `/content`, so files are written through `exec` as
  base64, mode 0600.
- Sizes `colab-auto`, `t4`, `l4`, `a100`, `h100`, `v5e1`, `v6e1`, shadow-priced
  at half the Vast.ai rate. `colab-auto` asks for H100, A100, L4, T4 in that order.
- No snapshots and no stop/resume. A runtime has no lease at the provider, so
  extending changes nothing there and Core's TTL is the only one.
- Availability: no usable account, every usable account already running a
  notebook, or the requested accelerator not eligible is `saturated`; an unusable
  account is `degraded`. Cached 30 s.

Verified on the dev deployment on 2026-11-13: a `t4` runtime publishes its
tunnel in about 17 s, the node started without systemd enrols about 40 s after
the request and stays up, the guest reports a Tesla T4 with 2 vCPU, about
12.7 GiB and a 113 GB disk, and the notebook is deleted on destroy. The other
sizes are not verified.

## Automatic placement on the static fleet

Code: `lean/OrbCore/OrbCore/AutoPlacement.lean`, applied by `start_mission`.

A mission started through MCP with no node of its own inherits its parent's node
and workspace. When there is none to inherit, or `remote_node_id` is `auto`, Core
chooses a static node once and records it as `remote-node:<id>`, so later turns
stay with the workspace.

- **Exclusions.** A mission tag `exclude-node:<id>` binds that mission and every
  descendant. `start_mission(exclude_nodes: [...])` adds exclusions for the child
  and its descendants; they are written as tags on the child. Naming an excluded
  node is refused (`placement_excluded`). A parent's node that the lineage
  excludes is not inherited, and neither is its workspace.
- **Eligibility.** Cordoned nodes and control-plane or admin-only nodes are never
  chosen automatically; a caller allowed to use one names it.
- **Choice.** Fewest non-terminal jobs in Core's ledger; configuration order
  breaks ties. Reachability is not probed.
- **No fallback.** If a fleet is configured and no node is eligible, the call
  fails with `placement_failed: no_eligible_node` and no mission is created.

A mission whose stored tag is still `remote-node:auto` (created before this
rule, or through REST) resolves as before to the first configured node, and its
children stay with it unless that node is excluded.

## Reusing an idle VM for the next child

Code: `lean/OrbCore/OrbCore/ManagedReuse.lean`, applied by `start_mission(auto-managed[:size])`.

Before renting, Core looks for a VM it can hand to the new child. All of these
must hold:

- it was rented by this same caller for an earlier child (requester is the
  caller, owner is that child), with the same provider, size, owner user and
  project; a VM a mission spawned for itself is never taken;
- that child has ended (`completed`, `failed`, `cancelled`, `archived`,
  `acknowledged`); a child that is `awaiting_user` or `interrupted` may continue
  and keeps its VM;
- the VM is running, not cordoned, polled within the last 2 minutes, has no
  non-terminal job in Core's ledger, has no expiry in progress, and has at least
  15 minutes left;
- the call does not ask for a snapshot (`managed_from_snapshot` always rents).

The transfer is one compare-and-set on the owner, so concurrent starts cannot
both take the same VM. Nothing is rented and no budget is reserved. The expiry is
not reset: the result carries `managed_machine_reused` and
`managed_machine_expires_at_sec`, and the child extends if it needs longer. If
the start then fails, the previous owner is restored and the VM is not destroyed.

An auto-managed VM is not released when its child ends. It runs until its TTL or
until `destroy_managed_machine`.

## Unnamed managed targets

A mission whose stored target is `auto-managed[:size]` (or `auto` when no static
fleet is configured) is dispatched to a ready managed machine chosen at dispatch
time. The choice is confined to the mission: a machine owned by that mission or
one of its ancestors, or a user-owned machine of the mission's own user. A ready
machine of any other mission or user is never used; with none in scope the
dispatch fails with `no_managed_machines_available`. A machine's sandbox name
resolves under the same rule; a `managed-<id>` node id is used as given. `start_mission` does not
rely on this: it rents or reuses a machine and records its concrete node id.
Mission creation over REST with `auto-managed` does not rent a machine.

## Harvesting a file from a VM

Code: `lean/OrbCore/OrbCore/ManagedHarvest.lean`, tool `harvest_managed_file(machine_id, path)`.

A mission brings a result back from a managed VM without the VM holding any
credential and without the content entering a transcript. Authorization is the
same lineage rule as the lifecycle tools; a caller outside it gets `not_found`.

- The path must be inside the VM work directory (`/var/lib/orb-node/work`;
  relative paths start there). `..` and control characters are refused before any
  command is built, and the guest resolves symlinks and refuses a target outside
  the work directory, so a link to the enrollment file cannot be read.
- Only regular files up to 20 MiB (`max_bytes` can lower this). The limit is the
  node's single-upload limit.
- Core reads the size and SHA-256 on the guest, then the content through the
  provider command API in 72 000-byte chunks (96 000 base64 characters), re-hashes
  what it received, and fails closed on any size, chunk or digest disagreement
  (`harvest_file_changed`, `harvest_checksum_mismatch`). The provider's own file
  API is not used: Boat's serves only `/home/user` and `/tmp` as UTF-8.
- Delivery goes to the node the calling mission's latest job ran on (a stored
  target such as `auto` is resolved first, never used as a node name), as an ordinary upload
  (`uploads/<uuid>/<name>` under the node work directory), and the node's receipt
  digest must match. A mission on the Core host gets
  `<working_directory>/harvest/<uuid>/<name>`; an operator session with no mission
  gets it under the Core data directory. External sessions without a mission are
  refused.
- The reply is `machine_id`, `source_path`, `node`, `path`, `bytes`, `sha256`,
  `chunks`.

## Snapshots, forks, stop

Code: `lean/OrbCore/OrbCore/ManagedSnapshotCatalog.lean` (naming and scope, pure),
`saveProjectSnapshot` / `deleteProjectSnapshot` / `projectSnapshotEntries` in
`RemoteFleetAndRelay.lean`.

The provider's saved-snapshot list is the only store. A snapshot's provider name
is `orb-snap-<project>-<label>-<suffix>`, and that name is what places it in a
project; the pre-cutover `managed_snapshots.json` only supplies project and
label for older names.

- **Save** (`snapshot_managed_machine`): the caller must manage the machine, have
  a project, and the machine must be running. The label is slugged; a label is
  taken until its snapshot is deleted or failed. Core first removes the
  credential files its own bootstrap wrote for this VM (`/etc/orb/leanci-env`
  and `/etc/profile.d/zz-orb-leanci.sh`, the copy of lean.ci's VM-scoped cache
  token) and `sync`s; if that command fails the snapshot is not taken
  (`managed_snapshot_scrub_failed`). The running VM loses those settings until
  it is provisioned again. Nothing else is removed: mission files, checkouts and
  any credential a mission placed on the VM are saved as they are.
- **List** (`list_managed_snapshots`): the caller's project only.
- **Delete** (`delete_managed_snapshot`): by label or provider name, resolved
  inside the caller's project; a name from another project is `not_found` and
  never reaches the provider. An ambiguous label deletes nothing.
- **From a snapshot**: `spawn_managed_machine(from_snapshot)` and
  `start_mission(auto-managed, managed_from_snapshot)` resolve the label inside
  the caller's project before anything is rented.
- **Fork** (`fork_managed_machine`): the source must be running and managed by
  the caller. The fork goes through the same path as a spawn (reservation, user
  cap, bootstrap, readiness on its own authenticated poll) with the provider's
  fork call in place of create; it has the source's size and the caller owns it.
  The bootstrap script stops the copied node service and deletes the copied
  `node.cred` before enrolling. Until it runs, a forked or restored guest may
  briefly start the copied node service with the source's identity.
- The REST routes under `/api/managed-machines/.../snapshot` still use the
  pre-cutover code and are not project-scoped.
- **Stop / resume** (`supports_free_stop == true`, `boat`): stop keeps the disk
  (`Stopped`, unregistered, no billing). Resume forks the stopped sandbox and
  keeps the machine's id, node id, owner and pool; cost of earlier runs is kept
  in `cost_before_resume`. Names of `Stopped` rows stay reserved in
  `allocate_name` so live allocations never collide with resumable machines.
- **Reaper**: rule 5 (owner interrupted/awaiting/blocked/paused and idle)
  stops instead of destroying (`stopped_by_reaper`) only when
  `provider.supports_free_stop()` is true, and destroys otherwise so stopped
  disks/VMs never keep billing. A stopped machine is closed after
  `SANDBOXED_MANAGED_STOPPED_RETENTION_HOURS` (24) or when its owner ends.
- **Snapshot cleanup** (each reconcile pass, dry-run aware): keep the newest
  `SANDBOXED_MANAGED_SNAPSHOT_KEEP` (2) ready snapshots per project, delete
  ones unused for `SANDBOXED_MANAGED_SNAPSHOT_UNUSED_DAYS` (14) and failed
  saves; never one a provisioning machine is being created from.

## Reconciler & Crash Recovery (every `reconcile_secs`, per provider)

- Every provider spawn attaches `orb-managed-<id>` atomically in the initial
  create request (`name` + provider labels/tags) so no crash window leaves an
  unnamed sandbox.
- On `ManagedManager::load()`, stale `Provisioning`/`Enrolling` rows without a
  `provider_id` left behind by a prior Core process are closed as `Failed`
  (`core_restarted_during_provision`) so they neither consume concurrency slots
  nor exempt crash-window orphans from reconciliation.
- Provider VM with our name prefix/tag and no live registry row (and no spawn in
  flight for it): destroy after `orphan_grace` from first sighting (respecting
  `deletable_at` if present).
- Live row whose provider VM is stopped: destroy (`stopped_by_provider`).
- Live row whose provider VM is missing from two consecutive non-empty
  listings: mark destroyed (`provider_vanished`) without a provider call and
  close the ledger. An empty listing never closes rows.

## Dry run

`managed_settings.json` `reaper_dry_run` defaults to **`false`** (active
reaping enforced out of the box; env `SANDBOXED_MANAGED_REAPER_DRY_RUN=1`
enables dry-run; `PUT /api/managed-machines/settings` merges partial bodies).
In dry run, rules 3-9 and orphan stops are recorded (`would_reap` in the ledger
once per machine and reason, `reap_at` on the row) but nothing is destroyed.
TTL always enforces. `GET /api/managed-machines/reap-plan` returns the current
decision for every live VM.

## Invariants

1. Every VM created after this change has `owner_kind` set; a mission-created
   one has `owner_mission_id`.
2. No lifecycle rule destroys a busy VM; only the TTL does.
3. A VM is never destroyed because of an owner whose state is unknown.
4. The requester's liveness never extends a VM's life, and a `Working` owner's
   idle worker VM is bounded by `working_idle` / `post_job_working_idle`.
5. No provider `destroy` is issued while `now < deletable_at`; expiration defers
   to `reap_at = deletable_at`.
6. Every destroy records a canonical `destroy_reason`.
7. A machine of tenant A is never claimed by tenant B (`orb_vm_claim_step`).
8. Cloud provider API keys (`CoreReserved`) are never disclosed to agent tasks,
   and untrusted `managed-*` nodes receive only allowlisted secrets
   (`orb_compute_secret_gate`).

## Formal Lean Kernel Gates (`lean/Orb/Kernel.lean` & `lean/Orb/Spec.lean`)

- `orb_vm_step`: admission (`size_rank`, `max_concurrent`, `ttl_minutes`,
  `job_mem_pct`, `daily_cap_cents`), reap safety gate, and reconcile actions.
- `orb_vm_lifecycle_step`: full 9-rule lifecycle decision stepper (`keep`,
  `schedule`, `stop`, `destroy`, `deferForMinLease`) covering `Working`-parent
  idle reaping, `supportsFreeStop` partitioning, and `deletable_at` deferral
  (Corollary 81).
- `orb_vm_claim_step`: tenant isolation + requester lineage gate for
  `claim_for_mission` (`vmClaimMetaGate`, Corollary 79).
- `orb_machine_action_admitted`: cross-client UI projection gate including
  `isLive`, `canAct`, `meterLiveCost`, `isStopped`, and `canResume`
  (`machineActionMetaGate`, Corollary 82).
- `orb_compute_secret_gate`: `CoreReserved` compute API key + untrusted managed
  node secret confinement (`computeSecretMetaGate`, Corollary 80).
- `orb_vm_cap_admit`: scoped mission concurrency + per-provider cap override vs.
  shared global pool admission with ancestor-cap monotonicity (`vmCapMetaGate`).

## Raw managed machines

`provisioning_mode` is `worker` (default for legacy machines and requests) or
`raw`. Both modes use the same tenant ownership, admission budgets, size caps,
provider TTL, stop/resume, reconciliation and reaper. `Online` means provider
ready for raw machines; it does not imply an Orb node heartbeat.

A fresh raw request must explicitly name an operator-approved clean image in
`SANDBOXED_MANAGED_RAW_IMAGES` (empty by default). Operators must exclude images
containing Orb node services or credentials; Core cannot inspect an image to
prove it is clean. Worker image allowlists do not authorize raw images.

For Boat, explicitly allow and request `provider-default` to select the provider
base image: set `SANDBOXED_MANAGED_RAW_IMAGES=provider-default` and send
`{"provisioning_mode":"raw","image":"provider-default"}`. The adapter omits
Boat's `from` field and always sends `noEnv: true`. Other allowed image values
are saved snapshot/share references, not arbitrary OS image names. See Boat's `POST /sandboxes` (`CreateSandboxRequest`) API reference.
This option skips Core provisioning; the contents of the provider base image
remain controlled by Boat.


Raw provisioning performs no guest writes, commands, installation, enrollment,
credential projection or cleanup. Raw machines never register node aliases or
enter automatic worker reuse. Their activity is not observed by a node agent,
so normal idle/owner/TTL policy still applies without busy auto-extension.

Forks and named snapshots inherit source mode when omitted; an explicit mode
mismatch is rejected before provisioning. Snapshot mode is persisted, and legacy
snapshots default to worker. Resume retains the same machine mode. Worker-only auto-managed mission placement
explicitly requests worker mode, rejecting raw snapshots before any provider
rental. Raw snapshot
and stop paths do not delete user files; Core has delivered no guest secrets.

Provider command/file endpoints are not exposed by this change: safely exposing
them requires a durable per-tenant operation journal with idempotency keys,
bounded inputs/time/output, redacted audit metadata and crash reconciliation.

### Raw operation receipts

`POST /api/managed-machines/:id/operations` accepts `idempotency_key` and one
`operation` (`exec`, `write_file`, or `read_file`). Only the authenticated owner
of a raw machine may call it. Commands and UTF-8 file writes are at most 64 KiB;
paths are absolute, at most 4096 bytes, without NUL; exec timeout is 1–120 seconds.
Receipts contain at most 64 KiB of serialized provider output (with explicit
truncation); Boat HTTP response collection is capped at 512 KiB before JSON allocation;
oversize responses are recorded as uncertain and are never replayed as commands.

The journal identity hashes tenant, immutable machine id, and idempotency key;
the request digest includes operation arguments. Before any provider call, Core
creates a private pending record with exclusive creation, fsyncs it and its
parent directory. A different request using that key is rejected. A matching
pending record returns `operation_uncertain`, including after a restart; Core
never automatically reexecutes it. A completed matching receipt is replayed.
Timeout and provider transport failures are persisted as uncertain outcomes,
not evidence that a guest command did not run. Final private receipts are fsynced
and atomically renamed. A failed final persistence leaves the pending fence.

Audit events contain operation kind and request digest, never command, path,
file content or output. Receipt files are mode 0600 in a mode 0700 directory;
they are retained as idempotency fences and may contain sensitive output.
Operation admission refreshes `last_busy_at`; it does not disable TTL or owner
reaping. Explicit lifecycle requests can stop a concurrently executing operation.

Receipt identity follows the immutable managed-machine ID across stop/resume and
provider incarnations: reusing the same key intentionally replays its earlier
receipt. Use a new key for a new operation after resume. Tenant-scoped display
budgets omit other tenants' raw machines, while admission uses global totals.

Global reconciliation and settings retain the existing administrator-wide policy.
Reconciliation still operates on the whole provider registry; its response omits
known raw machine/provider identifiers belonging to other tenants. Aggregate
provider inventory counts remain operational administrator information.


Journal admission is bounded across processes by a private `fs2` advisory lock.
The synced pending fence is created while holding it; the lock is released
before provider I/O. Fixed advisory operation slots allow at most 16 active
provider calls globally, four per tenant, and one per machine. Admission never
waits for a busy lock/slot: it returns HTTP 429. All journal scans, locks, fsyncs,
and receipt reads/writes run through `spawn_blocking` rather than Tokio workers.

Permanent receipt caps are 4096 globally, 512 per tenant, and 256 per machine.
Each reserves a maximum 132 KiB of serialized storage (528 MiB global), with
at most 16 additional atomic-write temporaries (about 2.1 MiB). Visible
temporary files are also counted conservatively by subsequent admission scans. New
admissions are additionally limited over a rolling minute to 240 globally, 60
per tenant, and 10 per machine. Recent file modification times conservatively
count completions as well as admissions. Existing receipts replay at any cap.
Legacy unscoped receipt files count against every scope, so upgrades fail closed
rather than forgetting an idempotency fence. Incomplete or malformed journal
entries fail closed with HTTP 503. No receipt is garbage-collected: pending and
uncertain fences are never deleted, and exhausted capacity requires an explicit
operator retention design rather than automatic reexecution of old keys.
