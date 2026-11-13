/-
Durable prompt managed-spawn receipts in Core's existing MCP action journal.
One winning insert schedules work. Matching retries only read the same receipt;
uncertain outcomes and restarts never automatically rent another machine.
-/
import Orb.ManagedSpawnPolicy
import OrbCore.Managed

namespace OrbCore.ManagedSpawnActions

open OrbCore.Store OrbCore.Managed OrbBin.Json OrbNetLeaf.Crypto

structure Owner where
  userId : String
  missionId : String

private def col (row : Array String) (i : Nat) : String := (row[i]?).getD ""

private def scope (owner : Owner) : String :=
  renderCompact (.arr #[.str "managed_spawn", .str owner.userId, .str owner.missionId])

/-- Only spawn-affecting inputs are journaled. Never store arbitrary body fields. -/
def canonicalRequest (args : JVal) : JVal := .obj #[
  ("provider", .str (canonicalizeProvider ((args.fieldStr? "provider").getD "boat"))),
  ("size", .str ((args.fieldStr? "size").getD "small")),
  ("ttl_minutes", JVal.uint64 ((args.fieldUInt64? "ttl_minutes").getD 60)),
  ("name", .str ((args.fieldStr? "name").orElse (fun _ => args.fieldStr? "sandbox_name") |>.getD "")),
  ("id", .str ((args.fieldStr? "id").getD "")),
  ("owner_mission_id", .str ((args.fieldStr? "owner_mission_id").getD "")),
  ("image", .str ((args.fieldStr? "image").getD "orb-node-base")),
  ("from_snapshot", .str ((args.fieldStr? "from_snapshot").orElse (fun _ => args.fieldStr? "managed_from_snapshot") |>.getD "")),
  ("project", .str ((args.fieldStr? "project").getD "")),
  ("provisioning_mode", .str ((args.fieldStr? "provisioning_mode").getD "worker")),
  ("repo", .str ((args.fieldStr? "repo").getD "")),
  ("base_key", .str ((args.fieldStr? "base_key").getD "")),
  ("lean_mode", .str ((args.fieldStr? "lean_mode").getD "auto")),
  ("memory_mib", (args.fieldUInt64? "memory_mib").map JVal.uint64 |>.getD .null),
  ("cpu", (args.fieldUInt64? "cpu").map JVal.uint64 |>.getD .null),
  ("ram_gb", (args.fieldUInt64? "ram_gb").map JVal.uint64 |>.getD .null)
]

private def receipt (id state : String) (result : JVal) : JVal := .obj #[
  ("action_id", .str id), ("accepted", .str "yes"), ("state", .str state),
  ("status", .str (if state == "succeeded" then "completed" else state)),
  ("tool_name", .str "spawn_managed_machine"), ("result", result),
  ("next_tool", .str "get_action"),
  ("poll_url", .str ("/api/managed-machines/actions/" ++ id))
]

/-- A missing/non-spawn row is distinct from an unauthorized spawn action. -/
def read? (store : CoreStore) (id : String) (owner : Owner)
    (operator : Bool := false) (requireMission : Bool := true) : IO (Except String (Option JVal)) := do
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id,state,COALESCE(result,'{}'),principal,owner FROM mcp_actions_v1 WHERE id=?1 AND tool='spawn_managed_machine' LIMIT 1;" #[id]
    | return .error "managed_action_store_unavailable"
  if rows.size ≤ 1 then return .ok none
  let row := rows[1]!
  if !operator && (col row 3 != owner.userId || (requireMission && col row 4 != owner.missionId)) then
    return .error "managed_action_not_found"
  let .ok result := OrbBin.Json.parse (col row 2)
    | return .error "managed_action_record_invalid"
  return .ok (some ((receipt (col row 0) (col row 1) result).setField "target_mission_id" (.str (col row 4))))

/-- Cancellation is truthful only before dispatch claims the action. -/
def cancel (store : CoreStore) (id : String) (owner : Owner)
    (operator : Bool := false) : IO (Except String JVal) := do
  let .ok (some _) ← read? store id owner operator
    | return .error "managed_action_not_found"
  let now := formatEpochIso8601Utc (← coreEpochSec)
  let .ok _ ← execParamQuery store.projectsDb
      "UPDATE mcp_actions_v1 SET state='cancelled',updated_at=?2 WHERE id=?1 AND tool='spawn_managed_machine' AND state='accepted';"
      #[id, now]
    | return .error "managed_action_store_unavailable"
  let .ok (some value) ← read? store id owner operator
    | return .error "managed_action_not_found"
  return .ok (value.setField "cancelled" (.bool (value.fieldStr? "state" == some "cancelled")))

private def settle (store : CoreStore) (id state : String) (result : JVal) : IO Unit := do
  let now := formatEpochIso8601Utc (← coreEpochSec)
  -- A cancelled/reconciled/restart-fenced action cannot be overwritten by a late task.
  discard <| execParamQuery store.projectsDb
    "UPDATE mcp_actions_v1 SET state=?2,result=?3,updated_at=?4 WHERE id=?1 AND state='running';"
    #[id, state, renderCompact result, now]

/-- An error that names a machine or request (`code:id`) was returned after the
    reservation, so a VM may exist or still be starting: that is never a clean
    failure. Only a bare refusal code proves nothing was left behind. -/
def uncertain (error : String) : Bool :=
  error.contains ':' ||
    #["uncertain", "pending"].any (fun fragment => (error.splitOn fragment).length > 1)

private def run (store : CoreStore) (id : String) (work : IO (Except String JVal)) : IO Unit := do
  let now := formatEpochIso8601Utc (← coreEpochSec)
  let .ok claimed ← execParamQuery store.projectsDb
      "UPDATE mcp_actions_v1 SET state='running',updated_at=?2 WHERE id=?1 AND state='accepted' RETURNING id;" #[id, now]
    | return
  if claimed.size ≤ 1 then return
  try
    match ← work with
    | .ok result => settle store id "succeeded" result
    | .error error =>
      settle store id (if uncertain error then "uncertain" else "failed")
        (.obj #[("error", .str error),
          ("http_status", .nat (if error == "provider_at_capacity" then 503 else 400))])
  catch _ =>
    settle store id "uncertain" (.obj #[("error", .str "managed_spawn_internal_outcome_uncertain")])

/-- The receipt an earlier request with this key already holds, before any
    admission is re-run: a retry must get its receipt back, not a fresh refusal. -/
def replay? (store : CoreStore) (owner : Owner) (key : String) (args : JVal) : IO (Except String (Option JVal)) := do
  if key.trimAscii.toString.isEmpty then return .ok none
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id,fingerprint,state,COALESCE(result,'{}') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2;" #[scope owner, key]
    | return .error "managed_action_store_unavailable"
  if rows.size ≤ 1 then return .ok none
  let row := rows[1]!
  if col row 1 != renderCompact (canonicalRequest args) then return .error "managed_idempotency_conflict"
  let .ok result := OrbBin.Json.parse (col row 3) | return .error "managed_action_record_invalid"
  return .ok (some (receipt (col row 0) (col row 2) result))

/-- Whether an action ID names a spawn receipt, whoever owns it. -/
def isSpawnAction (store : CoreStore) (id : String) : IO Bool := do
  match ← execParamQuery store.projectsDb
      "SELECT 1 FROM mcp_actions_v1 WHERE id=?1 AND tool='spawn_managed_machine';" #[id] with
  | .ok rows => return rows.size > 1
  | .error _ => return true

/-- Acceptance is persisted before dispatch. INSERT uniqueness fences concurrent
    requests even across processes. No provider callback runs after store failure. -/
def submit (store : CoreStore) (owner : Owner) (key : String) (args : JVal)
    (work : IO (Except String JVal))
    (admit : IO (Except String Unit) := pure (.ok ()))
    (preview : JVal := .obj #[]) : IO (Except String JVal) := do
  if key.trimAscii.toString.isEmpty || key.utf8ByteSize > 200 then
    return .error "managed_idempotency_key_required"
  let request := renderCompact (canonicalRequest args)
  let .ok prior ← execParamQuery store.projectsDb
      "SELECT id,fingerprint,state,COALESCE(result,'{}') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2;" #[scope owner, key]
    | return .error "managed_action_store_unavailable"
  if prior.size > 1 then
    let row := prior[1]!
    if col row 1 != request then return .error "managed_idempotency_conflict"
    let .ok result := OrbBin.Json.parse (col row 3) | return .error "managed_action_record_invalid"
    return .ok (receipt (col row 0) (col row 2) result)
  -- Read-only capacity/configuration preflight may reject before acceptance.
  -- A replay never repeats it, so saturation cannot revoke an existing action.
  if let .error error ← admit then return .error error
  let id ← OrbBin.PosixExt.newUuidV4
  let now := formatEpochIso8601Utc (← coreEpochSec)
  let .ok _ ← execParamQuery store.projectsDb
      ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
       "VALUES(?1,?2,?3,?4,?5,?6,'spawn_managed_machine',?5,'accepted',?8,?7,?7) ON CONFLICT(scope,retry_key) DO NOTHING;")
      #[id, owner.missionId, scope owner, key, request, owner.userId, now, renderCompact preview]
    | return .error "managed_action_store_unavailable"
  let .ok rows ← execParamQuery store.projectsDb
      "SELECT id,fingerprint,state,COALESCE(result,'{}') FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2;" #[scope owner, key]
    | return .error "managed_action_store_unavailable"
  let row? := if rows.size > 1 then some rows[1]! else none
  let stored := row?.map (fun row => (col row 0, col row 1))
  match Orb.ManagedSpawnPolicy.receiptDecision stored id request with
  | .unavailable => return .error "managed_action_store_unavailable"
  | .conflict => return .error "managed_idempotency_conflict"
  | .execute =>
    discard <| IO.asTask (prio := .dedicated) (run store id work)
    return .ok (receipt id "accepted" preview)
  | .replay =>
    let some row := row? | return .error "managed_action_store_unavailable"
    let .ok result := OrbBin.Json.parse (col row 3) | return .error "managed_action_record_invalid"
    return .ok (receipt (col row 0) (col row 2) result)

/-- Call once at Core startup, before serving requests. A crash never makes a
    pending provider side effect safe to replay, even if the caller retries. -/
def fenceInterrupted (store : CoreStore) : IO (Except String Unit) := do
  let now := formatEpochIso8601Utc (← coreEpochSec)
  match ← execParamQuery store.projectsDb
      ("UPDATE mcp_actions_v1 SET state='uncertain',result=?1,updated_at=?2 " ++
       "WHERE tool='spawn_managed_machine' AND state IN ('accepted','running');")
      #[renderCompact (.obj #[("error", .str "core_restarted_during_managed_spawn")]), now] with
  | .error _ => return .error "managed_action_recovery_failed"
  | .ok _ => return .ok ()

end OrbCore.ManagedSpawnActions
