import Lake
open Lake DSL

package «lean-mesh» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    -- `declaration uses 'sorry'` is a warning; fail the build on it.
    ⟨`warningAsError, true⟩
  ]

@[default_target]
lean_lib «LeanMesh» where
  globs := #[.submodules `LeanMesh]
  precompileModules := true
