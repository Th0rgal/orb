import LeanSys
import Orb.Kernel
import OrbBin.Json
import Std.Data.HashMap

/-
  OrbLocald.NativeChrome — Canonical single-owner sidebar row projection & `Cmd+K` palette
  engine for Hybrid Native Chrome (`macos_shell` AppKit + `linux_shell` GTK3).
  - `0 import Lean`, `0 sorryAx`
  - Every deduplication, visibility/cycle, and move-target admission decision routes
    through `Orb.Kernel` (`sidebarMergeStep`, `sidebarVisibility`, `sidebarMoveTargetAdmit`).
  - Substring & trigram candidate scoring reuses `LeanSys.Search`.
-/

namespace OrbLocald.NativeChrome

open OrbBin.Json

def maxNativeChromeScopes : Nat := 8

structure ChromeProjectInput where
  slug    : String
  name    : String
  color   : String := ""
  folders : Array String := #[]
  files   : Array String := #[]
  deriving Repr, Inhabited, BEq

structure ChromeMissionInput where
  id              : String
  title           : String
  status          : String := "completed"
  project         : String := ""
  folder          : String := ""
  hasProjectField : Bool := true
  hasFolderField  : Bool := true
  parentMissionId : String := ""
  forkSourceId    : String := ""
  isFork          : Bool := false
  isBtwDirect     : Bool := false
  acknowledged    : Bool := false
  superseded      : Bool := false
  createdAtMs     : UInt64 := 0
  updatedAtMs     : UInt64 := 0
  deriving Repr, Inhabited, BEq

structure SidebarRow where
  rowId          : String
  kind           : String
  depth          : Nat := 0
  title          : String
  subtitle       : String := ""
  target         : String := ""
  project        : String := ""
  folder         : String := ""
  status         : String := ""
  shortcut       : String := ""
  icon           : String := ""
  color          : String := ""
  badge          : Nat := 0
  childCount     : Nat := 0
  liveChildCount : Nat := 0
  expandable     : Bool := false
  expanded       : Bool := false
  selected       : Bool := false
  attention      : Bool := false
  deriving Repr, Inhabited, BEq

def SidebarRow.toJson (r : SidebarRow) : JVal :=
  .obj #[
    ("row_id", .str r.rowId),
    ("kind", .str r.kind),
    ("depth", .nat r.depth),
    ("title", .str r.title),
    ("subtitle", .str r.subtitle),
    ("target", .str r.target),
    ("project", .str r.project),
    ("folder", .str r.folder),
    ("status", .str r.status),
    ("shortcut", .str r.shortcut),
    ("icon", .str r.icon),
    ("color", .str r.color),
    ("badge", .nat r.badge),
    ("child_count", .nat r.childCount),
    ("live_child_count", .nat r.liveChildCount),
    ("expandable", .bool r.expandable),
    ("expanded", .bool r.expanded),
    ("selected", .bool r.selected),
    ("attention", .bool r.attention)
  ]

structure PaletteItem where
  itemId   : String
  kind     : String
  title    : String
  subtitle : String := ""
  target   : String
  status   : String := ""
  shortcut : String := ""
  icon     : String := ""
  color    : String := ""
  score    : Nat := 0
  deriving Repr, Inhabited, BEq

def PaletteItem.toJson (p : PaletteItem) : JVal :=
  .obj #[
    ("id", .str p.itemId),
    ("kind", .str p.kind),
    ("title", .str p.title),
    ("subtitle", .str p.subtitle),
    ("target", .str p.target),
    ("status", .str p.status),
    ("shortcut", .str p.shortcut),
    ("icon", .str p.icon),
    ("color", .str p.color),
    ("score", .nat p.score)
  ]

structure ChromeScopeState where
  scope         : String
  syncRevision  : UInt64 := 0
  viewRevision  : UInt64 := 0
  selected      : String := ""
  onSettings    : Bool := false
  isAdmin       : Bool := true
  inboxEnabled  : Bool := true
  inboxUnread   : Nat := 0
  settingsBadge : Nat := 0
  settingsDots  : Array String := #[]
  projects      : Array ChromeProjectInput := #[]
  missions      : Array ChromeMissionInput := #[]
  expandedIds   : Array String := #[]
  collapsedIds  : Array String := #[]
  hydratedOnly  : Bool := false
  deriving Repr, Inhabited

structure NativeChromeHub where
  activeScope : String := ""
  scopes      : Array ChromeScopeState := #[]
  deriving Repr, Inhabited

/-- Normalize a relative folder path (`"a/b/"` -> `"a/b"`, `"/"` or `"."` -> `""`). -/
def normalizeFolderPath (raw : String) : String :=
  let parts := (raw.trimAscii.toString.splitOn "/").filterMap fun seg =>
    let clean := seg.trimAscii.toString
    if clean.isEmpty || clean == "." || clean == ".." then none else some clean
  String.intercalate "/" parts

/-- Parent folder path of a normalized relative folder (`"ui/desktop"` -> `"ui"`, `"ui"` -> `""`). -/
def parentFolderPath (normPath : String) : String :=
  let clean := normalizeFolderPath normPath
  if clean.isEmpty then ""
  else
    let parts := clean.splitOn "/"
    if parts.length ≤ 1 then ""
    else String.intercalate "/" (parts.dropLast)

/-- Basename of a normalized relative folder (`"ui/desktop"` -> `"desktop"`). -/
def basenameFolderPath (normPath : String) : String :=
  let clean := normalizeFolderPath normPath
  if clean.isEmpty then ""
  else (clean.splitOn "/").getLast?.getD clean

/-- Expand `"ui/desktop"` into `["ui", "ui/desktop"]` so ancestor folders always exist. -/
def ancestorFolderPaths (normPath : String) : Array String := Id.run do
  let clean := normalizeFolderPath normPath
  if clean.isEmpty then return #[]
  let parts := clean.splitOn "/"
  let mut acc : Array String := #[]
  let mut cur := ""
  for seg in parts do
    cur := if cur.isEmpty then seg else cur ++ "/" ++ seg
    acc := acc.push cur
  return acc

private def isLeapYearUtc (y : Nat) : Bool :=
  (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

private def daysInMonthUtc (y m : Nat) : Nat :=
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
  | 4 | 6 | 9 | 11 => 30
  | 2 => if isLeapYearUtc y then 29 else 28
  | _ => 0

/-- Parse an ISO-8601 / RFC-3339 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff...](Z|±HH:MM)`) into UTC epoch milliseconds. -/
def parseIso8601EpochMs? (raw : String) : Option UInt64 := do
  let s := raw.trimAscii.toString
  if s.isEmpty then none
  let (datePart, rest0) ← match s.splitOn "T" with
    | [d, t] => some (d, t)
    | _ => match s.splitOn "t" with
      | [d, t] => some (d, t)
      | _ => match s.splitOn " " with
        | [d, t] => some (d, t)
        | _ => none
  let [yStr, mStr, dStr] := datePart.splitOn "-" | none
  if yStr.length != 4 || mStr.length != 2 || dStr.length != 2 then none
  if !yStr.all Char.isDigit || !mStr.all Char.isDigit || !dStr.all Char.isDigit then none
  let y ← yStr.toNat?
  let mo ← mStr.toNat?
  let da ← dStr.toNat?
  if y < 1970 || y > 9999 || mo < 1 || mo > 12 || da < 1 || da > daysInMonthUtc y mo then none
  let (timePart, tzOffsetSec) ←
    if rest0.endsWith "Z" || rest0.endsWith "z" then
      some ((rest0.dropEnd 1).toString, (0 : Int))
    else if rest0.length > 6 then
      let tzSignPos := rest0.length - 6
      let pfx := (rest0.take tzSignPos).toString
      let sfx := (rest0.drop tzSignPos).toString
      let signChar := sfx.toList.headD ' '
      if signChar != '+' && signChar != '-' then
        some (rest0, (0 : Int))
      else
        match (sfx.drop 1).toString.splitOn ":" with
        | [ohS, omS] =>
          if ohS.length != 2 || omS.length != 2 || !ohS.all Char.isDigit || !omS.all Char.isDigit then none
          else
            let oh ← ohS.toNat?
            let om ← omS.toNat?
            if oh > 23 || om > 59 then none
            else
              let mag : Int := Int.ofNat (oh * 3600 + om * 60)
              some (pfx, if signChar == '+' then mag else -mag)
        | _ => none
    else
      some (rest0, (0 : Int))
  let (baseTime, fracMs) ← match timePart.splitOn "." with
    | [h] => some (h, (0 : UInt64))
    | [h, frac] =>
      let digits := (frac.takeWhile Char.isDigit).toString
      if digits.isEmpty then none
      else
        let d3 := ((digits ++ "000").take 3).toString
        some (h, (d3.toNat?.getD 0).toUInt64)
    | _ => none
  let [hhS, mmS, ssS] := baseTime.splitOn ":" | none
  if hhS.length != 2 || mmS.length != 2 || ssS.length != 2 then none
  if !hhS.all Char.isDigit || !mmS.all Char.isDigit || !ssS.all Char.isDigit then none
  let hh ← hhS.toNat?
  let mm ← mmS.toNat?
  let ss ← ssS.toNat?
  if hh > 23 || mm > 59 || ss > 60 then none
  let mut yearDays : Nat := 0
  for yr in [1970:y] do
    yearDays := yearDays + (if isLeapYearUtc yr then 366 else 365)
  let mut monthDays : Nat := 0
  for mn in [1:mo] do
    monthDays := monthDays + daysInMonthUtc y mn
  let totalDays : Int := Int.ofNat (yearDays + monthDays + (da - 1))
  let utcSec : Int := totalDays * 86400 + Int.ofNat (hh * 3600 + mm * 60 + ss) - tzOffsetSec
  if utcSec < 0 then none else some (utcSec.toNat.toUInt64 * 1000 + fracMs)

private def normalizeEpochScale (n : UInt64) : UInt64 :=
  if n > 0 && n < 100000000000 then n * 1000 else n

/-- Normalize explicit `created_at_ms` / `createdAtMs` or ISO-8601 `created_at` / `createdAt` to UTC epoch milliseconds. -/
def parseCreatedAtMs (jv : JVal) : UInt64 := Id.run do
  if let some n := jv.fieldUInt64? "created_at_ms" then
    return normalizeEpochScale n
  if let some n := jv.fieldUInt64? "createdAtMs" then
    return normalizeEpochScale n
  for key in #["created_at", "createdAt"] do
    if let some n := jv.fieldUInt64? key then
      return normalizeEpochScale n
    if let some s := jv.fieldStr? key then
      let clean := s.trimAscii.toString
      if let some ms := parseIso8601EpochMs? clean then
        return ms
      if let some dec := clean.toNat? then
        return normalizeEpochScale dec.toUInt64
  return 0

/-- Normalize explicit `updated_at_ms` / `updatedAtMs` or ISO-8601 `updated_at` / `created_at` to UTC epoch milliseconds. -/
def parseUpdatedAtMs (jv : JVal) : UInt64 := Id.run do
  if let some n := jv.fieldUInt64? "updated_at_ms" then
    return normalizeEpochScale n
  if let some n := jv.fieldUInt64? "updatedAtMs" then
    return normalizeEpochScale n
  for key in #["updated_at", "updatedAt", "created_at", "createdAt"] do
    if let some n := jv.fieldUInt64? key then
      return normalizeEpochScale n
    if let some s := jv.fieldStr? key then
      let clean := s.trimAscii.toString
      if let some ms := parseIso8601EpochMs? clean then
        return ms
      if let some dec := clean.toNat? then
        return normalizeEpochScale dec.toUInt64
  return 0

private def normalizeProjectColor (raw : String) : String :=
  let c := raw.trimAscii.toString.toLower
  if c == "#8aaed4" || c == "blue" then "#8aaed4"
  else if c == "#94b89a" || c == "green" then "#94b89a"
  else if c == "#c5aa70" || c == "amber" then "#c5aa70"
  else if c == "#cb929f" || c == "rose" then "#cb929f"
  else if c == "#ad9acb" || c == "purple" then "#ad9acb"
  else ""

def parseProjectInput? (jv : JVal) : Option ChromeProjectInput := do
  let slug := ((jv.fieldStr? "slug").orElse (fun _ => jv.fieldStr? "id")).getD "" |>.trimAscii.toString
  if slug.isEmpty then none
  let name := ((jv.fieldStr? "name").orElse (fun _ => jv.fieldStr? "title")).getD slug |>.trimAscii.toString
  let color := normalizeProjectColor ((jv.fieldStr? "color").getD "")
  let rawFolders := (jv.fieldArr? "folders").getD #[]
  let folders := rawFolders.filterMap fun f =>
    let p := match f.asStr? with
      | some s => normalizeFolderPath s
      | none => normalizeFolderPath ((f.fieldStr? "path").getD "")
    if p.isEmpty || p == "attachments" then none else some p
  let rawFiles := (jv.fieldArr? "files").getD #[]
  let files := rawFiles.filterMap fun f =>
    let p := match f.asStr? with
      | some s => normalizeFolderPath s
      | none => normalizeFolderPath ((f.fieldStr? "path").getD "")
    if p.isEmpty || p.startsWith "attachments/" then none else some p
  some { slug := slug, name := if name.isEmpty then slug else name, color := color, folders := folders, files := files }

def parseMissionInput? (jv : JVal) (fallbackProject : String := "") : Option ChromeMissionInput := do
  let id := (jv.fieldStr? "id").getD "" |>.trimAscii.toString
  if id.isEmpty then none
  let rawTitle := ((jv.fieldStr? "title").orElse (fun _ => jv.fieldStr? "delivered_prompt")).getD "Untitled"
  let firstLine := ((rawTitle.splitOn "\n").head?.getD rawTitle).trimAscii.toString
  let title := if firstLine.isEmpty then "Untitled" else firstLine
  let status := (jv.fieldStr? "status").getD "completed" |>.trimAscii.toString
  let statusLower := status.toLower
  let hasProjField := (jv.field? "project").isSome || !fallbackProject.isEmpty
  let proj :=
    match jv.field? "project" with
    | some .null => ""
    | some v => (v.asStr?.getD "").trimAscii.toString
    | none => fallbackProject.trimAscii.toString
  let hasFolderField := (jv.field? "folder").isSome
  let folder :=
    match jv.field? "folder" with
    | some .null => ""
    | some v => normalizeFolderPath (v.asStr?.getD "")
    | none => ""
  let rawParentId :=
    ((jv.fieldStr? "parent_mission_id")
      |>.orElse (fun _ => jv.fieldStr? "parentMissionId")).getD ""
      |>.trimAscii.toString
  let callbackParentId :=
    ((jv.fieldStr? "callback_parent_mission_id")
      |>.orElse (fun _ => jv.fieldStr? "callbackParentMissionId")).getD ""
      |>.trimAscii.toString
  let relKind :=
    ((jv.fieldStr? "parent_kind").orElse (fun _ => jv.fieldStr? "relation_kind")).getD ""
      |>.trimAscii.toString.toLower
  let tags := ((jv.fieldArr? "tags").getD #[]).filterMap (·.asStr?)
  let hasBtwTag := tags.any (fun t => t.startsWith "btw-parent:" || t == "btw-subagent")
  let isBtwDirect := (jv.fieldBool? "is_btw").getD hasBtwTag
  let forkTagSource :=
    (tags.findSome? fun t =>
      if t.startsWith "fork-of:" then
        let src := (t.drop 8).trimAscii.toString
        if src.isEmpty then none else some src
      else none).getD ""
  let explicitForkOf :=
    ((jv.fieldStr? "fork_of").orElse (fun _ => jv.fieldStr? "forkOf")).getD ""
      |>.trimAscii.toString
  let legacyForkTitle := title.toLower.endsWith " · fork"
  let forkSrc :=
    if !explicitForkOf.isEmpty then explicitForkOf
    else if !forkTagSource.isEmpty then forkTagSource
    else if !rawParentId.isEmpty && (legacyForkTitle || relKind == "fork") then rawParentId
    else ""
  let isFork := (jv.fieldBool? "is_fork").getD (!forkSrc.isEmpty || relKind == "fork" || legacyForkTitle)
  -- Matching `missionParent` in `orb/src/missionTree.ts`: a fork is never launched work of its fork source.
  let launchedParentId :=
    let direct := if !forkSrc.isEmpty && forkSrc == rawParentId then "" else rawParentId
    if !direct.isEmpty then direct else callbackParentId
  let statusArchived := statusLower == "acknowledged" || statusLower == "archived"
  let ack :=
    (jv.fieldBool? "acknowledged").getD
      ((jv.fieldBool? "archived").getD statusArchived)
  let succId :=
    ((jv.fieldStr? "superseded_by_mission_id").orElse (fun _ => jv.fieldStr? "superseded_by")).getD ""
      |>.trimAscii.toString
  let sup :=
    (jv.fieldBool? "superseded").getD
      (statusLower == "superseded" || !succId.isEmpty)
  some {
    id := id
    title := title
    status := status
    project := proj
    folder := folder
    hasProjectField := hasProjField
    hasFolderField := hasFolderField
    parentMissionId := launchedParentId
    forkSourceId := forkSrc
    isFork := isFork
    isBtwDirect := isBtwDirect
    acknowledged := ack
    superseded := sup
    createdAtMs := parseCreatedAtMs jv
    updatedAtMs := parseUpdatedAtMs jv
  }

/-- Deduplicate and merge mission inputs via `Orb.Kernel.sidebarMergeStep` (`orb_sidebar_merge_step`).
    Superseded inputs remain in the merged set (`incomingSupersededOrArchived = 0`) so projection can
    preserve running and currently-selected superseded conversations (`isSupersededInTree` in `orb/src/missionTree.ts`). -/
def mergeMissionInputs (inputs : Array ChromeMissionInput) : Array ChromeMissionInput := Id.run do
  let mut ordById : Std.HashMap String UInt32 := {}
  let mut nextOrd : UInt32 := 1
  let mut idxById : Std.HashMap String Nat := {}
  let mut acc : Array ChromeMissionInput := #[]
  for inc in inputs do
    let incOrd ←
      match ordById[inc.id]? with
      | some ord => pure ord
      | none =>
        let ord := nextOrd
        ordById := ordById.insert inc.id ord
        nextOrd := nextOrd + 1
        pure ord
    match idxById[inc.id]? with
    | none =>
      let verdict := Orb.Kernel.sidebarMergeStep 0 incOrd 0 inc.updatedAtMs 0 0
      let hi32 : UInt32 := ((verdict >>> 32) &&& 0xFFFFFFFF).toUInt32
      if hi32 == 1 then
        idxById := idxById.insert inc.id acc.size
        acc := acc.push inc
    | some idx =>
      let ex := acc[idx]!
      let verdict := Orb.Kernel.sidebarMergeStep incOrd incOrd ex.updatedAtMs inc.updatedAtMs 0 0
      let lo32 : UInt32 := (verdict &&& 0xFFFFFFFF).toUInt32
      if (lo32 &&& 1) != 0 then
        let mergedProj := if inc.hasProjectField then inc.project else ex.project
        let mergedFolder := if inc.hasFolderField then inc.folder else ex.folder
        let mergedParent := if inc.parentMissionId.isEmpty then ex.parentMissionId else inc.parentMissionId
        let mergedForkSrc := if inc.forkSourceId.isEmpty then ex.forkSourceId else inc.forkSourceId
        let mergedCreated := if inc.createdAtMs > 0 then inc.createdAtMs else ex.createdAtMs
        acc := acc.set! idx {
          inc with
          project := mergedProj
          folder := mergedFolder
          hasProjectField := inc.hasProjectField || ex.hasProjectField
          hasFolderField := inc.hasFolderField || ex.hasFolderField
          parentMissionId := mergedParent
          forkSourceId := mergedForkSrc
          isFork := inc.isFork || ex.isFork || !mergedForkSrc.isEmpty
          isBtwDirect := inc.isBtwDirect || ex.isBtwDirect
          superseded := inc.superseded || ex.superseded
          createdAtMs := mergedCreated
        }
      else
        -- Even when an older duplicate is ignored, sticky lineage/btw markers are preserved (`withHierarchy`).
        let mergedParent := if ex.parentMissionId.isEmpty then inc.parentMissionId else ex.parentMissionId
        let mergedForkSrc := if ex.forkSourceId.isEmpty then inc.forkSourceId else ex.forkSourceId
        acc := acc.set! idx {
          ex with
          parentMissionId := mergedParent
          forkSourceId := mergedForkSrc
          isFork := ex.isFork || inc.isFork || !mergedForkSrc.isEmpty
          isBtwDirect := ex.isBtwDirect || inc.isBtwDirect
          superseded := ex.superseded || inc.superseded
        }
  return acc

/-- Sort rank for mission status (`WORKING_STATUSES` in `orb/src/missionStatus.ts` first, then `updatedAtMs` descending, then `id`). -/
private def isWorkingMissionStatus (status : String) : Bool :=
  let s := status.toLower
  s == "active" || s == "running" || s == "starting" || s == "resuming" ||
  s == "working" || s == "in_progress" || s == "processing" || s == "streaming" ||
  s == "pending" || s == "queued" || s == "waiting_background"

private def missionActivePriority (status : String) : Nat :=
  let s := status.toLower
  if isWorkingMissionStatus s || s == "waiting_for_approval" || s == "blocked" then 0
  else 1

private def forkSettleGraceMs : UInt64 := 15000

/-- True when `m` was explicitly superseded and is no longer actively running (`isSupersededMission` in `orb/src/missionTree.ts`).
    Note: `orb/src/missionTree.ts` uses `hasTypedSuperseded` (`status == "superseded" || superseded_by_mission_id != ""`). -/
private def isSupersededStoppedMission (m : ChromeMissionInput) : Bool :=
  !isWorkingMissionStatus m.status && m.superseded

/-- True when `m` or any ancestor along `parentOf` is a stopped superseded mission (`isSupersededInTree` in `orb/src/missionTree.ts`). -/
private def isSupersededInTree
    (m : ChromeMissionInput)
    (byId : Std.HashMap String ChromeMissionInput)
    (maxHops : Nat)
    (parentOf : String → Option String) : Bool := Id.run do
  if isWorkingMissionStatus m.status then return false
  if isSupersededStoppedMission m then return true
  let mut curParent := (parentOf m.id).getD ""
  if curParent.isEmpty then return false
  let mut seen : Array String := #[m.id]
  let mut steps := 0
  while !curParent.isEmpty && !seen.contains curParent && steps < maxHops do
    seen := seen.push curParent
    match byId[curParent]? with
    | none => break
    | some row =>
      if isSupersededStoppedMission row then return true
      curParent := (parentOf row.id).getD ""
      steps := steps + 1
  return false

/-- Exclude `/btw` side sessions and every worker/descendant in their subtree (`excludeBtwMissions` in `orb/src/missionHierarchy.ts`). -/
def excludeBtwMissionInputs (rows : Array ChromeMissionInput) : Array ChromeMissionInput := Id.run do
  if !rows.any (·.isBtwDirect) then return rows
  let mut byId : Std.HashMap String ChromeMissionInput := {}
  for r in rows do
    byId := byId.insert r.id r
  let maxHops := rows.size
  return rows.filter fun m => Id.run do
    if m.isBtwDirect then return false
    let mut cur :=
      if !m.parentMissionId.isEmpty then m.parentMissionId else m.forkSourceId
    if cur.isEmpty then return true
    let mut seen : Array String := #[m.id]
    let mut steps := 0
    while !cur.isEmpty && !seen.contains cur && steps < maxHops do
      seen := seen.push cur
      match byId[cur]? with
      | none => break
      | some anc =>
        if anc.isBtwDirect then return false
        cur := if !anc.parentMissionId.isEmpty then anc.parentMissionId else anc.forkSourceId
        steps := steps + 1
    return true

private structure ForkLineageInfo where
  missionId : String
  rootId    : String
  depth     : Nat
  ancestors : Array String
  deriving Repr, Inhabited

/-- Elect fork-group leaders (`forkLeaders` in `orb/src/missionTree.ts`) using the normative
    `(unretired, working, effectiveActivity, forkDepth)` rank with the 15s `FORK_SETTLE_MS` grace window.
    Returns `missionId -> leaderId` for every member of a multi-version fork group in O(N). -/
private def electForkGroupLeaders (missions : Array ChromeMissionInput) : Std.HashMap String String := Id.run do
  if !missions.any (fun m => !m.forkSourceId.isEmpty) then return {}
  let mut byId : Std.HashMap String ChromeMissionInput := {}
  for m in missions do
    byId := byId.insert m.id m
  let mut infoById : Std.HashMap String ForkLineageInfo := {}
  let mut groupsByRoot : Std.HashMap String (Array ChromeMissionInput) := {}
  let mut rootIds : Array String := #[]
  for m in missions do
    let mut seen : Array String := #[]
    let mut ancestors : Array String := #[]
    let mut cur := m
    let mut steps := 0
    while !cur.forkSourceId.isEmpty && steps < missions.size do
      let src := cur.forkSourceId
      if seen.contains src || src == cur.id then break
      match byId[src]? with
      | none => break
      | some target =>
        seen := seen.push cur.id
        cur := target
        ancestors := ancestors.push cur.id
        steps := steps + 1
    let inf : ForkLineageInfo := { missionId := m.id, rootId := cur.id, depth := ancestors.size, ancestors := ancestors }
    infoById := infoById.insert m.id inf
    let prevGrp := (groupsByRoot[cur.id]?).getD #[]
    if prevGrp.isEmpty then rootIds := rootIds.push cur.id
    groupsByRoot := groupsByRoot.insert cur.id (prevGrp.push m)
  let mut leaders : Std.HashMap String String := {}
  for rid in rootIds do
    let group := (groupsByRoot[rid]?).getD #[]
    if group.size ≥ 2 then
      let mut effective : Std.HashMap String UInt64 := {}
      for m in group do
        effective := effective.insert m.id m.updatedAtMs
      for m in group do
        if m.createdAtMs > 0 then
          let ancs := ((infoById[m.id]?).map (·.ancestors)).getD #[]
          for ancId in ancs do
            if let some ancAct := effective[ancId]? then
              if ancAct ≤ m.createdAtMs + forkSettleGraceMs then
                let clamped := if ancAct < m.createdAtMs then ancAct else m.createdAtMs
                effective := effective.insert ancId clamped
      let getEff := fun (mid : String) => (effective[mid]?).getD 0
      let getDepth := fun (mid : String) => ((infoById[mid]?).map (·.depth)).getD 0
      let beats := fun (a b : ChromeMissionInput) =>
        let unretA : Nat := if a.acknowledged || isSupersededStoppedMission a then 0 else 1
        let unretB : Nat := if b.acknowledged || isSupersededStoppedMission b then 0 else 1
        if unretA != unretB then unretA > unretB
        else
          let workA : Nat := if isWorkingMissionStatus a.status then 1 else 0
          let workB : Nat := if isWorkingMissionStatus b.status then 1 else 0
          if workA != workB then workA > workB
          else
            let actA := getEff a.id
            let actB := getEff b.id
            if actA != actB then actA > actB
            else getDepth a.id > getDepth b.id
      let mut best := group[0]!
      for idx in [1:group.size] do
        let cand := group[idx]!
        if beats cand best then best := cand
      for m in group do
        leaders := leaders.insert m.id best.id
  return leaders

private def sortMissions (xs : Array ChromeMissionInput) : Array ChromeMissionInput :=
  xs.qsort fun a b =>
    let pa := missionActivePriority a.status
    let pb := missionActivePriority b.status
    if pa != pb then pa < pb
    else if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs
    else a.id < b.id

/-- Bounded parent-chain cycle check (`parentReachesSelf == 1` iff following `parentMissionId`
    from `m.parentMissionId` reaches `m.id` or exceeds `maxSteps` hops). -/
private def parentChainReachesSelf
    (m : ChromeMissionInput)
    (byId : Std.HashMap String ChromeMissionInput)
    (maxSteps : Nat) : Bool := Id.run do
  if m.parentMissionId.isEmpty then return false
  if m.parentMissionId == m.id then return true
  let mut cur := m.parentMissionId
  let mut steps := 0
  while !cur.isEmpty && steps < maxSteps do
    if cur == m.id then return true
    match byId[cur]? with
    | none => return false
    | some p =>
      cur := p.parentMissionId
      steps := steps + 1
  return steps ≥ maxSteps

private def matchesFilterNeedle (m : ChromeMissionInput) (needleLower : ByteArray) : Bool :=
  if needleLower.isEmpty then true
  else
    LeanSys.Search.containsBytesLower m.title.toUTF8 needleLower ||
    LeanSys.Search.containsBytesLower m.id.toUTF8 needleLower ||
    LeanSys.Search.containsBytesLower m.project.toUTF8 needleLower ||
    LeanSys.Search.containsBytesLower m.folder.toUTF8 needleLower

/-- Map a selected page id to its owning Settings section id (matching `orb/src/settingsNav.ts` and `shared/orb-spec/fixtures/settings-nav.json`). -/
def settingsSectionIdForSelected (sel : String) : Option String :=
  if sel == "settings" || sel == "users-settings" || sel == "usage-telemetry" then some "account"
  else if sel == "routing" || sel == "routing-providers" || sel == "usage-settings" || sel == "routing-keys" then some "models"
  else if sel == "skills-settings" || sel == "hermes-settings" || sel == "btw-settings" || sel == "inbox-summaries" || sel == "local-agents" || sel == "execution" then some "agents"
  else if sel.startsWith "sk:" then some "agents"
  else if sel == "security-settings" || sel == "bitwarden-settings" then some "security"
  else if sel == "inbox-settings" then some "notifications"
  else none

private def settingsSectionsMeta : Array (String × String × String) := #[
  ("account", "Account", "settings"),
  ("models", "Models", "routing"),
  ("agents", "Agents", "skills-settings"),
  ("security", "Security", "security-settings"),
  ("notifications", "Notifications", "inbox-settings")
]

private def settingsSectionIcon (secId : String) : String :=
  if secId == "account" then "gear"
  else if secId == "models" then "cube"
  else if secId == "agents" then "skills"
  else if secId == "security" then "key"
  else if secId == "notifications" then "bell"
  else "gear"

private def isSelectedMissionTarget (sel : String) (mid : String) : Bool :=
  sel == s!"m:{mid}" || sel == s!"ms:{mid}" || sel == s!"rm:{mid}"

/-- Project the pinned bottom Settings footer row (`sb-foot` / `.gear-btn` in `orb/src/App.tsx`). -/
def projectSidebarFooter (st : ChromeScopeState) : SidebarRow :=
  let sel := st.selected.trimAscii.toString
  let inSettings := st.onSettings || (settingsSectionIdForSelected sel).isSome
  {
    rowId := "nav:settings"
    kind := "footer"
    depth := 0
    title := "Settings"
    target := "settings"
    icon := "gear"
    badge := st.settingsBadge
    selected := inSettings
    attention := !st.settingsDots.isEmpty
  }

/-- Slug of the catch-all project (`DEFAULT_PROJECT` in `orb/src/defaultProject.ts`). -/
def defaultProjectSlug : String := "default"

/-- Row id of the sidebar's Archived section toggle. -/
def archiveRowId : String := "archive"

/-- Project canonical flat `Array SidebarRow` from `ChromeScopeState` + optional `filterQuery`. -/
def projectSidebarRows (st : ChromeScopeState) (filterQuery : String := "") : Array SidebarRow := Id.run do
  let sel := st.selected.trimAscii.toString
  let inSettings := st.onSettings || (settingsSectionIdForSelected sel).isSome
  if inSettings then
    let activeSec := (settingsSectionIdForSelected sel).getD "account"
    let mut srows : Array SidebarRow := #[
      {
        rowId := "nav:settings-back"
        kind := "nav"
        depth := 0
        title := "Back"
        target := "settings-back"
        icon := "arrow-left"
      }
    ]
    for (secId, label, firstTab) in settingsSectionsMeta do
      if secId != "security" || st.isAdmin then
        let badge := if secId == "security" then st.settingsBadge else 0
        let attn := st.settingsDots.contains secId
        srows := srows.push {
          rowId := s!"settings:{secId}"
          kind := "settings-section"
          depth := 0
          title := label
          target := firstTab
          icon := settingsSectionIcon secId
          badge := badge
          selected := activeSec == secId
          attention := attn
        }
    return srows

  let needleLower := LeanSys.Search.asciiLowerBytes filterQuery.trimAscii.toString.toUTF8
  let filterActive := !needleLower.isEmpty
  let resolveExpanded := fun (rid : String) (defaultOpen : Bool) =>
    if filterActive then true
    else if st.expandedIds.contains rid then true
    else if st.collapsedIds.contains rid then false
    else defaultOpen

  let mut rows : Array SidebarRow := #[
    {
      rowId := "nav:new-agent"
      kind := "nav"
      depth := 0
      title := "New Agent"
      target := "new-agent"
      shortcut := "⌘N"
      icon := "new-agent"
      selected := sel.isEmpty || sel == "new-agent"
    }
  ]
  if st.inboxEnabled then
    rows := rows.push {
      rowId := "nav:inbox"
      kind := "nav"
      depth := 0
      title := "Inbox"
      target := "inbox"
      shortcut := "⌘I"
      icon := "inbox"
      badge := st.inboxUnread
      selected := sel == "inbox"
    }
  rows := rows ++ #[
    {
      rowId := "nav:cloud-agent"
      kind := "nav"
      depth := 0
      title := "Cloud agent"
      target := "cloud-agent"
      shortcut := "⌘2"
      icon := "cloud"
      selected := sel == "cloud-agent"
    },
    {
      rowId := "nav:machines"
      kind := "nav"
      depth := 0
      title := "Machines"
      target := "machines"
      shortcut := "⌘3"
      icon := "machines"
      selected := sel == "machines"
    },
    {
      rowId := "nav:providers"
      kind := "nav"
      depth := 0
      title := "Inference"
      target := "providers"
      shortcut := "⌘4"
      icon := "cube"
      selected := sel == "providers"
    },
    {
      rowId := "nav:resources"
      kind := "nav"
      depth := 0
      title := "Resources"
      target := "resources"
      shortcut := "⌘6"
      icon := "resources"
      selected := sel == "resources" || sel.startsWith "rm:"
    },
    {
      rowId := "section:projects"
      kind := "section"
      depth := 0
      title := "Projects"
    }
  ]

  -- Note: `st.missions` is already deduplicated on sync/hydration; run `excludeBtwMissionInputs` + `sortMissions` in O(N log N).
  let rawMerged := sortMissions (excludeBtwMissionInputs (mergeMissionInputs st.missions))
  let mut rawById : Std.HashMap String ChromeMissionInput := {}
  for m in rawMerged do
    rawById := rawById.insert m.id m

  -- Group fork lineages (`forkLeaders` / `nestMissions` in `orb/src/missionTree.ts`) in O(N):
  let forkLeaderMap := electForkGroupLeaders rawMerged
  let isNonLeaderVersion := fun (mid : String) =>
    match forkLeaderMap[mid]? with
    | some lid => lid != mid
    | none => false

  let mut placeOfByLeader : Std.HashMap String ChromeMissionInput := {}
  if !forkLeaderMap.isEmpty then
    for c in rawMerged do
      if let some lid := forkLeaderMap[c.id]? then
        if !placeOfByLeader.contains lid && (c.forkSourceId.isEmpty || !rawById.contains c.forkSourceId) then
          placeOfByLeader := placeOfByLeader.insert lid c

  let merged : Array ChromeMissionInput :=
    if forkLeaderMap.isEmpty then rawMerged
    else rawMerged.map fun m =>
      match forkLeaderMap[m.id]? with
      | none => m
      | some lid =>
        if lid != m.id then m
        else
          let placeOf := (placeOfByLeader[lid]?).getD m
          let effParent := if !placeOf.parentMissionId.isEmpty then placeOf.parentMissionId else m.parentMissionId
          let effProj := if !m.project.isEmpty then m.project else placeOf.project
          let effFolder := if !m.folder.isEmpty then m.folder else placeOf.folder
          { m with parentMissionId := effParent, project := effProj, folder := effFolder }

  let mut mergedById : Std.HashMap String ChromeMissionInput := {}
  for m in merged do
    mergedById := mergedById.insert m.id m
  let maxHops := merged.size + 1

  -- Determine cycle-safe parent links in O(N):
  let mut safeParentMap : Std.HashMap String String := {}
  for m in merged do
    let checkLaunchedParent := Id.run do
      if m.parentMissionId.isEmpty then return false
      match mergedById[m.parentMissionId]? with
      | none => return false
      | some p =>
        let sameProj := m.project.isEmpty || p.project.isEmpty || p.project == m.project
        if !sameProj then return false
        let reachesSelfBit : UInt8 := if parentChainReachesSelf m mergedById maxHops then 1 else 0
        let visWord := Orb.Kernel.sidebarVisibility 1 0 0 1 0 reachesSelfBit
        return (visWord &&& 65536) != 0
    match forkLeaderMap[m.id]? with
    | some lid =>
      if lid != m.id then
        safeParentMap := safeParentMap.insert m.id lid
      else if checkLaunchedParent then
        safeParentMap := safeParentMap.insert m.id m.parentMissionId
    | none =>
      if checkLaunchedParent then
        safeParentMap := safeParentMap.insert m.id m.parentMissionId

  let getSafeParent := fun (mid : String) => safeParentMap[mid]?

  -- Resolve effective `(project, folder)` along cycle-safe parent links in O(N):
  let resolveEffectivePlacement := fun (start : ChromeMissionInput) => Id.run do
    let mut cur := start
    let mut steps := 0
    while steps < maxHops do
      match safeParentMap[cur.id]? with
      | none => break
      | some pid =>
        match mergedById[pid]? with
        | none => break
        | some p =>
          cur := p
          steps := steps + 1
    let effProj := if cur.project.isEmpty then start.project else cur.project
    let effFolder := if !cur.folder.isEmpty then cur.folder else start.folder
    (effProj, effFolder)

  -- A mission Core filed under no project belongs to the catch-all Default project
  -- (`DEFAULT_PROJECT` in `orb/src/defaultProject.ts`), never at the sidebar root.
  let placedMerged := merged.map fun m =>
    let (ep, ef) := resolveEffectivePlacement m
    { m with project := if ep.isEmpty then defaultProjectSlug else ep, folder := ef }

  let mut placedById : Std.HashMap String ChromeMissionInput := {}
  for m in placedMerged do
    placedById := placedById.insert m.id m

  -- Discover any implicit projects referenced by missions that aren't in `st.projects`
  let mut projects := st.projects
  let mut projSeen : Std.HashMap String Bool := {}
  for p in projects do
    projSeen := projSeen.insert p.slug true
  for m in placedMerged do
    if !m.project.isEmpty && !projSeen.contains m.project then
      projSeen := projSeen.insert m.project true
      projects := projects.push { slug := m.project, name := if m.project == defaultProjectSlug then "Default" else m.project }

  -- Compute `directMatchSet` and bottom-up `visDescSet` in O(N):
  let mut directMatchSet : Std.HashMap String Bool := {}
  let mut directMatchIds : Array String := #[]
  for m in placedMerged do
    let isSel := isSelectedMissionTarget sel m.id
    let supHidden := isSupersededInTree m placedById maxHops getSafeParent && !isSel
    let directMatch :=
      if supHidden then false
      else if filterActive then matchesFilterNeedle m needleLower
      -- Archived conversations live only under the Archived section (which opens for a selected one).
      else !m.acknowledged
    if directMatch then
      directMatchSet := directMatchSet.insert m.id true
      directMatchIds := directMatchIds.push m.id

  let mut visDescSet : Std.HashMap String Bool := {}
  for mid in directMatchIds do
    let mut cur := mid
    let mut steps := 0
    while steps < maxHops do
      match safeParentMap[cur]? with
      | none => break
      | some pid =>
        if visDescSet.contains pid then break
        visDescSet := visDescSet.insert pid true
        cur := pid
        steps := steps + 1

  let mut retainedMissions : Array ChromeMissionInput := #[]
  for m in placedMerged do
    let mf : UInt8 := if directMatchSet.contains m.id then 1 else 0
    let hvd : UInt8 := if visDescSet.contains m.id then 1 else 0
    let ack : UInt8 := if m.acknowledged then 1 else 0
    let visWord := Orb.Kernel.sidebarVisibility mf hvd ack 0 0 0
    if (visWord &&& 1) != 0 then
      retainedMissions := retainedMissions.push m

  -- Index retained children by parent id and root/project missions by project slug in O(N):
  let mut childrenByParent : Std.HashMap String (Array ChromeMissionInput) := {}
  let mut missionsByProject : Std.HashMap String (Array ChromeMissionInput) := {}
  let mut unassigned : Array ChromeMissionInput := #[]
  for m in retainedMissions do
    if let some pid := safeParentMap[m.id]? then
      let prev := (childrenByParent[pid]?).getD #[]
      childrenByParent := childrenByParent.insert pid (prev.push m)
    else if m.project.isEmpty then
      unassigned := unassigned.push m
    if !m.project.isEmpty then
      let pprev := (missionsByProject[m.project]?).getD #[]
      missionsByProject := missionsByProject.insert m.project (pprev.push m)

  let subtreeFuel := retainedMissions.size + 1

  -- Matching `TreeView.ts` (`holdsSelected`, `countNested`, `countVersions`):
  -- Mission subtrees (`m:<id>`) default to COLLAPSED unless a descendant inside the subtree is currently selected.
  let rec missionHoldsSelectedDesc (fuel : Nat) (mid : String) : Bool :=
    match fuel with
    | 0 => false
    | fuel' + 1 =>
      let kids := (childrenByParent[mid]?).getD #[]
      kids.any (fun c => isSelectedMissionTarget sel c.id || missionHoldsSelectedDesc fuel' c.id)

  let rec countMissionDescendants (fuel : Nat) (mid : String) : Nat × Nat × Nat :=
    match fuel with
    | 0 => (0, 0, 0)
    | fuel' + 1 =>
      let kids := (childrenByParent[mid]?).getD #[]
      kids.foldl (init := (0, 0, 0)) fun (totL, liveL, totV) c =>
        let (subL, subLive, subV) := countMissionDescendants fuel' c.id
        if isNonLeaderVersion c.id then
          (totL + subL, liveL + subLive, totV + 1 + subV)
        else
          let selfLive := if isWorkingMissionStatus c.status then 1 else 0
          (totL + 1 + subL, liveL + selfLive + subLive, totV + subV)

  -- Helper to emit mission + cycle-safe descendants recursively up to bounded depth `subtreeFuel`
  -- Launched children come first in list order, followed by earlier fork versions sorted by `updatedAtMs` descending (`nestMissions`).
  let rec emitMissionSubtree (fuel : Nat) (m : ChromeMissionInput) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
    match fuel with
    | 0 => acc
    | fuel' + 1 =>
      let rawKids := (childrenByParent[m.id]?).getD #[]
      let hasChildren := !rawKids.isEmpty
      let defaultOpen := hasChildren && missionHoldsSelectedDesc subtreeFuel m.id
      let rowId := s!"m:{m.id}"
      let exp := resolveExpanded rowId defaultOpen
      let (totL, liveL, totV) :=
        if hasChildren then countMissionDescendants subtreeFuel m.id else (0, 0, 0)
      let totalCount := if totL > 0 then totL else totV
      let liveCount := if totL > 0 then liveL else 0
      let row : SidebarRow := {
        rowId := rowId
        kind := "mission"
        depth := depth
        title := m.title
        subtitle := m.status
        target := rowId
        project := m.project
        folder := m.folder
        status := m.status
        icon := "bot"
        color := ""
        childCount := totalCount
        liveChildCount := liveCount
        expandable := hasChildren
        expanded := if hasChildren then exp else false
        selected := isSelectedMissionTarget sel m.id
      }
      let nextAcc := acc.push row
      if !hasChildren || !exp then nextAcc
      else
        let launchedChildren := rawKids.filter (fun c => !isNonLeaderVersion c.id)
        let versionChildren :=
          (rawKids.filter (fun c => isNonLeaderVersion c.id)).qsort fun a b =>
            if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs else a.id < b.id
        let children := launchedChildren ++ versionChildren
        children.foldl (fun a c => emitMissionSubtree fuel' c (depth + 1) a) nextAcc

  for proj in projects do
    let projMissions := (missionsByProject[proj.slug]?).getD #[]
    let mut folderSeen : Std.HashMap String Bool := {}
    let mut folderSet : Array String := #[]
    let addAncestors := fun (seen : Std.HashMap String Bool) (arr : Array String) (p : String) => Id.run do
      let mut s := seen
      let mut out := arr
      for anc in ancestorFolderPaths p do
        if !s.contains anc then
          s := s.insert anc true
          out := out.push anc
      (s, out)
    for rawF in proj.folders do
      let (s1, o1) := addAncestors folderSeen folderSet rawF
      folderSeen := s1
      folderSet := o1
    for rawFile in proj.files do
      let fp := parentFolderPath rawFile
      if !fp.isEmpty then
        let (s1, o1) := addAncestors folderSeen folderSet fp
        folderSeen := s1
        folderSet := o1
    for m in projMissions do
      let (s1, o1) := addAncestors folderSeen folderSet m.folder
      folderSeen := s1
      folderSet := o1
    let sortedFolders := folderSet.qsort (· < ·)
    let sortedFiles :=
      if filterActive then
        (proj.files.filter fun fp => LeanSys.Search.containsBytesLower fp.toUTF8 needleLower).qsort (· < ·)
      else
        proj.files.qsort (· < ·)
    if !filterActive || !projMissions.isEmpty || !sortedFiles.isEmpty then
      let projRowId := s!"proj:{proj.slug}"
      let projHoldsSelected :=
        sel == s!"c:{proj.slug}" ||
        sel == s!"ps:{proj.slug}" ||
        sel.startsWith s!"pf:{proj.slug}:" ||
        sel.startsWith s!"pc:{proj.slug}:" ||
        projMissions.any (fun m => isSelectedMissionTarget sel m.id)
      let projDefaultOpen := projHoldsSelected || projects.size == 1
      let projExpanded := resolveExpanded projRowId projDefaultOpen
      let projIconColor := if proj.color.isEmpty then "#8a8a8a" else proj.color
      rows := rows.push {
        rowId := projRowId
        kind := "project"
        depth := 0
        title := proj.name
        target := s!"project:{proj.slug}"
        project := proj.slug
        icon := if projExpanded then "folder-open" else "folder"
        color := projIconColor
        expandable := true
        expanded := projExpanded
        selected := sel == s!"c:{proj.slug}"
      }
      if projExpanded then
        let beforeProjChildren := rows.size
        let rec emitFolderSubtree (fuel : Nat) (parentPath : String) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
          match fuel with
          | 0 => acc
          | fuel' + 1 =>
            let childFolders := sortedFolders.filter (fun fp => parentFolderPath fp == parentPath)
            let afterFolders := childFolders.foldl (init := acc) fun a fp =>
              let hasAnyDescMission := projMissions.any (fun m => m.folder == fp || m.folder.startsWith (fp ++ "/"))
              let hasAnyDescFile := sortedFiles.any (fun fileP => parentFolderPath fileP == fp || fileP.startsWith (fp ++ "/"))
              if filterActive && !hasAnyDescMission && !hasAnyDescFile then a
              else
                let fRowId := s!"folder:{proj.slug}:{fp}"
                let fHoldsSelected :=
                  sel == s!"pf:{proj.slug}:{fp}" ||
                  sel.startsWith s!"pf:{proj.slug}:{fp}/" ||
                  projMissions.any (fun m =>
                    (m.folder == fp || m.folder.startsWith (fp ++ "/")) && isSelectedMissionTarget sel m.id)
                let fExpanded := resolveExpanded fRowId (fHoldsSelected || hasAnyDescMission)
                let fRow : SidebarRow := {
                  rowId := fRowId
                  kind := "folder"
                  depth := depth
                  title := basenameFolderPath fp
                  subtitle := fp
                  target := fRowId
                  project := proj.slug
                  folder := fp
                  icon := if fExpanded then "folder-open" else "folder"
                  color := projIconColor
                  expandable := true
                  expanded := fExpanded
                }
                let a1 := a.push fRow
                if fExpanded then
                  let a2 := emitFolderSubtree fuel' fp (depth + 1) a1
                  if a2.size == a1.size && !filterActive then
                    a2.push {
                      rowId := s!"empty:{proj.slug}:{fp}"
                      kind := "note"
                      depth := depth + 1
                      title := "Empty folder"
                      project := proj.slug
                      folder := fp
                    }
                  else a2
                else a1
            let directMissions := projMissions.filter (fun m => m.folder == parentPath && (safeParentMap[m.id]?).isNone)
            let afterMissions := directMissions.foldl (fun a m => emitMissionSubtree subtreeFuel m depth a) afterFolders
            let directFiles := sortedFiles.filter (fun fileP => parentFolderPath fileP == parentPath)
            directFiles.foldl (init := afterMissions) fun a fileP =>
              let fileTarget := s!"pf:{proj.slug}:{fileP}"
              a.push {
                rowId := fileTarget
                kind := "file"
                depth := depth
                title := basenameFolderPath fileP
                subtitle := fileP
                target := fileTarget
                project := proj.slug
                folder := parentPath
                icon := "file"
                selected := sel == fileTarget
              }
        rows := emitFolderSubtree (sortedFolders.size + 2) "" 1 rows
        if rows.size == beforeProjChildren && !filterActive then
          rows := rows.push {
            rowId := s!"empty:{proj.slug}"
            kind := "note"
            depth := 1
            title := "No missions or files yet."
            project := proj.slug
          }

  -- Unassigned missions (`project == ""`)
  for m in unassigned do
    rows := emitMissionSubtree subtreeFuel m 0 rows

  -- An archived root that still holds a live descendant stays in its project (no duplicate row).
  let retainedIds : Std.HashMap String Bool := retainedMissions.foldl (fun acc m => acc.insert m.id true) {}
  -- Archived conversations (`archive-section-toggle` in `ProjectFiles.tsx`): collapsed by default,
  -- newest first, roots only (archived descendants stay with their root).
  let archivedRoots :=
    (placedMerged.filter fun m =>
      m.acknowledged && (safeParentMap[m.id]?).isNone && !retainedIds.contains m.id &&
      (!filterActive || matchesFilterNeedle m needleLower)).qsort fun a b =>
        if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs else a.id < b.id
  if !filterActive || !archivedRoots.isEmpty then
    let selArchived := placedMerged.any fun m => m.acknowledged && !retainedIds.contains m.id && isSelectedMissionTarget sel m.id
    let archExpanded := resolveExpanded archiveRowId selArchived
    rows := rows.push {
      rowId := archiveRowId
      kind := "archive"
      depth := 0
      title := "Archived"
      icon := if archExpanded then "folder-open" else "folder"
      expandable := true
      expanded := archExpanded
    }
    if archExpanded then
      if archivedRoots.isEmpty then
        rows := rows.push { rowId := "note:archive-empty", kind := "note", depth := 1, title := "No archived conversations." }
      -- Archived children and earlier fork versions stay under their archived root
      -- (newest first), so every archived conversation remains reachable.
      let mut archivedKids : Std.HashMap String (Array ChromeMissionInput) := {}
      for m in placedMerged do
        if m.acknowledged && !retainedIds.contains m.id then
          if let some pid := safeParentMap[m.id]? then
            archivedKids := archivedKids.insert pid (((archivedKids[pid]?).getD #[]).push m)
      let rec emitArchived (fuel : Nat) (m : ChromeMissionInput) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
        match fuel with
        | 0 => acc
        | fuel' + 1 =>
          let row : SidebarRow := {
            rowId := s!"m:{m.id}"
            kind := "mission"
            depth := depth
            title := m.title
            subtitle := m.status
            target := s!"m:{m.id}"
            project := m.project
            folder := m.folder
            status := m.status
            icon := "bot"
            selected := isSelectedMissionTarget sel m.id
          }
          let kids := ((archivedKids[m.id]?).getD #[]).qsort fun a b =>
            if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs else a.id < b.id
          kids.foldl (fun a c => emitArchived fuel' c (depth + 1) a) (acc.push row)
      for m in archivedRoots do
        rows := emitArchived (placedMerged.size + 1) m 1 rows

  if projects.isEmpty && unassigned.isEmpty then
    rows := rows.push {
      rowId := "note:projects-empty"
      kind := "note"
      depth := 0
      title := if st.scope.isEmpty then "No backend connected." else "No projects on the core backend."
    }

  return rows

/-- Check whether moving `(itemKind, srcProject, srcPath)` into `(dstProject, dstPath)` is admitted
    by `Orb.Kernel.sidebarMoveTargetAdmit` (`orb_sidebar_move_target_admit`). -/
def admitSidebarMove
    (itemKindStr srcProject rawSrcPath dstProject rawDstPath : String) : Bool := Id.run do
  let k := itemKindStr.trimAscii.toString.toLower
  let itemKind : UInt8 :=
    if k == "mission" || k == "0" then 0
    else if k == "folder" || k == "1" then 1
    else if k == "file" || k == "2" then 2
    else if k == "cron" || k == "3" then 3
    else 255
  let sp := srcProject.trimAscii.toString
  let dp := dstProject.trimAscii.toString
  if sp.isEmpty || dp.isEmpty || itemKind > 3 then return false
  let srcPath := normalizeFolderPath rawSrcPath
  let dstPath := normalizeFolderPath rawDstPath
  let srcParent := parentFolderPath srcPath
  let mut projTbl : Array String := #[sp]
  if dp != sp then projTbl := projTbl.push dp
  let srcProjOrd : UInt32 := 1
  let dstProjOrd : UInt32 := if dp == sp then 1 else 2
  -- Ordinal `1` = project root `""`; non-empty paths get distinct ordinals `2..`
  let mut pathTbl : Array String := #[""]
  let internPath := fun (tbl : Array String) (p : String) =>
    match tbl.findIdx? (· == p) with
    | some idx => (tbl, (idx + 1).toUInt32)
    | none => (tbl.push p, (tbl.size + 1).toUInt32)
  let (t1, srcPathOrd) := internPath pathTbl srcPath
  let (t2, srcParentOrd) := internPath t1 srcParent
  let (_, dstPathOrd) := internPath t2 dstPath
  let dstIsSelfOrSubtree : UInt8 :=
    if itemKind == 1 && sp == dp && !srcPath.isEmpty &&
       (dstPath == srcPath || dstPath.startsWith (srcPath ++ "/")) then 1
    else 0
  Orb.Kernel.sidebarMoveTargetAdmit
    itemKind dstIsSelfOrSubtree srcProjOrd srcPathOrd srcParentOrd dstProjOrd dstPathOrd == 1

/-- Score a candidate `PaletteItem` against lowercased query bytes + query trigrams (`LeanSys.Search`). -/
private def scorePaletteCandidate
    (qLower : ByteArray)
    (qTris : Array UInt32)
    (title subtitle : String)
    (baseBoost : Nat) : Option Nat := Id.run do
  if qLower.isEmpty then
    return some baseBoost
  let titleLower := LeanSys.Search.asciiLowerBytes title.toUTF8
  let exactTitle := titleLower == qLower
  let prefixTitle :=
    titleLower.size ≥ qLower.size && titleLower.extract 0 qLower.size == qLower
  let subMatchTitle := LeanSys.Search.containsBytesLower title.toUTF8 qLower
  let subMatchSub := LeanSys.Search.containsBytesLower subtitle.toUTF8 qLower
  if exactTitle then
    return some (1000 + baseBoost)
  if prefixTitle then
    return some (800 + baseBoost)
  if subMatchTitle then
    return some (600 + baseBoost)
  if subMatchSub then
    return some (400 + baseBoost)
  if qTris.size > 0 then
    let docTris := LeanSys.Search.extractTrigrams (title ++ " " ++ subtitle)
    let shared := LeanSys.Search.intersectSortedPostings
      (qTris.map LeanSys.Search.hex6BE)
      (docTris.map LeanSys.Search.hex6BE)
    if shared.size * 2 ≥ qTris.size && shared.size > 0 then
      return some (150 + shared.size * 20 + baseBoost)
  return none

/-- Query `Cmd+K` / `Ctrl+K` quick-switcher items across navigation pages, Settings sections,
    projects, and merged missions for `st`. -/
def queryPaletteItems (st : ChromeScopeState) (rawQuery : String) (limit : Nat := 24) : Array PaletteItem := Id.run do
  let qTrim := rawQuery.trimAscii.toString
  let qLower := LeanSys.Search.asciiLowerBytes qTrim.toUTF8
  let qTris := LeanSys.Search.extractTrigrams qTrim
  let cap := Nat.max 1 (Nat.min limit 100)

  let mut candidates : Array (PaletteItem × Nat) := #[]
  let navItems : Array (String × String × String × String × String × String) := #[
    ("nav:new-agent", "New Agent", "Start a new conversation", "new-agent", "⌘N", "new-agent"),
    ("nav:inbox", "Inbox", "Missions awaiting attention", "inbox", "⌘I", "inbox"),
    ("nav:cloud-agent", "Cloud agent", "Launch on managed cloud compute", "cloud-agent", "⌘2", "cloud"),
    ("nav:machines", "Machines", "Fleet nodes & managed VMs", "machines", "⌘3", "machines"),
    ("nav:providers", "Inference", "Model routing & providers", "providers", "⌘4", "cube"),
    ("nav:resources", "Resources", "Compute, memory & budgets", "resources", "⌘6", "resources")
  ]
  for (id, title, sub, target, sc, ic) in navItems do
    if id != "nav:inbox" || st.inboxEnabled then
      if let some scVal := scorePaletteCandidate qLower qTris title sub 30 then
        candidates := candidates.push ({
          itemId := id, kind := "nav", title := title, subtitle := sub, target := target, shortcut := sc, icon := ic, score := scVal
        }, scVal)

  for (secId, label, firstTab) in settingsSectionsMeta do
    if secId != "security" || st.isAdmin then
      let sub := s!"Settings · {label}"
      if let some scVal := scorePaletteCandidate qLower qTris label sub 20 then
        candidates := candidates.push ({
          itemId := s!"settings:{secId}", kind := "settings", title := label, subtitle := sub, target := firstTab, icon := settingsSectionIcon secId, score := scVal
        }, scVal)

  for proj in st.projects do
    let projCol := if proj.color.isEmpty then "#8a8a8a" else proj.color
    if let some scVal := scorePaletteCandidate qLower qTris proj.name s!"Project · {proj.slug}" 25 then
      candidates := candidates.push ({
        itemId := s!"proj:{proj.slug}", kind := "project", title := proj.name, subtitle := s!"Project · {proj.slug}", target := s!"project:{proj.slug}", icon := "folder", color := projCol, score := scVal
      }, scVal)

  let merged := sortMissions (excludeBtwMissionInputs (mergeMissionInputs st.missions))
  let mut mergedById : Std.HashMap String ChromeMissionInput := {}
  for m in merged do
    mergedById := mergedById.insert m.id m
  let maxHops := merged.size + 1
  let directParent := fun (mid : String) =>
    (mergedById[mid]?).bind fun r =>
      if r.parentMissionId.isEmpty then none else some r.parentMissionId
  let mut rankIdx : Nat := 0
  for m in merged do
    if !isSupersededInTree m mergedById maxHops directParent then
      let recencyBoost := if rankIdx < 40 then 40 - rankIdx else 0
      let activeBoost := if missionActivePriority m.status == 0 then 15 else 0
      let sub :=
        if m.project.isEmpty then m.status
        else if m.folder.isEmpty then s!"{m.project} · {m.status}"
        else s!"{m.project}/{m.folder} · {m.status}"
      if let some scVal := scorePaletteCandidate qLower qTris m.title (sub ++ " " ++ m.id) (recencyBoost + activeBoost) then
        candidates := candidates.push ({
          itemId := s!"m:{m.id}", kind := "mission", title := m.title, subtitle := sub, target := s!"m:{m.id}", status := m.status, icon := "bot", color := "", score := scVal
        }, scVal)
      rankIdx := rankIdx + 1

  let sorted := candidates.qsort fun (a, sa) (b, sb) =>
    if sa != sb then sa > sb
    else a.itemId < b.itemId
  return (sorted.take cap).map (·.1)

/-- Hydrate a `ChromeScopeState` from a persisted `ui_sidebar` JSON payload (`PersistedSidebarPayload`). -/
def parsePersistedSidebarPayload? (fallbackScope : String) (rawJson : String) : Option ChromeScopeState := do
  let .ok jv := OrbBin.Json.parse rawJson | none
  let scope := (jv.fieldStr? "scope").getD fallbackScope |>.trimAscii.toString
  if scope.isEmpty then none
  let projects := ((jv.fieldArr? "projects").getD #[]).filterMap parseProjectInput?
  let mut missions : Array ChromeMissionInput := #[]
  for m in (jv.fieldArr? "missions").getD #[] do
    if let some pm := parseMissionInput? m then
      missions := missions.push pm
  for m in (jv.fieldArr? "completedMissions").getD #[] do
    if let some pm := parseMissionInput? m then
      missions := missions.push pm
  if let some pmObj := (jv.field? "projectMissions").bind (·.asObj?) then
    for (slug, arrJv) in pmObj do
      for m in (arrJv.asArr?).getD #[] do
        if let some pm := parseMissionInput? m slug then
          missions := missions.push pm
  some {
    scope := scope
    syncRevision := 0
    viewRevision := 0
    projects := projects
    missions := mergeMissionInputs missions
    hydratedOnly := true
  }

/-- Pre-parsed `native_chrome_sync_state` payload computed outside any `IO.Ref` CAS loop. -/
structure ParsedChromeSync where
  scope         : String
  syncRevision  : UInt64
  selected      : String
  onSettings    : Bool
  isAdmin       : Bool
  inboxEnabled  : Bool
  inboxUnread   : Nat
  settingsBadge : Nat
  settingsDots  : Array String
  projects      : Array ChromeProjectInput
  missions      : Array ChromeMissionInput
  deriving Repr, Inhabited

def parseChromeSyncPayload (args : JVal) : Except String ParsedChromeSync := do
  let scope := (args.fieldStr? "scope").getD "" |>.trimAscii.toString
  if scope.isEmpty || scope.utf8ByteSize > 512 then
    throw "Invalid native_chrome_sync_state scope"
  let rev := (args.fieldUInt64? "revision").getD 1
  let selected := (args.fieldStr? "selected").getD "" |>.trimAscii.toString
  let onSettings := (args.fieldBool? "on_settings").getD false
  let isAdmin := (args.fieldBool? "is_admin").getD true
  let inboxEnabled := (args.fieldBool? "inbox_enabled").getD true
  let inboxUnread := (args.fieldNat? "inbox_unread").getD 0
  let settingsBadge := (args.fieldNat? "settings_badge").getD 0
  let settingsDots := ((args.fieldArr? "settings_dots").getD #[]).filterMap (·.asStr?)
  let projects := ((args.fieldArr? "projects").getD #[]).filterMap parseProjectInput?
  let mut missions : Array ChromeMissionInput := #[]
  for m in (args.fieldArr? "missions").getD #[] do
    if let some pm := parseMissionInput? m then
      missions := missions.push pm
  for m in (args.fieldArr? "completed_missions").getD #[] do
    if let some pm := parseMissionInput? m then
      missions := missions.push pm
  -- Explicitly archived conversations (`listArchivedMissions`), shown under the Archived section.
  for m in (args.fieldArr? "archived_missions").getD #[] do
    if let some pm := parseMissionInput? m then
      missions := missions.push pm
  if let some pmObj := (args.field? "project_missions").bind (·.asObj?) then
    for (slug, arrJv) in pmObj do
      for m in (arrJv.asArr?).getD #[] do
        if let some pm := parseMissionInput? m slug then
          missions := missions.push pm
  return {
    scope := scope
    syncRevision := rev
    selected := selected
    onSettings := onSettings
    isAdmin := isAdmin
    inboxEnabled := inboxEnabled
    inboxUnread := inboxUnread
    settingsBadge := settingsBadge
    settingsDots := settingsDots
    projects := projects
    missions := mergeMissionInputs missions
  }

/-- Apply a pre-parsed `ParsedChromeSync` in O(scopes) with monotonic `syncRevision` fencing. -/
def NativeChromeHub.applyParsedSync
    (hub : NativeChromeHub)
    (p : ParsedChromeSync) : Bool × ChromeScopeState × NativeChromeHub := Id.run do
  let existing? := hub.scopes.find? (·.scope == p.scope)
  if let some ex := existing? then
    if !ex.hydratedOnly && p.syncRevision < ex.syncRevision then
      let nextHub := { hub with activeScope := p.scope }
      return (false, ex, nextHub)
  let prevExpanded := (existing?.map (·.expandedIds)).getD #[]
  let prevCollapsed := (existing?.map (·.collapsedIds)).getD #[]
  let prevViewRev := (existing?.map (·.viewRevision)).getD 0
  let bumpedView := if prevViewRev < 0xFFFFFFFFFFFFFFFF then prevViewRev + 1 else prevViewRev
  let nextViewRev := if p.syncRevision > bumpedView then p.syncRevision else bumpedView
  let nextScope : ChromeScopeState := {
    scope := p.scope
    syncRevision := p.syncRevision
    viewRevision := nextViewRev
    selected := p.selected
    onSettings := p.onSettings
    isAdmin := p.isAdmin
    inboxEnabled := p.inboxEnabled
    inboxUnread := p.inboxUnread
    settingsBadge := p.settingsBadge
    settingsDots := p.settingsDots
    projects := p.projects
    missions := p.missions
    expandedIds := prevExpanded
    collapsedIds := prevCollapsed
    hydratedOnly := false
  }
  let others := hub.scopes.filter (·.scope != p.scope)
  let trimmed :=
    if others.size + 1 > maxNativeChromeScopes then
      others.extract (others.size + 1 - maxNativeChromeScopes) others.size
    else others
  let nextHub : NativeChromeHub := {
    activeScope := p.scope
    scopes := trimmed.push nextScope
  }
  return (true, nextScope, nextHub)

/-- Upsert a live `native_chrome_sync_state` payload into `NativeChromeHub` with monotonic `syncRevision` fencing.
    Returns `(applied, updatedScopeState, nextHub)`. -/
def NativeChromeHub.syncFromJson
    (hub : NativeChromeHub)
    (args : JVal) : Except String (Bool × ChromeScopeState × NativeChromeHub) := do
  let parsed ← parseChromeSyncPayload args
  return hub.applyParsedSync parsed

/-- Install a cold-hydrated `ChromeScopeState` if `scope` is not yet resident in `hub`. -/
def NativeChromeHub.installHydratedScope
    (hub : NativeChromeHub)
    (hydrated : ChromeScopeState) : ChromeScopeState × NativeChromeHub :=
  match hub.scopes.find? (·.scope == hydrated.scope) with
  | some existing => (existing, if hub.activeScope.isEmpty then { hub with activeScope := existing.scope } else hub)
  | none =>
    let trimmed :=
      if hub.scopes.size + 1 > maxNativeChromeScopes then
        hub.scopes.extract (hub.scopes.size + 1 - maxNativeChromeScopes) hub.scopes.size
      else hub.scopes
    let nextHub : NativeChromeHub := {
      activeScope := if hub.activeScope.isEmpty then hydrated.scope else hub.activeScope
      scopes := trimmed.push hydrated
    }
    (hydrated, nextHub)

/-- Toggle or set expansion state of `rowId` in `scope`. Returns `(expandedNow, updatedScope, nextHub)`. -/
def NativeChromeHub.toggleExpand
    (hub : NativeChromeHub)
    (scope : String)
    (rowId : String)
    (explicitExpanded? : Option Bool := none)
    (fallbackExpanded? : Option Bool := none) : Option (Bool × ChromeScopeState × NativeChromeHub) := do
  let targetScope := if scope.trimAscii.toString.isEmpty then hub.activeScope else scope.trimAscii.toString
  let cleanRow := rowId.trimAscii.toString
  if cleanRow.isEmpty then none
  let idx ← hub.scopes.findIdx? (·.scope == targetScope)
  let cur := hub.scopes[idx]!
  let curExpanded :=
    if cur.expandedIds.contains cleanRow then true
    else if cur.collapsedIds.contains cleanRow then false
    else
      match fallbackExpanded? with
      | some fb => fb
      | none => ((projectSidebarRows cur).find? (·.rowId == cleanRow)).map (·.expanded) |>.getD false
  let nextExpanded := explicitExpanded?.getD (!curExpanded)
  let nextExpandedIds :=
    if nextExpanded then
      if cur.expandedIds.contains cleanRow then cur.expandedIds else cur.expandedIds.push cleanRow
    else
      cur.expandedIds.filter (· != cleanRow)
  let nextCollapsedIds :=
    if nextExpanded then
      cur.collapsedIds.filter (· != cleanRow)
    else
      if cur.collapsedIds.contains cleanRow then cur.collapsedIds else cur.collapsedIds.push cleanRow
  let nextViewRev := if cur.viewRevision < 0xFFFFFFFFFFFFFFFF then cur.viewRevision + 1 else cur.viewRevision
  let updated := { cur with expandedIds := nextExpandedIds, collapsedIds := nextCollapsedIds, viewRevision := nextViewRev }
  let nextHub := { hub with scopes := hub.scopes.set! idx updated }
  some (nextExpanded, updated, nextHub)

end OrbLocald.NativeChrome
