import OrbCore.AccountVpnSidecar
import OrbCore.AccountVpnRelay

/-- Fixture entry point for the same management client used by the account
Settings route. The short-lived fixture management key arrives on stdin. -/
def main (args : List String) : IO UInt32 := do
  if let ["relay", first, second] := args then
    let some a := first.toNat? | return 2
    let some b := second.toNat? | return 2
    if a == 0 || b == 0 || a > 65535 || b > 65535 then return 2
    let input ← IO.getStdin
    let key := (← input.getLine).trimAscii.toString
    let unavailable ← IO.mkRef false
    let listener ← IO.ofExcept (← OrbCore.AccountVpnRelay.start 0 key fun provider account => do
      unless provider == "openai" do return .error "unknown_provider"
      match account with
      | "a" => return if ← unavailable.get then .error "vpn_exit_unverified" else .ok a.toUInt16
      | "b" => return .ok b.toUInt16
      | _ => return .error "unknown_account")
    try
      let out ← IO.getStdout
      for account in ["a", "b"] do
        let some url := OrbCore.AccountVpnRelay.proxyUrl key listener.port "openai" account | return 1
        out.putStrLn url
      out.flush
      if (← input.getLine).trimAscii == "drop-a" then
        unavailable.set true
        out.putStrLn "blocked"
        out.flush
        discard input.getLine
      return 0
    finally listener.stop
  let [base, file, relay, mode] := args | return 2
  if !["enable", "disable"].contains mode then return 2
  let key := (← (← IO.getStdin).getLine).trimAscii.toString
  match ← OrbCore.AccountVpnSidecar.configure base key file relay (mode == "enable") with
  | .ok () => return 0
  | .error code =>
    IO.eprintln code
    return 1
