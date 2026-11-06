import Lake
open Lake DSL
open System (FilePath)

package «orb-node» where
  version := v!"1.3.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := #["-lssl", "-lcrypto", "-lutil", "-ldl"]

require «orb-spec» from ".."
require «orb-net-leaf» from "../OrbNetLeaf"
require «orb-bin» from "../OrbBin"

target orb_node_posix_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "orb_node_posix.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "orb_node_posix.c"
  let leanIncludeDir ← getLeanIncludeDir
  buildO oFile srcJob #["-I", leanIncludeDir.toString] #["-std=gnu11", "-O3", "-fPIC", "-Wall", "-Wextra", "-Werror"] "cc"

extern_lib liborb_node_posix pkg := do
  let shimO ← orb_node_posix_o.fetch
  let name := nameToStaticLib "orb_node_posix"
  buildStaticLib (pkg.staticLibDir / name) #[shimO]

@[default_target]
lean_lib «OrbNode» where
  roots := #[`OrbNode]
  precompileModules := false

@[default_target]
lean_exe «orb-node» where
  exeName := "sandboxed-node"
  root := `OrbNode.CliMain
  supportInterpreter := false

@[default_target]
lean_exe «orb-node-test» where
  root := `OrbNode.SelfTest
  supportInterpreter := false
