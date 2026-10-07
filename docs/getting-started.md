# Getting Started with Orb & sandboxed.sh

This guide walks you through connecting **Orb** (macOS and iOS) to your **sandboxed.sh** backend, configuring your local harnesses and subscription providers, and launching your first coding agent.

> **Upcoming rename to Orb:** `sandboxed.sh` (formerly Open Agent) is transitioning to the name **Orb**, hosted at **[`orb.thomas.md`](https://orb.thomas.md)**. Existing server binary names (`sandboxed-sh`, `sandboxed-node`, `sandboxed-mcp`) and API paths remain compatible.

![Orb on macOS](../screenshots/orb-desktop.webp)

## 1. Prerequisites

1. **A running `sandboxed-sh` backend**:
   - **Docker**: `http://localhost:3000` (see [install-docker.md](install-docker.md))
   - **Native Linux Server**: e.g. `https://orb.thomas.md` or `https://agent-backend.example.com` (see [install-native.md](install-native.md))
2. **Orb Client**:
   - **macOS Desktop**: Located in [`../orb/`](../orb/README.md) (`pnpm install && pnpm tauri dev`)
   - **iOS App**: Located in [`../ios_dashboard/`](../ios_dashboard/README.md) (SwiftUI, generated via XcodeGen)
   - **Web Admin Console**: Located in `../dashboard/` (bundled in the Docker image on port 3000)

## 2. Connect to Your Backend

### macOS Desktop (`orb/`)

1. Open **Settings** (`⌘,`) → **Client**.
2. Enter your backend URL and dashboard password (or username + password when `SANDBOXED_SH_USERS` multi-user auth is configured) and click **Connect**.
3. Under **Local agents**, click **Scan** to detect coding CLIs installed on your Mac (`claude`, `codex`, `agy`, `opencode`, `grok`).

### iOS (`ios_dashboard/`)

1. Open **Orb** on iOS and enter your **Server URL** and **Password** in the connection sheet.
2. Tap the top-right profile icon at any time to manage **Backend**, **Providers**, and **Machines** (including the shared SSH address book).

<p align="center">
  <img src="../screenshots/orb-ios-projects.webp" width="240" alt="Orb on iOS Projects" />
  &nbsp;&nbsp;&nbsp;
  <img src="../screenshots/orb-ios.webp" width="240" alt="Orb on iOS Conversation" />
</p>

## 3. Configure Subscriptions & Model Routing

1. **Providers (`⌘4`)**:
   - **Subscription OAuth via CLIProxyAPI Plus**: Connect Anthropic, OpenAI, xAI, Kimi, or Google Antigravity subscriptions directly from Orb (`GET/POST /api/ai/providers/cli-proxy-login`). See [CREDENTIAL_OWNERSHIP.md](CREDENTIAL_OWNERSHIP.md).
   - **API Keys**: Configure keys for OpenRouter, Anthropic, OpenAI, xAI, MiniMax, Z.AI, or Google.
2. **Model Routing (`Settings → Routing`)**:
   - Configure ordered fallback chains (such as `builtin/smart` and `builtin/fast`) and inspect per-account health and recent fallback events. See [ORB_ROUTING_SETTINGS.md](ORB_ROUTING_SETTINGS.md).

## 4. Launch Your First Mission

![Creating an agent in Orb on macOS](../screenshots/orb-setup.webp)

1. Press `⌘N` (**New Agent**) or `⌘2` (**Cloud agent**).
2. Choose a **Project** and an execution mode:
   - **This computer (`placement: "client"`)**: Runs a local CLI on your Mac in `~/.orb/local-runs/<mission-id>` while keeping the mission record and `@context` synced to the server.
   - **Core / Fleet machine**: Runs in a host directory or isolated `systemd-nspawn` container on your server or a registered `sandboxed-node` machine.
   - **Cloud agent**: Connects to **Hermes**, **ChatGPT**, **Grok Bot**, or **Cursor Cloud**.
3. Choose the **Harness** and **Model Override**:
   - **Claude Code (`claudecode`)**: Raw model ID (e.g., `claude-opus-5-5`, `claude-sonnet-4-20250514`)
   - **Codex (`codex`)**: Raw model ID (e.g., `gpt-5.6-terra`, `gpt-5.5`) plus optional **Cyber Access** (`Standard`, `Daybreak`, `Automatic`)
   - **Antigravity (`antigravity`)**: Exact model ID discovered by `agy models` in the target execution environment
   - **OpenCode (`opencode`)**: `provider/model` or router chain (`builtin/smart`, `xai/grok-4.5`)
   - **Grok (`grok`)**: Canonical CLI model ID (e.g., `grok-4.5`)
   - **Effort**: Set `model_effort` (`low`, `medium`, `high`, `xhigh`) separately from the model ID.
4. Optional composer prefixes and mentions:
   - `/plan <task>` — Native interactive planning mode (Claude Code and Codex).
   - `/goal <objective>` — Multi-turn autonomous goal execution.
   - `/btw <question>` (or `⌘⇧J`) — Open an independent side-agent conversation in the same workspace.
   - `@context/<path>` — Reference live synchronized project files.

---

## Dev Smoke Suites & Deferred Proxy Mode

### Harness & Proxy Smoke Gate

Before or after backend changes, validate model routing and harness streaming against your dev deployment:

```bash
export SANDBOXED_SH_DEV_URL="https://your-dev-backend.example.com"
export SANDBOXED_SH_TOKEN="<control-api-token>"
export SANDBOXED_SH_WORKSPACE_ID="<workspace-uuid>"
export SANDBOXED_PROXY_SECRET="<proxy-bearer-token>"

scripts/smoke_harnesses_dev.sh \
  --backend claudecode \
  --backend opencode \
  --backend codex \
  --model-override opencode=builtin/smart \
  --expect-model opencode=glm-5 \
  --non-streaming
```

### Deferred Queue Mode for Proxy Routing

When calling `/v1/chat/completions` (`stream: false`) with model-routing chains, pass `x-sandboxed-defer-on-rate-limit: true` to queue requests (`202 Accepted` with `request_id`) when all providers in a chain are temporarily rate-limited. Poll or cancel via `GET/DELETE /v1/deferred/<request_id>`.
