# Shared development identity

Core resolves a selected Bitwarden Secrets Manager profile and distributes it
over pinned SSH to the fleet execution users. Orb's Mac pulls the same profile.
Nodes receive no Bitwarden bootstrap token. This is an operator-managed shared
development identity, not a per-mission authorization broker.

## Identity and ownership

| Purpose | Source |
| --- | --- |
| GitHub API and HTTPS Git | Bitwarden `GITHUB_TOKEN`, validated as `Th0rgal` |
| GitHub SSH | `GITHUB_SSH_PRIVATE_KEY` / `GITHUB_SSH_PUBLIC_KEY`, existing GitHub `agent` key |
| Infrastructure SSH | Existing `PALOMA_SSH_PRIVATE_KEY` / `PALOMA_SSH_PUBLIC_KEY` |
| Signed commits | `GIT_SIGNING_PRIVATE_KEY`, existing agent OpenPGP identity |

Commits use `Thomas Marchand (agent) <agent@thomas.md>` and fingerprint
`30EAE29B6766A7A70A4DEB4BF480B9A3F84BE648`. GitHub SSH fingerprint:
`SHA256:sjqEzn4AF7dPpBvNPK5bfJ0sAsIk7qKxrp4PbF5Ekd0`. Infrastructure fingerprint:
`SHA256:DudUQO4SLLQgsBYmLgkd8aUNSWg7jeLqG/TUiO7/E10`.

The existing GitHub token has broad account permissions. This rollout reuses it
as authorized; it does not claim repository-scoped access. Jobs sharing an
execution user can access that user's shared development profile. A later broker
can narrow this without changing Bitwarden's role as the credential source.

No password-manager vault, wallet key, model-provider OAuth login, or unrelated
service secret belongs in the distributed bundle. Do not copy `~/.ssh`,
`~/.gnupg`, Hermes's `.env`, or an entire Bitwarden response into a mission.
Validate key content rather than trusting a `.pub` suffix.

## Provisioning and launch

Install `scripts/development_identity.py` as
`/usr/local/lib/sandboxed-sh/development_identity.py` on Core and nodes. It uses
Python's standard library plus `git`, `gh`, `gpg`, and OpenSSH. Install those tools
before enrollment. Core's private configuration is
`/etc/sandboxed-sh/development-identity/config.json`:

```json
{
  "bitwarden_command": ["/var/lib/hermes-assistant/bin/bws", "secret", "list", "297f3106-758f-43d5-8a4b-b460007558c8"],
  "known_hosts": "/etc/sandboxed-sh/development-identity/known_hosts",
  "skill": "/root/.sandboxed-sh/library/skill/development-identity/SKILL.md",
  "library_revision": "<published-library-commit>",
  "ssh_hosts": [{"alias":"old-agent", "hostname":"95.216.112.253", "user":"root"}],
  "python": "/usr/bin/python3",
  "script": "/usr/local/lib/sandboxed-sh/development_identity.py",
  "ssh_identity": "/var/lib/hermes-assistant/.ssh/paloma",
  "api_url": "http://127.0.0.1:3000",
  "api_token_file": "/run/paloma-development-identity/api-token",
  "targets": [{"name":"old-agent", "ssh":"root@95.216.112.253", "user":"sandboxed-node", "root":"/var/lib/sandboxed-node/.config/sandboxed-sh/development-identity"}]
}
```

Keep the config and pinned host-key inventory private. The config contains
references, never credential values. `sync --config <file>` checks the source;
adding `--apply` provisions targets. `check` reports installation, and `verify`
performs API/SSH/HTTPS and temporary signed-commit checks as the execution user.
The node-side `apply` accepts a private JSON stream on stdin. Core filters the
vault to the six enumerated development entries before transmitting anything.

Each target stores owner-only, immutable generations below its managed root.
Validation precedes atomic replacement of `current`. Failed preparation leaves
the old generation active. Retain prior generations while old processes may
reference them; revoke upstream credentials when immediate revocation is needed.
Replacing files cannot remove a token already inherited by a running process.

`hooks --companion /usr/local/bin/sandboxed-mcp` installs a small launch adapter.
It retains the native companion as `.identity-native`, applies the profile only
to `launch`, and forwards MCP serving unchanged. Installing a newer native
companion requires reapplying this hook. Never copy a dev companion to a prod
path. No backend or node restart is needed for the adapter.

Linux login-shell integration covers the `sandboxed-node` and `spark-admin` accounts even though
node jobs clear their environment and replace HOME. Other execution identities
use the companion or explicitly invoke `run -- <command>`. Existing turns can
source `<managed-root>/activate.sh` before a credential-using command. The
profile overrides stale GH_TOKEN/GITHUB_TOKEN and commit-identity environment
values, while preserving unrelated Git command policies.

`run` also installs discovery links for the common operational skill and a
secret-free `.paloma/development-identity.json` receipt. Existing project or
user-owned skills are preserved. General project skill selection remains owned
by sandboxed.sh's Library/project-skills preparation, not this credential tool.

Core also discovers ready container workspaces through its authenticated API.
It stages the filtered bundle using no-follow directory handles and owner-only
permissions, then provisions and
validates it through `/api/workspaces/:id/exec` inside the container. Failed
attempts retain pending data for the next timer run or companion launch. New
containers must have Python, Git, gh, GnuPG and OpenSSH installed; enrollment
converges on the next reconciliation. Host paths never enter container GPG
configuration. Wrapped companions retain their native sibling inside each
container; the reconciler refreshes both after a companion deployment.
The Core API owner session remains on Core and is refreshed
from the Bitwarden dashboard password only when needed.

Enable the Core scheduler after a successful manual canary:

```sh
sudo install -m 644 deploy/systemd/sandboxed-development-identity.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sandboxed-development-identity.timer
sudo systemctl start sandboxed-development-identity.service
sudo systemctl show sandboxed-development-identity.service -p Result -p ExecMainStatus
```

The connected dashboard GitHub account and workspace token fields may still
contain older credentials. Managed launches override these at execution time;
they do not disconnect other accounts or copy a cached token back to Bitwarden.
Already-running processes must source the activation hook or start a fresh turn.

## Orb on macOS

Install the helper under `~/.local/lib/sandboxed-sh`. Use `pull --config <file>`
with a private config containing `source_ssh`, `ssh_identity`, `remote_python`,
`remote_script`, and `remote_config`. These identify Core's export command;
only the selected development profile crosses the pipe. Never run `export`
directly into a tool transcript or log.

Schedule the pull with a five-minute LaunchAgent. `hooks --local` adds guarded
activation only for shells inside `~/.orb`; other personal shell/Git behavior
is preserved. Apply the companion adapter to each installed Orb build's
`sandboxed-mcp` sibling for local launches in arbitrary directories. Older Orb
builds without the unified companion use the guarded shell hook in their private
workspaces, or an explicit `run` wrapper. No personal signing key is replaced. New Orb builds use the managed `launch`
helper automatically, including checkouts outside `~/.orb`; this native change
takes effect when Orb is relaunched after active local missions finish.
When Nix Git is installed, the managed profile prioritizes it over Apple's
Xcode-dependent Git shim.

## Rotation, recovery, and removal

The systemd units in `deploy/systemd/` run reconciliation every five minutes.
Review `status.json` freshness on each target and service failure status on Core.
Disconnected machines retain their last validated profile and converge after
reconnection. On an intentional identity-key rotation update the expected public
fingerprints, validate the new identity, then publish; never silently accept a
different key. GitHub token rotation requires no key-fingerprint change.

Disable the former `github-token-sync.py` reverse-sync job: a stored gh token
must not overwrite the authoritative source. Preserve its previous files for
rollback. Do not reset unrelated cron jobs or Library changes.

To remove, stop the reconciliation timers, restore the native companion, remove
only the marked shell blocks and managed skill links, and delete the managed
profile after its processes finish. Restore retained configuration backups if
needed. Never delete the personal SSH/GPG directories or Bitwarden secrets.

Run `python3 -m unittest discover -s scripts -p test_development_identity.py`.
Live acceptance additionally requires signed commits and GitHub operations in
the actual node, container, and Orb execution environments; root-only success is
insufficient. The rollout's final acceptance mission is
`3e24a46c-5f71-402c-8633-5b8613b8a44b`: preserve its existing project-skills work,
resolve conflicts, sign, push, satisfy required checks, and merge. Verify GitHub
state independently of the agent's report.

## Current rollout

The configured fleet is Core, Ashur, Babylon, Nippur, old-agent, DGX Spark and
its separate `spark-admin` execution account, plus Thomas's Mac. Core has
separate roots for its node user, backend, root operations and Hermes. Ben's
independent installation is outside this fleet.

The shared skill is published in `Th0rgal/sandboxed-library` and pinned by
`library_revision`. To publish a skill update, commit/push the Library, update
that reference, and reconcile. General Library skills continue to use the
existing mission preparation system. Nodes do not need a Bitwarden MCP or a
full mirror of coordinator-only Hermes skills.

The Mac scheduler is `~/Library/LaunchAgents/md.thomas.sandboxed-development-identity.plist`.
It runs the installed helper's `pull` command every 300 seconds and at load,
with the private configuration in `<managed-root>/pull.json`. The optional
`known_hosts` field selects the Mac's pinned inventory (default `~/.ssh/known_hosts`). Inspect it with
`launchctl print gui/$(id -u)/md.thomas.sandboxed-development-identity`; success
reports are in `<managed-root>/sync.log`. A failure is in `sync-error.log` and
leaves the previous generation active.

Container hook reconciliation requires Core’s `/api/workspaces/:id/exec-rooted` endpoint. It forces target-root namespace attachment regardless of the legacy nsenter setting. Older Core versions return 404 and leave reconciliation pending; upgrade Core before enabling container reconciliation. A missing generated `skill/SKILL.md` also triggers profile repair.
