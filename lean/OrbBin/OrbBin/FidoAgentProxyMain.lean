/-
  OrbBin.FidoAgentProxyMain: Native Lean `fido-agent-proxy` SSH Agent FIDO/U2F Proxy (`0 import Lean`).
  Intercepts `SSH_AGENTC_SIGN_REQUEST` (`13`) for `sk-*` hardware security keys, requests live operator
  approval from `POST /api/fido/request`, gates forwarding through `OrbBin.Spec.verifySshSignForward`,
  and proxies permitted frames to `SSH_AUTH_SOCK_UPSTREAM`.
-/
import LeanSys.Posix
import LeanSys.Auth
import OrbBin.Spec
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient

namespace OrbBin.FidoAgentProxy

open OrbBin.Spec
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

def maxAgentMsgLen : Nat := 256 * 1024

def sshAgentFailureFrame : ByteArray :=
  ByteArray.mk #[0, 0, 0, 1, 5]

def sshAgentEmptyIdentitiesFrame : ByteArray :=
  ByteArray.mk #[0, 0, 0, 5, 12, 0, 0, 0, 0]

def skKeyTypes : Array String := #[
  "sk-ssh-ed25519@openssh.com",
  "sk-ecdsa-sha2-nistp256@openssh.com",
  "sk-ssh-ed25519-cert-v01@openssh.com",
  "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com"
]

def isSkKeyType (kt : String) : Bool :=
  skKeyTypes.contains kt

def readU32BE (b : ByteArray) (off : Nat) : Option Nat :=
  if off + 4 > b.size then none
  else
    let b0 := (b.get! off).toUInt32
    let b1 := (b.get! (off + 1)).toUInt32
    let b2 := (b.get! (off + 2)).toUInt32
    let b3 := (b.get! (off + 3)).toUInt32
    some (((b0 <<< 24) ||| (b1 <<< 16) ||| (b2 <<< 8) ||| b3).toNat)

def readSshStringSlice (b : ByteArray) (off : Nat) : Option (ByteArray × Nat) := do
  let len ← readU32BE b off
  if off + 4 + len > b.size then none
  else some (b.extract (off + 4) (off + 4 + len), off + 4 + len)

/-- Parse `SSH_AGENTC_SIGN_REQUEST` (`payload[0] == 13`) to `(keyType, SHA256:<b64-nopad>)`. -/
def parseSignRequestKeyInfo? (payload : ByteArray) : Option (String × String) := do
  if payload.size < 5 || payload.get! 0 != 13 then none
  let (keyBlob, _) ← readSshStringSlice payload 1
  let (keyTypeBytes, _) ← readSshStringSlice keyBlob 0
  let keyType ← String.fromUTF8? keyTypeBytes
  let digest := LeanSys.Auth.sha256Bytes keyBlob
  let fp := "SHA256:" ++ base64Encode digest false false
  return (keyType, fp)

def encodeSshFrame (payload : ByteArray) : ByteArray :=
  let n := payload.size.toUInt32
  let hdr := ByteArray.mk #[
    ((n >>> 24) &&& 0xFF).toUInt8,
    ((n >>> 16) &&& 0xFF).toUInt8,
    ((n >>> 8) &&& 0xFF).toUInt8,
    (n &&& 0xFF).toUInt8
  ]
  hdr ++ payload

/-- Read exact `n` bytes from `fd`, returning `none` on EOF/error. -/
def readExactBytes (fd : LeanSys.Posix.Fd) (n : Nat) (timeoutMs : UInt32 := 300000) : IO (Option ByteArray) := do
  let mut buf := ByteArray.emptyWithCapacity n
  while buf.size < n do
    let rem := n - buf.size
    match (← readSocketTimed fd rem timeoutMs) with
    | .eof => return none
    | .timeout => return none
    | .fatal _ => return none
    | .bytes chunk =>
      if chunk.isEmpty then return none
      buf := buf ++ chunk
  return some buf

/-- Read one framed SSH agent message (`1 ..= 262144` bytes). -/
def readAgentFrame (fd : LeanSys.Posix.Fd) (timeoutMs : UInt32 := 300000) : IO (Option ByteArray) := do
  let some hdr ← readExactBytes fd 4 timeoutMs
    | return none
  let some frameLen := readU32BE hdr 0
    | return none
  if frameLen == 0 || frameLen > maxAgentMsgLen then
    return none
  let some body ← readExactBytes fd frameLen timeoutMs
    | return none
  return parseSshAgentFrame (hdr ++ body)

def forwardToUpstream (upstreamSock : String) (payload : ByteArray) : IO ByteArray := do
  let ufd ← match (← LeanSys.Posix.unixConnect upstreamSock) with
    | .ok f => pure f
    | .error _ =>
      IO.eprintln s!"[fido-agent-proxy] failed to connect upstream SSH agent `{upstreamSock}`"
      return sshAgentFailureFrame
  try
    match (← LeanSys.Posix.writeAll ufd (encodeSshFrame payload)) with
    | .error _ =>
      let _ ← LeanSys.Posix.closeFd ufd
      return sshAgentFailureFrame
    | .ok _ => pure ()
    let respPayload? ← readAgentFrame ufd 60000
    let _ ← LeanSys.Posix.closeFd ufd
    match respPayload? with
    | some rp => return encodeSshFrame rp
    | none => return sshAgentFailureFrame
  catch _ =>
    let _ ← LeanSys.Posix.closeFd ufd
    return sshAgentFailureFrame

def requestFidoApproval
    (apiUrl : String) (apiToken : Option String) (keyType fingerprint : String) : IO Bool := do
  let url := stripTrailingSlash apiUrl ++ "/api/fido/request"
  let body := JVal.obj #[
    ("key_type", .str keyType),
    ("key_fingerprint", .str fingerprint),
    ("origin", .str "ssh")
  ]
  match (← sendJsonRequest "POST" url apiToken (some body) #[] 90000) with
  | .ok (status, _, some j) =>
    if 200 ≤ status && status < 300 then
      return (j.fieldBool? "approved").getD false
    else
      IO.eprintln s!"[fido-agent-proxy] Core returned HTTP {status} for FIDO approval"
      return false
  | .ok (status, _, none) =>
    IO.eprintln s!"[fido-agent-proxy] non-JSON response (HTTP {status}) from Core"
    return false
  | .error err =>
    IO.eprintln s!"[fido-agent-proxy] FIDO request failed: {err}"
    return false

def handleClient (cfd : LeanSys.Posix.Fd) (apiUrl : String) (apiToken upstreamSock : Option String) : IO Unit := do
  try
    while true do
      let some payload ← readAgentFrame cfd 300000
        | break
      let msgType := payload.get! 0
      let mut isSk : UInt8 := 0
      let mut approved : UInt8 := 0
      if msgType == 13 then
        match parseSignRequestKeyInfo? payload with
        | some (kt, fp) =>
          if isSkKeyType kt then
            isSk := 1
            let ok ← requestFidoApproval apiUrl apiToken kt fp
            approved := if ok then 1 else 0
        | none =>
          -- Malformed sign request fails closed.
          let _ ← LeanSys.Posix.writeAll cfd sshAgentFailureFrame
          continue
      match upstreamSock with
      | none =>
        if msgType == 11 then
          let _ ← LeanSys.Posix.writeAll cfd sshAgentEmptyIdentitiesFrame
        else
          let _ ← LeanSys.Posix.writeAll cfd sshAgentFailureFrame
      | some up =>
        if verifySshSignForward payload.size.toUInt32 msgType isSk approved 1 == 1 then
          let reply ← forwardToUpstream up payload
          let _ ← LeanSys.Posix.writeAll cfd reply
        else
          let _ ← LeanSys.Posix.writeAll cfd sshAgentFailureFrame
    let _ ← LeanSys.Posix.closeFd cfd
  catch _ =>
    let _ ← LeanSys.Posix.closeFd cfd

def parseSocketArg (args : List String) : Option String :=
  match args with
  | [] => none
  | "--socket" :: p :: _ => some p
  | _ :: rest => parseSocketArg rest

def runMain (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    IO.println "Usage: fido-agent-proxy [--socket <path>]"
    return 0
  if args.contains "--version" then
    IO.println "fido-agent-proxy 1.3.0 (Lean 4)"
    return 0
  let envSock ← getEnvNonEmpty "FIDO_AGENT_SOCKET"
  let sockPath := (parseSocketArg args).orElse (fun _ => envSock)
    |>.getD "/run/sandboxed-sh/fido-agent.sock"
  let apiUrl := (← getEnvNonEmpty "SANDBOXED_SH_API_URL").getD "http://localhost:3000"
  let apiToken ← getEnvNonEmpty "SANDBOXED_SH_API_TOKEN"
  let upstreamSock ← getEnvNonEmpty "SSH_AUTH_SOCK_UPSTREAM"
  let sp := System.FilePath.mk sockPath
  if let some parent := sp.parent then
    IO.FS.createDirAll parent
  try IO.FS.removeFile sp catch _ => pure ()
  let lfd ← match (← LeanSys.Posix.unixListen sockPath 64) with
    | .ok f => pure f
    | .error e =>
      IO.eprintln s!"[fido-agent-proxy] failed to bind Unix socket `{sockPath}`: {e}"
      return 1
  let _ ← chmod sockPath 0o660
  IO.eprintln s!"[fido-agent-proxy] listening on {sockPath} (api={apiUrl})"
  while true do
    match (← LeanSys.Posix.tcpAcceptPoll lfd 1000) with
    | .ok cfd =>
      let _ ← IO.asTask (prio := .dedicated) (handleClient cfd apiUrl apiToken upstreamSock)
    | .error _ => pure ()
  return 0

end OrbBin.FidoAgentProxy
