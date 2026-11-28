# Spec Card: Pi Harness (`Orb.Kernel` / `Orb.Spec` / `OrbCore.Harness`)

- **Repository & sync commit:** `Th0rgal/orb@81c7075` (branch `feat/pi-harness`, issue `#2258`)
- **Covered files:**
  - `lean/Orb/PiHarness.lean` (`PiRpcPhase`, `PiRpcSession`, `PiRpcEvent`, `PiRpcOutcome`, `piRpcStep`, `PiMcpPolicyInput`, `piMcpConfigGate`, `piSessionRelPathSafe`, `PiExtractedEventTag`, `PiNormalizedKind`, `piNormalizeTag`)
  - `lean/Orb/PiHarnessSpec.lean` (`piRpcStickyFence`, `PiRpcContract`, `piMcpPolicyMetaGate`, `piMcpScopedAuthority`, two-sided regression theorems & mutants)
  - `lean/OrbNode/OrbNode/PiRpc.lean` (`sandboxed-node pi-rpc` subprocess driver)
  - `lean/OrbCore/OrbCore/Harness.lean` (`stepPiJsonLine` + contract tests)
  - `pi/orb-extension/index.ts` (minimal MCP & policy bridge)
- **Intent & violation harm (1 sentence):** Ensure Pi RPC sessions never emit post-abort/post-exit deltas, never corrupt active model state during tool calls or failed `set_model` switches, never leak secrets into `argv` or allow writes in `readonly`/plan mode or path traversal on session JSONL files, and never leak `thinking` blocks into user-facing prose.

## Requirement Mapping

| Req | Domain requirement | Formal declaration / theorem | Location |
| --- | --- | --- | --- |
| `R1` | Mutually exclusive `set_model`: immediate in `idle`, deterministically queued in `running`, never mutating mid-tool-call | `pi_rpc_set_model_idle_immediate`, `pi_rpc_set_model_running_queues_without_mutating_active`, `pi_rpc_turn_end_enters_switching_model`, `pi_rpc_turn_end_blocked_during_tool_call` | `lean/Orb/PiHarnessSpec.lean` |
| `R2` | Irreversible `StickyFence` on `aborted` / `closed` (no output, no turn reuse) | `piRpcStickyFence`, `pi_rpc_fenced_forbids_output`, `pi_rpc_contract_forbids_post_abort_output` | `lean/Orb/PiHarnessSpec.lean` |
| `R3` | Correlated RPC `id` rollback on `set_model` failure (`success: false`) | `pi_rpc_response_failure_rolls_back_switching`, `pi_rpc_response_failure_rolls_back_idle`, `pi_rpc_response_wrong_id_noop`, `pi_rpc_contract_forbids_rollback_drop` | `lean/Orb/PiHarnessSpec.lean` |
| `R4` | Dual-MCP / secret hygiene (`0` secrets in `argv`, `0700` agent dir, `0600` config, `readonly` blocks mutations) | `piMcpPolicyMetaGate`, `piMcpScopedAuthority`, `pi_mcp_spec_forbids_argv_secret`, `pi_mcp_spec_forbids_readonly_mutation` | `lean/Orb/PiHarnessSpec.lean` |
| `R5` | Mission session `.jsonl` path confinement (zero `..`, zero leading `/`, zero NUL/backslash) | `piSessionRelPathSafe`, `pi_session_rel_path_safe_no_parent_escape`, `pi_session_rel_path_accepts_mission_jsonl`, `pi_session_rel_path_rejects_traversal` | `lean/Orb/PiHarness.lean`, `lean/Orb/PiHarnessSpec.lean` |
| `R6` | Strict `Thinking` vs. `TextDelta` separation & fail-closed RPC/process errors | `pi_thinking_never_leaks_to_text_delta`, `pi_errors_always_turn_error`, `pi_normalize_tag_forbids_thinking_leak`, `OrbCore.Harness.stepPiJsonLine` | `lean/Orb/PiHarnessSpec.lean`, `lean/OrbCore/OrbCore/Harness.lean` |

## Reachable Positive Trace

1. Initial state: `s0 := { phase := .idle, activeModel := "orb/builtin/smart" }` with valid relative path `"mission-123/session.jsonl"` (`pi_session_rel_path_accepts_mission_jsonl`) and `piMcpPolicyMetaGate.posWitness` (`secretsInArgv = false, agentDirMode0700 = true, configFileMode0600 = true, sessionPathConfined = true, sandboxedMcpHttpOnly = true, readOnlyMode = true, toolIsMutating = false`).
2. `startTurn 1` → `phase = .running 1 "orb/builtin/smart"`.
3. `toolStart "call_1"` → `inToolCall = true`, emits `.emitToolStart "call_1"`.
4. `setModel 42 "orb/anthropic/claude-opus-5-5"` during active tool call → `activeModel` stays `"orb/builtin/smart"`, `queuedModel = some "orb/anthropic/claude-opus-5-5"`, emits `.switchQueued`.
5. `toolEnd "call_1"` → `inToolCall = false`, emits `.emitToolEnd "call_1"`.
6. `turnEnd` → `phase = .switchingModel "orb/anthropic/claude-opus-5-5"`, `previousModel = "orb/builtin/smart"`.
7. `rpcResponse 42 true ""` → `phase = .idle`, `activeModel = "orb/anthropic/claude-opus-5-5"`, `pendingReqId = none`, emits `.switchApplied`.
   (Conversely, `rpcResponse 42 false "model_not_found"` restores `activeModel = "orb/builtin/smart"` and emits `.switchRolledBack`.)

## Epistemic Boundary

- **Proved (`kernel-checked`, `0 import Lean`, `0 sorryAx`, `0 native_decide`):**
  - All theorems listed in the Requirement Mapping above over `PiRpcSession`, `PiRpcEvent`, `PiMcpPolicyInput`, `piSessionRelPathSafe`, and `PiExtractedEventTag`.
  - `pi_rpc_step_satisfies_contract` and `pi_mcp_gate_satisfies_spec` close the positive side of every two-sided regression.
- **Counterexample / mutant-refuted (`kernel-checked`):**
  - `piRpcMutantApplyDuringTool` → hits `PiMidToolSwitchBug` and fails `PiRpcContract`.
  - `piRpcMutantDropRollback` → hits `PiRollbackDropBug` and fails `PiRpcContract`.
  - `piRpcMutantEmitAfterAbort` → hits `PiPostAbortOutputBug` and fails `PiRpcContract`.
  - `piMcpMutantAllowArgvSecret` → hits `PiArgvSecretLeakReachable` and fails `PiMcpGateSpec`.
  - `piMcpMutantAllowReadonlyWrite` → hits `PiReadonlyMutationReachable` and fails `PiMcpGateSpec`.
  - `piTagMutantLeakThinking` → hits `PiThinkingLeakBug` and is separated from `piNormalizeTag`.
- **Unchecked (caller obligations & TCB):**
  - OS `umask`/`chmod`/`lstat` syscalls that populate `agentDirMode0700`, `configFileMode0600`, `sessionPathConfined`, and `secretsInArgv` in `OrbCore.RemoteDispatch` and `OrbNode.PiRpc`.
  - Raw JSONL parsing (`OrbBin.Json.parse`) extracting `PiExtractedEventTag` from `pi --mode rpc` stdout (`extractInTcb`).
  - Node.js / Pi runtime (`@mariozechner/pi-coding-agent`) and TypeScript extension (`pi/orb-extension/index.ts`) execution semantics, HTTP transport to Core's Streamable HTTP MCP endpoint, and stdio IPC with `turbo-lean mcp`.
- **Outside scope:**
  - Upstream LLM provider behavior, network/TLS transport faults, Linux cgroup/systemd isolation (covered by separate specs), and interactive TUI mode of Pi.
