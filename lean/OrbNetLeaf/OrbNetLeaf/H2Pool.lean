/-
  OrbNetLeaf.H2Pool: Persistent multiplexed RFC 9113 HTTP/2 connection pool over WebPKI TLS 1.3
  (`ALPN "h2"`) with single-owner actor `Task` per `(host, port)` origin, priority-ordered
  (`0 = P0 > 1 = P1 > 2 = P2`) `16 KiB` frame scheduling, shared connection-level `HpackDecoderTable`,
  automatic `SETTINGS`/`PING` ACK & bidirectional `WINDOW_UPDATE`, live `PING` RTT measurement,
  unprocessed-stream `GOAWAY` retry, and automatic HTTP/1.1 fallback when a custom origin only
  negotiates `http/1.1`.
-/
import Std.Sync.Mutex
import LeanSys.Spec
import LeanSys.Posix
import LeanSys.H2
import OrbNetLeaf.Spec
import OrbNetLeaf.HpackQpack
import OrbNetLeaf.TlsHttp

namespace OrbNetLeaf.H2Pool

open LeanSys.Spec
open LeanSys.Posix
open LeanSys.H2
open OrbNetLeaf.Spec
open OrbNetLeaf.HpackQpack
open OrbNetLeaf.TlsHttp

/-- Request priority class (`0 = P0` critical user send/approval, `1 = P1` foreground mission/sidebar,
    `2 = P2` background sweep/prefetch). -/
abbrev StreamPriority := UInt8

/-- Result returned by `H2ClientPool.request`: `(response, rttSampleMs, reusedConnection)`. -/
structure PooledHttpResult where
  response   : HttpsResponse
  rttMs      : UInt32
  reusedConn : Bool

/-- Outcome signaled to a waiting request caller. -/
private inductive StreamOutcome where
  | ok (resp : HttpsResponse) (rttMs : UInt32) (reused : Bool)
  | retryUnprocessed (reason : String)
  | error (msg : String)

private instance : Nonempty StreamOutcome := ⟨.error "uninitialized"⟩

private structure PendingRequest where
  priority     : StreamPriority
  method       : String
  authority    : String
  path         : String
  headers      : Array (String × String)
  body         : ByteArray
  maxRespBytes : Nat
  deadlineMs   : Nat
  enqueuedMs   : Nat
  promise      : IO.Promise StreamOutcome

private structure ActiveStream where
  streamId       : UInt32
  priority       : StreamPriority
  method         : String
  hpackBlock     : ByteArray
  headersSent    : Bool := false
  body           : ByteArray
  sentBody       : Nat := 0
  peerSendWin    : Int := 65535
  unackedRecv    : Nat := 0
  maxRespBytes   : Nat
  deadlineMs     : Nat
  startedMs      : Nat
  reusedConn     : Bool
  sawFinalStatus : Bool := false
  sawTrailers    : Bool := false
  infoCount      : Nat := 0
  statusCode     : Nat := 0
  respHeaders    : Array (String × String) := #[]
  contentLen?    : Option Nat := none
  bodyChunks     : Array ByteArray := #[]
  bodyBytes      : Nat := 0
  pendingEnd     : Bool := false
  rxDone         : Bool := false
  promise        : IO.Promise StreamOutcome

private structure ConnSharedState where
  queue          : Array PendingRequest := #[]
  closed         : Bool := false
  lastPingRttMs  : UInt32 := 0

private structure OriginPoolEntry where
  host         : String
  port         : UInt16
  verifyPeer   : Bool
  shared       : Std.Mutex ConnSharedState
  generation   : Nat

private inductive OriginConnectResult where
  | ok (entry : OriginPoolEntry)
  | fallbackH1
  | failed (msg : String)

private instance : Nonempty OriginConnectResult := ⟨.failed "uninitialized"⟩

private structure InFlightOriginConnect where
  host       : String
  port       : UInt16
  verifyPeer : Bool
  promise    : IO.Promise OriginConnectResult

private structure PoolMapState where
  nextGen          : Nat := 1
  entries          : Array OriginPoolEntry := #[]
  inFlightConnects : Array InFlightOriginConnect := #[]
  h1OnlyHosts      : Array (String × UInt16) := #[]

/-- Persistent multiplexed HTTP/2 client pool (`Std.Mutex`-guarded). -/
structure H2ClientPool where
  private mk ::
  mu : Std.Mutex PoolMapState

/-- Create a fresh empty `H2ClientPool`. -/
def H2ClientPool.new : IO H2ClientPool := do
  let mu ← Std.Mutex.new {}
  return { mu := mu }

private def flattenChunks (chunks : Array ByteArray) (total : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity total
  for c in chunks do
    out := out ++ c
  return out

private def encodePingFrame (token : UInt64) : ByteArray := Id.run do
  let mut pay := ByteArray.emptyWithCapacity 8
  for shift in [0:8] do
    let b := ((token >>> ((7 - shift) * 8).toUInt64) &&& 0xFF).toUInt8
    pay := pay.push b
  return (ByteArray.mk #[0x00, 0x00, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00]) ++ pay

private def buildRstStreamFrame? (streamId : UInt32) (errCode : UInt32) : Option ByteArray :=
  if streamId == 0 || streamId > 0x7FFFFFFF then none
  else
    let pay := ByteArray.mk #[
      ((errCode >>> 24) &&& 0xFF).toUInt8,
      ((errCode >>> 16) &&& 0xFF).toUInt8,
      ((errCode >>> 8) &&& 0xFF).toUInt8,
      (errCode &&& 0xFF).toUInt8
    ]
    encodeFrame? { frameType := .rstStream, flags := 0x00, streamId := streamId, payload := pay } 16384 4

private def decodeU64BE (b : ByteArray) : UInt64 := Id.run do
  if b.size < 8 then return 0
  let mut acc : UInt64 := 0
  for i in [0:8] do
    acc := (acc <<< 8) ||| (b.get! i).toUInt64
  return acc

private def insertByPriority (arr : Array ActiveStream) (s : ActiveStream) : Array ActiveStream := Id.run do
  let mut out : Array ActiveStream := Array.mkEmpty (arr.size + 1)
  let mut inserted := false
  for item in arr do
    if !inserted && s.priority < item.priority then
      out := out.push s
      inserted := true
    out := out.push item
  if !inserted then
    out := out.push s
  return out

private def removeStreamById (arr : Array ActiveStream) (sid : UInt32) : Array ActiveStream :=
  arr.filter (fun s => s.streamId != sid)

private def findStreamIdx? (arr : Array ActiveStream) (sid : UInt32) : Option Nat := Id.run do
  for i in [0:arr.size] do
    if let some item := arr[i]? then
      if item.streamId == sid then
        return some i
  return none

private def drainPendingQueue (shared : Std.Mutex ConnSharedState) : IO (Array PendingRequest) :=
  shared.atomically do
    let st ← get
    if st.queue.isEmpty then
      return #[]
    set { st with queue := #[] }
    return st.queue

private def markConnClosedAndDrain (shared : Std.Mutex ConnSharedState) : IO (Array PendingRequest) :=
  shared.atomically do
    let st ← get
    set { st with queue := #[], closed := true }
    return st.queue

private def failAllStreams (streams : Array ActiveStream) (out : StreamOutcome) : IO Unit := do
  for s in streams do
    s.promise.resolve out

private def failPendingRequests (reqs : Array PendingRequest) (out : StreamOutcome) : IO Unit := do
  for r in reqs do
    r.promise.resolve out

/-- Single-owner actor loop driving one persistent TLS 1.3 `ALPN "h2"` connection. -/
private partial def runH2OriginWorker
    (pool : H2ClientPool) (entry : OriginPoolEntry) (sess : TlsSession) : IO Unit := do
  let connOpenedMs ← IO.monoMsNow
  let mut nextStreamId : UInt32 := 1
  let mut streams : Array ActiveStream := #[]
  let mut hpackTbl : HpackDecoderTable := {}
  let mut peerInitWin : Int := 65535
  let mut peerConnWin : Int := 65535
  let mut peerMaxConcurrent : Nat := 100
  let mut unackedConnRecv : Nat := 0
  let mut pendingBuf := ByteArray.empty
  let mut pendingOff : Nat := 0
  let mut awaitingContSid? : Option UInt32 := none
  let mut hdrAccum := ByteArray.empty
  let mut goingAway := false
  let mut fatalErr? : Option String := none
  let mut lastActivityMs ← IO.monoMsNow
  let mut lastRxMs : Nat := lastActivityMs
  let mut lastPingSentMs : Nat := lastActivityMs
  let mut inFlightPingToken? : Option (UInt64 × Nat) := none
  let mut firstStreamUsed := false

  try
    while fatalErr?.isNone && !(goingAway && streams.isEmpty) do
      let nowMs ← IO.monoMsNow

      -- 1. Pull newly submitted requests from mutex queue when capacity allows
      if !goingAway && streams.size < peerMaxConcurrent && nextStreamId < 0x3FFFFFFF then
        let incoming ← drainPendingQueue entry.shared
        let mut overflow : Array PendingRequest := #[]
        for req in incoming do
          if nowMs >= req.deadlineMs then
            req.promise.resolve (.error "HTTP/2 request timed out before dispatch")
          else if streams.size < peerMaxConcurrent && nextStreamId < 0x3FFFFFFF then
            match buildPseudoAndAppHeaders req.method req.authority req.path req.headers req.body.size with
            | .error e =>
              req.promise.resolve (.error e)
            | .ok allHdrs =>
              let sid := nextStreamId
              nextStreamId := nextStreamId + 2
              let reused := firstStreamUsed || (nowMs - connOpenedMs >= 5)
              firstStreamUsed := true
              let s : ActiveStream := {
                streamId := sid
                priority := req.priority
                method := req.method
                hpackBlock := encodeHeadersBlock allHdrs
                body := req.body
                peerSendWin := peerInitWin
                maxRespBytes := req.maxRespBytes
                deadlineMs := req.deadlineMs
                startedMs := nowMs
                reusedConn := reused
                promise := req.promise
              }
              streams := insertByPriority streams s
              lastActivityMs := nowMs
          else
            overflow := overflow.push req
        if !overflow.isEmpty then
          entry.shared.atomically do
            let st ← get
            set { st with queue := overflow ++ st.queue }
        if nextStreamId >= 0x3FFFFFFF then
          goingAway := true

      -- 2. Fail any individual stream whose deadline expired (sending RST_STREAM CANCEL = 0x08)
      let mut expiredIds : Array UInt32 := #[]
      for s in streams do
        if nowMs >= s.deadlineMs then
          expiredIds := expiredIds.push s.streamId
          s.promise.resolve (.error "HTTP/2 stream deadline exceeded")
          if s.headersSent then
            if let some rst := buildRstStreamFrame? s.streamId 0x08 then
              discard <| writeTlsSessionAll sess rst
      if !expiredIds.isEmpty then
        streams := streams.filter (fun s => !expiredIds.contains s.streamId)

      -- 3. Priority-ordered outbound frame flush:
      --    (a) Send HEADERS (+ CONTINUATION) in priority order (`P0` -> `P1` -> `P2`)
      for idx in [0:streams.size] do
        if fatalErr?.isNone then
          if let some s := streams[idx]? then
            if !s.headersSent then
              let endStream := s.body.isEmpty
              match encodeH2HeadersWithContinuation s.streamId s.hpackBlock endStream 16384 with
              | .error e =>
                s.promise.resolve (.error e)
                streams := streams.setIfInBounds idx { s with headersSent := true, rxDone := true }
              | .ok hdrWire =>
                if !(← writeTlsSessionAll sess hdrWire) then
                  fatalErr? := some "HTTP/2 TLS write failed during HEADERS"
                else
                  streams := streams.setIfInBounds idx { s with headersSent := true }
                  lastActivityMs := nowMs
      streams := streams.filter (fun s => !(s.headersSent && s.rxDone))

      --    (b) Send one 16 KiB DATA quantum per pass in strict priority order (`P0` preempts `P1`/`P2`)
      let mut madeWriteProgress := true
      while madeWriteProgress && fatalErr?.isNone && peerConnWin > 0 do
        madeWriteProgress := false
        for idx in [0:streams.size] do
          if !madeWriteProgress && fatalErr?.isNone && peerConnWin > 0 then
            if let some s := streams[idx]? then
              if s.headersSent && s.sentBody < s.body.size && s.peerSendWin > 0 then
                let minWin : Int := if peerConnWin < s.peerSendWin then peerConnWin else s.peerSendWin
                let avail := minWin.toNat
                let chunkLen := Nat.min 16384 (Nat.min avail (s.body.size - s.sentBody))
                if chunkLen > 0 then
                  let isLast := (s.sentBody + chunkLen == s.body.size)
                  let dFlags : UInt8 := if isLast then 0x01 else 0x00
                  let chunk := s.body.extract s.sentBody (s.sentBody + chunkLen)
                  match encodeFrame? { frameType := .data, flags := dFlags, streamId := s.streamId, payload := chunk } 16384 chunkLen.toUInt64 with
                  | none =>
                    fatalErr? := some "failed to encode HTTP/2 DATA frame"
                  | some dFrame =>
                    if !(← writeTlsSessionAll sess dFrame) then
                      fatalErr? := some "HTTP/2 TLS write failed during DATA"
                    else
                      let sent' := s.sentBody + chunkLen
                      peerConnWin := peerConnWin - (chunkLen : Int)
                      streams := streams.setIfInBounds idx { s with
                        sentBody := sent'
                        peerSendWin := s.peerSendWin - (chunkLen : Int)
                      }
                      lastActivityMs := nowMs
                      madeWriteProgress := true

      -- 4. Idle timeout (`90 s`) & liveness `PING` probe (`3 s` rx-silence + `4 s` ACK deadline when streams wait)
      if fatalErr?.isNone then
        let hasQueued ← entry.shared.atomically do return !(← get).queue.isEmpty
        if streams.isEmpty && !hasQueued && (nowMs - lastActivityMs >= 90000) then
          goingAway := true
        else
          if let some (_, pingSentAt) := inFlightPingToken? then
            let pingDeadlineMs : Nat := if !streams.isEmpty then 4000 else 12000
            if nowMs - pingSentAt >= pingDeadlineMs then
              fatalErr? := some "HTTP/2 keepalive PING timed out"
          else if (!streams.isEmpty && nowMs - lastRxMs >= 3000 && nowMs - lastPingSentMs >= 3000) ||
                  (!streams.isEmpty && nowMs - lastPingSentMs >= 15000) ||
                  (streams.isEmpty && nowMs - lastPingSentMs >= 30000) then
            let tok : UInt64 := nowMs.toUInt64 ^^^ 0x4F52424832504E47
            if !(← writeTlsSessionAll sess (encodePingFrame tok)) then
              fatalErr? := some "HTTP/2 PING write failed"
            else
              lastPingSentMs := nowMs
              inFlightPingToken? := some (tok, nowMs)

      -- 5. Poll inbound TLS records with short timeout (`4 ms` when streams active, `8 ms` when idle)
      if fatalErr?.isNone && !(goingAway && streams.isEmpty) then
        let hasQueuedNow ← entry.shared.atomically do return !(← get).queue.isEmpty
        let pollMs : UInt32 := if hasQueuedNow then 1 else if !streams.isEmpty then 4 else 8
        match ← readTlsSessionChunk sess 16384 pollMs with
        | .closeNotify | .tcpEof =>
          fatalErr? := some "HTTP/2 peer closed TLS connection"
        | .timeout =>
          pure ()
        | .transportError =>
          fatalErr? := some "HTTP/2 TLS read error"
        | .chunk c =>
          if !c.isEmpty then
            let rxAtMs ← IO.monoMsNow
            lastActivityMs := rxAtMs
            lastRxMs := rxAtMs
            pendingBuf := pendingBuf ++ c
            let mut scanMore := true
            while scanMore && fatalErr?.isNone do
              if pendingBuf.size - pendingOff < 9 then
                scanMore := false
              else
                let b0 := (pendingBuf.get! pendingOff).toNat
                let b1 := (pendingBuf.get! (pendingOff + 1)).toNat
                let b2 := (pendingBuf.get! (pendingOff + 2)).toNat
                let payLen := (b0 <<< 16) ||| (b1 <<< 8) ||| b2
                if payLen > 16384 then
                  fatalErr? := some s!"HTTP/2 inbound frame exceeds 16384 maxFrameSize ({payLen})"
                else if pendingBuf.size - pendingOff < 9 + payLen then
                  scanMore := false
                else
                  let ty := pendingBuf.get! (pendingOff + 3)
                  let fl := pendingBuf.get! (pendingOff + 4)
                  let s0 := (pendingBuf.get! (pendingOff + 5)).toUInt32 &&& 0x7F
                  let s1 := (pendingBuf.get! (pendingOff + 6)).toUInt32
                  let s2 := (pendingBuf.get! (pendingOff + 7)).toUInt32
                  let s3 := (pendingBuf.get! (pendingOff + 8)).toUInt32
                  let sid := (s0 <<< 24) ||| (s1 <<< 16) ||| (s2 <<< 8) ||| s3
                  let pay := pendingBuf.extract (pendingOff + 9) (pendingOff + 9 + payLen)
                  pendingOff := pendingOff + 9 + payLen
                  let canonFt := H2FrameType.ofByte ty
                  if verifyH2FrameHeader payLen.toUInt32 16384 ty fl sid 16777216 (9 + payLen).toUInt64 != 1 ||
                     !payloadStructurallyValid canonFt fl (ByteSource.ofByteArray pay) then
                    fatalErr? := some "HTTP/2 inbound frame rejected by verifyH2FrameHeader"
                  else if awaitingContSid?.isSome && (ty != 9 || awaitingContSid? != some sid) then
                    fatalErr? := some "HTTP/2 connection-level CONTINUATION lock violated"
                  else if ty == 5 then
                    fatalErr? := some "HTTP/2 server PUSH_PROMISE forbidden (ENABLE_PUSH=0)"
                  else if ty == 4 && sid == 0 then
                    match validatePeerSettingsPayload fl pay with
                    | .error e => fatalErr? := some e
                    | .ok newWin? =>
                      if (fl &&& 0x01) == 0 then
                        -- Parse SETTINGS_MAX_CONCURRENT_STREAMS (0x0003) if present
                        let scount := pay.size / 6
                        for i in [0:scount] do
                          let b := i * 6
                          let pid : UInt16 := ((pay.get! b).toUInt16 <<< 8) ||| (pay.get! (b + 1)).toUInt16
                          if pid == 0x0003 then
                            let v0 := (pay.get! (b + 2)).toUInt32
                            let v1 := (pay.get! (b + 3)).toUInt32
                            let v2 := (pay.get! (b + 4)).toUInt32
                            let v3 := (pay.get! (b + 5)).toUInt32
                            let mc := ((v0 <<< 24) ||| (v1 <<< 16) ||| (v2 <<< 8) ||| v3).toNat
                            peerMaxConcurrent := Nat.max 1 (Nat.min mc 256)
                        if let some nw := newWin? then
                          let delta : Int := (nw : Int) - peerInitWin
                          peerInitWin := (nw : Int)
                          for k in [0:streams.size] do
                            if let some sk := streams[k]? then
                              streams := streams.setIfInBounds k { sk with peerSendWin := sk.peerSendWin + delta }
                        if !(← writeTlsSessionAll sess h2SettingsAckFrame) then
                          fatalErr? := some "HTTP/2 SETTINGS ACK write failed"
                  else if ty == 6 && sid == 0 && pay.size == 8 then
                    if (fl &&& 0x01) == 0 then
                      if !(← writeTlsSessionAll sess (buildH2PingAckFrame pay)) then
                        fatalErr? := some "HTTP/2 PING ACK write failed"
                    else
                      if let some (expectedTok, sentAt) := inFlightPingToken? then
                        if decodeU64BE pay == expectedTok then
                          let rttNat := Nat.max 1 (rxAtMs - sentAt)
                          entry.shared.atomically do
                            let st ← get
                            set { st with lastPingRttMs := (Nat.min rttNat 60000).toUInt32 }
                          inFlightPingToken? := none
                  else if ty == 8 && pay.size == 4 then
                    let w0 := (pay.get! 0).toUInt32 &&& 0x7F
                    let w1 := (pay.get! 1).toUInt32
                    let w2 := (pay.get! 2).toUInt32
                    let w3 := (pay.get! 3).toUInt32
                    let inc := (w0 <<< 24) ||| (w1 <<< 16) ||| (w2 <<< 8) ||| w3
                    if sid == 0 then
                      peerConnWin := peerConnWin + (inc.toNat : Int)
                      if peerConnWin > (0x7FFFFFFF : Int) then
                        fatalErr? := some "HTTP/2 connection send window overflow"
                    else if let some sIdx := findStreamIdx? streams sid then
                      if let some sk := streams[sIdx]? then
                        let nextWin := sk.peerSendWin + (inc.toNat : Int)
                        if nextWin > (0x7FFFFFFF : Int) then
                          sk.promise.resolve (.error "HTTP/2 stream send window overflow")
                          streams := removeStreamById streams sid
                        else
                          streams := streams.setIfInBounds sIdx { sk with peerSendWin := nextWin }
                  else if ty == 3 then
                    if let some sIdx := findStreamIdx? streams sid then
                      if let some sk := streams[sIdx]? then
                        let e0 := if pay.size >= 4 then (pay.get! 0).toUInt32 else 0
                        let e1 := if pay.size >= 4 then (pay.get! 1).toUInt32 else 0
                        let e2 := if pay.size >= 4 then (pay.get! 2).toUInt32 else 0
                        let e3 := if pay.size >= 4 then (pay.get! 3).toUInt32 else 0
                        let errCode := (e0 <<< 24) ||| (e1 <<< 16) ||| (e2 <<< 8) ||| e3
                        -- REFUSED_STREAM (0x07) guarantees zero server processing (RFC 9113 §8.7)
                        if errCode == 0x07 then
                          sk.promise.resolve (.retryUnprocessed "HTTP/2 REFUSED_STREAM")
                        else
                          sk.promise.resolve (.error s!"HTTP/2 peer reset stream (RST_STREAM err={errCode})")
                        streams := removeStreamById streams sid
                  else if ty == 7 then
                    match parseGoawayPayload pay with
                    | .error e => fatalErr? := some e
                    | .ok (lastSid, errCode) =>
                      goingAway := true
                      if errCode != 0 then
                        fatalErr? := some s!"HTTP/2 GOAWAY error {errCode}"
                      else
                        let mut kept : Array ActiveStream := #[]
                        for sk in streams do
                          if sk.streamId > lastSid then
                            sk.promise.resolve (.retryUnprocessed "HTTP/2 GOAWAY unprocessed stream")
                          else
                            kept := kept.push sk
                        streams := kept
                  else if ty == 1 || ty == 9 then
                    -- Always decode HPACK blocks even if stream was already reset/timed-out so dynamic table stays synchronized!
                    let mut fragOk := true
                    let mut frameEndHeaders := false
                    let mut frameEndStream := false
                    if ty == 1 then
                      let padded := (fl &&& 0x08) != 0
                      let hasPrio := (fl &&& 0x20) != 0
                      let minHdr := (if padded then 1 else 0) + (if hasPrio then 5 else 0)
                      let padLen := if padded then (pay.get! 0).toNat else 0
                      let fragLen := pay.size - minHdr - padLen
                      frameEndHeaders := (fl &&& 0x04) != 0
                      frameEndStream := (fl &&& 0x01) != 0
                      if hdrAccum.size + fragLen > 65536 then
                        fatalErr? := some "HTTP/2 header block exceeds 64 KiB cap"
                        fragOk := false
                      else
                        hdrAccum := hdrAccum ++ pay.extract minHdr (minHdr + fragLen)
                        if !frameEndHeaders then
                          awaitingContSid? := some sid
                          if let some sIdx := findStreamIdx? streams sid then
                            if let some sk := streams[sIdx]? then
                              streams := streams.setIfInBounds sIdx { sk with pendingEnd := frameEndStream }
                    else
                      frameEndHeaders := (fl &&& 0x04) != 0
                      if hdrAccum.size + pay.size > 65536 then
                        fatalErr? := some "HTTP/2 header block exceeds 64 KiB cap"
                        fragOk := false
                      else
                        hdrAccum := hdrAccum ++ pay
                        if frameEndHeaders then
                          awaitingContSid? := none
                    if fragOk && frameEndHeaders then
                      match decodeRfc7541BlockWithTable? hpackTbl (ByteSource.ofByteArray hdrAccum) with
                      | none =>
                        fatalErr? := some "HTTP/2 HPACK decode failed"
                      | some (fields, hpackTbl') =>
                        hpackTbl := hpackTbl'
                        hdrAccum := ByteArray.empty
                        if let some sIdx := findStreamIdx? streams sid then
                          if let some sk := streams[sIdx]? then
                            let effEndStream := if ty == 1 then frameEndStream else sk.pendingEnd
                            let mut skNext := { sk with pendingEnd := false }
                            let mut streamErr? : Option String := none
                            if skNext.sawTrailers then
                              streamErr? := some "HTTP/2 unexpected HEADERS after trailers"
                            else if skNext.sawFinalStatus then
                              if !effEndStream then
                                streamErr? := some "HTTP/2 trailing HEADERS missing END_STREAM"
                              else
                                match validateTrailerFields "HTTP/2" fields with
                                | .error e => streamErr? := some e
                                | .ok () => skNext := { skNext with sawTrailers := true }
                            else
                              match validateDecodedHeaderFields "HTTP/2" fields with
                              | .error e => streamErr? := some e
                              | .ok (code, hdrs, cl?) =>
                                if code >= 100 && code < 200 then
                                  if code == 101 || effEndStream || skNext.infoCount >= 8 then
                                    streamErr? := some "HTTP/2 invalid 1xx informational response"
                                  else
                                    skNext := { skNext with infoCount := skNext.infoCount + 1 }
                                else
                                  skNext := { skNext with
                                    sawFinalStatus := true
                                    statusCode := code
                                    respHeaders := hdrs
                                    contentLen? := cl?
                                  }
                            if let some serr := streamErr? then
                              skNext.promise.resolve (.error serr)
                              streams := removeStreamById streams sid
                            else if effEndStream then
                              if !skNext.sawFinalStatus then
                                skNext.promise.resolve (.error "HTTP/2 stream ended without final :status")
                              else
                                let bodyBuf := flattenChunks skNext.bodyChunks skNext.bodyBytes
                                match enforceBodylessAndLengthInvariants "HTTP/2" skNext.method skNext.statusCode skNext.respHeaders skNext.contentLen? bodyBuf with
                                | .error e => skNext.promise.resolve (.error e)
                                | .ok resp =>
                                  let dur := Nat.max 1 (rxAtMs - skNext.startedMs)
                                  skNext.promise.resolve (.ok resp (Nat.min dur 60000).toUInt32 skNext.reusedConn)
                              streams := removeStreamById streams sid
                            else
                              streams := streams.setIfInBounds sIdx skNext
                  else if ty == 0 then
                    -- Replenish connection window regardless of whether stream is still active
                    unackedConnRecv := unackedConnRecv + payLen
                    if unackedConnRecv >= 2097152 then
                      if let some wuConn := buildWindowUpdateFrame? 0 unackedConnRecv.toUInt32 then
                        if !(← writeTlsSessionAll sess wuConn) then
                          fatalErr? := some "HTTP/2 connection WINDOW_UPDATE write failed"
                        else
                          unackedConnRecv := 0
                    if let some sIdx := findStreamIdx? streams sid then
                      if let some sk := streams[sIdx]? then
                        if !sk.sawFinalStatus || sk.sawTrailers then
                          sk.promise.resolve (.error "HTTP/2 DATA frame outside response body phase")
                          streams := removeStreamById streams sid
                        else
                          let padded := (fl &&& 0x08) != 0
                          let dStart := if padded then 1 else 0
                          let padLen := if padded then (pay.get! 0).toNat else 0
                          let dLen := pay.size - dStart - padLen
                          if sk.bodyBytes + dLen > sk.maxRespBytes then
                            sk.promise.resolve (.error s!"HTTP/2 response body exceeds maxRespBytes ({sk.maxRespBytes})")
                            if let some rst := buildRstStreamFrame? sid 0x08 then
                              discard <| writeTlsSessionAll sess rst
                            streams := removeStreamById streams sid
                          else
                            let payloadSlice := pay.extract dStart (dStart + dLen)
                            let nextChunks := if dLen > 0 then sk.bodyChunks.push payloadSlice else sk.bodyChunks
                            let nextBytes := sk.bodyBytes + dLen
                            let nextUnacked := sk.unackedRecv + payLen
                            let isEnd := (fl &&& 0x01) != 0
                            if isEnd then
                              let bodyBuf := flattenChunks nextChunks nextBytes
                              match enforceBodylessAndLengthInvariants "HTTP/2" sk.method sk.statusCode sk.respHeaders sk.contentLen? bodyBuf with
                              | .error e => sk.promise.resolve (.error e)
                              | .ok resp =>
                                let dur := Nat.max 1 (rxAtMs - sk.startedMs)
                                sk.promise.resolve (.ok resp (Nat.min dur 60000).toUInt32 sk.reusedConn)
                              streams := removeStreamById streams sid
                            else
                              let mut remUnacked := nextUnacked
                              if remUnacked >= 2097152 then
                                if let some wuStrm := buildWindowUpdateFrame? sid remUnacked.toUInt32 then
                                  if !(← writeTlsSessionAll sess wuStrm) then
                                    fatalErr? := some "HTTP/2 stream WINDOW_UPDATE write failed"
                                  else
                                    remUnacked := 0
                              streams := streams.setIfInBounds sIdx { sk with
                                bodyChunks := nextChunks
                                bodyBytes := nextBytes
                                unackedRecv := remUnacked
                              }
            if pendingOff >= 32768 && pendingOff * 2 >= pendingBuf.size then
              pendingBuf := pendingBuf.extract pendingOff pendingBuf.size
              pendingOff := 0
  finally
    closeTlsSession sess
    let leftover ← markConnClosedAndDrain entry.shared
    pool.mu.atomically do
      let st ← get
      set { st with entries := st.entries.filter (fun e => e.generation != entry.generation) }
    let errMsg := fatalErr?.getD "HTTP/2 connection closed"
    -- Any request still queued in `leftover` or active without `headersSent` was never transmitted and can safely retry!
    failPendingRequests leftover (.retryUnprocessed errMsg)
    for sk in streams do
      if !sk.headersSent then
        sk.promise.resolve (.retryUnprocessed errMsg)
      else
        sk.promise.resolve (.error errMsg)

/-- Ensure a live HTTP/2 connection worker exists for `(host, port, verifyPeer)`, coalescing
    concurrent cold-start handshakes onto a single in-flight TLS 1.3 dial per origin, and falling
    back to HTTP/1.1 strictly when TLS succeeded without negotiating `ALPN "h2"`. -/
private def getOrConnectOrigin
    (pool : H2ClientPool) (host : String) (port : UInt16)
    (verifyPeer : Bool) (connectTimeoutMs : UInt32) : IO OriginConnectResult := do
  let freshProm ← IO.Promise.new
  let (immediate?, waiter?, isLeader) ← pool.mu.atomically do
    let st ← get
    if st.h1OnlyHosts.contains (host, port) then
      return (some OriginConnectResult.fallbackH1, none, false)
    match st.entries.find? (fun e => e.host == host && e.port == port && e.verifyPeer == verifyPeer) with
    | some e => return (some (.ok e), none, false)
    | none =>
      match st.inFlightConnects.find? (fun c => c.host == host && c.port == port && c.verifyPeer == verifyPeer) with
      | some inflight => return (none, some inflight.promise, false)
      | none =>
        let inflight : InFlightOriginConnect := {
          host := host, port := port, verifyPeer := verifyPeer, promise := freshProm
        }
        set { st with inFlightConnects := st.inFlightConnects.push inflight }
        return (none, some freshProm, true)
  if let some res := immediate? then
    return res
  if !isLeader then
    match waiter? with
    | some prom => return prom.result!.get
    | none => return .failed s!"missing in-flight connect promise for {host}:{port}"
  let mut resolved := false
  try
    match ← openH2PersistentSessionOutcome host port verifyPeer connectTimeoutMs with
    | .ok sess =>
      let shared ← Std.Mutex.new {}
      let (chosen, supersededSess?) ← pool.mu.atomically do
        let st ← get
        let remInflight := st.inFlightConnects.filter
          (fun c => !(c.host == host && c.port == port && c.verifyPeer == verifyPeer))
        match st.entries.find? (fun e => e.host == host && e.port == port && e.verifyPeer == verifyPeer) with
        | some raceWinner =>
          set { st with inFlightConnects := remInflight }
          return (raceWinner, some sess)
        | none =>
          let gen := st.nextGen
          let entry : OriginPoolEntry := {
            host := host, port := port, verifyPeer := verifyPeer, shared := shared, generation := gen
          }
          set { st with nextGen := gen + 1, entries := st.entries.push entry, inFlightConnects := remInflight }
          return (entry, none)
      if let some dup := supersededSess? then
        closeTlsSession dup
      else
        discard <| IO.asTask (prio := .dedicated) (runH2OriginWorker pool chosen sess)
      let out := OriginConnectResult.ok chosen
      freshProm.resolve out
      resolved := true
      return out
    | .alpnFallbackH1 =>
      pool.mu.atomically do
        let st ← get
        let remInflight := st.inFlightConnects.filter
          (fun c => !(c.host == host && c.port == port && c.verifyPeer == verifyPeer))
        let h1' := if st.h1OnlyHosts.contains (host, port) then st.h1OnlyHosts else st.h1OnlyHosts.push (host, port)
        set { st with inFlightConnects := remInflight, h1OnlyHosts := h1' }
      let out := OriginConnectResult.fallbackH1
      freshProm.resolve out
      resolved := true
      return out
    | .transportError msg =>
      pool.mu.atomically do
        let st ← get
        let remInflight := st.inFlightConnects.filter
          (fun c => !(c.host == host && c.port == port && c.verifyPeer == verifyPeer))
        set { st with inFlightConnects := remInflight }
      let out := OriginConnectResult.failed msg
      freshProm.resolve out
      resolved := true
      return out
  finally
    if !resolved then
      pool.mu.atomically do
        let st ← get
        let remInflight := st.inFlightConnects.filter
          (fun c => !(c.host == host && c.port == port && c.verifyPeer == verifyPeer))
        set { st with inFlightConnects := remInflight }
      freshProm.resolve (.failed s!"HTTP/2 connect aborted for {host}:{port}")

/-- Pre-warm a persistent TLS 1.3 HTTP/2 connection in the background so the user's first action pays 0 handshake RTTs. -/
def H2ClientPool.prewarm
    (pool : H2ClientPool) (host : String) (port : UInt16 := 443)
    (verifyPeer : Bool := true) (connectTimeoutMs : UInt32 := 6000) : IO Unit := do
  discard <| IO.asTask (prio := .dedicated) do
    discard <| getOrConnectOrigin pool host port verifyPeer connectTimeoutMs

/-- Execute a prioritized HTTP request over the persistent multiplexed HTTP/2 pool, transparently
    retrying once on a fresh connection if an idle socket closed or emitted `GOAWAY` before processing,
    and falling back to `httpsRequest` (`HTTP/1.1`) when a custom server does not negotiate `ALPN "h2"`. -/
def H2ClientPool.request
    (pool : H2ClientPool)
    (priority : StreamPriority)
    (method host : String) (port : UInt16 := 443) (path : String := "/")
    (headers : Array (String × String) := #[])
    (body : ByteArray := ByteArray.empty)
    (maxRespBytes : Nat := 16777216)
    (verifyPeer : Bool := true)
    (connectTimeoutMs : UInt32 := 8000)
    (totalTimeoutMs : UInt32 := 65000) : IO (Except String PooledHttpResult) := do
  let authority := formatHostAuthority host port 443
  let mut attempt : Nat := 0
  while attempt < 2 do
    attempt := attempt + 1
    match ← getOrConnectOrigin pool host port verifyPeer connectTimeoutMs with
    | .ok entry =>
      let nowMs ← IO.monoMsNow
      let tmoNat := if totalTimeoutMs == 0 then 65000 else totalTimeoutMs.toNat
      let prom ← IO.Promise.new
      let preq : PendingRequest := {
        priority := priority
        method := method
        authority := authority
        path := path
        headers := headers
        body := body
        maxRespBytes := maxRespBytes
        deadlineMs := nowMs + tmoNat
        enqueuedMs := nowMs
        promise := prom
      }
      let accepted ← entry.shared.atomically do
        let st ← get
        if st.closed then
          return false
        set { st with queue := st.queue.push preq }
        return true
      if !accepted then
        if attempt >= 2 then
          return .error s!"HTTP/2 connection to {host}:{port} closed before enqueue"
      else
        match prom.result!.get with
        | .ok resp rttMs reused =>
          let pingRtt ← entry.shared.atomically do return (← get).lastPingRttMs
          let effRtt := if pingRtt > 0 && pingRtt < rttMs then pingRtt else rttMs
          return .ok { response := resp, rttMs := effRtt, reusedConn := reused }
        | .retryUnprocessed reason =>
          if attempt >= 2 then
            return .error reason
        | .error msg =>
          return .error msg
    | .fallbackH1 =>
      let t0 ← IO.monoMsNow
      match ← httpsRequest method host port path headers body maxRespBytes verifyPeer totalTimeoutMs with
      | .ok resp =>
        let t1 ← IO.monoMsNow
        let dur := (Nat.min (Nat.max 1 (t1 - t0)) 60000).toUInt32
        return .ok { response := resp, rttMs := dur, reusedConn := false }
      | .error e =>
        return .error e
    | .failed errMsg =>
      return .error errMsg
  return .error s!"HTTP/2 pool exhausted retries for {host}:{port}"

end OrbNetLeaf.H2Pool
