import OrbCore.AccountVpnPool

namespace OrbCore.AccountVpnWireGuardTests

open OrbCore OrbBin.HttpClient OrbBin.Json

/-- The Python fixture supplies temporary device profiles and TLS receivers
in a private network namespace. This driver calls the production allocator. -/
def run (root : String) (resume : Bool) (hold := false) : IO UInt32 := do
  let store ← IO.ofExcept (← Store.openCoreStore root)
  let pool ← Std.Mutex.new ({} : AccountVpnPool.PoolState)
  try
    unless resume do
      let input ← IO.getStdin
      for _ in [:4] do
        let (status, _) ← AirVpnSettings.settings root "PUT" (← input.getLine).toUTF8
        unless status == 200 do throw (IO.userError "fixture settings rejected")
    let route := fun (account provider : String) => AccountVpnRoutes.resolve store.missionsDb account fun pref =>
      AccountVpnPool.allocate pool root root store.missionsDb account provider pref
    let source := fun (account provider : String) => do
      let response ← IO.ofExcept (← sendRequest "GET" "https://provider.test/source" (resolveTransport? := some (route account provider)))
      unless response.status == 200 do throw (IO.userError "fixture receiver status")
      return String.fromUTF8! response.body
    if resume then
      let b ← source "b" "codex"
      let a ← source "a" "chatgpt"
      let out ← IO.getStdout
      out.putStrLn (renderCompact (.obj #[("a", .str a), ("b", .str b)]))
      out.flush
      if hold then
        let input ← IO.getStdin
        repeat
          match (← input.getLine).trimAscii.toString with
          | "repeat" => out.putStrLn (← source "a" "chatgpt")
          | "other" => out.putStrLn (← source "b" "codex")
          | "expect-blocked" =>
            let response ← sendRequest "GET" "https://provider.test/source" (resolveTransport? := some (route "a" "chatgpt"))
            if response.isOk then throw (IO.userError "colliding exit admitted")
            out.putStrLn "blocked"
          | _ => break
          out.flush
      return 0
    for account in ["a", "b", "c", "extra"] do
      IO.ofExcept (← AccountVpnPool.savePreference pool store.missionsDb account (some "NL"))
    let first ← IO.asTask (prio := .dedicated) (source "a" "chatgpt")
    let second ← IO.asTask (prio := .dedicated) (source "b" "codex")
    let a ← IO.ofExcept (← IO.wait first)
    let b ← IO.ofExcept (← IO.wait second)
    let c ← source "c" "claude"
    let direct ← source "direct" "chatgpt"
    unless a != b && [a,b].contains c && ![a,b].contains direct do throw (IO.userError "credential routing mismatch")
    let .error "airvpn_session_limit" ← route "extra" "openai" | throw (IO.userError "sixth session must be refused")
    unless (← source "a" "chatgpt") == a && (← source "b" "codex") == b do throw (IO.userError "existing route changed")
    IO.println (renderCompact (.obj #[("a", .str a), ("b", .str b), ("c", .str c), ("direct", .str direct)]))
    return 0
  finally
    AccountVpnPool.shutdown pool
    Store.closeCoreStore store

end OrbCore.AccountVpnWireGuardTests
