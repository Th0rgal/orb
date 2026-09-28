# Orb cloud installation — 2026-09-26

Core was deployed through the guarded `/api/system/deploy` endpoint on
`agent-core`, without forcing past active missions. Production and
`hermes-assistant` passed service health checks after restart.

The Linux source checkout is `/opt/sandboxed-sh-cloud-20260926`, based on the
actually deployed `67b7df9f` plus cloud integration changes. The existing
production `opencode.rs` change was preserved. Debug builds were used.
Local corresponding checkout: `sandboxed_sh-cloud-deploy`.

Installed: `sandboxed-sh-prod`, `assistant-mcp`, `orchestrator-mcp`,
`palomactl.real`, and the ChatGPT browser driver. Hermes cloud tool guidance was
appended to the installed project-manager, mission and controller skills.
The existing dev service was not restarted or replaced.

Provider credentials remain in the service-only, mode-0600 file
`/etc/sandboxed-sh/cloud-agents-prod.env`; the systemd drop-in is
`/etc/systemd/system/sandboxed-sh-prod.service.d/90-cloud-agents.conf`.
Both validated providers are bound to authenticated owner `prod`.
Connecting/discovering an account does not create a mission.

Backups:

- `/var/backups/sandboxed-sh/pre-cloud-1790429952`
- The deploy endpoint's `*.pre-deploy-67b7df9fd34b` files beside installed binaries
  and `/opt/sandboxed-sh/scripts/chatgpt_ui_driver.py`.

The isolated validation service is `sandboxed-sh-cloud-check`, on localhost
3012 with its own working directory `/var/lib/sandboxed-sh-cloud-validation`.
It is stopped after validation; its records and files are retained. Its
validation missions must not be confused with production missions.

Orb runs in Tauri dev from `sandboxed_sh-orb-client`. The project/folder
`Cloud agent` command opens a full page using the New agent composer layout.
The live checkout contains unrelated local work, which was preserved.

## Evidence

- Cursor HTTP canary: `96f7649c-b742-4f4f-84b3-8c9c397744df`; same external
  agent across Core restart and two completed turns; duplicate creates/messages
  deduplicated.
- ChatGPT HTTP canary: `b34238e1-0acc-43e6-9b96-00eb406aa792`; same conversation
  `/c/6ab7c7c5-4cfc-83ed-a56a-0e63ca31d2ac` across restarts and follow-up.
  Both text turns returned the expected marker. No replacement chat was created.
  The file canary recovered `orb-cloud-check.txt` through the authenticated Core
  artifact endpoint, verifying all 15 bytes of `ORB_ARTIFACT_OK`.
- MCP canary: `e73928b5-d448-4b03-a122-5e045d8f6a0f`; discovery, create, exact
  replay and durable result retrieval succeeded using the real MCP binary.
- Production missions created through the Orb page against the real Core:
  ChatGPT `8eb8916d-4ec7-4333-ad98-623497d67201`, Cursor
  `1fe09a95-93d1-4d92-bc48-27e6cfa8c5de`. Both returned `ORB_UI_OK`; the Orb
  conversation view recovered their results after reload. ChatGPT's persisted
  mode was explicitly Pro even when the UI omitted an optional model field.
- Core: seven cloud tests passed (the separate live canary is ignored by normal
  test runs). Orb: five targeted unit tests and the production frontend build pass.
- All 34 browser-driver tests passed. Browser fixtures cover legacy/current/mixed message layouts, hydration,
  resumed follow-up identity, and download activation under the preview overlay.

Grok Bot remains unavailable. Installed app 0.58.0 contracts were inspected,
but no functioning adapter or compatibility canary has been established. No
administrative Grok method was invoked. Do not describe this as three-provider
acceptance.
