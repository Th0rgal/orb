# Storage lifecycle policy

Core treats cleanup as an approval workflow, not an automatic disk
reclamation mechanism. The inventory is dry-run-only: it never deletes
workspaces, mission directories, Lean/build caches, worktrees, images, or
credentials. `--apply` is intentionally rejected.

Run it against explicit roots and retain the JSONL output as the operator audit
log:

```bash
python3 scripts/storage_inventory.py \
  --missions-dir /root/.sandboxed-sh/missions \
  --root /root/.sandboxed-sh/containers/example/workspaces \
  --root /root/.cache \
  --root /var/lib/machines \
  --retention-days 30 \
  --audit-log /var/log/sandboxed-sh/storage-inventory.jsonl
```

Each record identifies path, kind, size, age, persisted mission owner (the
mission-store key when known), mission/workspace IDs and status, and a policy
decision. `active`, `pending`, and `waiting_background` missions are always
`keep`; an unreadable store remains unattributed and must not be treated as an
approval candidate. Only an attributed, terminal `mission-*` directory past
retention is emitted as `would_remove`; caches, worktrees, images, and every
unattributed path remain `keep` until ownership is established. A
`would_remove` record is a candidate list for the listed owner to review
manually, not authority to delete.

The inventory also finds nested Lean (`.lake`, `.lean`) and common build-cache
directories under each supplied root. They receive their enclosing mission's
owner when one exists, but are still retained as separate review records so
their bytes can be attributed without authorizing cache deletion.

The background mission-directory retention sweep is also dry-run by default.
With cleanup enabled in Settings, it emits structured `mission GC audit` logs
with `action=would_remove`, ownership identifiers, size, path, and reason. It
never deletes filesystem content, including with `WORKSPACE_GC_EXECUTE=1`.
That switch only enables the separate [explicit mission discard lifecycle](specs/mission-workspace-purge.md):
a persisted owner authorization, execution checks, recoverable quarantine, and a
seven-day delay are all required. Archive and conversation DELETE preserve files;
unindexed and legacy quarantine directories remain retained. The default retention is one day for terminal
missions and seven days for AwaitingUser/Paused missions. The normal sweep is
hourly unless `WORKSPACE_GC_INTERVAL_MINUTES` is set. While disk pressure is at
Warn or Critical, the disk watcher requests the same configured sweep every
five minutes; a shared lock prevents overlapping scans.

Resource limits are separate from retention. Use `GET
/api/workspaces/:id/resources` to inspect effective memory/swap/CPU limits and
matching live scopes before changing a workspace shared by concurrent missions.

## Admission and continuity

By default, disk warning is not a portfolio-wide stop. Local mission placement
uses `MISSION_WORKSPACE_ROOT` when it names an existing writable absolute
directory (for example `/srv/sandboxed-storage`). The service canonicalizes the
directory, including a deliberate symlink, and falls back safely to the
workspace's recorded root if it is missing, unwritable, relative, or contains
path traversal. It never moves or deletes existing workspace records or active
mission directories; an already-existing legacy mission directory continues to
be used.

Admission and fleet health measure the `statvfs` filesystem that backs this
selected path, not `/`. Their non-secret output includes the canonical path,
filesystem identifier, free GiB, and required GiB. Set
`DISK_ADMISSION_AT_WARN=1` on build-heavy hosts to refuse all new missions at
Warn instead of waiting for Critical. A local disk-heavy mission should set
`estimated_disk_gib`; the API rejects it when its estimate would cross
`MISSION_DISK_EMERGENCY_RESERVE_GB` (default 150 GiB).
`MISSION_DISK_DEFAULT_ESTIMATE_GIB` defaults to 64 GiB, so a local request
without an explicit estimate remains fail-closed. Critical level always rejects
all new local missions.

For a high-churn Lean/build host, a deliberately aggressive profile is:

```bash
DISK_WARN_PCT=80
DISK_CRITICAL_PCT=88
DISK_ADMISSION_AT_WARN=1
MISSION_DISK_EMERGENCY_RESERVE_GB=200
MISSION_DISK_DEFAULT_ESTIMATE_GIB=64
WORKSPACE_GC_EXECUTE=1
WORKSPACE_GC_INTERVAL_MINUTES=10
```

Host-level caches and harness logs are outside the mission ownership model.
Install `scripts/storage_hard_cleanup.sh --apply` from an hourly systemd timer
on dedicated build hosts. It removes expired mission-store backups, old
OpenCode logs, reconstructible OpenCode cache entries, Hermes staging and
quarantine content, truncates oversized harness logs, and caps the journal.
Its retention and size controls are environment-configurable; run it without
`--apply` for an inventory.

Lean builds should use `remote-lean-build`. The wrapper can ship modified and
untracked regular source files as a bounded, content-hashed overlay on top of a
pinned commit; deletion, rename, symlink, `.git`, `.lake`, traversal and
oversized overlays fail closed. Remote placement reserves the declared scratch
estimate, while runners reuse content-addressed checkouts and dependency-only
Lake cache slots. This lets a dirty proof lane continue on a roomy node without
duplicating a fresh Mathlib tree on the production host.

## Future placement scoring (design only)

After the P0 filesystem admission work, placement can consume one unified
scorecard: hard constraints first (workspace isolation, reachable runner,
filesystem capacity after estimate plus reserve), then soft penalties for a
GitHub runner being busy or highly loaded. Busy/load must only rank otherwise
admissible candidates lower; it must never become an admission rejection or
weaken the local filesystem fail-closed checks.

## Remote worker storage

Use the same inventory against a worker's node ledger. It attributes full UUID
mission directories and nested build/toolchain trees without reading command
payloads or treating succeeded jobs as permission to delete source:

```bash
# Optional: export non-secret Core mission status metadata on Core first
python3 scripts/storage_inventory.py \
  --missions-dir /root/.sandboxed-sh/missions \
  --export-missions /tmp/missions-snapshot.jsonl

# Attribute worker UUID dirs + nested caches against both jobs.db and Core status
python3 scripts/storage_inventory.py \
  --missions-snapshot /tmp/missions-snapshot.jsonl \
  --node-work-dir /var/lib/sandboxed-node \
  --root /tmp --root /opt/actions-runner --root /srv/verity-ci-cache
```

Run in the node's mount namespace when inspecting its private /tmp, or supply the
host-visible systemd-private path. The scanner never deletes, excludes symlinks
and nested mounts, and reports both apparent bytes and allocated file blocks.
Supplying `--missions-dir` or `--missions-snapshot` alongside `--node-work-dir`
enriches UUID mission directories and nested caches with Core's authoritative
`mission_status`, `owner`, and `workspace_id` while keeping `action="keep"`.
Nested entries overlap and shared XFS extents are not exclusive/reclaimable bytes;
use filesystem free-space measurements before/after any separately authorized
cleanup. Missing or unreadable node ledgers or snapshots never grant deletion
permission.

When reconstructible per-mission build/toolchain trees (`.elan`, `.lake`,
`target`, `toolchains`, `.rustup`, `node_modules`) inside finished missions pin a
worker's disk, inspect and reclaim only those reconstructible caches via
`scripts/reclaim_worker_build_caches.py` (dry-run by default; requires complete
Core + `jobs.db` indexes and `lsof +D` open-descriptor verification before
`--apply`, and never deletes mission source or `.git` repositories). To roll out
`sandboxed-node` binary updates across busy workers without retiring in-flight
turns, stage `.new` binaries and run `scripts/rolling_upgrade_nodes.py` to
cordon, drain `jobs.db` to zero active jobs, swap, restart, and uncordon in
capacity-bounded waves.

[Worker scratch reclamation](specs/node-storage-lifecycle.md) covers new owned
TMPDIR/TMP/TEMP directories after confirmed supervision (72-hour baseline grace when
healthy; pressure-accelerated `6h` / `0h` sweep for confirmed-retired receipts under
`orb_node_gc_step`, while unretired receipts remain permanently retained).
Hard-coded /tmp paths and legacy data require owner review. Completed remote mission
source still needs a future node-local implementation of the explicit discard
contract; archive/delete does not silently opt it in.

Prefer the durable Lean build API and its shared dependency cache to recursively
copying .lake into ad-hoc review trees. Never copy a .lake directory into itself
(the Ashur incident included a multi-GiB .lake/.lake copy). Keep persistent source
and final artifacts in the mission workspace, outside execution scratch. CI caches
and toolchains require their own tool-aware budgets; they are not generic temporary
files. When non-cache storage pins a worker below `SANDBOXED_NODE_MIN_FREE_GB` above
its emergency floor, `orb_node_gc_step` preserves hot (`< 2h`) shared Lake caches
instead of thrashing them every 30 minutes and publishes `disk_pressure_pinned` on
`/heartbeat` so Core placement (`orb_node_disk_admission_step`) excludes the node and
surfaces the exact floor or pinned-pressure reason.
