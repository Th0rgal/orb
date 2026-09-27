<p align="center">
  <img src="dashboard/public/favicon.svg" width="80" alt="sandboxed.sh" />
</p>

<h1 align="center">sandboxed.sh + Orb</h1>

<p align="center">
  <strong>Your agents, machines and subscriptions. One place to work.</strong><br/>
  Use Orb on desktop or iOS to organize projects, launch agents and continue their conversations.
</p>

<p align="center">
  <a href="#get-started">Get started</a> ·
  <a href="orb/README.md">Desktop</a> ·
  <a href="ios_dashboard/README.md">iOS</a> ·
  <a href="https://sandboxed.sh">Website</a> ·
  <a href="https://relens.ai/community">Discord</a>
</p>

![Orb on macOS, following a Verity coding mission](screenshots/orb-desktop.webp)

## Choose where your agent works

| Mode | Where it runs | How you use it |
| --- | --- | --- |
| **Your computer** | A local coding agent on your desktop | Choose **New Agent → This computer**, then a harness and model. Work with your local files and tools. |
| **Your private cloud** | Your own servers and remote machines | Add machines to sandboxed.sh, then select one in Orb. Run agents in the configured host or isolated container workspace. |
| **Cloud agents** | A provider-managed assistant | Choose **Cloud agent**, then ChatGPT, Grok Bot or Cursor Cloud. Continue the provider conversation from Orb. |

Use Claude Code, Codex and other supported harnesses for local and remote work.
Cloud agents have their own connections: **ChatGPT** uses a signed-in browser
profile and your available subscription modes; **Grok Bot** uses its connected
account; **Cursor Cloud** uses its official API, with a repository, Git reference
and available model. ChatGPT and Grok Bot connectors are experimental; available
models and actions depend on the connected account and provider.

![Creating an agent in Orb on macOS](screenshots/orb-setup.webp)

## Pick up the conversation anywhere

Projects contain folders, conversations and shared context. Open a mission to
follow its progress, send a follow-up, change supported model settings, or review
its output. Markdown, code, tables, LaTeX, images and downloadable artifacts stay
readable inside the conversation.

Orb for **iOS** connects to the same sandboxed.sh server: browse projects, follow
agents, start remote or cloud work, and view or edit shared Markdown files.
Agents run on the selected computer or service, not on your phone. Local desktop
execution still depends on the computer that owns the run.

<p align="center">
  <img src="screenshots/orb-ios.webp" width="280" alt="Orb on iOS showing code and downloadable files in a test conversation" /><br/>
  <sub>iOS Simulator · ChatGPT rendering test with fixture data.</sub>
</p>

## Bring your subscriptions

Connect supported subscription accounts through **CLIProxyAPI Plus**, then
configure that endpoint as an inference provider in sandboxed.sh. The proxy
handles account routing and rotation among configured, eligible accounts;
Orb lets you choose the harness and model. Provider quotas still apply.

- [CLIProxyAPI Plus — maintained CCS fork](https://github.com/kaitranntt/CLIProxyAPIPlus)
- [CLIProxyAPI — upstream](https://github.com/router-for-me/CLIProxyAPI)
- [Credential ownership and proxy configuration](docs/CREDENTIAL_OWNERSHIP.md)

This routes **model inference** for coding agents. Managed cloud agents use
separate service adapters; connecting a proxy account does not sign in to the
ChatGPT browser or create a Cursor Cloud API account.

## Get started

1. **Run sandboxed.sh.** Follow the [Docker guide](docs/install-docker.md) or
   [native Linux guide](docs/install-native.md). It keeps the project record,
   mission history and remote execution services.
2. **Open Orb.** Build the [desktop client](orb/README.md) or the
   [iOS app](ios_dashboard/README.md), then enter your server URL and sign in.
3. **Connect your execution environment.** Set up local harnesses, register
   [remote machines](docs/REMOTE_NODES.md), or connect a cloud-agent account.
   Configure inference providers for the models you want to use.
4. **Create a project and launch an agent.** Choose its execution mode, write
   your task, and keep its conversation and results together.

## Under the hood

**Orb is the client; sandboxed.sh is the execution and persistence layer.**
Desktop is built with Tauri and SolidJS; iOS uses SwiftUI. The Rust backend owns
projects, missions, event history and remote-node coordination. Cloud adapters
observe provider work independently of the client window.

The same control plane is available over MCP for coordinators such as
[Hermes](https://github.com/Th0rgal/hermes-agent). Automation uses the same project
and mission records as Orb.

[Execution architecture](agents.md) ·
[Workspaces](docs/WORKSPACES.md) ·
[MCP and Hermes](docs/HERMES_ORCHESTRATION.md) ·
[Development and troubleshooting](DEBUGGING.md)

---

Formerly Open Agent.
