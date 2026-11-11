/-
  OrbCore.ProjectFilesAndController:
  1. Project Roster, Overview, Appearance, Skills, Grants, Steers, Decisions, Situation, Tracks & Tasks
     backed by `projects.db` (`projects`, `project_grant`, `project_steers`, `project_decisions`,
     `project_tracks`, `project_crons`, `controller_archives`, `project_bindings`) + `missions.db`.
  2. Confined Project Filesystem (`/api/projects/:slug/{files,file,file/mkdir,file/transfer,file/transfer/:dest}`)
     backed by `{dataRoot}/project-files/<slug>/` + `context_entries`, including `#1545` atomic folder
     rename/move cascades across `missions.folder` (`placement_revision` bump) and `project_crons.folder`
     with rollback safety (`restoreCronFolders`) and SSE `mission_placement_changed` broadcast.
  3. Hermes Project Controller & Crons (`/api/projects/:slug/controller*`, `/api/projects/:slug/crons*`).
  4. Admin-confined `/api/file-resources` & `/api/fs/{list,read,download}`.
  (`0 import Lean`, `0 sorryAx`).
-/
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

/-! ## Project Roster, Grants, Steers, Decisions, Situation & Tasks Helpers -/

def listProjectsJVal
    (store : CoreStore)
    (callerUserId : String)
    (bootstrapAdminId : String)
    (isLegacyUnscoped : Bool)
    (includeArchived : Bool := false) : IO (Array JVal) := do
  let mut bySlug : Array (String × JVal) := #[]
  if let .ok rows ← execParamQuery store.projectsDb
      ("SELECT p.slug, COALESCE(NULLIF(p.title,''), NULLIF(p.name,''), p.slug), COALESCE(p.objective,''), " ++
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
        isLegacyUnscoped || ownerUid.isEmpty || ownerUid == callerUserId ||
        (callerUserId == bootstrapAdminId && !rawSlug.contains ':')
      if visible && (includeArchived || (status != "archived" && status != "deleted")) then
        let clientSlug := unscopeProjectSlug callerUserId rawSlug
        if !bySlug.any (fun (s, _) => s == clientSlug) then
          bySlug := bySlug.push (clientSlug, .obj #[
            ("slug", .str clientSlug),
            ("title", .str (if title.isEmpty then clientSlug else title)),
            ("objective", optStrJVal obj),
            ("status", .str status),
            ("updated_at", .str updAt),
            ("color", optStrJVal color)
          ])
  -- Discover inferred projects from `missions.project` that do not yet have a `projects` row
  if let .ok mRows ← execParamQuery store.missionsDb
      "SELECT COALESCE(project,''), MAX(COALESCE(metadata_updated_at, created_at, '')), COALESCE(owner_user_id,'') FROM missions WHERE COALESCE(project,'') <> '' GROUP BY project, owner_user_id;" #[] then
    for i in [1:mRows.size] do
      let r := mRows[i]!
      let rawProj := cell r 0
      let updAt := cell r 1
      let ownerUid := cell r 2
      let visible := isLegacyUnscoped || ownerUid.isEmpty || ownerUid == callerUserId
      if visible && validProjectSlug (unscopeProjectSlug callerUserId rawProj) then
        let clientSlug := unscopeProjectSlug callerUserId rawProj
        if !bySlug.any (fun (s, _) => s == clientSlug) then
          bySlug := bySlug.push (clientSlug, .obj #[
            ("slug", .str clientSlug),
            ("title", .str clientSlug),
            ("objective", .null),
            ("status", .str "active"),
            ("updated_at", .str updAt),
            ("color", .null)
          ])
  return bySlug.map Prod.snd

def upsertProjectRecord
    (store : CoreStore)
    (scopedSlug clientSlug title objective status color nowIso : String)
    (ownerUserId? : Option String := none) : IO (Except String JVal) := do
  let effTitle := if title.trimAscii.toString.isEmpty then clientSlug else title.trimAscii.toString
  let effStatus := if status.trimAscii.toString.isEmpty then "active" else status.trimAscii.toString
  let sql :=
    "INSERT INTO projects(slug,id,name,title,objective,status,color,created_at,updated_at) " ++
    "VALUES(?1,?1,?2,?2,?3,?4,?5,?6,?6) " ++
    "ON CONFLICT(slug) DO UPDATE SET " ++
    "name=COALESCE(NULLIF(?2,''),projects.name), " ++
    "title=COALESCE(NULLIF(?2,''),projects.title), " ++
    "objective=CASE WHEN ?3<>'' THEN ?3 ELSE projects.objective END, " ++
    "status=COALESCE(NULLIF(?4,''),projects.status), " ++
    "color=CASE WHEN ?5<>'' THEN ?5 ELSE projects.color END, " ++
    "updated_at=?6;"
  if let .error e ← execParamQuery store.projectsDb sql #[scopedSlug, effTitle, objective, effStatus, color, nowIso] then
    return .error e
  if let some uid := ownerUserId? then
    if !uid.isEmpty then
      discard <| execParamQuery store.projectsDb
        "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
        #[scopedSlug, uid, nowIso]
  -- Read back persisted row so existing color/objective stay intact when omitted
  let mut outTitle := effTitle
  let mut outObj := objective
  let mut outStatus := effStatus
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

def listProjectSteersJVal (store : CoreStore) (scopedSlug : String) : IO JVal := do
  let mut items : Array JVal := #[]
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT id,body,created_at,COALESCE(consumed_at,''),COALESCE(origin,'orb') FROM project_steers WHERE slug=?1 ORDER BY created_at DESC LIMIT 100;"
      #[scopedSlug] then
    for i in [1:rows.size] do
      let r := rows[i]!
      items := items.push (.obj #[
        ("id", .str (cell r 0)),
        ("body", .str (cell r 1)),
        ("created_at", .str (cell r 2)),
        ("consumed_at", optStrJVal (cell r 3)),
        ("origin", .str (cell r 4))
      ])
  let pending := items.filter (fun it => (it.field? "consumed_at").map JVal.isNull |>.getD true)
  return .obj #[("steers", .arr items), ("pending", .arr pending)]

def addProjectSteerJVal (store : CoreStore) (scopedSlug body origin nowIso : String) : IO (Except String JVal) := do
  let cleanBody := body.trimAscii.toString
  if cleanBody.isEmpty then return .error "missing_steer_body"
  let sid ← newUuidV4
  let effOrigin := if origin.trimAscii.toString.isEmpty then "orb" else origin.trimAscii.toString
  if let .error e ← execParamQuery store.projectsDb
      "INSERT INTO project_steers(id,slug,body,created_at,origin) VALUES(?1,?2,?3,?4,?5);"
      #[sid, scopedSlug, cleanBody, nowIso, effOrigin] then
    return .error e
  return .ok (.obj #[
    ("id", .str sid),
    ("slug", .str scopedSlug),
    ("body", .str cleanBody),
    ("created_at", .str nowIso),
    ("consumed_at", .null),
    ("origin", .str effOrigin)
  ])

def listProjectDecisionsJVal (store : CoreStore) (scopedSlug : String) : IO (Array JVal) := do
  let mut out : Array JVal := #[]
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT id,question,COALESCE(rationale,''),COALESCE(status,'pending'),COALESCE(answered,0),COALESCE(answer,''),COALESCE(answered_at,''),COALESCE(authority,'escalation'),COALESCE(evidence,''),COALESCE(updated_at,at,'') FROM project_decisions WHERE slug=?1 OR project_slug=?1 ORDER BY COALESCE(updated_at,at,'') DESC LIMIT 100;"
      #[scopedSlug] then
    for i in [1:rows.size] do
      let r := rows[i]!
      out := out.push (.obj #[
        ("id", .str (cell r 0)),
        ("question", .str (cell r 1)),
        ("rationale", optStrJVal (cell r 2)),
        ("status", .str (cell r 3)),
        ("answered", .bool (cell r 4 != "0")),
        ("answer", optStrJVal (cell r 5)),
        ("answered_at", optStrJVal (cell r 6)),
        ("authority", .str (cell r 7)),
        ("evidence", optStrJVal (cell r 8)),
        ("updated_at", .str (cell r 9))
      ])
  return out

def recordProjectDecisionJVal (store : CoreStore) (scopedSlug : String) (jv : JVal) (nowIso : String) : IO (Except String JVal) := do
  let q := ((jv.fieldStr? "question").orElse (fun _ => jv.fieldStr? "summary") |>.getD "").trimAscii.toString
  if q.isEmpty then return .error "missing_question"
  let did ← match (jv.fieldStr? "id").filter (!·.isEmpty) with | some x => pure x | none => newUuidV4
  let rat := (jv.fieldStr? "rationale").getD ""
  let auth := (jv.fieldStr? "authority").getD "escalation"
  let evid := (jv.fieldStr? "evidence").getD ""
  let ans := (jv.fieldStr? "answer").getD ""
  let answered := if ans.isEmpty then "0" else "1"
  let status := if ans.isEmpty then ((jv.fieldStr? "status").getD "pending") else "answered"
  let ansAt := if ans.isEmpty then "" else nowIso
  if let .error e ← execParamQuery store.projectsDb
      ("INSERT INTO project_decisions(id,slug,project_slug,at,status,question,rationale,answered,authority,answer,answered_at,evidence,updated_at) " ++
       "VALUES(?1,?2,?2,?3,?4,?5,?6,CAST(?7 AS INTEGER),?8,NULLIF(?9,''),NULLIF(?10,''),?11,?3) " ++
       "ON CONFLICT(id) DO UPDATE SET status=excluded.status,question=excluded.question,rationale=excluded.rationale,answered=excluded.answered,answer=excluded.answer,answered_at=excluded.answered_at,evidence=excluded.evidence,updated_at=excluded.updated_at;")
      #[did, scopedSlug, nowIso, status, q, rat, answered, auth, ans, ansAt, evid] then
    return .error e
  return .ok (.obj #[
    ("id", .str did),
    ("slug", .str scopedSlug),
    ("question", .str q),
    ("status", .str status),
    ("answered", .bool (answered == "1")),
    ("answer", optStrJVal ans),
    ("updated_at", .str nowIso)
  ])

def answerProjectDecisionJVal (store : CoreStore) (scopedSlug decisionId answer nowIso : String) : IO (Except String JVal) := do
  let cleanAns := answer.trimAscii.toString
  if decisionId.isEmpty || cleanAns.isEmpty then return .error "missing_decision_id_or_answer"
  if let .error e ← execParamQuery store.projectsDb
      "UPDATE project_decisions SET answered=1,status='answered',answer=?3,answered_at=?4,updated_at=?4 WHERE id=?1 AND (slug=?2 OR project_slug=?2);"
      #[decisionId, scopedSlug, cleanAns, nowIso] then
    return .error e
  return .ok (.obj #[
    ("id", .str decisionId),
    ("slug", .str scopedSlug),
    ("status", .str "answered"),
    ("answered", .bool true),
    ("answer", .str cleanAns),
    ("answered_at", .str nowIso)
  ])

def buildProjectSituationJVal (store : CoreStore) (scopedSlug clientSlug : String) : IO JVal := do
  let mut pObj := JVal.obj #[("slug", .str clientSlug), ("title", .str clientSlug), ("status", .str "active")]
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT COALESCE(NULLIF(title,''),NULLIF(name,''),slug), COALESCE(objective,''), COALESCE(status,'active'), COALESCE(mode,''), COALESCE(next_action,''), COALESCE(blocker,''), COALESCE(updated_at,''), COALESCE(color,'') FROM projects WHERE slug=?1;"
      #[scopedSlug] then
    if rows.size > 1 then
      let r := rows[1]!
      pObj := .obj #[
        ("slug", .str clientSlug),
        ("title", .str (cell r 0)),
        ("objective", optStrJVal (cell r 1)),
        ("status", .str (cell r 2)),
        ("mode", optStrJVal (cell r 3)),
        ("next_action", optStrJVal (cell r 4)),
        ("blocker", optStrJVal (cell r 5)),
        ("updated_at", .str (cell r 6)),
        ("color", optStrJVal (cell r 7))
      ]
  let grant ← getProjectGrantJVal store scopedSlug clientSlug
  let steers ← listProjectSteersJVal store scopedSlug
  let decisions ← listProjectDecisionsJVal store scopedSlug
  let mut tracks : Array JVal := #[]
  if let .ok tRows ← execParamQuery store.projectsDb
      "SELECT track, COALESCE(title,track), COALESCE(desired_condition,desired_state,''), COALESCE(status,'open'), COALESCE(lifecycle,'active'), COALESCE(updated_at,''), COALESCE(state_revision,1) FROM project_tracks WHERE project_slug=?1 OR slug=?1 ORDER BY track ASC;"
      #[scopedSlug] then
    for i in [1:tRows.size] do
      let tr := tRows[i]!
      tracks := tracks.push (.obj #[
        ("track", .str (cell tr 0)),
        ("title", .str (cell tr 1)),
        ("desired_condition", .str (cell tr 2)),
        ("status", .str (cell tr 3)),
        ("lifecycle", .str (cell tr 4)),
        ("updated_at", .str (cell tr 5)),
        ("state_revision", JVal.uint64 (cellU64 tr 6))
      ])
  let mut tasks : Array JVal := #[]
  if let .ok tkRows ← execParamQuery store.missionsDb
      "SELECT task_key, track, mission_id, attempt_seq, status FROM mission_board_tasks WHERE project_slug=?1 ORDER BY task_key ASC;"
      #[scopedSlug] then
    for i in [1:tkRows.size] do
      let r := tkRows[i]!
      tasks := tasks.push (.obj #[
        ("task_key", .str (cell r 0)),
        ("track", .str (cell r 1)),
        ("mission_id", .str (cell r 2)),
        ("attempt_seq", JVal.uint64 (cellU64 r 3)),
        ("status", .str (cell r 4))
      ])
  return .obj #[
    ("slug", .str clientSlug),
    ("project", pObj),
    ("grant", grant),
    ("tracks", .arr tracks),
    ("tasks", .arr tasks),
    ("decisions", .arr decisions),
    ("steers", (steers.field? "steers").getD (.arr #[]))
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

  -- Step 1 (`#1545`): Cascade cron folders first (capturing rollback snapshot of mutated rows)
  let cronSnap ←
    if sameProjectDirMove then
      match ← cascadeRenameCronFolder store srcScopedSlug srcRel dstRel with
      | .ok snap => pure snap
      | .error e => return .error (500, e)
    else pure #[]

  -- Step 2: Perform filesystem copy/move when present on disk
  if srcExistsOnDisk then
    if let some parentDir := dstAbs.parent then
      if let .error e ← (IO.FS.createDirAll parentDir).toBaseIO then
        if sameProjectDirMove then restoreCronFolders store srcScopedSlug cronSnap
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
            if sameProjectDirMove then restoreCronFolders store srcScopedSlug cronSnap
            return .error (500, e)
          removeDirTree srcAbs
        else
          match ← (IO.FS.readBinFile srcAbs).toBaseIO with
          | .error e =>
            if sameProjectDirMove then restoreCronFolders store srcScopedSlug cronSnap
            return .error (500, s!"read_failed:{e}")
          | .ok bytes =>
            if let .error e ← (IO.FS.writeBinFile dstAbs bytes).toBaseIO then
              if sameProjectDirMove then restoreCronFolders store srcScopedSlug cronSnap
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
        -- Roll back filesystem move and cron folder mutations!
        if ← dstAbs.pathExists then
          discard <| (IO.FS.rename dstAbs srcAbs).toBaseIO
        restoreCronFolders store srcScopedSlug cronSnap
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
    ("moved_missions", .arr movedMissionJVals),
    ("moved_crons", JVal.nat cronSnap.size)
  ])

/-! ## Hermes Controller & Project Crons (`/api/projects/:slug/controller*`, `/api/projects/:slug/crons*`) -/

private def resolveHermesHome (workingDir : String) : IO System.FilePath := do
  if let some h ← IO.getEnv "HERMES_HOME" then
    let clean := h.trimAscii.toString
    if !clean.isEmpty then return System.FilePath.mk clean
  for cand in #["/root/.hermes", "/var/lib/hermes/.hermes", s!"{workingDir}/.hermes"] do
    let p := System.FilePath.mk cand
    if ← p.pathExists then return p
  return System.FilePath.mk s!"{workingDir}/.hermes"

private def readHermesJobsArray (hermesHome : System.FilePath) : IO (Array JVal) := do
  let jobsFile := hermesHome / "cron" / "jobs.json"
  if !(← jobsFile.pathExists) then return #[]
  match ← (try some <$> IO.FS.readFile jobsFile catch _ => pure none) with
  | none => return #[]
  | some raw =>
    match OrbBin.Json.parse raw with
    | .ok (.arr xs) => return xs
    | .ok (.obj kvs) =>
      match (kvs.find? (fun (k, _) => k == "jobs")).map Prod.snd with
      | some (.arr xs) => return xs
      | _ => return #[]
    | _ => return #[]

private def writeHermesJobsArray (hermesHome : System.FilePath) (jobs : Array JVal) : IO (Except String Unit) := do
  let cronDir := hermesHome / "cron"
  discard <| (IO.FS.createDirAll cronDir).toBaseIO
  let wrapper := JVal.obj #[("jobs", .arr jobs), ("version", JVal.nat 1)]
  writeAtomicPrivate0600 (cronDir / "jobs.json") ((renderPretty wrapper) ++ "\n").toUTF8

private def normalizeHermesControllerJob (job : JVal) (folder : String) (archived : Bool) : JVal :=
  let id := (job.fieldStr? "id").getD ""
  let name := (job.fieldStr? "name").getD id
  let enabled := (job.fieldBool? "enabled").getD true
  let stateStr := (job.fieldStr? "state").getD (if enabled then "active" else "paused")
  .obj #[
    ("id", .str id),
    ("name", .str name),
    ("folder", .str folder),
    ("archived", .bool archived),
    ("schedule", job.fieldOrNull "schedule"),
    ("enabled", .bool enabled),
    ("state", .str stateStr),
    ("paused_reason", job.fieldOrNull "paused_reason"),
    ("next_run_at", job.fieldOrNull "next_run_at"),
    ("last_run_at", job.fieldOrNull "last_run_at"),
    ("last_status", job.fieldOrNull "last_status"),
    ("last_error", job.fieldOrNull "last_error"),
    ("failure_streak", JVal.nat ((job.fieldNat? "failure_streak").getD 0)),
    ("deliver", job.fieldOrNull "deliver")
  ]

private def normalizeHermesControllerSettings (job : JVal) : JVal :=
  let prompt := (job.fieldStr? "prompt").getD ""
  let skills := (job.fieldArr? "skills").getD #[]
  let toolsets := (job.fieldArr? "enabled_toolsets").getD #[]
  .obj #[
    ("prompt", .str prompt),
    ("prompt_chars", JVal.nat prompt.length),
    ("skills", .arr skills),
    ("deliver", job.fieldOrNull "deliver"),
    ("failure_deliver", job.fieldOrNull "failure_deliver"),
    ("repeat_times", job.fieldOrNull "repeat_times"),
    ("repeat_completed", JVal.nat ((job.fieldNat? "repeat_completed").getD 0)),
    ("model", job.fieldOrNull "model"),
    ("provider", job.fieldOrNull "provider"),
    ("reasoning_effort", job.fieldOrNull "reasoning_effort"),
    ("workdir", job.fieldOrNull "workdir"),
    ("no_agent", .bool ((job.fieldBool? "no_agent").getD false)),
    ("continuity", .bool ((job.fieldBool? "continuity").getD false)),
    ("enabled_toolsets", .arr toolsets),
    ("created_at", job.fieldOrNull "created_at")
  ]

def buildControllerViewJVal (store : CoreStore) (workingDir scopedSlug clientSlug : String) : IO JVal := do
  let hermesHome ← resolveHermesHome workingDir
  let jobs ← readHermesJobsArray hermesHome
  let mut pinnedId := ""
  if let .ok pRows ← execParamQuery store.projectsDb
      "SELECT COALESCE(controller_cron_id,'') FROM projects WHERE slug=?1;" #[scopedSlug] then
    if pRows.size > 1 then pinnedId := cell pRows[1]! 0
  let expectedDeliver := s!"project:{clientSlug}"
  let found? :=
    if !pinnedId.isEmpty then
      jobs.find? (fun j => (j.fieldStr? "id").getD "" == pinnedId)
    else
      jobs.find? (fun j =>
        (j.fieldStr? "deliver").getD "" == expectedDeliver ||
        (j.fieldStr? "project").getD "" == clientSlug)
  match found? with
  | none =>
    return .obj #[("slug", .str clientSlug), ("job", .null), ("settings", .null), ("runs", .arr #[])]
  | some j =>
    let jid := (j.fieldStr? "id").getD ""
    let mut archived := false
    if let .ok aRows ← execParamQuery store.projectsDb
        "SELECT COUNT(*) FROM controller_archives WHERE slug=?1 AND job_id=?2;" #[scopedSlug, jid] then
      if aRows.size > 1 && cellU64 aRows[1]! 0 > 0 then archived := true
    let mut folder := (j.fieldStr? "folder").getD ""
    if let .ok cRows ← execParamQuery store.projectsDb
        "SELECT COALESCE(folder,'') FROM project_crons WHERE slug=?1 AND job_id=?2;" #[scopedSlug, jid] then
      if cRows.size > 1 then folder := normalizeMissionFolder (cell cRows[1]! 0)
    return .obj #[
      ("slug", .str clientSlug),
      ("job", normalizeHermesControllerJob j folder archived),
      ("settings", normalizeHermesControllerSettings j),
      ("runs", .arr #[])
    ]

def listProjectCronsJVal (store : CoreStore) (workingDir scopedSlug clientSlug : String) : IO JVal := do
  let hermesHome ← resolveHermesHome workingDir
  let allJobs ← readHermesJobsArray hermesHome
  let mut boundMap : Array (String × String) := #[]
  if let .ok rows ← execParamQuery store.projectsDb
      "SELECT job_id, COALESCE(folder,'') FROM project_crons WHERE slug=?1 ORDER BY created_at ASC;" #[scopedSlug] then
    for i in [1:rows.size] do
      boundMap := boundMap.push (cell rows[1 * i]! 0, normalizeMissionFolder (cell rows[1 * i]! 1))
  let mut out : Array JVal := #[]
  for (jid, folder) in boundMap do
    if let some rawJob := allJobs.find? (fun j => (j.fieldStr? "id").getD "" == jid) then
      let enriched := ((rawJob.setField "folder" (.str folder)).setField "project" (.str clientSlug))
      out := out.push enriched
  return .obj #[("jobs", .arr out)]

/-! ## Main HTTP Route Dispatcher (`dispatchProjectAndControllerRoutes?`) -/

private def dispatchProjectFilesAndCronsTail?
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (workingDir clientSlug scopedSlug : String)
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

    -- `/api/projects/:slug/controller*` & `/api/projects/:slug/crons*`
    if tail == ["controller"] then
      if method == "GET" then
        return some (jsonResp 200 (← buildControllerViewJVal store workingDir scopedSlug clientSlug))
      else if method == "PUT" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let hermesHome ← resolveHermesHome workingDir
        let jobs ← readHermesJobsArray hermesHome
        let expectedDeliver := s!"project:{clientSlug}"
        let existing? := jobs.find? (fun j => (j.fieldStr? "deliver").getD "" == expectedDeliver)
        let jid ← match existing?.bind (fun j => j.fieldStr? "id") with
          | some id => pure id
          | none => newUuidV4
        let baseJob := existing?.getD (.obj #[
          ("id", .str jid),
          ("name", .str s!"{clientSlug} controller"),
          ("enabled", .bool true),
          ("deliver", .str expectedDeliver),
          ("created_at", .str nowIso)
        ])
        let mut updated := baseJob
        for k in #["name", "schedule", "prompt", "deliver", "failure_deliver", "workdir", "model", "provider", "reasoning_effort", "skills", "continuity"] do
          if let some v := jv.field? k then
            updated := updated.setField k v
        let nextJobs :=
          if existing?.isSome then jobs.map (fun j => if (j.fieldStr? "id").getD "" == jid then updated else j)
          else jobs.push updated
        discard <| writeHermesJobsArray hermesHome nextJobs
        discard <| upsertProjectRecord store scopedSlug clientSlug clientSlug "" "active" "" nowIso
          (if isLegacyUnscoped then none else some callerUserId)
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET controller_cron_id=?2, updated_at=?3 WHERE slug=?1;" #[scopedSlug, jid, nowIso]
        if let some fld := jv.fieldStr? "folder" then
          discard <| execParamQuery store.projectsDb
            "INSERT INTO project_crons(slug,job_id,created_at,folder) VALUES(?1,?2,?3,?4) ON CONFLICT(job_id) DO UPDATE SET slug=excluded.slug,folder=excluded.folder;"
            #[scopedSlug, jid, nowIso, normalizeMissionFolder fld]
        return some (jsonResp 200 (← buildControllerViewJVal store workingDir scopedSlug clientSlug))
      else if method == "DELETE" then
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET controller_cron_id=NULL, updated_at=?2 WHERE slug=?1;" #[scopedSlug, nowIso]
        return some (jsonResp 200 (← buildControllerViewJVal store workingDir scopedSlug clientSlug))

    if method == "POST" && tail == ["controller", "action"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let act := ((jv.fieldStr? "action").getD "").trimAscii.toString.toLower
      let hermesHome ← resolveHermesHome workingDir
      let jobs ← readHermesJobsArray hermesHome
      let viewBefore ← buildControllerViewJVal store workingDir scopedSlug clientSlug
      if let some jid := (viewBefore.field? "job") >>= (fun j => j.fieldStr? "id") then
        if act == "archive" then
          discard <| execParamQuery store.projectsDb
            "INSERT OR IGNORE INTO controller_archives(slug,job_id) VALUES(?1,?2);" #[scopedSlug, jid]
        else if act == "restore" then
          discard <| execParamQuery store.projectsDb
            "DELETE FROM controller_archives WHERE slug=?1 AND job_id=?2;" #[scopedSlug, jid]
        else if act == "pause" || act == "resume" || act == "run" then
          let en := act != "pause"
          let stStr := if en then "active" else "paused"
          let nextJobs := jobs.map fun j =>
            if (j.fieldStr? "id").getD "" == jid then
              ((j.setField "enabled" (.bool en)).setField "state" (.str stStr))
            else j
          discard <| writeHermesJobsArray hermesHome nextJobs
      return some (jsonResp 200 (← buildControllerViewJVal store workingDir scopedSlug clientSlug))

    if method == "GET" && tail == ["crons", "defaults"] then
      return some (jsonResp 200 (.obj #[
        ("deliver", .str s!"project:{clientSlug}"),
        ("route_ready", .bool true),
        ("folders_supported", .bool true)
      ]))

    if tail == ["crons"] then
      if method == "GET" then
        return some (jsonResp 200 (← listProjectCronsJVal store workingDir scopedSlug clientSlug))
      else if method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let jid ← newUuidV4
        let folder := normalizeMissionFolder ((jv.fieldStr? "folder").getD "")
        let newJob := JVal.obj #[
          ("id", .str jid),
          ("name", .str ((jv.fieldStr? "name").getD "Scheduled job")),
          ("schedule", jv.fieldOrNull "schedule"),
          ("prompt", .str ((jv.fieldStr? "prompt").getD "")),
          ("enabled", .bool true),
          ("state", .str "active"),
          ("deliver", .str ((jv.fieldStr? "deliver").getD s!"project:{clientSlug}")),
          ("folder", .str folder),
          ("project", .str clientSlug),
          ("created_at", .str nowIso)
        ]
        let hermesHome ← resolveHermesHome workingDir
        let jobs ← readHermesJobsArray hermesHome
        discard <| writeHermesJobsArray hermesHome (jobs.push newJob)
        discard <| execParamQuery store.projectsDb
          "INSERT INTO project_crons(slug,job_id,created_at,folder) VALUES(?1,?2,?3,?4) ON CONFLICT(job_id) DO UPDATE SET slug=excluded.slug,folder=excluded.folder;"
          #[scopedSlug, jid, nowIso, folder]
        return some (jsonResp 201 (.obj #[("job", newJob)]))

    if tail.length ≥ 2 && tail[0]? == some "crons" && tail[1]? != some "defaults" then
      let jid := (percentDecodeStrict tail[1]!).getD tail[1]!
      let hermesHome ← resolveHermesHome workingDir
      let jobs ← readHermesJobsArray hermesHome
      if tail.length == 2 && method == "GET" then
        let mut folder := ""
        if let .ok r ← execParamQuery store.projectsDb
            "SELECT COALESCE(folder,'') FROM project_crons WHERE slug=?1 AND job_id=?2;" #[scopedSlug, jid] then
          if r.size > 1 then folder := normalizeMissionFolder (cell r[1]! 0)
        let job := (jobs.find? (fun j => (j.fieldStr? "id").getD "" == jid)).getD (.obj #[("id", .str jid), ("name", .str jid), ("enabled", .bool true)])
        return some (jsonResp 200 (.obj #[("job", (job.setField "folder" (.str folder)).setField "project" (.str clientSlug)), ("runs", .arr #[])]))
      else if tail.length == 2 && method == "PATCH" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let nextSlugClient := ((jv.fieldStr? "project").filter (!·.isEmpty)).getD clientSlug
        let nextScoped :=
          if isLegacyUnscoped then nextSlugClient
          else (scopeProjectSlug callerUserId bootstrapAdminId nextSlugClient).getD nextSlugClient
        let mut nextFolder := ""
        if let .ok r ← execParamQuery store.projectsDb
            "SELECT COALESCE(folder,'') FROM project_crons WHERE job_id=?1;" #[jid] then
          if r.size > 1 then nextFolder := normalizeMissionFolder (cell r[1]! 0)
        if let some f := jv.fieldStr? "folder" then
          nextFolder := normalizeMissionFolder f
        discard <| execParamQuery store.projectsDb
          "INSERT INTO project_crons(slug,job_id,created_at,folder) VALUES(?1,?2,?3,?4) ON CONFLICT(job_id) DO UPDATE SET slug=excluded.slug,folder=excluded.folder;"
          #[nextScoped, jid, nowIso, nextFolder]
        let mut updatedJob := (jobs.find? (fun j => (j.fieldStr? "id").getD "" == jid)).getD (.obj #[("id", .str jid), ("enabled", .bool true)])
        for k in #["name", "schedule", "prompt", "deliver", "failure_deliver", "workdir", "model", "provider", "reasoning_effort", "skills", "continuity"] do
          if let some v := jv.field? k then
            updatedJob := updatedJob.setField k v
        updatedJob := (updatedJob.setField "folder" (.str nextFolder)).setField "project" (.str nextSlugClient)
        let nextJobs := jobs.map (fun j => if (j.fieldStr? "id").getD "" == jid then updatedJob else j)
        discard <| writeHermesJobsArray hermesHome nextJobs
        return some (jsonResp 200 (.obj #[("job", updatedJob), ("runs", .arr #[])]))
      else if tail.length == 2 && method == "DELETE" then
        discard <| execParamQuery store.projectsDb "DELETE FROM project_crons WHERE job_id=?1;" #[jid]
        let nextJobs := jobs.filter (fun j => (j.fieldStr? "id").getD "" != jid)
        discard <| writeHermesJobsArray hermesHome nextJobs
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))
      else if tail == ["crons", tail[1]!, "action"] && method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let act := ((jv.fieldStr? "action").getD "").trimAscii.toString.toLower
        let en := act != "pause"
        let stStr := if en then "active" else "paused"
        let nextJobs := jobs.map fun j =>
          if (j.fieldStr? "id").getD "" == jid then
            ((j.setField "enabled" (.bool en)).setField "state" (.str stStr))
          else j
        discard <| writeHermesJobsArray hermesHome nextJobs
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))
    return none

set_option maxHeartbeats 800000 in
def dispatchProjectAndControllerRoutes?
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (workingDir : String)
    (method cleanPath rawTarget : String)
    (bodyBytes : ByteArray)
    (callerUserId bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool)
    (nowIso : String) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let qMap := parseQueryMap rawTarget

  -- Admin Host FS Endpoints (`/api/file-resources`, `/api/fs/{list,read,download}`)
  if method == "GET" && segs == ["api", "file-resources"] then
    return some (jsonResp 200 (.obj #[("resources", .arr #[])]))

  if segs.length == 3 && segs[0]? == some "api" && segs[1]? == some "fs" then
    if !isAdmin then return some (jsonErr 403 "admin_required")
    let sub := segs[2]!
    let rawPath := (qParam? qMap "path").getD workingDir
    let targetPath := if rawPath.trimAscii.toString.isEmpty then workingDir else rawPath.trimAscii.toString
    if targetPath.contains '\x00' || (targetPath.splitOn "..").length > 1 then
      return some (jsonErr 400 "invalid_path")
    let fp := System.FilePath.mk targetPath
    if method == "GET" && sub == "list" then
      if !(← fp.pathExists) || !(← fp.isDir) then
        return some (jsonErr 404 "directory_not_found")
      let mut items : Array JVal := #[]
      if let .ok es ← fp.readDir.toBaseIO then
        for e in es do
          let isDir ← e.path.isDir
          let st ← statIdentity e.path.toString false
          items := items.push (.obj #[
            ("name", .str e.fileName),
            ("path", .str e.path.toString),
            ("kind", .str (if isDir then "dir" else "file")),
            ("is_dir", .bool isDir),
            ("size", JVal.uint64 st.size)
          ])
      return some (jsonResp 200 (.obj #[("path", .str targetPath), ("entries", .arr items)]))
    else if method == "GET" && sub == "read" then
      match ← (IO.FS.readFile fp).toBaseIO with
      | .ok content => return some (jsonResp 200 (.obj #[("path", .str targetPath), ("content", .str content)]))
      | .error _ => return some (jsonErr 404 "file_not_found")
    else if method == "GET" && sub == "download" then
      match ← (IO.FS.readBinFile fp).toBaseIO with
      | .ok bytes => return some (200, "application/octet-stream", bytes)
      | .error _ => return some (jsonErr 404 "file_not_found")

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
      let owner? := if isLegacyUnscoped then none else some callerUserId
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
          "SELECT slug FROM project_bindings WHERE control_session_id=?1 LIMIT 1;" #[sid] then
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
    let scopedSlug :=
      if isLegacyUnscoped then clientSlug
      else (scopeProjectSlug callerUserId bootstrapAdminId clientSlug).getD clientSlug
    let tail := segs.drop 3

    -- `GET|DELETE /api/projects/:slug`
    if tail.isEmpty then
      if method == "GET" then
        let sit ← buildProjectSituationJVal store scopedSlug clientSlug
        return some (jsonResp 200 sit)
      else if method == "DELETE" then
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET status='deleted', updated_at=?2 WHERE slug=?1;" #[scopedSlug, nowIso]
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("slug", .str clientSlug)]))

    -- `GET /api/projects/:slug/{state,situation,updates,conversation}`
    if method == "GET" && (tail == ["state"] || tail == ["situation"]) then
      return some (jsonResp 200 (← buildProjectSituationJVal store scopedSlug clientSlug))
    if method == "GET" && tail == ["updates"] then
      return some (jsonResp 200 (.obj #[("updates", .arr #[])]))
    if method == "GET" && tail == ["conversation"] then
      return some (jsonResp 200 (.obj #[("mission_id", .null), ("messages", .arr #[])]))
    if method == "POST" && tail == ["reconcile", "ack"] then
      return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    -- `POST /api/projects/:slug/action` (`archive`, `restore`, `unarchive`)
    if method == "POST" && tail == ["action"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let act := ((jv.fieldStr? "action").getD "").trimAscii.toString.toLower
      let nextStatus :=
        if act == "archive" then "archived"
        else if act == "delete" then "deleted"
        else "active"
      discard <| upsertProjectRecord store scopedSlug clientSlug clientSlug "" nextStatus "" nowIso
        (if isLegacyUnscoped then none else some callerUserId)
      discard <| execParamQuery store.projectsDb
        "UPDATE projects SET status=?2, updated_at=?3 WHERE slug=?1;" #[scopedSlug, nextStatus, nowIso]
      return some (jsonResp 200 (.obj #[("ok", .bool true), ("slug", .str clientSlug), ("status", .str nextStatus)]))

    -- `POST /api/projects/:slug/rename`
    if method == "POST" && tail == ["rename"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let newTitle := ((jv.fieldStr? "title").orElse (fun _ => jv.fieldStr? "name") |>.getD clientSlug).trimAscii.toString
      match ← upsertProjectRecord store scopedSlug clientSlug newTitle "" "active" "" nowIso
          (if isLegacyUnscoped then none else some callerUserId) with
      | .ok rec => return some (jsonResp 200 rec)
      | .error e => return some (jsonErr 500 e)

    -- `POST|PUT /api/projects/:slug/appearance`
    if (method == "POST" || method == "PUT" || method == "PATCH") && tail == ["appearance"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let col := ((jv.fieldStr? "color").getD "").trimAscii.toString
      discard <| upsertProjectRecord store scopedSlug clientSlug clientSlug "" "active" col nowIso
        (if isLegacyUnscoped then none else some callerUserId)
      discard <| execParamQuery store.projectsDb
        "UPDATE projects SET color=NULLIF(?2,''), updated_at=?3 WHERE slug=?1;" #[scopedSlug, col, nowIso]
      return some (jsonResp 200 (.obj #[("slug", .str clientSlug), ("color", optStrJVal col)]))

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
        discard <| upsertProjectRecord store scopedSlug clientSlug clientSlug "" "active" "" nowIso
          (if isLegacyUnscoped then none else some callerUserId)
        discard <| execParamQuery store.projectsDb
          "UPDATE projects SET skills=?2, updated_at=?3 WHERE slug=?1;" #[scopedSlug, skJson, nowIso]
        return some (jsonResp 200 (.obj #[("skills", .arr skArr)]))

    -- `POST /api/projects/:slug/status` & `POST /api/projects/:slug/track`
    if method == "POST" && tail == ["status"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let stVal := (jv.fieldStr? "status").getD "active"
      let modeVal := (jv.fieldStr? "mode").getD ""
      let nextAct := (jv.fieldStr? "next_action").getD ""
      let blk := (jv.fieldStr? "blocker").getD ""
      discard <| upsertProjectRecord store scopedSlug clientSlug clientSlug "" stVal "" nowIso
        (if isLegacyUnscoped then none else some callerUserId)
      discard <| execParamQuery store.projectsDb
        "UPDATE projects SET status=?2, mode=COALESCE(NULLIF(?3,''),mode), next_action=COALESCE(NULLIF(?4,''),next_action), blocker=?5, updated_at=?6 WHERE slug=?1;"
        #[scopedSlug, stVal, modeVal, nextAct, blk, nowIso]
      return some (jsonResp 200 (← buildProjectSituationJVal store scopedSlug clientSlug))

    if method == "POST" && tail == ["track"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let trk := (jv.fieldStr? "track").getD ""
      let des := ((jv.fieldStr? "desired_condition").orElse (fun _ => jv.fieldStr? "desired_state")).getD ""
      let stVal := (jv.fieldStr? "status").getD "open"
      let (code, bodyStr) ← putProjectTrack store scopedSlug trk des stVal nowIso (jv.fieldNat? "expected_revision")
      return some (code, "application/json", bodyStr.toUTF8)

    if tail.length == 3 && tail[0]? == some "tracks" then
      let trk := (percentDecodeStrict tail[1]!).getD tail[1]!
      let subAct := tail[2]!
      if method == "GET" && subAct == "receipts" then
        return some (jsonResp 200 (.obj #[("track", .str trk), ("receipts", .arr #[])]))
      else if method == "POST" && (subAct == "accept" || subAct == "invalidate" || subAct == "evidence" || subAct == "reopen") then
        let nextSt :=
          if subAct == "accept" then "accepted"
          else if subAct == "reopen" || subAct == "invalidate" then "open"
          else "evidence_submitted"
        discard <| execParamQuery store.projectsDb
          "UPDATE project_tracks SET status=?3, state_revision=state_revision+1, updated_at=?4 WHERE (project_slug=?1 OR slug=?1) AND track=?2;"
          #[scopedSlug, trk, nextSt, nowIso]
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("track", .str trk), ("status", .str nextSt)]))

    -- `GET|POST /api/projects/:slug/grant`
    if tail == ["grant"] then
      if method == "GET" then
        return some (jsonResp 200 (← getProjectGrantJVal store scopedSlug clientSlug))
      else if method == "POST" || method == "PUT" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        match ← upsertProjectGrantJVal store scopedSlug clientSlug jv nowIso with
        | .ok gv => return some (jsonResp 200 gv)
        | .error e => return some (jsonErr 500 e)

    -- `GET|POST /api/projects/:slug/steers`
    if tail == ["steers"] then
      if method == "GET" then
        return some (jsonResp 200 (← listProjectSteersJVal store scopedSlug))
      else if method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let body := ((jv.fieldStr? "body").orElse (fun _ => jv.fieldStr? "message") |>.getD "")
        let orig := (jv.fieldStr? "origin").getD "orb"
        match ← addProjectSteerJVal store scopedSlug body orig nowIso with
        | .ok sv => return some (jsonResp 201 sv)
        | .error e => return some (jsonErr 400 e)

    -- `/api/projects/:slug/decision` & `/api/projects/:slug/decision/answer`
    if tail == ["decision"] then
      if method == "GET" then
        return some (jsonResp 200 (.obj #[("decisions", .arr (← listProjectDecisionsJVal store scopedSlug))]))
      else if method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        match ← recordProjectDecisionJVal store scopedSlug jv nowIso with
        | .ok dv => return some (jsonResp 200 dv)
        | .error e => return some (jsonErr 400 e)
    if method == "POST" && tail == ["decision", "answer"] then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let did := (jv.fieldStr? "id").orElse (fun _ => jv.fieldStr? "decision_id") |>.getD ""
      let ans := (jv.fieldStr? "answer").getD ""
      match ← answerProjectDecisionJVal store scopedSlug did ans nowIso with
      | .ok dv => return some (jsonResp 200 dv)
      | .error e => return some (jsonErr 400 e)

    -- `/api/projects/:slug/tasks*`
    if tail == ["tasks"] then
      if method == "GET" then
        let sit ← buildProjectSituationJVal store scopedSlug clientSlug
        return some (jsonResp 200 (.obj #[("tasks", (sit.field? "tasks").getD (.arr #[]))]))
      else if method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let tKey ← match (jv.fieldStr? "task_key").filter (!·.isEmpty) with | some k => pure k | none => newUuidV4
        let trk := (jv.fieldStr? "track").getD "default"
        let mid := (jv.fieldStr? "mission_id").getD ""
        let stVal := (jv.fieldStr? "status").getD "open"
        discard <| execParamQuery store.missionsDb
          "INSERT INTO mission_board_tasks(task_key,project_slug,track,mission_id,attempt_seq,status) VALUES(?1,?2,?3,?4,0,?5) ON CONFLICT(task_key) DO UPDATE SET track=excluded.track,mission_id=excluded.mission_id,status=excluded.status;"
          #[tKey, scopedSlug, trk, mid, stVal]
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("task_key", .str tKey), ("status", .str stVal)]))
    if tail.length == 2 && tail[0]? == some "tasks" then
      let tKey := (percentDecodeStrict tail[1]!).getD tail[1]!
      if method == "PATCH" || method == "POST" then
        let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
        let stVal := (jv.fieldStr? "status").getD "done"
        discard <| execParamQuery store.missionsDb
          "UPDATE mission_board_tasks SET status=?3 WHERE project_slug=?1 AND task_key=?2;"
          #[scopedSlug, tKey, stVal]
        return some (jsonResp 200 (.obj #[("ok", .bool true), ("task_key", .str tKey), ("status", .str stVal)]))
      else if method == "DELETE" then
        discard <| execParamQuery store.missionsDb
          "DELETE FROM mission_board_tasks WHERE project_slug=?1 AND task_key=?2;" #[scopedSlug, tKey]
        return some (jsonResp 200 (.obj #[("ok", .bool true)]))

    if let some r ← dispatchProjectFilesAndCronsTail? store broadcastHub? workingDir clientSlug scopedSlug tail qMap method bodyBytes callerUserId bootstrapAdminId isLegacyUnscoped nowIso then
      return some r

  return none

end OrbCore.ProjectFilesAndController
