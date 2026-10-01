---
name: development-identity
description: Use the shared Paloma development identity for GitHub, signed commits and fleet SSH access in sandboxed.sh and Orb missions.
---

# Development identity

GitHub account: `Th0rgal`. Managed commits use `Thomas Marchand (agent)
<agent@thomas.md>`, OpenPGP fingerprint
`30EAE29B6766A7A70A4DEB4BF480B9A3F84BE648`.

The runtime provisions development credentials before work. Use ordinary `gh`,
`git`, and SSH commands. If an existing turn predates setup, source the private
`activate.sh` in the managed profile; `SANDBOXED_DEVELOPMENT_IDENTITY` identifies
that directory. Fleet execution users default to
`~/.config/sandboxed-sh/development-identity`; a mission's HOME may differ from
the execution user's home. On remote nodes the profile is under
`/var/lib/sandboxed-node/.config/sandboxed-sh/development-identity`.

For infrastructure SSH use `ssh -F "$SANDBOXED_DEVELOPMENT_IDENTITY/current/ssh/config" <host>`.
Git automatically selects the separate GitHub key. SSH access is for operations;
launch project work through sandboxed.sh missions/jobs, not ad-hoc remote agents.

Never display tokens, private keys, credential files, environment dumps, or
Bitwarden output. Do not disable signing to work around a setup failure. Report
the failed check and retain the worktree. Bitwarden is the authoritative source;
do not copy a cached gh token back into Hermes or the Library.

Verify identity with `gh api user --jq .login` and a signed commit's fingerprint
with `git log -1 --format='%G? %GF %an <%ae>'`. A push or merge requires the user's
task authorization and repository checks; credential access is not a waiver.

Workers receive only development credentials. Other service credentials require
an explicit addition to the managed profile; no full Bitwarden token is present.
