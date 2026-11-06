/-
  OrbCore.Managed: Pure-Lean Managed Compute Fleet (`boat.dev`), Service-Scoped Sandbox Prefix,
  Reverse Long-Poll Relay, Budget Ledger & `sandboxed-sh deploy --service` Confinement (`0 import Lean`, `0 sorryAx`).
-/
import Orb.Kernel
import OrbCore.Spec
import OrbCore.Store

namespace OrbCore.Managed

open Orb.Kernel
open OrbCore.Spec
open OrbCore.Store

/-- Service-scoped VM name prefix (`"orb-managed-"` on production or unsuffixed binaries,
    `"orb-managed-<suffix>-"` on `sandboxed-sh-<suffix>` so non-prod instances never reap prod VMs). -/
def sandboxNamePrefixFor (exeName : String) : String :=
  let base := ((exeName.splitOn "/").getLast?).getD exeName
  if base.startsWith "sandboxed-sh-" then
    let suffix := (base.drop 13).toString
    if suffix.isEmpty || suffix == "prod" then "orb-managed-"
    else s!"orb-managed-{suffix}-"
  else
    "orb-managed-"

/-- Managed machine record persisted in Core's fleet state. -/
structure ManagedMachine where
  id           : String
  sandboxName  : String
  provider     : String := "boat"
  size         : String := "small"
  status       : String := "ready"
  ownerMission : String := ""
  ttlMinutes   : UInt64 := 60
  spentCents   : UInt64 := 0
  cordoned     : Bool   := false
  deriving Repr, DecidableEq

/-- Managed fleet budget & concurrency state. -/
structure ManagedFleetState where
  enabled         : Bool   := false
  boatEnabled     : Bool   := false
  dailyCapCents   : UInt64 := 2000
  spentTodayCents : UInt64 := 0
  maxConcurrent   : UInt64 := 100
  machines        : Array ManagedMachine := #[]
  deriving Repr, DecidableEq

/-- Overflow-safe managed VM spawn admission through `Orb.Kernel.vmStep` (`orb_vm_step`). -/
def admitManagedSpawn (st : ManagedFleetState) (reqCents : UInt64) (ttlMins : UInt32 := 60) : Bool :=
  if !st.enabled then false
  else if reqCents > st.dailyCapCents || st.spentTodayCents > st.dailyCapCents - reqCents then
    false
  else
    let activeNat := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
    let active : UInt32 := (Nat.min activeNat 0xFFFFFFFF).toUInt32
    let cap : UInt32 := (Nat.min st.maxConcurrent.toNat 0xFFFFFFFF).toUInt32
    let totalSpent : UInt64 := st.spentTodayCents + reqCents
    vmStep 0 1 3 0 0 0 0 0 active cap ttlMins 720 20 totalSpent st.dailyCapCents == 1

/-- Render `/api/managed-machines/spend` & budget summary JSON. -/
def renderManagedBudgetJson (st : ManagedFleetState) : String :=
  let active := (st.machines.filter (fun m => m.status == "ready" || m.status == "provisioning")).size
  let enStr := if st.enabled then "true" else "false"
  let boatStr := if st.boatEnabled then "true" else "false"
  s!"\{\"enabled\":{enStr},\"boat_enabled\":{boatStr},\"active_machines\":{active},\"max_concurrent\":{st.maxConcurrent},\"spent_today_cents\":{st.spentTodayCents},\"daily_cap_cents\":{st.dailyCapCents}}"

/-- Map systemd unit alias (`sandboxed-sh`, `orb-core`, `sandboxed-node`, `orb-node`, `orb-privd`) to
    allowlisted `unitCode` (`1..3`) and validate via `verifyDeployUnitName` (`OrbCore.Spec`). -/
def validateDeployServiceUnit (rawUnit : String) : Except String String :=
  let trimmed := rawUnit.trimAscii.toString
  let hasTraversal : UInt8 :=
    if trimmed.contains '/' || trimmed.contains '\\' || (trimmed.splitOn "..").length > 1 then 1 else 0
  let leaf := ((trimmed.splitOn "/").getLast?).getD trimmed
  let canonical := if leaf.endsWith ".service" then (leaf.dropEnd 8).toString else leaf
  let (unitCode, systemdUnit) : UInt8 × String :=
    if canonical == "sandboxed-sh" || canonical == "orb-core" then (1, "sandboxed-sh.service")
    else if canonical == "sandboxed-node" || canonical == "orb-node" then (2, "sandboxed-node.service")
    else if canonical == "orb-privd" then (3, "orb-privd.service")
    else (0, "")
  if verifyDeployUnitName unitCode hasTraversal trimmed.utf8ByteSize.toUInt32 != 1 then
    .error s!"forbidden or invalid deploy unit `{rawUnit}`"
  else
    .ok systemdUnit

end OrbCore.Managed
