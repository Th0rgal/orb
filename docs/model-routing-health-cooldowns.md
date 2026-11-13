# Model routing health cooldown owners

Two owners hold a cooldown on a provider account: the legacy `proxyCooldownsRef` and the `ProviderHealthTracker` (`SM-21`) that the proxy plans routing chains from. For a login held by CLIProxyAPI (an OAuth-only account), the proxy records the cooldown under `cliproxyapi:<provider_type>`, not the row id.

`GET /api/model-routing/health` reads active cooldowns from both owners and reports the longest remaining window across the account's keys (`<id>` and, for OAuth-only accounts, `cliproxyapi:<provider_type>`). `POST /api/model-routing/health/:account_id/clear` clears those same keys from both owners and leaves other accounts untouched.
