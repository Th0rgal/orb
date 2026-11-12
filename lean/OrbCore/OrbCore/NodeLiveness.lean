import OrbBin.Json

/-!
  Node liveness and capacity as evidence, not assumption.

  A managed node is online only while an authenticated relay poll is recent. The
  poll time Core persisted counts as well as the in-memory relay hub, so a Core
  restart neither marks every machine offline nor, as before, every `ready`
  machine online with the current time as its last contact.

  A static node that does not answer its heartbeat keeps what its last successful
  heartbeat reported (when it was seen, how many CPUs, how much memory and disk),
  marked as cached, instead of losing its capacity and history.
-/

namespace OrbCore.NodeLiveness

open OrbBin.Json

/-- A relay poll older than this no longer proves the node is reachable. -/
def pollWindowSecs : UInt64 := 90

/-- The most recent authenticated contact, from the relay hub or the persisted poll. -/
def lastSeen (hubSeen? : Option UInt64) (persistedPollSec : UInt64) : Option UInt64 :=
  let persisted? := if persistedPollSec == 0 then none else some persistedPollSec
  match hubSeen?, persisted? with
  | some a, some b => some (max a b)
  | some a, none => some a
  | none, b => b

def relayConnected (seen? : Option UInt64) (now : UInt64) : Bool :=
  match seen? with
  | some s => now ≤ s + pollWindowSecs
  | none => false

/-- Status shown for a managed machine. `ready` in the database is a claim; only a
    recent poll makes it `online`. -/
def managedStatus (machineStatus : String) (seen? : Option UInt64) (now : UInt64) : String :=
  if machineStatus == "ready" then (if relayConnected seen? now then "online" else "offline")
  else if machineStatus == "provisioning" then "provisioning"
  else "offline"

/-- What a successful heartbeat tells us that stays true while the node is away. -/
def cachedKeys : Array String :=
  #["last_seen", "cpu_total", "mem_total_bytes", "disk_total_bytes", "capacity_total", "version"]

private def fieldsOf (value : JVal) : Array (String × JVal) :=
  match value with
  | .obj fields => fields
  | _ => #[]

private def isOnline (item : JVal) : Bool := item.fieldStr? "status" == some "online"

/-- Fold this round's probes into the cache: an online node replaces its entry, a
    silent one keeps it, and a node no longer configured is dropped. -/
def updateCache (previous : JVal) (items : Array JVal) : JVal :=
  .obj (items.filterMap fun item => do
    let id ← item.fieldStr? "id"
    if isOnline item then
      some (id, .obj (cachedKeys.filterMap fun key =>
        match item.field? key with
        | some .null | none => none
        | some value => some (key, value)))
    else
      (previous.field? id).map fun entry => (id, entry))

/-- A node that did not answer shows its last known contact and size. Live fields
    (free memory, free slots, running jobs) stay unknown. -/
def applyCache (cache : JVal) (item : JVal) : JVal :=
  if isOnline item then item else
  match item.fieldStr? "id" with
  | none => item
  | some id =>
    let entry := fieldsOf ((cache.field? id).getD .null)
    if entry.isEmpty then item else
    let known (key : String) : Option JVal := (entry.find? (·.1 == key)).map (·.2)
    let filled := (fieldsOf item).map fun (key, value) =>
      if cachedKeys.contains key && value == JVal.null then (key, (known key).getD value) else (key, value)
    let missing := entry.filter fun (key, _) => !filled.any (·.1 == key)
    .obj (filled ++ missing ++ #[("capacity_cached", .bool true)])

end OrbCore.NodeLiveness
