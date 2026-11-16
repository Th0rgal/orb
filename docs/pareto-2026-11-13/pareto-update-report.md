# Pareto Credit Vault — update on `fixes-and-updated`

**Date:** 13 November 2026
**Source reviewed:** `Idle-Labs/idle-tranches`, branch `fixes-and-updated`, commit `2ac4eab34d72478a3914ead646e1834976f37427`
**Compared against:** the originally audited commit `54502d162e58fef706e7c3dfd24e59c442ae5576` (25 commits earlier)
**Previously confirmed to you:** `440fe500bf1c0bab0b6c09100a701e849d016c97` on 11 November; the commit pushed after that removes the one-argument `setApr`, which closes the buffer-period APR point we raised

## Summary

- The new fee snapshot (`openingUnclaimedFees`, written at `startEpoch`) does what it is meant to do. Two independent reviews each reproduced the write-off formula on a fresh epoch and matched it exactly.
- The storage layout change is structurally safe: the two new fields take slots from the gap, and no existing field moves.
- **One thing to act on before upgrading:** the upgrade must not happen while an epoch is running, and legacy accrued management fees should be settled first. Both are upgrade-procedure conditions, not bugs in the steady-state logic. Details in section 2.
- Formal verification of this commit is not complete yet\*. 30 of the 31 proof modules affected by the change are machine-checked; the epoch invariant module is being finalized.

\* See section 4 for exactly what is and is not machine-checked today.

## 1. What changed and what we checked

At epoch start the contract now records the fees that were already unclaimed (`openingUnclaimedFees = unclaimedFees`), and `writeOffDeposit` excludes that amount from its denominator:

```
relief = underlyings × (expectedInterest − feeFloor) / (lastNAVAA + lastNAVBB + unclaimedFees − openingUnclaimedFees)
```

Checked and found consistent with the intended accounting:

| Area | Result |
|---|---|
| Snapshot value and write order | Written in `startEpoch` before the NAV read; only pre-epoch fees are excluded, fees accrued during the epoch stay in the base |
| Write-off proration | Matches the formula to the wei, including a mid-epoch deposit and pending-withdrawal fee floors |
| Storage layout | `pendingManagementFees` at slot 243, `openingUnclaimedFees` at slot 244, gap reduced 43 → 41; all existing labels, slots and offsets unchanged in the epoch, prefunded and strategy contracts |
| Management-fee activation | No fee while `epochNumber() == 0`; no retroactive charge on the first epoch |
| `setFeeParams` | Accrues at the old rate before changing it; caps enforced |
| APR setter | Manager can no longer change APR during a running epoch |
| `stopEpoch` ordering | Accrue, mint, update accounting, then mint fee shares at the exact NAV ratio; no double counting found |
| No underflow in the new denominator | `unclaimedFees` only grows during an epoch on the normal path |

## 2. Findings

### 2.1 Upgrading during a running epoch leaves the snapshot at zero

*Found independently by both reviewers, each with a passing reproduction. Severity: low to medium, and only if an upgrade is performed mid-epoch.*

The snapshot is written only by `startEpoch`. If a vault is upgraded while an epoch started on the old implementation is still running, the new slot reads zero. A write-off in that epoch then waives less interest than intended, by the factor (opening unclaimed fees ÷ strategy principal). The borrower over-pays and the remaining lenders receive the difference. Nothing reverts.

Example: a 20,000-token vault carrying about 200 tokens of unpaid fees; the borrower writes off a quarter to a half of the position; relief is short by about 4.95 tokens (about 1%).

**Recommendation:** upgrade only between epochs, or add a one-time migration that sets the snapshot to the true epoch-opening value. Your existing fork-upgrade test covers one migration that re-syncs the slot; the gap is for any other upgrade path.

### 2.2 Management fees accrued before the upgrade are allocated by the old rule

*Found by one reviewer with a reproduction. Severity: medium if the new pro-rata allocation is expected to apply across the upgrade.*

On the old implementation, `setFeeParams` can accrue management fees into `unclaimedFees` without updating tranche NAVs. After the upgrade `pendingManagementFees` starts at zero, so the next accounting update treats that amount as an ordinary loss and charges it junior-first. In the reproduction (AA and BB at 10,000 each, about 100 tokens accrued), BB was charged about 100 tokens where a NAV-proportional split would charge about 50.

**Recommendation:** checkpoint and allocate fees on the old implementation before upgrading, or migrate the unallocated management-fee amount explicitly.

### 2.3 Upgrade the CDO and the strategy together

The new `stopEpoch` calls `prepareStopEpochWithApr0(uint256,bool)`, which the old strategy does not have. Upgrading only the CDO made `stopEpoch` revert in a reproduction; upgrading both resolved it.

### 2.4 Lower-priority observations

- **APR0 allocation depends on checkpoint timing.** The APR0 split reads contract value before `stopEpoch` accrues elapsed management fees. An owner or guardian accounting checkpoint just before the stop changes the split slightly (about 49.75 vs 50.00 tokens on 500 pending shares in the reproduction).
- **A one-unit deposit mid-epoch can raise fees.** A dust deposit triggers an accounting checkpoint and shifts about 10.5 tokens from holders to the fee receiver in a 20,000-token example. This behaves identically at the original audited commit, so it is not introduced by this change.
- **Exact zero-interest loss settlement** for programmable borrowers needs `pendingWithdrawFees` to be exactly zero; a dust residue would block it. Analytical only, not reproduced.
- **Contract size.** An independent compile puts the epoch contract 48 bytes under the 24,576-byte limit. Check against your exact build settings.
- **ABI change.** The public one-argument `setApr` is removed; integrations that call it need updating.
- **Management fee keeps accruing after `epochEndDate`** when `stopEpoch` is delayed. You confirmed on 11 November that continuous fees are the expected behaviour; noted here as agreed.

## 3. Assumptions

These apply to the review above and to the formal proofs.

- **Token:** a standard ERC-20. Fee-on-transfer, rebasing, callback or malicious tokens are not covered.
- **Roles:** owner, proxy admin, manager, guardian, strategy and programmable borrower are trusted. Privileged loss, default and recovery actions are modeled operations, not guaranteed harmless.
- **External calls:** the proofs constrain the registered external calls to the modeled deployment. Unregistered calls are outside the model.
- **Keyring / credential check:** modeled as returning any answer; the proofs do not establish policy correctness or availability.
- **Arithmetic:** specifications use exact integers with floor division in the source's order of operations.
- **Storage:** separation is proved over symbolic storage keys; it is not a proof of the compiler's physical layout. The layout check in section 1 is a separate, compile-based check.
- **Logical axioms:** only Lean's standard three (`propext`, `Classical.choice`, `Quot.sound`). No `sorry` and no `native_decide` are permitted in the final package.
- **Not checked:** your production state, deployment schedule, or deployment scripts and configuration.

## 4. Formal verification status\*

| Item | Status at `2ac4eab3` |
|---|---|
| Proof modules affected by the change | 31 |
| Machine-checked individually | 30 |
| Epoch invariant module (`Invariant`) | Being finalized; not yet machine-checked |
| Full build of the whole proof project | Not yet passed on this commit |
| Complete axiom check (22 files) | Not yet passed on this commit |

One specification was strengthened, not weakened: the epoch-start state description now records the snapshot write explicitly (the slot equals the pre-start `unclaimedFees`).

The guarantees these proofs target, each conditional on the assumptions above:

- **Prices:** the AA price only decreases through a registered loss, a default finalization, or management-fee accrual.
- **APR:** the APR in use is preserved through a running epoch.
- **Interest:** epoch start records the expected interest; normal settlement pays it net of fees.
- **APR0 withdrawals:** principal is credited exactly and interest is bounded by the request's pro-rata share.
- **Losses:** a registered loss is split pro-rata between pending and active positions, junior tranche first.
- **Recovery:** default finalization records a shared recovery rate backed by cash.
- **Claims:** a successful claim clears that entitlement only and leaves other users and the reserve intact.

\* Until the last module, the full build and the axiom check pass, the statements in this section are the intended guarantees, with 30 of 31 affected modules checked. The findings and checks in sections 1 and 2 come from source review and executable reproductions, not from the formal proofs. We will send the complete verification package when it passes.

## 5. Method and limits

- Two independent source reviews of the full diff between the two commits, run without sharing notes, each with executable reproductions (one on a mainnet fork with Foundry, one on a local EVM with independently compiled contracts).
- One reviewer ran the repository's Foundry suite (227 of 229 passing, the two failures attributed to RPC rate limits); the other did not run the repository suites.
- `IdleCreditVaultWriteOffEscrow.sol` is unchanged in this range and was not reviewed.
- No exhaustive fuzzing or adversarial reentrancy campaign was run.
