# Hermes conversations in Orb

Choose **Cloud agent → Hermes → Paloma**. **Profile default** uses the model configured on the Hermes gateway; the model menu lists only gateway-advertised aliases. Each Orb mission starts a separate Hermes conversation. This does not bind the project's canonical control conversation, create a controller, or enable autonomous scheduling.

## Server configuration

Core must explicitly set `HERMES_CLOUD_OWNER` to the authenticated Core user ID allowed to use the Paloma gateway. Other accounts see Hermes as unavailable. This uses the existing runtime-scoped Hermes loopback URL and server-side `API_SERVER_KEY`; Orb never receives the gateway credential. Paloma means the existing configured gateway profile, not a new profile directory. Mission credentials and skills remain server-managed.

Hermes must advertise both `features.runs_idempotency.durable=true` and `features.run_events_replay=true` at `/v1/capabilities`. An older or unavailable gateway produces an actionable unavailable-profile message. Deploy the compatible Hermes event-replay support before enabling the Core owner setting.

## Lifecycle

Core stores the conversation root, run IDs, per-turn idempotency keys, resolved continuation sessions, and event cursor in its existing cloud execution record. A lost acceptance is retried with exactly the same key and request body. Recovery refuses to resubmit beyond the conservative 20-hour window. Investigate an expired ambiguous submission in Hermes before taking any manual recovery action.

Hermes journals run events in its existing durable run store. `GET /v1/runs/{id}/events?format=json&after=<cursor>` returns ordered, principal-scoped pages with `events`, `cursor`, and `has_more`. SSE disconnect and transport expiry do not end durable recording. Restarted Core reconciles the recorded run; restarted Hermes reports interrupted runs rather than silently restarting tools.

Follow-ups address the same root conversation, and Hermes resolves compression continuations. Approvals carry the exact active run and approval request identity; Orb only offers choices supplied by Hermes. **Stop** interrupts the current Hermes turn. It does not cancel delegated Core missions. Child attempts are listed from their Hermes-injected `origin_session_id`, including resolved continuation sessions. Hermes's existing completion delivery ledger handles their results.

This initial integration accepts text. Attachments, importing arbitrary existing conversations, profile administration, and recurring controller setup are separate features.

## Local validation

- Core: `CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 cargo test -j1 --lib api::cloud_agents`.
- Orb: use pinned pnpm 10.17.1 in `orb/`; run TypeScript, Vitest, and `pnpm exec playwright test tests/cloud-agents.browser.spec.ts`.
- Hermes: `scripts/run_tests.sh tests/gateway/test_api_run_replay.py tests/gateway/test_api_server_runs.py`.
- Build a separate debug Orb bundle and identifier; keep the operator's running app untouched.
- Live acceptance uses a dedicated test conversation: remember a marker, close/reopen, recall it in a follow-up, interrupt a bounded turn, then continue. Delegate only a harmless explicitly requested child and verify its result and provenance. Perform restart/failure injection against fixtures or an isolated stack, never against production jobs.
