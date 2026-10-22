import Lake
open Lake DSL

package «orb-spec» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib «Orb» where
  globs := #[.submodules `Orb]
