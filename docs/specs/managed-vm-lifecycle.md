# Managed VM lifecycle

Goal: no managed VM (boat.dev) keeps running in the void. Every VM has an
owner whose lifetime governs it, and a reaper plus a reconciler enforce that.
Code: `src/managed/lifecycle.rs` (pure decision), `src/managed/mod.rs`
(`reap_once`, `reconcile_once`, `claim_for_mission`). Lean gate for the final
destroy: `orb_vm_step` op `reap_check`.

## Ownership

| Field | Meaning |
| --- | --- |
| `owner_mission_id` | The mission the VM serves. Its lifetime governs the VM. |
| `requested_by_mission_id` | The mission that rented it for the owner (e.g. the caller of `start_mission(remote_node_id="auto-managed")`). Informational: it never keeps the VM alive. |
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

Evaluated every reaper pass (30 s) for each online VM. `busy` = the node
reports active jobs, leases or queued jobs (any mission). `idle` = time since
`last_busy_at`.

| # | Condition | Decision | `destroy_reason` |
| --- | --- | --- | --- |
| 1 | `now >= expires_at` | destroy (even if busy) | `ttl_expired` |
| 2 | busy | keep, clear any schedule | |
| 3 | owner terminal (completed, failed, not_feasible, cancelled, acknowledged, archived) | destroy after `owner_grace` from first observation | `owner_<status>` |
| 4 | owner deleted | destroy after `owner_grace` | `owner_missing` |
| 5 | owner interrupted / awaiting_user / blocked / paused since `t` | destroy at `max(t + waiting_grace, last_busy + idle)` | `owner_<status>_idle` |
| 6 | owner working (pending, active, waiting_background) | keep | |
| 7 | owner state unknown (tenant store not loaded, no tenant) | keep | |
| 8 | user-owned | destroy when idle > `idle` | `idle_user_owned` |
| 9 | no owner (legacy) | destroy when idle > `idle` | `idle_no_owner` |

A rule whose due time is in the future is persisted as `reap_at` /
`reap_reason`; clients show "Reaps in X (reason)".

Defaults (env): `SANDBOXED_MANAGED_IDLE_MINUTES` 30,
`SANDBOXED_MANAGED_OWNER_GRACE_MINUTES` 5,
`SANDBOXED_MANAGED_WAITING_GRACE_MINUTES` 15,
`SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES` 60 with
`SANDBOXED_MANAGED_AUTO_EXTEND_MINUTES` 30 (a busy VM within 10 minutes of
its TTL is extended by one chunk if its budget pool and the daily cap allow),
`SANDBOXED_MANAGED_ORPHAN_GRACE_MINUTES` 10,
`SANDBOXED_MANAGED_RECONCILE_SECS` 120.

Owner death cascades through the tree: a descendant still running on the VM
holds a lease, so rule 2 protects it; once nothing runs there, rule 3 applies.

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

## Provisioning

`provision` runs `src/managed/orb-node-provision.sh` as root before
starting `orb-node` (best effort, logged): `/tmp/opencode` writable by
`orbnode`, a git credential helper answering only `https://github.com` with
the mission's GitHub token (the `paloma-secrets` file Core delivered, else
`GITHUB_TOKEN`/`GH_TOKEN`; never written by the script), ssh GitHub URLs
rewritten to https, and the orbnode rustup env when the image has it. The
`online` ledger event records `ready_ms`, `provision_ms`, `enroll_ms` and
`total_ms`. The image recipe adds gh, ripgrep, fd, clang/llvm/lld and an
orbnode-owned rustup with stable and 1.93.0.

## Snapshots, forks, stop

Code: `src/managed/snapshots.rs`. Agent guide: `skills/boat-machines/SKILL.md`.

- **Named snapshots** (`snapshot_managed_machine`, `POST
  /api/managed-machines/:id/snapshot`) are recorded in
  `.sandboxed-sh/managed_snapshots.json` with owner mission, tenant, project
  (the owner mission's), source machine and size. Delivered
  `.paloma-secrets` are deleted on the VM first; a VM holding a projected
  Antigravity sign-in cannot be saved or forked. Visible and usable only
  within the same tenant and project. Pricing: 10 included, then $1.70/month.
- **From a snapshot**: `spawn_managed_machine(from_snapshot)` and
  `start_mission(auto-managed, managed_from_snapshot)`; `last_used_at` is
  recorded. Budget and caps apply as for any rent.
- **Fork** (`fork_managed_machine`, `POST /:id/fork`): new machine from the
  source's latest background snapshot (up to ~1 min stale), owner = caller,
  `forked_from` recorded. Provisioning deletes the copied `node.cred` and
  `managed-auth` before enrolling.
- **Stop / resume**: stop keeps the disk (`Stopped`, unregistered, no
  billing). The boat key has no `sandbox.resume`, so resume forks the
  stopped sandbox and keeps the machine's id, node id, owner and pool;
  cost of earlier runs is kept in `cost_before_resume`.
- **Reaper**: rule 5 (owner interrupted/awaiting/blocked/paused and idle)
  stops instead of destroying (`stopped_by_reaper`), and such a machine is
  resumed when its owner works again. A stopped machine is closed after
  `SANDBOXED_MANAGED_STOPPED_RETENTION_HOURS` (24) or when its owner ends.
- **Snapshot cleanup** (each reconcile pass, dry-run aware): keep the newest
  `SANDBOXED_MANAGED_SNAPSHOT_KEEP` (2) ready snapshots per project, delete
  ones unused for `SANDBOXED_MANAGED_SNAPSHOT_UNUSED_DAYS` (14) and failed
  saves; never one a provisioning machine is being created from.

## Reconciler (every `reconcile_secs`)

- Provider VM with our name prefix and no live registry row (and no spawn in
  flight for it): stop after `orphan_grace` from first sighting.
- Live row whose provider VM is stopped: destroy (`stopped_by_provider`).
- Live row whose provider VM is missing from two consecutive non-empty
  listings: mark destroyed (`provider_vanished`) without a provider call and
  close the ledger. An empty listing never closes rows.

## Dry run

`managed_settings.json` `reaper_dry_run` (default true until changed; env
`SANDBOXED_MANAGED_REAPER_DRY_RUN=0` turns it off; `PUT
/api/managed-machines/settings` merges partial bodies). In dry run, rules 3-9
and orphan stops are recorded (`would_reap` in the ledger once per machine and
reason, `reap_at` on the row) but nothing is destroyed. TTL always destroys.
`GET /api/managed-machines/reap-plan` returns the current decision for every
live VM.

## Invariants

1. Every VM created after this change has `owner_kind` set; a mission-created
   one has `owner_mission_id`.
2. No lifecycle rule destroys a busy VM; only the TTL does.
3. A VM is never destroyed because of an owner whose state is unknown.
4. The requester's liveness never extends a VM's life.
5. Every destroy records exactly one `destroy_reason` from the table above (or
   `requested`, `provisioning failed: ...`, `stopped_by_provider`,
   `provider_vanished`).
6. A machine of tenant A is never claimed by tenant B.

## Proposed Lean gates (not implemented; Lean is owned elsewhere)

- `vmReapDecision` over `(ttlExpired, busy, ownerClass, waitingElapsed,
  idleElapsed, graceElapsed)` returning keep/schedule/destroy, with
  corollaries for invariants 2-4.
- `vmClaimAdmit (sameTenant, ownerNone, ownerIsRequester)`: admits iff
  `sameTenant && (ownerNone || ownerIsRequester)` (invariant 6).

## Raw managed machines

`provisioning_mode` is `worker` (default for legacy machines and requests) or
`raw`. Both modes use the same tenant ownership, admission budgets, size caps,
provider TTL, stop/resume, reconciliation and reaper. `Online` means provider
ready for raw machines; it does not imply an Orb node heartbeat.

A fresh raw request must explicitly name an operator-approved clean image in
`SANDBOXED_MANAGED_RAW_IMAGES` (empty by default). Operators must exclude images
containing Orb node services or credentials; Core cannot inspect an image to
prove it is clean. Worker image allowlists do not authorize raw images.

Raw provisioning performs no guest writes, commands, installation, enrollment,
credential projection or cleanup. Raw machines never register node aliases or
enter automatic worker reuse. Their activity is not observed by a node agent,
so normal idle/owner/TTL policy still applies without busy auto-extension.

Forks and named snapshots inherit source mode when omitted; an explicit mode
mismatch is rejected before provisioning. Snapshot mode is persisted, and legacy
snapshots default to worker. Resume retains the same machine mode. Raw snapshot
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
