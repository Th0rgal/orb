# Mission-scoped MacBook tethers

Ending a session revokes its pending requests and approved session leases, clears their tokens, and invalidates their relay slots. Other missions, explicitly non-session-scoped leases, and standing relay pairs keep their own lifetimes. A duplicate terminal write does not advance the lifecycle epoch. Awaiting input, background work and rate-limit waits preserve the session.

The revocation boundary is the committed mission row. Writers include HTTP stop/delete and transition APIs, MCP cancellation and status changes, local/hosted and client-runner settlement, remote job completion/failure, dispatch and launch failure, queue interruption and restart reconciliation. Superseding a mission also ends its session. Explicit stop additionally releases the session even if no run is active. The relay observes the durable epoch before processing a packet; idle polling propagates the change to the laptop's events feed.

At approval Core records the direct peer candidate for the mission's placement. Local placements use the laptop's `mac_direct_endpoint`; remote placements use its `mac_wan_endpoint`. When the latter is absent, a remote client can use the advertised relay, never the laptop's LAN address. Managed VMs retain their relay-first policy. Requester-supplied host labels do not decide placement.
