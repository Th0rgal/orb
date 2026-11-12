import LeanSys
import Orb.Kernel
import OrbBin.Json

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
  folders : Array String := #[]
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
  rowId      : String
  kind       : String
  depth      : Nat := 0
  title      : String
  subtitle   : String := ""
  target     : String := ""
  project    : String := ""
  folder     : String := ""
  status     : String := ""
  shortcut   : String := ""
  badge      : Nat := 0
  expandable : Bool := false
  expanded   : Bool := false
  selected   : Bool := false
  attention  : Bool := false
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
    ("badge", .nat r.badge),
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
  shortcut : String := ""
  score    : Nat := 0
  deriving Repr, Inhabited, BEq

def PaletteItem.toJson (p : PaletteItem) : JVal :=
  .obj #[
    ("id", .str p.itemId),
    ("kind", .str p.kind),
    ("title", .str p.title),
    ("subtitle", .str p.subtitle),
    ("target", .str p.target),
    ("shortcut", .str p.shortcut),
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

def parseProjectInput? (jv : JVal) : Option ChromeProjectInput := do
  let slug := ((jv.fieldStr? "slug").orElse (fun _ => jv.fieldStr? "id")).getD "" |>.trimAscii.toString
  if slug.isEmpty then none
  let name := ((jv.fieldStr? "name").orElse (fun _ => jv.fieldStr? "title")).getD slug |>.trimAscii.toString
  let rawFolders := (jv.fieldArr? "folders").getD #[]
  let folders := rawFolders.filterMap fun f =>
    let p := match f.asStr? with
      | some s => normalizeFolderPath s
      | none => normalizeFolderPath ((f.fieldStr? "path").getD "")
    if p.isEmpty then none else some p
  some { slug := slug, name := if name.isEmpty then slug else name, folders := folders }

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
  let mut idTable : Array String := #[]
  let internOrd := fun (tbl : Array String) (mid : String) =>
    match tbl.findIdx? (· == mid) with
    | some idx => (tbl, (idx + 1).toUInt32)
    | none => (tbl.push mid, (tbl.size + 1).toUInt32)
  let mut acc : Array ChromeMissionInput := #[]
  for inc in inputs do
    let (tbl1, incOrd) := internOrd idTable inc.id
    idTable := tbl1
    match acc.findIdx? (fun ex => ex.id == inc.id) with
    | none =>
      let verdict := Orb.Kernel.sidebarMergeStep 0 incOrd 0 inc.updatedAtMs 0 0
      let hi32 : UInt32 := ((verdict >>> 32) &&& 0xFFFFFFFF).toUInt32
      if hi32 == 1 then
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
private def isSupersededInTree (m : ChromeMissionInput) (byId : Array ChromeMissionInput) (parentOf : String → Option String) : Bool := Id.run do
  if isWorkingMissionStatus m.status then return false
  if isSupersededStoppedMission m then return true
  let mut seen : Array String := #[m.id]
  let mut curParent := (parentOf m.id).getD ""
  let mut steps := 0
  while !curParent.isEmpty && !seen.contains curParent && steps < byId.size do
    seen := seen.push curParent
    match byId.find? (·.id == curParent) with
    | none => break
    | some row =>
      if isSupersededStoppedMission row then return true
      curParent := (parentOf row.id).getD ""
      steps := steps + 1
  return false

/-- Exclude `/btw` side sessions and every worker/descendant in their subtree (`excludeBtwMissions` in `orb/src/missionHierarchy.ts`). -/
def excludeBtwMissionInputs (rows : Array ChromeMissionInput) : Array ChromeMissionInput :=
  rows.filter fun m => Id.run do
    if m.isBtwDirect then return false
    let mut seen : Array String := #[m.id]
    let mut cur :=
      if !m.parentMissionId.isEmpty then m.parentMissionId else m.forkSourceId
    let mut steps := 0
    while !cur.isEmpty && !seen.contains cur && steps < rows.size do
      seen := seen.push cur
      match rows.find? (·.id == cur) with
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
    Returns `(missionId, leaderId)` pairs for every member of a multi-version fork group. -/
private def electForkGroupLeaders (missions : Array ChromeMissionInput) : Array (String × String) := Id.run do
  let traceLineage := fun (m : ChromeMissionInput) => Id.run do
    let mut seen : Array String := #[]
    let mut ancestors : Array String := #[]
    let mut cur := m
    let mut steps := 0
    while !cur.forkSourceId.isEmpty && steps < missions.size do
      let src := cur.forkSourceId
      if seen.contains src || src == cur.id then break
      match missions.find? (·.id == src) with
      | none => break
      | some target =>
        seen := seen.push cur.id
        cur := target
        ancestors := ancestors.push cur.id
        steps := steps + 1
    { missionId := m.id, rootId := cur.id, depth := ancestors.size, ancestors := ancestors : ForkLineageInfo }
  let infos := missions.map traceLineage
  let mut rootIds : Array String := #[]
  for inf in infos do
    if !rootIds.contains inf.rootId then
      rootIds := rootIds.push inf.rootId
  let mut leaders : Array (String × String) := #[]
  for rid in rootIds do
    let group := missions.filter fun m =>
      (infos.find? (·.missionId == m.id)).map (·.rootId) == some rid
    if group.size ≥ 2 then
      let mut effective : Array (String × UInt64) := group.map (fun m => (m.id, m.updatedAtMs))
      for m in group do
        if m.createdAtMs > 0 then
          let ancs := ((infos.find? (·.missionId == m.id)).map (·.ancestors)).getD #[]
          for ancId in ancs do
            if let some eIdx := effective.findIdx? (fun (k, _) => k == ancId) then
              let ancAct := effective[eIdx]!.2
              if ancAct ≤ m.createdAtMs + forkSettleGraceMs then
                let clamped := if ancAct < m.createdAtMs then ancAct else m.createdAtMs
                effective := effective.set! eIdx (ancId, clamped)
      let getEff := fun (mid : String) =>
        ((effective.find? (fun (k, _) => k == mid)).map (·.2)).getD 0
      let getDepth := fun (mid : String) =>
        ((infos.find? (·.missionId == mid)).map (·.depth)).getD 0
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
        leaders := leaders.push (m.id, best.id)
  return leaders

private def sortMissions (xs : Array ChromeMissionInput) : Array ChromeMissionInput :=
  xs.qsort fun a b =>
    let pa := missionActivePriority a.status
    let pb := missionActivePriority b.status
    if pa != pb then pa < pb
    else if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs
    else a.id < b.id

/-- Bounded parent-chain cycle check (`parentReachesSelf == 1` iff following `parentMissionId`
    from `m.parentMissionId` reaches `m.id` or exceeds `byId.size` hops). -/
private def parentChainReachesSelf (m : ChromeMissionInput) (byId : Array ChromeMissionInput) : Bool := Id.run do
  if m.parentMissionId.isEmpty then return false
  if m.parentMissionId == m.id then return true
  let maxSteps := byId.size + 1
  let mut cur := m.parentMissionId
  let mut steps := 0
  while !cur.isEmpty && steps < maxSteps do
    if cur == m.id then return true
    match byId.find? (·.id == cur) with
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

private def isSelectedMissionTarget (sel : String) (mid : String) : Bool :=
  sel == s!"m:{mid}" || sel == s!"ms:{mid}" || sel == s!"rm:{mid}"

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
          badge := badge
          selected := activeSec == secId
          attention := attn
        }
    return srows

  let needleLower := LeanSys.Search.asciiLowerBytes filterQuery.trimAscii.toString.toUTF8
  let filterActive := !needleLower.isEmpty
  let isCollapsed := fun (rid : String) => !filterActive && st.collapsedIds.contains rid

  let mut rows : Array SidebarRow := #[
    {
      rowId := "nav:new-agent"
      kind := "nav"
      depth := 0
      title := "New Agent"
      target := "new-agent"
      shortcut := "⌘N"
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
      shortcut := "⌘2"
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
      shortcut := "⌘3"
      selected := sel == "cloud-agent"
    },
    {
      rowId := "nav:machines"
      kind := "nav"
      depth := 0
      title := "Machines"
      target := "machines"
      shortcut := "⌘4"
      selected := sel == "machines"
    },
    {
      rowId := "nav:providers"
      kind := "nav"
      depth := 0
      title := "Inference"
      target := "providers"
      selected := sel == "providers"
    },
    {
      rowId := "nav:resources"
      kind := "nav"
      depth := 0
      title := "Resources"
      target := "resources"
      selected := sel == "resources" || sel.startsWith "rm:"
    },
    {
      rowId := "section:projects"
      kind := "section"
      depth := 0
      title := "Projects"
    }
  ]

  let rawMerged := sortMissions (excludeBtwMissionInputs (mergeMissionInputs st.missions))
  -- Group fork lineages (`forkLeaders` / `nestMissions` in `orb/src/missionTree.ts`):
  -- A leading fork takes the place (launched `parentMissionId`, `project`, `folder`) of the conversation it continues,
  -- while earlier versions fold inside their group's leader.
  let forkLeaderMap := electForkGroupLeaders rawMerged
  let findLeaderId := fun (mid : String) =>
    (forkLeaderMap.find? (fun (k, _) => k == mid)).map (·.2)
  let isNonLeaderVersion := fun (mid : String) =>
    match findLeaderId mid with
    | some lid => lid != mid
    | none => false
  let merged : Array ChromeMissionInput := rawMerged.map fun m =>
    match findLeaderId m.id with
    | none => m
    | some lid =>
      if lid != m.id then m
      else
        let placeOf :=
          (rawMerged.find? fun c =>
            findLeaderId c.id == some lid &&
            (c.forkSourceId.isEmpty || !rawMerged.any (·.id == c.forkSourceId))).getD m
        let effParent := if !placeOf.parentMissionId.isEmpty then placeOf.parentMissionId else m.parentMissionId
        let effProj := if !m.project.isEmpty then m.project else placeOf.project
        let effFolder := if !m.folder.isEmpty then m.folder else placeOf.folder
        { m with parentMissionId := effParent, project := effProj, folder := effFolder }

  -- Determine cycle-safe parent links:
  -- 1. Non-leader fork versions nest directly under their group's leader (`version: true` in `nestMissions`).
  -- 2. Launched children route through `Orb.Kernel.sidebarVisibility` bit 16 (`65536`), with `isForkBit == 0`
  --    since `parseMissionInput?` already strips fork-of-parent links (`missionParent` in `orb/src/missionTree.ts`).
  let mut safeParentOf : Array (String × String) := #[]
  for m in merged do
    match findLeaderId m.id with
    | some lid =>
      if lid != m.id then
        safeParentOf := safeParentOf.push (m.id, lid)
      else
        let hasParentObj :=
          !m.parentMissionId.isEmpty &&
          merged.any (fun p =>
            p.id == m.parentMissionId &&
            (m.project.isEmpty || p.project.isEmpty || p.project == m.project))
        let hasParentBit : UInt8 := if hasParentObj then 1 else 0
        let reachesSelfBit : UInt8 := if hasParentObj && parentChainReachesSelf m merged then 1 else 0
        let visWord := Orb.Kernel.sidebarVisibility 1 0 0 hasParentBit 0 reachesSelfBit
        if (visWord &&& 65536) != 0 then
          safeParentOf := safeParentOf.push (m.id, m.parentMissionId)
    | none =>
      let hasParentObj :=
        !m.parentMissionId.isEmpty &&
        merged.any (fun p =>
          p.id == m.parentMissionId &&
          (m.project.isEmpty || p.project.isEmpty || p.project == m.project))
      let hasParentBit : UInt8 := if hasParentObj then 1 else 0
      let reachesSelfBit : UInt8 := if hasParentObj && parentChainReachesSelf m merged then 1 else 0
      let visWord := Orb.Kernel.sidebarVisibility 1 0 0 hasParentBit 0 reachesSelfBit
      if (visWord &&& 65536) != 0 then
        safeParentOf := safeParentOf.push (m.id, m.parentMissionId)

  let getSafeParent := fun (mid : String) =>
    (safeParentOf.find? (fun (k, _) => k == mid)).map (·.2)

  -- Resolve effective `(project, folder)` along cycle-safe parent links so children with `folder == ""`
  -- inherit their root ancestor's project & folder placement.
  let resolveEffectivePlacement := fun (start : ChromeMissionInput) => Id.run do
    let mut cur := start
    let mut steps := 0
    while steps < merged.size do
      match getSafeParent cur.id with
      | none => break
      | some pid =>
        match merged.find? (·.id == pid) with
        | none => break
        | some p =>
          cur := p
          steps := steps + 1
    let effProj := if cur.project.isEmpty then start.project else cur.project
    let effFolder := if !cur.folder.isEmpty then cur.folder else start.folder
    (effProj, effFolder)

  let placedMerged := merged.map fun m =>
    let (ep, ef) := resolveEffectivePlacement m
    { m with project := ep, folder := ef }

  -- Discover any implicit projects referenced by missions that aren't in `st.projects`
  let mut projects := st.projects
  for m in placedMerged do
    if !m.project.isEmpty && !projects.any (·.slug == m.project) then
      projects := projects.push { slug := m.project, name := m.project }

  -- Compute `hasVisibleDescendant` bottom-up (`placedMerged.size` passes suffices for any DAG)
  -- Matching `ProjectFiles.tsx`: `!isArchived(m) && (!isSupersededInTree(m, byId) || isSelectedMissionId(m.id))`
  let mut directMatchIds : Array String := #[]
  for m in placedMerged do
    let isSel := isSelectedMissionTarget sel m.id
    let supHidden := isSupersededInTree m placedMerged getSafeParent && !isSel
    let directMatch :=
      if supHidden then false
      else if filterActive then matchesFilterNeedle m needleLower
      else !m.acknowledged || isSel
    if directMatch then
      directMatchIds := directMatchIds.push m.id

  let mut visDescIds : Array String := #[]
  for _ in [0:placedMerged.size] do
    for m in placedMerged do
      if let some pid := getSafeParent m.id then
        let childVisible := directMatchIds.contains m.id || visDescIds.contains m.id
        if childVisible && !visDescIds.contains pid then
          visDescIds := visDescIds.push pid

  let mut retainedIds : Array String := #[]
  for m in placedMerged do
    let mf : UInt8 := if directMatchIds.contains m.id then 1 else 0
    let hvd : UInt8 := if visDescIds.contains m.id then 1 else 0
    let ack : UInt8 := if m.acknowledged then 1 else 0
    let visWord := Orb.Kernel.sidebarVisibility mf hvd ack 0 0 0
    if (visWord &&& 1) != 0 then
      retainedIds := retainedIds.push m.id

  let retainedMissions := placedMerged.filter (fun m => retainedIds.contains m.id)

  -- Helper to emit mission + cycle-safe descendants recursively up to bounded depth `retainedMissions.size`
  -- Launched children come first in list order, followed by earlier fork versions sorted by `updatedAtMs` descending (`nestMissions`).
  let rec emitMissionSubtree (fuel : Nat) (m : ChromeMissionInput) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
    match fuel with
    | 0 => acc
    | fuel' + 1 =>
      let launchedChildren := retainedMissions.filter (fun c => getSafeParent c.id == some m.id && !isNonLeaderVersion c.id)
      let versionChildren :=
        (retainedMissions.filter (fun c => getSafeParent c.id == some m.id && isNonLeaderVersion c.id)).qsort fun a b =>
          if a.updatedAtMs != b.updatedAtMs then a.updatedAtMs > b.updatedAtMs else a.id < b.id
      let children := launchedChildren ++ versionChildren
      let rowId := s!"m:{m.id}"
      let hasChildren := !children.isEmpty
      let exp := !isCollapsed rowId
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
        expandable := hasChildren
        expanded := if hasChildren then exp else false
        selected := isSelectedMissionTarget sel m.id
      }
      let nextAcc := acc.push row
      if !hasChildren || !exp then nextAcc
      else children.foldl (fun a c => emitMissionSubtree fuel' c (depth + 1) a) nextAcc

  for proj in projects do
    let projMissions := retainedMissions.filter (·.project == proj.slug)
    let mut folderSet : Array String := #[]
    for rawF in proj.folders do
      for anc in ancestorFolderPaths rawF do
        if !folderSet.contains anc then folderSet := folderSet.push anc
    for m in projMissions do
      for anc in ancestorFolderPaths m.folder do
        if !folderSet.contains anc then folderSet := folderSet.push anc
    let sortedFolders := folderSet.qsort (· < ·)
    if !filterActive || !projMissions.isEmpty then
      let projRowId := s!"proj:{proj.slug}"
      let projExpandable := !sortedFolders.isEmpty || !projMissions.isEmpty
      let projExpanded := !isCollapsed projRowId
      rows := rows.push {
        rowId := projRowId
        kind := "project"
        depth := 0
        title := proj.name
        target := s!"project:{proj.slug}"
        project := proj.slug
        expandable := projExpandable
        expanded := if projExpandable then projExpanded else false
        selected := sel == s!"c:{proj.slug}"
      }
      if projExpanded then
        let rec emitFolderSubtree (fuel : Nat) (parentPath : String) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
          match fuel with
          | 0 => acc
          | fuel' + 1 =>
            let childFolders := sortedFolders.filter (fun fp => parentFolderPath fp == parentPath)
            let afterFolders := childFolders.foldl (init := acc) fun a fp =>
              let hasSubfolders := sortedFolders.any (fun sub => parentFolderPath sub == fp)
              let folderMissions := projMissions.filter (fun m => m.folder == fp && (getSafeParent m.id).isNone)
              let hasAnyDescMission := projMissions.any (fun m => m.folder == fp || m.folder.startsWith (fp ++ "/"))
              if filterActive && !hasAnyDescMission then a
              else
                let fRowId := s!"folder:{proj.slug}:{fp}"
                let fExpandable := hasSubfolders || !folderMissions.isEmpty
                let fExpanded := !isCollapsed fRowId
                let fRow : SidebarRow := {
                  rowId := fRowId
                  kind := "folder"
                  depth := depth
                  title := basenameFolderPath fp
                  subtitle := fp
                  target := fRowId
                  project := proj.slug
                  folder := fp
                  expandable := fExpandable
                  expanded := if fExpandable then fExpanded else false
                }
                let a1 := a.push fRow
                if fExpanded then
                  emitFolderSubtree fuel' fp (depth + 1) a1
                else a1
            let directMissions := projMissions.filter (fun m => m.folder == parentPath && (getSafeParent m.id).isNone)
            directMissions.foldl (fun a m => emitMissionSubtree (retainedMissions.size + 1) m depth a) afterFolders
        rows := emitFolderSubtree (sortedFolders.size + 2) "" 1 rows

  -- Unassigned missions (`project == ""`)
  let unassigned := retainedMissions.filter (fun m => m.project.isEmpty && (getSafeParent m.id).isNone)
  for m in unassigned do
    rows := emitMissionSubtree (retainedMissions.size + 1) m 0 rows

  rows := rows.push {
    rowId := "nav:settings"
    kind := "nav"
    depth := 0
    title := "Settings"
    target := "settings"
    shortcut := "⌘,"
    badge := st.settingsBadge
    attention := !st.settingsDots.isEmpty
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
  let navItems : Array (String × String × String × String × String) := #[
    ("nav:new-agent", "New Agent", "Start a new conversation", "new-agent", "⌘N"),
    ("nav:inbox", "Inbox", "Missions awaiting attention", "inbox", "⌘2"),
    ("nav:cloud-agent", "Cloud agent", "Launch on managed cloud compute", "cloud-agent", "⌘3"),
    ("nav:machines", "Machines", "Fleet nodes & managed VMs", "machines", "⌘4"),
    ("nav:providers", "Inference", "Model routing & providers", "providers", ""),
    ("nav:resources", "Resources", "Compute, memory & budgets", "resources", "")
  ]
  for (id, title, sub, target, sc) in navItems do
    if id != "nav:inbox" || st.inboxEnabled then
      if let some scVal := scorePaletteCandidate qLower qTris title sub 30 then
        candidates := candidates.push ({
          itemId := id, kind := "nav", title := title, subtitle := sub, target := target, shortcut := sc, score := scVal
        }, scVal)

  for (secId, label, firstTab) in settingsSectionsMeta do
    if secId != "security" || st.isAdmin then
      let sub := s!"Settings · {label}"
      if let some scVal := scorePaletteCandidate qLower qTris label sub 20 then
        candidates := candidates.push ({
          itemId := s!"settings:{secId}", kind := "settings", title := label, subtitle := sub, target := firstTab, score := scVal
        }, scVal)

  for proj in st.projects do
    if let some scVal := scorePaletteCandidate qLower qTris proj.name s!"Project · {proj.slug}" 25 then
      candidates := candidates.push ({
        itemId := s!"proj:{proj.slug}", kind := "project", title := proj.name, subtitle := s!"Project · {proj.slug}", target := s!"project:{proj.slug}", score := scVal
      }, scVal)

  let merged := sortMissions (excludeBtwMissionInputs (mergeMissionInputs st.missions))
  let directParent := fun (mid : String) =>
    (merged.find? (·.id == mid)).bind fun r =>
      if r.parentMissionId.isEmpty then none else some r.parentMissionId
  let mut rankIdx : Nat := 0
  for m in merged do
    if !isSupersededInTree m merged directParent then
      let recencyBoost := if rankIdx < 40 then 40 - rankIdx else 0
      let activeBoost := if missionActivePriority m.status == 0 then 15 else 0
      let sub :=
        if m.project.isEmpty then m.status
        else if m.folder.isEmpty then s!"{m.project} · {m.status}"
        else s!"{m.project}/{m.folder} · {m.status}"
      if let some scVal := scorePaletteCandidate qLower qTris m.title (sub ++ " " ++ m.id) (recencyBoost + activeBoost) then
        candidates := candidates.push ({
          itemId := s!"m:{m.id}", kind := "mission", title := m.title, subtitle := sub, target := s!"m:{m.id}", score := scVal
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

/-- Upsert a live `native_chrome_sync_state` payload into `NativeChromeHub` with monotonic `syncRevision` fencing.
    Returns `(applied, updatedScopeState, nextHub)`. -/
def NativeChromeHub.syncFromJson
    (hub : NativeChromeHub)
    (args : JVal) : Except String (Bool × ChromeScopeState × NativeChromeHub) := do
  let scope := (args.fieldStr? "scope").getD "" |>.trimAscii.toString
  if scope.isEmpty || scope.utf8ByteSize > 512 then
    throw "Invalid native_chrome_sync_state scope"
  let rev := (args.fieldUInt64? "revision").getD 1
  let existing? := hub.scopes.find? (·.scope == scope)
  if let some ex := existing? then
    if !ex.hydratedOnly && rev < ex.syncRevision then
      let nextHub := { hub with activeScope := scope }
      return (false, ex, nextHub)

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
  if let some pmObj := (args.field? "project_missions").bind (·.asObj?) then
    for (slug, arrJv) in pmObj do
      for m in (arrJv.asArr?).getD #[] do
        if let some pm := parseMissionInput? m slug then
          missions := missions.push pm

  let prevCollapsed := (existing?.map (·.collapsedIds)).getD #[]
  let prevViewRev := (existing?.map (·.viewRevision)).getD 0
  let bumpedView := if prevViewRev < 0xFFFFFFFFFFFFFFFF then prevViewRev + 1 else prevViewRev
  let nextViewRev := if rev > bumpedView then rev else bumpedView
  let nextScope : ChromeScopeState := {
    scope := scope
    syncRevision := rev
    viewRevision := nextViewRev
    selected := selected
    onSettings := onSettings
    isAdmin := isAdmin
    inboxEnabled := inboxEnabled
    inboxUnread := inboxUnread
    settingsBadge := settingsBadge
    settingsDots := settingsDots
    projects := projects
    missions := mergeMissionInputs missions
    collapsedIds := prevCollapsed
    hydratedOnly := false
  }
  let others := hub.scopes.filter (·.scope != scope)
  let trimmed :=
    if others.size + 1 > maxNativeChromeScopes then
      others.extract (others.size + 1 - maxNativeChromeScopes) others.size
    else others
  let nextHub : NativeChromeHub := {
    activeScope := scope
    scopes := trimmed.push nextScope
  }
  return (true, nextScope, nextHub)

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
    (explicitExpanded? : Option Bool := none) : Option (Bool × ChromeScopeState × NativeChromeHub) := do
  let targetScope := if scope.trimAscii.toString.isEmpty then hub.activeScope else scope.trimAscii.toString
  let cleanRow := rowId.trimAscii.toString
  if cleanRow.isEmpty then none
  let idx ← hub.scopes.findIdx? (·.scope == targetScope)
  let cur := hub.scopes[idx]!
  let wasCollapsed := cur.collapsedIds.contains cleanRow
  let nextExpanded := explicitExpanded?.getD wasCollapsed
  let nextCollapsed :=
    if nextExpanded then cur.collapsedIds.filter (· != cleanRow)
    else if wasCollapsed then cur.collapsedIds
    else cur.collapsedIds.push cleanRow
  let nextViewRev := if cur.viewRevision < 0xFFFFFFFFFFFFFFFF then cur.viewRevision + 1 else cur.viewRevision
  let updated := { cur with collapsedIds := nextCollapsed, viewRevision := nextViewRev }
  let nextHub := { hub with scopes := hub.scopes.set! idx updated }
  some (nextExpanded, updated, nextHub)

end OrbLocald.NativeChrome
