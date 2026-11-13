import Lake
open System Lake DSL

package «orb-desktop-native» where
  srcDir := ".."
  leanOptions := #[⟨`autoImplicit, false⟩, ⟨`warningAsError, true⟩]
  moreLinkArgs := #["-lwayland-client", "-lxkbcommon", "-lfreetype", "-lharfbuzz", "-lfontconfig", "-ldl"]

require «orb-spec» from ".."

lean_lib «LeanUI» where
  roots := #[`LeanUI, `OrbDesktop.State, `OrbDesktop.Chrome, `OrbDesktop.Screens]
  precompileModules := false

lean_lib «LeanUIRuntime» where
  roots := #[`LeanUI.FFI, `LeanUI.Wayland, `LeanUI.Text, `LeanUI.Vulkan, `LeanUI.Runtime, `LeanUI.Canary, `OrbDesktop.Main]
  precompileModules := false

target lean_ui_wayland_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_wayland.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / ".." / "c" / "lean_ui_wayland.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

target lean_ui_text_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_text.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / ".." / "c" / "lean_ui_text.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString, "-I/usr/include/freetype2", "-I/usr/include/harfbuzz"] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

target lean_ui_vulkan_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_vulkan.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / ".." / "c" / "lean_ui_vulkan.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

extern_lib liblean_ui_c pkg := do
  let wlO ← lean_ui_wayland_o.fetch
  let txO ← lean_ui_text_o.fetch
  let vkO ← lean_ui_vulkan_o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "lean_ui_c") #[wlO, txO, vkO]

lean_exe «orb-desktop-native» where
  root := `OrbDesktop.Main
  supportInterpreter := false
