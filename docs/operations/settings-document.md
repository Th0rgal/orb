# Settings transfer contract

The approved dev/prod plan transfers configuration, never instance data or
credentials. `OrbCore.SettingsDocument` owns the version 1 JSON contract and
validates the entire document before a diff can be rendered. CLI and storage
integration are still in progress; this document defines their boundary.

The required top-level fields are:

| Field | Contents |
| --- | --- |
| `version` | Integer `1` |
| `global` | Allowed execution/cleanup settings and library remote/revision |
| `routing_chains` | Chain ID, name, ordered provider/model entries, default and thinking flags |
| `inference_providers` | Existing provider IDs and enabled flags |
| `managed_providers` | Compute provider IDs and enabled flags |
| `user_preferences` | Existing usernames, inference/compute provider preferences and daily spending cap |
| `fleet` | Enabled flags, daily cap and maximum concurrent machines |
| `monitor` | Non-secret health-check thresholds |

Every object rejects unknown or repeated fields. Arrays reject repeated IDs;
usernames are compared without case, matching the users table. Counts must fit
a nonnegative signed SQLite integer. No export includes timestamps or local
user IDs. Object keys serialize in a deterministic order. Routing entry order
is preserved because it controls provider preference.

Provider configuration is intentionally projected to IDs and switches.
`ProxyModelRouting.chainResponse` already provides a safe provider/model-only
entry projection; export must use the same boundary. Import must preserve
matching inline settings already stored in the target through
`keepStoredEntrySettings`, including credentials that were never exported.
Library remotes with URL credentials, query strings or fragments are rejected.

The persistence integration must resolve usernames to accounts that already
exist on the target and reject missing users or provider IDs before mutation.
It must not create or copy accounts, password hashes, session epochs, grants,
mission budgets, usage counters, machines, projects, missions, transcripts,
vault configuration, proxy tokens or provider keys. Updating an existing
user's daily spending cap is configuration; the user's spending counters stay
local. The target's unrelated settings and secrets remain under their current
owners.

`settings import` must show the validated before/after diff, require `--yes`
to apply, and recheck its target snapshot before writing so confirmation does
not overwrite a concurrent edit. Errors contain fixed error codes rather than
rejected JSON. A failed or partial export must never become an empty import.

`refresh-dev` is prod → dev; `promote-dev` is dev → prod. Both use the same
export/validate/diff/import path and confirmation. Promotion is a local
operator action. Mission credentials cannot authorize it. These directions
transfer no database files, env files or secrets. Tests use temporary local
stores; live round trips and account-isolation checks run on dev.
