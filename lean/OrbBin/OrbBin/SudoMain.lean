/-
  OrbBin.SudoMain: Native Lean `orb-sudo` Client over `/run/orb-privd.sock` (`0 import Lean`).
  Supports `--ping`, `--update-harness <harness> <MAJOR.MINOR.PATCH>`, and JIT-leased
  `<command> [args...]` execution with `ORB_JIT_LEASE` + `ORB_MISSION_ID` / `SANDBOXED_SH_MISSION_ID`.
-/
import LeanSys.Posix
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.PrivdShared

namespace OrbBin.Sudo

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.PrivdShared

def sendPrivdRequest (socketPath : String) (payload : JVal) (isPing : Bool := false) : IO UInt32 := do
  let fd ← match (← LeanSys.Posix.unixConnect socketPath) with
    | .ok f => pure f
    | .error _ =>
      IO.eprintln s!"orb-sudo: failed connecting to {socketPath}"
      return 126
  let wire := ((renderCompact payload) ++ "\n").toUTF8
  match (← LeanSys.Posix.writeAll fd wire) with
  | .error _ =>
    let _ ← LeanSys.Posix.closeFd fd
    IO.eprintln "orb-sudo: failed sending request to orb-privd"
    return 126
  | .ok _ => pure ()
  let _ ← shutdownWr (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
  let mut respBytes := ByteArray.emptyWithCapacity 4096
  while true do
    match (← readSocketTimed fd 65536 610000) with
    | .eof => break
    | .timeout => break
    | .fatal _ => break
    | .bytes chunk => respBytes := respBytes ++ chunk
  let _ ← LeanSys.Posix.closeFd fd
  match Json.parseBytes respBytes with
  | .error err =>
    IO.eprintln s!"orb-sudo: invalid response from orb-privd: {err}"
    return 126
  | .ok resp =>
    if isPing then
      IO.println (renderCompact resp)
      return if (resp.fieldBool? "ok").getD false then 0 else 1
    if let some out := resp.fieldStr? "stdout" then
      if !out.isEmpty then
        IO.print out
    if let some errOut := resp.fieldStr? "stderr" then
      if !errOut.isEmpty then
        IO.eprint errOut
        if !errOut.endsWith "\n" then IO.eprintln ""
    let code := (resp.fieldInt? "exit_code").getD (if (resp.fieldBool? "ok").getD false then 0 else 1)
    if code < 0 then return 126
    return code.toNat.toUInt32

def runMain (args : List String) : IO UInt32 := do
  let sockPath := (← getEnvNonEmpty "ORB_PRIVD_SOCKET").getD defaultPrivdSocket
  match args with
  | [] =>
    IO.eprintln "orb-sudo: command required"
    return 2
  | ["-h"] | ["--help"] =>
    IO.println "Usage:\n  ORB_JIT_LEASE=<token> orb-sudo <command> [args...]\n  orb-sudo --update-harness {claude|codex|opencode|grok|vibe} MAJOR.MINOR.PATCH\n  orb-sudo --ping"
    return 0
  | ["--version"] =>
    IO.println "orb-sudo 1.3.0 (Lean 4)"
    return 0
  | ["--ping"] =>
    sendPrivdRequest sockPath (JVal.obj #[("action", .str "ping")]) true
  | "--update-harness" :: rest =>
    match rest with
    | [harness, ver] =>
      sendPrivdRequest sockPath <| JVal.obj #[
        ("action", .str "update_harness"),
        ("name", .str harness),
        ("version", .str ver)
      ]
    | _ =>
      IO.eprintln "Usage: orb-sudo --update-harness {claude|codex|opencode|grok|vibe} VERSION"
      return 2
  | cmdArgs =>
    let realArgs := match cmdArgs with
      | "--" :: tail => tail
      | other => other
    if realArgs.isEmpty then
      IO.eprintln "orb-sudo: command required"
      return 2
    let lease? ← firstEnvNonEmpty ["ORB_JIT_LEASE", "ORB_PRIVILEGE_LEASE_TOKEN"]
    let mission? ← firstEnvNonEmpty ["ORB_MISSION_ID", "SANDBOXED_SH_MISSION_ID", "MISSION_ID"]
    let (some lease, some missionId) := (lease?, mission?)
      | do
        IO.eprintln "orb-sudo: ORB_JIT_LEASE (and ORB_MISSION_ID / SANDBOXED_SH_MISSION_ID) required."
        return 126
    let cwd ← IO.currentDir
    let targetHost := (← getEnvNonEmpty "ORB_TARGET_HOST").getD "self"
    sendPrivdRequest sockPath <| JVal.obj #[
      ("action", .str "exec"),
      ("lease_token", .str lease),
      ("mission_id", .str missionId),
      ("target_host", .str targetHost),
      ("cwd", .str cwd.toString),
      ("argv", .arr (realArgs.toArray.map .str))
    ]

end OrbBin.Sudo
