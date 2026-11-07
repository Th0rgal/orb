/-
  Domain-meaningful mutation-kill suite across all 7 P1/P6 roadmap families (`0 import Lean`, `0 sorryAx`).

  Each of the 7 families in `docs/TRUSTWORTHY_SHARED_LEAN_ROADMAP.md` §3 defines 3 concrete
  domain-level mutants (21 total) of exported `Orb.Kernel` state machines and gates, paired
  with kernel-checked `decide` counterexample theorems proving strict semantic divergence
  (`mutant args ≠ kernel args`) on reachable boundary inputs.

  The same 21 mutant definitions and witness inputs are compiled into mutated C and WebAssembly
  backends and executed against `stock_lean` by `scripts/run_shared_kernel_conformance.py`.
-/
import Orb.Kernel

namespace Orb.MutantSuite

open Orb.Kernel

-- ===========================================================================
-- Family 1: Versioned mission merge / hierarchy (epoch-aware, unarchive vs fence)
-- ===========================================================================

/-- Mutant 1.1 (`orb_mission_control_step`): Archived fence bypass — drops `isArchived == 1` sticky fence. -/
@[inline, export orb_mut_m01]
def m01_missionControl_archivedRevive
    (isArchived : UInt8) (activeTrackWriters : UInt32)
    (hasLease msgAlreadyDelivered isResume : UInt8)
    (sessionCreated lineageVerified rolloutExists hasFallbackPrompt : UInt8) : UInt64 :=
  let _ := isArchived
  let lo32 : UInt32 :=
    if msgAlreadyDelivered == 1 then 4
    else if !(hasLease == 1 && activeTrackWriters == 0) then 5
    else if isResume == 1 then
      if sessionCreated == 1 && lineageVerified == 1 && rolloutExists == 1 then 258
      else if hasFallbackPrompt == 1 then 771
      else 6
    else 257
  let hi32 : UInt32 :=
    if msgAlreadyDelivered == 1 then 0
    else if !(hasLease == 1 && activeTrackWriters == 0) then 0
    else if isResume == 1 then
      if sessionCreated == 1 && lineageVerified == 1 && rolloutExists == 1 then 1
      else if hasFallbackPrompt == 1 then 1
      else 0
    else 1
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m01_missionControl_archivedRevive :
    m01_missionControl_archivedRevive 1 0 1 0 0 0 0 0 0 ≠
      missionControlStep 1 0 1 0 0 0 0 0 0 := by
  decide

/-- Mutant 1.2 (`orb_sidebar_merge_step`): Duplicate mission insertion — skips `sameMission` deduplication. -/
@[inline, export orb_mut_m02]
def m02_sidebarMerge_duplicateRow
    (existingIdOrd incomingIdOrd : UInt32)
    (existingUpdatedAtMs incomingUpdatedAtMs : UInt64)
    (incomingSupersededOrArchived isPartialPage : UInt8) : UInt64 :=
  let _ := existingIdOrd
  let _ := incomingIdOrd
  let _ := existingUpdatedAtMs
  let _ := incomingUpdatedAtMs
  let partialKeepBit : UInt32 := if isPartialPage == 1 then 2048 else 0
  let lo32 : UInt32 :=
    if incomingSupersededOrArchived == 1 then 1024 ||| partialKeepBit
    else 1795 ||| partialKeepBit
  let hi32 : UInt32 :=
    if !(incomingSupersededOrArchived == 1) then 1 else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m02_sidebarMerge_duplicateRow :
    m02_sidebarMerge_duplicateRow 7 7 100 200 0 0 ≠
      sidebarMergeStep 7 7 100 200 0 0 := by
  decide

/-- Mutant 1.3 (`orb_fork_home_step`): Fork HOME override bug (`#1302`) — honors `requestedOverrideHome == 1`. -/
@[inline, export orb_mut_m03]
def m03_forkHome_overrideHomeLeak
    (isForkOrSide sourceExists sourceIsSymlink sameWorkspace sameNode : UInt8)
    (hasCommittedTransfer requestedOverrideHome : UInt8) : UInt64 :=
  let validForkSource : Bool :=
    sourceExists == 1 && sourceIsSymlink == 0 && sameWorkspace == 1 && sameNode == 1
  let homeBits : UInt32 := if requestedOverrideHome == 1 then 65536 else 131072
  let lo32 : UInt32 :=
    if isForkOrSide == 0 then 257 ||| homeBits
    else if !validForkSource then homeBits
    else if hasCommittedTransfer == 1 then 771 ||| homeBits
    else 770 ||| homeBits
  let hi32 : UInt32 :=
    if isForkOrSide == 0 then 0
    else if !validForkSource then 78
    else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m03_forkHome_overrideHomeLeak :
    m03_forkHome_overrideHomeLeak 1 1 0 1 1 0 1 ≠
      forkHomeStep 1 1 0 1 1 0 1 := by
  decide

-- ===========================================================================
-- Family 2: Transcript reducer / streaming (stable IDs, gap buffer, replay eq)
-- ===========================================================================

/-- Mutant 2.1 (`orb_transcript_reduce_step`): Off-by-one sequence monotonicity (`>=` admits duplicate seq). -/
@[inline, export orb_mut_m04]
def m04_transcriptReduce_staleSeqAccepted
    (lastAppliedSeq incomingSeq : UInt64)
    (thinkingOpen normalizedAction isReplayFromLog : UInt8) : UInt64 :=
  let _ := isReplayFromLog
  let seqAdvances : Bool := incomingSeq >= lastAppliedSeq
  let nextSeq32 : UInt32 := (if seqAdvances then incomingSeq else lastAppliedSeq).toUInt32
  let lo32 : UInt32 :=
    if !seqAdvances then
      if thinkingOpen == 1 then 512 else 0
    else if normalizedAction == 4 then 769
    else if normalizedAction == 5 || normalizedAction == 6 || normalizedAction == 7 ||
            normalizedAction == 9 || normalizedAction == 10 then
      if thinkingOpen == 1 then 1282 else 258
    else if normalizedAction == 2 || normalizedAction == 3 || normalizedAction == 8 then
      if thinkingOpen == 1 then 771 else 259
    else
      if thinkingOpen == 1 then 512 else 0
  lo32.toUInt64 ||| (nextSeq32.toUInt64 <<< 32)

theorem kill_m04_transcriptReduce_staleSeqAccepted :
    m04_transcriptReduce_staleSeqAccepted 42 42 0 5 0 ≠
      transcriptReduceStep 42 42 0 5 0 := by
  decide

/-- Mutant 2.2 (`orb_cursor_page_step`): Inclusive cursor boundary (`>=` / `<=` double-counts boundary row). -/
@[inline, export orb_mut_m05]
def m05_cursorPage_inclusiveBoundary
    (sinceSeq beforeSeq itemSeq : UInt64)
    (hasSinceCursor hasBeforeCursor isPartialResponse existingCount : UInt32) : UInt64 :=
  let validWindow : Bool := !(hasSinceCursor == 1 && hasBeforeCursor == 1 && sinceSeq >= beforeSeq)
  let afterSince : Bool := hasSinceCursor == 0 || itemSeq >= sinceSeq
  let beforeBound : Bool := hasBeforeCursor == 0 || itemSeq <= beforeSeq
  let admitItem : Bool := validWindow && afterSince && beforeBound
  let partialBit : UInt32 := if isPartialResponse == 1 then 1024 else 0
  let lo32 : UInt32 :=
    if !validWindow then 512 ||| partialBit
    else if admitItem then 769 ||| partialBit
    else 514 ||| partialBit
  let hi32 : UInt32 :=
    if admitItem then existingCount + 1 else existingCount
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m05_cursorPage_inclusiveBoundary :
    m05_cursorPage_inclusiveBoundary 10 20 10 1 1 0 5 ≠
      cursorPageStep 10 20 10 1 1 0 5 := by
  decide

/-- Mutant 2.3 (`orb_agent_event_normalize_step`): Duplicate turn/tool filter dropped (`isDuplicateTurnOrTool` ignored). -/
@[inline, export orb_mut_m06]
def m06_agentEventNormalize_duplicateAdmitted
    (harnessKind rawEventKind isCompleted hasNonEmptyText : UInt8)
    (sessionMatchesExpected isDuplicateTurnOrTool payloadBytes maxPayloadBytes : UInt32) : UInt64 :=
  let _ := isDuplicateTurnOrTool
  let bounded : Bool := payloadBytes <= maxPayloadBytes
  let harnessValid : Bool := harnessKind <= 5
  let sessionOk : Bool :=
    sessionMatchesExpected == 1 || rawEventKind == 0 || rawEventKind == 1 || rawEventKind == 7
  let lo32 : UInt32 :=
    if !bounded then 2048
    else if !(harnessValid && sessionOk) then 2049
    else if rawEventKind == 0 then 2306
    else if rawEventKind == 1 then 2307
    else if rawEventKind == 2 then (if hasNonEmptyText == 1 then 2820 else 2049)
    else if rawEventKind == 3 then (if hasNonEmptyText == 1 then 3333 else 2049)
    else if rawEventKind == 4 then (if isCompleted == 1 then 3334 else 3335)
    else if rawEventKind == 5 then 2312
    else if rawEventKind == 6 then 3337
    else if rawEventKind == 7 then 3338
    else 2049
  let cappedBytes : UInt32 := if bounded then payloadBytes else maxPayloadBytes
  lo32.toUInt64 ||| (cappedBytes.toUInt64 <<< 32)

theorem kill_m06_agentEventNormalize_duplicateAdmitted :
    m06_agentEventNormalize_duplicateAdmitted 0 3 1 1 1 1 64 1024 ≠
      agentEventNormalizeStep 0 3 1 1 1 1 64 1024 := by
  decide

-- ===========================================================================
-- Family 3: Durable outbox / queue / leases (persistent+volatile, crash safety)
-- ===========================================================================

/-- Mutant 3.1 (`orb_queue_step`): Premature queue consumption before `durablyStarted == 1`. -/
@[inline, export orb_mut_m07]
def m07_queueStep_prematureConsume (deliveryOutcome durablyStarted : UInt8) : UInt32 :=
  let _ := durablyStarted
  if deliveryOutcome == 0 then
    256
  else if deliveryOutcome == 2 then
    65537
  else
    1

theorem kill_m07_queueStep_prematureConsume :
    m07_queueStep_prematureConsume 0 0 ≠ queueStep 0 0 := by
  decide

/-- Mutant 3.2 (`orb_verify_remote_outbox`): Superseded mission enqueue bypass (`isSuperseded` ignored). -/
@[inline, export orb_mut_m08]
def m08_verifyRemoteOutbox_supersededAdmitted
    (opKind alreadyExists sameMission isCancelled isSuperseded sessionReady
     prUnsupported hasJobId deliveryAbandonable : UInt8) : UInt8 :=
  let _ := isSuperseded
  if (opKind == 0 && ((alreadyExists == 1 && sameMission == 1 && isCancelled == 0) ||
                      (alreadyExists == 0 && sessionReady == 1 && prUnsupported == 0))) ||
     (opKind != 0 && (hasJobId == 0 || deliveryAbandonable == 1)) then 1 else 0

theorem kill_m08_verifyRemoteOutbox_supersededAdmitted :
    m08_verifyRemoteOutbox_supersededAdmitted 0 0 1 0 1 1 0 0 0 ≠
      verifyRemoteOutbox 0 0 1 0 1 1 0 0 0 := by
  decide

/-- Mutant 3.3 (`orb_verify_lease_mode`): Readonly tag precedence inverted (`writerFlag == 1` overrides `hasReadonlyTag`). -/
@[inline, export orb_mut_m09]
def m09_verifyLeaseMode_readonlyOverridden
    (writerFlag hasReadonlyTag hasWriterTag isReadonlyIntent : UInt8) : UInt8 :=
  if writerFlag == 1 || hasWriterTag == 1 then 1
  else if writerFlag == 0 || hasReadonlyTag == 1 then 0
  else if isReadonlyIntent == 1 then 0
  else 1

theorem kill_m09_verifyLeaseMode_readonlyOverridden :
    m09_verifyLeaseMode_readonlyOverridden 1 1 0 1 ≠
      verifyLeaseMode 1 1 0 1 := by
  decide

-- ===========================================================================
-- Family 4: Provider attempt lifecycle (retry budgets, first-byte fence, clocks)
-- ===========================================================================

/-- Mutant 4.1 (`orb_provider_pool_step`): First-byte commitment fence broken — fails over mid-stream. -/
@[inline, export orb_mut_m10]
def m10_providerPool_firstByteFailover
    (hasBoundAccount : UInt8) (boundAccountId candidateAccountId : UInt32)
    (isRejected firstByteSent isFailoverAttempt : UInt8)
    (attempts maxAttempts : UInt32)
    (nowEpoch resetEpoch : UInt64) : UInt64 :=
  let lockBit : UInt32 := if firstByteSent == 1 then 65536 else 0
  let lo32 : UInt32 :=
    if isFailoverAttempt == 1 && !(1 ≤ maxAttempts && attempts < maxAttempts) then 4 + lockBit
    else if hasBoundAccount == 1 && !(candidateAccountId == boundAccountId) then lockBit
    else if isRejected == 1 && nowEpoch < resetEpoch then lockBit
    else if candidateAccountId == 0 then lockBit
    else (if hasBoundAccount == 1 then 1 else 2) + 256 + lockBit
  let hi32 : UInt32 :=
    if isFailoverAttempt == 1 && !(1 ≤ maxAttempts && attempts < maxAttempts) then 0
    else if hasBoundAccount == 1 && !(candidateAccountId == boundAccountId) then 0
    else if isRejected == 1 && nowEpoch < resetEpoch then 0
    else if candidateAccountId == 0 then 0
    else candidateAccountId
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m10_providerPool_firstByteFailover :
    m10_providerPool_firstByteFailover 0 0 7 0 1 1 0 3 100 0 ≠
      providerPoolStep 0 0 7 0 1 1 0 3 100 0 := by
  decide

/-- Mutant 4.2 (`orb_proxy_step`): Committed stream retried on stall (`committed == 0` guard omitted). -/
@[inline, export orb_mut_m11]
def m11_proxyStep_retryAfterCommit
    (committed chunkCommits stalled : UInt8) (retries maxRetries : UInt32) : UInt32 :=
  let cNext : UInt32 := if committed == 1 || chunkCommits == 1 then 1 else 0
  if stalled == 1 then
    if retries < maxRetries then
      if retries + 1 ≥ 2 then cNext ||| 0x00010200
      else cNext ||| 0x00000100
    else
      cNext ||| 0x00000300
  else
    cNext

theorem kill_m11_proxyStep_retryAfterCommit :
    m11_proxyStep_retryAfterCommit 1 0 1 0 3 ≠
      proxyStep 1 0 1 0 3 := by
  decide

/-- Mutant 4.3 (`orb_breaker_step`): Transient 502 below streak threshold poisons shared subscription. -/
@[inline, export orb_mut_m12]
def m12_breakerStep_transientPoisonsSub
    (reason : UInt8) (transientStreak transientThreshold : UInt32) : UInt32 :=
  if reason == 0 then 0
  else if reason == 4 then
    if transientStreak ≥ transientThreshold && transientThreshold ≥ 1 then 65792 else 256
  else if reason == 2 || reason == 3 then
    let sub : UInt32 := if reason == 2 then 256 else 0
    (1 : UInt32) ||| sub ||| 65536
  else if reason == 1 then
    65792
  else
    65536

theorem kill_m12_breakerStep_transientPoisonsSub :
    m12_breakerStep_transientPoisonsSub 4 1 3 ≠
      breakerStep 4 1 3 := by
  decide

-- ===========================================================================
-- Family 5: Authorization (fresh scoped revocable evidence observe->gate->execute)
-- ===========================================================================

/-- Mutant 5.1 (`orb_privilege_step`): Scope escalation — omits `scopeRank ≤ maxGrantedScope` check. -/
@[inline, export orb_mut_m13]
def m13_privilegeStep_scopeEscalation
    (sameOwner missionActive biometricSigned scopeRank maxGrantedScope bunkerState revoked : UInt8)
    (nowEpoch grantExpiresAt sessionExpiresAt : UInt64) : UInt32 :=
  let _ := maxGrantedScope
  if missionActive == 0 || revoked == 1 || bunkerState != 0 ||
     grantExpiresAt ≤ nowEpoch || sessionExpiresAt ≤ nowEpoch then
    65536
  else if sameOwner == 1 && biometricSigned == 1 then
    if scopeRank < 2 then 257 else 1
  else
    0

theorem kill_m13_privilegeStep_scopeEscalation :
    m13_privilegeStep_scopeEscalation 1 1 1 2 0 0 0 100 200 200 ≠
      privilegeStep 1 1 1 2 0 0 0 100 200 200 := by
  decide

/-- Mutant 5.2 (`orb_privd_command_step`): Shell metacharacter bypass — drops `hasShellMetacharOrFlagBypass == 0`. -/
@[inline, export orb_mut_m14]
def m14_privdCommand_metacharBypass
    (leaseValid grantScope commandClass unitMatchesAllowed : UInt8)
    (hasShellMetacharOrFlagBypass hasPathTraversalOrSymlink hasUnsafeEnvVar requireForceCmd : UInt8) : UInt64 :=
  let _ := hasShellMetacharOrFlagBypass
  let safeInput : Bool :=
    leaseValid == 1 && hasPathTraversalOrSymlink == 0 && hasUnsafeEnvVar == 0
  let lo32 : UInt32 :=
    if !safeInput then 1536
    else if !(grantScope <= 2) then 1536
    else if commandClass == 1 then 1793
    else if commandClass == 2 && 1 <= grantScope && unitMatchesAllowed == 1 then 1794
    else if commandClass == 3 && 1 <= grantScope then 1794
    else if commandClass == 4 && grantScope == 2 && requireForceCmd == 0 then 1795
    else 1536
  let hi32 : UInt32 :=
    if lo32 == 1536 then 126 else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m14_privdCommand_metacharBypass :
    m14_privdCommand_metacharBypass 1 0 1 0 1 0 0 0 ≠
      privdCommandStep 1 0 1 0 1 0 0 0 := by
  decide

/-- Mutant 5.3 (`orb_verify_approval`): Critical-risk approval admitted without `confirmed == 1`. -/
@[inline, export orb_mut_m15]
def m15_verifyApproval_criticalUnconfirmed
    (signed owned pending unexpired unchanged risk confirmed : UInt8) : UInt8 :=
  let _ := risk
  let _ := confirmed
  if signed == 1 && owned == 1 && pending == 1 && unexpired == 1 && unchanged == 1 then 1 else 0

theorem kill_m15_verifyApproval_criticalUnconfirmed :
    m15_verifyApproval_criticalUnconfirmed 1 1 1 1 1 2 0 ≠
      verifyApproval 1 1 1 1 1 2 0 := by
  decide

-- ===========================================================================
-- Family 6: Scheduling / resources (reservation capacity, TTL/boot epochs)
-- ===========================================================================

/-- Mutant 6.1 (`orb_verify_board_slots`): Off-by-one `≤` steals the boss's reserved slot. -/
@[inline, export orb_mut_m16]
def m16_verifyBoardSlots_stealsBossSlot
    (maxParallel reservedBossSlots totalRunning : UInt32) : UInt8 :=
  if reservedBossSlots ≥ 1 && reservedBossSlots < maxParallel &&
     totalRunning ≤ maxParallel - reservedBossSlots then 1 else 0

theorem kill_m16_verifyBoardSlots_stealsBossSlot :
    m16_verifyBoardSlots_stealsBossSlot 4 1 3 ≠
      verifyBoardSlots 4 1 3 := by
  decide

/-- Mutant 6.2 (`orb_schedule_step`): Fires cron tick while mission is mid-turn (`busy == 1` ignored). -/
@[inline, export orb_mut_m17]
def m17_scheduleStep_fireWhileBusy
    (op known cancelled ownerTerminal authorized busy : UInt8)
    (lastFired nextDue now : UInt64) : UInt8 :=
  let _ := busy
  if authorized != 1 then 0
  else if op == 0 then (if known == 1 then 2 else if ownerTerminal == 1 then 0 else 1)
  else if cancelled == 1 || ownerTerminal == 1 then 0
  else if lastFired < nextDue && nextDue ≤ now then 3
  else 4

theorem kill_m17_scheduleStep_fireWhileBusy :
    m17_scheduleStep_fireWhileBusy 1 1 0 0 1 1 10 20 30 ≠
      scheduleStep 1 1 0 0 1 1 10 20 30 := by
  decide

/-- Mutant 6.3 (`orb_route_argmin_step`): Admissibility guard dropped (`candAdmissible == 0` still wins). -/
@[inline, export orb_mut_m18]
def m18_routeArgmin_inadmissibleSelected
    (hasBest : UInt8) (bestId : UInt32) (bestScore : UInt64)
    (candId : UInt32) (candScore : UInt64) (candAdmissible : UInt8) : UInt64 :=
  let _ := candAdmissible
  let takeCand : Bool := hasBest == 0 || candScore < bestScore
  let lo32 : UInt32 :=
    if takeCand then 257
    else if hasBest == 1 then 1
    else 0
  let hi32 : UInt32 :=
    if takeCand then candId
    else if hasBest == 1 then bestId
    else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m18_routeArgmin_inadmissibleSelected :
    m18_routeArgmin_inadmissibleSelected 1 2 50 9 10 0 ≠
      routeArgminStep 1 2 50 9 10 0 := by
  decide

-- ===========================================================================
-- Family 7: Incremental parsing / indexing / scroll (chunk eq, bounded tail)
-- ===========================================================================

/-- Mutant 7.1 (`orb_stream_fence_step`): Cross-fence closure bug — tilde fence closes open backtick fence. -/
@[inline, export orb_mut_m19]
def m19_streamFence_mismatchedMarkerCloses
    (openKind : UInt8) (openCount : UInt32) (markerKind : UInt8) (markerCount : UInt32) : UInt64 :=
  let nk : UInt8 :=
    if openKind == 0 then
      if (markerKind == 1 || markerKind == 2) && 3 ≤ markerCount then markerKind else 0
    else
      if (markerKind == 1 || markerKind == 2) && openCount ≤ markerCount && 3 ≤ markerCount then 0 else openKind
  let nc : UInt32 :=
    if openKind == 0 then
      if (markerKind == 1 || markerKind == 2) && 3 ≤ markerCount then markerCount else 0
    else
      if (markerKind == 1 || markerKind == 2) && openCount ≤ markerCount && 3 ≤ markerCount then 0 else openCount
  nk.toUInt64 ||| (nc.toUInt64 <<< 32)

theorem kill_m19_streamFence_mismatchedMarkerCloses :
    m19_streamFence_mismatchedMarkerCloses 1 3 2 3 ≠
      streamFenceStep 1 3 2 3 := by
  decide

/-- Mutant 7.2 (`orb_stream_commit_step`): Unclosed fence prematurely commits blank line inside code block. -/
@[inline, export orb_mut_m20]
def m20_streamCommit_commitsInsideOpenFence
    (tick openKind : UInt8) (openCount : UInt32)
    (lineBlank lineTick markerKind : UInt8) (markerCount pos commit : UInt32) : UInt64 :=
  let nextTick : UInt8 := if lineTick == 1 then (if tick == 1 then 0 else 1) else (if tick == 1 then 1 else 0)
  let nextFenceKind := streamNextFenceKind openKind openCount markerKind markerCount
  let nextPos := satAdd32 pos 1
  let commits : UInt8 := if lineBlank == 1 && nextTick == 0 then 1 else 0
  let nextCommit : UInt32 := if commits == 1 then nextPos else commit
  let nextFenceBits : UInt32 :=
    if nextFenceKind == 1 then 256 else if nextFenceKind == 2 then 512 else 0
  let commitBits : UInt32 := if commits == 1 then 65536 else 0
  let lo32 : UInt32 := nextTick.toUInt32 ||| nextFenceBits ||| commitBits
  lo32.toUInt64 ||| (nextCommit.toUInt64 <<< 32)

theorem kill_m20_streamCommit_commitsInsideOpenFence :
    m20_streamCommit_commitsInsideOpenFence 0 1 3 1 0 0 0 10 4 ≠
      streamCommitStep 0 1 3 1 0 0 0 10 4 := by
  decide

/-- Mutant 7.3 (`orb_scroll_epoch_step`): Double scroll correction within same layout epoch (`alreadyCorrected` ignored). -/
@[inline, export orb_mut_m21]
def m21_scrollEpoch_doubleCorrectionInEpoch
    (layoutEpoch lastCorrectedEpoch : UInt32)
    (correctionsInEpoch isPinnedToBottom userIsDragging : UInt8)
    (targetScrollTopPx currentScrollTopPx : UInt32) : UInt64 :=
  let _ := layoutEpoch
  let _ := lastCorrectedEpoch
  let _ := correctionsInEpoch
  let needsDelta : Bool := targetScrollTopPx != currentScrollTopPx
  let admitCorrection : Bool :=
    isPinnedToBottom == 1 && userIsDragging == 0 && needsDelta
  let lo32 : UInt32 :=
    if admitCorrection then 1281 else 0
  let hi32 : UInt32 :=
    if admitCorrection then targetScrollTopPx else currentScrollTopPx
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

theorem kill_m21_scrollEpoch_doubleCorrectionInEpoch :
    m21_scrollEpoch_doubleCorrectionInEpoch 5 5 1 1 0 480 320 ≠
      scrollEpochStep 5 5 1 1 0 480 320 := by
  decide

-- ===========================================================================
-- Family 8: R2-A Epoch Fence (`orb_epoch_fence_step`)
-- ===========================================================================

/-- Mutant 8.1 (`orb_epoch_fence_step`): Stale `liveRevision` accepted (`revMatch` omitted). -/
@[inline, export orb_mut_m22]
def m22_epochFence_staleRevisionAccepted
    (durableOwnerEpoch liveOwnerEpoch : UInt64)
    (durableRunGeneration liveRunGeneration : UInt64)
    (durableBootEpoch liveBootEpoch : UInt64)
    (durableRevision liveRevision : UInt32)
    (writerOwnerEpoch : UInt64) : UInt64 :=
  let _ := liveRevision
  let ownerOk : Bool := writerOwnerEpoch == durableOwnerEpoch && writerOwnerEpoch == liveOwnerEpoch
  let runOk : Bool := liveRunGeneration == durableRunGeneration
  let bootOk : Bool := liveBootEpoch == durableBootEpoch
  let revRoom : Bool := durableRevision < 0xFFFFFFFF
  let shaped : Bool :=
    durableOwnerEpoch != 0 && durableRunGeneration != 0 && durableBootEpoch != 0 && durableRevision != 0
  let lo32 : UInt32 :=
    if !shaped then 0
    else if !ownerOk then 5
    else if !runOk then 3
    else if !bootOk then 4
    else if !revRoom then 6
    else 257
  let nextRev : UInt32 := if lo32 == 257 then durableRevision + 1 else durableRevision
  lo32.toUInt64 ||| (nextRev.toUInt64 <<< 32)

theorem kill_m22_epochFence_staleRevisionAccepted :
    m22_epochFence_staleRevisionAccepted 11 11 3 3 5 5 10 9 11 ≠
      epochFenceStep 11 11 3 3 5 5 10 9 11 := by
  decide

/-- Mutant 8.2 (`orb_epoch_fence_step`): Pre-crash boot epoch accepted (`bootOk` omitted). -/
@[inline, export orb_mut_m23]
def m23_epochFence_staleBootEpochAccepted
    (durableOwnerEpoch liveOwnerEpoch : UInt64)
    (durableRunGeneration liveRunGeneration : UInt64)
    (durableBootEpoch liveBootEpoch : UInt64)
    (durableRevision liveRevision : UInt32)
    (writerOwnerEpoch : UInt64) : UInt64 :=
  let _ := liveBootEpoch
  let ownerOk : Bool := writerOwnerEpoch == durableOwnerEpoch && writerOwnerEpoch == liveOwnerEpoch
  let runOk : Bool := liveRunGeneration == durableRunGeneration
  let revMatch : Bool := liveRevision == durableRevision
  let revRoom : Bool := durableRevision < 0xFFFFFFFF
  let shaped : Bool :=
    durableOwnerEpoch != 0 && durableRunGeneration != 0 && durableBootEpoch != 0 && durableRevision != 0
  let lo32 : UInt32 :=
    if !shaped then 0
    else if !ownerOk then 5
    else if !revMatch then 2
    else if !runOk then 3
    else if !revRoom then 6
    else 257
  let nextRev : UInt32 := if lo32 == 257 then durableRevision + 1 else durableRevision
  lo32.toUInt64 ||| (nextRev.toUInt64 <<< 32)

theorem kill_m23_epochFence_staleBootEpochAccepted :
    m23_epochFence_staleBootEpochAccepted 11 11 3 3 6 5 10 10 11 ≠
      epochFenceStep 11 11 3 3 6 5 10 10 11 := by
  decide

/-- Mutant 8.3 (`orb_epoch_fence_step`): Saturated `0xFFFFFFFF` revision wraps around to `0`. -/
@[inline, export orb_mut_m24]
def m24_epochFence_saturatedRevisionWraps
    (durableOwnerEpoch liveOwnerEpoch : UInt64)
    (durableRunGeneration liveRunGeneration : UInt64)
    (durableBootEpoch liveBootEpoch : UInt64)
    (durableRevision liveRevision : UInt32)
    (writerOwnerEpoch : UInt64) : UInt64 :=
  let ownerOk : Bool := writerOwnerEpoch == durableOwnerEpoch && writerOwnerEpoch == liveOwnerEpoch
  let runOk : Bool := liveRunGeneration == durableRunGeneration
  let bootOk : Bool := liveBootEpoch == durableBootEpoch
  let revMatch : Bool := liveRevision == durableRevision
  let shaped : Bool :=
    durableOwnerEpoch != 0 && durableRunGeneration != 0 && durableBootEpoch != 0 && durableRevision != 0
  let lo32 : UInt32 :=
    if !shaped then 0
    else if !ownerOk then 5
    else if !revMatch then 2
    else if !runOk then 3
    else if !bootOk then 4
    else 257
  let nextRev : UInt32 := if lo32 == 257 then durableRevision + 1 else durableRevision
  lo32.toUInt64 ||| (nextRev.toUInt64 <<< 32)

theorem kill_m24_epochFence_saturatedRevisionWraps :
    m24_epochFence_saturatedRevisionWraps 11 11 3 3 5 5 0xFFFFFFFF 0xFFFFFFFF 11 ≠
      epochFenceStep 11 11 3 3 5 5 0xFFFFFFFF 0xFFFFFFFF 11 := by
  decide

-- ===========================================================================
-- Family 9: R2-A Effect Outbox (`orb_effect_outbox_step`)
-- ===========================================================================

/-- Mutant 9.1 (`orb_effect_outbox_step`): Fresh retry (`Claim`) allowed out of `Uncertain (4)`. -/
@[inline, export orb_mut_m25]
def m25_effectOutbox_uncertainFreshRetry
    (phase delivered op fenceMatches : UInt8)
    (attemptEpoch nodeBootEpoch : UInt64) : UInt64 :=
  let fenceOk : Bool := fenceMatches == 1 && attemptEpoch == nodeBootEpoch && attemptEpoch != 0
  let phaseOk : Bool := phase ≤ 5
  let opOk : Bool := op ≤ 5
  let nextPhase : UInt8 :=
    if !fenceOk then phase
    else if !phaseOk then phase
    else if !opOk then phase
    else if op == 0 then (if phase == 3 then 0 else if phase == 5 then 0 else phase)
    else if op == 1 then (if phase == 0 then 1 else if phase == 4 then 1 else phase)
    else if op == 2 then (if phase == 1 then 2 else phase)
    else if op == 3 then (if phase == 1 then 3 else phase)
    else if op == 4 then (if phase == 1 then 4 else phase)
    else if op == 5 then (if phase == 4 then 5 else phase)
    else phase
  let moved : Bool := nextPhase != phase
  let deliveredNext : UInt8 :=
    if !moved then delivered
    else if nextPhase == 2 then 1
    else if nextPhase == 0 || nextPhase == 3 then 0
    else delivered
  let lo32 : UInt32 :=
    if !fenceOk then 4
    else if !phaseOk || !opOk then 0
    else if moved then (257 : UInt32) ||| (nextPhase.toUInt32 <<< 16)
    else 2
  lo32.toUInt64 ||| (deliveredNext.toUInt32.toUInt64 <<< 32)

theorem kill_m25_effectOutbox_uncertainFreshRetry :
    m25_effectOutbox_uncertainFreshRetry 4 0 1 1 9 9 ≠
      effectOutboxStep 4 0 1 1 9 9 := by
  decide

/-- Mutant 9.2 (`orb_effect_outbox_step`): `Reconcile` fabricates delivery (`deliveredNext = 1`). -/
@[inline, export orb_mut_m26]
def m26_effectOutbox_reconcileDoubleDelivers
    (phase delivered op fenceMatches : UInt8)
    (attemptEpoch nodeBootEpoch : UInt64) : UInt64 :=
  let fenceOk : Bool := fenceMatches == 1 && attemptEpoch == nodeBootEpoch && attemptEpoch != 0
  let phaseOk : Bool := phase ≤ 5
  let opOk : Bool := op ≤ 5
  let nextPhase : UInt8 :=
    if !fenceOk then phase
    else if !phaseOk then phase
    else if !opOk then phase
    else if op == 0 then (if phase == 3 then 0 else if phase == 5 then 0 else phase)
    else if op == 1 then (if phase == 0 then 1 else phase)
    else if op == 2 then (if phase == 1 then 2 else phase)
    else if op == 3 then (if phase == 1 then 3 else phase)
    else if op == 4 then (if phase == 1 then 4 else phase)
    else if op == 5 then (if phase == 4 then 5 else phase)
    else phase
  let moved : Bool := nextPhase != phase
  let deliveredNext : UInt8 :=
    if !moved then delivered
    else if nextPhase == 2 then 1
    else if nextPhase == 5 then 1
    else if nextPhase == 0 || nextPhase == 3 then 0
    else delivered
  let freshRetry : Bool := (op == 1 || op == 2) && phase == 4
  let lo32 : UInt32 :=
    if !fenceOk then 4
    else if !phaseOk || !opOk then 0
    else if freshRetry then 3
    else if moved then (257 : UInt32) ||| (nextPhase.toUInt32 <<< 16)
    else 2
  lo32.toUInt64 ||| (deliveredNext.toUInt32.toUInt64 <<< 32)

theorem kill_m26_effectOutbox_reconcileDoubleDelivers :
    m26_effectOutbox_reconcileDoubleDelivers 4 0 5 1 9 9 ≠
      effectOutboxStep 4 0 5 1 9 9 := by
  decide

/-- Mutant 9.3 (`orb_effect_outbox_step`): Stale-boot attempt commits outbox transition (`attemptEpoch == nodeBootEpoch` dropped). -/
@[inline, export orb_mut_m27]
def m27_effectOutbox_unfencedBootCommit
    (phase delivered op fenceMatches : UInt8)
    (attemptEpoch nodeBootEpoch : UInt64) : UInt64 :=
  let _ := nodeBootEpoch
  let fenceOk : Bool := fenceMatches == 1 && attemptEpoch != 0
  let phaseOk : Bool := phase ≤ 5
  let opOk : Bool := op ≤ 5
  let nextPhase : UInt8 :=
    if !fenceOk then phase
    else if !phaseOk then phase
    else if !opOk then phase
    else if op == 0 then (if phase == 3 then 0 else if phase == 5 then 0 else phase)
    else if op == 1 then (if phase == 0 then 1 else phase)
    else if op == 2 then (if phase == 1 then 2 else phase)
    else if op == 3 then (if phase == 1 then 3 else phase)
    else if op == 4 then (if phase == 1 then 4 else phase)
    else if op == 5 then (if phase == 4 then 5 else phase)
    else phase
  let moved : Bool := nextPhase != phase
  let deliveredNext : UInt8 :=
    if !moved then delivered
    else if nextPhase == 2 then 1
    else if nextPhase == 0 || nextPhase == 3 then 0
    else delivered
  let freshRetry : Bool := (op == 1 || op == 2) && phase == 4
  let lo32 : UInt32 :=
    if !fenceOk then 4
    else if !phaseOk || !opOk then 0
    else if freshRetry then 3
    else if moved then (257 : UInt32) ||| (nextPhase.toUInt32 <<< 16)
    else 2
  lo32.toUInt64 ||| (deliveredNext.toUInt32.toUInt64 <<< 32)

theorem kill_m27_effectOutbox_unfencedBootCommit :
    m27_effectOutbox_unfencedBootCommit 1 0 2 1 8 9 ≠
      effectOutboxStep 1 0 2 1 8 9 := by
  decide

-- ===========================================================================
-- Family 10: R2-A Crash-Boundary Conservation (`orb_crash_boundary_step`, `G-ORB-2`)
-- ===========================================================================

/-- Mutant 10.1 (`orb_crash_boundary_step`): Corrupt WAL (`durableAcked > durableQueued`) underflows `UInt32` instead of failing closed. -/
@[inline, export orb_mut_m28]
def m28_crashBoundary_corruptWalAdmitted
    (durableQueued durableAcked : UInt32)
    (stateRevision : UInt64)
    (volatileInFlight : UInt32)
    (leaseBootEpoch nodeBootEpoch : UInt64)
    (volatileLeaseOwner reqOwner : UInt32) : UInt64 :=
  let validWal : Bool := stateRevision != 0
  let unacked : UInt32 := if validWal then durableQueued - durableAcked else 0
  let crashReset : Bool := leaseBootEpoch != nodeBootEpoch
  let effOwner : UInt32 := if crashReset then 0 else volatileLeaseOwner
  let effInFlight : UInt32 := if crashReset then 0 else volatileInFlight
  let canAcquire : Bool :=
    validWal && unacked > 0 && reqOwner != 0 &&
    (effOwner == 0 || effOwner == reqOwner) && effInFlight < unacked
  let nextOwner : UInt32 := if canAcquire then reqOwner else effOwner
  let writerBit : UInt32 := if nextOwner != 0 then 1024 else 0
  let crashBit : UInt32 := if crashReset then 512 else 0
  let lo32 : UInt32 :=
    if !validWal then 0
    else if canAcquire then 257 ||| crashBit ||| writerBit
    else (if unacked == 0 then 2 else 3) ||| crashBit ||| writerBit
  lo32.toUInt64 ||| (unacked.toUInt64 <<< 32)

theorem kill_m28_crashBoundary_corruptWalAdmitted :
    m28_crashBoundary_corruptWalAdmitted 2 5 1 0 9 9 0 7 ≠
      crashBoundaryStep 2 5 1 0 9 9 0 7 := by
  decide

/-- Mutant 10.2 (`orb_crash_boundary_step`): Volatile lease owner survives node reboot (`crashReset` ignored on `effOwner`). -/
@[inline, export orb_mut_m29]
def m29_crashBoundary_volatileLeaseSurvivesReboot
    (durableQueued durableAcked : UInt32)
    (stateRevision : UInt64)
    (volatileInFlight : UInt32)
    (leaseBootEpoch nodeBootEpoch : UInt64)
    (volatileLeaseOwner reqOwner : UInt32) : UInt64 :=
  let validWal : Bool := durableAcked ≤ durableQueued && stateRevision != 0
  let unacked : UInt32 := if validWal then durableQueued - durableAcked else 0
  let crashReset : Bool := leaseBootEpoch != nodeBootEpoch
  let effOwner : UInt32 := volatileLeaseOwner
  let effInFlight : UInt32 := if crashReset then 0 else volatileInFlight
  let canAcquire : Bool :=
    validWal && unacked > 0 && reqOwner != 0 &&
    (effOwner == 0 || effOwner == reqOwner) && effInFlight < unacked
  let nextOwner : UInt32 := if canAcquire then reqOwner else effOwner
  let writerBit : UInt32 := if nextOwner != 0 then 1024 else 0
  let crashBit : UInt32 := if crashReset then 512 else 0
  let lo32 : UInt32 :=
    if !validWal then 0
    else if canAcquire then 257 ||| crashBit ||| writerBit
    else (if unacked == 0 then 2 else 3) ||| crashBit ||| writerBit
  lo32.toUInt64 ||| (unacked.toUInt64 <<< 32)

theorem kill_m29_crashBoundary_volatileLeaseSurvivesReboot :
    m29_crashBoundary_volatileLeaseSurvivesReboot 5 2 1 0 8 9 4 7 ≠
      crashBoundaryStep 5 2 1 0 8 9 4 7 := by
  decide

/-- Mutant 10.3 (`orb_crash_boundary_step`): Dual-writer steal on live node (`effOwner == 0 || effOwner == reqOwner` omitted). -/
@[inline, export orb_mut_m30]
def m30_crashBoundary_dualWriterSteal
    (durableQueued durableAcked : UInt32)
    (stateRevision : UInt64)
    (volatileInFlight : UInt32)
    (leaseBootEpoch nodeBootEpoch : UInt64)
    (volatileLeaseOwner reqOwner : UInt32) : UInt64 :=
  let validWal : Bool := durableAcked ≤ durableQueued && stateRevision != 0
  let unacked : UInt32 := if validWal then durableQueued - durableAcked else 0
  let crashReset : Bool := leaseBootEpoch != nodeBootEpoch
  let effOwner : UInt32 := if crashReset then 0 else volatileLeaseOwner
  let effInFlight : UInt32 := if crashReset then 0 else volatileInFlight
  let canAcquire : Bool :=
    validWal && unacked > 0 && reqOwner != 0 && effInFlight < unacked
  let nextOwner : UInt32 := if canAcquire then reqOwner else effOwner
  let writerBit : UInt32 := if nextOwner != 0 then 1024 else 0
  let crashBit : UInt32 := if crashReset then 512 else 0
  let lo32 : UInt32 :=
    if !validWal then 0
    else if canAcquire then 257 ||| crashBit ||| writerBit
    else (if unacked == 0 then 2 else 3) ||| crashBit ||| writerBit
  lo32.toUInt64 ||| (unacked.toUInt64 <<< 32)

theorem kill_m30_crashBoundary_dualWriterSteal :
    m30_crashBoundary_dualWriterSteal 5 2 1 0 9 9 4 7 ≠
      crashBoundaryStep 5 2 1 0 9 9 4 7 := by
  decide

-- Phase R6-A Domain Mutants (`orb_mut_m31`..`orb_mut_m39`)

/-- Mutant 11.1 (`orb_followup_queue_step`): Stale `expectedServerRev` still advances edit CAS. -/
@[inline, export orb_mut_m31]
def m31_followupQueue_staleRevisionAccepted
    (op : UInt8)
    (serverRev incomingServerRev expectedServerRev : UInt32)
    (clientMsgId trackedMsgId deliveredMsgId : UInt64)
    (postedAfterSeq turnSeq : UInt64)
    (optimisticSending serverListed contentMatched alreadyDelivered : UInt8) : UInt64 :=
  let effExpected : UInt32 :=
    if op == 1 && expectedServerRev != serverRev then serverRev else expectedServerRev
  followupQueueStep op serverRev incomingServerRev effExpected
    clientMsgId trackedMsgId deliveredMsgId postedAfterSeq turnSeq
    optimisticSending serverListed contentMatched alreadyDelivered

theorem kill_m31_followupQueue_staleRevisionAccepted :
    m31_followupQueue_staleRevisionAccepted 1 5 5 4 42 42 0 10 10 0 0 0 0 ≠
      followupQueueStep 1 5 5 4 42 42 0 10 10 0 0 0 0 := by
  decide

/-- Mutant 11.2 (`orb_followup_queue_step`): Historical `turnSeq` retires optimistic row. -/
@[inline, export orb_mut_m32]
def m32_followupQueue_historicalSeqRetires
    (op : UInt8)
    (serverRev incomingServerRev expectedServerRev : UInt32)
    (clientMsgId trackedMsgId deliveredMsgId : UInt64)
    (postedAfterSeq turnSeq : UInt64)
    (optimisticSending serverListed contentMatched alreadyDelivered : UInt8) : UInt64 :=
  let bumpedTurn : UInt64 := if turnSeq == postedAfterSeq then turnSeq + 1 else turnSeq
  followupQueueStep op serverRev incomingServerRev expectedServerRev
    clientMsgId trackedMsgId deliveredMsgId postedAfterSeq bumpedTurn
    optimisticSending serverListed contentMatched alreadyDelivered

theorem kill_m32_followupQueue_historicalSeqRetires :
    m32_followupQueue_historicalSeqRetires 3 5 5 5 42 42 0 10 10 0 0 1 0 ≠
      followupQueueStep 3 5 5 5 42 42 0 10 10 0 0 1 0 := by
  decide

/-- Mutant 11.3 (`orb_followup_queue_step`): Duplicate `clientMsgId` double-applies enqueue. -/
@[inline, export orb_mut_m33]
def m33_followupQueue_duplicateClientMsgDoubleApplies
    (op : UInt8)
    (serverRev incomingServerRev expectedServerRev : UInt32)
    (clientMsgId trackedMsgId deliveredMsgId : UInt64)
    (postedAfterSeq turnSeq : UInt64)
    (optimisticSending serverListed contentMatched alreadyDelivered : UInt8) : UInt64 :=
  let effTracked : UInt64 :=
    if op == 2 && clientMsgId == trackedMsgId then 0 else trackedMsgId
  followupQueueStep op serverRev incomingServerRev expectedServerRev
    clientMsgId effTracked deliveredMsgId postedAfterSeq turnSeq
    optimisticSending serverListed contentMatched alreadyDelivered

theorem kill_m33_followupQueue_duplicateClientMsgDoubleApplies :
    m33_followupQueue_duplicateClientMsgDoubleApplies 2 5 5 5 42 42 0 10 10 0 0 0 0 ≠
      followupQueueStep 2 5 5 5 42 42 0 10 10 0 0 0 0 := by
  decide

/-- Mutant 12.1 (`orb_transport_epoch_step`): `everReady == 1` blocks SSE fallback. -/
@[inline, export orb_mut_m34]
def m34_transportEpoch_everReadyBlocksFallback
    (mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq : UInt8)
    (failureStreak failThreshold httpStatus sinceSeq32 : UInt32)
    (nowMs cooldownUntilMs : UInt64) : UInt64 :=
  let w := transportEpochStep mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq
    failureStreak failThreshold httpStatus sinceSeq32 nowMs cooldownUntilMs
  if everReady == 1 && eventKind == 1 then
    let lo := ((w &&& 0xFFFFFFFF).toUInt32 &&& (0xFFFFFB00 : UInt32))
    lo.toUInt64 ||| (w &&& 0xFFFFFFFF00000000)
  else w

theorem kill_m34_transportEpoch_everReadyBlocksFallback :
    m34_transportEpoch_everReadyBlocksFallback 0 1 1 0 0 0 1 1 2 0 40 0 0 ≠
      transportEpochStep 0 1 1 0 0 0 1 1 2 0 40 0 0 := by
  decide

/-- Mutant 12.2 (`orb_transport_epoch_step`): SSE fallback resets `sinceSeq32` and presence bit to `0`. -/
@[inline, export orb_mut_m35]
def m35_transportEpoch_fallbackDropsSinceSeq
    (mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq : UInt8)
    (failureStreak failThreshold httpStatus sinceSeq32 : UInt32)
    (nowMs cooldownUntilMs : UInt64) : UInt64 :=
  let w := transportEpochStep mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq
    failureStreak failThreshold httpStatus sinceSeq32 nowMs cooldownUntilMs
  if ((w &&& 0xFFFFFFFF).toUInt32 &&& 1024) != 0 then
    ((w &&& 0xFFFFFFFF) &&& (0xFFFFEFFF : UInt64))
  else w

theorem kill_m35_transportEpoch_fallbackDropsSinceSeq :
    m35_transportEpoch_fallbackDropsSinceSeq 0 1 1 0 0 0 1 1 2 0 40 0 0 ≠
      transportEpochStep 0 1 1 0 0 0 1 1 2 0 40 0 0 := by
  decide

/-- Mutant 12.3 (`orb_transport_epoch_step`): Transient WS failure sets sticky unsupported bit. -/
@[inline, export orb_mut_m36]
def m36_transportEpoch_transientSetsStickyUnsupported
    (mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq : UInt8)
    (failureStreak failThreshold httpStatus sinceSeq32 : UInt32)
    (nowMs cooldownUntilMs : UInt64) : UInt64 :=
  let w := transportEpochStep mode eventKind everReady stickyUnsupported endpointClass prevEndpointClass hasSinceSeq
    failureStreak failThreshold httpStatus sinceSeq32 nowMs cooldownUntilMs
  if eventKind == 1 then w ||| (512 : UInt64) else w

theorem kill_m36_transportEpoch_transientSetsStickyUnsupported :
    m36_transportEpoch_transientSetsStickyUnsupported 0 1 1 0 0 0 1 1 2 0 40 0 0 ≠
      transportEpochStep 0 1 1 0 0 0 1 1 2 0 40 0 0 := by
  decide

/-- Mutant 13.1 (`orb_stream_open_tail_cap_step`): Unclosed fence freezes `prevCheckpoint`. -/
@[inline, export orb_mut_m37]
def m37_streamOpenTailCap_openFenceFreezesCheckpoint
    (prevLen prevCommit prevCheckpoint : UInt32)
    (newLen rawCommit maxOpenTailBytes : UInt32)
    (openFenceActive : UInt8) : UInt64 :=
  if openFenceActive == 1 then
    (257 : UInt64) ||| (prevCheckpoint.toUInt64 <<< 32)
  else
    streamOpenTailCapStep prevLen prevCommit prevCheckpoint newLen rawCommit maxOpenTailBytes openFenceActive

theorem kill_m37_streamOpenTailCap_openFenceFreezesCheckpoint :
    m37_streamOpenTailCap_openFenceFreezesCheckpoint 20 5 12 40 5 8 1 ≠
      streamOpenTailCapStep 20 5 12 40 5 8 1 := by
  decide

/-- Mutant 13.2 (`orb_stream_open_tail_cap_step`): Zero cap (`maxOpenTailBytes == 0`) admitted. -/
@[inline, export orb_mut_m38]
def m38_streamOpenTailCap_zeroCapAdmitted
    (prevLen prevCommit prevCheckpoint : UInt32)
    (newLen rawCommit maxOpenTailBytes : UInt32)
    (openFenceActive : UInt8) : UInt64 :=
  let effCap := if maxOpenTailBytes == 0 then 1 else maxOpenTailBytes
  streamOpenTailCapStep prevLen prevCommit prevCheckpoint newLen rawCommit effCap openFenceActive

theorem kill_m38_streamOpenTailCap_zeroCapAdmitted :
    m38_streamOpenTailCap_zeroCapAdmitted 20 5 12 40 5 0 1 ≠
      streamOpenTailCapStep 20 5 12 40 5 0 1 := by
  decide

/-- Mutant 13.3 (`orb_stream_open_tail_cap_step`): Checkpoint regresses behind `prevCheckpoint`. -/
@[inline, export orb_mut_m39]
def m39_streamOpenTailCap_checkpointRegresses
    (prevLen prevCommit prevCheckpoint : UInt32)
    (newLen rawCommit maxOpenTailBytes : UInt32)
    (openFenceActive : UInt8) : UInt64 :=
  let w := streamOpenTailCapStep prevLen prevCommit prevCheckpoint newLen rawCommit maxOpenTailBytes openFenceActive
  let capFloor : UInt32 := if maxOpenTailBytes ≤ newLen then newLen - maxOpenTailBytes else 0
  if ((w &&& 0xFFFFFFFF).toUInt32 &&& (256 : UInt32)) != 0 then
    ((w &&& 0xFFFFFFFF).toUInt32).toUInt64 ||| (capFloor.toUInt64 <<< 32)
  else w

theorem kill_m39_streamOpenTailCap_checkpointRegresses :
    m39_streamOpenTailCap_checkpointRegresses 20 5 18 22 5 8 1 ≠
      streamOpenTailCapStep 20 5 18 22 5 8 1 := by
  decide

end Orb.MutantSuite
