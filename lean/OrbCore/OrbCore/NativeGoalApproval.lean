import OrbCore.NativeSharedWorkspace
import OrbBin.McpCatalog

namespace OrbCore.NativeGoalApproval

open OrbCore.Store OrbBin.Json OrbBin.Sqlite
open OrbCore.NativeSharedWorkspace (Placement)

def ticketPrefix :=  "native-goal-approval-"

def currentGoal (store : CoreStore) (p : Placement) : IO Bool := do
  let .ok rows ← execParamQuery store.missionsDb
    ("SELECT j.payload_json FROM missions m JOIN remote_node_jobs j ON j.job_id=m.placement_job_id " ++
     "WHERE m.id=?1 AND j.job_id=?2 AND j.mission_id=m.id AND m.owner_user_id=?3 AND m.goal_mode=1 " ++
     "AND m.run_generation=CAST(?4 AS INTEGER) AND m.status='active' AND j.state='running';")
    #[p.mission,p.job,p.owner,toString p.runGeneration] | return false
  let some #[raw] := rows[1]? | return false
  let .ok meta := parse raw | return false
  return meta.fieldNat? "goal_generation" == some p.runGeneration

def allowedKeys := #["title","prompt","backend","model_override","remote_node_id","idempotency_key"]

def validArgs (args : JVal) : Bool := Id.run do
  let .obj fields := args | return false
  unless fields.all (fun (k,v) => allowedKeys.contains k && v.asStr?.isSome) do return false
  unless #["title","prompt","backend","model_override"].all (fun k =>
      ((args.fieldStr? k).getD "").trimAscii.toString != "") do return false
  unless #["codex","antigravity","opencode"].contains ((args.fieldStr? "backend").getD "") do return false
  return (renderCompact args).utf8ByteSize ≤ 32768

def catalogue : JVal := Id.run do
  let some raw := OrbBin.McpCatalog.catalogPrettyJsonForRole "executor" | return .arr #[]
  let .ok (.arr entries) := parse raw | return .arr #[]
  let some entry := entries.find? (fun t => t.fieldStr? "name" == some "start_mission") | return .arr #[]
  let schema := entry.fieldOrNull "inputSchema"
  let .obj props := schema.fieldOrNull "properties" | return .arr #[]
  let selected := props.filter fun (k,_) => allowedKeys.contains k
  let input := (schema.setField "properties" (.obj selected)).setField "required"
    (.arr (#["title","prompt","backend","model_override"].map JVal.str))
  return .arr #[entry.setField "inputSchema" input]

def digest (args : JVal) : String :=
  LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes (renderCompact args).toUTF8)

/-- Only the actual owner can resolve this one-shot request via the dashboard. -/
def answer (store : CoreStore) (id owner explicitMid action : String) (now : UInt64) : IO (Option String) := do
  if !id.startsWith ticketPrefix || owner.isEmpty || (action != "accept" && action != "revise") then return none
  let result := if action == "accept" then "accepted" else "declined"
  let .ok rows ← execParamQuery store.missionsDb
    ("UPDATE native_goal_approvals SET decision=?1 WHERE id=?2 AND owner=?3 AND (?4='' OR mission=?4) " ++
     "AND expires>CAST(?5 AS INTEGER) AND decision='pending' AND EXISTS(SELECT 1 FROM missions m " ++
     "WHERE m.id=mission AND m.owner_user_id=?3 AND m.placement_job_id=job AND m.status='active' AND m.goal_mode=1) RETURNING mission;")
    #[result,id,owner,explicitMid,toString now] | return none
  return rows[1]?.bind (·[0]?)

def ask (store : CoreStore) (p : Placement) (args : JVal) (now : UInt64)
    (announce : String → JVal → IO Unit) (live : IO Bool) : IO JVal := do
  unless validArgs args && (← currentGoal store p) do return .null
  let id := ticketPrefix ++ (← OrbBin.PosixExt.newUuidV4)
  let expiry := min p.expires (now.toNat + 90)
  let .ok _ ← execParamQuery store.missionsDb
    "INSERT INTO native_goal_approvals(id,mission,owner,job,input_digest,expires,decision) VALUES(?1,?2,?3,?4,?5,CAST(?6 AS INTEGER),'pending');"
    #[id,p.mission,p.owner,p.job,digest args,toString expiry] | return .null
  let title := (((args.fieldStr? "title").getD "").take 150).toString
  let model := (((args.fieldStr? "model_override").getD "").take 100).toString
  let backend := (args.fieldStr? "backend").getD ""
  let target := (((args.fieldStr? "remote_node_id").getD "automatic placement").take 100).toString
  let label := s!"Start child mission “{title}” using {backend} / {model} on {target}?"
  announce id (.obj #[("method",.str "permission"),("params",.obj #[("tool",.str "start_mission"),
    ("input",.obj #[("description",.str label),("once_only",.bool true)])])])
  for _ in [:360] do
    IO.sleep 250
    unless ← live do break
    let .ok rows ← execParamQuery store.missionsDb
      "SELECT decision FROM native_goal_approvals WHERE id=?1;" #[id] | break
    let some #[state] := rows[1]? | break
    if state == "accepted" then return .obj #[("ticket",.str id)]
    if state != "pending" then break
  discard <| execParamQuery store.missionsDb "DELETE FROM native_goal_approvals WHERE id=?1;" #[id]
  return .null

def consume (store : CoreStore) (p : Placement) (args : JVal) (ticket : String) (now : UInt64) : IO Bool := do
  unless ticket.startsWith ticketPrefix && validArgs args && (← currentGoal store p) do return false
  let .ok rows ← execParamQuery store.missionsDb
    ("DELETE FROM native_goal_approvals WHERE id=?1 AND owner=?2 AND mission=?3 AND job=?4 " ++
     "AND input_digest=?5 AND expires>CAST(?6 AS INTEGER) AND decision='accepted' RETURNING id;")
    #[ticket,p.owner,p.mission,p.job,digest args,toString now] | return false
  return rows.size == 2

end OrbCore.NativeGoalApproval
