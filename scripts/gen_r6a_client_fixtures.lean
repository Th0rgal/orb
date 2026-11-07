import Orb.Kernel
open Orb.Kernel

-- Prints shared/orb-spec/fixtures/r6a-client-kernel.json. Every expected word is
-- the C-ABI result of the Lean R6-A steppers; do not edit the JSON by hand.

private def b (v : Bool) : String := if v then "true" else "false"

private def lo (w : UInt64) : UInt32 := (w &&& 0xFFFFFFFF).toUInt32
private def hi (w : UInt64) : UInt32 := (w >>> 32).toUInt32

private def followupCase
    (name : String) (op : UInt8)
    (serverRev incomingServerRev expectedServerRev : UInt32)
    (clientMsgId trackedMsgId deliveredMsgId postedAfterSeq turnSeq : UInt64)
    (optimisticSending serverListed contentMatched alreadyDelivered : UInt8) : String :=
  let w := followupQueueStep op serverRev incomingServerRev expectedServerRev
    clientMsgId trackedMsgId deliveredMsgId postedAfterSeq turnSeq
    optimisticSending serverListed contentMatched alreadyDelivered
  let word := lo w
  s!"    \{\"op\": \"followupQueue\", \"name\": \"{name}\", \"queueOp\": {op}, \"serverRev\": \"{serverRev}\", \"incomingServerRev\": \"{incomingServerRev}\", \"expectedServerRev\": \"{expectedServerRev}\", \"clientMsgId\": \"{clientMsgId}\", \"trackedMsgId\": \"{trackedMsgId}\", \"deliveredMsgId\": \"{deliveredMsgId}\", \"postedAfterSeq\": \"{postedAfterSeq}\", \"turnSeq\": \"{turnSeq}\", \"optimisticSending\": {b (optimisticSending == 1)}, \"serverListed\": {b (serverListed == 1)}, \"contentMatched\": {b (contentMatched == 1)}, \"alreadyDelivered\": {b (alreadyDelivered == 1)}, \"expectedReasonCode\": {word &&& 0xFF}, \"expectedAdmitted\": {b ((word &&& 256) != 0)}, \"expectedOptimisticLiveNext\": {b ((word &&& 512) != 0)}, \"expectedRetiredNow\": {b ((word &&& 1024) != 0)}, \"expectedNextServerRev\": \"{hi w}\"}"

private def transportCase
    (name : String) (mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq : UInt8)
    (failureStreak failThreshold httpStatus sinceSeq32 : UInt32)
    (nowMs cooldownUntilMs : UInt64) : String :=
  let w := transportEpochStep mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq
    failureStreak failThreshold httpStatus sinceSeq32 nowMs cooldownUntilMs
  let word := lo w
  s!"    \{\"op\": \"transportEpoch\", \"name\": \"{name}\", \"mode\": {mode}, \"eventKind\": {eventKind}, \"everReady\": {b (everReady == 1)}, \"stickyUnsupported\": {b (stickyUnsupported == 1)}, \"endpointClass\": {endpointClass}, \"prevEndpointClass\": {prevEndpointClass}, \"hasSinceSeq\": {b (hasSinceSeq == 1)}, \"failureStreak\": \"{failureStreak}\", \"failThreshold\": \"{failThreshold}\", \"httpStatus\": \"{httpStatus}\", \"sinceSeq32\": \"{sinceSeq32}\", \"nowMs\": \"{nowMs}\", \"cooldownUntilMs\": \"{cooldownUntilMs}\", \"expectedNextMode\": {word &&& 0xFF}, \"expectedAdmitted\": {b ((word &&& 256) != 0)}, \"expectedStickyUnsupportedNext\": {b ((word &&& 512) != 0)}, \"expectedFallbackActiveNext\": {b ((word &&& 1024) != 0)}, \"expectedReprobeTriggered\": {b ((word &&& 2048) != 0)}, \"expectedHasPreservedSinceSeq\": {b ((word &&& 4096) != 0)}, \"expectedNextFailureStreak\": {(word >>> 16) &&& 0xFF}, \"expectedPreservedSinceSeq32\": \"{hi w}\"}"

private def tailCase
    (name : String) (prevLen prevCommit prevCheckpoint newLen rawCommit maxOpenTailBytes : UInt32)
    (openFenceActive : UInt8) : String :=
  let w := streamOpenTailCapStep prevLen prevCommit prevCheckpoint newLen rawCommit maxOpenTailBytes openFenceActive
  let word := lo w
  s!"    \{\"op\": \"streamOpenTailCap\", \"name\": \"{name}\", \"prevLen\": \"{prevLen}\", \"prevCommit\": \"{prevCommit}\", \"prevCheckpoint\": \"{prevCheckpoint}\", \"newLen\": \"{newLen}\", \"rawCommit\": \"{rawCommit}\", \"maxOpenTailBytes\": \"{maxOpenTailBytes}\", \"openFenceActive\": {b (openFenceActive == 1)}, \"expectedAdmitted\": {b ((word &&& 256) != 0)}, \"expectedCheckpointForced\": {b ((word &&& 512) != 0)}, \"expectedOpenFenceCapped\": {b ((word &&& 1024) != 0)}, \"expectedNextCheckpoint\": \"{hi w}\"}"

def main : IO Unit := do
  let rows : Array String := #[
    followupCase "edit_cas_applied" 1 5 5 5 42 42 0 10 10 0 0 0 0,
    followupCase "historical_turn_not_retired" 3 5 5 5 0x1234 0x1234 0x9000000000000001 10 11 0 0 1 0,
    followupCase "high_bit_ids_not_clamped" 3 5 5 5 0xFFFFFFFFFFFFFFFF 0x80000001 0xFFFFFFFFFFFFFFFF 10 11 0 0 1 0,
    followupCase "content_match_retires_later_turn" 3 5 5 5 42 42 0 10 11 0 0 1 0,
    transportCase "sse_fallback_preserves_since" 0 1 1 0 0 0 1 1 2 0 40 1000 0,
    transportCase "endpoint_class_change_clears_sticky_404" 1 2 1 1 1 0 1 3 2 404 40 0 100,
    transportCase "endpoint_class_change_clears_sticky_501" 1 2 1 1 2 0 1 3 2 501 40 0 100,
    transportCase "zero_since_present" 0 1 1 0 0 0 1 1 2 0 0 0 0,
    transportCase "since_absent_drops_positive_seq" 0 1 1 0 0 0 0 1 2 0 40 0 0,
    transportCase "high_bit_since_present" 0 1 1 0 0 0 1 1 2 0 0x80000001 0xFFFFFFFFFFFFFFFF 0,
    tailCase "open_fence_caps_tail" 20 5 12 40 5 8 1,
    tailCase "zero_cap_rejected" 20 5 12 40 5 0 1,
    tailCase "high_bit_lengths_not_clamped" 0x80000001 0x80000000 0x80000000 0xFFFFFFFF 0x80000000 8 1
  ]
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/Orb/Kernel.lean by scripts/gen_r6a_client_fixtures.lean; do not edit. Phase R6-A follow-up queue, transport epoch, and open-tail cap words, including unsigned high-bit u32/u64 inputs.\","
  IO.println "  \"cases\": ["
  IO.println (",\n".intercalate rows.toList)
  IO.println "  ]"
  IO.println "}"
