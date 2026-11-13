# Settings transfer contract

The approved dev/prod plan transfers configuration, never instance data or
credentials. `OrbCore.SettingsDocument` owns the version 1 JSON contract and
validates the entire document before a diff can be rendered. The CLI accesses
existing stores without starting Core or running its startup migrations.

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
Removing a chain or entry with local inline settings is refused; resolve that
configuration separately before transferring settings.
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

Run as the local service operator, with the instance's service environment:

```bash
orb-core settings export --data-root /root/.sandboxed-sh --output /tmp/orb-settings.json
orb-core-dev settings import /tmp/orb-settings.json --data-root /var/lib/sandboxed-sh-dev
orb-core-dev settings import /tmp/orb-settings.json --data-root /var/lib/sandboxed-sh-dev --yes
orb-core-dev settings refresh-dev                  # preview prod → dev
orb-core-dev settings refresh-dev --yes            # confirm prod → dev
orb-core settings promote-dev                     # preview dev → prod
orb-core settings promote-dev --yes               # operator confirms dev → prod
```

`--prod-root` and `--dev-root` override the two roots for direction commands.
They must name distinct existing instances. Export files and the target's
`settings-before-import.json` recovery document are private (`0600`). Imports
lock both SQLite stores and the settings file, reject stale previews, and roll
back ordinary SQL/file failures, including commit failures. SQLite WAL commits
across two databases and a filesystem rename are not crash-atomic; after a host
crash during import, compare with the recovery document and reapply the desired
document. Unrelated settings, credentials and usage remain local.

Monitor thresholds live in a dedicated non-secret `core_monitor_settings` row
in `managed_compute.db`. `orb-monitor` reads that row without opening the
credentials-bearing settings file; older databases use its existing defaults.
Installing the updated monitor script is an operator action.
Exporting an older instance without the settings table uses those defaults and
does not create a table. A confirmed import creates only that configuration
table inside its transaction; it never runs Core's startup migrations.

Export records the Library checkout's current commit when no revision was
explicitly configured. An imported revision is a full lowercase Git SHA and
pins the next `POST /api/library/sync` (or `force-sync`) to that exact commit.
Configuration import does not move Library files. Synchronizing a pinned
revision refuses a dirty checkout, including untracked drafts; unpin it by
setting `global.library_revision` to `null` in a confirmed settings import.
