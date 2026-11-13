import Lake
open Lake DSL

package «orb-client» where
  version := v!"0.1.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]

require «orb-spec» from ".."

@[default_target]
lean_lib «OrbClient» where
  roots := #[`OrbClient]
  precompileModules := false

@[default_target]
lean_exe «orb-client-test» where
  root := `OrbClient.SelfTest
  supportInterpreter := false
