/-
  OrbNode.Dial: Dial-Out Enrollment & Reverse Relay Loop for Managed Sandboxes (`src/node/dial.rs`).
  Exchanges `SANDBOXED_NODE_ENROLL_TOKEN` at `<core>/api/managed-machines/enroll` (caching `0600`
  `node.cred`), then long-polls `/api/managed-machines/relay/poll`, forwards each `RelayRequest`
  against the local `127.0.0.1:<port>` listener, and posts `RelayResponse` to `/relay/respond`.
-/
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient

namespace OrbNode.Dial

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

structure DialCredential where
  coreUrl   : String
  machineId : String
  nodeId    : String
  nodeToken : String
  deriving Repr, BEq

def DialCredential.toJson (c : DialCredential) : JVal :=
  .obj #[
    ("core_url", .str c.coreUrl),
    ("machine_id", .str c.machineId),
    ("node_id", .str c.nodeId),
    ("node_token", .str c.nodeToken)
  ]

def DialCredential.fromJson? (v : JVal) : Option DialCredential := do
  let coreUrl ← v.fieldStr? "core_url"
  let machineId ← v.fieldStr? "machine_id"
  let nodeId := (v.fieldStr? "node_id").getD ""
  let nodeToken ← v.fieldStr? "node_token"
  return { coreUrl, machineId, nodeId, nodeToken }

def credentialPath : IO System.FilePath := do
  if let some p ← getEnvNonEmpty "SANDBOXED_NODE_CREDENTIAL_FILE" then
    return System.FilePath.mk p
  let work := (← getEnvNonEmpty "SANDBOXED_NODE_WORK_DIR").getD "/var/lib/sandboxed-node/work"
  let wp := System.FilePath.mk work
  return match wp.parent with
    | some par => par / "node.cred"
    | none => System.FilePath.mk "node.cred"

/-- Enroll with Core when `SANDBOXED_NODE_DIAL_CORE_URL` is configured (or reuse cached `0600` `node.cred`). -/
def enrollFromEnv : IO (Except String (Option DialCredential)) := do
  let some rawCore ← getEnvNonEmpty "SANDBOXED_NODE_DIAL_CORE_URL"
    | return .ok none
  let coreUrl := stripTrailingSlash rawCore.trimAscii.toString
  if coreUrl.isEmpty then return .ok none
  let some machineId ← getEnvNonEmpty "SANDBOXED_NODE_MANAGED_ID"
    | return .error "dial-out mode needs SANDBOXED_NODE_MANAGED_ID"
  let credFile ← credentialPath
  if ← credFile.pathExists then
    if let .ok raw ← IO.FS.readFile credFile |>.toBaseIO then
      if let .ok jv := OrbBin.Json.parse raw then
        if let some cached := DialCredential.fromJson? jv then
          if cached.machineId == machineId && cached.coreUrl == coreUrl && !cached.nodeToken.isEmpty then
            return .ok (some cached)
  let some enrollTok ← getEnvNonEmpty "SANDBOXED_NODE_ENROLL_TOKEN"
    | return .error "dial-out mode needs SANDBOXED_NODE_ENROLL_TOKEN"
  let enrollUrl := s!"{coreUrl}/api/managed-machines/enroll"
  let body := .obj #[("machine_id", .str machineId), ("enroll_token", .str enrollTok)]
  let mut lastErr := "unreachable"
  for attempt in [0:30] do
    match ← sendJsonRequest "POST" enrollUrl none (some body) #[] 30000 with
    | .ok (st, _, some jv) =>
      if 200 ≤ st && st < 300 then
        if let some nodeTok := jv.fieldStr? "node_token" then
          let nodeId := (jv.fieldStr? "node_id").getD ""
          let cred : DialCredential := { coreUrl, machineId, nodeId, nodeToken := nodeTok }
          let serialized := (renderCompact cred.toJson).toUTF8
          if let .error e ← writeAtomicPrivate0600 credFile serialized then
            return .error s!"enroll credential write failed: {e}"
          return .ok (some cred)
        else
          return .error "enroll response missing node_token"
      else if st == 401 then
        return .error "enrollment denied (token used, expired or wrong)"
      else
        lastErr := s!"HTTP {st}"
    | .ok (st, _, none) =>
      if st == 401 then
        return .error "enrollment denied (token used, expired or wrong)"
      lastErr := s!"HTTP {st}"
    | .error e =>
      lastErr := e
    let sleepMs := (min 10 (attempt + 1) * 1000).toUInt32
    IO.sleep sleepMs
  return .error s!"enrollment failed: {lastErr}"

private def forwardToLocal (localPort : UInt16) (reqJson : JVal) : IO JVal := do
  let reqId := (reqJson.fieldStr? "id").getD ""
  let method := ((reqJson.fieldStr? "method").getD "GET").trimAscii.toString.toUpper
  let path := (reqJson.fieldStr? "path").getD "/"
  let timeoutSecs := max 30 ((reqJson.fieldUInt64? "timeout_secs").getD 30).toNat
  let bodyB64 := (reqJson.fieldStr? "body_b64").getD ""
  let body := (base64Decode? bodyB64).getD ByteArray.empty
  let mut hdrs : Array (String × String) := #[]
  if let some rawHdrs := reqJson.fieldArr? "headers" then
    for pair in rawHdrs do
      if let some kv := pair.asArr? then
        if h : kv.size >= 2 then
          if let (some k, some v) := (kv[0].asStr?, kv[1].asStr?) then
            hdrs := hdrs.push (k, v)
  let cleanPath := if path.startsWith "/" then path else "/" ++ path
  let localUrl := s!"http://127.0.0.1:{localPort}{cleanPath}"
  match ← sendRequest method localUrl hdrs body (timeoutSecs * 1000).toUInt32 1073741824 with
  | .error e =>
    return .obj #[
      ("id", .str reqId),
      ("status", JVal.nat 502),
      ("headers", .arr #[.arr #[.str "content-type", .str "text/plain"]]),
      ("body_b64", .str (base64Encode (s!"local node request failed: {e}").toUTF8 false true))
    ]
  | .ok resp =>
    let respHdrs := resp.headers.map fun (k, v) => JVal.arr #[.str k, .str v]
    return .obj #[
      ("id", .str reqId),
      ("status", JVal.nat resp.status),
      ("headers", .arr respHdrs),
      ("body_b64", .str (base64Encode resp.body false true))
    ]

/-- Spawn background dial-out relay loop (`410 Gone` removes `node.cred` and flags `goneRef`). -/
def spawnRelay (cred : DialCredential) (localPort : UInt16) (goneRef : IO.Ref Bool) : IO (Task (Except IO.Error Unit)) :=
  IO.asTask do
    let pollUrl := s!"{cred.coreUrl}/api/managed-machines/relay/poll"
    let respondUrl := s!"{cred.coreUrl}/api/managed-machines/relay/respond"
    let extraHdrs := #[("x-orb-machine-id", cred.machineId)]
    let mut backoffMs : UInt32 := 1000
    while !(← goneRef.get) do
      match ← sendJsonRequest "GET" pollUrl (some cred.nodeToken) none extraHdrs 60000 134217728 with
      | .ok (410, _, _) =>
        let cp ← credentialPath
        try IO.FS.removeFile cp catch _ => pure ()
        goneRef.set true
        break
      | .ok (st, _, some (.arr reqs)) =>
        if 200 ≤ st && st < 300 then
          backoffMs := 1000
          for reqJson in reqs do
            let _ ← IO.asTask do
              let respJson ← forwardToLocal localPort reqJson
              let _ ← sendJsonRequest "POST" respondUrl (some cred.nodeToken) (some respJson) extraHdrs 600000
        else
          IO.sleep backoffMs
          backoffMs := min 15000 (backoffMs * 2)
      | _ =>
        IO.sleep backoffMs
        backoffMs := min 15000 (backoffMs * 2)

end OrbNode.Dial
