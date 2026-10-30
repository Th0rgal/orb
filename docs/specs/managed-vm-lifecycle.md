# Managed VM lifecycle

Goal: no managed VM (`boat`, `hetzner`, `vastai`, `scaleway`) keeps running in
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
| `hetzner` | Larger x86\_64 / ARM64 CPU & RAM instances (`cpx22`..`ccx43`, `cax31`; legacy `cpx21`..`cpx51` aliases map to `cpx22`..`cpx62` with EU location fallback `fsn1` -> `hel1` -> `nbg1`) | Cloud-init `user_data` -> reverse relay | No (stopped servers still bill) | No | Hourly / per-minute |
| `vastai` | Ephemeral CUDA GPUs (`rtx4090`, `a100`, `h100`, or explicit `gpu` filter) | Offer `onstart` -> reverse relay | No (stopped instances bill storage/GPU) | No | On-demand |
| `scaleway` | EU Linux/GPU Instances (`DEV1-*`, `PRO2-*`, `L4-*`, `H100-*`) & Apple Silicon Mac minis (`M1-M`, `M2-M`, `M2-PRO`, `M4-M`) | Cloud-init / SSH -> reverse relay | No | No | Instances: per-minute; Apple Silicon: **24h (`deletable_at`)** |

Provider credentials (`BOAT_API_KEY`, `HETZNER_CLOUD_APIKEY`, `VASTAI_API_KEY`,
`SCALEWAY_SECRET_KEY`, `SCALEWAY_KEY_ID`, etc.) are resolved inside Core from
operator settings (`.sandboxed-sh/managed_providers.json`, `0600`, AES-256-GCM
via `env_crypto`), environment variables, or Bitwarden Secrets Manager
(`bitwarden.rs`) and are classified as `CoreReserved` in `secret_broker.rs`
(`orb_compute_secret_gate`):

1. Agents cannot read `CoreReserved` cloud provider keys via `secret_get` or
   `secret_request`, and `secret_list` omits them from `accessible`. Agents must
   rent VMs through `spawn_managed_machine` or
   `start_mission(remote_node_id="auto-managed[:provider[:size]]")`.
2. Callers executing on untrusted `managed-*` remote nodes are denied all
   non-allowlisted vault secrets (`orb_compute_secret_gate`).
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
- `start_mission` with `auto-managed`: Core first validates the launch
  (`POST /api/control/missions` with `validate_only: true`: model, harness
  auth a fresh `orb-node-base` VM can satisfy (no grok login; Antigravity only
  when projection is allowed), project caps, sub-budget). A rejection rents
  nothing. Then the VM is rented with owner = caller (or an idle VM of the
  same size/image left by an ended sibling, still inside its owner grace, is
  handed over: `reuse_idle`), and `POST /api/control/missions` carries
  `claim_managed_machine_id`; once the child exists Core makes the child the
  owner and the caller the requester. If the create still fails, the rented
  VM is destroyed (`requested: launch_failed`).
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
`SANDBOXED_MANAGED_POST_JOB_IDLE_MINUTES` 5,
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
any pool in its lineage a mission is limited only by the daily cap.

Each VM records `budget_pool_id` at create (the pool of its owner, or of the
child it is claimed for). Per pool, derived from the registry
(`src/managed/budget.rs`):

- `spent` = metered (or estimated so far) cost of its VMs;
- `reserved` = for each live VM, `min(remaining TTL, 60 min) × usd_per_hour`;
- `carved` = each child pool's budget while its owner runs, only its use
  once the owner is terminal (unused money returns);
- `available = budget − spent − reserved − carved`.

Checked under the admission lock at `spawn_managed_machine`, `start_mission`
auto-managed (before renting), `extend_managed_machine` and auto-extend
(each needs `min(minutes, 60) × price`), and sub-budget grants. Refusals are
`402 budget_exceeded` with the remaining amount. The daily cap stays the
outer bound (`none` = unlimited). Budgets persist in
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
- `provider_max_concurrent`: optional map of canonical provider (`boat`,
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

## Provisioning

`provision` runs `src/managed/orb-node-provision.sh` as root before
starting `orb-node` (best effort, logged): `/tmp/opencode` writable by
`orbnode`, a git credential helper answering only `https://github.com` with
the mission's GitHub token (the `paloma-secrets` file Core delivered, else
`GITHUB_TOKEN`/`GH_TOKEN`; never written by the script), ssh GitHub URLs
rewritten to https, and the orbnode rustup env when the image has it. For cloud-init/onstart providers (`hetzner`, `vastai`, `scaleway`), Core generates a
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
  /api/managed-machines/:id/snapshot`, `boat` only) are recorded in
  `.sandboxed-sh/managed_snapshots.json` with owner mission, tenant, project
  (the owner mission's), source machine and size. Delivered
  `.paloma-secrets` are deleted on the VM first; a VM holding a projected
  Antigravity sign-in cannot be saved or forked. Visible and usable only
  within the same tenant and project. Pricing: 10 included, then \$1.70/month.
- **From a snapshot**: `spawn_managed_machine(from_snapshot)` and
  `start_mission(auto-managed, managed_from_snapshot)`; `last_used_at` is
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
