/-
  OrbCore.Harness: Pure-Lean Shared CLI, OpenCode SSE, Stream Event & Native Vibe ACP Parsers
  (`0 import Lean`, `0 sorryAx`) enforcing all 9 `scripts/harness_contract_tests.sh` invariants.
-/
import LeanSys

namespace OrbCore.Harness

open LeanSys.Posix
open LeanSys.Codec

/-- Normalized harness stream event (`Thinking` capability parity). -/
inductive AgentEvent where
  | TextDelta (missionId : String) (delta : String)
  | Thinking (missionId : String) (content : String) (done : Bool)
  | ToolCall (missionId : String) (callId : String) (name : String)
  | ToolResult (missionId : String) (callId : String) (toolName : String) (output : String)
  | AssistantMessage (missionId : String) (text : String)
  | TurnResult (missionId : String) (isError : Bool) (message : String)
  deriving Repr, DecidableEq

/-- Stateful parser reducer storing active `callId -> toolName` correlations across turns. -/
structure HarnessParserState where
  missionId     : String
  pendingCalls  : Array (String × String) := #[]
  emittedEvents : Array AgentEvent := #[]
  deriving Repr, DecidableEq

private def lookupToolName (calls : Array (String × String)) (callId : String) : String :=
  match calls.find? (fun p => p.1 == callId) with
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
    else if evType == "tool_call" || evType == "tool_use" then
      let callId := (JsonTape.lookupString? tape "id").getD ((JsonTape.lookupString? tape "call_id").getD "")
      let name := (JsonTape.lookupString? tape "name").getD "tool"
      let calls' := st.pendingCalls.push (callId, name)
      { st with pendingCalls := calls', emittedEvents := st.emittedEvents.push (.ToolCall st.missionId callId name) }
    else if evType == "tool_result" then
      let callId := (JsonTape.lookupString? tape "tool_use_id").getD ((JsonTape.lookupString? tape "call_id").getD "")
      let toolName := lookupToolName st.pendingCalls callId
      let out := (JsonTape.lookupString? tape "output").getD ((JsonTape.lookupString? tape "content").getD "")
      { st with emittedEvents := st.emittedEvents.push (.ToolResult st.missionId callId toolName out) }
    else if evType == "assistant" then
      let txt := (JsonTape.lookupString? tape "text").getD ((JsonTape.lookupString? tape "message").getD "")
      { st with emittedEvents := st.emittedEvents.push (.AssistantMessage st.missionId txt) }
    else if evType == "result" then
      let isErr := (JsonTape.lookupBool? tape "is_error").getD (subtype == "error")
      let msg := (JsonTape.lookupString? tape "error").getD ((JsonTape.lookupString? tape "result").getD "")
      { st with emittedEvents := st.emittedEvents.push (.TurnResult st.missionId isErr msg) }
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

/-- Validate a native Vibe ACP JSON-RPC `session/update` or `session/new` message (`vibe::tests` contract). -/
def parseVibeAcpNotification? (line : String) : Option (String × AgentEvent) := do
  let sl := ByteSlice.ofString line.trimAscii.toString
  let tape := JsonTape.indexJsonObject sl
  let method ← JsonTape.lookupString? tape "method"
  if method != "session/update" then none
  else
    let sid := (JsonTape.lookupString? tape "sessionId").getD "vibe-session"
    let kind := (JsonTape.lookupString? tape "sessionUpdate").getD "agent_message_chunk"
    let txt := (JsonTape.lookupString? tape "text").getD ""
    if kind == "agent_thought_chunk" then
      some (sid, .Thinking sid txt false)
    else
      some (sid, .TextDelta sid txt)

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

def runAllHarnessContractTests : Bool :=
  text_delta_does_not_contain_thinking_content &&
  thinking_produces_thinking_event &&
  tool_call_stored_for_result_correlation &&
  error_result_preserves_message &&
  opencode_sse_ignores_done_and_parses_deltas &&
  test_parse_stream_event_delta &&
  test_parse_assistant_event &&
  test_parse_result_event &&
  vibe_acp_session_update_contract

end OrbCore.Harness
