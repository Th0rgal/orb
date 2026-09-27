# Hosted cloud attempts

Development branch: `feat/orb-cloud-agents`, based on Orb `00ceacf7`.

Cloud execution receipts and deduplicated provider events live in the same
per-user SQLite mission database. The mission remains the attempt and owns its
project, folder tags, title and archive state. Existing missions are not migrated.

## Operator configuration

Cursor: `CURSOR_CLOUD_API_KEY` is service-side only. `CURSOR_CLOUD_OWNER` must match
the authenticated Core user ID. `CURSOR_CLOUD_VALIDATED=1` is an operator gate;
set it only after the bounded canary below. No API key is returned to Orb.

ChatGPT: uses the existing `chatgpt_ui` configuration and service-owned profiles.
`CHATGPT_CLOUD_OWNER` scopes profile discovery; `CHATGPT_CLOUD_VALIDATED=1` gates
creation. Account IDs pin a profile basename. No attachments or cloud repository
access are advertised. The original harness remains available unchanged.

Grok Bot remains unavailable. Bundle discovery identified user methods
`CreateGrokBotAgent`, `ListGrokBotAgents`, `ListGrokBotAgentSessions`,
`SendGrokBotUserMessage`, `GetGrokBotSendStatus`, and `InterruptGrokBotAgentRun`.
This is not proof of protocol compatibility or account authentication. No admin
method was invoked. A complete authenticated adapter and canary are outstanding.

## Verification / remaining gates

Required live canary: create a bounded test conversation, close Orb, restart Core,
observe the same provider identity and final result, then send one follow-up.
Verify repeated request keys do not produce another conversation or turn. Test
expired authentication and confirmed cancellation. Record provider/account,
external IDs, Core version and the result before enabling its gate.

ChatGPT and Cursor Cloud were activated in production on 2026-09-26 after
bounded HTTP and provider canaries. Both retain their external conversation
identity across Core restart and follow-up, and deduplicate exact request replays.
Production missions created through the Orb page returned the expected response
and remained readable after reloading the UI. MCP discovery, creation and result
retrieval passed against the real service. See [INSTALLATION.md](INSTALLATION.md)
for mission IDs, deployment paths, backups and remaining limits.

ChatGPT artifact download was verified through the owning mission's HTTP artifact
endpoint: `orb-cloud-check.txt`, 15 bytes, expected test marker. The driver supports
both observed message layouts and keyboard activation of the current download
button beneath its preview overlay. Pro is persisted and verified explicitly.

Track leasing/writer grants/scheduled admission, account connection/reconnection
actions, and the complete Grok connector are not implemented yet. Orb settings
show account availability and the ChatGPT pool state, with manual refresh. ChatGPT downloads
reuse the harness validation and are served only from the owning mission output
directory, with its existing 8-file / 50 MiB limits.
Cloud requests with unsupported admission fields fail explicitly. Do not use
this initial cloud route for autonomous project-controller dispatch.

Cursor API contract: https://cursor.com/docs/cloud-agent/api/endpoints
The adapter uses v1 durable agents and runs, a caller-generated `bc-<uuid>` for
initial creation, SSE event IDs, and run reconciliation after stream loss.
An ambiguous follow-up without a run receipt is held for verification; it is
never resubmitted automatically. Orb archive never deletes provider files.

Local validation: Orb production build; 512 unit tests (including 5 cloud
tests); 2 Playwright scenarios for project/subfolder creation and conversation
reopening (mock providers); browser-driver and message-layout regression tests.
Seven Rust cloud tests pass (plus the explicitly run live canary): atomic launch/replay, database reopen, event
deduplication, transport state, and concurrent follow-up receipt preservation.

Grok protocol evidence is in [GROK_PROTOCOL.md](GROK_PROTOCOL.md). The installed
app reports a signed-in session; its encrypted session requires macOS Keychain authorization, which did not
complete during installation. No Grok RPC was invoked; the service-side
authentication contract remains unvalidated.

The companion Hermes project-manager instructions are supplied as
`patches/hermes/cloud-agent-tools.patch`; the corresponding guidance was installed alongside the updated MCP.
The two sandboxed.sh controller/mission skills are updated directly.

Cursor repository discovery caches successes and failures for five minutes to
respect the discovery endpoint's rate limits. Creation verifies that `/me`
identifies a user API key. Model variants/parameters and rendering detailed
provider events in Orb remain outstanding; durable events are exposed by Core.
