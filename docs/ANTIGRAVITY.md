# Google Antigravity

Sandboxed.sh and Orb run Google's native `agy` CLI with backend ID
`antigravity`. This is separate from the `gemini` backend and does not route
through an API-key proxy. Install the official CLI from
https://antigravity.google/docs/cli/install/ and sign in by running `agy`
as the account that executes missions.

Run `agy models` to see the signed-in account's available model IDs. Orb's
local agent scan and Core's model endpoint use that command rather than a
hardcoded catalog. Select the exact account-supported model. An unavailable
model fails in the native CLI; it is never silently replaced. During validation
with CLI 1.2.16, Gemini 4 Argon was reported as `agy-demo`.

## Remote nodes

Install `agy` on the node's service PATH, then run it interactively as the
`sandboxed-node` service user and complete Google's native sign-in. Keep OAuth
codes and tokens out of mission messages, repositories, and deployment logs.

Configure the node service with:

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
for continuation. No credential value travels in a Core job payload.

Upgrade both `sandboxed-node` and its `sandboxed-mcp` companion before enabling
this backend. Existing production deployment and draining rules apply.

## Lifecycle and project context

Every turn uses `--output-format stream-json`. Success requires both an explicit
native `SUCCESS` result and a successful process exit. Missing terminal output,
a changed conversation identity, or a failed native result cannot become a
successful mission. Follow-ups use the stored `--conversation` ID, never the
CLI's most-recent conversation. Per-step token usage avoids counting the native
result's lifetime usage again on continuation.

Project skills use `.agents/skills`. The MCP supervisor temporarily merges its
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
