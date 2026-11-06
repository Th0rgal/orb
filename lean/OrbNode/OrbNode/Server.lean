/-
  OrbNode.Server: Complete HTTP/1.1 `:3088` Worker Server & Route Dispatcher
  enforcing `OrbNode.Spec` Bearer & HMAC Lease Gates across every route.
-/
import LeanSys.Auth
import OrbBin.Json
import OrbNode.Spec
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store
import OrbNode.Runner

namespace OrbNode.Server

open LeanSys.Auth
open OrbBin.Json
open OrbNode.Spec
open OrbNode.Lease
open OrbNode.Store
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

/-- Read a bounded HTTP/1.1 request (`<= 52 MiB`) from `cfd`. -/
def readHttpRequest (cfd : UInt32) (maxBodyBytes : Nat := 54525952) : IO (Except String HttpRequest) := do
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

private def readLogTail64K (logPath? : Option String) : IO (Option String) := do
  let some lp := logPath? | return none
  let p := System.FilePath.mk lp
  if !(← p.pathExists) then return none
  let .ok bytes ← IO.FS.readBinFile p |>.toBaseIO
    | return none
  let start := if bytes.size > 65536 then bytes.size - 65536 else 0
  let sub := bytes.extract start bytes.size
  return some (String.fromUTF8? sub |>.getD "")

private def listDirJson (dirPath : String) : IO (Except String JVal) := do
  let p := System.FilePath.mk dirPath
  if !(← p.pathExists) then
    return .error "directory does not exist"
  let .ok entries ← p.readDir |>.toBaseIO
    | return .error "failed to read directory"
  let mut items : Array JVal := #[]
  for e in entries do
    let isDir ← e.path.isDir
    let sz : UInt64 ←
      if isDir then pure 0
      else match ← e.path.metadata |>.toBaseIO with
        | .ok md => pure md.byteSize
        | .error _ => pure 0
    items := items.push (.obj #[
      ("name", .str e.fileName),
      ("path", .str e.path.toString),
      ("kind", .str (if isDir then "dir" else "file")),
      ("size", JVal.uint64 sz),
      ("mtime", JVal.int 0)
    ])
  return .ok (.arr items)

/-- Pure + IO route handler over `NodeRuntime` (returns updated `NodeRuntime` and `HttpResponse`). -/
def handleRequest (rt0 : NodeRuntime) (req : HttpRequest) : IO (NodeRuntime × HttpResponse) := do
  let mut rt ← tickRuntime rt0
  if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
    return (rt, textResp 401 "invalid node token")
  let segs := (req.path.splitOn "/").filter (fun s => !s.isEmpty)
  let nowEp ← OrbNode.Posix.nowEpoch
  match req.method, segs with
  | "GET", ["heartbeat"] =>
    let hb ← buildHeartbeatJson rt
    return (rt, jsonResp 200 hb)
  | "POST", ["capacity"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let some leaseTok := jv.fieldStr? "lease_token"
      | return (rt, textResp 400 "missing lease_token")
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .nodeCapacity nowEp none with
    | .error msg => return (rt, textResp 400 msg)
    | .ok claims =>
      if claims.missionId != "00000000-0000-0000-0000-000000000000" then
        return (rt, textResp 400 "capacity lease requires nil mission_id")
      let some targetCap := jv.fieldNat? "capacity"
        | return (rt, textResp 400 "missing capacity")
      let targetCoord? := (jv.fieldNat? "coordinator_capacity").map (·.toUInt32)
      match ← resizeCapacity rt targetCap.toUInt32 targetCoord? with
      | .error msg => return (rt, textResp 400 msg)
      | .ok rt' =>
        let hb ← buildHeartbeatJson rt'
        return (rt', jsonResp 200 hb)
  | "POST", ["execute"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let (some missionId, some leaseTok, some command) :=
        (jv.fieldStr? "mission_id", jv.fieldStr? "lease_token", jv.fieldStr? "command")
      | return (rt, textResp 400 "missing mission_id, lease_token, or command")
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .missionExecute nowEp none with
    | .error msg => return (rt, textResp 400 msg)
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease mission_id mismatch")
      let sideLane := (jv.fieldBool? "side_lane").getD false
      let (stCode, outVal) ← runSyncExecute rt missionId command sideLane
      if stCode == 200 then return (rt, jsonResp 200 outVal)
      else return (rt, textResp stCode (outVal.asStr?.getD "execution rejected"))
  | "POST", ["jobs"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let (some jobId, some missionId, some leaseTok, some payloadVal) :=
        (jv.fieldStr? "job_id", jv.fieldStr? "mission_id", jv.fieldStr? "lease_token", jv.field? "payload")
      | return (rt, textResp 400 "missing job_id, mission_id, lease_token, or payload")
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .jobSubmit nowEp none with
    | .error msg => return (rt, textResp 400 msg)
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease mission_id mismatch")
      if rt.ledger.jobs.contains jobId then
        return (rt, textResp 409 "duplicate job_id")
      if rt.queueOrder.size >= rt.cfg.maxQueued then
        return (rt, textResp 429 "node job queue full")
      let st ← OrbNode.Posix.hostStats rt.cfg.workDir
      let estDisk := (payloadVal.fieldUInt64? "estimated_disk_bytes").getD 0
      let availAfterEst := if st.diskAvailBytes > estDisk then st.diskAvailBytes - estDisk else 0
      if verifyNodeCapacityDisk rt.cfg.capacityTotal rt.cfg.coordinatorCapacity availAfterEst rt.cfg.minFreeDiskBytes 0 0 != 1 then
        return (rt, textResp 422 "insufficient free disk space below min_free_disk_bytes floor")
      let nowTs ← nowRfc3339
      let logPath := (System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jobId}.log").toString
      let jobRec : JobRecord := {
        jobId := jobId
        missionId := missionId
        payloadJson := renderCompact payloadVal
        state := .queued
        createdAt := nowTs
        logPath? := some logPath
      }
      match ← rt.ledger.insertQueued jobRec with
      | .error "duplicate_job_id" => return (rt, textResp 409 "duplicate job_id")
      | .error msg => return (rt, textResp 500 msg)
      | .ok l' =>
        let rtQueued := { rt with ledger := l', queueOrder := rt.queueOrder.push jobId }
        let rtTicked ← tickRuntime rtQueued
        return (rtTicked, jsonResp 202 (.obj #[("job_id", .str jobId), ("state", .str "queued")]))
  | "GET", ["jobs"] =>
    let lim := (req.query? "limit" >>= String.toNat?).getD 20
    let recs := rt.ledger.listRecent lim
    return (rt, jsonResp 200 (.arr (recs.map (fun r => r.toStatusJson none))))
  | "GET", ["jobs", jid] =>
    let some rec := rt.ledger.jobs.get? jid
      | return (rt, textResp 404 "job not found")
    let tail? ← readLogTail64K rec.logPath?
    return (rt, jsonResp 200 (rec.toStatusJson tail?))
  | "GET", ["jobs", jid, "log"] =>
    let some rec := rt.ledger.jobs.get? jid
      | return (rt, textResp 404 "job not found")
    let off := (req.query? "offset" >>= String.toNat?).getD 0
    let maxB := (req.query? "max_bytes" >>= String.toNat?).getD 262144
    let rawBytes ← match rec.logPath? with
      | some lp =>
        if ← (System.FilePath.mk lp).pathExists then
          match ← IO.FS.readBinFile lp |>.toBaseIO with
          | .ok b => pure b
          | .error _ => pure ByteArray.empty
        else pure ByteArray.empty
      | none => pure ByteArray.empty
    let sl := sliceJobLogBytes rawBytes off maxB
    return (rt, jsonResp 200 (.obj #[
      ("job_id", .str jid),
      ("offset", JVal.uint64 sl.offset),
      ("next_offset", JVal.uint64 sl.nextOffset),
      ("log_len", JVal.uint64 sl.logLen),
      ("data", .str sl.data),
      ("state", .str rec.state.asString)
    ]))
  | "POST", ["jobs", jid, "cancel"] =>
    let actor := (req.header? "x-sandboxed-cancel-actor").getD "unknown"
    let reason := (req.header? "x-sandboxed-cancel-reason").getD "cancelled"
    match ← cancelJob rt jid actor reason with
    | .error "not_found" => return (rt, textResp 404 "job not found")
    | .error msg => return (rt, textResp 500 msg)
    | .ok (rt', updated) =>
      return (rt', jsonResp 200 (.obj #[
        ("job_id", .str jid),
        ("state", .str updated.state.asString),
        ("cancel_requested", .bool true)
      ]))
  | "POST", ["jobs", jid, "interrupt"] =>
    let mode ← match String.fromUTF8? req.body with
      | some s =>
        match OrbBin.Json.parse s with
        | .ok jv => pure ((jv.fieldStr? "mode").getD "interrupt_now")
        | .error _ => pure "interrupt_now"
      | none => pure "interrupt_now"
    match ← interruptJob rt jid mode with
    | .error "not_found" => return (rt, textResp 404 s!"job {jid} not found")
    | .error msg => return (rt, textResp 500 msg)
    | .ok (rt', respObj) => return (rt', jsonResp 200 respObj)
  | "POST", ["jobs", jid, "force"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let (some missionId, some leaseTok) := (jv.fieldStr? "mission_id", jv.fieldStr? "lease_token")
      | return (rt, textResp 400 "missing mission_id or lease_token")
    match verifyLeaseToken leaseTok rt.cfg.token rt.cfg.tokenPrevious? rt.cfg.nodeId .jobForce nowEp (some jid) with
    | .error msg => return (rt, textResp 400 msg)
    | .ok claims =>
      if claims.missionId != missionId then
        return (rt, textResp 400 "lease mission_id mismatch")
      match ← forceJob rt jid with
      | .error "not_found" => return (rt, textResp 404 "job not found")
      | .error "not_queued" => return (rt, textResp 409 "job is not queued")
      | .error "force_slot_busy" => return (rt, textResp 409 "force bypass slot is busy")
      | .error msg => return (rt, textResp 500 msg)
      | .ok (rt', updated) =>
        return (rt', jsonResp 200 (.obj #[
          ("job_id", .str jid),
          ("state", .str updated.state.asString),
          ("forced", .bool true)
        ]))
  | "POST", ["jobs", jid, "files"] =>
    let some rec := rt.ledger.jobs.get? jid
      | return (rt, textResp 404 "job not found")
    let missionDir := (System.FilePath.mk rt.cfg.workDir / rec.missionId).toString
    match ← listDirJson missionDir with
    | .ok v => return (rt, jsonResp 200 v)
    | .error msg => return (rt, textResp 400 msg)
  | "GET", ["fs", "list"] =>
    let target := (req.query? "path").getD rt.cfg.workDir
    match ← listDirJson target with
    | .ok v => return (rt, jsonResp 200 v)
    | .error msg => return (rt, textResp 400 msg)
  | "POST", ["fs", "mkdir"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let some p := jv.fieldStr? "path"
      | return (rt, textResp 400 "missing path")
    IO.FS.createDirAll p
    return (rt, jsonResp 200 (.obj #[("ok", .bool true)]))
  | "GET", ["machine-transfer", "capabilities"] =>
    return (rt, jsonResp 200 (.obj #[
      ("version", JVal.nat 2),
      ("harnesses", .arr #[.str "opencode", .str "claudecode", .str "codex", .str "antigravity"]),
      ("features", .arr #[.str "links", .str "selection", .str "archive-zstd-v1"])
    ]))
  | "GET", ["software"] =>
    return (rt, jsonResp 200 (.obj #[("components", .arr #[]), ("active_update", .null)]))
  | "GET", ["antigravity", "models"] =>
    return (rt, jsonResp 200 (.arr #[]))
  | "POST", ["uploads"] =>
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body")
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body")
    let (some name, some b64) := (jv.fieldStr? "name", jv.fieldStr? "data_base64")
      | return (rt, textResp 400 "missing name or data_base64")
    if name.isEmpty || name.contains '/' || name == ".." then
      return (rt, textResp 400 "invalid upload filename")
    let some decoded := base64UrlDecode? (b64.replace "+" "-" |>.replace "/" "_")
      | return (rt, textResp 400 "invalid base64 payload")
    let dest := System.FilePath.mk rt.cfg.workDir / "uploads" / name
    IO.FS.writeBinFile dest decoded
    let sha := bytesToHexLower (sha256Bytes decoded)
    return (rt, jsonResp 200 (.obj #[
      ("name", .str name),
      ("path", .str dest.toString),
      ("size", JVal.uint64 decoded.size.toUInt64),
      ("sha256", .str sha)
    ]))
  | _, _ =>
    return (rt, textResp 404 "route not found")

/-- Serve HTTP/1.1 requests on `rt.cfg.bindHost:rt.cfg.bindPort` until `SIGTERM`/`SIGINT`. -/
def runServerLoop (rtInit : NodeRuntime) : IO UInt32 := do
  OrbNode.Posix.installSignals
  let lfd ← OrbNode.Posix.tcpListen rtInit.cfg.bindHost rtInit.cfg.bindPort
  let mut rt := rtInit
  try
    while true do
      let sigs ← OrbNode.Posix.pollSignals
      if (sigs &&& 1) != 0 then break
      let cfd ← OrbNode.Posix.tcpAccept lfd 200
      if cfd == 0xFFFFFFFF then
        rt ← tickRuntime rt
      else
        match ← readHttpRequest cfd with
        | .error "payload_too_large" =>
          discard <| OrbNode.Posix.fdWriteAll cfd (encodeHttpResponse (textResp 413 "payload too large"))
        | .error _ =>
          pure ()
        | .ok req =>
          let (rt', resp) ← handleRequest rt req
          rt := rt'
          discard <| OrbNode.Posix.fdWriteAll cfd (encodeHttpResponse resp)
        OrbNode.Posix.fdClose cfd
  finally
    OrbNode.Posix.fdClose lfd
  return 0

end OrbNode.Server
