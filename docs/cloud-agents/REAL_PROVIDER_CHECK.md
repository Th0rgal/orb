# Orb cloud agents — real-provider check (2026-09-26)

ChatGPT and Cursor Cloud are installed and enabled on the production Core.
Orb is running in Tauri dev from `sandboxed_sh-orb-client`; Cloud agent opens a
full page in the New agent style. Creation, response retrieval and reload were
verified through that frontend against production.

| Provider | Real result | Remaining limitation |
| --- | --- | --- |
| ChatGPT Pro | Same conversation across Core restarts and follow-up; production UI reply verified; generated text file downloaded through Core with its contents verified | Attachments, Agent and Deep Research are excluded; profile reconnection remains manual |
| Cursor Cloud | Creation, ambiguous-submit reconciliation, follow-up, result recovery, MCP and production UI checks passed | Detailed event rendering/model variants and track/writer admission remain outside this implementation |
| Grok Bot | Installed app contracts inspected; entry visible but disabled | macOS Keychain authorization for the existing session has not completed; adapter and authenticated compatibility canary remain outstanding |

See [INSTALLATION.md](INSTALLATION.md) for exact mission IDs, service paths,
backup locations and verification details. No existing mission was migrated and
no account discovery automatically launched work. Three-provider acceptance has
not been achieved.
