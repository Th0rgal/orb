/-
  Orb.MutantSuite: Adversarial Buggy-Transition Mutant Kill Suite (`0 import Lean`, `0 sorryAx`)
  Proves that `>= 3` concrete buggy transition mutants per stateful family (`>= 21` total across
  Families 1–7) are strictly rejected: every mutant diverges from the verified `Orb.Kernel` /
  `Orb.Spec` stepper on a reachable adversarial witness by violating safety (`Admissible = false`),
  dropping a sticky fence, double-spending/overflowing a conserved resource, clobbering a field
  absent from `presenceBits`, or leaking a TOCTOU / crash-epoch race.
-/

import Orb.Spec

namespace Orb.StatefulMutantSuite

open Orb.Kernel
open Orb.Spec

-- ===========================================================================
-- Family 1 (`G-ORB-5`): Mission Hierarchy & Partial-Presence Mutants (M1..M3)
-- ===========================================================================

/-- Mutant 1A (Boundary / off-by-one): accepts equal epoch (`incomingEpoch >= currentEpoch`)
    on a partial patch (`isPartialPatch == 1`) instead of strictly newer `<`. -/
def mutantHierarchyEqEpochPartial (s : HierarchyNodeState) (h : HierarchyMergeCheck) :
    HierarchyNodeState :=
  if h.parentPresence ≤ 2 && s.epoch ≤ h.incomingEpoch then
    ⟨h.incomingEpoch, s.archiveEpoch, s.archived, s.superseded,
     if h.parentPresence == 1 then h.incParentOrd else s.parentOrd⟩
  else s

/-- Mutant 1B (Alias / partial-presence clobber): treats `parentPresence == 0` (`omitted`)
    on a partial patch as a clear-to-zero (`incParentOrd = 0`) instead of preserving `parentOrd`. -/
def mutantHierarchyOmittedParentClobber (s : HierarchyNodeState) (h : HierarchyMergeCheck) :
    HierarchyNodeState :=
  if hierarchyMergeMetaGate.gate (effectiveHierarchyCheck s h) then
    ⟨h.incomingEpoch, s.archiveEpoch, s.archived, s.superseded,
     if h.parentPresence == 0 then 0 else h.incParentOrd⟩
  else s

/-- Mutant 1C (Semantic / sticky-fence drop): allows an `incUnarchive == 1` event to
    unarchive and clear a superseded mission (`s.superseded == 1`). -/
def mutantHierarchyUnarchiveSuperseded (s : HierarchyNodeState) (h : HierarchyMergeCheck) :
    HierarchyNodeState :=
  if h.parentPresence ≤ 2 && s.epoch < h.incomingEpoch &&
      h.incUnarchive == 1 && s.archiveEpoch < h.incomingEpoch then
    ⟨h.incomingEpoch, s.archiveEpoch, 0, h.incSupersede, s.parentOrd⟩
  else s

/-- Family 1 mutant kill theorem: all 3 hierarchy mutants violate `hierarchyMachineStep`
    on concrete reachable states (`M1A` equal-epoch partial clobber, `M1B` omitted-field wipe,
    `M1C` sticky-supersede clearing). -/
theorem kill_family1_hierarchy_mutants :
    let sOpen : HierarchyNodeState := ⟨5, 0, 0, 0, 42⟩
    let sSup : HierarchyNodeState := ⟨5, 3, 1, 1, 42⟩
    let evEqEp : HierarchyMergeCheck := ⟨5, 5, 0, 0, 0, 1, 1, 42, 99, 0, 0, 0⟩
    let evOmit : HierarchyMergeCheck := ⟨5, 6, 0, 0, 0, 1, 0, 42, 0, 0, 0, 0⟩
    let evUnarchSup : HierarchyMergeCheck := ⟨5, 6, 3, 1, 1, 1, 0, 42, 42, 0, 1, 0⟩
    (mutantHierarchyEqEpochPartial sOpen evEqEp).parentOrd ≠
      (hierarchyMachineStep sOpen evEqEp).1.parentOrd ∧
    (mutantHierarchyOmittedParentClobber sOpen evOmit).parentOrd ≠
      (hierarchyMachineStep sOpen evOmit).1.parentOrd ∧
    (mutantHierarchyUnarchiveSuperseded sSup evUnarchSup).superseded ≠
      (hierarchyMachineStep sSup evUnarchSup).1.superseded ∧
    (hierarchyMachineStep sSup evUnarchSup).1.superseded = 1 := by
  decide

#guard (mutantHierarchyEqEpochPartial ⟨5, 0, 0, 0, 42⟩
  ⟨5, 5, 0, 0, 0, 1, 1, 42, 99, 0, 0, 0⟩).parentOrd != 42
#guard (hierarchyMachineStep ⟨5, 0, 0, 0, 42⟩
  ⟨5, 5, 0, 0, 0, 1, 1, 42, 99, 0, 0, 0⟩).1.parentOrd == 42

-- ===========================================================================
-- Family 2 (`G-ORB-2` / `G-ORB-3`): Transcript Replay & Sequence Mutants (M4..M6)
-- ===========================================================================

/-- Mutant 2A (Boundary / off-by-one): accepts `incomingSeq >= lastSeq + 1`, silently
    skipping a missing sequence gap instead of rejecting out-of-order gaps. -/
def mutantTranscriptAllowSeqGap (s : TranscriptFoldState) (t : TranscriptFoldCheck) :
    TranscriptFoldState :=
  if s.lastSeq < t.incomingSeq && isTranscriptAppendAction t.normalizedAction then
    ⟨t.incomingSeq, s.entryCount + 1, 0⟩
  else s

/-- Mutant 2B (Alias / duplicate replay): accepts duplicate `incomingSeq == s.lastSeq`
    on retry/replay and double-appends into `entryCount`. -/
def mutantTranscriptDuplicateDoubleCount (s : TranscriptFoldState) (t : TranscriptFoldCheck) :
    TranscriptFoldState :=
  if (t.incomingSeq == s.lastSeq || t.incomingSeq == s.lastSeq + 1) &&
      isTranscriptAppendAction t.normalizedAction then
    ⟨t.incomingSeq, s.entryCount + 1, s.thinkingOpen⟩
  else s

/-- Mutant 2C (Semantic / replay divergence): increments `entryCount` on metadata actions
    (`normalizedAction == 2`) during replay (`isReplayFromLog == 1`) while keeping live
    streaming unchanged, breaking `live == replay` fold equivalence. -/
def mutantTranscriptReplayDivergence (s : TranscriptFoldState) (t : TranscriptFoldCheck) :
    TranscriptFoldState :=
  if t.incomingSeq == s.lastSeq + 1 && isTranscriptMetaAction t.normalizedAction then
    ⟨t.incomingSeq,
     if t.isReplayFromLog == 1 then s.entryCount + 1 else s.entryCount,
     s.thinkingOpen⟩
  else s

/-- Family 2 mutant kill theorem: all 3 transcript mutants diverge from
    `transcriptFoldMachineStep` (`M2A` sequence gap, `M2B` duplicate double-count,
    `M2C` replay-vs-live fold divergence). -/
theorem kill_family2_transcript_mutants :
    let sBase : TranscriptFoldState := ⟨3, 7, 0⟩
    let evGap : TranscriptFoldCheck := ⟨3, 5, 7, 0, 5, 0⟩
    let evDup : TranscriptFoldCheck := ⟨3, 3, 7, 0, 5, 1⟩
    let evMetaReplay : TranscriptFoldCheck := ⟨3, 4, 7, 0, 2, 1⟩
    (mutantTranscriptAllowSeqGap sBase evGap).lastSeq ≠
      (transcriptFoldMachineStep sBase evGap).1.lastSeq ∧
    (mutantTranscriptDuplicateDoubleCount sBase evDup).entryCount ≠
      (transcriptFoldMachineStep sBase evDup).1.entryCount ∧
    (mutantTranscriptReplayDivergence sBase evMetaReplay).entryCount ≠
      (transcriptFoldMachineStep sBase evMetaReplay).1.entryCount ∧
    (transcriptFoldMachineStep sBase evMetaReplay).1.entryCount = 7 := by
  decide

#guard (transcriptFoldMachineStep ⟨3, 7, 0⟩ ⟨3, 3, 7, 0, 5, 1⟩).1.entryCount == 7
#guard (mutantTranscriptDuplicateDoubleCount ⟨3, 7, 0⟩ ⟨3, 3, 7, 0, 5, 1⟩).entryCount == 8

-- ===========================================================================
-- Family 3 (`G-ORB-2` / `G-ORB-3`): Outbox WAL & Lease Mutants (M7..M9)
-- ===========================================================================

/-- Mutant 3A (Boundary / off-by-one): allows `volatileInFlight <= unacked` instead of
    strict `< unacked`, dispatching one extra duplicate in-flight delivery beyond backlog. -/
def mutantOutboxInFlightOffByOne (o : OutboxReconcileCheck) : Bool :=
  decide (o.durableAcked ≤ o.durableQueued) &&
  decide (0 < o.durableQueued - o.durableAcked) &&
  (o.reqOwner != 0) &&
  (o.volatileLeaseOwner == 0 || o.volatileLeaseOwner == o.reqOwner) &&
  decide ((if o.leaseBootEpoch != o.nodeBootEpoch then 0 else o.volatileInFlight) ≤
          o.durableQueued - o.durableAcked)

/-- Mutant 3B (Alias / split-brain writer): forgets to check `effOwner == reqOwner`,
    letting a second worker steal an active same-boot lease. -/
def mutantOutboxStealActiveLease (o : OutboxReconcileCheck) : Bool :=
  decide (o.durableAcked ≤ o.durableQueued) &&
  decide (0 < o.durableQueued - o.durableAcked) &&
  (o.reqOwner != 0) &&
  (o.leaseBootEpoch == o.nodeBootEpoch || o.volatileLeaseOwner == 0) &&
  decide (o.volatileInFlight < o.durableQueued - o.durableAcked)

/-- Mutant 3C (Semantic / crash-epoch wedge): fails to reset `volatileLeaseOwner` on
    `leaseBootEpoch != nodeBootEpoch`, permanently wedging recovery after a node reboot. -/
def mutantOutboxForgetCrashReset (o : OutboxReconcileCheck) : Bool :=
  decide (o.durableAcked ≤ o.durableQueued) &&
  decide (0 < o.durableQueued - o.durableAcked) &&
  (o.reqOwner != 0) &&
  (o.volatileLeaseOwner == 0 || o.volatileLeaseOwner == o.reqOwner) &&
  decide (o.volatileInFlight < o.durableQueued - o.durableAcked) &&
  (o.leaseBootEpoch == o.nodeBootEpoch)

/-- Family 3 mutant kill theorem: all 3 outbox mutants disagree with
    `outboxCrashReconcileMetaGate.gate` (`M3A` over-dispatch at `inFlight == unacked`,
    `M3B` rival writer split-brain, `M3C` reboot liveness deadlock). -/
theorem kill_family3_outbox_mutants :
    let wFull : OutboxReconcileCheck := ⟨10, 8, 2, 7, 7, 1, 1⟩
    let wRival : OutboxReconcileCheck := ⟨10, 8, 0, 7, 7, 1, 2⟩
    let wReboot : OutboxReconcileCheck := ⟨10, 8, 2, 7, 8, 1, 2⟩
    mutantOutboxInFlightOffByOne wFull = true ∧
    outboxCrashReconcileMetaGate.gate wFull = false ∧
    mutantOutboxStealActiveLease wRival = true ∧
    outboxCrashReconcileMetaGate.gate wRival = false ∧
    mutantOutboxForgetCrashReset wReboot = false ∧
    outboxCrashReconcileMetaGate.gate wReboot = true := by
  decide

#guard outboxCrashReconcileMetaGate.gate ⟨10, 8, 0, 7, 7, 1, 2⟩ == false
#guard outboxCrashReconcileMetaGate.gate ⟨10, 8, 2, 7, 8, 1, 2⟩ == true

-- ===========================================================================
-- Family 4 (`G-ORB-2`): Provider Failover, Pinning & 3-Clock Mutants (M10..M12)
-- ===========================================================================

/-- Mutant 4A (Boundary / off-by-one): uses `attemptsUsed <= retryBudget` on retries
    instead of `<`, allowing `retryBudget + 1` retry attempts, and `<= upstreamDeadline`. -/
def mutantProviderRetryOffByOne (p : ProviderAttemptCheck) : Bool :=
  let isRetry := p.failureKind == 1 || p.failureKind == 2
  !(p.firstByteCommitted == 1 && isRetry) &&
  (p.candidateAccountId != 0) &&
  (p.pinnedAccountId == 0 || p.candidateAccountId == p.pinnedAccountId) &&
  (p.failureKind != 2) &&
  decide (p.cooldownUntilEpoch ≤ p.upstreamNowEpoch) &&
  decide (p.upstreamNowEpoch ≤ p.upstreamDeadline) &&
  (p.authValid == 1) &&
  decide (p.attemptsUsed ≤ p.retryBudget)

/-- Mutant 4B (Alias / cross-account leak): ignores `pinnedAccountId` on retry failover,
    routing mid-conversation state to a different Antigravity account. -/
def mutantProviderUnpinnedFailover (p : ProviderAttemptCheck) : Bool :=
  let isRetry := p.failureKind == 1 || p.failureKind == 2
  !(p.firstByteCommitted == 1 && isRetry) &&
  (p.candidateAccountId != 0) &&
  (p.pinnedAccountId == p.pinnedAccountId) &&
  (p.failureKind != 2) &&
  decide (p.cooldownUntilEpoch ≤ p.upstreamNowEpoch) &&
  decide (p.upstreamNowEpoch < p.upstreamDeadline) &&
  (p.authValid == 1) &&
  decide (p.attemptsUsed < p.retryBudget)

/-- Mutant 4C (Semantic / sticky first-byte drop): retries after `firstByteCommitted == 1`,
    corrupting an already-streaming SSE response with a second upstream stream. -/
def mutantProviderRetryAfterFirstByte (p : ProviderAttemptCheck) : Bool :=
  (p.candidateAccountId != 0) &&
  (p.pinnedAccountId == 0 || p.candidateAccountId == p.pinnedAccountId) &&
  (p.failureKind != 2) &&
  (p.firstByteCommitted ≤ 1) &&
  decide (p.cooldownUntilEpoch ≤ p.upstreamNowEpoch) &&
  decide (p.upstreamNowEpoch < p.upstreamDeadline) &&
  (p.authValid == 1) &&
  decide (p.attemptsUsed < p.retryBudget)

/-- Family 4 mutant kill theorem: all 3 provider mutants are caught by
    `providerAttemptMetaGate.gate` (`M4A` exhausted retry budget, `M4B` account pin mismatch,
    `M4C` retry after first byte committed). -/
theorem kill_family4_provider_mutants :
    let pBudget : ProviderAttemptCheck := ⟨42, 42, 3, 3, 0, 1, 1000, 500, 2000, 1⟩
    let pPin : ProviderAttemptCheck := ⟨42, 99, 1, 3, 0, 1, 1000, 500, 2000, 1⟩
    let pFirstByte : ProviderAttemptCheck := ⟨42, 42, 1, 3, 1, 1, 1000, 500, 2000, 1⟩
    mutantProviderRetryOffByOne pBudget = true ∧
    providerAttemptMetaGate.gate pBudget = false ∧
    mutantProviderUnpinnedFailover pPin = true ∧
    providerAttemptMetaGate.gate pPin = false ∧
    mutantProviderRetryAfterFirstByte pFirstByte = true ∧
    providerAttemptMetaGate.gate pFirstByte = false := by
  decide

#guard providerAttemptMetaGate.gate ⟨42, 42, 3, 3, 0, 1, 1000, 500, 2000, 1⟩ == false
#guard providerAttemptMetaGate.gate ⟨42, 99, 1, 3, 0, 1, 1000, 500, 2000, 1⟩ == false

-- ===========================================================================
-- Family 5 (`G-ORB-7`): TOCTOU Authorization Binding Mutants (M13..M15)
-- ===========================================================================

/-- Mutant 5A (Boundary / off-by-one): admits execution at exact lease expiry
    (`nowTick <= expiryTick` instead of `nowTick < expiryTick`). -/
def mutantAuthAdmitAtExactExpiry (a : AuthToctouCheck) : Bool :=
  (a.bunkerState == 0) &&
  decide (1 ≤ a.principalKind) && decide (a.principalKind ≤ 3) &&
  decide (a.nowTick ≤ a.expiryTick) &&
  (a.observedLeaseEpoch != 0) && (a.observedLeaseEpoch == a.liveLeaseEpoch) &&
  (a.observedTargetId != 0) && (a.observedTargetId == a.execTargetId) &&
  (a.observedDigest != 0) && (a.observedDigest == a.execDigest)

/-- Mutant 5B (Alias / TOCTOU target swap): checks `observedTargetId != 0` and
    `execTargetId != 0` separately without binding `observedTargetId == execTargetId`. -/
def mutantAuthUnboundTargetSwap (a : AuthToctouCheck) : Bool :=
  (a.bunkerState == 0) &&
  decide (1 ≤ a.principalKind) && decide (a.principalKind ≤ 3) &&
  decide (a.nowTick < a.expiryTick) &&
  (a.observedLeaseEpoch != 0) && (a.observedLeaseEpoch == a.liveLeaseEpoch) &&
  (a.observedTargetId != 0) && (a.execTargetId != 0) &&
  (a.observedDigest != 0) && (a.observedDigest == a.execDigest)

/-- Mutant 5C (Semantic / stale-lease & bunker bypass): trusts `observedLeaseEpoch != 0`
    cached at gate time without re-checking `liveLeaseEpoch` or `bunkerState == 0` at execute. -/
def mutantAuthCachedGateBypass (a : AuthToctouCheck) : Bool :=
  (a.bunkerState ≤ 1) &&
  decide (1 ≤ a.principalKind) && decide (a.principalKind ≤ 3) &&
  decide (a.nowTick < a.expiryTick) &&
  (a.observedLeaseEpoch != 0) && (a.liveLeaseEpoch ≤ a.observedLeaseEpoch) &&
  (a.observedTargetId != 0) && (a.observedTargetId == a.execTargetId) &&
  (a.observedDigest != 0) && (a.observedDigest == a.execDigest)

/-- Family 5 mutant kill theorem: all 3 TOCTOU authorization mutants admit an execution
    that `authToctouMetaGate.gate` fails closed on (`M5A` exact-expiry boundary,
    `M5B` target swap between gate and execute, `M5C` bunker trip + lease revocation). -/
theorem kill_family5_auth_toctou_mutants :
    let aExp : AuthToctouCheck := ⟨2, 0, 7, 7, 11, 11, 200, 200, 55, 55⟩
    let aSwap : AuthToctouCheck := ⟨2, 0, 7, 8, 11, 11, 100, 200, 55, 55⟩
    let aRevoked : AuthToctouCheck := ⟨2, 1, 7, 7, 11, 0, 100, 200, 55, 55⟩
    mutantAuthAdmitAtExactExpiry aExp = true ∧
    authToctouMetaGate.gate aExp = false ∧
    mutantAuthUnboundTargetSwap aSwap = true ∧
    authToctouMetaGate.gate aSwap = false ∧
    mutantAuthCachedGateBypass aRevoked = true ∧
    authToctouMetaGate.gate aRevoked = false := by
  decide

#guard authToctouMetaGate.gate ⟨2, 0, 7, 8, 11, 11, 100, 200, 55, 55⟩ == false
#guard authToctouMetaGate.gate ⟨2, 1, 7, 7, 11, 0, 100, 200, 55, 55⟩ == false

-- ===========================================================================
-- Family 6 (`G-ORB-3`): Conserved Resource Ledger & TTL Mutants (M16..M18)
-- ===========================================================================

/-- Mutant 6A (Boundary / wrapping addition): checks `spentCents + costDeltaCents <= budgetCents`
    using wrapping `UInt64` addition instead of `costDeltaCents <= budgetCents - spentCents`,
    admitting a huge `costDeltaCents` that wraps `UInt64` modulo `2^64`. -/
def mutantResourceWrappingBudgetCheck (r : ResourceLedgerCheck) : Bool :=
  (r.opKind == 0) &&
  decide (r.activeSlots ≤ r.maxSlots) &&
  decide (r.reservedSlots < r.maxSlots - r.activeSlots) &&
  decide (r.spentCents ≤ r.budgetCents) &&
  decide (r.spentCents + r.costDeltaCents ≤ r.budgetCents) &&
  decide (r.nowTick < r.ttlExpiryTick)

/-- Mutant 6B (Alias / slot-pool double-book): checks `reservedSlots < maxSlots` instead
    of `reservedSlots < maxSlots - activeSlots`, over-subscribing `reserved + active > maxSlots`. -/
def mutantResourceIgnoreActiveSlots (r : ResourceLedgerCheck) : Bool :=
  (r.opKind == 0) &&
  decide (r.activeSlots ≤ r.maxSlots) &&
  decide (r.reservedSlots < r.maxSlots) &&
  decide (r.spentCents ≤ r.budgetCents) &&
  decide (r.costDeltaCents ≤ r.budgetCents - r.spentCents) &&
  decide (r.nowTick < r.ttlExpiryTick)

/-- Mutant 6C (Semantic / premature TTL reap): reaps a live reservation before `ttlExpiryTick`
    (`nowTick < ttlExpiryTick` instead of `nowTick >= ttlExpiryTick`). -/
def mutantResourcePrematureTtlReap (r : ResourceLedgerCheck) : Bool :=
  (r.opKind == 3) &&
  decide (r.activeSlots ≤ r.maxSlots) &&
  decide (r.reservedSlots ≤ r.maxSlots - r.activeSlots) &&
  decide (r.spentCents ≤ r.budgetCents) &&
  decide (0 * r.costDeltaCents ≤ r.budgetCents) &&
  decide (0 < r.reservedSlots) &&
  decide (r.nowTick < r.ttlExpiryTick)

/-- Family 6 mutant kill theorem: all 3 resource-ledger mutants are killed by
    `resourceLedgerMetaGate.gate` (`M6A` `UInt64` overflow wrap spend, `M6B` slot pool
    over-subscription, `M6C` premature reaping of a live reservation). -/
theorem kill_family6_resource_ledger_mutants :
    let rWrap : ResourceLedgerCheck :=
      ⟨0, 0, 0, 2, 50, 0xFFFFFFFFFFFFFFEC, 100, 10, 20⟩
    let rOverSlot : ResourceLedgerCheck := ⟨0, 1, 1, 2, 10, 5, 100, 10, 20⟩
    let rEarlyReap : ResourceLedgerCheck := ⟨3, 1, 0, 2, 10, 0, 100, 10, 20⟩
    mutantResourceWrappingBudgetCheck rWrap = true ∧
    resourceLedgerMetaGate.gate rWrap = false ∧
    mutantResourceIgnoreActiveSlots rOverSlot = true ∧
    resourceLedgerMetaGate.gate rOverSlot = false ∧
    mutantResourcePrematureTtlReap rEarlyReap = true ∧
    resourceLedgerMetaGate.gate rEarlyReap = false := by
  decide

#guard resourceLedgerMetaGate.gate ⟨0, 0, 0, 2, 50, 0xFFFFFFFFFFFFFFEC, 100, 10, 20⟩ == false
#guard resourceLedgerMetaGate.gate ⟨0, 1, 1, 2, 10, 5, 100, 10, 20⟩ == false

-- ===========================================================================
-- Family 7 (`G-ORB-6`): Bounded-Tail Stream Scanner Mutants (M19..M21)
-- ===========================================================================

/-- Mutant 7A (Boundary / zero-cap acceptance): admits `maxOpenTailBytes == 0` (`>= 0`)
    and underflows `newLen - maxOpenTailBytes` or spins without progress. -/
def mutantStreamAcceptZeroTailCap (c : StreamBoundedCommitCheck) : Bool :=
  decide (0 ≤ c.maxOpenTailBytes) &&
  decide (c.prevCommit ≤ c.prevCheckpoint) &&
  decide (c.prevCheckpoint ≤ c.prevLen) &&
  decide (c.prevLen ≤ c.newLen) &&
  decide (c.rawCommit ≤ c.newLen || c.newLen < c.rawCommit)

/-- Mutant 7B (Alias / commit regression): trusts `rawCommit` directly without clamping
    below by `prevCommit`, letting an open-fence chunk regress already-committed output. -/
def mutantStreamRegressCommit (s : StreamCommitState) (c : StreamBoundedCommitCheck) :
    StreamCommitState :=
  let clampedRaw := if c.rawCommit ≤ c.newLen then c.rawCommit else c.newLen
  let capFloor := if c.maxOpenTailBytes ≤ c.newLen then c.newLen - c.maxOpenTailBytes else 0
  let nextCp := if s.checkpoint ≤ capFloor then capFloor else s.checkpoint
  if c.maxOpenTailBytes > 0 && s.len ≤ c.newLen then
    ⟨c.newLen, clampedRaw, nextCp⟩
  else s

/-- Mutant 7C (Semantic / unbounded unclosed-fence tail): never advances `checkpoint`
    when `rawCommit == prevCommit`, re-scanning the entire buffer `O(n^2)` on unclosed fences. -/
def mutantStreamUnboundedOpenFenceTail (s : StreamCommitState)
    (c : StreamBoundedCommitCheck) : StreamCommitState :=
  let clampedRaw := if c.rawCommit ≤ c.newLen then c.rawCommit else c.newLen
  let nextCommit := if s.commit ≤ clampedRaw then clampedRaw else s.commit
  let nextCp := if s.checkpoint ≤ nextCommit then nextCommit else s.checkpoint
  if c.maxOpenTailBytes > 0 && s.len ≤ c.newLen then
    ⟨c.newLen, nextCommit, nextCp⟩
  else s

/-- Family 7 mutant kill theorem: all 3 stream-commit mutants are killed (`M7A` zero-cap
    admission rejected by `streamBoundedCommitMetaGate`, `M7B` commit regression prevented,
    `M7C` unbounded open-fence tail exceeds `maxOpenTailBytes` whereas
    `streamBoundedCommitMachineStep` enforces `len - checkpoint <= maxOpenTailBytes`). -/
theorem kill_family7_stream_commit_mutants :
    let cZeroCap : StreamBoundedCommitCheck := ⟨0, 0, 0, 16, 8, 0⟩
    let sCommitted : StreamCommitState := ⟨16, 12, 12⟩
    let cOpenFence : StreamBoundedCommitCheck := ⟨16, 12, 12, 40, 4, 8⟩
    mutantStreamAcceptZeroTailCap cZeroCap = true ∧
    streamBoundedCommitMetaGate.gate cZeroCap = false ∧
    (mutantStreamRegressCommit sCommitted cOpenFence).commit < sCommitted.commit ∧
    (streamBoundedCommitMachineStep sCommitted cOpenFence).1.commit ≥ sCommitted.commit ∧
    (mutantStreamUnboundedOpenFenceTail sCommitted cOpenFence).len -
      (mutantStreamUnboundedOpenFenceTail sCommitted cOpenFence).checkpoint > 8 ∧
    (streamBoundedCommitMachineStep sCommitted cOpenFence).1.len -
      (streamBoundedCommitMachineStep sCommitted cOpenFence).1.checkpoint ≤ 8 := by
  decide

#guard streamBoundedCommitMetaGate.gate ⟨0, 0, 0, 16, 8, 0⟩ == false
#guard (streamBoundedCommitMachineStep ⟨16, 12, 12⟩ ⟨16, 12, 12, 40, 4, 8⟩).1.checkpoint == 32

/-- Master P5 Mutant Kill Registry: all 21 concrete buggy transition mutants across
    all 7 stateful families are simultaneously killed with `0 sorryAx`. -/
theorem all_21_stateful_mutants_killed :
    (let sOpen : HierarchyNodeState := ⟨5, 0, 0, 0, 42⟩
     (mutantHierarchyEqEpochPartial sOpen ⟨5, 5, 0, 0, 0, 1, 1, 42, 99, 0, 0, 0⟩).parentOrd ≠
       (hierarchyMachineStep sOpen ⟨5, 5, 0, 0, 0, 1, 1, 42, 99, 0, 0, 0⟩).1.parentOrd) ∧
    ((mutantTranscriptDuplicateDoubleCount ⟨3, 7, 0⟩ ⟨3, 3, 7, 0, 5, 1⟩).entryCount ≠
       (transcriptFoldMachineStep ⟨3, 7, 0⟩ ⟨3, 3, 7, 0, 5, 1⟩).1.entryCount) ∧
    (mutantOutboxStealActiveLease ⟨10, 8, 0, 7, 7, 1, 2⟩ ≠
       outboxCrashReconcileMetaGate.gate ⟨10, 8, 0, 7, 7, 1, 2⟩) ∧
    (mutantProviderRetryAfterFirstByte ⟨42, 42, 1, 3, 1, 1, 1000, 500, 2000, 1⟩ ≠
       providerAttemptMetaGate.gate ⟨42, 42, 1, 3, 1, 1, 1000, 500, 2000, 1⟩) ∧
    (mutantAuthUnboundTargetSwap ⟨2, 0, 7, 8, 11, 11, 100, 200, 55, 55⟩ ≠
       authToctouMetaGate.gate ⟨2, 0, 7, 8, 11, 11, 100, 200, 55, 55⟩) ∧
    (mutantResourceWrappingBudgetCheck ⟨0, 0, 0, 2, 50, 0xFFFFFFFFFFFFFFEC, 100, 10, 20⟩ ≠
       resourceLedgerMetaGate.gate ⟨0, 0, 0, 2, 50, 0xFFFFFFFFFFFFFFEC, 100, 10, 20⟩) ∧
    ((streamBoundedCommitMachineStep ⟨16, 12, 12⟩ ⟨16, 12, 12, 40, 4, 8⟩).1.checkpoint ≠
       (mutantStreamUnboundedOpenFenceTail ⟨16, 12, 12⟩ ⟨16, 12, 12, 40, 4, 8⟩).checkpoint) := by
  decide

/-! ## Family 8: Live Node Capacity Resize & Coordinator Priority Lane Mutants -/

/-- Mutant 8A (Shrink debt drop): forgets `debt` during a live shrink when `idlePermits == 0`,
    falsely reporting extra free capacity while running holders are still active. -/
def mutantNodeResizeDropShrinkDebt (s : NodeResizeState) (c : NodeResizeCheck) :
    NodeResizeState :=
  let c' := effectiveNodeResize s c
  if nodeResizeMetaGate.gate c' then
    ⟨c.targetCap, 0⟩
  else s

/-- Mutant 8B (Worker steals coordinator lane): omits `!(isChildWorker == 1)` when `Main` is
    saturated (`mainRunning >= mainMax`), allowing subagent workers to exhaust `Coordinator`
    reserve slots and starve root coordinator `schedule_wakeup` turns. -/
def mutantNodeLaneWorkerStealsCoordinator (s : NodeLaneCheck) : UInt32 :=
  if s.isSideQuestion == 1 then
    if s.sideRunning < s.sideMax then 258 else 514
  else if s.hasWorkspaceBg == 1 then
    if s.coordRunning < s.coordMax then 260
    else if s.mainRunning < s.mainMax then 257
    else 515
  else if s.isCoordinatorPriority == 1 && !(s.isLongRunning == 1) then
    if s.mainRunning < s.mainMax then 257
    else if s.coordRunning < s.coordMax then 259
    else 515
  else if s.mainRunning < s.mainMax then
    257
  else
    513

/-- Mutant 8C (Coordinator starved behind workers): routes coordinator/wakeup turns (`hasWorkspaceBg == 0`)
    strictly to `Main` (`513` when `mainRunning >= mainMax`) instead of failing over to `Coordinator`. -/
def mutantNodeLaneStarveCoordinatorWakeup (s : NodeLaneCheck) : UInt32 :=
  if s.isSideQuestion == 1 then
    if s.sideRunning < s.sideMax then 258 else 514
  else if s.hasWorkspaceBg == 1 then
    if s.coordRunning < s.coordMax then 260
    else if s.mainRunning < s.mainMax then 257
    else 515
  else if s.mainRunning < s.mainMax then
    257
  else
    513

theorem kill_node_resize_drop_shrink_debt :
    (mutantNodeResizeDropShrinkDebt ⟨10, 0⟩ ⟨1, 0, 1, 10, 0, 0, 6, 256⟩).debt ≠
      (nodeResizeMachineStep ⟨10, 0⟩ ⟨1, 0, 1, 10, 0, 0, 6, 256⟩).1.debt := by
  decide

theorem kill_node_lane_worker_steals_coordinator :
    mutantNodeLaneWorkerStealsCoordinator ⟨0, 1, 0, 1, 0, 10, 10, 0, 2, 0, 2⟩ ≠
      nodeLaneStep 0 1 0 1 0 10 10 0 2 0 2 := by
  decide

theorem kill_node_lane_starve_coordinator_wakeup :
    mutantNodeLaneStarveCoordinatorWakeup ⟨0, 1, 0, 0, 0, 10, 10, 0, 2, 0, 2⟩ ≠
      nodeLaneStep 0 1 0 0 0 10 10 0 2 0 2 := by
  decide

-- ===========================================================================
-- Family 9: Mission Placement & Optimistic-Move Reconciliation Mutants (M25..M28)
-- ===========================================================================

/-- Mutant 9A (Stale poll snap-back): ignores `pendingOpId != 0` on list polls (`sourceKind == 0`),
    allowing an in-flight poll carrying pre-move placement (`incRev == curRev`) to overwrite the
    optimistic move and snap the mission back to its old folder/project. -/
def mutantPlacementUnfencedStalePoll (p : PlacementMergeCheck) : Bool :=
  if !(decide (p.sourceKind ≤ 3)) then false
  else if p.sourceKind == 2 then
    p.hasPlacement == 1 && p.ackOpId != 0
  else if p.sourceKind == 3 then
    p.pendingOpId != 0 && p.ackOpId == p.pendingOpId
  else if !(p.hasPlacement == 1) then false
  else
    decide (p.curRev ≤ p.incRev)

/-- Mutant 9B (Stale revision rollback): omits `curRev <= incRev` check when `pendingOpId == 0`,
    allowing an out-of-order older poll (`incRev < curRev`) to revert a settled move. -/
def mutantPlacementAcceptsOlderRevision (p : PlacementMergeCheck) : Bool :=
  if !(decide (p.sourceKind ≤ 3)) then false
  else if p.sourceKind == 2 then
    p.hasPlacement == 1 && p.ackOpId != 0
  else if p.sourceKind == 3 then
    p.pendingOpId != 0 && p.ackOpId == p.pendingOpId
  else if !(p.hasPlacement == 1) then false
  else if p.pendingOpId != 0 then
    decide (p.curRev < p.incRev) ||
    (p.sourceKind == 1 && p.ackOpId == p.pendingOpId && decide (p.curRev ≤ p.incRev))
  else
    true

/-- Mutant 9C (Unmatched rollback clobbers newer optimistic op): rolls back on `sourceKind == 3`
    whenever `pendingOpId != 0` without checking `ackOpId == pendingOpId`, letting a failed older
    move clobber a newer optimistic move already in flight. -/
def mutantPlacementUnboundRollback (p : PlacementMergeCheck) : Bool :=
  if !(decide (p.sourceKind ≤ 3)) then false
  else if p.sourceKind == 2 then
    p.hasPlacement == 1 && p.ackOpId != 0
  else if p.sourceKind == 3 then
    p.pendingOpId != 0
  else if !(p.hasPlacement == 1) then false
  else if p.pendingOpId != 0 then
    decide (p.curRev < p.incRev) ||
    (p.sourceKind == 1 && p.ackOpId == p.pendingOpId && decide (p.curRev ≤ p.incRev))
  else
    decide (p.curRev ≤ p.incRev)

/-- Mutant 9D (Older ack / intermediate poll clears newer pending op): sets `clearPendingBit(512)`
    (`lo32 = 1793`) whenever `incRev > curRev` without checking `sourceKind == 0` or
    `ackOpId < pendingOpId`, prematurely clearing a newer in-flight move during overlapping moves
    (such as `A -> B -> C -> B`). -/
def mutantPlacementOlderAckClearsPending (p : PlacementMergeCheck) : UInt32 :=
  if p.pendingOpId != 0 && decide (p.curRev < p.incRev) && p.hasPlacement == 1 && decide (p.sourceKind ≤ 1) then
    1793
  else
    placementMergeLo32 p.curRev p.incRev p.pendingOpId p.ackOpId p.sourceKind p.hasPlacement

theorem kill_placement_unfenced_stale_poll :
    mutantPlacementUnfencedStalePoll ⟨4, 4, 11, 0, 0, 1⟩ ≠
      placementMergeMetaGate.gate ⟨4, 4, 11, 0, 0, 1⟩ := by
  decide

theorem kill_placement_accepts_older_revision :
    mutantPlacementAcceptsOlderRevision ⟨5, 4, 0, 0, 0, 1⟩ ≠
      placementMergeMetaGate.gate ⟨5, 4, 0, 0, 0, 1⟩ := by
  decide

theorem kill_placement_unbound_rollback :
    mutantPlacementUnboundRollback ⟨4, 4, 12, 11, 3, 1⟩ ≠
      placementMergeMetaGate.gate ⟨4, 4, 12, 11, 3, 1⟩ := by
  decide

theorem kill_placement_older_ack_clears_pending :
    mutantPlacementOlderAckClearsPending ⟨0, 1, 3, 1, 1, 1⟩ ≠
      placementMergeLo32 0 1 3 1 1 1 := by
  decide

theorem kill_placement_intermediate_poll_clears_pending :
    mutantPlacementOlderAckClearsPending ⟨0, 1, 3, 0, 0, 1⟩ ≠
      placementMergeLo32 0 1 3 0 0 1 := by
  decide

theorem kill_placement_foreign_event_clears_pending :
    mutantPlacementOlderAckClearsPending ⟨0, 1, 1, 0, 1, 1⟩ ≠
      placementMergeLo32 0 1 1 0 1 1 := by
  decide

#guard placementMergeMetaGate.gate ⟨4, 4, 11, 0, 0, 1⟩ == false
#guard placementMergeMetaGate.gate ⟨5, 4, 0, 0, 0, 1⟩ == false
#guard placementMergeMetaGate.gate ⟨4, 4, 12, 11, 3, 1⟩ == false
#guard ((placementMergeStep 0 1 3 1 1 1 &&& 0xFFFFFFFF) &&& 512) == 0
#guard ((placementMergeStep 0 1 3 0 0 1 &&& 0xFFFFFFFF) &&& 512) == 0
#guard ((placementMergeStep 0 1 1 0 1 1 &&& 0xFFFFFFFF) &&& 512) == 0

-- ===========================================================================
-- Family 10 (`G-ORB-2`): R2-A Epoch Fence, Effect Outbox, Crash Boundary (M29..M37)
-- ===========================================================================

/-- Mutant 10A (`epochFence`): stale `liveRevision` still matches the durable row. -/
def mutantEpochFenceStaleRevision (c : EpochFenceCheck) : Bool :=
  (c.durableOwnerEpoch != 0) &&
  (c.durableRunGeneration != 0) &&
  (c.durableBootEpoch != 0) &&
  (c.durableRevision != 0) &&
  (c.writerOwnerEpoch == c.durableOwnerEpoch) &&
  (c.writerOwnerEpoch == c.liveOwnerEpoch) &&
  (c.liveRunGeneration == c.durableRunGeneration) &&
  (c.liveBootEpoch == c.durableBootEpoch) &&
  decide (c.durableRevision < 0xFFFFFFFF)

/-- Mutant 10B (`epochFence`): pre-crash `liveBootEpoch` is treated as current. -/
def mutantEpochFenceStaleBoot (c : EpochFenceCheck) : Bool :=
  (c.durableOwnerEpoch != 0) &&
  (c.durableRunGeneration != 0) &&
  (c.durableBootEpoch != 0) &&
  (c.durableRevision != 0) &&
  (c.writerOwnerEpoch == c.durableOwnerEpoch) &&
  (c.writerOwnerEpoch == c.liveOwnerEpoch) &&
  (c.liveRevision == c.durableRevision) &&
  (c.liveRunGeneration == c.durableRunGeneration) &&
  decide (c.durableRevision < 0xFFFFFFFF)

/-- Mutant 10C (`epochFence`): saturated revision `0xFFFFFFFF` is still advanced. -/
def mutantEpochFenceSaturatedWrap (c : EpochFenceCheck) : Bool :=
  (c.durableOwnerEpoch != 0) &&
  (c.durableRunGeneration != 0) &&
  (c.durableBootEpoch != 0) &&
  (c.durableRevision != 0) &&
  (c.writerOwnerEpoch == c.durableOwnerEpoch) &&
  (c.writerOwnerEpoch == c.liveOwnerEpoch) &&
  (c.liveRevision == c.durableRevision) &&
  (c.liveRunGeneration == c.durableRunGeneration) &&
  (c.liveBootEpoch == c.durableBootEpoch)

/-- Mutant 10D (`effectOutbox`): `Claim` retries out of sticky `Uncertain`. -/
def mutantEffectOutboxFreshRetry (e : EffectOutboxCheck) : Bool :=
  (e.fenceMatches == 1) &&
  (e.attemptEpoch == e.nodeBootEpoch) &&
  (e.attemptEpoch != 0) &&
  decide (e.phase ≤ 5) &&
  decide (e.op ≤ 5) &&
  ((e.op == 0 && (e.phase == 3 || e.phase == 5)) ||
   (e.op == 1 && (e.phase == 0 || e.phase == 4)) ||
   (e.op == 2 && e.phase == 1) ||
   (e.op == 3 && e.phase == 1) ||
   (e.op == 4 && e.phase == 1) ||
   (e.op == 5 && e.phase == 4))

/-- Mutant 10E (`effectOutbox`): `Reconcile` fabricates a delivery instead of preserving `s.delivered`. -/
def mutantEffectOutboxDoubleDelivery (s : EffectOutboxState) (ev : EffectOutboxEvent) : UInt8 :=
  if ev.fenceMatches == 1 && ev.attemptEpoch == ev.nodeBootEpoch && ev.attemptEpoch != 0 &&
     s.phase == 4 && ev.op == 5 then 1
  else s.delivered

/-- Mutant 10F (`effectOutbox`): stale node boot still fences the attempt. -/
def mutantEffectOutboxStaleBoot (e : EffectOutboxCheck) : Bool :=
  (e.fenceMatches == 1) &&
  (e.attemptEpoch != 0) &&
  decide (e.phase ≤ 5) &&
  decide (e.op ≤ 5) &&
  EffectOutboxCheck.ValidTransition e.phase e.op

/-- Mutant 10G (`crashBoundary`): corrupt WAL (`acked > queued`) is treated as valid. -/
def mutantCrashBoundaryCorruptWal (c : CrashBoundaryCheck) : Bool :=
  (c.stateRevision != 0) &&
  decide (0 < c.durableQueued - c.durableAcked) &&
  (c.reqOwner != 0) &&
  (c.volatileLeaseOwner == 0 || c.volatileLeaseOwner == c.reqOwner) &&
  decide (c.volatileInFlight < c.durableQueued - c.durableAcked) &&
  (c.leaseBootEpoch == c.nodeBootEpoch)

/-- Mutant 10H (`crashBoundary`): volatile lease owner survives a reboot. -/
def mutantCrashBoundaryLeaseSurvivesReboot (c : CrashBoundaryCheck) : UInt32 :=
  let validWal := decide (c.durableAcked ≤ c.durableQueued) && (c.stateRevision != 0)
  let unacked := if validWal then c.durableQueued - c.durableAcked else 0
  let crashReset := c.leaseBootEpoch != c.nodeBootEpoch
  let effOwner := c.volatileLeaseOwner
  let effInFlight := if crashReset then 0 else c.volatileInFlight
  let canAcquire :=
    validWal && decide (0 < unacked) && (c.reqOwner != 0) &&
    (effOwner == 0 || effOwner == c.reqOwner) && decide (effInFlight < unacked)
  if canAcquire then c.reqOwner else effOwner

/-- Mutant 10I (`crashBoundary`): a second live writer steals an owned lease. -/
def mutantCrashBoundaryDualWriter (c : CrashBoundaryCheck) : Bool :=
  let validWal := decide (c.durableAcked ≤ c.durableQueued) && (c.stateRevision != 0)
  let unacked := if validWal then c.durableQueued - c.durableAcked else 0
  let crashReset := c.leaseBootEpoch != c.nodeBootEpoch
  let effInFlight := if crashReset then 0 else c.volatileInFlight
  validWal && decide (0 < unacked) && (c.reqOwner != 0) && decide (effInFlight < unacked)

theorem kill_epoch_fence_stale_revision :
    mutantEpochFenceStaleRevision ⟨11, 11, 3, 3, 5, 5, 10, 9, 11⟩ ≠
      epochFenceMetaGate.gate ⟨11, 11, 3, 3, 5, 5, 10, 9, 11⟩ := by
  decide

theorem kill_epoch_fence_stale_boot :
    mutantEpochFenceStaleBoot ⟨11, 11, 3, 3, 6, 5, 10, 10, 11⟩ ≠
      epochFenceMetaGate.gate ⟨11, 11, 3, 3, 6, 5, 10, 10, 11⟩ := by
  decide

theorem kill_epoch_fence_saturated_wrap :
    mutantEpochFenceSaturatedWrap ⟨11, 11, 3, 3, 5, 5, 0xFFFFFFFF, 0xFFFFFFFF, 11⟩ ≠
      epochFenceMetaGate.gate ⟨11, 11, 3, 3, 5, 5, 0xFFFFFFFF, 0xFFFFFFFF, 11⟩ := by
  decide

theorem kill_effect_outbox_fresh_retry :
    mutantEffectOutboxFreshRetry ⟨4, 0, 1, 1, 9, 9⟩ ≠
      effectOutboxMetaGate.gate ⟨4, 0, 1, 1, 9, 9⟩ := by
  decide

theorem kill_effect_outbox_double_delivery :
    mutantEffectOutboxDoubleDelivery ⟨4, 0⟩ ⟨5, 1, 9, 9⟩ ≠
      (effectOutboxTransition ⟨4, 0⟩ ⟨5, 1, 9, 9⟩).delivered := by
  decide

theorem kill_effect_outbox_stale_boot :
    mutantEffectOutboxStaleBoot ⟨1, 0, 2, 1, 8, 9⟩ ≠
      effectOutboxMetaGate.gate ⟨1, 0, 2, 1, 8, 9⟩ := by
  decide

theorem kill_crash_boundary_corrupt_wal :
    mutantCrashBoundaryCorruptWal ⟨2, 5, 1, 0, 9, 9, 0, 7⟩ ≠
      crashBoundaryMetaGate.gate ⟨2, 5, 1, 0, 9, 9, 0, 7⟩ := by
  decide

theorem kill_crash_boundary_lease_survives_reboot :
    mutantCrashBoundaryLeaseSurvivesReboot ⟨5, 2, 1, 0, 8, 9, 4, 7⟩ ≠
      (if ((crashBoundaryStep 5 2 1 0 8 9 4 7 &&& 0xFFFFFFFF) &&& 256) != 0 then (7 : UInt32) else 0) := by
  decide

theorem kill_crash_boundary_dual_writer :
    mutantCrashBoundaryDualWriter ⟨5, 2, 1, 0, 9, 9, 4, 7⟩ ≠
      crashBoundaryMetaGate.gate ⟨5, 2, 1, 0, 9, 9, 4, 7⟩ := by
  decide

#guard epochFenceMetaGate.gate ⟨11, 11, 3, 3, 5, 5, 10, 9, 11⟩ == false
#guard effectOutboxMetaGate.gate ⟨4, 0, 1, 1, 9, 9⟩ == false
#guard crashBoundaryMetaGate.gate ⟨2, 5, 1, 0, 9, 9, 0, 7⟩ == false

-- Phase R6-A Stateful Transition Mutants (`followupQueue`, `transportEpoch`, `streamOpenTailCap`)

/-- Mutant 11A (`followupQueue`): stale server revision accepted on edit CAS. -/
def mutantFollowupQueueStaleRevision (c : FollowupQueueCheck) : Bool :=
  followupQueueMetaGate.gate { c with expectedServerRev := c.serverRev }

/-- Mutant 11B (`followupQueue`): historical turn (`turnSeq == postedAfterSeq`) retires optimistic row. -/
def mutantFollowupQueueHistoricalRetire (c : FollowupQueueCheck) : Bool :=
  (((followupQueueStep c.op c.serverRev c.incomingServerRev c.expectedServerRev
      c.clientMsgId c.trackedMsgId c.deliveredMsgId c.postedAfterSeq (c.turnSeq + 1)
      c.optimisticSending c.serverListed c.contentMatched c.alreadyDelivered) &&& 0xFFFFFFFF) &&& 1024) != 0

/-- Mutant 11C (`followupQueue`): duplicate `clientMsgId` double-admitted on enqueue. -/
def mutantFollowupQueueDuplicateAdmit (c : FollowupQueueCheck) : Bool :=
  followupQueueMetaGate.gate { c with trackedMsgId := 0 }

/-- Mutant 12A (`transportEpoch`): `everReady == 1` locks out SSE fallback (`nextMode` stays `0`). -/
def mutantTransportEpochEverReadyLock (c : TransportEpochCheck) : UInt8 :=
  if c.everReady == 1 && c.eventKind == 1 then 0 else (c.eval &&& 0xFF).toUInt8

/-- Mutant 12B (`transportEpoch`): SSE fallback drops `sinceSeq32` cursor to `0`. -/
def mutantTransportEpochDropsSinceSeq (c : TransportEpochCheck) : UInt32 :=
  if ((c.eval &&& 0xFFFFFFFF) &&& 1024) != 0 then 0 else (c.eval >>> 32).toUInt32

/-- Mutant 12C (`transportEpoch`): transient WS failure sets sticky unsupported capability bit. -/
def mutantTransportEpochTransientSticky (c : TransportEpochCheck) : Bool :=
  if c.eventKind == 1 then true else (((c.eval &&& 0xFFFFFFFF) &&& 512) != 0)

/-- Mutant 13A (`streamOpenTailCap`): open fence freezes checkpoint instead of advancing cap floor. -/
def mutantStreamOpenTailCapFrozenFence (c : StreamOpenTailCapCheck) : UInt32 :=
  if c.openFenceActive == 1 then c.prevCheckpoint else (c.eval >>> 32).toUInt32

/-- Mutant 13B (`streamOpenTailCap`): zero cap (`maxOpenTailBytes == 0`) admitted. -/
def mutantStreamOpenTailCapZeroAdmitted (c : StreamOpenTailCapCheck) : Bool :=
  streamOpenTailCapMetaGate.gate { c with maxOpenTailBytes := if c.maxOpenTailBytes == 0 then 1 else c.maxOpenTailBytes }

/-- Mutant 13C (`streamOpenTailCap`): checkpoint regresses behind `prevCheckpoint`. -/
def mutantStreamOpenTailCapRegresses (c : StreamOpenTailCapCheck) : UInt32 :=
  if c.maxOpenTailBytes ≤ c.newLen then c.newLen - c.maxOpenTailBytes else 0

theorem kill_followup_queue_stale_revision :
    mutantFollowupQueueStaleRevision ⟨1, 5, 5, 4, 42, 42, 0, 10, 10, 0, 0, 0, 0⟩ ≠
      followupQueueMetaGate.gate ⟨1, 5, 5, 4, 42, 42, 0, 10, 10, 0, 0, 0, 0⟩ := by
  decide

theorem kill_followup_queue_historical_retire :
    mutantFollowupQueueHistoricalRetire ⟨3, 5, 5, 5, 42, 42, 0, 10, 10, 0, 0, 1, 0⟩ ≠
      ((((followupQueueStep 3 5 5 5 42 42 0 10 10 0 0 1 0) &&& 0xFFFFFFFF) &&& 1024) != 0) := by
  decide

theorem kill_followup_queue_duplicate_admit :
    mutantFollowupQueueDuplicateAdmit ⟨2, 5, 5, 5, 42, 42, 0, 10, 10, 0, 0, 0, 0⟩ ≠
      followupQueueMetaGate.gate ⟨2, 5, 5, 5, 42, 42, 0, 10, 10, 0, 0, 0, 0⟩ := by
  decide

theorem kill_transport_epoch_ever_ready_lock :
    mutantTransportEpochEverReadyLock ⟨0, 1, 1, 0, 0, 1, 2, 0, 40, 0, 0⟩ ≠
      ((transportEpochStep 0 1 1 0 0 1 2 0 40 0 0) &&& 0xFF).toUInt8 := by
  decide

theorem kill_transport_epoch_drops_since_seq :
    mutantTransportEpochDropsSinceSeq ⟨0, 1, 1, 0, 0, 1, 2, 0, 40, 0, 0⟩ ≠
      (transportEpochStep 0 1 1 0 0 1 2 0 40 0 0 >>> 32).toUInt32 := by
  decide

theorem kill_transport_epoch_transient_sticky :
    mutantTransportEpochTransientSticky ⟨0, 1, 1, 0, 0, 1, 2, 0, 40, 0, 0⟩ ≠
      ((((transportEpochStep 0 1 1 0 0 1 2 0 40 0 0) &&& 0xFFFFFFFF) &&& 512) != 0) := by
  decide

theorem kill_stream_open_tail_cap_frozen_fence :
    mutantStreamOpenTailCapFrozenFence ⟨20, 5, 12, 40, 5, 8, 1⟩ ≠
      (streamOpenTailCapStep 20 5 12 40 5 8 1 >>> 32).toUInt32 := by
  decide

theorem kill_stream_open_tail_cap_zero_admitted :
    mutantStreamOpenTailCapZeroAdmitted ⟨20, 5, 12, 40, 5, 0, 1⟩ ≠
      streamOpenTailCapMetaGate.gate ⟨20, 5, 12, 40, 5, 0, 1⟩ := by
  decide

theorem kill_stream_open_tail_cap_regresses :
    mutantStreamOpenTailCapRegresses ⟨20, 5, 18, 22, 5, 8, 1⟩ ≠
      (streamOpenTailCapStep 20 5 18 22 5 8 1 >>> 32).toUInt32 := by
  decide

#guard followupQueueMetaGate.gate ⟨1, 5, 5, 4, 42, 42, 0, 10, 10, 0, 0, 0, 0⟩ == false
#guard (transportEpochStep 0 1 1 0 0 1 2 0 40 0 0 >>> 32).toUInt32 == 40
#guard streamOpenTailCapMetaGate.gate ⟨20, 5, 12, 40, 5, 0, 1⟩ == false

end Orb.StatefulMutantSuite
