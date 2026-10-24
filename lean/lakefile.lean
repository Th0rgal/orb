import Lake
open Lake DSL

package «orb-spec» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    -- `declaration uses 'sorry'` is a warning; fail the build on it.
    ⟨`warningAsError, true⟩
  ]

@[default_target]
lean_lib «Orb» where
  globs := #[.submodules `Orb]
