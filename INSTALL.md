# Installing Orb & sandboxed.sh

> **Upcoming rename to Orb:** `sandboxed.sh` (formerly Open Agent) is being renamed to **Orb** and will be hosted at **[`orb.thomas.md`](https://orb.thomas.md)**. During the transition, server binaries (`sandboxed-sh`, `sandboxed-node`, `sandboxed-mcp`), Docker images, and environment variables retain their `sandboxed-sh` names.

There are two ways to install the backend server, which powers **Orb Desktop** (`orb/`), **Orb iOS** (`ios_dashboard/`), and the **Web Admin Console** (`dashboard/`):

## 1. Docker (Recommended for Quick Start)

One command starts the Rust backend, web console, Caddy proxy, and primary coding-agent CLIs on Linux, macOS, or Windows.

→ **[Docker installation guide](docs/install-docker.md)**

```bash
git clone https://github.com/Th0rgal/sandboxed.sh.git
cd sandboxed.sh
cp .env.example .env
# Edit .env to set DASHBOARD_PASSWORD and JWT_SECRET
docker compose up -d
```

## 2. Native Bare-Metal (Production Linux)

For production servers running **Ubuntu 24.04 LTS** with native `systemd-nspawn` container isolation, `missions.slice` cgroup resource caps, CLIProxyAPI Plus OAuth management, and remote `sandboxed-node` fleet runners.

→ **[Native installation guide](docs/install-native.md)**

## Comparison

| | Docker | Native (Ubuntu 24.04 LTS) |
|---|---|---|
| **Best for** | Getting started, macOS/Windows host, quick evaluation | Production servers, heavy builds, multi-node fleets |
| **Setup time** | ~5 minutes | ~20–30 minutes |
| **Container workspaces** | Yes (with `privileged: true` and `cgroup: host`) | Yes (native `systemd-nspawn` + disk-backed `/tmp`) |
| **Resource isolation** | Container-level | Per-mission systemd scopes under `missions.slice` |
| **Desktop automation** | Yes (headless Wayland/Sway pre-installed) | Yes (headless Wayland/Sway or Xvfb fallback) |
| **Updates** | `git pull && docker compose up -d --build` | `cargo build` + guarded `/api/system/deploy` |
