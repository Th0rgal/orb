/-
  Project-scoped view of provider saved snapshots (`orb-snap-<project>-<label>-<suffix>`).
  The provider's list is the only evidence that a snapshot exists; the pre-cutover
  registry (`managed_snapshots.json`) only supplies the project and label where present.
  Nothing here writes to the provider or to Core state.
-/
import OrbCore.ManagedProvider

namespace OrbCore.ManagedSnapshotCatalog

open OrbCore.ManagedProvider OrbBin.Json

def snapshotPrefix : String := "orb-snap-"

/-- Lowercase `[a-z0-9-]`, at most `max` chars, no leading/trailing dash (the naming
    rule the snapshots were created with). -/
def slug (raw : String) (max : Nat := 24) : String := Id.run do
  let mut out := ""
  for c in raw.trimAscii.toString.toList do
    if out.length ≥ max then break
    let c := c.toLower
    if c.isAlphanum then out := out.push c
    else if !out.isEmpty && !out.endsWith "-" then out := out.push '-'
  let chars := out.toList.dropWhile (· == '-')
  return String.ofList (chars.reverse.dropWhile (· == '-')).reverse

structure LegacyRecord where
  name : String
  label : String
  project : String
  deriving Repr, BEq

def parseLegacyRegistry (raw : String) : Array LegacyRecord :=
  match OrbBin.Json.parse raw with
  | .ok (.arr items) => items.filterMap fun item => do
      let name ← item.fieldStr? "name"
      if name.isEmpty then none
      else some { name, label := (item.fieldStr? "label").getD "", project := (item.fieldStr? "project").getD "" }
  | _ => #[]

structure Entry where
  name : String
  label : String
  project : String
  status : String
  sizeBytes : Option UInt64
  deriving Repr, BEq, Inhabited

/-- A status the provider may still be working on, or has given up on. Anything else
    is offered; the provider itself refuses an unusable source at create time. -/
def unusableStatus (status : String) : Bool :=
  #["saving", "pending", "creating", "failed", "error", "deleting", "deleted"].contains status.toLower

/-- Which project a snapshot belongs to. A registry record decides; otherwise the name
    prefix does, and the longest known project slug wins so `verity` never claims a
    snapshot named for `verity-core`. -/
def projectOf (registry : Array LegacyRecord) (knownProjects : Array String) (name : String) : String :=
  match registry.find? (·.name == name) with
  | some record => if record.project.isEmpty then "" else slug record.project
  | none =>
    let body := (name.drop snapshotPrefix.length).toString
    let candidates := knownProjects.map (slug ·) |>.filter (fun p => !p.isEmpty && body.startsWith (p ++ "-"))
    candidates.foldl (fun best p => if p.length > best.length then p else best) ""

def labelOf (registry : Array LegacyRecord) (project name : String) : String :=
  match registry.find? (·.name == name) with
  | some record => if record.label.isEmpty then name else record.label
  | none =>
    let body := (name.drop (snapshotPrefix.length + project.length + 1)).toString
    -- Drop the random suffix after the last dash.
    match (body.splitOn "-").reverse with
    | _ :: rest@(_ :: _) => String.intercalate "-" rest.reverse
    | _ => body

/-- Snapshots of `project`, from the provider's own list. An empty project sees nothing. -/
def visible (inventory : Array Snapshot) (registry : Array LegacyRecord)
    (knownProjects : Array String) (project : String) : Array Entry :=
  let wanted := slug project
  if wanted.isEmpty then #[] else
  inventory.filterMap fun snap =>
    if !snap.name.startsWith snapshotPrefix then none
    else if projectOf registry (knownProjects.push project) snap.name != wanted then none
    else some {
      name := snap.name, label := labelOf registry wanted snap.name, project := wanted,
      status := snap.status, sizeBytes := snap.sizeBytes
    }

/-- Resolve what a caller typed (provider name or its own label) to one usable provider
    name inside the caller's project. Ambiguity is an error, never a guess. -/
def resolve (entries : Array Entry) (requested : String) : Except String String := do
  let wanted := requested.trimAscii.toString
  if wanted.isEmpty then throw "managed_snapshot_name_required"
  let byName := entries.filter (·.name == wanted)
  let hits := if byName.isEmpty then entries.filter (fun e => e.label == wanted || slug e.label == slug wanted) else byName
  if hits.isEmpty then throw "managed_snapshot_not_found_in_project"
  let usable := hits.filter (fun e => !unusableStatus e.status)
  if usable.isEmpty then throw "managed_snapshot_not_ready"
  if usable.size > 1 then
    throw ("managed_snapshot_ambiguous:" ++ String.intercalate "," (usable.map (·.name)).toList)
  return usable[0]!.name

def entryJson (e : Entry) : JVal :=
  .obj #[("name", .str e.name), ("label", .str e.label), ("project", .str e.project),
    ("status", .str e.status),
    ("size_bytes", match e.sizeBytes with | some n => JVal.uint64 n | none => .null)]

end OrbCore.ManagedSnapshotCatalog
