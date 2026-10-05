# OAuth credential ownership

Anthropic and OpenAI OAuth refresh tokens rotate: each refresh returns a new
refresh token and revokes the previous one. Two processes holding copies of the
same token race each other, and the loser is stuck with `invalid_grant` until
the user logs in again. This can cause recurring "login expired" states for Claude Code and Codex.

## Policy

`src/api/oauth_owner.rs` decides who owns a provider's OAuth credential.

- With server-only `CLI_PROXY_MANAGEMENT_KEY` configured and ownership set to
  `cli-proxy`, **CLIProxyAPI owns Anthropic, OpenAI, xAI, Kimi and Antigravity subscriptions**,
  including missing/expired logins. sandboxed.sh never resumes token renewal
  when a proxy login fails: the user reconnects through the UI instead.
- `CLI_PROXY_AUTH_DIR` is the authoritative account store. sandboxed.sh projects
  read-only quota snapshots and binds accounts by filename/email, preserving
  account UUIDs, labels, priorities, backend settings and independent API keys.
- Without management integration, the previous ownership detection remains:
  refreshable proxy files select proxy ownership; other logins use legacy flows.
- API keys and unsupported Google/GitHub subscription integrations retain their
  existing owners. Gemini CLI and Copilot are not native login providers in the
  deployed CLIProxyAPI version; Antigravity is a distinct Google integration.
- The Grok CLI harness keeps its own cached login in `~/.grok/auth.json`
  (its ACP transport accepts nothing else). Treat that as a second login on
  the same account, never a copy of the proxy's token.

Switch: `SANDBOXED_OAUTH_OWNER=cli-proxy` (default) or `legacy` (sandboxed.sh
refreshes its own copies, pre-refactor behaviour). `CLAUDE_CODE_DISABLE_CLI_PROXY=1`
also forces legacy.

## What each harness does when the proxy owns the credential

| Harness | Mechanism |
|---|---|
| Claude Code | `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` point at the proxy; any mission `.claude/.credentials.json` is deleted; host tiers are not read, copied or back-synced. |
| Codex | `auth.json` in apikey mode with the proxy key; `config.toml` gets `model_provider = "cliproxy"` and a `[model_providers.cliproxy]` section (`wire_api = "responses"`, `env_key = "OPENAI_API_KEY"`); `OPENAI_API_KEY` env carries the proxy key. Rotation sees one `cliproxy` credential; CLIProxyAPI rotates across its own accounts. |
| OpenCode | `opencode.json` gets native `anthropic`/`openai` blocks with `options.baseURL` = proxy `/v1` and the proxy key; the workspace `auth.json` entries become `type: "api"` with the proxy key; the OAuth plugins are not installed. |
| Inference proxy (`/v1/*`) | Anthropic OAuth records are no longer hoisted to a Bearer token; all Anthropic OAuth traffic takes the existing CLIProxyAPI branch. |

Containers: CLIProxyAPI listens on the host loopback. A container workspace
needs a shared network to reach it; host workspaces always can.

## UI login and reconnect

Orb, web and iOS call `/api/ai/providers/cli-proxy-login`. The backend requests a
login URL from the loopback `/v0/management` API. The browser performs consent;
Claude codes or Codex localhost redirects are pasted into the UI, while xAI and
Kimi device flows complete automatically. The backend forwards the OAuth state
and code to CLIProxyAPI; CLIProxyAPI exchanges, stores and renews the tokens.
The management key and tokens are never returned to the UI.

Reconnect includes `provider_id` and verifies that the selected account received
new credentials before reporting completion. Disable/delete actions update the
proxy store as well. Login sessions expire after 15 minutes and can be cancelled
with `DELETE /api/ai/providers/cli-proxy-login/:id`.

## Deployment

Configure CLIProxyAPI `remote-management.secret-key` and the matching backend
`CLI_PROXY_MANAGEMENT_KEY` using a secret manager. Keep `allow-remote: false`.
Set `CLI_PROXY_AUTH_DIR` to the proxy auth directory and ensure the backend can
read it. Management access requires a loopback proxy endpoint; never distribute
this key in desktop/mobile builds or workspace configuration.

Before enabling ownership, import only usable, non-rejected credentials; never
replace an existing proxy login with an older sandboxed.sh snapshot. Codex needs
its account/ID-token metadata and Kimi needs its device metadata, so reconnect
through the UI when those are unavailable. Rejected refresh tokens require new
browser consent. Verify login, inference and automatic renewal after deploying.

The one-time `scripts/migrate-cli-proxy-accounts.py` defaults to dry-run and
imports through management `auth-files` only with `--apply`. It skips rejected
or expired snapshots and preserves existing proxy files by default. The optional
`--replace-unusable` replaces only a single matching proxy file expired more than
24 hours ago with a currently usable source. It checks the proxy refresh token
generation again before upload and never replaces a live proxy login. Pass `--codex-auth`
for each matching native `auth.json`, and `--kimi-device-file` for the existing
`sandboxed-sh/kimi_device_id`. Imported metadata preserves the original row UUID,
including identityless Kimi accounts. Enable strict ownership before applying
the import, so sandboxed.sh has stopped renewing the source token generation.

## Antigravity subscriptions and native agents

Orb Providers → Add subscription account obtains the supported login types from
`GET /api/ai/providers/cli-proxy-login`. Select Google Antigravity, open the
consent link, then paste the complete localhost callback URL into Orb. Additional
accounts use the same flow. Reconnect preserves the existing account identity;
a different Google account must be added as a new account.

Antigravity is a distinct provider type, not Gemini CLI OAuth. Its proxy auth
files use the `antigravity` prefix, and model discovery reads that account's
management catalog. Requests retain `antigravity/<model>` all the way to the
proxy, so a Claude model selected through Google cannot consume a Claude
subscription by accident. No Google refresh token is exported to a workspace.

The native `agy` agent remains a machine-local harness, with installation and
login controls under Orb Settings. Connecting a proxy subscription enables
model inference through the backend; it does not replace the native agent's
session protocol or sign it in on other machines.

After rollout, reconnect any account marked as needing authentication. A
rejected refresh token requires fresh browser consent; importing it again
cannot repair it. Account disable and removal act on the connected backend's
proxy store. Cancellation and retry are available in the login dialog.
