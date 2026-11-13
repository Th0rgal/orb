# Model routing health cooldown owners

Three owners can hold a cooldown on a provider account:
1. Core's legacy `proxyCooldownsRef` (`AccountCooldown`),
2. Core's `ProviderHealthTracker` (`SM-21`) that the proxy plans routing chains from, and
3. CLIProxyAPI's in-memory credential/model cooldowns exposed on `GET /v0/management/auth-files` (`cooldowns[].remaining_seconds`, `retry_at`, `reason`).

For a login held by CLIProxyAPI (an OAuth-only account), Core's proxy records its own cooldown under `cliproxyapi:<provider_type>`, not the row id, while CLIProxyAPI parks the underlying auth file until the provider's quota reset window (`retry_at`).

## Matching an OAuth-only row to a sidecar auth file (`matchSidecarFileForProvider?`)

`GET /api/model-routing/health` and `POST /api/model-routing/health/:account_id/clear` fetch `GET /v0/management/auth-files` from CLIProxyAPI with a 2-second timeout and match an OAuth-only Core provider row to an enabled (`disabled == false`) sidecar file of the corresponding auth-file type (`anthropic -> claude`, `openai -> codex`, `google -> gemini`, `antigravity -> antigravity`, `github-copilot -> github-copilot`, `kimi -> kimi`) using four cases:

- **(a)** The row's `account_email` is set, and **1 OAuth-only row + 1 enabled file** of that type carry that email (case-insensitive): **match**.
- **(b)** Otherwise, **1 OAuth-only row and 1 enabled file** of that type exist, and the file's email is empty or equal to the row's: **match**.
- **(c)** **1 row, 1 file**, both emails set and different: **no match**.
- **(d)** Anything else (for example, multiple OAuth-only rows or multiple enabled files of that type without a unique email match): **no match** (no guess and no sidecar toggle).

When a sidecar file matches and its longest `cooldowns[].remaining_seconds` exceeds Core's own remaining cooldown, `GET /api/model-routing/health` folds that window into `cooldown_secs_remaining` (keeping `cooldown_secs_remaining` as the single cooldown-seconds field) and sets `parked_until` (`retry_at`), `parked_reason` (`reason`), and `parked_source: "sidecar"`. When Core's own cooldown is active and exceeds the sidecar's, `parked_source` is `"core"`; otherwise `parked_until`, `parked_reason`, and `parked_source` are `null`. Neither endpoint ever exposes the sidecar auth file `name` or `email`.

## Clearing cooldowns (`POST /api/model-routing/health/:account_id/clear`)

`POST /api/model-routing/health/:account_id/clear` first removes `<account_id>` and `cliproxyapi:<provider_type>` from both Core owners (`proxyCooldownsRef` and `ProviderHealthTracker`). Then, if the provider row matches a sidecar auth file whose active `remainingSecs > 0` (healthy logins with `remainingSecs == 0` are never toggled):

1. It calls `PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": true}` (2-second timeout). If the management key is missing or this first `PATCH` fails, Core returns `502` naming the provider row id and stating that the sidecar cooldown was not cleared and the login was not disabled (so `502` means "Core cleared, sidecar not").
2. It immediately calls `PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": false}` (2-second timeout). If that re-enable call fails, Core retries `disabled: false` once; if the retry also fails, Core returns `502` naming the provider row id, stating that the login was left disabled, and advising the operator to re-enable it in CLIProxyAPI (`PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": false}`), since Core has no route that re-enables a disabled sidecar auth file.

## Interaction with `orb-sidecar-guard`

`scripts/ops/orb-sidecar-guard` runs periodically via systemd (`orb-sidecar-guard.timer`) and checks `/v0/management/auth-files`. It restarts `cli-proxy-api.service` only when `total == 0` or `active == 0` (every auth file is disabled or missing), and treats upstream `429`/`quota` errors (`status_message` matching `429|quota|rate|exhausted|cooldown`) as normal parked state rather than an auth failure. Because `clear`'s `disabled: true` -> `disabled: false` toggle completes within milliseconds inside a single request, `orb-sidecar-guard` does not restart the sidecar unless a single-credential sidecar was left disabled after a failed re-enable retry (in which case restarting `cli-proxy-api.service` or re-enabling the file in CLIProxyAPI restores the credential).

