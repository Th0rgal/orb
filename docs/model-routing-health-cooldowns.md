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

When a sidecar file matches and its longest `cooldowns[].remaining_seconds` exceeds Core's own remaining cooldown, `GET /api/model-routing/health` folds that window into `cooldown_secs_remaining` and `cooldown_remaining_secs` (both fields carry the same remaining cooldown in seconds so callers reading either name observe the same window) and sets `parked_until` (`retry_at`), `parked_reason` (`reason`), and `parked_source: "sidecar"`. Because the live content of `cooldowns[].reason` and `cooldowns[].retry_at` on CLIProxyAPI has not been observed, `fetchSidecarAuthFiles` filters both to a fixed closed shape (`reason`: 1 to 40 ASCII lowercase letters, digits, or `_`, otherwise treated as absent so the default `"credential_quota"` applies; `retry_at`: 1 to 35 characters from `[0-9-:TZ+.]`, otherwise treated as absent so the computed `now + remaining_seconds` UTC timestamp applies). When Core's own cooldown is active and exceeds the sidecar's, `parked_source` is `"core"`; otherwise `parked_until`, `parked_reason`, and `parked_source` are `null`. Each row also includes `provider_id` (`hp.providerType`), `is_degraded` (`true` iff `cooldown_secs_remaining > 0`, `ProviderHealthTracker` has `parkedQuota` or `poisonedSub` set for the account's health keys, or `consecutive_failures > 0`), and `is_healthy` (`!is_degraded`). Request/token/latency counters that Core does not track per account (`total_requests`, `total_successes`, `total_rate_limits`, `total_errors`, `avg_latency_ms`, `total_input_tokens`, `total_output_tokens`, `last_failure_reason`, `last_failure_at`, `rate_limit_snapshot`, `account_state`, `next_probe_at`) remain absent. Neither endpoint ever exposes the sidecar auth file `name` or `email`.

## Clearing cooldowns (`POST /api/model-routing/health/:account_id/clear`)

`POST /api/model-routing/health/:account_id/clear` first removes `<account_id>` and `cliproxyapi:<provider_type>` from both Core owners (`proxyCooldownsRef` and `ProviderHealthTracker`). Then, if the provider row matches a sidecar auth file whose active `remainingSecs > 0` (healthy logins with `remainingSecs == 0` are never toggled):

1. It calls `PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": true}` (2-second timeout). If the management key is missing or this first `PATCH` fails, Core returns `502` naming the provider row id and stating that the sidecar cooldown was not cleared and the login was not disabled (so `502` means "Core cleared, sidecar not").
2. It immediately calls `PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": false}` (2-second timeout). If that re-enable call fails, Core retries `disabled: false` once; if the retry also fails, Core returns `502` naming the provider row id, stating that the login was left disabled, and advising the operator to re-enable it in CLIProxyAPI (`PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": false}`), since Core has no route that re-enables a disabled sidecar auth file.

## Interaction with `orb-sidecar-guard`

Each `orb-sidecar-guard.timer` run executes `scripts/ops/orb-sidecar-guard`, which reads the sidecar login list from `GET /v0/management/auth-files` on loopback (`GUARD_SIDECAR_URL`, default `http://127.0.0.1:8317`). For each enabled Claude login (`entry.get("provider") == "claude"` and `not entry.get("disabled")`) whose longest `cooldowns[].remaining_seconds` exceeds `GUARD_MAX_BAN_SECONDS` (`21600`), the guard releases the ban by calling `PATCH /v0/management/auth-files/status` with `{"name": name, "disabled": true}` followed by `{"name": name, "disabled": false}`, recording the release timestamp in `GUARD_STATE` (default `/var/lib/orb-sidecar-guard/state.json`). A login already released `GUARD_MAX_LIFTS` (`3`) times within `GUARD_WINDOW_SECONDS` (`21600`) is left banned because the quota limit is real; passing `--print` runs the decision as a dry run without modifying sidecar or state files.

Both `POST /api/model-routing/health/:account_id/clear` and `orb-sidecar-guard` release a parked sidecar credential using the same `PATCH /v0/management/auth-files/status` `disabled: true` -> `disabled: false` sequence (the admin clear route does not write to `GUARD_STATE`, so manual clears do not count against `GUARD_MAX_LIFTS`). Because `decide()` in `scripts/ops/orb-sidecar-guard` skips any entry where `entry.get("disabled")` is truthy (`if entry.get("provider") != "claude" or entry.get("disabled") or not name: continue`), a login left disabled after a failed re-enable in `POST /api/model-routing/health/:account_id/clear` is **not** re-enabled by `orb-sidecar-guard` and must be re-enabled in CLIProxyAPI (`PATCH /v0/management/auth-files/status` with `{"name": "<file>", "disabled": false}`).

