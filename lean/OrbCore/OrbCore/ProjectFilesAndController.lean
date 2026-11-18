/- Project metadata, controller mission, text board, and confined project files. -/
import LeanSys.Http
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Store
import OrbCore.Managed
import OrbCore.R7Core
import OrbCore.LegacyHydrate

namespace OrbCore.ProjectFilesAndController

open LeanSys.Http
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Managed
open OrbCore.R7Core
open OrbCore.LegacyHydrate

private def unscopeProjectSlug (callerUserId storedSlug : String) : String :=
  if !callerUserId.isEmpty && storedSlug.startsWith (callerUserId ++ ":") then
    (storedSlug.drop (callerUserId.length + 1)).toString
  else
    storedSlug

/-! ## URL Query & Safe Path Helpers -/

private def parseQueryMap (rawTarget : String) : Array (String × String) := Id.run do
  let qStr :=
    match rawTarget.splitOn "?" with
    | _ :: qs => String.intercalate "?" qs
    | [] => ""
  if qStr.isEmpty then return #[]
  let mut out : Array (String × String) := #[]
  for pair in qStr.splitOn "&" do
    if !pair.isEmpty then
      match pair.splitOn "=" with
      | [] => pure ()
      | [k] => out := out.push ((percentDecodeStrict k).getD k, "")
      | k :: vs =>
        let rawV := String.intercalate "=" vs
        out := out.push ((percentDecodeStrict k).getD k, (percentDecodeStrict rawV).getD rawV)
  return out

private def qParam? (qMap : Array (String × String)) (key : String) : Option String :=
  (qMap.find? (fun (k, _) => k == key)).map Prod.snd

/-- Normalize a relative path inside a project (`""` = root, `"Audits/Report.md"` = file/folder).
    Returns `none` on `..`, NUL, or control characters. -/
def sanitizeProjectRelPath? (raw : String) : Option String := Id.run do
  let norm := String.ofList (raw.toList.map (fun c => if c == '\\' then '/' else c))
  for ch in norm.toList do
    if ch.toNat < 0x20 || ch.toNat == 0x7F then
      return none
  let parts := (norm.splitOn "/").map (fun s => s.trimAscii.toString) |>.filter (!·.isEmpty)
  let mut clean : Array String := #[]
  for p in parts do
    if p == "." then pure ()
    else if p == ".." then return none
    else clean := clean.push p
  return some (String.intercalate "/" clean.toList)

def projectFilesDir (dataRoot slug : String) : System.FilePath :=
  System.FilePath.mk dataRoot / "project-files" / slug

def projectFileAbsPath? (dataRoot slug rawRel : String) : Option (String × System.FilePath) := do
  if !validProjectSlug slug then none
  let rel ← sanitizeProjectRelPath? rawRel
  let base := projectFilesDir dataRoot slug
  let full := if rel.isEmpty then base else base / rel
  return (rel, full)

private def jsonResp (status : Nat) (jv : JVal) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact jv).toUTF8)

private def jsonErr (status : Nat) (code : String) : Nat × String × ByteArray :=
  (status, "application/json", s!"\{\"error\":{jsonEscape code}}".toUTF8)

private def optStrJVal (s : String) : JVal :=
  if s.isEmpty then .null else .str s

/-! ## Project metadata helpers -/

private structure RosterEntry where
  slug      : String
  title     : String
  objective : String
  status    : String
  updatedAt : String
  color     : String
  deriving Inhabited

private def readJsonStringMapFile (path : System.FilePath) : IO (Array (String × String)) := do
  let raw ← try IO.FS.readFile path catch _ => pure ""
  if raw.isEmpty then return #[]
  match OrbBin.Json.parse raw with
  | .ok (.obj kvs) =>
    let mut out : Array (String × String) := #[]
    for (k, v) in kvs do
      if let some s := v.asStr? then
        out := out.push (k, s)
    return out
  | _ => return #[]

private def writeJsonStringMapAtomic (dir : System.FilePath) (fileName : String) (kvs : Array (String × String)) : IO Unit := do
  let obj : JVal := .obj (kvs.map (fun (k, v) => (k, .str v)))
  let pretty := renderPrettyAux 0 obj ++ "\n"
  let tmp := dir / s!".{fileName}.tmp"
  let dst := dir / fileName
  try
    IO.FS.writeFile tmp pretty
    IO.FS.rename tmp dst
  catch _ =>
    pure ()

private def resolveHermesProjectsDir? (overrideDir? : Option String := none) : IO (Option System.FilePath) := do
  let raw :=
    match overrideDir? with
    | some d => d.trimAscii.toString
    | none => ""
  let dirStr ←
    if !raw.isEmpty then pure raw
    else pure (((← IO.getEnv "HERMES_PROJECTS_DIR").getD "").trimAscii.toString)
  if dirStr.isEmpty then return none
  let fp := System.FilePath.mk dirStr
  if ← fp.isDir then return some fp else return none

private def lookupStrMap? (m : Array (String × String)) (k : String) : Option String :=
  (m.find? (fun (mk, _) => mk == k)).map Prod.snd

def canonicalizeProjectSlugWith (aliases : Array (String × String)) (raw : String) : String :=
  let t := raw.trimAscii.toString
  if t.isEmpty then ""
  else
    match lookupStrMap? aliases t with
    | some c => c
    | none =>
      let lo := t.toLower
      if lo != t then (lookupStrMap? aliases lo).getD t else t

def listProjectsJVal
    (store : CoreStore)
    (callerUserId : String)
    (bootstrapAdminId : String)
    (isLegacyUnscoped : Bool)
    (includeArchived : Bool := false)
    (hermesProjectsDir? : Option String := none) : IO (Array JVal) := do
  let hDir? ← resolveHermesProjectsDir? hermesProjectsDir?
  let aliases ← match hDir? with | some d => readJsonStringMapFile (d / "routes.json") | none => pure #[]
  let overrides ← match hDir? with | some d => readJsonStringMapFile (d / "board-overrides.json") | none => pure #[]
  let mut byCanonical : Array RosterEntry := #[]
  if let .ok rows ← execParamQuery store.projectsDb
      ("SELECT p.slug, COALESCE(NULLIF(p.title,''), NULLIF(p.name,''), ''), COALESCE(p.objective,''), " ++
       "COALESCE(NULLIF(p.status,''),'active'), COALESCE(p.updated_at,''), COALESCE(p.color,''), " ++
       "COALESCE(o.owner_user_id,'') " ++
       "FROM projects p LEFT JOIN project_owners o ON o.slug = p.slug " ++
       "ORDER BY p.updated_at DESC, p.slug ASC;") #[] then
    for i in [1:rows.size] do
      let r := rows[i]!
      let rawSlug := cell r 0
      let title := cell r 1
      let obj := cell r 2
      let status := cell r 3
      let updAt := cell r 4
      let color := cell r 5
      let ownerUid := cell r 6
      let visible :=
        isLegacyUnscoped || ownerUid == callerUserId ||
        (callerUserId == bootstrapAdminId && !rawSlug.contains ':')
      if visible then
        let rawClientSlug := unscopeProjectSlug callerUserId rawSlug
        let canon := canonicalizeProjectSlugWith aliases rawClientSlug
        let canonical := if canon.isEmpty then rawClientSlug else canon
        let isCanonicalRow := rawClientSlug == canonical
        match byCanonical.findIdx? (fun e => e.slug == canonical) with
        | none =>
          byCanonical := byCanonical.push {
            slug := canonical
            title := title
            objective := obj
            status := status
            updatedAt := updAt
            color := color
          }
        | some idx =>
          let ex := byCanonical[idx]!
          let nextTitle :=
            if isCanonicalRow then (if !title.isEmpty then title else ex.title)
            else (if ex.title.isEmpty then title else ex.title)
          let nextObj :=
            if isCanonicalRow then (if !obj.isEmpty then obj else ex.objective)
            else (if ex.objective.isEmpty then obj else ex.objective)
          let nextStatus :=
            if isCanonicalRow then (if !status.isEmpty then status else ex.status)
            else (if ex.status.isEmpty then status else ex.status)
          let nextColor :=
            if isCanonicalRow then (if !color.isEmpty then color else ex.color)
            else (if ex.color.isEmpty then color else ex.color)
          let nextUpd := if updAt > ex.updatedAt then updAt else ex.updatedAt
          byCanonical := byCanonical.set! idx {
            slug := canonical
            title := nextTitle
            objective := nextObj
            status := nextStatus
            updatedAt := nextUpd
            color := nextColor
          }
  let mut out : Array JVal := #[]
  for entry in byCanonical do
    let effStatus := (lookupStrMap? overrides entry.slug).getD entry.status
    if includeArchived || (effStatus != "archived" && effStatus != "deleted") then
      let dispTitle := if entry.title.isEmpty then entry.slug else entry.title
      out := out.push (.obj #[
        ("slug", .str entry.slug),
        ("title", .str dispTitle),
        ("objective", optStrJVal entry.objective),
        ("status", .str effStatus),
        ("updated_at", .str entry.updatedAt),
        ("color", optStrJVal entry.color)
      ])
  return out

def upsertProjectRecord
    (store : CoreStore)
    (scopedSlug clientSlug title objective status color nowIso : String)
    (ownerUserId? : Option String := none) : IO (Except String JVal) := do
  let rawTitle := title.trimAscii.toString
  let rawStatus := status.trimAscii.toString
  let sql :=
    "INSERT INTO projects(slug,id,name,title,objective,status,color,created_at,updated_at) " ++
    "VALUES(?1,?1,COALESCE(NULLIF(?2,''),?1),COALESCE(NULLIF(?2,''),?1),?3,COALESCE(NULLIF(?4,''),'active'),?5,?6,?6) " ++
    "ON CONFLICT(slug) DO UPDATE SET " ++
    "name=COALESCE(NULLIF(?2,''),projects.name), " ++
    "title=COALESCE(NULLIF(?2,''),projects.title), " ++
    "objective=CASE WHEN ?3<>'' THEN ?3 ELSE projects.objective END, " ++
    "status=COALESCE(NULLIF(?4,''),projects.status), " ++
    "color=CASE WHEN ?5<>'' THEN ?5 ELSE projects.color END, " ++
    "updated_at=?6;"
  if let .error e ← execParamQuery store.projectsDb sql #[scopedSlug, rawTitle, objective, rawStatus, color, nowIso] then
    return .error e
  if let some uid := ownerUserId? then
    if !uid.isEmpty then
      discard <| execParamQuery store.projectsDb
        "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
        #[scopedSlug, uid, nowIso]
  -- Read back persisted row so existing title/status/color/objective stay intact when omitted
  let mut outTitle := if rawTitle.isEmpty then clientSlug else rawTitle
  let mut outObj := objective
  let mut outStatus := if rawStatus.isEmpty then "active" else rawStatus
  let mut outColor := color
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT COALESCE(NULLIF(title,''),NULLIF(name,''),slug), COALESCE(objective,''), COALESCE(status,'active'), COALESCE(color,'') FROM projects WHERE slug=?1;"
      #[scopedSlug] then
    if rows.size > 1 then
      let r := rows[1]!
      outTitle := cell r 0
      outObj := cell r 1
      outStatus := cell r 2
      outColor := cell r 3
  return .ok (.obj #[
    ("slug", .str clientSlug),
    ("title", .str outTitle),
    ("objective", optStrJVal outObj),
    ("status", .str outStatus),
    ("updated_at", .str nowIso),
    ("color", optStrJVal outColor)
  ])

/-- Appearance changes only the operator's color: it is not project activity, so it
    must not rewrite title, status or `updated_at`. An unknown project is a 404. -/
def updateProjectColor
    (store : CoreStore) (scopedSlug clientSlug color _nowIso : String) : IO (Except String JVal) := do
  match ← execParamQuery store.projectsDb "SELECT 1 FROM projects WHERE slug=?1 LIMIT 1;" #[scopedSlug] with
  | .error e => return .error e
  | .ok rows =>
    if rows.size <= 1 then return .error "not_found"
  if let .error e ← execParamQuery store.projectsDb
      "UPDATE projects SET color=NULLIF(?2,'') WHERE slug=?1;" #[scopedSlug, color] then
    return .error e
  return .ok (.obj #[("slug", .str clientSlug), ("color", optStrJVal color)])

def getProjectGrantJVal (store : CoreStore) (scopedSlug clientSlug : String) : IO JVal := do
  match ← execParamQuery store.projectsDb
      "SELECT COALESCE(merge_authority,''), COALESCE(budget_per_tick,''), COALESCE(parallel_missions,0), COALESCE(pause_reason,''), COALESCE(resume_condition,''), COALESCE(material_bar,''), COALESCE(autonomy_level,''), COALESCE(updated_at,'') FROM project_grant WHERE slug=?1;"
      #[scopedSlug] with
  | .ok rows =>
    if rows.size > 1 then
      let r := rows[1]!
      let par := cellU64 r 2
      return .obj #[
        ("slug", .str clientSlug),
        ("merge_authority", optStrJVal (cell r 0)),
        ("budget_per_tick", optStrJVal (cell r 1)),
        ("parallel_missions", if par == 0 then .null else JVal.uint64 par),
        ("pause_reason", optStrJVal (cell r 3)),
        ("resume_condition", optStrJVal (cell r 4)),
        ("material_bar", optStrJVal (cell r 5)),
        ("autonomy_level", optStrJVal (cell r 6)),
        ("updated_at", .str (cell r 7))
      ]
    else
      return .obj #[
        ("slug", .str clientSlug),
        ("merge_authority", .null),
        ("budget_per_tick", .null),
        ("parallel_missions", .null),
        ("pause_reason", .null),
        ("resume_condition", .null),
        ("material_bar", .null),
        ("autonomy_level", .null),
        ("updated_at", .str "")
      ]
  | .error _ =>
    return .obj #[("slug", .str clientSlug)]

def upsertProjectGrantJVal (store : CoreStore) (scopedSlug clientSlug : String) (jv : JVal) (nowIso : String) : IO (Except String JVal) := do
  let mergeAuth := (jv.fieldStr? "merge_authority").getD ""
  let budget := (jv.fieldStr? "budget_per_tick").getD ""
  let parStr := match jv.fieldNat? "parallel_missions" with | some n => s!"{n}" | none => ""
  let pauseR := (jv.fieldStr? "pause_reason").getD ""
  let resumeC := (jv.fieldStr? "resume_condition").getD ""
  let matBar := (jv.fieldStr? "material_bar").getD ""
  let autoLvl := (jv.fieldStr? "autonomy_level").getD ""
  let sql :=
    "INSERT INTO project_grant(slug,merge_authority,budget_per_tick,parallel_missions,pause_reason,resume_condition,material_bar,autonomy_level,updated_at) " ++
    "VALUES(?1,NULLIF(?2,''),NULLIF(?3,''),CASE WHEN ?4='' THEN NULL ELSE CAST(?4 AS INTEGER) END,NULLIF(?5,''),NULLIF(?6,''),NULLIF(?7,''),NULLIF(?8,''),?9) " ++
    "ON CONFLICT(slug) DO UPDATE SET " ++
    "merge_authority=COALESCE(excluded.merge_authority,project_grant.merge_authority)," ++
    "budget_per_tick=COALESCE(excluded.budget_per_tick,project_grant.budget_per_tick)," ++
    "parallel_missions=COALESCE(excluded.parallel_missions,project_grant.parallel_missions)," ++
    "pause_reason=COALESCE(excluded.pause_reason,project_grant.pause_reason)," ++
    "resume_condition=COALESCE(excluded.resume_condition,project_grant.resume_condition)," ++
    "material_bar=COALESCE(excluded.material_bar,project_grant.material_bar)," ++
    "autonomy_level=COALESCE(excluded.autonomy_level,project_grant.autonomy_level)," ++
    "updated_at=excluded.updated_at;"
  if let .error e ← execParamQuery store.projectsDb sql
      #[scopedSlug, mergeAuth, budget, parStr, pauseR, resumeC, matBar, autoLvl, nowIso] then
    return .error e
  return .ok (← getProjectGrantJVal store scopedSlug clientSlug)

def nominateCreatedProjectController (store : CoreStore) (slug title missionId nowIso ownerId : String) : IO (Except String Unit) := do
  if let .error e ← execParamQuery store.projectsDb
      "INSERT OR IGNORE INTO projects(slug,id,name,title,created_at,updated_at) VALUES(?1,?1,?2,?2,?3,?3);" #[slug, title, nowIso] then
    return .error e
  if !ownerId.isEmpty then
    if let .error e ← execParamQuery store.projectsDb
        "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);" #[slug, ownerId, nowIso] then
      return .error e
  match ← execParamQuery store.projectsDb
      "UPDATE projects SET controller_mission_id=?2 WHERE slug=?1;" #[slug, missionId] with
  | .error e => return .error e
  | .ok _ => return ← OrbCore.MissionBoard.claimUnclaimed store.missionsDb store.projectsDb slug missionId

/-- Shared REST/MCP project board representation. -/
def readProjectBoard (store : CoreStore) (slug : String) : IO JVal := do
  let mut text := ""
  let mut updated := ""
  let mut author := ""
  let mut controller := ""
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT COALESCE(b.text,''),COALESCE(b.updated_at,''),COALESCE(b.updated_by_mission_id,''),COALESCE(p.controller_mission_id,'') FROM projects p LEFT JOIN project_board b ON b.slug=p.slug WHERE p.slug=?1;" #[slug] then
    if rows.size > 1 then
      text := cell rows[1]! 0
      updated := cell rows[1]! 1
      author := cell rows[1]! 2
      controller := cell rows[1]! 3
  if !controller.isEmpty then
    if let .ok rows ← execParamQuery store.missionsDb
        "SELECT text,updated_at,updated_by_mission_id FROM mission_board WHERE mission_id=?1;" #[controller] then
      text := ""
      updated := ""
      author := ""
      if rows.size > 1 then
        text := cell rows[1]! 0
        updated := cell rows[1]! 1
        author := cell rows[1]! 2
  return .obj #[("text", .str text), ("updated_at", optStrJVal updated),
    ("updated_by_mission_id", optStrJVal author), ("controller_mission_id", optStrJVal controller)]

def writeProjectBoard (store : CoreStore) (slug text nowIso missionId : String) : IO (Except String Unit) := do
  if text.toUTF8.size > 16384 then return .error "board_too_large"
  match ← execParamQuery store.projectsDb
      "INSERT INTO project_board(slug,text,updated_at,updated_by_mission_id) SELECT ?1,?2,?3,NULLIF(?4,'') FROM projects WHERE slug=?1 AND (?4='' OR controller_mission_id=?4) ON CONFLICT(slug) DO UPDATE SET text=excluded.text,updated_at=excluded.updated_at,updated_by_mission_id=excluded.updated_by_mission_id RETURNING slug;"
      #[slug, text, nowIso, missionId] with
  | .error e => return .error e
  | .ok rows => if rows.size > 1 then return .ok () else return .error "not_project_controller"

def getProjectJVal (store : CoreStore) (scopedSlug clientSlug : String) : IO JVal := do
  let mut pObj := JVal.obj #[("slug", .str clientSlug), ("title", .str clientSlug), ("status", .str "active")]
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT COALESCE(NULLIF(title,''),NULLIF(name,''),slug), COALESCE(objective,''), COALESCE(status,'active'), COALESCE(updated_at,''), COALESCE(color,''), COALESCE(skills,'[]') FROM projects WHERE slug=?1;"
      #[scopedSlug] then
    if rows.size > 1 then
      let r := rows[1]!
      pObj := .obj #[
        ("slug", .str clientSlug),
        ("title", .str (cell r 0)),
        ("objective", optStrJVal (cell r 1)),
        ("status", .str (cell r 2)),
        ("updated_at", .str (cell r 3)),
        ("color", optStrJVal (cell r 4)),
        ("skills", (OrbBin.Json.parse (cell r 5)).toOption.getD (.arr #[]))
      ]
  let board ← readProjectBoard store scopedSlug
  pObj := pObj.setField "controller_mission_id" ((board.field? "controller_mission_id").getD .null)
    |>.setField "board_updated_at" ((board.field? "updated_at").getD .null)
  return .obj #[
    ("slug", .str clientSlug), ("project", pObj),
    ("controller_mission_id", (board.field? "controller_mission_id").getD .null),
    ("board", (board.field? "text").getD (.str "")),
    ("board_updated_at", (board.field? "updated_at").getD .null)
  ]

/-! ## Confined Project Files & `#1545` Folder Rename/Move Cascade -/

private partial def copyDirTree (src dst : System.FilePath) : IO (Except String Unit) := do
  if let .error e ← (IO.FS.createDirAll dst).toBaseIO then
    return .error s!"mkdir_failed:{e}"
  let entries ← match ← src.readDir.toBaseIO with
    | .ok es => pure es
    | .error e => return .error s!"readdir_failed:{e}"
  for entry in entries do
    let childSrc := entry.path
    let childDst := dst / entry.fileName
    let st ← statPath childSrc.toString
    if st.isSymlink then
      pure ()
    else if st.isDir then
      if let .error ce ← copyDirTree childSrc childDst then
        return .error ce
    else
      match ← (IO.FS.readBinFile childSrc).toBaseIO with
      | .error e => return .error s!"read_failed:{e}"
      | .ok bytes =>
        if let .error e ← (IO.FS.writeBinFile childDst bytes).toBaseIO then
          return .error s!"write_failed:{e}"
  return .ok ()

private partial def removeDirTree (target : System.FilePath) : IO Unit := do
  let st ← statPath target.toString
  if !st.exists_ then return ()
  if st.isSymlink || !st.isDir then
    try IO.FS.removeFile target catch _ => pure ()
  else
    if let .ok entries ← target.readDir.toBaseIO then
      for entry in entries do
        removeDirTree entry.path
    try IO.FS.removeDir target catch _ => pure ()

def listProjectDirectoryEntries (store : CoreStore) (scopedSlug rawRel : String) : IO (Except String JVal) := do
  let some (rel, absDir) := projectFileAbsPath? store.rootDir scopedSlug rawRel
    | return .error "invalid_path"
  let mut entriesByName : Array (String × JVal) := #[]
  if ← absDir.pathExists then
    if ← absDir.isDir then
      if let .ok dirEntries ← absDir.readDir.toBaseIO then
        for de in dirEntries do
          let name := de.fileName
          if !name.startsWith "." || name == ".gitignore" then
            let stFlags ← statPath de.path.toString
            if !stFlags.isSymlink then
              let iden ← statIdentity de.path.toString false
              let isDir := stFlags.isDir
              let item := JVal.obj #[
                ("name", .str name),
                ("kind", .str (if isDir then "dir" else "file")),
                ("size", JVal.uint64 iden.size),
                ("modified", .str (formatEpochIso8601Utc iden.mtime))
              ]
              entriesByName := entriesByName.push (name, item)
  -- Merge any `context_entries` children stored only in `projects.db`
  let prefixSlash := if rel.isEmpty then "" else rel ++ "/"
  if let .ok cRows ← execParamQuery store.projectsDb
      "SELECT path, directory, size FROM context_entries WHERE project_slug=?1 AND COALESCE(deleted,0)=0;"
      #[scopedSlug] then
    for i in [1:cRows.size] do
      let r := cRows[i]!
      let p := normalizeMissionFolder (cell r 0)
      if !p.isEmpty && (rel.isEmpty || p.startsWith prefixSlash) then
        let rem := if rel.isEmpty then p else (p.drop prefixSlash.length).toString
        let segs := (rem.splitOn "/").filter (!·.isEmpty)
        if let some childName := segs[0]? then
          let isSubDir := segs.length > 1 || cell r 1 != "0"
          if !entriesByName.any (fun (n, _) => n == childName) then
            entriesByName := entriesByName.push (childName, .obj #[
              ("name", .str childName),
              ("kind", .str (if isSubDir then "dir" else "file")),
              ("size", JVal.uint64 (cellU64 r 2))
            ])
  -- Also surface mission folders in this project so folders created implicitly by missions appear cleanly
  if let .ok fRows ← execParamQuery store.missionsDb
      "SELECT DISTINCT COALESCE(folder,'') FROM missions WHERE COALESCE(project,'')=?1 AND COALESCE(folder,'')<>'';"
      #[scopedSlug] then
    for i in [1:fRows.size] do
      let f := normalizeMissionFolder (cell fRows[i]! 0)
      if !f.isEmpty && (rel.isEmpty || f.startsWith prefixSlash) then
        let rem := if rel.isEmpty then f else (f.drop prefixSlash.length).toString
        let segs := (rem.splitOn "/").filter (!·.isEmpty)
        if let some childName := segs[0]? then
          if !entriesByName.any (fun (n, _) => n == childName) then
            entriesByName := entriesByName.push (childName, .obj #[
              ("name", .str childName),
              ("kind", .str "dir")
            ])
  let sorted := entriesByName.qsort (fun (a, av) (b, bv) =>
    let ak := (av.fieldStr? "kind").getD "file"
    let bk := (bv.fieldStr? "kind").getD "file"
    if ak != bk then ak == "dir" else a < b)
  return .ok (.obj #[("entries", .arr (sorted.map Prod.snd))])

def transferProjectFileOrFolder
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (srcScopedSlug dstScopedSlug dstClientSlug rawSrc rawDst : String)
    (isCopy : Bool)
    (nowIso : String) : IO (Except (Nat × String) JVal) := do
  let some (srcRel, srcAbs) := projectFileAbsPath? store.rootDir srcScopedSlug rawSrc
    | return .error (400, "invalid_source_path")
  let some (dstRel, dstAbs) := projectFileAbsPath? store.rootDir dstScopedSlug rawDst
    | return .error (400, "invalid_destination_path")
  if srcRel.isEmpty || dstRel.isEmpty then
    return .error (400, "root_transfer_forbidden")
  if srcScopedSlug == dstScopedSlug && srcRel == dstRel then
    return .ok (.obj #[("ok", .bool true), ("path", .str dstRel), ("moved_missions", .arr #[]), ("moved_crons", JVal.nat 0)])
  if srcScopedSlug == dstScopedSlug && dstRel.startsWith (srcRel ++ "/") then
    return .error (400, "cannot_move_folder_into_itself")

  let srcExistsOnDisk ← srcAbs.pathExists
  let srcIsDirOnDisk ← if srcExistsOnDisk then srcAbs.isDir else pure false
  -- A folder may also exist virtually via `context_entries` or `missions.folder` even before files land on disk
  let mut srcIsVirtualFolder := false
  if !srcExistsOnDisk then
    if let .ok mRows ← execParamQuery store.missionsDb
        "SELECT COUNT(*) FROM missions WHERE COALESCE(project,'')=?1 AND (COALESCE(folder,'')=?2 OR COALESCE(folder,'') LIKE (?2 || '/%'));"
        #[srcScopedSlug, srcRel] then
      if mRows.size > 1 && cellU64 mRows[1]! 0 > 0 then
        srcIsVirtualFolder := true
    if !srcIsVirtualFolder then
      if let .ok cRows ← execParamQuery store.projectsDb
          "SELECT COUNT(*) FROM context_entries WHERE project_slug=?1 AND COALESCE(deleted,0)=0 AND (path=?2 OR path LIKE (?2 || '/%'));"
          #[srcScopedSlug, srcRel] then
        if cRows.size > 1 && cellU64 cRows[1]! 0 > 0 then
          srcIsVirtualFolder := true
  if !srcExistsOnDisk && !srcIsVirtualFolder then
    return .error (404, "source_not_found")
  if ← dstAbs.pathExists then
    return .error (409, "destination_already_exists")

  let isDirTransfer := srcIsDirOnDisk || srcIsVirtualFolder
  let sameProjectDirMove := (srcScopedSlug == dstScopedSlug) && !isCopy && isDirTransfer

  -- Step 2: Perform filesystem copy/move when present on disk
  if srcExistsOnDisk then
    if let some parentDir := dstAbs.parent then
      if let .error e ← (IO.FS.createDirAll parentDir).toBaseIO then
        return .error (500, s!"mkdir_parent_failed:{e}")
    if isCopy then
      if srcIsDirOnDisk then
        if let .error e ← copyDirTree srcAbs dstAbs then
          return .error (500, e)
      else
        match ← (IO.FS.readBinFile srcAbs).toBaseIO with
        | .error e => return .error (500, s!"read_failed:{e}")
        | .ok bytes =>
          if let .error e ← (IO.FS.writeBinFile dstAbs bytes).toBaseIO then
            return .error (500, s!"write_failed:{e}")
    else
      match ← (IO.FS.rename srcAbs dstAbs).toBaseIO with
      | .ok () => pure ()
      | .error _ =>
        if srcIsDirOnDisk then
          if let .error e ← copyDirTree srcAbs dstAbs then
            return .error (500, e)
          removeDirTree srcAbs
        else
          match ← (IO.FS.readBinFile srcAbs).toBaseIO with
          | .error e =>
            return .error (500, s!"read_failed:{e}")
          | .ok bytes =>
            if let .error e ← (IO.FS.writeBinFile dstAbs bytes).toBaseIO then
              return .error (500, s!"write_failed:{e}")
            try IO.FS.removeFile srcAbs catch _ => pure ()
  else if isDirTransfer then
    discard <| (IO.FS.createDirAll dstAbs).toBaseIO

  -- Update `context_entries` if mirrored in `projects.db`
  if !isCopy && srcScopedSlug == dstScopedSlug then
    discard <| execParamQuery store.projectsDb
      "UPDATE context_entries SET path = ?3 || SUBSTR(path, LENGTH(?2) + 1) WHERE project_slug=?1 AND (path=?2 OR path LIKE (?2 || '/%'));"
      #[srcScopedSlug, srcRel, dstRel]

  -- Step 3 (`#1545`): Cascade `missions.folder` + `placement_revision` on same-project directory rename/move
  let movedMissions ←
    if sameProjectDirMove then
      match ← cascadeRenameMissionFolder store srcScopedSlug srcRel dstRel nowIso with
      | .ok items => pure items
      | .error e =>
        -- Roll back filesystem move!
        if ← dstAbs.pathExists then
          discard <| (IO.FS.rename dstAbs srcAbs).toBaseIO
        return .error (500, e)
    else pure #[]

  let movedMissionJVals := movedMissions.map fun it =>
    JVal.obj #[
      ("mission_id", .str it.missionId),
      ("project", .str dstClientSlug),
      ("folder", .str it.folder),
      ("placement_revision", JVal.uint64 it.placementRevision)
    ]

  if !movedMissionJVals.isEmpty then
    let evPayload := renderCompact (.obj #[
      ("type", .str "mission_placement_changed"),
      ("moves", .arr movedMissionJVals)
    ])
    publishControlEvent broadcastHub? "mission_placement_changed" evPayload none

  return .ok (.obj #[
    ("ok", .bool true),
    ("path", .str dstRel),
    ("moved_missions", .arr movedMissionJVals)
  ])

/-! ## Main HTTP Route Dispatcher (`dispatchProjectAndControllerRoutes?`) -/

private def dispatchProjectFilesTail?
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (clientSlug scopedSlug : String)
    (tail : List String)
    (qMap : Array (String × String))
    (method : String)
    (bodyBytes : ByteArray)
    (callerUserId bootstrapAdminId : String)
    (isLegacyUnscoped : Bool)
    (nowIso : String) : IO (Option (Nat × String × ByteArray)) := do
    -- `/api/projects/:slug/files`, `/api/projects/:slug/file*`
    if method == "GET" && tail == ["files"] then
      let rawP := (qParam? qMap "path").getD ""
      match ← listProjectDirectoryEntries store scopedSlug rawP with
      | .ok res => return some (jsonResp 200 res)
      | .error e => return some (jsonErr 400 e)

    if tail == ["file"] then
      if method == "GET" then
        let rawP := (qParam? qMap "path").getD ""
        let some (rel, absFp) := projectFileAbsPath? store.rootDir scopedSlug rawP
          | return some (jsonErr 400 "invalid_path")
        if rel.isEmpty then return some (jsonErr 400 "invalid_path")
        if ← absFp.pathExists then
          match ← (IO.FS.readFile absFp).toBaseIO with
          | .ok txt => return some (jsonResp 200 (.obj #[("path", .str rel), ("content", .str txt), ("revision", JVal.nat 1)]))
          | .error _ =>
            match ← (IO.FS.readBinFile absFp).toBaseIO with
            | .ok bytes => return some (jsonResp 200 (.obj #[("path", .str rel), ("content_b64", .str (OrbBin.PosixExt.base64Encode bytes false true)), ("revision", JVal.nat 1)]))
            | .error _ => return some (jsonErr 404 "file_not_found")
        else
          -- Fallback to `context_entries` blob if stored only via R7 context sync
          if let .ok cRows ← execParamQuery store.projectsDb
              "SELECT content_hash, revision FROM context_entries WHERE project_slug=?1 AND path=?2 AND COALESCE(deleted,0)=0;"
              #[scopedSlug, rel] then
            if cRows.size > 1 then
              let h := cell cRows[1]! 0
              let rev := (cellU64 cRows[1]! 1).toNat
              if let .ok bytes ← readContextBlob store.rootDir scopedSlug h then
                return some (jsonResp 200 (.obj #[("path", .str rel), ("content", .str ((String.fromUTF8? bytes).getD "")), ("revision", JVal.nat rev)]))
          return some (jsonErr 404 "file_not_found")
      else if method == "PUT" then
        let .ok jv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "invalid_json")
        let rawP := (jv.fieldStr? "path").getD ""
        let content := (jv.fieldStr? "content").getD ""
        let some (rel, absFp) := projectFileAbsPath? store.rootDir scopedSlug rawP
          | return some (jsonErr 400 "invalid_path")
        if rel.isEmpty then return some (jsonErr 400 "invalid_path")
        if let some parentDir := absFp.parent then
          if let .error e ← (IO.FS.createDirAll parentDir).toBaseIO then
            return some (jsonErr 500 s!"mkdir_failed:{e}")
        if let .error e ← (IO.FS.writeFile absFp content).toBaseIO then
          return some (jsonErr 500 s!"write_failed:{e}")
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str rel), ("revision", JVal.nat 1)]))
      else if method == "DELETE" then
        let rawP := (qParam? qMap "path").getD ""
        let some (rel, absFp) := projectFileAbsPath? store.rootDir scopedSlug rawP
          | return some (jsonErr 400 "invalid_path")
        if rel.isEmpty then return some (jsonErr 400 "root_delete_forbidden")
        removeDirTree absFp
        discard <| execParamQuery store.projectsDb
          "UPDATE context_entries SET deleted=1 WHERE project_slug=?1 AND (path=?2 OR path LIKE (?2 || '/%'));"
          #[scopedSlug, rel]
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    if method == "POST" && tail == ["file", "mkdir"] then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "invalid_json")
      let rawP := (jv.fieldStr? "path").getD ""
      let some (rel, absFp) := projectFileAbsPath? store.rootDir scopedSlug rawP
        | return some (jsonErr 400 "invalid_path")
      if rel.isEmpty then return some (jsonErr 400 "invalid_path")
      if let .error e ← (IO.FS.createDirAll absFp).toBaseIO then
        return some (jsonErr 500 s!"mkdir_failed:{e}")
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("path", .str rel)]))

    if method == "POST" && (tail == ["file", "transfer"] || (tail.length == 3 && tail[0]? == some "file" && tail[1]? == some "transfer")) then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "invalid_json")
      let dstClient :=
        if tail.length == 3 then (percentDecodeStrict tail[2]!).getD tail[2]!
        else clientSlug
      if !validProjectSlug dstClient then
        return some (jsonErr 400 "invalid_destination_project")
      let dstScoped :=
        if isLegacyUnscoped then dstClient
        else (scopeProjectSlug callerUserId bootstrapAdminId dstClient).getD dstClient
      let rawSrc := ((jv.fieldStr? "path").orElse (fun _ => jv.fieldStr? "source")).getD ""
      let rawDst := (jv.fieldStr? "destination").getD ""
      let isCopy :=
        match jv.fieldBool? "copy" with
        | some b => b
        | none => ((jv.fieldStr? "operation").getD "move").trimAscii.toString.toLower == "copy"
      match ← transferProjectFileOrFolder store broadcastHub? scopedSlug dstScoped dstClient rawSrc rawDst isCopy nowIso with
      | .ok res => return some (jsonResp 200 res)
      | .error (code, msg) => return some (jsonErr code msg)

    return none

def dispatchProjectAndControllerRoutes?
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (_workingDir : String)
    (method cleanPath rawTarget : String)
    (bodyBytes : ByteArray)
    (callerUserId bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool)
    (nowIso : String) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let qMap := parseQueryMap rawTarget

  -- Project Roster Root (`/api/projects`, `/api/projects/overview`, `/api/projects/by-session/:sid`)
  if segs == ["api", "projects"] then
    if method == "GET" then
      let incArch := ((qParam? qMap "include_archived").getD "") == "true"
      let projs ← listProjectsJVal store callerUserId bootstrapAdminId isLegacyUnscoped incArch
      return some (jsonResp 200 (.obj #[("projects", .arr projs)]))
    else if method == "PUT" || method == "POST" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "invalid_json")
      let rawSlug := ((jv.fieldStr? "slug").getD "").trimAscii.toString
      if !validProjectSlug rawSlug then
        return some (jsonErr 400 "invalid_project_slug")
      let scopedSlug :=
        if isLegacyUnscoped then rawSlug
        else (scopeProjectSlug callerUserId bootstrapAdminId rawSlug).getD rawSlug
      let title := (jv.fieldStr? "title").orElse (fun _ => jv.fieldStr? "name") |>.getD rawSlug
      let obj := (jv.fieldStr? "objective").getD ""
      let status := (jv.fieldStr? "status").getD "active"
      let color := (jv.fieldStr? "color").getD ""
      let owner? := some (if isLegacyUnscoped then bootstrapAdminId else callerUserId)
      match ← upsertProjectRecord store scopedSlug rawSlug title obj status color nowIso owner? with
      | .ok rec => return some (jsonResp 200 rec)
      | .error e => return some (jsonErr 500 e)

  if method == "GET" && segs == ["api", "projects", "overview"] then
    let projs ← listProjectsJVal store callerUserId bootstrapAdminId isLegacyUnscoped false
    return some (jsonResp 200 (.obj #[("projects", .arr projs)]))

  if segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "projects" && segs[2]? == some "by-session" then
    let sid := (percentDecodeStrict segs[3]!).getD segs[3]!
    if method == "GET" then
      if let .ok rows ← execParamQuery store.projectsDb
          ("SELECT b.slug FROM project_bindings b LEFT JOIN project_owners o ON o.slug=b.slug " ++
           "WHERE b.control_session_id=?1 AND (?2='1' OR o.owner_user_id=?3) LIMIT 1;")
          #[sid, if isLegacyUnscoped then "1" else "0", callerUserId] then
        if rows.size > 1 then
          let sl := unscopeProjectSlug callerUserId (cell rows[1]! 0)
          return some (jsonResp 200 (.obj #[("slug", .str sl)]))
      return some (jsonResp 200 (.obj #[("slug", .null)]))

  -- Per-Project Endpoints (`/api/projects/:slug/...`)
  if segs.length ≥ 3 && segs[0]? == some "api" && segs[1]? == some "projects" then
    let some clientSlug := percentDecodeStrict segs[2]!
      | return some (jsonErr 400 "invalid_project")
    if !validProjectSlug clientSlug then
      return some (jsonErr 400 "invalid_project")
    let mut scopedSlug :=
      if isLegacyUnscoped then clientSlug
      else (scopeProjectSlug callerUserId bootstrapAdminId clientSlug).getD clientSlug
    let tail := segs.drop 3
    -- Remove these two compatibility GETs once iOS/Android < 1.77.0 are retired.
    if method == "GET" && tail == ["controller"] then
      return some (jsonResp 200 (.obj #[("job", .null)]))
    if method == "GET" && tail == ["crons"] then
      return some (jsonResp 200 (.obj #[("jobs", .arr #[])]))
    if ["controller", "crons", "track", "tracks", "tasks", "task-board",
        "decision", "decisions", "steers", "state", "situation"].contains (tail.headD "") then
      return some (jsonErr 410 "removed")
    if tail == ["board"] || tail == ["controller-mission"] || (tail.isEmpty && method == "GET") then
      let .ok rows ← execParamQuery store.projectsDb
          "SELECT p.slug FROM projects p LEFT JOIN project_owners o ON o.slug=p.slug WHERE (p.slug=?1 OR p.slug=?2) AND (?3='1' OR o.owner_user_id=?4) ORDER BY (p.slug=?1) DESC LIMIT 1;"
          #[scopedSlug, clientSlug, if isAdmin then "1" else "0", callerUserId]
        | return some (jsonErr 500 "db_error")
      if rows.size ≤ 1 then return some (jsonErr 404 "not_found")
      scopedSlug := cell rows[1]! 0
    if tail == ["board"] || tail == ["controller-mission"] then
      let .ok rows ← execParamQuery store.projectsDb
          "SELECT p.slug FROM projects p LEFT JOIN project_owners o ON o.slug=p.slug WHERE p.slug=?1 AND (?2='1' OR o.owner_user_id=?3);"
          #[scopedSlug, if isAdmin then "1" else "0", callerUserId]
        | return some (jsonErr 500 "db_error")
      if rows.size ≤ 1 then return some (jsonErr 404 "not_found")
      if method == "GET" && tail == ["board"] then
        return some (jsonResp 200 (← readProjectBoard store scopedSlug))
      if method == "PUT" then
        let .ok jv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "invalid_json")
        if tail == ["board"] then
          return some (jsonErr 403 "not_project_controller")
        let mid ← match jv.field? "mission_id" with
          | some .null => pure ""
          | some (.str mid) =>
            let some mission ← getMission? store mid | return some (jsonErr 404 "not_found")
            if mission.project != scopedSlug then return some (jsonErr 404 "not_found")
            pure mid
          | _ => return some (jsonErr 400 "invalid_mission_id")
        if let .error e ← execParamQuery store.projectsDb
            "UPDATE projects SET controller_mission_id=NULLIF(?2,'') WHERE slug=?1;" #[scopedSlug, mid] then
          return some (jsonErr 500 e)
        if let .error e ← OrbCore.MissionBoard.claimUnclaimed store.missionsDb store.projectsDb scopedSlug mid then
          return some (jsonErr 500 e)
        return some (jsonResp 200 (← readProjectBoard store scopedSlug))

    -- `GET|DELETE /api/projects/:slug`
    if tail.isEmpty then
      if method == "GET" then
        let sit ← getProjectJVal store scopedSlug clientSlug
        return some (jsonResp 200 sit)
      else if method == "DELETE" then
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET status='deleted', updated_at=?2 WHERE slug=?1;" #[scopedSlug, nowIso]
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("slug", .str clientSlug)]))

    if method == "GET" && tail == ["updates"] then
      return some (jsonResp 200 (.obj #[("updates", .arr #[])]))
    if method == "GET" && tail == ["conversation"] then
      return some (jsonResp 200 (.obj #[("mission_id", .null), ("messages", .arr #[])]))
    if method == "POST" && tail == ["reconcile", "ack"] then
      return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    -- `POST /api/projects/:slug/action` (`archive`, `restore`, `unarchive`, `pause`, `resume`, `delete`)
    if method == "POST" && tail == ["action"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let act := ((jv.fieldStr? "action").getD "").trimAscii.toString.toLower
      let nextStatus :=
        if act == "archive" then "archived"
        else if act == "delete" then "deleted"
        else if act == "pause" then "paused"
        else "active"
      discard <| upsertProjectRecord store scopedSlug clientSlug "" "" nextStatus "" nowIso
        (if isLegacyUnscoped then none else some callerUserId)
      discard <| execParamQuery store.projectsDb
        "UPDATE projects SET status=?2, updated_at=?3 WHERE slug=?1;" #[scopedSlug, nextStatus, nowIso]
      if let some hDir ← resolveHermesProjectsDir? then
        let curOv ← readJsonStringMapFile (hDir / "board-overrides.json")
        let filtered := curOv.filter (fun (k, _) => k != clientSlug)
        let nextOv :=
          if act == "resume" || act == "unarchive" || act == "restore" then filtered
          else filtered.push (clientSlug, nextStatus)
        writeJsonStringMapAtomic hDir "board-overrides.json" nextOv
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("slug", .str clientSlug), ("status", .str nextStatus)]))

    -- `POST /api/projects/:slug/rename`
    if method == "POST" && tail == ["rename"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let newTitle := ((jv.fieldStr? "title").orElse (fun _ => jv.fieldStr? "name") |>.getD clientSlug).trimAscii.toString
      match ← upsertProjectRecord store scopedSlug clientSlug newTitle "" "" "" nowIso
          (if isLegacyUnscoped then none else some callerUserId) with
      | .ok rec => return some (jsonResp 200 rec)
      | .error e => return some (jsonErr 500 e)

    -- `POST|PUT /api/projects/:slug/appearance`
    if (method == "POST" || method == "PUT" || method == "PATCH") && tail == ["appearance"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let col := ((jv.fieldStr? "color").getD "").trimAscii.toString
      match ← updateProjectColor store scopedSlug clientSlug col nowIso with
      | .ok rec => return some (jsonResp 200 rec)
      | .error "not_found" => return some (jsonErr 404 "not_found")
      | .error e => return some (jsonErr 500 e)

    -- `GET|PUT /api/projects/:slug/skills`
    if tail == ["skills"] then
      if method == "GET" then
        let mut skArr : Array JVal := #[]
        if let .ok rows ← execParamQuery store.projectsDb
            "SELECT COALESCE(skills,'[]') FROM projects WHERE slug=?1;" #[scopedSlug] then
          if rows.size > 1 then
            skArr := ((OrbBin.Json.parse (cell rows[1]! 0)).toOption >>= JVal.asArr?).getD #[]
        return some (jsonResp 200 (.obj #[("skills", .arr skArr)]))
      else if method == "PUT" || method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let skArr := (jv.fieldArr? "skills").getD #[]
        let skJson := renderCompact (.arr skArr)
        discard <| upsertProjectRecord store scopedSlug clientSlug "" "" "" "" nowIso
          (if isLegacyUnscoped then none else some callerUserId)
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET skills=?2, updated_at=?3 WHERE slug=?1;" #[scopedSlug, skJson, nowIso]
        return some (jsonResp 200 (.obj #[("skills", .arr skArr)]))

    -- `POST /api/projects/:slug/status`
    if method == "POST" && tail == ["status"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let stVal := (jv.fieldStr? "status").getD "active"
      discard <| upsertProjectRecord store scopedSlug clientSlug "" "" stVal "" nowIso
        (if isLegacyUnscoped then none else some callerUserId)
      discard <| execParamQuery store.projectsDb
        "UPDATE projects SET status=?2, updated_at=?3 WHERE slug=?1;"
        #[scopedSlug, stVal, nowIso]
      return some (jsonResp 200 (← getProjectJVal store scopedSlug clientSlug))

    -- `GET|POST /api/projects/:slug/grant`
    if tail == ["grant"] then
      if method == "GET" then
        return some (jsonResp 200 (← getProjectGrantJVal store scopedSlug clientSlug))
      else if method == "POST" || method == "PUT" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        match ← upsertProjectGrantJVal store scopedSlug clientSlug jv nowIso with
        | .ok gv => return some (jsonResp 200 gv)
        | .error e => return some (jsonErr 500 e)

    if !isLegacyUnscoped && callerUserId != bootstrapAdminId then
      let .ok ownerRows ← execParamQuery store.projectsDb
          "SELECT 1 FROM project_owners WHERE (slug=?1 OR slug=?2) AND owner_user_id=?3 LIMIT 1;"
          #[scopedSlug, clientSlug, callerUserId]
        | return some (jsonErr 500 "db_error")
      if ownerRows.size ≤ 1 then return some (jsonErr 404 "not_found")
    if let some r ← dispatchProjectFilesTail? store broadcastHub? clientSlug scopedSlug tail qMap method bodyBytes callerUserId bootstrapAdminId isLegacyUnscoped nowIso then
      return some r

  return none

end OrbCore.ProjectFilesAndController
