/-
  OrbCore.Harness: Pure-Lean Shared CLI, OpenCode SSE, Stream Event & Native Vibe ACP Parsers
  (`0 import Lean`, `0 sorryAx`) enforcing all `scripts/harness_contract_tests.sh` invariants
  plus Phase R4-C (`SM-15`, `SM-16`) OpenCode SSE + CLI dual-channel session/turn coordination.
-/
import LeanSys
import Orb.Kernel
import Orb.HarnessCloud
import OrbBin.Json
import OrbBin.ClaudeControl

namespace OrbCore.Harness

open LeanSys.Posix
open LeanSys.Codec
open Orb.Kernel
open Orb.HarnessCloud
open OrbBin.Json

/-- True when OpenCode emitted an auto-compaction checkpoint rather than user-facing assistant prose. -/
def isOpenCodeCompactionSummary (text : String) : Bool :=
  let t := text.trimAscii.toString
  (t.startsWith "## Objective\n" || t.startsWith "## Objective\r\n") &&
  ((t.splitOn "\n## Work State\n").length > 1 || (t.splitOn "\n## Progress\n").length > 1 ||
   (t.splitOn "\r\n## Work State\r\n").length > 1 || (t.splitOn "\r\n## Progress\r\n").length > 1) &&
  ((t.splitOn "\n## Next Move\n").length > 1 || (t.splitOn "\r\n## Next Move\r\n").length > 1) &&
  ((t.splitOn "\n## Relevant Files").length > 1 || (t.splitOn "\r\n## Relevant Files").length > 1)

/-- Normalized harness stream event (`Thinking` capability parity). -/
inductive AgentEvent where
  | TextDelta (missionId : String) (delta : String)
  | Thinking (missionId : String) (content : String) (done : Bool)
  | ToolCall (missionId : String) (callId : String) (name : String) (argsJson : String := "{}")
  | ToolResult (missionId : String) (callId : String) (toolName : String) (output : String)
  | AssistantMessage (missionId : String) (text : String)
  | TurnResult (missionId : String) (isError : Bool) (message : String)
  deriving Repr, DecidableEq, Inhabited

/-- Stateful parser reducer storing active `callId -> toolName` correlations across turns. -/
structure HarnessParserState where
  missionId      : String
  pendingCalls   : Array (String × String) := #[]
  emittedEvents  : Array AgentEvent := #[]
  sawUserText    : Bool := false
  sawActivity    : Bool := false
  lastStopReason : String := ""
  deriving Repr, DecidableEq

/-- Normalize OpenCode / Vercel AI SDK `step_finish` stop reasons (`"stop"` -> `"end_turn"`),
    preserving distinct terminal reasons such as `"length"`, `"max_tokens"`, `"content-filter"`, and `"error"`. -/
def normalizeOpenCodeStopReason (rawReason : String) : String :=
  let r := rawReason.trimAscii.toString
  if r == "stop" || r == "end_turn" || r == "EndTurn" then "end_turn" else r

private def lookupToolName (calls : Array (String × String)) (callId : String) : String :=
  match calls.findRev? (fun p => p.1 == callId) with
  | some (_, nm) => nm
  | none => "unknown_tool"

/-- Parse a single JSONL CLI/harness event line, strictly separating `thinking` blocks from `TextDelta`,
    correlating `tool_use`/`tool_call` IDs to subsequent `tool_result` events, and preserving error messages. -/
def stepHarnessJsonLine (st : HarnessParserState) (line : String) : HarnessParserState :=
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty then st
  else
    let sl := ByteSlice.ofString trimmed
    let tape := JsonTape.indexJsonObject sl
    let evType := (JsonTape.lookupString? tape "type").getD ""
    let subtype := (JsonTape.lookupString? tape "subtype").getD ""
    if evType == "thinking" || subtype == "thinking" then
      let thought := (JsonTape.lookupString? tape "thinking").getD ((JsonTape.lookupString? tape "text").getD "")
      let done := (JsonTape.lookupBool? tape "done").getD false
      { st with emittedEvents := st.emittedEvents.push (.Thinking st.missionId thought done) }
    else if evType == "stream_event" || evType == "text_delta" then
      let blockType := (JsonTape.lookupString? tape "content_type").getD "text"
      if blockType == "thinking" then
        let thought := (JsonTape.lookupString? tape "delta").getD ((JsonTape.lookupString? tape "thinking").getD "")
        { st with emittedEvents := st.emittedEvents.push (.Thinking st.missionId thought false) }
      else
        let delta := (JsonTape.lookupString? tape "delta").getD ((JsonTape.lookupString? tape "text").getD "")
        { st with emittedEvents := st.emittedEvents.push (.TextDelta st.missionId delta) }
    else if evType == "control_request" then
      match (OrbBin.Json.parse trimmed).toOption.bind OrbBin.ClaudeControl.parseClaudeControlRequest? with
      | none => st
      | some cr =>
        let callId := cr.requestId
        let name := "ui_native_request"
        let argsJson := renderCompact (.obj #[
          ("method", .str cr.method),
          ("params", cr.uiParams)
        ])
        let baseCalls := if st.pendingCalls.size ≥ 1024 then st.pendingCalls.extract 1 st.pendingCalls.size else st.pendingCalls
        let calls' := baseCalls.push (callId, name)
        { st with sawActivity := true, pendingCalls := calls', emittedEvents := st.emittedEvents.push (.ToolCall st.missionId callId name argsJson) }
    else if evType == "tool_call" || evType == "tool_use" then
      let parsedOpt := (OrbBin.Json.parse trimmed).toOption
      let openCodePart? :=
        match parsedOpt with
        | some jv =>
          if (jv.fieldStr? "name").isNone then
            match jv.field? "part" with
            | some part => if (part.fieldStr? "tool").isSome then some part else none
            | none => none
          else none
        | none => none
      match openCodePart? with
      | some part =>
        let toolName := (part.fieldStr? "tool").getD "tool"
        let callId := (part.fieldStr? "callID").orElse (fun _ => part.fieldStr? "id") |>.getD ""
        let stateOpt := part.field? "state"
        let argsJson :=
          match stateOpt.bind (fun s => s.field? "input") with
          | some a => renderCompact a
          | none => "{}"
        let status := (stateOpt.bind (fun s => s.fieldStr? "status")).getD ""
        let evsCall := st.emittedEvents.push (.ToolCall st.missionId callId toolName argsJson)
        if status == "completed" || status == "error" || status == "failed" || status == "cancelled" then
          let out :=
            (stateOpt.bind (fun s => s.fieldStr? "output"))
              |>.orElse (fun _ => stateOpt.bind (fun s => s.fieldStr? "error"))
              |>.getD ""
          let calls' := st.pendingCalls.filter (fun p => p.1 != callId)
          { st with
            sawActivity := true
            pendingCalls := calls'
            emittedEvents := evsCall.push (.ToolResult st.missionId callId toolName out) }
        else
          let baseCalls := if st.pendingCalls.size ≥ 1024 then st.pendingCalls.extract 1 st.pendingCalls.size else st.pendingCalls
          let calls' := baseCalls.push (callId, toolName)
          { st with sawActivity := true, pendingCalls := calls', emittedEvents := evsCall }
      | none =>
        let callId := (JsonTape.lookupString? tape "id").getD ((JsonTape.lookupString? tape "call_id").getD "")
        let name := (JsonTape.lookupString? tape "name").getD "tool"
        let argsJson :=
          match parsedOpt with
          | some jv =>
            match (jv.field? "input").orElse (fun _ => jv.field? "args") with
            | some a => renderCompact a
            | none => "{}"
          | none => "{}"
        let baseCalls := if st.pendingCalls.size ≥ 1024 then st.pendingCalls.extract 1 st.pendingCalls.size else st.pendingCalls
        let calls' := baseCalls.push (callId, name)
        { st with sawActivity := true, pendingCalls := calls', emittedEvents := st.emittedEvents.push (.ToolCall st.missionId callId name argsJson) }
    else if evType == "tool_result" then
      let callId := (JsonTape.lookupString? tape "tool_use_id").getD ((JsonTape.lookupString? tape "call_id").getD "")
      let toolName := lookupToolName st.pendingCalls callId
      let calls' := st.pendingCalls.filter (fun p => p.1 != callId)
      let out := (JsonTape.lookupString? tape "output").getD ((JsonTape.lookupString? tape "content").getD "")
      { st with pendingCalls := calls', emittedEvents := st.emittedEvents.push (.ToolResult st.missionId callId toolName out) }
    else if evType == "assistant" then
      let txt := (JsonTape.lookupString? tape "text").getD ((JsonTape.lookupString? tape "message").getD "")
      { st with emittedEvents := st.emittedEvents.push (.AssistantMessage st.missionId txt) }
    else if evType == "result" then
      let isErr := (JsonTape.lookupBool? tape "is_error").getD (subtype == "error")
      let msg := (JsonTape.lookupString? tape "error").getD ((JsonTape.lookupString? tape "result").getD "")
      { st with emittedEvents := st.emittedEvents.push (.TurnResult st.missionId isErr msg) }
    else if evType == "error" then
      let msg :=
        match OrbBin.Json.parse trimmed with
        | .ok jv =>
          match jv.field? "error" with
          | some (.str s) => if s.isEmpty then "opencode_error" else s
          | some errObj =>
            let dataMsg? := (errObj.field? "data").bind (fun d => d.fieldStr? "message")
            let directMsg? := errObj.fieldStr? "message"
            let nameStr? := errObj.fieldStr? "name"
            match dataMsg?.orElse (fun _ => directMsg?) with
            | some m =>
              match nameStr? with
              | some nm => if nm.isEmpty || m.startsWith nm then m else s!"{nm}: {m}"
              | none => m
            | none => renderCompact errObj
          | none =>
            let fallback := (jv.fieldStr? "message").getD ""
            if fallback.isEmpty then "opencode_error" else fallback
        | .error _ =>
          let fallback := (JsonTape.lookupString? tape "message").getD ""
          if fallback.isEmpty then "opencode_error" else fallback
      { st with sawActivity := true, emittedEvents := st.emittedEvents.push (.TurnResult st.missionId true msg) }
    else
      -- OpenCode `run --format json` events carry a nested `"part": {...}` object with `"sessionID"`.
      match OrbBin.Json.parse trimmed with
      | .error _ => st
      | .ok jv =>
        match jv.field? "part" with
        | none => st
        | some part =>
          if evType == "step_start" then
            { st with sawActivity := true }
          else if evType == "reasoning" then
            let thought := (part.fieldStr? "text").getD ""
            { st with sawActivity := true, emittedEvents := st.emittedEvents.push (.Thinking st.missionId thought true) }
          else if evType == "text" then
            let txt := (part.fieldStr? "text").getD ""
            if isOpenCodeCompactionSummary txt then
              { st with sawActivity := true }
            else if txt.trimAscii.toString.isEmpty then
              st
            else
              { st with sawUserText := true, sawActivity := true, emittedEvents := st.emittedEvents.push (.TextDelta st.missionId txt) }
          else if evType == "step_finish" then
            let rawReason := (part.fieldStr? "reason").getD ""
            let normReason := normalizeOpenCodeStopReason rawReason
            if normReason.isEmpty || normReason == "tool-calls" || normReason == "tool_calls" then
              { st with sawActivity := true, lastStopReason := normReason }
            else if normReason == "end_turn" then
              if st.sawActivity && !st.sawUserText then
                { st with
                  sawActivity := true
                  lastStopReason := "end_turn"
                  emittedEvents := st.emittedEvents.push (.TurnResult st.missionId true "OpenCode finished without assistant text (stop reason: end_turn).") }
              else
                { st with
                  lastStopReason := "end_turn"
                  emittedEvents := st.emittedEvents.push (.TurnResult st.missionId false "end_turn") }
            else if !st.sawUserText then
              { st with
                sawActivity := true
                lastStopReason := normReason
                emittedEvents := st.emittedEvents.push (.TurnResult st.missionId true s!"OpenCode finished without assistant text (stop reason: {normReason}).") }
            else if normReason == "length" || normReason == "max_tokens" then
              { st with
                sawActivity := true
                lastStopReason := normReason
                emittedEvents := st.emittedEvents.push (.TurnResult st.missionId true s!"OpenCode stopped at output token limit (stop reason: {normReason}).") }
            else
              { st with
                sawActivity := true
                lastStopReason := normReason
                emittedEvents := st.emittedEvents.push (.TurnResult st.missionId true s!"OpenCode stopped abnormally (stop reason: {normReason}).") }
          else
            st

/-- Parse an OpenCode SSE frame (`event: ... \n data: {...}`), ignoring keepalive comments and `[DONE]` sentinels. -/
def parseOpenCodeSseChunk (st : HarnessParserState) (ssePayload : String) : HarnessParserState := Id.run do
  let mut cur := st
  for rawLine in ssePayload.splitOn "\n" do
    let ln := rawLine.trimAscii.toString
    if ln.startsWith "data:" then
      let dataPart := (ln.drop 5).trimAscii.toString
      if dataPart != "" && dataPart != "[DONE]" then
        cur := stepHarnessJsonLine cur dataPart
  return cur

/-- Reset per-turn `HarnessParserState` latches on warm-session turn boundaries (`SM-15`) so
    `sawUserText`, `sawActivity`, `lastStopReason`, `pendingCalls`, and `emittedEvents` from turn `N` never bleed into turn `N + 1`. -/
def HarnessParserState.resetForWarmTurn (st : HarnessParserState) : HarnessParserState :=
  { missionId := st.missionId
    pendingCalls := #[]
    emittedEvents := #[]
    sawUserText := false
    sawActivity := false
    lastStopReason := "" }

/-- Validate a native Vibe ACP JSON-RPC `session/update` or `session/new` message (`vibe::tests` contract). -/
def parseVibeAcpNotification? (line : String) : Option (String × AgentEvent) :=
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty then none
  else
    let sl := ByteSlice.ofString trimmed
    let tape := JsonTape.indexJsonObject sl
    match JsonTape.lookupString? tape "method" with
    | some "session/new" =>
      let sidOpt :=
        match JsonTape.lookupString? tape "sessionId" with
        | some s => if s.isEmpty then none else some s
        | none =>
          match OrbBin.Json.parse trimmed with
          | .ok jv =>
            (jv.field? "params").bind (fun p => p.fieldStr? "sessionId") |>.bind (fun s => if s.isEmpty then none else some s)
          | .error _ => none
      match sidOpt with
      | some sid => some (sid, .AssistantMessage sid "")
      | none => none
    | some "session/update" =>
      let (sid, kind, txt) :=
        match JsonTape.lookupString? tape "sessionId", JsonTape.lookupString? tape "sessionUpdate", JsonTape.lookupString? tape "text" with
        | some s, some k, some t => (s, k, t)
        | sOpt, kOpt, tOpt =>
          match OrbBin.Json.parse trimmed with
          | .ok jv =>
            let pOpt := jv.field? "params"
            let uOpt := pOpt.bind (fun p => p.field? "update")
            let cOpt := uOpt.bind (fun u => u.field? "content")
            let s := sOpt.orElse (fun _ => pOpt.bind (fun p => p.fieldStr? "sessionId")) |>.getD "vibe-session"
            let k := kOpt.orElse (fun _ => uOpt.bind (fun u => u.fieldStr? "sessionUpdate")) |>.getD "agent_message_chunk"
            let t := tOpt.orElse (fun _ => uOpt.bind (fun u => u.fieldStr? "text"))
                         |>.orElse (fun _ => cOpt.bind (fun c => c.fieldStr? "text")) |>.getD ""
            (s, k, t)
          | .error _ =>
            (sOpt.getD "vibe-session", kOpt.getD "agent_message_chunk", tOpt.getD "")
      if kind == "agent_thought_chunk" then
        some (sid, .Thinking sid txt false)
      else
        some (sid, .TextDelta sid txt)
    | _ =>
      match OrbBin.Json.parse trimmed with
      | .ok jv =>
        if (jv.fieldStr? "type").getD "" == "update" then
          match jv.field? "update" with
          | some u =>
            let sid := (jv.fieldStr? "session_id").orElse (fun _ => jv.fieldStr? "sessionId") |>.getD ""
            let kind := (u.fieldStr? "sessionUpdate").getD "agent_message_chunk"
            let txt := (u.fieldStr? "text").orElse (fun _ => (u.field? "content").bind (fun c => c.fieldStr? "text")) |>.getD ""
            if kind == "agent_thought_chunk" then
              some (sid, .Thinking sid txt false)
            else
              some (sid, .TextDelta sid txt)
          | none => none
        else none
      | .error _ => none

/-- Extract a non-empty session or native thread identifier (`sessionID`, `sessionId`, `session_id`, `thread_id`)
    from top-level or nested `properties` / `params` / `part` JSON objects across all 6 harnesses. -/
def extractHarnessLineSessionId? (line : String) : Option String :=
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty then none
  else
    let nonEmpty? := fun (o : Option String) =>
      match o with
      | some s => if s.isEmpty then none else some s
      | none => none
    match OrbBin.Json.parse trimmed with
    | .error _ => none
    | .ok jv =>
      let top? :=
        (nonEmpty? (jv.fieldStr? "sessionID"))
          |>.orElse (fun _ => nonEmpty? (jv.fieldStr? "sessionId"))
          |>.orElse (fun _ => nonEmpty? (jv.fieldStr? "session_id"))
          |>.orElse (fun _ => nonEmpty? (jv.fieldStr? "thread_id"))
      top?.orElse fun _ =>
        let nestedField? := fun (subName : String) =>
          match jv.field? subName with
          | none => none
          | some sub =>
            (nonEmpty? (sub.fieldStr? "sessionID"))
              |>.orElse (fun _ => nonEmpty? (sub.fieldStr? "sessionId"))
              |>.orElse (fun _ => nonEmpty? (sub.fieldStr? "session_id"))
              |>.orElse (fun _ => nonEmpty? (sub.fieldStr? "thread_id"))
        (nestedField? "properties")
          |>.orElse (fun _ => nestedField? "params")
          |>.orElse (fun _ => nestedField? "part")

/-- Pure OpenCode SSE + CLI exit dual-channel turn outcome (`SM-16`), gated by `Orb.HarnessCloud.stepHarnessSessionSlice`
    and `Orb.Kernel.agentEventNormalizeStep`. Ensures SSE `session.idle` racing ahead of a non-zero CLI exit
    never misclassifies an error/crash as clean completion, and `Terminating -> Dead` (`opCode = 10`) never
    admits without `hasProcExitReceipt == 1`. -/
def reconcileOpenCodeSseAndCliExit
    (sess : HarnessSessionSliceState)
    (eventGeneration : UInt64)
    (sawSseIdle : Bool)
    (cliExited : Bool)
    (cliExitCode : Int32)
    (hasUserText : Bool)
    (sawActivity : Bool)
    (lastStopReason : String := "end_turn") : HarnessSessionSliceState × Option (Bool × String) :=
  let normStop :=
    let r := normalizeOpenCodeStopReason lastStopReason
    if r.isEmpty || r == "tool-calls" || r == "tool_calls" then "end_turn" else r
  if sess.sessionGeneration == 0 || eventGeneration != sess.sessionGeneration ||
     sess.phaseCode == HarnessSessionPhase.encode .dead then
    (sess, none)
  else if !cliExited then
    -- While the CLI process is still running, a raced SSE `session.idle` alone must NOT complete or reap the session.
    (sess, none)
  else if cliExitCode != 0 then
    let w := Orb.Kernel.agentEventNormalizeStep 3 7 1 1 1 0 32 4096
    let _ := w
    if sess.phaseCode == HarnessSessionPhase.encode .terminating then
      let (sDead, _) := stepHarnessSessionSlice sess {
        opCode := HarnessSessionOp.encode .confirmProcessDead
        hasTurnIdleReceipt := 0
        hasProcExitReceipt := 1
        eventGeneration := eventGeneration
      }
      (sDead, some (true, s!"opencode_cli_exit_{cliExitCode}"))
    else
      (sess, some (true, s!"opencode_cli_exit_{cliExitCode}"))
  else if (sawActivity || normStop != "end_turn") && !hasUserText then
    (sess, some (true, s!"OpenCode finished without assistant text (stop reason: {normStop})."))
  else if normStop == "length" || normStop == "max_tokens" then
    (sess, some (true, s!"OpenCode stopped at output token limit (stop reason: {normStop})."))
  else if normStop != "end_turn" then
    (sess, some (true, s!"OpenCode stopped abnormally (stop reason: {normStop})."))
  else
    let _ := sawSseIdle
    let w := Orb.Kernel.agentEventNormalizeStep 3 6 1 (if hasUserText then 1 else 0) 1 0 32 4096
    if ((w &&& 0xFFFFFFFF) &&& 256) != 0 &&
       sess.phaseCode == HarnessSessionPhase.encode .inTurn &&
       sess.toolDepth == 0 && sess.steerPending == 0 then
      let (sReady, _) := stepHarnessSessionSlice sess {
        opCode := HarnessSessionOp.encode .finishTurnToReady
        hasTurnIdleReceipt := 1
        hasProcExitReceipt := 1
        eventGeneration := eventGeneration
      }
      (sReady, some (false, "end_turn"))
    else
      (sess, none)

/-! ### Built-In Contract Invariant Checks (`scripts/harness_contract_tests.sh`) -/

def text_delta_does_not_contain_thinking_content : Bool :=
  let s0 : HarnessParserState := { missionId := "m1" }
  let s1 := stepHarnessJsonLine s0 "{\"type\":\"stream_event\",\"content_type\":\"thinking\",\"delta\":\"secret-chain\"}"
  let s2 := stepHarnessJsonLine s1 "{\"type\":\"stream_event\",\"content_type\":\"text\",\"delta\":\"visible-answer\"}"
  s2.emittedEvents == #[
    .Thinking "m1" "secret-chain" false,
    .TextDelta "m1" "visible-answer"
  ]

def thinking_produces_thinking_event : Bool :=
  let s := stepHarnessJsonLine { missionId := "m1" } "{\"type\":\"thinking\",\"thinking\":\"step-by-step\",\"done\":true}"
  s.emittedEvents == #[.Thinking "m1" "step-by-step" true]

def tool_call_stored_for_result_correlation : Bool :=
  let s1 := stepHarnessJsonLine { missionId := "m1" } "{\"type\":\"tool_call\",\"id\":\"call-77\",\"name\":\"read_file\"}"
  let s2 := stepHarnessJsonLine s1 "{\"type\":\"tool_result\",\"tool_use_id\":\"call-77\",\"output\":\"ok-bytes\"}"
  s2.emittedEvents == #[
    .ToolCall "m1" "call-77" "read_file",
    .ToolResult "m1" "call-77" "read_file" "ok-bytes"
  ]

def error_result_preserves_message : Bool :=
  let s := stepHarnessJsonLine { missionId := "m1" } "{\"type\":\"result\",\"is_error\":true,\"error\":\"rate limit exceeded\"}"
  s.emittedEvents == #[.TurnResult "m1" true "rate limit exceeded"]

def opencode_sse_ignores_done_and_parses_deltas : Bool :=
  let chunk := ": keepalive\ndata: {\"type\":\"text_delta\",\"delta\":\"hello \"}\n\ndata: {\"type\":\"text_delta\",\"delta\":\"world\"}\ndata: [DONE]\n"
  let s := parseOpenCodeSseChunk { missionId := "m2" } chunk
  s.emittedEvents == #[.TextDelta "m2" "hello ", .TextDelta "m2" "world"]

def test_parse_stream_event_delta : Bool :=
  let s := stepHarnessJsonLine { missionId := "m3" } "{\"type\":\"stream_event\",\"delta\":\"tok-1\"}"
  s.emittedEvents == #[.TextDelta "m3" "tok-1"]

def test_parse_assistant_event : Bool :=
  let s := stepHarnessJsonLine { missionId := "m3" } "{\"type\":\"assistant\",\"text\":\"full reply\"}"
  s.emittedEvents == #[.AssistantMessage "m3" "full reply"]

def test_parse_result_event : Bool :=
  let s := stepHarnessJsonLine { missionId := "m3" } "{\"type\":\"result\",\"is_error\":false,\"result\":\"completed\"}"
  s.emittedEvents == #[.TurnResult "m3" false "completed"]

def vibe_acp_session_update_contract : Bool :=
  parseVibeAcpNotification? "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"sessionId\":\"s-9\",\"sessionUpdate\":\"agent_message_chunk\",\"text\":\"ACP_OK\"}"
    == some ("s-9", .TextDelta "s-9" "ACP_OK") &&
  parseVibeAcpNotification? "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"sessionId\":\"s-9\",\"sessionUpdate\":\"agent_thought_chunk\",\"text\":\"ACP_THINK\"}"
    == some ("s-9", .Thinking "s-9" "ACP_THINK" false)

def opencode_empty_stop_after_reasoning_or_compaction_is_flagged : Bool :=
  let compaction := "## Objective\nShip fix\n\n## Work State\nDone\n\n## Next Move\nSummarize\n\n## Relevant Files\n- a.lean"
  let escComp := OrbBin.Json.escapeJsonString compaction
  let s0 : HarnessParserState := { missionId := "m4" }
  let s1 := stepHarnessJsonLine s0 "{\"type\":\"reasoning\",\"sessionID\":\"ses_1\",\"part\":{\"type\":\"reasoning\",\"text\":\"Let me write the summary.\"}}"
  let s2 := stepHarnessJsonLine s1 s!"\{\"type\":\"text\",\"sessionID\":\"ses_1\",\"part\":\{\"type\":\"text\",\"text\":{escComp}}}"
  let s3 := stepHarnessJsonLine s2 "{\"type\":\"step_finish\",\"sessionID\":\"ses_1\",\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}"
  s3.emittedEvents == #[
    .Thinking "m4" "Let me write the summary." true,
    .TurnResult "m4" true "OpenCode finished without assistant text (stop reason: end_turn)."
  ]

def opencode_raced_sse_idle_vs_nonzero_cli_exit_contract : Bool :=
  let inTurn : HarnessSessionSliceState := {
    phaseCode := HarnessSessionPhase.encode .inTurn
    steerPending := 0
    toolDepth := 0
    sessionGeneration := 5
  }
  let (sWhileRunning, resWhileRunning) := reconcileOpenCodeSseAndCliExit inTurn 5 true false 0 true true
  let (sAfterCrash, resAfterCrash) := reconcileOpenCodeSseAndCliExit sWhileRunning 5 true true 137 true true
  let (sClean, resClean) := reconcileOpenCodeSseAndCliExit inTurn 5 true true 0 true true
  let sReset := (stepHarnessJsonLine { missionId := "m5" } "{\"type\":\"text_delta\",\"delta\":\"hi\"}").resetForWarmTurn
  sWhileRunning == inTurn &&
  resWhileRunning.isNone &&
  sAfterCrash.phaseCode == HarnessSessionPhase.encode .inTurn &&
  resAfterCrash == some (true, "opencode_cli_exit_137") &&
  sClean.phaseCode == HarnessSessionPhase.encode .ready &&
  resClean == some (false, "end_turn") &&
  !sReset.sawUserText && !sReset.sawActivity && sReset.emittedEvents.isEmpty

def claude_control_request_emits_ui_native_request : Bool :=
  let line := "{\"type\":\"control_request\",\"request_id\":\"req-perm-9\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"git status\"}}}"
  let s1 := stepHarnessJsonLine { missionId := "m9" } line
  let s2 := stepHarnessJsonLine s1 "{\"type\":\"tool_result\",\"tool_use_id\":\"req-perm-9\",\"output\":\"accepted\"}"
  let ev0? : Option AgentEvent := s2.emittedEvents[0]?
  let ev1? : Option AgentEvent := s2.emittedEvents[1]?
  match ev0?, ev1? with
  | some (AgentEvent.ToolCall "m9" "req-perm-9" "ui_native_request" argsJson),
    some (AgentEvent.ToolResult "m9" "req-perm-9" "ui_native_request" "accepted") =>
    (argsJson.splitOn "\"method\":\"permission\"").length > 1
  | _, _ => false

def opencode_length_stop_and_nested_tool_use_contract : Bool :=
  let s0 : HarnessParserState := { missionId := "m-len" }
  let s1 := stepHarnessJsonLine s0 "{\"type\":\"step_start\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"step-start\"}}"
  let s2 := stepHarnessJsonLine s1 "{\"type\":\"tool_use\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"tool\",\"callID\":\"call_h1\",\"tool\":\"sandboxed_get_mission_health\",\"state\":{\"status\":\"completed\",\"input\":{\"mission_id\":\"m-len\"},\"output\":\"healthy\"}}}"
  let s3 := stepHarnessJsonLine s2 "{\"type\":\"step_finish\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"step-finish\",\"reason\":\"tool-calls\"}}"
  let s4 := stepHarnessJsonLine s3 "{\"type\":\"step_start\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"step-start\"}}"
  let s5 := stepHarnessJsonLine s4 "{\"type\":\"reasoning\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"reasoning\",\"text\":\"31999 tokens of reasoning\"}}"
  let s6 := stepHarnessJsonLine s5 "{\"type\":\"step_finish\",\"sessionID\":\"ses_len\",\"part\":{\"type\":\"step-finish\",\"reason\":\"length\"}}"
  -- Also verify partial text followed by `reason == "length"` surfaces token-limit truncation instead of clean completion,
  -- and top-level OpenCode `type == "error"` surfaces `.TurnResult _ true`.
  let t0 : HarnessParserState := { missionId := "m-trunc" }
  let t1 := stepHarnessJsonLine t0 "{\"type\":\"text\",\"sessionID\":\"ses_t\",\"part\":{\"type\":\"text\",\"text\":\"Half-written sentence\"}}"
  let t2 := stepHarnessJsonLine t1 "{\"type\":\"step_finish\",\"sessionID\":\"ses_t\",\"part\":{\"type\":\"step-finish\",\"reason\":\"length\"}}"
  let e1 := stepHarnessJsonLine { missionId := "m-err" } "{\"type\":\"error\",\"sessionID\":\"ses_e\",\"error\":{\"name\":\"APIError\",\"data\":{\"message\":\"Context window exceeded\"}}}"
  s6.pendingCalls.isEmpty &&
  s6.lastStopReason == "length" &&
  s6.emittedEvents == #[
    .ToolCall "m-len" "call_h1" "sandboxed_get_mission_health" "{\"mission_id\":\"m-len\"}",
    .ToolResult "m-len" "call_h1" "sandboxed_get_mission_health" "healthy",
    .Thinking "m-len" "31999 tokens of reasoning" true,
    .TurnResult "m-len" true "OpenCode finished without assistant text (stop reason: length)."
  ] &&
  t2.emittedEvents == #[
    .TextDelta "m-trunc" "Half-written sentence",
    .TurnResult "m-trunc" true "OpenCode stopped at output token limit (stop reason: length)."
  ] &&
  e1.emittedEvents == #[
    .TurnResult "m-err" true "APIError: Context window exceeded"
  ]

def runAllHarnessContractTests : Bool :=
  text_delta_does_not_contain_thinking_content &&
  thinking_produces_thinking_event &&
  tool_call_stored_for_result_correlation &&
  error_result_preserves_message &&
  opencode_sse_ignores_done_and_parses_deltas &&
  test_parse_stream_event_delta &&
  test_parse_assistant_event &&
  test_parse_result_event &&
  vibe_acp_session_update_contract &&
  opencode_empty_stop_after_reasoning_or_compaction_is_flagged &&
  opencode_raced_sse_idle_vs_nonzero_cli_exit_contract &&
  claude_control_request_emits_ui_native_request &&
  opencode_length_stop_and_nested_tool_use_contract

end OrbCore.Harness
