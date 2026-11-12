import Lake
open System Lake DSL

package «orb-core» where
  version := v!"0.7.10"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]

require «orb-spec» from ".."
require «orb-net-leaf» from "../OrbNetLeaf"
require «orb-bin» from "../OrbBin"

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
  exeName := "orb-core"
  root := `OrbCore.CliMain
  supportInterpreter := false

@[default_target]
lean_exe «orb-core-test» where
  root := `OrbCore.SelfTest
  supportInterpreter := false

@[default_target]
lean_exe «orb-spec-runner» where
  root := `OrbCore.SpecRunnerMain
  supportInterpreter := false
