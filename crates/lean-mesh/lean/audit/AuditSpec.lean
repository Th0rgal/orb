import Lean
import LeanMesh.Kernel
import LeanMesh.Spec

/-
  Independent Zero-Trust Specification Auditor (`lean/audit/AuditSpec.lean`)
  Verifies at build time:
  1. Neither `LeanMesh/Kernel.lean` nor `LeanMesh/Spec.lean` contains `import Lean` (checked both
     via whitespace-tokenized source scanning and environment module graph inspection).
  2. Every theorem/declaration in `LeanMesh.Kernel` and `LeanMesh.Spec` has `0 sorryAx` and zero custom axioms
     (only standard axioms `propext`, `Classical.choice`, `Quot.sound` are permitted).
  3. No theorem in `LeanMesh.Spec` is vacuous (`True` conclusion or syntactic `False` hypothesis).
  4. 100% of `@[export]` C-ABI functions in `LeanMesh.Kernel` are transitively referenced by at least
     one machine-checked `.thmInfo` theorem in `LeanMesh.Spec`.
-/

open Lean

def allowedAxioms : List Name :=
  [``propext, ``Classical.choice, ``Quot.sound]

def collectTransitiveConstantsAndAxioms (env : Environment) (n : Name) : (NameSet × List Name) := Id.run do
  let mut visited : NameSet := {}
  let mut worklist : List Name := [n]
  let mut axioms : List Name := []
  while !worklist.isEmpty do
    match worklist with
    | [] => break
    | curr :: rest =>
      worklist := rest
      if visited.contains curr then
        continue
      visited := visited.insert curr
      if let some cinfo := env.find? curr then
        match cinfo with
        | .axiomInfo _ =>
          if !axioms.contains curr then
            axioms := curr :: axioms
        | _ =>
          let used := cinfo.getUsedConstantsAsSet
          for u in used do
            if !visited.contains u then
              worklist := u :: worklist
  return (visited, axioms)

partial def isVacuousTheoremType (e : Expr) : Bool :=
  match e with
  | .forallE _ d b _ =>
    if d.isConstOf ``False then true
    else isVacuousTheoremType b
  | _ => e.isConstOf ``True

def main : IO Unit := do
  -- 1a. Source-level whitespace-tokenized `import Lean` check
  for path in (["LeanMesh/Kernel.lean", "LeanMesh/Spec.lean"] : List System.FilePath) do
    let src ← IO.FS.readFile path
    for line in src.splitOn "\n" do
      let tokens := (line.trimAscii.toString.splitOn " ").filter (fun s => !s.isEmpty)
      match tokens with
      | "import" :: modName :: _ =>
        if modName == "Lean" || modName.startsWith "Lean." then
          throw <| IO.userError s!"FATAL: `{path}` contains forbidden `import {modName}`"
      | _ => pure ()

  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `LeanMesh.Kernel }, { module := `LeanMesh.Spec }] {}

  -- 1b. Environment module graph check (`Lean` metaprogramming namespace must not be imported)
  for modName in env.header.moduleNames do
    let modStr := modName.toString
    if modStr == "Lean" || modStr.startsWith "Lean." then
      throw <| IO.userError s!"FATAL: Environment module graph contains forbidden module `{modStr}`"

  let mut kernelExports : List Name := []
  let mut specTheoremRefs : List (Name × NameSet) := []
  let mut totalTheorems : Nat := 0

  for (name, cinfo) in env.constants.map₁.toList do
    let nameStr := name.toString
    if nameStr.startsWith "LeanMesh.Kernel." || nameStr.startsWith "LeanMesh.Spec." then
      -- 2. Transitive axiom check
      let (transConsts, ax) := collectTransitiveConstantsAndAxioms env name
      for a in ax do
        if a == ``sorryAx then
          throw <| IO.userError s!"FATAL: `{name}` transitively depends on `sorryAx`"
        if !allowedAxioms.contains a then
          throw <| IO.userError s!"FATAL: `{name}` depends on forbidden custom axiom `{a}`"

      if nameStr.startsWith "LeanMesh.Kernel." then
        if (Lean.getExportNameFor? env name).isSome then
          if !nameStr.endsWith "._cstage1" && !nameStr.endsWith "._cstage2" && !nameStr.contains "_boxed" then
            kernelExports := name :: kernelExports

      if nameStr.startsWith "LeanMesh.Spec." then
        if let .thmInfo tval := cinfo then
          totalTheorems := totalTheorems + 1
          if isVacuousTheoremType tval.type then
            throw <| IO.userError s!"FATAL: Theorem `{name}` in `LeanMesh.Spec` is vacuous"
          specTheoremRefs := (name, transConsts) :: specTheoremRefs

  -- 4. 100% C-ABI export `.thmInfo` theorem coverage check
  let mut coveredExports : Nat := 0
  for expName in kernelExports do
    let mut referencedByTheorem := false
    for (_, transConsts) in specTheoremRefs do
      if transConsts.contains expName then
        referencedByTheorem := true
        break
    if !referencedByTheorem then
      throw <| IO.userError s!"FATAL: Exported kernel function `{expName}` has 0 `.thmInfo` theorem references in `LeanMesh.Spec`"
    coveredExports := coveredExports + 1

  IO.println s!"[AUDIT PASS] 0 `import Lean`, 0 `sorryAx`, 0 custom axioms, 0 vacuous theorems ({totalTheorems} theorems checked), {coveredExports}/{kernelExports.length} C-ABI exports covered by `.thmInfo` theorems."
