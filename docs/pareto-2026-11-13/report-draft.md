# Pareto — draft for Thomas, 13 November 2026

**30 of 31 changed modules machine-checked; epoch invariant being finalized**

**Qualification:** this is the predecessor-reported status, not a receipt-verified result of this review. The predecessor reports 30 individual Lake checks, `Invariant` unverified, and a failed last full build. A complete 22-file axiom pass is not established. No prior revision’s full certification is established either. Independent source review is pending; this draft does not anticipate its outcome.

## What the formal work says

The actual theorem statements describe conditional guarantees about Lean contract models, not unconditional certification of the deployed vault. Reading a declaration establishes what it claims, not that its proof machine-checks at this exact revision. The guarantees below are statement-level, source-inspected summaries; exact-revision machine-check evidence remains separately unverified.

`audit/FINAL-REPORT.md` claims that all seven guarantees are resolved and records client confirmations. These are historical repository notes, not fresh proof receipts or revalidated team agreements. Earlier partial-library passes cited in historical documentation do not establish a full current build or axiom gate; Hindsight access was denied, so those agreements were not retrieved or reconfirmed:

- **Prices:** over admitted AA-price episodes, a price decrease requires a registered loss, default finalization, or positive management-fee accrual. This requires coherent/nonempty checkpoints, fee and signed-NAV bounds, and no unregistered NAV drop at accounting inputs. `depositDuringEpoch` is excluded from the episode guarantee; this is not a blanket AA/BB price guarantee.
- **APR:** the latest model’s admitted running-epoch strategy traces preserve the APR used. Unlike the original pin, attempted non-CDO setters now include manager attempts and revert on wired strategies. The trace remains restricted: it is not a theorem about every possible administrative or cross-contract action.
- **Interest:** successful start records `pending fees + max(calculated NAV interest + signed adjustment, 0)` and clears the adjustment. Normal cash/minted settlement relates that commitment plus modeled in-epoch deltas to net interest, under start/stop invariants, faithful external calls, no APR0 principal, and successful borrower pulls. The privileged interest-override stop is outside this normal-settlement promise.
- **APR-zero withdrawals:** under the recorded-rate and epoch hypotheses, settlement credits principal exactly, bounds interest by the request’s realized pro-rata share, and clears the request. The public-stop result additionally needs a fresh rate, open principal, cash mode, and nondefaulted before/after states.
- **Losses:** a successful admitted loss stop splits pending loss as `floor(loss × pending basis / total eligible basis)` and assigns the remainder active-side. The negative-gain accounting waterfall is BB-first; simple “NAV falls by exactly the registered loss” wording is wrong when interest/fees settle together.
- **Recovery:** successful finalization records a positive-basis shared recovery multiplier and cash-backed reserve. It requires a default receipt-ledger equality in addition to `InvFacts`, faithful calls, and a recovery source distinct from the strategy. A theorem explicitly shows that the ledger is not implied by `InvFacts` alone after default.
- **Claims:** successful normal/instant claims from an `InvFacts` state clear the relevant entitlement, preserve specified other-user fields, conserve recovery reserve, and retain cash backing. These success-conditional statements do not establish claim availability or eventual payment.

## Boundary and assumptions

Original proof `90a26536c92930d306fed221a929c48b9363f9f3` vendors Solidity `54502d162e58fef706e7c3dfd24e59c442ae5576`. Latest audit branch `Idle-Labs/idle-tranches:fixes-and-updated` was independently read at `2ac4eab34d72478a3914ead646e1834976f37427`. The separate fetched proof worktree `origin/wip/pr112-verify`, at `6599011a703a7d489d230105bb1ec8596a9cd43b`, vendors that latest pin. **The old proof is not transferred to the new source; neither fetched worktree is the missing restored-patch artifact.**

`RefinesPareto` constrains registered external-call return values and state effects to the modeled deployment. Underlying-token behavior is the modeled standard ERC20, not arbitrary fee-on-transfer, rebasing, callback, or malicious-token behavior. Unregistered calls are not covered by that refinement. Administrative controls and wiring are modeled assumptions/operations, not a promise that all privileged actions are harmless. The keyring adapter admits arbitrary Boolean answers and failures with read-only state behavior: it does not prove credential-policy truth or oracle availability. The interest-start theorem explicitly assumes non-programmable-borrower mode.

Arithmetic specs use mathematical naturals/integers, floor division, and the source’s division order; the interest formula divides APR by 100 before multiplying. Checked word overflow/reverts and signed bounds must be connected through the implementation lemmas, not assumed away. Storage separation is proved over symbolic namespaced keys; that is not a proof of physical EVM hashing/layout or compiler equivalence. Source/model fidelity and compilation remain separate acceptance boundaries.

Allowed logical axioms are only `propext`, `Classical.choice`, and `Quot.sound`; `sorryAx`, `Lean.ofReduceBool`/`native_decide` trust, and project axioms are not allowed by the audit policy. Existing `#print axioms` scripts are not evidence that the complete current 22-file pass succeeded.

## Snapshot specification change — material disclosure

The stronger restored `StartNavState` is reported to explicitly record the snapshot write. Code inspection confirms that latest Solidity writes `openingUnclaimedFees = unclaimedFees` before reading NAV (`IdleCDOEpochVariant.sol:245–262`); the generated Lean body does the same (`Cdo/IdleCDOEpochVariant.lean:738–746`). The latest vendored Solidity file’s Git blob matches the GitHub file at the exact latest pin (`87e9e8836760c06862d66d0854e383a21af0902f`).

However, both fetched proof revisions still have the older `StartNavState` (`Interest1Start.lean:199–205`): its unchanged-slot frame lacks an exception for `openingUnclaimedFees` and it has no snapshot-equality field. **The strengthened declaration and its proof are not verified here until the restored patch is supplied.** Acceptance must check both the frame exception and explicit equality to the pre-start fee value, then recheck downstream interest/epoch proofs. This is a specification change, not merely a proof-tactic repair.

## Open before sign-off

1. Obtain coordinator’s saved uncommitted repair patch and exact 31-module manifest; the committed `wip/pr112-verify` branch does not include that repair set. Worker `8c609dfb-9355-4b54-9852-4c66ec61b4db` access remains pending. Bind each individual success receipt to module content, dependency revision, command, and exit code.
2. Finish/recheck `Invariant`, then complete a coherent full build. The conditional `inv1_preserved_by_ledger_step` takes preservation obligations as an input; it does not discharge them itself.
3. Verify the strengthened snapshot declaration and dependent proofs; run the complete 22-file transitive axiom check on those exact inputs.
4. Complete independent source/model review and source-delta disposition at `2ac4eab34d`; do not label source changes certified from old results or isolated test receipts.
5. Hindsight search/recall was reported denied with “Administrator required”; team agreements could not be retrieved and are not reconstructed here.

No push, team message, or subagent was used. Prepared before the requested 14:25 UTC draft cutoff; the request also lists a 15:33 report deadline.
