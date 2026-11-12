namespace Orb.ManagedSpawnPolicy

/-!
Spawn-receipt Spec Card (Th0rgal/orb@902af38de; this declaration and
OrbCore.ManagedSpawnActions): a matching request replays its winning receipt;
only the successful inserter may schedule provider work. SQL uniqueness and
successful durable insertion, UUID freshness and authenticated scope derivation
are outside this pure theorem. Missing journal rows never authorize execution.
Positive trace: stored ("new", "digest"), fresh "new", requested "digest" executes;
a concurrent loser with fresh "other" replays the same stored receipt.
-/
inductive ReceiptDecision where
  | execute
  | replay
  | conflict
  | unavailable
  deriving DecidableEq, Repr, BEq

def receiptDecision (stored : Option (String × String)) (freshId digest : String) : ReceiptDecision :=
  match stored with
  | none => .unavailable
  | some (id, expected) =>
    if expected != digest then .conflict
    else if id == freshId then .execute else .replay

theorem receipt_execute_iff (stored : Option (String × String)) (freshId digest : String) :
    receiptDecision stored freshId digest = .execute ↔ stored = some (freshId, digest) := by
  cases stored with
  | none => simp [receiptDecision]
  | some pair =>
    rcases pair with ⟨id, expected⟩
    by_cases hd : expected = digest
    · by_cases hi : id = freshId <;> simp [receiptDecision, hd, hi]
    · simp [receiptDecision, hd]

theorem receipt_retry_replays (winner freshId digest : String) (h : winner ≠ freshId) :
    receiptDecision (some (winner, digest)) freshId digest = .replay := by
  simp [receiptDecision, h]

theorem receipt_missing_never_executes (freshId digest : String) :
    receiptDecision none freshId digest ≠ .execute := by
  simp [receiptDecision]

/-- The realistic mutation drops inserter identity and dispatches both retries. -/
def receiptDuplicateMutant (stored : Option (String × String)) (digest : String) : ReceiptDecision :=
  match stored with
  | none => .unavailable
  | some (_, expected) => if expected != digest then .conflict else .execute

theorem receipt_duplicate_mutant_counterexample :
    receiptDuplicateMutant (some ("winner", "digest")) "digest" = .execute ∧
    receiptDecision (some ("winner", "digest")) "loser" "digest" = .replay := by decide

end Orb.ManagedSpawnPolicy
