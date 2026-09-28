# Mission Finish Detection

The runner currently mixes three different concepts:

- backend stream finished: the CLI/process stopped producing events
- agent turn finished: the model ended one assistant turn
- mission finished: Sandboxed should move the mission to a terminal status

That ambiguity is why missions can be marked `Failed` even after useful work
landed, or marked `Completed` from a weak fallback such as buffered text after a
process exit.

## Current Signals

- Codex has native turn and goal events. These should be high-confidence when
  present.
- Claude Code has structured stream messages, but transport failures can happen
  after useful output.
- OpenCode, Gemini, and Grok vary by backend. Some paths depend on process exit,
  idle state, or text/sentinel parsing.
- Goal mode is strongest for Codex. Grok sentinel parsing is useful but should
  be treated as weaker evidence until it becomes structured.

## Better Model

Every backend should adapt its native result into a typed turn outcome:

```rust
enum TurnOutcome {
    Complete { signal, confidence, message },
    Failed { reason, source, message },
    Interrupted { reason, message },
}
```

`AgentResult` can remain as a compatibility wrapper, but the mission runner
should carry completion evidence alongside the assistant message:

- `terminal_reason`
- `completion_signal`
- `completion_confidence`
- `native_terminal_seen`
- `pending_tools`
- `transport_failure_stage`
- `provider_error_source`
- `failure_class`
- `classification_source`

## Confidence Rules

- High: native terminal result such as `turn_complete`, `completed`,
  `response.completed`, or explicit goal completion.
- Medium: session idle after meaningful output with no pending tools.
- Low: recovered buffered output after nonzero/process exit, text fallback, or a
  missing Grok goal sentinel.

Low-confidence completion evidence should be visible in event metadata, but it
must not drive high-impact transitions such as marking a mission `Completed`.

## Implementation Plan

1. Persist completion evidence on assistant events and replay it from SQLite.
2. Add a typed `TurnOutcome` adapter layer per backend.
3. Gate mission `Completed` transitions on medium/high confidence.
4. Replace broad text matching with structured JSON/error classification first,
   and mark remaining fallback matches as `classification_source =
   "text_fallback"`.
5. Harden Grok goal mode by persisting parsed sentinel state, missing-sentinel
   count, and the last goal decision.
6. Add replay fixture tests for useful-output-then-error, pending-tool failure,
   incomplete response then idle, recovered process exit, Grok complete/continue
   and missing sentinel, and Claude missing terminal result.
7. Once every backend emits typed outcomes, simplify
   `mission_status_for_terminal_reason` into a deterministic state transition.
