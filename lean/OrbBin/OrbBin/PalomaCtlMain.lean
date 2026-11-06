/-
  OrbBin.PalomaCtlMain: Native Lean `palomactl` Control-Plane CLI (`0 import Lean`),
  implementing `models` (`discover`, `export`, `validate`, `diff`, `snapshot update`),
  `status`, `reconcile`, `import-trackers`, `pr-gates` (backed directly by `Orb.Kernel.prGateStep`),
  `set-mode`, `dispatch-plan`, `repair-borrowed-tracks`, `validation-matrix`, and `cluster-lean-errors`.
-/
import Orb.Kernel
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient

namespace OrbBin.PalomaCtl

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

def printUsage : IO Unit :=
  IO.println <|
    "usage:\n" ++
    "  palomactl models discover|export|diff|validate|snapshot update\n" ++
    "  palomactl status\n" ++
    "  palomactl reconcile [--api <url> [--token <jwt>] [--dir <trackers>] [slug...]]\n" ++
    "  palomactl import-trackers --api <url> [--token <jwt>] [--dir <trackers>] [--dry-run] [slug...]\n" ++
    "  palomactl pr-gates <owner/repo> <number> [--worker-head <sha>]\n" ++
    "  palomactl set-mode <project> <mode> --until <iso>\n" ++
    "  palomactl dispatch-plan --project <slug>\n" ++
    "  palomactl repair-borrowed-tracks --api <url> [--token <jwt>] [--apply]\n" ++
    "  palomactl validation-matrix [path]\n" ++
    "  palomactl cluster-lean-errors <log-path>"

def valueAfterFlag? (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: b :: rest => if a == flag then some b else valueAfterFlag? (b :: rest) flag
  | [_] => none

def validateProjectSlug (slug : String) : Except String Unit := do
  if slug.isEmpty || slug == "." || slug == ".." || slug.contains '/' || slug.contains '\\' ||
     !slug.all (fun c => c.isAlphanum || c == '-' || c == '_') then
    throw "project slug must be non-empty and contain only ASCII letters, numbers, '-' or '_'"

def prGateRecommendation (code : UInt8) : String :=
  if code == 0 then "already_merged"
  else if code == 1 then "wait_for_ready_for_review"
  else if code == 2 then "closed_without_merge"
  else if code == 3 then "head_changed_since_worker"
  else if code == 4 then "action_required_external"
  else if code == 5 then "blocked_by_policy"
  else if code == 6 then "needs_update_with_base"
  else if code == 7 then "needs_conflict_resolution"
  else if code == 8 then "ready_for_review_or_merge"
  else "needs_checks_or_review"

/-! ### `cluster-lean-errors`: Exact Normalized SHA-256 Diagnostic Clustering -/

def normalizeDiagnostic (line : String) : String := Id.run do
  let mut chars : Array Char := Array.mkEmpty line.length
  let mut inDigits := false
  for ch in line.toList do
    if ch.isDigit then
      if !inDigits then chars := chars.push '#'
      inDigits := true
    else
      inDigits := false
      chars := chars.push ch.toLower
  let raw := String.ofList chars.toList
  let words := (raw.splitToList (fun c => c == ' ' || c == '\t' || c == '\r' || c == '\n')).filter (!·.isEmpty)
  return String.intercalate " " words

structure DiagCluster where
  fingerprint    : String
  representative : String
  count          : Nat
  deriving Repr, Inhabited

def clusterDiagnostics (raw : String) : JVal := Id.run do
  let mut clusters : Array DiagCluster := #[]
  for rawLine in raw.splitOn "\n" do
    let line := rawLine.trimAscii.toString
    if !line.isEmpty then
      let norm := normalizeDiagnostic line
      let fp := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes norm.toUTF8)
      match clusters.findIdx? (fun c => c.fingerprint == fp) with
      | some idx =>
        let cur := clusters[idx]!
        clusters := clusters.set! idx { cur with count := cur.count + 1 }
      | none =>
        clusters := clusters.push { fingerprint := fp, representative := line, count := 1 }
  let sorted := clusters.qsort (fun a b =>
    if a.count != b.count then a.count > b.count
    else a.representative < b.representative)
  return .arr (sorted.map fun c =>
    .obj #[
      ("fingerprint", .str c.fingerprint),
      ("representative", .str c.representative),
      ("count", .nat c.count)
    ])

/-! ### `pr-gates`: Fixture + `gh` CLI Loader & Direct `Orb.Kernel.prGateStep` Evaluator -/

private def isAcceptedCheckConclusion (c : String) : Bool :=
  let lc := c.trimAscii.toString.toLower
  lc == "success" || lc == "skipped" || lc == "neutral"

def evaluateAndAnnotatePrGates
    (rawGates : JVal) (ownerRepo : String) (number : Nat) (workerHead? : Option String) : JVal := Id.run do
  let state := (rawGates.fieldStr? "state").getD "OPEN"
  let draft := (rawGates.fieldBool? "draft").orElse (fun _ => rawGates.fieldBool? "isDraft") |>.getD false
  let merged := (rawGates.fieldBool? "merged").getD (state.toLower == "merged")
  let mergeable? : Option Bool :=
    match rawGates.field? "mergeable" with
    | some (.bool b) => some b
    | some (.str s) =>
      let ls := s.toLower
      if ls == "mergeable" then some true
      else if ls == "conflicting" then some false
      else none
    | _ => none
  let mergeStateStatus? := (rawGates.fieldStr? "merge_state_status")
    |>.orElse (fun _ => rawGates.fieldStr? "mergeStateStatus")
  let mssLower := (mergeStateStatus?.getD "").toLower
  let blocked := mssLower == "blocked"
  let behind := mssLower == "behind"
  let rawConflicting := (rawGates.fieldBool? "conflicting").getD false
  let conflicting := rawConflicting || mssLower == "dirty" || (mergeable? == some false && !blocked && !behind)
  let checks : Array JVal :=
    match rawGates.fieldArr? "checks" with
    | some arr => arr
    | none =>
      match rawGates.fieldArr? "statusCheckRollup" with
      | some rollup =>
        rollup.map fun item =>
          let name := (item.fieldStr? "name").orElse (fun _ => item.fieldStr? "context") |>.getD ""
          if let some st := item.fieldStr? "status" then
            .obj #[
              ("name", .str name),
              ("status", .str st.toLower),
              ("conclusion", match item.fieldStr? "conclusion" with | some c => .str c.toLower | none => .null)
            ]
          else
            let ctxState := ((item.fieldStr? "state").getD "").toLower
            let st := if ctxState == "success" || ctxState == "failure" || ctxState == "error" then "completed" else "in_progress"
            let concl := if ctxState == "success" then "success" else if ctxState == "failure" || ctxState == "error" then "failure" else ""
            .obj #[
              ("name", .str name),
              ("status", .str st),
              ("conclusion", .str concl)
            ]
      | none => #[]
  let workflowRuns := (rawGates.fieldArr? "workflow_runs").getD #[]
  let checksGreen := !checks.isEmpty && checks.all (fun c =>
    ((c.fieldStr? "status").getD "").toLower == "completed" &&
    match c.fieldStr? "conclusion" with
    | some concl => isAcceptedCheckConclusion concl
    | none => false)
  let actionRequired := workflowRuns.any (fun r =>
    ((r.fieldStr? "status").getD "").toLower == "completed" &&
    ((r.fieldStr? "conclusion").getD "").toLower == "action_required")
  let workflowRunsGreen := workflowRuns.isEmpty || workflowRuns.all (fun r =>
    ((r.fieldStr? "status").getD "").toLower == "completed" &&
    match r.fieldStr? "conclusion" with
    | some concl => isAcceptedCheckConclusion concl
    | none => false)
  let currentHead? := (rawGates.fieldStr? "current_head")
    |>.orElse (fun _ => rawGates.fieldStr? "headRefOid")
  let effectiveWorkerHead? :=
    match workerHead?.filter (!·.trimAscii.isEmpty) with
    | some wh => some wh.trimAscii.toString
    | none => rawGates.fieldStr? "worker_head"
  let exactHead := match effectiveWorkerHead?, currentHead? with
    | some wh, some ch => wh.toLower == ch.toLower
    | _, _ => true
  let closed := state.toLower == "closed"
  let code := Orb.Kernel.prGateStep
    (if merged then 1 else 0)
    (if draft then 1 else 0)
    (if closed then 1 else 0)
    (if exactHead then 1 else 0)
    (if actionRequired then 1 else 0)
    (if blocked then 1 else 0)
    (if behind then 1 else 0)
    (if conflicting then 1 else 0)
    (if checksGreen then 1 else 0)
    (if workflowRunsGreen then 1 else 0)
  let recStr := prGateRecommendation code
  let bugbot := (rawGates.fieldBool? "bugbot_accessible").getD false
  return .obj #[
    ("owner_repo", .str ownerRepo),
    ("number", .nat number),
    ("state", .str state),
    ("draft", .bool draft),
    ("merged", .bool merged),
    ("mergeable", match mergeable? with | some b => .bool b | none => .null),
    ("merge_state_status", match mergeStateStatus? with | some s => .str s | none => .null),
    ("conflicting", .bool conflicting),
    ("checks", .arr checks),
    ("workflow_runs", .arr workflowRuns),
    ("current_head", match currentHead? with | some h => .str h | none => .null),
    ("worker_head", match effectiveWorkerHead? with | some h => .str h | none => .null),
    ("bugbot_accessible", .bool bugbot),
    ("recommendation", .str recStr)
  ]

def loadPrGates (root : System.FilePath) (ownerRepo : String) (number : Nat) : IO (Except String JVal) := do
  let safeRepo := String.intercalate "__" (ownerRepo.splitOn "/")
  let f1 := root / ".paloma" / "fixtures" / s!"pr-{safeRepo}-{number}.json"
  let f2 := root / ".paloma" / "fixtures" / s!"pr-{number}.json"
  for cand in [f1, f2] do
    if (← cand.pathExists) then
      let raw ← IO.FS.readFile cand
      match Json.parse raw with
      | .ok j => return .ok j
      | .error e => return .error s!"invalid PR fixture `{cand}`: {e}"
  let out ← IO.Process.output {
    cmd := "gh"
    args := #[
      "pr", "view", toString number, "--repo", ownerRepo, "--json",
      "state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup,mergedAt"
    ]
  }
  if out.exitCode != 0 then
    return .error s!"gh pr view failed: {out.stderr.trimAscii.toString}"
  let prJson ← match Json.parse out.stdout with
    | .ok j => pure j
    | .error e => return .error s!"invalid gh pr view JSON: {e}"
  let merged := match prJson.field? "mergedAt" with
    | some .null | none => false
    | _ => true
  let mut enriched := prJson.setField "merged" (.bool merged)
  if let some headSha := prJson.fieldStr? "headRefOid" then
    let wfOut ← IO.Process.output {
      cmd := "gh"
      args := #["api", s!"repos/{ownerRepo}/actions/runs?head_sha={headSha}&per_page=100"]
    }
    if wfOut.exitCode == 0 then
      if let .ok wfJson := Json.parse wfOut.stdout then
        if let some runs := wfJson.fieldArr? "workflow_runs" then
          let mapped := runs.map fun r => JVal.obj #[
            ("name", .str ((r.fieldStr? "name").getD "")),
            ("status", .str ((r.fieldStr? "status").getD "")),
            ("conclusion", match r.fieldStr? "conclusion" with | some c => .str c | none => .null),
            ("head_sha", .str ((r.fieldStr? "head_sha").getD "")),
            ("url", .str ((r.fieldStr? "html_url").getD ""))
          ]
          enriched := enriched.setField "workflow_runs" (.arr mapped)
  return .ok enriched

/-! ### Minimal TOML/JSON Validation Matrix Parser (`validation-matrix`) -/

private def stripTomlComment (line : String) : String := Id.run do
  let mut inStr := false
  let mut esc := false
  let mut out : Array Char := #[]
  for c in line.toList do
    if esc then
      out := out.push c; esc := false
    else if c == '\\' && inStr then
      out := out.push c; esc := true
    else if c == '"' then
      inStr := !inStr; out := out.push c
    else if c == '#' && !inStr then
      break
    else
      out := out.push c
  return (String.ofList out.toList).trimAscii.toString

def parseValidationMatrixText (raw : String) : Except String JVal := do
  let trimmed := raw.trimAscii.toString
  if trimmed.startsWith "{" then
    return (← Json.parse trimmed)
  let mut version : Nat := 1
  let mut project : String := ""
  let mut profile? : Option String := none
  let mut gates : Array JVal := #[]
  let mut curGate : Option (Array (String × JVal)) := none
  for rawLine in raw.splitOn "\n" do
    let line := stripTomlComment rawLine
    if !line.isEmpty then
      if line == "[[gates]]" then
        if let some g := curGate then
          gates := gates.push (.obj g)
        curGate := some #[
          ("dependencies", .arr #[]),
          ("required", .bool true),
          ("mode", .str "incremental"),
          ("reuse", .bool true),
          ("artifacts", .arr #[])
        ]
      else if let keyPart :: valParts := line.splitOn "=" then
        if !valParts.isEmpty then
          let k := keyPart.trimAscii.toString
          let vRaw := (String.intercalate "=" valParts).trimAscii.toString
          let vParsed ← Json.parse vRaw
          match curGate with
          | none =>
            if k == "version" then version := (vParsed.asNat?).getD 1
            else if k == "project" then project := (vParsed.asStr?).getD ""
            else if k == "profile" then profile? := vParsed.asStr?
          | some g =>
            let normKey := if k == "depends_on" then "dependencies" else k
            let updated := JVal.setField (.obj g) normKey vParsed
            curGate := updated.asObj?
  if let some g := curGate then
    gates := gates.push (.obj g)
  return .obj #[
    ("version", .nat version),
    ("project", .str project),
    ("profile", match profile? with | some p => .str p | none => .null),
    ("gates", .arr gates)
  ]

private def validGateId (id : String) : Bool :=
  !id.isEmpty && id.length ≤ 80 && id.all (fun c => c.isAlphanum || c == '_' || c == '-')

partial def checkGateCycle
    (id : String) (gates : Array JVal) (visiting visited : List String) : Except String (List String) := do
  if visited.contains id then return visited
  if visiting.contains id then throw s!"validation gate dependency cycle contains '{id}'"
  let some g := gates.find? (fun x => x.fieldStr? "id" == some id)
    | throw s!"unknown gate '{id}'"
  let deps := ((g.fieldArr? "dependencies").getD #[]).filterMap JVal.asStr?
  let mut vis := visited
  for dep in deps do
    vis ← checkGateCycle dep gates (id :: visiting) vis
  return id :: vis

def validateMatrixJson (m : JVal) : Except String JVal := do
  let ver := (m.fieldNat? "version").getD 1
  if ver != 1 then throw s!"unsupported validation matrix version {ver}"
  let proj := ((m.fieldStr? "project").getD "").trimAscii.toString
  if proj.isEmpty then throw "matrix.project is required"
  let gates := (m.fieldArr? "gates").getD #[]
  if gates.isEmpty then throw "matrix.gates must not be empty"
  let mut seen : List String := []
  for g in gates do
    let gid := (g.fieldStr? "id").getD ""
    if !validGateId gid then throw s!"invalid gate id '{gid}'"
    if seen.contains gid then throw s!"duplicate gate id '{gid}'"
    seen := gid :: seen
    let cmd := ((g.fieldArr? "command").getD #[]).filterMap JVal.asStr?
    if cmd.isEmpty || cmd.any (fun a => a.any (· == '\x00')) then
      throw s!"gate '{gid}' requires a safe, non-empty argv"
    if g.fieldNat? "timeout_secs" == some 0 then
      throw s!"gate '{gid}' timeout_secs must be positive"
  for g in gates do
    let gid := (g.fieldStr? "id").getD ""
    let req := (g.fieldBool? "required").getD true
    let deps := ((g.fieldArr? "dependencies").getD #[]).filterMap JVal.asStr?
    for dep in deps do
      if dep == gid then throw s!"gate '{gid}' has invalid dependency '{dep}'"
      let some dg := gates.find? (fun x => x.fieldStr? "id" == some dep)
        | throw s!"gate '{gid}' has invalid dependency '{dep}'"
      let depReq := (dg.fieldBool? "required").getD true
      if req && !depReq then
        throw s!"required gate '{gid}' depends on optional gate '{dep}'"
  let mut visited : List String := []
  for g in gates do
    let gid := (g.fieldStr? "id").getD ""
    visited ← checkGateCycle gid gates [] visited
  return m

/-! ### `models`: Snapshot-Directory Catalog Validate / Export / Diff / Discover / Update -/

private def isSafeSnapshotSlug (s : String) : Bool :=
  !s.isEmpty && s.length < 100 && s.all (fun c => c.isAlphanum || c == '-' || c == '_')

private def validateSnapshotJson (v : JVal) : Except String (String × String × String × Array JVal) := do
  let some obj := v.asObj?
    | throw "snapshot must be a JSON object"
  let allowedKeys := #["schema_version", "provider_id", "access_profile", "source", "observed_at", "completeness", "models"]
  for (k, _) in obj do
    if !allowedKeys.contains k then
      throw s!"unknown snapshot field: {k}"
  let some schemaVer := v.fieldNat? "schema_version"
    | throw "missing schema_version"
  if schemaVer != 1 then
    throw "unsupported snapshot schema"
  let providerId := (v.fieldStr? "provider_id").getD ""
  let accessProfile := (v.fieldStr? "access_profile").getD ""
  if !isSafeSnapshotSlug providerId || !isSafeSnapshotSlug accessProfile then
    throw "invalid provider/profile"
  let source := (v.fieldStr? "source").getD ""
  if source != "curated" && source != "discovery" then
    throw "invalid snapshot source"
  let obsOpt := v.field? "observed_at"
  let hasObs := match obsOpt with
    | some (.str s) => !s.isEmpty
    | _ => false
  if source == "discovery" && !hasObs then
    throw "discovery snapshot needs observed_at"
  let completeness := (v.fieldStr? "completeness").getD ""
  if completeness != "complete" && completeness != "partial" then
    throw "invalid snapshot completeness"
  let some models := v.fieldArr? "models"
    | throw "missing snapshot models array"
  if models.isEmpty then
    throw "empty snapshot cannot replace fallback models"
  let mut seenIds : Array String := #[]
  for m in models do
    let mid := (m.fieldStr? "id").getD ""
    let hasCtrl := mid.toList.any (fun c => c.toNat < 0x20 || c.toNat == 0x7F)
    if mid.trimAscii.toString != mid || mid.isEmpty || mid.length > 256 || hasCtrl ||
       (mid.splitOn "://").length > 1 || mid.contains '@' || seenIds.contains mid then
      throw s!"invalid or duplicate model ID: {mid}"
    if providerId == "zai" && mid == "glm-5.3[1m]" then
      throw "use glm-5.3; context size is metadata, not an API ID"
    seenIds := seenIds.push mid
  return (providerId, accessProfile, completeness, models)

private def snapshotFilename (providerId accessProfile : String) : String :=
  s!"{providerId}-{accessProfile}.json"

def loadSnapshotDir (dir : System.FilePath) : IO (Except String (Array (String × JVal))) := do
  if !(← dir.isDir) then
    return .error s!"read {dir}: not a directory"
  let entries ← try dir.readDir catch e => return .error s!"read {dir}: {e}"
  let mut out : Array (String × JVal) := #[]
  for entry in entries do
    let p := entry.path
    if p.extension == some "json" then
      let raw ← try IO.FS.readFile p catch e => return .error s!"read {p}: {e}"
      let parsed ← match Json.parse raw with
        | .ok j => pure j
        | .error e => return .error s!"parse {p}: {e}"
      match validateSnapshotJson parsed with
      | .error e => return .error s!"{p}: {e}"
      | .ok (prov, prof, _, _) =>
        let expected := snapshotFilename prov prof
        if entry.fileName != expected then
          return .error s!"snapshot filename must match {expected}"
        if out.any (fun (k, _) => k == expected) then
          return .error "duplicate snapshot profile"
        out := out.push (expected, parsed)
  if out.isEmpty then
    return .error s!"no snapshots in {dir}"
  return .ok (out.qsort (fun a b => a.1 < b.1))

def writeSnapshotsToDir (dir : System.FilePath) (snapshots : Array JVal) : IO (Except String Nat) := do
  if snapshots.isEmpty then
    return .error "no successful exportable discoveries; no files changed"
  let mut validated : Array (String × JVal) := #[]
  for s in snapshots do
    match validateSnapshotJson s with
    | .error e => return .error e
    | .ok (prov, prof, _, _) =>
      validated := validated.push (snapshotFilename prov prof, s)
  IO.FS.createDirAll dir
  let pid ← getpid
  let mut seq : Nat := 0
  for (fname, snap) in validated do
    seq := seq + 1
    let tmp := dir / s!".{fname}.{pid}.{seq}.tmp"
    let dest := dir / fname
    IO.FS.writeFile tmp ((renderPretty snap) ++ "\n")
    IO.FS.rename tmp dest
  return .ok validated.size

def mergeSnapshotJson (existing incoming : JVal) : Except String JVal := do
  let (eProv, eProf, _, eModels) ← validateSnapshotJson existing
  let (iProv, iProf, iComp, iModels) ← validateSnapshotJson incoming
  if eProv != iProv || eProf != iProf then
    throw "snapshot profile mismatch"
  if iComp != "partial" then
    return incoming
  let mut byId : Array (String × JVal) := #[]
  for m in eModels do
    let mid := (m.fieldStr? "id").getD ""
    byId := byId.push (mid, m)
  for m in iModels do
    let mid := (m.fieldStr? "id").getD ""
    match byId.findIdx? (fun (k, _) => k == mid) with
    | some idx => byId := byId.set! idx (mid, m)
    | none => byId := byId.push (mid, m)
  let sortedModels := (byId.qsort (fun a b => a.1 < b.1)).map Prod.snd
  let merged := incoming.setField "models" (.arr sortedModels)
  let _ ← validateSnapshotJson merged
  return merged

def snapshotDiffJson (oldSnap newSnap : JVal) : JVal := Id.run do
  let newProv := (newSnap.fieldStr? "provider_id").getD ""
  let newProf := (newSnap.fieldStr? "access_profile").getD ""
  let newComp := (newSnap.fieldStr? "completeness").getD "partial"
  let oldModels := (oldSnap.fieldArr? "models").getD #[]
  let newModels := (newSnap.fieldArr? "models").getD #[]
  let mut added : Array JVal := #[]
  let mut absent : Array JVal := #[]
  let mut changed : Array JVal := #[]
  let sortedNew := newModels.qsort (fun a b => ((a.fieldStr? "id").getD "") < ((b.fieldStr? "id").getD ""))
  let sortedOld := oldModels.qsort (fun a b => ((a.fieldStr? "id").getD "") < ((b.fieldStr? "id").getD ""))
  for nm in sortedNew do
    let nid := (nm.fieldStr? "id").getD ""
    match sortedOld.find? (fun om => (om.fieldStr? "id").getD "" == nid) with
    | none => added := added.push (.str nid)
    | some om =>
      let oldName := (om.fieldStr? "name").getD ""
      let newName := (nm.fieldStr? "name").getD ""
      let oldDesc := om.fieldStr? "description"
      let newDesc := nm.fieldStr? "description"
      if oldName != newName || oldDesc != newDesc then
        changed := changed.push (.str nid)
  for om in sortedOld do
    let oid := (om.fieldStr? "id").getD ""
    if !sortedNew.any (fun nm => (nm.fieldStr? "id").getD "" == oid) then
      absent := absent.push (.str oid)
  return .obj #[
    ("provider_id", .str newProv),
    ("access_profile", .str newProf),
    ("completeness", .str newComp),
    ("added", .arr added),
    ("absent", .arr absent),
    ("removals_authoritative", .bool (newComp == "complete")),
    ("changed", .arr changed)
  ]

private def resolveDir (root : System.FilePath) (raw : String) : System.FilePath :=
  let p := System.FilePath.mk raw
  if p.isAbsolute then p else root / p

def runModelsCmd (root : System.FilePath) (args : List String) : IO (Except String Unit) := do
  match args with
  | "discover" :: rest =>
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api or SANDBOXED_API_URL"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let base := stripTrailingSlash api
    match (← sendJsonRequest "POST" (base ++ "/api/providers/catalog/refresh") tok? none #[] 300000) with
    | .ok (st, _, _) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
    match (← sendJsonRequest "GET" (base ++ "/api/providers/discovery") tok? none #[] 300000) with
    | .ok (st, _, some j) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
      IO.println (renderPretty j)
      return .ok ()
    | .ok (st, _, none) => return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
  | "export" :: rest =>
    if let some src := valueAfterFlag? rest "--source" then
      if src != "last-success" then
        return .error "only --source last-success is supported"
    let some outRaw := valueAfterFlag? rest "--output"
      | return .error "missing --output DIR"
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api or SANDBOXED_API_URL"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let base := stripTrailingSlash api
    match (← sendJsonRequest "GET" (base ++ "/api/providers/snapshots") tok? none #[] 300000) with
    | .ok (st, _, some (.arr snaps)) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
      let outDir := resolveDir root outRaw
      match (← writeSnapshotsToDir outDir snaps) with
      | .error e => return .error e
      | .ok cnt =>
        IO.println <| renderCompact <| JVal.obj #[("written", .nat cnt), ("directory", .str outRaw)]
        return .ok ()
    | .ok (st, _, _) => return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
  | "validate" :: rest =>
    let some dirArg := rest.find? (fun s => !s.startsWith "--")
      | return .error "models validate DIR"
    match (← loadSnapshotDir (resolveDir root dirArg)) with
    | .error e => return .error e
    | .ok snaps =>
      IO.println <| renderCompact <| JVal.obj #[("valid", .bool true), ("snapshots", .nat snaps.size)]
      return .ok ()
  | "diff" :: rest =>
    let baseRaw := (valueAfterFlag? rest "--snapshot-dir").getD "catalog/snapshots"
    let incoming? := (valueAfterFlag? rest "--from").orElse (fun _ => rest.find? (fun s => !s.startsWith "--"))
    let some incRaw := incoming?
      | return .error "models diff --snapshot-dir DIR --from DIR"
    let oldSnaps ← match (← loadSnapshotDir (resolveDir root baseRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let newSnaps ← match (← loadSnapshotDir (resolveDir root incRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let changes := newSnaps.map fun (fname, newS) =>
      match oldSnaps.find? (fun (k, _) => k == fname) with
      | some (_, oldS) => snapshotDiffJson oldS newS
      | none =>
        let mCount := ((newS.fieldArr? "models").getD #[]).size
        JVal.obj #[("file", .str fname), ("new_profile", .bool true), ("models", .nat mCount)]
    IO.println <| renderPretty <| JVal.obj #[
      ("changes", .arr changes),
      ("missing_profiles_are_preserved", .bool true)
    ]
    return .ok ()
  | "snapshot" :: "update" :: rest =>
    let some fromRaw := valueAfterFlag? rest "--from"
      | return .error "missing --from DIR"
    let destRaw := (valueAfterFlag? rest "--snapshot-dir").getD "catalog/snapshots"
    let oldSnaps ← match (← loadSnapshotDir (resolveDir root destRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let newSnaps ← match (← loadSnapshotDir (resolveDir root fromRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let mut prepared : Array JVal := #[]
    for (fname, inc) in newSnaps do
      match oldSnaps.find? (fun (k, _) => k == fname) with
      | some (_, prev) =>
        match mergeSnapshotJson prev inc with
        | .ok m => prepared := prepared.push m
        | .error e => return .error e
      | none => prepared := prepared.push inc
    match (← writeSnapshotsToDir (resolveDir root destRaw) prepared) with
    | .error e => return .error e
    | .ok cnt =>
      IO.println <| renderCompact <| JVal.obj #[("updated", .nat cnt), ("directory", .str destRaw)]
      return .ok ()
  | _ =>
    return .error "models: discover --connected [--api URL] | export --source last-success --output DIR | validate DIR | diff --snapshot-dir DIR --from DIR | snapshot update --from DIR [--snapshot-dir DIR]"

/-! ### `status`, `reconcile`, `set-mode`, `dispatch-plan`, `import-trackers`, `repair-borrowed-tracks` -/

def loadFixtureMissions (root : System.FilePath) : IO (Array JVal) := do
  let p := root / ".paloma" / "fixtures" / "missions.json"
  if !(← p.pathExists) then return #[]
  let raw ← IO.FS.readFile p
  match Json.parse raw with
  | .ok (.arr xs) => return xs
  | .ok v => return (v.fieldArr? "missions").getD #[]
  | .error _ => return #[]

def buildLocalState (root : System.FilePath) : IO JVal := do
  let missions ← loadFixtureMissions root
  let mut counts : Array (String × Nat) := #[]
  for m in missions do
    let st := (m.fieldStr? "status").getD "unknown"
    match counts.findIdx? (fun (k, _) => k == st) with
    | some idx =>
      let (k, n) := counts[idx]!
      counts := counts.set! idx (k, n + 1)
    | none => counts := counts.push (st, 1)
  let sortedCounts := counts.qsort (fun a b => a.1 < b.1)
  let ts ← nowEpoch
  return .obj #[
    ("generated_at", .str s!"{ts}"),
    ("project_docs", .arr #[]),
    ("mission_counts", .obj (sortedCounts.map fun (k, n) => (k, .nat n))),
    ("missions", .arr missions),
    ("drift", .arr #[])
  ]

def renderStatusText (state : JVal) : String := Id.run do
  let docs := ((state.fieldArr? "project_docs").getD #[]).size
  let missions := ((state.fieldArr? "missions").getD #[]).size
  let drift := (state.fieldArr? "drift").getD #[]
  let mut out := s!"paloma control-plane status\nproject_docs={docs}\nmissions={missions}\n"
  if let some mc := (state.field? "mission_counts") >>= JVal.asObj? then
    for (st, cnt) in mc do
      out := out ++ s!"mission_status.{st}={(cnt.asNat?).getD 0}\n"
  out := out ++ s!"drift={drift.size}\n"
  return out

def renderStatusMd (state : JVal) : String := Id.run do
  let gen := (state.fieldStr? "generated_at").getD "0"
  let mut out := s!"# Paloma Status\n\nGenerated: `{gen}`\n\n## Mission Counts\n\n"
  let mc := ((state.field? "mission_counts") >>= JVal.asObj?).getD #[]
  if mc.isEmpty then
    out := out ++ "- none\n"
  else
    for (st, cnt) in mc do
      out := out ++ s!"- `{st}`: {(cnt.asNat?).getD 0}\n"
  out := out ++ "\n## Drift\n\n- none\n"
  return out

/-! ### `import-trackers`, `set-mode`, and `dispatch-plan` Helpers -/

private def positionalSlugs (rest : List String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut skip := false
  for arg in rest do
    if skip then
      skip := false
    else if arg == "--api" || arg == "--token" || arg == "--dir" then
      skip := true
    else if !arg.startsWith "--" then
      out := out.push arg
  return out

private def resolveTrackersDir (root : System.FilePath) (rest : List String) : IO (Except String System.FilePath) := do
  let dirRaw? ← match valueAfterFlag? rest "--dir" with
    | some d => pure (some d)
    | none => getEnvNonEmpty "HERMES_PROJECTS_DIR"
  let some dirRaw := dirRaw?
    | return .error "missing --dir <trackers> (or HERMES_PROJECTS_DIR)"
  let dir := resolveDir root dirRaw
  if !(← dir.isDir) then
    return .error s!"tracker directory {dir} is not a directory"
  return .ok dir

private def listTrackerFiles (dir : System.FilePath) (only : Array String) : IO (Except String (Array (String × System.FilePath))) := do
  let entries ← try dir.readDir catch e => return .error s!"read {dir}: {e}"
  let mut files : Array (String × System.FilePath) := #[]
  for entry in entries do
    let p := entry.path
    if p.extension == some "md" then
      if let some stem := p.fileStem then
        if (validateProjectSlug stem).isOk then
          if only.isEmpty || only.contains stem then
            files := files.push (stem, p)
  return .ok (files.qsort (fun a b => a.1 < b.1))

def runImportTrackers (root : System.FilePath) (rest : List String) : IO (Except String Unit) := do
  let api? ← match valueAfterFlag? rest "--api" with
    | some u => pure (some u)
    | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
  let some api := api? | return .error "missing --api <url> (or SANDBOXED_API_URL)"
  let tok? ← match valueAfterFlag? rest "--token" with
    | some t => pure (some t)
    | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
  let dir ← match (← resolveTrackersDir root rest) with
    | .ok d => pure d
    | .error e => return .error e
  let dryRun := rest.contains "--dry-run"
  let only := positionalSlugs rest
  let files ← match (← listTrackerFiles dir only) with
    | .ok f => pure f
    | .error e => return .error e
  let mut reports : Array JVal := #[]
  let base := stripTrailingSlash api
  for (slug, path) in files do
    let content ← try IO.FS.readFile path catch e => return .error s!"read {path}: {e}"
    let payload := JVal.obj #[
      ("source_path", .str path.toString),
      ("content", .str content),
      ("dry_run", .bool dryRun),
      ("actor", .str "palomactl")
    ]
    match (← sendJsonRequest "POST" s!"{base}/api/projects/{slug}/imports" tok? (some payload) #[] 60000) with
    | .error e => return .error e
    | .ok (200, _, body?) =>
      let b := body?.getD (.obj #[])
      let itemsCount : JVal := match b.fieldArr? "items" with
        | some xs => .nat xs.size
        | none => .null
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("created", (b.field? "created").getD .null),
        ("claims", (b.field? "claims").getD .null),
        ("already_imported", (b.field? "already_imported").getD .null),
        ("ambiguities", (b.field? "ambiguities").getD .null),
        ("receipt_id", (b.field? "receipt_id").getD .null),
        ("items", itemsCount)
      ]
    | .ok (404, _, _) =>
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("skipped", .str "not a roster project")
      ]
    | .ok (other, rawBody, _) =>
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("error", .str s!"HTTP {other}: {rawBody}")
      ]
  IO.println <| renderPretty <| JVal.obj #[
    ("dry_run", .bool dryRun),
    ("reports", .arr reports)
  ]
  return .ok ()

private def explorationLimitForMode (mode : String) : Option Nat :=
  match mode with
  | "conservative" => some 0
  | "normal" => some 1
  | "aggressive" => some 3
  | "very_aggressive" => some 5
  | _ => none

private def isLeapYear (y : Nat) : Bool :=
  (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

private def daysInMonth (y m : Nat) : Nat :=
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
  | 4 | 6 | 9 | 11 => 30
  | 2 => if isLeapYear y then 29 else 28
  | _ => 0

/-- Parse an RFC3339 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`) into UTC epoch seconds. -/
def parseRfc3339Epoch? (raw : String) : Option Int := do
  let s := raw.trimAscii.toString
  let (datePart, rest0) ← match s.splitOn "T" with
    | [d, t] => some (d, t)
    | _ => match s.splitOn "t" with
      | [d, t] => some (d, t)
      | _ => none
  let [yStr, mStr, dStr] := datePart.splitOn "-" | none
  if yStr.length != 4 || mStr.length != 2 || dStr.length != 2 then none
  let y ← yStr.toNat?
  let mo ← mStr.toNat?
  let da ← dStr.toNat?
  if y < 1970 || mo < 1 || mo > 12 || da < 1 || da > daysInMonth y mo then none
  let (timePart, tzOffsetSec) ←
    if rest0.endsWith "Z" || rest0.endsWith "z" then
      some ((rest0.dropEnd 1).toString, (0 : Int))
    else if rest0.length > 6 then
      let tzSignPos := rest0.length - 6
      let pfx := (rest0.take tzSignPos).toString
      let sfx := (rest0.drop tzSignPos).toString
      let signChar := sfx.toList.headD ' '
      if signChar != '+' && signChar != '-' then none
      else
        match (sfx.drop 1).toString.splitOn ":" with
        | [ohS, omS] =>
          if ohS.length != 2 || omS.length != 2 then none
          else
            let oh ← ohS.toNat?
            let om ← omS.toNat?
            if oh > 23 || om > 59 then none
            else
              let mag : Int := Int.ofNat (oh * 3600 + om * 60)
              some (pfx, if signChar == '+' then mag else -mag)
        | _ => none
    else none
  let baseTime := match timePart.splitOn "." with
    | h :: _ => h
    | [] => timePart
  let [hhS, mmS, ssS] := baseTime.splitOn ":" | none
  if hhS.length != 2 || mmS.length != 2 || ssS.length != 2 then none
  let hh ← hhS.toNat?
  let mm ← mmS.toNat?
  let ss ← ssS.toNat?
  if hh > 23 || mm > 59 || ss > 60 then none
  let mut days : Nat := 0
  for yr in [1970:y] do
    days := days + (if isLeapYear yr then 366 else 365)
  for mn in [1:mo] do
    days := days + daysInMonth y mn
  days := days + (da - 1)
  let utcSec : Int := Int.ofNat (days * 86400 + hh * 3600 + mm * 60 + ss) - tzOffsetSec
  return utcSec

private def loadProjectModePolicy (root : System.FilePath) (project : String) : IO (String × String × Nat) := do
  let modeFile := root / ".paloma" / "modes" / s!"{project}.json"
  let nowSec := Int.ofNat (← nowEpoch).toNat
  if (← modeFile.pathExists) then
    if let .ok j := Json.parse (← IO.FS.readFile modeFile) then
      let m := (j.fieldStr? "mode").getD "normal"
      let u := (j.fieldStr? "until").getD "unset"
      if let some expLimit := explorationLimitForMode m then
        if let some untilSec := parseRfc3339Epoch? u then
          if untilSec > nowSec then
            return (m, u, expLimit)
  return ("normal", "unset", 1)

private def loadFixtureTasks (root : System.FilePath) : IO (Except String (Array JVal)) := do
  let p := root / ".paloma" / "fixtures" / "tasks.json"
  if !(← p.pathExists) then return .ok #[]
  let raw ← IO.FS.readFile p
  match Json.parse raw with
  | .ok (.arr xs) => return .ok xs
  | .ok v => return .ok ((v.fieldArr? "tasks").getD #[])
  | .error e => return .error s!"parse {p}: {e}"

private def intentRequestsExploration (intent : String) : Bool := Id.run do
  let toks := (intent.splitToList (fun c => !c.isAlphanum)).filter (!·.isEmpty)
  let keywords := #["proof", "prove", "explore", "explores", "explored", "exploring", "exploration", "exploratory"]
  for tok in toks do
    if keywords.contains tok.toLower then
      return true
  return false

private def isExplorationTask (t : JVal) : Bool :=
  (t.fieldStr? "lane").getD "" == "exploration" ||
  match t.fieldStr? "intent" with
  | some intent => intentRequestsExploration intent
  | none => false

private def taskFixtureId (t : JVal) : String :=
  (t.fieldStr? "id").orElse (fun _ => t.fieldStr? "task_key") |>.getD ""

def buildDispatchPlanJson (root : System.FilePath) (project : String) : IO (Except String JVal) := do
  let (modeName, _, expLimit) ← loadProjectModePolicy root project
  let tasks ← match (← loadFixtureTasks root) with
    | .ok ts => pure ts
    | .error e => return .error e
  let ready := tasks.filter fun t =>
    let proj := (t.fieldStr? "project").getD ""
    let st := (t.fieldStr? "status").getD ""
    proj == project && (st == "ready" || st == "pending")
  if ready.isEmpty then
    return .ok <| JVal.obj #[
      ("project", .str project),
      ("mode", .str modeName),
      ("safe_lane_max_workers", .nat 1),
      ("exploration_lane_max_workers", .nat expLimit),
      ("dispatch", .arr #[]),
      ("reason", .str "no_ready_tasks")
    ]
  let mut safe : Array JVal := #[]
  let mut exploration : Array JVal := #[]
  for t in ready do
    if isExplorationTask t then exploration := exploration.push t
    else safe := safe.push t
  let sortedSafe := safe.qsort (fun a b => taskFixtureId a < taskFixtureId b)
  let sortedExp := exploration.qsort (fun a b => taskFixtureId a < taskFixtureId b)
  let mut dispatch : Array JVal := #[]
  if sortedSafe.size > 0 then
    dispatch := dispatch.push <| JVal.obj #[
      ("task_id", .str (taskFixtureId sortedSafe[0]!)),
      ("lane", .str "safe"),
      ("max_workers", .nat 1),
      ("gate_protected", .bool true)
    ]
  let expTake := Nat.min expLimit sortedExp.size
  for i in [0:expTake] do
    dispatch := dispatch.push <| JVal.obj #[
      ("task_id", .str (taskFixtureId sortedExp[i]!)),
      ("lane", .str "exploration"),
      ("max_workers", .nat 1),
      ("isolated_branch", .bool true)
    ]
  let reasonVal : JVal := if dispatch.isEmpty then .str "no_schedulable_tasks" else .null
  return .ok <| JVal.obj #[
    ("project", .str project),
    ("mode", .str modeName),
    ("safe_lane_max_workers", .nat 1),
    ("exploration_lane_max_workers", .nat expLimit),
    ("dispatch", .arr dispatch),
    ("reason", reasonVal)
  ]

def runPalomaCtl (args : List String) : IO (Except String Unit) := do
  let rootEnv ← getEnvNonEmpty "PALOMACTL_ROOT"
  let cwd ← IO.currentDir
  let root := (rootEnv.map System.FilePath.mk).getD cwd
  match args with
  | [] | ["-h"] | ["--help"] | ["help"] =>
    printUsage
    return .ok ()
  | ["--version"] | ["-V"] =>
    IO.println "palomactl 1.3.0 (Lean 4)"
    return .ok ()
  | "models" :: rest =>
    runModelsCmd root rest
  | "status" :: _ =>
    let st ← buildLocalState root
    IO.print (renderStatusText st)
    return .ok ()
  | "reconcile" :: rest =>
    if let some api := valueAfterFlag? rest "--api" then
      let tok? ← match valueAfterFlag? rest "--token" with
        | some t => pure (some t)
        | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
      let url := stripTrailingSlash api ++ "/api/control/situation"
      match (← sendJsonRequest "GET" url tok?) with
      | .ok (200, _, some j) =>
        IO.println (renderPretty j)
        return .ok ()
      | .ok (st, body, _) => return .error s!"HTTP {st}: {body}"
      | .error e => return .error e
    else
      let st ← buildLocalState root
      let cdir := root / ".paloma"
      IO.FS.createDirAll cdir
      let sj := cdir / "status.json"
      let sm := cdir / "status.md"
      IO.FS.writeFile sj ((renderPretty st) ++ "\n")
      IO.FS.writeFile sm (renderStatusMd st)
      let driftLen := ((st.fieldArr? "drift").getD #[]).size
      IO.println s!"wrote {sj}\nwrote {sm}\ndrift={driftLen}"
      return .ok ()
  | "import-trackers" :: rest =>
    runImportTrackers root rest
  | "pr-gates" :: repo :: numStr :: rest =>
    let some num := numStr.toNat? | return .error "PR number must be numeric"
    let workerHead? := valueAfterFlag? rest "--worker-head"
    let rawGates ← match (← loadPrGates root repo num) with
      | .ok g => pure g
      | .error e => return .error e
    let annotated := evaluateAndAnnotatePrGates rawGates repo num workerHead?
    IO.println (renderPretty annotated)
    if let some recStr := annotated.fieldStr? "recommendation" then
      IO.println s!"recommendation={recStr}"
    return .ok ()
  | "pr-gates" :: _ =>
    return .error "usage: palomactl pr-gates <owner/repo> <number> [--worker-head <sha>]"
  | "set-mode" :: project :: mode :: rest =>
    if let .error e := validateProjectSlug project then return .error e
    let some untilIso := valueAfterFlag? rest "--until" | return .error "missing --until <iso>"
    let some untilSec := parseRfc3339Epoch? untilIso
      | return .error "--until must be RFC3339/ISO timestamp"
    let nowSec := Int.ofNat (← nowEpoch).toNat
    if untilSec <= nowSec then
      return .error "--until must be in the future"
    let some expLimit := explorationLimitForMode mode
      | return .error "mode must be conservative|normal|aggressive|very_aggressive"
    let mdir := root / ".paloma" / "modes"
    IO.FS.createDirAll mdir
    let policy := JVal.obj #[
      ("project", .str project),
      ("mode", .str mode),
      ("until", .str untilIso),
      ("safe_lane_max_workers", .nat 1),
      ("exploration_lane_max_workers", .nat expLimit)
    ]
    IO.FS.writeFile (mdir / s!"{project}.json") ((renderPretty policy) ++ "\n")
    IO.println (renderPretty policy)
    return .ok ()
  | "set-mode" :: _ =>
    return .error "usage: palomactl set-mode <project> <mode> --until <iso>"
  | "dispatch-plan" :: rest =>
    let some project := valueAfterFlag? rest "--project" | return .error "missing --project <slug>"
    if let .error e := validateProjectSlug project then return .error e
    match (← buildDispatchPlanJson root project) with
    | .ok plan =>
      IO.println (renderPretty plan)
      return .ok ()
    | .error e => return .error e
  | "repair-borrowed-tracks" :: rest =>
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api <url> (or SANDBOXED_API_URL)"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let apply := rest.contains "--apply"
    let dryStr := if apply then "false" else "true"
    let url := stripTrailingSlash api ++
      s!"/api/control/repair/borrowed-tracks?dry_run={dryStr}"
    match (← sendJsonRequest "POST" url tok?) with
    | .ok (200, _, some j) =>
      IO.println (renderPretty j)
      return .ok ()
    | .ok (st, body, _) => return .error s!"HTTP {st}: {body}"
    | .error e => return .error e
  | "validation-matrix" :: rest =>
    let mPath := match rest.head? with
      | some p => System.FilePath.mk p
      | none => root / ".sandboxed" / "validation.toml"
    let raw ← try IO.FS.readFile mPath catch e => return .error s!"read validation matrix {mPath}: {e}"
    match parseValidationMatrixText raw >>= validateMatrixJson with
    | .ok m =>
      IO.println (renderPretty m)
      return .ok ()
    | .error e => return .error e
  | "cluster-lean-errors" :: path :: _ =>
    let raw ← try IO.FS.readFile path catch e => return .error s!"read {path}: {e}"
    IO.println (renderPretty (clusterDiagnostics raw))
    return .ok ()
  | "cluster-lean-errors" :: [] =>
    return .error "missing log path"
  | unknown :: _ =>
    printUsage
    return .error s!"unknown command {unknown}"

def runMain (args : List String) : IO UInt32 := do
  match (← runPalomaCtl args) with
  | .ok () => return 0
  | .error err =>
    IO.eprintln s!"palomactl: {err}"
    return 1

end OrbBin.PalomaCtl
