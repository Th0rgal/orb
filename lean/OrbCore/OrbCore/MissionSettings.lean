import OrbCore.Store
import OrbCore.MissionMoveRecovery
import OrbCore.R7Core
import OrbCore.SecretAndApproval
import OrbBin.Json

namespace OrbCore.MissionSettings

open OrbCore.Store OrbCore.R7Core OrbCore.SecretAndApproval OrbBin.Json

def commitPlacementWithRecovery
    (store : CoreStore) (updates : Array CheckedPlacementUpdate) (owner nowIso : String)
    (beforeCommitExtra : IO (Except String Unit) := pure (.ok ()))
    (afterCommit : IO (Except String Unit) := pure (.ok ())) :
    IO (Except (Nat × String) (Array MissionPlacementItem × Array MissionPlacementItem)) := do
  if let .error _ ← MissionMoveRecovery.ensureSchema store.missionsDb then
    return .error (500, "move_marker_schema_failed")
  let beforeCommit := do
    match ← MissionMoveRecovery.mark store (updates.map (·.missionId)) owner nowIso with
    | .error e => return .error e
    | .ok () => beforeCommitExtra
  let moved ← batchSetMissionPlacementChecked store updates nowIso beforeCommit
  let (allMoved, changedMoved) ← match moved with
    | .error e => return .error e
    | .ok pair => pure pair
  if let .error _ := ← afterCommit then
    return .error (500, "move_secret_policy_failed")
  if let .error _ ← rebindMovedMissionMcpSessionsChecked store allMoved nowIso then
    return .error (500, "move_rebind_failed")
  if let .error _ ← MissionMoveRecovery.clearPending store (allMoved.map (·.missionId)) then
    return .error (500, "move_marker_clear_failed")
  return .ok (allMoved, changedMoved)

def normalizeModelEffortForBackend (backend? : Option String) (raw : String) : Option String :=
  let level := raw.trimAscii.toString.toLower
  match backend? with
  | some "antigravity" =>
    if level == "low" || level == "medium" || level == "high" then some level else none
  | some "claudecode" | some "codex" =>
    if level == "low" || level == "medium" || level == "high" || level == "xhigh" || level == "max" then some level else none
  | _ => none

structure Settings where
  title : String
  backend : String
  modelOverride : String
  modelEffort : String
  shortDescription? : Option String
  githubPr? : Option String

def resolve (existing : MissionRecord) (patch : JVal) : Except String Settings := do
  let backend := (patch.fieldStr? "backend").getD existing.backend
  let model := match patch.field? "model_override" with
    | some .null => ""
    | some (.str s) => s
    | _ => existing.modelOverride
  let effort ← match patch.field? "model_effort" with
    | some .null => pure ""
    | some (.str s) =>
      let t := s.trimAscii.toString
      if t.isEmpty then pure ""
      else match normalizeModelEffortForBackend (some backend) t with
        | some eff => pure eff
        | none => .error "unsupported_model_effort"
    | _ => pure existing.modelEffort
  return {
    title := (patch.fieldStr? "title").getD existing.title
    backend := backend
    modelOverride := model
    modelEffort := effort
    shortDescription? := patch.fieldStr? "short_description"
    githubPr? := patch.fieldStr? "github_pr"
  }

def persistQuery (store : CoreStore) (existing : MissionRecord) (settings : Settings)
    (nowIso : String) (query : SqliteDb → String → Array String → IO (Except String (Array (Array String)))) : IO (Except String Unit) := do
  match ← query store.missionsDb
      ("UPDATE missions SET title=?2, backend=?3, model_override=?4, model_effort=?5, " ++
       "session_id=CASE WHEN backend<>?3 THEN NULL ELSE session_id END, " ++
       "resumable=CASE WHEN backend<>?3 THEN 0 ELSE resumable END, " ++
       "metadata_updated_at=?6, state_revision=state_revision+1, " ++
       "short_description=CASE WHEN ?7='1' THEN ?8 ELSE short_description END, " ++
       "github_pr=CASE WHEN ?9='1' THEN ?10 ELSE github_pr END, " ++
       "repo=CASE WHEN ?9='1' THEN ?10 ELSE repo END WHERE id=?1;")
      #[existing.id, settings.title, settings.backend, settings.modelOverride, settings.modelEffort,
        nowIso,
        if settings.shortDescription?.isSome then "1" else "0", settings.shortDescription?.getD "",
        if settings.githubPr?.isSome then "1" else "0", settings.githubPr?.getD ""] with
  | .error e => return .error e
   | .ok _ => return .ok ()

def persist (store : CoreStore) (existing : MissionRecord) (settings : Settings)
    (nowIso : String) : IO (Except String Unit) :=
  persistQuery store existing settings nowIso execParamQuery

private def persistUnlocked (store : CoreStore) (existing : MissionRecord) (settings : Settings)
    (nowIso : String) : IO (Except String Unit) :=
  persistQuery store existing settings nowIso (fun db sql params => execParamQueryUnlocked db sql params)

private def unscopeDisplayProject (userId : String) (isLegacyUnscoped : Bool) (p : String) : String :=
  if !isLegacyUnscoped && !userId.isEmpty && p.startsWith (userId ++ ":") then
    (p.drop (userId.length + 1)).toString
  else
    p

/-- Resolve and atomically apply a family placement patch (`project`/`project_slug`/`folder`) on
    `/api/control/missions/:id/project` or `/api/control/missions/:id/settings` (`docs/ui/mission-moves.md`).
    Returns `.ok (some ssePayload)` when `mission_placement_changed` should be broadcast. -/
def applyPlacementPatch
    (store : CoreStore)
    (existing : MissionRecord)
    (jv : JVal)
    (callerUserId : String)
    (callerIsLegacyUnscoped : Bool)
    (bootstrapAdminId : String)
    (nowIso : String)
    (nowEpochSec : UInt64)
    (settings? : Option Settings := none) : IO (Except (Nat × String) (Option String)) := do
  let saveSettings := match settings? with
    | some settings => persistUnlocked store existing settings nowIso
    | none => pure (.ok ())
  let hasProjPatch := (jv.field? "project").isSome || (jv.field? "project_slug").isSome
  let hasFolderPatch := (jv.field? "folder").isSome
  if !hasProjPatch && !hasFolderPatch then
    if let some settings := settings? then
      if let .error _ ← persist store existing settings nowIso then
        return .error (500, "{\"error\":\"mission_settings_update_failed\"}")
    return .ok none
  let rawP ← do
    if !hasProjPatch then
      pure (unscopeDisplayProject callerUserId callerIsLegacyUnscoped existing.project)
    else
      match (jv.field? "project").orElse (fun _ => jv.field? "project_slug") with
      | none | some .null => pure ""
      | some (.str s) =>
        let t := s.trimAscii.toString
        pure (if t.isEmpty || t == "__unassigned__" then "" else t)
      | some _ => pure "__INVALID_PROJECT__"
  if rawP == "__INVALID_PROJECT__" then
    return .error (400, "{\"error\":\"invalid_project\"}")
  let nextProj ← do
    if !hasProjPatch then pure existing.project
    else if rawP.isEmpty || callerIsLegacyUnscoped then pure rawP
    else
      match scopeProjectSlug callerUserId bootstrapAdminId rawP with
      | some sp => pure sp
      | none => pure "__INVALID_PROJECT__"
  if nextProj == "__INVALID_PROJECT__" then
    return .error (400, "{\"error\":\"invalid_project\"}")
  let nextFolder ← do
    if !hasFolderPatch then
      pure (if nextProj.isEmpty || nextProj != existing.project then "" else existing.folder)
    else
      let parsedF ←
        match jv.field? "folder" with
        | none | some .null => pure ""
        | some (.str s) =>
          match normalizeMissionFolderStrict s with
          | .ok nf => pure nf
          | .error _ => pure "__INVALID_FOLDER__"
        | some _ => pure "__INVALID_FOLDER__"
      if parsedF == "__INVALID_FOLDER__" then pure "__INVALID_FOLDER__"
      else if nextProj.isEmpty then pure ""
      else pure parsedF
  if nextFolder == "__INVALID_FOLDER__" then
    return .error (400, "{\"error\":\"invalid_folder\"}")
  let policy := ((jv.fieldStr? "approval_policy").getD "check").trimAscii.toString.toLower
  if policy != "check" && policy != "revoke" && policy != "keep" then
    return .error (400, "{\"error\":\"invalid_approval_policy\"}")
  let descendantIds : Array String :=
    match jv.fieldArr? "descendant_ids" with
    | some xs => xs.filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    | none => #[]
  let callerOpt := if callerIsLegacyUnscoped then none else some callerUserId
  let plan ←
    match ← planExpandedMoveFamily store #[existing.id] descendantIds nextFolder callerOpt with
    | .ok p => pure p
    | .error (code, msg) => return .error (code, s!"\{\"error\":{jsonEscape msg}}")
  let crossProjIds := (plan.filter (fun m => m.currentProject != nextProj)).map (·.missionId)
  if !crossProjIds.isEmpty && policy == "check" then
    if let some confBody ← inspectCrossProjectSecretTransfer store.rootDir crossProjIds rawP nowEpochSec then
      return .error (409, confBody)
  let brokerPath := System.FilePath.mk s!"{store.rootDir}/secret_broker.json"
  let brokerRawBefore? ← do
    if !crossProjIds.isEmpty && (policy == "revoke" || policy == "keep") then
      if ← brokerPath.pathExists then
        let raw ← IO.FS.readFile brokerPath
        applyCrossProjectSecretPolicy store.rootDir crossProjIds rawP policy nowIso nowEpochSec
        pure (some raw)
      else
        pure none
    else
      pure none
  let updates : Array CheckedPlacementUpdate := plan.map fun m => {
    missionId       := m.missionId
    expectedProject := m.currentProject
    nextProject     := nextProj
    nextFolder      := m.targetFolder
  }
  let (_allMoved, changedMoved) ←
    match ← commitPlacementWithRecovery store updates (if callerIsLegacyUnscoped then "" else callerUserId) nowIso saveSettings with
    | .ok pair => pure pair
    | .error (code, msg) =>
      if let some prevRaw := brokerRawBefore? then
        IO.FS.writeFile brokerPath prevRaw
      return .error (code, s!"\{\"error\":{jsonEscape msg}}")
  if let .error e ← MissionMoveRecovery.reconcile store then
    return .error (500, s!"\{\"error\":{jsonEscape e}}")
  let unscopeItem (it : MissionPlacementItem) : MissionPlacementItem :=
    { it with project? := it.project?.map (unscopeDisplayProject callerUserId callerIsLegacyUnscoped) }
  let changedDisplay := changedMoved.map unscopeItem
  if changedDisplay.isEmpty then
    return .ok none
  return .ok (some (renderMissionPlacementChangedEventJson changedDisplay none none))

end OrbCore.MissionSettings
