# Orb & sandboxed.sh Documentation

> **Upcoming rename to Orb:** `sandboxed.sh` (formerly Open Agent) is unifying under the name **Orb**, and the web app and documentation will be served at **[`orb.thomas.md`](https://orb.thomas.md)**. Existing binary names (`sandboxed-sh`, `sandboxed-node`, `sandboxed-mcp`, `palomactl`), systemd units, and API paths remain compatible during the transition.

![Orb on macOS](../screenshots/orb-desktop.webp)

<p align="center">
  <img src="../screenshots/orb-ios-projects.webp" width="240" alt="Orb on iOS Projects" />
  &nbsp;&nbsp;&nbsp;
  <img src="../screenshots/orb-ios.webp" width="240" alt="Orb on iOS Conversation" />
</p>

---

## 1. Quick Start & Installation

- **[Getting Started](getting-started.md)** — Connect Orb (macOS & iOS) to your backend, configure subscriptions/harnesses, and launch your first agent.
- **[Docker Installation](install-docker.md)** — Run the backend, web admin console, and pre-installed CLIs in a single container.
- **[Native Ubuntu 24.04 Installation](install-native.md)** — Bare-metal systemd setup with `systemd-nspawn` containers, `missions.slice` cgroups, and Tailscale.

## 2. Orb Client & Mission Capabilities

- **[Orb Desktop (`../orb/README.md`)](../orb/README.md)** — Tauri v2 + SolidJS macOS app, keyboard shortcuts, local voice input, and browser tests.
- **[Orb iOS (`../ios_dashboard/README.md`)](../ios_dashboard/README.md)** — Native SwiftUI iOS client (`SandboxedDashboard/Orb`), synced project colors, transcripts, and settings.
- **[Shared Project Context & Offline Local Starts](ORB_PROJECT_CONTEXT.md)** — Bi-directionally synced `@context` directories and offline local mission creation (`~/.orb/local-origins/`).
- **[Project Skills](PROJECT_SKILLS.md)** — Synchronized per-project `skills/<name>/SKILL.md` discovery across Codex, Claude Code, Antigravity, OpenCode, and Grok.
- **[Native Plan Mode (`/plan`)](ORB_PLAN_MODE.md)** — Interactive planning with native question/approval cards and checklist progress tracking.
- **[Side Agents (`/btw`)](ORB_BTW.md)** — Independent side-panel agent sessions (`⌘⇧J`) with incremental transcript excerpts and `@conversation` archives.
- **[Cross-Machine Mission Transfer](ORB_MISSION_TRANSFER.md)** — Move idle missions (`Change machine…`) across your computer, Core, and fleet nodes with SHA-256 verified checkpoints and Git bundles.
- **[Scheduled Continuations](SCHEDULED_CONTINUATIONS.md)** — Durable mission wake-ups (`schedule_wakeup` / `schedule_job_wakeup`).
- **[File Attachments & Uploads](ORB_FILE_UPLOADS.md)** — Native multi-file picker and 20 MiB destination-routed uploads (`POST /api/uploads`).
- **[Codex Cyber Access](ORB_CYBER_ACCESS.md)** — Per-mission `Standard`, `Daybreak`, and `Automatic` access program selection.
- **[Settings & Shared SSH Address Book](ORB_SETTINGS.md)** — Synchronized non-secret SSH host directory (`GET/POST /api/settings/ssh-hosts`).
- **[Model Routing Settings](ORB_ROUTING_SETTINGS.md)** — Ordered fallback chains, provider health, and fallback event inspection.

## 3. Execution, Harnesses & Fleet

- **[Execution Architecture (`../AGENTS.md`)](../AGENTS.md)** — Per-workspace CLI execution, `missions.slice` cgroup isolation, and disk-backed container `/tmp`.
- **[Harness System](HARNESS_SYSTEM.md)** — How Claude Code, Codex, Antigravity (`agy`), OpenCode, and Grok execute inside host and container workspaces.
- **[Google Antigravity (`agy`)](ANTIGRAVITY.md)** — Workspace-native `agy` CLI execution, model discovery (`agy models`), and managed node profiles.
- **[Managed Fleet Harnesses](FLEET_HARNESSES.md)** — Atomic `/opt/sandboxed-tools/<harness>/<version>/` installations and daily fleet reconciliation.
- **[Agent Software Inventory & Updates](AGENT_SOFTWARE.md)** — Inspecting and updating host CLI versions from Orb's **Machines** page (`GET /api/software`).
- **[Remote Runner Nodes & Spark Offload](REMOTE_NODES.md)** — `sandboxed-node` lease architecture, `remote_launch` capability matrix, and Lean 4 build offload.
- **[Workspaces](WORKSPACES.md)** — Host vs `systemd-nspawn` container workspaces, Library templates, and stdio MCP allowlists.
- **[Storage Lifecycle Policy](STORAGE_LIFECYCLE.md)** — Dry-run-by-default storage inventory and retention rules.

## 4. Subscriptions, Providers & Identity

- **[OAuth Credential Ownership & CLIProxyAPI](CREDENTIAL_OWNERSHIP.md)** — Preventing OAuth refresh-token races with `SANDBOXED_OAUTH_OWNER=cli-proxy` and UI login flows.
- **[Inference Protocols & Reasoning Continuity](INFERENCE_PROTOCOLS.md)** — Wire format routing (Anthropic Messages, OpenAI Responses, Chat Completions) to preserve reasoning blocks.
- **[Model Catalog](MODEL_CATALOG.md)** — Live provider model discovery and compiled-in fallback snapshots.
- **[AI Provider Configuration](PROVIDERS.md)** — Configuring API keys and custom provider endpoints.
- **[Shared Development Identity](DEVELOPMENT_IDENTITY.md)** — Operator-managed Bitwarden Secrets Manager profile for GitHub, OpenPGP commit signing, and fleet SSH.

## 5. Control Plane, Cloud Agents & Hermes

- **[Agent Control Plane Constitution](AGENT_CONTROL_PLANE.md)** & **[Roadmap](AGENT_NATIVE_ROADMAP.md)** — The canonical abstraction tower: portfolio → project → track → attempt → action → receipt → evidence.
- **[Hermes Orchestration](HERMES_ORCHESTRATION.md)** & **[Autonomous Controllers](CONTROLLERS.md)** — How Hermes crons drive projects through control conversations and MCP.
- **[Hermes Cloud Conversations in Orb](ORB_HERMES.md)** — Launching durable Hermes conversations directly from **Orb → Cloud agent**.
- **[Cloud Agents (`cloud-agents/STATUS.md`)](cloud-agents/STATUS.md)** & **[ChatGPT UI Harness](CHATGPT_UI_HARNESS.md)** — Cursor Cloud, Grok Bot, and pooled ChatGPT web sessions (with versioned policy in [`policy/CHATGPT_UI_POOL_POLICY.md`](policy/CHATGPT_UI_POOL_POLICY.md)).
- **[Unified MCP (`sandboxed-mcp`)](MCP_UNIFICATION.md)** — Scoped `mcp1.` sessions, executor/coordinator/operator profiles, and idempotent action receipts.
- **[Writer Dispatch Admission](writer-dispatch-admission.md)**, **[Codex Native Continuity](codex-native-continuity.md)**, **[Codex Goal Lifecycle](codex-goal-lifecycle.md)**, & **[Validation Campaigns](validation-campaigns.md)**.
- **[`palomactl`](PALOMACTL.md)** — CLI for project-state reconciliation.

## 6. API & Streaming Reference

- **[Mission API](MISSION_API.md)** — Mission CRUD, snapshots, cursor-paginated events, SSE streaming, and automations.
- **[Streaming Contract](STREAMING.md)** — Canonical SSE, WebSocket, and historical event replay contract.
- **[Workspace API](WORKSPACE_API.md)** — Workspace CRUD, container builds, command execution, and diagnostics.
- **[Backend API](BACKEND_API.md)** — Harness discovery and configuration endpoints.
- **[Capability Matrix](CAPABILITY_MATRIX.md)** — CI-enforced feature parity across API, Web, and iOS (`capabilities/matrix.v1.json`).

---

Historical incident postmortems, one-off validation receipts, and retired migration guides live in [`docs/archive/`](archive/).
