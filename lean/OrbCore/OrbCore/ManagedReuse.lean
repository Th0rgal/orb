import OrbCore.Store
import OrbCore.Managed
import OrbCore.LegacyHydrate

/-!
  Reuse of an idle managed VM by a sibling mission.

  `start_mission(auto-managed)` rents a VM per child. When a child has ended and
  its VM is still running with useful time left, the next child of the same
  parent takes that VM over instead of renting another: nothing new is rented
  and no budget is reserved. Only a VM that was itself rented for a child (its
  requester differs from its owner) is a candidate; a VM a mission spawned for
  itself is never taken.

  The transfer is one compare-and-set on the owner, so two concurrent starts
  cannot both take the same VM.
-/

namespace OrbCore.ManagedReuse

open OrbCore.Store OrbCore.Managed OrbCore.LegacyHydrate

/-- A reused VM must outlive the handover by at least this much. -/
def minRemainingSecs : UInt64 := 15 * 60

/-- A VM that has not polled this recently is not known to be usable. -/
def maxPollAgeSecs : UInt64 := 120

/-- Statuses in which a mission holds no turn and none is scheduled. -/
def missionEnded (status : String) : Bool :=
  #["completed", "failed", "cancelled", "canceled", "archived", "acknowledged"].contains status

structure Request where
  provider : String
  size : String
  /-- The mission starting the child: parent of both the old and the new owner. -/
  parentMission : String
  userId : String
  project : String
  now : UInt64

structure Claimed where
  machine : ManagedMachine
  previousOwner : String

private def hasActiveJobs (store : CoreStore) (machineId : String) : IO Bool := do
  match ← execParamQuery store.missionsDb
      ("SELECT 1 FROM remote_node_jobs WHERE node_id=?1 AND state NOT IN " ++
       "('terminal','completed','succeeded','failed','aborted','cancelled','lost') LIMIT 1;") #[s!"managed-{machineId}"] with
  | .ok rows => return rows.size > 1
  -- The ledger table is created with the first remote job.
  | .error _ => return false

/-- The previous owner must have ended and be a sibling under the same tenant and project. -/
private def siblingEnded (store : CoreStore) (req : Request) (ownerMission : String) : IO Bool := do
  let some owner ← getMission? store ownerMission | return false
  return missionEnded owner.status && owner.parentMissionId == req.parentMission &&
    owner.ownerUserId == req.userId && owner.project == req.project

/-- Take over one idle sibling VM for `newOwner`, or `none` when there is none.
    `newOwner` is recorded as owner at once; the caller re-points it to the child
    mission once that exists, and calls `restore` if the start fails. -/
def claim (store : CoreStore) (mc : ManagedComputeStore) (req : Request) (newOwner : String) :
    IO (Option Claimed) := do
  if req.parentMission.isEmpty || newOwner.isEmpty then return none
  let .ok rows ← execParamQuery mc.db
      ("SELECT m.id,m.owner_mission FROM managed_machines m WHERE m.provider=?1 AND m.size=?2 AND m.phase_code=1 " ++
       "AND m.cordoned=0 AND m.owner_kind='mission' AND m.owner_mission<>'' AND m.owner_user_id=?3 " ++
       "AND m.requested_by_mission_id=?4 AND m.requested_by_mission_id<>m.owner_mission " ++
       "AND m.expires_at_sec>=?5 AND m.last_poll_sec>=?6 " ++
       "AND NOT EXISTS (SELECT 1 FROM managed_expirations e WHERE e.machine_id=m.id AND e.boot_epoch=m.node_boot_epoch) " ++
       "ORDER BY m.expires_at_sec DESC, m.id;")
      #[req.provider, req.size, req.userId, req.parentMission, s!"{req.now + minRemainingSecs}",
        s!"{req.now - min req.now maxPollAgeSecs}"]
    | return none
  for row in rows.extract 1 rows.size do
    let machineId := cell row 0
    let previousOwner := cell row 1
    if !(← siblingEnded store req previousOwner) then continue
    if ← hasActiveJobs store machineId then continue
    let .ok taken ← execParamQuery mc.db
        ("UPDATE managed_machines SET owner_mission=?3 WHERE id=?1 AND owner_mission=?2 AND phase_code=1 " ++
         "AND cordoned=0 RETURNING id;") #[machineId, previousOwner, newOwner]
      | continue
    if taken.size < 2 then continue
    let some (machine, _) ← getManagedMachine? mc machineId | continue
    return some { machine, previousOwner }
  return none

/-- Undo a claim whose mission could not be started. -/
def restore (mc : ManagedComputeStore) (claimed : Claimed) : IO Unit := do
  discard <| execParamQuery mc.db
    "UPDATE managed_machines SET owner_mission=?2 WHERE id=?1 AND phase_code=1;"
    #[claimed.machine.id, claimed.previousOwner]

end OrbCore.ManagedReuse
