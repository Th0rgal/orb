# Dashboard queue snapshot synchronization

The Next.js control page reconciles queued flags with server snapshots. Queue
removal increments a mutation generation so an older response cannot restore
deleted state. Queue refreshes obey these rules:

- At most one queue snapshot request runs at a time.
- A refresh requested during an active request is retained. Multiple requests
  coalesce into a follow-up refresh for the most recently requested viewed mission.
- A snapshot applies only if its mission is still viewed and its captured
  mutation generation is current. Temporary optimistic messages remain unchanged.
- An error preserves displayed state and does not discard a pending refresh.
- There is no automatic retry loop when a failed request has no pending refresh.

Regression sequence: request A starts; a local queue deletion increments the
generation and requests B; A returns a pre-deletion snapshot. Discard A and run B.
Previously B was dropped by the in-flight guard, leaving no fresh reconciliation.

Mission-switch sequence: request A starts for mission A; the user switches to B
and requests B; A's response must not change B's queued flags. Fetch B next.

This covers queue-only refreshes. History reload reconciliation and mobile
foreground recovery are separate paths; this does not resolve every case in #333.
