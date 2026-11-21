# M3: ben visibility receipt

Use `python3 scripts/ben_visibility_receipt.py --manifest PRIVATE_PLAN --receipt PRIVATE_OBSERVATIONS`.
With no inputs it prints 18 blocked cells and exits 3. Exit 1 means unexpected
visibility; 0 means all designated projections matched. This compares operator
observations offline; it does not authenticate a caller or exercise Core.

Before collecting observations, the owner supplies a dated, unique `walk`
reference, authorized existing ben identity binding for each transport, and a
complete visibility manifest naming each documented list/metadata operation,
scope and designated fixture. Verify the binding in the authorized client. A
member role alone is insufficient. Keep all inputs private. If any prerequisite
is missing or the operation can return contents or secret values, skip the cell.
Do not provision resources, mint a session, fetch details, or try another identity.

Both JSON documents use `identity: "ben"`, `target: "production"`, the same
`walk`, and a `cells` object keyed by `surface/REST` or `surface/MCP` (case
sensitive; use the keys printed with no inputs). The operator assigns opaque
aliases consistently before collection; use a distinct unapproved alias for
any unexpected row, never discard it. Example cell entries:

```json
{"projects/REST":{"operation":"designated-project-list","mode":"list","aliases":["own-A","shared-B"]}}
```

```json
{"projects/REST":{"operation":"designated-project-list","outcome":"visible","complete":true,"aliases":["shared-B","own-A"]}}
```

`complete` means the approved scoped list is exhausted. Missing positive
fixtures, truncation and unsupported operations block coverage. For a documented
denial use manifest mode `denied` and observation `permission_denied` only for
an explicit authorization refusal; a missing route/tool or generic error is
not a denial. Stop collection for the cell at first unexpected visibility,
even on a partial page. Record one private remediation node per distinct leak
with walk reference, surface, protocol and mismatch class only. Never attach
response bodies or identifiers. Report deployment SHA and time privately.

| Surface | Metadata boundary (REST and MCP evaluated independently) |
| --- | --- |
| missions | Designated mission list identifiers only |
| projects | Designated project list identifiers only |
| files | Names in an approved test folder; no file reads |
| secrets | Names-only visibility or documented denial; never get a value |
| machines | Designated machine roster only |
| settings | Metadata only; no configuration dump |
| Inbox | Designated fixture references only; no message or digest contents |
| search | Designated test query; only if metadata-only results are supported |
| providers | Designated provider metadata only; no account details or credentials |

Each pass is limited to that projection, scope and observation time. No matching
operation for a transport means blocked; never substitute another surface.
