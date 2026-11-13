import Lake
open System Lake DSL

package «orb-spec» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    -- `declaration uses 'sorry'` is a warning; fail the build on it.
    ⟨`warningAsError, true⟩
  ]
  moreLinkArgs := #["-lwayland-client", "-lxkbcommon", "-lfreetype", "-lharfbuzz", "-lfontconfig", "-ldl"]

@[default_target]
lean_lib «Orb» where
  globs := #[.submodules `Orb]
  precompileModules := false

/-- Pure `LeanUI` library (`0` FFI, `0` IO, kernel-verified layout/scene/widgets/style + `OrbDesktop.State`..`Screens`). -/
lean_lib «LeanUI» where
  roots := #[`LeanUI, `OrbDesktop.State, `OrbDesktop.Chrome, `OrbDesktop.Screens]
  precompileModules := false

/-- Kernel-verified specifications and mutant suite (`0` `sorry`, `0` `native_decide`). -/
lean_lib «LeanUISpec» where
  roots := #[`LeanUI.Spec.LayoutSpec, `LeanUI.Spec.DamageSpec, `LeanUI.Spec.FocusSpec, `LeanUI.Spec.AtlasSpec, `LeanUI.Spec.MutantSuite]
  precompileModules := false

/-- FFI + runtime layer (`LeanUI.FFI`, `LeanUI.Wayland`, `LeanUI.Text`, `LeanUI.Vulkan`, `LeanUI.Runtime`, `LeanUI.Canary`, `OrbDesktop.Main`). -/
lean_lib «LeanUIRuntime» where
  roots := #[`LeanUI.FFI, `LeanUI.Wayland, `LeanUI.Text, `LeanUI.Vulkan, `LeanUI.Runtime, `LeanUI.Canary, `OrbDesktop.Main]
  precompileModules := false

target lean_ui_wayland_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_wayland.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / "c" / "lean_ui_wayland.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString, "-I/usr/include/freetype2", "-I/usr/include/harfbuzz"] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

target lean_ui_text_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_text.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / "c" / "lean_ui_text.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString, "-I/usr/include/freetype2", "-I/usr/include/harfbuzz"] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

target lean_ui_vulkan_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "lean_ui_vulkan.o"
  let srcJob ← inputTextFile <| pkg.dir / ".." / "c" / "lean_ui_vulkan.c"
  let leanIncludeDir ← getLeanIncludeDir
  let cDir := pkg.dir / ".." / "c"
  buildO oFile srcJob #["-I", leanIncludeDir.toString, "-I", cDir.toString] #["-std=c11", "-O2", "-fPIC"] ((← IO.getEnv "LEAN_CC").getD "cc")

extern_lib liblean_ui_c pkg := do
  let wlO ← lean_ui_wayland_o.fetch
  let txO ← lean_ui_text_o.fetch
  let vkO ← lean_ui_vulkan_o.fetch
  let name := nameToStaticLib "lean_ui_c"
  buildStaticLib (pkg.staticLibDir / name) #[wlO, txO, vkO]

lean_exe «lean-ui-canary» where
  root := `LeanUI.Canary
  supportInterpreter := false

lean_exe «orb-desktop» where
  root := `OrbDesktop.Main
  supportInterpreter := false


