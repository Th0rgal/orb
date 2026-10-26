# Approvals

Missions ask for things only the user may grant: secret access (Bitwarden
read, write, delete, move), privileged access on a host (`ops_read`,
`service_deploy`, `root_exec`) and read access to another mission. These are
three stores (`secret_broker.rs`, `privilege_broker.rs`, `mission_access.rs`)
with one approval model on top (`src/api/approval_queue.rs`).

## The model

Every pending request is an `ApprovalItem`:

| Field | Meaning |
| --- | --- |
| `kind` | `secret`, `privilege` or `mission_access` |
| `id` | the request id in its store |
| `requester_mission_id`, `requester_title` | who asks |
| `tier` | what it does: `ops_read` / `service_deploy` / `root_exec`, `read` / `write` / `delete` / `move`, `read_mission` |
| `target` | where: a host, a secret or project, a mission id |
| `risk` | `routine`, `elevated` or `critical` (table in `shared/orb-spec/fixtures/approvals.json`) |
| `digest` | SHA-256 over every field that changes what approving grants (tier, target, mission, lifetime, unit, a write's value digest). Not the reason. |

`GET /api/approvals/queue` lists them for the signed-in user. The per-kind list
endpoints also carry `digest` on pending requests.

## One admission rule

Every approval, single or batch, of every kind passes the Lean gate
`orb_verify_approval` (`lean/Orb/Kernel.lean`, `approvalMetaGate` in
`Spec.lean`): the request is signed, owned by the approver, pending,
unexpired, unchanged since shown, and either below critical risk or
explicitly confirmed. A batch is admitted only when every item is.
`approval_queue::admit` is the only caller.

## Approve all

`POST /api/approvals/approve-all` (always device-signed through
`/api/approvals/challenge` and `X-Paloma-Approval`):

```json
{ "items": [{ "kind": "privilege", "id": "…", "digest": "…" }], "confirm_critical": false }
```

- One Touch ID / Face ID / BiometricPrompt signs the exact body, so the list,
  each digest and the confirmation are all signed. A request added after the
  challenge is not in the list; one that changed no longer matches its digest.
- Core writes the prompt text: counts per risk (critical first), then each item.
- At most 20 items, no duplicates.
- Critical items (root, secret delete or move) are left out by clients unless
  the approver ticks them, which sets `confirm_critical`.
- Order: every item is checked first; then privilege and mission access are
  each approved all-or-nothing under their store's lock, then secrets under
  the lock that serializes secret approvals. A secret write that Bitwarden
  refuses comes back denied with its error; the rest still apply.
- Each request keeps its own transition, audit entry and (for privilege) lease
  token, and every later command still goes through `orb_privilege_step`.

`POST /api/privilege-access/approve-all` (Orb 1.14 clients) is translated into
the same call.

## Clients

Desktop, iOS and Android label items with the shared fixtures
(`privilege-access.json`, `approvals.json`) and sign `{kind, id, digest}`.
