# Dev native job transport

This opt-in transport connects a job-private SOCKS listener on a trusted node to one Antigravity account relay. It adds no system service. The owner-profile executor remains disabled.

The node adapter sends one admission frame over a certificate-verified TLS connection to the Core-side adapter per provider connection. The Core-side adapter uses the existing authenticated Core API on loopback to check both the registered node bearer and the job grant. Core checks the job, current mission placement, caller, account, user preference, grant expiry and enrollment and VPN revisions. Core captures both revisions in its grant issuance transaction. Grants created before this transport have no relay binding. The dev endpoint requires authenticated Core with `ORB_INSTANCE=dev` and `DEV_MODE=false`.

The Core-side adapter connects only to the configured account SOCKS relay on Core loopback. Its RFC 1929 username is `antigravity/<account>`. It requests port 443 with a provider hostname from `Destination`, forwarding DNS resolution to the account relay. It parses the native TLS ClientHello and requires matching SNI before forwarding the original bytes. The provider handshake and certificate verification remain end to end. This is hostname-level admission. Encrypted HTTP paths are opaque to Orb.

Each admitted connection has a deadline from the Core grant. While connected the adapter rechecks Core every 250 ms with a 1.25-second authorization timeout. Cancellation, expiry, a changed binding or VPN generation, or loss of either relay closes the stream. The adapter has no direct upstream dial. Enforcing egress for *all* sockets opened by a native process still requires the job network namespace qualified in #2028.

## Trusted supervisor interface

Both roles run `python3 -I transport.py ROLE --listen-fd N --config-fd M`. The supervisor supplies a pre-bound stream listener and a private JSON pipe or descriptor. See the executable fixture for a complete invocation using `pass_fds`. Keep the adapters and their configuration descriptors outside the mission process. Pass the job just its private listener address. Namespace creation, adapter lifecycle management and provisioning a personal profile are separate from this transport.

| Role | JSON configuration |
| --- | --- |
| `core` | `core_port` for local authenticated Core, `account`, `relay_port` for the existing Core account relay, its account-specific `relay_password`, and TLS `cert` and `key` paths |
| `node` | Core-side adapter `host` and `port`, optional private `ca` path, and the supervisor-held `claim` containing `node`, `job`, `owner`, `account`, `revision`, `node_token` and `grant` |

The Core-side credential is the account-specific password from the existing `AccountVpnRelay.proxyUrl`. The adapter has no need for the key that signs those passwords. The node adapter accepts SOCKS5 DNS-form requests on its inherited job-private listener. Only the trusted supervisor may choose the listener, Core address and configuration.

## Reproduce

Use the disposable Linux guest from #2028 with only loopback, Python 3.12, the actual built binaries, and agy 1.5.14. Map `daily-cloudcode-pa.googleapis.com` to `127.0.0.2` in the guest. The direct-route trap binds that address on 443. Generate a disposable certificate on the fixture builder and install it and the temporary key in the guest:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=daily-cloudcode-pa.googleapis.com \
  -addext 'subjectAltName=DNS:daily-cloudcode-pa.googleapis.com,IP:127.0.0.1' \
  -out transport.crt -keyout transport.key
scripts/build_orb_bins.sh --only orb-core --only sandboxed-node
```

From the checkout in the guest, run:

```sh
python3 scripts/test_native_job_relay.py --core /bin/orb-core --agy /bin/agy-new \
  --cert /transport.crt --key /transport.key
python3 scripts/test_native_owner_node.py /bin/sandboxed-node
```

The transport test seeds a synthetic running job, native grant and corresponding issuance-time binding in an isolated Core database. It runs both adapter entry points, the genuine agy CLI, the Core HTTP admission and cancellation endpoints, a synthetic account relay and a synthetic Google TLS peer. The separate node control exercises ordinary signed job execution. The fixture does not enable owner-profile dispatch or use a subscription.
