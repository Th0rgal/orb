import OrbBin.Json
import OrbLocald

/-
  OrbLocald.SelfTest — Conformance & self-test runner for `lean/OrbLocald`.
-/

open OrbBin.Json
open OrbLocald.Spec
open OrbLocald.Rpc

private def assertEq {α : Type} [BEq α] [ToString α] (label : String) (got expected : α) : IO Bool := do
  if got == expected then
    return true
  else
    IO.eprintln s!"FAIL [{label}]: got {got}, expected {expected}"
    return false

private def assertTrue (label : String) (cond : Bool) : IO Bool := do
  if cond then return true
  else
    IO.eprintln s!"FAIL [{label}]"
    return false

def main : IO UInt32 := do
  let mut passed := 0
  let mut total := 0

  -- 1. Command table size (87 desktop commands + plugin:app|version = 88)
  total := total + 1
  if (← assertEq "desktop_command_count" supportedDesktopCommands.size 88) then passed := passed + 1

  -- 2. Loopback RPC auth gate
  let validTok := "0123456789abcdef0123456789abcdef"
  total := total + 1
  if (← assertTrue "rpc_auth_loopback_ok" (checkRpcAuth "127.0.0.1" validTok validTok)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_remote" (!(checkRpcAuth "10.0.0.5" validTok validTok))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_bad_token" (!(checkRpcAuth "127.0.0.1" "wrong-token-00000000000000000000" validTok))) then passed := passed + 1

  -- 3. Transport bridge 6 SSE stream shard ports & 3-way failover
  let stRef ← IO.mkRef ({ launchToken := "tok-test" } : LocaldState)
  let txRes ← dispatchRpcCommand stRef "transport_bridge_configure" (.obj #[])
  total := total + 1
  match txRes with
  | .ok jv =>
    let shards := match jv.fieldArr? "stream_proxy_base_urls" with
      | some xs => xs.size
      | none => 0
    if (← assertEq "transport_6_sse_shards" shards 6) then passed := passed + 1
  | .error e =>
    IO.eprintln s!"FAIL [transport_bridge_configure]: {e}"

  total := total + 1
  if (← assertTrue "failover_get_allowed" (canFailoverRequest "GET" false 1 defaultFailoverOrigins)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_without_idem_blocked" (!(canFailoverRequest "POST" false 1 defaultFailoverOrigins))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_with_idem_allowed" (canFailoverRequest "POST" true 2 defaultFailoverOrigins)) then passed := passed + 1

  -- 4. Channel subscribe / unsubscribe lifecycle
  let sub1 ← dispatchRpcCommand stRef "local_bindings_subscribe" (.obj #[])
  let sub2 ← dispatchRpcCommand stRef "local_interaction_subscribe" (.obj #[("id", .str "m1")])
  total := total + 1
  let okSubs := match sub1, sub2 with
    | .ok (.num "1"), .ok (.num "2") => true
    | _, _ => false
  if (← assertTrue "channel_subscribe_monotonic" okSubs) then passed := passed + 1

  let _ ← dispatchRpcCommand stRef "local_bindings_unsubscribe" (.obj #[("token", JVal.nat 1)])
  let curSt ← stRef.get
  total := total + 1
  let activeCount := (curSt.subscriptions.filter (·.active)).size
  if (← assertEq "channel_unsubscribe_deactivates" activeCount 1) then passed := passed + 1

  -- 5. Paloma Touch ID grace eligibility
  let goodPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/bitwarden/requests/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nAllow secret FOO"
  let nonBwPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/privilege-access/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nRoot shell"
  total := total + 1
  if (← assertTrue "paloma_grace_bitwarden_approve" (isPalomaPayloadGraceEligible goodPayload)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_priv" (!(isPalomaPayloadGraceEligible nonBwPayload))) then passed := passed + 1

  -- 6. WebView init script exposes __TAURI__ and __TAURI_INTERNALS__
  let js := renderWebviewInitScript 19479 "tok-abc"
  total := total + 1
  let hasGlobals := (js.splitOn "__TAURI_INTERNALS__").length > 1 && (js.splitOn "Channel").length > 1
  if (← assertTrue "webview_init_script_globals" hasGlobals) then passed := passed + 1

  -- 7. Version RPC
  let verRes ← dispatchRpcCommand stRef "plugin:app|version" (.obj #[])
  total := total + 1
  let verOk := match verRes with | .ok (.str "0.13.0") => true | _ => false
  if (← assertTrue "plugin_app_version_0_13_0" verOk) then passed := passed + 1

  IO.println s!"orb-locald-test: {passed}/{total} checks passed"
  return if passed == total then 0 else 1
