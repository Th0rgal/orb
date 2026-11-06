import Lake
open Lake DSL
open System (FilePath)

package «orb-net-leaf» where
  version := v!"0.1.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := #["-lssl", "-lcrypto", "-lutil", "-ldl"]

require «lean-sys» from git
  "https://github.com/Th0rgal/lean-sys.git" @ "d658cb2450743434d255e59ea4225bd651681177"

target orb_net_leaf_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "orb_net_leaf.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "orb_net_leaf.c"
  let leanIncludeDir ← getLeanIncludeDir
  buildO oFile srcJob #["-I", leanIncludeDir.toString] #["-std=gnu11", "-O3", "-fPIC", "-Wall", "-Wextra", "-Werror"] "cc"

extern_lib liborb_net_leaf_shim pkg := do
  let shimO ← orb_net_leaf_o.fetch
  let name := nameToStaticLib "orb_net_leaf_shim"
  buildStaticLib (pkg.staticLibDir / name) #[shimO]

@[default_target]
lean_lib «OrbNetLeaf» where
  roots := #[`OrbNetLeaf]
  precompileModules := false

@[default_target]
lean_exe «orb-net-leaf-test» where
  root := `OrbNetLeaf.SelfTest
  supportInterpreter := false
