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
def authorize (store : CoreStore) (hub : ProviderRuntimeHub) (workingDir grant job node owner : String) :
    IO (Except String Placement) := do
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
  return .ok before

end OrbCore.NativeSharedWorkspace
