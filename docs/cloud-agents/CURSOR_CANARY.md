# Cursor live canary

The ignored `live_cursor_restart_and_followup` Rust test uses the production
Cursor adapter, reconciliation code and SQLite store with an isolated database.
It creates one agent without a repository and sends at most two small prompts.
No API key is written into the database or passed to the cloud prompt.

Provide `CURSOR_CLOUD_API_KEY` via the secrets manager. Choose a new dedicated
`CURSOR_CLOUD_CANARY_DIR` for the initial run, and keep that exact directory on
all retries. Never change directories after a timeout or ambiguous submission.

Run the ignored test with `CURSOR_CLOUD_CANARY_STEP=submit`, then run it again
in a new process with `CURSOR_CLOUD_CANARY_STEP=observe`. The first process exits
after persisting the initial provider receipt; the second reopens the same SQLite
database, observes the run and sends one follow-up. The follow-up asks for a marker
from the previous prompt, without including the marker again. Repeated follow-up
keys must yield one turn; both turns must use the same agent with distinct run IDs.

```
cargo test --lib live_cursor_restart_and_followup -- --ignored --nocapture
```

This is a live adapter/restart test, not a full Orb/Core HTTP acceptance test.
Orb closing/reopening, MCP authorization, authenticated download and cancellation
still need end-to-end validation before general activation.

## Recorded run — 2026-09-26

Result: PASS for the live adapter/store canary. General activation is unchanged.

- Base: Orb `00ceacf7`, local branch `feat/orb-cloud-agents` (uncommitted work).
- Account: `cursor-default`, secret reference `CURSOR_CLOUD_API_KEY` in Bitwarden.
- Mission: `7aa2be55-63bf-40fa-9c68-720a816a6c3c`.
- Agent: `bc-7aa2be55-63bf-40fa-9c68-720a816a6c3c`.
- First run: `run-4ef5b863-ecc7-4ada-8afc-48d9b1f320a5`, FINISHED.
- Follow-up: `run-e5950cd4-3a3a-4bb9-8c85-9e31a6e29503`, FINISHED.
- Initial create exceeded the transport timeout. Its persisted state remained
  submission_uncertain. A separate process recovered the predetermined agent
  identity and run through the production worker, without another POST /agents.
- Both response checks passed, including recalling the first prompt's marker
  from a follow-up that did not repeat it. Duplicate follow-up keys yielded one
  local turn. The store contains one mission with two distinct run receipts.
- The canary exposed a numeric `/me.userId`; the adapter now accepts positive
  integer or nonempty string user IDs. A regression test rejects absent/null IDs
  and service-account responses without a user identity.

No repository, file editing or PR was requested. The test agent is retained for
inspection. Cancellation, artifact download, and real Orb/Core HTTP/MCP paths
were not exercised by this canary.
