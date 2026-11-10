/-
  OrbNode.LeanBuild: `lean_build` Payload Validation, Checkout Materialization, Shared Mission
  Cache Setup (`<work_dir>/caches/{elan,turbo-lean,bin/lake}`), and Symlink-Free Artifact Hashing.
-/
import LeanSys.Auth
import Orb.Kernel
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Store

namespace OrbNode.LeanBuild

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.Store

def defaultMaxSourceBundleBytes : UInt64 := 1024 * 1024
def defaultMaxCompleteBundleBytes : UInt64 := 32 * 1024 * 1024
def defaultMaxArchiveBytes : UInt64 := 32 * 1024 * 1024
def maxBundleFiles : Nat := 128
def maxCompleteBundleFiles : Nat := 4096
def maxArchiveObjects : Nat := 65536
def maxTurboLeanJobs : Nat := 64
def maxTurboLeanMemoryMb : Nat := 131072
def maxSingleArtifactBytes : UInt64 := 4 * 1024 * 1024 * 1024

def lakeAdvisoryWrapper : String :=
  "#!/bin/sh\n" ++
  "self_dir=$(CDPATH='' cd -- \"$(dirname -- \"$0\")\" && pwd -P)\n" ++
  "real_lake=\"\"\n" ++
  "if [ -n \"${ELAN_HOME:-}\" ] && [ -x \"${ELAN_HOME}/bin/lake\" ]; then\n" ++
  "  cand_dir=$(CDPATH='' cd -- \"$(dirname -- \"${ELAN_HOME}/bin/lake\")\" 2>/dev/null && pwd -P || true)\n" ++
  "  if [ \"$cand_dir\" != \"$self_dir\" ]; then real_lake=\"${ELAN_HOME}/bin/lake\"; fi\n" ++
  "fi\n" ++
  "if [ -z \"$real_lake\" ]; then\n" ++
  "  old_ifs=$IFS; IFS=':'\n" ++
  "  for dir in ${PATH:-/usr/local/bin:/usr/bin:/bin}; do\n" ++
  "    [ -n \"$dir\" ] || continue\n" ++
  "    if [ -x \"$dir/lake\" ]; then\n" ++
  "      cand_dir=$(CDPATH='' cd -- \"$dir\" 2>/dev/null && pwd -P || true)\n" ++
  "      if [ \"$cand_dir\" != \"$self_dir\" ]; then real_lake=\"$dir/lake\"; break; fi\n" ++
  "    fi\n" ++
  "  done\n" ++
  "  IFS=$old_ifs\n" ++
  "fi\n" ++
  "if [ -z \"$real_lake\" ]; then\n" ++
  "  printf 'sandboxed-node: lake binary not found in ELAN_HOME or PATH\\n' >&2\n" ++
  "  exit 127\n" ++
  "fi\n" ++
  "heavy_lake=0\n" ++
  "case \"${1:-}\" in\n" ++
  "  build|check|test) heavy_lake=1 ;;\n" ++
  "  env) case \"${2:-}\" in lake) case \"${3:-}\" in build|check|test) heavy_lake=1 ;; esac ;; esac ;;\n" ++
  "esac\n" ++
  "if [ \"$heavy_lake\" -eq 1 ] && [ \"${SANDBOXED_ALLOW_RAW_LAKE:-0}\" != \"1\" ] && [ \"${SANDBOXED_REMOTE_EXECUTION:-0}\" != \"1\" ]; then\n" ++
  "  printf '[sandboxed-node] warning: raw `lake %s` duplicates .lake/.olean artifacts; prefer `turbo-lean build` or `turbo-lean check`.\\n' \"${1:-build}\" >&2\n" ++
  "fi\n" ++
  "exec \"$real_lake\" \"$@\"\n"

/-- Prepare `<workDir>/caches/{elan,turbo-lean,bin/lake}` and return baseline cleared-env pairs. -/
def prepareSharedMissionEnv (workDir cwd : String) : IO (Array (String × String)) := do
  let root := System.FilePath.mk workDir
  let caches := root / "caches"
  let elan ← do
    let wElan := caches / "elan"
    if ← (wElan / "toolchains").isDir then pure wElan
    else if let some envElan ← getEnvNonEmpty "ELAN_HOME" then
      let p := System.FilePath.mk envElan
      if ← (p / "toolchains").isDir then pure p else pure wElan
    else if ← (System.FilePath.mk "/opt/orb/elan/toolchains").isDir then
      pure (System.FilePath.mk "/opt/orb/elan")
    else if let some h ← getEnvNonEmpty "HOME" then
      let p := System.FilePath.mk h / ".elan"
      if ← (p / "toolchains").isDir then pure p else pure wElan
    else pure wElan
  let tl := caches / "turbo-lean"
  let bin := caches / "bin"
  IO.FS.createDirAll (caches / "elan")
  IO.FS.createDirAll tl
  IO.FS.createDirAll bin
  let lakeShim := bin / "lake"
  let curBytes ← match ← IO.FS.readFile lakeShim |>.toBaseIO with
    | .ok s => pure s
    | .error _ => pure ""
  if curBytes != lakeAdvisoryWrapper then
    let nonce ← newUuidV4
    let tmp := bin / s!".lake.tmp.{nonce}"
    IO.FS.writeFile tmp lakeAdvisoryWrapper
    let _ ← chmod tmp.toString 0o755
    try IO.FS.rename tmp lakeShim catch _ => try IO.FS.removeFile tmp catch _ => pure ()
  let servicePath := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  let safeServiceDirs := (servicePath.splitOn ":").filter fun d => d.startsWith "/"
  let rustup := caches / "rustup"
  let cargo := caches / "cargo"
  let hasRustup ← (rustup / "toolchains").isDir <||> (cargo / "bin" / "rustup").pathExists
  let mut pathParts : Array String := #[bin.toString]
  if hasRustup && (← (cargo / "bin").isDir) then
    pathParts := pathParts.push (cargo / "bin").toString
  pathParts := pathParts.push (elan / "bin").toString
  for d in safeServiceDirs do
    if !pathParts.contains d then pathParts := pathParts.push d
  for fb in ["/usr/local/bin", "/usr/bin", "/bin"] do
    if !pathParts.contains fb then pathParts := pathParts.push fb
  let mut envs : Array (String × String) := #[
    ("PATH", String.intercalate ":" pathParts.toList),
    ("HOME", cwd),
    ("LANG", "C.UTF-8"),
    ("ELAN_HOME", elan.toString),
    ("TURBO_LEAN_HOME", tl.toString)
  ]
  if hasRustup then
    envs := envs.push ("RUSTUP_HOME", rustup.toString) |>.push ("CARGO_HOME", cargo.toString)
  return envs

def isLowerHex (s : String) (expectedLen : Nat) : Bool :=
  s.length == expectedLen && s.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

def isSafeRelSegmentChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '.' || c == '-'

def relPathIsSafe (rel : String) : Bool :=
  if rel.isEmpty then true
  else
    !rel.startsWith "/" && !rel.endsWith "/" && !rel.contains '\\' &&
    (rel.splitOn "/").all fun seg =>
      !seg.isEmpty && seg != "." && seg != ".." && !seg.startsWith "-" && seg.all isSafeRelSegmentChar

def bundlePathIsSafe (p : String) : Bool :=
  !p.isEmpty && relPathIsSafe p &&
  !(p.splitOn "/").any fun seg =>
    seg == "." || seg == ".git" || seg == ".lake" || seg == ".turbo-lean" ||
    seg == ".turbo-lean.toml" || seg == "turbo-lean.toml"

def repoUrlHasCredentialsOrQuery (repo : String) : Bool := Id.run do
  let r := repo.trimAscii.toString
  if r.contains '?' || r.contains '#' then return true
  if r.startsWith "https://" || r.startsWith "http://" then
    let after := if r.startsWith "https://" then (r.drop 8).toString else (r.drop 7).toString
    let auth := (after.splitOn "/").headD ""
    return auth.contains '@'
  if r.startsWith "ssh://" then
    let after := (r.drop 6).toString
    let auth := (after.splitOn "/").headD ""
    if let [userPart, _] := auth.splitOn "@" then
      return userPart.contains ':'
  return false

def repoUrlIsRemote (repo : String) : Bool :=
  let r := repo.trimAscii.toString
  if r.startsWith "https://" then (r.drop 8).toString.length > 1
  else if r.startsWith "ssh://" then (r.drop 6).toString.length > 1
  else if r.startsWith "/" || r.startsWith "." || r.contains '\\' || r.contains ':' == false then false
  else
    match r.splitOn ":" with
    | userHost :: rest =>
      let path := String.intercalate ":" rest
      userHost.contains '@' && !userHost.contains '/' && !path.isEmpty
    | [] => false

def isReservedNodeEnvKey (raw : String) : Bool :=
  let key := raw.trimAscii.toString.toUpper
  if key == "TURBO_LEAN_MAX_MEMORY_MB" || key == "TURBO_LEAN_NO_AUDIT_CACHE" then false
  else
    key == "PATH" || key == "HOME" || key == "USER" || key == "LOGNAME" || key == "SHELL" ||
    key == "TMPDIR" || key == "TMP" || key == "TEMP" || key == "SSL_CERT_FILE" ||
    key == "SSL_CERT_DIR" || key == "CURL_CA_BUNDLE" || key == "HTTP_PROXY" ||
    key == "HTTPS_PROXY" || key == "ALL_PROXY" || key == "NO_PROXY" ||
    key.startsWith "XDG_" || key.startsWith "ELAN_" || key.startsWith "TURBO_LEAN_" ||
    key.startsWith "LEAN_NATIVE_" || key.startsWith "SANDBOXED_" || key.startsWith "LD_" ||
    key.startsWith "DYLD_" || key.startsWith "GIT_" || key.startsWith "SSH_" ||
    (key.splitOn "TOKEN").length > 1 || (key.splitOn "SECRET").length > 1 ||
    (key.splitOn "PASSWORD").length > 1 || (key.splitOn "CREDENTIAL").length > 1 ||
    (key.splitOn "KEY").length > 1

private def turboLeanIdentSafe (s : String) : Bool :=
  !s.isEmpty && !s.startsWith "-" &&
  s.all (fun c => c.isAlphanum || c == '_' || c == '.' || c == '\'' || c == ':' || c == '-')

private def turboLeanTargetSafe (s : String) : Bool :=
  !s.isEmpty && !s.startsWith "-" && !s.startsWith "/" && !s.contains '\\' &&
  !(s.splitOn "/").any (· == "..") &&
  s.all (fun c => c.isAlphanum || c == '_' || c == '.' || c == '-' || c == '/' || c == ':' || c == '+' || c == '@')

private def turboLeanRelSafe (s : String) : Bool :=
  s == "." || bundlePathIsSafe s

def validateTurboLeanArgs (args : Array String) : Except String Unit := do
  let mut subcmd? : Option String := none
  let mut positionals : Array String := #[]
  let mut idx := 0
  while idx < args.size do
    let arg := args[idx]!
    if arg.isEmpty then throw "turbo-lean argument must not be empty"
    if arg == "--json" || arg == "--no-daemon" || arg == "--no-telemetry" || arg == "--no-auto-worktree-link" then
      idx := idx + 1; continue
    if arg == "--cache-dir" || arg.startsWith "--cache-dir=" ||
       arg == "--telemetry" || arg.startsWith "--telemetry=" then
      throw s!"turbo-lean flag '{arg}' is managed by the node runner and cannot be overridden"
    if arg == "--max-memory-mb" || arg.startsWith "--max-memory-mb=" then
      let v ← if arg.startsWith "--max-memory-mb=" then .ok (arg.drop 16).toString
              else if idx + 1 < args.size then idx := idx + 1; .ok args[idx]!
              else .error "turbo-lean --max-memory-mb requires a value"
      let some mb := v.toNat? | throw "turbo-lean --max-memory-mb must be positive integer"
      if mb == 0 || mb > maxTurboLeanMemoryMb then throw "turbo-lean --max-memory-mb out of range"
      idx := idx + 1; continue
    match subcmd? with
    | none =>
      if arg.startsWith "-" then throw s!"disallowed turbo-lean global flag '{arg}'"
      if !(["build", "check", "audit-spec", "agent-step", "prove-step", "eval"].contains arg) then
        throw s!"turbo-lean subcommand '{arg}' is not allowed"
      subcmd? := some arg
      idx := idx + 1
    | some verb =>
      if !arg.startsWith "-" then
        positionals := positionals.push arg
        idx := idx + 1
      else
        let takeFlagVal (flag : String) ( curIdx : Nat ) : Except String (String × Nat) := do
          let pfx := flag ++ "="
          if arg.startsWith pfx then
            let val := (arg.drop pfx.length).toString
            if val.isEmpty then throw s!"turbo-lean {flag} requires a non-empty value"
            return (val, curIdx)
          else if curIdx + 1 < args.size then
            let val := args[curIdx + 1]!
            if val.isEmpty then throw s!"turbo-lean {flag} requires a non-empty value"
            return (val, curIdx + 1)
          else
            throw s!"turbo-lean {flag} requires a value"
        match verb with
        | "build" =>
          if arg == "--project-dir" || arg.startsWith "--project-dir=" then
            let (v, ni) ← takeFlagVal "--project-dir" idx
            if !turboLeanRelSafe v then throw s!"unsafe turbo-lean --project-dir '{v}'"
            idx := ni + 1
          else throw s!"disallowed turbo-lean build flag '{arg}'"
        | "check" =>
          if arg == "--project-dir" || arg.startsWith "--project-dir=" then
            let (v, ni) ← takeFlagVal "--project-dir" idx
            if !turboLeanRelSafe v then throw s!"unsafe turbo-lean --project-dir '{v}'"
            idx := ni + 1
          else if arg == "--decl" || arg.startsWith "--decl=" then
            let (v, ni) ← takeFlagVal "--decl" idx
            if !turboLeanIdentSafe v then throw s!"invalid turbo-lean --decl '{v}'"
            idx := ni + 1
          else if arg == "-j" || arg == "--jobs" || arg.startsWith "--jobs=" then
            let flag := if arg == "-j" then "-j" else "--jobs"
            let (v, ni) ← takeFlagVal flag idx
            let some n := v.toNat? | throw "invalid --jobs"
            if n == 0 || n > maxTurboLeanJobs then throw "turbo-lean --jobs out of range"
            idx := ni + 1
          else if arg == "--parallel-shards" then
            idx := idx + 1
          else if arg == "--timeout" || arg.startsWith "--timeout=" then
            let (v, ni) ← takeFlagVal "--timeout" idx
            if (v.toNat?.getD 0) == 0 then throw "invalid --timeout"
            idx := ni + 1
          else if arg == "--kernel" || arg.startsWith "--kernel=" then
            let (v, ni) ← takeFlagVal "--kernel" idx
            if !(["standard", "con-leche", "both"].contains v) then throw "invalid --kernel"
            idx := ni + 1
          else throw s!"disallowed turbo-lean check flag '{arg}'"
        | "audit-spec" =>
          if arg == "--decl" || arg.startsWith "--decl=" then
            let (v, ni) ← takeFlagVal "--decl" idx
            if !turboLeanIdentSafe v then throw "invalid --decl"
            idx := ni + 1
          else if arg == "--policy" || arg.startsWith "--policy=" then
            let (v, ni) ← takeFlagVal "--policy" idx
            if !(["permissive", "default", "strict-proofs"].contains v) then throw "invalid --policy"
            idx := ni + 1
          else if arg == "--forbid-namespace" || arg.startsWith "--forbid-namespace=" then
            let (v, ni) ← takeFlagVal "--forbid-namespace" idx
            if !turboLeanIdentSafe v then throw "invalid --forbid-namespace"
            idx := ni + 1
          else if arg == "--forbid-decl-kinds" || arg.startsWith "--forbid-decl-kinds=" then
            let (v, ni) ← takeFlagVal "--forbid-decl-kinds" idx
            if !(v.splitOn ",").all (fun p => !p.isEmpty && turboLeanIdentSafe p) then throw "invalid --forbid-decl-kinds"
            idx := ni + 1
          else if arg == "--require-nonempty" then
            idx := idx + 1
          else throw s!"disallowed turbo-lean audit-spec flag '{arg}'"
        | "agent-step" | "prove-step" =>
          if arg == "--project-dir" || arg.startsWith "--project-dir=" then
            let (v, ni) ← takeFlagVal "--project-dir" idx
            if !turboLeanRelSafe v then throw "unsafe --project-dir"
            idx := ni + 1
          else if arg == "--decl" || arg.startsWith "--decl=" then
            let (v, ni) ← takeFlagVal "--decl" idx
            if !turboLeanIdentSafe v then throw "invalid --decl"
            idx := ni + 1
          else if arg == "--low-memory" then
            idx := idx + 1
          else throw s!"disallowed turbo-lean {verb} flag '{arg}'"
        | "eval" =>
          if arg == "--project-dir" || arg.startsWith "--project-dir=" then
            let (v, ni) ← takeFlagVal "--project-dir" idx
            if !turboLeanRelSafe v then throw "unsafe --project-dir"
            idx := ni + 1
          else if arg == "--timeout-ms" || arg.startsWith "--timeout-ms=" then
            let (v, ni) ← takeFlagVal "--timeout-ms" idx
            if (v.toNat?.getD 0) == 0 then throw "invalid --timeout-ms"
            idx := ni + 1
          else if arg == "--verify-determinism" then
            idx := idx + 1
          else throw s!"disallowed turbo-lean eval flag '{arg}'"
        | _ => throw "unreachable verb"
  let some verb := subcmd? | throw "turbo-lean command must specify an allowed subcommand"
  match verb with
  | "build" =>
    for t in positionals do
      if !turboLeanTargetSafe t then throw s!"unsafe turbo-lean build target '{t}'"
  | "check" | "agent-step" | "prove-step" | "eval" =>
    if positionals.size != 1 then throw s!"turbo-lean {verb} requires exactly one .lean file"
    let p := positionals[0]!
    if !turboLeanRelSafe p || p == "." || !p.endsWith ".lean" then
      throw s!"unsafe or non-.lean file '{p}'"
  | "audit-spec" =>
    if positionals.isEmpty then throw "turbo-lean audit-spec requires at least one path"
    for p in positionals do
      if !turboLeanRelSafe p then throw s!"unsafe turbo-lean audit-spec path '{p}'"
  | _ => pure ()

def bundleManifestSha256 (files : Array (String × String)) (complete : Bool) : String := Id.run do
  let mut buf := (if complete then "sandboxed-source-bundle-v2-complete\n" else "sandboxed-source-bundle-v1\n").toUTF8
  for (path, sha) in files do
    buf := buf ++ path.toUTF8 ++ ByteArray.mk #[0] ++ sha.toUTF8 ++ "\n".toUTF8
  return bytesToHexLower (sha256Bytes buf)

def bundleOperationsSha256 (files : Array (String × Option Bool)) (deleted : Array String) : String := Id.run do
  let mut buf := "sandboxed-source-bundle-ops-v1\n".toUTF8
  for (path, exec?) in files do
    let mode := if exec? == some true then "x" else "-"
    buf := buf ++ "file".toUTF8 ++ ByteArray.mk #[0] ++ path.toUTF8 ++ ByteArray.mk #[0] ++ mode.toUTF8 ++ "\n".toUTF8
  for d in deleted do
    buf := buf ++ "delete".toUTF8 ++ ByteArray.mk #[0] ++ d.toUTF8 ++ "\n".toUTF8
  return bytesToHexLower (sha256Bytes buf)

def sourceArchiveSha256 (commit : String) (packBytes : ByteArray) : String :=
  let hdr := "sandboxed-source-archive-v1".toUTF8 ++ ByteArray.mk #[0] ++ commit.toUTF8 ++ ByteArray.mk #[0]
  bytesToHexLower (sha256Bytes (hdr ++ packBytes))

def validateSourceBundle (bundle : JVal) (maxOverlay maxComplete : UInt64) : Except String Unit := do
  let complete := (bundle.fieldBool? "complete").getD false
  let files := (bundle.fieldArr? "files").getD #[]
  let deleted := ((bundle.fieldArr? "deleted_paths").getD #[]).filterMap JVal.asStr?
  if files.isEmpty && deleted.isEmpty then
    throw "source bundle must contain files or deletions"
  let maxOps := if complete then maxCompleteBundleFiles else maxBundleFiles
  if files.size + deleted.size > maxOps then
    throw s!"source bundle exceeds maximum {maxOps} operations"
  let some manifestSha := bundle.fieldStr? "manifest_sha256"
    | throw "source bundle missing manifest_sha256"
  let maxBytes := if complete then maxComplete else maxOverlay
  let mut manifestPairs : Array (String × String) := #[]
  let mut opFiles : Array (String × Option Bool) := #[]
  let mut fileSet : Array String := #[]
  let mut prev? : Option String := none
  let mut totalBytes : UInt64 := 0
  let mut anyExecField := false
  for f in files do
    let some fpath := f.fieldStr? "path" | throw "bundle file missing path"
    let some fsha := f.fieldStr? "sha256" | throw "bundle file missing sha256"
    let some fb64 := f.fieldStr? "data_base64" | throw "bundle file missing data_base64"
    let exec? := f.fieldBool? "executable"
    if (f.field? "executable").isSome && f.field? "executable" != some .null then
      anyExecField := true
    if !bundlePathIsSafe fpath then
      throw s!"unsafe source bundle path '{fpath}'"
    if let some pr := prev? then
      if pr >= fpath then throw "source bundle paths must be unique and sorted"
    prev? := some fpath
    if !isLowerHex fsha 64 then
      throw s!"invalid source bundle sha256 for '{fpath}'"
    let some decoded := base64Decode? fb64
      | throw s!"invalid source bundle base64 for '{fpath}'"
    totalBytes := totalBytes + decoded.size.toUInt64
    if totalBytes > maxBytes then
      throw s!"source bundle exceeds {maxBytes} byte budget"
    let computed := bytesToHexLower (sha256Bytes decoded)
    if !ctEqString computed fsha then
      throw s!"source bundle content hash mismatch for '{fpath}'"
    manifestPairs := manifestPairs.push (fpath, fsha)
    opFiles := opFiles.push (fpath, exec?)
    fileSet := fileSet.push fpath
  let expectedManifest := bundleManifestSha256 manifestPairs complete
  if !ctEqString expectedManifest manifestSha then
    throw "source bundle manifest hash mismatch"
  let opsSha? := (bundle.fieldStr? "operations_sha256").filter (fun s => !s.isEmpty)
  if !deleted.isEmpty || anyExecField then
    let some opsSha := opsSha? | throw "source bundle operations_sha256 is required"
    let expectedOps := bundleOperationsSha256 opFiles deleted
    if !ctEqString expectedOps opsSha then
      throw "source bundle operations hash mismatch"
    let mut delPrev? : Option String := none
    for dp in deleted do
      if !bundlePathIsSafe dp || fileSet.contains dp then
        throw s!"unsafe or conflicting source bundle deletion '{dp}'"
      if let some pr := delPrev? then
        if pr >= dp then throw "source bundle deleted paths must be unique and sorted"
      delPrev? := some dp
  else if opsSha?.isSome then
    throw "source bundle operations_sha256 has no operations"

def validateSourceArchive (commit : String) (archive : JVal) (maxBytes : UInt64 := defaultMaxArchiveBytes) :
    Except String ByteArray := do
  let some sha := archive.fieldStr? "sha256" | throw "source archive missing sha256"
  let some sz := archive.fieldUInt64? "size_bytes" | throw "source archive missing size_bytes"
  let some b64 := archive.fieldStr? "data_base64" | throw "source archive missing data_base64"
  if !isLowerHex sha 64 then throw "invalid source archive sha256"
  if sz == 0 || sz > maxBytes then throw s!"source archive size must be in 1..={maxBytes}"
  let some bytes := base64Decode? b64 | throw "invalid source archive base64"
  if bytes.size.toUInt64 != sz then throw "source archive decoded size mismatch"
  let computed := sourceArchiveSha256 commit bytes
  if !ctEqString computed sha then throw "source archive commit-bound hash mismatch"
  if bytes.size < 12 || bytes.extract 0 4 != "PACK".toUTF8 then
    throw "source archive is not a Git pack"
  let objCount : Nat :=
    ((bytes.get! 8).toNat <<< 24) ||| ((bytes.get! 9).toNat <<< 16) |||
    ((bytes.get! 10).toNat <<< 8) ||| (bytes.get! 11).toNat
  if objCount > maxArchiveObjects then
    throw s!"source archive exceeds {maxArchiveObjects} objects"
  return bytes

/-- Full pre-admission `lean_build` validator (`422 Unprocessable Entity` on failure). -/
def validateLeanBuildPayload (payload : JVal) (allowlist : Array String) : Except String Unit := do
  let some src := payload.field? "source" | throw "lean_build requires source"
  let repo := ((src.fieldStr? "repo").getD "").trimAscii.toString
  if repo.isEmpty then throw "source.repo is required"
  if repoUrlHasCredentialsOrQuery repo then
    throw "source.repo URL must not contain credentials, query parameters, or a fragment"
  if !repoUrlIsRemote repo then
    throw s!"source.repo must be an https://, ssh:// or git@host: URL (got '{repo}')"
  let commit := (src.fieldStr? "commit").getD ""
  if !isLowerHex commit 40 then
    throw s!"source.commit must be a full 40-char lowercase hex SHA (got '{commit}')"
  if let some rawBaseTree := src.fieldStr? "base_tree_sha" then
    let bt := rawBaseTree.trimAscii.toString
    if !bt.isEmpty && !isLowerHex bt.toLower 40 then
      throw s!"source.base_tree_sha must be a 40-char hex SHA (got '{bt}')"
  if let some arch := src.field? "archive" then
    if arch != .null then discard <| validateSourceArchive commit arch
  if let some bnd := src.field? "bundle" then
    if bnd != .null then
      validateSourceBundle bnd defaultMaxSourceBundleBytes defaultMaxCompleteBundleBytes
  let cwdRelRaw := (payload.fieldStr? "cwd_rel").getD ""
  let cwdRel := (cwdRelRaw.dropWhile (· == '/') |>.dropEndWhile (· == '/')).toString
  if !relPathIsSafe cwdRel then
    throw s!"invalid cwd_rel '{cwdRel}'"
  let cmdArr := ((payload.fieldArr? "command").getD #[]).filterMap JVal.asStr?
  if cmdArr.isEmpty || cmdArr[0]!.trimAscii.isEmpty then
    throw "command must be a non-empty argv"
  let argv0 := cmdArr[0]!
  if argv0.contains '/' || argv0.contains '\\' then
    throw s!"argv[0] must be a bare tool name (lake/lean/turbo-lean), not '{argv0}'"
  if argv0 != "lake" && argv0 != "lean" && argv0 != "turbo-lean" then
    throw s!"command '{argv0}' is not allowed; argv[0] must be lake, lean, or turbo-lean"
  if argv0 == "lake" then
    let v1? := if h : 1 < cmdArr.size then some cmdArr[1] else none
    let v2? := if h : 2 < cmdArr.size then some cmdArr[2] else none
    let ok := v1? == some "build" || v1? == some "test" || v1? == some "check" ||
              (v1? == some "env" && v2? == some "lean")
    if !ok then
      throw "lake command must use build, test, check, or fixed 'env lean'"
  else if argv0 == "turbo-lean" then
    validateTurboLeanArgs (cmdArr.extract 1 cmdArr.size)
  if let some envPairs := (payload.field? "env") >>= JVal.asObj? then
    for (k, _) in envPairs do
      if isReservedNodeEnvKey k then
        throw s!"env key '{k}' is reserved by the node runner"
      if !allowlist.contains k then
        throw s!"env key '{k}' is not in the node allowlist"
  if let some arts := payload.fieldArr? "artifacts" then
    for a in arts do
      let some pat := a.asStr? | throw "artifact pattern must be a string"
      if pat.isEmpty || pat.startsWith "/" || pat.contains '\\' ||
         (pat.splitOn "/").any (fun seg => seg.isEmpty || seg == "." || seg == "..") then
        throw s!"unsafe artifact pattern '{pat}'"

/-- Verify every existing ancestor component of `relPath`'s parent below `checkoutRoot` is a real
    (non-symlink) directory before creating directories, deleting files, or writing bundle overlays. -/
private def requireSafeBundleParent (checkoutRoot : System.FilePath) (relPath label : String) :
    IO (Except String System.FilePath) := do
  let rst ← statPath checkoutRoot.toString
  if !rst.exists_ || rst.isSymlink || !rst.isDir then
    return .error s!"{label} root must be a real directory"
  let segs := relPath.splitOn "/"
  if segs.isEmpty || segs.any (fun s => s.isEmpty || s == "." || s == "..") then
    return .error s!"{label} contains invalid path component: {relPath}"
  let parentSegs := segs.dropLast
  let mut cur := checkoutRoot
  for seg in parentSegs do
    cur := cur / seg
    let st ← statPath cur.toString
    if st.exists_ then
      if st.isSymlink then
        return .error s!"{label} must not traverse a symlink: {cur}"
      if !st.isDir then
        return .error s!"{label} ancestor is not a directory: {cur}"
  return .ok cur

/-- Verify `source.base_tree_sha` (`HEAD^{tree}`) matches the checked-out Git root tree (`src/node/lean.rs:929-956`). -/
def verifyBaseTree (src : JVal) (checkout : System.FilePath) : IO (Except String Unit) := do
  let expected := ((src.fieldStr? "base_tree_sha").getD "").trimAscii.toString
  if expected.isEmpty then
    return .ok ()
  let commit := (src.fieldStr? "commit").getD ""
  let res ← (IO.Process.output {
    cmd := "git"
    args := #["rev-parse", "HEAD^{tree}"]
    cwd := some checkout.toString
  }).toBaseIO
  match res with
  | .error _ => return .error "could not resolve the checked-out tree for base tree verification"
  | .ok out =>
    if out.exitCode != 0 then
      return .error "could not resolve the checked-out tree for base tree verification"
    let actual := out.stdout.trimAscii.toString.toLower
    if actual != expected.toLower then
      return .error s!"BASE_TREE_MISMATCH: submitter pinned tree {expected} but commit {commit} checks out tree {actual}"
    return .ok ()

/-- Quarantine any Git-tracked `turbo-lean.toml`, `.turbo-lean.toml`, or `.turbo-lean/` inside `root`
    (`src/node/lean.rs:2242-2276`) without following directory symlinks. -/
def quarantineCheckoutTurboLeanConfigs (root : System.FilePath) : IO (Except String Nat) := do
  let mut removed : Nat := 0
  let mut stack : Array System.FilePath := #[root]
  while h : 0 < stack.size do
    let dir := stack[stack.size - 1]
    stack := stack.pop
    let .ok entries ← dir.readDir |>.toBaseIO
      | continue
    for e in entries do
      let name := e.fileName
      if name == ".git" || name == ".lake" then
        continue
      let st ← statPath e.path.toString
      if name == "turbo-lean.toml" || name == ".turbo-lean.toml" || name == ".turbo-lean" then
        if st.isDir && !st.isSymlink then
          let _ ← IO.Process.output { cmd := "rm", args := #["-rf", e.path.toString] }
        else
          try IO.FS.removeFile e.path catch _ => pure ()
        removed := removed + 1
      else if st.isDir && !st.isSymlink then
        stack := stack.push e.path
  return .ok removed

/-- Materialize an isolated per-job `lean_build` checkout under
    `<work_dir>/checkouts/<repo_hash16>/jobs/<job_id>` (seeding shared base commits into
    `<work_dir>/checkouts/<repo_hash16>/seed-<commit>`), so concurrent builds of the same
    repository/commit never reset, clean, or overwrite each other's working tree. -/
def materializeLeanCheckout
    (workDir : String) (src : JVal) (logPath : String) (jobId? : Option String := none) :
    IO (Except String String) := do
  let repo := ((src.fieldStr? "repo").getD "").trimAscii.toString
  let commit := (src.fieldStr? "commit").getD ""
  let repoHash16 := (bytesToHexLower (sha256Bytes repo.toUTF8)).take 16 |>.toString
  let shardDir := System.FilePath.mk workDir / "checkouts" / repoHash16
  IO.FS.createDirAll shardDir
  let jobSub ← match jobId? with
    | some jid => pure jid
    | none => newUuidV4
  let jobsRoot := shardDir / "jobs"
  IO.FS.createDirAll jobsRoot
  let dest := jobsRoot / jobSub
  let dstSt ← statPath dest.toString
  if dstSt.isSymlink then
    return .error "job checkout path must not be a symlink"
  if dstSt.exists_ then
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
  let bundle? := (src.field? "bundle").filter (· != .null)
  let isComplete := bundle?.bind (·.fieldBool? "complete") |>.getD false
  if isComplete then
    IO.FS.createDirAll dest
  else
    let seedDir := shardDir / s!"seed-{commit}"
    let seedLock := shardDir / s!".seed-{commit}.lock"
    let mut lockFd : UInt32 := 0xFFFFFFFF
    for _ in [0:600] do
      if lockFd == 0xFFFFFFFF then
        let fd ← flockExclusiveNb seedLock.toString
        if fd != 0xFFFFFFFF then
          lockFd := fd
        else
          IO.sleep 100
    if lockFd == 0xFFFFFFFF then
      return .error "timed out acquiring seed checkout lock"
    let heldLockFd := lockFd
    try
      if !(← seedDir.isDir) then
        let nonce ← newUuidV4
        let tmp := shardDir / s!".tmp-{commit}-{nonce}"
        IO.FS.createDirAll tmp
        if let some arch := (src.field? "archive").filter (· != .null) then
          match validateSourceArchive commit arch with
          | .error e =>
            let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmp.toString] }
            return .error e
          | .ok packBytes =>
            let packFile := shardDir / s!".pack-{nonce}.pack"
            IO.FS.writeBinFile packFile packBytes
            let r1 ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some tmp.toString }
            let r2 ← IO.Process.output {
              cmd := "sh"
              args := #["-c", s!"git index-pack --stdin < {shellSingleQuote packFile.toString}"]
              cwd := some tmp.toString
            }
            try IO.FS.removeFile packFile catch _ => pure ()
            IO.FS.writeFile (tmp / ".git" / "shallow") s!"{commit}\n"
            let r3 ← IO.Process.output {
              cmd := "git", args := #["checkout", "--quiet", "--detach", commit], cwd := some tmp.toString
            }
            if r1.exitCode != 0 || r2.exitCode != 0 || r3.exitCode != 0 then
              let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmp.toString] }
              return .error s!"source archive git import failed: {r2.stderr} {r3.stderr}"
        else
          let fetchEnv : Array (String × Option String) ← do
            match ← IO.getEnv "SANDBOXED_NODE_GIT_SSH_KEY" with
            | some raw =>
              let key := raw.trimAscii.toString
              if key.isEmpty then pure #[]
              else pure #[("GIT_SSH_COMMAND", some s!"ssh -i {shellSingleQuote key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")]
            | none => pure #[]
          let r1 ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some tmp.toString }
          let r2 ← IO.Process.output {
            cmd := "git"
            args := #["-c", "protocol.file.allow=never", "fetch", "--depth", "1", "--no-tags", repo, commit]
            cwd := some tmp.toString
            env := fetchEnv
          }
          let r3 ← IO.Process.output {
            cmd := "git", args := #["checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd := some tmp.toString
          }
          if r1.exitCode != 0 || r2.exitCode != 0 || r3.exitCode != 0 then
            let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmp.toString] }
            let _ ← IO.FS.writeFile logPath s!"git fetch failed: {r2.stderr}\n"
            return .error s!"git fetch failed for {repo}@{commit}: {r2.stderr.trimAscii}"
        if let .error btErr ← verifyBaseTree src tmp then
          let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmp.toString] }
          return .error btErr
        try
          IO.FS.rename tmp seedDir
        catch e =>
          let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmp.toString] }
          if !(← seedDir.isDir) then
            return .error s!"failed finalizing seed checkout: {e}"
      if let .error btErr ← verifyBaseTree src seedDir then
        return .error btErr
      let cpRes ← IO.Process.output { cmd := "cp", args := #["-a", seedDir.toString, dest.toString] }
      if cpRes.exitCode != 0 then
        return .error s!"failed cloning isolated job checkout: {cpRes.stderr.trimAscii}"
    finally
      closeFdRaw (Int32.ofBitVec (BitVec.ofNat 32 heldLockFd.toNat))
  if let some bnd := bundle? then
    let deleted := ((bnd.fieldArr? "deleted_paths").getD #[]).filterMap JVal.asStr?
    for dp in deleted do
      if bundlePathIsSafe dp then
        match ← requireSafeBundleParent dest dp "source bundle deletion" with
        | .error e =>
          let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
          return .error e
        | .ok _ =>
          let target := dest / dp
          let st ← statPath target.toString
          if st.exists_ then
            if st.isReg || st.isSymlink then
              try IO.FS.removeFile target catch _ => pure ()
            else
              let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
              return .error s!"source bundle deletion must target a file: {dp}"
    for f in (bnd.fieldArr? "files").getD #[] do
      if let (some fp, some b64) := (f.fieldStr? "path", f.fieldStr? "data_base64") then
        if bundlePathIsSafe fp then
          let some decoded := base64Decode? b64
            | let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
              return .error s!"invalid bundle base64 for '{fp}'"
          let par ← match ← requireSafeBundleParent dest fp "source bundle destination" with
            | .ok p => pure p
            | .error e =>
              let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
              return .error e
          IO.FS.createDirAll par
          let target := dest / fp
          let tst ← statPath target.toString
          if tst.isSymlink then
            let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
            return .error s!"refusing symlinked target in source bundle: {fp}"
          if tst.exists_ && tst.isDir then
            let _ ← IO.Process.output { cmd := "rm", args := #["-rf", dest.toString] }
            return .error s!"source bundle destination is a directory: {fp}"
          IO.FS.writeBinFile target decoded
          if f.fieldBool? "executable" == some true then
            let _ ← chmod target.toString 0o755
  discard <| quarantineCheckoutTurboLeanConfigs dest
  return .ok dest.toString

/-- Build confined `lean_build` environment (`cache_env_for_repo` + concurrency budget + allowlisted env). -/
def buildLeanJobEnv
    (workDir repo : String) (cpuTotal capacity : UInt32)
    (allowlist : Array String) (usesLakeFanout : Bool)
    (payloadEnv : Array (String × JVal)) : IO (Array (String × String)) := do
  let root := System.FilePath.mk workDir
  let caches := root / "caches"
  let elan ← do
    let wElan := caches / "elan"
    if ← (wElan / "toolchains").isDir then pure wElan
    else if let some envElan ← getEnvNonEmpty "ELAN_HOME" then
      let p := System.FilePath.mk envElan
      if ← (p / "toolchains").isDir then pure p else pure wElan
    else if ← (System.FilePath.mk "/opt/orb/elan/toolchains").isDir then
      pure (System.FilePath.mk "/opt/orb/elan")
    else if let some h ← getEnvNonEmpty "HOME" then
      let p := System.FilePath.mk h / ".elan"
      if ← (p / "toolchains").isDir then pure p else pure wElan
    else pure wElan
  let repoHash16 := (bytesToHexLower (sha256Bytes repo.toUTF8)).take 16 |>.toString
  let tlHome := caches / "turbo-lean" / repoHash16
  let tlStage := caches / "turbo-lean-staging" / repoHash16 / "base"
  let xdg := caches / "xdg"
  let home := caches / "home"
  IO.FS.createDirAll (caches / "elan")
  IO.FS.createDirAll (tlHome / "audit-cache")
  if let some p := tlStage.parent then IO.FS.createDirAll p
  IO.FS.createDirAll xdg
  IO.FS.createDirAll home
  let servicePath := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  let mut parts : Array String := #[(elan / "bin").toString]
  for d in (servicePath.splitOn ":").filter (·.startsWith "/") do
    if !parts.contains d then parts := parts.push d
  for fb in ["/usr/local/bin", "/usr/bin", "/bin"] do
    if !parts.contains fb then parts := parts.push fb
  let budget := max 1 (cpuTotal.toNat / max 1 capacity.toNat)
  let defaultLakeJobs := if usesLakeFanout then min 4 budget else 1
  let defaultThreads := max 1 (budget / max 1 defaultLakeJobs)
  let mut kvs : Array (String × String) := #[
    ("ELAN_HOME", elan.toString),
    ("TURBO_LEAN_HOME", tlHome.toString),
    ("TURBO_LEAN_STAGING_DIR", tlStage.toString),
    ("TURBO_LEAN_NO_DAEMON", "1"),
    ("TURBO_LEAN_NO_WORKTREE_LINK", "1"),
    ("TURBO_LEAN_TELEMETRY", "off"),
    ("LEAN_NATIVE_TELEMETRY", "off"),
    ("TURBO_LEAN_TRUST_PROJECT_TELEMETRY", "0"),
    ("TURBO_LEAN_DISABLE_ACCEL", "all"),
    ("TURBO_LEAN_ACCELERATORS_CONFIG", "{\"enabled\":false,\"default_budget_ms\":0,\"disabled_builtins\":[],\"external\":[]}"),
    ("TURBO_LEAN_AUDIT_SPEC_CONFIG", "{\"policy\":\"default\"}"),
    ("TURBO_LEAN_AUDIT_CACHE_DIR", (tlHome / "audit-cache").toString),
    ("TURBO_LEAN_ALLOWED_AXIOMS", ""),
    ("TURBO_LEAN_ALLOWED_CSIMP", ""),
    ("TURBO_LEAN_USER_CONFIG", "/dev/null"),
    ("SANDBOXED_REMOTE_EXECUTION", "1"),
    ("SANDBOXED_TELEMETRY_BATCH_ONLY", "1"),
    ("XDG_CACHE_HOME", xdg.toString),
    ("HOME", home.toString),
    ("LANG", "C.UTF-8"),
    ("PATH", String.intercalate ":" parts.toList),
    ("LAKE_JOBS", toString defaultLakeJobs),
    ("LEAN_NUM_THREADS", toString defaultThreads)
  ]
  for (k, v) in payloadEnv do
    if allowlist.contains k && !isReservedNodeEnvKey k then
      if let some sv := v.asStr? then
        kvs := (kvs.filter (fun (ek, _) => ek != k)).push (k, sv)
  return kvs

/-! ### Symlink-Free Single-Segment `*` Glob Artifact Collector -/

def segmentMatchesGlob (name pattern : String) : Bool := Id.run do
  let parts := pattern.splitOn "*"
  if parts.length == 1 then return name == pattern
  let pArr := parts.toArray
  let first := pArr[0]!
  if !name.startsWith first then return false
  let mut rest := (name.drop first.length).toString
  if pArr.size > 2 then
    for i in [1 : pArr.size - 1] do
      let mid := pArr[i]!
      if !mid.isEmpty then
        let split := rest.splitOn mid
        if split.length < 2 then return false
        rest := String.intercalate mid split.tail!
  let last := pArr[pArr.size - 1]!
  return rest.length >= last.length && rest.endsWith last

def isSymlinkFreePath (root : System.FilePath) (relSegs : List String) : IO (Option StatFlags) := do
  let rst ← statPath root.toString
  if !rst.exists_ || rst.isSymlink then return none
  let mut cur := root
  let mut lastSt := rst
  for seg in relSegs do
    cur := cur / seg
    let st ← statPath cur.toString
    if !st.exists_ || st.isSymlink then return none
    lastSt := st
  return some lastSt

def collectArtifactsConfined (rootDir : String) (patterns : Array String) : IO (Array ArtifactEntry) := do
  let root := System.FilePath.mk rootDir
  let mut matchedRels : Array String := #[]
  for pat in patterns do
    if pat.isEmpty || pat.startsWith "/" || pat.contains '\\' then continue
    let segs := pat.splitOn "/"
    if segs.any (fun s => s.isEmpty || s == "." || s == "..") then continue
    let mut candidates : Array (List String) := #[[]]
    for seg in segs do
      let mut next : Array (List String) := #[]
      for rel in candidates do
        if seg.contains '*' then
          if let some dst ← isSymlinkFreePath root rel then
            if dst.isDir then
              let dirPath := rel.foldl (fun p s => p / s) root
              if let .ok entries ← dirPath.readDir |>.toBaseIO then
                for e in entries do
                  if segmentMatchesGlob e.fileName seg then
                    next := next.push (rel ++ [e.fileName])
        else
          next := next.push (rel ++ [seg])
      candidates := next
    for rel in candidates do
      if let some fst ← isSymlinkFreePath root rel then
        if fst.isReg then
          let relStr := String.intercalate "/" rel
          if !matchedRels.contains relStr then
            matchedRels := matchedRels.push relStr
  let sorted := matchedRels.qsort (· < ·)
  let mut out : Array ArtifactEntry := #[]
  for rel in sorted do
    let full := root / rel
    let fst ← statPath full.toString
    if fst.exists_ && !fst.isSymlink && fst.isReg then
      if let .ok md ← full.metadata |>.toBaseIO then
        if md.byteSize ≤ maxSingleArtifactBytes then
          if md.byteSize ≤ 4 * 1024 * 1024 then
            if let .ok bytes ← IO.FS.readBinFile full |>.toBaseIO then
              let sha := bytesToHexLower (sha256Bytes bytes)
              out := out.push { path := rel, sha256 := sha, sizeBytes := bytes.size.toUInt64 }
          else
            if let .ok outSum ← (IO.Process.output { cmd := "sha256sum", args := #[full.toString] }).toBaseIO then
              if outSum.exitCode == 0 then
                let hex := ((outSum.stdout.splitOn " ").headD "").trimAscii.toString.toLower
                let fstAfter ← statPath full.toString
                if let .ok mdAfter ← full.metadata |>.toBaseIO then
                  if hex.length == 64 && fstAfter.exists_ && !fstAfter.isSymlink &&
                     mdAfter.byteSize == md.byteSize && mdAfter.modified == md.modified then
                    out := out.push { path := rel, sha256 := hex, sizeBytes := md.byteSize }
  return out

def listCachedToolchains (workDir : String) : IO (Array String) := do
  let dir := System.FilePath.mk workDir / "caches" / "elan" / "toolchains"
  if !(← dir.isDir) then return #[]
  let .ok entries ← dir.readDir |>.toBaseIO | return #[]
  let mut names : Array String := #[]
  for e in entries do
    if ← e.path.isDir then
      names := names.push e.fileName
  return names.qsort (· < ·)

end OrbNode.LeanBuild
