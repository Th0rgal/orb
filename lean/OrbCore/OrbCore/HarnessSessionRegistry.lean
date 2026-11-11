/-
  OrbCore.HarnessSessionRegistry: Phase R4-C Generation-Owned Harness Session Registry,
  OpenCode SSE + CLI Dual-Channel Reducer, Non-Contended Process-Kill Handle & Continuity Store,
  and Ask Sidecar Post-Ack Midturn Note Flush + Startup Sandbox GC (`SM-15`, `SM-16`, `SM-17`, `SM-18`,
  `0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import Std.Data.HashMap
import Orb.Kernel
import Orb.HarnessCloud
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Store
import OrbCore.Harness

namespace OrbCore.HarnessSessionRegistry

open Orb.Kernel
open Orb.HarnessCloud
open OrbBin.Json
open OrbCore.Store
open OrbCore.Harness

/-! ## 1. Harness Kind Mapping (`Orb.Kernel.agentEventNormalizeStep`) -/

inductive HarnessBackendKind where
  | codex
  | claudeCode
  | antigravity
  | openCode
  | grok
  | vibe
  deriving Repr, DecidableEq, BEq, Inhabited

def HarnessBackendKind.code : HarnessBackendKind → UInt8
  | .codex       => 0
  | .claudeCode  => 1
  | .antigravity => 2
  | .openCode    => 3
  | .grok        => 4
  | .vibe        => 5

def HarnessBackendKind.asString : HarnessBackendKind → String
  | .codex       => "codex"
  | .claudeCode  => "claudecode"
  | .antigravity => "antigravity"
  | .openCode    => "opencode"
  | .grok        => "grok"
  | .vibe        => "vibe"

def HarnessBackendKind.ofString? (s : String) : Option HarnessBackendKind :=
  match s.trimAscii.toString.toLower with
  | "codex"                   => some .codex
  | "claudecode" | "claude"   => some .claudeCode
  | "antigravity" | "agy"     => some .antigravity
  | "opencode"                => some .openCode
  | "grok"                    => some .grok
  | "vibe"                    => some .vibe
  | _                         => none

/-! ## 2. `SM-17`: Non-Contended `ProcessKillHandle` Verified via `Orb.Kernel.procLivenessStep` -/

/-- Parsed `/proc/<pid>/stat` observation ready for `Orb.Kernel.procLivenessStep`. -/
structure ProcStatObservation where
  procMissing         : UInt8
  procReadError       : UInt8
  isZombieOrDeadState : UInt8
  fieldsAfterComm     : UInt32
  actualStartTicks    : UInt64
  deriving Repr, DecidableEq

/-- Parse raw contents of Linux `/proc/<pid>/stat`, handling arbitrary spaces/parentheses inside `comm`
    by splitting at the FIRST `'('` and LAST `") "`. Field 1 after `") "` is state (`'Z'`/`'X'`/`'x'`),
    and field 20 after `") "` (0-indexed index 19, Linux `/proc` 1-indexed field 22) is `starttime` ticks. -/
def parseProcStatContent (raw : String) : ProcStatObservation :=
  let partsOpen := raw.splitOn "("
  if partsOpen.length < 2 then
    { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  else
    let afterOpen := String.intercalate "(" partsOpen.tail!
    let partsClose := afterOpen.splitOn ") "
    if partsClose.length < 2 then
      { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
    else
      let rest := partsClose.getLast!
      let fields := ((rest.trimAscii.toString.splitOn " ").filter (fun s => !s.isEmpty)).toArray
      let nFields := fields.size
      if nFields == 0 then
        { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
      else
        let stTok := fields[0]!
        let isZomb : UInt8 := if stTok == "Z" || stTok == "X" || stTok == "x" then 1 else 0
        let ticks : UInt64 :=
          if h : 19 < fields.size then
            match fields[19].toNat? with
            | some n => n.toUInt64
            | none   => 0
          else 0
        let fCount : UInt32 := (Nat.min nFields 0xFFFFFFFF).toUInt32
        { procMissing := 0
          procReadError := 0
          isZombieOrDeadState := isZomb
          fieldsAfterComm := fCount
          actualStartTicks := ticks }

/-- Read `/proc/<pid>/stat` from `procRoot` (default `"/proc"`). Distinguishes missing `/proc/<pid>/stat`
    (`procMissing = 1`) from transient/permission procfs read failure (`procReadError = 1`). -/
def observeProcStat (pid : UInt32) (procRoot : System.FilePath := System.FilePath.mk "/proc") : IO ProcStatObservation := do
  if pid == 0 then
    return { procMissing := 1, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  let statFile := procRoot / s!"{pid}" / "stat"
  let stFlags ← OrbBin.PosixExt.statPath statFile.toString
  if !stFlags.exists_ then
    return { procMissing := 1, procReadError := 0, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  match ← IO.FS.readFile statFile |>.toBaseIO with
  | .error _ =>
    return { procMissing := 0, procReadError := 1, isZombieOrDeadState := 0, fieldsAfterComm := 0, actualStartTicks := 0 }
  | .ok raw =>
    return parseProcStatContent raw

/-- Read the current `starttime` ticks of `pid` from `/proc/<pid>/stat` when alive (`none` if dead/missing). -/
def readLiveProcStartTicks? (pid : UInt32) (procRoot : System.FilePath := System.FilePath.mk "/proc") : IO (Option UInt64) := do
  let obs ← observeProcStat pid procRoot
  let v := Orb.Kernel.procLivenessStep
    obs.procMissing obs.procReadError obs.isZombieOrDeadState 0
    obs.fieldsAfterComm 0 obs.actualStartTicks
  if v == 1 then return some obs.actualStartTicks else return none

inductive ProcessKillVerdict where
  | skippedInvalidHandle
  | skippedDeadOrPidReused
  | signaledAlive (errno : UInt32)
  | signaledInconclusive (errno : UInt32)
  deriving Repr, DecidableEq

/-- Non-contended process-kill handle (`SM-17`). Holds immutable `(pid, startTicks)` and an optional
    custom signal/stat hook for deterministic testing, completely independent of any `HarnessSessionHandle`
    state mutex (`try_lock()` contention can never skip teardown). -/
structure ProcessKillHandle where
  pid             : UInt32
  startTicks      : UInt64
  killProcessGrp  : Bool := true
  observeFn?      : Option (UInt32 → IO ProcStatObservation) := none
  signalFn?       : Option (Int64 → Int32 → IO UInt32) := none

/-- Pure classification wrapper binding `Orb.Kernel.procLivenessStep` to `(pid, startTicks)` kill admission:
    - `0 (dead)` (including `actualStartTicks != startTicks` PID reuse or zombie/missing): NEVER signal.
    - `1 (alive)` or `2 (inconclusive_alive)` (transient `/proc` read error): signal target PID / process group. -/
def classifyKillLiveness (handle : ProcessKillHandle) (obs : ProcStatObservation) : UInt8 :=
  if handle.pid == 0 then 0
  else
    let hasExpectedTicks : UInt8 := if handle.startTicks != 0 then 1 else 0
    Orb.Kernel.procLivenessStep
      obs.procMissing obs.procReadError obs.isZombieOrDeadState hasExpectedTicks
      obs.fieldsAfterComm handle.startTicks obs.actualStartTicks

/-- Signal a child process or process group without acquiring any session mutex (`SM-17`).
    Verifies `(pid, startTicks)` via `Orb.Kernel.procLivenessStep` immediately before signaling. -/
def reapWithKillHandle (handle : ProcessKillHandle) (sig : Int32 := 15) : IO ProcessKillVerdict := do
  if handle.pid == 0 || handle.pid > 0x7FFFFFFF then
    return .skippedInvalidHandle
  let obs ← match handle.observeFn? with
    | some f => f handle.pid
    | none   => observeProcStat handle.pid
  let liveness := classifyKillLiveness handle obs
  if liveness == 0 then
    return .skippedDeadOrPidReused
  let target : Int64 :=
    let base : Int64 := Int64.ofNat handle.pid.toNat
    if handle.killProcessGrp then -base else base
  let errno ← match handle.signalFn? with
    | some sf => sf target sig
    | none    => OrbBin.PosixExt.killSig target sig
  if liveness == 2 then
    return .signaledInconclusive errno
  else
    return .signaledAlive errno

/-! ## 3. `SM-16`: Unified OpenCode SSE Sidecar + CLI Process Exit Dual-Channel Reducer -/

/-- Terminal classification of a single OpenCode dual-channel turn (`SM-16`). -/
inductive OpenCodeTurnVerdict where
  | inProgress
  | completedClean
  | failedSilentStop (reason : String)
  | failedCliExit (exitCode : Int32) (detail : String)
  | failedSseError (detail : String)
  deriving Repr, DecidableEq

/-- Typed dual-channel input event joining OpenCode SSE sidecar frames and CLI stdout/exit (`SM-16`). -/
inductive OpenCodeDualChannelInput where
  | sseSessionIdle (sessionId : String)
  | sseChunk (sessionId : String) (ssePayload : String)
  | cliJsonLine (line : String)
  | cliProcessExited (exitCode : Int32)
  deriving Repr, DecidableEq

/-- Per-turn OpenCode dual-channel coordination state (`SM-16`). Reset cleanly on every warm turn boundary. -/
structure OpenCodeDualChannelState where
  expectedSessionId    : String := ""
  sawSseIdle           : Bool := false
  sawStepStop          : Bool := false
  sawCliExit           : Bool := false
  cliExitCode?         : Option Int32 := none
  sawExplicitError     : Bool := false
  explicitErrorMsg     : String := ""
  turnSettledEmitted   : Bool := false
  completedCallIds     : Array String := #[]
  verdict              : OpenCodeTurnVerdict := .inProgress
  lastNormWord         : UInt64 := 0
  deriving Repr, DecidableEq

private def checkNormalizerAdmitted (w : UInt64) : Bool :=
  ((w &&& 0xFFFFFFFF) &&& 256) != 0

private def extractSessionIdFromJson? (trimmed : String) : Option String :=
  extractHarnessLineSessionId? trimmed

private def isSseSessionIdleJson (trimmed : String) : Option String :=
  match OrbBin.Json.parse trimmed with
  | .error _ => none
  | .ok jv =>
    let ty := (jv.fieldStr? "type").getD ""
    if ty == "session.idle" || ty == "session.status" then
      let statusOk :=
        if ty == "session.idle" then true
        else
          match jv.field? "properties" with
          | some p =>
            match p.field? "status" with
            | some stObj => (stObj.fieldStr? "type").getD "" == "idle"
            | none => (p.fieldStr? "status").getD "" == "idle"
          | none => false
      if statusOk then
        some ((extractSessionIdFromJson? trimmed).getD "")
      else none
    else none

/-- Recompute the authoritative `OpenCodeTurnVerdict` from latched SSE + CLI observations:
    - Non-zero CLI process exit ALWAYS dominates SSE `session.idle` (`failedCliExit`), even if SSE `session.idle`
      arrived first (`SSE idle -> CLI non-zero exit` race).
    - Explicit harness/SSE error (`TurnResult _ true msg`) dominates idle (`failedSseError` / `failedSilentStop`).
    - Silent OpenCode stop after reasoning/compaction without user text (`sawActivity && !sawUserText` on `step_finish=stop`
      or `cliExitCode = 0` + `sawActivity && !sawUserText` without assistant prose) classifies as `failedSilentStop`.
    - Clean turn completion (`completedClean`) requires zero active tool calls (`toolDepth == 0`) AND:
      either CLI exited `0` (with user text or clean result, and no error), OR (`sawSseIdle && sawStepStop` with `sawUserText`
      while CLI has not exited non-zero — note that session-level `Terminating -> Dead` still waits for `hasProcExitReceipt == 1`,
      and turn completion in CLI-managed runs requires either `sawCliExit` with `exitCode == 0` or coordinated `sawSseIdle && sawCliExit`). -/
def deriveOpenCodeTurnVerdict
    (dc : OpenCodeDualChannelState) (parser : HarnessParserState) (toolDepth : UInt32)
    (requireCliExitForTurnDone : Bool := true) : OpenCodeTurnVerdict :=
  match dc.cliExitCode? with
  | some code =>
    if code != 0 then
      let msg := if dc.explicitErrorMsg.isEmpty then s!"opencode_cli_exit_{code}" else dc.explicitErrorMsg
      .failedCliExit code msg
    else if dc.sawExplicitError then
      if (dc.explicitErrorMsg.splitOn "finished without assistant text").length > 1 then
        .failedSilentStop dc.explicitErrorMsg
      else
        .failedSseError dc.explicitErrorMsg
    else if parser.sawActivity && !parser.sawUserText &&
            !parser.emittedEvents.any (fun e => match e with | .AssistantMessage _ t => !t.trimAscii.toString.isEmpty | .TextDelta _ d => !d.trimAscii.toString.isEmpty | _ => false) then
      .failedSilentStop "OpenCode finished without assistant text (stop reason: end_turn)."
    else if toolDepth == 0 then
      .completedClean
    else
      .inProgress
  | none =>
    if dc.sawExplicitError then
      if (dc.explicitErrorMsg.splitOn "finished without assistant text").length > 1 then
        .failedSilentStop dc.explicitErrorMsg
      else
        .failedSseError dc.explicitErrorMsg
    else if !requireCliExitForTurnDone && dc.sawSseIdle && dc.sawStepStop && parser.sawUserText && toolDepth == 0 then
      .completedClean
    else
      .inProgress

/-- Pure step folding one newly-emitted `AgentEvent` from `HarnessParserState` through
    `Orb.Kernel.agentEventNormalizeStep` (`harnessKind = 3` for OpenCode) and into `HarnessSessionSliceState`. -/
def foldEmittedAgentEventIntoSession
    (harnessKind : UInt8)
    (sess : HarnessSessionSliceState)
    (dc : OpenCodeDualChannelState)
    (sessionMatches : UInt32)
    (payloadBytes : UInt32)
    (ev : AgentEvent) :
    HarnessSessionSliceState × OpenCodeDualChannelState × List HarnessSessionEffect × Option AgentEvent :=
  let maxBytes : UInt32 := 65536
  match ev with
  | .Thinking _ txt _ =>
    let nonEmpty : UInt8 := if txt.isEmpty then 0 else 1
    let w := Orb.Kernel.agentEventNormalizeStep harnessKind 2 0 nonEmpty sessionMatches 0 payloadBytes maxBytes
    if checkNormalizerAdmitted w then
      (sess, { dc with lastNormWord := w }, [], some ev)
    else
      (sess, { dc with lastNormWord := w }, [], none)
  | .TextDelta _ delta =>
    let nonEmpty : UInt8 := if delta.isEmpty then 0 else 1
    let w := Orb.Kernel.agentEventNormalizeStep harnessKind 3 0 nonEmpty sessionMatches 0 payloadBytes maxBytes
    if checkNormalizerAdmitted w then
      (sess, { dc with lastNormWord := w }, [], some ev)
    else
      (sess, { dc with lastNormWord := w }, [], none)
  | .AssistantMessage _ txt =>
    let nonEmpty : UInt8 := if txt.isEmpty then 0 else 1
    let w := Orb.Kernel.agentEventNormalizeStep harnessKind 3 1 nonEmpty sessionMatches 0 payloadBytes maxBytes
    if checkNormalizerAdmitted w then
      (sess, { dc with lastNormWord := w }, [], some ev)
    else
      (sess, { dc with lastNormWord := w }, [], none)
  | .ToolCall _ callId _ _ =>
    let isDup : UInt32 := if !callId.isEmpty && dc.completedCallIds.contains callId then 1 else 0
    let w := Orb.Kernel.agentEventNormalizeStep harnessKind 4 0 1 sessionMatches isDup payloadBytes maxBytes
    if checkNormalizerAdmitted w then
      let (sess', effs) := stepHarnessSessionSlice sess {
        opCode := HarnessSessionOp.encode .enterToolCall
        hasTurnIdleReceipt := 0
        hasProcExitReceipt := 0
        eventGeneration := sess.sessionGeneration
      }
      (sess', { dc with lastNormWord := w }, effs, some ev)
    else
      (sess, { dc with lastNormWord := w }, [], none)
  | .ToolResult _ callId _ _ =>
    let isDup : UInt32 := if !callId.isEmpty && dc.completedCallIds.contains callId then 1 else 0
    let w := Orb.Kernel.agentEventNormalizeStep harnessKind 4 1 1 sessionMatches isDup payloadBytes maxBytes
    if checkNormalizerAdmitted w && sess.toolDepth > 0 then
      let (sess', effs) := stepHarnessSessionSlice sess {
        opCode := HarnessSessionOp.encode .exitToolCall
        hasTurnIdleReceipt := 0
        hasProcExitReceipt := 0
        eventGeneration := sess.sessionGeneration
      }
      let nextCompleted := if callId.isEmpty then dc.completedCallIds else dc.completedCallIds.push callId
      (sess', { dc with completedCallIds := nextCompleted, lastNormWord := w }, effs, some ev)
    else
      (sess, { dc with lastNormWord := w }, [], none)
  | .TurnResult _ isErr msg =>
    if isErr then
      let sessGateOk : Bool := dc.expectedSessionId.isEmpty || sessionMatches == 1
      let w := Orb.Kernel.agentEventNormalizeStep harnessKind 7 1 1 sessionMatches 0 payloadBytes maxBytes
      if checkNormalizerAdmitted w && sessGateOk then
        let dc' := { dc with sawExplicitError := true, explicitErrorMsg := msg, lastNormWord := w }
        (sess, dc', [], some ev)
      else
        (sess, { dc with lastNormWord := w }, [], none)
    else
      let isDupTurn : UInt32 := if dc.sawStepStop then 1 else 0
      let w := Orb.Kernel.agentEventNormalizeStep harnessKind 6 1 1 sessionMatches isDupTurn payloadBytes maxBytes
      if checkNormalizerAdmitted w then
        let dc' := { dc with sawStepStop := true, lastNormWord := w }
        (sess, dc', [], none)
      else
        (sess, { dc with lastNormWord := w }, [], none)

/-- Pure dual-channel OpenCode reducer step (`SM-16`). Coordinates SSE sidecar frames (`session.idle`,
    `text_delta`, `reasoning`, `step_finish`, `tool_call`, `tool_result`) and CLI JSONL stdout + process exit:
    - Gates every frame through `Orb.Kernel.agentEventNormalizeStep` (`sessionMatchesExpected`, duplicate-turn/tool
      suppression, payload byte bound).
    - Never completes the turn prematurely on `session.idle` alone while CLI process is still running
      (`requireCliExitForTurnDone = true`), preventing raced `SSE session.idle` before non-zero CLI exit
      from misclassifying an errored/crashed CLI run as `completedClean`.
    - Duplicate `session.idle` or duplicate `step_finish` frames are idempotently absorbed (`isDuplicateTurnOrTool = 1`).
    - Out-of-order `CLI exit 0` before trailing SSE `session.idle` settles deterministically once CLI stdout has drained,
      and any trailing SSE `session.idle` for that turn is suppressed without double-completing or corrupting the next turn. -/
def stepOpenCodeDualChannel
    (sess : HarnessSessionSliceState)
    (parser : HarnessParserState)
    (dc : OpenCodeDualChannelState)
    (eventGeneration : UInt64)
    (inp : OpenCodeDualChannelInput)
    (requireCliExitForTurnDone : Bool := true) :
    HarnessSessionSliceState × HarnessParserState × OpenCodeDualChannelState × List HarnessSessionEffect × Array AgentEvent := Id.run do
  if sess.sessionGeneration == 0 || eventGeneration != sess.sessionGeneration || sess.phaseCode == HarnessSessionPhase.encode .dead then
    return (sess, parser, dc, [], #[])
  let mut curSess := sess
  let mut curParser := parser
  let mut curDc := dc
  let mut allEffs : List HarnessSessionEffect := []
  let mut outEvents : Array AgentEvent := #[]
  let maxBytes : UInt32 := 65536

  let processJsonLine := fun (s0 : HarnessSessionSliceState) (p0 : HarnessParserState) (d0 : OpenCodeDualChannelState)
                             (rawLine : String) (explicitSid : String) => Id.run do
    let trimmed := rawLine.trimAscii.toString
    if trimmed.isEmpty then
      return (s0, p0, d0, ([] : List HarnessSessionEffect), (#[] : Array AgentEvent))
    let lineBytes : UInt32 := (Nat.min trimmed.utf8ByteSize 0xFFFFFFFF).toUInt32
    let mut dCur := d0
    if let some idleSid := isSseSessionIdleJson trimmed then
      let idleMatch : UInt32 :=
        if idleSid.isEmpty || dCur.expectedSessionId.isEmpty || idleSid == dCur.expectedSessionId then 1 else 0
      let isDupIdle : UInt32 := if dCur.sawSseIdle then 1 else 0
      let wIdle := Orb.Kernel.agentEventNormalizeStep 3 6 1 0 idleMatch isDupIdle lineBytes maxBytes
      if checkNormalizerAdmitted wIdle then
        let boundSid :=
          if dCur.expectedSessionId.isEmpty && !idleSid.isEmpty then idleSid else dCur.expectedSessionId
        return (s0, p0, { dCur with expectedSessionId := boundSid, sawSseIdle := true, lastNormWord := wIdle }, [], #[])
      else
        return (s0, p0, { dCur with lastNormWord := wIdle }, [], #[])
    let sidOpt := if !explicitSid.isEmpty then some explicitSid else extractSessionIdFromJson? trimmed
    if dCur.expectedSessionId.isEmpty then
      if let some sid := sidOpt then
        if !sid.isEmpty then
          let wSid := Orb.Kernel.agentEventNormalizeStep 3 1 0 1 1 0 lineBytes maxBytes
          if checkNormalizerAdmitted wSid then
            dCur := { dCur with expectedSessionId := sid, lastNormWord := wSid }
          else
            dCur := { dCur with lastNormWord := wSid }
    let sessMatch : UInt32 :=
      match sidOpt with
      | none => 1
      | some sid =>
        if sid.isEmpty || dCur.expectedSessionId.isEmpty || sid == dCur.expectedSessionId then 1 else 0
    if sessMatch == 0 then
      let wRej := Orb.Kernel.agentEventNormalizeStep 3 3 0 1 0 0 lineBytes maxBytes
      return (s0, p0, { dCur with lastNormWord := wRej }, [], #[])
    if lineBytes > maxBytes then
      let wOver := Orb.Kernel.agentEventNormalizeStep 3 3 0 1 sessMatch 0 lineBytes maxBytes
      return (s0, p0, { dCur with lastNormWord := wOver }, [], #[])
    let prevCount := p0.emittedEvents.size
    let p1 := stepHarnessJsonLine p0 trimmed
    let mut sCur := s0
    let mut effAcc : List HarnessSessionEffect := []
    let mut evAcc : Array AgentEvent := #[]
    for idx in [prevCount:p1.emittedEvents.size] do
      let emitted := p1.emittedEvents[idx]!
      let (sNext, dNext, effs, ev?) := foldEmittedAgentEventIntoSession 3 sCur dCur sessMatch lineBytes emitted
      sCur := sNext
      dCur := dNext
      effAcc := effAcc ++ effs
      if let some keepEv := ev? then
        evAcc := evAcc.push keepEv
    return (sCur, p1, dCur, effAcc, evAcc)

  match inp with
  | .sseSessionIdle sid =>
    let sessMatch : UInt32 :=
      if sid.isEmpty || curDc.expectedSessionId.isEmpty || sid == curDc.expectedSessionId then 1 else 0
    let isDup : UInt32 := if curDc.sawSseIdle then 1 else 0
    let w := Orb.Kernel.agentEventNormalizeStep 3 6 1 0 sessMatch isDup 32 maxBytes
    curDc := { curDc with lastNormWord := w }
    if checkNormalizerAdmitted w then
      let boundSid :=
        if curDc.expectedSessionId.isEmpty && !sid.isEmpty then sid else curDc.expectedSessionId
      curDc := { curDc with expectedSessionId := boundSid, sawSseIdle := true }
  | .sseChunk sid ssePayload =>
    for rawLine in ssePayload.splitOn "\n" do
      let ln := rawLine.trimAscii.toString
      if ln.startsWith "data:" then
        let dataPart := (ln.drop 5).trimAscii.toString
        if dataPart != "" && dataPart != "[DONE]" then
          let (sNext, pNext, dNext, effs, evs) := processJsonLine curSess curParser curDc dataPart sid
          curSess := sNext
          curParser := pNext
          curDc := dNext
          allEffs := allEffs ++ effs
          outEvents := outEvents ++ evs
  | .cliJsonLine line =>
    let (sNext, pNext, dNext, effs, evs) := processJsonLine curSess curParser curDc line ""
    curSess := sNext
    curParser := pNext
    curDc := dNext
    allEffs := allEffs ++ effs
    outEvents := outEvents ++ evs
  | .cliProcessExited exitCode =>
    if !curDc.sawCliExit then
      curDc := { curDc with sawCliExit := true, cliExitCode? := some exitCode }
      -- Reconcile any unclosed tool calls on abrupt process exit so `toolDepth` cannot stay wedged > 0.
      while curSess.phaseCode == HarnessSessionPhase.encode .inTurn && curSess.toolDepth > 0 do
        let (sExitTool, effTool) := stepHarnessSessionSlice curSess {
          opCode := HarnessSessionOp.encode .exitToolCall
          hasTurnIdleReceipt := 0
          hasProcExitReceipt := 0
          eventGeneration := eventGeneration
        }
        if sExitTool == curSess then break
        curSess := sExitTool
        allEffs := allEffs ++ effTool
      curParser := { curParser with pendingCalls := #[] }
      if curSess.phaseCode == HarnessSessionPhase.encode .terminating then
        let (sDead, effDead) := stepHarnessSessionSlice curSess {
          opCode := HarnessSessionOp.encode .confirmProcessDead
          hasTurnIdleReceipt := 0
          hasProcExitReceipt := 1
          eventGeneration := eventGeneration
        }
        curSess := sDead
        allEffs := allEffs ++ effDead

  let nextVerdict := deriveOpenCodeTurnVerdict curDc curParser curSess.toolDepth requireCliExitForTurnDone
  curDc := { curDc with verdict := nextVerdict }

  if !curDc.turnSettledEmitted then
    match nextVerdict with
    | .inProgress => pure ()
    | .completedClean =>
      if curSess.phaseCode == HarnessSessionPhase.encode .inTurn && curSess.toolDepth == 0 && curSess.steerPending == 0 then
        let (sReady, effReady) := stepHarnessSessionSlice curSess {
          opCode := HarnessSessionOp.encode .finishTurnToReady
          hasTurnIdleReceipt := 1
          hasProcExitReceipt := if curDc.sawCliExit then 1 else 0
          eventGeneration := eventGeneration
        }
        if sReady.phaseCode == HarnessSessionPhase.encode .ready then
          curSess := sReady
          allEffs := allEffs ++ effReady
          curDc := { curDc with turnSettledEmitted := true }
          outEvents := outEvents.push (.TurnResult curParser.missionId false "end_turn")
    | .failedSilentStop msg =>
      curDc := { curDc with turnSettledEmitted := true }
      if !outEvents.any (fun e => match e with | .TurnResult _ true _ => true | _ => false) then
        outEvents := outEvents.push (.TurnResult curParser.missionId true msg)
    | .failedCliExit _ msg =>
      curDc := { curDc with turnSettledEmitted := true }
      outEvents := outEvents.push (.TurnResult curParser.missionId true msg)
    | .failedSseError msg =>
      curDc := { curDc with turnSettledEmitted := true }
      if !outEvents.any (fun e => match e with | .TurnResult _ true _ => true | _ => false) then
        outEvents := outEvents.push (.TurnResult curParser.missionId true msg)

  return (curSess, curParser, curDc, allEffs, outEvents)

/-! ## 4. `SM-15`: Generation-Owned `HarnessSessionHandle` & Registry -/

/-- Reset per-turn latches on warm turn transitions (`beginTurn`, `finishTurnToReady`, `parkSession`, `wakeParkedSession`)
    so flags from turn `N` (`sawUserText`, `sawActivity`, `emittedEvents`, `pendingCalls`, OpenCode dual-channel latches)
    NEVER leak into turn `N + 1` (`SM-15`). Preserves `expectedSessionId` across warm turns of the same process. -/
def resetWarmTurnLatches (parser : HarnessParserState) (dc : OpenCodeDualChannelState) :
    HarnessParserState × OpenCodeDualChannelState :=
  let cleanParser : HarnessParserState := {
    missionId := parser.missionId
    pendingCalls := #[]
    emittedEvents := #[]
    sawUserText := false
    sawActivity := false
  }
  let cleanDc : OpenCodeDualChannelState := {
    expectedSessionId := dc.expectedSessionId
    sawSseIdle := false
    sawStepStop := false
    sawCliExit := false
    cliExitCode? := none
    sawExplicitError := false
    explicitErrorMsg := ""
    turnSettledEmitted := false
    completedCallIds := #[]
    verdict := .inProgress
    lastNormWord := 0
  }
  (cleanParser, cleanDc)

/-- Authoritative mutable payload inside a generation-owned `HarnessSessionHandle` (`SM-15`). -/
structure HarnessSessionInner where
  slice        : HarnessSessionSliceState
  turnOrdinal  : UInt64 := 0
  modelEffort  : String := ""
  sessionId    : String := ""
  parser       : HarnessParserState
  openCode     : OpenCodeDualChannelState := {}
  procExited   : Bool := false
  lastExitCode : Option Int32 := none
  deriving Repr, DecidableEq

/-- Generation-owned handle for an active harness process (`SM-15`, `SM-16`, `SM-17`).
    Replaces scattered `PARKED` / `MIDTURN` / `EFFORT` / `HARNESS_PIDS` maps and 12 manual turn booleans.
    `killHandle?` is stored IMMUTABLY outside `mu` so teardown/drop/cancel can reap the child process group
    immediately even while `mu` is held by an in-flight turn reader (`SM-17`). -/
structure HarnessSessionHandle where
  missionId         : String
  backend           : HarnessBackendKind
  sessionGeneration : UInt64
  killHandle?       : Option ProcessKillHandle := none
  mu                : Std.Mutex HarnessSessionInner

/-- Registry mapping `missionId` to its single active generation-owned `HarnessSessionHandle`. -/
structure HarnessSessionRegistry where
  mu : Std.Mutex (Std.HashMap String HarnessSessionHandle)

def newHarnessSessionRegistry : IO HarnessSessionRegistry := do
  let mu ← Std.Mutex.new ({} : Std.HashMap String HarnessSessionHandle)
  return { mu }

def mkHarnessSessionHandle
    (missionId : String)
    (backend : HarnessBackendKind)
    (sessionGeneration : UInt64)
    (modelEffort : String := "")
    (killHandle? : Option ProcessKillHandle := none) : IO (Except String HarnessSessionHandle) := do
  if missionId.trimAscii.toString.isEmpty then
    return .error "empty_mission_id"
  if sessionGeneration == 0 then
    return .error "zero_session_generation"
  let initInner : HarnessSessionInner := {
    slice := {
      phaseCode := HarnessSessionPhase.encode .starting
      steerPending := 0
      toolDepth := 0
      sessionGeneration := sessionGeneration
    }
    turnOrdinal := 0
    modelEffort := modelEffort
    sessionId := ""
    parser := { missionId := missionId }
    openCode := {}
    procExited := false
    lastExitCode := none
  }
  let mu ← Std.Mutex.new initInner
  return .ok {
    missionId := missionId
    backend := backend
    sessionGeneration := sessionGeneration
    killHandle? := killHandle?
    mu := mu
  }

/-- Non-blocking / non-contended process kill on a `HarnessSessionHandle` (`SM-17`).
    Does NOT touch `handle.mu`, so a contended or wedged turn mutex NEVER prevents child process reaping. -/
def forceKillHandleNonBlocking (handle : HarnessSessionHandle) (sig : Int32 := 15) : IO ProcessKillVerdict := do
  match handle.killHandle? with
  | none    => return .skippedInvalidHandle
  | some kh => reapWithKillHandle kh sig

/-- Register a fresh generation-owned `HarnessSessionHandle` for `missionId`.
    Rejects stale or duplicate generations (`newGen <= prev.sessionGeneration`); if superseding an older
    generation whose process has not yet been reaped, fires its non-contended `ProcessKillHandle` outside its state lock. -/
def registerSessionHandle
    (reg : HarnessSessionRegistry)
    (missionId : String)
    (backend : HarnessBackendKind)
    (sessionGeneration : UInt64)
    (modelEffort : String := "")
    (killHandle? : Option ProcessKillHandle := none) : IO (Except String HarnessSessionHandle) := do
  let fresh ← match ← mkHarnessSessionHandle missionId backend sessionGeneration modelEffort killHandle? with
    | .error e => return .error e
    | .ok h    => pure h
  let res : Except String (Option HarnessSessionHandle) ← reg.mu.atomically do
    let map ← get
    match map.get? missionId with
    | some prev =>
      if sessionGeneration ≤ prev.sessionGeneration then
        return Except.error s!"stale_or_duplicate_session_generation:{sessionGeneration}<={prev.sessionGeneration}"
      set (map.insert missionId fresh)
      return Except.ok (some prev)
    | none =>
      set (map.insert missionId fresh)
      return Except.ok none
  match res with
  | .error e => return .error e
  | .ok prev? =>
    if let some prev := prev? then
      discard <| forceKillHandleNonBlocking prev 15
    return .ok fresh

def lookupSessionHandle? (reg : HarnessSessionRegistry) (missionId : String) : IO (Option HarnessSessionHandle) :=
  reg.mu.atomically do
    let map ← get
    return map.get? missionId

def inspectSessionInner (handle : HarnessSessionHandle) : IO HarnessSessionInner :=
  handle.mu.atomically get

/-- Apply an authoritative `HarnessSessionOp` transition to `handle`, enforcing `Orb.HarnessCloud.stepHarnessSessionSlice`
    fencing (`eventGeneration == sessionGeneration`), resetting warm-turn parser/activity latches on turn boundaries,
    and executing non-contended process-group kill when `signalProcessGroupKill` is emitted. -/
def applySessionOp
    (handle : HarnessSessionHandle)
    (op : HarnessSessionOp)
    (eventGeneration : UInt64)
    (hasTurnIdleReceipt : Bool := false)
    (hasProcExitReceipt : Bool := false)
    (exitCode? : Option Int32 := none) :
    IO (Except String (HarnessSessionInner × List HarnessSessionEffect)) := do
  let stepRes : Except String (HarnessSessionInner × List HarnessSessionEffect) ← handle.mu.atomically do
    let st ← get
    let effProcExit : UInt8 := if hasProcExitReceipt || st.procExited then 1 else 0
    let effIdle : UInt8 := if hasTurnIdleReceipt then 1 else 0
    let opCode := op.encode
    if verifyHarnessSessionAdmit st.slice.phaseCode opCode st.slice.steerPending
         effIdle effProcExit st.slice.toolDepth st.slice.sessionGeneration eventGeneration != 1 then
      return Except.error s!"harness_session_op_rejected:phase={st.slice.phaseCode}:op={opCode}:depth={st.slice.toolDepth}:steer={st.slice.steerPending}:gen={eventGeneration}/{st.slice.sessionGeneration}"
    let (nextSlice, effs) := stepHarnessSessionSlice st.slice {
      opCode := opCode
      hasTurnIdleReceipt := effIdle
      hasProcExitReceipt := effProcExit
      eventGeneration := eventGeneration
    }
    let resetBoundary : Bool :=
      op == .beginTurn || op == .finishTurnToReady || op == .parkSession || op == .wakeParkedSession
    let (nextParser, nextOc) :=
      if resetBoundary then resetWarmTurnLatches st.parser st.openCode
      else (st.parser, st.openCode)
    let nextOrdinal := if op == .beginTurn then st.turnOrdinal + 1 else st.turnOrdinal
    let nextExited := st.procExited || hasProcExitReceipt
    let nextExitCode := match exitCode? with | some c => some c | none => st.lastExitCode
    let nextInner : HarnessSessionInner := {
      st with
      slice := nextSlice
      turnOrdinal := nextOrdinal
      parser := nextParser
      openCode := nextOc
      procExited := nextExited
      lastExitCode := nextExitCode
    }
    set nextInner
    return Except.ok (nextInner, effs)
  match stepRes with
  | .error e => return .error e
  | .ok (nextInner, effs) =>
    if effs.any (fun e => match e with | .signalProcessGroupKill _ => true | _ => false) then
      discard <| forceKillHandleNonBlocking handle 15
    return .ok (nextInner, effs)

/-- Feed a dual-channel OpenCode input (`SSE` or `CLI`) into a generation-owned `HarnessSessionHandle` (`SM-16`). -/
def stepOpenCodeHandleInput
    (handle : HarnessSessionHandle)
    (eventGeneration : UInt64)
    (inp : OpenCodeDualChannelInput)
    (requireCliExitForTurnDone : Bool := true) :
    IO (Except String (HarnessSessionInner × List HarnessSessionEffect × Array AgentEvent)) := do
  if handle.backend != .openCode then
    return .error s!"invalid_backend_for_opencode_dual_channel:{handle.backend.asString}"
  handle.mu.atomically do
    let st ← get
    if eventGeneration != st.slice.sessionGeneration then
      return .error s!"stale_event_generation:{eventGeneration}!={st.slice.sessionGeneration}"
    let (nextSlice, nextParser, nextOc, effs, outEvs) :=
      stepOpenCodeDualChannel st.slice st.parser st.openCode eventGeneration inp requireCliExitForTurnDone
    let nextExited := match inp with | .cliProcessExited _ => true | _ => st.procExited
    let nextExitCode := match inp with | .cliProcessExited c => some c | _ => st.lastExitCode
    let nextSid := if !nextOc.expectedSessionId.isEmpty then nextOc.expectedSessionId else st.sessionId
    let nextInner : HarnessSessionInner := {
      st with
      slice := nextSlice
      sessionId := nextSid
      parser := nextParser
      openCode := nextOc
      procExited := nextExited
      lastExitCode := nextExitCode
    }
    set nextInner
    return .ok (nextInner, effs, outEvs)

/-- Feed a standard JSONL or Vibe ACP harness line (Claude Code, Codex, Grok, Antigravity, Vibe) into `handle`,
    extracting and binding/fencing session identity via `Orb.Kernel.agentEventNormalizeStep` and updating
    `toolDepth` (`enterToolCall` / `exitToolCall`) through `stepHarnessSessionSlice` (`SM-15`). -/
def stepStandardHarnessLine
    (handle : HarnessSessionHandle)
    (eventGeneration : UInt64)
    (line : String) :
    IO (Except String (HarnessSessionInner × List HarnessSessionEffect × Array AgentEvent)) := do
  handle.mu.atomically do
    let st ← get
    if eventGeneration != st.slice.sessionGeneration then
      return .error s!"stale_event_generation:{eventGeneration}!={st.slice.sessionGeneration}"
    if st.slice.phaseCode != HarnessSessionPhase.encode .inTurn then
      return .error s!"harness_not_in_turn:phase={st.slice.phaseCode}"
    let trimmed := line.trimAscii.toString
    if trimmed.isEmpty then
      return .ok (st, [], #[])
    let maxBytes : UInt32 := 65536
    let lineBytes : UInt32 := (Nat.min trimmed.utf8ByteSize 0xFFFFFFFF).toUInt32
    let hCode := handle.backend.code
    if lineBytes > maxBytes then
      let wOver := Orb.Kernel.agentEventNormalizeStep hCode 3 0 1 1 0 lineBytes maxBytes
      let nextInner : HarnessSessionInner := {
        st with
        openCode := { st.openCode with lastNormWord := wOver }
      }
      set nextInner
      return .ok (nextInner, [], #[])

    -- Synchronize initial bound session identity between `st.sessionId` and `st.openCode.expectedSessionId`.
    let mut curDc :=
      if st.openCode.expectedSessionId.isEmpty && !st.sessionId.isEmpty then
        { st.openCode with expectedSessionId := st.sessionId }
      else
        st.openCode

    let vibeParsed? : Option (String × AgentEvent) :=
      if handle.backend == .vibe then parseVibeAcpNotification? trimmed else none

    let lineSid? : Option String :=
      match vibeParsed? with
      | some (vSid, _) =>
        if !vSid.isEmpty && vSid != "vibe-session" then some vSid
        else extractHarnessLineSessionId? trimmed
      | none =>
        extractHarnessLineSessionId? trimmed

    if curDc.expectedSessionId.isEmpty then
      if let some sid := lineSid? then
        if !sid.isEmpty then
          let wSid := Orb.Kernel.agentEventNormalizeStep hCode 1 0 1 1 0 lineBytes maxBytes
          if checkNormalizerAdmitted wSid then
            curDc := { curDc with expectedSessionId := sid, lastNormWord := wSid }
          else
            curDc := { curDc with lastNormWord := wSid }

    let sessMatch : UInt32 :=
      match lineSid? with
      | none => 1
      | some sid =>
        if sid.isEmpty || curDc.expectedSessionId.isEmpty || sid == curDc.expectedSessionId then 1 else 0

    if sessMatch == 0 then
      let wRej := Orb.Kernel.agentEventNormalizeStep hCode 3 0 1 0 0 lineBytes maxBytes
      let nextInner : HarnessSessionInner := {
        st with
        sessionId := if !curDc.expectedSessionId.isEmpty then curDc.expectedSessionId else st.sessionId
        openCode := { curDc with lastNormWord := wRej }
      }
      set nextInner
      return .ok (nextInner, [], #[])

    let mut curSlice := st.slice
    let mut effAcc : List HarnessSessionEffect := []
    let mut evAcc : Array AgentEvent := #[]
    let mut nextParser := st.parser

    match vibeParsed? with
    | some (_, rawVibeEv) =>
      let rewrittenEv : AgentEvent :=
        match rawVibeEv with
        | .TextDelta _ d       => .TextDelta handle.missionId d
        | .Thinking _ c done   => .Thinking handle.missionId c done
        | .ToolCall _ cid nm argsJson => .ToolCall handle.missionId cid nm argsJson
        | .ToolResult _ c n o  => .ToolResult handle.missionId c n o
        | .AssistantMessage _ t => .AssistantMessage handle.missionId t
        | .TurnResult _ err m  => .TurnResult handle.missionId err m
      let (sNext, dNext, effs, ev?) :=
        foldEmittedAgentEventIntoSession hCode curSlice curDc sessMatch lineBytes rewrittenEv
      curSlice := sNext
      curDc := dNext
      effAcc := effAcc ++ effs
      if let some keep := ev? then
        evAcc := evAcc.push keep
        nextParser := {
          nextParser with
          sawActivity := true
          sawUserText := nextParser.sawUserText ||
            (match keep with | .TextDelta _ d => !d.trimAscii.toString.isEmpty | .AssistantMessage _ t => !t.trimAscii.toString.isEmpty | _ => false)
          emittedEvents := nextParser.emittedEvents.push keep
        }
    | none =>
      let prevCount := st.parser.emittedEvents.size
      let p1 := stepHarnessJsonLine st.parser trimmed
      nextParser := p1
      for idx in [prevCount:p1.emittedEvents.size] do
        let ev := p1.emittedEvents[idx]!
        let (sNext, dNext, effs, ev?) :=
          foldEmittedAgentEventIntoSession hCode curSlice curDc sessMatch lineBytes ev
        curSlice := sNext
        curDc := dNext
        effAcc := effAcc ++ effs
        if let some keep := ev? then
          evAcc := evAcc.push keep

    let nextSid := if !curDc.expectedSessionId.isEmpty then curDc.expectedSessionId else st.sessionId
    let nextInner : HarnessSessionInner := {
      st with
      slice := curSlice
      sessionId := nextSid
      parser := nextParser
      openCode := curDc
    }
    set nextInner
    return .ok (nextInner, effAcc, evAcc)

/-- Remove a `Dead` session handle from `reg` if its generation matches `expectedGen`. Refuses to evict a live handle. -/
def retireDeadSessionHandle (reg : HarnessSessionRegistry) (missionId : String) (expectedGen : UInt64) : IO Bool := do
  let cand? ← lookupSessionHandle? reg missionId
  match cand? with
  | none => return false
  | some h =>
    if h.sessionGeneration != expectedGen then return false
    let inner ← inspectSessionInner h
    if inner.slice.phaseCode != HarnessSessionPhase.encode .dead then
      return false
    reg.mu.atomically do
      let map ← get
      match map.get? missionId with
      | some cur =>
        if cur.sessionGeneration == expectedGen then
          set (map.erase missionId)
          return true
        else
          return false
      | none => return false

/-! ## 5. `SM-17`: Durable `(session_id, prompt_claim, tool_journal)` Continuity Store (Codex / Grok / Vibe) -/

inductive PromptClaimPhase where
  | none
  | claimed
  | delivered
  | uncertain
  deriving Repr, DecidableEq, BEq

def PromptClaimPhase.asString : PromptClaimPhase → String
  | .none      => "none"
  | .claimed   => "claimed"
  | .delivered => "delivered"
  | .uncertain => "uncertain"

def PromptClaimPhase.ofString? : String → Option PromptClaimPhase
  | "none" | "" => some .none
  | "claimed"   => some .claimed
  | "delivered" => some .delivered
  | "uncertain" => some .uncertain
  | _           => none

inductive ToolJournalPhase where
  | started
  | completed
  | crashTombstone
  deriving Repr, DecidableEq, BEq

def ToolJournalPhase.asString : ToolJournalPhase → String
  | .started        => "started"
  | .completed      => "completed"
  | .crashTombstone => "crash_tombstone"

def ToolJournalPhase.ofString? : String → Option ToolJournalPhase
  | "started"         => some .started
  | "completed"       => some .completed
  | "crash_tombstone" => some .crashTombstone
  | _                 => none

structure ToolJournalEntry where
  callId     : String
  toolName   : String
  phase      : ToolJournalPhase
  outputHash : String := ""
  deriving Repr, DecidableEq

def ToolJournalEntry.toJson (e : ToolJournalEntry) : JVal :=
  .obj #[ ("call_id", .str e.callId)
        , ("tool_name", .str e.toolName)
        , ("phase", .str e.phase.asString)
        , ("output_hash", .str e.outputHash) ]

def ToolJournalEntry.fromJson? (v : JVal) : Option ToolJournalEntry := do
  let callId ← v.fieldStr? "call_id"
  let toolName ← v.fieldStr? "tool_name"
  let phaseStr ← v.fieldStr? "phase"
  let phase ← ToolJournalPhase.ofString? phaseStr
  let outputHash := (v.fieldStr? "output_hash").getD ""
  return { callId, toolName, phase, outputHash }

private def serializeToolJournal (entries : Array ToolJournalEntry) : String :=
  OrbBin.Json.renderCompact (.arr (entries.map ToolJournalEntry.toJson))

private def parseToolJournal (raw : String) : Except String (Array ToolJournalEntry) := do
  let trimmed := raw.trimAscii.toString
  if trimmed.isEmpty then return #[]
  let jv ← OrbBin.Json.parse trimmed
  match jv with
  | .arr items =>
    let mut out : Array ToolJournalEntry := Array.mkEmpty items.size
    for item in items do
      match ToolJournalEntry.fromJson? item with
      | some entry => out := out.push entry
      | none => throw "corrupt_tool_journal_entry"
    return out
  | _ => throw "corrupt_tool_journal_root"

structure HarnessContinuityRecord where
  missionId          : String
  backend            : HarnessBackendKind
  sessionGeneration  : UInt64
  sessionId          : String
  promptClaimId      : String
  promptClaimPhase   : PromptClaimPhase
  toolJournal        : Array ToolJournalEntry
  reconcileRequired  : Bool
  stateRevision      : UInt64
  updatedAt          : String
  deriving Repr, DecidableEq

/-- Reconciliation outcome loaded across Core / locald restarts (`SM-17`). -/
inductive ContinuityReconcileOutcome where
  | cleanReady (record : HarnessContinuityRecord)
  | requiresReconciliation (record : HarnessContinuityRecord) (reason : String)
  deriving Repr, DecidableEq

def harnessContinuitySchemaSql : String :=
  OrbCore.Store.harnessContinuitySchemaSql

def harnessContinuityIndexSql : String :=
  OrbCore.Store.harnessContinuityIndexSql

/-- Schema bootstrap for `harness_continuity` that must run only while `db.mu` is already held
    (including inside `withImmediateTx`), matching `OrbCore.CloudAgents.ensureCloudTurnSchemaUnlocked`. -/
def ensureHarnessContinuitySchemaUnlocked (db : SqliteDb) : IO (Except String Unit) := do
  if let .error e ← execParamQueryUnlocked db harnessContinuitySchemaSql #[] then
    return .error e
  let idxRes ← execParamQueryUnlocked db harnessContinuityIndexSql #[]
  return idxRes.map (fun _ => ())

/-- Initialize the durable `harness_continuity` table and index on `db` (`missions.db`) via separate
    single-statement `execParamQueryUnlocked` calls under `db.mu`. -/
def ensureHarnessContinuitySchema (db : SqliteDb) : IO (Except String Unit) :=
  db.mu.atomically (ensureHarnessContinuitySchemaUnlocked db)

/-- Execute a single-row guarded SQLite `UPDATE` inside an active `withImmediateTx` transaction and verify
    `SELECT changes(); == 1`. Any `0`-row (or multi-row) match returns `cas_conflict` so `withImmediateTx`
    rolls back cleanly without ever returning an unwritten revision or claiming a lost CAS succeeded. -/
private def execCasUpdateOneRowUnlocked
    (db : SqliteDb)
    (sql : String)
    (params : Array String)
    (conflictTag : String) : IO (Except String Unit) := do
  let upd ← execParamQueryUnlocked db sql params
  match upd with
  | .error e => return .error e
  | .ok _ =>
    let chg ← execParamQueryUnlocked db "SELECT changes();" #[]
    match chg with
    | .error e => return .error s!"cas_changes_failed:{e}"
    | .ok crs =>
      let n := ((crs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
      if n == 1 then
        return .ok ()
      else
        return .error s!"cas_conflict:{conflictTag}:changes={n}"

/-- Execute a single-row guarded SQLite `UPDATE` on `harness_continuity` at `expectedRevision` inside an active
    `withImmediateTx` transaction (`BEGIN IMMEDIATE`) and verify `SELECT changes(); == 1`.
    Any `0`-row match returns `cas_conflict` so `withImmediateTx` rolls back cleanly without ever returning
    an unwritten revision as `.ok`. Exposed for deterministic `0`-row CAS conflict testing in `SelfTest`. -/
def commitHarnessContinuityCas
    (db : SqliteDb)
    (missionId : String)
    (expectedRevision : UInt64)
    (nextBackend : HarnessBackendKind)
    (nextGeneration : UInt64)
    (nextSessionId : String)
    (nextClaimId : String)
    (nextClaimPhase : PromptClaimPhase)
    (nextToolJournal : Array ToolJournalEntry)
    (nextReconcileRequired : Bool)
    (nowAt : String)
    (conflictTag : String := "continuity_cas") : IO (Except String HarnessContinuityRecord) := do
  if missionId.trimAscii.toString.isEmpty || nextGeneration == 0 || expectedRevision == 0 then
    return .error "invalid_continuity_cas_args"
  let nextRev := expectedRevision + 1
  let nextJson := serializeToolJournal nextToolJournal
  let recFlag := if nextReconcileRequired then "1" else "0"
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let upd ← execCasUpdateOneRowUnlocked db
      "UPDATE harness_continuity SET backend=?2, session_generation=?3, session_id=?4, prompt_claim_id=?5, prompt_claim_phase=?6, tool_journal_json=?7, reconcile_required=?8, state_revision=?9, updated_at=?10 WHERE mission_id=?1 AND state_revision=?11;"
      #[missionId, nextBackend.asString, s!"{nextGeneration}", nextSessionId, nextClaimId, nextClaimPhase.asString, nextJson, recFlag, s!"{nextRev}", nowAt, s!"{expectedRevision}"]
      s!"{conflictTag}:expected={expectedRevision}"
    match upd with
    | .error e => return .error e
    | .ok () =>
      return .ok {
        missionId := missionId
        backend := nextBackend
        sessionGeneration := nextGeneration
        sessionId := nextSessionId
        promptClaimId := nextClaimId
        promptClaimPhase := nextClaimPhase
        toolJournal := nextToolJournal
        reconcileRequired := nextReconcileRequired
        stateRevision := nextRev
        updatedAt := nowAt
      }

private def decodeContinuityRow (r : Array String) : Except String HarnessContinuityRecord := do
  if r.size < 10 then throw "continuity_row_short"
  let missionId := r[0]!
  let some backend := HarnessBackendKind.ofString? r[1]!
    | throw s!"unknown_continuity_backend:{r[1]!}"
  let some genNat := r[2]!.toNat?
    | throw s!"invalid_continuity_generation:{r[2]!}"
  let sessionId := r[3]!
  let claimId := r[4]!
  let some claimPhase := PromptClaimPhase.ofString? r[5]!
    | throw s!"invalid_prompt_claim_phase:{r[5]!}"
  let journal ← parseToolJournal r[6]!
  let recReq := r[7]! == "1"
  let some revNat := r[8]!.toNat?
    | throw s!"invalid_continuity_revision:{r[8]!}"
  let updatedAt := r[9]!
  return {
    missionId := missionId
    backend := backend
    sessionGeneration := genNat.toUInt64
    sessionId := sessionId
    promptClaimId := claimId
    promptClaimPhase := claimPhase
    toolJournal := journal
    reconcileRequired := recReq
    stateRevision := revNat.toUInt64
    updatedAt := updatedAt
  }

def loadHarnessContinuity? (db : SqliteDb) (missionId : String) : IO (Except String (Option HarnessContinuityRecord)) :=
  db.mu.atomically do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok none
      match decodeContinuityRow rows[1]! with
      | .ok rec => return .ok (some rec)
      | .error e => return .error e

/-- Bind or advance a `(missionId, backend, sessionGeneration, sessionId)` continuity record (`SM-17`).
    Rejects stale `sessionGeneration < existing.sessionGeneration` fail-closed, and refuses to silently
    overwrite an unreconciled `claimed` / `uncertain` prompt claim without explicit reconciliation. -/
def bindHarnessContinuitySession
    (db : SqliteDb)
    (missionId : String)
    (backend : HarnessBackendKind)
    (sessionGeneration : UInt64)
    (sessionId : String)
    (nowAt : String) : IO (Except String HarnessContinuityRecord) := do
  if missionId.trimAscii.toString.isEmpty || sessionGeneration == 0 then
    return .error "invalid_continuity_identity"
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then
        let ins ← execParamQueryUnlocked db
          "INSERT INTO harness_continuity(mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at) VALUES(?1,?2,?3,?4,'','none','[]',0,1,?5);"
          #[missionId, backend.asString, s!"{sessionGeneration}", sessionId, nowAt]
        match ins with
        | .error e => return .error e
        | .ok _ =>
          return .ok {
            missionId := missionId
            backend := backend
            sessionGeneration := sessionGeneration
            sessionId := sessionId
            promptClaimId := ""
            promptClaimPhase := .none
            toolJournal := #[]
            reconcileRequired := false
            stateRevision := 1
            updatedAt := nowAt
          }
      else
        match decodeContinuityRow rows[1]! with
        | .error e => return .error e
        | .ok cur =>
          if sessionGeneration < cur.sessionGeneration then
            return .error s!"stale_continuity_generation:{sessionGeneration}<{cur.sessionGeneration}"
          if cur.reconcileRequired || cur.promptClaimPhase == .claimed || cur.promptClaimPhase == .uncertain then
            return .error "native_continuity_required"
          let effSid := if sessionId.isEmpty then cur.sessionId else sessionId
          let nextRev := cur.stateRevision + 1
          let upd ← execCasUpdateOneRowUnlocked db
            "UPDATE harness_continuity SET backend=?2, session_generation=?3, session_id=?4, state_revision=?5, updated_at=?6 WHERE mission_id=?1 AND state_revision=?7;"
            #[missionId, backend.asString, s!"{sessionGeneration}", effSid, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
            s!"bind_continuity:expected={cur.stateRevision}"
          match upd with
          | .error e => return .error e
          | .ok () =>
            return .ok {
              cur with
              backend := backend
              sessionGeneration := sessionGeneration
              sessionId := effSid
              stateRevision := nextRev
              updatedAt := nowAt
            }

/-- Durable pre-dispatch prompt claim (`SM-17` for Codex / Grok / Vibe).
    Persists `(prompt_claim_id, 'claimed')` with `state_revision` CAS BEFORE sending the turn over stdio/RPC.
    Duplicate replay of the already-delivered `claimId` is rejected idempotently; attempting a fresh claim while
    a prior claim is still `claimed` or `uncertain` fails closed with `native_continuity_required`. -/
def claimHarnessPrompt
    (db : SqliteDb)
    (missionId : String)
    (sessionGeneration : UInt64)
    (claimId : String)
    (nowAt : String) : IO (Except String HarnessContinuityRecord) := do
  if claimId.trimAscii.toString.isEmpty || sessionGeneration == 0 then
    return .error "invalid_prompt_claim"
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then
        return .error "continuity_session_not_bound"
      match decodeContinuityRow rows[1]! with
      | .error e => return .error e
      | .ok cur =>
        if sessionGeneration != cur.sessionGeneration then
          return .error s!"continuity_generation_mismatch:{sessionGeneration}!={cur.sessionGeneration}"
        if cur.reconcileRequired || cur.promptClaimPhase == .uncertain then
          return .error "native_continuity_required"
        if cur.promptClaimPhase == .claimed then
          if cur.promptClaimId == claimId then
            return .error "duplicate_inflight_prompt_claim"
          else
            return .error "native_continuity_required"
        if cur.promptClaimPhase == .delivered && cur.promptClaimId == claimId then
          return .error "duplicate_delivered_prompt_claim"
        let nextRev := cur.stateRevision + 1
        let upd ← execCasUpdateOneRowUnlocked db
          "UPDATE harness_continuity SET prompt_claim_id=?2, prompt_claim_phase='claimed', state_revision=?3, updated_at=?4 WHERE mission_id=?1 AND state_revision=?5;"
          #[missionId, claimId, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
          s!"claim_prompt:expected={cur.stateRevision}"
        match upd with
        | .error e => return .error e
        | .ok () =>
          return .ok {
            cur with
            promptClaimId := claimId
            promptClaimPhase := .claimed
            stateRevision := nextRev
            updatedAt := nowAt
          }

/-- Commit post-ack prompt delivery (`claimed -> delivered`) and optionally bind discovered native `sessionId` (`SM-17`). -/
def confirmHarnessPromptDelivered
    (db : SqliteDb)
    (missionId : String)
    (sessionGeneration : UInt64)
    (claimId : String)
    (discoveredSessionId : String := "")
    (nowAt : String) : IO (Except String HarnessContinuityRecord) := do
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .error "continuity_session_not_bound"
      match decodeContinuityRow rows[1]! with
      | .error e => return .error e
      | .ok cur =>
        if sessionGeneration != cur.sessionGeneration then
          return .error s!"continuity_generation_mismatch:{sessionGeneration}!={cur.sessionGeneration}"
        if cur.promptClaimId != claimId then
          return .error s!"prompt_claim_id_mismatch:{claimId}!={cur.promptClaimId}"
        if cur.promptClaimPhase == .delivered && !cur.reconcileRequired then
          return .ok cur
        if cur.promptClaimPhase != .claimed && cur.promptClaimPhase != .uncertain then
          return .error s!"invalid_prompt_claim_transition:{cur.promptClaimPhase.asString}"
        let effSid := if discoveredSessionId.isEmpty then cur.sessionId else discoveredSessionId
        let nextRev := cur.stateRevision + 1
        let upd ← execCasUpdateOneRowUnlocked db
          "UPDATE harness_continuity SET session_id=?2, prompt_claim_phase='delivered', reconcile_required=0, state_revision=?3, updated_at=?4 WHERE mission_id=?1 AND state_revision=?5;"
          #[missionId, effSid, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
          s!"confirm_prompt_delivered:expected={cur.stateRevision}"
        match upd with
        | .error e => return .error e
        | .ok () =>
          return .ok {
            cur with
            sessionId := effSid
            promptClaimPhase := .delivered
            reconcileRequired := false
            stateRevision := nextRev
            updatedAt := nowAt
          }

/-- Record a tool call start or completion in the single authoritative `tool_journal_json` column (`SM-17`). -/
def recordHarnessToolJournal
    (db : SqliteDb)
    (missionId : String)
    (sessionGeneration : UInt64)
    (entry : ToolJournalEntry)
    (nowAt : String) : IO (Except String HarnessContinuityRecord) := do
  if entry.callId.trimAscii.toString.isEmpty || entry.toolName.trimAscii.toString.isEmpty then
    return .error "invalid_tool_journal_entry"
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .error "continuity_session_not_bound"
      match decodeContinuityRow rows[1]! with
      | .error e => return .error e
      | .ok cur =>
        if sessionGeneration != cur.sessionGeneration then
          return .error s!"continuity_generation_mismatch:{sessionGeneration}!={cur.sessionGeneration}"
        let mut found := false
        let mut updated : Array ToolJournalEntry := Array.mkEmpty (cur.toolJournal.size + 1)
        for existing in cur.toolJournal do
          if existing.callId == entry.callId then
            found := true
            -- Completed / crash_tombstone entries are sticky against duplicate `started` replays.
            if existing.phase == .started then
              updated := updated.push entry
            else
              updated := updated.push existing
          else
            updated := updated.push existing
        if !found then
          updated := updated.push entry
        let nextJson := serializeToolJournal updated
        let nextRev := cur.stateRevision + 1
        let upd ← execCasUpdateOneRowUnlocked db
          "UPDATE harness_continuity SET tool_journal_json=?2, state_revision=?3, updated_at=?4 WHERE mission_id=?1 AND state_revision=?5;"
          #[missionId, nextJson, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
          s!"record_tool_journal:expected={cur.stateRevision}"
        match upd with
        | .error e => return .error e
        | .ok () =>
          return .ok {
            cur with
            toolJournal := updated
            stateRevision := nextRev
            updatedAt := nowAt
          }

/-- Crash-boundary startup / resume reconciliation (`SM-17`):
    - Any `prompt_claim_phase = 'claimed'` stranded across process crash/restart transitions to `'uncertain'`
      with `reconcile_required = 1` (never silently re-submitted under a fresh session or prompt).
    - Any `started` tool journal entry stranded across crash transitions deterministically to `crash_tombstone`
      and flags `reconcile_required = 1` until explicitly reconciled with `resolveContinuityReconciliation`. -/
def reconcileHarnessContinuityOnRestart
    (db : SqliteDb)
    (missionId : String)
    (nowAt : String) : IO (Except String (Option ContinuityReconcileOutcome)) := do
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok none
      match decodeContinuityRow rows[1]! with
      | .error e => return .error e
      | .ok cur =>
        let hadInflightClaim := cur.promptClaimPhase == .claimed || cur.promptClaimPhase == .uncertain
        let mut hadUnfinishedTool := false
        let mut tombstonedJournal : Array ToolJournalEntry := Array.mkEmpty cur.toolJournal.size
        for item in cur.toolJournal do
          if item.phase == .started then
            hadUnfinishedTool := true
            tombstonedJournal := tombstonedJournal.push { item with phase := .crashTombstone }
          else
            tombstonedJournal := tombstonedJournal.push item
        let nextClaimPhase : PromptClaimPhase :=
          if cur.promptClaimPhase == .claimed then .uncertain else cur.promptClaimPhase
        let needsRec := cur.reconcileRequired || hadInflightClaim || hadUnfinishedTool
        if nextClaimPhase == cur.promptClaimPhase && tombstonedJournal == cur.toolJournal && needsRec == cur.reconcileRequired then
          if needsRec then
            let reason :=
              if hadInflightClaim then "prompt_claim_uncertain"
              else "unfinished_tool_journal"
            return .ok (some (.requiresReconciliation cur reason))
          else
            return .ok (some (.cleanReady cur))
        let nextRev := cur.stateRevision + 1
        let recFlag := if needsRec then "1" else "0"
        let nextJson := serializeToolJournal tombstonedJournal
        let upd ← execCasUpdateOneRowUnlocked db
          "UPDATE harness_continuity SET prompt_claim_phase=?2, tool_journal_json=?3, reconcile_required=?4, state_revision=?5, updated_at=?6 WHERE mission_id=?1 AND state_revision=?7;"
          #[missionId, nextClaimPhase.asString, nextJson, recFlag, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
          s!"reconcile_restart:expected={cur.stateRevision}"
        match upd with
        | .error e => return .error e
        | .ok () =>
          let updatedRec : HarnessContinuityRecord := {
            cur with
            promptClaimPhase := nextClaimPhase
            toolJournal := tombstonedJournal
            reconcileRequired := needsRec
            stateRevision := nextRev
            updatedAt := nowAt
          }
          if needsRec then
            let reason :=
              if hadInflightClaim then "prompt_claim_uncertain"
              else "unfinished_tool_journal"
            return .ok (some (.requiresReconciliation updatedRec reason))
          else
            return .ok (some (.cleanReady updatedRec))

/-- Explicit operator / harness native-thread reconciliation clearing `reconcile_required` (`SM-17`).
    Preserves native `sessionId` (unless bound for the first time) and settles `uncertain` prompt claim
    either as `delivered` (`promptWasDelivered = true`) or `none` (`promptWasDelivered = false`, safe to retry). -/
def resolveContinuityReconciliation
    (db : SqliteDb)
    (missionId : String)
    (sessionGeneration : UInt64)
    (promptWasDelivered : Bool)
    (verifiedSessionId : String := "")
    (nowAt : String) : IO (Except String HarnessContinuityRecord) := do
  withImmediateTx db do
    if let .error e ← ensureHarnessContinuitySchemaUnlocked db then
      return .error e
    let q ← execParamQueryUnlocked db
      "SELECT mission_id, backend, session_generation, session_id, prompt_claim_id, prompt_claim_phase, tool_journal_json, reconcile_required, state_revision, updated_at FROM harness_continuity WHERE mission_id=?1;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .error "continuity_session_not_bound"
      match decodeContinuityRow rows[1]! with
      | .error e => return .error e
      | .ok cur =>
        if sessionGeneration != cur.sessionGeneration then
          return .error s!"continuity_generation_mismatch:{sessionGeneration}!={cur.sessionGeneration}"
        if !cur.sessionId.isEmpty && !verifiedSessionId.isEmpty && cur.sessionId != verifiedSessionId then
          return .error s!"continuity_session_id_drift:{verifiedSessionId}!={cur.sessionId}"
        let effSid := if cur.sessionId.isEmpty then verifiedSessionId else cur.sessionId
        let nextClaimPhase : PromptClaimPhase :=
          if promptWasDelivered then .delivered
          else if cur.promptClaimPhase == .uncertain || cur.promptClaimPhase == .claimed then .none
          else cur.promptClaimPhase
        let nextClaimId := if nextClaimPhase == .none then "" else cur.promptClaimId
        let nextRev := cur.stateRevision + 1
        let upd ← execCasUpdateOneRowUnlocked db
          "UPDATE harness_continuity SET session_id=?2, prompt_claim_id=?3, prompt_claim_phase=?4, reconcile_required=0, state_revision=?5, updated_at=?6 WHERE mission_id=?1 AND state_revision=?7;"
          #[missionId, effSid, nextClaimId, nextClaimPhase.asString, s!"{nextRev}", nowAt, s!"{cur.stateRevision}"]
          s!"resolve_reconciliation:expected={cur.stateRevision}"
        match upd with
        | .error e => return .error e
        | .ok () =>
          return .ok {
            cur with
            sessionId := effSid
            promptClaimId := nextClaimId
            promptClaimPhase := nextClaimPhase
            reconcileRequired := false
            stateRevision := nextRev
            updatedAt := nowAt
          }

/-! ## 6. `SM-18`: Ask Sidecar Post-Ack `operator_notes` Flush & Startup `ask-sandbox-*` GC -/

structure OperatorNoteRecord where
  noteId        : String
  missionId     : String
  content       : String
  createdAtSeq  : UInt64
  createdAtIso  : String
  deliveryTries : UInt32 := 0
  flushedAt?    : Option String := none
  deriving Repr, DecidableEq, Inhabited

def askMidturnSchemaSql : String :=
  OrbCore.Store.askMidturnSchemaSql

def askMidturnPendingIndexSql : String :=
  OrbCore.Store.askMidturnPendingIndexSql

/-- Schema bootstrap for `operator_notes` that must run only while `askDb.mu` is already held
    (including inside `withImmediateTx`), matching `OrbCore.CloudAgents.ensureCloudTurnSchemaUnlocked`. -/
def ensureAskMidturnSchemaUnlocked (askDb : SqliteDb) : IO (Except String Unit) := do
  if let .error e ← execParamQueryUnlocked askDb askMidturnSchemaSql #[] then
    return .error e
  for stmt in OrbCore.Store.askMidturnAdditiveAlters do
    match ← sqliteExecRaw askDb.handle stmt with
    | .ok () => pure ()
    | .error e =>
      if (e.toLower.splitOn "duplicate column name").length ≤ 1 then
        return .error e
  let idxRes ← execParamQueryUnlocked askDb askMidturnPendingIndexSql #[]
  return idxRes.map (fun _ => ())

/-- Eagerly ensure `operator_notes` and `idx_operator_notes_pending` exist on `ask.db` (`SM-18`)
    via separate single-statement `execParamQueryUnlocked` calls under `askDb.mu`. -/
def ensureAskMidturnSchema (askDb : SqliteDb) : IO (Except String Unit) :=
  askDb.mu.atomically (ensureAskMidturnSchemaUnlocked askDb)

private def decodeOperatorNoteRow (r : Array String) : Except String OperatorNoteRecord := do
  if r.size < 7 then throw "operator_note_row_short"
  let noteId := r[0]!
  let missionId := r[1]!
  let content := r[2]!
  let some seqNat := r[3]!.toNat?
    | throw s!"invalid_note_seq:{r[3]!}"
  let createdIso := r[4]!
  let some triesNat := r[5]!.toNat?
    | throw s!"invalid_note_tries:{r[5]!}"
  let flushedRaw := r[6]!
  let flushed? := if flushedRaw.isEmpty then none else some flushedRaw
  return {
    noteId := noteId
    missionId := missionId
    content := content
    createdAtSeq := seqNat.toUInt64
    createdAtIso := createdIso
    deliveryTries := triesNat.toUInt32
    flushedAt? := flushed?
  }

/-- Enqueue an operator midturn note with a stable caller/UUID identity (`noteId`) and monotone FIFO
    `createdAtSeq` (`SM-18`). Idempotent on `note_id`: re-inserting an existing `note_id` preserves the
    original `note_id`, `created_at_seq`, and `flushed_at` without duplicating or reordering. -/
def enqueueOperatorNote
    (askDb : SqliteDb)
    (noteId : String)
    (missionId : String)
    (content : String)
    (createdAtSeq : UInt64)
    (createdAtIso : String) : IO (Except String OperatorNoteRecord) := do
  let canonicalId := noteId.trimAscii.toString
  if canonicalId.isEmpty || missionId.trimAscii.toString.isEmpty then
    return .error "invalid_operator_note_identity"
  withImmediateTx askDb do
    if let .error e ← ensureAskMidturnSchemaUnlocked askDb then
      return .error e
    let q ← execParamQueryUnlocked askDb
      "SELECT COALESCE(NULLIF(note_id,''),id), mission_id, COALESCE(NULLIF(content,''),body,''), COALESCE(created_at_seq,0), COALESCE(NULLIF(created_at_iso,''),created_at,''), COALESCE(delivery_tries,0), COALESCE(flushed_at, '') FROM operator_notes WHERE note_id=?1 OR id=?1;"
      #[canonicalId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size > 1 then
        return decodeOperatorNoteRow rows[1]!
      let ins ← execParamQueryUnlocked askDb
        "INSERT INTO operator_notes(note_id, id, mission_id, content, body, created_at_seq, created_at_iso, created_at, delivery_tries, flushed_at) VALUES(?1,?1,?2,?3,?3,?4,?5,?5,0,NULL);"
        #[canonicalId, missionId, content, s!"{createdAtSeq}", createdAtIso]
      match ins with
      | .error e => return .error e
      | .ok _ =>
        return .ok {
          noteId := canonicalId
          missionId := missionId
          content := content
          createdAtSeq := createdAtSeq
          createdAtIso := createdAtIso
          deliveryTries := 0
          flushedAt? := none
        }

/-- List unflushed `operator_notes` for `missionId` in strict FIFO `(created_at_seq ASC, note_id ASC)` order (`SM-18`). -/
def listPendingOperatorNotes (askDb : SqliteDb) (missionId : String) : IO (Except String (Array OperatorNoteRecord)) :=
  askDb.mu.atomically do
    if let .error e ← ensureAskMidturnSchemaUnlocked askDb then
      return .error e
    let q ← execParamQueryUnlocked askDb
      "SELECT COALESCE(NULLIF(note_id,''),id), mission_id, COALESCE(NULLIF(content,''),body,''), COALESCE(created_at_seq,0), COALESCE(NULLIF(created_at_iso,''),created_at,''), COALESCE(delivery_tries,0), COALESCE(flushed_at, '') FROM operator_notes WHERE mission_id=?1 AND (flushed_at IS NULL OR flushed_at = '') ORDER BY created_at_seq ASC, COALESCE(NULLIF(note_id,''),id) ASC;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok #[]
      let mut out : Array OperatorNoteRecord := Array.mkEmpty (rows.size - 1)
      for idx in [1:rows.size] do
        match decodeOperatorNoteRow rows[idx]! with
        | .ok rec => out := out.push rec
        | .error e => return .error e
      return .ok out

/--List ALL `operator_notes` (both pending and flushed) for `missionId` in `(created_at_seq ASC, note_id ASC)` order. -/
def listAllOperatorNotes (askDb : SqliteDb) (missionId : String) : IO (Except String (Array OperatorNoteRecord)) :=
  askDb.mu.atomically do
    if let .error e ← ensureAskMidturnSchemaUnlocked askDb then
      return .error e
    let q ← execParamQueryUnlocked askDb
      "SELECT COALESCE(NULLIF(note_id,''),id), mission_id, COALESCE(NULLIF(content,''),body,''), COALESCE(created_at_seq,0), COALESCE(NULLIF(created_at_iso,''),created_at,''), COALESCE(delivery_tries,0), COALESCE(flushed_at, '') FROM operator_notes WHERE mission_id=?1 ORDER BY created_at_seq ASC, COALESCE(NULLIF(note_id,''),id) ASC;"
      #[missionId]
    match q with
    | .error e => return .error e
    | .ok rows =>
      if rows.size ≤ 1 then return .ok #[]
      let mut out : Array OperatorNoteRecord := Array.mkEmpty (rows.size - 1)
      for idx in [1:rows.size] do
        match decodeOperatorNoteRow rows[idx]! with
        | .ok rec => out := out.push rec
        | .error e => return .error e
      return .ok out

/-- Explicit delivery receipt returned by `injectFn` once the harness RPC/stdin write has been durably
    accepted (`SM-18`). A note's `flushed_at` timestamp is NEVER written before a non-empty receipt is returned. -/
structure MidturnDeliveryReceipt where
  receiptId : String
  deriving Repr, DecidableEq, Inhabited

structure MidturnFlushSummary where
  flushedNoteIds : Array String
  remainingCount : Nat
  failedReason?  : Option String := none
  deriving Repr, DecidableEq

/-- Flush pending `operator_notes` into `handle` between tools (`SM-15` + `SM-18`):
    1. Verifies `handle` is in `InTurn` with `toolDepth == 0` and `eventGeneration == sessionGeneration`.
       Ensures `steerPending == 1` via `queueSteer` (`opCode = 4`) if not already latched, then checks
       `verifyHarnessSessionAdmit` for `flushSteerBetweenTools` (`opCode = 5`) BEFORE touching RPC/stdin.
    2. Injects each pending note in strict FIFO order via `injectFn`, requiring a non-empty `MidturnDeliveryReceipt`.
    3. Commits `flushed_at = flushedAtIso` in `ask.db` via `BEGIN IMMEDIATE` + `SELECT changes() == 1` CAS
       ONLY AFTER `injectFn` returns `.ok receipt` with a non-empty `receipt.receiptId`!
       - If `injectFn` returns `.error err` or an empty receipt, or a post-inject SQLite error occurs:
         leaves `flushed_at IS NULL`, preserves original `note_id` and `created_at_seq` FIFO order
         (never re-enqueuing under a new UUID or bumping `created_at_seq`), increments `delivery_tries`
         on inject failure, keeps `steerPending == 1`, stops draining so subsequent notes cannot leapfrog
         an earlier failed note, and returns `.error` (never claiming success).
       - If `injectFn` succeeded but the `WHERE ... AND (flushed_at IS NULL OR flushed_at = '')` CAS lost
         (`changes() != 1`), rolls back and does NOT report the note in `flushedNoteIds` for this caller.
    4. Once all pending notes have been acked and verified empty in `ask.db` (`failedErr?.isNone && remNotes.isEmpty`),
       commits `flushSteerBetweenTools` (`opCode = 5`) on `handle` (`steerPending := 0`). -/
def flushPendingOperatorNotesBetweenTools
    (askDb : SqliteDb)
    (handle : HarnessSessionHandle)
    (eventGeneration : UInt64)
    (flushedAtIso : String)
    (injectFn : OperatorNoteRecord → IO (Except String MidturnDeliveryReceipt)) :
    IO (Except String MidturnFlushSummary) := do
  if flushedAtIso.trimAscii.toString.isEmpty then
    return .error "empty_flushed_at_timestamp"
  let pending ← match ← listPendingOperatorNotes askDb handle.missionId with
    | .error e => return .error e
    | .ok ns   => pure ns
  if pending.isEmpty then
    return .ok { flushedNoteIds := #[], remainingCount := 0, failedReason? := none }

  -- Gate via `stepHarnessSessionSlice` (`queueSteer` if needed, then verify `flushSteerBetweenTools` admissibility).
  let gateRes : Except String Unit ← handle.mu.atomically do
    let st ← get
    if eventGeneration != st.slice.sessionGeneration then
      return Except.error s!"stale_event_generation:{eventGeneration}!={st.slice.sessionGeneration}"
    let mut curSlice := st.slice
    if curSlice.steerPending == 0 then
      let (queuedSlice, _) := stepHarnessSessionSlice curSlice {
        opCode := HarnessSessionOp.encode .queueSteer
        hasTurnIdleReceipt := 0
        hasProcExitReceipt := 0
        eventGeneration := eventGeneration
      }
      curSlice := queuedSlice
    if verifyHarnessSessionAdmit curSlice.phaseCode (HarnessSessionOp.encode .flushSteerBetweenTools)
         curSlice.steerPending 0 0 curSlice.toolDepth curSlice.sessionGeneration eventGeneration != 1 then
      return Except.error s!"midturn_flush_not_admissible:phase={curSlice.phaseCode}:depth={curSlice.toolDepth}:steer={curSlice.steerPending}"
    set { st with slice := curSlice }
    return Except.ok ()
  if let .error e := gateRes then
    return .error e

  let mut flushedIds : Array String := Array.mkEmpty pending.size
  let mut failedErr? : Option String := none

  for idx in [0:pending.size] do
    if failedErr?.isNone then
      let note := pending[idx]!
      match ← injectFn note with
      | .ok receipt =>
        if receipt.receiptId.trimAscii.toString.isEmpty then
          discard <| withImmediateTx askDb do
            execCasUpdateOneRowUnlocked askDb
              "UPDATE operator_notes SET delivery_tries=COALESCE(delivery_tries,0)+1 WHERE COALESCE(NULLIF(note_id,''),id)=?1 AND (flushed_at IS NULL OR flushed_at = '');"
              #[note.noteId]
              s!"operator_note_tries:{note.noteId}"
          failedErr? := some s!"missing_delivery_receipt:{note.noteId}"
        else
          let markRes ← withImmediateTx askDb do
            execCasUpdateOneRowUnlocked askDb
              "UPDATE operator_notes SET flushed_at=?2, delivery_tries=COALESCE(delivery_tries,0)+1 WHERE COALESCE(NULLIF(note_id,''),id)=?1 AND (flushed_at IS NULL OR flushed_at = '');"
              #[note.noteId, flushedAtIso]
              s!"operator_note_flush:{note.noteId}"
          match markRes with
          | .ok () =>
            flushedIds := flushedIds.push note.noteId
          | .error e =>
            if e.startsWith "cas_conflict:" then
              -- Lost CAS (`flushed_at` was already set by a concurrent caller): do NOT report as flushed by this caller.
              pure ()
            else
              failedErr? := some s!"post_ack_sqlite_commit_failed:{e}"
      | .error rpcErr =>
        discard <| withImmediateTx askDb do
          execCasUpdateOneRowUnlocked askDb
            "UPDATE operator_notes SET delivery_tries=COALESCE(delivery_tries,0)+1 WHERE COALESCE(NULLIF(note_id,''),id)=?1 AND (flushed_at IS NULL OR flushed_at = '');"
            #[note.noteId]
            s!"operator_note_tries:{note.noteId}"
        failedErr? := some rpcErr

  let remNotes ← match ← listPendingOperatorNotes askDb handle.missionId with
    | .error e =>
      return .error (match failedErr? with | some fe => fe | none => s!"post_flush_pending_query_failed:{e}")
    | .ok ns   => pure ns

  if let some errMsg := failedErr? then
    return .error errMsg

  if remNotes.isEmpty then
    -- All pending notes durably acked: clear `steerPending` via `flushSteerBetweenTools` (`opCode = 5`).
    discard <| handle.mu.atomically do
      let st ← get
      let (flushedSlice, _) := stepHarnessSessionSlice st.slice {
        opCode := HarnessSessionOp.encode .flushSteerBetweenTools
        hasTurnIdleReceipt := 0
        hasProcExitReceipt := 0
        eventGeneration := eventGeneration
      }
      set { st with slice := flushedSlice }

  return .ok {
    flushedNoteIds := flushedIds
    remainingCount := remNotes.size
    failedReason? := none
  }

/-- Startup garbage collector for orphaned Ask sandbox throwaway directories (`SM-18`).
    Scans `tmpRoot` for entries named `ask-sandbox-<sandboxId>`:
    - Never touches entries without the exact `"ask-sandbox-"` prefix.
    - Never touches entries whose `<sandboxId>` (or full directory name) is in `activeIds`.
    - Uses `lstatInfo` (`OrbBin.PosixExt.statPath`) before removal: refuses to recursively traverse
      symlinks (unlinks symlinked `ask-sandbox-*` leaf directly via `IO.FS.removeFile` instead of `removeDirAll`),
      and removes orphaned real directories via `IO.FS.removeDirAll`.
    - Returns the sorted list of removed entry names for deterministic auditing. -/
def gcOrphanedAskSandboxes (tmpRoot : System.FilePath) (activeIds : Array String) : IO (Array String) := do
  let rootFlags ← OrbBin.PosixExt.statPath tmpRoot.toString
  if !rootFlags.exists_ || !rootFlags.isDir || rootFlags.isSymlink then
    return #[]
  let entries ← match ← tmpRoot.readDir |>.toBaseIO with
    | .ok es   => pure es
    | .error _ => pure #[]
  let pfx := "ask-sandbox-"
  let mut removed : Array String := #[]
  for entry in entries do
    let name := entry.fileName
    if name.startsWith pfx && name.length > pfx.length then
      let sandboxId := (name.drop pfx.length).toString
      let isActive := activeIds.contains sandboxId || activeIds.contains name
      if !isActive then
        let st ← OrbBin.PosixExt.statPath entry.path.toString
        if st.exists_ then
          if st.isSymlink || st.isReg then
            try
              IO.FS.removeFile entry.path
              removed := removed.push name
            catch _ => pure ()
          else if st.isDir then
            try
              IO.FS.removeDirAll entry.path
              removed := removed.push name
            catch _ => pure ()
  return removed.qsort (· < ·)

/-- Eager startup bootstrap for the Ask sidecar (`SM-18`): ensures `operator_notes` schema on `ask.db`,
    collects orphaned `ask-sandbox-*` directories under `sandboxTmpRoot`, and returns pending pre-restart
    `operator_notes` counts alongside removed orphan directories so pre-restart notes never sit undrained
    waiting for an HTTP Ask hit. -/
def bootstrapAskSidecarOnStartup
    (askDb : SqliteDb)
    (sandboxTmpRoot : System.FilePath)
    (activeSandboxIds : Array String := #[]) :
    IO (Except String (Nat × Array String)) := do
  if let .error e ← ensureAskMidturnSchema askDb then
    return .error e
  let pendingCount : Nat ← match ← execParamQuery askDb
      "SELECT COUNT(*) FROM operator_notes WHERE flushed_at IS NULL OR flushed_at = '';"
      #[] with
    | .ok rows =>
      if rows.size > 1 && rows[1]!.size > 0 then
        match rows[1]![0]!.toNat? with
        | some n => pure n
        | none   => return .error s!"invalid_operator_notes_count:{rows[1]![0]!}"
      else
        return .error "missing_operator_notes_count_row"
    | .error e =>
      return .error e
  let reaped ← gcOrphanedAskSandboxes sandboxTmpRoot activeSandboxIds
  return .ok (pendingCount, reaped)

end OrbCore.HarnessSessionRegistry
