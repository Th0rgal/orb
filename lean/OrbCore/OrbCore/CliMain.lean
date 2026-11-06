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

namespace OrbCore.CliMain

open OrbCore.Control
open OrbCore.Managed
open OrbCore.Harness

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
    if dryRun then
      IO.println s!"\{\"ok\":true,\"dry_run\":true,\"unit\":\"{unitName}\"}"
      return 0
    let sysCtlCmd ← if ← System.FilePath.pathExists "/bin/systemctl" then pure "/bin/systemctl" else pure "/usr/bin/systemctl"
    let res ← IO.Process.output {
      cmd := sysCtlCmd
      args := #["restart", unitName]
    }
    if res.exitCode != 0 then
      IO.eprintln s!"[sandboxed-sh deploy] systemctl restart {unitName} failed: {res.stderr}"
      return 1
    IO.println s!"\{\"ok\":true,\"unit\":\"{unitName}\"}"
    return 0

end OrbCore.CliMain

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--version"] | ["-V"] =>
    IO.println "sandboxed-sh 0.7.10"
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
