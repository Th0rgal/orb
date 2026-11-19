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
In that revision, PATCH `/v8/management/credentials/fields` sets
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

The fixture in `scripts/test_airvpn_sidecar.py` exercises that binary with
three synthetic Codex credentials inside a loopback-only Linux network
namespace. A TLS receiver recorded buffered inference as `fixture-a` from
127.0.0.2 and streaming inference as `fixture-b` from 127.0.0.3. The
management request for the Direct credential reached its receiver from
127.0.0.1. After changing only account A to an unavailable SOCKS proxy, its
management request and inference request failed. Run the fixture with
`unshare -n sh -c 'ip link set lo up && python3 scripts/test_airvpn_sidecar.py /usr/local/bin/cli-proxy-api'`.
A forced refresh of each synthetic login reached a TLS token receiver over its own exit.
The fixture covers per-file routing on this binary; reconnect,
Orb-driven configuration and live AirVPN sessions require separate receipts.

Core's sidecar listener binds to loopback when `ORB_AIRVPN_RELAY_PORT` is
configured. Use a distinct fixed port per Core instance and the same
operator-owned `ORB_AIRVPN_COORDINATOR_DIR` for instances on one host.
The relay authenticates an account-specific SOCKS5 credential and re-reads
that account's preference for each CONNECT. The downstream name goes to the
verified WireGuard gateway. A missing preference or unavailable gateway
rejects the connection.

For targeted OAuth reconnects, CLIProxyAPIPlus v8.0.56-0 at
`0341bcc440583738d7d0e673abefc63bbe99e131` provides the v8 per-login
proxy and target credential fields. Run the same isolated fixture with
`--reconnect` after the binary path. Its authorization-code receiver checks
the source address for each account. It also checks the adopted credential
ID, rotated refresh token and retained proxy URL for each file. This test
uses synthetic identities and the released aarch64 Linux binary.

Build the optional `orb-airvpn-sidecar-test` executable in the OrbCore Lean
package and pass its absolute path with `--orb-configure` to the fixture above.
This runs Core’s credential configuration client and authenticated relay against
the real sidecar. Only the verified gateway lookup and the upstream services
are fixtures. The independent receiver checks both accounts through the relay,
including requests with a conflicting `proxy_url` field in the public inference
JSON. Blocking account A in the relay leaves account B usable. Choosing Direct
for B clears its sidecar proxy and the receiver observes the direct source.

For a routing-chain entry that names a sidecar account, Core selects the model
using that credential’s unique sidecar prefix. When enabling VPN for a file
with an empty prefix, Core sets a deterministic prefix and the account relay
URL in one management PATCH. The account keeps its original Orb identifier.
Disabling VPN removes the generated prefix and preserves a pre-existing
operator prefix. Before forwarding a pinned VPN request to CLIProxyAPI,
Core checks the file’s current proxy URL and prefix against its route. The
local request carries the sidecar service credential. The sidecar sends the
provider credential through the authenticated relay.
