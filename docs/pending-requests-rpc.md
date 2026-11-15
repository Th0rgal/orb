# Pending requests RPC — Spec Card (frozen 2026-11-15)

* Scope: desktop `pending_requests_list` and single-item
  `pending_requests_approve {kind,id,expected_digest}`; unified Core queue kinds
  secret, privilege and mission_access. Tethers are outside this contract.
* List returns Core's queue. Approval refreshes that queue and requires the
  displayed digest to match before signing exactly one item. A single-item
  approval explicitly confirms that item's critical risk.
* Linux lock state comes from `omarchy-shell lock isLocked`; locked, missing,
  failing or unrecognized output refuses both commands. Check again after
  signing. Caller-provided lock flags carry no authority.
* Capture the saved connection and its generation. Every network operation uses
  that origin and token; any connection change aborts, including switch-away/back.
* Resolve the existing enrolled device by signer public key using
  `/api/approvals/devices`. Request a server challenge bound to the exact serialized
  approve-all body, validate its payload, sign with grace zero, and submit once
  with `X-Paloma-Approval`. No enrollment, unsigned fallback or mutation retry.
* Failures remain errors (never an empty queue or fabricated success). Tests cover
  actual dispatch, malformed inputs, stale digest, lock failures, connection
  changes, challenge binding, cancelled signing and one-shot submission.

## Temporary restrictions and unresolved Core blocker

* Locald rejects every secret tier other than `read` before enrollment lookup,
  challenge creation or signing. Core's existing approve-all secret branch grants
  read even for write/delete/move and drops the encrypted value; these operations
  cannot safely use this batch route until Core is fixed.
* Locald rejects privilege requests with more than one `request.allowed_units`
  entry (and malformed non-array values). Core currently hashes `allowed_unit`
  but grants the full `allowed_units` collection, so the digest does not bind the
  complete multi-unit grant. These items remain visible in the queue.
* The challenge summary includes the selected kind, tier, target, reason and ID,
  with embedded newlines normalized. Locald requires the returned signed payload
  to contain that exact summary as well as the exact body hash.
* **Existing server-side security blocker:** Core's Control dispatch passes no
  headers to the approval handler, and Core does not verify `X-Paloma-Approval`
  server-side on this path. Sending a locally biometric-gated signature is not
  end-to-end device authorization: other callers can bypass locald's checks.
  The local restrictions do not fix this server-side enforcement gap. Core must
  forward and verify the approval header before this flow can be considered
  server-enforced device approval. No Core changes are included here.
