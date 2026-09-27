# Orb side agents (`/btw`)

`/btw` opens an independent agent conversation in the side panel. Settings → Btw
selects its harness and model; the defaults are OpenCode and `builtin/smart`.
Settings apply to the next question. Changing the harness, model, or source
placement creates a fresh agent session with a new context cursor.

The agent runs on the source mission's host and in its working directory. It
has the harness's normal tools and permissions, with no extra Orb tool filter
or token budget. Files are shared: edits are immediately visible to the main
agent. Side questions do not enter the main agent's prompt or stop its run.

The first turn includes a bounded recent excerpt. Subsequent turns include only
public events after the session's last accepted cursor (at most about 6.5 KiB
of automatic excerpts), plus a short live-text snapshot only when it changed.
Legacy sessions without a cursor are migrated to a fresh child; their saved side
history is linked from the archive instead of replayed into the prompt.
The child harness already retains its own side history; Orb does not reinsert
that history into every prompt. The cursor advances only after launch/message
acceptance and resets for a different child/model/placement or reset event log.

`@conversation` points to `.paloma/conversation/<snapshot-id>/conversation.json`
inside the actual harness workspace (including a transferred workspace). It lists ordered `transcript.md` and `events.jsonl` parts containing the
full available public history and tool arguments/results. Archives omit private
thinking and unsent drafts. Large archives are split into bounded uploads, not
silently truncated. Agents are instructed to search/read relevant passages.
Uploads are staged into that workspace before the side harness starts, without
changing harness permissions. Core stages host snapshots through the authenticated
`/btw/context` endpoint; remote job startup copies the verified upload paths; local
Orb writes through its native workspace adapter. Paths reject traversal and
symlinks. Immutable snapshot paths avoid cross-conversation overwrite races. Each
send refreshes the archive; it is a snapshot, not a live subscription during the
answer. Files are staged through the existing local/Core/node upload transport.
This reduces prompt tokens, not archive upload bandwidth or retained harness
context. Reading the entire archive can still consume substantial tokens.

The launch request sets `side_context_mode: "incremental"` so Core does not
prepend the parent history a second time. Legacy callers retain their existing
snapshot behavior. Attachments are uploaded to the target host and their paths
passed to the agent; local images also use native harness attachment arguments.

Core creates the side mission through `POST /api/control/missions/:id/btw/agent`.
Only that internal launch path permits the source workspace to remain occupied.
Side missions carry `btw-parent:<id>` and are excluded from Orb's conversation lists, project folders, and global archives. They remain accessible by ID for the side panel's transcript and lifecycle operations. Archive pagination counts raw rows before filtering, so hidden sessions cannot skip subsequent pages.
Local runs use the ordinary client-run protocol with a distinct run and harness
session identity. Remote runs use the regular mission runner.

The panel stores its conversation and child mission identity in connection-scoped
local storage. Reload reconnects to the stored child. Closing the panel hides it;
Stop cancels only the side agent. Local execution still requires the owning Orb
process/computer. Clearing local application storage loses the panel association;
cross-device history discovery is not implemented yet.

Verification: frontend unit tests cover separate child creation, continuation,
local placement, and cancellation; WebKit tests cover panel persistence and
attachments. The opt-in `btw_same_workspace_roundtrip` native test launches real
OpenCode through Core's client-run protocol, reads a fixture using tools, and
checks the working directory and captured session identity.
