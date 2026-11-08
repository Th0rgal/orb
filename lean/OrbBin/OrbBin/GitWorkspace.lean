/-
  OrbBin.GitWorkspace: Zero-Index-Contention Hidden Git Checkpoints (`refs/orb/checkpoints/...`),
  Authored-Path Diff Filtering (`Orb.Kernel.repoDiffBudgetStep`), Atomic Checkpoint Restore,
  and Sibling Git Worktree Lifecycle (`Orb.Kernel.worktreeDecisionStep`) (`0 import Lean`, `0 sorryAx`).
-/
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt

namespace OrbBin.GitWorkspace

open Orb.Kernel
open OrbBin.Json
open OrbBin.PosixExt

/-- Default diff byte budget (512 KiB) passed to `Orb.Kernel.repoDiffBudgetStep`. -/
def defaultDiffMaxBytes : UInt32 := 524288

/-- Default diff changed-file cap (200 files) passed to `Orb.Kernel.repoDiffBudgetStep`. -/
def defaultDiffMaxFiles : UInt16 := 200

/-- Metadata for one hidden Orb git checkpoint ref (`refs/orb/checkpoints/<mission>/<turn>`). -/
structure CheckpointMeta where
  ref        : String
  commitSha  : String
  treeSha    : String
  headSha    : String
  branch     : String
  turnIndex  : Nat
  turnId     : String
  label      : String
  createdAt  : UInt64
  deriving Repr, BEq, Inhabited

/-- Summary + unified diff patch for a single file between two trees or working directory. -/
structure DiffFileEntry where
  path       : String
  oldPath?   : Option String := none
  status     : String -- "M" | "A" | "D" | "R"
  additions  : Nat := 0
  deletions  : Nat := 0
  binary     : Bool := false
  patch      : String := ""
  truncated  : Bool := false
  deriving Repr, BEq, Inhabited

/-- Aggregated repository or checkpoint diff payload gated by `Orb.Kernel.repoDiffBudgetStep`. -/
structure CheckpointDiffReport where
  repoRoot      : String
  branch        : String
  fromRef       : String
  toRef         : String
  files         : Array DiffFileEntry
  totalAdded    : Nat := 0
  totalDeleted  : Nat := 0
  truncated     : Bool := false
  summaryOnly   : Bool := false
  verdictCode   : UInt32 := 256
  deriving Repr, BEq, Inhabited

/-- Repository occupancy and `Orb.Kernel.worktreeDecisionStep` verdict for mission launch. -/
structure WorktreeStatus where
  isGitRepo        : Bool
  repoRoot         : String := ""
  branch           : String := ""
  isDirty          : Bool := false
  isWorktree       : Bool := false
  occupiedByOther  : Bool := false
  decisionWord     : UInt32 := 0
  createWorktree   : Bool := false
  recommendedMode  : String := "local" -- "local" | "worktree"
  suggestedBranch  : String := ""
  suggestedPath    : String := ""
  deriving Repr, BEq, Inhabited

/-- Result of creating an isolated sibling git worktree for a mission. -/
structure CreatedWorktree where
  repoRoot      : String
  worktreePath  : String
  branch        : String
  baseRef       : String
  reused        : Bool := false
  deriving Repr, BEq, Inhabited

/-- Sanitize an arbitrary identifier into a safe git ref / directory path component (`[A-Za-z0-9_-]`). -/
def sanitizeGitToken (raw : String) (fallback : String := "default") (maxLen : Nat := 64) : String := Id.run do
  let mut chars : Array Char := #[]
  for c in raw.trimAscii.toString.toList do
    if chars.size < maxLen then
      if c.isAlphanum || c == '-' || c == '_' then
        chars := chars.push c
      else if c == ':' || c == '.' || c == ' ' || c == '/' then
        if chars.back? != some '-' then
          chars := chars.push '-'
  let cleaned := (String.ofList chars.toList).dropWhile (· == '-') |>.dropEndWhile (· == '-') |>.toString
  return if cleaned.isEmpty then fallback else cleaned

/-- Construct the canonical hidden checkpoint ref for `(missionId, turnIndex, turnId)`. -/
def checkpointRefName (missionId : String) (turnIndex : Nat) (turnId : String) : String :=
  let safeMid := sanitizeGitToken missionId "mission" 64
  let safeTurn := sanitizeGitToken turnId s!"t{turnIndex}" 40
  let padded :=
    let s := s!"{turnIndex}"
    if s.length >= 4 then s else String.ofList (List.replicate (4 - s.length) '0') ++ s
  s!"refs/orb/checkpoints/{safeMid}/{padded}-{safeTurn}"

/-- Verify that a candidate ref string is strictly confined under `refs/orb/checkpoints/` with no traversal. -/
def isValidCheckpointRef (refName : String) : Bool :=
  let t := refName.trimAscii.toString
  t.startsWith "refs/orb/checkpoints/" &&
  t.length > "refs/orb/checkpoints/".length &&
  !(t.splitOn "..").tail!.isEmpty == false &&
  !t.endsWith "/" &&
  !t.endsWith ".lock" &&
  !(t.splitOn "//").tail!.isEmpty == false &&
  t.toList.all (fun c => c.isAlphanum || c == '/' || c == '-' || c == '_' || c == '.')

private def hasNoDoubleDotOrSlash (t : String) : Bool :=
  (t.splitOn "..").length == 1 && (t.splitOn "//").length == 1

/-- Confined check for Orb hidden checkpoint refs. -/
def checkSafeCheckpointRef (refName : String) : Bool :=
  let t := refName.trimAscii.toString
  t.startsWith "refs/orb/checkpoints/" &&
  t.length > 22 &&
  hasNoDoubleDotOrSlash t &&
  !t.endsWith "/" &&
  !t.endsWith ".lock" &&
  t.toList.all (fun c => c.isAlphanum || c == '/' || c == '-' || c == '_' || c == '.')

/-- Confined check for Orb hidden checkpoint refs scoped strictly to `missionId`. -/
def checkSafeMissionCheckpointRef (missionId : String) (refName : String) : Bool :=
  let safeMid := sanitizeGitToken missionId "mission" 64
  let prefixRef := s!"refs/orb/checkpoints/{safeMid}/"
  let t := refName.trimAscii.toString
  checkSafeCheckpointRef t && t.startsWith prefixRef && t.length > prefixRef.length

/-- Validate a user-supplied git branch or ref spec (blocks leading `-` option injection, `..`, `//`, `.lock`, whitespace, and git ref control characters). -/
def checkSafeBranchOrRef (raw : String) : Bool :=
  let t := raw.trimAscii.toString
  !t.isEmpty &&
  t.length ≤ 128 &&
  !t.startsWith "-" &&
  !t.startsWith "/" &&
  !t.endsWith "/" &&
  !t.endsWith "." &&
  !t.endsWith ".lock" &&
  hasNoDoubleDotOrSlash t &&
  (t.splitOn "@{").length == 1 &&
  t.toList.all (fun c =>
    c.toNat > 0x20 && c.toNat < 0x7F &&
    c != '~' && c != '^' && c != ':' && c != '?' && c != '*' && c != '[' && c != '\\')

private def runGit
    (cwd : String)
    (args : Array String)
    (extraEnv : Array (String × Option String) := #[]) : IO (Except String IO.Process.Output) := do
  let baseEnv := #[
    ("GIT_TERMINAL_PROMPT", some "0"),
    ("GIT_OPTIONAL_LOCKS", some "0"),
    ("LC_ALL", some "C")
  ] ++ extraEnv
  match ← (IO.Process.output {
    cmd := "git"
    args := #["-C", cwd] ++ args
    env := baseEnv
  }).toBaseIO with
  | .error e => return .error s!"git exec failed: {e}"
  | .ok out => return .ok out

/-- Resolve the canonical top-level git worktree root for `cwd`, or `none` if `cwd` is not in a git repository. -/
def resolveGitTopLevel? (cwd : String) : IO (Option String) := do
  if !(← System.FilePath.pathExists cwd) then
    return none
  match ← runGit cwd #["rev-parse", "--show-toplevel"] with
  | .error _ => return none
  | .ok out =>
    if out.exitCode != 0 then return none
    let p := out.stdout.trimAscii.toString
    if p.isEmpty then return none
    try
      let rp ← IO.FS.realPath (System.FilePath.mk p)
      return some rp.toString
    catch _ =>
      return some p

/-- Resolve current branch name (or `"HEAD"` if detached / `"main"` if unborn). -/
def currentGitBranch (repoRoot : String) : IO String := do
  match ← runGit repoRoot #["symbolic-ref", "--quiet", "--short", "HEAD"] with
  | .ok out =>
    let b := out.stdout.trimAscii.toString
    if out.exitCode == 0 && !b.isEmpty then return b
    else return "HEAD"
  | .error _ => return "HEAD"

/-- Resolve current `HEAD` commit SHA, or `""` on an unborn branch. -/
def currentHeadSha (repoRoot : String) : IO String := do
  match ← runGit repoRoot #["rev-parse", "--verify", "--quiet", "HEAD"] with
  | .ok out =>
    let s := out.stdout.trimAscii.toString
    if out.exitCode == 0 && !s.isEmpty then return s else return ""
  | .error _ => return ""

/-- Encode structured checkpoint commit message metadata. -/
private def encodeCheckpointMessage (turnIndex : Nat) (turnId label headSha branch : String) (createdAt : UInt64) : String :=
  renderCompact (.obj #[
    ("orb_checkpoint", .nat 1),
    ("turn_index", .nat turnIndex),
    ("turn_id", .str turnId),
    ("label", .str label),
    ("head_sha", .str headSha),
    ("branch", .str branch),
    ("created_at", .nat createdAt.toNat)
  ])

/-- Parse structured checkpoint commit message metadata. -/
private def decodeCheckpointMeta (ref commitSha treeSha rawBody : String) : CheckpointMeta :=
  match OrbBin.Json.parse rawBody.trimAscii.toString with
  | .ok jv =>
    { ref := ref
      commitSha := commitSha
      treeSha := treeSha
      headSha := (jv.fieldStr? "head_sha").getD ""
      branch := (jv.fieldStr? "branch").getD ""
      turnIndex := (jv.fieldNat? "turn_index").getD 0
      turnId := (jv.fieldStr? "turn_id").getD ""
      label := (jv.fieldStr? "label").getD ""
      createdAt := ((jv.fieldNat? "created_at").getD 0).toUInt64 }
  | .error _ =>
    { ref := ref
      commitSha := commitSha
      treeSha := treeSha
      headSha := ""
      branch := ""
      turnIndex := 0
      turnId := ""
      label := rawBody.trimAscii.toString
      createdAt := 0 }

/-- Serialize `CheckpointMeta` to JSON (emitting canonical and cross-client alias keys). -/
def CheckpointMeta.toJVal (m : CheckpointMeta) : JVal :=
  .obj #[
    ("ref", .str m.ref),
    ("commit_sha", .str m.commitSha),
    ("commit", .str m.commitSha),
    ("oid", .str m.commitSha),
    ("tree_sha", .str m.treeSha),
    ("head_sha", .str m.headSha),
    ("head_commit", .str m.headSha),
    ("branch", .str m.branch),
    ("turn_index", .nat m.turnIndex),
    ("turn", .nat m.turnIndex),
    ("turn_id", .str m.turnId),
    ("label", .str m.label),
    ("created_at", .nat m.createdAt.toNat)
  ]

/-- Serialize `DiffFileEntry` to JSON. -/
def DiffFileEntry.toJVal (f : DiffFileEntry) : JVal :=
  let base : Array (String × JVal) := #[
    ("path", .str f.path),
    ("status", .str f.status),
    ("additions", .nat f.additions),
    ("deletions", .nat f.deletions),
    ("binary", .bool f.binary),
    ("patch", .str f.patch),
    ("truncated", .bool f.truncated)
  ]
  let withOld := match f.oldPath? with
    | some op => base.push ("old_path", .str op)
    | none => base
  .obj withOld

/-- Serialize `CheckpointDiffReport` to JSON. -/
def CheckpointDiffReport.toJVal (r : CheckpointDiffReport) : JVal :=
  let rawDiff := String.intercalate "\n" ((r.files.toList.map (·.patch)).filter (!·.isEmpty))
  .obj #[
    ("repo_root", .str r.repoRoot),
    ("branch", .str r.branch),
    ("from_ref", .str r.fromRef),
    ("to_ref", .str r.toRef),
    ("files", .arr (r.files.map DiffFileEntry.toJVal)),
    ("raw_diff", .str rawDiff),
    ("total_additions", .nat r.totalAdded),
    ("total_deletions", .nat r.totalDeleted),
    ("truncated", .bool r.truncated),
    ("budget_exceeded", .bool r.truncated),
    ("summary_only", .bool r.summaryOnly),
    ("verdict_code", .nat r.verdictCode.toNat)
  ]

/-- Serialize `WorktreeStatus` to JSON. -/
def WorktreeStatus.toJVal (w : WorktreeStatus) : JVal :=
  .obj #[
    ("is_git_repo", .bool w.isGitRepo),
    ("repo_root", .str w.repoRoot),
    ("branch", .str w.branch),
    ("current_branch", .str w.branch),
    ("is_dirty", .bool w.isDirty),
    ("is_worktree", .bool w.isWorktree),
    ("occupied_by_other", .bool w.occupiedByOther),
    ("repo_busy", .bool w.occupiedByOther),
    ("decision_word", .nat w.decisionWord.toNat),
    ("create_worktree", .bool w.createWorktree),
    ("recommended_mode", .str w.recommendedMode),
    ("suggested_branch", .str w.suggestedBranch),
    ("suggested_path", .str w.suggestedPath)
  ]

/-- Serialize `CreatedWorktree` to JSON. -/
def CreatedWorktree.toJVal (w : CreatedWorktree) : JVal :=
  .obj #[
    ("repo_root", .str w.repoRoot),
    ("worktree_path", .str w.worktreePath),
    ("branch", .str w.branch),
    ("base_ref", .str w.baseRef),
    ("reused", .bool w.reused)
  ]

/-- Capture a hidden git checkpoint (`refs/orb/checkpoints/<mission>/<turn>`) using a private temporary
    `GIT_INDEX_FILE` so concurrent user or agent git operations never experience `.git/index.lock` contention
    and the user's staged index is untouched. -/
def captureCheckpoint
    (cwd : String)
    (missionId : String)
    (turnIndex : Nat)
    (turnId : String)
    (label : String := "") : IO (Except String CheckpointMeta) := do
  let some repoRoot ← resolveGitTopLevel? cwd
    | return .error "not_a_git_repository"
  let uuid ← newUuidV4
  let tmpBase := ((← IO.getEnv "TMPDIR").getD "/tmp").trimAscii.toString
  let cleanTmp := if tmpBase.endsWith "/" then (tmpBase.dropEnd 1).toString else if tmpBase.isEmpty then "/tmp" else tmpBase
  let tmpIndex := s!"{cleanTmp}/orb-git-idx-{uuid}"
  let cleanup : IO Unit := do
    try IO.FS.removeFile tmpIndex catch _ => pure ()
    try IO.FS.removeFile (tmpIndex ++ ".lock") catch _ => pure ()
  try
    let headSha ← currentHeadSha repoRoot
    let branch ← currentGitBranch repoRoot
    let idxEnv : Array (String × Option String) := #[
      ("GIT_INDEX_FILE", some tmpIndex),
      ("GIT_AUTHOR_NAME", some "Orb Checkpoint"),
      ("GIT_AUTHOR_EMAIL", some "checkpoint@orb.local"),
      ("GIT_COMMITTER_NAME", some "Orb Checkpoint"),
      ("GIT_COMMITTER_EMAIL", some "checkpoint@orb.local")
    ]
    if !headSha.isEmpty then
      let _ ← runGit repoRoot #["read-tree", headSha] idxEnv
    match ← runGit repoRoot #["add", "-A", "--", "."] idxEnv with
    | .error e => cleanup; return .error e
    | .ok addOut =>
      if addOut.exitCode != 0 then
        cleanup
        return .error s!"git add -A failed: {addOut.stderr.trimAscii.toString}"
      match ← runGit repoRoot #["write-tree"] idxEnv with
      | .error e => cleanup; return .error e
      | .ok treeOut =>
        if treeOut.exitCode != 0 then
          cleanup
          return .error s!"git write-tree failed: {treeOut.stderr.trimAscii.toString}"
        let treeSha := treeOut.stdout.trimAscii.toString
        let nowSec ← nowEpoch
        let msg := encodeCheckpointMessage turnIndex turnId label headSha branch nowSec
        let commitArgs :=
          if headSha.isEmpty then #["commit-tree", treeSha, "-m", msg]
          else #["commit-tree", treeSha, "-p", headSha, "-m", msg]
        match ← runGit repoRoot commitArgs idxEnv with
        | .error e => cleanup; return .error e
        | .ok cmtOut =>
          if cmtOut.exitCode != 0 then
            cleanup
            return .error s!"git commit-tree failed: {cmtOut.stderr.trimAscii.toString}"
          let commitSha := cmtOut.stdout.trimAscii.toString
          let refName := checkpointRefName missionId turnIndex turnId
          match ← runGit repoRoot #["update-ref", refName, commitSha] with
          | .error e => cleanup; return .error e
          | .ok refOut =>
            cleanup
            if refOut.exitCode != 0 then
              return .error s!"git update-ref failed: {refOut.stderr.trimAscii.toString}"
            return .ok {
              ref := refName
              commitSha := commitSha
              treeSha := treeSha
              headSha := headSha
              branch := branch
              turnIndex := turnIndex
              turnId := turnId
              label := label
              createdAt := nowSec
            }
  catch e =>
    cleanup
    return .error s!"checkpoint_exception: {e}"

/-- List all hidden checkpoints recorded for `missionId` inside `cwd`'s git repository, ordered by ref name (`turnIndex` ascending). -/
def listCheckpoints (cwd : String) (missionId : String) : IO (Except String (Array CheckpointMeta)) := do
  let some repoRoot ← resolveGitTopLevel? cwd
    | return .ok #[]
  let safeMid := sanitizeGitToken missionId "mission" 64
  let prefixRef := s!"refs/orb/checkpoints/{safeMid}/"
  let fmt := "%(refname)\t%(objectname)\t%(tree)\t%(contents:lines=1)"
  match ← runGit repoRoot #["for-each-ref", "--sort=refname", s!"--format={fmt}", prefixRef] with
  | .error e => return .error e
  | .ok out =>
    if out.exitCode != 0 then
      return .error s!"git for-each-ref failed: {out.stderr.trimAscii.toString}"
    let mut items : Array CheckpointMeta := #[]
    for rawLine in out.stdout.splitOn "\n" do
      let line := (rawLine.dropEndWhile (· == '\r')).toString
      if !line.trimAscii.toString.isEmpty then
        let cols := line.splitOn "\t"
        if h : cols.length >= 3 then
          let rName := cols[0]
          let cSha := cols[1]
          let tSha := cols[2]
          let body := String.intercalate "\t" (cols.drop 3)
          items := items.push (decodeCheckpointMeta rName cSha tSha body)
    return .ok items

/-- Collect authored file paths modified since `sinceEpoch` excluding clean upstream merge commits (`--diff-merges=remerge`). -/
def authoredPathsSince? (repoRoot : String) (sinceEpoch : UInt64) : IO (Option (Array String)) := do
  match ← runGit repoRoot #["log", "--diff-merges=remerge", "--name-only", "--pretty=format:", s!"--since=@{sinceEpoch}"] with
  | .error _ => return none
  | .ok out =>
    if out.exitCode != 0 then return none
    let mut seen : Array String := #[]
    for raw in out.stdout.splitOn "\n" do
      let p := raw.trimAscii.toString
      if !p.isEmpty && !seen.contains p then
        seen := seen.push p
    return some seen

/-- Capture a transient tree SHA of the live working directory (including untracked files) via a private `GIT_INDEX_FILE`. -/
private def snapshotWorkingTreeSha (repoRoot : String) : IO (Except String String) := do
  let uuid ← newUuidV4
  let tmpBase := ((← IO.getEnv "TMPDIR").getD "/tmp").trimAscii.toString
  let cleanTmp := if tmpBase.endsWith "/" then (tmpBase.dropEnd 1).toString else if tmpBase.isEmpty then "/tmp" else tmpBase
  let tmpIndex := s!"{cleanTmp}/orb-diff-idx-{uuid}"
  let cleanup : IO Unit := do
    try IO.FS.removeFile tmpIndex catch _ => pure ()
    try IO.FS.removeFile (tmpIndex ++ ".lock") catch _ => pure ()
  let headSha ← currentHeadSha repoRoot
  let idxEnv : Array (String × Option String) := #[("GIT_INDEX_FILE", some tmpIndex)]
  if !headSha.isEmpty then
    let _ ← runGit repoRoot #["read-tree", headSha] idxEnv
  match ← runGit repoRoot #["add", "-A", "--", "."] idxEnv with
  | .error e => cleanup; return .error e
  | .ok addOut =>
    if addOut.exitCode != 0 then
      cleanup
      return .error s!"git add -A failed: {addOut.stderr.trimAscii.toString}"
    match ← runGit repoRoot #["write-tree"] idxEnv with
    | .error e => cleanup; return .error e
    | .ok treeOut =>
      cleanup
      if treeOut.exitCode != 0 then
        return .error s!"git write-tree failed: {treeOut.stderr.trimAscii.toString}"
      return .ok treeOut.stdout.trimAscii.toString

/-- Resolve a ref (`"WORKTREE"`, `"HEAD"`, `"EMPTY"`, checkpoint ref, or commit/tree SHA) into a git tree-ish. -/
private def resolveDiffEndpoint (repoRoot : String) (spec : String) : IO (Except String String) := do
  let s := spec.trimAscii.toString
  if s.isEmpty || s == "WORKTREE" then
    snapshotWorkingTreeSha repoRoot
  else if s == "EMPTY" then
    -- Canonical git empty tree SHA-1
    return .ok "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  else if s == "HEAD" then
    let headSha ← currentHeadSha repoRoot
    if headSha.isEmpty then
      return .ok "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    else
      return .ok headSha
  else
    if s.startsWith "-" then
      return .error "invalid_diff_ref"
    match ← runGit repoRoot #["rev-parse", "--verify", "--quiet", s ++ "^{tree}"] with
    | .error e => return .error e
    | .ok out =>
      let resolved := out.stdout.trimAscii.toString
      if out.exitCode != 0 || resolved.isEmpty then
        return .error s!"unknown_git_ref:{s}"
      return .ok resolved

/-- Split unified `git diff` output by `diff --git ` headers into `(path, patchChunk)` entries. -/
def splitUnifiedDiffByFile (rawDiff : String) : Array (String × String) := Id.run do
  let mut result : Array (String × String) := #[]
  let mut curPath : String := ""
  let mut curLines : Array String := #[]
  for line in rawDiff.splitOn "\n" do
    if line.startsWith "diff --git " then
      if !curPath.isEmpty then
        result := result.push (curPath, String.intercalate "\n" curLines.toList)
      curLines := #[line]
      -- Extract `b/<path>` from `diff --git a/<old> b/<new>`
      let parts := line.splitOn " b/"
      curPath := if parts.length >= 2 then String.intercalate " b/" parts.tail! else line
    else if !curPath.isEmpty then
      curLines := curLines.push line
  if !curPath.isEmpty then
    result := result.push (curPath, String.intercalate "\n" curLines.toList)
  return result

/-- Compute diff between `fromSpec` (default `"HEAD"`) and `toSpec` (default `"WORKTREE"`),
    optionally filtering committed noise via `authoredPathsSince?` and enforcing `Orb.Kernel.repoDiffBudgetStep`. -/
def diffCheckpoints
    (cwd : String)
    (fromSpec : String := "HEAD")
    (toSpec : String := "WORKTREE")
    (sinceEpoch? : Option UInt64 := none)
    (maxBytes : UInt32 := defaultDiffMaxBytes)
    (maxFiles : UInt16 := defaultDiffMaxFiles) : IO (Except String CheckpointDiffReport) := do
  let some repoRoot ← resolveGitTopLevel? cwd
    | return .error "not_a_git_repository"
  let branch ← currentGitBranch repoRoot
  let .ok fromTree ← resolveDiffEndpoint repoRoot (if fromSpec.trimAscii.toString.isEmpty then "HEAD" else fromSpec)
    | return .error s!"invalid_from_ref:{fromSpec}"
  let .ok toTree ← resolveDiffEndpoint repoRoot (if toSpec.trimAscii.toString.isEmpty then "WORKTREE" else toSpec)
    | return .error s!"invalid_to_ref:{toSpec}"

  let authoredFilter? ← match sinceEpoch? with
    | some ts =>
      if ts > 0 then authoredPathsSince? repoRoot ts else pure none
    | none => pure none
  -- Also always include currently dirty working-tree paths when `toSpec == "WORKTREE"` so uncommitted edits are never filtered out!
  let mut dirtyPaths : Array String := #[]
  if toSpec.trimAscii.toString.isEmpty || toSpec.trimAscii.toString == "WORKTREE" then
    if let .ok stOut ← runGit repoRoot #["status", "--porcelain=v1", "-uall"] then
      if stOut.exitCode == 0 then
        for ln in stOut.stdout.splitOn "\n" do
          if ln.length > 3 then
            let rawP := (ln.drop 3).trimAscii.toString
            let p := match rawP.splitOn " -> " with
              | [_, dst] => dst
              | _ => rawP
            if !p.isEmpty then dirtyPaths := dirtyPaths.push p

  let allowPath (p : String) : Bool :=
    match authoredFilter? with
    | none => true
    | some authored => authored.contains p || dirtyPaths.contains p

  let .ok statusOut ← runGit repoRoot #["diff-tree", "-r", "-M", "--name-status", fromTree, toTree]
    | return .error "git_diff_name_status_failed"
  let .ok numOut ← runGit repoRoot #["diff-tree", "-r", "-M", "--numstat", fromTree, toTree]
    | return .error "git_diff_numstat_failed"

  -- Parse numstat: `<added>\t<deleted>\t<path>`
  let mut statsByPath : Array (String × (Nat × Nat × Bool)) := #[]
  for raw in numOut.stdout.splitOn "\n" do
    let ln := (raw.dropEndWhile (· == '\r')).toString
    if !ln.isEmpty then
      let cols := ln.splitOn "\t"
      if h : cols.length >= 3 then
        let aRaw := cols[0]
        let dRaw := cols[1]
        let pRaw := cols.getLast!
        let isBin := aRaw == "-" || dRaw == "-"
        let a := aRaw.toNat?.getD 0
        let d := dRaw.toNat?.getD 0
        statsByPath := statsByPath.push (pRaw, (a, d, isBin))

  let lookupStat (p : String) : Nat × Nat × Bool :=
    match statsByPath.find? (fun (k, _) => k == p) with
    | some (_, st) => st
    | none => (0, 0, false)

  let mut rawEntries : Array DiffFileEntry := #[]
  let mut totalAdded : Nat := 0
  let mut totalDeleted : Nat := 0
  for raw in statusOut.stdout.splitOn "\n" do
    let ln := (raw.dropEndWhile (· == '\r')).toString
    if !ln.isEmpty then
      let cols := ln.splitOn "\t"
      if h : cols.length >= 2 then
        let stCode := cols[0]
        if stCode.startsWith "R" && cols.length >= 3 then
          let oldP := cols[1]!
          let newP := cols[2]!
          if allowPath newP || allowPath oldP then
            let (a, d, bin) := lookupStat newP
            totalAdded := totalAdded + a
            totalDeleted := totalDeleted + d
            rawEntries := rawEntries.push {
              path := newP, oldPath? := some oldP, status := "R", additions := a, deletions := d, binary := bin
            }
        else
          let p := cols[1]
          if allowPath p then
            let normStatus :=
              if stCode.startsWith "A" then "A"
              else if stCode.startsWith "D" then "D"
              else "M"
            let (a, d, bin) := lookupStat p
            totalAdded := totalAdded + a
            totalDeleted := totalDeleted + d
            rawEntries := rawEntries.push {
              path := p, status := normStatus, additions := a, deletions := d, binary := bin
            }

  let modCountU32 : UInt32 := (Nat.min rawEntries.size 0xFFFFFFFF).toUInt32
  let maxFilesU32 : UInt32 := maxFiles.toUInt32
  -- Check file-count budget first before materializing full unified patch text
  let preWord64 := repoDiffBudgetStep 1 1 0 modCountU32 0 0 0 0 maxFilesU32 maxBytes
  let preDecision : UInt32 := preWord64.toUInt32
  let preTruncFiles := (preDecision &&& 1024) != 0
  let cappedEntries :=
    if rawEntries.size > maxFiles.toNat then rawEntries.extract 0 maxFiles.toNat else rawEntries

  if cappedEntries.isEmpty then
    return .ok {
      repoRoot := repoRoot
      branch := branch
      fromRef := fromSpec
      toRef := toSpec
      files := cappedEntries
      totalAdded := totalAdded
      totalDeleted := totalDeleted
      truncated := preTruncFiles
      summaryOnly := false
      verdictCode := preDecision
    }

  let .ok patchOut ← runGit repoRoot #["diff", "-M", "--unified=3", fromTree, toTree]
    | return .error "git_diff_patch_failed"
  let totalBytesU32 : UInt32 := (Nat.min patchOut.stdout.utf8ByteSize 0xFFFFFFFF).toUInt32
  let decWord64 := repoDiffBudgetStep 1 1 0 modCountU32 0 0 0 totalBytesU32 maxFilesU32 maxBytes
  let decision : UInt32 := decWord64.toUInt32
  let isTruncated := (decision &&& (1024 ||| 2048)) != 0
  let isSummaryOnly := false
  let patchesByFile := splitUnifiedDiffByFile patchOut.stdout
  let lookupPatch (p : String) : String :=
    match patchesByFile.find? (fun (k, _) => k == p) with
    | some (_, txt) => txt
    | none => ""

  let mut remainingBudget : Nat := maxBytes.toNat
  let mut enriched : Array DiffFileEntry := Array.mkEmpty cappedEntries.size
  for entry in cappedEntries do
    if isSummaryOnly || entry.binary then
      enriched := enriched.push entry
    else
      let rawPatch := lookupPatch entry.path
      if rawPatch.utf8ByteSize <= remainingBudget then
        remainingBudget := remainingBudget - rawPatch.utf8ByteSize
        enriched := enriched.push { entry with patch := rawPatch }
      else if remainingBudget > 0 then
        let prefixPatch := (rawPatch.take remainingBudget).toString
        remainingBudget := 0
        enriched := enriched.push { entry with patch := prefixPatch, truncated := true }
      else
        enriched := enriched.push { entry with patch := "", truncated := !rawPatch.isEmpty }

  return .ok {
    repoRoot := repoRoot
    branch := branch
    fromRef := fromSpec
    toRef := toSpec
    files := enriched
    totalAdded := totalAdded
    totalDeleted := totalDeleted
    truncated := isTruncated || rawEntries.size > maxFiles.toNat
    summaryOnly := isSummaryOnly
    verdictCode := decision
  }

/-- Atomically restore the working directory to a hidden Orb checkpoint (`refs/orb/checkpoints/<mission>/...`):
    1. Rejects any `targetRef` outside `refs/orb/checkpoints/<mission>/` (supports resolving by `turn?` when `targetRef` is empty).
    2. Captures an automatic `"pre-restore"` safety checkpoint so a revert is itself reversible!
    3. Restores tracked files to `targetRef`'s tree (`git read-tree --reset -u <tree>`) and removes
       untracked non-ignored files added after `targetRef` (`git clean -fd`), then resets `.git/index`
       back to `HEAD` so `git status` accurately shows the restored state relative to `HEAD`. -/
def restoreCheckpoint
    (cwd : String)
    (missionId : String)
    (targetRef : String)
    (turn? : Option Nat := none) : IO (Except String JVal) := do
  let some repoRoot ← resolveGitTopLevel? cwd
    | return .error "not_a_git_repository"
  let existing ← listCheckpoints repoRoot missionId
  let resolvedRef ←
    if !targetRef.trimAscii.toString.isEmpty then
      pure targetRef.trimAscii.toString
    else
      match turn?, existing with
      | some tIdx, .ok xs =>
        pure (((xs.find? (fun cp => cp.turnIndex == tIdx)).map (·.ref)).getD "")
      | _, _ => pure ""
  if !checkSafeMissionCheckpointRef missionId resolvedRef then
    return .error "invalid_checkpoint_ref"
  match ← runGit repoRoot #["rev-parse", "--verify", "--quiet", resolvedRef ++ "^{tree}"] with
  | .error e => return .error e
  | .ok verOut =>
    let targetTree := verOut.stdout.trimAscii.toString
    if verOut.exitCode != 0 || targetTree.isEmpty then
      return .error "checkpoint_not_found"
    -- Capture a safety backup checkpoint before mutating the working tree
    let nextIdx := match existing with
      | .ok xs =>
        let maxTurn := xs.foldl (fun acc cp => Nat.max acc cp.turnIndex) 0
        Nat.max (xs.size + 1) (maxTurn + 1)
      | .error _ => 999
    let backupRes ← captureCheckpoint repoRoot missionId nextIdx "pre-restore" s!"Before restore to {resolvedRef}"
    let backupRef := match backupRes with
      | .ok cpMeta => cpMeta.ref
      | .error _ => ""
    -- Materialize target tree into working directory and index
    match ← runGit repoRoot #["read-tree", "--reset", "-u", targetTree] with
    | .error e => return .error e
    | .ok rtOut =>
      if rtOut.exitCode != 0 then
        return .error s!"git read-tree --reset -u failed: {rtOut.stderr.trimAscii.toString}"
      -- Remove untracked files that were not in `targetTree` while preserving `.gitignore`d caches (`.lake`, `node_modules`, etc.)
      let _ ← runGit repoRoot #["clean", "-fd"]
      -- Re-align the user's real `.git/index` with `HEAD` (if `HEAD` exists) without touching the working tree
      let headSha ← currentHeadSha repoRoot
      if !headSha.isEmpty then
        let _ ← runGit repoRoot #["read-tree", headSha]
      return .ok (.obj #[
        ("ok", .bool true),
        ("restored", .bool true),
        ("ref", .str resolvedRef),
        ("tree_sha", .str targetTree),
        ("backup_ref", .str backupRef),
        ("repo_root", .str repoRoot)
      ])

/-- Inspect git repository state and evaluate `Orb.Kernel.worktreeDecisionStep` (`513` = create isolated worktree, `256` = use local checkout). -/
def inspectWorktreeStatus
    (cwd : String)
    (missionId : String := "new")
    (otherActiveCwds : Array String := #[])
    (preferWorktree : Bool := false)
    (worktreesParentDir? : Option String := none) : IO WorktreeStatus := do
  let some repoRoot ← resolveGitTopLevel? cwd
    | return { isGitRepo := false, decisionWord := worktreeDecisionStep 0 0 0 1 0 1 1 64 0 32 }
  let branch ← currentGitBranch repoRoot
  let isDirty ← match ← runGit repoRoot #["status", "--porcelain=v1", "-uno"] with
    | .ok out => pure (out.exitCode == 0 && !out.stdout.trimAscii.toString.isEmpty)
    | .error _ => pure false
  let isLinkedWorktree ← match ← runGit repoRoot #["rev-parse", "--git-common-dir", "--git-dir"] with
    | .ok out =>
      let lines := (out.stdout.splitOn "\n").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      pure (lines.length >= 2 && lines[0]! != lines[1]!)
    | .error _ => pure false
  let mut occupied := false
  for other in otherActiveCwds do
    if !occupied then
      if let some otherRoot ← resolveGitTopLevel? other then
        if otherRoot == repoRoot then
          occupied := true
  let isolateRequested := occupied || preferWorktree
  let shortId := sanitizeGitToken missionId "mission" 24
  let repoFp := System.FilePath.mk repoRoot
  let repoName := sanitizeGitToken (repoFp.fileName.getD "repo") "repo" 32
  let defaultParent := (repoFp.parent.map (·.toString)).getD "/tmp"
  let parentDirRaw := (worktreesParentDir?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)).getD defaultParent
  let parentDir := if parentDirRaw.endsWith "/" && parentDirRaw.length > 1 then (parentDirRaw.dropEnd 1).toString else parentDirRaw
  let suggestedPath := s!"{parentDir}/.orb-worktrees/{repoName}-{shortId}"
  let suggestedBranch := s!"orb/{shortId}"
  let occFlag : UInt8 := if isolateRequested then 1 else 0
  let word := worktreeDecisionStep 0 occFlag 1 1 0 1 shortId.utf8ByteSize.toUInt32 64 0 32
  let shouldCreate := word == 513
  return {
    isGitRepo := true
    repoRoot := repoRoot
    branch := branch
    isDirty := isDirty
    isWorktree := isLinkedWorktree
    occupiedByOther := occupied
    decisionWord := word
    createWorktree := shouldCreate
    recommendedMode := if shouldCreate then "worktree" else "local"
    suggestedBranch := suggestedBranch
    suggestedPath := suggestedPath
  }

/-- Create (or reuse if already created for `missionId`) an isolated sibling git worktree gated by `Orb.Kernel.worktreeDecisionStep`. -/
def createMissionWorktree
    (cwd : String)
    (missionId : String)
    (baseBranch? : Option String := none)
    (worktreesParentDir? : Option String := none) : IO (Except String CreatedWorktree) := do
  if let some rawB := baseBranch?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    if !checkSafeBranchOrRef rawB then
      return .error "invalid_base_branch"
  let status ← inspectWorktreeStatus cwd missionId #[] true worktreesParentDir?
  if !status.isGitRepo then
    return .error "not_a_git_repository"
  let wtPath := status.suggestedPath
  let wtBranch := status.suggestedBranch
  if (← System.FilePath.pathExists wtPath) then
    if let some existingRoot ← resolveGitTopLevel? wtPath then
      let existingBranch ← currentGitBranch existingRoot
      return .ok {
        repoRoot := status.repoRoot
        worktreePath := existingRoot
        branch := existingBranch
        baseRef := status.branch
        reused := true
      }
  let createDecision := worktreeDecisionStep 1 1 1 1 0 1 wtBranch.utf8ByteSize.toUInt32 64 0 32
  if createDecision != 257 then
    return .error s!"worktree_rejected_by_kernel:{createDecision}"
  if let some parent := (System.FilePath.mk wtPath).parent then
    IO.FS.createDirAll parent
  -- Ensure initial commit exists if repo has an unborn HEAD so `git worktree add` succeeds
  let headSha ← currentHeadSha status.repoRoot
  let baseRef := match baseBranch?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) with
    | some b => b
    | none => if headSha.isEmpty then "" else "HEAD"
  let wtArgs :=
    if baseRef.isEmpty then #["worktree", "add", "--orphan", "-b", wtBranch, "--", wtPath]
    else #["worktree", "add", "-B", wtBranch, "--", wtPath, baseRef]
  match ← runGit status.repoRoot wtArgs with
  | .error e => return .error e
  | .ok out =>
    if out.exitCode != 0 then
      return .error s!"git worktree add failed: {out.stderr.trimAscii.toString}"
    let finalPath ← try
        let rp ← IO.FS.realPath (System.FilePath.mk wtPath)
        pure rp.toString
      catch _ =>
        pure wtPath
    return .ok {
      repoRoot := status.repoRoot
      worktreePath := finalPath
      branch := wtBranch
      baseRef := if baseRef.isEmpty then "orphan" else baseRef
      reused := false
    }

/-- Safely remove an Orb-managed sibling worktree (must reside inside an `.orb-worktrees/` directory). -/
def removeMissionWorktree (worktreePath : String) (force : Bool := false) : IO (Except String JVal) := do
  let clean := worktreePath.trimAscii.toString
  if clean.isEmpty || (clean.splitOn "/.orb-worktrees/").length < 2 then
    return .error "not_an_orb_managed_worktree"
  if !(← System.FilePath.pathExists clean) then
    return .ok (.obj #[("removed", .bool true), ("already_absent", .bool true)])
  -- Discover main repository via `--git-common-dir`
  let commonDirRes ← runGit clean #["rev-parse", "--git-common-dir"]
  let mainGitDir := match commonDirRes with
    | .ok out =>
      let raw := out.stdout.trimAscii.toString
      if raw.startsWith "/" then raw else s!"{clean}/{raw}"
    | .error _ => clean
  let rmArgs := if force then #["worktree", "remove", "--force", clean] else #["worktree", "remove", clean]
  match ← IO.Process.output {
    cmd := "git"
    args := #[s!"--git-dir={mainGitDir}"] ++ rmArgs
    env := #[("GIT_TERMINAL_PROMPT", some "0")]
  } with
  | out =>
    if out.exitCode != 0 then
      return .error s!"git worktree remove failed: {out.stderr.trimAscii.toString}"
    let _ ← IO.Process.output {
      cmd := "git"
      args := #[s!"--git-dir={mainGitDir}", "worktree", "prune"]
      env := #[("GIT_TERMINAL_PROMPT", some "0")]
    }
    return .ok (.obj #[("removed", .bool true), ("worktree_path", .str clean)])

end OrbBin.GitWorkspace
