/-
  OrbNode.Server: Complete Concurrent HTTP/1.1 `:3088` Worker Server & Route Dispatcher
  enforcing `OrbNode.Spec` Bearer & HMAC Lease Gates across all 26 routes.
-/
import Std.Sync.Mutex
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Spec
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store
import OrbNode.Dial
import OrbNode.LeanBuild
import OrbNode.FileBrowser
import OrbNode.Transfer
import OrbNode.ProjectContext
import OrbNode.Runner

namespace OrbNode.Server

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.Spec
open OrbNode.Lease
open OrbNode.Store
open OrbNode.LeanBuild
open OrbNode.FileBrowser
open OrbNode.Transfer
open OrbNode.ProjectContext
open OrbNode.Runner

structure HttpRequest where
  method  : String
  rawPath : String
  path    : String
  query   : Array (String × String)
  headers : Array (String × String)
  body    : ByteArray
  deriving Inhabited

def HttpRequest.header? (req : HttpRequest) (nameLower : String) : Option String :=
  (req.headers.find? (fun (k, _) => k == nameLower)).map Prod.snd

def HttpRequest.query? (req : HttpRequest) (key : String) : Option String :=
  (req.query.find? (fun (k, _) => k == key)).map Prod.snd

structure HttpResponse where
  status      : Nat
  contentType : String := "application/json"
  body        : ByteArray
  deriving Inhabited

def jsonResp (status : Nat) (v : JVal) : HttpResponse :=
  { status := status, contentType := "application/json", body := (renderCompact v).toUTF8 }

def textResp (status : Nat) (msg : String) : HttpResponse :=
  { status := status, contentType := "text/plain; charset=utf-8", body := msg.toUTF8 }

private def statusReason : Nat → String
  | 200 => "OK"
  | 202 => "Accepted"
  | 204 => "No Content"
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 404 => "Not Found"
  | 409 => "Conflict"
  | 413 => "Payload Too Large"
  | 422 => "Unprocessable Entity"
  | 429 => "Too Many Requests"
  | 503 => "Service Unavailable"
  | _   => "Internal Server Error"

def encodeHttpResponse (resp : HttpResponse) : ByteArray :=
  let head :=
    s!"HTTP/1.1 {resp.status} {statusReason resp.status}\r\n" ++
    s!"Content-Type: {resp.contentType}\r\n" ++
    s!"Content-Length: {resp.body.size}\r\n" ++
    "Connection: close\r\n\r\n"
  head.toUTF8 ++ resp.body

private def hexNibble? (c : Char) : Option UInt8 :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat).toUInt8
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10).toUInt8
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10).toUInt8
  else none

def urlDecode (s : String) : String := Id.run do
  let chars := s.toList.toArray
  let mut out := ByteArray.emptyWithCapacity chars.size
  let mut i := 0
  while i < chars.size do
    let c := chars[i]!
    if c == '+' then
      out := out.push 32
      i := i + 1
    else if c == '%' && i + 2 < chars.size then
      match hexNibble? chars[i + 1]!, hexNibble? chars[i + 2]! with
      | some hi, some lo =>
        out := out.push ((hi <<< 4) ||| lo)
        i := i + 3
      | _, _ =>
        out := out ++ c.toString.toUTF8
        i := i + 1
    else
      out := out ++ c.toString.toUTF8
      i := i + 1
  return String.fromUTF8? out |>.getD s

def parsePathAndQuery (raw : String) : String × Array (String × String) :=
  match raw.splitOn "?" with
  | [] => ("/", #[])
  | [p] => (p, #[])
  | p :: rest =>
    let qs := String.intercalate "?" rest
    let pairs := (qs.splitOn "&").toArray.filterMap fun item =>
      if item.isEmpty then none
      else match item.splitOn "=" with
        | [] => none
        | [k] => some (urlDecode k, "")
        | k :: vs => some (urlDecode k, urlDecode (String.intercalate "=" vs))
    (p, pairs)

private def findHeaderEnd? (buf : ByteArray) : Option Nat := Id.run do
  if buf.size < 4 then return none
  for i in [0 : buf.size - 3] do
    if buf.get! i == 13 && buf.get! (i + 1) == 10 &&
       buf.get! (i + 2) == 13 && buf.get! (i + 3) == 10 then
      return some i
  return none

/-- Read a bounded HTTP/1.1 request (`<= 128 MiB`, per-route limits enforced below) from `cfd`. -/
def readHttpRequest (cfd : UInt32) (maxBodyBytes : Nat := 134217728) : IO (Except String HttpRequest) := do
  let mut buf := ByteArray.emptyWithCapacity 8192
  let mut hdrEnd? : Option Nat := none
  while hdrEnd?.isNone && buf.size < 65536 do
    let chunk ← OrbNode.Posix.fdRead cfd 16384
    if chunk.isEmpty then break
    buf := buf ++ chunk
    hdrEnd? := findHeaderEnd? buf
  let some hdrEnd := hdrEnd?
    | return .error "incomplete HTTP header"
  let hdrBytes := buf.extract 0 hdrEnd
  let some hdrText := String.fromUTF8? hdrBytes
    | return .error "non-UTF8 HTTP header"
  let lines := hdrText.splitOn "\r\n"
  let reqLine :: rawHdrs := lines
    | return .error "empty HTTP request"
  let reqParts := reqLine.splitOn " "
  let method :: rawTarget :: _ := reqParts
    | return .error "malformed HTTP request line"
  let mut headers : Array (String × String) := #[]
  let mut contentLen : Nat := 0
  for hl in rawHdrs do
    if let p :: vs := hl.splitOn ":" then
      let k := p.trimAscii.toString.toLower
      let v := (String.intercalate ":" vs).trimAscii.toString
      headers := headers.push (k, v)
      if k == "content-length" then
        contentLen := v.toNat?.getD 0
  if contentLen > maxBodyBytes then
    return .error "payload_too_large"
  let bodyStart := hdrEnd + 4
  let mut body := if bodyStart < buf.size then buf.extract bodyStart buf.size else ByteArray.empty
  while body.size < contentLen do
    let want := min 65536 (contentLen - body.size)
    let chunk ← OrbNode.Posix.fdRead cfd (USize.ofNat want)
    if chunk.isEmpty then break
    body := body ++ chunk
  if body.size > contentLen then
    body := body.extract 0 contentLen
  let (path, query) := parsePathAndQuery rawTarget
  return .ok {
    method := method.toUpper
    rawPath := rawTarget
    path := path
    query := query
    headers := headers
    body := body
  }

private def readLogTail64K (logPath? : Option String) : IO (Option String) :=
  readJobLogTailBounded logPath? 65536

private def scanSoftwareInventory : IO JVal := do
  let candidates := #[
    ("sandboxed-node", "sandboxed-node", "--version"),
    ("turbo-lean", "turbo-lean", "--version"),
    ("lean", "lean", "--version"),
    ("lake", "lake", "--version"),
    ("git", "git", "--version"),
    ("codex", "codex", "--version"),
    ("opencode", "opencode", "--version"),
    ("claude", "claude", "--version"),
    ("agy", "agy", "--version")
  ]
  let mut comps : Array JVal := #[]
  for (cid, bin, flag) in candidates do
    let res ← (IO.Process.output { cmd := bin, args := #[flag] }).toBaseIO
    match res with
    | .ok out =>
      if out.exitCode == 0 then
        let ver := ((out.stdout.splitOn "\n").headD "").trimAscii.toString
        comps := comps.push (.obj #[
          ("id", .str cid),
          ("installed", .bool true),
          ("version", .str ver)
        ])
    | .error _ => pure ()
  return .obj #[("target", .str "Node runner"), ("components", .arr comps), ("active_update", .null)]

private def discoverAntigravityModels (ma : ManagedAuthConfig) (slot? : Option String) : IO (Except (Nat × String) JVal) := do
  let cleanSlot? := slot?.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  let profile ← match cleanSlot? with
    | some sl =>
      if !validAntigravitySlot sl then
        return .error (400, "Invalid Antigravity slot identifier")
      pure s!"antigravity:{sl}"
    | none => pure "antigravity"
  let nonce ← newUuidV4
  let tmpHome := s!"/tmp/orb-node-ag-models-{nonce}"
  IO.FS.createDirAll tmpHome
  match ← prepareManagedAuthWorkspace ma #[profile] tmpHome with
  | .error e =>
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpHome] }
    return .error (503, e)
  | .ok _ =>
    let res ← (IO.Process.output {
      cmd := "agy"
      args := #["models", "--json"]
      env := #[("HOME", some tmpHome)]
    }).toBaseIO
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpHome] }
    match res with
    | .error _ => return .ok (.arr #[])
    | .ok out =>
      if out.exitCode != 0 then return .ok (.arr #[])
      match OrbBin.Json.parse out.stdout with
      | .ok (.arr xs) => return .ok (.arr xs)
      | _ => return .ok (.arr #[])

/-- Core route dispatcher over `NodeRuntime` returning `(updatedRuntime, response, pendingLaunches, steerWatchers)`
    so `handleRequestConcurrent` runs blocking checkout preparation and tool-steer watchers outside `Std.Mutex`. -/
def handleNonExecRequestCore (rt0 : NodeRuntime) (req : HttpRequest) :
    IO (NodeRuntime × HttpResponse × Array PendingAsyncLaunch × Array (String × UInt64)) := do
  let (rt, preLaunches) ← tickRuntimeReserve rt0
  if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
    return (rt, textResp 401 "invalid node token", preLaunches, #[])
  let segs := (req.path.splitOn "/").filter (fun s => !s.isEmpty)
  let nowEp ← OrbNode.Posix.nowEpoch
  match req.method, segs with
  | "GET", ["heartbeat"] =>
    let hb ← buildHeartbeatJson rt
    return (rt, jsonResp 200 hb, preLaunches, #[])
  | "POST", ["capacity"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let some leaseTok := jv.fieldStr? "lease_token"
      | return (rt, textResp 400 "missing lease_token", preLaunches, #[])
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .nodeCapacity nowEp none with
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
    | .ok claims =>
      if claims.missionId != "00000000-0000-0000-0000-000000000000" then
        return (rt, textResp 400 "node:capacity lease must use nil mission_id", preLaunches, #[])
      let some targetCap := jv.fieldNat? "capacity"
        | return (rt, textResp 400 "missing capacity", preLaunches, #[])
      let targetCoord? := (jv.fieldNat? "coordinator_capacity").map (·.toUInt32)
      match ← resizeCapacity rt targetCap.toUInt32 targetCoord? true with
      | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
      | .ok rt' =>
        let (rtTicked, postLaunches) ← tickRuntimeReserve rt'
        let hb ← buildHeartbeatJson rtTicked
        return (rtTicked, jsonResp 200 hb, preLaunches ++ postLaunches, #[])
  | "POST", ["jobs"] =>
    if req.body.size > 54525952 then
      return (rt, textResp 413 "payload too large", preLaunches, #[])
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let (some rawJobId, some rawMissionId, some leaseTok, some payloadVal) :=
        (jv.fieldStr? "job_id", jv.fieldStr? "mission_id", jv.fieldStr? "lease_token", jv.field? "payload")
      | return (rt, textResp 400 "missing job_id, mission_id, lease_token, or payload", preLaunches, #[])
    let (some jobId, some missionId) := (parseUuidCanonical? rawJobId, parseUuidCanonical? rawMissionId)
      | return (rt, textResp 400 "job_id and mission_id must be valid UUIDs", preLaunches, #[])
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .jobSubmit nowEp none with
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease is scoped to a different mission", preLaunches, #[])
      if let some cid := claims.jobId? then
        if cid != jobId then
          return (rt, textResp 400 "lease is scoped to a different job", preLaunches, #[])
      let kind := (payloadVal.fieldStr? "kind").getD "raw_command"
      if kind == "lean_build" then
        if let .error err := validateLeanBuildPayload payloadVal rt.cfg.envAllowlist then
          return (rt, textResp 422 err, preLaunches, #[])
        let st ← OrbNode.Posix.hostStats rt.cfg.workDir
        let estDisk := (payloadVal.fieldUInt64? "estimated_disk_bytes").getD 0
        let availAfterEst := if st.diskAvailBytes > estDisk then st.diskAvailBytes - estDisk else 0
        if verifyNodeCapacityDisk rt.cfg.capacityTotal rt.cfg.coordinatorCapacity availAfterEst rt.cfg.minFreeDiskBytes 0 0 != 1 then
          return (rt, textResp 422 "insufficient free disk space below min_free_disk_bytes floor", preLaunches, #[])
      else if kind == "raw_command" then
        let longRunning := (payloadVal.fieldBool? "long_running").getD false
        if !longRunning then
          let reqAuth := ((payloadVal.fieldArr? "managed_auth").getD #[]).filterMap JVal.asStr?
          if !reqAuth.isEmpty then
            if let .error err ← validateManagedAuthRequest rt.cfg.managedAuth reqAuth then
              return (rt, textResp 422 err, preLaunches, #[])
      else
        return (rt, textResp 422 s!"unknown job kind '{kind}'", preLaunches, #[])
      if rt.ledger.jobs.contains jobId then
        return (rt, textResp 409 s!"job {jobId} already exists", preLaunches, #[])
      if rt.queueOrder.size >= rt.cfg.maxQueued then
        return (rt, textResp 429 "node job queue full", preLaunches, #[])
      let nowTs ← nowRfc3339
      let logPath := (System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jobId}.log").toString
      let persistedPayload := sanitizePersistedPayload payloadVal
      let jobRec : JobRecord := {
        jobId := jobId
        missionId := missionId
        payloadJson := renderCompact persistedPayload
        state := .queued
        createdAt := nowTs
        logPath? := some logPath
      }
      match ← rt.ledger.insertQueued jobRec with
      | .error "duplicate_job_id" => return (rt, textResp 409 s!"job {jobId} already exists", preLaunches, #[])
      | .error msg => return (rt, textResp 503 msg, preLaunches, #[])
      | .ok l' =>
        let rtQueued := {
          rt with
          ledger := l'
          queuedPayloads := rt.queuedPayloads.insert jobId payloadVal
          queueOrder := rt.queueOrder.push jobId
        }
        let (rtReserved, postLaunches) ← tickRuntimeReserve rtQueued
        return (rtReserved, jsonResp 202 (.obj #[("job_id", .str jobId), ("state", .str "queued")]),
          preLaunches ++ postLaunches, #[])
  | "GET", ["jobs"] =>
    let lim := (req.query? "limit" >>= String.toNat?).getD 20
    let recs := rt.ledger.listRecent lim
    return (rt, jsonResp 200 (.arr (recs.map (fun r => r.toStatusJson none))), preLaunches, #[])
  | "GET", ["jobs", jid] =>
    let key := (parseUuidCanonical? jid).getD jid
    let some rec := rt.ledger.jobs.get? key
      | return (rt, textResp 404 "job not found", preLaunches, #[])
    let tail? ← readLogTail64K rec.logPath?
    return (rt, jsonResp 200 (rec.toStatusJson tail?), preLaunches, #[])
  | "GET", ["jobs", jid, "log"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let some rec := rt.ledger.jobs.get? key
      | return (rt, textResp 404 "job not found", preLaunches, #[])
    let off := (req.query? "offset" >>= String.toNat?).getD 0
    let maxB := (req.query? "max_bytes" >>= String.toNat?).getD 262144
    let sl ← readJobLogSliceBounded rec.logPath? off.toUInt64 maxB
    return (rt, jsonResp 200 (.obj #[
      ("job_id", .str key),
      ("offset", JVal.uint64 sl.offset),
      ("next_offset", JVal.uint64 sl.nextOffset),
      ("log_len", JVal.uint64 sl.logLen),
      ("data", .str sl.data),
      ("state", .str rec.state.asString)
    ]), preLaunches, #[])
  | "POST", ["jobs", jid, "cancel"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let actor := (req.header? "x-sandboxed-cancel-actor").getD "unknown"
    let reason := (req.header? "x-sandboxed-cancel-reason").getD "Cancellation requested without reason"
    match ← cancelJob rt key actor reason with
    | .error "not_found" => return (rt, textResp 404 s!"job {key} not found", preLaunches, #[])
    | .error msg => return (rt, textResp 500 msg, preLaunches, #[])
    | .ok (rt', updated) =>
      let (rtTicked, postLaunches) ← tickRuntimeReserve rt'
      return (rtTicked, jsonResp 200 (.obj #[
        ("job_id", .str key),
        ("state", .str updated.state.asString),
        ("cancel_requested", .bool true)
      ]), preLaunches ++ postLaunches, #[])
  | "POST", ["jobs", jid, "interrupt"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let mode ← match String.fromUTF8? req.body with
      | some s =>
        match OrbBin.Json.parse s with
        | .ok jv => pure ((jv.fieldStr? "mode").getD "interrupt_now")
        | .error _ => pure "interrupt_now"
      | none => pure "interrupt_now"
    match ← interruptJob rt key mode with
    | .error "not_found" => return (rt, textResp 404 s!"job {key} not found", preLaunches, #[])
    | .error msg => return (rt, textResp 500 msg, preLaunches, #[])
    | .ok (rt', respObj, watchPid?) =>
      let watchers := match watchPid? with | some p => #[(key, p)] | none => #[]
      let (rtTicked, postLaunches) ← tickRuntimeReserve rt'
      return (rtTicked, jsonResp 200 respObj, preLaunches ++ postLaunches, watchers)
  | "POST", ["jobs", jid, "force"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let (some rawMissionId, some leaseTok) := (jv.fieldStr? "mission_id", jv.fieldStr? "lease_token")
      | return (rt, textResp 400 "missing mission_id or lease_token", preLaunches, #[])
    let missionId := (parseUuidCanonical? rawMissionId).getD rawMissionId
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .jobForce nowEp (some key) with
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease is scoped to a different mission", preLaunches, #[])
      let some rec := rt.ledger.jobs.get? key
        | return (rt, textResp 404 s!"job {key} not found", preLaunches, #[])
      if rec.missionId != missionId then
        return (rt, textResp 400 "job belongs to a different mission", preLaunches, #[])
      match reserveForceJob rt key with
      | .error "not_found" => return (rt, textResp 404 s!"job {key} not found", preLaunches, #[])
      | .error "not_queued" => return (rt, textResp 409 s!"job {key} is not queued", preLaunches, #[])
      | .error "force_slot_busy" => return (rt, textResp 409 "Force-start slot is already in use on this node", preLaunches, #[])
      | .error msg => return (rt, textResp 500 msg, preLaunches, #[])
      | .ok (rt', forceLaunch, updated) =>
        return (rt', jsonResp 200 (.obj #[
          ("job_id", .str key),
          ("state", .str updated.state.asString),
          ("forced", .bool true)
        ]), preLaunches.push forceLaunch, #[])
  | "POST", ["jobs", jid, "files"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let some rec := rt.ledger.jobs.get? key
      | return (rt, textResp 404 "Job not found", preLaunches, #[])
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok reqJson := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let missionDir := (System.FilePath.mk rt.cfg.workDir / rec.missionId).toString
    match ← executeFileBrowser missionDir reqJson with
    | .ok v => return (rt, jsonResp 200 v, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "GET", ["fs", "list"] =>
    let rawPath := (req.query? "path").getD ""
    match ← listNodeFsDir rt.cfg.workDir rawPath with
    | .ok v => return (rt, jsonResp 200 v, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "POST", ["fs", "mkdir"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let some p := jv.fieldStr? "path"
      | return (rt, textResp 400 "missing path", preLaunches, #[])
    let target := resolveNodeFsPath rt.cfg.workDir p
    match ← (IO.FS.createDirAll target).toBaseIO with
    | .ok () => return (rt, jsonResp 200 (.obj #[("ok", .bool true)]), preLaunches, #[])
    | .error e => return (rt, textResp 400 s!"Cannot create directory '{target}': {e}", preLaunches, #[])
  | "POST", ["uploads"] =>
    if req.body.size > 30 * 1024 * 1024 then
      return (rt, textResp 413 "payload too large", preLaunches, #[])
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    match ← storeSingleUpload rt.cfg.workDir jv with
    | .ok receipt => return (rt, jsonResp 200 receipt, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "POST", ["uploads", "sessions"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    match ← initOrStatusUploadSession rt.cfg.workDir jv with
    | .ok status => return (rt, jsonResp 200 status, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "PUT", ["uploads", "sessions", uid, "chunks", idxStr] =>
    if req.body.size > maxChunkBytes then
      return (rt, textResp 413 "chunk too large", preLaunches, #[])
    let some idx := idxStr.toNat?
      | return (rt, textResp 400 "invalid chunk index", preLaunches, #[])
    match ← writeUploadSessionChunk rt.cfg.workDir uid idx req.body with
    | .ok status => return (rt, jsonResp 200 status, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "POST", ["uploads", "sessions", uid, "complete"] =>
    match ← completeUploadSession rt.cfg.workDir uid with
    | .ok receipt => return (rt, jsonResp 200 receipt, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "DELETE", ["uploads", "sessions", uid] =>
    match ← cancelUploadSession rt.cfg.workDir uid with
    | .ok () => return (rt, { status := 204, contentType := "text/plain; charset=utf-8", body := ByteArray.empty }, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | "GET", ["machine-transfer", "capabilities"] =>
    let harnesses ← detectTransferHarnesses rt.cfg.managedAuth
    return (rt, jsonResp 200 (.obj #[
      ("version", JVal.nat 2),
      ("harnesses", .arr (harnesses.map .str)),
      ("features", .arr #[.str "links", .str "selection", .str "archive-zstd-v1"])
    ]), preLaunches, #[])
  | "POST", ["machine-transfer", "files"] =>
    if req.body.size > 16 * 1024 * 1024 then
      return (rt, textResp 413 "payload too large", preLaunches, #[])
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let (some rawMid, some rawTid, some side, some opVal) :=
        (jv.fieldStr? "mission_id", jv.fieldStr? "transfer_id", jv.fieldStr? "side", jv.field? "operation")
      | return (rt, textResp 400 "missing mission_id, transfer_id, side, or operation", preLaunches, #[])
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return (rt, textResp 400 "invalid UUID", preLaunches, #[])
    if side != "source" && side != "destination" then
      return (rt, textResp 400 "Invalid side", preLaunches, #[])
    let srcMid := ((jv.fieldStr? "source_mission_id") >>= parseUuidCanonical?).getD mid
    if rt.ledger.missionHasLiveJobs mid || rt.ledger.missionHasLiveJobs srcMid then
      return (rt, textResp 409 "Source execution has not terminated", preLaunches, #[])
    let area := System.FilePath.mk rt.cfg.workDir / ".transfers" / tid / side
    let srcTransfer? := (jv.fieldStr? "source_transfer") >>= parseUuidCanonical?
    let sourceDir := match srcTransfer? with
      | some stid => System.FilePath.mk rt.cfg.workDir / ".transfers" / stid / "destination" / "workspace"
      | none => System.FilePath.mk rt.cfg.workDir / srcMid
    let opName := (opVal.fieldStr? "op").getD ""
    if side == "source" && srcTransfer?.isNone && (opName == "inventory" || opName == "snapshot") then
      let sst ← statPath sourceDir.toString
      let wst ← statPath rt.cfg.workDir
      if !sst.exists_ && wst.exists_ && wst.isDir && !wst.isSymlink then
        IO.FS.createDirAll sourceDir
    match ← operateTransfer area (some sourceDir) opVal with
    | .ok res => return (rt, jsonResp 200 res, preLaunches, #[])
    | .error msg => return (rt, textResp 409 msg, preLaunches, #[])
  | "POST", ["machine-transfer", "archive", "pack"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let (some rawMid, some rawTid) := (jv.fieldStr? "mission_id", jv.fieldStr? "transfer_id")
      | return (rt, textResp 400 "missing mission_id or transfer_id", preLaunches, #[])
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return (rt, textResp 400 "invalid UUID", preLaunches, #[])
    let srcMid := ((jv.fieldStr? "source_mission_id") >>= parseUuidCanonical?).getD mid
    if rt.ledger.missionHasLiveJobs mid || rt.ledger.missionHasLiveJobs srcMid then
      return (rt, textResp 409 "Source execution has not terminated", preLaunches, #[])
    let area := System.FilePath.mk rt.cfg.workDir / ".transfers" / tid / "source"
    match ← packTransferArchive area with
    | .ok zstBytes =>
      return (rt, { status := 200, contentType := "application/zstd", body := zstBytes }, preLaunches, #[])
    | .error msg =>
      return (rt, textResp 409 msg, preLaunches, #[])
  | "POST", ["machine-transfer", "archive", "unpack"] =>
    let (some rawMid, some rawTid) := (req.query? "mission_id", req.query? "transfer_id")
      | return (rt, textResp 400 "missing mission_id or transfer_id query parameter", preLaunches, #[])
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return (rt, textResp 400 "invalid UUID", preLaunches, #[])
    if rt.ledger.missionHasLiveJobs mid then
      return (rt, textResp 409 "Source execution has not terminated", preLaunches, #[])
    let area := System.FilePath.mk rt.cfg.workDir / ".transfers" / tid / "destination"
    match ← unpackTransferArchive area req.body with
    | .ok written => return (rt, jsonResp 200 (.obj #[("ok", .bool true), ("bytes", JVal.uint64 written)]), preLaunches, #[])
    | .error msg => return (rt, textResp 409 msg, preLaunches, #[])
  | "POST", ["machine-transfer", "browse"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let (some rawTid, some opVal) := (jv.fieldStr? "transfer_id", jv.field? "operation")
      | return (rt, textResp 400 "missing transfer_id or operation", preLaunches, #[])
    let some tid := parseUuidCanonical? rawTid
      | return (rt, textResp 400 "invalid transfer_id UUID", preLaunches, #[])
    let area := System.FilePath.mk rt.cfg.workDir / ".transfers" / tid / "destination"
    if !(← (area / "verified").pathExists) then
      return (rt, textResp 409 "Workspace is not verified", preLaunches, #[])
    match ← executeFileBrowser (area / "workspace").toString opVal with
    | .ok res => return (rt, jsonResp 200 res, preLaunches, #[])
    | .error msg => return (rt, textResp 409 msg, preLaunches, #[])
  | "PUT", ["managed-auth", "antigravity"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let slot? := req.query? "slot"
    let updateDefault := match req.query? "default" with
      | some "false" | some "0" => false
      | _ => true
    match ← installAntigravityAuth rt.cfg.managedAuth slot? updateDefault jv with
    | .ok res => return (rt, jsonResp 200 res, preLaunches, #[])
    | .error msg =>
      if msg.startsWith "conflict:" then return (rt, textResp 409 (msg.drop 9).toString, preLaunches, #[])
      else if msg.startsWith "bad_request:" then return (rt, textResp 400 (msg.drop 12).toString, preLaunches, #[])
      else return (rt, textResp 500 msg, preLaunches, #[])
  | "GET", ["antigravity", "models"] =>
    match ← discoverAntigravityModels rt.cfg.managedAuth (req.query? "slot") with
    | .ok res => return (rt, jsonResp 200 res, preLaunches, #[])
    | .error (code, msg) => return (rt, textResp code msg, preLaunches, #[])
  | "GET", ["software"] =>
    let inv ← scanSoftwareInventory
    return (rt, jsonResp 200 inv, preLaunches, #[])
  | "POST", ["software", "updates"] =>
    return (rt, textResp 400 "Automated self-updates are managed out-of-band on native Lean nodes", preLaunches, #[])
  | "POST", ["software", "updates", "cancel"] =>
    return (rt, jsonResp 200 (.obj #[("ok", .bool true)]), preLaunches, #[])
  | "POST", ["project-context", "prepare"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    match ← prepareNodeProjectContext rt.cfg.workDir jv with
    | .ok res => return (rt, jsonResp 200 res, preLaunches, #[])
    | .error msg => return (rt, textResp 400 msg, preLaunches, #[])
  | _, _ =>
    return (rt, textResp 404 "route not found", preLaunches, #[])

/-- Synchronous wrapper over `handleNonExecRequestCore` (used by `SelfTest` / `handleRequest`). -/
def handleNonExecRequest (rt0 : NodeRuntime) (req : HttpRequest) : IO (NodeRuntime × HttpResponse) := do
  let (rtReserved, resp, launches, _) ← handleNonExecRequestCore rt0 req
  let mut rt := rtReserved
  for item in launches do
    let prepRes ← prepareJobOutsideLock item.cfg item.jid item.missionId item.payload item.logPath
      item.forced item.sideLane item.coordLane
    rt ← commitPreparedJob rt item.jid prepRes
  return (rt, resp)

/-- Spawn background `IO.asTask` workers for `PendingAsyncLaunch` items outside `Std.Mutex NodeRuntime`. -/
private partial def spawnAsyncLaunches (mtx : Std.Mutex NodeRuntime) (launches : Array PendingAsyncLaunch) : IO Unit := do
  for item in launches do
    let _ ← IO.asTask do
      let prepRes ← match ← (prepareJobOutsideLock item.cfg item.jid item.missionId item.payload item.logPath
          item.forced item.sideLane item.coordLane).toBaseIO with
        | .ok r => pure r
        | .error e => pure (.error s!"unexpected launch exception: {e}")
      let more ← mtx.atomically do
        let rt ← get
        let rtCommitted ← commitPreparedJob rt item.jid prepRes
        let (rtNext, nextLaunches) ← tickRuntimeReserve rtCommitted
        set rtNext
        return nextLaunches
      if !more.isEmpty then
        spawnAsyncLaunches mtx more

/-- Spawn background `100ms` watcher for `steer_between_tools` so turn cancellation triggers promptly
    even when no HTTP traffic arrives before the next `tcpAccept` timeout. -/
private def spawnSteerWatchers (mtx : Std.Mutex NodeRuntime) (watchers : Array (String × UInt64)) : IO Unit := do
  for (jid, rootPid) in watchers do
    let _ ← IO.asTask do
      let mut done := false
      while !done do
        IO.sleep 100
        let (stillActive, scopeUnit?) ← mtx.atomically do
          let rt ← get
          match rt.liveProcs.get? jid with
          | some lp => return (lp.pid == rootPid && lp.steerAfterTool, lp.systemdScope?.map (·.unit))
          | none => return (false, none)
        if !stillActive then
          done := true
        else
          let inflight ← collectInflightChildToolPids rootPid scopeUnit?
          if inflight.isEmpty then
            IO.sleep 120
            let nextLaunches ← mtx.atomically do
              let rt ← get
              if let .ok (rt', _) ← cancelJob rt jid "core" "Steered immediately after tool call completed" then
                let (rtNext, more) ← tickRuntimeReserve rt'
                set rtNext
                return more
              return #[]
            if !nextLaunches.isEmpty then
              spawnAsyncLaunches mtx nextLaunches
            done := true

/-- Direct single-threaded route handler over `NodeRuntime` (used by `SelfTest`). -/
def handleRequest (rt0 : NodeRuntime) (req : HttpRequest) : IO (NodeRuntime × HttpResponse) := do
  let segs := (req.path.splitOn "/").filter (fun s => !s.isEmpty)
  if req.method == "POST" && segs == ["execute"] then
    let rt ← tickRuntime rt0
    if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
      return (rt, textResp 401 "invalid node token")
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let (some rawMid, some leaseTok, some command) :=
        (jv.fieldStr? "mission_id", jv.fieldStr? "lease_token", jv.fieldStr? "command")
      | return (rt, textResp 400 "missing mission_id, lease_token, or command")
    let missionId := (parseUuidCanonical? rawMid).getD rawMid
    let nowEp ← OrbNode.Posix.nowEpoch
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .missionExecute nowEp none with
    | .error msg => return (rt, textResp 400 msg)
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease mission_id mismatch")
      let sideLane := (jv.fieldBool? "side_lane").getD false
      let (stCode, outVal) ← runSyncExecute rt missionId command sideLane
      if stCode == 200 then return (rt, jsonResp 200 outVal)
      else return (rt, textResp stCode (outVal.asStr?.getD "execution rejected"))
  else
    handleNonExecRequest rt0 req

/-- Concurrent `Std.Mutex NodeRuntime` route handler:
    - `POST /execute`, `POST /project-context/prepare`, and async job checkout preparation ALL execute
      outside `Std.Mutex NodeRuntime` so slow network/git/command I/O never blocks `/heartbeat`, `/cancel`,
      `/jobs/:id/log`, or deadline enforcement! -/
def handleRequestConcurrent (mtx : Std.Mutex NodeRuntime) (req : HttpRequest) : IO HttpResponse := do
  let segs := (req.path.splitOn "/").filter (fun s => !s.isEmpty)
  if req.method == "POST" && segs == ["execute"] then
    let (prep, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      let some bodyStr := String.fromUTF8? req.body
        | return (Except.error (textResp 400 "invalid UTF-8 body"), preL)
      let .ok jv := OrbBin.Json.parse bodyStr
        | return (Except.error (textResp 400 "invalid JSON body"), preL)
      let (some rawMid, some leaseTok, some command) :=
          (jv.fieldStr? "mission_id", jv.fieldStr? "lease_token", jv.fieldStr? "command")
        | return (Except.error (textResp 400 "missing mission_id, lease_token, or command"), preL)
      let missionId := (parseUuidCanonical? rawMid).getD rawMid
      let nowEp ← OrbNode.Posix.nowEpoch
      match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .missionExecute nowEp none with
      | .error msg => return (Except.error (textResp 400 msg), preL)
      | .ok claims =>
        if claims.missionId != missionId then
          return (Except.error (textResp 400 "lease mission_id mismatch"), preL)
        let sideLane := (jv.fieldBool? "side_lane").getD false
        if sideLane then
          if activeSideCount rt >= rt.cfg.sideCapacity then
            return (Except.error (textResp 429 "node side-lane capacity exhausted"), preL)
          set { rt with activeExecSide := rt.activeExecSide + 1 }
        else
          if activeRegularCount rt + rt.shrinkDebt >= rt.cfg.capacityTotal then
            return (Except.error (textResp 429 "node capacity exhausted"), preL)
          set { rt with activeExecMain := rt.activeExecMain + 1 }
        return (Except.ok (rt.cfg, rt.ledger.hasSqlite3, missionId, command, sideLane), preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match prep with
    | .error errResp => return errResp
    | .ok (cfg, hasSqlite3, missionId, command, sideLane) =>
      try
        match ← execClearedLeaseCommand cfg hasSqlite3 missionId command with
        | .ok outVal => return jsonResp 200 outVal
        | .error fenceErr => return textResp 503 fenceErr
      finally
        let postLaunches ← mtx.atomically do
          let rt ← get
          let rtReleased :=
            if sideLane then
              { rt with activeExecSide := if rt.activeExecSide > 0 then rt.activeExecSide - 1 else 0 }
            else
              let nextMain := if rt.activeExecMain > 0 then rt.activeExecMain - 1 else 0
              let nextDebt := if rt.shrinkDebt > 0 then rt.shrinkDebt - 1 else 0
              { rt with activeExecMain := nextMain, shrinkDebt := nextDebt }
          let (rtNext, nextL) ← tickRuntimeReserve rtReleased
          set rtNext
          return nextL
        if !postLaunches.isEmpty then
          spawnAsyncLaunches mtx postLaunches
  else if req.method == "GET" && segs.length == 3 && segs[0]? == some "jobs" && segs[2]? == some "log" then
    let jid := segs[1]!
    let key := (parseUuidCanonical? jid).getD jid
    let (lookupRes, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      let some rec := rt.ledger.jobs.get? key
        | return (Except.error (textResp 404 "job not found"), preL)
      return (Except.ok (rec.logPath?, rec.state.asString), preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match lookupRes with
    | .error errResp => return errResp
    | .ok (logPath?, stateStr) =>
      let off := (req.query? "offset" >>= String.toNat?).getD 0
      let maxB := (req.query? "max_bytes" >>= String.toNat?).getD 262144
      let sl ← readJobLogSliceBounded logPath? off.toUInt64 maxB
      return jsonResp 200 (.obj #[
        ("job_id", .str key),
        ("offset", JVal.uint64 sl.offset),
        ("next_offset", JVal.uint64 sl.nextOffset),
        ("log_len", JVal.uint64 sl.logLen),
        ("data", .str sl.data),
        ("state", .str stateStr)
      ])
  else if req.method == "GET" && segs.length == 2 && segs[0]? == some "jobs" then
    let jid := segs[1]!
    let key := (parseUuidCanonical? jid).getD jid
    let (lookupRes, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      let some rec := rt.ledger.jobs.get? key
        | return (Except.error (textResp 404 "job not found"), preL)
      return (Except.ok rec, preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match lookupRes with
    | .error errResp => return errResp
    | .ok rec =>
      let tail? ← readLogTail64K rec.logPath?
      return jsonResp 200 (rec.toStatusJson tail?)
  else if req.method == "POST" && segs == ["project-context", "prepare"] then
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.workDir
    match authCheck with
    | .error errResp => return errResp
    | .ok workDir =>
      let some bodyStr := String.fromUTF8? req.body
        | return textResp 400 "invalid UTF-8 body"
      let .ok jv := OrbBin.Json.parse bodyStr
        | return textResp 400 "invalid JSON body"
      match ← prepareNodeProjectContext workDir jv with
      | .ok res => return jsonResp 200 res
      | .error msg => return textResp 400 msg
  else
    let (resp, launches, watchers) ← mtx.atomically do
      let rt ← get
      let (rt', r, ls, ws) ← handleNonExecRequestCore rt req
      set rt'
      return (r, ls, ws)
    if !launches.isEmpty then
      spawnAsyncLaunches mtx launches
    if !watchers.isEmpty then
      spawnSteerWatchers mtx watchers
    return resp

/-- Serve HTTP/1.1 requests concurrently on `rt.cfg.bindHost:rt.cfg.bindPort` until `SIGTERM`/`SIGINT`
    (or `410 Gone` from dial-out relay), reloading capacity on `SIGHUP` and running background
    2-second project-context replica synchronization. -/
def runServerLoop (rtInit : NodeRuntime) (dialCred? : Option OrbNode.Dial.DialCredential := none) : IO UInt32 := do
  OrbNode.Posix.installSignals
  let lfd ← OrbNode.Posix.tcpListen rtInit.cfg.bindHost rtInit.cfg.bindPort
  let mtx ← Std.Mutex.new rtInit
  let goneRef ← IO.mkRef false
  let _ ← startProjectContextDaemon rtInit.cfg.workDir goneRef
  if let some cred := dialCred? then
    let _ ← OrbNode.Dial.spawnRelay cred rtInit.cfg.bindPort goneRef
  try
    while !(← goneRef.get) do
      let sigs ← OrbNode.Posix.pollSignals
      if (sigs &&& 1) != 0 then break
      if (sigs &&& 2) != 0 then
        let launches ← mtx.atomically do
          let rt ← get
          let rtReloaded ← reloadCapacityFromFiles rt
          let (rtNext, ls) ← tickRuntimeReserve rtReloaded
          set rtNext
          return ls
        if !launches.isEmpty then
          spawnAsyncLaunches mtx launches
      let cfd ← OrbNode.Posix.tcpAccept lfd 200
      if cfd == 0xFFFFFFFF then
        let launches ← mtx.atomically do
          let rt ← get
          let (rtNext, ls) ← tickRuntimeReserve rt
          set rtNext
          return ls
        if !launches.isEmpty then
          spawnAsyncLaunches mtx launches
      else
        let _ ← IO.asTask do
          try
            match ← readHttpRequest cfd with
            | .error "payload_too_large" =>
              discard <| OrbNode.Posix.fdWriteAll cfd (encodeHttpResponse (textResp 413 "payload too large"))
            | .error _ =>
              pure ()
            | .ok req =>
              let resp ← handleRequestConcurrent mtx req
              discard <| OrbNode.Posix.fdWriteAll cfd (encodeHttpResponse resp)
          finally
            OrbNode.Posix.fdClose cfd
  finally
    goneRef.set true
    OrbNode.Posix.fdClose lfd
  return 0

end OrbNode.Server
