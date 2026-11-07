/-
  OrbCore.CloudAgents: Phase R4-B typed cloud-agent adapters (`SM-14`).

  Grok, Hermes, and Cursor Cloud share one durable turn record. Phase, error,
  cancellation, approval, and reconciliation decisions come only from
  `Orb.HarnessCloud.verifyCloudTurnAdmit` and `Orb.HarnessCloud.stepCloudTurnSlice`.
  Human prose in `detail` is stored and never read by a transition.
-/
import Orb.HarnessCloud
import OrbBin.Json
import OrbCore.Store

namespace OrbCore.CloudAgents

open Orb.HarnessCloud
open OrbBin.Json
open OrbCore.Store

inductive CloudProvider where
  | grok
  | hermes
  | cursorCloud
  deriving Repr, DecidableEq

def CloudProvider.encode : CloudProvider → UInt8
  | .grok => 0
  | .hermes => 1
  | .cursorCloud => 2

def CloudProvider.decode? : Nat → Option CloudProvider
  | 0 => some .grok
  | 1 => some .hermes
  | 2 => some .cursorCloud
  | _ => none

def CloudProvider.name : CloudProvider → String
  | .grok => "grok_bot"
  | .hermes => "hermes"
  | .cursorCloud => "cursor_cloud"

def parseCloudProvider? (raw : String) : Option CloudProvider :=
  match raw.trimAscii.toString.toLower with
  | "grok" | "grok_bot" | "cloud_grok" => some .grok
  | "hermes" | "cloud_hermes" => some .hermes
  | "cursor" | "cursor_cloud" | "cloud_cursor" => some .cursorCloud
  | _ => none

/-- Typed submission failure. Never inferred from `detail` prose. -/
inductive SubmissionErrorKind where
  | none
  | reconnectRequired
  | rateLimited
  | authFailed
  | providerRejected
  | transportTimeout
  deriving Repr, DecidableEq

def SubmissionErrorKind.encode : SubmissionErrorKind → UInt8
  | .none => 0
  | .reconnectRequired => 1
  | .rateLimited => 2
  | .authFailed => 3
  | .providerRejected => 4
  | .transportTimeout => 5

def SubmissionErrorKind.decode? : Nat → Option SubmissionErrorKind
  | 0 => some .none
  | 1 => some .reconnectRequired
  | 2 => some .rateLimited
  | 3 => some .authFailed
  | 4 => some .providerRejected
  | 5 => some .transportTimeout
  | _ => none

/-- Typed cancellation. A prose sentence such as "Cancellation sent..." is not a state. -/
inductive CancelState where
  | none
  | requested
  | confirmedReceipt
  deriving Repr, DecidableEq

def CancelState.encode : CancelState → UInt8
  | .none => 0
  | .requested => 1
  | .confirmedReceipt => 2

def CancelState.decode? : Nat → Option CancelState
  | 0 => some .none
  | 1 => some .requested
  | 2 => some .confirmedReceipt
  | _ => none

/-- Approval lifted out of the untyped artifact blob. -/
structure CloudApprovalRequest where
  reqId : UInt64
  command : String := ""
  choices : Array String := #[]
  deriving Repr, DecidableEq

/-- One provider turn. `submittedAtMs?` and `eventCursor?` are distinct fields. -/
structure CloudTurnState where
  missionId : String
  turnIndex : UInt64 := 0
  provider : CloudProvider
  phase : CloudTurnPhase := .queued
  errorKind : SubmissionErrorKind := .none
  cancel : CancelState := .none
  lastAttemptId : UInt64 := 0
  providerTurnId : UInt64 := 0
  approvalReqId : UInt64 := 0
  submittedAtMs? : Option UInt64 := none
  eventCursor? : Option UInt64 := none
  approval? : Option CloudApprovalRequest := none
  detail : String := ""
  stateRevision : UInt64 := 0
  deriving Repr, DecidableEq

/-- One turn already visible at the provider, used only by read-only inspection. -/
structure ObservedProviderTurn where
  providerTurnId : UInt64
  attemptId : UInt64
  submittedAtMs : UInt64
  deriving Repr, DecidableEq

inductive ProviderTurnMatch where
  | none
  | matched (providerTurnId : UInt64)
  deriving Repr, DecidableEq

def freshCloudTurn (missionId : String) (turnIndex : UInt64) (provider : CloudProvider) : CloudTurnState :=
  { missionId := missionId, turnIndex := turnIndex, provider := provider }

def phaseCodeOf (s : CloudTurnState) : UInt8 :=
  CloudTurnPhase.encode s.phase

def submittedAtOf (s : CloudTurnState) : UInt64 :=
  s.submittedAtMs?.getD 0

def cursorOf (s : CloudTurnState) : UInt64 :=
  s.eventCursor?.getD 0

def toSliceState (s : CloudTurnState) : CloudTurnSliceState :=
  { phaseCode := phaseCodeOf s
    unreconciledUnc := if s.phase == .uncertain then 1 else 0
    lastAttemptId := s.lastAttemptId
    providerTurnId := s.providerTurnId
    eventCursor := cursorOf s
    approvalReqId := s.approvalReqId
    submittedAtMs := submittedAtOf s }

def applySlice (s : CloudTurnState) (next : CloudTurnSliceState) : CloudTurnState :=
  let phase := (CloudTurnPhase.decode? next.phaseCode.toNat).getD s.phase
  let cursor? := if next.eventCursor == 0 then none else some next.eventCursor
  let submitted? := if next.submittedAtMs == 0 then none else some next.submittedAtMs
  let approval? :=
    if next.approvalReqId == 0 then none
    else
      match s.approval? with
      | some req => if req.reqId == next.approvalReqId then some req else some { reqId := next.approvalReqId }
      | none => some { reqId := next.approvalReqId }
  { s with
    phase := phase
    lastAttemptId := next.lastAttemptId
    providerTurnId := next.providerTurnId
    approvalReqId := next.approvalReqId
    submittedAtMs? := submitted?
    eventCursor? := cursor?
    approval? := approval?
    stateRevision := s.stateRevision + 1 }

/-- The only mutating step. A refused kernel admit returns the input unchanged. -/
def stepCloudTurn (s : CloudTurnState) (ev : CloudTurnSliceEvent) :
    CloudTurnState × List CloudTurnEffect :=
  if (CloudTurnPhase.decode? (phaseCodeOf s).toNat).isNone then (s, [])
  else
    let (next, effs) := stepCloudTurnSlice (toSliceState s) ev
    if effs.isEmpty then (s, [])
    else
      let stepped := applySlice s next
      let withError :=
        if ev.opCode == CloudTurnOp.encode .rejectPreCommit then
          if s.errorKind == .none then { stepped with errorKind := .providerRejected }
          else stepped
        else if ev.opCode == CloudTurnOp.encode .markUncertain then
          { stepped with errorKind := .transportTimeout }
        else if ev.opCode == CloudTurnOp.encode .confirmAccepted ||
                ev.opCode == CloudTurnOp.encode .bindReconciledTurn ||
                ev.opCode == CloudTurnOp.encode .confirmNotDeliveredRetry then
          { stepped with errorKind := .none }
        else
          stepped
      let withCancel :=
        if ev.opCode == CloudTurnOp.encode .requestCancel then
          { withError with cancel := .requested }
        else if ev.opCode == CloudTurnOp.encode .finalizeCancelReceipt then
          { withError with cancel := .confirmedReceipt }
        else
          withError
      (withCancel, effs)

def beginSubmit (s : CloudTurnState) (attemptId submittedAtMs nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .beginSubmit
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := attemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := 0
    reqSubmittedAtMs := submittedAtMs
    nowMs := nowMs
  }

def confirmAccepted (s : CloudTurnState) (providerTurnId eventCursor nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .confirmAccepted
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := providerTurnId
    reqEventCursor := eventCursor
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

def rejectPreCommit (s : CloudTurnState) (kind : SubmissionErrorKind) (nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  let (next, effs) := stepCloudTurn s {
    opCode := CloudTurnOp.encode .rejectPreCommit
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }
  if effs.isEmpty then (s, [])
  else ({ next with errorKind := kind }, effs)

def markUncertain (s : CloudTurnState) (nowMs : UInt64) : CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .markUncertain
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

def awaitApproval (s : CloudTurnState) (req : CloudApprovalRequest) (nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  if req.reqId == 0 then (s, [])
  else
  let (next, effs) := stepCloudTurn s {
    opCode := CloudTurnOp.encode .awaitApproval
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := req.reqId
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }
  if effs.isEmpty then (s, [])
  else ({ next with approval? := some req, approvalReqId := req.reqId }, effs)

def resolveApproval (s : CloudTurnState) (eventCursor nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .resolveApproval
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 1
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := eventCursor
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

/-- Bind a provider turn found by `inspectProviderTurns`. This is not a fresh submit. -/
def bindExistingTurn (s : CloudTurnState) (providerTurnId eventCursor nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .bindReconciledTurn
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := providerTurnId
    reqEventCursor := eventCursor
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

/-- Return to `queued` only after the operator confirms the attempt was not delivered. -/
def confirmNotDeliveredRetry (s : CloudTurnState) (nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .confirmNotDeliveredRetry
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 1
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

def requestCancel (s : CloudTurnState) (nowMs : UInt64) : CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .requestCancel
    hasTerminationReceipt := 0
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := 0
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

/-- `cancelRequested` stays there until the provider termination receipt arrives.
    `eventCursor` is preserved by the kernel (`opCode == 9` keeps `s.eventCursor`);
    callers that learned a newer cursor stamp it before this step. -/
def finalizeCancelReceipt (s : CloudTurnState) (nowMs : UInt64) : CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .finalizeCancelReceipt
    hasTerminationReceipt := 1
    hasCompletionReceipt := 0
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := cursorOf s
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

def completeTurnReceipt (s : CloudTurnState) (eventCursor nowMs : UInt64) :
    CloudTurnState × List CloudTurnEffect :=
  stepCloudTurn s {
    opCode := CloudTurnOp.encode .completeTurnReceipt
    hasTerminationReceipt := 0
    hasCompletionReceipt := 1
    operatorConfirmedNotDelivered := 0
    approvalResolved := 0
    proposedAttemptId := s.lastAttemptId
    reqProviderTurnId := 0
    reqEventCursor := eventCursor
    reqApprovalReqId := 0
    reqSubmittedAtMs := 0
    nowMs := nowMs
  }

/-- Advance `eventCursor?` strictly forward while `running`, preserving `submittedAtMs?`. -/
def advanceRunningCursor (s : CloudTurnState) (cursor : UInt64) : CloudTurnState :=
  if s.phase != .running || cursor == 0 then s
  else
    let prev := cursorOf s
    if cursor ≤ prev then s
    else { s with eventCursor? := some cursor, stateRevision := s.stateRevision + 1 }

/-- Changing `detail` cannot change the emitted effects or any non-`detail` field. -/
def detailIsInert (s : CloudTurnState) (ev : CloudTurnSliceEvent) (detail : String) : Bool :=
  let (nextPlain, effsPlain) := stepCloudTurn s ev
  let (nextMut, effsMut) := stepCloudTurn { s with detail := detail } ev
  effsPlain == effsMut &&
  { nextPlain with detail := "" } == { nextMut with detail := "" } &&
  nextMut.detail == detail &&
  verifyCloudTurnAdmit (phaseCodeOf s) ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
    ev.operatorConfirmedNotDelivered ev.approvalResolved s.lastAttemptId ev.proposedAttemptId
    (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
    (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
    (if ev.opCode == 0 then ev.reqSubmittedAtMs else submittedAtOf s)
    ev.nowMs ==
  verifyCloudTurnAdmit (phaseCodeOf { s with detail := detail }) ev.opCode ev.hasTerminationReceipt
    ev.hasCompletionReceipt ev.operatorConfirmedNotDelivered ev.approvalResolved s.lastAttemptId
    ev.proposedAttemptId
    (if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId)
    (if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId)
    (if ev.opCode == 0 then ev.reqSubmittedAtMs else submittedAtOf s)
    ev.nowMs

/-- Read-only match of the durable local attempt against observed provider turns. -/
def inspectProviderTurns (s : CloudTurnState) (observed : Array ObservedProviderTurn) : ProviderTurnMatch :=
  match s.submittedAtMs? with
  | none => .none
  | some submitted =>
    match observed.find? fun t =>
      t.attemptId == s.lastAttemptId && t.submittedAtMs == submitted && t.providerTurnId != 0 with
    | some hit => .matched hit.providerTurnId
    | none => .none

def cloudTurnSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS cloud_turn_states (" ++
  "mission_id TEXT NOT NULL, turn_index INTEGER NOT NULL, provider TEXT NOT NULL, " ++
  "phase_code INTEGER NOT NULL, last_attempt_id INTEGER NOT NULL DEFAULT 0, " ++
  "provider_turn_id INTEGER NOT NULL DEFAULT 0, approval_req_id INTEGER NOT NULL DEFAULT 0, " ++
  "submitted_at_ms INTEGER NOT NULL DEFAULT 0, event_cursor INTEGER NOT NULL DEFAULT 0, " ++
  "error_kind INTEGER NOT NULL DEFAULT 0, cancel_state INTEGER NOT NULL DEFAULT 0, " ++
  "state_revision INTEGER NOT NULL, approval_json TEXT NOT NULL DEFAULT '', " ++
  "detail TEXT NOT NULL DEFAULT '', PRIMARY KEY(mission_id, turn_index));"

/-- Schema bootstrap that must run only while `db.mu` is already held (including inside `withImmediateTx`). -/
def ensureCloudTurnSchemaUnlocked (db : SqliteDb) : IO (Except String Unit) :=
  sqliteExecRaw db.handle cloudTurnSchemaSql

def ensureCloudTurnSchema (db : SqliteDb) : IO (Except String Unit) :=
  db.mu.atomically (ensureCloudTurnSchemaUnlocked db)

private def optU64 (n : UInt64) : Option UInt64 :=
  if n == 0 then none else some n

private def approvalJson (req? : Option CloudApprovalRequest) : String :=
  match req? with
  | none => ""
  | some req =>
    let choices := req.choices.map fun c => JVal.str c
    renderCompact (.obj #[
      ("req_id", .uint64 req.reqId),
      ("command", .str req.command),
      ("choices", .arr choices)
    ])

private def parseApproval? (raw : String) : Option CloudApprovalRequest :=
  match OrbBin.Json.parse raw with
  | .ok jv => do
    let reqId ← jv.fieldUInt64? "req_id"
    if reqId == 0 then none
    else
      let cmd ← jv.fieldStr? "command"
      let xs ← jv.fieldArr? "choices"
      let choices := xs.filterMap (fun v => v.asStr?)
      if choices.size != xs.size then none
      else some { reqId := reqId, command := cmd, choices := choices }
  | _ => none

private def hasConsistentApproval (s : CloudTurnState) : Bool :=
  match s.phase == .waitingApproval, s.approval? with
  | true, some req => s.approvalReqId != 0 && req.reqId == s.approvalReqId
  | false, none => s.approvalReqId == 0
  | _, _ => false

private def rowToTurn? (row : Array String) : Option CloudTurnState := do
  let missionId ← row[0]?
  let turnIndex ← (row[1]?.bind String.toNat?).map Nat.toUInt64
  let provider ← row[2]?.bind parseCloudProvider?
  let phase ← (row[3]?.bind String.toNat?).bind CloudTurnPhase.decode?
  let lastAttempt ← (row[4]?.bind String.toNat?).map Nat.toUInt64
  let providerTurn ← (row[5]?.bind String.toNat?).map Nat.toUInt64
  let approvalReq ← (row[6]?.bind String.toNat?).map Nat.toUInt64
  let submitted ← (row[7]?.bind String.toNat?).map Nat.toUInt64
  let cursor ← (row[8]?.bind String.toNat?).map Nat.toUInt64
  let err ← (row[9]?.bind String.toNat?).bind SubmissionErrorKind.decode?
  let cancel ← (row[10]?.bind String.toNat?).bind CancelState.decode?
  let revision ← (row[11]?.bind String.toNat?).map Nat.toUInt64
  if revision == 0 then none
  else
    let approvalRaw := (row[12]?).getD ""
    let detail := (row[13]?).getD ""
    let approval? := if approvalRaw.isEmpty then none else parseApproval? approvalRaw
    let waiting := phase == .waitingApproval
    if waiting != (approvalReq != 0) then none
    else if waiting && (approvalRaw.isEmpty || approval?.isNone) then none
    else if !waiting && !approvalRaw.isEmpty then none
    else if let some req := approval? then
      if req.reqId != approvalReq || req.reqId == 0 then none
      else
        some {
          missionId := missionId
          turnIndex := turnIndex
          provider := provider
          phase := phase
          errorKind := err
          cancel := cancel
          lastAttemptId := lastAttempt
          providerTurnId := providerTurn
          approvalReqId := approvalReq
          submittedAtMs? := optU64 submitted
          eventCursor? := optU64 cursor
          approval? := approval?
          detail := detail
          stateRevision := revision
        }
    else
      some {
        missionId := missionId
        turnIndex := turnIndex
        provider := provider
        phase := phase
        errorKind := err
        cancel := cancel
        lastAttemptId := lastAttempt
        providerTurnId := providerTurn
        approvalReqId := approvalReq
        submittedAtMs? := optU64 submitted
        eventCursor? := optU64 cursor
        approval? := none
        detail := detail
        stateRevision := revision
      }

def loadCloudTurn? (db : SqliteDb) (missionId : String) (turnIndex : UInt64) :
    IO (Except String (Option CloudTurnState)) := do
  let schema ← ensureCloudTurnSchema db
  if let .error e := schema then return .error e
  let rows ← execParamQuery db
    "SELECT mission_id,turn_index,provider,phase_code,last_attempt_id,provider_turn_id,approval_req_id,submitted_at_ms,event_cursor,error_kind,cancel_state,state_revision,approval_json,detail FROM cloud_turn_states WHERE mission_id=?1 AND turn_index=?2;"
    #[missionId, s!"{turnIndex}"]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok none
    match rowToTurn? rs[1]! with
    | some s => return .ok (some s)
    | none => return .error "cloud_turn_row_corrupt"

private def sqliteConstraintConflict (err : String) : Bool :=
  let low := err.toLower
  (low.splitOn "constraint").length > 1 || (low.splitOn "primary key").length > 1

private def changesEq1 (db : SqliteDb) : IO (Except String Unit) := do
  let chg ← execParamQueryUnlocked db "SELECT changes();" #[]
  match chg with
  | .error e => return .error e
  | .ok crs =>
    if ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 == 1 then return .ok ()
    else return .error "cloud_turn_cas_conflict"

/-- Compare-and-swap write. A stale `expectedRevision` or a racing insert changes nothing.
    `expectedRevision == 0` is an insert of `state_revision = 1` (no upsert). A positive
    revision is an `UPDATE ... WHERE state_revision = expected` confirmed by `changes() == 1`.
    The schema is created inside the same immediate transaction so a fresh `CoreStore` works
    without a prior `ensureCloudTurnSchema` call. -/
def persistCloudTurn (db : SqliteDb) (s : CloudTurnState) (expectedRevision : UInt64) :
    IO (Except String CloudTurnState) := do
  if (CloudTurnPhase.decode? (phaseCodeOf s).toNat).isNone then
    return .error "cloud_turn_phase_out_of_domain"
  if !hasConsistentApproval s then
    return .error "cloud_turn_invalid_approval_state"
  if expectedRevision != 0 && expectedRevision + 1 ≤ expectedRevision then
    return .error "cloud_turn_revision_overflow"
  let nextRev := if expectedRevision == 0 then 1 else expectedRevision + 1
  let written := { s with stateRevision := nextRev }
  let params : Array String := #[
    written.missionId, s!"{written.turnIndex}", written.provider.name,
    s!"{phaseCodeOf written}", s!"{written.lastAttemptId}", s!"{written.providerTurnId}",
    s!"{written.approvalReqId}", s!"{submittedAtOf written}", s!"{cursorOf written}",
    s!"{written.errorKind.encode}", s!"{written.cancel.encode}", s!"{written.stateRevision}",
    approvalJson written.approval?, written.detail
  ]
  withImmediateTx db do
    let schema ← ensureCloudTurnSchemaUnlocked db
    if let .error e := schema then return .error e
    if expectedRevision == 0 then
      let sql :=
        "INSERT INTO cloud_turn_states(mission_id,turn_index,provider,phase_code,last_attempt_id,provider_turn_id,approval_req_id,submitted_at_ms,event_cursor,error_kind,cancel_state,state_revision,approval_json,detail) " ++
        "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14);"
      match ← execParamQueryUnlocked db sql params with
      | .error e =>
        if sqliteConstraintConflict e then return .error "cloud_turn_cas_conflict"
        else return .error e
      | .ok _ =>
        let changed ← changesEq1 db
        if let .error e := changed then return .error e
        return .ok written
    else
      let sql :=
        "UPDATE cloud_turn_states SET provider=?3,phase_code=?4,last_attempt_id=?5," ++
        "provider_turn_id=?6,approval_req_id=?7,submitted_at_ms=?8,event_cursor=?9," ++
        "error_kind=?10,cancel_state=?11,state_revision=?12,approval_json=?13,detail=?14 " ++
        "WHERE mission_id=?1 AND turn_index=?2 AND state_revision=?15;"
      match ← execParamQueryUnlocked db sql (params.push s!"{expectedRevision}") with
      | .error e => return .error e
      | .ok _ =>
        let changed ← changesEq1 db
        if let .error e := changed then return .error e
        return .ok written

end OrbCore.CloudAgents
