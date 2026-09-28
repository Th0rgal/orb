# Portable conversation context fix — 26 September 2026

Large transfer histories are retained verbatim in a SHA-256 verified checkpoint file. The inline prompt references the archive instead of rejecting conversations over 128 KiB. Archive reads come from Core even when the source workspace belongs to Orb. Small contexts retain the inline behavior. Archive storage remains bounded at 64 MiB and 50,000 events.

Validation: nine backend transfer tests, seven Orb tests, and TypeScript checking passed. The Unicode archive test checks a multi-block round trip through the real staging/writing/verifying adapter.

Deployed through the guarded endpoint with force=false, based on the source matching production binary 5eb453da0a0579edc6aa8d8bf25eaca0a1a8c4205efbc6a3c3b80789ee9fdd92. Isolated build source: /opt/sandboxed-sh-transfer-context-20260926 on agent-core. Hermes was restarted and both services passed health checks. See backend-tests.txt for the resulting binary hash.

Live Orb verification: mission ebb2f1fe-8d03-4cc0-b966-68b3cb86077f, transfer 631f935b-1c7e-4d17-9ddb-1e18e995dc4d, This computer → old-agent. Archive: 186660 bytes. Full checkpoint: 115 files, 199756696 bytes, including recovery data for uncommitted external Verity checkouts. Activation/resumption evidence is recorded separately after completion.

## Final deployment and live result

A concurrent cloud-agent deployment replaced the first backend build during copying. The final build preserves those cloud-agent changes and adds this fix. Its source is `/opt/sandboxed-sh-transfer-context-final-20260926`; immutable artifacts are held under `release-artifacts/`. The cloud deployment source also carries the patch to avoid reintroducing the refusal. Final production SHA-256: `c70e43c0085d666ed288ec2aa843859c92fd93572175baf765dabbdd91112cdb`. Guarded deployment used `force=false`; both production and Hermes passed health checks afterward.

All nine backend tests passed on the combined source. A live, non-executing client-placement canary retrieved a 240633-byte archive exactly; its transfer was cancelled and the test mission archived.

Orb's real native UI prepared the transfer and copied most files through its native adapter. The native webview later stopped issuing requests; the remaining blocks were completed through the authenticated transfer API from the existing native checkpoint. All 114 source files were rehashed and compared against the native manifest before activation (there were no exclusions or Git directories in this source workspace). The destination verified all 115 files, including the generated conversation archive. The three temporarily paused Mac validation process groups were resumed after activation.

Activation and live execution evidence: `activation.json`, `resumed.json`, and `canary.json`. The same mission is active on old-agent at execution generation 10, with Codex / GPT-6 Astra and its unchanged goal. The archive SHA-256 on old-agent is `766a8eaa610f4fd8222f1d71d48dfc1c4b42546e4efcae6eb65d894263466dc6`. Temporary native UI probe imports were removed.

Orb checkpoint requests now have a two-minute deadline and at most two retries for transport failures, HTTP 408/429, or server errors. Permanent refusals are not retried. Seven Orb tests and TypeScript validation passed after this addition.
