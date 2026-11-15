# Reproducible env migration handoff

This document records the checked-in env-migration handoff (classification
landed in `b1166b8e`, PR #1784). The smallest
interpretation of the plan's “env-migration” item is: make `orb-env migrate`
accept one-sided keys only through a complete, reviewed names-only policy,
preserve instance authority, and provide operator-run activation commands.
Live application and verification remain operator work; no live success is
claimed by the repository tests.

Historical groups: **65 prod-only, 10 dev-only, 11 differing** (86 total).
All 10 named dev-only and 11 differing keys retain instance ownership. The full
65-name prod-only list is absent from the public report: it lists families only,
including unnamed Supabase and Spark arbiter settings. Consequently exact
86-key coverage and successful live migration cannot be certified. Unknown
names deliberately fail; obtain their names only and extend the classification.
The historical list also calls WORKING_DIR dev-only: the existing validator
requires it on both instances. Confirm the real prod working directory through
the unit configuration; do not guess it or copy dev's directory.

Checked-in `scripts/ops/env-migration.json` uses the existing ownership JSON
schema: **144 known names**, **53 shared from prod**, **91 local** (78
instance-owned plus 13 prod-only authority names). Secrets, endpoints, paths,
model/dev switches and tenant identity stay local, including absence. Hermes
and console authority stay forbidden on dev. Shared tuning takes prod; a
missing prod assignment fails. Unknown keys, malformed/duplicate JSON and
incomplete policy fail before writes. Diagnostics never include env values.

Migration is a joint split of two inputs, not a per-instance deployment. It
writes both exact backups first, then ownership, base, prod and dev files.
Default and explicit --dry-run write nothing. --apply stages files only; it
never changes legacy inputs, installs drop-ins or restarts either instance.

## Operator commands (agent-core, root, from this checkout)

Install code and policy together:

```bash
install -d -m 755 /etc/orb /usr/local/libexec
install -m 755 scripts/ops/orb-env /usr/local/libexec/orb-env
install -m 644 scripts/ops/env-migration.json /usr/local/libexec/env-migration.json
```

Stage once for dev validation. The output directory must not already exist:

```bash
/usr/local/libexec/orb-env migrate --prod /etc/open_agent/open_agent.env --dev /etc/open_agent/open_agent_dev.env --output /etc/orb/environments --dry-run
/usr/local/libexec/orb-env migrate --prod /etc/open_agent/open_agent.env --dev /etc/open_agent/open_agent_dev.env --output /etc/orb/environments --apply
/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/dev.env
```

Follow core-environments.md to back up units and install the **dev** drop-in;
then the operator deploys the integrated tested SHA with
`orb-deploy --detach <tested-sha> --dev-only` and verifies dev health/build/auth
mode before prod activation.

## Deploy/apply on prod (operator only, after dev verification)

Reuse the staged migration; do not rerun `--apply` against an existing directory.
Run the following in a root shell on agent-core, replacing `<tested-sha>` with
the full merged SHA. `set -e` stops activation if validation or either backup
comparison fails. These commands retain the original unit/drop-ins and create
the new drop-in exclusively; an existing drop-in must be inspected, not replaced.

```bash
set -e
/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/prod.env
cmp -s /etc/open_agent/open_agent.env /etc/orb/environments/backups/prod.env
cmp -s /etc/open_agent/open_agent_dev.env /etc/orb/environments/backups/dev.env
backup=$(mktemp -d /etc/orb/prod-units-before-env.XXXXXXXX)
chmod 700 "$backup"
systemctl cat sandboxed-sh-prod.service > "$backup/effective-unit.txt"
chmod 600 "$backup/effective-unit.txt"
cp -a /etc/systemd/system/sandboxed-sh-prod.service* "$backup/"
install -d -m 755 /etc/systemd/system/sandboxed-sh-prod.service.d
(
  set -C
  cat > /etc/systemd/system/sandboxed-sh-prod.service.d/40-environments.conf <<'EOF'
[Service]
EnvironmentFile=
EnvironmentFile=/etc/orb/environments/core.env
EnvironmentFile=/etc/orb/environments/prod.env
ExecStartPre=/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/prod.env
EOF
)
systemctl daemon-reload
orb-deploy --detach <tested-sha>
```

The existing deploy tool checks dev before prod. Wait for its completion receipt
and verify the health endpoint's build equals the tested SHA; acceptance also
requires the expected auth mode and clean startup logs. If migration was not
applied to dev first, stop here and complete the dev procedure above.
To roll back the unit change, remove only the new `40-environments.conf` and run
`systemctl daemon-reload`; the legacy files remain unchanged. Use the governed
deploy tool for any subsequent restart. There is no separate
`orb-env migrate --prod-only` or `--dev-only` command.

## Verification

```text
$ python3 -m unittest discover -s scripts -p test_orb_env.py -v
Ran 23 tests

OK
$ git diff --check
(no output; exit 0)
```

Coverage includes strict classification parsing/completeness, all 21 named
historical keys, default/explicit dry-run output, unknown-key refusal on dry-run
and apply, prod source choice, local secret placement, backup/apply ordering,
exact backups, private modes, input preservation and cleanup after write failure.
The installed-tool regression copies the executable and policy beside each
other, runs dry-run/apply and both startup checks as subprocesses, verifies
effective environments and exact backups, and refuses a second apply without
changing the staged files. All inputs are synthetic.
