/-
  OrbCore.QueueCont: R3-C / R3-D persistence for row-level control queues (`SM-04`),
  structured deferred batches (`SM-05`), unified `waiting_rate_limit` (`SM-06`),
  generation-fenced `mission_continuations` (`SM-07`), shared reconcile + supervision
  counters (`SM-09`, `SM-01`), typed-placement `beginMissionRun` (`SM-10`), and
  canonical `project_decisions.status` (`SM-13`).
  `0 import Lean`, `0 sorryAx`.
-/
import Orb.Lifecycle
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Store

namespace OrbCore.QueueCont

open Orb.Lifecycle
open Orb.Kernel
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store

def deferredBatchSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS deferred_message_batches (" ++
  "mission_id TEXT NOT NULL, batch_seq INTEGER NOT NULL, message_id TEXT NOT NULL, " ++
  "content TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', unpacked INTEGER NOT NULL DEFAULT 1, " ++
  "created_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(mission_id, batch_seq, message_id));"

def queueReceiptsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS queue_item_receipts (" ++
  "message_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, phase INTEGER NOT NULL DEFAULT 0, " ++
  "claimed_generation INTEGER NOT NULL DEFAULT 0, claim_boot_epoch INTEGER NOT NULL DEFAULT 0, " ++
  "delivered_seq INTEGER NOT NULL DEFAULT 0, edit_revision INTEGER NOT NULL DEFAULT 0, " ++
  "content TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', " ++
  "updated_at TEXT NOT NULL DEFAULT '');"

def continuationsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS mission_continuations (" ++
  "id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, run_generation INTEGER NOT NULL, " ++
  "phase INTEGER NOT NULL DEFAULT 1, due_epoch INTEGER NOT NULL DEFAULT 0, " ++
  "trigger_kind TEXT NOT NULL DEFAULT 'time', reason TEXT NOT NULL DEFAULT '', " ++
  "prompt TEXT NOT NULL DEFAULT '', request_id TEXT NOT NULL DEFAULT '', " ++
  "job_id TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', " ++
  "error TEXT NOT NULL DEFAULT '', recurrence TEXT NOT NULL DEFAULT '', " ++
  "stop_after_first INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', " ++
  "updated_at TEXT NOT NULL DEFAULT '', UNIQUE(mission_id, request_id));"

def supervisionSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS mission_supervision (" ++
  "mission_id TEXT PRIMARY KEY, bg_wait_arms INTEGER NOT NULL DEFAULT 0, " ++
  "stall_consecutive_arms INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');"

def projectDecisionsSchemaSql : String :=
  "CREATE TABLE IF NOT EXISTS project_decisions (" ++
  "id TEXT PRIMARY KEY, project_slug TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', " ++
  "question TEXT NOT NULL DEFAULT '', evidence TEXT NOT NULL DEFAULT '', " ++
  "updated_at TEXT NOT NULL DEFAULT '');"

def queueContSchemaSql : String :=
  deferredBatchSchemaSql ++ queueReceiptsSchemaSql ++ continuationsSchemaSql ++ supervisionSchemaSql

def projectsDecisionsSchemaSql : String :=
  projectDecisionsSchemaSql

def queueContAdditiveAlters : Array String := #[
  "ALTER TABLE missions ADD COLUMN not_before INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE missions ADD COLUMN resume_intent INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN phase INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN claimed_generation INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN claim_boot_epoch INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN delivered_seq INTEGER NOT NULL DEFAULT 0;",
  "ALTER TABLE remote_message_queue ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0;",
  "CREATE UNIQUE INDEX IF NOT EXISTS deferred_message_batches_uuid ON deferred_message_batches(mission_id, message_id);"
]

def projectsDecisionsAdditiveAlters : Array String := #[
  "ALTER TABLE project_decisions ADD COLUMN project_slug TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN status TEXT NOT NULL DEFAULT 'pending';",
  "ALTER TABLE project_decisions ADD COLUMN question TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN evidence TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE project_decisions ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';"
]

def isQueueContIntegerCol (col : String) : Bool :=
  col == "not_before" || col == "resume_intent" || col == "phase" ||
  col == "claimed_generation" || col == "claim_boot_epoch" || col == "delivered_seq" ||
  col == "edit_revision" || col == "batch_seq" || col == "unpacked" ||
  col == "run_generation" || col == "due_epoch" || col == "stop_after_first" ||
  col == "bg_wait_arms" || col == "stall_consecutive_arms"

def missionPhaseOfStatus (status : String) : UInt8 :=
  if status == "awaiting_user" || status == "acknowledged" then 0
  else if status == "active" || status == "pending" then 1
  else if status == "waiting_background" then 2
  else if status == "waiting_rate_limit" then 3
  else if status == "interrupted" || status == "paused" || status == "blocked" then 4
  else if status == "completed" then 5
  else if status == "failed" || status == "not_feasible" then 6
  else if status == "cancelled" then 7
  else 1

def statusOfMissionPhase (phase : UInt8) : String :=
  if phase == 0 then "awaiting_user"
  else if phase == 1 then "active"
  else if phase == 2 then "waiting_background"
  else if phase == 3 then "waiting_rate_limit"
  else if phase == 4 then "interrupted"
  else if phase == 5 then "completed"
  else if phase == 6 then "failed"
  else "cancelled"

def ownerTerminalOfStatus (status : String) : UInt8 :=
  if status == "completed" || status == "failed" || status == "cancelled" || status == "not_feasible" then 1 else 0

def ownerBusyOfStatus (status : String) : UInt8 :=
  if status == "active" || status == "pending" || status == "waiting_background" then 1 else 0

def queuePhaseName (phase : UInt8) : String :=
  if phase == 0 then "queued"
  else if phase == 1 then "claimed"
  else if phase == 2 then "delivered"
  else if phase == 3 then "crash_tombstone"
  else "cancelled"

def wakeupPhaseName (phase : UInt8) : String :=
  if phase == 0 then "disarmed"
  else if phase == 1 then "scheduled"
  else if phase == 2 then "queued"
  else if phase == 3 then "error"
  else "cancelled"

def continuationApiState (phase : UInt8) (triggerKind : String) : String :=
  if phase == 2 then
    if triggerKind == "delivery" then "waiting_for_client" else "queued"
  else if phase == 3 then "error"
  else if phase == 4 || phase == 0 then "cancelled"
  else "scheduled"

structure QueueClaimResult where
  messageId   : String
  missionId   : String
  content     : String
  source      : String
  deliveredSeq : UInt64
  phase        : UInt8
  deriving Repr

inductive QueueStepCode where
  | ok (rec : QueueClaimResult)
  | notFound
  | rejected (reason : String)
  deriving Repr

private def cell (row : Array String) (i : Nat) : String :=
  (row[i]?).getD ""

private def cellNat (row : Array String) (i : Nat) : Nat :=
  (cell row i).toNat?.getD 0

private def changesOf (rows : Array (Array String)) : Nat :=
  ((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0

private def queuePayloadObj (content missionId : String) (source? : Option String) : String :=
  let sourceJson := match source? with | some s => jsonEscape s | none => "null"
  s!"\{\"message\":\{\"id\":\"\",\"content\":{jsonEscape content},\"mission_id\":{jsonEscape missionId},\"source\":{sourceJson}},\"job_id\":null}"

private def queuePayloadContent? (payload : String) : Option String :=
  (OrbBin.Json.parse payload).toOption.bind (·.field? "message") |>.bind (·.fieldStr? "content")

private def queuePayloadSource? (payload : String) : Option String :=
  (OrbBin.Json.parse payload).toOption.bind (·.field? "message") |>.bind (·.fieldStr? "source")

def stripDeferredTrailer (goal : String) : String × Option String :=
  let nlMarker := "\n<!-- sandboxed:messages:v1:"
  let nlParts := goal.splitOn nlMarker
  if nlParts.length ≥ 2 && (nlParts.getLast!).endsWith " -->" then
    let head := String.intercalate nlMarker (nlParts.dropLast)
    let b64 := ((nlParts.getLast!).dropEnd 4).toString
    (head, some b64)
  else
    let marker := "<!-- sandboxed:messages:v1:"
    let parts := goal.splitOn marker
    if parts.length < 2 then
      (goal, none)
    else
      let head := String.intercalate marker (parts.dropLast)
      let tail := parts.getLast!
      if tail.endsWith " -->" then
        let b64 := (tail.dropEnd 4).toString
        (head, some b64)
      else
        (goal, none)

def hasRawDeferredTrailerMarker (s : String) : Bool :=
  (s.splitOn "<!-- sandboxed:messages:v1:").length > 1

private def isCanonicalUuid (s : String) : Bool :=
  (parseUuidCanonical? s) == some s.toLower

def parseDeferredBatch? (b64 : String) : Except String (Array (String × String)) := do
  let some bytes := base64Decode? b64 | throw "deferred_batch_b64"
  let some txt := String.fromUTF8? bytes | throw "deferred_batch_utf8"
  let .ok jv := OrbBin.Json.parse txt | throw "deferred_batch_json"
  let some arr := jv.fieldArr? "messages" | throw "deferred_batch_messages"
  if arr.isEmpty then throw "deferred_batch_empty"
  let mut out : Array (String × String) := #[]
  let mut seen : Array String := #[]
  for item in arr do
    let some pair := item.asArr? | throw "deferred_batch_pair"
    if pair.size < 2 then throw "deferred_batch_pair"
    let some mid := pair[0]!.asStr? | throw "deferred_batch_id"
    let some content := pair[1]!.asStr? | throw "deferred_batch_content"
    let canon := mid.trimAscii.toString.toLower
    if !isCanonicalUuid canon then throw "deferred_batch_uuid"
    if content.trimAscii.toString.isEmpty then throw "deferred_batch_content"
    if hasRawDeferredTrailerMarker content then throw "deferred_batch_nested_trailer"
    if seen.any (· == canon) then throw "deferred_batch_dup"
    seen := seen.push canon
    out := out.push (canon, content)
  return out

def extractDeferredTrailerStrict (raw : String) : Except String (String × Option (Array (String × String))) := do
  let (plain, b64?) := stripDeferredTrailer raw
  match b64? with
  | none =>
    if hasRawDeferredTrailerMarker raw then
      throw "deferred_batch_unterminated"
    return (raw, none)
  | some b64 =>
    if hasRawDeferredTrailerMarker plain then
      throw "deferred_batch_multiple"
    let msgs ← parseDeferredBatch? b64
    return (plain, some msgs)

def persistDeferredBatch
    (st : CoreStore) (missionId source createdAt : String) (msgs : Array (String × String)) :
    IO (Except String Nat) :=
  withImmediateTx st.missionsDb do
    let seqRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(MAX(batch_seq),0) FROM deferred_message_batches WHERE mission_id=?1;" #[missionId]
    let .ok srs := seqRows | return .error "deferred_seq_failed"
    let nextSeq := changesOf srs + 1
    let mut n : Nat := 0
    for (mid, content) in msgs do
      let dup ← execParamQueryUnlocked st.missionsDb
        "SELECT 1 FROM deferred_message_batches WHERE mission_id=?1 AND message_id=?2 LIMIT 1;"
        #[missionId, mid]
      let .ok drs := dup | return .error "deferred_dup_select_failed"
      if drs.size > 1 then return .error "deferred_batch_dup"
      let ins ← execParamQueryUnlocked st.missionsDb
        ("INSERT INTO deferred_message_batches(mission_id,batch_seq,message_id,content,source,unpacked,created_at) " ++
         "VALUES(?1,?2,?3,?4,?5,1,?6);")
        #[missionId, s!"{nextSeq}", mid, content, source, createdAt]
      if let .error e := ins then
        if (e.toLower.splitOn "unique").length > 1 then return .error "deferred_batch_dup"
        return .error e
      n := n + 1
    return .ok n

def unpackDeferredGoal
    (st : CoreStore) (missionId source createdAt : String) : IO (Except String Nat) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(deferred_goal,'') FROM missions WHERE id=?1;" #[missionId]
    let .ok rs := rows | return .error "deferred_goal_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let goal := cell (rs[1]!) 0
    match extractDeferredTrailerStrict goal with
    | .error e => return .error e
    | .ok (_, none) => return .ok 0
    | .ok (stripped, some msgs) =>
        let seqRows ← execParamQueryUnlocked st.missionsDb
          "SELECT COALESCE(MAX(batch_seq),0) FROM deferred_message_batches WHERE mission_id=?1;" #[missionId]
        let .ok srs := seqRows | return .error "deferred_seq_failed"
        let nextSeq := changesOf srs + 1
        for (mid, content) in msgs do
          let dup ← execParamQueryUnlocked st.missionsDb
            "SELECT 1 FROM deferred_message_batches WHERE mission_id=?1 AND message_id=?2 LIMIT 1;"
            #[missionId, mid]
          let .ok drs := dup | return .error "deferred_dup_select_failed"
          if drs.size > 1 then return .error "deferred_batch_dup"
          let ins ← execParamQueryUnlocked st.missionsDb
            ("INSERT INTO deferred_message_batches(mission_id,batch_seq,message_id,content,source,unpacked,created_at) " ++
             "VALUES(?1,?2,?3,?4,?5,1,?6);")
            #[missionId, s!"{nextSeq}", mid, content, source, createdAt]
          if let .error e := ins then
            if (e.toLower.splitOn "unique").length > 1 then return .error "deferred_batch_dup"
            return .error e
        let upd ← execParamQueryUnlocked st.missionsDb
          "UPDATE missions SET deferred_goal=?2 WHERE id=?1;" #[missionId, stripped]
        match upd with
        | .error e => return .error e
        | .ok _ => return .ok msgs.size

def enqueueStructuredFollowup
    (st : CoreStore) (userId messageId missionId content source createdAt : String) :
    IO (Except String String) := do
  match extractDeferredTrailerStrict content with
  | .error e => return .error e
  | .ok (plain, msgs?) =>
    withImmediateTx st.missionsDb do
      let existing ← execParamQueryUnlocked st.missionsDb
        "SELECT payload FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;" #[userId, messageId]
      let .ok ers := existing | return .error "queue_select_failed"
      if ers.size > 1 then
        return .ok ((queuePayloadContent? (cell (ers[1]!) 0)).getD plain)
      let recExisting ← execParamQueryUnlocked st.missionsDb
        "SELECT content FROM queue_item_receipts WHERE message_id=?1;" #[messageId]
      let .ok rers := recExisting | return .error "queue_receipt_select_failed"
      if rers.size > 1 then
        return .ok (cell (rers[1]!) 0)
      if plain.trimAscii.toString.isEmpty then return .error "deferred_batch_content"
      let stored := plain
      let ins ← execParamQueryUnlocked st.missionsDb
        ("INSERT INTO remote_message_queue(user_id,message_id,mission_id,payload,state,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision) " ++
         "VALUES(?1,?2,?3,?4,'waiting',0,0,0,0,0);")
        #[userId, messageId, missionId, queuePayloadObj stored missionId (some source)]
      if let .error e := ins then return .error e
      if let some msgs := msgs? then
        let seqRows ← execParamQueryUnlocked st.missionsDb
          "SELECT COALESCE(MAX(batch_seq),0) FROM deferred_message_batches WHERE mission_id=?1;" #[missionId]
        let .ok srs := seqRows | return .error "deferred_seq_failed"
        let nextSeq := changesOf srs + 1
        for (mid, body) in msgs do
          let dup ← execParamQueryUnlocked st.missionsDb
            "SELECT 1 FROM deferred_message_batches WHERE mission_id=?1 AND message_id=?2 LIMIT 1;"
            #[missionId, mid]
          let .ok drs := dup | return .error "deferred_dup_select_failed"
          if drs.size > 1 then return .error "deferred_batch_dup"
          let bins ← execParamQueryUnlocked st.missionsDb
            ("INSERT INTO deferred_message_batches(mission_id,batch_seq,message_id,content,source,unpacked,created_at) " ++
             "VALUES(?1,?2,?3,?4,?5,1,?6);")
            #[missionId, s!"{nextSeq}", mid, body, source, createdAt]
          if let .error e := bins then
            if (e.toLower.splitOn "unique").length > 1 then return .error "deferred_batch_dup"
            return .error e
      let rec ← execParamQueryUnlocked st.missionsDb
        ("INSERT INTO queue_item_receipts(message_id,mission_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content,source,updated_at) " ++
         "VALUES(?1,?2,0,0,0,0,0,?3,?4,?5) ON CONFLICT(message_id) DO NOTHING;")
        #[messageId, missionId, stored, source, createdAt]
      match rec with
      | .error e => return .error e
      | .ok _ => return .ok stored

private def loadQueueRow
    (st : CoreStore) (userId messageId : String) :
    IO (Except String (Option (Array String))) := do
  let rows ← execParamQueryUnlocked st.missionsDb
    ("SELECT message_id,mission_id,payload,COALESCE(phase,0),COALESCE(claimed_generation,0)," ++
     "COALESCE(claim_boot_epoch,0),COALESCE(delivered_seq,0),COALESCE(edit_revision,0),state " ++
     "FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;")
    #[userId, messageId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok none else return .ok (some (rs[1]!))

def stepQueueItem
    (st : CoreStore) (userId messageId : String) (op : UInt8)
    (runGeneration nodeBootEpoch deliverySeq nowAt : String)
    (uncertain operatorConfirmed : UInt8 := 0) (nextContent : String := "") :
    IO (Except String QueueStepCode) :=
  withImmediateTx st.missionsDb do
    let loaded ← loadQueueRow st userId messageId
    let .ok row? := loaded | return .error "queue_load_failed"
    let some row := row? | return .ok .notFound
    let mid := cell row 1
    let payload := cell row 2
    let phase := cellNat row 3 |>.toUInt8
    let claimedGen := cellNat row 4 |>.toUInt64
    let claimBoot := cellNat row 5 |>.toUInt64
    let delivered := cellNat row 6 |>.toUInt64
    let editRev := cellNat row 7 |>.toUInt32
    let state := cell row 8
    let _ := state
    let content := (queuePayloadContent? payload).getD ""
    let source := (queuePayloadSource? payload).getD ""
    let runGen := (runGeneration.toNat?.getD 0).toUInt64
    let boot := (nodeBootEpoch.toNat?.getD 0).toUInt64
    let seq := (deliverySeq.toNat?.getD 0).toUInt64
    let pendingRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id=?1 AND unpacked=0;" #[mid]
    let .ok prs := pendingRows | return .error "deferred_pending_select_failed"
    let pendingUnpacked := changesOf prs
    let mGoalRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(deferred_goal,'') FROM missions WHERE id=?1;" #[mid]
    let .ok mgrs := mGoalRows | return .error "deferred_goal_select_failed"
    let mGoal := if mgrs.size > 1 then cell (mgrs[1]!) 0 else ""
    let deferred : UInt8 :=
      if hasRawDeferredTrailerMarker content || hasRawDeferredTrailerMarker payload ||
         hasRawDeferredTrailerMarker mGoal || pendingUnpacked > 0 then 0 else 1
    let editContent : Except String String :=
      if op != 6 then .ok content
      else match extractDeferredTrailerStrict nextContent with
        | .error e => .error e
        | .ok (_plain, some _) => .error "deferred_batch_edit_trailer"
        | .ok (plain, none) =>
          if plain.trimAscii.toString.isEmpty then .error "deferred_batch_content" else .ok plain
    let .ok nextPlain := editContent | return .error (match editContent with | .error e => e | .ok _ => "err")
    let (nextSlice, effs) := stepQueueSlice
      { phaseCode := phase, claimedGeneration := claimedGen, claimBootEpoch := claimBoot,
        deliveredSeq := delivered, editRevision := editRev }
      { opCode := op, deferredUnpacked := deferred, durablyStarted := 1,
        uncertainTimeout := (if uncertain == 1 then 1 else 0),
        operatorConfirmedNotDelivered := operatorConfirmed,
        contentNonEmpty := (if nextPlain.trimAscii.toString.isEmpty then 0 else 1),
        runGeneration := runGen, nodeBootEpoch := boot, deliverySeq := seq }
    if effs.isEmpty then
      return .ok (.rejected s!"queue_admit:{phase}:{op}")
    let (nextPhase, nextClaimed, nextSeq) :=
      match effs with
      | .persistQueuePhase ph cg ds :: _ => (ph, cg, ds)
      | _ => (nextSlice.phaseCode, nextSlice.claimedGeneration, nextSlice.deliveredSeq)
    let nextBoot := nextSlice.claimBootEpoch
    let nextEdit : UInt32 := nextSlice.editRevision
    let nextContentStored := if op == 6 then nextPlain else content
    let nextState :=
      if nextPhase == 0 then "waiting"
      else if nextPhase == 1 then "claimed"
      else if nextPhase == 2 then "delivered"
      else if nextPhase == 3 then "crash_tombstone"
      else "cancelled"
    let upd ← execParamQueryUnlocked st.missionsDb
      ("UPDATE remote_message_queue SET phase=?3,claimed_generation=?4,claim_boot_epoch=?5,delivered_seq=?6," ++
       "edit_revision=?7,state=?8,payload=CASE WHEN ?9='' THEN payload ELSE json_set(payload,'$.message.content',?9) END " ++
       "WHERE user_id=?1 AND message_id=?2 AND COALESCE(phase,0)=CAST(?10 AS INTEGER) AND COALESCE(edit_revision,0)=CAST(?11 AS INTEGER);")
      #[userId, messageId, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}", s!"{nextSeq}",
        s!"{nextEdit}", nextState, if op == 6 then nextContentStored else "", s!"{phase.toNat}", s!"{editRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "queue_changes_failed"
    if changesOf crs == 0 then return .ok (.rejected "queue_cas_lost")
    let rec ← execParamQueryUnlocked st.missionsDb
      ("INSERT INTO queue_item_receipts(message_id,mission_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content,source,updated_at) " ++
       "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " ++
       "ON CONFLICT(message_id) DO UPDATE SET phase=excluded.phase,claimed_generation=excluded.claimed_generation," ++
       "claim_boot_epoch=excluded.claim_boot_epoch,delivered_seq=excluded.delivered_seq,edit_revision=excluded.edit_revision," ++
       "content=excluded.content,updated_at=excluded.updated_at;")
      #[messageId, mid, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}", s!"{nextSeq}",
        s!"{nextEdit}", nextContentStored, source, nowAt]
    match rec with
    | .error e => return .error e
    | .ok _ =>
      return .ok (.ok {
        messageId := messageId, missionId := mid, content := nextContentStored, source := source,
        deliveredSeq := nextSeq, phase := nextPhase
      })

def queueItemBlocksEdit (st : CoreStore) (userId messageId : String) : IO (Except String Bool) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT COALESCE(phase,0),state FROM remote_message_queue WHERE user_id=?1 AND message_id=?2;"
    #[userId, messageId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok false
    let phase := cellNat (rs[1]!) 0
    let state := cell (rs[1]!) 1
    return .ok (phase == 1 || phase == 2 || phase == 3 || phase == 4 ||
      state == "claimed" || state == "delivered" || state == "crash_tombstone" || state == "cancelled")

def parkRateLimit
    (st : CoreStore) (missionId : String) (notBefore nowEpoch : UInt64) (resumeIntent : UInt8)
    (updatedAt : String) : IO (Except String Unit) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT status,superseded_by_mission_id,COALESCE(owner_epoch,1),COALESCE(state_revision,1) FROM missions WHERE id=?1;" #[missionId]
    let .ok rs := rows | return .error "rate_limit_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let status := cell (rs[1]!) 0
    let superseded : UInt8 := if (cell (rs[1]!) 1).isEmpty then 0 else 1
    let ownerEpoch := cellNat (rs[1]!) 2 |>.toUInt64
    let stateRev := cellNat (rs[1]!) 3 |>.toUInt32
    let phase := missionPhaseOfStatus status
    let (nextState, effs) := stepMissionSlice
      { phaseCode := phase, superseded := superseded, resumeIntent := 0, ownerEpoch := ownerEpoch, notBeforeEpoch := 0, stateRevision := stateRev }
      { opCode := 3, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := resumeIntent, callerEpoch := ownerEpoch, nowEpoch := nowEpoch, reqNotBefore := notBefore, markSuperseded := 0 }
    if effs.isEmpty then return .error s!"rate_limit_park_rejected:{status}"
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET status='waiting_rate_limit',not_before=?2,resume_intent=?3,terminal_reason='usage_limit_wait',state_revision=?4,updated_at=?5 WHERE id=?1 AND status=?6 AND COALESCE(state_revision,1)=CAST(?7 AS INTEGER);"
      #[missionId, s!"{nextState.notBeforeEpoch}", s!"{nextState.resumeIntent.toNat}", s!"{nextState.stateRevision}", updatedAt, status, s!"{stateRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "rate_limit_changes_failed"
    if changesOf crs == 0 then return .error "rate_limit_cas_lost"
    return .ok ()

def resumeRateLimit
    (st : CoreStore) (missionId : String) (nowEpoch : UInt64) (updatedAt : String) :
    IO (Except String Unit) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT status,COALESCE(not_before,0),COALESCE(resume_intent,0),superseded_by_mission_id,COALESCE(owner_epoch,1),COALESCE(state_revision,1) FROM missions WHERE id=?1;" #[missionId]
    let .ok rs := rows | return .error "rate_limit_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let status := cell (rs[1]!) 0
    let notBefore := cellNat (rs[1]!) 1 |>.toUInt64
    let intent := cellNat (rs[1]!) 2 |>.toUInt8
    let superseded : UInt8 := if (cell (rs[1]!) 3).isEmpty then 0 else 1
    let ownerEpoch := cellNat (rs[1]!) 4 |>.toUInt64
    let stateRev := cellNat (rs[1]!) 5 |>.toUInt32
    let phase := missionPhaseOfStatus status
    let (nextState, effs) := stepMissionSlice
      { phaseCode := phase, superseded := superseded, resumeIntent := intent, ownerEpoch := ownerEpoch, notBeforeEpoch := notBefore, stateRevision := stateRev }
      { opCode := 4, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := intent, callerEpoch := ownerEpoch, nowEpoch := nowEpoch, reqNotBefore := notBefore, markSuperseded := 0 }
    if effs.isEmpty then return .error s!"rate_limit_resume_rejected:{status}"
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET status='active',not_before=0,resume_intent=0,terminal_reason='',state_revision=?2,updated_at=?3 WHERE id=?1 AND status='waiting_rate_limit' AND COALESCE(state_revision,1)=CAST(?4 AS INTEGER);"
      #[missionId, s!"{nextState.stateRevision}", updatedAt, s!"{stateRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "rate_limit_changes_failed"
    if changesOf crs == 0 then return .error "rate_limit_cas_lost"
    return .ok ()

structure ContinuationDraft where
  id           : String
  missionId    : String
  requestId    : String
  prompt       : String
  reason       : String
  source       : String
  triggerKind  : String
  jobId        : String := ""
  dueEpoch     : UInt64
  recurrence   : String := ""
  stopAfterFirst : Bool := true
  deriving Repr

def registerContinuation
    (st : CoreStore) (d : ContinuationDraft) (nowEpoch : UInt64) (nowAt : String)
    (callerGeneration? : Option UInt64 := none) :
    IO (Except String String) :=
  withImmediateTx st.missionsDb do
    let isoNow := normalizeContinuationIso8601 nowAt nowEpoch
    let mrows ← execParamQueryUnlocked st.missionsDb
      "SELECT status,COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[d.missionId]
    let .ok mrs := mrows | return .error "continuation_mission_select_failed"
    if mrs.size ≤ 1 then return .error "mission_not_found"
    let status := cell (mrs[1]!) 0
    let runGen := cellNat (mrs[1]!) 1 |>.toUInt64
    if let some callerGen := callerGeneration? then
      if callerGen != runGen then
        return .error "stale_run_generation"
    let existing ← execParamQueryUnlocked st.missionsDb
      "SELECT id,phase,run_generation FROM mission_continuations WHERE mission_id=?1 AND request_id=?2;"
      #[d.missionId, d.requestId]
    let .ok ers := existing | return .error "continuation_select_failed"
    if ers.size > 1 then
      let prevId := cell (ers[1]!) 0
      let prevPhase := cellNat (ers[1]!) 1 |>.toUInt8
      let prevGen := cellNat (ers[1]!) 2 |>.toUInt64
      if prevGen != runGen || prevPhase == 4 || prevPhase == 3 then
        return .error "stale_run_generation"
      return .ok prevId
    if d.triggerKind == "time" then
      let prior ← execParamQueryUnlocked st.missionsDb
        "SELECT id,phase,run_generation,due_epoch FROM mission_continuations WHERE mission_id=?1 AND trigger_kind='time' AND phase=1 ORDER BY id ASC;"
        #[d.missionId]
      let .ok prs := prior | return .error "continuation_prior_failed"
      if prs.size > 1 then
        let row1 := prs[1]!
        let prevId := cell row1 0
        let admit1 := verifyWakeupContinuationAdmit
          (cellNat row1 1 |>.toUInt8) 1 (ownerTerminalOfStatus status) (ownerBusyOfStatus status)
          (cellNat row1 2 |>.toUInt64) runGen d.dueEpoch nowEpoch
        if admit1 != 1 then return .error "continuation_replace_rejected"
        for i in [2:prs.size] do
          let extra := prs[i]!
          let cancelAdmit := verifyWakeupContinuationAdmit
            (cellNat extra 1 |>.toUInt8) 4 (ownerTerminalOfStatus status) (ownerBusyOfStatus status)
            (cellNat extra 2 |>.toUInt64) runGen d.dueEpoch nowEpoch
          if cancelAdmit != 1 then return .error "continuation_replace_rejected"
          let rev ← execParamQueryUnlocked st.missionsDb
            "UPDATE mission_continuations SET phase=4,updated_at=?2 WHERE id=?1 AND phase=1;"
            #[cell extra 0, isoNow]
          if let .error e := rev then return .error e
          let rch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
          let .ok rcrs := rch | return .error "continuation_changes_failed"
          if changesOf rcrs == 0 then return .error "continuation_replace_rejected"
        let upd ← execParamQueryUnlocked st.missionsDb
          "UPDATE mission_continuations SET phase=1,run_generation=?2,due_epoch=?3,prompt=?4,reason=?5,source=?6,request_id=?7,updated_at=?8 WHERE id=?1 AND phase=1;"
          #[prevId, s!"{runGen}", s!"{d.dueEpoch}", d.prompt, d.reason, d.source, d.requestId, isoNow]
        if let .error e := upd then return .error e
        let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        let .ok crs := ch | return .error "continuation_changes_failed"
        if changesOf crs == 0 then return .error "continuation_replace_rejected"
        return .ok prevId
    else if !d.jobId.isEmpty then
      let prior ← execParamQueryUnlocked st.missionsDb
        "SELECT id,phase,run_generation FROM mission_continuations WHERE mission_id=?1 AND job_id=?2 AND phase=1 ORDER BY id ASC;"
        #[d.missionId, d.jobId]
      let .ok prs := prior | return .error "continuation_job_prior_failed"
      if prs.size > 1 then
        let row := prs[1]!
        let prevId := cell row 0
        let admit := verifyWakeupContinuationAdmit
          (cellNat row 1 |>.toUInt8) 1 (ownerTerminalOfStatus status) (ownerBusyOfStatus status)
          (cellNat row 2 |>.toUInt64) runGen d.dueEpoch nowEpoch
        if admit != 1 then return .error "continuation_replace_rejected"
        for i in [2:prs.size] do
          let extra := prs[i]!
          let cancelAdmit := verifyWakeupContinuationAdmit
            (cellNat extra 1 |>.toUInt8) 4 (ownerTerminalOfStatus status) (ownerBusyOfStatus status)
            (cellNat extra 2 |>.toUInt64) runGen d.dueEpoch nowEpoch
          if cancelAdmit != 1 then return .error "continuation_replace_rejected"
          let rev ← execParamQueryUnlocked st.missionsDb
            "UPDATE mission_continuations SET phase=4,updated_at=?2 WHERE id=?1 AND phase=1;"
            #[cell extra 0, isoNow]
          if let .error e := rev then return .error e
          let rch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
          let .ok rcrs := rch | return .error "continuation_changes_failed"
          if changesOf rcrs == 0 then return .error "continuation_replace_rejected"
        let upd ← execParamQueryUnlocked st.missionsDb
          "UPDATE mission_continuations SET run_generation=?2,due_epoch=?3,prompt=?4,reason=?5,source=?6,request_id=?7,updated_at=?8 WHERE id=?1 AND phase=1;"
          #[prevId, s!"{runGen}", s!"{d.dueEpoch}", d.prompt, d.reason, d.source, d.requestId, isoNow]
        if let .error e := upd then return .error e
        let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        let .ok crs := ch | return .error "continuation_changes_failed"
        if changesOf crs == 0 then return .error "continuation_replace_rejected"
        return .ok prevId
    let admit := verifyWakeupContinuationAdmit
      0 0 (ownerTerminalOfStatus status) (ownerBusyOfStatus status) 0 runGen d.dueEpoch nowEpoch
    if admit != 1 then
      if runGen == 0 then return .error "stale_run_generation"
      return .error "continuation_arm_rejected"
    let ins ← execParamQueryUnlocked st.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
       "VALUES(?1,?2,?3,1,?4,?5,?6,?7,?8,?9,?10,'',?11,?12,?13,?13);")
      #[d.id, d.missionId, s!"{runGen}", s!"{d.dueEpoch}", d.triggerKind, d.reason, d.prompt, d.requestId,
        d.jobId, d.source, d.recurrence, if d.stopAfterFirst then "1" else "0", isoNow]
    match ins with
    | .error e => return .error e
    | .ok _ => return .ok d.id

def bumpRunGenerationFence (st : CoreStore) (missionId nowAt : String) : IO (Except String UInt64) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(run_generation,1),status,COALESCE(state_revision,0) FROM missions WHERE id=?1;" #[missionId]
    let .ok rs := rows | return .error "fence_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    if ownerTerminalOfStatus (cell (rs[1]!) 1) == 1 then return .error "mission_terminal"
    let cur := cellNat (rs[1]!) 0 |>.toUInt64
    let curRev := cellNat (rs[1]!) 2 |>.toUInt32
    if cur == 0xFFFFFFFFFFFFFFFF then return .error "run_generation_overflow"
    if curRev == 0xFFFFFFFF then return .error "state_revision_overflow"
    let next := cur + 1
    let nextRev := curRev + 1
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET run_generation=?2,state_revision=?3,updated_at=?4 WHERE id=?1 AND COALESCE(run_generation,1)=CAST(?5 AS INTEGER) AND COALESCE(state_revision,0)=CAST(?6 AS INTEGER) AND status NOT IN ('completed','failed','cancelled','not_feasible');"
      #[missionId, s!"{next}", s!"{nextRev}", nowAt, s!"{cur}", s!"{curRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "fence_changes_failed"
    if changesOf crs == 0 then return .error "fence_cas_lost"
    return .ok next

private def revokeContinuationsUnlocked
    (st : CoreStore) (missionId nowAt : String) (alsoOutbox : Bool) : IO (Except String Nat) := do
  let isoNow := normalizeContinuationIso8601 nowAt
  let armed ← execParamQueryUnlocked st.missionsDb
    "SELECT id,phase,run_generation FROM mission_continuations WHERE mission_id=?1 AND phase=1;" #[missionId]
  let .ok ars := armed | return .error "continuation_list_failed"
  let mut n : Nat := 0
  for i in [1:ars.size] do
    let row := ars[i]!
    let admit := verifyWakeupContinuationAdmit (cellNat row 1 |>.toUInt8) 4 0 0 (cellNat row 2 |>.toUInt64) (cellNat row 2 |>.toUInt64) 0 1
    if admit == 1 then
      let upd ← execParamQueryUnlocked st.missionsDb
        "UPDATE mission_continuations SET phase=4,error='revoked',updated_at=?2 WHERE id=?1 AND phase=1 AND run_generation=CAST(?3 AS INTEGER);"
        #[cell row 0, isoNow, s!"{cellNat row 2}"]
      if let .error e := upd then return .error e
      let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok crs := ch | return .error "continuation_changes_failed"
      if changesOf crs > 0 then
        n := n + 1
  if alsoOutbox then
    let q ← execParamQueryUnlocked st.missionsDb
      "UPDATE effect_outbox SET delivered=0,phase=5,updated_at=?2 WHERE mission_id=?1 AND delivered=0 AND phase<2;"
      #[missionId, isoNow]
    if let .error e := q then return .error e
    let boot : UInt64 := if st.bootEpoch == 0 then 1 else st.bootEpoch
    let pendingRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id=?1 AND unpacked=0;" #[missionId]
    let .ok prs := pendingRows | return .error "deferred_pending_select_failed"
    let pendingUnpacked := changesOf prs
    let mGoalRows ← execParamQueryUnlocked st.missionsDb
      "SELECT COALESCE(deferred_goal,'') FROM missions WHERE id=?1;" #[missionId]
    let .ok mgrs := mGoalRows | return .error "deferred_goal_select_failed"
    let mGoal := if mgrs.size > 1 then cell (mgrs[1]!) 0 else ""
    let qRows ← execParamQueryUnlocked st.missionsDb
      ("SELECT user_id,message_id,payload,COALESCE(phase,0),COALESCE(claimed_generation,0)," ++
       "COALESCE(claim_boot_epoch,0),COALESCE(delivered_seq,0),COALESCE(edit_revision,0),state " ++
       "FROM remote_message_queue WHERE mission_id=?1 AND state='waiting' AND COALESCE(phase,0)=0;")
      #[missionId]
    let .ok qrs := qRows | return .error "queue_revoke_select_failed"
    for i in [1:qrs.size] do
      let qrow := qrs[i]!
      let qUser := cell qrow 0
      let qMsgId := cell qrow 1
      let qPayload := cell qrow 2
      let qPhase := cellNat qrow 3 |>.toUInt8
      let qClaimed := cellNat qrow 4 |>.toUInt64
      let qBoot := cellNat qrow 5 |>.toUInt64
      let qDeliv := cellNat qrow 6 |>.toUInt64
      let qEdit := cellNat qrow 7 |>.toUInt32
      let qState := cell qrow 8
      let qContent := (queuePayloadContent? qPayload).getD ""
      let qSource := (queuePayloadSource? qPayload).getD ""
      let effPhase : UInt8 :=
        if qPhase != 0 then qPhase
        else if qState == "claimed" then 1
        else if qState == "delivered" then 2
        else if qState == "crash_tombstone" then 3
        else if qState == "cancelled" then 4
        else 0
      let deferred : UInt8 :=
        if hasRawDeferredTrailerMarker qContent || hasRawDeferredTrailerMarker qPayload ||
           hasRawDeferredTrailerMarker mGoal || pendingUnpacked > 0 then 0 else 1
      let contentNonEmpty : UInt8 := if qContent.trimAscii.toString.isEmpty then 0 else 1
      let (nextSlice, qEffs) := stepQueueSlice
        { phaseCode := effPhase, claimedGeneration := qClaimed, claimBootEpoch := qBoot,
          deliveredSeq := qDeliv, editRevision := qEdit }
        { opCode := 5, deferredUnpacked := deferred, durablyStarted := 1,
          uncertainTimeout := 0, operatorConfirmedNotDelivered := 0,
          contentNonEmpty := contentNonEmpty, runGeneration := 0, nodeBootEpoch := boot, deliverySeq := 0 }
      if !qEffs.isEmpty then
        let (nextPhase, nextClaimed, nextSeq) :=
          match qEffs with
          | .persistQueuePhase ph cg ds :: _ => (ph, cg, ds)
          | _ => (nextSlice.phaseCode, nextSlice.claimedGeneration, nextSlice.deliveredSeq)
        let nextBoot := nextSlice.claimBootEpoch
        let nextEdit := nextSlice.editRevision
        let nextState :=
          if nextPhase == 0 then "waiting"
          else if nextPhase == 1 then "claimed"
          else if nextPhase == 2 then "delivered"
          else if nextPhase == 3 then "crash_tombstone"
          else "cancelled"
        let qupd ← execParamQueryUnlocked st.missionsDb
          ("UPDATE remote_message_queue SET phase=?3,claimed_generation=?4,claim_boot_epoch=?5,delivered_seq=?6," ++
           "edit_revision=?7,state=?8 " ++
           "WHERE user_id=?1 AND message_id=?2 AND state='waiting' AND COALESCE(phase,0)=CAST(?9 AS INTEGER) AND COALESCE(edit_revision,0)=CAST(?10 AS INTEGER);")
          #[qUser, qMsgId, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}", s!"{nextSeq}",
            s!"{nextEdit}", nextState, s!"{qPhase.toNat}", s!"{qEdit}"]
        if let .error e := qupd then return .error e
        let qch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        let .ok qcrs := qch | return .error "queue_changes_failed"
        if changesOf qcrs == 0 then return .error "queue_cas_lost"
        let qrec ← execParamQueryUnlocked st.missionsDb
          ("INSERT INTO queue_item_receipts(message_id,mission_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content,source,updated_at) " ++
           "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " ++
           "ON CONFLICT(message_id) DO UPDATE SET phase=excluded.phase,claimed_generation=excluded.claimed_generation," ++
           "claim_boot_epoch=excluded.claim_boot_epoch,delivered_seq=excluded.delivered_seq,edit_revision=excluded.edit_revision," ++
           "content=excluded.content,updated_at=excluded.updated_at;")
          #[qMsgId, missionId, s!"{nextPhase.toNat}", s!"{nextClaimed}", s!"{nextBoot}", s!"{nextSeq}",
            s!"{nextEdit}", qContent, qSource, isoNow]
        if let .error e := qrec then return .error e
    let orphanRecs ← execParamQueryUnlocked st.missionsDb
      ("SELECT message_id,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision " ++
       "FROM queue_item_receipts WHERE mission_id=?1 AND phase=0;")
      #[missionId]
    let .ok orrs := orphanRecs | return .error "queue_receipt_revoke_select_failed"
    for i in [1:orrs.size] do
      let orow := orrs[i]!
      let rMsgId := cell orow 0
      let rPhase := cellNat orow 1 |>.toUInt8
      let rClaimed := cellNat orow 2 |>.toUInt64
      let rBoot := cellNat orow 3 |>.toUInt64
      let rDeliv := cellNat orow 4 |>.toUInt64
      let rEdit := cellNat orow 5 |>.toUInt32
      let (nextRSlice, rEffs) := stepQueueSlice
        { phaseCode := rPhase, claimedGeneration := rClaimed, claimBootEpoch := rBoot,
          deliveredSeq := rDeliv, editRevision := rEdit }
        { opCode := 5, deferredUnpacked := 1, durablyStarted := 1,
          uncertainTimeout := 0, operatorConfirmedNotDelivered := 0,
          contentNonEmpty := 1, runGeneration := 0, nodeBootEpoch := boot, deliverySeq := 0 }
      if !rEffs.isEmpty then
        let (rNextPhase, rNextClaimed, rNextSeq) :=
          match rEffs with
          | .persistQueuePhase ph cg ds :: _ => (ph, cg, ds)
          | _ => (nextRSlice.phaseCode, nextRSlice.claimedGeneration, nextRSlice.deliveredSeq)
        let rUpd ← execParamQueryUnlocked st.missionsDb
          ("UPDATE queue_item_receipts SET phase=?2,claimed_generation=?3,claim_boot_epoch=?4,delivered_seq=?5,updated_at=?6 " ++
           "WHERE message_id=?1 AND phase=CAST(?7 AS INTEGER) AND edit_revision=CAST(?8 AS INTEGER);")
          #[rMsgId, s!"{rNextPhase.toNat}", s!"{rNextClaimed}", s!"{nextRSlice.claimBootEpoch}", s!"{rNextSeq}",
            isoNow, s!"{rPhase.toNat}", s!"{rEdit}"]
        if let .error e := rUpd then return .error e
        let rch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        let .ok rcrs := rch | return .error "queue_changes_failed"
        if changesOf rcrs == 0 then return .error "queue_cas_lost"
  return .ok n

/-- Revoke armed continuations (`phase=1 -> phase=4`) and, when `alsoOutbox`, undelivered `effect_outbox` + `remote_message_queue` + `queue_item_receipts` rows. -/
def revokeContinuations (st : CoreStore) (missionId nowAt : String) (alsoOutbox : Bool) :
    IO (Except String Nat) :=
  withImmediateTx st.missionsDb (revokeContinuationsUnlocked st missionId nowAt alsoOutbox)

private def applyMissionInterrupt
    (st : CoreStore) (missionId nowAt terminalReason : String) : IO (Except String Unit) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT status,superseded_by_mission_id,COALESCE(owner_epoch,1),COALESCE(state_revision,1),COALESCE(not_before,0),COALESCE(resume_intent,0) FROM missions WHERE id=?1;"
      #[missionId]
    let .ok rs := rows | return .error "interrupt_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let status := cell (rs[1]!) 0
    let superseded : UInt8 := if (cell (rs[1]!) 1).isEmpty then 0 else 1
    let ownerEpoch := cellNat (rs[1]!) 2 |>.toUInt64
    let stateRev := cellNat (rs[1]!) 3 |>.toUInt32
    let notBefore := cellNat (rs[1]!) 4 |>.toUInt64
    let resumeIntent := cellNat (rs[1]!) 5 |>.toUInt8
    let phase := missionPhaseOfStatus status
    let effPhase : UInt8 :=
      if status == "paused" || status == "awaiting_user" || status == "interrupted" then 1 else phase
    let (nextState, effs) := stepMissionSlice
      { phaseCode := effPhase, superseded := superseded, resumeIntent := resumeIntent, ownerEpoch := ownerEpoch, notBeforeEpoch := notBefore, stateRevision := stateRev }
      { opCode := 5, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := 0, callerEpoch := ownerEpoch, nowEpoch := 0, reqNotBefore := 0, markSuperseded := 0 }
    if effs.isEmpty then return .error s!"interrupt_rejected:{status}"
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET status='interrupted',terminal_reason=?2,not_before=0,resume_intent=0,state_revision=?3,updated_at=?4 WHERE id=?1 AND status=?5 AND COALESCE(state_revision,1)=CAST(?6 AS INTEGER);"
      #[missionId, terminalReason, s!"{nextState.stateRevision}", nowAt, status, s!"{stateRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "interrupt_changes_failed"
    if changesOf crs == 0 then return .error "interrupt_cas_lost"
    return .ok ()

/-- Hosted Stop: interrupt + run-generation fence + continuation/outbox/queue revocation inside ONE `BEGIN IMMEDIATE` transaction. -/
def hostedStop (st : CoreStore) (missionId nowAt : String) : IO (Except String UInt64) :=
  withImmediateTx st.missionsDb do
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT status,superseded_by_mission_id,COALESCE(owner_epoch,1),COALESCE(state_revision,0),COALESCE(not_before,0),COALESCE(resume_intent,0),COALESCE(run_generation,1) FROM missions WHERE id=?1;"
      #[missionId]
    let .ok rs := rows | return .error "interrupt_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let status := cell (rs[1]!) 0
    let superseded : UInt8 := if (cell (rs[1]!) 1).isEmpty then 0 else 1
    let ownerEpoch := cellNat (rs[1]!) 2 |>.toUInt64
    let stateRev := cellNat (rs[1]!) 3 |>.toUInt32
    let notBefore := cellNat (rs[1]!) 4 |>.toUInt64
    let resumeIntent := cellNat (rs[1]!) 5 |>.toUInt8
    let curGen := cellNat (rs[1]!) 6 |>.toUInt64
    if ownerTerminalOfStatus status == 1 then return .error "mission_terminal"
    let phase := missionPhaseOfStatus status
    let effPhase : UInt8 :=
      if status == "paused" || status == "awaiting_user" || status == "interrupted" then 1 else phase
    let (nextState, effs) := stepMissionSlice
      { phaseCode := effPhase, superseded := superseded, resumeIntent := resumeIntent, ownerEpoch := ownerEpoch, notBeforeEpoch := notBefore, stateRevision := stateRev }
      { opCode := 5, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := 0, callerEpoch := ownerEpoch, nowEpoch := 0, reqNotBefore := 0, markSuperseded := 0 }
    if effs.isEmpty then return .error s!"interrupt_rejected:{status}"
    if curGen == 0xFFFFFFFFFFFFFFFF then return .error "run_generation_overflow"
    if nextState.stateRevision == 0xFFFFFFFF then return .error "state_revision_overflow"
    let nextGen := curGen + 1
    let nextRev := nextState.stateRevision + 1
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET status='interrupted',terminal_reason='hosted_stop',not_before=0,resume_intent=0,run_generation=?2,state_revision=?3,updated_at=?4 WHERE id=?1 AND status=?5 AND COALESCE(state_revision,0)=CAST(?6 AS INTEGER) AND COALESCE(run_generation,1)=CAST(?7 AS INTEGER);"
      #[missionId, s!"{nextGen}", s!"{nextRev}", nowAt, status, s!"{stateRev}", s!"{curGen}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "interrupt_changes_failed"
    if changesOf crs == 0 then return .error "interrupt_cas_lost"
    let isoNow := normalizeContinuationIso8601 nowAt
    let _ ← execParamQueryUnlocked st.missionsDb
      "UPDATE mission_runs SET execution_state='terminal',terminal_reason='hosted_stop',updated_at=?2 WHERE mission_id=?1 AND execution_state NOT IN ('terminal','completed','failed','aborted');"
      #[missionId, isoNow]
    match ← revokeContinuationsUnlocked st missionId nowAt true with
    | .error e => return .error e
    | .ok _ => return .ok nextGen

def reportLocalInterrupt (st : CoreStore) (missionId nowAt : String) : IO (Except String Unit) :=
  applyMissionInterrupt st missionId nowAt "local_process_interrupted"

inductive ContinuationActOutcome where
  | ok (missionId : String)
  | superseded
  deriving Repr

def actOnContinuation
    (st : CoreStore) (contId action nowAt : String) (nowEpoch : UInt64) : IO (Except String ContinuationActOutcome) :=
  withImmediateTx st.missionsDb do
    let isoNow := normalizeContinuationIso8601 nowAt nowEpoch
    let rows ← execParamQueryUnlocked st.missionsDb
      "SELECT c.phase,c.run_generation,c.due_epoch,c.mission_id,m.status,COALESCE(m.run_generation,1) FROM mission_continuations c JOIN missions m ON m.id=c.mission_id WHERE c.id=?1;"
      #[contId]
    let .ok rs := rows | return .error "continuation_select_failed"
    if rs.size ≤ 1 then return .error "continuation_not_found"
    let row := rs[1]!
    let phase := cellNat row 0 |>.toUInt8
    let armed := cellNat row 1 |>.toUInt64
    let due := cellNat row 2 |>.toUInt64
    let mid := cell row 3
    let status := cell row 4
    let runGen := cellNat row 5 |>.toUInt64
    if action == "cancel" then
      if phase != 1 then return .error "continuation_cancel_race"
      let admit := verifyWakeupContinuationAdmit phase 4 (ownerTerminalOfStatus status) (ownerBusyOfStatus status) armed runGen due nowEpoch
      if admit != 1 then return .error "continuation_cancel_race"
      let upd ← execParamQueryUnlocked st.missionsDb
        "UPDATE mission_continuations SET phase=4,updated_at=?2 WHERE id=?1 AND phase=1;" #[contId, isoNow]
      if let .error e := upd then return .error e
      let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok crs := ch | return .error "continuation_changes_failed"
      if changesOf crs == 0 then return .error "continuation_cancel_race"
      return .ok (.ok mid)
    else if action == "resume" then
      if phase == 1 && armed < runGen then
        let supAdmit := verifyWakeupContinuationAdmit phase 3 (ownerTerminalOfStatus status) (ownerBusyOfStatus status) armed runGen due nowEpoch
        if supAdmit != 1 then return .error "continuation_resume_rejected"
        let supUpd ← execParamQueryUnlocked st.missionsDb
          "UPDATE mission_continuations SET phase=3,error='stale_run_generation',updated_at=?2 WHERE id=?1 AND phase=1 AND run_generation=CAST(?3 AS INTEGER);"
          #[contId, isoNow, s!"{armed}"]
        if let .error e := supUpd then return .error e
        let supCh ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
        let .ok supCrs := supCh | return .error "continuation_changes_failed"
        if changesOf supCrs == 0 then return .error "stale_run_generation"
        return .ok .superseded
      let admit := verifyWakeupContinuationAdmit phase 2 (ownerTerminalOfStatus status) (ownerBusyOfStatus status) armed runGen due nowEpoch
      if admit != 1 then return .error "continuation_resume_rejected"
      let upd ← execParamQueryUnlocked st.missionsDb
        "UPDATE mission_continuations SET phase=2,updated_at=?2 WHERE id=?1 AND phase=1 AND run_generation=CAST(?3 AS INTEGER);"
        #[contId, isoNow, s!"{armed}"]
      if let .error e := upd then return .error e
      let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok crs := ch | return .error "continuation_changes_failed"
      if changesOf crs == 0 then return .error "continuation_resume_rejected"
      return .ok (.ok mid)
    else
      return .error "continuation_bad_action"

def continuationJsonForMission (st : CoreStore) (missionId : String) : IO (Except String String) := do
  let rows ← execParamQuery st.missionsDb
    ("SELECT id,phase,due_epoch,trigger_kind,reason,source,error,recurrence FROM mission_continuations " ++
     "WHERE mission_id=?1 AND phase IN (1,2,3) ORDER BY due_epoch ASC, id ASC;")
    #[missionId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok "{\"count\":0,\"items\":[]}"
    let mut items : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let phase := cellNat r 1 |>.toUInt8
      let due := cellNat r 2
      let trigger := cell r 3
      let reason := cell r 4
      let source := cell r 5
      let err := cell r 6
      let recur := cell r 7
      let errJson := if err.isEmpty then "" else s!",\"error\":{jsonEscape err}"
      let recJson := if recur.isEmpty then "" else s!",\"recurrence\":{jsonEscape recur}"
      let srcJson := if source.isEmpty then "" else s!",\"source\":{jsonEscape source}"
      items := items.push (
        s!"\{\"id\":{jsonEscape (cell r 0)},\"state\":{jsonEscape (continuationApiState phase trigger)}," ++
        s!"\"next_at\":{renderContinuationNextAtJson trigger due.toUInt64},\"trigger\":{jsonEscape trigger},\"reason\":{jsonEscape reason}{srcJson}{errJson}{recJson}}")
    return .ok s!"\{\"count\":{rs.size - 1},\"items\":[{String.intercalate "," items.toList}]}"

def bumpSupervision
    (st : CoreStore) (missionId field nowAt : String) : IO (Except String Nat) :=
  withImmediateTx st.missionsDb do
    let col := if field == "stall_consecutive_arms" then "stall_consecutive_arms" else "bg_wait_arms"
    let ins ← execParamQueryUnlocked st.missionsDb
      "INSERT INTO mission_supervision(mission_id,bg_wait_arms,stall_consecutive_arms,updated_at) VALUES(?1,0,0,?2) ON CONFLICT(mission_id) DO NOTHING;"
      #[missionId, nowAt]
    if let .error e := ins then return .error e
    let upd ← execParamQueryUnlocked st.missionsDb
      s!"UPDATE mission_supervision SET {col}={col}+1,updated_at=?2 WHERE mission_id=?1;"
      #[missionId, nowAt]
    if let .error e := upd then return .error e
    let q ← execParamQueryUnlocked st.missionsDb
      s!"SELECT {col} FROM mission_supervision WHERE mission_id=?1;" #[missionId]
    match q with
    | .error e => return .error e
    | .ok rs => return .ok (cellNat (rs[1]!) 0)

def readSupervision (st : CoreStore) (missionId : String) : IO (Except String (Nat × Nat)) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT bg_wait_arms,stall_consecutive_arms FROM mission_supervision WHERE mission_id=?1;" #[missionId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok (0, 0)
    return .ok (cellNat (rs[1]!) 0, cellNat (rs[1]!) 1)

def reconcileMissionRow (status placementKind : String) (sameBoot liveRun hasEvents : Bool) : UInt8 :=
  let statusCode : UInt8 :=
    if status == "active" then 0
    else if status == "awaiting_user" then 1
    else if status == "interrupted" then 2
    else 3
  let isClient : UInt8 := if placementKind == "client" then 1 else 0
  reconcileStep statusCode isClient (if sameBoot then 1 else 0) 0 0 0
    (if liveRun then 1 else 0) 0 (if hasEvents then 1 else 0) 0 0 0 0

def runSharedReconcile (st : CoreStore) (nowAt : String) : IO (Except String Nat) :=
  runStartupAndHealthReconcile st.missionsDb st.bootEpoch nowAt

structure BeginRunResult where
  runId        : String
  generation   : UInt64
  placementKind : String
  deriving Repr

def beginMissionRun
    (st : CoreStore) (missionId runId updatedAt : String)
    (callerOwnerEpoch : UInt64) : IO (Except String BeginRunResult) :=
  withImmediateTx st.missionsDb do
    let isoNow := normalizeContinuationIso8601 updatedAt
    let rows ← execParamQueryUnlocked st.missionsDb
      ("SELECT placement_kind,COALESCE(run_generation,0),COALESCE(owner_epoch,1),superseded_by_mission_id," ++
       "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=missions.id AND r.execution_state NOT IN ('terminal','completed','failed','aborted'))," ++
       "status,COALESCE(state_revision,1),COALESCE(not_before,0),COALESCE(resume_intent,0) " ++
       "FROM missions WHERE id=?1;")
      #[missionId]
    let .ok rs := rows | return .error "begin_run_select_failed"
    if rs.size ≤ 1 then return .error "mission_not_found"
    let placement := cell (rs[1]!) 0
    if placement != "managed" && placement != "client" && placement != "local" && placement != "remote" then
      return .error s!"invalid_placement_kind:{placement}"
    let curGen := cellNat (rs[1]!) 1 |>.toUInt64
    let owner := cellNat (rs[1]!) 2 |>.toUInt64
    let superseded : UInt8 := if (cell (rs[1]!) 3).isEmpty then 0 else 1
    let liveRuns := cellNat (rs[1]!) 4
    let status := cell (rs[1]!) 5
    let stateRev := cellNat (rs[1]!) 6 |>.toUInt32
    let notBefore := cellNat (rs[1]!) 7 |>.toUInt64
    let resumeIntent := cellNat (rs[1]!) 8 |>.toUInt8
    let dispatchPhase := missionPhaseOfStatus status
    let (nextMState, mEffs) := stepMissionSlice
      { phaseCode := dispatchPhase, superseded := superseded, resumeIntent := resumeIntent, ownerEpoch := owner, notBeforeEpoch := notBefore, stateRevision := stateRev }
      { opCode := 0, hasEvidence := 0, hasTermReceipt := 0, reqResumeInt := 0, callerEpoch := callerOwnerEpoch, nowEpoch := 0, reqNotBefore := 0, markSuperseded := 0 }
    if mEffs.isEmpty then return .error s!"begin_run_mission_rejected:{status}"
    let phase : UInt8 :=
      if liveRuns > 0 || status == "active" || status == "pending" then 2
      else if curGen == 0 then 0
      else 4
    if curGen == 0xFFFFFFFFFFFFFFFF then return .error "run_generation_overflow"
    let proposed := curGen + 1
    let admit := verifyRunLifecycleAdmit phase 0 superseded 0 0 0 0 curGen proposed owner callerOwnerEpoch
    if admit != 1 then return .error "begin_run_rejected"
    let ins ← execParamQueryUnlocked st.missionsDb
      "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES(?1,?2,?3,'claimed','','',?4);"
      #[runId, missionId, s!"{proposed}", updatedAt]
    if let .error e := ins then return .error e
    let staleRows ← execParamQueryUnlocked st.missionsDb
      "SELECT id,phase,run_generation,due_epoch FROM mission_continuations WHERE mission_id=?1 AND phase=1 AND run_generation<CAST(?2 AS INTEGER);"
      #[missionId, s!"{proposed}"]
    let .ok srs := staleRows | return .error "continuation_select_failed"
    for i in [1:srs.size] do
      let srow := srs[i]!
      let cid := cell srow 0
      let cPhase := cellNat srow 1 |>.toUInt8
      let cArmed := cellNat srow 2 |>.toUInt64
      let cDue := cellNat srow 3 |>.toUInt64
      let supAdmit := verifyWakeupContinuationAdmit cPhase 3 (ownerTerminalOfStatus status) (ownerBusyOfStatus status) cArmed proposed cDue 0
      if supAdmit != 1 then return .error "begin_run_cas_lost"
      let supUpd ← execParamQueryUnlocked st.missionsDb
        "UPDATE mission_continuations SET phase=3,error='stale_run_generation',updated_at=?3 WHERE id=?1 AND mission_id=?2 AND phase=1 AND run_generation=CAST(?4 AS INTEGER);"
        #[cid, missionId, isoNow, s!"{cArmed}"]
      if let .error e := supUpd then return .error e
      let supCh ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
      let .ok supCrs := supCh | return .error "begin_run_changes_failed"
      if changesOf supCrs == 0 then return .error "begin_run_cas_lost"
    let upd ← execParamQueryUnlocked st.missionsDb
      "UPDATE missions SET run_generation=?2,status='active',state_revision=?3,updated_at=?4 WHERE id=?1 AND status=?5 AND COALESCE(run_generation,0)=CAST(?6 AS INTEGER) AND COALESCE(state_revision,1)=CAST(?7 AS INTEGER);"
      #[missionId, s!"{proposed}", s!"{nextMState.stateRevision}", updatedAt, status, s!"{curGen}", s!"{stateRev}"]
    if let .error e := upd then return .error e
    let ch ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[]
    let .ok crs := ch | return .error "begin_run_changes_failed"
    if changesOf crs == 0 then return .error "begin_run_cas_lost"
    return .ok { runId := runId, generation := proposed, placementKind := placement }

structure ProjectDecision where
  id          : String
  projectSlug : String
  status      : String
  question    : String := ""
  evidence    : String := ""
  updatedAt   : String := ""
  deriving Repr

def answeredOfStatus (status : String) : Bool :=
  status == "answered"

def putProjectDecision (st : CoreStore) (d : ProjectDecision) (answered? : Option Bool) :
    IO (Except String ProjectDecision) := do
  if d.status != "pending" && d.status != "answered" && d.status != "dismissed" then
    return .error "invalid_decision_status"
  if let some flag := answered? then
    if flag != answeredOfStatus d.status then
      return .error "contradictory_answered"
  let res ← execParamQuery st.projectsDb
    ("INSERT INTO project_decisions(id,project_slug,status,question,evidence,updated_at) VALUES(?1,?2,?3,?4,?5,?6) " ++
     "ON CONFLICT(id) DO UPDATE SET project_slug=excluded.project_slug,status=excluded.status,question=excluded.question,evidence=excluded.evidence,updated_at=excluded.updated_at;")
    #[d.id, d.projectSlug, d.status, d.question, d.evidence, d.updatedAt]
  match res with
  | .error e => return .error e
  | .ok _ => return .ok d

def listProjectDecisionsJson (st : CoreStore) (slug : String) : IO (Except String String) := do
  let rows ← execParamQuery st.projectsDb
    "SELECT id,project_slug,status,question,evidence,updated_at FROM project_decisions WHERE project_slug=?1 OR ?1='' ORDER BY updated_at DESC, id ASC;"
    #[slug]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok "[]"
    let mut items : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let status := cell r 2
      let answered := if answeredOfStatus status then "true" else "false"
      items := items.push (
        s!"\{\"id\":{jsonEscape (cell r 0)},\"project_slug\":{jsonEscape (cell r 1)},\"status\":{jsonEscape status}," ++
        s!"\"answered\":{answered},\"question\":{jsonEscape (cell r 3)},\"evidence\":{jsonEscape (cell r 4)},\"updated_at\":{jsonEscape (cell r 5)}}")
    return .ok ("[" ++ String.intercalate "," items.toList ++ "]")

def isMcpWakeupPayload (jv : JVal) : Bool :=
  let vars? := jv.field? "variables"
  let reqId? := vars?.bind (·.fieldStr? "__wakeup_request_id")
  let stopType? := (jv.field? "stop_policy").bind (·.fieldStr? "type")
  reqId?.isSome || stopType? == some "after_first_fire" ||
    ((jv.field? "trigger").bind (·.fieldStr? "type")) == some "durable_job_terminal"

def parseMcpWakeupPayload?
    (jv : JVal) (missionId fallbackId : String) (nowEpoch : UInt64) :
    Option ContinuationDraft := Id.run do
  let vars? := jv.field? "variables"
  let reqId? := vars?.bind (·.fieldStr? "__wakeup_request_id")
  let stopType? := (jv.field? "stop_policy").bind (·.fieldStr? "type")
  let trig? := jv.field? "trigger"
  let trigType := (trig?.bind (·.fieldStr? "type")).getD "interval"
  if reqId?.isNone && stopType? != some "after_first_fire" && trigType != "durable_job_terminal" then
    return none
  let prompt :=
    match (jv.field? "command_source").bind (·.fieldStr? "content") with
    | some p => p
    | none => (jv.fieldStr? "prompt").getD ""
  let reason :=
    match vars?.bind (·.fieldStr? "__wakeup_reason") with
    | some r => r
    | none => (jv.fieldStr? "reason").getD ""
  let source :=
    match vars?.bind (·.fieldStr? "__wakeup_source") with
    | some s => s
    | none => (jv.fieldStr? "source").getD "automation-manager"
  let reqId := reqId?.getD fallbackId
  if trigType == "durable_job_terminal" then
    let jobId := ((trig?.bind (·.fieldStr? "job_id")).getD "").trimAscii.toString
    if jobId.isEmpty then
      return none
    return some {
      id := fallbackId, missionId := missionId, requestId := reqId,
      prompt := prompt, reason := reason, source := source,
      triggerKind := "job", jobId := jobId, dueEpoch := nowEpoch + 86400
    }
  else
    let delay := (trig?.bind (·.fieldNat? "seconds")).getD 60
    let dueFromIso? :=
      match vars?.bind (·.fieldStr? "__wakeup_due_at") with
      | some iso => parseIso8601EpochU64? iso
      | none =>
        match jv.fieldStr? "next_at" with
        | some iso => parseIso8601EpochU64? iso
        | none => none
    let due :=
      match dueFromIso? with
      | some ep => ep
      | none => (jv.fieldNat? "due_epoch").map Nat.toUInt64 |>.getD (nowEpoch + delay.toUInt64)
    return some {
      id := fallbackId, missionId := missionId, requestId := reqId,
      prompt := prompt, reason := reason, source := source,
      triggerKind := "time", dueEpoch := due
    }

def sanitizeAutomationVariablesJson (jv : JVal) : String :=
  match jv.field? "variables" with
  | some (.obj pairs) =>
    let kept := pairs.filter (fun (k, _) => !k.startsWith "__wakeup_")
    renderCompact (.obj kept)
  | _ => "{}"

def missionDetailJson
    (st : CoreStore)
    (missionId : String)
    (callerUserId? : Option String := none)
    (bootstrapAdminId : String := "") : IO (Except String (Option String)) := do
  let sql :=
    "SELECT m.id,m.title,m.status,m.backend,COALESCE(m.model_override,''),COALESCE(m.model_effort,'')," ++
    "m.working_directory,m.updated_at,m.total_cost_cents,m.authority_mode,m.placement_kind," ++
    "m.superseded_by_mission_id,m.orphaned_at,m.reserved_disk_gib,m.state_revision,m.node_boot_epoch," ++
    "COALESCE(m.terminal_reason,''),COALESCE(m.not_before,0),COALESCE(m.resume_intent,0),COALESCE(m.run_generation,1)," ++
    "COALESCE(e.terminal_reason,''),COALESCE(e.summary,''),COALESCE(e.artifact_ref,''),COALESCE(e.recorded_at,'')," ++
    "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal')," ++
    "(SELECT COUNT(*) FROM mission_events ev WHERE ev.mission_id=m.id),m.tags," ++
    "(SELECT COUNT(*) FROM mission_continuations c WHERE c.mission_id=m.id AND c.phase=1)," ++
    "COALESCE(e.verified,1)," ++
    "COALESCE(m.project,''),COALESCE(m.track,''),COALESCE(m.repo,''),COALESCE(m.working_directory,''),COALESCE(m.total_cost_cents,0)," ++
    "COALESCE(m.owner_user_id,''),COALESCE((SELECT u.username FROM users u WHERE u.id = m.owner_user_id),'') " ++
    "FROM missions m LEFT JOIN mission_terminal_evidence e ON e.mission_id=m.id WHERE m.id=?1;"
  let rows ← execParamQuery st.missionsDb sql #[missionId]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    if rs.size ≤ 1 then return .ok none
    let r := rs[1]!
    let status := cell r 2
    let modelOverride := cell r 4
    let modelEffort := cell r 5
    let authMode := cell r 9
    let place := cell r 10
    let superBy := cell r 11
    let orph := cell r 12
    let diskGib := cellNat r 13
    let mReason := cell r 16
    let evReason := cell r 20
    let evSummary := cell r 21
    let evArtifact := cell r 22
    let evRecorded := cell r 23
    let hasEv := !evRecorded.isEmpty || !evReason.isEmpty
    let effReason := if !evReason.isEmpty then evReason else mReason
    let armedWakeups := cellNat r 27
    let evVerified := (cellNat r 28) != 0
    let rawProj := cell r 29
    let proj :=
      match callerUserId? with
      | some uid =>
        if !rawProj.isEmpty && rawProj.startsWith (uid ++ ":") then
          (rawProj.drop (uid.length + 1)).toString
        else if !bootstrapAdminId.isEmpty && uid == bootstrapAdminId then
          rawProj
        else
          match rawProj.splitOn ":" with
          | [_, rest] => rest
          | _ => rawProj
      | none => rawProj
    let track := cell r 30
    let githubPr := cell r 31
    let workDir := cell r 32
    let totalCostCents := cellNat r 33
    let ownerUid := cell r 34
    let ownerUname := cell r 35
    let viewerRole :=
      match callerUserId? with
      | some uid => if ownerUid == uid then "owner" else "participant"
      | none => "owner"
    let sharedWithJson ← match ← listMissionSharesJson st missionId with
      | .ok sj => pure sj
      | .error _ => pure "[]"
    let verdict := deriveMissionHealthVerdict status effReason orph superBy place
      ((cellNat r 15).toUInt64 == st.bootEpoch) false ((cellNat r 24) > 0) ((cellNat r 25) > 0) (armedWakeups > 0) hasEv
    let evJson :=
      if hasEv then
        s!"\{\"terminal_reason\":{jsonEscape evReason},\"summary\":{jsonEscape evSummary},\"artifact_ref\":{jsonEscape evArtifact},\"verified\":{if evVerified then "true" else "false"},\"recorded_at\":{jsonEscape evRecorded}}"
      else "null"
    let cont ← continuationJsonForMission st missionId
    let .ok contJson := cont | return .error "continuation_json_failed"
    let tags := cell r 26
    let tagsOut :=
      if tags.startsWith "[" then tags
      else projectCompatibilityTagsJson authMode place superBy orph diskGib.toUInt64
    return .ok (some (
      s!"\{\"id\":{jsonEscape (cell r 0)},\"title\":{jsonEscape (cell r 1)},\"status\":{jsonEscape status}," ++
      s!"\"backend\":{jsonEscape (cell r 3)},\"model_override\":{jsonEscape modelOverride},\"model_effort\":{jsonEscape modelEffort}," ++
      s!"\"project\":{jsonEscape proj},\"track\":{jsonEscape track},\"github_pr\":{jsonEscape githubPr}," ++
      s!"\"working_directory\":{jsonEscape workDir}," ++
      s!"\"updated_at\":{jsonEscape (cell r 7)},\"total_cost_cents\":{totalCostCents}," ++
      s!"\"authority_mode\":{jsonEscape authMode},\"placement_kind\":{jsonEscape place}," ++
      s!"\"superseded_by_mission_id\":{jsonEscape superBy},\"orphaned_at\":{jsonEscape orph},\"reserved_disk_gib\":{diskGib}," ++
      s!"\"viewer_role\":{jsonEscape viewerRole},\"owner_username\":{jsonEscape ownerUname},\"shared_with\":{sharedWithJson}," ++
      s!"\"state_revision\":{cellNat r 14},\"not_before\":{cellNat r 17},\"resume_intent\":{cellNat r 18}," ++
      s!"\"run_generation\":{cellNat r 19},\"health_verdict\":{jsonEscape verdict}," ++
      s!"\"terminal_evidence\":{evJson},\"continuation\":{contJson},\"tags\":{tagsOut}}"))

def ensureQueueContSchema (st : CoreStore) : IO (Except String Unit) := do
  match ← st.missionsDb.mu.atomically (sqliteExecRaw st.missionsDb.handle queueContSchemaSql) with
  | .error e => return .error e
  | .ok () =>
    let r1 : Except String Unit ← st.missionsDb.mu.atomically (do
      for stmt in queueContAdditiveAlters do
        match ← sqliteExecRaw st.missionsDb.handle stmt with
        | .ok () => pure ()
        | .error e =>
          if (e.toLower.splitOn "duplicate column name").length ≤ 1 then
            return Except.error e
      return Except.ok ())
    match r1 with
    | .error e => return .error e
    | .ok () =>
      match ← st.projectsDb.mu.atomically (sqliteExecRaw st.projectsDb.handle projectsDecisionsSchemaSql) with
      | .error e => return .error e
      | .ok () =>
        st.projectsDb.mu.atomically (do
          for stmt in projectsDecisionsAdditiveAlters do
            match ← sqliteExecRaw st.projectsDb.handle stmt with
            | .ok () => pure ()
            | .error e =>
              if (e.toLower.splitOn "duplicate column name").length ≤ 1 then
                return Except.error e
          return Except.ok ())

end OrbCore.QueueCont
