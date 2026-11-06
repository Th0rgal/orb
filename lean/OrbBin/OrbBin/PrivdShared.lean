/-
  OrbBin.PrivdShared: Shared Policy, Scope Classification, Environment Confinement, and
  Direct `Orb.Kernel.privdCommandStep` Integration for `orb-privd` and `orb-sudo` (`0 import Lean`).
-/
import Orb.Kernel
import OrbBin.PosixExt
import OrbBin.Json

namespace OrbBin.PrivdShared

open OrbBin.PosixExt
open OrbBin.Json

def defaultPrivdSocket : String := "/run/orb-privd.sock"

def trustedExecDirs : Array String := #[
  "/bin", "/usr/bin", "/sbin", "/usr/sbin"
]

def trustedExecPath : String := "/usr/sbin:/usr/bin:/sbin:/bin"

def opsReadBinaries : Array String := #[
  "journalctl", "systemctl", "docker", "nft", "ss", "ps", "df", "du",
  "free", "uptime", "uname", "cat", "head", "tail", "ls", "stat",
  "grep", "mdadm", "lsblk", "smartctl"
]

def journalctlReadOpts : Array String := #[
  "-u", "--unit", "-n", "--lines", "--since", "--until", "-p", "--priority",
  "-b", "--boot", "--no-pager", "-o", "--output", "-k", "--dmesg", "-r", "--reverse",
  "-x", "--catalog", "-e", "--pager-end", "--list-boots", "--disk-usage", "-g", "--grep"
]

def mdadmReadOpts : Array String := #[
  "--detail", "-D", "--examine", "-E", "--query", "-Q",
  "--scan", "-s", "--verbose", "-v", "--brief", "-b"
]

def smartctlReadOpts : Array String := #[
  "-a", "--all", "-x", "--xall", "-i", "--info", "-H", "--health",
  "-A", "--attributes", "-d", "--device", "-j", "--json"
]

def unsafeEnvKeys : Array String := #[
  "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "LD_DEBUG", "DYLD_INSERT_LIBRARIES",
  "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "NODE_OPTIONS", "RUBYLIB", "RUBYOPT",
  "PERL5LIB", "PERL5OPT", "BASH_ENV", "ENV", "PROMPT_COMMAND", "IFS", "PATH",
  "GCONV_PATH", "LOCPATH", "ORB_CORE_API_URL", "ORB_CORE_API_TOKEN"
]

def allowedHarnesses : Array String := #[
  "claude", "codex", "opencode", "grok", "vibe"
]

def normalizeHarnessName? (raw : String) : Option String :=
  let s := raw.trimAscii.toString.toLower
  let norm := if s == "vibe-acp" then "vibe" else s
  if allowedHarnesses.contains norm then some norm else none

/-- Strict `MAJOR.MINOR.PATCH` numeric semver validation (`\d+\.\d+\.\d+`). -/
def isStrictSemver (v : String) : Bool :=
  match v.splitOn "." with
  | [maj, min, pat] =>
    !maj.isEmpty && maj.all Char.isDigit &&
    !min.isEmpty && min.all Char.isDigit &&
    !pat.isEmpty && pat.all Char.isDigit
  | _ => false

private def containsSubstr (s sub : String) : Bool :=
  (s.splitOn sub).length > 1

def isSafeReadPositional (s : String) : Bool :=
  !s.isEmpty && s.all fun c =>
    c.isAlphanum || c == '_' || c == '.' || c == ',' || c == '=' || c == '-'

def isReadOnlyArg (prog arg : String) : Bool :=
  if !arg.startsWith "-" then
    prog == "journalctl" || arg.startsWith "/dev/" || isSafeReadPositional arg
  else
    let opt := (arg.splitOn "=").head?.getD arg
    if prog == "journalctl" then journalctlReadOpts.contains opt
    else if prog == "mdadm" then mdadmReadOpts.contains opt
    else if prog == "smartctl" then smartctlReadOpts.contains opt
    else true

def hasShellMetacharOrBypass (scopeStr : String) (argv : Array String) : UInt8 := Id.run do
  if argv.isEmpty then return 1
  let isRootExec := scopeStr == "root_exec" || scopeStr == "host_admin"
  for tok in argv do
    if tok.isEmpty then return 1
    if containsSubstr tok "$(" then return 1
    for c in tok.toList do
      if c == '\x00' || c == '\n' || c == '\r' || c == ';' || c == '|' || c == '&' || c == '`' then
        return 1
      if !isRootExec && (c == '>' || c == '<') then
        return 1
  return 0

def isTrustedExecutableToken (rawExe : String) : IO Bool := do
  if rawExe.isEmpty || rawExe == "." || rawExe == ".." then return false
  if !(rawExe.any (· == '/')) && !(rawExe.any (· == '\\')) then
    return true
  if (rawExe.any (· == '\\')) || rawExe.startsWith "./" || rawExe.startsWith "../" ||
     containsSubstr rawExe "/./" || containsSubstr rawExe "/../" || !rawExe.startsWith "/" then
    return false
  let dir := ((System.FilePath.mk rawExe).parent.map toString).getD ""
  if !trustedExecDirs.contains dir then return false
  let st ← statPath rawExe
  if st.exists_ && st.isSymlink then
    try
      let real ← IO.FS.realPath (System.FilePath.mk rawExe)
      let realDir := (real.parent.map toString).getD ""
      if !trustedExecDirs.contains realDir then return false
    catch _ =>
      return false
  return true

def hasCwdTraversalOrSymlink (cwd? : Option String) : IO Bool := do
  match cwd? with
  | none => return false
  | some raw =>
    let s := raw.trimAscii.toString
    if s.isEmpty then return false
    if !s.startsWith "/" then return true
    let parts := s.splitOn "/"
    if parts.any (· == "..") then return true
    let st ← statPath s
    if st.exists_ && st.isSymlink then return true
    return false

def hasArgvTraversal (argv : Array String) : Bool :=
  argv.any fun tok =>
    tok == ".." || tok.startsWith "../" || tok.endsWith "/.." || containsSubstr tok "/../"

def hasUnsafeClientEnv (envPairs : Array (String × String)) (argv : Array String := #[]) : UInt8 := Id.run do
  for (k, v) in envPairs do
    let ku := k.trimAscii.toString.toUpper
    if !isSafeEnvIdent k then return 1
    if unsafeEnvKeys.any (· == ku) then return 1
    if ku.startsWith "LD_" || ku.startsWith "DYLD_" then return 1
    if v.any (· == '\x00') then return 1
  for tok in argv do
    if tok.any (· == '=') then
      let lhs := ((tok.splitOn "=").head?.getD "").trimAscii.toString.toUpper
      if unsafeEnvKeys.any (· == lhs) || lhs.startsWith "LD_" || lhs.startsWith "DYLD_" then
        return 1
  return 0

/-- Map textual scope (`ops_read` = 0, `service_deploy` = 1, `root_exec`/`host_admin` = 2) to `grantScope`. -/
def parseGrantScope? (s : String) : Option UInt8 :=
  match s.trimAscii.toString with
  | "ops_read" => some 0
  | "service_deploy" => some 1
  | "root_exec" | "host_admin" => some 2
  | _ => none

/-- Full confinement check matching `check_scope_restrictions` + `Orb.Kernel.privdCommandStep` (`1793 | 1794 | 1795`). -/
def checkScopeRestrictions
    (scopeStr : String)
    (allowedUnits : Array String)
    (argv : Array String)
    (cwd? : Option String := none)
    (envPairs : Array (String × String) := #[])
    (requireForceCmd : Bool := false) : IO (Except String UInt64) := do
  if argv.isEmpty then
    return .error "Empty command argv"
  let gs : UInt8 := (parseGrantScope? scopeStr).getD 255
  let unsafeEnv := hasUnsafeClientEnv envPairs argv
  let cwdBad ← hasCwdTraversalOrSymlink cwd?
  let argvBad := hasArgvTraversal argv
  let exeTrusted ← isTrustedExecutableToken argv[0]!
  let pathTrav : UInt8 := if cwdBad || argvBad || !exeTrusted then 1 else 0
  let metaByp := hasShellMetacharOrBypass scopeStr argv
  let reqForce : UInt8 := if requireForceCmd then 1 else 0
  if !exeTrusted then
    let _ := Orb.Kernel.privdCommandStep 1 gs 5 0 metaByp 1 unsafeEnv reqForce
    return .error s!"Untrusted executable path '{argv[0]!}' rejected by orb_privd_command_step confinement gate"
  let prog := (System.FilePath.mk argv[0]!).fileName.getD argv[0]!
  let rest := argv.extract 1 argv.size
  let mut cmdClass : UInt8 := 0
  let mut unitMatches : UInt8 := 0
  if scopeStr == "ops_read" then
    if !opsReadBinaries.contains prog then
      return .error s!"ops_read grant does not allow binary '{prog}'"
    if prog == "systemctl" then
      if rest.isEmpty || !(["status", "show", "list-units", "is-active", "is-failed"].contains rest[0]!) then
        return .error "ops_read grant only allows read-only systemctl subcommands"
    if prog == "docker" then
      if rest.isEmpty || !(["ps", "logs", "inspect", "stats", "info", "version"].contains rest[0]!) then
        return .error "ops_read grant only allows read-only docker subcommands"
    if prog == "nft" && rest != #["list", "ruleset"] then
      return .error "ops_read grant only allows 'nft list ruleset'"
    if prog == "mdadm" then
      if rest.isEmpty || !(["--detail", "-D", "--examine", "-E", "--query", "-Q"].contains rest[0]!) then
        return .error "ops_read grant only allows 'mdadm --detail/--examine/--query'"
    if ["journalctl", "mdadm", "smartctl"].contains prog then
      if !(rest.all (isReadOnlyArg prog)) then
        return .error s!"ops_read grant only allows read-only {prog} options"
    cmdClass := 1
    unitMatches := 1
  else if scopeStr == "service_deploy" then
    if prog == "systemctl" then
      if rest.isEmpty || !(["restart", "reload", "status", "start", "stop", "daemon-reload"].contains rest[0]!) then
        return .error "service_deploy grant only allows systemctl service lifecycle subcommands"
      if rest.any (·.startsWith "-") then
        return .error "service_deploy grant does not allow systemctl option flags"
      if rest[0]! == "daemon-reload" then
        if rest.size != 1 then
          return .error "systemctl daemon-reload does not take target unit arguments"
        cmdClass := 3
        unitMatches := 1
      else
        let targets := rest.extract 1 rest.size
        if targets.isEmpty then
          return .error s!"systemctl {rest[0]!} requires a target unit"
        if !allowedUnits.isEmpty then
          for target in targets do
            let okUnit := allowedUnits.any fun u =>
              u == "*" || target == u || target == (u ++ ".service") || (target ++ ".service") == u
            if !okUnit then
              return .error s!"service_deploy grant restricted to allowed unit (rejected '{target}')"
        cmdClass := 2
        unitMatches := 1
    else if prog == "nginx" then
      if rest != #["-t"] && rest != #["-s", "reload"] then
        return .error "service_deploy grant only allows 'nginx -t' or 'nginx -s reload'"
      cmdClass := 3
      unitMatches := 1
    else
      return .error s!"service_deploy grant does not allow arbitrary binary '{prog}'; request root_exec if needed"
  else if scopeStr == "root_exec" || scopeStr == "host_admin" then
    cmdClass := 4
    unitMatches := 1
  else
    return .error s!"Unknown privilege scope '{scopeStr}'"

  let packed := Orb.Kernel.privdCommandStep 1 gs cmdClass unitMatches metaByp pathTrav unsafeEnv reqForce
  let lo32 := packed &&& 0xFFFFFFFF
  if (lo32 &&& 256) == 0 || (lo32 &&& 1536) != 1536 then
    return .error "Rejected by orb_privd_command_step confinement gate"
  return .ok packed

def resolveTrustedBinary? (bin : String) : IO (Option String) := do
  if bin.any (· == '/') then
    if (← isTrustedExecutableToken bin) then
      let st ← statPath bin
      if st.exists_ && st.isReg then return some bin
    return none
  for dir in trustedExecDirs do
    let cand := s!"{dir}/{bin}"
    let st ← statPath cand
    if st.exists_ && st.isReg then
      return some cand
  return none

end OrbBin.PrivdShared
