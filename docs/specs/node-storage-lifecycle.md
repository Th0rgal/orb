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
`<work-root>/.scratch/`. TMPDIR, TMP and TEMP point there for all supervised commands
(including Lean's subprocesses). They are runner-owned environment keys. Hard-coded
/tmp paths cannot be redirected by environment variables and remain legacy,
unmanaged storage. Persistent outputs must be written to the mission workspace.

The node persists a receipt in jobs.db before executing: unique execution ID,
mission/job attribution, parent and directory device/inode identity. Filesystem
identity is observed without following symlinks. No source directory is enrolled.
The receipt is marked retired only after the execution future returns successfully
through the supervisor's confirmed process-group/scope cleanup. Failed exit codes,
timeouts and cancellation are successful *supervision*, not necessarily successful
jobs. Dropped futures, shutdown/restart, failed reads or uncertain cleanup retain
scratch without an expiry. A terminal job row alone is never enough.

After a fixed 72-hour recovery period, the existing node GC cadence consumes retired
receipts. It reuses Core's descriptor-relative removal, refuses symlink/root/inode
replacement and mount traversal, and checks private ownership. Unlike whole-workspace
purge, execution-private scratch permits unrelated views of the backing filesystem
created by systemd ReadWritePaths; mounts inside scratch are still refused. Unsupported platforms
retain scratch. A crash during removal retries the same identity; a crash after
removal retries parent fsync before deleting the receipt. There is no broad /tmp scan
or mtime-based deletion. The managed-execution trust boundary and same-uid writer
limits of mission-workspace-purge.md also apply here. Scratch is execution-private;
other jobs must not use it as shared storage or as a working directory.

## Cache pressure and attribution

The existing locked checkout/Lake-cache collector starts below
SANDBOXED_NODE_MIN_FREE_GB, then aims for that floor plus 20 GiB (capped at filesystem
capacity), avoiding repeated threshold crossings. Admission keeps the original floor.
Logs distinguish attempted, removed and remaining bytes/free space; measured free
space, rather than summed directory sizes, determines recovery.

The read-only storage inventory accepts a node jobs.db and full UUID mission
folders, reports job-state counts and last completion without exposing payloads,
and always retains node-owned source. Apparent bytes and allocated blocks are
reported separately; nested records overlap, and reflink/shared extents mean neither
is a promise of reclaimable space. Missing/unreadable indexes stay unattributed.

Tests must cover running/unretired and interrupted scratch, delayed reclamation,
failed execution, symlinks/replacement, persisted restart recovery, and node UUID
attribution. Only temporary test directories may be removed during validation.
