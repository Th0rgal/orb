# Google Antigravity

Core and Orb run Google's native `agy` CLI with backend ID
`antigravity`. It replaces the retired Gemini CLI harness and does not route
through an API-key proxy. Historical Gemini CLI session IDs cannot be resumed
with Antigravity. Install the official CLI from
https://antigravity.google/docs/cli/install/ on each machine.

## One Google sign-in

Connect **Google Antigravity** once in Providers. That login (stored by
CLIProxyAPI for model routing) is also the login of every native run: both use
the same Google OAuth client, so Core copies it into the native CLI file
`$HOME/.gemini/antigravity-cli/antigravity-oauth-token` before `agy` starts in
a Core workspace, and pushes it to a node over the node's authenticated
`PUT /managed-auth/antigravity` before model discovery, transfer, or dispatch.
The refresh token travels with it, so `agy` refreshes long runs itself. A token
the CLI already refreshed for the same login is kept; a different login
replaces it. With no Antigravity login connected, an existing `agy` sign-in on
the machine is left alone.

The Providers card shows the Google plan (`paidTier`, e.g. Google AI Ultra) and
one quota bar per model family from Cloud Code `retrieveUserQuota`, each with
its reported reset. Google sets the window length per plan (5 hours, weekly…);
it is read from the reset time, never hard-coded. Reading the quota costs no
request.

Run `agy models` to see the signed-in account's available model IDs. Orb's
local agent scan and Core's model endpoint use that command rather than a
hardcoded catalog. Select the exact account-supported model. An unavailable
model fails in the native CLI; it is never silently replaced. During validation
with CLI 1.2.16, Gemini 4 Argon was reported as `agy-demo`.

## Remote nodes

Install `agy` on the node's service PATH. No sign-in on the node is needed:
the Core's login lands in `<work root>/managed-auth/antigravity` (mode 0600),
or in `SANDBOXED_NODE_ANTIGRAVITY_HOME` when set. To keep a node on its own
`agy` sign-in instead, set `SANDBOXED_NODE_ANTIGRAVITY_LOCAL_ONLY=1`, run `agy`
interactively as the `sandboxed-node` service user, and configure:

```ini
SANDBOXED_NODE_ANTIGRAVITY_HOME=/var/lib/sandboxed-node/.gemini/antigravity-cli
```

This value names the native CLI profile directory, not the user's whole home.
On Linux, CLI 1.2.16 stores `antigravity-oauth-token` there with mode 0600.
The node advertises the managed profile only while that file is private and
readable. This is a local credential-presence check; expired/revoked credentials
still require native sign-in. Verify `agy models` as the service user after
provisioning.

Jobs retain their isolated HOME. The node binds only
`$HOME/.gemini/antigravity-cli` to the operator-configured profile. Existing
workspace symlinks or conflicting destinations are rejected. The profile holds
both native authentication and conversations; it must stay on the same node
for continuation. No credential value travels in a Core job payload or the
node job database.

Upgrade both `sandboxed-node` and its `sandboxed-mcp` companion before enabling
this backend. Existing production deployment and draining rules apply.

## Lifecycle and project context

Every turn uses `--output-format stream-json`. Success requires both an explicit
native `SUCCESS` result and a successful process exit. Missing terminal output,
a changed conversation identity, or a failed native result cannot become a
successful mission. Follow-ups use the stored `--conversation` ID, never the
CLI's most-recent conversation. Per-step token usage avoids counting the native
result's lifetime usage again on continuation.

Project skills use `.agents/skills`; user-level global skills use
`~/.gemini/config/skills`. The MCP supervisor temporarily merges its
scoped server into `.agents/mcp_config.json`, holds an exclusive checkout lock,
and restores the original configuration on normal exit or handled cancellation.
User-defined servers are preserved. Concurrent runs need separate worktrees.
After a supervisor crash or SIGKILL, a stale `sandboxed` MCP entry fails closed;
remove that stale entry after confirming the old run has stopped. External
configuration edits during a run are preserved rather than overwritten.

Rebuild Orb and its bundled MCP companion after updating the source; refreshing
only the frontend cannot install native harness support. Orb Settings shows the
CLI path, account model count, or a sign-in/discovery error.

## Validation evidence

The shared stream parser is tested against a sanitized real Argon trajectory
in `tests/fixtures/antigravity_turn.jsonl`, including file writes, terminal
commands, tool results, usage, and the explicit terminal result. Focused tests
also cover duplicate completed steps, missing results, identity changes,
argument boundaries, managed-profile binding, and MCP restoration/locking.

On 2026-10-04, native CLI 1.2.16 passed a disposable multi-file feature task on
macOS: module and UI edits, two Node tests, a browser click changing a counter
from 0 to 1, and a screenshot inspected separately. Exact-session continuation
also passed. Native file-write/assertion and exact-session resume tests passed
as `sandboxed-node` on Core, old-agent, Ashur, Babylon, Nippur, and DGX Spark.
These CLI checks verify the account and protocol; deployed Core/Orb validation
must also be completed before calling the integration shipped.

A real Argon MCP probe also passed through the built `sandboxed-mcp` launcher
against an isolated loopback test gateway: the advertised tool was called,
its marker was returned, and the temporary project MCP configuration was
removed afterward. Core and Orb native test binaries both compile and pass
their focused Antigravity checks.

An isolated Linux Core instance also passed initial and follow-up Argon turns,
with file assertions, scoped MCP calls, and an unchanged persisted native
conversation ID. Production services and the installed Orb app still require
a coordinated upgrade.

Orb discovers remote models from the selected node's managed login through
an authenticated node endpoint; Core and local accounts are not substituted.
Prompts are limited to 16 KiB before native launch to stay within command-line
limits, including remote shell escaping. Put larger context in workspace files.

Core records native launch intent before starting the CLI. An ambiguous attempt
without a persisted conversation ID requires reconciliation; a proven failure
before launch can be retried. Backend handoffs carry bounded conversation
history. A committed machine transfer clears Antigravity's source-machine
identity and launch guard, then starts a fresh conversation with portable
history on the destination.

Orb also records an unbound native launch durably before starting the process.
If no conversation ID is recovered, retrying that mission is blocked even after
an app restart. Reconcile the native conversation and restore its exact ID before
continuing; do not remove the launch marker to blindly replay repository work.
Node transfer readiness requires both the installed CLI and managed profile.

An isolated Core-to-node mission passed three immediate turns with scoped MCP
calls, independent file assertions, a stable native conversation ID, and durable
per-turn input/output/cache usage. Its node model endpoint rejected unauthenticated
requests and returned the selected account's Argon model when authenticated.

Core's native model catalog runs discovery through the selected workspace's
execution environment (`workspace_id` on `/api/providers/antigravity-models`,
defaulting to the host workspace). Discovery uses a separate request so a slow
or stale login cannot block other harnesses in the shared catalog. Container account models are never inferred
from the API process login. Antigravity transfer history is always archived in
the checkpoint and referenced by a short prompt, including medium conversations.

Fresh backend configuration enables Antigravity even when `agy` is installed
only inside a workspace. Existing saved enable/disable settings are preserved;
if an older host-only probe disabled it, enable Antigravity in backend settings.
The selected workspace must still pass native model discovery and launch preflight.

Legacy assistant/Telegram channels configured for Gemini, or linked to a Gemini
mission, are deactivated before webhook registration. Configure Antigravity and
a workspace-native model, migrate linked missions without reusing Gemini native
session IDs, then reactivate the channel. Historical mission records are retained.
