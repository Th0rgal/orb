# Request-bound privilege approvals (R11)

A privilege lease may be marked biometric-signed only after Core verifies an
enrolled device's P-256 / SHA-256 ECDSA signature. The existing client protocol
uses a base64 SPKI DER public key, a DER signature, and
`X-Paloma-Approval: challenge.device.signature`.

Core persists the exact issued `paloma-approval-v1` payload, HTTP method, raw
request target, SHA-256 of the exact body bytes, and 120-second expiry before
returning the challenge. Approval requires all of them to match. There is no
unsigned fallback, including when the device mode is changed. Unknown devices,
malformed keys/signatures, non-P-256 keys, altered bodies/paths/methods, and
expired or consumed challenges fail closed before any approval mutation.

After cryptographic verification a SQLite DELETE RETURNING atomically consumes
the challenge. Consumption is durable across restart and admits only one
concurrent caller. A separate unique request claim prevents a new challenge
from minting a second lease for the same privilege request. Pending-state and
request-expiry validation precede that claim. A failed operation may consume
its authorization; it never restores a reusable nonce.

Both privilege approval URL forms and the shared approve-all endpoint require
verification. Existing admin-only enrollment remains the trust boundary for
enrolled keys; this change does not attest device hardware or biometric policy.
