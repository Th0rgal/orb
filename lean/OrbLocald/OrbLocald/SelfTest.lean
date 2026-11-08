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
    (match listRes1 with | .ok (.arr #[jv]) => jv.fieldStr? "id" == some mid && jv.fieldBool? "local_sync_pending" == some true | _ => false) &&
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

def main : IO UInt32 := do
  let mut passed := 0
  let mut total := 0

  -- 1. Command table size (88 desktop commands + plugin:app|version = 89)
  total := total + 1
  if (← assertEq "desktop_command_count" supportedDesktopCommands.size 89) then passed := passed + 1

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
  total := total + 1
  let idAndMetricsOk :=
    (match idRes1, idRes2 with
     | .ok (.str s1), .ok (.str s2) => !s1.isEmpty && s1 == s2
     | _, _ => false) &&
    (match metricsRes with
     | .ok jv =>
       (jv.fieldNat? "memory_total").isSome &&
       (jv.fieldNat? "memory_used").isSome &&
       (jv.fieldArr? "consumers").isSome
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
    classifyProxyRequestPriority "POST" "/api/control/missions/m1/inbox-digest" none == 1 &&
    classifyProxyRequestPriority "POST" "/api/file-resources" none == 1 &&
    classifyProxyRequestPriority "POST" "/api/control/missions/m1/opened" none == 1 &&
    classifyProxyRequestPriority "GET" "/api/control/missions/m1/events" (some "p2") == 2 &&
    classifyProxyRequestPriority "GET" "/api/software" (some "p0") == 0
  if (← assertTrue "proxy_request_priority_classification" prioOk) then passed := passed + 1

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

  try IO.FS.removeDirAll tmpStateDir catch _ => pure ()

  IO.println s!"orb-locald-test: {passed}/{total} checks passed"
  return if passed == total then 0 else 1
