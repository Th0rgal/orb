/-
  OrbCore.CliMain: Production entrypoint for `sandboxed-sh` (`0 import Lean`, `0 sorryAx`).
  Supports:
  - `sandboxed-sh` (default HTTP/WS Core server on `$HOST:$PORT`)
  - `sandboxed-sh deploy --service <unit>` (validated systemd unit deployment)
  - `sandboxed-sh --harness-contract-tests` (9 CLI/SSE/ACP parser contract tests)
  - `sandboxed-sh --version` / `-V`
-/
import OrbCore.Control
import OrbCore.Managed
import OrbCore.Harness
import OrbCore.Store
import OrbCore.R7Core

namespace OrbCore.CliMain

open OrbCore.Control
open OrbCore.Managed
open OrbCore.Harness
open OrbCore.Store
open OrbCore.R7Core

private def findFlagVal? (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: rest =>
    if a == flag then rest.head?
    else if a.startsWith (flag ++ "=") then some (a.drop (flag.length + 1)).toString
    else findFlagVal? rest flag

def runDeploySubcommand (args : List String) : IO UInt32 := do
  let rawUnit := (findFlagVal? args "--service").getD "sandboxed-sh"
  match validateDeployServiceUnit rawUnit with
  | .error e =>
    IO.eprintln s!"[sandboxed-sh deploy] ERROR: {e}"
    return 1
  | .ok unitName =>
    let dryRun := args.contains "--dry-run"
    let forceFlag := args.contains "--force"
    let cfg ← loadConfigFromEnv
    let normWork := cfg.workingDir.trimAscii.toString
    let dataRoot :=
      if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then normWork
      else s!"{normWork}/.sandboxed-sh"
    let nowSec ← coreEpochSec
    match ← openCoreStore dataRoot with
    | .error e =>
      IO.eprintln s!"[sandboxed-sh deploy] store open failed: {e}"
      return 1
    | .ok st =>
      let leaseTok := (findFlagVal? args "--lease").getD ""
      if leaseTok.isEmpty then
        IO.eprintln "[sandboxed-sh deploy] ERROR: --lease is required"
        closeCoreStore st
        return 1
      let some lease ← lookupPrivilegeLease? st leaseTok
        | do
          IO.eprintln "[sandboxed-sh deploy] ERROR: unknown lease"
          closeCoreStore st
          return 1
      let obs ← observeDeployLive st unitName forceFlag dryRun true (some lease) nowSec
      let reobserveLive : IO DeployObservation := do
        let liveSec ← coreEpochSec
        let liveLease? ← lookupPrivilegeLease? st leaseTok
        observeDeployLive st unitName forceFlag dryRun true liveLease? liveSec
      let res ← runGuardedDeploy st obs reobserveLive dryRun s!"{nowSec}" none
      closeCoreStore st
      match res with
      | .error e =>
        IO.eprintln s!"[sandboxed-sh deploy] {e}"
        return 1
      | .ok rcpt =>
        if rcpt.verdict != "admitted" && rcpt.verdict != "dry_run_admitted" then
          IO.eprintln s!"[sandboxed-sh deploy] rejected ({rcpt.verdict})"
          return 1
        let drStr := if dryRun then "\"dry_run\":true," else ""
        IO.println s!"\{\"ok\":true,{drStr}\"unit\":\"{unitName}\",\"verdict\":\"{rcpt.verdict}\"}"
        return 0

end OrbCore.CliMain

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--version"] | ["-V"] =>
    IO.println "orb-server 0.7.10"
    return 0
  | ["--harness-contract-tests"] =>
    if OrbCore.Harness.runAllHarnessContractTests then
      IO.println "{\"ok\":true,\"harness_contract_tests\":9}"
      return 0
    else
      IO.eprintln "[sandboxed-sh] FAIL: harness contract invariant check failed"
      return 1
  | "deploy" :: rest =>
    OrbCore.CliMain.runDeploySubcommand rest
  | _ =>
    let cfg ← OrbCore.Control.loadConfigFromEnv
    OrbCore.Control.runCoreServer cfg none
