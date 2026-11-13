import OrbCore.Store
import OrbCore.RemoteFleetAndRelay

/-!
  Automatic placement on the static fleet.

  `auto` used to mean "the first configured node". It is now a choice among the
  nodes the mission may use: not excluded by the mission or an ancestor, not
  cordoned, not a control-plane or admin-only node, least busy first. The choice
  is made once, when the mission is created, and recorded as a concrete node so
  later turns stay with the workspace.

  An exclusion is a mission tag `exclude-node:<id>`. It binds the mission and
  every descendant.
-/

namespace OrbCore.AutoPlacement

open OrbBin.Json OrbCore.Store OrbCore.LegacyHydrate OrbCore.RemoteFleetAndRelay

private def cell (row : Array String) (i : Nat) : String := (row[i]?).getD ""

def exclusionTagPrefix : String := "exclude-node:"

def normalize (nodeId : String) : String := nodeId.trimAscii.toString.toLower

/-- Deduplicated, normalised node ids. Empty and whitespace entries are dropped. -/
def normalizeAll (nodeIds : Array String) : Array String :=
  nodeIds.foldl (init := #[]) fun acc raw =>
    let id := normalize raw
    if id.isEmpty || acc.contains id then acc else acc.push id

def exclusionsOfTags (tags : Array String) : Array String :=
  normalizeAll (tags.filterMap fun tag =>
    if tag.startsWith exclusionTagPrefix then some (tag.drop exclusionTagPrefix.length).toString else none)

/-- Nodes that host Core or are reserved for administration. Automatic placement
    never selects them; a caller allowed to use one names it explicitly. -/
def reserved (node : StaticRemoteNode) : Bool :=
  node.id == "sepolia" || node.id == "agent-core" || node.id == "orb-core" || node.id == "dgx-spark-admin" ||
  node.baseUrl.contains "10.88.0.1:" || node.baseUrl.endsWith "10.88.0.1" || node.baseUrl.contains "127.0.0.1" ||
  node.labels.contains "control-plane" || node.labels.contains "administration" || node.labels.contains "admin-only"

structure Candidate where
  id : String
  reserved : Bool := false
  cordoned : Bool := false
  activeJobs : Nat := 0
  deriving Repr, BEq

def eligible (excluded : Array String) (c : Candidate) : Bool :=
  !c.reserved && !c.cordoned && !excluded.contains (normalize c.id)

/-- Fewest active jobs wins; configuration order breaks ties. -/
def choose (candidates : Array Candidate) (excluded : Array String) : Option String :=
  let best := (candidates.filter (eligible excluded)).foldl (init := (none : Option Candidate)) fun best c =>
    match best with
    | some b => if c.activeJobs < b.activeJobs then some c else best
    | none => some c
  best.map (·.id)

/-- Exclusions declared on the mission or any ancestor. Bounded, so a corrupt
    parent cycle cannot loop. -/
def lineageExclusions (store : CoreStore) (missionId : String) : IO (Array String) := do
  let mut current := missionId.trimAscii.toString
  let mut found : Array String := #[]
  for _ in [0:16] do
    if current.isEmpty then break
    let .ok rows ← execParamQuery store.missionsDb
        "SELECT COALESCE(tags,'[]'), COALESCE(parent_mission_id,'') FROM missions WHERE id=?1;" #[current]
      | break
    if rows.size < 2 then break
    let tags := match OrbBin.Json.parse (cell rows[1]! 0) with
      | .ok (.arr items) => items.filterMap JVal.asStr?
      | _ => #[]
    found := found ++ exclusionsOfTags tags
    current := (cell rows[1]! 1).trimAscii.toString
  return normalizeAll found

def candidates (store : CoreStore) (nodes : Array StaticRemoteNode) : IO (Array Candidate) := do
  let cordons := (← loadPersistedNodeCordons store.rootDir).map normalize
  let mut load : Array (String × Nat) := #[]
  if let .ok rows ← execParamQuery store.missionsDb
      ("SELECT node_id, COUNT(*) FROM remote_node_jobs WHERE state NOT IN " ++
       "('terminal','completed','succeeded','failed','aborted','cancelled','lost') GROUP BY node_id;") #[] then
    load := (rows.extract 1 rows.size).map fun row => (normalize (cell row 0), ((cell row 1).toNat?).getD 0)
  return nodes.map fun node => {
    id := node.id
    reserved := reserved node
    cordoned := cordons.contains (normalize node.id)
    activeJobs := ((load.find? (·.1 == normalize node.id)).map (·.2)).getD 0
  }

inductive Decision where
  /-- No static fleet is configured: nothing to choose from. -/
  | noFleet
  /-- A fleet exists but every node is excluded, cordoned or reserved. -/
  | noneEligible
  | node (id : String)
  deriving Repr, BEq

def decide (store : CoreStore) (excluded : Array String) : IO Decision := do
  let (enabled, nodes) ← loadStaticRemoteNodes
  if !enabled || nodes.isEmpty then return .noFleet
  match choose (← candidates store nodes) (normalizeAll excluded) with
  | some id => return .node id
  | none => return .noneEligible

end OrbCore.AutoPlacement
