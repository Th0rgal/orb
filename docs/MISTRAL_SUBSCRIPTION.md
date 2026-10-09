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

## Native Vibe harness

Select **Mistral Vibe** in Orb's harness picker. Core/container and remote-node
turns use the connected Core Mistral provider through `/v1`. Local Orb turns
use the execution user's native Vibe login (`vibe` → sign in); server account
credentials are never copied to the desktop. Routing model suggestions show
their exact IDs when provider labels hide different aliases.

Install on each execution machine (and inside each container rootfs):

```sh
uv tool install --python 3.12 mistral-vibe==2.19.1
vibe-acp --version
```

Python 3 and `vibe-acp` must be on that execution user's PATH. Installation on
the Core host does not install it inside an nspawn workspace. Orb Settings →
Local agents accepts a `vibe-acp` path override. A missing CLI fails preflight;
it never silently switches to OpenCode. The same version is used for contract
validation. Software inventory treats Vibe as externally managed.

The shared ACP bridge (`shared/vibe_bridge.py`) runs native tools in the actual
workspace, selects Vibe's `auto-approve` or `plan` mode, and suppresses history
replayed by `session/load`. It journals the native ID before sending any prompt
and Core/Orb additionally acknowledge that identity. Only an ACP `end_turn`
result completes a turn; text followed by process exit is a failure. `/goal`
is not a Vibe native capability.

Proxy sessions keep their private Vibe configuration and native session logs
under `$HOME/.local/state/sandboxed-vibe/`. Preserve that directory and the
mission's recorded session ID across upgrades. Do not relaunch an unresolved
first attempt as a new session: inspect its journal and recover the native ID.
Remote launches use a per-mission proxy key with the existing retirement path.
MCP credentials are supplied by the unified scoped launcher, not project files.

Validation: `python3 -m unittest discover -s tests -p test_vibe_bridge.py`,
`cargo test -j 1 --lib vibe`, and Orb's routing-picker tests. Live acceptance
requires a native tool call plus a second turn on the same Vibe session.
