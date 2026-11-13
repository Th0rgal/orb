# Dev and prod environments: one configuration, settings sync, agent access

## Handoff 2026-11-13

The operator is applying live steps on agent-core; the successor orchestrator
owns remaining acceptance. Implementation through **6b34935eb510c375bb416ccd77cc99dae640d911**
is pushed to master. This mission made no live changes. Its last independent dev
health read reported healthy, authenticated `multi_user`, build `de3fd0fa1`.
That observation does not establish migration, settings, sealing, grants, timer
or spending acceptance. Reconcile operator receipts before repeating a step.
The commands below run **only in the operator session on agent-core**, as root.
No mission should run them through SSH. Production restarts/promotions remain
the operator's deliberate action; the deploy commands here are dev-only.

### Ordered operator commands and verification

**0. Pin the tested implementation and private working directory.** Do not touch
the build checkout while `orb-deploy.service` or another build is active.

```bash
set -euo pipefail
umask 077
orb_sha=6b34935eb510c375bb416ccd77cc99dae640d911
orb_tree=/var/tmp/orbcore-lean-build
test "$(systemctl is-active orb-deploy.service || true)" != active
pgrep -lx 'lean|lake|turbo-lean|xcodebuild|java' || true
# If a real build is active, wait; do not terminate unrelated work.
git -C "$orb_tree" fetch origin master
orb_code=$(mktemp -d /var/tmp/orb-dev-handoff.XXXXXX)
git -C "$orb_tree" archive "$orb_sha" | tar -x -C "$orb_code"
test -f "$orb_code/scripts/ops/orb-env"
```

**1. Env migration, backup, startup checks.** Skip migration if its output already
exists and the operator has verified it; never delete backups to force a rerun.
The reviewed per-key policy is checked in. Unknown keys or unresolved shared
differences must stop migration. Choosing a source changes the other instance's
next-start configuration; there is no automatic safe choice for these decisions.

```bash
install -d -m 0755 /etc/orb /usr/local/libexec
install -m 0755 "$orb_code/scripts/ops/orb-env" /usr/local/libexec/orb-env
/usr/local/libexec/orb-env inventory \
  --prod /etc/open_agent/open_agent.env \
  --dev /etc/open_agent/open_agent_dev.env > "$orb_code/env-inventory.json"
if test ! -e /etc/orb/env-ownership.json; then
  python3 - "$orb_code/env-inventory.json" <<'PY'
import json, sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text())
assert not report.get('unknown_keys'), 'unclassified key names: update reviewed repository policy'
Path('/etc/orb/env-ownership.json').write_text(json.dumps(report['ownership'], indent=2) + '\n')
PY
fi
# Names/source choices only: replace every shared_from "review" with the
# operator's chosen "prod" or "dev". Do not paste env values into this file.
${EDITOR:-vi} /etc/orb/env-ownership.json
/usr/local/libexec/orb-env migrate \
  --prod /etc/open_agent/open_agent.env --dev /etc/open_agent/open_agent_dev.env \
  --ownership /etc/orb/env-ownership.json --output /etc/orb/environments
/usr/local/libexec/orb-env migrate \
  --prod /etc/open_agent/open_agent.env --dev /etc/open_agent/open_agent_dev.env \
  --ownership /etc/orb/env-ownership.json --output /etc/orb/environments --apply
# Verify exact backups of BOTH inputs without displaying any values.
cmp -s /etc/open_agent/open_agent.env /etc/orb/environments/backups/prod.env
cmp -s /etc/open_agent/open_agent_dev.env /etc/orb/environments/backups/dev.env
orb_units_backup=$(mktemp -d /etc/orb/units-before-base.XXXXXX)
for orb_instance in prod dev; do
  for orb_unit_path in "/etc/systemd/system/sandboxed-sh-$orb_instance.service" \
      "/etc/systemd/system/sandboxed-sh-$orb_instance.service.d"; do
    if test -e "$orb_unit_path"; then cp -a "$orb_unit_path" "$orb_units_backup/"; fi
  done
  install -d -m 0755 "/etc/systemd/system/sandboxed-sh-$orb_instance.service.d"
  orb_dropin="/etc/systemd/system/sandboxed-sh-$orb_instance.service.d/40-environments.conf"
  test ! -e "$orb_dropin"
  cat > "$orb_dropin" <<EOF
[Service]
EnvironmentFile=
EnvironmentFile=/etc/orb/environments/core.env
EnvironmentFile=/etc/orb/environments/$orb_instance.env
ExecStartPre=/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/$orb_instance.env
EOF
  /usr/local/libexec/orb-env check --base /etc/orb/environments/core.env \
    --overlay "/etc/orb/environments/$orb_instance.env"
done
systemctl daemon-reload
systemctl show sandboxed-sh-dev sandboxed-sh-prod -p EnvironmentFiles
```

Both checks and backup comparisons must succeed. `daemon-reload` does not change
a running instance's environment. Prod's next restart remains operator-owned.
See [migration and rollback details](../operations/core-environments.md).

**2. Dev deploy and fixed dev-operator host command installation.** This installs
the only executable path accepted by Core's `deploy_dev`. No extra SSH or generic
execution grant is needed. Wait for the detached deployment to finish before
changing the build checkout or installing the automatic timer.

```bash
install -m 0755 "$orb_code/scripts/ops/orb-deploy" /usr/local/sbin/orb-deploy
install -m 0755 "$orb_code/scripts/ops/orb-monitor" /usr/local/sbin/orb-monitor
/usr/local/sbin/orb-deploy --detach "$orb_sha" --dev-only
# Completion verification: rerun after the detached unit completes.
systemctl show orb-deploy.service -p ActiveState -p Result -p ExecMainStatus
curl -fsS --max-time 5 http://127.0.0.1:3002/api/health |
  python3 -c 'import json,sys; h=json.load(sys.stdin); assert h.get("status")=="ok" and h.get("build")==sys.argv[1] and h.get("auth_mode")=="multi_user"; print("exact dev SHA healthy; multi_user")' "$orb_sha"
```

The health assertion is the gate for subsequent dev tests, not the detach
acknowledgement. The script itself builds and runs the Core self-test before
installing dev. Production is excluded by `--dev-only`.

**3. Settings round trip and confirmed refresh (design item 2).** Use the new dev
CLI against existing roots; exporting prod does not require restarting/upgrading
its running binary. The dev database may be directly under the service directory
or under its `.sandboxed-sh` child; reject ambiguity rather than guessing.

```bash
orb_prod_root=/root/.sandboxed-sh
orb_dev_root=$(python3 - <<'PY'
from pathlib import Path
candidates = [Path('/var/lib/sandboxed-sh-dev'), Path('/var/lib/sandboxed-sh-dev/.sandboxed-sh')]
found = [str(p) for p in candidates if (p / 'managed_compute.db').is_file() and (p / 'missions.db').is_file()]
assert len(found) == 1, 'resolve actual dev data root before transfer'
print(found[0])
PY
)
orb_cli() {
  local orb_instance="$1"; shift
  systemd-run --quiet --wait --pipe --collect \
    --property="EnvironmentFile=/etc/orb/environments/core.env /etc/orb/environments/$orb_instance.env" \
    /usr/local/bin/orb-core-dev "$@"
}
orb_cli prod settings export --data-root "$orb_prod_root" --output "$orb_code/prod-settings.json"
orb_cli dev settings import "$orb_code/prod-settings.json" --data-root "$orb_dev_root"
# Review the printed non-secret diff, then confirm this exact transfer.
orb_cli dev settings import "$orb_code/prod-settings.json" --data-root "$orb_dev_root" --yes
orb_cli dev settings export --data-root "$orb_dev_root" --output "$orb_code/dev-settings.json"
cmp -s "$orb_code/prod-settings.json" "$orb_code/dev-settings.json"
orb_cli dev settings refresh-dev --prod-root "$orb_prod_root" --dev-root "$orb_dev_root"
```

`cmp` must return zero; record a mismatch as unfinished. Missing target users or
providers cause refusal: do not copy accounts, databases, inline keys or vault
configuration to bypass it. Users, missions, transcripts and secrets never move.
After reviewing a later refresh diff, its apply command is the same
`settings refresh-dev --prod-root "$orb_prod_root" --dev-root "$orb_dev_root" --yes`.
Only if the operator separately chooses settings promotion, preview with
`orb_cli prod settings promote-dev --prod-root "$orb_prod_root" --dev-root "$orb_dev_root"`,
then repeat with `--yes` and re-export/compare prod. Promotion is not required
to test dev, and is not implicitly part of this handoff execution.

**4. Vault-only batch sealing on each instance (design item 3).** Each command
runs under that instance's environment and seals locally inside Core. Never
print, copy, request or supply provider key values or copy `managed-secrets`.

```bash
orb_cli dev seal-provider --all --data-root "$orb_dev_root" > "$orb_code/dev-seal-result.json"
orb_cli prod seal-provider --all --data-root "$orb_prod_root" > "$orb_code/prod-seal-result.json"
python3 - "$orb_code" "$orb_dev_root" "$orb_prod_root" <<'PY'
import json, os, stat, sys
from pathlib import Path
for instance, root in [('dev', sys.argv[2]), ('prod', sys.argv[3])]:
    names = json.loads((Path(sys.argv[1]) / (instance + '-seal-result.json')).read_text())['sealed']
    assert isinstance(names, list) and all(n in {'boat', 'leanci', 'colab'} for n in names)
    for name in names:
        p = Path(root) / 'managed-secrets' / (name + '.aead')
        m = p.lstat()
        assert stat.S_ISREG(m.st_mode) and not m.st_mode & 0o077 and m.st_uid == os.geteuid() and m.st_size > 12
    print(instance, 'sealed provider names:', ', '.join(names) or '(none configured)')
PY
```

Exit zero plus the expected configured provider names and private sealed files
are required; an empty inventory is not evidence that configured keys were
sealed. This verifies no provider value and does not enable providers.

**5. Dev pass approval, redemption, deploy and logs (design item 4).** Core and
the fixed deploy executable were installed in step 2. Use a mission local to
dev until the operator has intentionally upgraded the issuing prod Core too;
the old issuer cannot verify new grants. In that dev mission's own authenticated
MCP session, execute these exact tool requests in order:

```text
request_privileged_access({"scope":"dev_operator","target_host":"dev","ttl_minutes":30,"reason":"Approved dev/prod plan live acceptance"})
list_privileged_access({})
```

The operator approves the pending request with the normal hardware approval UI.
Read its **grant ID**, never its raw lease token. Then substitute that ID in:

```text
get_dev_access({"grant_id":"<approved-grant-id>"})
read_dev_logs({"grant_id":"<approved-grant-id>","lines":20})
deploy_dev({"grant_id":"<approved-grant-id>","sha":"6b34935eb510c375bb416ccd77cc99dae640d911"})
```

Keep the returned bearer in the requesting session's private credential storage;
never paste it into logs, a URL, shell arguments or the handoff. Verification:
`instance=dev`, `role=admin`, expiry within four hours; a bounded dev journal
result; and the exact-SHA health command from step 2 **after** deployment finishes.
Use the bearer against dev, revoke the grant through the normal approval UI,
and verify the same dev request now fails. Do not send this token to prod as a
test. Expiry, revoke/owner-disable and prohibited routes have local regressions;
live grant acceptance remains unverified. There is no stand-alone dev-operator
daemon or unit to install. See [the capability restrictions](../operations/dev-operator.md).

With that redeemed bearer already saved privately by its requesting session,
the concrete API verification is (do not substitute an ordinary admin bearer):

```bash
: "${orb_dev_pass_file:?Private dev-pass bearer file from get_dev_access required}"
python3 - "$orb_code/scripts" "$orb_dev_pass_file" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dev_user_isolation import Api, private_token
a, token = Api('http://127.0.0.1:3002'), private_token(sys.argv[2])
assert a.call('GET', '/api/admin/users', token)[0] == 200
assert a.call('GET', '/api/privilege', token)[0] == 403
print('dev admin access and privilege restriction verified')
PY
# After revoking this grant in the normal approval UI:
python3 - "$orb_code/scripts" "$orb_dev_pass_file" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dev_user_isolation import Api, private_token
assert Api('http://127.0.0.1:3002').call('GET', '/api/admin/users', private_token(sys.argv[2]))[0] == 401
print('dev pass revocation verified')
PY
```

**6. Automatic dev deployment (design item 5).** Enable only after the manual
dev deploy and health gate have passed and no deployment is still running.

```bash
install -m 0755 "$orb_code/scripts/ops/orb-dev-autodeploy" /usr/local/sbin/orb-dev-autodeploy
install -m 0644 "$orb_code/deploy/systemd/orb-dev-autodeploy.service" /etc/systemd/system/
install -m 0644 "$orb_code/deploy/systemd/orb-dev-autodeploy.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now orb-dev-autodeploy.timer
systemctl list-timers orb-dev-autodeploy.timer
systemctl start orb-dev-autodeploy.service
systemctl show orb-dev-autodeploy.service -p Result -p ExecMainStatus
# Once its deployment completes, compare the fetched full master SHA with dev.
orb_master_sha=$(git -C "$orb_tree" rev-parse refs/remotes/origin/master)
curl -fsS --max-time 5 http://127.0.0.1:3002/api/health |
  python3 -c 'import json,sys; h=json.load(sys.stdin); assert h.get("status")=="ok" and h.get("build")==sys.argv[1]; print("master reached dev")' "$orb_master_sha"
```

Repeat the last comparison after the **next** master merge without a manual
deploy; installation or a successful timer tick alone does not prove automation.
The timer may coalesce superseded heads. Do not promote prod from the timer.

**7. Dev label and spending ceiling (design item 6).** `ORB_INSTANCE=dev` from
step 1 activates the default 500-cent daily rental-commitment ceiling; no provider
key or extra budget write is needed. The operator may explicitly set
`ORB_DEV_DAILY_CAP_CENTS` in the shared base before a future dev deployment to
choose a lower ceiling (zero disables new commitments). It is not `DEV_MODE`.
With an existing private **dev** admin-bearer file, verify metadata without
printing credentials, provider inventory or other users' data:

```bash
: "${orb_dev_admin_bearer_file:?Existing private dev operator bearer file required}"
python3 - "$orb_code/scripts" "$orb_dev_admin_bearer_file" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dev_user_isolation import Api, private_token
status, b = Api('http://127.0.0.1:3002').call('GET', '/api/managed-machines/spend', private_token(sys.argv[2]))
assert status == 200 and b['instance'] == 'dev' and b['cost_basis'] == 'rental_commitments'
assert 0 <= b['instance_daily_cap_cents'] <= 500 and b['daily_cap_cents'] <= b['instance_daily_cap_cents']
print('dev rental-commitment ceiling verified:', b['instance_daily_cap_cents'])
PY
```

This verifies reported configuration, not actual provider billing/admission.
Still required: one deliberately capped dev-only rental, provider-visible
`orb-managed-dev-` name and `instance=dev` label, dev-only usage attribution,
then destroy it and confirm stopped billing/cleanup. Exercise denial at the
instance ceiling, including resumes/extensions, without raising the cap or
touching prod. Those live spending cases are **unfinished**, not certified by
the metadata command. [Spending semantics](../operations/dev-spending.md)
cover rental estimates, reservation-day accounting and existing leases.

### Isolation status and unfinished work

Local two-user HTTP-dispatch regressions cover REST/MCP missions, projects,
secret/grant/memory boundaries, machine/snapshot ownership, provider settings,
usage, role spoofing, shared/external sessions, retry receipts, account removal,
remote placement and shared-host scheduler denial. Client regressions cover
account-switch cache/native-sidebar clearing and dev-to-prod failover. These
are local synthetic tests, **not live dev acceptance**.

After exact-SHA health, the operator can run the expanded live probe using an
existing private dev admin-bearer file (a dev pass may create its zero-budget
member fixtures). It creates no harness or VM and prints statuses/booleans only:

```bash
python3 "$orb_code/scripts/dev_user_isolation.py" --url http://127.0.0.1:3002 \
  --sha "$orb_sha" --token-file "$orb_dev_admin_bearer_file"
```

All results and cleanup fields must pass. It covers guessed mission/project
reads and mutations, provider-mutation and owner-secret denials, usage, scoped
and external MCP roles, all shared-session roles, share revocation, owner fixture
integrity and account disabling. It deletes synthetic fixtures and disables
the member. No live probe result was received by this mission. After enabling
auto-deploy, choose the actual full healthy master SHA for `--sha` instead of
assuming the pinned earlier implementation is still deployed.

Remaining acceptance: actual admin-owned machine/provider/usage fixtures through
REST and MCP (not merely absent IDs), dev rental/cap lifecycle above, full real
desktop member login/direct links/settings/network checks, and admin-to-member
switching in the installed native shell. Inspect responses; hiding controls is
insufficient. Repeat after every leak fix/redeployment, add a regression for
each leak, and revoke/disable test identities afterwards. No real prod accounts
should be created on the strength of the local tests or partial REST results.

Before implementation push: actual CI-parity Core build/full self-test passed
(11 spec gates, 10 harness contracts, 101 host tests), 5 spec fixtures, locald
100/100, desktop build/bundle and 2,195 unit tests, two Chromium account-switch
browser tests, 34 Python tests, harness contracts/capability matrix/state inventory.
Full WebKit suite is unfinished: initially missing WebKit, subsequently missing
host `libgstreamer-plugins-bad1.0-0`/`libavif16`. Android local checks stopped for
missing SDK; iOS checks/TestFlight cannot run on this Linux host. Mobile version
bumps are iOS `2026111302`, Android code `118`, version `1.74.0`; verify tester
delivery separately. At final check, exact implementation CI `43431346691` and
Kernel ABI `43431346696` were pending; Android APK `43431346664` and iOS Build
`43431347061` were in progress. Do not treat pending/cancelled as green.

All six repository features are implemented; all corresponding live receipts
remain to be reconciled with the operator. No provider key values were retrieved
or passed to missions. This mission is stopping for consolidation and will not
schedule another wakeup; the successor owns these open gates. A previously
scheduled continuation `6d727419-9c5f-4f60-849e-9260bb031723` was due at
`2026-11-13T13:16:46Z`; mission closure should prevent further continuation.

---

Status: approved by Thomas on 2026-11-13. Owner: the "Orb Core: dev/prod environments" mission in Refinery.

## Why

On 2026-11-12/13 the two Core instances on `agent-core` caused repeated friction:

- `/etc/open_agent/open_agent.env` and `open_agent_dev.env` drifted (a stale `LIBRARY_REMOTE` in both; dev's password and JWT secret differ, so agents could not log in to dev).
- Agents had no sanctioned way into dev; the operator minted short-lived admin tokens by hand from the JWT secret.
- Provider setup was repeated by hand per instance: keys sealed twice, providers enabled twice, a guest-script path override for dev only.
- Settings (routing chains, provider switches and per-user preferences, fleet settings, budgets) differed between instances with nothing showing the difference.

## Current layout (2026-11-13)

| | Prod | Dev |
| --- | --- | --- |
| Unit | `sandboxed-sh-prod` | `sandboxed-sh-dev` |
| Binary | `/usr/local/bin/orb-core` | `/usr/local/bin/orb-core-dev` |
| Port / URL | `:3000`, `orbcore.thomas.md` | `:3002`, `agent-backend-dev.thomas.md` |
| Data | `/root/.sandboxed-sh` | `/var/lib/sandboxed-sh-dev` |
| Env | `/etc/open_agent/open_agent.env` | `/etc/open_agent/open_agent_dev.env` |

Shared: the host, the cloud provider accounts (real money), very likely the model proxy and its logins. Deploys: `orb-deploy [--detach] <sha|master> [--dev-only]` on agent-core (`scripts/ops/orb-deploy`) builds once, installs dev, health-checks, then prod with backup and rollback.

## Design

1. **One configuration, two thin overlays.** A shared base env (for example `/etc/orb/core.env`) holds everything common: model proxy, library remote, memory broker, CA paths, fleet node tokens. Each instance has a small overlay with only what must differ: instance name, port, data directory, public URL, its own JWT secret and dashboard password. Core refuses to start when an overlay redefines a key that the base owns (or a check script reports it). Migration keeps backups of both current files and changes nothing a running mission depends on.
2. **Settings as an exportable document.** `orb-core settings export` writes the non-secret settings to a versioned JSON (routing chains, provider enabled flags and per-user preferences, fleet settings and budgets, library revision, monitor thresholds); `settings import` applies one with a printed diff and a `--yes` confirmation. Two directions: refresh dev from prod (`prod → dev`) and promote dev to prod (`dev → prod`, diff shown, applied only on confirmation). Users, missions, transcripts and secrets never travel this way.
3. **Secrets stay in the vault.** One command per instance seals every configured provider key from the same Bitwarden entries (`seal-provider --all`); values are never copied, printed or put in a mission.
4. **A dev pass for agents.** A mission working on Orb requests a `dev_operator` grant (approved like other grants). It yields a dev-only admin token that expires within hours, the right to deploy a commit to dev (`orb-deploy --dev-only` through Core, not SSH), and read access to dev's logs. Prod deploys stay with the operator.
5. **Dev deploys itself.** Every merge to master is deployed to dev automatically through `orb-deploy --dev-only`, with its health check; prod is promoted on purpose from the same build.
6. **Dev spending is labelled and capped.** Machines rented by dev carry a dev label and a small daily cap, visible separately in usage.

## Then: multi-user isolation test (on dev)

Create a test user on dev; as that user, try to read or act on admin's missions, projects, secrets, machines, provider settings and usage, through REST, MCP and the clients. Fix every leak with a test, deploy to dev, repeat. Only then create real accounts on prod (with a daily spend cap). Note: model subscriptions and cloud accounts are server-wide, so a member spends the owner's subscriptions within the cap.

## Done when

Both instances run from the base plus overlays; a settings round trip (export prod, import to dev, export dev) is byte-identical; a mission can deploy to dev and call dev's API with a grant and no password; master merges reach dev without a human; the isolation test passes on dev.

## Implementation

- Item 1: the repository units share a base and enforce overlay ownership with
  `scripts/ops/orb-env`. The migration preserves both legacy env files as
  private backups and does not change running services. See
  [the operator migration procedure](../operations/core-environments.md).
  A reviewed names-only ownership manifest handles the operator's one-sided
  inventory without implicitly enabling prod-only authority on dev.
  Live application and dev verification are still required.
- Item 2: `orb-core settings export|import|refresh-dev|promote-dev` uses a
  strict non-secret document, a printed diff, explicit `--yes` confirmation and
  stale-preview detection. Existing target users are matched by username;
  target credentials and instance data stay local. Library revision and monitor
  thresholds are included. See [the transfer contract](../operations/settings-document.md).
  Temporary-store round trips and rollback tests pass; the live dev round trip
  still requires operator application and verification.
- Item 3: `seal-provider --all` discovers configured provider keys through
  Bitwarden metadata and seals them inside Core for the current instance.
  See [the operator procedure](../operations/provider-sealing.md). Live sealing
  remains an operator step; no vault values are delivered to a mission.

- Item 4: `dev_operator` reuses hardware-approved mission leases for an opaque
  dev-only admin bearer, fixed dev deployment and bounded dev journal tools.
  See [the dev pass contract](../operations/dev-operator.md). Cross-instance
  redemption requires the issuing Core to support verification; live acceptance
  remains pending operator installation.
- Item 5: an operator-installed systemd timer follows master and submits exact
  commits through `orb-deploy --dev-only`, which builds, self-tests and verifies
  the exact healthy SHA. See [dev auto-deployment](../operations/dev-autodeploy.md).
  The repository tests use fake systemd/network effects; live timer installation
  and observing a merge reach dev are still pending.
- Item 6: dev rentals carry the provider-visible dev name and usage attribution,
  with a default $5 daily commitment ceiling checked transactionally across all
  users, including resumes and extensions. Settings imports cannot override it.
  See [dev spending](../operations/dev-spending.md). Live rental and cap
  acceptance remains pending dev installation.
- Isolation: the two-user HTTP regression suite covers REST and MCP ownership,
  including caller-selected MCP roles and sessions minted for shared missions.
  See [the acceptance procedure](../operations/dev-isolation.md). These local
  regressions do not certify live dev or desktop acceptance; that work is pending.
