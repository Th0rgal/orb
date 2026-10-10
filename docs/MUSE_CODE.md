# Muse Code subscription

Muse Code and Meta Muse API are separate provider types. `muse/<model>` continues
using the configured Meta API key. `muse-code/<model>` uses a Muse Code device
login owned by CLIProxyAPI; it never falls back to the Meta API provider.

## Setup

1. Run a CLIProxyAPI build with Meta OAuth support (validated with v8.0.23).
2. Configure the existing loopback management endpoint and authoritative auth
   directory. Sandboxed must not refresh its read-only copy of the credentials.
3. In Orb, Providers → Add subscription account → Muse Code. Approve the device
   code in the browser. An active Muse Code subscription is required. An account
   with a payment method alone is not sufficient.
4. Choose a model exposed by the connected account's live catalog. For example:
   `muse-code/muse-spark-1.3`.

CLIProxyAPI's native Meta adapter exchanges the device token for a Muse Code
credential. It does not launch the Muse Code CLI process. Account files must
have `type: meta`, `auth_kind: oauth`, `is_subs_active: true`, a DCA token and the
`muse-code` routing prefix. Unknown/inactive subscription state fails closed.
Model discovery uses the bound account's catalog, not the public Meta API list.

## API

Use the existing authenticated `/v1/chat/completions` endpoint with the explicit
`muse-code/` model namespace. Streaming and function tools use the same proxy
transport. A quota/authentication failure is returned to the caller rather than
retried against a pay-as-you-go Meta account.

Keep benchmark results under a distinct model identity. Do not relabel old
`muse/` results as subscription runs, or silently switch them to Contributor.
Contributor is a separate paid API offering with different data-use terms.

## Usage display and verification

Orb does not invent a percentage when the connection provides no quota counter.
The provider details say the remaining quota is unavailable. A successful HTTP
response alone does not prove subscription billing: verify the active-plan
receipt, explicit route and account selection, and the provider's own usage
records before claiming a billing result.

For rollout, stage the proxy with an empty auth directory first. Do not run two
proxy processes against copies of live rotating credentials. Back up the current
binary/configuration and use the normal guarded backend deployment procedure.
