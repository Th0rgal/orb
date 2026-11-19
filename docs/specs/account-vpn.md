# Per-account VPN routing

A connected account defaults to Direct. Choosing VPN reserves a route to a
country for that account, including when a sidecar selects the credential.
Core owns the setting and the route lifecycle. Desktop and mobile display
Core's country, route status and most recently verified public exit.

## Admission contract

The pure kernel is in `lean/Orb/AccountVpn.lean` (Orb base `9c6b94da2`).
Ready bindings use the stable credential identity, canonical provider
category, verified country, and every public address the transport can use.
Address observations belong to a particular tunnel generation. Core must
invalidate them before reconnecting, changing a profile, or resuming after a
restart. Persisted server preference is safe to reuse after fresh verification.

| Obligation | Evidence |
| --- | --- |
| Each ready account occurs once. Within a category, each pair has disjoint public exit addresses. | `admission_preserves_isolation` preserves the invariant across a successful admission from a valid starting state. |
| Every admitted candidate has exit evidence and the requested country. | `admission_country_and_evidence`. |
| Admitting a handshake reservation fits the configured account-wide session limit. | `reservation_within_budget`, conditional on accurate occupied and pending counts and atomic use by the caller. |
| Selection prefers the saved server and reuses a compatible verified exit. | Checked selection examples cover reordered inventory, shared IPv6 across servers, compatible different categories, unavailable exits and saturation. |

For example, a first OpenAI login uses a Dutch server with two observed
addresses. A second OpenAI login seeking the Netherlands skips every tunnel
with either address. An Anthropic login can reuse the first server. This saves
one session and keeps the OpenAI exits disjoint.

## Runtime obligations

Only the transport owner can establish which credential was used, which address
families are reachable and which exit a provider observes. These facts are
inputs to the kernel. In particular, a WireGuard entry address, a sidecar's
provider-level routing label and an observation from Core's default network
are insufficient evidence. The runtime must canonicalize provider aliases and
IP representations before admission. Serialize reservation and admission across
competing requests, drain old transports before releasing a binding, and
reconcile failed handshakes and external sessions without disconnecting them.

Independent end-to-end tests must observe concurrent requests from two ChatGPT
accounts, a different provider category and a Direct account. Cover credential
selection, streaming, retry, token refresh, discovery and quota requests, a
tunnel interruption, Core restart, and a full session budget. A VPN transport
failure must never open a direct connection for the credential. Settings
responses, settings exports, logs and client state must omit secret material
after submission. These are deployment acceptance obligations.

## Live account selection

Use two connected ChatGPT accounts on dev and one connected ChatGPT account
for the production canary. Record the selected account identifiers in the
restricted deployment receipt. Exercise cross-category sharing with a fixture
until a live account in another category is designated. Use the existing admin
login for Settings. Never include credentials in the receipt.

### Sidecar version and reconnect acceptance

The binary inspected on agent-core reports CLIProxyAPI 8.0.26, commit
`a27799ec`; its SHA-256 is
`65e5de542296ea80293711d91393b7dbd655d40eb64461e993cd46fd9865b31e`.
In that revision, PATCH `/v0/management/auth-files/fields` sets
`proxy_url` on a named OAuth credential. The Codex executor passes that
credential's proxy URL to its refresh client. Its WebSocket transport also
honors a request-level override ahead of the credential setting. The OAuth
login handler constructs its exchange client from global configuration.

A passing per-file PATCH therefore cannot activate a verified route on its
own. Exercise a reconnect/token exchange and a request-level override against
an independent receiver before enabling a routed ChatGPT account. The
selected account's route must cover both flows. Core's display hydration can
fall back to the first matching provider type; never use that fallback as
authority to edit a particular credential.
