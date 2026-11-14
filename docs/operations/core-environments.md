# Core environment ownership and migration

Core's systemd units read `/etc/orb/environments/core.env`, followed by
`prod.env` or `dev.env` in the same directory. Both run
`/usr/local/libexec/orb-env check` before starting. The overlay cannot repeat a
base key, even with the same value, and can contain only instance identity,
storage paths and authentication, plus names explicitly declared instance-owned
in the adjacent `ownership.json`. The instance is named by `ORB_INSTANCE`;
this is independent of `DEV_MODE`, which controls authentication and must not
be enabled just because this is the dev instance.

`scripts/ops/orb-env` is a standalone Python 3 program. It never evaluates an
env file as shell code or prints its values. Install it as
`/usr/local/libexec/orb-env` (mode 755). Its assignments follow the single-line
subset of systemd's `EnvironmentFile` syntax: unquoted, single quoted or double
quoted values, without shell expansion. Duplicate keys, multiline values and
continuations are rejected. Comments start with `#` or `;` on their own line.

The operator migrates the two legacy files with:

```bash
install -d -m 755 /etc/orb /usr/local/libexec
install -m 755 scripts/ops/orb-env /usr/local/libexec/orb-env
install -m 644 scripts/ops/env-migration.json /usr/local/libexec/env-migration.json
/usr/local/libexec/orb-env migrate \
  --prod /etc/open_agent/open_agent.env \
  --dev /etc/open_agent/open_agent_dev.env \
  --output /etc/orb/environments
# After validation, repeat with --apply.
/usr/local/libexec/orb-env migrate \
  --prod /etc/open_agent/open_agent.env \
  --dev /etc/open_agent/open_agent_dev.env \
  --output /etc/orb/environments --apply
```

The checked-in [env-migration.json](../../scripts/ops/env-migration.json) is a
complete names-only policy over the script's known keys. Install it beside the
executable (mode 644), or pass its path with `--classification`. Migration loads
it by default, validates completeness with the existing strict ownership parser,
and scopes decisions to keys present in the inputs. `--dry-run` is explicit but
optional; it is mutually exclusive with `--apply`.

Shared operational settings select prod. Secrets, endpoints, paths, dev feature
switches, models and tenant identity retain their original per-instance values
and absence. Hermes and console authority remain forbidden on dev. In particular,
`SCOPE_REAPER_ENABLED` stays local because the observed setting is dev-only.
Missing selected source assignments fail rather than silently selecting dev.
Unknown live keys fail with names only before creating any output. The optional
`--ownership` override retains the previous strict parser and cannot change a
key's allowed layer or admit unknown names.

Historical inventory: **65 prod-only, 10 dev-only, 11 differing**. The report in
`docs/plans/orb-consolidation-2026-11.md` names all dev-only/differing keys but
summarizes the prod-only group by families. All ten named dev-only keys and all
eleven named differing keys are instance-owned in the checked-in policy. Prod-only
shared tuning selects prod; secrets/paths stay local; Hermes/console stay prod-only.
The exact 65-name historical group cannot be reconstructed from that report;
this change does not invent names for Supabase or Spark arbiter. Any live name
outside the explicit policy requires a names-only repository update and is
refused. Do not interpret the historical count as a verified live inventory.

Migration preserves existing paths, adds only `ORB_INSTANCE`, and requires
distinct ports, working directories, JWT secrets and dashboard passwords when
present. It does not mint credentials or touch users, missions, transcripts or
provider keys. Instance-owned differences stay local; shared differences use the checked-in
source choice. Migration does not certify identical setup.

The output directory must not already exist. It is mode 700, with mode 600
files and exact copies of **both** inputs in `backups/prod.env` and
`backups/dev.env`. The original files and running services are untouched. A
write failure removes the incomplete output; reruns never overwrite a
configuration or backups. Keep the backups private: they contain credentials.

For existing units on agent-core, the operator adds this drop-in separately
to `sandboxed-sh-prod.service.d/40-environments.conf` and
`sandboxed-sh-dev.service.d/40-environments.conf`, substituting `prod` or `dev`:

```ini
[Service]
EnvironmentFile=
EnvironmentFile=/etc/orb/environments/core.env
EnvironmentFile=/etc/orb/environments/dev.env
ExecStartPre=/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/dev.env
```

Back up the existing units and drop-ins before installing this change. Run
both checks explicitly, then `systemctl daemon-reload`. Restart dev only with
`orb-deploy --detach <tested-sha> --dev-only`; check its health and logs. The
operator chooses when to restart prod. Loading new unit files does not change
the environment of a running service. To roll back before a future restart,
remove only the new `40-environments.conf` drop-ins and daemon-reload; the
original env files remain in place.

The env ownership check is also useful after edits:

```bash
/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env \
  --overlay /etc/orb/environments/dev.env
```

Settings document transfer, provider sealing, dev grants and automatic dev
deployment are separate steps of
[the approved plan](../plans/dev-prod-environments.md). An env migration does
not synchronize instance settings or data.
