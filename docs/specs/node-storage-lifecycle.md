# Worker storage lifecycle

## Ownership before deletion

Ashur's October 2026 disk incident was dominated by mission directories, repeated
Lean toolchains/mathlib builds, CI worktrees and the node service's private /tmp.
The cache collector was healthy but had no eligible checkout/Lake slots. An empty
candidate list must report that coverage gap, not imply all host caches were removed.

Mission completion, archive, conversation deletion and directory age are not discard
permission. Remote mission source, legacy /tmp, CI caches, toolchains and unknown
paths remain inventory-only. The existing Core discard API remains fail-closed for
remote placements; this change does not weaken its authorization contract.

## Owned scratch

Every new asynchronous job and synchronous lease receives a unique directory under
`<work-root>/.scratch/`. TMPDIR, TMP, TEMP and `OPENCODE_TMPDIR` (`<scratch>/opencode`)
point there for all supervised commands (including OpenCode's git/clone scratch and
Lean's subprocesses). They are runner-owned environment keys. Hard-coded
/tmp paths cannot be redirected by environment variables and remain legacy,
unmanaged storage. Persistent outputs must be written to the mission workspace.

Remote `RawCommand` and synchronous lease commands also wire `ELAN_HOME`
(`<work-root>/caches/elan`), `TURBO_LEAN_HOME` (`<work-root>/caches/turbo-lean`),
and an advisory `<work-root>/caches/bin/lake` shim before applying payload `env`
overrides so multi-agent Lean turns share one toolchain/CAS store per host and
emit actionable `turbo-lean build` / `turbo-lean check` stderr guidance on unshared
`lake build|check|test` calls while transparently passing through `lake setup-file`,
`lake env`, and `lake exe`. Core's local/container `scripts/lake` shim emits the same
advisory when `SANDBOXED_COMPUTE_POLICY=local_allowed` falls through to local Lake.

The node persists a receipt in jobs.db before executing: unique execution ID,
mission/job attribution, parent and directory device/inode identity. Filesystem
identity is observed without following symlinks. No source directory is enrolled.
The receipt is marked retired only after the execution future returns successfully
through the supervisor's confirmed process-group/scope cleanup. Failed exit codes,
timeouts and cancellation are successful *supervision*, not necessarily successful
jobs. Every supervised command must also have used systemd scope containment;
process-group-only fallback cannot rule out escaped setsid() descendants. One
fallback command permanently prevents retirement for the entire execution.
Dropped futures, shutdown/restart, failed reads or uncertain cleanup retain
scratch without an expiry. A terminal job row alone is never enough.

After a 72-hour baseline recovery period when disk space is healthy, the node GC
cadence consumes retired receipts. Under disk pressure below `SANDBOXED_NODE_MIN_FREE_GB`,
the verified kernel controller (`orb_node_gc_step` in `lean/Orb/Kernel.lean`) accelerates
retirement grace exclusively for **already-retired** receipts (`72h` when healthy, `6h`
when aged retired scratch plus cold caches cover the deficit, `0h` when deeper
reclamation or emergency `< 10 GiB` survival is required, sweeping oldest `retired_at`
first and stopping once the recovery target is reached). Unretired receipts
(`retired_at IS NULL`) are never swept regardless of disk pressure. Reclamation reuses
Core's descriptor-relative removal, refuses symlink/root/inode
replacement and mount traversal, and checks private ownership. Unlike whole-workspace
purge, execution-private scratch permits unrelated views of the backing filesystem
created by systemd ReadWritePaths; mounts inside scratch are still refused. Unsupported platforms
retain scratch and report zero reclaimable scratch bytes to the GC controller. A crash during removal retries the same identity; a crash after
removal retries parent fsync before deleting the receipt. There is no broad /tmp scan
or mtime-based deletion. The managed-execution trust boundary and same-uid writer
limits of mission-workspace-purge.md also apply here. Scratch is execution-private;
other jobs must not use it as shared storage or as a working directory.

## Cache pressure, anti-thrashing and fleet placement

`SANDBOXED_NODE_MIN_FREE_GB` is hot-reloadable alongside `SANDBOXED_NODE_CAPACITY` via
`SIGHUP` or `/etc/sandboxed-node.env` mtime polling, without restarting `sandboxed-node`
or interrupting running scopes. Each `/heartbeat` advertises `min_free_disk_bytes` and
`disk_pressure_pinned`.

Below `SANDBOXED_NODE_MIN_FREE_GB`, `orb_node_gc_step` orders reclamation across four
node-owned tiers toward `floor + 20 GiB` (capped at filesystem capacity):

1. Aged confirmed-retired scratch (`age >= 6h`)
2. Cold unlocked caches (stale transfer mutation `.lake/build` plus checkouts and Lake
   slots idle `>= 2h`)
3. Fresh confirmed-retired scratch (`0h <= age < 6h`)
4. Hot unlocked shared caches (`idle < 2h`), guarded against cache thrashing: when
   non-cache storage pins the filesystem below `SANDBOXED_NODE_MIN_FREE_GB` (`free +
   retired_scratch + cold_caches + hot_caches < floor`) and free space remains at or
   above the emergency survival floor (`min(floor / 2, 10 GiB)`), hot `< 2h` caches are
   preserved rather than destroyed every 30 minutes, and `disk_pressure_pinned = true`
   is published on `/heartbeat`. Below the emergency survival floor, survival overrides
   cache warmth and hot caches are evicted.

Core placement (`orb_node_disk_admission_step`) enforces `effective_floor =
max(core_min_disk_bytes, node.min_free_disk_bytes)` after subtracting in-flight burst
reservations, rejects nodes reporting `disk_pressure_pinned`, and ranks nodes inside the
`20 GiB` GC hysteresis band behind nodes with comfortable disk headroom at equal
normalized utilization. Logs distinguish attempted, removed and remaining bytes/free
space; measured free space, rather than summed directory sizes, determines recovery.

The read-only storage inventory accepts a node jobs.db and full UUID mission
folders, reports job-state counts and last completion without exposing payloads,
and always retains node-owned source. Apparent bytes and allocated blocks are
reported separately; nested records overlap, and reflink/shared extents mean neither
is a promise of reclaimable space. Missing/unreadable indexes stay unattributed.

Tests must cover running/unretired and interrupted scratch, delayed reclamation,
failed execution, symlinks/replacement, persisted restart recovery, and node UUID
attribution. Only temporary test directories may be removed during validation.
