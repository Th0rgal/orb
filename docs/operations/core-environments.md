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

Shared settings must agree in both inputs unless the operator explicitly chooses
one source. A one-sided setting is also a conflict: migration cannot infer whether
enabling it on the other instance is safe. Generate the names-only inventory and
conservative ownership template without editing the legacy files:

```bash
umask 077
/usr/local/libexec/orb-env inventory \
  --prod /etc/open_agent/open_agent.env \
  --dev /etc/open_agent/open_agent_dev.env > /etc/orb/env-inventory.json
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path('/etc/orb/env-inventory.json').read_text())
Path('/etc/orb/env-ownership.json').write_text(json.dumps(report['ownership'], indent=2) + '\n')
PY
```

Review these two files locally. The inventory reports names and classifications
only, never values. The script has a checked-in per-key policy: `shared`,
`instance-owned` and `prod-only-allowed`. Instance-owned assignments always stay
in their own overlay, even if equal, and an absent key stays absent. Hermes and
console SSH authority cannot appear on dev. Instance-specific fleet tokens,
authentication, storage paths and security switches cannot be made shared by a
manifest. Unknown live names appear in `unknown_keys` and migration refuses them;
add a reviewed repository classification rather than bypassing the check.

For each differing or one-sided shared key, the ownership template places
`"review"` in `shared_from`. Replace that marker locally with `"prod"` or `"dev"`
to select an existing assignment for the common base. For example:

```json
{"schema_version": 1, "instance_keys": [], "shared_from": {"LIBRARY_REMOTE": "prod"}}
```

This illustrates the shape, not a policy for the live inventory. Selecting a
source deliberately changes the other instance's next-start configuration.
The manifest cannot reclassify a key: `instance_keys` accepts only names already
classified instance-owned/prod-only and is unnecessary in new manifests. Unknown
names, duplicate decisions, missing source assignments, `"review"` markers and
unresolved shared differences fail before any write.
Run both migration commands above with the additional argument
`--ownership /etc/orb/env-ownership.json`, first validating, then `--apply`.
The resulting private `ownership.json` is automatically loaded by the existing
startup check. Overlay/base overlap remains forbidden, including instance-owned
keys. A missing manifest still uses the checked-in ownership policy; malformed
manifests fail. Adding a shared key to an overlay cannot bypass the policy.

Migration preserves existing paths, adds only `ORB_INSTANCE`, and requires
distinct ports, working directories, JWT secrets and dashboard passwords when
present. It does not mint credentials or touch users, missions, transcripts or
provider keys. Instance-owned differences stay local; shared differences require a deliberate
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
