import Lake
open System Lake DSL

package «orb-locald» where
  version := v!"0.13.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := #["-lssl", "-lcrypto", "-lutil", "-ldl"]

require «orb-spec» from ".."
require «orb-net-leaf» from "../OrbNetLeaf"
require «orb-bin» from "../OrbBin"

@[default_target]
lean_lib OrbLocald where
  roots := #[`OrbLocald, `OrbLocald.Spec, `OrbLocald.MutantSuite]
  precompileModules := false

@[default_target]
lean_exe «orb-locald» where
  root := `OrbLocald.CliMain
  supportInterpreter := false

@[default_target]
lean_exe «orb-locald-test» where
  root := `OrbLocald.SelfTest
  supportInterpreter := false
