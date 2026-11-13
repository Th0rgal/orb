/-
  OrbCore.CliMain: Production entrypoint for `orb-core` (`0 import Lean`, `0 sorryAx`).
  Supports:
  - `orb-core` (default HTTP/WS Core server on `$HOST:$PORT`)
  - `orb-core deploy --service <unit>` (validated systemd unit deployment)
  - `orb-core managed-inspect <id>...` (read-only: Core row beside provider-side state)
  - `orb-core seal-provider <boat|leanci|colab>` (operator vault-to-Core key sealing)
  - `orb-core --harness-contract-tests` (9 CLI/SSE/ACP parser contract tests)
  - `orb-core --version` / `-V`
-/
import OrbCore.Control
import OrbCore.Managed
import OrbCore.Harness
import OrbCore.Store
import OrbCore.R7Core
import OrbCore.ManagedProviderSealing

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
  let rawUnit := (findFlagVal? args "--service").getD "orb-core"
  match validateDeployServiceUnit rawUnit with
  | .error e =>
    IO.eprintln s!"[orb-core deploy] ERROR: {e}"
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
      IO.eprintln s!"[orb-core deploy] store open failed: {e}"
      return 1
    | .ok st =>
      let leaseTok := (findFlagVal? args "--lease").getD ""
      if leaseTok.isEmpty then
        IO.eprintln "[orb-core deploy] ERROR: --lease is required"
        closeCoreStore st
        return 1
      let some lease ← lookupPrivilegeLease? st leaseTok
        | do
          IO.eprintln "[orb-core deploy] ERROR: unknown lease"
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
        IO.eprintln s!"[orb-core deploy] {e}"
        return 1
      | .ok rcpt =>
        if rcpt.verdict != "admitted" && rcpt.verdict != "dry_run_admitted" then
          IO.eprintln s!"[orb-core deploy] rejected ({rcpt.verdict})"
          return 1
        let drStr := if dryRun then "\"dry_run\":true," else ""
        IO.println s!"\{\"ok\":true,{drStr}\"unit\":\"{unitName}\",\"verdict\":\"{rcpt.verdict}\"}"
        return 0

/-- `orb-core managed-inspect <id|managed-<id>|unique-prefix>...`: read-only. Prints one JSON
    line per machine with Core's row and the provider's own state. Run it as the service user
    with the service environment so the same data root and sealed provider key are used. -/
def runManagedInspectSubcommand (ids : List String) : IO UInt32 := do
  if ids.isEmpty then
    IO.eprintln "usage: orb-core managed-inspect <machine-id>..."
    return 2
  let cfg ← loadConfigFromEnv
  let normWork := cfg.workingDir.trimAscii.toString
  let dataRoot :=
    if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then normWork
    else s!"{normWork}/.sandboxed-sh"
  if !(← (System.FilePath.mk s!"{dataRoot}/managed_compute.db").pathExists) then
    IO.eprintln "[orb-core managed-inspect] managed_compute.db not found under the configured WORKING_DIR"
    return 1
  let .ok mc ← openManagedComputeStore s!"{dataRoot}/managed_compute.db"
    | do IO.eprintln "[orb-core managed-inspect] managed store open failed"; return 1
  let now ← coreEpochSec
  for id in ids do
    let row ← OrbCore.ManagedTtl.inspectMachine mc
      (OrbCore.RemoteFleetAndRelay.resolveManagedProvider dataRoot) id now
    IO.println (OrbBin.Json.renderCompact row)
  closeManagedComputeStore mc
  return 0

/-- Local operator sealing. Authority is filesystem ownership of Core's data
    root by the invoking user, never an HTTP login: dev-mode sessions, fallback
    signing keys and mission credentials do not exist on this path. A process
    carrying a mission identity is refused. The key travels vault -> Core's
    sealed file only; nothing but the provider name is printed. -/
def runSealProviderSubcommand (args : List String) : IO UInt32 := do
  let some provider := args.head?
    | do IO.eprintln "[orb-core seal-provider] usage: seal-provider <boat|leanci|colab>"; return 2
  let cfg ← loadConfigFromEnv
  let normWork := cfg.workingDir.trimAscii.toString
  let dataRoot :=
    if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then normWork
    else s!"{normWork}/.sandboxed-sh"
  let st ← OrbBin.PosixExt.statPath dataRoot
  let ownsDataRoot := st.exists_ && st.isDir && !st.isSymlink && st.ownedByEuid
  let mut missionIdentity := false
  for name in #["SANDBOXED_MISSION_ID", "SANDBOXED_SH_MISSION_ID", "SANDBOXED_JOB_ID"] do
    if ((← IO.getEnv name).getD "").trimAscii.toString != "" then missionIdentity := true
  match ← OrbCore.ManagedProviderSealing.sealReserved dataRoot provider ownsDataRoot missionIdentity false
      (OrbCore.SecretAndApproval.resolveReservedComputeSecret cfg.workingDir dataRoot) with
  | .ok () =>
    IO.println s!"\{\"provider\":\"{provider}\",\"sealed\":true}"
    return 0
  | .error e =>
    IO.eprintln s!"[orb-core seal-provider] {e} (data root {dataRoot})"
    return 1

end OrbCore.CliMain

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--version"] | ["-V"] =>
    IO.println "orb-core 0.7.10"
    return 0
  | ["--harness-contract-tests"] =>
    if OrbCore.Harness.runAllHarnessContractTests then
      IO.println "{\"ok\":true,\"harness_contract_tests\":9}"
      return 0
    else
      IO.eprintln "[orb-core] FAIL: harness contract invariant check failed"
      return 1
  | "deploy" :: rest =>
    OrbCore.CliMain.runDeploySubcommand rest
  | "managed-inspect" :: rest =>
    OrbCore.CliMain.runManagedInspectSubcommand rest
  | "seal-provider" :: rest =>
    OrbCore.CliMain.runSealProviderSubcommand rest
  | _ =>
    let cfg ← OrbCore.Control.loadConfigFromEnv
    OrbCore.Control.runCoreServer cfg none
