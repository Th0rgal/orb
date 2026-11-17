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
  let other := harnessProxySetup "grok" "grok-5" base "tok"
  check (other.env.isEmpty && other.args.isEmpty && other.model == some "grok-5") "other harnesses are unchanged"

end OrbCore.HarnessProxyTests
