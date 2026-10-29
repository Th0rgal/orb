# Mission workspace lifecycle and reclamation

Archiving (`Acknowledged`) changes presentation only. Retention settings and disk
pressure produce inventory proposals; they never grant filesystem permission.
Unknown `mission-*` directories and legacy `.deleted-mission-*` quarantine names
are retained, including when the complete mission index has no matching owner.

Conversation DELETE preserves source directories. It refuses live/unconfirmed jobs
and outstanding purge receipts; recovery history remains until permission is
revoked/restored or purge finishes. Existing descendants opt-in still applies.

## Explicit discard contract

Authenticated `POST /api/control/missions/:id/workspace-purge` accepts:

```json
{"action":"authorize","discard_untracked_ignored_and_unpushed_work":true}
```

This is a separate explicit abandonment of all filesystem work, including ignored
builds, untracked files, and commits which have not been backed up. False/missing
abandonment cannot authorize deletion. A retry returns the persisted receipt.
`{"action":"restore"}` revokes permission and restores quarantined source while
recoverable. Ordinary native resume/follow-up, job start, fork/clone and movement
must revoke under admission serialization before using source again.

The projects SQLite store owns a receipt per mission and a transactional audit
trail containing the full permission/path/inode receipt at each transition.
Receipt phases are `authorized -> quarantining -> quarantined -> removing
-> purged`; `authorized/quarantining/quarantined -> revoked` restores source.
`removing` is an irreversible fence, persisted before recursive removal; resume
refuses rather than silently creating an empty checkout. No permission is inferred
from timestamps, status, directory names, settings, or environment variables.

## Execution and crash recovery

`WORKSPACE_GC_EXECUTE=1` allows the hourly lifecycle sweep to consume explicit
receipts, independently of advisory retention settings. Without it, no lifecycle
filesystem changes occur. Authorization alone does not move files. Quarantine is a
same-filesystem descriptor-relative rename that refuses overwrite; the parent is synced and the receipt records inode/device
identity for both directory and parent. A seven-day recovery window starts when
quarantine intent is persisted before the rename, not from workspace mtime.

A crash after intent but before rename retries the move with a new full recovery
window. A crash after rename but before acknowledgement verifies the same inode
and repeats the parent fsync before completing the receipt. Restore retries and
already-absent final removal also repeat this durability barrier. A crash during final
removal retries the `removing` receipt; missing quarantine completes idempotently.
Permission/audit persistence errors prevent starting a mutation; uncertain later
errors retain the receipt for reconciliation. Source reappearance, inode/root
replacement, unreadable metadata, and both source+quarantine existing fail closed.
Final recursive removal opens the authorized inode through its parent descriptor
and traverses child descriptors. Identity checks detect replacement at observation
points; they are not an atomic compare-and-unlink primitive. Symlinks are
unlinked without traversal. Ambiguous device views/bind mounts and nested mounts
are retained. This implementation is Linux-only; other platforms refuse purge.

Each mutation holds the mission workspace lock, process admission mutex and
existing durable admission file lock, in that order. Every sweep rechecks mission
execution/queued ownership across live and offline stores, durable workspace jobs,
exec scopes, physical directory sharing (including archived owners, explicit cwd,
fork tags, aliases and short-id collisions), transfer state, persisted root and
receipt identity. Any failed read retains source/quarantine. Another mission's
permission cannot discard a shared workspace.

Remote/client placements are refused until node-local lifecycle support provides
these guarantees. Core never applies a local look-alike path to an unavailable
node. There is no remote purge fallback. Local workspaces with unresolved remote
claims are also retained. The first API has no client UI; desktop, iOS and Android
archive/delete remain non-destructive and do not issue discard requests.

## Verification scope

Regression tests exercise receipt persistence/idempotent audit, abandonment,
seven-day delay, rename crash recovery, failed persistence before mutation,
restore/revocation, source/inode replacement, legacy quarantines, history deletion,
and shared/durable ownership, failed-before-termination jobs, queued MCP actions,
and deletion without an actor/admission deadlock. Only temporary test directories may be removed
while validating this change. No production GC or system configuration changes
are part of validation.

Existing formal gates (`orb_verify_track_hold`, native lifecycle admission) remain
reused through execution ownership. No GC authorization model previously existed
in the formal kernel. The filesystem crash/lock contract above is an I/O contract;
no claim of an end-to-end formal filesystem proof is made.

## Isolation and deliberate limits

Before renaming, the authorized directory is made mode 0700 through its verified
file descriptor. Recovery verifies and reapplies this isolation before recording
`quarantined`; restore reinstates the recorded mode. The directory and its parent
must belong to the service uid, and the parent must not be group/world writable.
Final removal rechecks these conditions. Symlink and mount traversal are refused
with `openat2`; unsupported kernels fail closed.

The authority boundary is managed execution: same-uid/privileged application
writers must honor lifecycle admission, and jobs must remain in their managed
scope/process group. Private directory permissions exclude other Unix users,
but cannot exclude a privileged or same-uid process with preexisting descriptors.
An unrelated root process or same-uid process deliberately moving foreign data
into quarantine is outside this contract. Descriptor-relative operations alone
do not prevent such mutations. This service already trusts its execution identity;
this change does not claim OS isolation from that identity. Deployments allowing
unmanaged writers with that identity must leave the sweep disabled.

Filesystem purge defers while *any* accepted MCP action or managed exec /
durable scope is present. This favors retention over throughput; implicit action
arguments and legacy scope names cannot prove physical disjointness. Remote job
termination without node-local proof also retains data regardless of display status.

Conversation deletion checks accepted actions against the full deletion set
(including descendants), under the same admission fence. It retains issuer,
parent (including the existing `orb_<uuid>` origin-session inference), superseded
and explicit target missions for queued, dispatching and
uncertain actions. Replacement launches also retain their inherited successor
parent, resolved with the same helper used by mission creation; failed store
reads or an overlong successor chain refuse deletion. Unrelated actions with audited dependencies do not block
history deletion; malformed/legacy targets and unaudited tools fail closed.
Board acceptance only records a settled verdict, but its task UUID blocks
deletion of the boss whose deletion would cascade to that task. Task keys are
board-local and protected by the issuing boss identity, never compared globally. Machine
destruction owns the machine. Neither requires unrelated conversation history. Rejection/resumption
through indirect board references remains conservative. Blockers identify the
action ID, tool and state without exposing arguments. Action receipts are never
settled or removed by conversation deletion. Existing execution, durable-job,
cloud, descendant and purge-receipt guards still apply.

Regression order: accept work for B; leave its dispatch uncertain; delete terminal
A successfully; refuse deleting B or its issuer/parent/superseded mission, including
when B is a descendant in the deletion set. Unknown scopes must still refuse.

The global policy remains for project-wide history deletion, retention and
mission-directory purge.
The separate administrator workspace/container destruction API is unchanged and
remains an explicit whole-container operation; this feature does not route GC
through it or claim to govern container destruction, manual shell removal, or
host cache cleanup. Those operations require their own lifecycle policy.
