# Dev and prod environments: one configuration, settings sync, agent access

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
