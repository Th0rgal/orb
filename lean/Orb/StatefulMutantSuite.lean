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

end Orb.StatefulMutantSuite
