> **DRAFT — written as if the last module (`Invariant`), the full build and the axiom check have passed. Do not send before they do. Items marked [confirm] must be checked against the final run. Remove this block before sending.**

# Pareto Credit Vault — Formal Verification Report

**Client:** Pareto Credit
**Auditor:** Verity (LFG Labs)
**Date:** November 2026
**Source:** `Idle-Labs/idle-tranches`, PR #112, commit `2ac4eab34d72478a3914ead646e1834976f37427`
**Contracts in scope:** `IdleCDOEpochVariant`, `IdleCDOCreditVault`, `IdleCreditVault`, with `IdleCDOTranche` and the ERC-20 they depend on
**Compiler:** solc 0.8.10; optimizer runs 1 for the two CDO contracts, 999999 for `IdleCreditVault`
**Proof repository:** `lfglabs-dev/pareto-credit-vault-proof-closure`

## 1. Result

All seven guarantees agreed with the Pareto team are machine-checked in Lean 4 against a model of the contracts at this commit. The proofs use no unproven steps and no axioms beyond Lean's three standard ones.

Every issue found during the engagement was either fixed in PR #112 or confirmed by Pareto as intended behaviour. No open finding remains.

## 2. Guarantees

Each guarantee holds under the assumptions in section 3.

| | Guarantee | What is proved |
|---|---|---|
| PRICE-1 | Tranche price only goes down for a known reason | The AA price decreases only after a registered loss, a default, or management-fee accrual |
| APR-1 | The APR is locked during an epoch | No one but the CDO can change the strategy APR while an epoch is running |
| INTEREST-1 | Epoch interest is computed once and correctly | Epoch start records the expected interest; a normal stop settles exactly that amount net of fees, in cash and in minted mode |
| APR0-1 | APR-zero withdrawals are settled once | Principal is returned exactly once, and interest is bounded by the request's share of that epoch's realized interest |
| LOSS-1 | A registered loss is split fairly | Loss is split pro-rata between pending withdrawals and active holders (`floor(L × Q / (A + Q))`), BB absorbs first, and the total is conserved |
| RECOVERY-1 | Default recovery is one-time and uniform | A default is finalized once, every holder gets the same recovery rate, and the reserve backs all entitlements |
| CLAIM-1 | Claims are single-use and isolated | A claim pays once, does not touch other users, and never overspends the recovery reserve |

These rest on a 23-clause cross-contract invariant (INV-1) linking the CDO, the strategy, the tranche tokens and the underlying token. It is proved to hold at deployment and to be preserved by the operations the guarantees rely on.

## 3. Assumptions

Confirmed with Pareto during the engagement; none requires a code change.

1. **Trusted roles.** Owner and manager are operated by Pareto. The owner does not use `transferToken` on active reserves, fee and buffer parameters are not changed mid-epoch, and the settlement mode only moves from cash to minted.
2. **Standard token.** The underlying is a standard ERC-20 (no transfer fee, no rebasing). The borrower interacts only through `transferFrom`.
3. **Normal epoch stop.** INTEREST-1 covers the normal stop (`_interest = 0`). The manager's interest override on stop (`_newApr = 0` with a custom amount) is intended by design and outside this guarantee.
4. **Two-tranche configuration.** Adaptive yield split (AYS) is enabled whenever both tranches are economically active, which disables `depositDuringEpoch`.
5. **APR-zero scope.** The stop-to-settlement proof covers requests made in the epoch being stopped.
6. **Upgrades.** Live vaults are upgraded from a clean state (no active default).
7. **Vault value.** The underlying vault value does not fall on its own outside a registered loss or default.

Out of scope: the prefunded variant and programmable-borrower vaults. Results do not transfer to them.

## 4. Method

**Model.** Each in-scope Solidity contract is translated one-to-one into Verity, our contract language embedded in Lean 4. Every function, branch, revert condition, storage write and arithmetic operation in the Solidity has a counterpart in the model, in the same order.

**Proofs.** Each guarantee is stated as a Lean theorem about the model and checked by the Lean kernel. Where a guarantee did not hold as first stated, we produced a counterexample on the model, then either Pareto fixed the code or we agreed the exact condition under which it holds.

**Why the model is faithful.**

- *Line-by-line review.* The model was compared with the Solidity function by function: coverage, branch order, revert conditions, order of storage reads and writes around external calls, checked arithmetic and rounding, and storage layout. Accepted deviations are listed in the repository.
- *Replay on the real contracts.* Every counterexample and fix established on the model is replayed as a Foundry test against the pinned Solidity, compiled with the production settings. The model's predictions match the contracts in all 57 tests across 15 suites [confirm].
- *Limit.* This is a reviewed translation plus differential testing, not a proof that the compiled bytecode equals the model. Compiler correctness is assumed.

**Trust base.** Lean 4 kernel; axioms `propext`, `Classical.choice`, `Quot.sound` only [confirm]; no `sorry`, no project axioms, no `native_decide`.

## 5. Findings and their resolution

| Finding | Resolution |
|---|---|
| APR could be changed mid-epoch by the manager | Fixed in PR #112: setter reverts while an epoch is running |
| One-argument `setApr` during the buffer skipped the instant-withdraw APR check | Fixed at `2ac4eab3`: public `setApr` removed; updates go through `setAprs` / `setAprsWithBuffer` |
| Management fee charged entirely to BB; a tiny BB balance could trigger a vault default | Fixed in PR #112: fee allocated pro-rata by tranche NAV; fee-only BB wipe-out prevented |
| Loss registered on an epoch that also earned interest was processed in the wrong order | Fixed in PR #112: a stop with a loss settles zero active interest and skips performance-fee minting |
| Write-off after a late mid-epoch deposit subtracted full-epoch interest | Fixed in PR #112: interest is reduced proportionally, pending withdrawal fees preserved |
| Fixed-epoch interest can be overridden on stop | Intended by design (confirmed 7 October) |
| Management fee keeps accruing past `epochEndDate` if `stopEpoch` is delayed | Intended by design: continuous fees (confirmed 11 November) |
| Mid-epoch deposit can lower the saved price on a forced accounting update | See note below |

**Note on mid-epoch deposits.** This applies only when AYS is disabled; with AYS enabled `depositDuringEpoch` reverts. In an AA-only vault the effect is a rounding difference of 1 wei, which the proof allows as a tolerance. The decrease is in the *saved* price at a checkpoint; in our reproduction it did not change later minted shares or final payouts, so it is not a demonstrated economic loss. With management fees accruing, an automatic accounting update can also reprice shares, not only a manual one.

**Informational.**

- `maxWithdrawable` is an estimate and does not include pending management fees or instant mode; Pareto documented this and kept it unchanged because of bytecode size. `eth_call` on `requestWithdraw` gives an exact quote.
- `_projectedNAV`: we found no reachable underflow path. The fee projection and `virtualPrice` match actual settlement in cash and minted modes.
- Default recovery applies one shared rate without seniority; Pareto may change this later, and the guarantee would then need updating.
- An expired Keyring credential blocks new deposits and withdrawal requests, as intended; existing requests can still be claimed.

## 6. Reproducing

```
lake build                      # checks every proof
forge test --root . -vvv        # replays findings and fixes on the pinned Solidity
```

Build: passed at proof commit `[confirm]`. Axiom check: 22 of 22 files clean [confirm].
