/-
  Axiom and vacuity audit for `Orb.Kernel` / `Orb.Spec` (CI gate, not part of the `Orb` library).

  Run after `lake build` from `lean/`:
    LEAN_PATH=.lake/build/lib/lean lean audit/AuditSpec.lean

  Fails (error exit) when
  - any declaration in `Orb.Kernel` or `Orb.Spec` depends on `sorryAx` or on an axiom
    other than `propext`, `Classical.choice`, `Quot.sound`;
  - either module declares its own `axiom`;
  - a `theorem` in `Orb.Spec` concludes `True` or assumes `False` (vacuous statement);
  - an `@[export]`ed kernel function is not referenced by any `Orb.Spec` declaration
    (a C-ABI export without a spec).
-/
import Lean
import Orb.Spec

open Lean Elab Command

private def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

private def moduleConsts (env : Environment) (mod : Name) : CommandElabM (Array Name) := do
  let some idx := env.getModuleIdx? mod | throwError "module {mod} not loaded"
  return env.header.moduleData[idx.toNat]!.constNames.filter fun n => !n.isInternalDetail

private partial def stripForall : Expr → List Expr × Expr
  | .forallE _ d b _ => let (hs, c) := stripForall b; (d :: hs, c)
  | e => ([], e)

#eval show CommandElabM Unit from do
  let env ← getEnv
  let kernel ← moduleConsts env `Orb.Kernel
  let spec ← moduleConsts env `Orb.Spec
  let mut errors : Array String := #[]
  for n in kernel ++ spec do
    let some ci := env.find? n | continue
    if ci matches .axiomInfo _ then
      errors := errors.push s!"{n}: declares an axiom"
    let axs ← liftCoreM <| collectAxioms n
    for a in axs do
      unless allowedAxioms.contains a do
        errors := errors.push s!"{n}: depends on {a}"
  let mut theorems := 0
  for n in spec do
    let some (.thmInfo t) := env.find? n | continue
    theorems := theorems + 1
    let (hyps, concl) := stripForall t.type
    if concl.isConstOf ``True then
      errors := errors.push s!"{n}: vacuous theorem (concludes True)"
    if hyps.any (·.isConstOf ``False) then
      errors := errors.push s!"{n}: vacuous theorem (assumes False)"
  let mut exports := 0
  for n in kernel do
    let some sym := getExportNameFor? env n | continue
    exports := exports + 1
    let used := spec.any fun s => match env.find? s with
      | some ci => ci.type.getUsedConstants.contains n ||
          (ci.value?.map (·.getUsedConstants.contains n)).getD false
      | none => false
    unless used do
      errors := errors.push s!"{n} (export {sym}): not referenced by any Orb.Spec declaration"
  if theorems == 0 || exports == 0 then
    errors := errors.push s!"audit found {theorems} theorems / {exports} exports; expected both > 0"
  unless errors.isEmpty do
    throwError "Orb spec audit failed:\n{String.intercalate "\n" errors.toList}"
  logInfo m!"Orb spec audit OK: {kernel.size + spec.size} declarations, {theorems} theorems, {exports} exports, axioms ⊆ {allowedAxioms}"
