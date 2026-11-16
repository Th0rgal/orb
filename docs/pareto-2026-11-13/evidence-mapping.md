# Pareto evidence mapping — 13 November 2026

## Evidence labels and roots

- **O**: locally fetched original proof, `proof/`, exact HEAD `90a26536c92930d306fed221a929c48b9363f9f3`.
- **L**: separate locally fetched latest-source adaptation, `latest-proof/`, exact HEAD `6599011a703a7d489d230105bb1ec8596a9cd43b` (`origin/wip/pr112-verify`).
- **R**: inaccessible saved, uncommitted 31-module repair patch, **not supplied**. Neither O nor L includes or substitutes for R. Worker `8c609dfb-9355-4b54-9852-4c66ec61b4db` access is pending (coordinator update); no worker evidence was read.
- Coordinator also reports a Spark checkout named `pareto-proof`; this review used the separate local O/L worktrees above. `audit/FINAL-REPORT.md`, `audit/FINDINGS.md`, and `audit/assumptions.yaml` exist but are not substitutes for the actual theorem statements, definitions, or execution receipts.
- All mappings below are **source-inspected declarations**, not newly kernel-checked results. A theorem statement establishes the conditional claim being made; it does not establish successful machine checking of its proof and dependencies at the exact reviewed revision. No build or axiom execution receipts were supplied/inspected for R. “30 of 31” remains predecessor evidence; no per-module success attribution is invented.
- `audit/FINAL-REPORT.md` prose claiming all seven guarantees resolved and recording client confirmations is **historical repository testimony only**, not a fresh proof receipt or a revalidated team agreement. Historical references to earlier partial-library passes do not establish a complete current build or axiom gate. Hindsight access was denied; no team agreement is treated as retrieved or reconfirmed.
- Paths below are relative to the indicated worktree. `S/` abbreviates `ParetoCreditVault/Audit/Verity/Source/`; `P/` abbreviates `ParetoCreditVault/Audit/Spec/`.

## Guarantee → theorem → specification and restrictions

| Guarantee | Actual declaration in L | Specification / critical restrictions |
|---|---|---|
| AA price exceptions | `S/Guarantees.lean:354`, `price1_no_fee_exceptions_episode`; `:368`, `price1_full_lifecycle_episode` | `P/Predicates.lean:74`, `PricePreservationWithFees`; `S/G5Price.lean:76` requires `InvFacts`, initialized/nonempty AA and signed BB-NAV bound at boundaries. Episode constructors carry admissible steps/A-P2; do not infer all lifecycle actions or all tranches. |
| Running APR | `S/Apr1.lean:518`, `apr_used_stable_under_A7`; `S/Guarantees.lean:424`, `apr1_stable_under_A7` | `P/Predicates.lean:93`, `CurrentEpochAprStability`; actual `A7Step` constructors at `S/Apr1.lean:479–513` include all attempted non-CDO setters on wired strategies, owner cap/manager changes, reader and manager transfer-disable. The older “no manager setter” summary is stale for L. |
| Start/normal settlement interest | `S/Interest1Start.lean:218`, `startEpoch_expectedEpochInterest`; `S/Guarantees.lean:491/:530`, cash/minted settlement | `P/Predicates.lean:106/:116`; start needs distinct addresses, strategy wiring, non-programmable borrower and success. Settlement adds start/stop `InvFacts`, restricted trace, refinement, no APR0, mode and pull readiness. L’s snapshot frame is stale; R must be inspected. |
| APR0 once/share | `S/Guarantees.lean:600`, `apr0_settlement_once_with_realized_share`; `:631`, `apr0_public_stop_to_settlement` | `P/Predicates.lean:128`; direct call needs positive bucket, past principal, no prior settlement and recorded rate. Public call adds fresh rate, cash mode, open principal, no default before/after, faithful calls and successful stop/settlement. |
| Loss allocation / waterfall | `S/Guarantees.lean:721`, `loss1_pending_active_allocation`; `:749`, `loss1_bb_first_waterfall_and_conservation` | `P/Predicates.lean:152`, `ExplicitLossAllocation`; allocation is conditional on successful nonzero-loss stop, refinement and `InvFacts`, with no APR0 in the simple theorem. Combined theorem has separate APR0 branch. Negative-gain BB-first is distinct from total net NAV movement. |
| Default recovery | `S/Guarantees.lean:872`, `recovery1_receipts_backed`; `:926`, public CDO form | `P/Predicates.lean:160/:171`; needs extra default receipt ledger, refinement, source ≠ strategy and success. `:848`, `recovery1_boundary_obstruction`, demonstrates the ledger gap on an admitted state, not a reachable-source exploit. |
| Normal/instant claims | `S/Guarantees.lean:1000/:1067`, single-use reserve-backed theorems | `P/Predicates.lean:185`; `InvFacts` + success yields receipt clearing, specified cross-user frames and reserve conservation/backing. Not liveness. |
| Invariant | `S/Guarantees.lean:1153`, establishment; `:1177/:1187`, specific preservation; `:1200`, ledger-step harness | Fresh deployment requires stated nonzero/distinct-address and successful-deployment hypotheses. General harness takes `InvFactsStepObligations` as a parameter. It does not establish unconditional all-entrypoint preservation. R’s `Invariant` remains predecessor-reported unverified. |

## Per-module artifact table (available evidence, not a reconstructed change manifest)

The coordinator’s exact 31 changed module names and restored paths are absent. These rows identify inspected artifacts relevant to that mapping; **membership in the 31-module set and individual Lake status are unassigned unless explicitly noted**. The remaining changed-module identities cannot honestly be filled from a 150-file branch diff.

| Available module / artifact | Evidence extracted | R receipt / status |
|---|---|---|
| `S/Guarantees.lean` | O and L theorem signatures; latest references above | Pending exact restored version and receipt |
| `S/Interest1Start.lean` | O/L `StartNavState:199–205`, start theorem `:218` | Reported stronger spec absent in O/L; verify R |
| `S/Interest1Stop.lean` | O settlement use of `StartNavState`, including `:941` and `:1256` | Pending |
| `S/Apr1.lean` | L `A7Step:479`, stability theorem `:518` | Pending |
| `S/G5Price.lean` | L domain `:76`, per-step result `:96`, episode constructors `:107` | Pending |
| `S/Invariant.lean` | Available in O/L; do not equate source presence with checked restoration | **Predecessor says unverified** |
| `S/Cdo/IdleCDOEpochVariant.lean` | L snapshot write `:738–739`, NAV read `:746`, interest record `:755–758` | Pending |
| `S/Steps/RequestLinks.lean` | L `RefinesPareto:14–19` constrains registered return values and state effects | Pending |
| `S/Links.lean` | L standard-token and strategy dispatch `:34–44`, canonical context `:110` | Pending |
| `S/Fidelity.lean` | L generated-model scope; symbolic mapping separation `:30–37`, helper proofs `:61+` | Pending; comments do not replace fidelity acceptance |
| `S/Keyring.lean` | L adapter `:18`, state frame `:37`, arbitrary result `:69`, failure `:94`, typed answer `:144` | Pending |
| `S/Axioms.lean` | L allowlist policy `:24–29`; actual `#print axioms` requests | No execution receipt; not a completed pass |
| `S/AxiomsTrack/Guarantees.lean` | O/L report-request file, including named APR theorem requests | No execution receipt |
| `P/Predicates.lean` | Actual independent predicate bodies `:55–196`; stale introductory status comments not used for result claims | Not assigned to changed set |
| `P/Units.lean` | L formula `:37–38`; mathematical domain `:12–15` | Not assigned to changed set |
| `reference/source-provenance.json` | O exact source pin `:4`; L latest provenance present | Metadata, not machine-check receipt |
| `reference/solidity/contracts/IdleCDOEpochVariant.sol` | L snapshot `:245`, formula `:262–265` | Exact file blob matched GitHub at latest SHA |
| `lakefile.lean` | O/L Verity dependency pin at `:7–8`, Lean target at `:19–24` | Build configuration, not completed build |

## Original/latest separation

O’s top-level price/APR/interest/APR0/loss/recovery/claim results are at `S/Guarantees.lean:352/:403/:470/:579/:700/:851/:979` respectively; invariant harness is `:1179` (use actual source when updating citations). O’s unrestricted-manager APR counterexample at `:390` must not be described as a latest-source result. L’s manager-rejection theorem at `:397` is a concrete witness; its broader trace theorem has the explicit `A7Step` scope above. No old result or source comment establishes a successful rebuild of L or R.

## Acceptance gaps

- Missing R patch path, exact module manifest and content hashes: cannot populate a truthful 31-row changed-module status table yet.
- Missing individual receipts, successful full build, and complete 22-file axiom receipts: cannot promote predecessor status to independently checked certification.
- Missing strengthened snapshot declaration: require frame exception **and** explicit snapshot value, then downstream rechecks.
- Independent source review pending. Hindsight search/recall reportedly denied (“Administrator required”); team agreements unavailable.
- No code edits, build, lint, typecheck, push, team message, or subagent execution was performed; only read-only remote discovery, local fetch/worktree materialization, source inspection, and draft creation.
