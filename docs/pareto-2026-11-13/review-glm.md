# Independent Security Review — Idle-Labs/idle-tranches `fixes-and-updated`

- **Head reviewed:** `2ac4eab34d72478a3914ead646e1834976f37427` (branch `fixes-and-updated`)
- **Diff base:** `54502d162e58fef706e7c3dfd24e59c442ae5576` (25 commits)
- **Scope:** `IdleCDOCreditVault.sol`, `IdleCDOEpochVariant.sol`, `IdleCDOStorage.sol`, `IdleCreditVaultFactory.sol`, `IdleCreditVaultImpliedPrice.sol`, `strategies/idle/IdleCreditVault.sol`, `strategies/idle/ProgrammableBorrower.sol`, `IdleCDOEpochVariantPrefunded.sol` (diff), plus tests as evidence.
- **Method:** manual line-level review + storage-layout reconstruction + differential fork tests (mainnet fork @ 18678289, USDC) with PoCs in `test/foundry/AuditOpeningUnclaimedFees.t.sol` (run: `forge test --match-contract AuditOpeningUnclaimedFees`, `ETH_RPC_URL=https://eth.drpc.org`). Full suite baseline at this head: 227/229 pass in audit harness context; pre-existing suite passes except RPC-429 flakes.

## Findings

### F-1 (LOW, confirmed by PoC) — Mid-epoch proxy upgrade zeroes `openingUnclaimedFees`, understating write-off debt relief

`contracts/IdleCDOEpochVariant.sol` — `writeOffDeposit` (~line 963-985):

```solidity
uint256 interest = ... _underlyings * (expectedInterest - feeFloor) /
  (lastNAVAA + lastNAVBB + unclaimedFees - openingUnclaimedFees);
```

`openingUnclaimedFees` is a new slot carved out of the previous `__gap` (`IdleCDOStorage.sol:135`). It is written only in `startEpoch` (line 245). A vault whose implementation is upgraded **while an epoch is running** initializes the slot to `0` (gap slots are empty), so the denominator becomes `lastNAV + unclaimedFees` — inflated by the pre-epoch fee carry-over `U0`.

**Effect:** write-off interest relief is understated by the factor `U0/S` (S = strategy tokens). `expectedEpochInterest` stays too high, so at settlement the borrower pays interest already written off, to the benefit of remaining LPs. No revert/underflow (`unclaimedFees >= openingUnclaimedFees` holds; during an epoch `unclaimedFees` only grows). Value transfer only between borrower and LPs; no protocol loss.

**Aggravation:** `unclaimedFees` grows across zero/low-interest cash-mode epochs (stopEpoch pays fees only out of cash interest: `_availableForFees`), so distressed flat-yield vaults — exactly the write-off-prone ones — can carry a material `U0`.

**PoC** (`testMidEpochUpgradeUnderstatesWriteOffRelief`, passing at this head): AA-only cash-mode vault, 20,000 USDC, mgmt fee 1%/yr; epoch 1 at 0 APR leaves ~200.004876 USDC unpaid fees; epoch 2 at 10% APR, borrower writes off half its position:

```
epoch interest E          = 1,985.424656 USDC
control relief (formula)   =   496.342565 USDC
post-upgrade relief        =   491.379139 USDC   (slot zeroed mid-epoch)
understated by             =     4.963426 USDC   (== relief * U0/S, U0/S ≈ 1%)
```

**Recommendation:** re-initialize `openingUnclaimedFees = unclaimedFees` defensively at the top of `writeOffDeposit` (or gate `writeOffDeposit`/`stopEpoch` on `openingUnclaimedFees != 0 || unclaimedFees == 0` after an upgrade), or document that upgrades must not occur mid-epoch. Note the project's own upgrade-path test (`testWriteOffFalconXForkUpgrade`) covers a specific migration that re-syncs the slot; the gap remains for arbitrary future upgrades.

### F-2 (Informational, analytical) — Programmable zero-interest loss settlement requires exact `pendingWithdrawFees == 0`

`stopEpoch` zero-interest loss settlement (`_interest == 0` path) resolves `expectedEpochInterest` down to `pendingWithdrawFees` only when the floor is exactly zero for programmable borrowers (`settleBorrowerInterest` requires the full amount incl. the fee floor). A dust `pendingWithdrawFees` (e.g. 1 wei) left over from a redeemed request keeps the programmable borrower's required transfer above the intended loss level. Theoretical (requires exact-dust residue); not demonstrated on-chain here.

### F-3 (Informational) — Multi-decade accrual without checkpoints can wrap BB NAV

`_virtualPriceAux` gain allocation uses `int256` accumulators; sustained >50-year gaps between accounting checkpoints at live fee/APR settings could overflow the BB gain accumulator. Not reachable under any realistic `epochDuration`/`bufferPeriod` configuration; noted for completeness.

## Verified-correct areas (no finding)

1. **Write-off proration is exactly the intended accounting** (positive assurance, PoC `testWriteOffReliefMatchesFormula`): relief == `underlyings * (E - feeFloor) / (lastNAV + U - U0)` and the denominator identity `lastNAV + U - U0 == S - U0` (epoch-start interest base) both hold to the wei, including mid-epoch fee accrual and pending-withdraw floors.
2. **Storage layout**: `pendingManagementFees`/`openingUnclaimedFees` appended after `isBBDepositEnabled`, `__gap` reduced 43→41 — total slots preserved; child `IdleCDOEpochVariantPrefunded` layout unaffected; upgrading proxies read both as 0 (only F-1's write-off reads the internal one).
3. **Management-fee activation** (`IdleCDOCreditVault._calculateManagementFee`): returns 0 while `epochNumber() == 0`; `epochNumber` increments in strategy `deposit()` during `stopEpoch` **after** `_accrueManagementFee` (line 390), so no retroactive charging on first epoch.
4. **`setFeeParams`** (`IdleCDOCreditVault.sol:468`): accrues at the old rate before changing it; caps `_managementFee <= 2000` (2%/yr), `_fee <= MAX_FEE`; mid-epoch changes handled consistently by elapsed-time accrual.
5. **`_setApr` (was `setApr`, commit 2ac4eab)**: manager blocked mid-epoch (`msg.sender != _cdo && isEpochRunning()`); CDO path via `stopEpoch`'s `_setScaledApr` unaffected.
6. **`stopEpoch` ordering** (lines 340-480): accrue (390) → mint mode `S += grossInterest`/`U += pendingWithdrawFees` (436-438) → `_updateAccounting` (442) → fee-share minting at exact NAV ratio, floor-safe (451-465, `unclaimedFees -= _fees` only after mint) — no double counting, no dilution (`_mintSharesAtCurrPrice` adds proportional NAV).
7. **`_mintSharesAtCurrPrice` / `_trancheToUnderlyings`** exact-ratio changes round in favor of existing holders.
8. **`unclaimedFees` monotonicity during an epoch** → no underflow in the write-off denominator on the non-upgrade path.
9. **`finalizeDefault`** zeroes fee state and refreshes `latestHarvestBlock` before forced accounting; recovery enters via strategy reserve, donations skimmed.

## Caveats

- This is a source review with differential testing, **not** a formal verification of the full contract system; no complete behavioral gate was established for unchanged legacy paths.
- `IdleCreditVaultWriteOffEscrow.sol` was not part of the reviewed diff (unchanged in range) — out of scope.
- Test-harness-only deviations (do not affect audited source): `lib/forge-std` checked out at 15b2df92 with local pragma/assembly patches because the pinned submodule commit (31fffde) is unfetchable; fork RPC via public endpoint (drpc) with 429-flake retries.
- Findings distinguish severity/conditions; F-1's trigger requires an operator action (mid-epoch upgrade) outside normal parameters.
