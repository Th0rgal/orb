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
  method        : String
  rawPath       : String
  path          : String
  query         : Array (String × String)
  headers       : Array (String × String)
  body          : ByteArray
  bodyTempFile? : Option System.FilePath := none
  deriving Inhabited

def HttpRequest.header? (req : HttpRequest) (nameLower : String) : Option String :=
  (req.headers.find? (fun (k, _) => k == nameLower)).map Prod.snd

def HttpRequest.query? (req : HttpRequest) (key : String) : Option String :=
  (req.query.find? (fun (k, _) => k == key)).map Prod.snd

structure HttpResponse where
  status      : Nat
  contentType : String := "application/json"
  body        : ByteArray := ByteArray.empty
  tempFile?   : Option System.FilePath := none
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

/-- Stream `HttpResponse` onto socket `cfd` without loading `tempFile?` into RAM, unlinking `tempFile?` afterwards. -/
def sendHttpResponse (cfd : UInt32) (resp : HttpResponse) : IO Unit := do
  match resp.tempFile? with
  | none =>
    discard <| OrbNode.Posix.fdWriteAll cfd (encodeHttpResponse resp)
  | some fp =>
    try
      let fileLen ← match ← fp.metadata |>.toBaseIO with
        | .ok md => pure md.byteSize
        | .error _ => pure 0
      let head :=
        s!"HTTP/1.1 {resp.status} {statusReason resp.status}\r\n" ++
        s!"Content-Type: {resp.contentType}\r\n" ++
        s!"Content-Length: {fileLen}\r\n" ++
        "Connection: close\r\n\r\n"
      let rc ← OrbNode.Posix.fdWriteAll cfd head.toUTF8
      if rc == 0 && fileLen > 0 then
        if let .ok h ← (IO.FS.Handle.mk fp .read).toBaseIO then
          while true do
            let .ok chunk ← (h.read 65536).toBaseIO | break
            if chunk.isEmpty then break
            let wrc ← OrbNode.Posix.fdWriteAll cfd chunk
            if wrc != 0 then break
    finally
      try IO.FS.removeFile fp catch _ => pure ()

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

private def parseHexChunkSize? (line : String) : Option Nat := Id.run do
  let clean := ((line.splitOn ";").headD "").trimAscii.toString
  if clean.isEmpty then return none
  let mut acc : Nat := 0
  for c in clean.toList do
    match hexNibble? c with
    | some n => acc := acc * 16 + n.toNat
    | none => return none
  return some acc

private def findCrlf? (buf : ByteArray) (startIdx : Nat := 0) : Option Nat := Id.run do
  if startIdx + 2 > buf.size then return none
  for i in [startIdx : buf.size - 1] do
    if buf.get! i == 13 && buf.get! (i + 1) == 10 then
      return some i
  return none

/-- Read HTTP/1.1 request from `cfd`:
    - When `authTokens? = some (tok, tokPrev?)` is supplied, verifies `Authorization: Bearer` IMMEDIATELY after
      reading HTTP headers (`<= 64 KiB`) BEFORE allocating any request body buffer or disk temp file, preventing
      unauthenticated disk or memory DoS!
    - Normal routes enforce `maxBodyBytes` (`128 MiB`) in memory.
    - `POST /machine-transfer/archive/unpack` validates canonical `mission_id`/`transfer_id` UUIDs and checks that
      `<workDir>/.transfers/<tid>/destination/manifest.json` is staged (and unsealed) before streaming up to
      `maxTransferBytes` (`10 GiB`) directly to disk in `64 KiB` chunks! -/
def readHttpRequest
    (cfd : UInt32) (workDir : String := "/tmp") (maxBodyBytes : Nat := 134217728)
    (authTokens? : Option (String × Option String) := none) : IO (Except String HttpRequest) := do
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
  let mut contentLen? : Option Nat := none
  let mut isChunked := false
  let mut authHeader? : Option String := none
  for hl in rawHdrs do
    if let p :: vs := hl.splitOn ":" then
      let k := p.trimAscii.toString.toLower
      let v := (String.intercalate ":" vs).trimAscii.toString
      headers := headers.push (k, v)
      if k == "content-length" then
        contentLen? := v.toNat?
      else if k == "transfer-encoding" && (v.toLower.splitOn "chunked").length > 1 then
        isChunked := true
      else if k == "authorization" then
        authHeader? := some v
  if let some (tok, tokPrev?) := authTokens? then
    if !verifyBearerHeader authHeader? tok tokPrev? then
      return .error "unauthorized"
  let (path, query) := parsePathAndQuery rawTarget
  let methodUp := method.toUpper
  let segs := (path.splitOn "/").filter (fun s => !s.isEmpty)
  let isArchiveUnpack := methodUp == "POST" && segs == ["machine-transfer", "archive", "unpack"]
  let bodyStart := hdrEnd + 4
  let initialRem := if bodyStart < buf.size then buf.extract bodyStart buf.size else ByteArray.empty
  if isArchiveUnpack then
    let qLookup (key : String) : Option String :=
      (query.find? (fun (k, _) => k == key)).map Prod.snd
    let (some rawMid, some rawTid) := (qLookup "mission_id", qLookup "transfer_id")
      | return .error "bad_request:missing mission_id or transfer_id query parameter"
    let (some _mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return .error "bad_request:invalid UUID"
    let destArea := System.FilePath.mk workDir / ".transfers" / tid / "destination"
    if ← (destArea / "verified").pathExists then
      return .error "conflict:Checkpoint already sealed"
    if !(← (destArea / "manifest.json").pathExists) then
      return .error "conflict:Stage destination manifest first"
    let tmpDir := System.FilePath.mk workDir / ".transfers"
    IO.FS.createDirAll tmpDir
    let nonce ← newUuidV4
    let tmpFile := tmpDir / s!".http-unpack-{nonce}.tar.zst"
    let streamRes : IO (Except String Unit) := do
      let .ok hOut ← (IO.FS.Handle.mk tmpFile .write).toBaseIO
        | return .error "failed_open_temp"
      if isChunked then
        let mut remBuf := initialRem
        let mut totalWrittenNat : Nat := 0
        let maxBytesNat : Nat := maxTransferBytes.toNat
        while true do
          while (findCrlf? remBuf 0).isNone && remBuf.size < 4096 do
            let c ← OrbNode.Posix.fdRead cfd 16384
            if c.isEmpty then break
            remBuf := remBuf ++ c
          let some lineEnd := findCrlf? remBuf 0
            | return .error "malformed_chunk_header"
          let some lineStr := String.fromUTF8? (remBuf.extract 0 lineEnd)
            | return .error "malformed_chunk_header"
          let some chunkSz := parseHexChunkSize? lineStr
            | return .error "malformed_chunk_size"
          remBuf := remBuf.extract (lineEnd + 2) remBuf.size
          if chunkSz == 0 then
            break
          if totalWrittenNat + chunkSz > maxBytesNat then
            return .error "payload_too_large"
          let mut need := chunkSz
          if remBuf.size > 0 then
            let takeNow := min need remBuf.size
            let .ok () ← (hOut.write (remBuf.extract 0 takeNow)).toBaseIO
              | return .error "write_failed"
            remBuf := remBuf.extract takeNow remBuf.size
            need := need - takeNow
          while need > 0 do
            let want := min 65536 need
            let c ← OrbNode.Posix.fdRead cfd (USize.ofNat want)
            if c.isEmpty then return .error "truncated_chunk_body"
            let .ok () ← (hOut.write c).toBaseIO
              | return .error "write_failed"
            need := need - c.size
          while remBuf.size < 2 do
            let c ← OrbNode.Posix.fdRead cfd 4096
            if c.isEmpty then return .error "missing_chunk_crlf"
            remBuf := remBuf ++ c
          if remBuf.get! 0 != 13 || remBuf.get! 1 != 10 then
            return .error "missing_chunk_crlf"
          remBuf := remBuf.extract 2 remBuf.size
          totalWrittenNat := totalWrittenNat + chunkSz
      else
        let contentLen := contentLen?.getD 0
        if contentLen > maxTransferBytes.toNat then
          return .error "payload_too_large"
        let mut written : Nat := 0
        if initialRem.size > 0 then
          let takeNow := min contentLen initialRem.size
          let .ok () ← (hOut.write (initialRem.extract 0 takeNow)).toBaseIO
            | return .error "write_failed"
          written := takeNow
        while written < contentLen do
          let want := min 65536 (contentLen - written)
          let c ← OrbNode.Posix.fdRead cfd (USize.ofNat want)
          if c.isEmpty then return .error "truncated_body"
          let .ok () ← (hOut.write c).toBaseIO
            | return .error "write_failed"
          written := written + c.size
      discard <| (hOut.flush).toBaseIO
      return .ok ()
    match ← streamRes with
    | .error err =>
      try IO.FS.removeFile tmpFile catch _ => pure ()
      return .error err
    | .ok () =>
      return .ok {
        method := methodUp
        rawPath := rawTarget
        path := path
        query := query
        headers := headers
        body := ByteArray.empty
        bodyTempFile? := some tmpFile
      }
  else
    let contentLen := contentLen?.getD 0
    if contentLen > maxBodyBytes then
      return .error "payload_too_large"
    let mut body := initialRem
    if isChunked then
      let mut outBody := ByteArray.empty
      while true do
        while (findCrlf? body 0).isNone && body.size < 4096 do
          let c ← OrbNode.Posix.fdRead cfd 16384
          if c.isEmpty then break
          body := body ++ c
        let some lineEnd := findCrlf? body 0
          | return .error "malformed_chunk_header"
        let some lineStr := String.fromUTF8? (body.extract 0 lineEnd)
          | return .error "malformed_chunk_header"
        let some chunkSz := parseHexChunkSize? lineStr
          | return .error "malformed_chunk_size"
        body := body.extract (lineEnd + 2) body.size
        if chunkSz == 0 then break
        if outBody.size + chunkSz > maxBodyBytes then
          return .error "payload_too_large"
        while body.size < chunkSz + 2 do
          let c ← OrbNode.Posix.fdRead cfd (USize.ofNat (min 65536 (chunkSz + 2 - body.size)))
          if c.isEmpty then return .error "truncated_chunk_body"
          body := body ++ c
        outBody := outBody ++ body.extract 0 chunkSz
        body := body.extract (chunkSz + 2) body.size
      body := outBody
    else
      while body.size < contentLen do
        let want := min 65536 (contentLen - body.size)
        let chunk ← OrbNode.Posix.fdRead cfd (USize.ofNat want)
        if chunk.isEmpty then break
        body := body ++ chunk
      if body.size > contentLen then
        body := body.extract 0 contentLen
    return .ok {
      method := methodUp
      rawPath := rawTarget
      path := path
      query := query
      headers := headers
      body := body
    }

private def readLogTail64K (logPath? : Option String) : IO (Option String) :=
  readJobLogTailBounded logPath? 65536

private def resolveToolPath? (bin : String) : IO (Option String) := do
  let envPath := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  let mut dirs : Array String := (envPath.splitOn ":").toArray.filter (fun s => !s.isEmpty)
  if let some home ← IO.getEnv "HOME" then
    dirs := dirs ++ #[s!"{home}/.local/bin", s!"{home}/.bun/bin", s!"{home}/.cargo/bin"]
  dirs := dirs ++ #["/opt/orb/bin", "/opt/sandboxed-tools/bin", "/opt/orb-tools/bin", "/usr/local/bin", "/usr/bin", "/bin"]
  for d in dirs do
    let candPath := System.FilePath.mk d / bin
    if (← candPath.pathExists) && !(← candPath.isDir) then
      return some candPath.toString
  return none

private def classifyComponentOwner (path? : Option String) : String :=
  match path? with
  | none => "External"
  | some p =>
    if p.startsWith "/opt/orb/" || p.startsWith "/opt/sandboxed-tools/" || p.startsWith "/opt/orb-tools/" || p.startsWith "/usr/local/bin/" then
      "Fleet installer"
    else if (p.splitOn "/.bun/").length > 1 then
      "Bun"
    else if (p.splitOn "/pnpm/").length > 1 then
      "pnpm"
    else if (p.splitOn "/.cargo/").length > 1 then
      "Cargo"
    else if (p.splitOn "/node_modules/").length > 1 then
      "npm"
    else
      "External"

/-- Build the `shared/agent_software.rs::Inventory` payload expected by `GET /api/agent-software` on Core! -/
def scanSoftwareInventory : IO JVal := do
  let nowEp ← OrbNode.Posix.nowEpoch
  let exePathJson ← match ← (IO.appPath).toBaseIO with
    | .ok p => pure (JVal.str p.toString)
    | .error _ => pure JVal.null
  let hasTimeout ← do
    let r ← (IO.Process.output { cmd := "timeout", args := #["--version"] }).toBaseIO
    pure (match r with | .ok o => o.exitCode == 0 | .error _ => false)
  let tools := #[
    ("claudecode", "Claude Code", "claude"),
    ("codex", "Codex", "codex"),
    ("opencode", "OpenCode", "opencode"),
    ("grok", "Grok", "grok"),
    ("antigravity", "Antigravity", "agy"),
    ("vibe", "Mistral Vibe", "vibe-acp")
  ]
  let mut comps : Array JVal := #[]
  for (cid, cname, bin) in tools do
    let path? ← resolveToolPath? bin
    let mut ver? : Option String := none
    if let some binPath := path? then
      let probeArgs := if hasTimeout then #["5s", binPath, "--version"] else #["--version"]
      let probeCmd := if hasTimeout then "timeout" else binPath
      if let .ok out ← (IO.Process.output { cmd := probeCmd, args := probeArgs }).toBaseIO then
        if out.exitCode == 0 then
          let firstLine := ((out.stdout.splitOn "\n").find? (fun ln => !ln.trimAscii.isEmpty)).getD ""
          let clean := (firstLine.trimAscii.toString.take 200).toString
          if !clean.isEmpty then
            ver? := some clean
    let isInstalled := path?.isSome
    let owner := classifyComponentOwner path?
    let verJson := match ver? with | some v => JVal.str v | none => JVal.null
    let pathJson := match path? with | some p => JVal.str p | none => JVal.null
    comps := comps.push (.obj #[
      ("id", .str cid),
      ("name", .str cname),
      ("version", verJson),
      ("path", pathJson),
      ("installed", .bool isInstalled),
      ("owner", .str owner),
      ("update_supported", .bool false),
      ("latest", .null),
      ("release_error", .null),
      ("running", .arr #[]),
      ("instructions", .str "Managed out-of-band by host image / fleet provisioning"),
      ("ready", .bool isInstalled),
      ("ready_detail", .null)
    ])
  let runtimeObj := JVal.obj #[
    ("name", .str "sandboxed-node"),
    ("version", .str "1.3.0-lean4"),
    ("build", .str "1.3.0-lean4 · turbo-lean"),
    ("path", exePathJson),
    ("restart_required", .bool false),
    ("running", .arr #[])
  ]
  return .obj #[
    ("checked_at", JVal.uint64 nowEp),
    ("components", .arr comps),
    ("runtime", runtimeObj),
    ("jobs", .arr #[])
  ]

/-- Group Carbon (`agy-model-{low,medium,high}`) and Argon (`agy-demo-{low,medium,high}`) variants
    into single base `(id, label)` pairs matching `shared/antigravity.rs::group_models`! -/
def groupAntigravityModels (raw : Array (String × String)) : Array (String × String) := Id.run do
  let mut seen : Std.HashSet String := {}
  let mut out : Array (String × String) := #[]
  for (rawId, rawLabel) in raw do
    let grouped? : Option (String × String) :=
      if rawId.startsWith "agy-model-" then
        let lvl := (rawId.drop 10).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("agy-model", lvl) else none
      else if rawId.startsWith "agy-demo-" then
        let lvl := (rawId.drop 9).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("agy-demo", lvl) else none
      else none
    let (id, label) := match grouped? with
      | some (base, lvl) =>
        let suf := if lvl == "low" then " (Low)" else if lvl == "medium" then " (Medium)" else " (High)"
        let stripped := if rawLabel.endsWith suf then (rawLabel.dropEnd suf.length).toString else rawLabel
        (base, stripped)
      | none => (rawId, rawLabel)
    if !seen.contains id then
      seen := seen.insert id
      out := out.push (id, label)
  return out

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
    let some agyBin ← resolveToolPath? "agy"
      | let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpHome] }
        return .error (503, "Antigravity CLI is not installed")
    let res ← (IO.Process.output {
      cmd := "timeout"
      args := #["-k", "2", "15s", agyBin, "models"]
      env := #[("HOME", some tmpHome)]
    }).toBaseIO
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpHome] }
    match res with
    | .error _ => return .error (503, "Antigravity model discovery failed")
    | .ok out =>
      if out.exitCode == 124 then
        return .error (503, "Antigravity model discovery timed out; check sign-in")
      if out.exitCode != 0 then
        return .error (503, "Sign in with agy as this machine's execution user")
      let mut pairs : Array (String × String) := #[]
      for line in out.stdout.splitOn "\n" do
        let cleanLine := (line.dropEndWhile (· == '\r')).toString
        let cols := cleanLine.splitOn "\t"
        if h : cols.length >= 2 then
          let id := cols[0]
          let label := String.intercalate "\t" cols.tail!
          if !id.isEmpty && !label.isEmpty then
            pairs := pairs.push (id, label)
      let grouped := groupAntigravityModels pairs
      if grouped.isEmpty then
        return .error (503, "No Antigravity models are available for this account")
      return .ok (.arr (grouped.map fun (i, l) => .arr #[.str i, .str l]))

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
        let estDiskNat := (payloadVal.fieldNat? "estimated_disk_bytes").getD 0
        let estDisk : UInt64 :=
          if estDiskNat > 0xFFFFFFFFFFFFFFFF then 0xFFFFFFFFFFFFFFFF else estDiskNat.toUInt64
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
      let rawAuthMode :=
        match (jv.fieldStr? "authority_mode").orElse (fun _ => payloadVal.fieldStr? "authority_mode") with
        | some m => m
        | none =>
          match (jv.fieldBool? "writer").orElse (fun _ => payloadVal.fieldBool? "writer") with
          | some false => "readonly"
          | _ => "writer"
      if rawAuthMode != "readonly" && rawAuthMode != "writer" then
        return (rt, textResp 422 s!"invalid authority_mode '{rawAuthMode}'", preLaunches, #[])
      let placeKind := ((jv.fieldStr? "placement_kind").orElse (fun _ => payloadVal.fieldStr? "placement_kind")).getD "managed"
      let rawDiskGibNat ← do
        match (jv.fieldNat? "reserved_disk_gib").orElse (fun _ => payloadVal.fieldNat? "reserved_disk_gib") with
        | some g => pure g
        | none => pure (((payloadVal.fieldNat? "estimated_disk_bytes").getD 0) / 1073741824)
      if rawDiskGibNat > Ledger.maxReservedDiskGib.toNat then
        return (rt, textResp 422 s!"invalid reserved_disk_gib '{rawDiskGibNat}' (max {Ledger.maxReservedDiskGib})", preLaunches, #[])
      let diskGib := rawDiskGibNat.toUInt64
      let rawOpId := ((jv.fieldStr? "operation_id").orElse (fun _ => payloadVal.fieldStr? "operation_id")).getD jobId
      let opBoot := ((jv.fieldUInt64? "node_boot_epoch").orElse (fun _ => payloadVal.fieldUInt64? "node_boot_epoch")).getD rt.ledger.nodeBootEpoch
      let rawWsId := ((jv.fieldStr? "workspace_id").orElse (fun _ => payloadVal.fieldStr? "workspace_id")).getD missionId
      let rawMach? := ((jv.fieldStr? "machine_name").orElse (fun _ =>
        (jv.fieldStr? "container_machine").orElse (fun _ =>
          (payloadVal.fieldStr? "machine_name").orElse (fun _ =>
            payloadVal.fieldStr? "container_machine")))).filter (fun s => !s.isEmpty)
      let rawLeaderPid := ((jv.fieldUInt64? "leader_pid").orElse (fun _ => payloadVal.fieldUInt64? "leader_pid")).getD 0
      let rawLeaderTicks := ((jv.fieldUInt64? "start_ticks").orElse (fun _ => payloadVal.fieldUInt64? "start_ticks")).getD 0
      let nowTs ← nowRfc3339
      let claimLeader? : Option ContainerLeaderRecord :=
        rawMach?.map (fun mName => {
          workspaceId := if rawWsId.isEmpty then missionId else rawWsId
          machineName := mName
          leaderPid := if rawLeaderPid ≤ 0xFFFFFFFF then rawLeaderPid.toUInt32 else 0
          startTicks := rawLeaderTicks
          nodeBootEpoch := opBoot
          procPhase := if rawLeaderPid != 0 && rawLeaderTicks != 0 then 1 else 0
          jobId := jobId
          updatedAt := nowTs
        })
      let logPath := (System.FilePath.mk rt.cfg.workDir / "logs" / s!"{jobId}.log").toString
      let persistedPayload := sanitizePersistedPayload payloadVal
      let effClaimOp := if rawOpId.isEmpty then jobId else rawOpId
      let (scratchDir, scratchReceipt) ← match ← createScratchDirAndReceipt rt.cfg.workDir jobId missionId (some jobId)
          opBoot (operationIdToken effClaimOp) with
        | .ok pair => pure pair
        | .error scErr => return (rt, textResp 503 scErr, preLaunches, #[])
      let jobRec : JobRecord := {
        jobId := jobId
        missionId := missionId
        payloadJson := renderCompact persistedPayload
        state := .queued
        createdAt := nowTs
        logPath? := some logPath
        authorityMode := rawAuthMode
        placementKind := placeKind
        reservedDiskGib := diskGib
        operationId := rawOpId
        nodeBootEpoch := opBoot
        pid := rawLeaderPid
        startTicks := rawLeaderTicks
        phaseCode := 1
      }
      match ← rt.ledger.insertQueued jobRec (some scratchReceipt) claimLeader? with
      | .error "duplicate_job_id" =>
        discard <| (IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }).toBaseIO
        return (rt, textResp 409 s!"job {jobId} already exists", preLaunches, #[])
      | .error msg =>
        discard <| (IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }).toBaseIO
        let stCode := if msg.startsWith "job_claim_fence_rejected:" then 409 else 503
        return (rt, textResp stCode msg, preLaunches, #[])
      | .ok l' =>
        let rtQueued := {
          rt with
          ledger := l'
          queuedPayloads := rt.queuedPayloads.insert jobId payloadVal
          queueOrder := rt.queueOrder.push jobId
        }
        let (rtReserved, postLaunches) ← tickRuntimeReserve rtQueued
        return (rtReserved, jsonResp 202 (.obj #[
          ("job_id", .str jobId),
          ("state", .str "queued"),
          ("node_boot_epoch", JVal.uint64 l'.nodeBootEpoch)
        ]),
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
    let sl ← readJobLogSliceBounded rec.logPath? off.toUInt64 maxB rec.state.confirmsTermination
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
    | .ok (rt', updated, cancelRequested) =>
      let (rtTicked, postLaunches) ← tickRuntimeReserve rt'
      return (rtTicked, jsonResp 200 (.obj #[
        ("job_id", .str key),
        ("state", .str updated.state.asString),
        ("cancel_requested", .bool cancelRequested)
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
  | "POST", ["jobs", jid, "reconcile"] =>
    let key := (parseUuidCanonical? jid).getD jid
    let some bodyStr := String.fromUTF8? req.body
      | return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
    let .ok jv := OrbBin.Json.parse bodyStr
      | return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
    let some opNat := jv.fieldNat? "op_code"
      | return (rt, textResp 400 "missing op_code", preLaunches, #[])
    if opNat > 10 then
      return (rt, textResp 422 "invalid op_code", preLaunches, #[])
    let presOp := (jv.fieldStr? "operation_id").getD ""
    let presBoot := (jv.fieldUInt64? "node_boot_epoch").getD rt.ledger.nodeBootEpoch
    let nowTs ← nowRfc3339
    match ← rt.ledger.stepJobClaim key opNat.toUInt8 presOp presBoot nowTs with
    | .error "not_found" => return (rt, textResp 404 s!"job {key} not found", preLaunches, #[])
    | .error msg =>
      let stCode := if msg.startsWith "claim_step_rejected:" then 409 else 503
      return (rt, textResp stCode msg, preLaunches, #[])
    | .ok (l', updated) =>
      return ({ rt with ledger := l' }, jsonResp 200 (updated.toStatusJson none), preLaunches, #[])
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
      ("features", .arr #[.str "links", .str "selection", .str "bulk_copy", .str "archive-zstd-v1"])
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
    let cleanupBodyTmp : IO Unit :=
      match req.bodyTempFile? with
      | some fp => do try IO.FS.removeFile fp catch _ => pure ()
      | none => pure ()
    let (some rawMid, some rawTid) := (req.query? "mission_id", req.query? "transfer_id")
      | cleanupBodyTmp
        return (rt, textResp 400 "missing mission_id or transfer_id query parameter", preLaunches, #[])
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | cleanupBodyTmp
        return (rt, textResp 400 "invalid UUID", preLaunches, #[])
    if rt.ledger.missionHasLiveJobs mid then
      cleanupBodyTmp
      return (rt, textResp 409 "Source execution has not terminated", preLaunches, #[])
    let area := System.FilePath.mk rt.cfg.workDir / ".transfers" / tid / "destination"
    let unpackRes ← match req.bodyTempFile? with
      | some fp => do
        let r ← unpackTransferArchiveFromFile area fp
        try IO.FS.removeFile fp catch _ => pure ()
        pure r
      | none => unpackTransferArchive area req.body
    match unpackRes with
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
  | "POST", ["workspaces", wsId, "build"] =>
    let opId? ←
      if req.body.isEmpty then pure none
      else match String.fromUTF8? req.body with
        | none => return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
        | some s =>
          match OrbBin.Json.parse s with
          | .error _ => return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
          | .ok jv => pure (jv.fieldStr? "operation_id")
    match ← claimWorkspaceBuild rt.cfg.workDir rt.ledger.sqliteBackend wsId opId? with
    | .admitted rec => return (rt, jsonResp 200 rec.toJson, preLaunches, #[])
    | .conflict => return (rt, jsonResp 409 (.obj #[("error", .str "workspace_build_in_progress")]), preLaunches, #[])
    | .badRequest msg => return (rt, jsonResp 400 (.obj #[("error", .str msg)]), preLaunches, #[])
    | .dbError msg => return (rt, jsonResp 503 (.obj #[("error", .str msg)]), preLaunches, #[])
  | "POST", ["workspaces", wsId, "build", "complete"] =>
    let (termStatus, expGen?, expOp?) ←
      if req.body.isEmpty then pure ("completed", none, none)
      else match String.fromUTF8? req.body with
        | none => return (rt, textResp 400 "invalid UTF-8 body", preLaunches, #[])
        | some s =>
          match OrbBin.Json.parse s with
          | .error _ => return (rt, textResp 400 "invalid JSON body", preLaunches, #[])
          | .ok jv =>
            pure ((jv.fieldStr? "status").getD "completed", jv.fieldUInt64? "build_generation", jv.fieldStr? "operation_id")
    match ← completeWorkspaceBuild rt.cfg.workDir rt.ledger.sqliteBackend wsId termStatus expGen? expOp? with
    | .ok rec => return (rt, jsonResp 200 rec.toJson, preLaunches, #[])
    | .error (code, msg) => return (rt, jsonResp code (.obj #[("error", .str msg)]), preLaunches, #[])
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

/-- Spawn background `IO.asTask` workers for `PendingAsyncLaunch` items outside `Std.Mutex NodeRuntime`.
    Exception-hardened: even if `commitPreparedJob` or `tickRuntimeReserve` raises an unexpected `IO.Error`,
    the reserved `launching` slot, `queuedPayloads` entry, `shrinkDebt`, and any spawned PID/scope/checkout
    are ALWAYS cleaned up so a worker exception can never wedge node capacity! -/
private partial def spawnAsyncLaunches (mtx : Std.Mutex NodeRuntime) (launches : Array PendingAsyncLaunch) : IO Unit := do
  for item in launches do
    let _ ← IO.asTask do
      let prepRes ← match ← (prepareJobOutsideLock item.cfg item.jid item.missionId item.payload item.logPath
          item.forced item.sideLane item.coordLane).toBaseIO with
        | .ok r => pure r
        | .error e => pure (.error s!"unexpected launch exception: {e}")
      let more ← mtx.atomically do
        let rt ← get
        let stepAction : IO (NodeRuntime × Array PendingAsyncLaunch) := do
          let rtCommitted ← commitPreparedJob rt item.jid prepRes
          tickRuntimeReserve rtCommitted
        match ← stepAction.toBaseIO with
        | .ok (rtNext, nextLaunches) =>
          set rtNext
          return nextLaunches
        | .error commitErr =>
          if let .ok spec := prepRes then
            teardownJobResourcesAsync spec.systemdScope? spec.isolatedCheckout
          let nextDebt :=
            if !item.forced && !item.sideLane && !item.coordLane && rt.shrinkDebt > 0 then
              rt.shrinkDebt - 1
            else rt.shrinkDebt
          let mut rtClean := {
            rt with
            launching := rt.launching.erase item.jid
            queuedPayloads := rt.queuedPayloads.erase item.jid
            shrinkDebt := nextDebt
          }
          let updOut ← (rtClean.ledger.updateJob item.jid (fun r =>
              if r.state.isTerminal then .ok r
              else .ok { r with state := .failed, error? := some s!"commit failed: {commitErr}" })).toBaseIO
          if let .ok (.ok (l', _)) := updOut then
            rtClean := { rtClean with ledger := l' }
          set rtClean
          return #[]
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
        let (stillActive, scopeUnit?, rootTicks, rootBootId) ← mtx.atomically do
          let rt ← get
          match rt.liveProcs.get? jid with
          | some lp =>
            return (lp.pid == rootPid && lp.steerAfterTool, lp.systemdScope?.map (·.unit), lp.startTicks, lp.bootId)
          | none => return (false, none, 0, "")
        if !stillActive then
          done := true
        else
          let inflight ← collectVerifiedInflightChildTools rootPid scopeUnit? rootTicks rootBootId
          if inflight.isEmpty then
            IO.sleep 120
            let nextLaunches ← mtx.atomically do
              let rt ← get
              if let .ok (rt', _, _) ← cancelJob rt jid "core" "Steered immediately after tool call completed" then
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
    - `POST /execute`, `POST /project-context/prepare`, `POST /machine-transfer/*`, `GET /software`,
      `GET /jobs/:id/log`, `GET /jobs/:id`, and async job checkout preparation ALL execute outside
      `Std.Mutex NodeRuntime` so slow network/git/archive/command I/O never blocks `/heartbeat`, `/cancel`,
      `/jobs/:id/log`, or deadline enforcement! -/
def handleRequestConcurrent
    (mtx : Std.Mutex NodeRuntime) (transferMtx : Std.Mutex Unit) (req : HttpRequest) : IO HttpResponse := do
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
        return (Except.ok (rt.cfg, rt.ledger.sqliteBackend, rt.ledger.nodeBootEpoch, missionId, command, sideLane), preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match prep with
    | .error errResp => return errResp
    | .ok (cfg, sqliteBackend, nodeBootEpoch, missionId, command, sideLane) =>
      try
        match ← execClearedLeaseCommand cfg sqliteBackend missionId command nodeBootEpoch with
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
      return (Except.ok (rec.logPath?, rec.state.asString, rec.state.confirmsTermination), preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match lookupRes with
    | .error errResp => return errResp
    | .ok (logPath?, stateStr, isTerminal) =>
      let off := (req.query? "offset" >>= String.toNat?).getD 0
      let maxB := (req.query? "max_bytes" >>= String.toNat?).getD 262144
      let sl ← readJobLogSliceBounded logPath? off.toUInt64 maxB isTerminal
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
  else if req.method == "GET" && segs == ["software"] then
    let authOk ← mtx.atomically do
      let rt ← get
      return verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious?
    if !authOk then
      return textResp 401 "invalid node token"
    let inv ← scanSoftwareInventory
    return jsonResp 200 inv
  else if req.method == "GET" && segs == ["machine-transfer", "capabilities"] then
    let maCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.managedAuth
    match maCheck with
    | .error errResp => return errResp
    | .ok ma =>
      let harnesses ← detectTransferHarnesses ma
      return jsonResp 200 (.obj #[
        ("version", JVal.nat 2),
        ("harnesses", .arr (harnesses.map .str)),
        ("features", .arr #[.str "links", .str "selection", .str "bulk_copy", .str "archive-zstd-v1"])
      ])
  else if req.method == "GET" && segs == ["antigravity", "models"] then
    let maCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.managedAuth
    match maCheck with
    | .error errResp => return errResp
    | .ok ma =>
      match ← discoverAntigravityModels ma (req.query? "slot") with
      | .ok res => return jsonResp 200 res
      | .error (code, msg) => return textResp code msg
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
  else if req.method == "POST" && segs == ["uploads", "sessions"] then
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
      match ← initOrStatusUploadSession workDir jv with
      | .ok status => return jsonResp 200 status
      | .error msg => return textResp 400 msg
  else if req.method == "PUT" && segs.length == 5 &&
          segs[0]? == some "uploads" && segs[1]? == some "sessions" && segs[3]? == some "chunks" then
    let uid := segs[2]!
    let idxStr := segs[4]!
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.workDir
    match authCheck with
    | .error errResp => return errResp
    | .ok workDir =>
      if req.body.size > maxChunkBytes then
        return textResp 413 "chunk too large"
      let some idx := idxStr.toNat?
        | return textResp 400 "invalid chunk index"
      match ← writeUploadSessionChunk workDir uid idx req.body with
      | .ok status => return jsonResp 200 status
      | .error msg => return textResp 400 msg
  else if req.method == "POST" && segs.length == 4 &&
          segs[0]? == some "uploads" && segs[1]? == some "sessions" && segs[3]? == some "complete" then
    let uid := segs[2]!
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.workDir
    match authCheck with
    | .error errResp => return errResp
    | .ok workDir =>
      match ← completeUploadSession workDir uid with
      | .ok receipt => return jsonResp 200 receipt
      | .error msg => return textResp 400 msg
  else if req.method == "DELETE" && segs.length == 3 &&
          segs[0]? == some "uploads" && segs[1]? == some "sessions" then
    let uid := segs[2]!
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.workDir
    match authCheck with
    | .error errResp => return errResp
    | .ok workDir =>
      match ← cancelUploadSession workDir uid with
      | .ok () => return { status := 204, contentType := "text/plain; charset=utf-8", body := ByteArray.empty }
      | .error msg => return textResp 400 msg
  else if req.method == "POST" && segs.length == 3 &&
          segs[0]? == some "workspaces" && segs[2]? == some "build" then
    let wsId := segs[1]!
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok (rt.cfg.workDir, rt.ledger.sqliteBackend)
    match authCheck with
    | .error errResp => return errResp
    | .ok (workDir, sqliteBackend) =>
      let opId? ←
        if req.body.isEmpty then pure none
        else match String.fromUTF8? req.body with
          | none => return textResp 400 "invalid UTF-8 body"
          | some s =>
            match OrbBin.Json.parse s with
            | .error _ => return textResp 400 "invalid JSON body"
            | .ok jv => pure (jv.fieldStr? "operation_id")
      match ← claimWorkspaceBuild workDir sqliteBackend wsId opId? with
      | .admitted rec => return jsonResp 200 rec.toJson
      | .conflict => return jsonResp 409 (.obj #[("error", .str "workspace_build_in_progress")])
      | .badRequest msg => return jsonResp 400 (.obj #[("error", .str msg)])
      | .dbError msg => return jsonResp 503 (.obj #[("error", .str msg)])
  else if req.method == "POST" && segs.length == 4 &&
          segs[0]? == some "workspaces" && segs[2]? == some "build" && segs[3]? == some "complete" then
    let wsId := segs[1]!
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok (rt.cfg.workDir, rt.ledger.sqliteBackend)
    match authCheck with
    | .error errResp => return errResp
    | .ok (workDir, sqliteBackend) =>
      let (termStatus, expGen?, expOp?) ←
        if req.body.isEmpty then pure ("completed", none, none)
        else match String.fromUTF8? req.body with
          | none => return textResp 400 "invalid UTF-8 body"
          | some s =>
            match OrbBin.Json.parse s with
            | .error _ => return textResp 400 "invalid JSON body"
            | .ok jv =>
              pure ((jv.fieldStr? "status").getD "completed", jv.fieldUInt64? "build_generation", jv.fieldStr? "operation_id")
      match ← completeWorkspaceBuild workDir sqliteBackend wsId termStatus expGen? expOp? with
      | .ok rec => return jsonResp 200 rec.toJson
      | .error (code, msg) => return jsonResp code (.obj #[("error", .str msg)])
  else if req.method == "POST" && segs == ["machine-transfer", "files"] then
    if req.body.size > 16 * 1024 * 1024 then
      return textResp 413 "payload too large"
    let some bodyStr := String.fromUTF8? req.body
      | return textResp 400 "invalid UTF-8 body"
    let .ok jv := OrbBin.Json.parse bodyStr
      | return textResp 400 "invalid JSON body"
    let (some rawMid, some rawTid, some side, some opVal) :=
        (jv.fieldStr? "mission_id", jv.fieldStr? "transfer_id", jv.fieldStr? "side", jv.field? "operation")
      | return textResp 400 "missing mission_id, transfer_id, side, or operation"
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return textResp 400 "invalid UUID"
    if side != "source" && side != "destination" then
      return textResp 400 "Invalid side"
    let srcMid := ((jv.fieldStr? "source_mission_id") >>= parseUuidCanonical?).getD mid
    let (gate, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      if rt.ledger.missionHasLiveJobs mid || rt.ledger.missionHasLiveJobs srcMid then
        return (Except.error (textResp 409 "Source execution has not terminated"), preL)
      return (Except.ok rt.cfg.workDir, preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match gate with
    | .error errResp => return errResp
    | .ok workDir =>
      let area := System.FilePath.mk workDir / ".transfers" / tid / side
      let srcTransfer? := (jv.fieldStr? "source_transfer") >>= parseUuidCanonical?
      let sourceDir := match srcTransfer? with
        | some stid => System.FilePath.mk workDir / ".transfers" / stid / "destination" / "workspace"
        | none => System.FilePath.mk workDir / srcMid
      let opName := (opVal.fieldStr? "op").getD ""
      let res ← transferMtx.atomically do
        if side == "source" && srcTransfer?.isNone && (opName == "inventory" || opName == "snapshot") then
          let sst ← statPath sourceDir.toString
          let wst ← statPath workDir
          if !sst.exists_ && wst.exists_ && wst.isDir && !wst.isSymlink then
            IO.FS.createDirAll sourceDir
        operateTransfer area (some sourceDir) opVal
      match res with
      | .ok out => return jsonResp 200 out
      | .error msg => return textResp 409 msg
  else if req.method == "POST" && segs == ["machine-transfer", "archive", "pack"] then
    let some bodyStr := String.fromUTF8? req.body
      | return textResp 400 "invalid UTF-8 body"
    let .ok jv := OrbBin.Json.parse bodyStr
      | return textResp 400 "invalid JSON body"
    let (some rawMid, some rawTid) := (jv.fieldStr? "mission_id", jv.fieldStr? "transfer_id")
      | return textResp 400 "missing mission_id or transfer_id"
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | return textResp 400 "invalid UUID"
    let srcMid := ((jv.fieldStr? "source_mission_id") >>= parseUuidCanonical?).getD mid
    let (gate, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      if rt.ledger.missionHasLiveJobs mid || rt.ledger.missionHasLiveJobs srcMid then
        return (Except.error (textResp 409 "Source execution has not terminated"), preL)
      return (Except.ok rt.cfg.workDir, preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match gate with
    | .error errResp => return errResp
    | .ok workDir =>
      let area := System.FilePath.mk workDir / ".transfers" / tid / "source"
      let packRes ← transferMtx.atomically do
        packTransferArchiveToFile area
      match packRes with
      | .ok outFile =>
        return { status := 200, contentType := "application/zstd", tempFile? := some outFile }
      | .error msg =>
        return textResp 409 msg
  else if req.method == "POST" && segs == ["machine-transfer", "archive", "unpack"] then
    let cleanupBodyTmp : IO Unit :=
      match req.bodyTempFile? with
      | some fp => do try IO.FS.removeFile fp catch _ => pure ()
      | none => pure ()
    let (some rawMid, some rawTid) := (req.query? "mission_id", req.query? "transfer_id")
      | cleanupBodyTmp
        return textResp 400 "missing mission_id or transfer_id query parameter"
    let (some mid, some tid) := (parseUuidCanonical? rawMid, parseUuidCanonical? rawTid)
      | cleanupBodyTmp
        return textResp 400 "invalid UUID"
    let (gate, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      if rt.ledger.missionHasLiveJobs mid then
        return (Except.error (textResp 409 "Source execution has not terminated"), preL)
      return (Except.ok rt.cfg.workDir, preL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match gate with
    | .error errResp =>
      cleanupBodyTmp
      return errResp
    | .ok workDir =>
      let area := System.FilePath.mk workDir / ".transfers" / tid / "destination"
      let unpackRes ← transferMtx.atomically do
        match req.bodyTempFile? with
        | some fp => do
          try
            unpackTransferArchiveFromFile area fp
          finally
            try IO.FS.removeFile fp catch _ => pure ()
        | none => unpackTransferArchive area req.body
      match unpackRes with
      | .ok written => return jsonResp 200 (.obj #[("ok", .bool true), ("bytes", JVal.uint64 written)])
      | .error msg => return textResp 409 msg
  else if req.method == "POST" && segs == ["machine-transfer", "browse"] then
    let some bodyStr := String.fromUTF8? req.body
      | return textResp 400 "invalid UTF-8 body"
    let .ok jv := OrbBin.Json.parse bodyStr
      | return textResp 400 "invalid JSON body"
    let (some rawTid, some opVal) := (jv.fieldStr? "transfer_id", jv.field? "operation")
      | return textResp 400 "missing transfer_id or operation"
    let some tid := parseUuidCanonical? rawTid
      | return textResp 400 "invalid transfer_id UUID"
    let authCheck ← mtx.atomically do
      let rt ← get
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return Except.error (textResp 401 "invalid node token")
      return Except.ok rt.cfg.workDir
    match authCheck with
    | .error errResp => return errResp
    | .ok workDir =>
      let area := System.FilePath.mk workDir / ".transfers" / tid / "destination"
      if !(← (area / "verified").pathExists) then
        return textResp 409 "Workspace is not verified"
      match ← executeFileBrowser (area / "workspace").toString opVal with
      | .ok res => return jsonResp 200 res
      | .error msg => return textResp 409 msg
  else if req.method == "POST" && segs.length == 3 && segs[0]? == some "jobs" && segs[2]? == some "cancel" then
    let jid := segs[1]!
    let key := (parseUuidCanonical? jid).getD jid
    let actor := (req.header? "x-sandboxed-cancel-actor").getD "unknown"
    let reason := (req.header? "x-sandboxed-cancel-reason").getD "Cancellation requested without reason"
    let (preRes, preLaunches) ← mtx.atomically do
      let (rt, preL) ← tickRuntimeReserve (← get)
      set rt
      if !verifyBearerHeader (req.header? "authorization") rt.cfg.token rt.cfg.tokenPrevious? then
        return (Except.error (textResp 401 "invalid node token"), preL)
      let some cur := rt.ledger.jobs.get? key
        | return (Except.error (textResp 404 s!"job {key} not found"), preL)
      if cur.state == .lost then
        return (Except.ok (Except.error (rt.cfg.nodeId, rt.cfg.workDir)), preL)
      match ← cancelJob rt key actor reason with
      | .error "not_found" => return (Except.error (textResp 404 s!"job {key} not found"), preL)
      | .error msg => return (Except.error (textResp 500 msg), preL)
      | .ok (rt', updated, cancelRequested) =>
        let (rtTicked, postL) ← tickRuntimeReserve rt'
        set rtTicked
        return (Except.ok (Except.ok (jsonResp 200 (.obj #[
          ("job_id", .str key),
          ("state", .str updated.state.asString),
          ("cancel_requested", .bool cancelRequested)
        ]))), preL ++ postL)
    if !preLaunches.isEmpty then
      spawnAsyncLaunches mtx preLaunches
    match preRes with
    | .error errResp => return errResp
    | .ok (.ok fastResp) => return fastResp
    | .ok (.error (nodeId, workDir)) =>
      let scopeStopped ← stopLostJobScopeOutsideLock nodeId workDir key
      let (resp, postLaunches) ← mtx.atomically do
        let rt ← get
        match ← cancelJob rt key actor reason (some scopeStopped) with
        | .error "not_found" => return (textResp 404 s!"job {key} not found", (#[] : Array PendingAsyncLaunch))
        | .error msg => return (textResp 500 msg, #[])
        | .ok (rt', updated, cancelRequested) =>
          let (rtTicked, postL) ← tickRuntimeReserve rt'
          set rtTicked
          return (jsonResp 200 (.obj #[
            ("job_id", .str key),
            ("state", .str updated.state.asString),
            ("cancel_requested", .bool cancelRequested)
          ]), postL)
      if !postLaunches.isEmpty then
        spawnAsyncLaunches mtx postLaunches
      return resp
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
  let transferMtx ← Std.Mutex.new ()
  let workDirConst := rtInit.cfg.workDir
  let authTokensConst := some (rtInit.cfg.token, rtInit.cfg.tokenPrevious?)
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
            match ← readHttpRequest cfd workDirConst 134217728 authTokensConst with
            | .error "unauthorized" =>
              sendHttpResponse cfd (textResp 401 "invalid node token")
            | .error "payload_too_large" =>
              sendHttpResponse cfd (textResp 413 "payload too large")
            | .error err =>
              if err.startsWith "bad_request:" then
                sendHttpResponse cfd (textResp 400 (err.drop 12).toString)
              else if err.startsWith "conflict:" then
                sendHttpResponse cfd (textResp 409 (err.drop 9).toString)
              else
                pure ()
            | .ok req =>
              let resp ← handleRequestConcurrent mtx transferMtx req
              sendHttpResponse cfd resp
          finally
            OrbNode.Posix.fdClose cfd
  finally
    goneRef.set true
    OrbNode.Posix.fdClose lfd
  return 0

end OrbNode.Server
