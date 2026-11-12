# Managed VM lifecycle

Goal: no managed VM (`boat`, `leanci`, `hetzner`, `vastai`, `scaleway`, `colab`) keeps running in
the void, and no agent ever needs raw cloud API keys in shell. Every VM has an
owner whose lifetime and activity govern it, and a reaper plus a per-provider
reconciler enforce that.
Code: `src/managed/lifecycle.rs` (pure decision backed by
`orb_vm_lifecycle_step`), `src/managed/mod.rs` (`reap_once`, `reconcile_once`,
`claim_for_mission` backed by `orb_vm_claim_step`), and
`src/api/secret_broker.rs` (`orb_compute_secret_gate`).

## Providers & Secret Confinement

| Provider (`provider`) | Workloads | Bootstrap | `supports_free_stop` | `supports_snapshots` | Minimum lease |
| --- | --- | --- | --- | --- | --- |
| `boat` (default) | Fast ephemeral Linux x86\_64 workers (`small`..`xlarge`) & raw sandboxes | Provider file/exec API | Yes (14d disk retention, \$0) | Yes (named + fork) | Per-second |
| `leanci` (`lean.ci`, legacy alias `boost`) | Warm Cloud Hypervisor Linux x86\_64 microVMs (`lean-2vcpu-ubuntu-2604`..`lean-32vcpu`, `lean-32vcpu-96gb`) with optional CoW `.olean` overlays (`repo`/`base_key`/`lean_mode`) & `turbo-lean` | Provider file/exec API -> reverse relay | No | Yes (named + fork, engine-pinned CoW) | Per-second (60s..24h fixed TTL; no live extend) |
| `hetzner` | Larger x86\_64 / ARM64 CPU & RAM instances (`cpx22`..`ccx43`, `cax31`; legacy `cpx21`..`cpx51` aliases map to `cpx22`..`cpx62` with EU location fallback `fsn1` -> `hel1` -> `nbg1`) | Cloud-init `user_data` -> reverse relay | No (stopped servers still bill) | No | Hourly / per-minute |
| `vastai` | Ephemeral CUDA GPUs (`rtx4090`, `a100`, `h100`, or explicit `gpu` filter) | Offer `onstart` -> reverse relay | No (stopped instances bill storage/GPU) | No | On-demand |
| `scaleway` | EU Linux/GPU Instances (`DEV1-*`, `PRO2-*`, `L4-*`, `H100-*`) & Apple Silicon Mac minis (`M1-M`, `M2-M`, `M2-PRO`, `M4-M`) | Cloud-init / SSH -> reverse relay | No | No | Instances: per-minute; Apple Silicon: **24h (`deletable_at`)** |
| `colab` (`Google Colab`) | Pooled Google Colab CUDA GPUs (`colab-auto`, `t4`, `l4`, `a100`, `h100`) & TPUs (`v5e1`, `v6e1`) via `colab-api`, shadow-priced at ½ Vast.ai | Worker file/exec API -> reverse relay | No | No | On-demand (shadow-metered at ½ Vast.ai; explicit-only) |

Provider credentials (`BOAT_API_KEY`, `LEANCI_API_KEY`/`LEANCI_TOKEN` or legacy `BOOST_API_KEY`/`BOOST_TOKEN`, `HETZNER_CLOUD_APIKEY`, `VASTAI_API_KEY`,
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

**Spec Card** (`Th0rgal/orb@31f24317b`, `Orb.ManagedProviderPolicy`,
`ManagedProviderSealing.lean`, the Control seal route): `seal_authority_iff`
connects the pure gate to authenticated operator / non-mission / non-managed
flags. Positive trace: operator seals a synthetic lean.ci key, and only Core can
open it. The pure theorem does not verify HTTP credential classification,
Bitwarden, filesystem primitives or AEAD; route and synthetic-vault tests cover
those integrations. No live vault result is evidence from the self-test.

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
- Destroy is idempotent on 404, with stop fallback. `stop_failed` retries are
  bounded (3, 6, 9, 12 seconds); other failures propagate. Extend PATCHes
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
- **Expiry** (`ManagedTtl.tick`, every 30 s): within 2 minutes of the deadline the owner
  mission gets one `managed_machine_expiring` event. At the deadline Core claims the expiry
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
stopped; provider-ready observations never manufacture relay readiness or erase
an unreported cost. An unbound timed-out provisioning reservation can close only
against a complete inventory with no matching sandbox. A legacy resume also runs
this repair on demand before selecting its archived provider source.

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

`provision` runs `src/managed/orb-node-provision.sh` as root before
starting `orb-node` (best effort, logged): `/tmp/opencode` writable by
`orbnode`, a git credential helper answering only `https://github.com` with
the mission's GitHub token (the `paloma-secrets` file Core delivered, else
`GITHUB_TOKEN`/`GH_TOKEN`; never written by the script), ssh GitHub URLs
rewritten to https, and the orbnode rustup env when the image has it (skipping
recursive `chown -R` when `$CACHES/{rustup,cargo}` is already owned by
`orbnode`). Boot-time state preparation wipes `node.cred`, `managed-auth`,
`/run/user/*/paloma-secrets`, `.paloma-secrets`, and `/var/lib/orb-node/.boost-env`
while pruning heavy
toolchain/build/VCS trees (`caches/{elan,rustup,cargo,lake,xdg}`, `.git`,
`.lake`, `target`, `node_modules`) and skipping global `sync` so lazy CoW
snapshot hydration never times out (`SECRETS_WIPE` before snapshot/fork save
retains `&& sync`). On `leanci` microVMs, `orb-node-provision.sh` also extracts
guest `LEANCI_*` / `BOOST_*` environment variables (including the VM-scoped `LEANCI_CACHE_TOKEN` / `BOOST_CACHE_TOKEN`
for `turbo-lean`) into `/var/lib/orb-node/.boost-env` (`0600` `orbnode:orbnode`),
makes `/workspace/repo` and `/workspace/boost-cvm/lean-overlay/merged` readable to
`orbnode`, and installs `/usr/local/bin/orb-cow-worktree` so concurrent sub-agents
can create isolated git worktrees seeded with `cp -al` hardlinked `.lake/build`
artifacts without Lake lock contention. Post-create provisioning enforces an overall wall-clock
deadline (`360s` for Boat, `480s` for cloud-init and `leanci` reverse-relay providers) strictly below
`AssistantMcp`'s `540s` HTTP timeout (and Hermes's `600s` MCP stdio timeout) so
Core always destroys any partial VM and returns structured JSON before the
caller's HTTP socket times out. For cloud-init/onstart providers (`hetzner`, `vastai`, `scaleway`) and `leanci` (executed directly over `POST /v1/vms/:id/exec`), Core generates a
one-time `<4 KiB` enrollment script (fitting Vast.ai's `onstart` limit) that
fetches `sandboxed-node`, `sandboxed-mcp`, and verified native harnesses
(`opencode`, `claude`, `codex`) over streaming `GET /api/managed-machines/bootstrap-binary/:id`
(which verifies ELF `e_machine` matches the machine's `arch`), keeps
`/home/user/.orb/enroll.env` `0600` unprivileged-unreadable, enables `orbnode`'s
lingering user D-Bus session (`XDG_RUNTIME_DIR` + `DBUS_SESSION_BUS_ADDRESS`), and
dials back over the reverse relay (`SANDBOXED_NODE_DIAL_CORE_URL`). Marketplace
providers (`vastai`) quote a verified offer (`quote_spawn`) enforcing CPU/RAM floors
before budget admission so daily caps, pool reservations, and machine ledger rows use
the real `dph_total` rate rather than catalog placeholders. Scaleway Apple Silicon
(`M2-*`, 24h minimum lease) is rejected for Linux `worker` provisioning and omitted
from the worker size catalog (`raw`-only with `allow_24h_commitment: true`). The
`online` ledger event records `ready_ms`, `provision_ms`, `enroll_ms` and `total_ms`.

## Snapshots, forks, stop

Code: `src/managed/snapshots.rs`. Agent guide: `skills/managed-compute/SKILL.md`.

- **Named snapshots** (`snapshot_managed_machine`, `POST
  /api/managed-machines/:id/snapshot`, `boat` and `leanci`) are recorded in
  `.sandboxed-sh/managed_snapshots.json` with `provider`, owner mission, tenant, project
  (the owner mission's), source machine and size. Delivered
  `.paloma-secrets` and `.boost-env` are deleted on the VM first; a VM holding a projected
  Antigravity sign-in cannot be saved or forked. Visible and usable only
  within the same tenant, project, and provider (arbitrary `image` strings on `leanci`
  cannot reference snapshot IDs directly). Boat pricing: 10 included, then \$1.70/month.
- **From a snapshot**: `spawn_managed_machine(from_snapshot)` and
  `start_mission(auto-managed, managed_from_snapshot)` (explicit snapshot
  name/label or `"latest"`; omitted or `"light"`/`"none"`/`"base"` boots the
  clean base image); `last_used_at` is
  recorded. Budget and caps apply as for any rent.
- **Fork** (`fork_managed_machine`, `POST /:id/fork`): new machine from the
  source's latest background snapshot (up to ~1 min stale), owner = caller,
  `forked_from` recorded. Provisioning deletes the copied `node.cred` and
  `managed-auth` before enrolling.
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
