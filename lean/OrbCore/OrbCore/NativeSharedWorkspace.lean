import OrbCore.ProviderUsageAndLogin

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
  unless Orb.Kernel.validUnixUsername unixUser do return none
  return do
    return ⟨mission, user, unixUser, jobId, nodeId, account, model, mode == "readonly",
      ← runGen.toNat?, ← epoch.toNat?, ← revision.toNat?, country, ← routeGen.toNat?, ← expires.toNat?⟩

/-- Resolve a verified VPN and uniquely bound shared subscription inside Core.
    A concurrent revoke, move or route change invalidates the snapshot before
    Core can start a profile or return a successful admission. -/
def withVerifiedProfile {α : Type} (store : CoreStore) (hub : ProviderRuntimeHub) (workingDir grant job node owner : String)
    (consume : Placement → String → UInt16 → IO (Except String α)) : IO (Except String α) := do
  let denied := Except.error "native_shared_workspace_denied"
  let some before ← placement? store grant job node owner (← coreEpochSec) | return denied
  let accounts ← loadHydratedProviders store workingDir
  let some hp := accounts.find? (·.id == before.account) | return denied
  unless hp.providerType == "antigravity" && hp.enabled && hp.hasOAuth && !hp.oauthToken.isEmpty &&
      !((accountRoutingFile accounts hp).isEmpty) do return denied
  let some resolve := hub.resolveTransport? | return denied
  let .ok (some port) ← resolve hp.providerType hp.id | return denied
  if port == 0 then return denied
  unless (← placement? store grant job node owner (← coreEpochSec)) == some before do return denied
  consume before hp.oauthToken port

/-- Admission reports only the current placement to the requesting node. -/
def authorize (store : CoreStore) (hub : ProviderRuntimeHub) (workingDir grant job node owner : String) :
    IO (Except String Placement) :=
  withVerifiedProfile store hub workingDir grant job node owner fun placement _ _ => pure (.ok placement)

/-- The operator installs this holder on a co-located development worker. -/
structure HolderConfig where
  runtime : String
  profileUser : String

def holderFor? (node : String) : IO (Option HolderConfig) := do
  unless (← IO.getEnv "ORB_INSTANCE") == some "dev" do return none
  unless (← IO.getEnv "ORB_NATIVE_COLOCATED_NODE") == some node && !node.isEmpty do return none
  let some root ← IO.getEnv "ORB_NATIVE_PROFILE_RUNTIME" | return none
  let some user ← IO.getEnv "ORB_NATIVE_PROFILE_USER" | return none
  unless root.startsWith "/" && Orb.Kernel.validUnixUsername user do return none
  let info ← OrbBin.PosixExt.statPath root
  unless info.isDir && info.ownedByRoot && info.mode &&& 0o077 == 0 do return none
  return some ⟨root, user⟩

private def claim (store : CoreStore) (grant job : String) : IO Bool := do
  let digest := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes grant.toUTF8)
  let .ok rows ← execParamQuery store.missionsDb
    "INSERT OR IGNORE INTO native_shared_workspace_claims(job_id,token_sha256) VALUES(?1,?2) RETURNING job_id;"
    #[job, digest] | return false
  return rows.size == 2

/-- Pump one process only. The stdin pipe ties the isolated route and profile to Core. -/
def pumpTurn (store : CoreStore) (hub : ProviderRuntimeHub) (working grant job node owner prompt : String)
    (conversation : Option String) (expectedUid : Nat) (config : HolderConfig) (emit : ByteArray → IO Bool) : IO Bool := do
  unless ← emit ByteArray.empty do return false
  let result ← withVerifiedProfile store hub working grant job node owner fun p token port => do
    unless ← claim store grant p.job do return .error "native_turn_already_claimed"
    let packet := JVal.obj #[("unix_user", .str p.unixUser), ("owner", .str p.owner),
      ("mission", .str p.mission), ("account", .str p.account), ("model", .str p.model), ("exec_uid", .nat expectedUid),
      ("access_token", .str token), ("port", .nat port.toNat), ("readonly", .bool p.readonly),
      ("prompt", .str prompt), ("conversation", (conversation.map JVal.str).getD .null)]
    let .ok child ← (IO.Process.spawn {
      cmd := "/usr/bin/python3", args := #["-I", config.runtime ++ "/native_job_relay/main.py",
        config.runtime, config.profileUser], inheritEnv := false,
      env := #[("PATH", some (config.runtime ++ "/bin:/usr/sbin:/usr/bin:/bin"))],
      stdin := .piped, stdout := .piped, stderr := .null }).toBaseIO
      | return .error "native_holder_unavailable"
    let (input, running) ← child.takeStdin
    let stopping ← IO.mkRef false
    let watch ← IO.asTask (prio := .dedicated) do
      try
        let deadline := (← IO.monoMsNow) + 150000
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
          if !valid || (← IO.monoMsNow) > deadline then
            if (← running.tryWait).isNone then running.kill
            break
      catch _ =>
        if (← running.tryWait).isNone then running.kill
    try
      input.putStr (renderCompact packet ++ "\n")
      input.flush
      repeat
        let line ← running.stdout.getLine
        if line.isEmpty then break
        if !(← emit line.toUTF8) then return .error "native_stream_closed"
      -- Keep stdin open while the holder is alive; it watches EOF for Core loss.
      input.flush
      return .ok ((← running.wait) == 0)
    finally
      stopping.set true
      if (← running.tryWait).isNone then running.kill
      discard running.wait
      discard <| IO.wait watch
  if let .ok ok := result then return ok
  discard <| emit "{\"event\":\"error\",\"message\":\"Native turn unavailable\"}\n".toUTF8
  return false

end OrbCore.NativeSharedWorkspace
