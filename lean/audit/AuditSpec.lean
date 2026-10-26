/-
  Axiom, anti-vacuity, 10-Meta-Spec, and adversarial self-test audit for `Orb.Kernel` / `Orb.Spec`
  (CI gate, not part of the `Orb` library).

  Run after `lake build` from `lean/`:
    LEAN_PATH=.lake/build/lib/lean lean audit/AuditSpec.lean

  Fails (error exit) when:
  - any declaration in `Orb.Kernel` or `Orb.Spec` depends on `sorryAx` or on an axiom
    other than `propext`, `Classical.choice`, `Quot.sound`;
  - either module declares its own `axiom`;
  - a `theorem` in `Orb.Spec` concludes `True`, assumes `False`, or concludes a syntactic
    reflexive equality (`lhs = rhs` or `(lhs == rhs) = true` with `lhs == rhs`);
  - any of the 10 Universal Meta-Specs (`StickyFence`, `ClockDiscipline`, `ScopedAuthority`,
    `ConservedResource`, `ProjectionStability`, `EffectSafety`, `EffectLiveness`, `CostBound`,
    `ReplayIdempotence`, `GrammarConfinement`) or `MetaStepSpec` is missing from `Orb.Spec`;
  - an `@[export]`ed kernel function is not referenced by any `Orb.Spec` declaration
    (a C-ABI export without a spec);
  - the built-in adversarial self-test fails to reject any of the 4 synthetic vacuous/reflexive
    theorem shapes (`bad_true_concl`, `bad_false_hyp`, `bad_refl_eq`, `bad_refl_beq`).
-/
import Lean
import Orb.Spec

open Lean Elab Command

private def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

private def requiredMetaSpecs : List Name := [
  `Orb.Spec.StickyFence,
  `Orb.Spec.ClockDiscipline,
  `Orb.Spec.ScopedAuthority,
  `Orb.Spec.ConservedResource,
  `Orb.Spec.ProjectionStability,
  `Orb.Spec.EffectSafety,
  `Orb.Spec.EffectLiveness,
  `Orb.Spec.CostBound,
  `Orb.Spec.ReplayIdempotence,
  `Orb.Spec.GrammarConfinement,
  `Orb.Spec.MetaStepSpec
]

private def moduleConsts (env : Environment) (mod : Name) : CommandElabM (Array Name) := do
  let some idx := env.getModuleIdx? mod | throwError "module {mod} not loaded"
  return env.header.moduleData[idx.toNat]!.constNames.filter fun n => !n.isInternalDetail

private partial def stripForall : Expr → List Expr × Expr
  | .forallE _ d b _ => let (hs, c) := stripForall b; (d :: hs, c)
  | e => ([], e)

/-- Structural anti-vacuity predicate on a theorem statement `ty`. Returns `some reason` if rejected. -/
private def checkTheoremVacuity (ty : Expr) : Option String :=
  let (hyps, concl) := stripForall ty
  if concl.isConstOf ``True then
    some "vacuous theorem (concludes True)"
  else if hyps.any (·.isConstOf ``False) then
    some "vacuous theorem (assumes False)"
  else
    match concl.eq? with
    | some (_, lhs, rhs) =>
      if lhs == rhs then
        some "reflexive equality conclusion (lhs = lhs)"
      else
        match lhs.app4? ``BEq.beq with
        | some (_, _, a, b) =>
          if a == b && rhs.isConstOf ``Bool.true then
            some "reflexive boolean equality conclusion ((x == x) = true)"
          else none
        | none => none
    | none => none

/-- Adversarial self-test: verifies `checkTheoremVacuity` rejects all 4 synthetic bad theorem types. -/
private def runAdversarialSelfTest : CommandElabM Unit := do
  let natTy := mkConst ``Nat
  let zeroE := mkConst ``Nat.zero
  let badTrue := mkForall `x BinderInfo.default natTy (mkConst ``True)
  let badFalse := mkForall `h BinderInfo.default (mkConst ``False) (mkApp3 (mkConst ``Eq [Level.one]) natTy zeroE zeroE)
  let badReflEq := mkForall `x BinderInfo.default natTy
    (mkApp3 (mkConst ``Eq [Level.one]) natTy (mkBVar 0) (mkBVar 0))
  let badReflBeq := mkForall `x BinderInfo.default natTy
    (mkApp3 (mkConst ``Eq [Level.one]) (mkConst ``Bool)
      (mkApp4 (mkConst ``BEq.beq [Level.zero]) natTy zeroE (mkBVar 0) (mkBVar 0))
      (mkConst ``Bool.true))
  if (checkTheoremVacuity badTrue).isNone then
    throwError "Adversarial self-test failed: badTrue was not rejected"
  if (checkTheoremVacuity badFalse).isNone then
    throwError "Adversarial self-test failed: badFalse was not rejected"
  if (checkTheoremVacuity badReflEq).isNone then
    throwError "Adversarial self-test failed: badReflEq was not rejected"
  if (checkTheoremVacuity badReflBeq).isNone then
    throwError "Adversarial self-test failed: badReflBeq was not rejected"

#eval show CommandElabM Unit from do
  runAdversarialSelfTest
  let env ← getEnv
  let kernel ← moduleConsts env `Orb.Kernel
  let spec ← moduleConsts env `Orb.Spec
  let mut errors : Array String := #[]
  for req in requiredMetaSpecs do
    unless env.contains req do
      errors := errors.push s!"missing required Meta-Spec in Orb.Spec: {req}"
  for n in kernel ++ spec do
    let some ci := env.find? n | continue
    if ci matches .axiomInfo _ then
      errors := errors.push s!"{n}: declares an axiom"
    let axs ← liftCoreM <| collectAxioms n
    for a in axs do
      unless allowedAxioms.contains a do
        errors := errors.push s!"{n}: depends on {a}"
  let mut theorems : Nat := 0
  for n in spec do
    let some (.thmInfo t) := env.find? n | continue
    theorems := theorems + 1
    if let some reason := checkTheoremVacuity t.type then
      errors := errors.push s!"{n}: {reason}"
  let mut exports : Nat := 0
  for n in kernel do
    let some sym := getExportNameFor? env n | continue
    exports := exports + 1
    let used := spec.any fun s => match env.find? s with
      | some ci => ci.type.getUsedConstants.contains n ||
          (ci.value?.map (·.getUsedConstants.contains n)).getD false
      | none => false
    unless used do
      errors := errors.push s!"{n} (export {sym}): not referenced by any Orb.Spec declaration"
  let mut metaStepSpecs : Nat := 0
  for n in spec do
    let some ci := env.find? n | continue
    if ci.type.isAppOf ``Orb.Spec.MetaStepSpec then
      metaStepSpecs := metaStepSpecs + 1
  if theorems == 0 || exports == 0 || metaStepSpecs < 6 then
    errors := errors.push s!"audit found {theorems} theorems / {exports} exports / {metaStepSpecs} MetaStepSpecs; expected theorems > 0, exports > 0, metaStepSpecs >= 6"
  unless errors.isEmpty do
    throwError "Orb spec audit failed:\n{String.intercalate "\n" errors.toList}"
  logInfo m!"Orb spec audit OK: {kernel.size + spec.size} declarations, {theorems} theorems, {exports} exports, {metaStepSpecs} MetaStepSpec instances, 10 Meta-Specs + adversarial self-test verified, axioms ⊆ {allowedAxioms}"
