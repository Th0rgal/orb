import Lake
open System Lake DSL

package «orb-core» where
  version := v!"0.7.10"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]

-- These libraries are needed by the final executable link. Putting the flags
-- on the package also marks every library module as having a custom linker
-- configuration, preventing turbo-lean from reusing its verified Lake trace.

require «orb-spec» from ".."
require «orb-net-leaf» from "../OrbNetLeaf"
require «orb-bin» from "../OrbBin"
require «orb-node» from "../OrbNode"

target orb_core_sqlite_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "orb_core_sqlite.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "orb_core_sqlite.c"
  let leanIncludeDir ← getLeanIncludeDir
  buildO oFile srcJob #["-I", leanIncludeDir.toString] #["-std=gnu11", "-O3", "-fPIC", "-Wall", "-Wextra", "-Werror"] ((← IO.getEnv "LEAN_CC").getD "cc")

extern_lib liborb_core_sqlite pkg := do
  let shimO ← orb_core_sqlite_o.fetch
  let name := nameToStaticLib "orb_core_sqlite"
  buildStaticLib (pkg.staticLibDir / name) #[shimO]

@[default_target]
lean_lib «OrbCore» where
  roots := #[`OrbCore]
  precompileModules := false

@[default_target]
lean_exe «orb-core» where
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]
  exeName := "orb-core"
  root := `OrbCore.CliMain
  supportInterpreter := false

@[default_target]
lean_exe «orb-core-test» where
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]
  root := `OrbCore.SelfTest
  supportInterpreter := false

/-- Credential-owner integration fixture for scripts/test_airvpn_sidecar.py. -/
lean_exe «orb-airvpn-sidecar-test» where
  root := `OrbCore.AccountVpnSidecarTestMain
  supportInterpreter := false

/-- Focused inner loop; reuses the tests in orb-core-test without compiling Control. -/
lean_exe «orb-managed-provider-test» where
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]
  root := `OrbCore.ManagedProviderTestMain
  supportInterpreter := false

@[default_target]
lean_exe «orb-spec-runner» where
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]
  root := `OrbCore.SpecRunnerMain
  supportInterpreter := false

lean_exe «r24-focused» where
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]
  root := `R24Focused
  supportInterpreter := false
