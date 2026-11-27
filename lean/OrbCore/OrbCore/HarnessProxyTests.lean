import OrbCore.RemoteDispatch

/-! Turns that Core runs itself (the "Core" target) reach models through Core's router,
    exactly like node turns: same aliases, a mission proxy token, no host logins. -/
namespace OrbCore.HarnessProxyTests
open OrbCore.RemoteDispatch

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"harness proxy: {label}")

private def envOf (s : HarnessProxySetup) (k : String) : Option String :=
  (s.env.find? (fun (ek, _) => ek == k)).map Prod.snd

def run : IO Unit := do
  let base := "http://127.0.0.1:3000"
  let oc := harnessProxySetup "opencode" "builtin/smart" base "tok"
  check (oc.model == some "builtin/smart") "opencode keeps the router alias"
  check (envOf oc "SANDBOXED_PROXY_API_KEY" == some "tok") "opencode gets the mission proxy token"
  let ocCfg := (envOf oc "OPENCODE_CONFIG_CONTENT").getD ""
  check ((ocCfg.splitOn s!"{base}/v1").length > 1) "opencode config points at Core's router"
  check ((harnessProxySetup "opencode" "" base "tok").model == some "builtin/smart") "opencode defaults to smart"
  check ((harnessProxySetup "opencode" "openai/gpt-6-astra" base "tok").model == some "builtin/openai/gpt-6-astra")
    "a provider model goes through the router, not the host's provider login"
  let cc := harnessProxySetup "claudecode" "anthropic/claude-fable-5-2" base "tok"
  check (cc.model == some "claude-fable-5-2") "claude model is bare"
  check (envOf cc "ANTHROPIC_BASE_URL" == some base && envOf cc "ANTHROPIC_AUTH_TOKEN" == some "tok")
    "claude talks to Core's router with the mission token"
  check ((harnessProxySetup "claudecode" "" base "tok").model == none) "claude keeps its own default model"
  let cx := harnessProxySetup "codex" "openai/gpt-6-astra" base "tok"
  check (cx.model == some "gpt-6-astra") "codex model is bare"
  check (cx.args.contains s!"model_providers.sandboxed.base_url=\"{base}/v1\"") "codex provider points at Core's router"
  check (envOf cx "SANDBOXED_PROXY_API_KEY" == some "tok") "codex gets the mission proxy token"
  let gk := harnessProxySetup "grok" "xai/grok-5" base "tok"
  check (gk.model == some "grok-5") "grok model strips xai/ prefix"
  check (envOf gk "GROK_XAI_API_BASE_URL" == some base && envOf gk "XAI_API_KEY" == some "tok")
    "grok talks to Core's router with the mission token"
  let other := harnessProxySetup "custom" "custom-1" base "tok"
  check (other.env.isEmpty && other.args.isEmpty && other.model == some "custom-1") "other harnesses are unchanged"
  let relayUrl := OrbCore.AccountVpnRelay.proxyUrl "secret-key" 10855 "antigravity" "acct-1" "10.88.0.1" "socks5h"
  check (relayUrl.isSome && ((relayUrl.getD "").startsWith "socks5h://") &&
    ((relayUrl.getD "").splitOn "@10.88.0.1:10855").length == 2)
    "mesh AirVPN relay URL uses socks5h and configured mesh host"
  -- Fail-closed checks for native Antigravity VPN proxy env resolution and Grok direct fallback guard.
  IO.FS.withTempDir fun tmpDir => do
    let root := tmpDir.toString
    let store ← IO.ofExcept (← OrbCore.Store.openCoreStore root)
    try
      let baseSup ← newRemoteJobSupervisor "fixture-jwt-secret" false none
      -- Direct account returns empty proxy env array.
      let directEnvs ← IO.ofExcept (← resolveAntigravityVpnProxyEnvs store baseSup (some "agy-direct") "https://core.invalid")
      check directEnvs.isEmpty "Direct Antigravity account produces no VPN proxy env vars"
      -- VPN-routed Antigravity account must fail closed when coordinator/pool is missing.
      IO.ofExcept (← OrbCore.AccountVpnRoutes.set store.missionsDb "agy-vpn" (some "NL"))
      let noPool ← resolveAntigravityVpnProxyEnvs store baseSup (some "agy-vpn") "https://core.invalid"
      check (match noPool with | .error "antigravity_vpn_coordinator_unavailable" => true | _ => false)
        "VPN Antigravity account fails closed without coordinator pool"
      -- VPN-routed Antigravity account must fail closed when pool cannot verify a tunnel.
      let pool ← Std.Mutex.new ({} : OrbCore.AccountVpnPool.PoolState)
      let supWithPool := { baseSup with vpnPool? := some pool, vpnCoordinatorDir := root }
      let noProfile ← resolveAntigravityVpnProxyEnvs store supWithPool (some "agy-vpn") "https://core.invalid"
      check (match noProfile with | .error e => e.startsWith "antigravity_vpn_unavailable:" | _ => false)
        "VPN Antigravity account fails closed when tunnel cannot be verified"
      -- Grok direct fallback must refuse to run when any xAI account has AirVPN configured.
      IO.ofExcept (← OrbCore.Store.upsertAIProvider store {
        id := "xai-vpn-1", name := "xAI VPN", providerType := "xai", apiKey := "fixture-only"
      })
      check ((← anyXaiVpnConfigured? store root).toOption == some false)
        "Direct xAI account allows fallback check"
      IO.ofExcept (← OrbCore.AccountVpnRoutes.set store.missionsDb "xai-vpn-1" (some "NL"))
      check ((← anyXaiVpnConfigured? store root).toOption == some true)
        "VPN-routed xAI account blocks direct Grok managedAuth fallback"
      IO.ofExcept (← OrbCore.AccountVpnRoutes.set store.missionsDb "xai-vpn-1" none)
      check ((← anyXaiVpnConfigured? store root).toOption == some false)
        "Switching xAI account back to Direct clears VPN block"
    finally
      OrbCore.Store.closeCoreStore store

end OrbCore.HarnessProxyTests
