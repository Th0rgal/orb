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
  parentMissionId : String := ""
  isFork          : Bool := false
  acknowledged    : Bool := false
  superseded      : Bool := false
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
  revision      : UInt64 := 0
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

/-- Parse an ISO-8601-like timestamp or integer epoch ms into monotonic lexical UInt64 order.
    Accepts explicit `updated_at_ms` first, or packs ASCII digits of `updated_at` (`YYYYMMDDHHMMSSmmm`)
    so newer ISO-8601 UTC strings compare strictly greater without C `strptime`. -/
def parseUpdatedAtMs (jv : JVal) : UInt64 := Id.run do
  if let some n := jv.fieldUInt64? "updated_at_ms" then
    return n
  if let some n := jv.fieldNat? "updatedAtMs" then
    return n.toUInt64
  let iso := ((jv.fieldStr? "updated_at").orElse (fun _ => jv.fieldStr? "updatedAt")).getD ""
  if iso.isEmpty then return 0
  let mut acc : UInt64 := 0
  let mut count : Nat := 0
  for c in iso.toList do
    if '0' ≤ c && c ≤ '9' && count < 17 then
      acc := acc * 10 + (c.toNat - '0'.toNat).toUInt64
      count := count + 1
  return acc

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
  let proj := (jv.fieldStr? "project").getD fallbackProject |>.trimAscii.toString
  let folder := normalizeFolderPath ((jv.fieldStr? "folder").getD "")
  let parentId :=
    ((jv.fieldStr? "parent_mission_id").orElse (fun _ => jv.fieldStr? "parentMissionId")).getD ""
      |>.trimAscii.toString
  let relKind :=
    ((jv.fieldStr? "parent_kind").orElse (fun _ => jv.fieldStr? "relation_kind")).getD ""
      |>.trimAscii.toString.toLower
  let isFork := (jv.fieldBool? "is_fork").getD (relKind == "fork")
  let ack :=
    (jv.fieldBool? "acknowledged").getD
      ((jv.fieldBool? "archived").getD false)
  let sup :=
    (jv.fieldBool? "superseded").getD
      (status == "superseded" || ((jv.fieldStr? "superseded_by").map (!·.isEmpty)).getD false)
  some {
    id := id
    title := title
    status := status
    project := proj
    folder := folder
    parentMissionId := parentId
    isFork := isFork
    acknowledged := ack
    superseded := sup
    updatedAtMs := parseUpdatedAtMs jv
  }

/-- Deduplicate and merge mission inputs via `Orb.Kernel.sidebarMergeStep` (`orb_sidebar_merge_step`). -/
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
    let supFlag : UInt8 := if inc.superseded then 1 else 0
    match acc.findIdx? (fun ex => ex.id == inc.id) with
    | none =>
      let verdict := Orb.Kernel.sidebarMergeStep 0 incOrd 0 inc.updatedAtMs supFlag 0
      let hi32 : UInt32 := ((verdict >>> 32) &&& 0xFFFFFFFF).toUInt32
      if hi32 == 1 then
        acc := acc.push inc
    | some idx =>
      let ex := acc[idx]!
      let verdict := Orb.Kernel.sidebarMergeStep incOrd incOrd ex.updatedAtMs inc.updatedAtMs supFlag 0
      let lo32 : UInt32 := (verdict &&& 0xFFFFFFFF).toUInt32
      if supFlag == 1 && (lo32 &&& 4) != 0 then
        acc := acc.eraseIdx! idx
      else if (lo32 &&& 1) != 0 then
        let mergedProj := if inc.project.isEmpty then ex.project else inc.project
        let mergedFolder := if inc.folder.isEmpty then ex.folder else inc.folder
        acc := acc.set! idx { inc with project := mergedProj, folder := mergedFolder }
  return acc

/-- Sort rank for mission status (`active`/`running` first, then `updatedAtMs` descending, then `id`). -/
private def missionActivePriority (status : String) : Nat :=
  let s := status.toLower
  if s == "active" || s == "running" || s == "pending" || s == "waiting_for_approval" || s == "blocked" then 0
  else 1

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

/-- Map a selected page id to its owning Settings section id (matching `shared/orb-spec/fixtures/settings-nav.json`). -/
def settingsSectionIdForSelected (sel : String) : Option String :=
  if sel == "settings" || sel == "users-settings" || sel == "usage-telemetry" then some "account"
  else if sel == "routing" || sel == "routing-providers" || sel == "usage-settings" || sel == "routing-keys" then some "models"
  else if sel == "skills-settings" || sel == "hermes-settings" || sel == "btw-settings" || sel == "inbox-summaries" || sel == "local-agents" || sel == "execution" then some "agents"
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

  let merged := sortMissions (mergeMissionInputs st.missions)
  -- Discover any implicit projects referenced by missions that aren't in `st.projects`
  let mut projects := st.projects
  for m in merged do
    if !m.project.isEmpty && !projects.any (·.slug == m.project) then
      projects := projects.push { slug := m.project, name := m.project }

  -- Determine cycle-safe parent links (`Orb.Kernel.sidebarVisibility` bit 16 = `65536`)
  let mut safeParentOf : Array (String × String) := #[]
  for m in merged do
    let hasParentObj :=
      !m.parentMissionId.isEmpty &&
      merged.any (fun p => p.id == m.parentMissionId && p.project == m.project && p.folder == m.folder)
    let hasParentBit : UInt8 := if hasParentObj then 1 else 0
    let isForkBit : UInt8 := if m.isFork then 1 else 0
    let reachesSelfBit : UInt8 := if hasParentObj && parentChainReachesSelf m merged then 1 else 0
    let visWord := Orb.Kernel.sidebarVisibility 1 0 0 hasParentBit isForkBit reachesSelfBit
    if (visWord &&& 65536) != 0 then
      safeParentOf := safeParentOf.push (m.id, m.parentMissionId)

  let getSafeParent := fun (mid : String) =>
    (safeParentOf.find? (fun (k, _) => k == mid)).map (·.2)

  -- Compute `hasVisibleDescendant` bottom-up (`merged.size` passes suffices for any DAG)
  let mut directMatchIds : Array String := #[]
  for m in merged do
    let directMatch :=
      if filterActive then matchesFilterNeedle m needleLower
      else !m.acknowledged || isSelectedMissionTarget sel m.id
    if directMatch then
      directMatchIds := directMatchIds.push m.id

  let mut visDescIds : Array String := #[]
  for _ in [0:merged.size] do
    for m in merged do
      if let some pid := getSafeParent m.id then
        let childVisible := directMatchIds.contains m.id || visDescIds.contains m.id
        if childVisible && !visDescIds.contains pid then
          visDescIds := visDescIds.push pid

  let mut retainedIds : Array String := #[]
  for m in merged do
    let mf : UInt8 := if directMatchIds.contains m.id then 1 else 0
    let hvd : UInt8 := if visDescIds.contains m.id then 1 else 0
    let ack : UInt8 := if m.acknowledged then 1 else 0
    let visWord := Orb.Kernel.sidebarVisibility mf hvd ack 0 0 0
    if (visWord &&& 1) != 0 then
      retainedIds := retainedIds.push m.id

  let retainedMissions := merged.filter (fun m => retainedIds.contains m.id)

  -- Helper to emit mission + cycle-safe descendants recursively up to bounded depth `retainedMissions.size`
  let rec emitMissionSubtree (fuel : Nat) (m : ChromeMissionInput) (depth : Nat) (acc : Array SidebarRow) : Array SidebarRow :=
    match fuel with
    | 0 => acc
    | fuel' + 1 =>
      let children := retainedMissions.filter (fun c => getSafeParent c.id == some m.id)
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

  let merged := sortMissions (mergeMissionInputs st.missions)
  let mut rankIdx : Nat := 0
  for m in merged do
    if !m.superseded then
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
    revision := 0
    projects := projects
    missions := mergeMissionInputs missions
    hydratedOnly := true
  }

/-- Upsert a live `native_chrome_sync_state` payload into `NativeChromeHub` with monotonic `revision` fencing.
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
    if !ex.hydratedOnly && rev < ex.revision then
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
  let nextScope : ChromeScopeState := {
    scope := scope
    revision := rev
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
  let nextRev := if cur.revision < 0xFFFFFFFFFFFFFFFF then cur.revision + 1 else cur.revision
  let updated := { cur with collapsedIds := nextCollapsed, revision := nextRev }
  let nextHub := { hub with scopes := hub.scopes.set! idx updated }
  some (nextExpanded, updated, nextHub)

end OrbLocald.NativeChrome
