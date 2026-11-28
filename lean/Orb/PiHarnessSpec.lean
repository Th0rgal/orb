/-
  Orb.PiHarnessSpec: Formal Contracts & Two-Sided Regressions for the Pi Harness (`#2258`).
  Pure Lean 4 (`0 import Lean`, `0 sorryAx`), Summit Contract Criteria, verified by
  `turbo-lean --json audit-spec lean/Orb/PiHarnessSpec.lean`.
-/

import Orb.PiHarness
import Orb.Spec

namespace Orb.Spec

open Orb.Kernel

/-! ## Pi Harness Formal Contracts & Two-Sided Regressions (`#2258`) -/

/-- Layer-I `StickyFence` witness for `PiRpcSession`: once `aborted` or `closed`,
    `piRpcStep` remains fenced forever and never re-enters `running`. -/
def piRpcStickyFence : StickyFence PiRpcSession PiRpcEvent where
  fenced := piRpcIsFenced
  preFenceAct := fun s =>
    match s.phase with
    | .running _ _ => true
    | _ => false
  step := fun s ev => (piRpcStep s ev).1
  sticky := by
    intro s ev hf
    unfold piRpcStep
    simp only [hf, ↓reduceIte]
    cases ev
    all_goals first | exact hf | rfl
  forbids_post := by
    intro s ev hf
    unfold piRpcStep
    simp only [hf, ↓reduceIte]
    cases hph : s.phase
    all_goals simp [piRpcIsFenced, hph] at hf
    all_goals cases ev
    all_goals simp [hph]

theorem pi_rpc_fenced_forbids_output
    (s : PiRpcSession) (ev : PiRpcEvent)
    (h_fenced : piRpcIsFenced s = true) :
    piRpcOutcomeEmitsOutput (piRpcStep s ev).2 = false := by
  unfold piRpcStep
  simp only [h_fenced, ↓reduceIte]
  cases ev <;> rfl

theorem pi_rpc_set_model_idle_immediate
    (s : PiRpcSession) (reqId : Nat) (newModel : String)
    (h_idle : s.phase = .idle)
    (h_nonempty : newModel.isEmpty = false) :
    let res := piRpcStep s (.setModel reqId newModel)
    res.1.activeModel = newModel ∧
    res.1.previousModel = s.activeModel ∧
    res.1.pendingReqId = some reqId ∧
    res.2 = .switchApplied newModel := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_idle, h_nonempty]

theorem pi_rpc_set_model_running_queues_without_mutating_active
    (s : PiRpcSession) (tid : Nat) (curModel : String) (reqId : Nat) (newModel : String)
    (h_running : s.phase = .running tid curModel)
    (h_nonempty : newModel.isEmpty = false) :
    let res := piRpcStep s (.setModel reqId newModel)
    res.1.activeModel = s.activeModel ∧
    res.1.phase = .running tid curModel ∧
    res.1.queuedModel = some newModel ∧
    res.1.pendingReqId = some reqId ∧
    res.2 = .switchQueued newModel := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_running, h_nonempty]

theorem pi_rpc_turn_end_enters_switching_model
    (s : PiRpcSession) (tid : Nat) (curModel nextModel : String)
    (h_running : s.phase = .running tid curModel)
    (h_no_tool : s.inToolCall = false)
    (h_queued : s.queuedModel = some nextModel) :
    let res := piRpcStep s .turnEnd
    res.1.phase = .switchingModel nextModel ∧
    res.1.previousModel = s.activeModel ∧
    res.1.queuedModel = none ∧
    res.2 = .accepted := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_running, h_no_tool, h_queued]

theorem pi_rpc_turn_end_blocked_during_tool_call
    (s : PiRpcSession) (tid : Nat) (curModel : String)
    (h_running : s.phase = .running tid curModel)
    (h_in_tool : s.inToolCall = true) :
    piRpcStep s .turnEnd = (s, .rejectedInvalid) := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_running, h_in_tool]

theorem pi_rpc_response_failure_rolls_back_switching
    (s : PiRpcSession) (targetModel : String) (reqId : Nat) (err : String)
    (h_switching : s.phase = .switchingModel targetModel)
    (h_req : s.pendingReqId = some reqId) :
    let res := piRpcStep s (.rpcResponse reqId false err)
    res.1.phase = .idle ∧
    res.1.activeModel = s.previousModel ∧
    res.1.pendingReqId = none ∧
    res.2 = .switchRolledBack s.previousModel err := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_switching, h_req]

theorem pi_rpc_response_failure_rolls_back_idle
    (s : PiRpcSession) (reqId : Nat) (err : String)
    (h_idle : s.phase = .idle)
    (h_req : s.pendingReqId = some reqId) :
    let res := piRpcStep s (.rpcResponse reqId false err)
    res.1.activeModel = s.previousModel ∧
    res.1.pendingReqId = none ∧
    res.2 = .switchRolledBack s.previousModel err := by
  unfold piRpcStep
  simp [piRpcIsFenced, h_idle, h_req]

theorem pi_rpc_response_wrong_id_noop
    (s : PiRpcSession) (reqId : Nat) (ok : Bool) (err : String)
    (h_not_fenced : piRpcIsFenced s = false)
    (h_mismatch : (s.pendingReqId != some reqId) = true) :
    piRpcStep s (.rpcResponse reqId ok err) = (s, .rejectedInvalid) := by
  unfold piRpcStep
  simp [h_not_fenced, h_mismatch]

/-- Observable core contract over any candidate Pi RPC step function (Summit simplicity & non-overlap). -/
def PiRpcContract (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome) : Prop :=
  (∀ s ev, piRpcIsFenced s = true →
    piRpcIsFenced (stepFn s ev).1 = true ∧ piRpcOutcomeEmitsOutput (stepFn s ev).2 = false) ∧
  (∀ s tid cur reqId nextM,
    s.phase = .running tid cur → nextM.isEmpty = false →
    (stepFn s (.setModel reqId nextM)).1.activeModel = s.activeModel) ∧
  (∀ s targetM reqId err,
    s.phase = .switchingModel targetM → s.pendingReqId = some reqId →
    (stepFn s (.rpcResponse reqId false err)).1.activeModel = s.previousModel)

theorem pi_rpc_step_satisfies_contract : PiRpcContract piRpcStep := by
  refine ⟨?_, ?_, ?_⟩
  · intro s ev hf
    exact ⟨piRpcStickyFence.sticky s ev hf, pi_rpc_fenced_forbids_output s ev hf⟩
  · intro s tid cur reqId nextM hrun hne
    exact (pi_rpc_set_model_running_queues_without_mutating_active s tid cur reqId nextM hrun hne).1
  · intro s targetM reqId err hsw hreq
    exact (pi_rpc_response_failure_rolls_back_switching s targetM reqId err hsw hreq).2.1

/-- Exploit predicate 1: applying `set_model` mutates `activeModel` mid-tool-call while `running`. -/
def PiMidToolSwitchBug (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome) : Prop :=
  ∃ s tid cur reqId nextM,
    s.phase = .running tid cur ∧ s.inToolCall = true ∧ nextM.isEmpty = false ∧
    (stepFn s (.setModel reqId nextM)).1.activeModel ≠ s.activeModel

theorem pi_rpc_contract_forbids_mid_tool_switch
    (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome)
    (hSpec : PiRpcContract stepFn) :
    ¬ PiMidToolSwitchBug stepFn := by
  intro ⟨s, tid, cur, reqId, nextM, hrun, _, hne, hmut⟩
  exact hmut (hSpec.2.1 s tid cur reqId nextM hrun hne)

/-- Meaningful mutant 1: forgets to queue `set_model` during `running` and swaps `activeModel` immediately. -/
def piRpcMutantApplyDuringTool (s : PiRpcSession) (ev : PiRpcEvent) : PiRpcSession × PiRpcOutcome :=
  match ev with
  | .setModel reqId newModel =>
    if !piRpcIsFenced s && !newModel.isEmpty then
      ({ s with activeModel := newModel, previousModel := s.activeModel, pendingReqId := some reqId }, .switchApplied newModel)
    else piRpcStep s ev
  | _ => piRpcStep s ev

theorem pi_rpc_mutant_apply_during_tool_hits_bug :
    PiMidToolSwitchBug piRpcMutantApplyDuringTool := by
  refine ⟨{ phase := .running 1 "orb/smart", activeModel := "orb/smart", inToolCall := true },
          1, "orb/smart", 7, "orb/opus", rfl, rfl, rfl, ?_⟩
  decide

theorem pi_rpc_mutant_apply_during_tool_rejected :
    ¬ PiRpcContract piRpcMutantApplyDuringTool :=
  fun h => pi_rpc_contract_forbids_mid_tool_switch piRpcMutantApplyDuringTool h pi_rpc_mutant_apply_during_tool_hits_bug

/-- Exploit predicate 2: a rejected `set_model` RPC response fails to restore `previousModel`. -/
def PiRollbackDropBug (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome) : Prop :=
  ∃ s targetM reqId err,
    s.phase = .switchingModel targetM ∧ s.pendingReqId = some reqId ∧
    (stepFn s (.rpcResponse reqId false err)).1.activeModel ≠ s.previousModel

theorem pi_rpc_contract_forbids_rollback_drop
    (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome)
    (hSpec : PiRpcContract stepFn) :
    ¬ PiRollbackDropBug stepFn := by
  intro ⟨s, targetM, reqId, err, hsw, hreq, hbad⟩
  exact hbad (hSpec.2.2 s targetM reqId err hsw hreq)

/-- Meaningful mutant 2: on failed `set_model` RPC response, leaves `targetModel` installed instead of rolling back. -/
def piRpcMutantDropRollback (s : PiRpcSession) (ev : PiRpcEvent) : PiRpcSession × PiRpcOutcome :=
  match s.phase, ev with
  | .switchingModel targetM, .rpcResponse reqId false err =>
    if s.pendingReqId == some reqId then
      ({ s with phase := .idle, activeModel := targetM, pendingReqId := none }, .switchRolledBack targetM err)
    else piRpcStep s ev
  | _, _ => piRpcStep s ev

theorem pi_rpc_mutant_drop_rollback_hits_bug :
    PiRollbackDropBug piRpcMutantDropRollback := by
  refine ⟨{ phase := .switchingModel "orb/bad", activeModel := "orb/bad", previousModel := "orb/smart", pendingReqId := some 9 },
          "orb/bad", 9, "model_not_found", rfl, rfl, ?_⟩
  decide

theorem pi_rpc_mutant_drop_rollback_rejected :
    ¬ PiRpcContract piRpcMutantDropRollback :=
  fun h => pi_rpc_contract_forbids_rollback_drop piRpcMutantDropRollback h pi_rpc_mutant_drop_rollback_hits_bug

/-- Exploit predicate 3: emitting assistant text after `aborted` fence. -/
def PiPostAbortOutputBug (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome) : Prop :=
  ∃ s ev, piRpcIsFenced s = true ∧ piRpcOutcomeEmitsOutput (stepFn s ev).2 = true

theorem pi_rpc_contract_forbids_post_abort_output
    (stepFn : PiRpcSession → PiRpcEvent → PiRpcSession × PiRpcOutcome)
    (hSpec : PiRpcContract stepFn) :
    ¬ PiPostAbortOutputBug stepFn := by
  intro ⟨s, ev, hf, hout⟩
  have hno := (hSpec.1 s ev hf).2
  rw [hno] at hout
  contradiction

/-- Meaningful mutant 3: drops the fence check on `textDelta` after `abort`. -/
def piRpcMutantEmitAfterAbort (s : PiRpcSession) (ev : PiRpcEvent) : PiRpcSession × PiRpcOutcome :=
  match ev with
  | .textDelta d => (s, .emitDelta d)
  | _ => piRpcStep s ev

theorem pi_rpc_mutant_emit_after_abort_hits_bug :
    PiPostAbortOutputBug piRpcMutantEmitAfterAbort :=
  ⟨{ phase := .aborted, activeModel := "orb/smart" }, .textDelta "late chunk", rfl, rfl⟩

theorem pi_rpc_mutant_emit_after_abort_rejected :
    ¬ PiRpcContract piRpcMutantEmitAfterAbort :=
  fun h => pi_rpc_contract_forbids_post_abort_output piRpcMutantEmitAfterAbort h pi_rpc_mutant_emit_after_abort_hits_bug

/-! ### `PiMcpPolicyGate` (`MetaGateSpec`, `ScopedAuthority`, Two-Sided Regressions) -/

def PiMcpPolicySafe (inp : PiMcpPolicyInput) : Prop :=
  inp.secretsInArgv = false ∧
  inp.agentDirMode0700 = true ∧
  inp.configFileMode0600 = true ∧
  inp.sessionPathConfined = true ∧
  inp.sandboxedMcpHttpOnly = true ∧
  (inp.readOnlyMode = false ∨ inp.toolIsMutating = false)

def piMcpPolicyMetaGate : MetaGateSpec PiMcpPolicyInput PiMcpPolicySafe where
  gate := piMcpConfigGate
  sound := by
    intro x hx
    unfold piMcpConfigGate at hx
    rcases x with ⟨sec, d07, f06, sc, http, ro, isMut⟩
    simp only [Bool.and_eq_true, Bool.not_eq_true', Bool.or_eq_true] at hx
    exact ⟨hx.1.1.1.1.1, hx.1.1.1.1.2, hx.1.1.1.2, hx.1.1.2, hx.1.2, hx.2⟩
  complete := by
    intro x hx
    unfold piMcpConfigGate
    rcases hx with ⟨h1, h2, h3, h4, h5, h6⟩
    rcases h6 with hro | hm
    · simp [h1, h2, h3, h4, h5, hro]
    · simp [h1, h2, h3, h4, h5, hm]
  posWitness := {
    secretsInArgv := false
    agentDirMode0700 := true
    configFileMode0600 := true
    sessionPathConfined := true
    sandboxedMcpHttpOnly := true
    readOnlyMode := true
    toolIsMutating := false
  }
  negWitness := {
    secretsInArgv := true
    agentDirMode0700 := true
    configFileMode0600 := true
    sessionPathConfined := true
    sandboxedMcpHttpOnly := true
    readOnlyMode := false
    toolIsMutating := false
  }
  nonVacuous := rfl
  tight := rfl

def piMcpScopedAuthority : ScopedAuthority PiMcpPolicyInput where
  admit := piMcpConfigGate
  scopeValid := fun inp =>
    !inp.secretsInArgv && inp.sessionPathConfined && inp.agentDirMode0700 &&
    inp.configFileMode0600 && inp.sandboxedMcpHttpOnly && (!inp.readOnlyMode || !inp.toolIsMutating)
  sound := by
    intro x hx
    have hs := piMcpPolicyMetaGate.sound x hx
    rcases hs with ⟨h1, h2, h3, h4, h5, h6⟩
    rcases h6 with hro | hm
    · simp [h1, h2, h3, h4, h5, hro]
    · simp [h1, h2, h3, h4, h5, hm]

/-- Two-sided regression contract for Pi MCP/policy gates. -/
def PiMcpGateSpec (gateFn : PiMcpPolicyInput → Bool) : Prop :=
  ∀ inp, gateFn inp = true → PiMcpPolicySafe inp

theorem pi_mcp_gate_satisfies_spec : PiMcpGateSpec piMcpConfigGate :=
  piMcpPolicyMetaGate.sound

def PiArgvSecretLeakReachable (gateFn : PiMcpPolicyInput → Bool) : Prop :=
  ∃ inp, inp.secretsInArgv = true ∧ gateFn inp = true

theorem pi_mcp_spec_forbids_argv_secret
    (gateFn : PiMcpPolicyInput → Bool) (hSpec : PiMcpGateSpec gateFn) :
    ¬ PiArgvSecretLeakReachable gateFn := by
  intro ⟨inp, hsec, hadm⟩
  have hsafe := hSpec inp hadm
  rw [hsafe.1] at hsec
  contradiction

def piMcpMutantAllowArgvSecret (inp : PiMcpPolicyInput) : Bool :=
  inp.agentDirMode0700 && inp.configFileMode0600 && inp.sessionPathConfined &&
  inp.sandboxedMcpHttpOnly && (!inp.readOnlyMode || !inp.toolIsMutating)

theorem pi_mcp_mutant_argv_secret_hits_bug :
    PiArgvSecretLeakReachable piMcpMutantAllowArgvSecret :=
  ⟨{ secretsInArgv := true, agentDirMode0700 := true, configFileMode0600 := true,
     sessionPathConfined := true, sandboxedMcpHttpOnly := true, readOnlyMode := false, toolIsMutating := false },
   rfl, rfl⟩

theorem pi_mcp_mutant_argv_secret_rejected :
    ¬ PiMcpGateSpec piMcpMutantAllowArgvSecret :=
  fun h => pi_mcp_spec_forbids_argv_secret piMcpMutantAllowArgvSecret h pi_mcp_mutant_argv_secret_hits_bug

def PiReadonlyMutationReachable (gateFn : PiMcpPolicyInput → Bool) : Prop :=
  ∃ inp, inp.readOnlyMode = true ∧ inp.toolIsMutating = true ∧ gateFn inp = true

theorem pi_mcp_spec_forbids_readonly_mutation
    (gateFn : PiMcpPolicyInput → Bool) (hSpec : PiMcpGateSpec gateFn) :
    ¬ PiReadonlyMutationReachable gateFn := by
  intro ⟨inp, hro, hmut, hadm⟩
  have hsafe := (hSpec inp hadm).2.2.2.2.2
  cases hsafe with
  | inl h => rw [h] at hro; contradiction
  | inr h => rw [h] at hmut; contradiction

def piMcpMutantAllowReadonlyWrite (inp : PiMcpPolicyInput) : Bool :=
  !inp.secretsInArgv && inp.agentDirMode0700 && inp.configFileMode0600 &&
  inp.sessionPathConfined && inp.sandboxedMcpHttpOnly

theorem pi_mcp_mutant_readonly_write_hits_bug :
    PiReadonlyMutationReachable piMcpMutantAllowReadonlyWrite :=
  ⟨{ secretsInArgv := false, agentDirMode0700 := true, configFileMode0600 := true,
     sessionPathConfined := true, sandboxedMcpHttpOnly := true, readOnlyMode := true, toolIsMutating := true },
   rfl, rfl, rfl⟩

theorem pi_mcp_mutant_readonly_write_rejected :
    ¬ PiMcpGateSpec piMcpMutantAllowReadonlyWrite :=
  fun h => pi_mcp_spec_forbids_readonly_mutation piMcpMutantAllowReadonlyWrite h pi_mcp_mutant_readonly_write_hits_bug

/-- Raw kernel-verified session path confinement: accepted relative paths contain no `..` segment and end in `.jsonl`. -/
theorem pi_session_rel_path_safe_no_parent_escape
    (rel : String) (h : piSessionRelPathSafe rel = true) :
    ['.', '.'] ∉ piSplitSlash rel ∧ (rel.toList.reverse.take 6) = ['l', 'n', 'o', 's', 'j', '.'] := by
  unfold piSessionRelPathSafe at h
  simp only [Bool.and_eq_true, List.all_eq_true, beq_iff_eq] at h
  refine ⟨?_, h.1.1.2⟩
  intro hmem
  have hseg := h.2 ['.', '.'] hmem
  simp [piPathSegmentCharsSafe] at hseg

theorem pi_session_rel_path_accepts_mission_jsonl :
    piSessionRelPathSafe "mission-123/session.jsonl" = true := by
  decide

theorem pi_session_rel_path_rejects_traversal :
    piSessionRelPathSafe "../escape/session.jsonl" = false := by
  decide

/-! ### Pi Event Tag Normalization (`Thinking` isolation & fail-closed errors) -/

theorem pi_thinking_never_leaks_to_text_delta
    (t : PiExtractedEventTag)
    (h_think : t = .thinkingDelta ∨ t = .thinkingEnd) :
    piNormalizeTag t ≠ .textDelta := by
  cases h_think with
  | inl h => subst h; decide
  | inr h => subst h; decide

theorem pi_errors_always_turn_error
    (t : PiExtractedEventTag)
    (h_err : t = .rpcError ∨ t = .processError ∨ t = .agentEndError) :
    piNormalizeTag t = .turnError := by
  rcases h_err with h | h | h
  · subst h; rfl
  · subst h; rfl
  · subst h; rfl

def PiThinkingLeakBug (normFn : PiExtractedEventTag → PiNormalizedKind) : Prop :=
  ∃ t, (t = .thinkingDelta ∨ t = .thinkingEnd) ∧ normFn t = .textDelta

def piTagMutantLeakThinking : PiExtractedEventTag → PiNormalizedKind
  | .thinkingDelta => .textDelta
  | tag => piNormalizeTag tag

theorem pi_tag_mutant_leaks_thinking :
    PiThinkingLeakBug piTagMutantLeakThinking :=
  ⟨.thinkingDelta, Or.inl rfl, rfl⟩

theorem pi_normalize_tag_forbids_thinking_leak :
    ¬ PiThinkingLeakBug piNormalizeTag := by
  intro ⟨t, hth, hleak⟩
  exact pi_thinking_never_leaks_to_text_delta t hth hleak

end Orb.Spec
