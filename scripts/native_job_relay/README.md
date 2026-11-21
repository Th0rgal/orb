# Dev native job transport

This opt-in transport connects a job-private SOCKS listener on a trusted node to one Antigravity account relay. It adds no system service. The owner-profile executor remains disabled.

The node adapter sends one admission frame over a certificate-verified TLS connection to the Core-side adapter per provider connection. The Core-side adapter uses the existing authenticated Core API on loopback to check both the registered node bearer and the job grant. Core checks the job, current mission placement, caller, account, user preference, grant expiry and enrollment and VPN revisions. Core captures both revisions in its grant issuance transaction. Grants created before this transport have no relay binding. The dev endpoint requires authenticated Core with `ORB_INSTANCE=dev` and `DEV_MODE=false`.

The Core-side adapter connects only to the configured account SOCKS relay on Core loopback. Its RFC 1929 username is `antigravity/<account>`. It requests port 443 with a provider hostname from `Destination`, forwarding DNS resolution to the account relay. It parses the native TLS ClientHello and requires matching SNI before forwarding the original bytes. The provider handshake and certificate verification remain end to end. This is hostname-level admission. Encrypted HTTP paths are opaque to Orb.

Each admitted connection has a deadline from the Core grant. While connected the adapter rechecks Core every 250 ms with a 1.25-second authorization timeout. Cancellation, expiry, a changed binding or VPN generation, or loss of either relay closes the stream. The adapter has no direct upstream dial. Enforcing egress for *all* sockets opened by a native process still requires the job network namespace qualified in #2028.

## Trusted supervisor interface

Both roles run `python3 -I transport.py ROLE --listen-fd N --config-fd M`. The supervisor supplies a pre-bound stream listener and a private JSON pipe or descriptor. See the executable fixture for a complete invocation using `pass_fds`. Keep the adapters and their configuration descriptors outside the mission process. Pass the job just its private listener address. On Linux the trusted caller can use `supervisor.node_transport(config)` to create an anonymous loopback-only job namespace and start the node adapter. The returned descriptor is for the trusted privilege-dropping launcher. The workspace process receives the SOCKS address. The adapter stays in the outer namespace, using its inherited job-namespace socket for ingress. Its private configuration descriptor and supervisor lifetime pipe are excluded from the workload. Scope exit closes the lifetime pipe, waits for the adapter, and releases the namespace descriptor. Supervisor death also closes the pipe. The workload launcher remains responsible for terminating its process tree.

| Role | JSON configuration |
| --- | --- |
| `core` | `core_port` for local authenticated Core, `account`, `relay_port` for the existing Core account relay, its account-specific `relay_password`, and TLS `cert` and `key` paths |
| `node` | Core-side adapter `host` and `port`, optional private `ca` path, and the supervisor-held `claim` containing `node`, `job`, `owner`, `account`, `revision`, `node_token` and `grant` |

The Core-side credential is the account-specific password from the existing `AccountVpnRelay.proxyUrl`. The adapter has no need for the key that signs those passwords. The node adapter accepts SOCKS5 DNS-form requests on its inherited job-private listener. Only the trusted supervisor may choose the listener, Core address and configuration.

## Reproduce

Use the disposable Linux guest from #2028 with only loopback, Python 3.12, the actual built binaries, and agy 1.5.14. Map `daily-cloudcode-pa.googleapis.com` to `127.0.0.2` in the guest. The direct-route trap binds that address on 443. Generate independent provider and adapter certificates on the fixture builder. Install the temporary files in the guest:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=daily-cloudcode-pa.googleapis.com \
  -addext 'subjectAltName=DNS:daily-cloudcode-pa.googleapis.com' \
  -out transport.crt -keyout transport.key
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=fixture-adapter -addext 'subjectAltName=IP:127.0.0.1' \
  -out front.crt -keyout front.key
scripts/build_orb_bins.sh --only orb-core --only sandboxed-node
(cd lean/OrbCore && lake build orb-airvpn-sidecar-test)
```

From the checkout in the guest, run:

```sh
python3 scripts/test_native_job_relay.py --core /bin/orb-core --agy /bin/agy-new \
  --driver /bin/orb-airvpn-sidecar-test --cert /transport.crt --key /transport.key \
  --front-cert /front.crt --front-key /front.key
python3 scripts/test_native_owner_node.py /bin/sandboxed-node
python3 scripts/test_native_owner_core.py /bin/orb-core
python3 scripts/test_native_supervisor_loss.py
```

The test creates a fresh Core store using the real enrollment and grant issuers, then seeds a synthetic running job and placement. It runs both adapters, the genuine agy CLI, the Core HTTP admission and cancellation endpoints, and Orb’s authenticated account relay backed by a disposable SOCKS gateway and Google TLS peer. The separate node control exercises ordinary signed job execution. The fixture does not enable owner-profile dispatch or use a subscription.

## Transport baseline at 11e45a19

The guest had only the loopback interface. The guest runner recorded the following output and exit statuses.

```text
9 rejected requests; account-relay connects=0
old grant with updated enrollment revision denied
unlisted SOCKS host, port 80 and mismatched inner TLS SNI denied
native agy 1.5.14 Carbon SUCCESS; verified provider TLS through assigned account relay; direct hits=0
grant expiry closed established TLS; reconnect denied
assigned VPN gateway unavailable with live grant; native agy ERROR; origin delta=0; direct hits=0
Core cancellation closed established TLS; reconnect denied
transport exit=0
reserved node: signed owner and other-user jobs 403; unauthenticated job 401; workspace absent
restart with missing or changed owner binding: refused before listening
ordinary node: valid signed job admitted and succeeded
ordinary and reserved node controls exit=0
```

## Owner dispatch and supervisor qualification

The authenticated Core mission-creation and message endpoints exercise enrollment, owner binding and resume admission. The enrolled owner receives `native_owner_executor_unavailable` on dispatch. The reserved node rejects signed generic jobs before workspace creation. A synthetic running placement is seeded only in the independent transport test. Its real grant issuer and cancellation endpoint belong to Core. The supervisor consumes the resulting scoped claim.

The native CLI uses its Gemini API-key interface with a disposable fixture value and independent synthetic TLS upstream. Both models use a clean, unprivileged CLI identity in the job network namespace. A synthetic provider requests a native command to write the current working directory to the ledger. The test checks its contents, file owner and native conversation ID on follow-up. Neither the fixture profile nor the workspace contains a subscription login.

A network namespace controls sockets. The authenticated CLI still needs a way to delegate **all** workspace file access, commands, hooks and stdio MCP to a different OS identity, including after resume. The tested native tool interface lacks a documented mandatory executor with fail-closed disconnect. A separate restricted-main-agent fixture now demonstrates genuine writes by the existing Orb workspace MCP under a different UID. It also demonstrates that a CLI turn can succeed after losing that MCP connection. Until that exists, a private native login on the CLI identity would be accessible to local workspace tools. The [capability investigation](../../docs/specs/antigravity-model-account-selection.md) records the ACP handshake and native UID evidence. The supervisor is independently callable. Core and the node continue to deny shared-profile execution.

The crash regression waits for a SOCKS greeting, exits the supervisor immediately and holds an independent reference to the job namespace. It requires EOF on the established socket and ECONNREFUSED on a fresh connection while that namespace still exists. Closing only the asyncio server listener left the active socket open until the protocol timeout on Python 3.12. The adapter now cancels accepted handlers when the lifetime pipe closes.

Final disposable guest output (Core startup lines omitted)

```text
9 rejected requests; account-relay connects=0
old grant with updated enrollment revision denied
unlisted SOCKS host, port 80 and mismatched inner TLS SNI denied
gemini-4-carbon-high: native workspace file uid=16001; same conversation resumed
gemini-4-neon-high: native workspace file uid=16001; same conversation resumed
grant expiry closed established TLS; reconnect denied
gemini-4-carbon-high: gateway unavailable; resume ERROR; origin delta=0; direct hits=0
gemini-4-neon-high: gateway unavailable; resume ERROR; origin delta=0; direct hits=0
Core cancellation closed established TLS; reconnect denied
supervisor teardown: temporary profile removed; job namespace released
transport exit=0
reserved node: signed owner and other-user jobs 403; unauthenticated job 401; workspace absent
restart with missing or changed owner binding: refused before listening
ordinary node: valid signed job admitted and succeeded
ordinary and reserved node controls exit=0
initial and resumed mission dispatch denied; zero node jobs
targeted catalog: owner 503, other user and admin 403
other node owner 403; other account owner 403; owner revision 1; stale revision 409
rebind revision 2; old grant 401; unrelated grant active; restore original account at revision 4: old grant 401
restart without roster owner: persisted reservation refused catalog access
mission admission exit=0
supervisor process loss: active SOCKS connection closed; listener refused reconnect
supervisor loss exit=0
```
