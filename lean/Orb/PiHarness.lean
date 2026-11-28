/-
  Orb.PiHarness: Pure-Lean formal state machine & policy gate for the Pi harness (`#2258`).
  Kept in its own submodule of `Orb` (`0 import Lean`, `0 sorryAx`) so the frozen C-ABI
  scalar kernel (`Orb.Kernel` / `shared/orb-spec/kernel_abi.json`) remains bit-exact untouched.
-/

namespace Orb.Kernel

/-! ## Pi Harness RPC Session State Machine & MCP Policy Gate (`#2258`) -/

/-- Lifecycle phase of a `pi --mode rpc` session driven by `sandboxed-node pi-rpc`. -/
inductive PiRpcPhase where
  | idle
  | running (turnId : Nat) (modelId : String)
  | switchingModel (pendingModel : String)
  | settled
  | aborted
  | closed
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Pure session state for `pi_rpc_step`, tracking active/previous model for explicit rollback,
    correlated `set_model` RPC request ID, queued mid-turn switch, and active tool call fence. -/
structure PiRpcSession where
  phase         : PiRpcPhase    := .idle
  activeModel   : String        := ""
  previousModel : String        := ""
  pendingReqId  : Option Nat    := none
  queuedModel   : Option String := none
  inToolCall    : Bool          := false
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Input events processed by `pi_rpc_step`. -/
inductive PiRpcEvent where
  | startTurn (turnId : Nat)
  | textDelta (delta : String)
  | toolStart (callId : String)
  | toolEnd (callId : String)
  | turnEnd
  | setModel (reqId : Nat) (modelId : String)
  | rpcResponse (reqId : Nat) (success : Bool) (err : String)
  | abort
  | processExit (exitCode : Int)
  deriving Repr, DecidableEq, BEq

/-- Mutually exclusive observable outcomes returned by `pi_rpc_step`. -/
inductive PiRpcOutcome where
  | accepted
  | emitDelta (delta : String)
  | emitToolStart (callId : String)
  | emitToolEnd (callId : String)
  | switchApplied (modelId : String)
  | switchQueued (modelId : String)
  | switchRolledBack (restoredModel : String) (reason : String)
  | rejectedFenced
  | rejectedInvalid
  deriving Repr, DecidableEq, BEq

/-- True once a Pi RPC session has crossed its terminal fence (`aborted` or `closed`). -/
def piRpcIsFenced (s : PiRpcSession) : Bool :=
  match s.phase with
  | .aborted | .closed => true
  | _ => false

/-- True iff an outcome emits assistant text or tool events downstream. -/
def piRpcOutcomeEmitsOutput : PiRpcOutcome → Bool
  | .emitDelta _ | .emitToolStart _ | .emitToolEnd _ => true
  | _ => false

/-- Pure RPC lifecycle and atomic model-switch transition function (`pi_rpc_step`).
    - `aborted` / `closed` act as an irreversible `StickyFence` (zero output, zero new turns).
    - `setModel` in `idle`/`settled` applies immediately and records `previousModel` + `pendingReqId`.
    - `setModel` in `running` queues deterministically without mutating `activeModel` mid-turn or mid-tool-call;
      upon `turnEnd` (when `!inToolCall`), transitions to `switchingModel`.
    - `rpcResponse reqId false err` with matching `pendingReqId` explicitly rolls back `activeModel` to `previousModel`. -/
def piRpcStep (s : PiRpcSession) (ev : PiRpcEvent) : PiRpcSession × PiRpcOutcome :=
  if piRpcIsFenced s then
    match ev with
    | .processExit _ => ({ s with phase := .closed, inToolCall := false }, .rejectedFenced)
    | _ => (s, .rejectedFenced)
  else
    match ev with
    | .abort =>
      ({ s with phase := .aborted, inToolCall := false, queuedModel := none }, .accepted)
    | .processExit _ =>
      ({ s with phase := .closed, inToolCall := false, queuedModel := none }, .accepted)
    | .startTurn tid =>
      match s.phase with
      | .idle | .settled =>
        if s.activeModel.isEmpty then (s, .rejectedInvalid)
        else ({ s with phase := .running tid s.activeModel, inToolCall := false }, .accepted)
      | _ => (s, .rejectedInvalid)
    | .textDelta d =>
      match s.phase with
      | .running _ _ => (s, .emitDelta d)
      | _ => (s, .rejectedInvalid)
    | .toolStart cid =>
      match s.phase with
      | .running _ _ =>
        if cid.isEmpty then (s, .rejectedInvalid)
        else ({ s with inToolCall := true }, .emitToolStart cid)
      | _ => (s, .rejectedInvalid)
    | .toolEnd cid =>
      match s.phase with
      | .running _ _ =>
        if !s.inToolCall || cid.isEmpty then (s, .rejectedInvalid)
        else ({ s with inToolCall := false }, .emitToolEnd cid)
      | _ => (s, .rejectedInvalid)
    | .turnEnd =>
      match s.phase with
      | .running _ _ =>
        if s.inToolCall then (s, .rejectedInvalid)
        else
          match s.queuedModel with
          | some nextM =>
            ({ s with phase := .switchingModel nextM, previousModel := s.activeModel, queuedModel := none }, .accepted)
          | none =>
            ({ s with phase := .settled }, .accepted)
      | _ => (s, .rejectedInvalid)
    | .setModel reqId newModel =>
      if newModel.isEmpty then (s, .rejectedInvalid)
      else
        match s.phase with
        | .idle | .settled =>
          ({ s with
             activeModel := newModel
             previousModel := s.activeModel
             pendingReqId := some reqId
             queuedModel := none }, .switchApplied newModel)
        | .running _ _ =>
          ({ s with
             pendingReqId := some reqId
             queuedModel := some newModel }, .switchQueued newModel)
        | _ => (s, .rejectedInvalid)
    | .rpcResponse reqId ok err =>
      if s.pendingReqId != some reqId then
        (s, .rejectedInvalid)
      else
        match s.phase with
        | .switchingModel targetM =>
          if ok then
            ({ s with phase := .idle, activeModel := targetM, pendingReqId := none }, .switchApplied targetM)
          else
            ({ s with phase := .idle, activeModel := s.previousModel, pendingReqId := none }, .switchRolledBack s.previousModel err)
        | .idle | .settled =>
          if ok then
            ({ s with pendingReqId := none }, .accepted)
          else
            ({ s with activeModel := s.previousModel, pendingReqId := none }, .switchRolledBack s.previousModel err)
        | _ => (s, .rejectedInvalid)

abbrev pi_rpc_step := piRpcStep

/-- Post-extraction flags for `piMcpConfigGate` (`ScopedAuthority`).
    Filesystem mode/symlink checks and argv scanning live in the explicit extractor TCB. -/
structure PiMcpPolicyInput where
  secretsInArgv        : Bool
  agentDirMode0700     : Bool
  configFileMode0600   : Bool
  sessionPathConfined  : Bool
  sandboxedMcpHttpOnly : Bool
  readOnlyMode         : Bool
  toolIsMutating       : Bool
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Admission gate for Pi dual-MCP configuration, secret hygiene, session confinement, and plan/readonly policy. -/
def piMcpConfigGate (inp : PiMcpPolicyInput) : Bool :=
  !inp.secretsInArgv &&
  inp.agentDirMode0700 &&
  inp.configFileMode0600 &&
  inp.sessionPathConfined &&
  inp.sandboxedMcpHttpOnly &&
  (!inp.readOnlyMode || !inp.toolIsMutating)

abbrev pi_mcp_config_gate := piMcpConfigGate

/-- Pure structural split on `'/'` over `List Char` (reduces cleanly inside the Lean kernel). -/
def piSplitSlashAux (cur : List Char) : List Char → List (List Char)
  | [] => [cur.reverse]
  | '/' :: rest => cur.reverse :: piSplitSlashAux [] rest
  | c :: rest => piSplitSlashAux (c :: cur) rest

def piSplitSlash (s : String) : List (List Char) :=
  piSplitSlashAux [] s.toList

/-- Single path component recognizer for Pi mission session relative paths (no `.` / `..`, safe ASCII). -/
def piPathSegmentCharsSafe (cs : List Char) : Bool :=
  !cs.isEmpty && cs != ['.'] && cs != ['.', '.'] &&
  cs.all fun c =>
    c.isAlphanum || c == '-' || c == '_' || c == '.'

/-- Kernel-verified raw relative path recognizer for mission-confined `.jsonl` session files. -/
def piSessionRelPathSafe (rel : String) : Bool :=
  let cs := rel.toList
  let segs := piSplitSlash rel
  !cs.isEmpty &&
  cs.head? != some '/' &&
  cs.getLast? != some '/' &&
  (cs.reverse.take 6) == ['l', 'n', 'o', 's', 'j', '.'] &&
  !(cs.any fun c => c == '\\' || c == '\x00') &&
  segs.all piPathSegmentCharsSafe

/-- Post-extraction event classification tag for Pi RPC JSONL lines (explicit TCB boundary). -/
inductive PiExtractedEventTag where
  | thinkingDelta
  | thinkingEnd
  | textDelta
  | textEnd
  | toolStart
  | toolEnd
  | rpcError
  | processError
  | agentEndOk
  | agentEndError
  | other
  deriving Repr, DecidableEq, BEq

/-- Canonical normalized event category produced from a `PiExtractedEventTag`. -/
inductive PiNormalizedKind where
  | thinking
  | textDelta
  | toolCall
  | toolResult
  | turnOk
  | turnError
  | ignore
  deriving Repr, DecidableEq, BEq

/-- Post-extraction normalization mapping Pi event tags to `AgentEvent` categories. -/
def piNormalizeTag : PiExtractedEventTag → PiNormalizedKind
  | .thinkingDelta | .thinkingEnd => .thinking
  | .textDelta     | .textEnd     => .textDelta
  | .toolStart                    => .toolCall
  | .toolEnd                      => .toolResult
  | .rpcError | .processError | .agentEndError => .turnError
  | .agentEndOk                   => .turnOk
  | .other                        => .ignore

end Orb.Kernel
