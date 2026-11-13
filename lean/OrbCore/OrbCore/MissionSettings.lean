import OrbCore.Store
import OrbBin.Json

namespace OrbCore.MissionSettings

open OrbCore.Store OrbBin.Json

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

def persist (store : CoreStore) (existing : MissionRecord) (settings : Settings)
    (nowIso : String) (placement? : Option (String × String) := none) : IO (Except String Unit) := do
  let (project, folder) := placement?.getD (existing.project, existing.folder)
  let placementChanged := project != existing.project || folder != existing.folder
  match ← execParamQuery store.missionsDb
      ("UPDATE missions SET title=?2, backend=?3, model_override=?4, model_effort=?5, " ++
       "session_id=CASE WHEN backend<>?3 THEN NULL ELSE session_id END, " ++
       "resumable=CASE WHEN backend<>?3 THEN 0 ELSE resumable END, " ++
       "project=?6, folder=?7, placement_revision=CASE WHEN ?8='1' THEN COALESCE(placement_revision,0)+1 ELSE placement_revision END, " ++
       "metadata_updated_at=?9, state_revision=state_revision+1, " ++
       "short_description=CASE WHEN ?10='1' THEN ?11 ELSE short_description END, " ++
       "github_pr=CASE WHEN ?12='1' THEN ?13 ELSE github_pr END, " ++
       "repo=CASE WHEN ?12='1' THEN ?13 ELSE repo END WHERE id=?1;")
      #[existing.id, settings.title, settings.backend, settings.modelOverride, settings.modelEffort,
        project, folder, if placementChanged then "1" else "0", nowIso,
        if settings.shortDescription?.isSome then "1" else "0", settings.shortDescription?.getD "",
        if settings.githubPr?.isSome then "1" else "0", settings.githubPr?.getD ""] with
  | .error e => return .error e
  | .ok _ => return .ok ()

end OrbCore.MissionSettings
