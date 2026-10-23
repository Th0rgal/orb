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
- `start_mission` with `auto-managed`: the VM is rented with owner = caller,
  then `POST /api/control/missions` carries `claim_managed_machine_id`; once
  the child exists Core makes the child the owner and the caller the
  requester.
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
`SANDBOXED_MANAGED_WAITING_GRACE_MINUTES` 60,
`SANDBOXED_MANAGED_ORPHAN_GRACE_MINUTES` 10,
`SANDBOXED_MANAGED_RECONCILE_SECS` 120.

Owner death cascades through the tree: a descendant still running on the VM
holds a lease, so rule 2 protects it; once nothing runs there, rule 3 applies.

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
