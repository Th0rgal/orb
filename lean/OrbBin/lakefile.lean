import Lake
open Lake DSL
open System (FilePath)

package «orb-bin» where
  version := v!"1.3.0"
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := if System.Platform.isOSX then #["-lssl", "-lcrypto"] else #["-lssl", "-lcrypto", "-lutil", "-ldl"]

require «orb-spec» from ".."
require «lean-mesh» from "../LeanMesh"
require «orb-net-leaf» from "../OrbNetLeaf"

target orb_bin_posix_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "orb_bin_posix.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "orb_bin_posix.c"
  let leanIncludeDir ← getLeanIncludeDir
  buildO oFile srcJob #["-I", leanIncludeDir.toString] #["-std=gnu11", "-O3", "-fPIC", "-Wall", "-Wextra", "-Werror"] "cc"

extern_lib liborb_bin_posix pkg := do
  let shimO ← orb_bin_posix_o.fetch
  let name := nameToStaticLib "orb_bin_posix"
  buildStaticLib (pkg.staticLibDir / name) #[shimO]

@[default_target]
lean_lib «OrbBin» where
  roots := #[`OrbBin]
  precompileModules := false

@[default_target]
lean_exe «fido-agent-proxy» where
  root := `OrbBin.Exe.FidoAgentProxy
  supportInterpreter := false

@[default_target]
lean_exe «orb-privd» where
  root := `OrbBin.Exe.Privd
  supportInterpreter := false

@[default_target]
lean_exe «orb-sudo» where
  root := `OrbBin.Exe.Sudo
  supportInterpreter := false

@[default_target]
lean_exe «lean-mesh-cli» where
  exeName := "lean-mesh"
  root := `OrbBin.Exe.Mesh
  supportInterpreter := false

@[default_target]
lean_exe «palomactl» where
  root := `OrbBin.Exe.PalomaCtl
  supportInterpreter := false

@[default_target]
lean_exe «sandboxed-mcp» where
  root := `OrbBin.Exe.SandboxedMcp
  supportInterpreter := false

@[default_target]
lean_exe «workspace-mcp» where
  root := `OrbBin.Exe.WorkspaceMcp
  supportInterpreter := false

@[default_target]
lean_exe «desktop-mcp» where
  root := `OrbBin.Exe.DesktopMcp
  supportInterpreter := false

@[default_target]
lean_exe «automation-manager-mcp» where
  root := `OrbBin.Exe.AutomationMcp
  supportInterpreter := false

@[default_target]
lean_exe «orb-bin-test» where
  root := `OrbBin.Exe.SelfTest
  supportInterpreter := false
