/-
  OrbNode.Main: `sandboxed-node` Native Lean 4 Worker Daemon Entrypoint
  - `(no args)`: Optional dial-out enrollment (`OrbNode.Dial`) + `:3088` HTTP/1.1 worker daemon.
  - `reload [--unit NAME]`: Validates `sandboxed-node*` unit name and invokes `systemctl reload`.
  - `--sandboxed-scope-exec-cleared-env <KEY...> -- <program> <args...>`: Cleared-env scope trampoline.
  - `opencode-acp [--model M] [--effort E] [--session S] [--plan]`: one OpenCode turn over ACP,
    prompt on stdin, streamed `session/update` lines on stdout (`--probe` checks support).
-/
import OrbNode.Posix
import OrbNode.Store
import OrbNode.Dial
import OrbNode.Runner
import OrbNode.Server
import OrbBin.ClaudeControl

namespace OrbNode.Main

open OrbNode.Store
open OrbNode.Runner
open OrbNode.Server

private def isAllowedUnitChar (c : Char) : Bool :=
  c.isAlphanum || c == '-' || c == '_' || c == '@' || c == '.'

def validateReloadUnit (name : String) : Bool :=
  !name.isEmpty && name.startsWith "sandboxed-node" && name.toList.all isAllowedUnitChar

private def parseReloadArgs : List String → Option String
  | [] => some "sandboxed-node"
  | ["--unit", u] => if validateReloadUnit u then some u else none
  | [arg] =>
    if arg.startsWith "--unit=" then
      let u := (arg.drop 7).toString
      if validateReloadUnit u then some u else none
    else none
  | _ => none

private def runClearedEnvTrampoline (rest : List String) : IO UInt32 := do
  let rec splitDashDash (acc : Array String) : List String → Option (Array String × List String)
    | [] => none
    | "--" :: cmd => some (acc, cmd)
    | k :: ks => splitDashDash (acc.push k) ks
  let some (keepKeys, prog :: progArgs) := splitDashDash #[] rest
    | IO.eprintln "invalid --sandboxed-scope-exec-cleared-env arguments"; return 2
  let mut envArgs : Array String := #["-i"]
  for k in keepKeys do
    if let some v ← IO.getEnv k then
      envArgs := envArgs.push s!"{k}={v}"
  envArgs := envArgs.push prog
  for a in progArgs do
    envArgs := envArgs.push a
  let child ← IO.Process.spawn {
    cmd := "env"
    args := envArgs
  }
  child.wait

/-- Parse `opencode-acp` flags into a turn (prompt filled in later). -/
def parseOpenCodeAcpArgs (cwd : String) : List String → Option OrbBin.ClaudeControl.OpenCodeAcpTurn
  | [] => some { cwd := cwd, prompt := "" }
  | "--plan" :: rest => (parseOpenCodeAcpArgs cwd rest).map ({ · with plan := true })
  | "--model" :: v :: rest => (parseOpenCodeAcpArgs cwd rest).map ({ · with model? := some v })
  | "--effort" :: v :: rest => (parseOpenCodeAcpArgs cwd rest).map ({ · with effort? := some v })
  | "--session" :: v :: rest => (parseOpenCodeAcpArgs cwd rest).map ({ · with sessionId? := some v })
  | _ => none

private def runOpenCodeAcp (rest : List String) : IO UInt32 := do
  if rest == ["--probe"] then
    IO.println "opencode-acp 1"
    return 0
  let cwd := (← IO.currentDir).toString
  let some turn := parseOpenCodeAcpArgs cwd rest
    | IO.eprintln "usage: sandboxed-node opencode-acp [--model M] [--effort E] [--session S] [--plan] < prompt"; return 2
  let prompt ← (← IO.getStdin).readToEnd
  let env := (← OrbBin.PosixExt.currentEnvPairs).map fun (k, v) => s!"{k}={v}"
  let out ← IO.getStdout
  OrbBin.ClaudeControl.runOpenCodeAcpTurn "opencode" env { turn with prompt := prompt }
    (fun ln => do out.putStrLn ln; out.flush)

def runCli (args : List String) : IO UInt32 := do
  match args with
  | "opencode-acp" :: rest =>
    runOpenCodeAcp rest
  | "--version" :: _ | "-V" :: _ =>
    IO.println "sandboxed-node 1.3.0-lean4"
    return 0
  | "reload" :: rest =>
    let some unitBase := parseReloadArgs rest
      | IO.eprintln "invalid reload unit (must start with sandboxed-node)"; return 2
    let unitFull := if unitBase.endsWith ".service" then unitBase else s!"{unitBase}.service"
    let child ← IO.Process.spawn { cmd := "systemctl", args := #["reload", unitFull] }
    let code ← child.wait
    if code == 0 then
      IO.println s!"reloaded {unitFull} (running jobs are not restarted)"
    return code
  | "--sandboxed-scope-exec-cleared-env" :: rest =>
    runClearedEnvTrampoline rest
  | _ =>
    let mut cfg ← loadConfigFromEnv
    let uid ← OrbNode.Posix.geteuid
    if uid == 0 && !cfg.allowRoot then
      IO.eprintln "refusing to run sandboxed-node as UID 0 without SANDBOXED_NODE_ALLOW_ROOT=1"
      return 1
    let dialCred? ← match ← OrbNode.Dial.enrollFromEnv with
      | .ok c? => pure c?
      | .error err =>
        IO.eprintln s!"dial-out enrollment failed: {err}"
        return 1
    if let some cred := dialCred? then
      -- Dial-out enrollment (`SANDBOXED_NODE_DIAL_CORE_URL` + `SANDBOXED_NODE_MANAGED_ID`) always
      -- enrolls an ephemeral single-tenant managed guest (`orbnode` with `NoNewPrivileges=true`
      -- and no `orb-privd` socket); static/colocated multi-tenant workers never use dial-out.
      cfg := {
        cfg with
        token := cred.nodeToken
        nodeId := if cred.nodeId.isEmpty then cfg.nodeId else cred.nodeId
        managedSandbox := true
      }
    if cfg.token.isEmpty then
      IO.eprintln "SANDBOXED_NODE_TOKEN is required"
      return 1
    match ← openLedger cfg.workDir with
    | .error msg =>
      IO.eprintln s!"failed to open OrbNode ledger: {msg}"
      return 1
    | .ok ledger =>
      reapPreviousScopesOnStart cfg
      let rt : NodeRuntime := { cfg := cfg, ledger := ledger }
      runServerLoop rt dialCred?

def main (args : List String) : IO UInt32 :=
  runCli args

end OrbNode.Main
