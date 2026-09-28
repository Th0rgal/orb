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

Grok Bot has a separate experimental adapter pinned to the installed 0.58.0
user-scoped protocol. `GROK_BOT_CREDENTIAL_FILE` references a protected Core
credential file; `GROK_BOT_OWNER` scopes discovery and `GROK_BOT_VALIDATED=1`
gates activation. Credentials never enter missions. A dedicated Bot preserves
conversation identity; all Bots on the account share one computer. No admin
methods, attachment uploads, arbitrary model overrides or file deletion are used.
See GROK_PROTOCOL.md for real compatibility evidence.

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
actions, are not implemented yet. Orb settings
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

Grok protocol evidence is in [GROK_PROTOCOL.md](GROK_PROTOCOL.md). Authorized
Keychain access supplied the service credential. Dedicated Bot canaries verified
creation, follow-ups, restart recovery, deduplication, expired authentication
recovery and confirmed interruption. Production activation passed the guarded Core deployment on 2026-09-26,
after the unrelated active harness finished. Hermes was restarted for the new MCP.

The companion Hermes project-manager instructions are supplied as
`patches/hermes/cloud-agent-tools.patch`; the corresponding guidance was installed alongside the updated MCP.
The two sandboxed.sh controller/mission skills are updated directly.

Cursor repository discovery caches successes and failures for five minutes to
respect the discovery endpoint's rate limits. Creation verifies that `/me`
identifies a user API key. Model variants/parameters are exposed in Orb. Rendering detailed
provider events remains outstanding; durable events are exposed by Core.

## Model selection and presentation (2026-09-26)

Cursor discovery returns model IDs plus supported parameter combinations; Orb
shows searchable variants and forwards the exact ID/params pair. Repo discovery
failure no longer discards the model catalogue. ChatGPT explicitly verifies the
visible generation 6 and requested Instant/Medium/High/Extra High/Pro power before
submission. Model overrides belong to individual turns, preserving prior
selection history and idempotency checks. MCP exposes `list_cloud_models`.

Cloud conversations reuse Orb's Transcript and Composer. Unsupported uploads,
context commands and stop controls are filtered out. Semantic ChatGPT extraction
preserves tables, source links and original TeX; the shared renderer supports
KaTeX, ordered lists, escaped text and HTTPS Markdown images. Generated artifacts
remain authorized downloads. This does not advertise inbound attachments.

The primary browser identity was verified in ChatGPT Settings as ben@starknet.id,
also present in Codex account discovery. Codex also has thomas@lfglabs.dev; OAuth
tokens are not substituted for browser login cookies. Account identity labels
are held separately from missions in a service-side identity file.

Navigation shortcuts are centralized in `orb/src/keyboardShortcuts.ts` in the
live Orb checkout, with reserved chords documented in `orb/docs/KEYBOARD_SHORTCUTS.md`.
The final UI checks passed 26 unit tests, 3 browser scenarios, TypeScript and Vite.
A read-only check of ChatGPT profile 9 returned `auth_required`; it needs browser
login before use. The primary profile remains authenticated.

The live ChatGPT code-card canary returned a fenced Python block (`print(44)`)
on the same conversation after changing Instant → Pro → Instant. Extraction
recognizes semantic code cards even before pre/code elements hydrate.

Production Orb Grok canary `e24cc8eb-602e-439c-ac82-da44cffa9896` completed,
rendered a table/formula/code, then accepted a marker-recalling follow-up after
UI reload. Single-line display math from Grok is covered by a renderer regression
test. The isolated validation Core on port 3012 was stopped after verification.
