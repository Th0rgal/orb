import OrbCore.AccountVpnPool
import LeanSys.Auth

namespace OrbCore.AccountVpnRelay

open LeanSys.Posix LeanSys.Auth OrbNetLeaf.TlsHttp

/-- The username names the exact credential and provider. The password is a
domain-separated MAC that remains usable when Core restarts on its fixed port. -/
def password (operatorKey user : String) : String :=
  hmacSha256Hex operatorKey ("orb-airvpn-socks-v1\x00" ++ user)

def proxyUrl (operatorKey : String) (port : UInt16) (provider account : String) : Option String := do
  let user := provider ++ "/" ++ account
  guard (!operatorKey.isEmpty && port != 0 && !provider.isEmpty && !provider.contains '/' &&
    !account.isEmpty && user.utf8ByteSize ≤ 255)
  return s!"socks5://{OrbBin.HttpClient.urlEncodeComponent user}:{password operatorKey user}@127.0.0.1:{port}"

private def auth? (fd : Fd) (key : String) (deadline : Nat) : IO (Option (String × String)) := do
  let some hello ← readSocksBytes fd 2 deadline | return none
  if hello[0]! != 5 then return none
  let some methods ← readSocksBytes fd hello[1]!.toNat deadline | return none
  if !methods.data.contains 2 then
    discard <| writeAll fd ⟨#[5, 255]⟩
    return none
  unless (← writeAll fd ⟨#[5, 2]⟩).isOk do return none
  let some head ← readSocksBytes fd 2 deadline | return none
  if head[0]! != 1 || head[1]! == 0 then return none
  let some name ← readSocksBytes fd head[1]!.toNat deadline | return none
  let some size ← readSocksBytes fd 1 deadline | return none
  let some signature ← readSocksBytes fd size[0]!.toNat deadline | return none
  let some user := String.fromUTF8? name | return none
  let some mac := String.fromUTF8? signature | return none
  if key.isEmpty || !ctEqString (password key user) mac then
    discard <| writeAll fd ⟨#[1, 1]⟩
    return none
  let provider := (user.takeWhile (· != '/')).toString
  let account := (user.drop (provider.length + 1)).toString
  if provider.isEmpty || account.isEmpty then return none
  unless (← writeAll fd ⟨#[1, 0]⟩).isOk do return none
  return some (provider, account)

private def destination? (fd : Fd) (deadline : Nat) : IO (Option (String × UInt16)) := do
  let some head ← readSocksBytes fd 4 deadline | return none
  unless head.data == #[5, 1, 0, 3] do return none
  let some length ← readSocksBytes fd 1 deadline | return none
  let some name ← readSocksBytes fd length[0]!.toNat deadline | return none
  let some host := String.fromUTF8? name | return none
  if host.isEmpty || !host.all (fun c => c.isAlphanum || c == '.' || c == '-') then return none
  let some bytes ← readSocksBytes fd 2 deadline | return none
  let port := (bytes[0]!.toUInt16 <<< 8) ||| bytes[1]!.toUInt16
  return some (host, port)

private def reply (fd : Fd) (code : UInt8) : IO Bool := do
  return (← writeAll fd ⟨#[5, code, 0, 1, 0, 0, 0, 0, 0, 0]⟩).isOk

private def pump (client upstream : Fd) (stopping : IO Bool) : IO Unit := do
  let fds := #[client, upstream]
  let mut lastByte ← IO.monoMsNow
  repeat
    if ← stopping then return
    if (← IO.monoMsNow) - lastByte ≥ 300000 then return
    let .ok ready ← pollFdSet fds 1000 | return
    if !ready.isEmpty then lastByte ← IO.monoMsNow
    for idx in ready do
      let chunk ← readStreamChunk fds[idx]! 16384
      if chunk.isEmpty || (← stopping) then return
      unless (← writeAll fds[1 - idx]! chunk).isOk do return

/-- The relay has only one outbound entry point: a verified loopback SOCKS
listener. Network destinations are resolved by the WireGuard transport. -/
def serve (fd : Fd) (key : String)
    (resolve : String → String → IO (Except String AccountVpnPool.Gateway)) (stopping : IO Bool := pure false) : IO Unit := do
  let deadline := (← IO.monoMsNow) + 10000
  let some (provider, account) ← auth? fd key deadline | return
  let some (host, port) ← destination? fd deadline | discard <| reply fd 8; return
  let .ok gateway ← resolve provider account | discard <| reply fd 2; return
  if gateway.port == 0 || (← gateway.revoked.get) then discard <| reply fd 2; return
  let .ok upstream ← tcpConnectTimed "127.0.0.1" gateway.port 5000 | discard <| reply fd 5; return
  try
    unless ← negotiateSocks upstream host port ((← IO.monoMsNow) + 10000) do
      discard <| reply fd 5
      return
    if ← reply fd 0 then pump fd upstream (do return (← gateway.revoked.get) || (← stopping))
  finally discard <| closeFd upstream

structure Listener where
  port : UInt16
  stopping : IO.Ref Bool
  work : Task (Except IO.Error Unit)

def start (port : UInt16) (key : String) (resolve : String → String → IO (Except String AccountVpnPool.Gateway)) :
    IO (Except String Listener) := do
  if key.isEmpty then return .error "vpn_relay_key_unavailable"
  let .ok (fd, bound) ← tcpListen "127.0.0.1" port 64 | return .error "vpn_relay_bind_failed"
  let stopping ← IO.mkRef false
  let work ← IO.asTask (prio := .dedicated) do
    let workers ← IO.mkRef (#[] : Array (Task (Except IO.Error Unit)))
    try
      while !(← stopping.get) do
        let .ok client ← tcpAcceptPoll fd 250 | continue
        let live ← (← workers.get).filterM (fun task => return !(← IO.hasFinished task))
        if live.size ≥ 64 then
          discard <| closeFd client
        else
          let worker ← IO.asTask (prio := .dedicated) do
            try serve client key resolve stopping.get finally discard <| closeFd client
          workers.set (live.push worker)
    finally
      discard <| closeFd fd
      for worker in ← workers.get do discard <| IO.wait worker
  return .ok ⟨bound, stopping, work⟩

/-- The configured port must survive Core restarts because the credential owner
stores the relay URL. Only a current VPN preference can open its tunnel. -/
def configured (rawPort? : Option String) (operatorKey dir : String) (secure : Bool)
    (pool : AccountVpnPool.Pool) (store : OrbCore.Store.CoreStore) :
    IO (Except String (Option Listener)) := do
  let some raw := rawPort? | return .ok none
  let some n := raw.toNat? | return .error "invalid_airvpn_relay_port"
  if n == 0 || n > 65535 || !secure || operatorKey.isEmpty || dir.isEmpty then
    return .error "invalid_airvpn_relay_configuration"
  let listener ← start n.toUInt16 operatorKey fun provider account => do
    let .ok (some pref) ← AccountVpnRoutes.read store.missionsDb account | return .error "vpn_route_unavailable"
    AccountVpnPool.allocateGateway pool store.rootDir dir store.missionsDb account provider pref
  return listener.map some

def Listener.stop (listener : Listener) : IO Unit := do
  listener.stopping.set true
  discard <| IO.wait listener.work

end OrbCore.AccountVpnRelay
