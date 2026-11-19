import OrbCore.AccountVpnRelay

namespace OrbCore.AccountVpnRelayTests

open LeanSys.Posix OrbNetLeaf.TlsHttp OrbCore.AccountVpnRelay

private def expect (fd : Fd) (bytes : ByteArray) : IO Unit := do
  let some read ← readSocksBytes fd bytes.size ((← IO.monoMsNow) + 4000) | throw (IO.userError "relay timeout")
  unless read == bytes do throw (IO.userError "unexpected relay bytes")

private def write (fd : Fd) (bytes : ByteArray) : IO Unit := do
  unless (← writeAll fd bytes).isOk do throw (IO.userError "relay write failed")

private def login (fd : Fd) (user mac : String) : IO Unit := do
  write fd ⟨#[5, 1, 2]⟩
  expect fd ⟨#[5, 2]⟩
  write fd (⟨#[1, user.utf8ByteSize.toUInt8]⟩ ++ user.toUTF8 ++ ⟨#[mac.utf8ByteSize.toUInt8]⟩ ++ mac.toUTF8)

def run : IO Unit := do
  let .ok (gateway, port) ← tcpListen "127.0.0.1" 0 4 | throw (IO.userError "gateway listen")
  let key := "test-key"
  let user := "openai/acct"
  let mac := password key user
  let calls ← IO.mkRef 0
  let listener ← IO.ofExcept (← start 0 key fun provider account => do
    calls.modify (· + 1)
    if provider == "openai" && account == "acct" then return .ok port
    return .error "no_binding")
  let request := ⟨#[5, 1, 0, 3, 4]⟩ ++ "test".toUTF8 ++ ⟨#[1, 187]⟩
  let accepted : ByteArray := ⟨#[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]⟩
  let connect := do
    let .ok fd ← tcpConnectTimed "127.0.0.1" listener.port 1000 | throw (IO.userError "connect relay")
    pure fd
  try
    let bad ← connect
    try
      login bad "openai/other" mac
      expect bad ⟨#[1, 1]⟩
      unless (← calls.get) == 0 do throw (IO.userError "invalid credential reached allocator")
    finally discard <| closeFd bad
    let blocked ← connect
    try
      login blocked "openai/other" (password key "openai/other")
      expect blocked ⟨#[1, 0]⟩
      write blocked request
      expect blocked ⟨#[5, 2, 0, 1, 0, 0, 0, 0, 0, 0]⟩
    finally discard <| closeFd blocked
    let peer ← IO.asTask (prio := .dedicated) do
      let .ok fd ← tcpAcceptPoll gateway 5000 | throw (IO.userError "inner connection missing")
      try
        expect fd ⟨#[5, 1, 0]⟩
        write fd ⟨#[5, 0]⟩
        expect fd request
        write fd accepted
        expect fd "client".toUTF8
        write fd "server".toUTF8
      finally discard <| closeFd fd
    let good ← connect
    try
      login good user mac
      expect good ⟨#[1, 0]⟩
      write good request
      expect good accepted
      write good "client".toUTF8
      expect good "server".toUTF8
    finally discard <| closeFd good
    IO.ofExcept (← IO.wait peer)
  finally
    listener.stop
    discard <| closeFd gateway

end OrbCore.AccountVpnRelayTests
