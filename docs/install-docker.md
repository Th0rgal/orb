# Installing the Core Backend for Orb with Docker

Docker is the easiest way to run the Core backend. One command gets you a complete environment with the Rust backend, Next.js dashboard, and the primary AI harness CLIs pre-installed.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose installed
- (Optional) A domain name for production deployment with TLS

## Quick Start

```bash
git clone https://github.com/Th0rgal/orb.git
cd orb
cp .env.example .env
# Edit .env — at minimum, set DASHBOARD_PASSWORD and JWT_SECRET
docker compose up -d
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

## Configuration

### Essential environment variables

Copy `.env.example` to `.env` and configure the values below. The full file contains additional optional settings.
Docker Compose loads this optional `.env` file into the `sandboxed-sh` container.
After changing it, run `docker compose up -d` to recreate the container with
the new values.

#### Authentication

| Variable | Default | Description |
|---|---|---|
| `DEV_MODE` | `false` | Authentication is enforced by default. Local-only `DEV_MODE=true` is refused unless `HOST` is loopback |
| `DASHBOARD_PASSWORD` | _(required)_ | Strong password for dashboard login (placeholder values are rejected) |
| `JWT_SECRET` | _(required)_ | Long random secret used to sign JWT tokens (`openssl rand -hex 32`) |
| `JWT_TTL_DAYS` | `30` | How long JWT tokens remain valid |
| `SANDBOXED_SH_USERS` | _(unset)_ | Optional JSON array for multi-user auth (overrides `DASHBOARD_PASSWORD`) |

#### Library

| Variable | Default | Description |
|---|---|---|
| `LIBRARY_REMOTE` | `https://github.com/Th0rgal/sandboxed-library-template.git` | Git URL for your agent library. By default, clones the official template. Set this to your own fork or custom library (e.g. `git@github.com:your-org/agent-library.git`). Can also be changed via the dashboard Settings page. |
| `LIBRARY_PATH` | `/root/.sandboxed-sh/library` | Local path where the library is cloned |

#### Server

| Variable | Default | Description |
|---|---|---|
| `HOST` | `127.0.0.1` | Bind address for the backend inside the container (Caddy proxies `:80` to `localhost:$PORT`) |
| `PORT` | `3000` | Backend listen port inside the container; Caddy forwards API requests to this port |
| `WORKING_DIR` | `/root` | Root directory for workspaces |
| `MAX_ITERATIONS` | `50` | Max tool-call iterations per mission |
| `MAX_PARALLEL_MISSIONS` | `1` | Number of missions that can run concurrently |

`PORT` does not change the address you open in your browser: Compose publishes
host port 3000 (`127.0.0.1:3000:80`) to Caddy's port 80. To use a different host port, edit the
`ports` mapping in `docker-compose.yml` (for example, `"127.0.0.1:8080:80"`) and open
`http://localhost:8080`.

### Enabling container workspaces

By default, workspaces run in host/fallback mode — processes execute directly inside the Docker container. To enable full **systemd-nspawn isolation** (each workspace gets its own lightweight container), edit `docker-compose.yml` and uncomment the privileged lines:

```yaml
services:
  sandboxed-sh:
    # ...
    privileged: true
    cgroup: host
```

Then restart:

```bash
docker compose down && docker compose up -d
```

This works on **both Linux and macOS**. On macOS, Docker Desktop runs a Linux VM under the hood, so systemd-nspawn works inside it just fine.

### SSH keys for private git repos

The compose file mounts your host SSH keys read-only:

```yaml
volumes:
  - ~/.ssh:/root/.ssh:ro
```

On startup, the entrypoint automatically adds GitHub and GitLab host keys to `known_hosts`. If the mount is read-only (which it is by default), a writable copy is used instead so SSH operations work without modifying your host files.

If your library or workspaces use private git repos, ensure your SSH keys are at `~/.ssh` on the host.

### Persistent data

Two Docker volumes keep data across container restarts:

| Volume | Mount point | Contents |
|---|---|---|
| `sandboxed-data` | `/root/.sandboxed-sh` | SQLite database, library, container rootfs, settings |
| `claude-auth` | `/root/.claude` | Claude Code OAuth credentials |

To back up your data, use `docker volume inspect` to find the volume paths, or bind-mount them to host directories instead.

## What's included in the Docker image

The multi-stage build produces a single image with everything pre-installed:

- **Rust backend** — `sandboxed-sh`, `desktop-mcp`, `workspace-mcp`, `orchestrator-mcp`, `assistant-mcp` binaries
- **Next.js dashboard** — standalone build served on port 3001 internally
- **Caddy** — reverse proxy that unifies backend + dashboard on port 80
- **Claude Code CLI** — installed via npm
- **OpenCode CLI** — installed from opencode.ai
- **Grok CLI** — installed via npm when available
- **Bun** and **Node.js 20**
- **systemd-container + debootstrap** — for container workspace isolation
- **Desktop automation** — Sway (Wayland), grim, wtype, wlrctl, wf-recorder, Chromium, ImageMagick, Tesseract OCR
- **Utilities** — git, curl, jq, SSH client, gnupg

## Production deployment

### With a domain and TLS

The Docker image serves HTTP on port 80. For production with TLS, use an external reverse proxy:

1. **Keep the port bound to localhost** — `docker-compose.yml` binds loopback by default:
   ```yaml
   ports:
     - "127.0.0.1:3000:80"
   ```

2. **Set up a reverse proxy** on the host (Caddy, Nginx, etc.) with TLS pointing to `localhost:3000`.

3. **Harden the environment** in `.env`:
   ```bash
   DEV_MODE=false
   DASHBOARD_PASSWORD=<strong-password>
   JWT_SECRET=<long-random-string>
   ```

### Dashboard options

The Docker image includes the Next.js dashboard, but you can also:

- **Deploy the dashboard separately on Vercel** — set `NEXT_PUBLIC_API_URL` to your server's URL
- **Use the iOS app** — point it at your server URL

## Updating

```bash
cd sandboxed.sh
git pull
docker compose build
docker compose up -d
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Container workspaces not working | Uncomment `privileged: true` and `cgroup: host` in `docker-compose.yml` |
| Permission denied on SSH keys | Ensure `~/.ssh` on the host is readable by your user |
| Port conflict on 3000 | Change the port mapping (e.g. `"127.0.0.1:8080:80"`) in `docker-compose.yml` |
| Build takes too long | Rust compilation is the bottleneck (~5–10 min first time). Subsequent builds use Docker layer caching. |
| Backend not starting | Check logs with `docker compose logs -f sandboxed-sh` |

If an older Windows checkout reports `exec /entrypoint.sh: no such file or directory`,
the entrypoint may still have CRLF line endings. After updating the repository,
save any local changes to `docker/entrypoint.sh`, then run
`git restore --source=HEAD --worktree -- docker/entrypoint.sh` to check it out
with LF endings and rebuild with `docker compose build`. Fresh checkouts use LF
for shell scripts automatically.

## Comparison with native installation

Docker wraps the entire stack into a single container — backend, dashboard, reverse proxy, and all AI CLIs. Native installation gives you more control and slightly better performance.

For most users, **Docker is the right choice**. Consider native installation when you need maximum performance on a dedicated production server.

→ [Native installation guide](install-native.md)
