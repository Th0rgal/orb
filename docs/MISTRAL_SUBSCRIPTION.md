# Mistral Vibe subscriptions in Orb

In Providers, choose **Add subscription account → Mistral Vibe** and approve
the sign-in in the browser. Mistral sign-in is independent of CLIProxyAPI.
The connected backend must include the Mistral login endpoints; rebuilding
only the Orb frontend is insufficient.

This uses the PKCE browser sign-in protocol implemented by the official
Mistral Vibe CLI (`vibe/setup/auth/http_browser_sign_in_gateway.py`). It
provisions a Vibe credential without importing browser cookies. The verifier,
exchange token and credential never enter Orb's responses. Cancelled attempts
cannot subsequently install credentials. Attempts expire within 15 minutes.

The credential is stored in the existing backend provider store and exposed
through the existing OpenCode Mistral integration. A persisted
`mistral_subscription` marker separates browser-provisioned accounts from
manually entered API keys in Orb. Existing Mistral API-key records remain
unchanged; replacing a record's key manually clears the subscription marker.
Existing provider priorities and routing rules still apply when multiple
Mistral accounts are configured.

Mistral controls the included allowance and overage behavior. Connecting an
account does not change its subscription or enable pay-as-you-go.

Endpoints beneath `/api/ai/providers`:

- `POST /mistral-login`: accepts `provider: "mistral"` and an optional existing
  subscription `provider_id`; returns the browser URL and an opaque session ID.
- `GET /mistral-login/:id`: polls and exchanges a completed sign-in once.
- `DELETE /mistral-login/:id`: cancels the backend attempt.

Validation: `cargo test --locked -j 1 --lib mistral_login` and, in `orb`,
`pnpm exec vitest run tests/provider-reconnect.test.tsx` and `pnpm build`.
Live acceptance additionally requires approving the browser login and testing
an OpenCode prompt with the resulting account. Unit tests alone do not prove
subscription billing or live model access.

## Usage visibility

Mistral Vibe's included allowance is monthly, separate from API throughput
limits. The official [limits FAQ](https://help.mistral.ai/en/articles/698531-why-am-i-hitting-api-rate-limits-and-how-do-i-increase-them)
and the [subscription console](https://admin.mistral.ai/subscription) describe
this allowance. Do not label it as a five-hour or weekly window.

Checked 2026-10-09 with the connected Vibe credential:

- The official CLI's `GET https://console.mistral.ai/api/vibe/whoami` accepts
  the Vibe key and returns plan metadata, but no usage percentage or reset date.
- The console's `billing.vibeUsage` query requires its authenticated web
  session. With only the Vibe key it redirects to sign-in, rather than returning
  quota data. Treating that response as zero usage would be incorrect.

Orb therefore links Mistral subscription rows to the monthly usage console
and explains the missing automatic counter in the expanded row. Ordinary
Mistral API-key rows do not get subscription indicators. Automatic percentages
remain unimplemented: they need a supported quota endpoint or a separate,
explicitly designed console connection. Do not import browser cookies or reuse
another account's quota to fill this gap. Never infer exhaustion from missing
quota data or mark a working Vibe key as expired because the console needs login.
