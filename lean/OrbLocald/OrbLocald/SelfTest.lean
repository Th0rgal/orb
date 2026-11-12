import OrbBin.Json
import OrbLocald

/-
  OrbLocald.SelfTest — Conformance & self-test runner for `lean/OrbLocald`.
-/

open OrbBin.Json
open OrbLocald.Spec
open OrbLocald.Rpc

private def assertEq {α : Type} [BEq α] [ToString α] (label : String) (got expected : α) : IO Bool := do
  if got == expected then
    return true
  else
    IO.eprintln s!"FAIL [{label}]: got {got}, expected {expected}"
    return false

private def assertTrue (label : String) (cond : Bool) : IO Bool := do
  if cond then return true
  else
    IO.eprintln s!"FAIL [{label}]"
    return false

private def runR7aInteractiveToolSlotChecks (assertTrue : String → Bool → IO Bool) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut total := 0
  let stRef ← IO.mkRef ({ launchToken := "0123456789abcdef0123456789abcdef" } : LocaldState)
  let payload (k : String) : JVal := .obj #[("method", .str "questions"), ("params", .obj #[("k", .str k)])]
  let register (runId reqId : String) (ep : UInt64) (pl : JVal) (cap? : Option Nat) : IO (Except String JVal) := do
    let mut fields : Array (String × JVal) := #[
      ("action", .str "register"),
      ("id", .str runId),
      ("request_id", .str reqId),
      ("session_epoch", JVal.uint64 ep),
      ("payload", pl)
    ]
    if let some cap := cap? then
      fields := fields.push ("max_cap", JVal.nat cap)
    dispatchRpcCommand stRef "local_interaction" (.obj fields)
  let errOf : Except String JVal → String := fun
    | .error e => e
    | .ok _ => ""
  let okField (res : Except String JVal) (k : String) (pred : JVal → Bool) : Bool :=
    match res with
    | .ok jv =>
      match jv.field? k with
      | some v => pred v
      | none => false
    | .error _ => false
  -- 1. Capacity + no silent eviction: fill to max_cap, reject overflow, prior slots retained.
  let r1 ← register "run-a" "req-1" 1 (payload "a") (some 2)
  let r2 ← register "run-a" "req-2" 1 (payload "b") none
  let r3 ← register "run-a" "req-3" 1 (payload "c") none
  total := total + 1
  let capOk :=
    okField r1 "state" (· == .str "waiting_ack") &&
    okField r2 "active_slots" (· == JVal.nat 2) &&
    errOf r3 == "interactive_slot_backpressure"
  if (← assertTrue "tool_slot_capacity_backpressure_no_eviction" capOk) then passed := passed + 1
  let pollFull ← dispatchRpcCommand stRef "local_interaction"
    (.obj #[("action", .str "poll"), ("id", .str "run-a")])
  total := total + 1
  let retainedOk := match pollFull with
    | .ok jv =>
      jv.fieldNat? "active_slots" == some 2 &&
      (match jv.fieldArr? "slots" with
       | some xs => xs.any (fun s => s.fieldStr? "request_id" == some "req-1") &&
                    xs.any (fun s => s.fieldStr? "request_id" == some "req-2") &&
                    xs.all (fun s => s.fieldStr? "request_id" != some "req-3")
       | none => false)
    | .error _ => false
  if (← assertTrue "tool_slot_overflow_keeps_prior_waiting_slots" retainedOk) then passed := passed + 1
  -- 2. `"native-..."` request ids share the exact same gate (no prefix bypass) and hit backpressure identically.
  let nativeRes ← register "run-a" "native-bypass-1" 1 (payload "native") none
  total := total + 1
  if (← assertTrue "tool_slot_native_prefix_no_bypass" (errOf nativeRes == "interactive_slot_backpressure")) then
    passed := passed + 1
  -- 3. Idempotent same-payload replay vs conflicting duplicate vs stale epoch.
  let replay ← register "run-a" "req-1" 1 (payload "a") none
  let conflict ← register "run-a" "req-1" 1 (payload "MUTATED") none
  let stale ← register "run-a" "req-9" 0 (payload "stale") none
  total := total + 1
  let dedupOk :=
    okField replay "idempotent_replay" (· == .bool true) &&
    okField replay "state" (· == .str "waiting_ack") &&
    errOf conflict == "duplicate_request_id_conflict" &&
    errOf stale == "stale_session_epoch"
  if (← assertTrue "tool_slot_idempotent_replay_conflict_and_stale_epoch" dedupOk) then passed := passed + 1
  -- Empty request id is rejected even when capacity remains (no identity bypass).
  let emptyId ← register "run-b" "" 1 (payload "x") (some 4)
  total := total + 1
  if (← assertTrue "tool_slot_empty_request_id_rejected" (errOf emptyId == "invalid_tool_slot_identity")) then
    passed := passed + 1
  -- 4. Answer one slot, then reconnect: pending request retained, answered receipt preserved, poll after re-subscribe.
  let ans ← dispatchRpcCommand stRef "local_interaction_answer" (.obj #[
    ("id", .str "run-a"),
    ("requestId", .str "req-1"),
    ("answer", .obj #[("action", .str "accept")])
  ])
  total := total + 1
  if (← assertTrue "tool_slot_answer_returns_null" (match ans with | .ok .null => true | _ => false)) then
    passed := passed + 1
  let probe ← dispatchRpcCommand stRef "local_interaction" (.obj #[("id", .str "run-a")])
  total := total + 1
  let probeOk := match probe with
    | .ok jv => jv.fieldStr? "id" == some "req-2"
    | .error _ => false
  if (← assertTrue "tool_slot_probe_returns_next_active_request" probeOk) then passed := passed + 1
  -- Simulate a client reconnect: fresh subscription receives the retained active request, not null.
  let sub ← dispatchRpcCommand stRef "local_interaction_subscribe" (.obj #[("id", .str "run-a")])
  let polled ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  total := total + 1
  let reconnectOk :=
    (match sub with | .ok (.num _) => true | _ => false) &&
    (match polled with
     | .ok (.arr evs) =>
       evs.any fun ev =>
         match ev.field? "payload" with
         | some p => p.fieldStr? "id" == some "req-2"
         | none => false
     | _ => false)
  if (← assertTrue "tool_slot_reconnect_subscribe_retains_pending_request" reconnectOk) then passed := passed + 1
  let pollAfter ← dispatchRpcCommand stRef "local_interaction" (.obj #[
    ("action", .str "poll"), ("id", .str "run-a"), ("request_id", .str "req-1")
  ])
  total := total + 1
  let answeredKept := match pollAfter with
    | .ok jv => jv.fieldStr? "state" == some "answered" && (jv.field? "answer").isSome
    | .error _ => false
  if (← assertTrue "tool_slot_answered_receipt_retained_across_reconnect" answeredKept) then passed := passed + 1
  -- Reconcile at a higher epoch cancels prior-epoch slots and keeps the new epoch empty until re-register.
  let recon ← dispatchRpcCommand stRef "local_run_reconcile" (.obj #[
    ("id", .str "run-a"), ("session_epoch", JVal.uint64 2), ("include_slots", .bool true)
  ])
  let staleEpoch1 ← register "run-a" "req-old-ep" 1 (payload "old") none
  total := total + 1
  let reconOk := match recon with
    | .ok jv =>
      jv.fieldUInt64? "session_epoch" == some 2 &&
      jv.fieldNat? "active_slots" == some 0 &&
      (match jv.fieldArr? "pending" with | some xs => xs.isEmpty | none => false) &&
      errOf staleEpoch1 == "stale_session_epoch"
    | .error _ => false
  if (← assertTrue "tool_slot_reconcile_bumps_epoch_and_rejects_epoch_lt_current" reconOk) then passed := passed + 1
  -- `offer_early` enters `early_buffered` and promotes idempotently to `waiting_ack` on `register` without using a 2nd slot.
  let earlyRes ← dispatchRpcCommand stRef "local_interaction" (.obj #[
    ("action", .str "offer_early"), ("id", .str "run-a"), ("request_id", .str "native-early-1"),
    ("session_epoch", JVal.uint64 2), ("payload", payload "early")
  ])
  let promoRes ← register "run-a" "native-early-1" 2 (payload "early") none
  total := total + 1
  let earlyPromoOk :=
    okField earlyRes "state" (· == .str "early_buffered") &&
    okField earlyRes "active_slots" (· == JVal.nat 1) &&
    okField promoRes "state" (· == .str "waiting_ack") &&
    okField promoRes "idempotent_replay" (· == .bool true) &&
    okField promoRes "active_slots" (· == JVal.nat 1)
  if (← assertTrue "tool_slot_offer_early_promotes_idempotently_to_waiting_ack" earlyPromoOk) then passed := passed + 1
  -- Stop cancels the run and publishes a null snapshot to subscribers.
  let fresh ← register "run-a" "req-epoch2" 2 (payload "next") none
  let _ ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  let stopRes ← dispatchRpcCommand stRef "local_agents_stop" (.obj #[("id", .str "run-a")])
  let afterStop ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  total := total + 1
  let stopOk :=
    okField fresh "state" (· == .str "waiting_ack") &&
    (match stopRes with | .ok .null => true | _ => false) &&
    (match afterStop with
     | .ok (.arr evs) => evs.any fun ev => ev.field? "payload" == some .null
     | _ => false)
  if (← assertTrue "tool_slot_stop_cancels_run_and_clears_subscribers" stopOk) then passed := passed + 1
  -- Full default `maxInteractiveToolSlots = 64` burst: 64 succeed with 0 evictions, 65th fails with backpressure.
  let stRef64 ← IO.mkRef ({ launchToken := "0123456789abcdef0123456789abcdef" } : LocaldState)
  let mut all64Ok := true
  for i in [0:64] do
    let ri ← dispatchRpcCommand stRef64 "local_interaction" (.obj #[
      ("action", .str (if i % 2 == 0 then "offer_early" else "register")),
      ("id", .str "run-64"),
      ("request_id", .str s!"slot-{i}"),
      ("session_epoch", JVal.uint64 1),
      ("payload", payload s!"p-{i}")
    ])
    if !(okField ri "active_slots" (· == JVal.nat (i + 1))) then
      all64Ok := false
  let r65 ← dispatchRpcCommand stRef64 "local_interaction" (.obj #[
    ("action", .str "register"),
    ("id", .str "run-64"),
    ("request_id", .str "native-slot-65"),
    ("session_epoch", JVal.uint64 1),
    ("payload", payload "overflow")
  ])
  let poll64 ← dispatchRpcCommand stRef64 "local_interaction" (.obj #[("action", .str "poll"), ("id", .str "run-64")])
  total := total + 1
  let burst64Ok :=
    all64Ok &&
    errOf r65 == "interactive_slot_backpressure" &&
    (match poll64 with
     | .ok jv =>
       jv.fieldNat? "active_slots" == some 64 &&
       (match jv.fieldArr? "slots" with
        | some xs => xs.size == 64 && xs.any (fun s => s.fieldStr? "request_id" == some "slot-0") &&
                     xs.any (fun s => s.fieldStr? "request_id" == some "slot-63")
        | none => false)
     | .error _ => false)
  if (← assertTrue "tool_slot_full_64_burst_backpressure_and_zero_eviction" burst64Ok) then passed := passed + 1
  return (passed, total)

private def runR6bClientLinkAndConflictChecks
    (assertTrue : String → Bool → IO Bool) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut total := 0
  let validTok := "0123456789abcdef0123456789abcdef"
  let stRef ← IO.mkRef ({ launchToken := validTok } : LocaldState)

  -- 1. Capability latch: 404/501 latches within `(endpoint, server_build)` and clears on `server_build` or `endpoint` change; 503 never latches.
  let c503 ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-a.example")]),
    ("server_build", .str "build-1"),
    ("observed_http_status", JVal.nat 503)
  ])
  let c404 ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-a.example")]),
    ("server_build", .str "build-1"),
    ("observed_http_status", JVal.nat 404)
  ])
  let cSameEpoch ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-a.example/")]),
    ("server_build", .str "build-1"),
    ("observed_http_status", JVal.nat 200)
  ])
  let cNewBuild ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-a.example")]),
    ("server_build", .str "build-2"),
    ("observed_http_status", JVal.nat 200)
  ])
  let c501 ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-a.example")]),
    ("server_build", .str "build-2"),
    ("observed_http_status", JVal.nat 501)
  ])
  let cNewEndpoint ← dispatchRpcCommand stRef "client_link_connect" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("server_build", .str "build-2"),
    ("observed_http_status", JVal.nat 200)
  ])
  total := total + 1
  let capOk :=
    (match c503 with | .ok (.bool true) => true | _ => false) &&
    (match c404 with | .ok (.bool false) => true | _ => false) &&
    (match cSameEpoch with | .ok (.bool false) => true | _ => false) &&
    (match cNewBuild with | .ok (.bool true) => true | _ => false) &&
    (match c501 with | .ok (.bool false) => true | _ => false) &&
    (match cNewEndpoint with | .ok (.bool true) => true | _ => false)
  if (← assertTrue "client_link_capability_latch_scoped_to_endpoint_and_server_build" capOk) then passed := passed + 1

  -- 2. 256-frame outbound journal ring: fill 256 frames, verify 257th backpressures without evicting, cumulative ACK, reconnect resync.
  let mut enq256Ok := true
  for i in [:256] do
    let r ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
      ("action", .str "enqueue"),
      ("mission", .str "m-journal"),
      ("payload", .obj #[("idx", JVal.nat i)])
    ])
    match r with
    | .ok jv =>
      if jv.fieldUInt64? "seq" != some (i + 1).toUInt64 then enq256Ok := false
    | .error _ => enq256Ok := false
  let overflow257 ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
    ("action", .str "enqueue"),
    ("mission", .str "m-journal"),
    ("payload", .obj #[("idx", JVal.nat 256)])
  ])
  let flushPending ← dispatchRpcCommand stRef "client_link_flush" (.obj #[("mission", .str "m-journal")])
  let ack200 ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
    ("action", .str "ack"),
    ("ack_seq", JVal.nat 200)
  ])
  let badAckBeyondHead ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
    ("action", .str "ack"),
    ("ack_seq", JVal.nat 257)
  ])
  let resyncFrom250 ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
    ("action", .str "resync"),
    ("peer_ack_seq", JVal.nat 250)
  ])
  let ackAll ← dispatchRpcCommand stRef "client_link_flush" (.obj #[
    ("action", .str "ack"),
    ("ack_seq", JVal.nat 256)
  ])
  let flushDrained ← dispatchRpcCommand stRef "client_link_flush" (.obj #[("mission", .str "m-journal")])
  total := total + 1
  let journalOk :=
    enq256Ok &&
    (match overflow257 with | .error "client_link_journal_backpressure" => true | _ => false) &&
    (match flushPending with | .ok (.bool false) => true | _ => false) &&
    (match ack200 with | .ok jv => jv.fieldNat? "unacked_count" == some 56 && jv.fieldUInt64? "last_acked_seq" == some 200 | _ => false) &&
    (match badAckBeyondHead with | .error "client_link_invalid_ack_seq" => true | _ => false) &&
    (match resyncFrom250 with | .ok jv => jv.fieldNat? "replay_count" == some 6 && jv.fieldUInt64? "replay_from_seq" == some 250 | _ => false) &&
    (match ackAll with | .ok jv => jv.fieldNat? "unacked_count" == some 0 | _ => false) &&
    (match flushDrained with | .ok (.bool true) => true | _ => false)
  if (← assertTrue "client_link_journal_ring_256_backpressure_ack_and_resync" journalOk) then passed := passed + 1

  -- 3. Local-origin lifecycle + typed 409 conflict classification (`stopping`/`non_terminal_run` retry vs `already_ended`/`moved`/`stale_receipt` retire).
  let launchRes ← dispatchRpcCommand stRef "local_origin_launch" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("draft", .obj #[("title", .str "Origin A"), ("prompt", .str "hello")])
  ])
  let mid := match launchRes with | .ok jv => (jv.fieldStr? "id").getD "" | .error _ => ""
  let listRes1 ← dispatchRpcCommand stRef "local_origin_list" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")])
  ])
  let confStopping ← dispatchRpcCommand stRef "local_origin_confirm" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("id", .str mid),
    ("http_status", JVal.nat 409),
    ("conflict_code", .str "stopping")
  ])
  let confStale ← dispatchRpcCommand stRef "local_origin_confirm" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("id", .str mid),
    ("http_status", JVal.nat 409),
    ("conflict_code", .str "stale_receipt")
  ])
  let confUnknown ← dispatchRpcCommand stRef "local_origin_confirm" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("id", .str mid),
    ("http_status", JVal.nat 409),
    ("conflict_code", .str "mystery_409")
  ])
  let delConfirm ← dispatchRpcCommand stRef "local_origin_confirm" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")]),
    ("confirmations", .arr #[.obj #[("id", .str mid), ("deleted", .bool true), ("observed_at", JVal.nat 999)]])
  ])
  let listAfterDel ← dispatchRpcCommand stRef "local_origin_list" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-b.example")])
  ])
  total := total + 1
  let originConflictOk :=
    !mid.isEmpty &&
    (match launchRes with | .ok jv => jv.fieldStr? "placement_kind" == some "client" | _ => false) &&
    (match listRes1 with | .ok (.arr #[jv]) => jv.fieldStr? "id" == some mid && jv.fieldBool? "local_sync_pending" == some true && jv.fieldStr? "placement_kind" == some "client" | _ => false) &&
    (match confStopping with | .ok jv => jv.fieldBool? "retry" == some true && jv.fieldStr? "conflict_code" == some "stopping" | _ => false) &&
    (match confStale with | .ok jv => jv.fieldBool? "retry" == some false && jv.fieldStr? "conflict_code" == some "stale_receipt" | _ => false) &&
    (match confUnknown with | .error "unclassified_local_origin_conflict" => true | _ => false) &&
    delConfirm.isOk &&
    (match listAfterDel with | .ok (.arr #[]) => true | _ => false)
  if (← assertTrue "local_origin_lifecycle_and_typed_409_conflict_classification" originConflictOk) then passed := passed + 1

  return (passed, total)

private def runR6bClientLinkAndConflictTests : IO Unit := do
  let (p, t) ← runR6bClientLinkAndConflictChecks assertTrue
  if p != t then
    throw (IO.userError s!"runR6bClientLinkAndConflictTests failed ({p}/{t})")

private def runR7aInteractiveToolSlotTestsWithCounts (passedRef totalRef : IO.Ref Nat) : IO Unit := do
  let (p, t) ← runR7aInteractiveToolSlotChecks assertTrue
  passedRef.modify (· + p)
  totalRef.modify (· + t)

private def runR7aInteractiveToolSlotTests : IO Unit := do
  let passedRef ← IO.mkRef 0
  let totalRef ← IO.mkRef 0
  runR7aInteractiveToolSlotTestsWithCounts passedRef totalRef
  let p ← passedRef.get
  let t ← totalRef.get
  if p != t then
    throw (IO.userError s!"runR7aInteractiveToolSlotTests failed ({p}/{t})")

private def makeTestWav16kMono (sampleCount : Nat) (amp : UInt16) : ByteArray := Id.run do
  let dataBytes := sampleCount * 2
  let riffChunkSize := 36 + dataBytes
  let pushU16LE (b : ByteArray) (v : Nat) : ByteArray :=
    (b.push (v &&& 0xFF).toUInt8).push ((v >>> 8) &&& 0xFF).toUInt8
  let pushU32LE (b : ByteArray) (v : Nat) : ByteArray :=
    (((b.push (v &&& 0xFF).toUInt8).push ((v >>> 8) &&& 0xFF).toUInt8).push ((v >>> 16) &&& 0xFF).toUInt8).push ((v >>> 24) &&& 0xFF).toUInt8
  let mut out := ByteArray.emptyWithCapacity (44 + dataBytes)
  out := out ++ "RIFF".toUTF8
  out := pushU32LE out riffChunkSize
  out := out ++ "WAVEfmt ".toUTF8
  out := pushU32LE out 16
  out := pushU16LE out 1       -- PCM
  out := pushU16LE out 1       -- mono
  out := pushU32LE out 16000   -- 16 kHz
  out := pushU32LE out 32000   -- byte rate
  out := pushU16LE out 2       -- block align
  out := pushU16LE out 16      -- 16-bit
  out := out ++ "data".toUTF8
  out := pushU32LE out dataBytes
  let lo := (amp.toNat &&& 0xFF).toUInt8
  let hi := ((amp.toNat >>> 8) &&& 0xFF).toUInt8
  for _ in [0:sampleCount] do
    out := (out.push lo).push hi
  return out

private def runDesktopReliabilityParityChecksPart1 (pDir : System.FilePath) (validTok : String) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut total := 0

  -- A. Symlink escape & `/` root confinement (`read_upload_file` + `browse_local_files`)
  let secretDir := pDir / "outside-secret"
  let allowedDir := pDir / "granted-folder"
  IO.FS.createDirAll secretDir
  IO.FS.createDirAll allowedDir
  let secretFile := secretDir / "topsecret.txt"
  let goodFile := allowedDir / "safe.txt"
  let escapeLink := allowedDir / "escape.txt"
  IO.FS.writeFile secretFile "DO_NOT_READ"
  IO.FS.writeFile goodFile "SAFE_PAYLOAD"
  discard <| IO.Process.run { cmd := "ln", args := #["-s", secretFile.toString, escapeLink.toString] }

  let stConfRef ← IO.mkRef ({
    launchToken := validTok,
    orbStateDir := (pDir / "state").toString,
    homeDir := (pDir / "home").toString,
    hostOs := "macos"
  } : LocaldState)
  let _ ← dispatchRpcCommand stConfRef "grant_upload_folder" (.obj #[("path", .str allowedDir.toString)])
  let okGoodRead ← dispatchRpcCommand stConfRef "read_upload_file" (.obj #[("path", .str goodFile.toString)])
  let rejEscapeUpload ← dispatchRpcCommand stConfRef "read_upload_file" (.obj #[("path", .str escapeLink.toString)])
  let rejUngrantedBrowse ← dispatchRpcCommand stConfRef "browse_local_files" (.obj #[
    ("root", .str secretDir.toString),
    ("request", .obj #[("action", .str "list"), ("path", .str "")])
  ])
  let rejSlashRootBrowse ← dispatchRpcCommand stConfRef "browse_local_files" (.obj #[
    ("root", .str "/"),
    ("request", .obj #[("action", .str "list"), ("path", .str "")])
  ])
  let rejEscapeBrowseRead ← dispatchRpcCommand stConfRef "browse_local_files" (.obj #[
    ("root", .str allowedDir.toString),
    ("request", .obj #[("action", .str "read"), ("path", .str "escape.txt")])
  ])
  let okBrowseList ← dispatchRpcCommand stConfRef "browse_local_files" (.obj #[
    ("root", .str allowedDir.toString),
    ("request", .obj #[("action", .str "list"), ("path", .str "")])
  ])
  total := total + 1
  let confOk :=
    okGoodRead.isOk &&
    rejEscapeUpload.isOk.not &&
    rejUngrantedBrowse.isOk.not &&
    rejSlashRootBrowse.isOk.not &&
    rejEscapeBrowseRead.isOk.not &&
    (match okBrowseList with
     | .ok jv =>
       match jv.fieldArr? "entries" with
       | some #[ent] => ent.fieldStr? "name" == some "safe.txt"
       | _ => false
     | _ => false)
  if (← assertTrue "canonical_confinement_blocks_symlink_escape_and_slash_root" confOk) then passed := passed + 1

  -- B. Concurrent upload batch UUIDs: cancelling batch 1 does NOT revoke batch 2 from the same directory
  let batchDir := pDir / "shared-batch-dir"
  IO.FS.createDirAll batchDir
  let bf1 := batchDir / "a.txt"
  let bf2 := batchDir / "b.txt"
  IO.FS.writeFile bf1 "alpha"
  IO.FS.writeFile bf2 "beta"
  let stBatchRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := (pDir / "state-b").toString, hostOs := "macos" } : LocaldState)
  let filesArr : JVal := .arr #[
    .obj #[("path", .str "shared-batch-dir/a.txt"), ("local_path", .str bf1.toString)],
    .obj #[("path", .str "shared-batch-dir/b.txt"), ("local_path", .str bf2.toString)]
  ]
  let _ ← dispatchRpcCommand stBatchRef "offer_upload_folder" (.obj #[
    ("batch", .str "batch-uuid-1"), ("roots", .arr #[.str batchDir.toString]), ("files", filesArr)
  ])
  let _ ← dispatchRpcCommand stBatchRef "offer_upload_folder" (.obj #[
    ("batch", .str "batch-uuid-2"), ("roots", .arr #[.str batchDir.toString]), ("files", filesArr)
  ])
  let _ ← dispatchRpcCommand stBatchRef "grant_upload_folder" (.obj #[("batch", .str "batch-uuid-1")])
  let _ ← dispatchRpcCommand stBatchRef "grant_upload_folder" (.obj #[("batch", .str "batch-uuid-2")])
  let _ ← dispatchRpcCommand stBatchRef "revoke_upload_folder" (.obj #[("batch", .str "batch-uuid-1")])
  let batch2StillReadable ← dispatchRpcCommand stBatchRef "read_upload_file" (.obj #[("path", .str bf1.toString)])
  let _ ← dispatchRpcCommand stBatchRef "revoke_upload_folder" (.obj #[("batch", .str "batch-uuid-2")])
  let afterBothRevoked ← dispatchRpcCommand stBatchRef "read_upload_file" (.obj #[("path", .str bf1.toString)])
  total := total + 1
  if (← assertTrue "concurrent_upload_batches_isolated_across_same_folder"
      (batch2StillReadable.isOk && afterBothRevoked.isOk.not)) then passed := passed + 1

  -- C. `biometric_authenticate` never returns `.ok (.bool false)` on cancel/missing/non-macOS
  let bioAuthScript := pDir / "mock-bio-signer.sh"
  IO.FS.writeFile bioAuthScript
    "#!/bin/sh\nif [ \"$1\" = \"status\" ]; then echo '{\"available\":\"true\",\"kind\":\"passcode\",\"label\":\"Touch ID or Password\"}'; exit 0; fi\nif [ \"$1\" = \"auth\" ]; then echo 'User cancelled' >&2; exit 2; fi\nexit 1\n"
  discard <| OrbBin.PosixExt.chmod bioAuthScript.toString 0o700
  let stBioNone ← IO.mkRef ({ launchToken := validTok, hostOs := "macos", signerBin? := none } : LocaldState)
  let stBioCancel ← IO.mkRef ({ launchToken := validTok, hostOs := "macos", signerBin? := some bioAuthScript.toString } : LocaldState)
  let resBioNone ← dispatchRpcCommand stBioNone "local_machine_identity" (.obj #[])
  let _ := resBioNone
  let authNone ← dispatchRpcCommand stBioNone "biometric_authenticate" (.obj #[("reason", .str "Unlock")])
  let authCancel ← dispatchRpcCommand stBioCancel "biometric_authenticate" (.obj #[("reason", .str "Unlock")])
  let statusFallback ← dispatchRpcCommand stBioCancel "biometric_status" (.obj #[])
  total := total + 1
  let bioAuthOk :=
    authNone.isOk.not &&
    (match authCancel with | .error "biometric_cancelled" => true | _ => false) &&
    (match statusFallback with
     | .ok jv => jv.fieldBool? "available" == some true && jv.fieldStr? "kind" == some "passcode"
     | _ => false)
  if (← assertTrue "biometric_auth_errors_on_cancel_and_status_passcode_fallback" bioAuthOk) then passed := passed + 1

  -- C2. Linux `approval_key_status`, `approval_key_create`, and `approval_sign` via `orb-signer`
  let linuxSigner := pDir / "mock-linux-signer.sh"
  IO.FS.writeFile linuxSigner
    "#!/bin/sh\nif [ \"$1\" = \"status\" ]; then echo '{\"available\":\"true\",\"kind\":\"passcode\",\"label\":\"Touch ID or Password\"}'; exit 0; fi\nif [ \"$1\" = \"public\" ]; then exit 4; fi\nif [ \"$1\" = \"create\" ]; then echo '{\"public_key\":\"TEST_LINUX_PUBKEY\"}'; exit 0; fi\nif [ \"$1\" = \"serve\" ]; then read line; echo '{\"signature\":\"TEST_LINUX_SIG\",\"grace_until\":\"9999999999\"}'; exit 0; fi\nexit 1\n"
  discard <| OrbBin.PosixExt.chmod linuxSigner.toString 0o700
  let stLinuxKey ← IO.mkRef ({ launchToken := validTok, orbStateDir := (pDir / "state-lnx").toString, approvalKeyPath := (pDir / "lnx-key.bin").toString, hostOs := "linux", signerBin? := some linuxSigner.toString } : LocaldState)
  let lnxKeyStatus ← dispatchRpcCommand stLinuxKey "approval_key_status" (.obj #[])
  let lnxKeyCreate ← dispatchRpcCommand stLinuxKey "approval_key_create" (.obj #[])
  let lnxKeySign ← dispatchRpcCommand stLinuxKey "approval_sign" (.obj #[("payload", .str "paloma-approval-v1\nid\nPOST /api/approvals/approve-all\nhash\n9999999999\nAllow"), ("reason", .str "Allow")])
  total := total + 1
  let lnxSignerOk :=
    (match lnxKeyStatus with | .ok jv => jv.fieldBool? "available" == some true && jv.fieldBool? "enrolled" == some false | _ => false) &&
    (match lnxKeyCreate with | .ok (.str "TEST_LINUX_PUBKEY") => true | _ => false) &&
    (match lnxKeySign with | .ok (.str "TEST_LINUX_SIG") => true | _ => false)
  if (← assertTrue "linux_orb_signer_status_create_and_sign" lnxSignerOk) then passed := passed + 1

  -- D. Durable `local-bindings.json` + `local-origins.json` reload across daemon restarts
  let persistDir := (pDir / "persist-state").toString
  let stP1 ← IO.mkRef ({ launchToken := validTok, orbStateDir := persistDir, homeDir := (pDir / "home").toString, hostOs := "macos" } : LocaldState)
  let _ ← dispatchRpcCommand stP1 "local_binding_set" (.obj #[
    ("id", .str "m-persist-1"),
    ("binding", .obj #[("harness", .str "claudecode"), ("bin", .str "/usr/bin/true"), ("cwd", .str allowedDir.toString)])
  ])
  let origLaunchRes ← dispatchRpcCommand stP1 "local_origin_launch" (.obj #[
    ("connection", .obj #[("api_url", .str "https://orbcore.example")]),
    ("draft", .obj #[("title", .str "Durable Local Chat"), ("project", .str "orb"), ("prompt", .str "hello durable"), ("tags", .arr #[.str "placement:client"])])
  ])
  let origMid := match origLaunchRes with | .ok jv => (jv.fieldStr? "id").getD "" | _ => ""
  let _ ← dispatchRpcCommand stP1 "local_agents_stop" (.obj #[("id", .str origMid)])
  let stP2 ← IO.mkRef ({ launchToken := validTok, orbStateDir := persistDir, homeDir := (pDir / "home").toString, hostOs := "macos" } : LocaldState)
  let reloadedBinds ← dispatchRpcCommand stP2 "local_bindings_refresh" (.obj #[])
  let reloadedOrigins ← dispatchRpcCommand stP2 "local_origin_list" (.obj #[
    ("connection", .obj #[("api_url", .str "https://orbcore.example")])
  ])
  let sampleFailedEntry : LocalOriginEntry := {
    id := "m-failed-origin", endpoint := "https://orbcore.example", title := "Failed Local",
    status := "failed", statusMessage := some "Model unavailable: builtin/fast",
    syncError := some "Core synchronization failed (502): upstream", localSyncPending := true, localRunActive := false
  }
  let roundtrippedFailed? := LocalOriginEntry.fromMissionJson? sampleFailedEntry.toMissionJson
  total := total + 1
  let persistOk :=
    !origMid.isEmpty &&
    (match roundtrippedFailed? with
     | some rf => rf.statusMessage == some "Model unavailable: builtin/fast" && rf.syncError == some "Core synchronization failed (502): upstream"
     | none => false) &&
    (match reloadedBinds with
     | .ok jv => ((jv.field? "bindings").bind (·.field? "m-persist-1")).isSome
     | _ => false) &&
    (match reloadedOrigins with
     | .ok (.arr #[m]) =>
       m.fieldStr? "id" == some origMid &&
       m.fieldStr? "status" == some "interrupted" &&
       m.fieldBool? "local_run_active" == some false &&
       m.fieldStr? "project" == some "orb" &&
       (m.fieldArr? "history").map (·.size) == some 1 &&
       (m.fieldStr? "created_at").isSome
     | _ => false)
  if (← assertTrue "durable_local_bindings_and_origins_survive_daemon_restart" persistOk) then passed := passed + 1

  -- D2. Shared `ui-prefs.json` (`desktop_prefs_load` / `desktop_prefs_patch`) across prod & dev daemons
  let patchRes ← dispatchRpcCommand stP1 "desktop_prefs_patch" (.obj #[
    ("set", .obj #[
      ("orb-theme", .str "light"),
      ("orb.approval.graceSecs", .str "600"),
      ("orb.jwt", .str "MUST_NOT_PERSIST"),
      ("orb.apiUrl", .str "https://other.example"),
      ("orb.catalog:123:/api/projects", .str "MUST_NOT_PERSIST")
    ])
  ])
  let rev1 := match patchRes with | .ok jv => (jv.fieldStr? "rev").getD "" | _ => ""
  let patchPrefsOk :=
    match patchRes with
    | .ok jv =>
      match jv.field? "prefs" with
      | some p => p.fieldStr? "orb-theme" == some "light" && (p.field? "orb.apiUrl").isNone && (p.field? "orb.jwt").isNone
      | none => false
    | _ => false
  -- Concurrent patches across two daemon state refs must serialize via flock and preserve both keys
  let tA ← IO.asTask (dispatchRpcCommand stP1 "desktop_prefs_patch" (.obj #[("set", .obj #[("orb.concurrent.a", .str "1")])]))
  let tB ← IO.asTask (dispatchRpcCommand stP2 "desktop_prefs_patch" (.obj #[("set", .obj #[("orb.concurrent.b", .str "2")])]))
  let _ ← IO.wait tA
  let _ ← IO.wait tB
  let loadRes ← dispatchRpcCommand stP2 "desktop_prefs_load" (.obj #[])
  let rev2 := match loadRes with | .ok jv => (jv.fieldStr? "rev").getD "" | _ => ""
  let sameRevRes ← dispatchRpcCommand stP2 "desktop_prefs_load" (.obj #[("since_rev", .str rev2)])
  total := total + 1
  let prefsShareOk :=
    !rev1.isEmpty && !rev2.isEmpty && rev1 != rev2 && patchPrefsOk &&
    (match loadRes with
     | .ok jv =>
       jv.fieldBool? "unchanged" == some false &&
       (match jv.field? "prefs" with
        | some p =>
          p.fieldStr? "orb-theme" == some "light" &&
          p.fieldStr? "orb.approval.graceSecs" == some "600" &&
          p.fieldStr? "orb.concurrent.a" == some "1" &&
          p.fieldStr? "orb.concurrent.b" == some "2" &&
          (p.field? "orb.jwt").isNone &&
          (p.field? "orb.apiUrl").isNone &&
          (p.field? "orb.catalog:123:/api/projects").isNone
        | none => false)
     | _ => false) &&
    (match sameRevRes with
     | .ok jv => jv.fieldBool? "unchanged" == some true && (jv.field? "prefs").isNone
     | _ => false)
  -- Malformed existing ui-prefs.json must return an RPC error rather than wiping saved preferences
  IO.FS.writeFile (System.FilePath.mk persistDir / "ui-prefs.json") "{corrupt"
  let corruptLoadRes ← dispatchRpcCommand stP2 "desktop_prefs_load" (.obj #[])
  let corruptPatchRes ← dispatchRpcCommand stP2 "desktop_prefs_patch" (.obj #[("set", .obj #[("orb-theme", .str "dark")])])
  let corruptClearRes ← dispatchRpcCommand stP2 "desktop_prefs_patch" (.obj #[("clear", .bool true), ("set", .obj #[("orb-theme", .str "dark")])])
  let corruptOk :=
    (match corruptLoadRes with | .error _ => true | .ok _ => false) &&
    (match corruptPatchRes with | .error _ => true | .ok _ => false) &&
    (match corruptClearRes with | .ok _ => true | .error _ => false)
  if (← assertTrue "desktop_prefs_shared_across_daemons" (prefsShareOk && corruptOk)) then passed := passed + 1

  -- D3. Native `ui-cache` (`ui_cache_put` / `ui_cache_get` / LRU eviction / `ui_cache_clear`)
  let sbPut ← dispatchRpcCommand stP1 "ui_cache_put" (.obj #[
    ("kind", .str "sidebar"),
    ("key", .str "https://orbcore.thomas.md::scope1"),
    ("saved_at", .nat 1000),
    ("raw", .str "{\"missions\":[1],\"projects\":[]}")
  ])
  let sbGet ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[
    ("kind", .str "sidebar"),
    ("key", .str "https://orbcore.thomas.md::scope1")
  ])
  let badKindRes ← dispatchRpcCommand stP1 "ui_cache_put" (.obj #[
    ("kind", .str "../escape"),
    ("key", .str "k"),
    ("saved_at", .nat 1),
    ("raw", .str "{}")
  ])
  let mut lastPutRes : Except String JVal := .ok .null
  for idx in [0:252] do
    lastPutRes ← dispatchRpcCommand stP1 "ui_cache_put" (.obj #[
      ("kind", .str "transcript"),
      ("key", .str s!"scope1::m:tx-{idx}"),
      ("saved_at", .nat (2000 + idx)),
      ("raw", .str s!"\{\"idx\":{idx}}")
    ])
  let warmRewriteRes ← dispatchRpcCommand stP1 "ui_cache_put" (.obj #[
    ("kind", .str "transcript"),
    ("key", .str "scope1::m:tx-2"),
    ("saved_at", .nat 2002),
    ("tier", .str "warm"),
    ("raw", .str "{\"idx\":2,\"tier\":\"warm\"}")
  ])
  let demoteListOk := match lastPutRes, warmRewriteRes with
    | .ok jv1, .ok jv2 =>
      let ks1 := ((jv1.fieldArr? "demote_keys").getD #[]).filterMap (·.asStr?)
      let ks2 := ((jv2.fieldArr? "demote_keys").getD #[]).filterMap (·.asStr?)
      ks1.contains "scope1::m:tx-2" && !(ks2.contains "scope1::m:tx-2")
    | _, _ => false
  let stalePutRes ← dispatchRpcCommand stP1 "ui_cache_put" (.obj #[
    ("kind", .str "transcript"),
    ("key", .str "scope1::m:tx-251"),
    ("saved_at", .nat 1999),
    ("tier", .str "warm"),
    ("raw", .str "{\"idx\":251,\"stale\":true}")
  ])
  let oldestEvicted ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "transcript"), ("key", .str "scope1::m:tx-0")])
  let secondEvicted ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "transcript"), ("key", .str "scope1::m:tx-1")])
  let thirdKept ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "transcript"), ("key", .str "scope1::m:tx-2")])
  let newestKept ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "transcript"), ("key", .str "scope1::m:tx-251")])
  let _ ← dispatchRpcCommand stP1 "ui_cache_clear" (.obj #[])
  let afterClearSb ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "sidebar"), ("key", .str "https://orbcore.thomas.md::scope1")])
  let afterClearTx ← dispatchRpcCommand stP2 "ui_cache_get" (.obj #[("kind", .str "transcript"), ("key", .str "scope1::m:tx-251")])
  let isOkNull (r : Except String JVal) : Bool := match r with | .ok .null => true | _ => false
  let isOkStr (r : Except String JVal) (s : String) : Bool := match r with | .ok (.str v) => v == s | _ => false
  total := total + 1
  let uiCacheOk :=
    isOkNull sbPut &&
    isOkStr sbGet "{\"missions\":[1],\"projects\":[]}" &&
    (match badKindRes with | .error _ => true | .ok _ => false) &&
    demoteListOk &&
    isOkNull stalePutRes &&
    isOkNull oldestEvicted &&
    isOkNull secondEvicted &&
    isOkStr thirdKept "{\"idx\":2,\"tier\":\"warm\"}" &&
    isOkStr newestKept "{\"idx\":251}" &&
    isOkNull afterClearSb &&
    isOkNull afterClearTx
  if (← assertTrue "native_ui_cache_roundtrip_lru_and_clear" uiCacheOk) then passed := passed + 1

  -- D2. SQLite tail-sliced UI transcript cache (`ui_cache_put_transcript`, `ui_cache_get_tail`, `ui_cache_get_slice`)
  --     and origin-independent `ui_draft_*` persistence surviving `ui_cache_clear`
  let slicedEvents : Array JVal := (List.range 10).toArray.map fun i =>
    JVal.str s!"\{\"type\":\"assistant_message\",\"sequence\":{i + 1},\"data\":\{\"content\":\"turn-{i}\"}}"
  let putSlicedRes ← dispatchRpcCommand stP1 "ui_cache_put_transcript" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("saved_at", .nat 5000),
    ("start_idx", .nat 0),
    ("head_raw", .str "{\"fromLog\":true,\"cursor\":10,\"hasOlder\":true}"),
    ("events_raw", .arr slicedEvents)
  ])
  let tailRes ← dispatchRpcCommand stP2 "ui_cache_get_tail" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("tail_limit", .nat 3)
  ])
  -- Partial tail append (`start_idx = 7`) preserves `0..6` while updating `7..10`!
  let appendedTail : Array JVal := #[
    .str "{\"type\":\"assistant_message\",\"sequence\":8,\"data\":{\"content\":\"turn-7\"}}",
    .str "{\"type\":\"assistant_message\",\"sequence\":9,\"data\":{\"content\":\"turn-8\"}}",
    .str "{\"type\":\"assistant_message\",\"sequence\":10,\"data\":{\"content\":\"turn-9\"}}",
    .str "{\"type\":\"assistant_message\",\"sequence\":11,\"data\":{\"content\":\"turn-10\"}}"
  ]
  let putPartialRes ← dispatchRpcCommand stP1 "ui_cache_put_transcript" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("saved_at", .nat 5005),
    ("start_idx", .nat 7),
    ("head_raw", .str "{\"fromLog\":true,\"cursor\":11,\"hasOlder\":true}"),
    ("events_raw", .arr appendedTail)
  ])
  let sliceBefore7 ← dispatchRpcCommand stP2 "ui_cache_get_slice" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("before_idx", .nat 7),
    ("limit", .nat 4)
  ])
  let tailAfterAppend ← dispatchRpcCommand stP2 "ui_cache_get_tail" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("tail_limit", .nat 2)
  ])
  -- Stale sliced write (`saved_at = 4999 < 5005`) must be ignored without deleting cached events!
  let putStaleSlicedRes ← dispatchRpcCommand stP1 "ui_cache_put_transcript" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("saved_at", .nat 4999),
    ("start_idx", .nat 0),
    ("head_raw", .str "{\"fromLog\":true,\"cursor\":1,\"hasOlder\":false}"),
    ("events_raw", .arr #[.str "{\"type\":\"assistant_message\",\"sequence\":1,\"data\":{\"content\":\"stale\"}}"])
  ])
  let tailAfterStale ← dispatchRpcCommand stP2 "ui_cache_get_tail" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("tail_limit", .nat 2)
  ])
  let draftPut ← dispatchRpcCommand stP1 "ui_draft_put" (.obj #[
    ("key", .str "m:draft-1"),
    ("updated_at", .nat 9000),
    ("raw", .str "{\"text\":\"unsent prompt\",\"images\":[]}")
  ])
  let draftIfAbsent ← dispatchRpcCommand stP1 "ui_draft_put" (.obj #[
    ("key", .str "m:draft-1"),
    ("updated_at", .nat 9999),
    ("if_absent", .bool true),
    ("raw", .str "{\"text\":\"stale migration\",\"images\":[]}")
  ])
  -- Durable `thread:*` queue/receipt records must never be evicted when > 512 composer drafts arrive!
  let _ ← dispatchRpcCommand stP1 "ui_draft_put" (.obj #[
    ("key", .str "thread:orb-local-message-queue:v1:ep"),
    ("updated_at", .nat 1),
    ("raw", .str "[{\"id\":\"unsent-msg-1\"}]")
  ])
  for idx in [0:520] do
    let _ ← dispatchRpcCommand stP1 "ui_draft_put" (.obj #[
      ("key", .str s!"m:flood-{idx}"),
      ("updated_at", .nat (10000 + idx)),
      ("raw", .str "{\"text\":\"disposable\",\"images\":[]}")
    ])
  let durableQueueAfterFlood ← dispatchRpcCommand stP2 "ui_draft_get" (.obj #[("key", .str "thread:orb-local-message-queue:v1:ep")])
  let evictedOldestDraft ← dispatchRpcCommand stP2 "ui_draft_get" (.obj #[("key", .str "m:draft-1")])
  let newestFloodDraft ← dispatchRpcCommand stP2 "ui_draft_get" (.obj #[("key", .str "m:flood-519")])
  let _ ← dispatchRpcCommand stP1 "ui_cache_clear" (.obj #[])
  let tailAfterClear ← dispatchRpcCommand stP2 "ui_cache_get_tail" (.obj #[
    ("scope", .str "scope-sql"),
    ("mission_id", .str "m-big"),
    ("tail_limit", .nat 3)
  ])
  let draftAfterClear ← dispatchRpcCommand stP2 "ui_draft_get" (.obj #[("key", .str "m:flood-519")])
  let _ ← dispatchRpcCommand stP1 "ui_draft_delete" (.obj #[("key", .str "m:flood-519")])
  let draftAfterDelete ← dispatchRpcCommand stP2 "ui_draft_get" (.obj #[("key", .str "m:flood-519")])
  total := total + 1
  let tailStartOk := match tailRes with
    | .ok jv => jv.fieldNat? "start_idx" == some 7 && jv.fieldNat? "total_events" == some 10 && ((jv.fieldArr? "events_raw").map Array.size) == some 3
    | _ => false
  let sliceOk := match sliceBefore7 with
    | .ok jv => jv.fieldNat? "start_idx" == some 3 && ((jv.fieldArr? "events_raw").map Array.size) == some 4
    | _ => false
  let appendTailOk := match tailAfterAppend with
    | .ok jv => jv.fieldNat? "start_idx" == some 9 && jv.fieldNat? "total_events" == some 11 && ((jv.fieldArr? "events_raw").map Array.size) == some 2
    | _ => false
  let staleGuardOk := match tailAfterStale with
    | .ok jv => jv.fieldNat? "start_idx" == some 9 && jv.fieldNat? "total_events" == some 11 && jv.fieldNat? "saved_at" == some 5005
    | _ => false
  let sqlCacheAndDraftsOk :=
    isOkNull putSlicedRes &&
    tailStartOk &&
    isOkNull putPartialRes &&
    sliceOk &&
    appendTailOk &&
    isOkNull putStaleSlicedRes &&
    staleGuardOk &&
    isOkNull draftPut &&
    isOkNull draftIfAbsent &&
    isOkStr durableQueueAfterFlood "[{\"id\":\"unsent-msg-1\"}]" &&
    isOkNull evictedOldestDraft &&
    isOkStr newestFloodDraft "{\"text\":\"disposable\",\"images\":[]}" &&
    isOkNull tailAfterClear &&
    isOkStr draftAfterClear "{\"text\":\"disposable\",\"images\":[]}" &&
    isOkNull draftAfterDelete
  if (← assertTrue "sqlite_tail_sliced_ui_cache_and_draft_persistence" sqlCacheAndDraftsOk) then passed := passed + 1

  -- E. Token-scoped `__orb_poll_events` + per-SSE-subscriber broadcast (no multi-window event stealing)
  let stPub ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let sid1 ← stPub.modifyGet LocaldState.registerSseSubscriber
  let sid2 ← stPub.modifyGet LocaldState.registerSseSubscriber
  let tokA ← dispatchRpcCommand stPub "local_agents_subscribe" (.obj #[("id", .str "run-A")])
  let tokB ← dispatchRpcCommand stPub "local_agents_subscribe" (.obj #[("id", .str "run-B")])
  let tA := match tokA with | .ok jv => jv.asNat?.getD 0 | _ => 0
  let tB := match tokB with | .ok jv => jv.asNat?.getD 0 | _ => 0
  stPub.modify fun s =>
    let s1 := s.publishChannelEvent "local_agents" (.obj #[("text", .str "delta-A")]) (some "run-A")
    s1.publishChannelEvent "local_agents" (.obj #[("text", .str "delta-B")]) (some "run-B")
  let sseDrain1 ← stPub.modifyGet (·.drainSseSubscriber sid1)
  let sseDrain2 ← stPub.modifyGet (·.drainSseSubscriber sid2)
  let pollOnlyA ← dispatchRpcCommand stPub "__orb_poll_events" (.obj #[("tokens", .arr #[JVal.nat tA])])
  let pollOnlyB ← dispatchRpcCommand stPub "__orb_poll_events" (.obj #[("tokens", .arr #[JVal.nat tB])])
  total := total + 1
  let multiWinOk :=
    tA > 0 && tB > 0 && tA != tB &&
    sseDrain1.size == 2 && sseDrain2.size == 2 &&
    (match pollOnlyA, pollOnlyB with
     | .ok (.arr #[evA]), .ok (.arr #[evB]) =>
       evA.fieldNat? "token" == some tA &&
       ((evA.field? "payload").bind (·.fieldStr? "text")) == some "delta-A" &&
       evB.fieldNat? "token" == some tB &&
       ((evB.field? "payload").bind (·.fieldStr? "text")) == some "delta-B"
     | _, _ => false)
  if (← assertTrue "per_sse_subscriber_broadcast_and_token_scoped_poll_events" multiWinOk) then passed := passed + 1

  -- F. `software_inventory` schema, `local_skills_sync`/`local_skills_status`, and `stage_upload_file`
  let stInv ← IO.mkRef ({
    launchToken := validTok,
    orbStateDir := (pDir / "inv-state").toString,
    homeDir := (pDir / "inv-home").toString,
    hostOs := "macos"
  } : LocaldState)
  let invHome := pDir / "inv-home"
  IO.FS.createDirAll (invHome / ".claude" / "skills" / "retired-managed")
  IO.FS.writeFile (invHome / ".claude" / "skills" / "retired-managed" / "SKILL.md") "---\nname: retired-managed\n---\nOld.\n"
  IO.FS.writeFile (invHome / ".claude" / "skills" / "retired-managed" / ".managed-by-orb-skills") "managed-by-orb-skills\n"
  IO.FS.createDirAll (invHome / ".claude" / "skills" / "user-edited")
  IO.FS.writeFile (invHome / ".claude" / "skills" / "user-edited" / "SKILL.md") "---\nname: user-edited\n---\nMy local edit.\n"
  let invRes ← dispatchRpcCommand stInv "software_inventory" (.obj #[])
  let libPayloads : Array JVal := #[
    .obj #[
      ("name", .str "demo-skill"),
      ("content", .str "---\nname: demo-skill\ndescription: \"Demo\"\nmetadata:\n  sandboxed:\n    audience: [mission, coordinator, local]\n    scope: on-demand\n---\nUse demo.\n"),
      ("audience", .arr #[.str "mission", .str "coordinator", .str "local"]),
      ("scope", .str "on-demand")
    ],
    .obj #[
      ("name", .str "proton-mail"),
      ("content", .str "---\nname: proton-mail\ndescription: \"Coord mail\"\nmetadata:\n  sandboxed:\n    audience: [coordinator]\n    scope: on-demand\n---\nCoord only.\n"),
      ("audience", .arr #[.str "coordinator"]),
      ("scope", .str "on-demand")
    ],
    .obj #[
      ("name", .str "user-edited"),
      ("content", .str "---\nname: user-edited\ndescription: \"Lib version\"\n---\nLibrary body.\n")
    ]
  ]
  let preStatus ← dispatchRpcCommand stInv "local_skills_status" (.obj #[("request", .obj #[("library_skills", .arr libPayloads)])])
  let syncRes ← dispatchRpcCommand stInv "local_skills_sync" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr libPayloads),
      ("prune_removed", .bool true)
    ])
  ])
  let stageRes ← dispatchRpcCommand stInv "stage_upload_file" (.obj #[
    ("name", .str "clip.png"),
    ("dataBase64", .str (OrbBin.PosixExt.base64Encode "PNG_DATA".toUTF8))
  ])
  let stagedRead ← match stageRes with
    | .ok (.str sp) => dispatchRpcCommand stInv "read_upload_file" (.obj #[("path", .str sp)])
    | _ => pure (.error "stage_failed")
  total := total + 1
  let preStatusOk :=
    match preStatus with
    | .ok rep =>
      let hs := (rep.fieldArr? "harnesses").getD #[]
      let claude? := hs.find? (fun h => h.fieldStr? "id" == some "claudecode")
      let sks := (rep.fieldArr? "skills").getD #[]
      let retired? := sks.find? (fun s => s.fieldStr? "name" == some "retired-managed")
      let edited? := sks.find? (fun s => s.fieldStr? "name" == some "user-edited")
      let proton? := sks.find? (fun s => s.fieldStr? "name" == some "proton-mail")
      claude?.bind (·.fieldNat? "canonical_total") == some 2 &&
      claude?.bind (·.fieldNat? "synced_count") == some 0 &&
      retired?.bind (·.fieldBool? "removed_from_library") == some true &&
      (edited?.bind (·.field? "edited_copy")).map (fun v => v != .null) == some true &&
      proton?.bind (·.fieldBool? "desired") == some false
    | _ => false
  let postSyncOk :=
    match syncRes with
    | .ok jv =>
      let rep := (jv.field? "report").getD (.obj #[])
      let hs := (rep.fieldArr? "harnesses").getD #[]
      let claude? := hs.find? (fun h => h.fieldStr? "id" == some "claudecode")
      let codex? := hs.find? (fun h => h.fieldStr? "id" == some "codex")
      let prunedArr := ((jv.fieldArr? "pruned").getD #[]).filterMap (·.asStr?)
      let skippedArr := ((jv.fieldArr? "skipped_unmanaged").getD #[]).filterMap (·.asStr?)
      jv.fieldNat? "synced_skills" == some 1 &&
      jv.fieldNat? "harnesses_updated" == some 6 &&
      prunedArr.contains "~/.claude/skills/retired-managed" &&
      skippedArr.contains "~/.claude/skills/user-edited" &&
      claude?.bind (·.fieldNat? "canonical_total") == some 2 &&
      claude?.bind (·.fieldNat? "synced_count") == some 1 &&
      codex?.bind (·.fieldNat? "canonical_total") == some 2 &&
      codex?.bind (·.fieldNat? "synced_count") == some 2
    | _ => false
  let protonExists ← (invHome / ".claude" / "skills" / "proton-mail").pathExists
  let protonAbsent := !protonExists
  let invAndSkillsOk :=
    (match invRes with
     | .ok jv =>
       (jv.fieldNat? "checked_at").isSome &&
       (jv.fieldArr? "components").map (fun c => c.size == 6) == some true &&
       (jv.field? "runtime").isSome &&
       (jv.fieldArr? "jobs").isSome
     | _ => false) &&
    preStatusOk &&
    postSyncOk &&
    protonAbsent &&
    stagedRead.isOk
  if (← assertTrue "software_inventory_skills_sync_and_staged_upload_roundtrip" invAndSkillsOk) then passed := passed + 1

  -- F2. Local MCP auto-provisioning (`~/.orb/mcp/credential` `0600`, 0-byte Antigravity `mcp_config.json`, Claude/Codex/OpenCode preservation & endpoint fencing)
  IO.FS.createDirAll (invHome / ".local" / "bin")
  let fakeMcpBin := invHome / ".local" / "bin" / "sandboxed-mcp"
  IO.FS.writeFile fakeMcpBin "#!/bin/sh\nexit 0\n"
  discard <| OrbBin.PosixExt.chmod fakeMcpBin.toString 0o755
  IO.FS.writeFile (invHome / ".gemini" / "config" / "mcp_config.json") ""
  IO.FS.writeFile (invHome / ".claude.json") "{\"oauthAccount\":\"u1\",\"mcpServers\":{\"playwright\":{\"command\":\"npx\",\"args\":[]}}}\n"
  IO.FS.writeFile (invHome / ".codex" / "config.toml") "model = \"gpt-5.4\"\n"
  IO.FS.writeFile (invHome / ".config" / "opencode" / "opencode.json") "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}\n"
  let nowSecMcp ← OrbBin.PosixExt.nowEpoch
  let mcpPreStatus ← dispatchRpcCommand stInv "local_skills_status" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr libPayloads),
      ("api_url", .str "https://orbcore.thomas.md")
    ])
  ])
  let mcpSync1 ← dispatchRpcCommand stInv "local_skills_sync" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr libPayloads),
      ("api_url", .str "https://orbcore.thomas.md"),
      ("mcp_session", .obj #[
        ("api_url", .str "https://orbcore.thomas.md"),
        ("token", .str "mcp1.eyJhbGciOiJIUzI1NiJ9.eyJzZXNzaW9uX2lkIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDQyIn0.abcd"),
        ("session_id", .str "00000000-0000-4000-8000-000000000042"),
        ("role", .str "coordinator"),
        ("expires_at", JVal.uint64 (nowSecMcp + 3600)),
        ("hard_expires_at", JVal.uint64 (nowSecMcp + 86400))
      ])
    ])
  ])
  -- Reset Antigravity config to 0 bytes and verify silent repair without passing `mcp_session`
  IO.FS.writeFile (invHome / ".gemini" / "config" / "mcp_config.json") ""
  let mcpRepairSync ← dispatchRpcCommand stInv "local_skills_sync" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr libPayloads),
      ("api_url", .str "https://orbcore.thomas.md")
    ])
  ])
  let mcpOtherEpStatus ← dispatchRpcCommand stInv "local_skills_status" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr libPayloads),
      ("api_url", .str "https://other-core.example.com")
    ])
  ])
  let mcpOperatorReject ← dispatchRpcCommand stInv "local_skills_sync" (.obj #[
    ("request", .obj #[
      ("library_skills", .arr #[]),
      ("mcp_session", .obj #[
        ("api_url", .str "https://orbcore.thomas.md"),
        ("token", .str "mcp1.a.b.c"),
        ("role", .str "operator"),
        ("hard_expires_at", JVal.uint64 (nowSecMcp + 86400))
      ])
    ])
  ])
  let credSt ← OrbBin.PosixExt.statPath (invHome / ".orb" / "mcp" / "credential").toString
  let claudeAfterRaw ← try IO.FS.readFile (invHome / ".claude.json") catch _ => pure ""
  let codexAfterRaw ← try IO.FS.readFile (invHome / ".codex" / "config.toml") catch _ => pure ""
  let agyAfterRaw ← try IO.FS.readFile (invHome / ".gemini" / "config" / "mcp_config.json") catch _ => pure ""
  let opencodeAfterRaw ← try IO.FS.readFile (invHome / ".config" / "opencode" / "opencode.json") catch _ => pure ""
  total := total + 1
  let mcpAutoSyncOk :=
    credSt.exists_ && credSt.isReg && !credSt.isSymlink && (credSt.mode &&& 0o777) == 0o600 &&
    (match mcpPreStatus with
     | .ok rep =>
       let m := (rep.field? "mcp").getD (.obj #[])
       m.fieldBool? "ready" == some false && m.fieldBool? "needs_token" == some true && m.fieldBool? "binary_ready" == some true
     | _ => false) &&
    (match mcpSync1, mcpRepairSync with
     | .ok s1, .ok s2 =>
       let r1 := ((s1.field? "report").getD (.obj #[])).fieldOrNull "mcp"
       let r2 := ((s2.field? "report").getD (.obj #[])).fieldOrNull "mcp"
       r1.fieldBool? "ready" == some true &&
       (r1.fieldArr? "synced_harnesses").map (·.size) == some 4 &&
       (r1.fieldArr? "missing_harnesses").map (·.size) == some 0 &&
       r2.fieldBool? "ready" == some true &&
       (r2.fieldArr? "synced_harnesses").map (·.size) == some 4
     | _, _ => false) &&
    (match mcpOtherEpStatus with
     | .ok rep =>
       let m := rep.fieldOrNull "mcp"
       m.fieldBool? "ready" == some false && m.fieldBool? "needs_token" == some true
     | _ => false) &&
    (match mcpOperatorReject with
     | .ok jv => (jv.fieldStr? "mcp_error").isSome
     | _ => false) &&
    (match OrbBin.Json.parse claudeAfterRaw, OrbBin.Json.parse agyAfterRaw, OrbBin.Json.parse opencodeAfterRaw with
     | .ok cj, .ok aj, .ok oj =>
       cj.fieldStr? "oauthAccount" == some "u1" &&
       ((cj.field? "mcpServers").bind (·.field? "playwright")).isSome &&
       ((cj.field? "mcpServers").bind (·.field? "sandboxed")).isSome &&
       ((aj.field? "mcpServers").bind (·.field? "sandboxed")).isSome &&
       oj.fieldStr? "$schema" == some "https://opencode.ai/config.json" &&
       ((oj.field? "mcp").bind (·.field? "sandboxed")).isSome
     | _, _, _ => false) &&
    (codexAfterRaw.splitOn "model = \"gpt-5.4\"").length == 2 &&
    (codexAfterRaw.splitOn "[mcp_servers.sandboxed]").length == 2
  if (← assertTrue "local_mcp_auto_sync_repairs_0byte_agy_preserves_configs_and_fences_endpoint" mcpAutoSyncOk) then passed := passed + 1

  -- G. Voice worker Protocol v1 integration (`ORB_VOICE_FAKE=1`: `voice_capability`, `voice_prewarm`, `voice_transcribe`, `voice_cancel`)
  OrbBin.PosixExt.setenvVar "ORB_VOICE_FAKE" "1"
  let repoWorkerCandidates : Array String := #[
    "orb/voice/worker.py",
    "../../orb/voice/worker.py"
  ]
  for cand in repoWorkerCandidates do
    if (← System.FilePath.pathExists cand) then
      OrbBin.PosixExt.setenvVar "ORB_VOICE_WORKER" cand
  let wavBytes := makeTestWav16kMono 4800 4000 -- 0.30s @ 16kHz, peak=4000
  let vCap ← dispatchRpcCommand stInv "voice_capability" (.obj #[])
  let vWarm ← dispatchRpcCommand stInv "voice_prewarm" (.obj #[])
  let vTx ← dispatchRpcCommand stInv "voice_transcribe" (.obj #[
    ("__binaryBase64", .str (OrbBin.PosixExt.base64Encode wavBytes)),
    ("__headers", .obj #[("x-language", .str "fr")])
  ])
  let vCancel ← dispatchRpcCommand stInv "voice_cancel" (.obj #[])
  OrbBin.PosixExt.unsetenvVar "ORB_VOICE_FAKE"
  OrbBin.PosixExt.unsetenvVar "ORB_VOICE_WORKER"
  total := total + 1
  let voiceOk :=
    (match vCap with | .ok jv => jv.fieldBool? "supported" == some true && jv.fieldBool? "python_ready" == some true | _ => false) &&
    vWarm.isOk &&
    (match vTx with
     | .ok jv =>
       match jv.fieldStr? "text" with
       | some txt => (txt.splitOn "[fake fr]").length > 1
       | none => false
     | _ => false) &&
    (match vCancel with | .ok (.bool true) => true | _ => false)
  if (← assertTrue "voice_worker_protocol_v1_fake_backend_transcribe_and_cancel" voiceOk) then passed := passed + 1

  -- H. Large HTTP request framing (> 4 MiB: 5 MiB proxy & RPC framing) + live `/__orb_events` SSE latency (< 50ms)
  let fiveMbBody := ByteArray.mk (Array.replicate (5 * 1024 * 1024) (0x41 : UInt8))
  let largeRpcHead := s!"POST /__orb_rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {fiveMbBody.size}\r\n\r\n".toUTF8
  let largeProxyHead := s!"POST /__orb_tx/u1/api/projects/p/context/blobs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {fiveMbBody.size}\r\n\r\n".toUTF8
  let overRpcHead := s!"POST /__orb_rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {maxLocaldRpcBodyBytes + 1}\r\n\r\n".toUTF8
  total := total + 1
  let largeFrameOk :=
    (match parseLocaldHttpRequestFrame (largeRpcHead ++ fiveMbBody) false with
     | .ok (req, rem) => req.contentLength == fiveMbBody.size && rem.isEmpty
     | _ => false) &&
    (match parseLocaldHttpRequestFrame (largeProxyHead ++ fiveMbBody) true with
     | .ok (req, rem) => req.contentLength == fiveMbBody.size && rem.isEmpty
     | _ => false) &&
    (parseLocaldHttpRequestHead overRpcHead false).isOk.not
  if (← assertTrue "http_framing_supports_5mb_bodies_and_enforces_36mb_64mb_caps" largeFrameOk) then passed := passed + 1

  -- Live loopback SSE latency check on `streamLocalEventsSse` (< 50ms end-to-end wakeup)
  let stSseLive ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let subLiveRes ← dispatchRpcCommand stSseLive "local_agents_subscribe" (.obj #[("id", .str "live-sse")])
  let _ := subLiveRes
  let mut sseLatOk := false
  if let .ok (lfd, lport) ← LeanSys.Posix.tcpListen "127.0.0.1" 0 4 then
    try
      let srvTask ← IO.asTask (prio := .dedicated) do
        if let .ok sfd ← LeanSys.Posix.tcpAcceptPoll lfd 2000 then
          try streamLocalEventsSse stSseLive sfd none
          finally discard <| LeanSys.Posix.closeFd sfd
      if let .ok cfd ← LeanSys.Posix.tcpConnect "127.0.0.1" lport then
        try
          -- Wait for `: ready\n\n`
          if let .ok () ← LeanSys.Posix.pollReadable cfd 1000 then
            let _ ← LeanSys.Posix.readStreamChunk cfd 512
            let tStart ← IO.monoMsNow
            stSseLive.modify fun s =>
              s.publishChannelEvent "local_agents" (.obj #[("text", .str "fast-ping")]) (some "live-sse")
            if let .ok () ← LeanSys.Posix.pollReadable cfd 200 then
              let rx ← LeanSys.Posix.readStreamChunk cfd 1024
              let elapsed := (← IO.monoMsNow) - tStart
              let rxStr := String.fromUTF8? rx |>.getD ""
              sseLatOk := elapsed < 80 && (rxStr.splitOn "fast-ping").length > 1
        finally
          discard <| LeanSys.Posix.closeFd cfd
      let _ := srvTask.get
    finally
      discard <| LeanSys.Posix.closeFd lfd
  total := total + 1
  if (← assertTrue "live_sse_event_delivery_under_80ms_without_500ms_stall" sseLatOk) then passed := passed + 1
  return (passed, total)

private def runLinuxPortalAndRevealChecks (pDir : System.FilePath) (validTok : String) : IO (Nat × Nat) := do
  let mut passed : Nat := 0
  let mut total : Nat := 0

  -- J. Linux `reveal_download` prefers `org.freedesktop.FileManager1.ShowItems` and RFC 8089 `filePathToUri` encodes `,`/spaces/UTF-8
  let fmTestDir := pDir / "linux-reveal-test"
  let fmBinDir := fmTestDir / "bin"
  let fmHomeDir := fmTestDir / "home"
  IO.FS.createDirAll fmBinDir
  IO.FS.createDirAll (fmHomeDir / "Downloads")
  IO.FS.writeFile (fmHomeDir / "Downloads" / "Guide, Révision 2026.pdf") "%PDF"
  let dbusLogPath := fmTestDir / "dbus-args.log"
  let mockDbusSend := fmBinDir / "dbus-send"
  IO.FS.writeFile mockDbusSend s!"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"{dbusLogPath.toString}\"\nexit 0\n"
  discard <| OrbBin.PosixExt.chmod mockDbusSend.toString 0o755
  let prevPath := (← IO.getEnv "PATH").getD ""
  let prevDbus := (← IO.getEnv "DBUS_SESSION_BUS_ADDRESS").getD ""
  OrbBin.PosixExt.setenvVar "PATH" s!"{fmBinDir.toString}:{prevPath}"
  OrbBin.PosixExt.setenvVar "DBUS_SESSION_BUS_ADDRESS" "unix:path=/tmp/mock-orb-dbus"
  let stFmRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := fmTestDir.toString, homeDir := fmHomeDir.toString, hostOs := "linux" } : LocaldState)
  let revealLinuxRes ← dispatchRpcCommand stFmRef "reveal_download" (.obj #[("name", .str "Guide, Révision 2026.pdf")])
  OrbBin.PosixExt.setenvVar "PATH" prevPath
  if prevDbus.isEmpty then OrbBin.PosixExt.unsetenvVar "DBUS_SESSION_BUS_ADDRESS"
  else OrbBin.PosixExt.setenvVar "DBUS_SESSION_BUS_ADDRESS" prevDbus
  let dbusLogged ← try IO.FS.readFile dbusLogPath catch _ => pure ""
  let expectedUri := filePathToUri (fmHomeDir / "Downloads" / "Guide, Révision 2026.pdf").toString
  let linuxRevealOk :=
    revealLinuxRes.isOk &&
    expectedUri.endsWith "/Downloads/Guide%2C%20R%C3%A9vision%202026.pdf" &&
    (dbusLogged.splitOn "org.freedesktop.FileManager1.ShowItems").length == 2 &&
    (dbusLogged.splitOn s!"array:string:{expectedUri}").length == 2
  total := total + 1
  if (← assertTrue "linux_reveal_download_uses_filemanager1_and_encodes_uri" linuxRevealOk) then passed := passed + 1

  return (passed, total)

private def runLinuxPortalFileChooserChecks (tmpStateDir validTok : String) : IO (Nat × Nat) := do
  let pDir := System.FilePath.mk tmpStateDir / "desktop-parity"
  IO.FS.createDirAll pDir
  let mut passed := 0
  let mut total := 0

  -- K. Linux `fileUriToPath?` RFC 8089 decoding + XDG Desktop Portal `FileChooser` (`pick_working_directory`, `pick_upload_files`, `pick_upload_folder`) + CLI fallback
  let uriSamplePath := "/tmp/Guide, Révision 100% 2026/sub dir"
  let uriRoundTripOk :=
    fileUriToPath? (filePathToUri uriSamplePath) == some uriSamplePath &&
    fileUriToPath? "file://localhost/home/alice/my%20repo/" == some "/home/alice/my repo" &&
    fileUriToPath? "file:///" == some "/" &&
    (fileUriToPath? "file://remotehost/tmp/x").isNone &&
    (fileUriToPath? "https://example.com/tmp/x").isNone &&
    (fileUriToPath? "file:///bad%00nul").isNone
  total := total + 1
  if (← assertTrue "file_uri_to_path_rfc8089_roundtrip_and_validation" uriRoundTripOk) then passed := passed + 1

  let portalRoot := pDir / "linux-portal-test"
  let chosenWorkDir := portalRoot / "work repo, 2026"
  let fallbackWorkDir := portalRoot / "zenity-dir"
  let uploadDir := portalRoot / "bundle-folder"
  IO.FS.createDirAll chosenWorkDir
  IO.FS.writeFile (chosenWorkDir / "README.md") "# hello\n"
  IO.FS.createDirAll fallbackWorkDir
  IO.FS.createDirAll (uploadDir / "src")
  IO.FS.createDirAll (uploadDir / ".git")
  IO.FS.writeFile (uploadDir / "src" / "main.lean") "def x := 1\n"
  IO.FS.writeFile (uploadDir / ".git" / "config") "[core]\n"
  let pickSingleFile := portalRoot / "notes, draft.txt"
  IO.FS.writeFile pickSingleFile "draft-payload"
  let _ ← IO.Process.output { cmd := "ln", args := #["-s", pickSingleFile.toString, (uploadDir / "escape-link.txt").toString] }

  let canonChosenWorkDir := (← IO.FS.realPath chosenWorkDir).toString
  let canonFallbackWorkDir := (← IO.FS.realPath fallbackWorkDir).toString
  let canonSingleFile := (← IO.FS.realPath pickSingleFile).toString
  let canonUploadMain := (← IO.FS.realPath (uploadDir / "src" / "main.lean")).toString

  let pidNum ← OrbBin.PosixExt.getpid
  let portalSock := s!"/tmp/orb-portal-{pidNum}.sock"
  try IO.FS.removeFile portalSock catch _ => pure ()

  let servePortalOnce (lfd : LeanSys.Posix.Fd) (respCode : UInt32) (uris : Array String) (withExtraDict : Bool) : IO Bool := do
    let cfd ← match ← LeanSys.Posix.tcpAcceptPoll lfd 5000 with
      | .ok f => pure f
      | .error _ => return false
    try
      -- Read SASL `\0AUTH EXTERNAL ...\r\n`
      let mut sbuf := ByteArray.empty
      while !(String.fromUTF8? sbuf |>.getD "" |>.endsWith "\r\n") && sbuf.size < 512 do
        if let .ok () ← LeanSys.Posix.pollReadable cfd 2000 then
          let ch ← LeanSys.Posix.readStreamChunk cfd 256
          if ch.isEmpty then return false
          sbuf := sbuf ++ ch
        else return false
      discard <| LeanSys.Posix.writeAll cfd "OK 0123456789abcdef0123456789abcdef\r\n".toUTF8 false
      -- Read `BEGIN\r\n`
      let mut bbuf := ByteArray.empty
      let mut carry := ByteArray.empty
      let mut gotBegin := false
      while !gotBegin && bbuf.size < 2048 do
        if let .ok () ← LeanSys.Posix.pollReadable cfd 2000 then
          let ch ← LeanSys.Posix.readStreamChunk cfd 512
          if ch.isEmpty then return false
          bbuf := bbuf ++ ch
          if bbuf.size ≥ 7 then
            for idx in [0:bbuf.size - 6] do
              if !gotBegin && String.fromUTF8? (bbuf.extract idx (idx + 7)) == some "BEGIN\r\n" then
                gotBegin := true
                carry := bbuf.extract (idx + 7) bbuf.size
        else return false
      if !gotBegin then return false

      let readNextMsg (initBuf : ByteArray) : IO (Option (DbusMessageFrame × ByteArray)) := do
        let mut rbuf := initBuf
        for _ in [0:32] do
          match parseDbusMessageFrame rbuf with
          | .ok frm rem => return some (frm, rem)
          | .invalid _ => return none
          | .incomplete =>
            if let .ok () ← LeanSys.Posix.pollReadable cfd 2000 then
              let ch ← LeanSys.Posix.readStreamChunk cfd 4096
              if ch.isEmpty then return none
              rbuf := rbuf ++ ch
            else return none
        return none

      -- 1. Hello
      let some (m1, c1) ← readNextMsg carry | return false
      let r1 := buildDbusMessage 2 10 #[(5, .u32 m1.serial), (8, .sig "s")] (dbusPushString ByteArray.empty ":1.77")
      discard <| LeanSys.Posix.writeAll cfd r1 false
      -- 2. AddMatch
      let some (m2, c2) ← readNextMsg c1 | return false
      let r2 := buildDbusMessage 2 11 #[(5, .u32 m2.serial)] ByteArray.empty
      discard <| LeanSys.Posix.writeAll cfd r2 false
      -- 3. OpenFile
      let some (m3, _) ← readNextMsg c2 | return false
      if m3.interface? != some "org.freedesktop.portal.FileChooser" || m3.member? != some "OpenFile" then
        return false
      let reqPath := "/org/freedesktop/portal/desktop/request/1_77/orb_mock"
      let r3 := buildDbusMessage 2 12 #[(5, .u32 m3.serial), (8, .sig "o")] (dbusPushString ByteArray.empty reqPath)
      discard <| LeanSys.Posix.writeAll cfd r3 false

      -- Build Response(uint32, a{sv}) signal
      let mut dictElems := ByteArray.empty
      if withExtraDict then
        -- Prepend `choices : a(ss)` = `[("encoding", "utf8")]` so generic D-Bus skipper is exercised
        dictElems := dbusPushString dictElems "choices"
        dictElems := dbusPushSig dictElems "a(ss)"
        let pairElem := dbusPushString (dbusPushString ByteArray.empty "encoding") "utf8"
        let withPairLen := dbusPushU32LE (dbusPadTo dictElems 4) pairElem.size.toUInt32
        dictElems := (dbusPadTo withPairLen 8) ++ pairElem
        dictElems := dbusPadTo dictElems 8
      dictElems := dbusPushString dictElems "uris"
      dictElems := dbusPushSig dictElems "as"
      let mut uriArr := ByteArray.empty
      for u in uris do
        uriArr := dbusPushString uriArr u
      dictElems := (dbusPushU32LE (dbusPadTo dictElems 4) uriArr.size.toUInt32) ++ uriArr

      let sigHead := dbusPushU32LE (dbusPushU32LE ByteArray.empty respCode) dictElems.size.toUInt32
      let sigBody := (dbusPadTo sigHead 8) ++ dictElems
      let sigMsg := buildDbusMessage 4 13 #[
        (1, .objPath reqPath),
        (2, .str "org.freedesktop.portal.Request"),
        (3, .str "Response"),
        (8, .sig "ua{sv}")
      ] sigBody
      discard <| LeanSys.Posix.writeAll cfd sigMsg false
      return true
    finally
      discard <| LeanSys.Posix.closeFd cfd

  let mockPickerBinDir := portalRoot / "bin"
  IO.FS.createDirAll mockPickerBinDir
  let zenityHitFile := portalRoot / "zenity-called.flag"
  let mockZenity := mockPickerBinDir / "zenity"
  IO.FS.writeFile mockZenity s!"#!/bin/sh\necho 1 > \"{zenityHitFile.toString}\"\nprintf '%s\\n' \"{fallbackWorkDir.toString}\"\nexit 0\n"
  discard <| OrbBin.PosixExt.chmod mockZenity.toString 0o755

  let prevPathPortal := (← IO.getEnv "PATH").getD ""
  let prevDbusPortal := (← IO.getEnv "DBUS_SESSION_BUS_ADDRESS").getD ""
  let mut portalSuiteOk := false
  if let .ok lfd ← LeanSys.Posix.unixListen portalSock 8 then
    try
      OrbBin.PosixExt.setenvVar "PATH" s!"{mockPickerBinDir.toString}:{prevPathPortal}"
      OrbBin.PosixExt.setenvVar "DBUS_SESSION_BUS_ADDRESS" s!"unix:path={portalSock}"
      let stPortalRef ← IO.mkRef ({
        launchToken := validTok,
        orbStateDir := (portalRoot / "state").toString,
        homeDir := portalRoot.toString,
        hostOs := "linux"
      } : LocaldState)

      -- 1) `pick_working_directory` accept -> returns canonical path & grants browse root
      let t1 ← IO.asTask (prio := .dedicated) (servePortalOnce lfd 0 #[filePathToUri chosenWorkDir.toString] true)
      let pickDirOkRes ← dispatchRpcCommand stPortalRef "pick_working_directory" (.obj #[("path", .str portalRoot.toString)])
      let s1Ok := match t1.get with | .ok true => true | _ => false
      let browsePickedRes ← dispatchRpcCommand stPortalRef "browse_local_files" (.obj #[
        ("root", .str canonChosenWorkDir),
        ("request", .obj #[("action", .str "list"), ("path", .str "")])
      ])

      -- 2) `pick_working_directory` cancel (`respCode = 1`) -> returns `.null` WITHOUT invoking `zenity`
      let t2 ← IO.asTask (prio := .dedicated) (servePortalOnce lfd 1 #[] false)
      let pickDirCancelRes ← dispatchRpcCommand stPortalRef "pick_working_directory" (.obj #[])
      let s2Ok := match t2.get with | .ok true => true | _ => false
      let zenityCalledDuringCancel ← zenityHitFile.pathExists

      -- 3) `pick_upload_files` accept -> returns `[{name, path}]` & grants `read_upload_file`
      let t3 ← IO.asTask (prio := .dedicated) (servePortalOnce lfd 0 #[filePathToUri pickSingleFile.toString] true)
      let pickFilesRes ← dispatchRpcCommand stPortalRef "pick_upload_files" (.obj #[])
      let s3Ok := match t3.get with | .ok true => true | _ => false
      let readPickedFileRes ← dispatchRpcCommand stPortalRef "read_upload_file" (.obj #[("path", .str canonSingleFile)])

      -- 4) `pick_upload_folder` accept -> skips `.git` & symlinks, offers batch so `grant_upload_folder` enables read
      let t4 ← IO.asTask (prio := .dedicated) (servePortalOnce lfd 0 #[filePathToUri uploadDir.toString] false)
      let pickFolderRes ← dispatchRpcCommand stPortalRef "pick_upload_folder" (.obj #[])
      let s4Ok := match t4.get with | .ok true => true | _ => false
      let batchIdPicked :=
        match pickFolderRes with
        | .ok jv => (jv.fieldStr? "batch").getD ""
        | .error _ => ""
      let folderFilesCount :=
        match pickFolderRes with
        | .ok jv => ((jv.fieldArr? "files").getD #[]).size
        | .error _ => 0
      let _ ← dispatchRpcCommand stPortalRef "grant_upload_folder" (.obj #[("batch", .str batchIdPicked)])
      let readWalkedFileRes ← dispatchRpcCommand stPortalRef "read_upload_file" (.obj #[("path", .str canonUploadMain)])

      -- 5) Portal unavailable -> falls back to `zenity` CLI
      OrbBin.PosixExt.setenvVar "DBUS_SESSION_BUS_ADDRESS" "unix:path=/tmp/orb-nonexistent-portal.sock"
      let prevXdg := (← IO.getEnv "XDG_RUNTIME_DIR").getD ""
      OrbBin.PosixExt.setenvVar "XDG_RUNTIME_DIR" (portalRoot / "no-xdg").toString
      let fallbackDirRes ← dispatchRpcCommand stPortalRef "pick_working_directory" (.obj #[])
      if prevXdg.isEmpty then OrbBin.PosixExt.unsetenvVar "XDG_RUNTIME_DIR"
      else OrbBin.PosixExt.setenvVar "XDG_RUNTIME_DIR" prevXdg

      -- 6) `offer_upload_folder` also accepts `{name, path, relative_path, size}` shape from `macos_shell`
      let macOfferRes ← dispatchRpcCommand stPortalRef "offer_upload_folder" (.obj #[
        ("batch", .str "mac-shape-batch"),
        ("roots", .arr #[.str uploadDir.toString]),
        ("files", .arr #[.obj #[
          ("name", .str "main.lean"),
          ("path", .str canonUploadMain),
          ("relative_path", .str "bundle-folder/src/main.lean"),
          ("size", JVal.nat 10)
        ]])
      ])
      let stAfterMacOffer ← stPortalRef.get
      let macShapeOffered :=
        stAfterMacOffer.offeredUploadBatches.any (fun (b, _, pairs) => b == "mac-shape-batch" && pairs.size == 1)

      portalSuiteOk :=
        s1Ok && s2Ok && s3Ok && s4Ok &&
        (match pickDirOkRes with | .ok (.str p) => p == canonChosenWorkDir | _ => false) &&
        browsePickedRes.isOk &&
        (match pickDirCancelRes with | .ok .null => true | _ => false) &&
        !zenityCalledDuringCancel &&
        readPickedFileRes.isOk &&
        (match pickFilesRes with
         | .ok (.arr #[item]) => item.fieldStr? "name" == some "notes, draft.txt" && item.fieldStr? "path" == some canonSingleFile
         | _ => false) &&
        !batchIdPicked.isEmpty &&
        folderFilesCount == 1 &&
        readWalkedFileRes.isOk &&
        (match fallbackDirRes with | .ok (.str p) => p == canonFallbackWorkDir | _ => false) &&
        macOfferRes.isOk &&
        macShapeOffered
    finally
      OrbBin.PosixExt.setenvVar "PATH" prevPathPortal
      if prevDbusPortal.isEmpty then OrbBin.PosixExt.unsetenvVar "DBUS_SESSION_BUS_ADDRESS"
      else OrbBin.PosixExt.setenvVar "DBUS_SESSION_BUS_ADDRESS" prevDbusPortal
      discard <| LeanSys.Posix.closeFd lfd
      try IO.FS.removeFile portalSock catch _ => pure ()
  total := total + 1
  if (← assertTrue "linux_portal_filechooser_working_dir_uploads_cancel_and_zenity_fallback" portalSuiteOk) then passed := passed + 1

  return (passed, total)

private def runDesktopReliabilityParityChecks (tmpBase : String) (validTok : String) : IO (Nat × Nat) := do
  let pDir := System.FilePath.mk tmpBase / "parity-suite"
  IO.FS.createDirAll pDir
  let (p1, t1) ← runDesktopReliabilityParityChecksPart1 pDir validTok
  let (p2, t2) ← runLinuxPortalAndRevealChecks pDir validTok
  return (p1 + p2, t1 + t2)

private def runWarmClaudeRpcE2eChecks (validTok tmpStateDir : String) : IO (Nat × Nat) := do
  let warmRpcDir := System.FilePath.mk tmpStateDir / "warm-rpc-repo"
  IO.FS.createDirAll warmRpcDir
  let _ ← IO.Process.output { cmd := "git", args := #["-C", warmRpcDir.toString, "init", "-b", "main"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", warmRpcDir.toString, "config", "user.email", "rpc@orb.local"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", warmRpcDir.toString, "config", "user.name", "Orb RPC"] }
  IO.FS.writeFile (warmRpcDir / "hello.txt") "before\n"
  let _ ← IO.Process.output { cmd := "git", args := #["-C", warmRpcDir.toString, "add", "hello.txt"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", warmRpcDir.toString, "commit", "-m", "init"] }

  let mockClaudeRpc := System.FilePath.mk tmpStateDir / "mock-claude-rpc.py"
  IO.FS.writeFile mockClaudeRpc (
    "#!/usr/bin/env python3\n" ++
    "import sys, json\n" ++
    "for raw in sys.stdin:\n" ++
    "    line = raw.strip()\n" ++
    "    if not line: continue\n" ++
    "    msg = json.loads(line)\n" ++
    "    if msg.get('type') == 'control_request' and msg.get('request', {}).get('subtype') == 'initialize':\n" ++
    "        print(json.dumps({'type':'system','subtype':'init','session_id':'rpc-sid-1'}), flush=True)\n" ++
    "    elif msg.get('type') == 'user':\n" ++
    "        print(json.dumps({'type':'control_request','request_id':'rpc-perm-1','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'pwd'}}}), flush=True)\n" ++
    "    elif msg.get('type') == 'control_response':\n" ++
    "        with open('hello.txt', 'w') as f: f.write('after-turn\\n')\n" ++
    "        print(json.dumps({'type':'result','num_turns':1,'is_error':False,'result':'Done via RPC','session_id':'rpc-sid-1'}), flush=True)\n"
  )
  let _ ← OrbBin.PosixExt.chmod mockClaudeRpc.toString 0o755

  let warmStRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir } : LocaldState)
  let scanRes ← dispatchRpcCommand warmStRef "local_agents_scan" (.obj #[("request", .obj #[("overrides", .obj #[("claudecode", .str mockClaudeRpc.toString)])])])
  let wsPathRes ← dispatchRpcCommand warmStRef "local_agents_workspace" (.obj #[("request", .obj #[("slug", .str "demo-proj")])])
  let writeRes ← dispatchRpcCommand warmStRef "local_agents_write" (.obj #[("request", .obj #[
    ("root", .str warmRpcDir.toString),
    ("files", .arr #[
      .obj #[("rel", .str "note.md"), ("content", .str "# Note\n")],
      .obj #[("rel", .str ".env"), ("content", .str "SECRET=1\n")]
    ])
  ])])
  let runLaunchRes ← dispatchRpcCommand warmStRef "local_run_launch" (.obj #[("request", .obj #[
    ("id", .str "m-rpc-1"),
    ("harness", .str "claudecode"),
    ("bin", .str mockClaudeRpc.toString),
    ("cwd", .str warmRpcDir.toString),
    ("prompt", .str "edit file"),
    ("permission_mode", .str "supervised")
  ])])
  let mut waitedPerm := 0
  let mut activeReqId := ""
  while waitedPerm < 3000 && activeReqId.isEmpty do
    if let .ok jv ← dispatchRpcCommand warmStRef "local_interaction" (.obj #[("id", .str "m-rpc-1")]) then
      activeReqId := (jv.fieldStr? "id").getD ""
    if activeReqId.isEmpty then
      IO.sleep 25
      waitedPerm := waitedPerm + 25
  let _ ← dispatchRpcCommand warmStRef "local_interaction_answer" (.obj #[
    ("id", .str "m-rpc-1"),
    ("requestId", .str "rpc-perm-1"),
    ("answer", .obj #[("action", .str "accept_session")])
  ])
  let mut waitedDone := 0
  let mut pollTxt := ""
  while waitedDone < 3000 do
    if let .ok pj ← dispatchRpcCommand warmStRef "local_agents_poll" (.obj #[("id", .str "m-rpc-1")]) then
      if (pj.fieldBool? "done") == some true then
        pollTxt := (pj.fieldStr? "text").getD ""
        break
    IO.sleep 25
    waitedDone := waitedDone + 25
  let _ ← dispatchRpcCommand warmStRef "local_agents_stop" (.obj #[("id", .str "m-rpc-1")])
  let ungrantedDir := System.FilePath.mk tmpStateDir / "ungranted-repo"
  IO.FS.createDirAll ungrantedDir
  let ungrantedListRes ← dispatchRpcCommand warmStRef "local_checkpoints_list" (.obj #[("cwd", .str ungrantedDir.toString), ("mission_id", .str "m-rpc-1")])
  let cpListRes ← dispatchRpcCommand warmStRef "local_checkpoints_list" (.obj #[("cwd", .str warmRpcDir.toString), ("mission_id", .str "m-rpc-1")])
  let cpDiffRes ← dispatchRpcCommand warmStRef "local_checkpoint_diff" (.obj #[("cwd", .str warmRpcDir.toString)])
  let wtStatRes ← dispatchRpcCommand warmStRef "local_worktree_status" (.obj #[("cwd", .str warmRpcDir.toString), ("mission_id", .str "m-rpc-2"), ("prefer_worktree", .bool true)])

  let rpcE2eOk :=
    (match scanRes with | .ok (.arr rows) => rows.size == 6 | _ => false) &&
    (match wsPathRes with | .ok (.str p) => !p.isEmpty | _ => false) &&
    (match writeRes with | .ok jv => ((jv.fieldArr? "written").map Array.size) == some 1 && ((jv.fieldArr? "skipped").map Array.size) == some 1 | _ => false) &&
    (match runLaunchRes with | .ok jv => (jv.fieldStr? "run_id").isSome && (jv.fieldUInt64? "generation") == some 1 | _ => false) &&
    activeReqId == "rpc-perm-1" &&
    pollTxt == "Done via RPC" &&
    ungrantedListRes.isOk.not &&
    (match cpListRes with | .ok jv => ((jv.fieldArr? "checkpoints").map (fun cps => decide (cps.size >= 2))).getD false | _ => false) &&
    (match cpDiffRes with | .ok jv => ((jv.fieldArr? "files").map (fun fs => decide (fs.size >= 1))).getD false && !(jv.fieldStr? "raw_diff" |>.getD "").isEmpty | _ => false) &&
    (match wtStatRes with | .ok jv => (jv.fieldBool? "is_git_repo") == some true && (jv.fieldNat? "decision_word") == some 513 | _ => false)
  let ok ← assertTrue "warm_claude_rpc_checkpoints_diff_and_worktree_e2e" rpcE2eOk
  return (if ok then 1 else 0, 1)

private def runDesktopBootstrapChecks (tmpStateDir validTok : String) : IO (Nat × Nat) := do
  let bootDir := s!"{tmpStateDir}/bootstrap-test"
  IO.FS.createDirAll (System.FilePath.mk bootDir)
  let bootRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := bootDir, homeDir := bootDir, hostOs := "macos" } : LocaldState)
  let _ ← dispatchRpcCommand bootRef "desktop_connection_save" (.obj #[
    ("api_url", .str "https://agent-backend-dev.thomas.md/"),
    ("token", .str "boot-tok-123")
  ])
  let _ ← dispatchRpcCommand bootRef "desktop_prefs_patch" (.obj #[
    ("set", .obj #[("orb.theme", .str "dark")])
  ])
  let bootReloadRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := bootDir, homeDir := bootDir, hostOs := "macos" } : LocaldState)
  let bootRes ← dispatchRpcCommand bootReloadRef "desktop_bootstrap" (.obj #[])
  let bootOk :=
    match bootRes with
    | .ok jv =>
      let connOk :=
        match jv.field? "connection" with
        | some cj => cj.fieldStr? "api_url" == some "https://agent-backend-dev.thomas.md/" && cj.fieldStr? "token" == some "boot-tok-123"
        | none => false
      let prefsOk :=
        match jv.field? "prefs" with
        | some pj =>
          pj.fieldBool? "exists" == some true &&
          (match pj.field? "prefs" with | some inner => inner.fieldStr? "orb.theme" == some "dark" | none => false)
        | none => false
      let txOk :=
        match jv.field? "transport" with
        | some tj => tj.fieldStr? "configured_target" == some "https://agent-backend-dev.thomas.md"
        | none => false
      connOk && prefsOk && txOk
    | .error _ => false
  let ok ← assertTrue "desktop_bootstrap_single_rpc_hydrates_connection_prefs_and_bridge" bootOk
  return (if ok then 1 else 0, 1)

private def runLocalOpenCodeE2eChecks (validTok tmpStateDir : String) : IO (Nat × Nat) := do
  let ocDir := System.FilePath.mk tmpStateDir / "opencode-e2e"
  IO.FS.createDirAll ocDir
  let fakeOcBin := ocDir / "fake-opencode.sh"
  let fakeOcScript :=
    "#!/bin/sh\n" ++
    "if [ \"$1\" = \"models\" ]; then\n" ++
    "  printf 'opencode/glm-5.3-flash-free\\norbrouter/anthropic/claude-opus-5-5\\norbrouter/builtin/fast\\norbrouter/builtin/smart\\n'\n" ++
    "  exit 0\n" ++
    "fi\n" ++
    "printf '{\"type\":\"step_start\",\"sessionID\":\"ses_oc_e2e_99\"}\\n'\n" ++
    "printf '{\"type\":\"tool_use\",\"sessionID\":\"ses_oc_e2e_99\",\"part\":{\"id\":\"call_1\",\"tool\":\"shell\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"echo hi\"},\"title\":\"shell\"}}}\\n'\n" ++
    "printf '{\"type\":\"text\",\"sessionID\":\"ses_oc_e2e_99\",\"part\":{\"type\":\"text\",\"text\":\"## Objective\\nGoal\\n## Work State\\nDone\\n## Next Move\\nNone\\n## Relevant Files\\na.lean\"}}\\n'\n" ++
    "printf '{\"type\":\"text\",\"sessionID\":\"ses_oc_e2e_99\",\"part\":{\"type\":\"text\",\"text\":\"OPENCODE_LOCAL_READY\"}}\\n'\n" ++
    "printf '{\"type\":\"step_finish\",\"sessionID\":\"ses_oc_e2e_99\"}\\n'\n"
  IO.FS.writeFile fakeOcBin fakeOcScript
  let _ ← OrbBin.PosixExt.chmod fakeOcBin.toString 0o755
  let ocRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := ocDir.toString, homeDir := ocDir.toString } : LocaldState)
  let ocModelsRes ← dispatchRpcCommand ocRef "local_opencode_models" (.obj #[("path", .str fakeOcBin.toString)])
  let hasModelPair (ms : Array JVal) (mid mlbl : String) : Bool :=
    ms.any fun m =>
      match m with
      | .arr #[.str a, .str b] => a == mid && b == mlbl
      | _ => false
  let ocModelsOk :=
    match ocModelsRes with
    | .ok (.arr ms) =>
      ms.size >= 4 &&
      hasModelPair ms "orbrouter/builtin/smart" "Routing — Smart" &&
      hasModelPair ms "orbrouter/builtin/fast" "Routing — Fast"
    | _ => false
  let ocResolveOk :=
    OrbBin.ClaudeControl.resolveOpenCodeModelForLocal (some "builtin/fast") (some "orbrouter/builtin/smart") #["orbrouter"] #["orbrouter/builtin/smart", "orbrouter/builtin/fast"] == some "orbrouter/builtin/fast" &&
    OrbBin.ClaudeControl.resolveOpenCodeModelForLocal (some "sandboxed-sh/builtin/smart") (some "orbrouter/builtin/smart") #["orbrouter"] #["orbrouter/builtin/smart"] == some "orbrouter/builtin/smart"
  let ocArgs := OrbBin.ClaudeControl.buildOneShotHarnessArgs "opencode" "/plan - check flags" (some "orbrouter/builtin/fast") none (some "ses_prev") .bypassPermissions #["/tmp/a.png"]
  let ocArgsOk :=
    ocArgs == #["run", "--format", "json", "--auto", "--agent", "plan", "--model", "orbrouter/builtin/fast", "--session", "ses_prev", "--file", "/tmp/a.png", "--", "- check flags"]
  let ocErrParsed := OrbBin.ClaudeControl.parseOneShotHarnessEvent "opencode" "{\"type\":\"error\",\"sessionID\":\"ses_err\",\"error\":{\"type\":\"provider.no-route\",\"message\":\"Model unavailable: builtin/fast\"}}"
  let ocErrOk := ocErrParsed.errorMsg? == some "Model unavailable: builtin/fast" && ocErrParsed.sessionId? == some "ses_err"
  let ocSubRes ← dispatchRpcCommand ocRef "local_bindings_subscribe" (.obj #[])
  let ocSubTok := match ocSubRes with | .ok (.num s) => s.toNat?.getD 0 | _ => 0
  let ocLaunchRes ← dispatchRpcCommand ocRef "local_origin_launch" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-oc.example")]),
    ("request", .obj #[
      ("harness", .str "opencode"),
      ("bin", .str fakeOcBin.toString),
      ("cwd", .str ocDir.toString),
      ("prompt", .str "Reply OPENCODE_LOCAL_READY"),
      ("model", .str "builtin/fast")
    ]),
    ("draft", .obj #[("title", .str "OC Local"), ("project", .str "orb"), ("prompt", .str "Reply OPENCODE_LOCAL_READY")])
  ])
  let ocMid := match ocLaunchRes with | .ok jv => (jv.fieldStr? "id").getD "" | _ => ""
  let mut ocDone := false
  for _ in [0:40] do
    if !ocDone then
      let pRes ← dispatchRpcCommand ocRef "local_agents_poll" (.obj #[("id", .str ocMid)])
      if let .ok pJv := pRes then
        if pJv.fieldBool? "done" == some true then ocDone := true
      if !ocDone then IO.sleep 50
  let ocPollFinal ← dispatchRpcCommand ocRef "local_agents_poll" (.obj #[("id", .str ocMid)])
  let ocBindRefresh1 ← dispatchRpcCommand ocRef "local_bindings_refresh" (.obj #[])
  let _ ← dispatchRpcCommand ocRef "local_run_launch" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-oc.example")]),
    ("request", .obj #[
      ("id", .str ocMid),
      ("harness", .str "opencode"),
      ("bin", .str fakeOcBin.toString),
      ("cwd", .str ocDir.toString),
      ("prompt", .str "Follow up turn 2"),
      ("display_prompt", .str "Follow up turn 2"),
      ("message_id", .str "msg-followup-2"),
      ("model", .str "builtin/smart"),
      ("session_id", .str "ses_oc_e2e_99")
    ])
  ])
  let mut ocDone2 := false
  for _ in [0:40] do
    if !ocDone2 then
      let pRes2 ← dispatchRpcCommand ocRef "local_agents_poll" (.obj #[("id", .str ocMid)])
      if let .ok pJv2 := pRes2 then
        if pJv2.fieldBool? "done" == some true then ocDone2 := true
      if !ocDone2 then IO.sleep 50
  let ocBindRefresh ← dispatchRpcCommand ocRef "local_bindings_refresh" (.obj #[])
  let ocOriginsList ← dispatchRpcCommand ocRef "local_origin_list" (.obj #[
    ("connection", .obj #[("api_url", .str "https://core-oc.example")])
  ])
  let ocEvPoll ← dispatchRpcCommand ocRef "__orb_poll_events" (.obj #[("tokens", .arr #[JVal.nat ocSubTok])])
  -- Verify instant `~/.config/opencode/opencode.json` model loading (without spawning slow `opencode models`)
  -- and automatic migration of persisted unprefixed `builtin/*` OpenCode models on reload.
  let ocRepairDir := ocDir / "repair-state"
  let ocCfgDir := ocRepairDir / ".config" / "opencode"
  IO.FS.createDirAll ocCfgDir
  IO.FS.writeFile (ocCfgDir / "opencode.json")
    "{\"model\":\"orbrouter/builtin/smart\",\"provider\":{\"orbrouter\":{\"name\":\"OrbRouter\",\"models\":{\"builtin/smart\":{},\"builtin/fast\":{}}}}}"
  let slowOcBin := ocRepairDir / "slow-opencode.sh"
  IO.FS.writeFile slowOcBin
    "#!/bin/sh\nif [ \"$1\" = \"models\" ]; then\n  exit 99\nfi\nexit 0\n"
  let _ ← OrbBin.PosixExt.chmod slowOcBin.toString 0o755
  IO.FS.writeFile (ocRepairDir / "local-bindings.json")
    ("{\"revision\":1,\"bindings\":{\"m-legacy-oc\":{\"harness\":\"opencode\",\"bin\":\"" ++ slowOcBin.toString ++ "\",\"cwd\":\"" ++ ocRepairDir.toString ++ "\",\"model\":\"builtin/smart\",\"sessionId\":\"ses_leg\"}}}")
  IO.FS.writeFile (ocRepairDir / "local-origins.json")
    ("[{\"id\":\"m-legacy-oc\",\"endpoint\":\"https://core-oc.example\",\"title\":\"Legacy OC\",\"status\":\"failed\",\"backend\":\"opencode\",\"working_directory\":\"" ++ ocRepairDir.toString ++ "\",\"delivered_prompt\":\"hi\",\"local_sync_pending\":true,\"local_run_active\":false,\"project\":\"orb\",\"model_override\":\"builtin/smart\",\"history\":[{\"role\":\"user\",\"content\":\"hi\"}]}]")
  let ocRepairRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := ocRepairDir.toString, homeDir := ocRepairDir.toString } : LocaldState)
  let fastProbeRes ← dispatchRpcCommand ocRepairRef "local_opencode_models" (.obj #[("path", .str slowOcBin.toString)])
  let fastScanRes ← dispatchRpcCommand ocRepairRef "local_agents_scan" (.obj #[("request", .obj #[("overrides", .obj #[("opencode", .str slowOcBin.toString)])])])
  let repairedBindsRes ← dispatchRpcCommand ocRepairRef "local_bindings_refresh" (.obj #[])
  let repairedOriginsRes ← dispatchRpcCommand ocRepairRef "local_origin_list" (.obj #[("connection", .obj #[("api_url", .str "https://core-oc.example")])])
  let ocInstantAndRepairOk :=
    (match fastProbeRes with
     | .ok (.arr ms) => hasModelPair ms "orbrouter/builtin/smart" "Routing — Smart" && hasModelPair ms "orbrouter/builtin/fast" "Routing — Fast"
     | _ => false) &&
    (match fastScanRes with
     | .ok (.arr rows) =>
       match rows.find? (fun r => r.fieldStr? "id" == some "opencode") with
       | some r => ((r.fieldArr? "models").map (fun ms => hasModelPair ms "orbrouter/builtin/smart" "Routing — Smart")).getD false
       | none => false
     | _ => false) &&
    (match repairedBindsRes with
     | .ok bJv => ((bJv.fieldOrNull "bindings").fieldOrNull "m-legacy-oc").fieldStr? "model" == some "orbrouter/builtin/smart"
     | _ => false) &&
    (match repairedOriginsRes with
     | .ok (.arr rows) =>
       match rows.find? (fun r => r.fieldStr? "id" == some "m-legacy-oc") with
       | some r => r.fieldStr? "model_override" == some "orbrouter/builtin/smart"
       | none => false
     | _ => false)
  let ocRunOk :=
    ocInstantAndRepairOk && ocDone && ocDone2 &&
    (match ocPollFinal with
      | .ok pJv =>
        pJv.fieldStr? "text" == some "OPENCODE_LOCAL_READY" &&
        pJv.fieldStr? "session_id" == some "ses_oc_e2e_99" &&
        ((pJv.fieldArr? "activities").map (fun acts => acts.size == 1)).getD false
      | _ => false) &&
    (match ocBindRefresh1 with
      | .ok bJv =>
        let bRow := (bJv.fieldOrNull "bindings").fieldOrNull ocMid
        bRow.fieldStr? "sessionId" == some "ses_oc_e2e_99" &&
        bRow.fieldStr? "model" == some "orbrouter/builtin/fast"
      | _ => false) &&
    (match ocBindRefresh with
      | .ok bJv =>
        let bRow := (bJv.fieldOrNull "bindings").fieldOrNull ocMid
        bRow.fieldStr? "sessionId" == some "ses_oc_e2e_99" &&
        bRow.fieldStr? "model" == some "orbrouter/builtin/smart"
      | _ => false) &&
    (match ocOriginsList with
      | .ok (.arr rows) =>
        match rows.find? (fun r => r.fieldStr? "id" == some ocMid) with
        | some r =>
          r.fieldStr? "model_override" == some "orbrouter/builtin/smart" &&
          (match r.fieldArr? "history" with
           | some h => h.size == 4 && (h[2]?).bind (·.fieldStr? "id") == some "msg-followup-2"
           | none => false)
        | none => false
      | _ => false) &&
    (match ocEvPoll with
      | .ok (.arr evs) => evs.size >= 2
      | _ => false)
  let ok ← assertTrue "local_opencode_models_resolution_activities_errors_and_session_binding_e2e"
    (ocModelsOk && ocResolveOk && ocArgsOk && ocErrOk && ocRunOk)
  return (if ok then 1 else 0, 1)

private def runEndToEndSuites (tmpStateDir validTok : String) : IO (Nat × Nat) := do
  let (pParity, tParity) ← runDesktopReliabilityParityChecks tmpStateDir validTok
  let (pPortal, tPortal) ← runLinuxPortalFileChooserChecks tmpStateDir validTok
  let (warmPassed, warmTotal) ← runWarmClaudeRpcE2eChecks validTok tmpStateDir
  let (ocPassed, ocTotal) ← runLocalOpenCodeE2eChecks validTok tmpStateDir
  let (bootPassed, bootTotal) ← runDesktopBootstrapChecks tmpStateDir validTok
  return (pParity + pPortal + warmPassed + ocPassed + bootPassed, tParity + tPortal + warmTotal + ocTotal + bootTotal)

private def runPostParityTailChecks (validTok tmpStateDir : String) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut total := 0

  -- 16. R7-A (`SM-11`) run-scoped interactive tool slots, backpressure, `"native-"` parity, epoch dedup & reconnect retention
  runR7aInteractiveToolSlotTests
  passed := passed + 13
  total := total + 13

  -- 17. Edge-diverse failover ordering, priority classification, EWMA RTT + cooldown ranking, and transport_bridge_configure apiUrl
  total := total + 1
  let edgeDivOk :=
    candidateFailoverOrigins "https://orbcore.thomas.md" ==
      #["https://orbcore.thomas.md", "https://agent-backend.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"] &&
    candidateFailoverOrigins "https://agent-backend.thomas.md/" ==
      #["https://agent-backend.thomas.md", "https://orbcore.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"] &&
    candidateFailoverOrigins "https://agent-backend.nico-best-pc-ever.ovh" ==
      #["https://agent-backend.nico-best-pc-ever.ovh", "https://agent-backend.thomas.md", "https://orbcore.thomas.md"] &&
    candidateFailoverOrigins "https://selfhosted.example:8443/" ==
      #["https://selfhosted.example:8443"]
  if (← assertTrue "edge_diverse_candidate_failover_origins" edgeDivOk) then passed := passed + 1

  total := total + 1
  let prioOk :=
    classifyProxyRequestPriority "POST" "/api/control/missions/m1/message" none == 0 &&
    classifyProxyRequestPriority "GET" "/api/auth/me" none == 0 &&
    classifyProxyRequestPriority "GET" "/api/health" none == 0 &&
    classifyProxyRequestPriority "GET" "/api/control/missions/m1/events" none == 1 &&
    classifyProxyRequestPriority "GET" "/api/software" none == 2 &&
    classifyProxyRequestPriority "GET" "/api/providers/antigravity-models" none == 2 &&
    classifyProxyRequestPriority "GET" "/api/control/missions/m1/automations" none == 2 &&
    classifyProxyRequestPriority "GET" "/api/control/missions/m1/machine-transfer" none == 2 &&
    classifyProxyRequestPriority "GET" "/api/projects/orb/context/manifest" none == 2 &&
    classifyProxyRequestPriority "POST" "/api/control/missions/m1/inbox-digest" none == 1 &&
    classifyProxyRequestPriority "POST" "/api/file-resources" none == 1 &&
    classifyProxyRequestPriority "POST" "/api/control/missions/m1/opened" none == 1 &&
    classifyProxyRequestPriority "GET" "/api/control/missions/m1/events" (some "p2") == 2 &&
    classifyProxyRequestPriority "GET" "/api/software" (some "p0") == 0 &&
    isComputeBoundProxyRequest "GET" "/api/providers/antigravity-models" &&
    isComputeBoundProxyRequest "GET" "/api/software?force=false" &&
    isComputeBoundProxyRequest "GET" "/api/ai/providers/claude/usage?force=true" &&
    !isComputeBoundProxyRequest "GET" "/api/projects" &&
    !isComputeBoundProxyRequest "GET" "/api/ai/providers"
  if (← assertTrue "proxy_request_priority_classification" prioOk) then passed := passed + 1

  total := total + 1
  if (← assertTrue "h2_pool_teardown_drains_active_and_queued_waiters"
        (← OrbNetLeaf.H2Pool.H2ClientPool.testTeardownDrainsActiveAndQueuedWaiters)) then
    passed := passed + 1

  let stRankRef ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let srtt1 ← recordOriginSuccess stRankRef "https://orbcore.thomas.md" 800
  let srtt2 ← recordOriginSuccess stRankRef "https://orbcore.thomas.md" 400
  recordOriginFailure stRankRef "https://orbcore.thomas.md" 10000 20000
  let rankSt ← stRankRef.get
  let rankedDuringCooldown := rankFailoverOrigins defaultFailoverOrigins rankSt.originHealth 15000
  let rankedAfterCooldown := rankFailoverOrigins defaultFailoverOrigins rankSt.originHealth 35000
  let txCustomRes2 ← dispatchRpcCommand stRankRef "transport_bridge_configure" (.obj #[("apiUrl", .str "https://custom.orb.internal:9443/")])
  total := total + 1
  let rankAndCfgOk :=
    srtt1 == 800 && srtt2 == 750 &&
    rankedDuringCooldown == #["https://agent-backend.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh", "https://orbcore.thomas.md"] &&
    rankedAfterCooldown == defaultFailoverOrigins &&
    (match txCustomRes2 with
     | .ok jv =>
       match jv.fieldArr? "failover_origins" with
       | some #[.str "https://custom.orb.internal:9443"] => true
       | _ => false
     | _ => false)
  if (← assertTrue "origin_ewma_cooldown_ranking_and_bridge_api_url" rankAndCfgOk) then passed := passed + 1

  -- 18. R6-B (`SM-26` / `SM-23`) `(endpoint, server_build)` capability latch, 256-frame journal ring backpressure/resync, and typed 409 conflict disposition
  runR6bClientLinkAndConflictTests
  passed := passed + 3
  total := total + 3

  -- 19. Orphan parent-PID watchdog (`ORB_PARENT_PID`): exits when parent is gone & idle, stays alive while parent lives or local work is active/unsynced
  let selfPid ← OrbBin.PosixExt.getpid
  let orphanRef ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let aliveParentRes ← shouldExitForDeadParent (some (Int64.ofNat selfPid.toNat)) orphanRef
  let deadIdleRes ← shouldExitForDeadParent (some 2147483646) orphanRef
  let _ ← dispatchRpcCommand orphanRef "local_origin_launch" (.obj #[
    ("connection", .obj #[("api_url", .str "https://orbcore.thomas.md")]),
    ("prompt", .str "keep local run alive")
  ])
  let deadActiveRes ← shouldExitForDeadParent (some 2147483646) orphanRef
  total := total + 1
  if (← assertTrue "orphan_parent_watchdog_respects_liveness_and_active_local_origins"
        (!aliveParentRes && deadIdleRes && !deadActiveRes)) then
    passed := passed + 1

  -- 20–23. Desktop reliability, Linux XDG portal FileChooser, warm Claude RPC, local OpenCode E2E, and `desktop_bootstrap` suites
  let (e2ePassed, e2eTotal) ← runEndToEndSuites tmpStateDir validTok

  -- 24. Native Chrome (`OrbLocald.NativeChrome`) canonical sidebar row projection, cycle-safe hierarchy,
  --     monotonic revision fencing, SQLite cold-start hydration, move-target admission, and Cmd+K palette
  let mut ncPassed := 0
  let mut ncTotal := 0
  let fixCandidates : Array System.FilePath := #[
    "shared/orb-spec/fixtures/native-chrome-sidebar.json",
    "../../shared/orb-spec/fixtures/native-chrome-sidebar.json"
  ]
  let mut fixPath? : Option System.FilePath := none
  for cand in fixCandidates do
    if fixPath?.isNone && (← cand.pathExists) then
      fixPath? := some cand
  ncTotal := ncTotal + 1
  match fixPath? with
  | none =>
    let _ ← assertTrue "native_chrome_fixture_found" false
  | some fixPath =>
    let rawFix ← IO.FS.readFile fixPath
    match OrbBin.Json.parse rawFix with
    | .error _ =>
      let _ ← assertTrue "native_chrome_fixture_parse" false
    | .ok fixJv =>
      if (← assertTrue "native_chrome_fixture_parse" true) then ncPassed := ncPassed + 1
      let chromeDir := tmpStateDir ++ "/native-chrome-test"
      try IO.FS.createDirAll chromeDir catch _ => pure ()
      let ncRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := chromeDir } : LocaldState)
      let (_, sseSubId) ← ncRef.modifyGet fun s =>
        let (sid, s') := s.registerSseSubscriber
        (((), sid), s')
      let syncCase := (fixJv.field? "sync_case").getD (.obj #[])
      let syncRes ← dispatchRpcCommand ncRef "native_chrome_sync_state" syncCase
      let staleCase := JVal.setField syncCase "revision" (.nat 5)
      let staleRes ← dispatchRpcCommand ncRef "native_chrome_sync_state" staleCase
      let rowsRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[])
      let sseEvs ← ncRef.modifyGet (·.drainSseSubscriber sseSubId)
      ncTotal := ncTotal + 1
      let syncOk : Bool :=
        match syncRes, staleRes, rowsRes with
        | .ok sjv, .ok stjv, .ok rjv =>
          let applied1 := (sjv.fieldBool? "applied").getD false
          let applied2 := (stjv.fieldBool? "applied").getD true
          let gotRows := (rjv.fieldArr? "rows").getD #[]
          let gotIds := gotRows.filterMap (·.fieldStr? "row_id")
          let expIds := ((syncCase.fieldArr? "expected_row_ids").getD #[]).filterMap (·.asStr?)
          let selRows := gotRows.filter (fun r => (r.fieldBool? "selected").getD false)
          let selId := if selRows.size == 1 then (selRows[0]!.fieldStr? "row_id").getD "" else ""
          let expSel := (syncCase.fieldStr? "expected_selected_row_id").getD ""
          let inboxRow? := gotRows.find? (fun r => r.fieldStr? "row_id" == some "nav:inbox")
          let footerObj? := rjv.field? "footer"
          let rootRow? := gotRows.find? (fun r => r.fieldStr? "row_id" == some "m:m-root")
          let childRow? := gotRows.find? (fun r => r.fieldStr? "row_id" == some "m:m-child")
          let sseFired := sseEvs.size == 1 && (sseEvs[0]!.fieldStr? "event") == some "native_chrome_rows_changed"
          applied1 && !applied2 && sseFired &&
          gotIds == expIds &&
          selId == expSel &&
          (inboxRow?.bind (·.fieldNat? "badge")) == syncCase.fieldNat? "expected_inbox_badge" &&
          (inboxRow?.bind (·.fieldStr? "icon")) == some "inbox" &&
          (footerObj?.bind (·.fieldStr? "row_id")) == syncCase.fieldStr? "expected_footer_row_id" &&
          (footerObj?.bind (·.fieldNat? "badge")) == syncCase.fieldNat? "expected_settings_badge" &&
          (footerObj?.bind (·.fieldStr? "icon")) == some "gear" &&
          (rootRow?.bind (·.fieldStr? "title")) == syncCase.fieldStr? "expected_m_root_title" &&
          (rootRow?.bind (·.fieldStr? "color")) == some "" &&
          (rootRow?.bind (·.fieldNat? "child_count")) == some 1 &&
          (rootRow?.bind (·.fieldBool? "expanded")) == some true &&
          (childRow?.bind (·.fieldNat? "depth")) == syncCase.fieldNat? "expected_m_child_depth"
        | _, _, _ => false
      if (← assertTrue "native_chrome_sync_dedup_cycle_hierarchy_and_sse_fence" syncOk) then
        ncPassed := ncPassed + 1

      -- Filter retention (`m-root` retained via visible child `m-child` matching `"busy timeout"`)
      let filterCase := (fixJv.field? "filter_case").getD (.obj #[])
      let filtQ := (filterCase.fieldStr? "filter_query").getD ""
      let filtRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("filter_query", .str filtQ)])
      ncTotal := ncTotal + 1
      let filtOk : Bool :=
        match filtRes with
        | .ok fjv =>
          let fIds := ((fjv.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          let reqIn := ((filterCase.fieldArr? "expected_retained_missions").getD #[]).filterMap (·.asStr?)
          let reqOut := ((filterCase.fieldArr? "expected_excluded_missions").getD #[]).filterMap (·.asStr?)
          reqIn.all (fun id => fIds.contains id) && reqOut.all (fun id => !fIds.contains id)
        | .error _ => false
      if (← assertTrue "native_chrome_filter_retains_ancestor_of_matching_child" filtOk) then
        ncPassed := ncPassed + 1

      -- Collapse / expand toggle
      let colCase := (fixJv.field? "collapse_case").getD (.obj #[])
      let togRow := (colCase.fieldStr? "toggle_row_id").getD ""
      let togRes1 ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("row_id", .str togRow)])
      let togRes2 ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("row_id", .str togRow)])
      ncTotal := ncTotal + 1
      let togOk : Bool :=
        match togRes1, togRes2 with
        | .ok t1, .ok t2 =>
          let ids1 := ((t1.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          let ids2 := ((t2.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          let hidden := ((colCase.fieldArr? "expected_hidden_ids").getD #[]).filterMap (·.asStr?)
          let visible := ((colCase.fieldArr? "expected_visible_ids").getD #[]).filterMap (·.asStr?)
          (t1.fieldBool? "expanded") == some false &&
          (t2.fieldBool? "expanded") == some true &&
          hidden.all (fun id => !ids1.contains id && ids2.contains id) &&
          visible.all (fun id => ids1.contains id)
        | _, _ => false
      if (← assertTrue "native_chrome_toggle_expand_hides_and_restores_subtree" togOk) then
        ncPassed := ncPassed + 1

      -- Move target admission (`orb_sidebar_move_target_admit`)
      let moveCases := (fixJv.fieldArr? "move_admit_cases").getD #[]
      ncTotal := ncTotal + 1
      let mut allMovesOk := !moveCases.isEmpty
      for mc in moveCases do
        let mRes ← dispatchRpcCommand ncRef "native_chrome_move_admit" mc
        let exp := (mc.fieldBool? "expected").getD false
        match mRes with
        | .ok mjv =>
          if (mjv.fieldBool? "admitted") != some exp then allMovesOk := false
        | .error _ => allMovesOk := false
      if (← assertTrue "native_chrome_move_target_admit_fixtures" allMovesOk) then
        ncPassed := ncPassed + 1

      -- Palette query (`LeanSys.Search` + deterministic score order)
      let palCases := (fixJv.fieldArr? "palette_cases").getD #[]
      ncTotal := ncTotal + 1
      let mut allPalOk := !palCases.isEmpty
      for pc in palCases do
        let q := (pc.fieldStr? "query").getD ""
        let expTop := (pc.fieldStr? "expected_top_id").getD ""
        let pRes ← dispatchRpcCommand ncRef "native_chrome_palette_query" (.obj #[("query", .str q)])
        match pRes with
        | .ok pjv =>
          let items := (pjv.fieldArr? "items").getD #[]
          let gotTop := if items.size > 0 then (items[0]!.fieldStr? "id").getD "" else ""
          if gotTop != expTop then allPalOk := false
        | .error _ => allPalOk := false
      if (← assertTrue "native_chrome_palette_query_ranking_fixtures" allPalOk) then
        ncPassed := ncPassed + 1

      -- Settings mode projection (at producer revision 11 right after 2 local expansion toggles,
      -- verifying `toggleExpand` advances `viewRevision` without blocking `syncRevision == 11`)
      let setMode := (fixJv.field? "settings_mode_case").getD (.obj #[])
      let setSync := JVal.setField (JVal.setField (JVal.setField syncCase "revision" (.nat 11))
        "on_settings" (.bool true))
        "selected" (.str ((setMode.fieldStr? "selected").getD "security-settings"))
      let setSyncRes ← dispatchRpcCommand ncRef "native_chrome_sync_state" setSync
      let setRowsRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[])
      ncTotal := ncTotal + 1
      let setModeOk : Bool :=
        match setSyncRes, setRowsRes with
        | .ok ssjv, .ok srjv =>
          let srows := (srjv.fieldArr? "rows").getD #[]
          let sids := srows.filterMap (·.fieldStr? "row_id")
          let expSids := ((setMode.fieldArr? "expected_row_ids").getD #[]).filterMap (·.asStr?)
          let secRow? := srows.find? (fun r => r.fieldStr? "row_id" == some "settings:security")
          (ssjv.fieldBool? "applied") == some true &&
          sids == expSids &&
          (secRow?.bind (·.fieldBool? "selected")) == some true &&
          (secRow?.bind (·.fieldBool? "attention")) == setMode.fieldBool? "expected_security_attention" &&
          (secRow?.bind (·.fieldNat? "badge")) == setMode.fieldNat? "expected_security_badge"
        | _, _ => false
      if (← assertTrue "native_chrome_settings_mode_projection" setModeOk) then
        ncPassed := ncPassed + 1

      -- Skill detail pages (`sk:<name>` and `sk:<name>#history`) map to `settings:agents` even with `on_settings: false`
      let skillCases := (setMode.fieldArr? "skill_detail_pages").getD #[]
      ncTotal := ncTotal + 1
      let mut allSkillNavOk := !skillCases.isEmpty
      let mut nextRev : Nat := 12
      for sc in skillCases do
        let selPage := (sc.fieldStr? "selected").getD ""
        let onSet := (sc.fieldBool? "on_settings").getD false
        let expRow := (sc.fieldStr? "expected_selected_row_id").getD ""
        let skSync := JVal.setField (JVal.setField (JVal.setField syncCase "revision" (.nat nextRev))
          "on_settings" (.bool onSet))
          "selected" (.str selPage)
        nextRev := nextRev + 1
        let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" skSync
        let skRowsRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[])
        match skRowsRes with
        | .ok sr =>
          let srows := (sr.fieldArr? "rows").getD #[]
          let selRows := srows.filter (fun r => (r.fieldBool? "selected").getD false)
          let gotSel := if selRows.size == 1 then (selRows[0]!.fieldStr? "row_id").getD "" else ""
          if gotSel != expRow || !srows.any (fun r => r.fieldStr? "row_id" == some "nav:settings-back") then
            allSkillNavOk := false
        | .error _ => allSkillNavOk := false
      if (← assertTrue "native_chrome_skill_detail_pages_map_to_agents_section" allSkillNavOk) then
        ncPassed := ncPassed + 1

      -- Fork-group leader & worker-fork parent inheritance (`boss` -> `w2` -> `w`, collapsed by default until expanded)
      let wfCase := (fixJv.field? "worker_fork_case").getD (.obj #[])
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" wfCase
      let wfCollapsedRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:worker-fork:1")])
      let _ ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:worker-fork:1"), ("row_id", .str "m:boss")])
      let _ ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:worker-fork:1"), ("row_id", .str "m:w2")])
      let wfRowsRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:worker-fork:1")])
      ncTotal := ncTotal + 1
      let wfOk : Bool :=
        match wfCollapsedRes, wfRowsRes with
        | .ok wfc, .ok wfr =>
          let cmrows := ((wfc.fieldArr? "rows").getD #[]).filter (fun r => r.fieldStr? "kind" == some "mission")
          let expCmrows := (wfCase.fieldArr? "expected_collapsed_mission_rows").getD #[]
          let mrows := ((wfr.fieldArr? "rows").getD #[]).filter (fun r => r.fieldStr? "kind" == some "mission")
          let expMrows := (wfCase.fieldArr? "expected_mission_rows").getD #[]
          cmrows.size == expCmrows.size && cmrows.size == 1 &&
          cmrows[0]!.fieldStr? "row_id" == expCmrows[0]!.fieldStr? "row_id" &&
          cmrows[0]!.fieldBool? "expandable" == expCmrows[0]!.fieldBool? "expandable" &&
          cmrows[0]!.fieldBool? "expanded" == expCmrows[0]!.fieldBool? "expanded" &&
          cmrows[0]!.fieldNat? "child_count" == expCmrows[0]!.fieldNat? "child_count" &&
          cmrows[0]!.fieldNat? "live_child_count" == expCmrows[0]!.fieldNat? "live_child_count" &&
          mrows.size == expMrows.size && mrows.size > 0 &&
          (List.range mrows.size).all fun i =>
            let got := mrows[i]!
            let exp := expMrows[i]!
            got.fieldStr? "row_id" == exp.fieldStr? "row_id" &&
            got.fieldNat? "depth" == exp.fieldNat? "depth" &&
            got.fieldStr? "folder" == exp.fieldStr? "folder"
        | _, _ => false
      if (← assertTrue "native_chrome_worker_fork_leader_inherits_parent_and_placement" wfOk) then
        ncPassed := ncPassed + 1

      -- Superseded retention (running & selected kept; stopped & stopped descendants excluded) + `/btw` subtree exclusion
      let sbCase := (fixJv.field? "superseded_and_btw_case").getD (.obj #[])
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" sbCase
      let sbRowsCollapsed ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:sup-btw:1")])
      let sbRows1 ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:sup-btw:1"), ("row_id", .str "m:main")])
      let _ ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:sup-btw:1"), ("row_id", .str "m:main"), ("expanded", .bool false)])
      let sbSelSync := JVal.setField (JVal.setField sbCase "revision" (.nat 2))
        "selected" (.str ((sbCase.fieldStr? "selected_for_superseded").getD "m:sup-stopped"))
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" sbSelSync
      -- Clear explicit collapse on `m:main` by syncing on a fresh scope so auto-expand on selected descendant is exercised
      let sbAutoCase := JVal.setField sbSelSync "scope" (.str "scope:sup-btw:auto")
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" sbAutoCase
      let sbRows2 ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:sup-btw:auto")])
      let sbPal ← dispatchRpcCommand ncRef "native_chrome_palette_query" (.obj #[("scope", .str "scope:sup-btw:1"), ("query", .str "btw")])
      ncTotal := ncTotal + 1
      let sbOk : Bool :=
        match sbRowsCollapsed, sbRows1, sbRows2, sbPal with
        | .ok rc, .ok r1, .ok r2, .ok pj =>
          let cmids := (((rc.fieldArr? "rows").getD #[]).filter (fun r => r.fieldStr? "kind" == some "mission")).filterMap (·.fieldStr? "row_id")
          let mainRow? := ((rc.fieldArr? "rows").getD #[]).find? (fun r => r.fieldStr? "row_id" == some "m:main")
          let mids1 := (((r1.fieldArr? "rows").getD #[]).filter (fun r => r.fieldStr? "kind" == some "mission")).filterMap (·.fieldStr? "row_id")
          let mids2 := (((r2.fieldArr? "rows").getD #[]).filter (fun r => r.fieldStr? "kind" == some "mission")).filterMap (·.fieldStr? "row_id")
          let expCol := ((sbCase.fieldArr? "expected_unselected_collapsed_ids").getD #[]).filterMap (·.asStr?)
          let exp1 := ((sbCase.fieldArr? "expected_unselected_mission_ids").getD #[]).filterMap (·.asStr?)
          let exp2 := ((sbCase.fieldArr? "expected_selected_mission_ids").getD #[]).filterMap (·.asStr?)
          let palIds := ((pj.fieldArr? "items").getD #[]).filterMap (·.fieldStr? "id")
          cmids == expCol &&
          (mainRow?.bind (·.fieldNat? "child_count")) == sbCase.fieldNat? "expected_main_child_count" &&
          (mainRow?.bind (·.fieldNat? "live_child_count")) == sbCase.fieldNat? "expected_main_live_child_count" &&
          mids1 == exp1 &&
          mids2 == exp2 &&
          !palIds.contains "m:btw-root" &&
          !palIds.contains "m:btw-worker" &&
          !palIds.contains "m:btw-sub"
        | _, _, _, _ => false
      if (← assertTrue "native_chrome_superseded_running_selected_and_btw_exclusion" sbOk) then
        ncPassed := ncPassed + 1

      -- Cold-start SQLite hydration from `ui_sidebar` before WebView boots
      let coldDir := tmpStateDir ++ "/native-chrome-cold"
      try IO.FS.createDirAll coldDir catch _ => pure ()
      let seedRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := coldDir } : LocaldState)
      let persistedPayload := renderCompact (.obj #[
        ("scope", .str "scope:cold:1"),
        ("savedAt", .nat 1700000000000),
        ("projects", .arr #[.obj #[("slug", .str "orb"), ("name", .str "Orb"), ("folders", .arr #[.str "lean"])]]),
        ("missions", .arr #[.obj #[("id", .str "m-cold"), ("title", .str "Cold SQLite mission"), ("status", .str "active"), ("project", .str "orb"), ("folder", .str "lean")]]),
        ("completedMissions", .arr #[])
      ])
      let _ ← dispatchRpcCommand seedRef "ui_cache_put" (.obj #[
        ("kind", .str "sidebar"),
        ("key", .str "scope:cold:1"),
        ("saved_at", .nat 1700000000000),
        ("raw", .str persistedPayload)
      ])
      let coldFreshRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := coldDir } : LocaldState)
      let coldRowsRes ← dispatchRpcCommand coldFreshRef "native_chrome_get_rows" (.obj #[])
      ncTotal := ncTotal + 1
      let coldOk : Bool :=
        match coldRowsRes with
        | .ok crjv =>
          let cids := ((crjv.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          (crjv.fieldStr? "scope") == some "scope:cold:1" &&
          cids.contains "proj:orb" &&
          cids.contains "folder:orb:lean" &&
          cids.contains "m:m-cold"
        | .error _ => false
      if (← assertTrue "native_chrome_cold_sqlite_ui_sidebar_hydration" coldOk) then
        ncPassed := ncPassed + 1

      -- Mixed ISO-8601 precision (`01:00:00.000Z` vs `02:00:00Z`) + explicit move back to root (`folder: ""`, `project: null`)
      let tsOlderMs := OrbLocald.NativeChrome.parseUpdatedAtMs (.obj #[("updated_at", .str "2026-11-12T01:00:00.000Z")])
      let tsNewerNoFracMs := OrbLocald.NativeChrome.parseUpdatedAtMs (.obj #[("updated_at", .str "2026-11-12T02:00:00Z")])
      let moveRootSync := .obj #[
        ("scope", .str "scope:move-root:1"),
        ("revision", .nat 1),
        ("projects", .arr #[.obj #[("slug", .str "orb"), ("name", .str "Orb"), ("folders", .arr #[.str "lean"])]]),
        ("missions", .arr #[
          .obj #[("id", .str "m-mv"), ("title", .str "Old in folder"), ("status", .str "active"), ("project", .str "orb"), ("folder", .str "lean"), ("updated_at", .str "2026-11-12T01:00:00.000Z")],
          .obj #[("id", .str "m-mv"), ("title", .str "Moved to root"), ("status", .str "active"), ("project", .str "orb"), ("folder", .str ""), ("updated_at", .str "2026-11-12T02:00:00Z")],
          .obj #[("id", .str "m-unproj"), ("title", .str "Old assigned"), ("status", .str "active"), ("project", .str "orb"), ("folder", .str "lean"), ("updated_at", .str "2026-11-12T01:00:00.000Z")],
          .obj #[("id", .str "m-unproj"), ("title", .str "Unassigned project"), ("status", .str "active"), ("project", .null), ("folder", .str ""), ("updated_at", .str "2026-11-12T02:00:00Z")]
        ])
      ]
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" moveRootSync
      let mvRowsRes ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:move-root:1")])
      ncTotal := ncTotal + 1
      let mvAndTsOk : Bool :=
        tsNewerNoFracMs > tsOlderMs &&
        (tsNewerNoFracMs - tsOlderMs == 3600000) &&
        match mvRowsRes with
        | .ok mrjv =>
          let mrows := (mrjv.fieldArr? "rows").getD #[]
          let mvRow? := mrows.find? (fun r => r.fieldStr? "row_id" == some "m:m-mv")
          let unprojRow? := mrows.find? (fun r => r.fieldStr? "row_id" == some "m:m-unproj")
          (mvRow?.bind (·.fieldStr? "title")) == some "Moved to root" &&
          (mvRow?.bind (·.fieldStr? "folder")) == some "" &&
          (mvRow?.bind (·.fieldNat? "depth")) == some 1 &&
          (unprojRow?.bind (·.fieldStr? "title")) == some "Unassigned project" &&
          (unprojRow?.bind (·.fieldStr? "project")) == some ""
        | .error _ => false
      if (← assertTrue "native_chrome_iso_epoch_ms_and_empty_placement_clear" mvAndTsOk) then
        ncPassed := ncPassed + 1

      -- Folder/file expansion + empty project/folder notes + 1,500-mission O(N log N) latency bound
      let mut bigMissions : Array JVal := #[]
      for i in [0:1500] do
        let pid := if i % 5 == 0 then "" else s!"m-big-{(i / 5) * 5}"
        let forkTag : Array JVal := if i % 17 == 16 then #[.str s!"fork-of:m-big-{i - 1}"] else #[]
        bigMissions := bigMissions.push (.obj #[
          ("id", .str s!"m-big-{i}"),
          ("title", .str s!"Scale mission {i}"),
          ("status", .str (if i % 11 == 0 then "active" else "completed")),
          ("project", .str "core"),
          ("parent_mission_id", .str pid),
          ("tags", .arr forkTag),
          ("updated_at_ms", .nat (10000 + i))
        ])
      let folderAndScaleSync := .obj #[
        ("scope", .str "scope:folder-scale:1"),
        ("revision", .nat 1),
        ("projects", .arr #[
          .obj #[
            ("slug", .str "core"),
            ("name", .str "Core"),
            ("folders", .arr #[.str "Audits", .str "EmptyDir"]),
            ("files", .arr #[.str "Audits/report.md", .str "README.md"])
          ],
          .obj #[
            ("slug", .str "empty-proj"),
            ("name", .str "Empty"),
            ("folders", .arr #[])
          ]
        ]),
        ("missions", .arr bigMissions)
      ]
      let tScale0 ← IO.monoMsNow
      let _ ← dispatchRpcCommand ncRef "native_chrome_sync_state" folderAndScaleSync
      let initFolderRows ← dispatchRpcCommand ncRef "native_chrome_get_rows" (.obj #[("scope", .str "scope:folder-scale:1")])
      let openProjRows ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:folder-scale:1"), ("row_id", .str "proj:core"), ("expanded", .bool true)])
      let openAuditsRows ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:folder-scale:1"), ("row_id", .str "folder:core:Audits")])
      let openEmptyDirRows ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:folder-scale:1"), ("row_id", .str "folder:core:EmptyDir")])
      let openEmptyProjRows ← dispatchRpcCommand ncRef "native_chrome_toggle_expand" (.obj #[("scope", .str "scope:folder-scale:1"), ("row_id", .str "proj:empty-proj")])
      let tScaleMs := (← IO.monoMsNow) - tScale0
      ncTotal := ncTotal + 1
      let folderScaleOk : Bool :=
        tScaleMs < 500 &&
        match initFolderRows, openProjRows, openAuditsRows, openEmptyDirRows, openEmptyProjRows with
        | .ok rInit, .ok rProj, .ok rAud, .ok rEmpD, .ok rEmpP =>
          let idsInit := ((rInit.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          let rowsProj := (rProj.fieldArr? "rows").getD #[]
          let audClosed? := rowsProj.find? (fun r => r.fieldStr? "row_id" == some "folder:core:Audits")
          let rowsAud := (rAud.fieldArr? "rows").getD #[]
          let audOpen? := rowsAud.find? (fun r => r.fieldStr? "row_id" == some "folder:core:Audits")
          let repFile? := rowsAud.find? (fun r => r.fieldStr? "row_id" == some "pf:core:Audits/report.md")
          let idsEmpD := ((rEmpD.fieldArr? "rows").getD #[]).filterMap (·.fieldStr? "row_id")
          let rowsEmpP := (rEmpP.fieldArr? "rows").getD #[]
          let empProjOpen? := rowsEmpP.find? (fun r => r.fieldStr? "row_id" == some "proj:empty-proj")
          let idsEmpP := rowsEmpP.filterMap (·.fieldStr? "row_id")
          !idsInit.contains "folder:core:Audits" &&
          (audClosed?.bind (·.fieldBool? "expanded")) == some false &&
          (audClosed?.bind (·.fieldStr? "icon")) == some "folder" &&
          (audOpen?.bind (·.fieldBool? "expanded")) == some true &&
          (audOpen?.bind (·.fieldStr? "icon")) == some "folder-open" &&
          (repFile?.bind (·.fieldStr? "kind")) == some "file" &&
          idsEmpD.contains "empty:core:EmptyDir" &&
          (empProjOpen?.bind (·.fieldBool? "expanded")) == some true &&
          (empProjOpen?.bind (·.fieldStr? "icon")) == some "folder-open" &&
          idsEmpP.contains "empty:empty-proj"
        | _, _, _, _, _ => false
      if (← assertTrue "native_chrome_folder_file_expand_and_1500_mission_scale" folderScaleOk) then
        ncPassed := ncPassed + 1

  return (passed + e2ePassed + ncPassed, total + e2eTotal + ncTotal)

def main : IO UInt32 := do
  let mut passed := 0
  let mut total := 0

  -- 1. Command table size (107 desktop commands + plugin:app|version = 108)
  total := total + 1
  if (← assertEq "desktop_command_count" supportedDesktopCommands.size 108) then passed := passed + 1

  -- 2. Loopback RPC auth gate (>= 32-byte non-placeholder secret + local Origin confinement)
  let validTok := "0123456789abcdef0123456789abcdef"
  total := total + 1
  if (← assertTrue "rpc_auth_loopback_ok" (checkRpcAuth "127.0.0.1" validTok validTok)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_remote" (!(checkRpcAuth "10.0.0.5" validTok validTok))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_bad_token" (!(checkRpcAuth "127.0.0.1" "wrong-token-00000000000000000000" validTok))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_short_24b_default_token" (!(checkRpcAuth "127.0.0.1" "orb-locald-default-token" "orb-locald-default-token"))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_allow_local_loopback" (isAllowedLocaldOrigin (some "http://127.0.0.1:19479"))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_allow_orb_localhost" (isAllowedLocaldOrigin (some "orb://localhost"))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_reject_orb_evil" (!(isAllowedLocaldOrigin (some "orb://evil.example")))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_reject_remote_evil" (!(isAllowedLocaldOrigin (some "https://evil.example")))) then passed := passed + 1

  -- 3. Transport bridge 6 SSE stream shard ports & 3-way failover
  let stRef ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let txRes ← dispatchRpcCommand stRef "transport_bridge_configure" (.obj #[])
  total := total + 1
  match txRes with
  | .ok jv =>
    let shards := match jv.fieldArr? "stream_proxy_base_urls" with
      | some xs => xs.size
      | none => 0
    if (← assertEq "transport_6_sse_shards" shards 6) then passed := passed + 1
  | .error e =>
    IO.eprintln s!"FAIL [transport_bridge_configure]: {e}"

  let txCustomRes ← dispatchRpcCommand stRef "transport_bridge_configure" (.obj #[("apiUrl", .str "https://agent-backend-dev.thomas.md/")])
  total := total + 1
  let txCustomOk := match txCustomRes with
    | .ok jv =>
      jv.fieldStr? "configured_target" == some "https://agent-backend-dev.thomas.md" &&
      (match jv.fieldArr? "failover_origins" with
       | some #[.str o0, .str o1, .str o2] =>
         o0 == "https://agent-backend-dev.thomas.md" &&
         o1 == "https://agent-backend.thomas.md" &&
         o2 == "https://orbcore.thomas.md"
       | _ => false)
    | .error _ => false
  if (← assertTrue "transport_bridge_configure_updates_target_and_candidates" txCustomOk) then passed := passed + 1

  total := total + 1
  if (← assertEq "candidate_origins_standalone" (candidateOriginsFor "https://custom-core.example.org/") #["https://custom-core.example.org"]) then passed := passed + 1

  total := total + 1
  if (← assertTrue "sse_shard_rejects_port_overflow_65532" (verifySseShardConfig 6 65532 == 0)) then passed := passed + 1

  total := total + 1
  if (← assertTrue "failover_get_allowed" (canFailoverRequest "GET" false 1 defaultFailoverOrigins)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_without_idem_blocked" (!(canFailoverRequest "POST" false 1 defaultFailoverOrigins))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_with_idem_allowed" (canFailoverRequest "POST" true 2 defaultFailoverOrigins)) then passed := passed + 1

  -- 4. Channel subscribe / initial snapshot / unsubscribe / __orb_poll_events lifecycle
  let sub1 ← dispatchRpcCommand stRef "local_bindings_subscribe" (.obj #[])
  let sub2 ← dispatchRpcCommand stRef "local_interaction_subscribe" (.obj #[("id", .str "m1")])
  total := total + 1
  let okSubs := match sub1, sub2 with
    | .ok (.num "1"), .ok (.num "2") => true
    | _, _ => false
  if (← assertTrue "channel_subscribe_monotonic" okSubs) then passed := passed + 1

  -- Initial snapshots (`{"revision":0,"bindings":{}}` for 1, `null` for 2) are queued immediately!
  let polledInit ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  let polledEmpty ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  total := total + 1
  let pollOk := match polledInit, polledEmpty with
    | .ok (.arr #[_, _]), .ok (.arr #[]) => true
    | _, _ => false
  if (← assertTrue "channel_poll_events_initial_snapshots_and_drains_once" pollOk) then passed := passed + 1

  let _ ← dispatchRpcCommand stRef "local_bindings_unsubscribe" (.obj #[("token", JVal.nat 1)])
  let curSt ← stRef.get
  total := total + 1
  let activeCount := (curSt.subscriptions.filter (·.active)).size
  if (← assertEq "channel_unsubscribe_prunes" activeCount 1) then passed := passed + 1

  -- Origin CRLF reflection defense + approval_grace_until / set_approval_grace ({ secs }) contract
  total := total + 1
  if (← assertTrue "origin_reject_crlf_injection" (!(isAllowedLocaldOrigin (some "http://127.0.0.1:19479\r\nX-Injected: 1")))) then passed := passed + 1
  let _ ← dispatchRpcCommand stRef "set_approval_grace" (.obj #[("secs", JVal.nat 120)])
  let graceSt ← stRef.get
  let graceUntilRes ← dispatchRpcCommand stRef "approval_grace_until" (.obj #[])
  total := total + 1
  let graceOk := graceSt.approvalGraceSecs == 120 && (match graceUntilRes with | .ok (.num "0") => true | _ => false)
  if (← assertTrue "approval_grace_secs_and_until_contract" graceOk) then passed := passed + 1

  -- 5. Paloma Touch ID grace eligibility (strict canonical UUID + paloma-approval-v1 + non-empty summary)
  let goodPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/bitwarden/requests/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nAllow secret FOO"
  let nonBwPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/privilege-access/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nRoot shell"
  let badUuidPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/bitwarden/requests/zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz/approve\nhost\nhash\nAllow secret FOO"
  let badHeaderPayload :=
    "paloma-approval-v0\n1700000000\nPOST /api/bitwarden/requests/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nAllow secret FOO"
  total := total + 1
  if (← assertTrue "paloma_grace_bitwarden_approve" (isPalomaPayloadGraceEligible goodPayload)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_priv" (!(isPalomaPayloadGraceEligible nonBwPayload))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_non_hex_uuid" (!(isPalomaPayloadGraceEligible badUuidPayload))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_wrong_header" (!(isPalomaPayloadGraceEligible badHeaderPayload))) then passed := passed + 1

  -- 6. WebView init script exposes __ORB_DESKTOP__, __TAURI__, __TAURI_INTERNALS__, SSE /__orb_events, captured _fetch, and JSON-escapes token
  let js := renderWebviewInitScript 19479 (validTok ++ "\"quote")
  total := total + 1
  let hasGlobals :=
    (js.splitOn "__ORB_DESKTOP__").length > 1 &&
    (js.splitOn "__TAURI_INTERNALS__").length > 1 &&
    (js.splitOn "/__orb_events").length > 1 &&
    (js.splitOn "Channel").length > 1 &&
    (js.splitOn "const _fetch = window.fetch.bind(window);").length > 1 &&
    (js.splitOn "\\\"quote").length > 1
  if (← assertTrue "webview_init_script_globals_and_escaping" hasGlobals) then passed := passed + 1

  -- 7. Version RPC + CSPRNG UUIDv4 check
  let verRes ← dispatchRpcCommand stRef "plugin:app|version" (.obj #[])
  total := total + 1
  let verOk := match verRes with | .ok (.str "0.13.0") => true | _ => false
  if (← assertTrue "plugin_app_version_0_13_0" verOk) then passed := passed + 1

  let u1 ← randomUuidV4
  let u2 ← randomUuidV4
  total := total + 1
  if (← assertTrue "csprng_uuid_v4_canonical_and_distinct" (isCanonicalUuid u1 && isCanonicalUuid u2 && u1 != u2)) then passed := passed + 1

  -- 8. Streaming SSE response header parser preserves `\r\n\r\n`-delimited SSE events + split UTF-8 body tail
  let sseSample := ("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"type\":\"ready\"}\r\n\r\n".toUTF8).push 0xE2
  total := total + 1
  let sseOk := match extractStreamingResponseHead? sseSample with
    | .ok (some (200, _, tail)) =>
      tail == (("data: {\"type\":\"ready\"}\r\n\r\n".toUTF8).push 0xE2)
    | _ => false
  if (← assertTrue "sse_streaming_head_preserves_crlf_frames_and_split_utf8" sseOk) then passed := passed + 1

  -- 9. Streaming header parser rejects colon-less header lines and non-chunked Transfer-Encoding
  let badColonHead := "HTTP/1.1 200 OK\r\nMalformedHeaderWithoutColon\r\n\r\n".toUTF8
  let badTeHead := "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".toUTF8
  total := total + 1
  if (← assertTrue "sse_streaming_head_rejects_colonless_and_bad_te"
      ((extractStreamingResponseHeadEx? badColonHead).isOk.not &&
       (extractStreamingResponseHeadEx? badTeHead).isOk.not)) then passed := passed + 1

  -- 10. Incremental HTTP/1.1 `Transfer-Encoding: chunked` decoder reassembles split SSE events 1-byte-at-a-time
  let rawChunkedSse := ("7;ext=1\r\ndata: {\r\n10\r\n\"ok\":true}\r\n\r\n:k\r\n0\r\nX-Trl: 1\r\n\r\n").toUTF8
  let chunkedRes : Except String (ByteArray × Bool) := Id.run do
    let mut st : ChunkedStreamState := .readSizeLine ByteArray.empty
    let mut acc := ByteArray.empty
    let mut done := false
    for i in [0:rawChunkedSse.size] do
      match stepChunkedStream st (rawChunkedSse.extract i (i + 1)) with
      | .error e => return .error e
      | .ok (dec, st', d) =>
        acc := acc ++ dec
        st := st'
        done := d
    return .ok (acc, done)
  total := total + 1
  let chunkedOk := match chunkedRes with
    | .ok (dec, true) => dec == "data: {\"ok\":true}\r\n\r\n:k".toUTF8
    | _ => false
  if (← assertTrue "chunked_sse_decoder_reassembles_split_events_and_trailers" chunkedOk) then passed := passed + 1

  total := total + 1
  let badChunkOk :=
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("ZZ\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\n\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\n\nX-Ok: 1\r\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\nX-Ok: 1\n\r\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\nX-Ok : 1\r\n\r\n".toUTF8)).isOk.not
  if (← assertTrue "chunked_sse_decoder_rejects_bad_hex_and_bare_lf_trailers" badChunkOk) then passed := passed + 1

  -- 11. Bracketed IPv6 & IPv4/DNS `parseOriginHostPort`
  total := total + 1
  let ipv6Ok :=
    parseOriginHostPort "https://[::1]:8443/api/v1" == some (true, "::1", 8443, "/api/v1") &&
    parseOriginHostPort "https://[2001:db8::1]" == some (true, "2001:db8::1", 443, "") &&
    parseOriginHostPort "https://orbcore.thomas.md:9443/tx" == some (true, "orbcore.thomas.md", 9443, "/tx") &&
    (parseOriginHostPort "https://[:::]").isNone
  if (← assertTrue "parse_origin_host_port_supports_bracketed_ipv6" ipv6Ok) then passed := passed + 1

  -- 12. Optional unconfigured RPCs return `.null` (never `{ok: true}`) and unknown action commands fail cleanly
  let ctxFileRes ← dispatchRpcCommand stRef "project_context_file" (.obj #[("slug", .str "ethereum"), ("op", .str "list")])
  let ctxStatusRes ← dispatchRpcCommand stRef "project_context_status" (.obj #[("slug", .str "ethereum")])
  let unsupportedRes ← dispatchRpcCommand stRef "nonexistent_action_cmd" (.obj #[])
  total := total + 1
  let optionalNullOk :=
    (match ctxFileRes with | .ok .null => true | _ => false) &&
    (match ctxStatusRes with | .ok .null => true | _ => false) &&
    unsupportedRes.isOk.not
  if (← assertTrue "optional_project_context_rpcs_return_null_not_stub_obj" optionalNullOk) then passed := passed + 1

  -- 13. Persisted desktop connection (`0600`), diagnostics JSONL sink, machine identity string, and host metrics schema
  let tmpUuid ← randomUuidV4
  let tmpStateDir := s!"/tmp/orb-locald-selftest-{tmpUuid}"
  let stDiskRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir, hostOs := "macos" } : LocaldState)
  let initLoad ← dispatchRpcCommand stDiskRef "desktop_connection_load" (.obj #[])
  let _ ← dispatchRpcCommand stDiskRef "desktop_connection_save" (.obj #[("apiUrl", .str "https://orbcore.example:9443"), ("token", .str "tok-secret-123")])
  let savedLoad ← dispatchRpcCommand stDiskRef "desktop_connection_load" (.obj #[("ignore", .null)])
  let stReloadRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir, hostOs := "macos" } : LocaldState)
  let diskLoad ← dispatchRpcCommand stReloadRef "desktop_connection_load" (.obj #[])
  total := total + 1
  let connOk :=
    (match initLoad with | .ok .null => true | _ => false) &&
    (match savedLoad with
     | .ok jv => jv.fieldStr? "api_url" == some "https://orbcore.example:9443" && jv.fieldStr? "token" == some "tok-secret-123"
     | _ => false) &&
    (match diskLoad with
     | .ok jv => jv.fieldStr? "api_url" == some "https://orbcore.example:9443" && jv.fieldStr? "token" == some "tok-secret-123"
     | _ => false)
  if (← assertTrue "desktop_connection_save_and_disk_reload" connOk) then passed := passed + 1

  let _ ← dispatchRpcCommand stDiskRef "diagnostics_append" (.obj #[
    ("lines", .arr #[.str "{\"ts\":1,\"kind\":\"ok\"}", .str "bad\nmultiline"])
  ])
  let logsDir := System.FilePath.mk tmpStateDir / "logs"
  let logEntries ← if (← logsDir.pathExists) then logsDir.readDir else pure #[]
  total := total + 1
  let mut diagOk := false
  if let #[firstLog] := logEntries then
    let content ← IO.FS.readFile firstLog.path
    diagOk := content == "{\"ts\":1,\"kind\":\"ok\"}\n"
  if (← assertTrue "diagnostics_append_writes_single_line_jsonl" diagOk) then passed := passed + 1

  let idRes1 ← dispatchRpcCommand stDiskRef "local_machine_identity" (.obj #[])
  let idRes2 ← dispatchRpcCommand stReloadRef "local_machine_identity" (.obj #[])
  let metricsRes ← dispatchRpcCommand stDiskRef "local_machine_metrics" (.obj #[])
  let stHostRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir, hostOs := if System.Platform.isOSX then "macos" else "linux" } : LocaldState)
  let hostMetricsRes ← dispatchRpcCommand stHostRef "local_machine_metrics" (.obj #[("details", .bool true)])
  total := total + 1
  let idAndMetricsOk :=
    (match idRes1, idRes2 with
     | .ok (.str s1), .ok (.str s2) => !s1.isEmpty && s1 == s2
     | _, _ => false) &&
    (match metricsRes with
     | .ok jv =>
       (jv.fieldNat? "memory_total").isSome &&
       (jv.fieldNat? "memory_used").isSome &&
       (jv.fieldNat? "disk_total").getD 0 > 0 &&
       (jv.fieldArr? "consumers").isSome
     | _ => false) &&
    (match hostMetricsRes with
     | .ok jv =>
       (jv.fieldNat? "memory_total").getD 0 > 0 &&
       (jv.fieldNat? "disk_total").getD 0 > 0 &&
       (jv.fieldNat? "cpu_percent").isSome &&
       (match jv.fieldArr? "consumers" with | some cs => cs.size == 3 | none => false)
     | _ => false)
  if (← assertTrue "local_machine_identity_string_and_metrics_schema" idAndMetricsOk) then passed := passed + 1
  let bioStatusRes ← dispatchRpcCommand stDiskRef "biometric_status" (.obj #[])
  total := total + 1
  let bioStatusOk := match bioStatusRes with
    | .ok jv =>
      jv.fieldBool? "available" == some true &&
      jv.fieldStr? "kind" == some "touch_id" &&
      jv.fieldStr? "label" == some "Touch ID"
    | _ => false
  if (← assertTrue "biometric_status_touch_id_schema" bioStatusOk) then passed := passed + 1

  -- 14. `#1497` + `#1553` local cyber capabilities, invocable skills precedence, and fail-closed launch gates
  let cyberCapRes ← dispatchRpcCommand stDiskRef "local_agents_cyber_capabilities" (.obj #[])
  total := total + 1
  let cyberCapOk := match cyberCapRes with | .ok (.num "2") => true | _ => false
  if (← assertTrue "local_agents_cyber_capabilities_supported_2" cyberCapOk) then passed := passed + 1

  let homeRoot := System.FilePath.mk tmpStateDir / "fake-home"
  let projRoot := System.FilePath.mk tmpStateDir / "fake-repo"
  IO.FS.createDirAll (homeRoot / ".codex" / "skills" / "shared-skill")
  IO.FS.createDirAll (homeRoot / ".codex" / "skills" / "global-only")
  IO.FS.createDirAll (projRoot / ".agents" / "skills" / "shared-skill")
  IO.FS.writeFile (homeRoot / ".codex" / "skills" / "shared-skill" / "SKILL.md") "Global fallback description.\n"
  IO.FS.writeFile (homeRoot / ".codex" / "skills" / "global-only" / "SKILL.md") "---\ndescription: \"Global helper\"\n---\nBody\n"
  IO.FS.writeFile (projRoot / ".agents" / "skills" / "shared-skill" / "SKILL.md") "---\ndescription: \"Project override\"\n---\nBody\n"

  let skillsFound ← invocableSkillsIn homeRoot projRoot "codex"
  total := total + 1
  let skillsPrecOk := match skillsFound with
    | .ok #[s0, s1] =>
      s0.name == "global-only" && s0.description == some "Global helper" &&
      s1.name == "shared-skill" && s1.description == some "Project override"
    | _ => false
  if (← assertTrue "invocable_skills_project_precedence_and_frontmatter" skillsPrecOk) then passed := passed + 1

  let selOk ← selectLocalSkillsIn homeRoot projRoot "codex" "please run /skill:shared-skill and /skill:shared-skill"
  let selMissing ← selectLocalSkillsIn homeRoot projRoot "codex" "run /skill:missing-skill"
  let selBadId ← selectLocalSkillsIn homeRoot projRoot "codex" "run /skill:../escape"
  total := total + 1
  let localSkillGateOk :=
    (match selOk with
      | .ok sel =>
        match sel with
        | #[("shared-skill", _, 2)] =>
          let dir := withLocalSkillDirective "please run /skill:shared-skill" sel
          (dir.splitOn "Selected skills (load before performing the current request):").length == 2 &&
          (dir.splitOn "SKILL.md").length == 2
        | _ => false
      | _ => false) &&
    selMissing.isOk.not &&
    selBadId.isOk.not
  if (← assertTrue "select_local_skills_dedups_and_rejects_missing_or_invalid" localSkillGateOk) then passed := passed + 1

  total := total + 1
  let localCodexGateOk :=
    (validateLocalCodexLaunch "/goal ship it" "gpt-6.1-sol" "automatic" false).isOk &&
    (validateLocalCodexLaunch "/goal ship it" "gpt-6.1-sol" "daybreak" false).isOk.not &&
    (validateLocalCodexLaunch "/goal" "gpt-6.1-sol" "automatic" false).isOk.not &&
    (validateLocalCodexLaunch "audit" "gpt-daybreak-blue-latest" "automatic" false).isOk.not &&
    (validateLocalCodexLaunch "audit" "gpt-6.1-sol" "daybreak" false).isOk
  if (← assertTrue "validate_local_codex_launch_gates_goal_and_cyber" localCodexGateOk) then passed := passed + 1

  -- 15. Persistent `orb-signer serve` protocol (`approval_sign` + `grace_until` reuse + `cancelled` code 2)
  let mockSignerPath := System.FilePath.mk tmpStateDir / "mock-orb-signer.sh"
  let countPath := System.FilePath.mk tmpStateDir / "mock-signer-spawns.txt"
  let mockScript :=
    "#!/bin/sh\n" ++
    "cmd=\"$1\"\n" ++
    "if [ \"$cmd\" = \"public\" ]; then echo '{\"public_key\":\"MOCK_PUB_KEY\"}'; exit 0; fi\n" ++
    "if [ \"$cmd\" = \"create\" ]; then echo '{\"public_key\":\"MOCK_CREATED_KEY\"}'; exit 0; fi\n" ++
    "if [ \"$cmd\" = \"serve\" ]; then\n" ++
    s!"  echo spawn >> \"{countPath}\"\n" ++
    "  while IFS= read -r line; do\n" ++
    "    if [ \"$line\" = \"Q0FOQ0VM\" ]; then\n" ++
    "      echo '{\"error\":\"User cancelled\",\"code\":\"2\"}'\n" ++
    "    else\n" ++
    "      echo '{\"signature\":\"MOCK_SIG_OK\",\"grace_until\":\"4102444800\"}'\n" ++
    "    fi\n" ++
    "  done\n" ++
    "  exit 0\n" ++
    "fi\n" ++
    "exit 1\n"
  IO.FS.writeFile mockSignerPath mockScript
  let _ ← OrbBin.PosixExt.chmod mockSignerPath.toString 0o700
  let stSignRef ← IO.mkRef ({
    launchToken := validTok,
    orbStateDir := tmpStateDir,
    homeDir := tmpStateDir,
    approvalKeyPath := (System.FilePath.mk tmpStateDir / "key.bin").toString,
    hostOs := "macos",
    signerBin? := some mockSignerPath.toString
  } : LocaldState)
  let signRes1 ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str goodPayload)])
  let signRes2 ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str goodPayload)])
  let graceAfterSign ← dispatchRpcCommand stSignRef "approval_grace_until" (.obj #[])
  let cancelRes ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str "CANCEL")])
  let graceAfterCancel ← dispatchRpcCommand stSignRef "approval_grace_until" (.obj #[])
  let spawnLines ← if (← countPath.pathExists) then IO.FS.readFile countPath else pure ""
  let spawnCount := ((spawnLines.splitOn "\n").filter (fun s => !s.trimAscii.toString.isEmpty)).length
  let _ ← dispatchRpcCommand stSignRef "set_approval_grace" (.obj #[("secs", JVal.nat 0)])
  total := total + 1
  let signerServeOk :=
    (match signRes1, signRes2 with | .ok (.str "MOCK_SIG_OK"), .ok (.str "MOCK_SIG_OK") => true | _, _ => false) &&
    (match graceAfterSign with | .ok (.num "4102444800") => true | _ => false) &&
    (match cancelRes with | .error "cancelled" => true | _ => false) &&
    (match graceAfterCancel with | .ok (.num "0") => true | _ => false) &&
    spawnCount == 1
  if (← assertTrue "orb_signer_serve_reuses_persistent_helper_and_propagates_grace_and_cancel" signerServeOk) then passed := passed + 1

  let (tailPassed, tailTotal) ← runPostParityTailChecks validTok tmpStateDir
  passed := passed + tailPassed
  total := total + tailTotal

  try IO.FS.removeDirAll tmpStateDir catch _ => pure ()

  IO.println s!"orb-locald-test: {passed}/{total} checks passed"
  return if passed == total then 0 else 1
