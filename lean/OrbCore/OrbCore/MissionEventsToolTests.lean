import OrbCore.McpGateway

namespace OrbCore.MissionEventsToolTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.MemoryAndCloud OrbCore.LegacyHydrate

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"mission events tool: {label}")

/-- `get_mission_events` through the real dispatcher: the cursors page, they do
    not restart from the first event. -/
def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/events-tool-core" | throw (IO.userError "events tool core open failed")
  try
    let .ok _ ← execParamQuery store.missionsDb "INSERT INTO missions(id,owner_user_id,project) VALUES('reader','','p');" #[]
      | throw (IO.userError "events tool mission fixture failed")
    -- 45 events: a user message, a tool call, a tool result, then an answer, repeating.
    for i in [0:45] do
      let kind := #["user_message", "tool_call", "tool_result", "assistant_message"][i % 4]!
      let .ok _ ← appendMissionEvent store "reader" kind (renderCompact (.obj #[("content", .str s!"event {i + 1}")])) "2026-11-13T00:00:00Z"
        | throw (IO.userError "events tool event fixture failed")
    let claims : McpSessionClaims := { sessionId := "events-session", missionId := "reader", role := "executor", expiresAt := 2000 }
    let call (args : Array (String × JVal)) : IO (Array Nat × Array String × Bool × Nat) := do
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "get_mission_events"
        (.obj (#[("mission_id", JVal.str "reader")] ++ args)) 1000
      let reply := (OrbBin.Json.parse raw).toOption.getD .null
      let result := (reply.field? "result").getD .null
      let events := (result.fieldArr? "events").getD #[]
      if reply.fieldBool? "ok" != some true then throw (IO.userError s!"mission events tool: call failed: {raw}")
      return (events.filterMap (·.fieldNat? "sequence"), events.filterMap (·.fieldStr? "event_type"),
        (result.fieldBool? "has_more").getD false, (result.fieldNat? "max_seq").getD 0)
    let range (first last : Nat) : Array Nat := (Array.range (last + 1 - first)).map (· + first)
    -- No cursor: the newest page, oldest first, 40 by default.
    let (newest, _, more, maxSeq) ← call #[]
    check (newest == range 6 45 && more && maxSeq == 45) s!"the default page is the newest 40 in ascending order: {newest}"
    let (tail, _, _, _) ← call #[("limit", .nat 3)]
    check (tail == #[43, 44, 45]) s!"limit takes the newest events: {tail}"
    -- since_seq: only what came after.
    let (delta, _, deltaMore, _) ← call #[("since_seq", .nat 42)]
    check (delta == #[43, 44, 45] && !deltaMore) s!"since_seq returns the events after it: {delta}"
    let (after, _, _, _) ← call #[("since_seq", .nat 45)]
    check (after.isEmpty) "nothing after the last event"
    let (firstAfter, _, afterMore, _) ← call #[("since_seq", .nat 10), ("limit", .nat 2)]
    check (firstAfter == #[11, 12] && afterMore) s!"a limited delta starts right after the cursor: {firstAfter}"
    -- before_seq: page backwards, and it wins over since_seq.
    let (earlier, _, earlierMore, _) ← call #[("before_seq", .nat 6), ("limit", .nat 3)]
    check (earlier == #[3, 4, 5] && earlierMore) s!"before_seq returns the newest events below it: {earlier}"
    let (both, _, _, _) ← call #[("before_seq", .nat 6), ("since_seq", .nat 40), ("limit", .nat 2)]
    check (both == #[4, 5]) s!"before_seq takes precedence: {both}"
    let (start, _, startMore, _) ← call #[("before_seq", .nat 3)]
    check (start == #[1, 2] && !startMore) "the first page reports nothing earlier"
    -- Views filter by kind before the limit is applied.
    let (_, transcript, _, _) ← call #[("view", .str "transcript"), ("limit", .nat 6)]
    check (transcript.size == 6 && transcript.all (fun t => t == "user_message" || t == "assistant_message"))
      s!"the transcript view holds only messages: {transcript}"
    let (_, trace, _, _) ← call #[("view", .str "trace"), ("limit", .nat 6)]
    check (trace.size == 6 && trace.all (fun t => t == "tool_call" || t == "tool_result")) s!"the trace view holds only tool events: {trace}"
    let (capped, _, _, _) ← call #[("view", .str "all"), ("limit", .nat 500)]
    check (capped == range 1 45) s!"view=all returns at most 50 events, here all 45: {capped.size}"
    let (cappedTail, _, _, _) ← call #[("view", .str "all"), ("limit", .nat 500), ("before_seq", .nat 100)]
    check (cappedTail.size == 45) "an out-of-range cursor is harmless"
  finally
    closeCoreStore store

end OrbCore.MissionEventsToolTests
