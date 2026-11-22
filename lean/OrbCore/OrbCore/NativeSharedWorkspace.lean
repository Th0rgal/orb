import OrbCore.ProviderUsageAndLogin
import OrbCore.NativeCanary
import OrbBin.ClaudeControl

namespace OrbCore.NativeSharedWorkspace

open OrbCore.Store OrbBin.Sqlite OrbBin.Json OrbCore.ProviderUsageAndLogin

/-- Derived by Core from the active placement, never supplied by model or workspace.
    The same record must remain current for the lifetime of the profile process. -/
structure Placement where
  mission : String
  owner : String
  unixUser : String
  job : String
  node : String
  account : String
  model : String
  readonly : Bool
  runGeneration : Nat
  ownerEpoch : Nat
  placementRevision : Nat
  country : String
  routeGeneration : Nat
  expires : Nat
  deriving BEq

def placement? (store : CoreStore) (grant job node owner : String) (now : UInt64) :
    IO (Option Placement) := do
  unless grant.startsWith "orb-agy-v1_" do return none
  let digest := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes grant.toUTF8)
  let .ok rows ← execParamQuery store.missionsDb (include_str "native_shared_workspace.sql")
      #[digest, job, node, owner, toString now] | return none
  let some #[mission, user, unixUser, jobId, nodeId, account, model, mode, runGen, epoch, revision,
      country, routeGen, expires] := rows[1]? | return none
  let .ok allowed := (← NativeCanary.load).accountFor nodeId user | return none
  unless allowed.all (· == account) && Orb.Kernel.validUnixUsername unixUser do return none
  return do
    return ⟨mission, user, unixUser, jobId, nodeId, account, model, mode == "readonly",
      ← runGen.toNat?, ← epoch.toNat?, ← revision.toNat?, country, ← routeGen.toNat?, ← expires.toNat?⟩

/-- Resolve the saved route and uniquely bound shared subscription inside Core.
    A concurrent revoke, move or route change invalidates the snapshot before
    Core can start a profile or return a successful admission. -/
def withVerifiedProfile {α : Type} (store : CoreStore) (hub : ProviderRuntimeHub) (workingDir grant job node owner : String)
    (consume : Placement → String → Option UInt16 → IO (Except String α)) : IO (Except String α) := do
  let denied := Except.error "native_shared_workspace_denied"
  let some before ← placement? store grant job node owner (← coreEpochSec) | return denied
  let accounts ← loadHydratedProviders store workingDir
  let some hp := accounts.find? (·.id == before.account) | return denied
  unless hp.providerType == "antigravity" && hp.enabled && hp.hasOAuth && !hp.oauthToken.isEmpty &&
      !((accountRoutingFile accounts hp).isEmpty) do return denied
  let some resolve := hub.resolveTransport? | return denied
  let .ok port? ← resolve hp.providerType hp.id | return denied
  if before.country.isEmpty != port?.isNone || port? == some 0 then return denied
  unless (← placement? store grant job node owner (← coreEpochSec)) == some before do return denied
  consume before hp.oauthToken port?

/-- Admission reports only the current placement to the requesting node. -/
def authorize (store : CoreStore) (hub : ProviderRuntimeHub) (workingDir grant job node owner : String) :
    IO (Except String Placement) :=
  withVerifiedProfile store hub workingDir grant job node owner fun placement _ _ => pure (.ok placement)

/-- Explicit operator opt-in for authenticated native subscription execution. -/
def executionEnabled : IO Bool := do
  return (← IO.getEnv "ORB_NATIVE_SUBSCRIPTION_ENABLED") == some "1"

/-- Trusted runtime and workspace placement installed by the operator. -/
structure HolderConfig where
  runtime : String
  profileUser : String
  remote : Bool

def holderFor? (node : String) : IO (Option HolderConfig) := do
  unless ← executionEnabled do return none
  let localNode := (← IO.getEnv "ORB_NATIVE_COLOCATED_NODE") == some node
  let remoteNode := (← IO.getEnv "ORB_NATIVE_WORKSPACE_NODE") == some node
  if node.isEmpty || localNode == remoteNode then return none
  let some root ← IO.getEnv "ORB_NATIVE_PROFILE_RUNTIME" | return none
  let some user ← IO.getEnv "ORB_NATIVE_PROFILE_USER" | return none
  unless root.startsWith "/" && Orb.Kernel.validUnixUsername user do return none
  let info ← OrbBin.PosixExt.statPath root
  unless info.isDir && info.ownedByRoot && info.mode &&& 0o077 == 0 do return none
  return some ⟨root, user, remoteNode⟩

private def claim (store : CoreStore) (grant job : String) : IO Bool := do
  let digest := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes grant.toUTF8)
  let .ok rows ← execParamQuery store.missionsDb
    "INSERT OR IGNORE INTO native_shared_workspace_claims(job_id,token_sha256) VALUES(?1,?2) RETURNING job_id;"
    #[job, digest] | return false
  return rows.size == 2

/-- Time spent waiting for an explicit approval is accounted separately from model work. -/
structure ApprovalWait where
  elapsedMs : Nat := 0
  startedMs : Option Nat := none
  deriving Inhabited

def ApprovalWait.totalMs (wait : ApprovalWait) (now : Nat) : Nat :=
  wait.elapsedMs + (wait.startedMs.map (fun start => now - start)).getD 0

private def modelBudgetMs : Nat := 150000
private def approvalBudgetMs : Nat := 450000

def turnExpired (start now : Nat) (wait : ApprovalWait) : Bool :=
  now - start ≥ modelBudgetMs + min approvalBudgetMs (wait.totalMs now)

/-- Read grace after Core's hard deadline lets the worker receive the terminal frame. -/
def turnReadTimeoutSecs (goal : Bool) : Nat :=
  (modelBudgetMs + (if goal then approvalBudgetMs else 0)) / 1000 + 5

/-- Supply fresh, owner-scoped delegation state even when ACP loads an older conversation. -/
def childContext (store : CoreStore) (p : Placement) : IO String := do
  let unknown := "Orb could not verify this mission’s children. Do not assume a child exists or retry a delegation with a different key."
  let .ok rows ← execParamQuery store.missionsDb (include_str "native_direct_child_ids.sql") #[p.mission, p.owner]
    | return unknown
  let children := rows.extract 1 rows.size
  if children.isEmpty then
    return "Orb has no direct child missions for this Goal. If the task calls for delegation, use sandboxed/start_mission with title, prompt, backend and model_override. Read a child only after its mission UUID is known."
  let ids := (children.extract 0 16).filterMap fun row => row[0]? >>= OrbBin.PosixExt.parseUuidCanonical?
  if ids.size != min children.size 16 then return unknown
  let label := if children.size > 16 then "Orb’s 16 newest direct child mission IDs (additional children exist)" else "Orb’s direct child mission IDs"
  return label ++ ": " ++ String.intercalate ", " ids.toList ++
    ". Use sandboxed/get_mission with mission_id for the child you want to check before repeating delegated work."

/-- Pump one process only. The stdin pipe ties the isolated route and profile to Core. -/
def pumpTurn (store : CoreStore) (hub : ProviderRuntimeHub) (working grant job node owner prompt : String)
    (conversation : Option String) (expectedUid : Nat) (config : HolderConfig)
    (goal : Bool) (fileCall : Placement → JVal → IO JVal)
    (delegateCall : Placement → JVal → IO Bool → IO JVal) (emit : ByteArray → IO Bool) : IO Bool := do
  unless ← emit ByteArray.empty do return false
  let result ← withVerifiedProfile store hub working grant job node owner fun p token port => do
    unless ← claim store grant p.job do return .error "native_turn_already_claimed"
    let turnPrompt ← if goal then do
      let context ← childContext store p
      pure (context ++ "\n\n" ++ prompt)
    else pure prompt
    let packet := JVal.obj #[("unix_user", .str p.unixUser), ("owner", .str p.owner),
      ("mission", .str p.mission), ("account", .str p.account), ("model", .str p.model), ("exec_uid", .nat expectedUid),
      ("access_token", .str token), ("direct", .bool p.country.isEmpty), ("remote", .bool config.remote),
      ("port", (port.map (fun n => JVal.nat n.toNat)).getD .null), ("readonly", .bool p.readonly),
      ("goal", .bool goal), ("prompt", .str turnPrompt), ("conversation", (conversation.map JVal.str).getD .null)]
    let .ok child ← (IO.Process.spawn {
      cmd := "/usr/bin/python3", args := #["-I", config.runtime ++ "/native_job_relay/main.py",
        config.runtime, config.profileUser], inheritEnv := false,
      env := #[("PATH", some (config.runtime ++ "/bin:/usr/sbin:/usr/bin:/bin"))],
      stdin := .piped, stdout := .piped, stderr := .null }).toBaseIO
      | return .error "native_holder_unavailable"
    let (input, running) ← child.takeStdin
    let stopping ← IO.mkRef false
    let holderLive : IO Bool := do return !(← stopping.get)
    let watchdogError ← IO.mkRef (none : Option String)
    let approvalWait ← IO.mkRef ({} : ApprovalWait)
    let start ← IO.monoMsNow
    let watch ← IO.asTask (prio := .dedicated) do
      try
        let mut ticks : Nat := 0
        while !(← stopping.get) do
          IO.sleep 250
          if ← stopping.get then break
          let mut valid := (← placement? store grant job node owner (← coreEpochSec)) == some p
          ticks := ticks + 1
          if valid && ticks % 8 == 0 then
            let accounts ← loadHydratedProviders store working
            valid := accounts.any fun hp => hp.id == p.account && hp.providerType == "antigravity" &&
              hp.enabled && hp.hasOAuth && hp.oauthToken == token && !(accountRoutingFile accounts hp).isEmpty
          if !valid || turnExpired start (← IO.monoMsNow) (← approvalWait.get) then
            watchdogError.set (some (if valid then "native_turn_timeout" else "native_shared_workspace_denied"))
            stopping.set true
            discard <| running.kill.toBaseIO
            break
      catch _ =>
        stopping.set true
        discard <| running.kill.toBaseIO
    let reachedEof ← IO.mkRef false
    let exitCode ← IO.mkRef (1 : UInt32)
    try
      input.putStr (renderCompact packet ++ "\n")
      input.flush
      repeat
        let line ← running.stdout.getLine
        if line.isEmpty then break
        let some envelope := (OrbBin.Json.parse line).toOption | return .error "native_holder_protocol"
        if let some event := envelope.field? "agent" then
          if !(← emit (renderCompact event ++ "\n").toUTF8) then return .error "native_stream_closed"
        else if let some operation := (envelope.field? "file").orElse (fun _ => envelope.field? "delegate") then
          unless config.remote do return .error "native_holder_protocol"
          let delegated := (envelope.field? "delegate").isSome
          let action := operation.fieldStr? "action"
          unless (delegated && goal) || (!delegated && (action == some "read_file" || (action == some "write_file" && !p.readonly && !goal))) do
            return .error "native_holder_protocol"
          let checked ← withVerifiedProfile store hub working grant job node owner fun current currentToken _ => do
            unless current == p && currentToken == token do return .error "native_shared_workspace_denied"
            if delegated && action == some "ask" then
              let before ← IO.monoMsNow
              approvalWait.modify fun w => {w with startedMs := some before}
              try
                return .ok (← delegateCall p operation holderLive)
              finally
                let afterWait ← IO.monoMsNow
                approvalWait.modify fun w => ⟨w.totalMs afterWait, none⟩
            if delegated then return .ok (← delegateCall p operation holderLive)
            return .ok (← fileCall p operation)
          let .ok reply := checked | return .error "native_shared_workspace_denied"
          unless ← holderLive do return .error ((← watchdogError.get).getD "native_holder_closed")
          unless (← placement? store grant job node owner (← coreEpochSec)) == some p do
            return .error "native_shared_workspace_denied"
          input.putStr (renderCompact reply ++ "\n")
          input.flush
        else
          return .error "native_holder_protocol"
      reachedEof.set true
    finally
      stopping.set true
      discard <| IO.wait watch
      unless ← reachedEof.get do discard <| running.kill.toBaseIO
      -- Only this task reaps the holder. A second wait raises ECHILD on Linux.
      exitCode.set (← running.wait)
    if let some reason ← watchdogError.get then return .error reason
    return .ok ((← exitCode.get) == 0)
  match result with
  | .ok ok => return ok
  | .error reason =>
    let code := if (OrbBin.ClaudeControl.antigravityNativeError? reason).isSome then reason else "native_turn_unavailable"
    let event := JVal.obj #[("event", .str "error"), ("code", .str code), ("message", .str "Native turn unavailable")]
    discard <| emit (renderCompact event ++ "\n").toUTF8
    return false

end OrbCore.NativeSharedWorkspace
