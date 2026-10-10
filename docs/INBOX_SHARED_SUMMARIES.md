# Shared Inbox summaries

Desktop, iOS and Android request `POST /api/control/missions/:id/inbox-digest`
with `{ "model": "builtin/smart" }`. Core authorizes access using the caller's
mission store, builds the evidence snapshot, runs a tool-free metadata model,
and persists the schema-7 result in `ask.db`. Concurrent requests for the same
user, mission and requested model are coalesced. A source revision hashes the
recorded conversation and mission update timestamp; a changed revision
invalidates the cached result. Changes during generation return HTTP 409.

The response contains `context`, `contextDetails`, `outcome`, `unresolved`,
`decision`, `suggestions`, `sources` (exact quotes and optional event sequence),
`model`, `sourceUpdatedAt`, `sourceRevision` and `generatedAt`.
Sources must match message evidence; ungrounded results are rejected.
No summary request writes mission history, runs tools, or interrupts a harness.
Summaries retain the agent's uncertainty and are not independent verification.

All clients show the same fields, preserve the runtime title and status, and
open the original conversation from a source. Mobile previews expand in place
inside rounded cards. Suggestions fill an editable draft and require explicit
sending. Existing mobile draft text disables insertion. Stale summaries are
labelled and cannot offer current reply suggestions. Legacy desktop summaries
remain display fallbacks but do not prevent a shared-summary refresh.

`GET /api/control/inbox-state` reads per-user presentation data.
`PUT /api/control/inbox-state/preferences` stores `aiSummary`,
`includeAutonomous` and `model`. Autonomous agents are excluded by default.
`PUT /api/control/inbox-state/seen/:id` stores `{ "stamp": milliseconds }`:
positive marks a response read, negative marks that response unread.
Clients refresh this state every ten seconds while the Inbox is open and
serialize writes. A late fetch is fenced after a local edit or account change.
The mission `/opened` acknowledgement remains separate; marking unread never
clears it or changes execution state. Archive continues through the existing
mission-status API.

Roll out Core before distributing the updated native clients. Older Core
returns an unavailable-summary state rather than generating a divergent
client-side summary. Native builds and deterministic fixture tests validate
presentation; they do not demonstrate production model availability.
