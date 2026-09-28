# Orb integration review — 2026-09-28

## Remote Claude identity

A remote initial Claude launch persisted a generated Core session UUID without
passing it to Claude. The native transcript therefore had a different UUID and
the next `--resume` failed with `No conversation found`.

Initial remote launches now bind the persisted identity with `--session-id`;
continuations use the same identity with `--resume`. The persistence is fenced by
the active run generation. A regression test checks both commands. Existing
mismatched sessions require transcript identity verification before repair; do
not silently start a new conversation and lose its context.

Mission `d2415091-a5e0-4e38-8582-62f6175ed355` was repaired after verifying its
native transcript and confirming its previous run had ended. The original question
then received a real Claude answer. A separate bounded two-turn production
canary, `77f1b0e9-3f39-40f2-a207-c0b71fa453aa`, recalled a marker supplied only in
the first turn, confirming continuation across remote jobs.

## Integration choices

Retained master's cursor pagination, virtual transcript, serialized replay and
native interaction/context subscriptions. Added the reviewed Orb improvements:
sidebar cache and activity indicators, provider usage, cloud conversations,
optimistic idempotent resend, fork selection, queue recovery, image navigation
and semantic ChatGPT rendering. Removed superseded paging helper implementations.
Resend reference-loading failures now restore an actionable error instead of
leaving the edited message stuck in a sending state.

Cloud receipt storage and routes are included alongside the client; connecting
a provider never launches work. Unknown quota values stay unknown. Controller
instructions document unsupported tracked/scheduled cloud admission.

## Validation

- Native Orb: 89 passed, 6 ignored (serialized to avoid existing shared-state tests).
- WebKit: fork selection, provider layout, queue recovery and sidebar responsiveness passed.
- ChatGPT extraction/browser fixtures: 93 passed; remote Codex driver: 5 passed.
- Live remote Claude: repaired conversation and fresh two-turn canary completed.

Provider fixtures are not proof of every live provider edge case. Production
continues using its existing validated account gates.

## Deployment compatibility

The running Core includes an independent unified-MCP migration not yet present
on master. Its deployment must preserve that migration. The isolated production
source overlay adds reviewed context-transfer routes, cloud usage and the event
pagination protocol to that running source baseline. Guarded deployment waits
for active harness turns; it must not force termination to install the UI fixes.
