# Reproducible env migration handoff

Local branch: `fix/env-migrate-classification`. No push, credentials, live env
reads or service changes were performed. Inspected
`origin/ready/e-env-classification-report` (`58471dace`) and master sources.

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
then deploy the integrated tested SHA with `orb-deploy --detach <tested-sha>
--dev-only` and verify dev health/build/auth mode before prod activation.

For prod after dev verification, reuse the staged migration; do not rerun
--apply against an existing directory:

```bash
/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/prod.env
cmp -s /etc/open_agent/open_agent.env /etc/orb/environments/backups/prod.env
cmp -s /etc/open_agent/open_agent_dev.env /etc/orb/environments/backups/dev.env
```

Install the **prod** drop-in using core-environments.md, daemon-reload, then the
operator chooses production deployment with `orb-deploy --detach <tested-sha>`
(the existing deploy tool checks dev before prod). There is no separate
`orb-env migrate --prod-only` or `--dev-only` command. No live success is claimed.

## Verification

```text
$ python3 -m unittest discover -s scripts -p test_orb_env.py -v
Ran 22 tests in 0.048s

OK
$ git diff --check
(no output; exit 0)
```

Coverage includes strict classification parsing/completeness, all 21 named
historical keys, default/explicit dry-run output, unknown-key refusal on dry-run
and apply, prod source choice, local secret placement, backup/apply ordering,
exact backups, private modes, input preservation and cleanup after write failure.
Full verbose test output is delivered beside the bundle as env-migrate-tests.txt.
