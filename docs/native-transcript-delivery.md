# Selected mission delivery in the native window

Bootstrap reads the same `ORB_STATE_DIR` (default `~/.orb`) `connection.json`
as locald. All three roster reads must succeed with one endpoint and token;
an empty roster is valid, a failed bootstrap returns `none`. Normal launch
should use `DesktopState.liveUnavailable` for that case. Project labels use
Core's `title` and `objective`. Credentials never enter the scene or argv.

`readLiveFrame` owns one cancellable child. It rechecks the three authorized
roster lists on startup and every five seconds, even without a selection.
The first 200 mission IDs are positive evidence only. A tracked mission missing
from that page is checked directly. The selected mission's ordinary read serves
as its check; unselected IDs use `?presence=1`, which skips the event subquery
and returns no transcript. Only a scoped 403/404 removes a tracked mission.
Null, malformed, or failed roster samples are retried without publishing removals.
With a selection,
it samples `GET /api/control/missions/:id/current-bubble` once per second.
Core authorizes this like `/events`, then checks the owner/share again in the
same SQLite read as the mission metadata and text. The partial index orders
relevant rows by effective sequence and id. Queued submissions are excluded
*before* choosing the latest row. No page of prompt/assistant payloads and no
mission history are sent to the client.

Assistant rows replace the bubble; committed user rows clear it. A queued
user row does neither. Only the resulting title, status, and assistant text
and the authorized roster IDs cross the pipe, once per changed sample. Selection changes discard the old
reader, pending text, attachments, undo state and draft. Status changes do
not discard a draft. Live Send/Stop activation does nothing and preserves the
draft. A selected mission's 403/404 removes only that mission. Lost credentials,
a denied roster request, 401, or dead reader invalidate the session projection.
A malformed or oversized selected bubble clears just the text. Redirects are refused.
Transient roster errors retry with backoff capped at five seconds.
Relaunch to bootstrap again after invalidation.

The live `runWindow` invocation should use `DesktopState.hasLiveConnection`
as its producer predicate, including on the roster. Its idle wait polls the
Wayland fd (input wakes immediately), sampling the mailbox after at most
500 ms. Unchanged samples cause no damage. Render the selected header via
`st.headerTitle`, status via `st.selectedCard`, and selection via the real
`st.sidebarRows`. Fixture screens do not start a reader.

This is a current-bubble projection, not full history. Core caps assistant text
at 65,536 characters plus an ellipsis; the client caps a bubble response at
1 MiB and each roster response at 4 MiB. Legacy file-only content is not
opened by this endpoint. Roster revalidation prunes but does not discover new
items or refresh unselected titles; the scoped bootstrap lists up to 200 missions.
Deploy the Core endpoint with or before the client; it does not fall back to
downloading mission history from an older server.

After the native build, run `lake env python3 -IB tests/test_live_delivery.py -v`
in `lean/OrbDesktop` (or supply the built modules on `LEAN_PATH`). The suite
uses a loopback HTTP server, the embedded transport and the production Lean
reader/reducer. Mission clicks pass through live screen layout, scene hit
regions and pointer press/release handling, including the shaped-header path.
