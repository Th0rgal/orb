import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
import LeanUI.Widgets.VirtualList
import LeanUI.Widgets.RichText
import LeanUI.Widgets.DiffViewer
import LeanUI.Widgets.MermaidSvg
import LeanUI.Widgets.Overlays
import LeanUI.Widgets.Composer
import LeanUI.FFI
import LeanUI.Wayland
import LeanUI.Text
import LeanUI.Vulkan
import LeanUI.Runtime
import OrbDesktop.State
import OrbDesktop.Chrome
import OrbDesktop.Screens
/-!
# OrbDesktop.Main — Wave 3 Native Orb Desktop Shell Entry Point, 36-Golden Runner & Benchmark Harness

Integrates `OrbDesktop.State`, `OrbDesktop.Chrome`, and `OrbDesktop.Screens` with the native
Wayland + Vulkan 1.3 + HarfBuzz/FreeType runtime (`LeanUI.Runtime`) to support:
- `--headless-golden-all <out_dir>`: renders all 36 golden PNGs (`9 screens × 2 themes × 2 scales`)
  while verifying `0` redraws when quiescent (`framesRendered == 1`, `quiescentSkips >= 1`)
  for every single screen variant.
- `--headless-golden <out_path_or_dir>` with optional `--screen <id>`, `--dark`/`--light`, `--scale120 <120|240>`:
  renders a single screen PNG (or all 36 if `<out_path_or_dir>` has no `.png` suffix and `--screen` is omitted).
- `--bench <iterations>`: renders full frames at `--width`/`--height` through `Runtime.stepFrame`
  and prints JSON metrics (`cold_ms`, `frame_p50_ms`, `frame_p99_ms`, `frames_rendered`,
  `quiescent_skips`, `work_units`, `error_count`, `width`, `height`, `first_frame_crc32`).
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- Extended CLI configuration for `OrbDesktop.Main`. -/
structure DesktopCliConfig where
  runtimeCfg : Runtime.RuntimeConfig := {}
  headlessGoldenAllDir : Option System.FilePath := none
  screenOpt : Option ScreenId := none
  benchIterations : Option Nat := none
  selfTest : Bool := false
  deriving Repr, Inhabited

/-- Parse `OrbDesktop` CLI arguments. -/
def parseDesktopArgs (args : List String) : DesktopCliConfig :=
  let rec loop (rem : List String) (cfg : DesktopCliConfig) : DesktopCliConfig :=
    match rem with
    | [] => cfg
    | "--self-test" :: rest =>
      loop rest { cfg with selfTest := true }
    | "--headless-golden-all" :: dir :: rest =>
      loop rest { cfg with headlessGoldenAllDir := some dir }
    | "--headless-golden" :: path :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with headlessGolden := some path } }
    | "--screen" :: scrStr :: rest =>
      loop rest { cfg with screenOpt := ScreenId.parse? scrStr }
    | "--bench" :: nStr :: rest =>
      loop rest { cfg with benchIterations := some (max 1 (nStr.toNat?.getD 20)) }
    | "--width" :: w :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with width := w.toNat?.getD cfg.runtimeCfg.width } }
    | "--height" :: h :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with height := h.toNat?.getD cfg.runtimeCfg.height } }
    | "--scale120" :: s :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with scale120 := s.toNat?.getD cfg.runtimeCfg.scale120 } }
    | "--light" :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with darkTheme := false } }
    | "--dark" :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with darkTheme := true } }
    | "--frames" :: n :: rest =>
      loop rest { cfg with runtimeCfg := { cfg.runtimeCfg with maxFrames := n.toNat?.getD cfg.runtimeCfg.maxFrames } }
    | _ :: rest =>
      loop rest cfg
  loop args {}

/-- Shape a single-line or word-wrapped UTF-8 string into `List InlineRun` via `LeanUI.Text`
(updating `GlyphAtlasCache`), or synthesize deterministic fallback `InlineRun` advances when
running without a font face. -/
def shapeDesktopRuns (ac : Text.GlyphAtlasCache) (font : Text.FontHandle)
    (scale120 : Nat) (style : TextStyle) (text : String) :
    IO (Text.GlyphAtlasCache × List InlineRun) := do
  if text.isEmpty then
    return (ac, [])
  let devSize64 : UInt32 := ((style.sizeSub * scale120 + scaleDen / 2) / scaleDen).toUInt32
  if font.facePtr != 0 then
    let shaped ← Text.shapeText font devSize64 text ""
    let mut curAc := ac
    let mut glyphs : List ShapedGlyph := []
    let scDen : Int := scaleDen
    let scNum : Int := if scale120 == 0 then 120 else scale120
    for sg in shaped do
      let (ac', entry) ← Text.getOrRasterizeGlyph curAc font sg.glyphId devSize64 0
      curAc := ac'
      let advSubNat : SubPx := ((max 0 sg.xAdvance64 * scDen) / scNum).toNat
      let xOffSub : Int := (sg.xOffset64 * scDen) / scNum
      let yOffSub : Int := (sg.yOffset64 * scDen) / scNum
      let g : ShapedGlyph := {
        glyphId := sg.glyphId.toNat
        cluster := sg.cluster.toNat
        xAdvance := max (4 * subPerPx) advSubNat
        yAdvance := 0
        xOffset := xOffSub
        yOffset := yOffSub
        atlasSrc := entry.uv
        sizePx := (entry.uv.w.toNat, entry.uv.h.toNat)
        bearingPx := (entry.bearingX, entry.bearingY)
        isColor := entry.isColor
      }
      glyphs := glyphs ++ [g]
    let run : InlineRun := {
      glyphs := glyphs
      style := style
      allowBreakAfter := true
      hardBreakAfter := false
    }
    return (curAc, [run])
  else
    return (ac, [overlaySynthRun style text])

/-- Recursively shape any synthetic `.text` runs in `WidgetNode` into real HarfBuzz/FreeType
glyph runs so every label, badge, table cell, composer text, modal, and toast renders with `Inter`. -/
partial def shapeWidgetTree (ac : Text.GlyphAtlasCache) (font : Text.FontHandle) (scale120 : Nat)
    (node : WidgetNode) : IO (Text.GlyphAtlasCache × WidgetNode) := do
  match node with
  | .mk wid focusable hitTestable style payload children =>
    let mut curAc := ac
    let newPayload ←
      match payload with
      | .text lineHeightSub runs =>
        let mut shapedRuns : List InlineRun := []
        for r in runs do
          let isSynth := !r.glyphs.isEmpty && r.glyphs.all (fun g => g.sizePx.1 == 0 && g.sizePx.2 == 0)
          if isSynth then
            let txt := String.ofList (r.glyphs.map (fun g => Char.ofNat g.glyphId))
            let (ac', rs) ← shapeDesktopRuns curAc font scale120 r.style txt
            curAc := ac'
            let rsAdjusted := rs.map (fun sr =>
              { sr with allowBreakAfter := r.allowBreakAfter, hardBreakAfter := r.hardBreakAfter })
            shapedRuns := shapedRuns ++ rsAdjusted
          else
            shapedRuns := shapedRuns ++ [r]
        pure (WidgetPayload.text lineHeightSub shapedRuns)
      | other => pure other
    let mut shapedChildren : List WidgetNode := []
    for c in children do
      let (ac', c') ← shapeWidgetTree curAc font scale120 c
      curAc := ac'
      shapedChildren := shapedChildren ++ [c']
    return (curAc, .mk wid focusable hitTestable style newPayload shapedChildren)

/-- Render one frame of `DesktopState` via `OrbDesktop.buildDesktopScreen`, `Layout.layoutNode`,
`Scene.buildSceneFromLayout`, and HarfBuzz/FreeType glyph shaping (`shapeDesktopRuns` + `Text.layoutTextRun`). -/
def renderDesktopFrame (rt : Runtime.RuntimeState DesktopState) :
    IO (Text.GlyphAtlasCache × Color × Scene × List (EntityId × Rect)) := do
  let st := rt.app
  let theme := st.theme
  let pal := theme.palette
  let sc := rt.wayland.scale120
  let (availW, availH) := rt.wayland.logicalSubSize

  let (ac1, hdrRuns) ←
    shapeDesktopRuns rt.atlas rt.primaryFont sc (chromeTitleStyle theme)
      st.screen.headerTitle
  let (ac2, codeRuns) ←
    shapeDesktopRuns ac1 rt.primaryFont sc (Theme.bodyText theme)
      "Turn #1 (builtin/smart) — Verified pure Lean 4 layout, KaTeX math, and unified diff:"
  let (ac3, delRuns) ←
    shapeDesktopRuns ac2 rt.primaryFont sc
      { (Theme.codeText theme) with color := pal.diffDelText }
      "- webkit_web_view_load_uri(wv, orb_dev_url);"
  let (ac4, addRuns) ←
    shapeDesktopRuns ac3 rt.primaryFont sc
      { (Theme.codeText theme) with color := pal.diffAddText }
      "+ buildDesktopScreen st availW availH shapedRuns"

  let shapedRuns : ShapedScreenRuns := {
    headerTitleRuns := hdrRuns
    codeSampleRuns := codeRuns
    diffDelRuns := delRuns
    diffAddRuns := addRuns
  }

  let widgetRootRaw := buildDesktopScreen st availW availH shapedRuns
  let (ac5, widgetRoot) ← shapeWidgetTree ac4 rt.primaryFont sc widgetRootRaw
  let layoutRoot := widgetRoot.toLayoutNode
  let rootBox := layoutNode sc rt.focus.owner pal.focusRing 0 0 availW availH layoutRoot
  let sceneOut := buildSceneFromLayout sc rt.focus theme widgetRoot rootBox
  if st.screen == .searchDialog then
    let overRaw := buildSearchModalOverlay theme availW availH
    let (ac6, overWidget) ← shapeWidgetTree ac5 rt.primaryFont sc overRaw
    let overBox := layoutNode sc none pal.focusRing 0 0 availW availH overWidget.toLayoutNode
    let overScene := buildSceneFromLayout sc rt.focus theme overWidget overBox
    return (ac6, pal.canvas, sceneOut.prims ++ overScene.prims, sceneOut.hitRegionsSub ++ overScene.hitRegionsSub)
  else
    return (ac5, pal.canvas, sceneOut.prims, sceneOut.hitRegionsSub)

/-- `stepDesktopEvent` for the window `rt` currently has. -/
def desktopReducer (rt : Runtime.RuntimeState DesktopState) :
    DesktopState → Event → DesktopState × Damage :=
  stepDesktopEvent rt.wayland.scale120 rt.viewportDeviceRect

/-- Render one `(ScreenId, isDark, scale120)` configuration to `outFile`, verifying that
Frame 1 renders (`framesRendered == 1`) and Frame 2 skips redraw when quiescent (`quiescentSkips >= 1`). -/
def renderSingleGoldenToFile (width height : Nat) (scr : ScreenId) (isDark : Bool) (scale120 : Nat)
    (outFile : System.FilePath) : IO Bool := do
  let cfg : Runtime.RuntimeConfig := {
    headlessGolden := some outFile
    width := width
    height := height
    scale120 := scale120
    darkTheme := isDark
    maxFrames := 2
  }
  let initSt := DesktopState.forScreen scr isDark scale120
  let rt0Raw ← Runtime.initRuntime cfg initSt
  let rt0 := { rt0Raw with focus := initSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  if rt.framesRendered != 1 || rt.quiescentSkips < 1 then
    IO.eprintln s!"Quiescence check failed for {scr.goldenFileName isDark scale120}: frames={rt.framesRendered}, skips={rt.quiescentSkips}"
    Runtime.shutdownRuntime rt
    return false
  if let some parent := outFile.parent then
    IO.FS.createDirAll parent
  Vulkan.writeFramebufferPNG rt.vulkan outFile
  Runtime.shutdownRuntime rt
  return true

/-- Render all 36 canonical golden PNGs (`9 screens × 2 themes × 2 scales`) into `outDir`. -/
def renderAll36Goldens (width height : Nat) (outDir : System.FilePath) : IO UInt32 := do
  IO.FS.createDirAll outDir
  let themes : List Bool := [true, false]
  let scales : List Nat := [120, 240]
  let mut count : Nat := 0
  for scr in ScreenId.all do
    for isDark in themes do
      for sc in scales do
        let fname := scr.goldenFileName isDark sc
        let fpath := outDir / fname
        let ok ← renderSingleGoldenToFile width height scr isDark sc fpath
        if !ok then
          return 1
        count := count + 1
  IO.println s!"Rendered {count}/36 golden PNGs to {outDir}"
  return 0

/-- Format microseconds as milliseconds with two zero-padded decimals (`10050` -> `10.05`). -/
def fmtMs (us : Nat) : String :=
  let frac := (us % 1000) / 10
  s!"{us / 1000}.{if frac < 10 then "0" else ""}{frac}"

/-- Execute `--bench <iterations>`. Every iteration lays out, shapes and rasterises one full
frame at the requested size through `Runtime.stepFrame`, the path the window uses, then checks
that the next quiescent frame is skipped. `first_frame_crc32` is the CRC-32 of the first RGBA
framebuffer (`03_mission_transcript`), so a run can be tied to the golden of the same size. -/
def runDesktopBench (cfg : Runtime.RuntimeConfig) (iterations : Nat) : IO UInt32 := do
  let iters := max 1 iterations
  let tStartNs ← IO.monoNanosNow
  let firstSt := DesktopState.forScreen .missionTranscript cfg.darkTheme cfg.scale120
  let rt0Raw ← Runtime.initRuntime { cfg with headless := true } firstSt
  let rt0 := { rt0Raw with focus := firstSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  let coldUs : Nat := ((← IO.monoNanosNow) - tStartNs) / 1000
  let firstCrc := Vulkan.crc32 rt.vulkan.framebuffer
  let mut frameTimesUs : Array Nat := #[]
  for idx in [0:iters] do
    let scr := ScreenId.all[idx % ScreenId.all.length]?.getD .missionTranscript
    let nextSt := DesktopState.forScreen scr (idx % 2 == 0) cfg.scale120
    rt := { rt.markFullDamage with app := nextSt, focus := nextSt.initialFocusState }
    let f0 ← IO.monoNanosNow
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
    let f1 ← IO.monoNanosNow
    frameTimesUs := frameTimesUs.push ((f1 - f0) / 1000)
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  let (bw, bh) := (rt.vulkan.width, rt.vulkan.height)
  let fbBytes := rt.vulkan.framebuffer.size
  Runtime.shutdownRuntime rt
  let sorted := frameTimesUs.qsort (· < ·)
  let p50Us := sorted[sorted.size / 2]?.getD 0
  let p99Us := sorted[min ((sorted.size * 99) / 100) (sorted.size - 1)]?.getD 0
  let errors : Nat :=
    if rt.framesRendered == iters + 1 && rt.quiescentSkips == iters && fbBytes == bw * bh * 4 then 0 else 1
  IO.println s!"\{\"cold_ms\": {fmtMs coldUs}, \"frame_p50_ms\": {fmtMs p50Us}, \"frame_p99_ms\": {fmtMs p99Us}, \"frames_rendered\": {rt.framesRendered}, \"quiescent_skips\": {rt.quiescentSkips}, \"work_units\": {iters}, \"error_count\": {errors}, \"width\": {bw}, \"height\": {bh}, \"scale120\": {cfg.scale120}, \"first_frame_crc32\": {firstCrc.toNat}}"
  return (if errors == 0 then 0 else 1)

/-- `--self-test`: render one frame offscreen and check that the next, quiescent one is skipped. -/
def runSelfTest (cfg : Runtime.RuntimeConfig) (initSt : DesktopState) : IO UInt32 := do
  let rt0Raw ← Runtime.initRuntime { cfg with headless := true } initSt
  let rt0 := { rt0Raw with focus := initSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  Runtime.shutdownRuntime rt
  if rt.framesRendered != 1 || rt.quiescentSkips < 1 then
    IO.eprintln s!"orb-desktop self-test: frames={rt.framesRendered}, skips={rt.quiescentSkips}"
    return 1
  IO.println "orb-desktop self-test: ok"
  return 0

/-- Main entry point for `OrbDesktop`. -/
def main (args : List String) : IO UInt32 := do
  let dcfg := parseDesktopArgs args
  let rcfg := dcfg.runtimeCfg
  if let some iters := dcfg.benchIterations then
    return (← runDesktopBench rcfg iters)
  if let some allDir := dcfg.headlessGoldenAllDir then
    return (← renderAll36Goldens rcfg.width rcfg.height allDir)
  if let some outPath := rcfg.headlessGolden then
    let pathStr := outPath.toString
    if dcfg.screenOpt.isNone && !pathStr.endsWith ".png" then
      return (← renderAll36Goldens rcfg.width rcfg.height outPath)
    let scr := dcfg.screenOpt.getD .missionTranscript
    let ok ← renderSingleGoldenToFile rcfg.width rcfg.height scr rcfg.darkTheme rcfg.scale120 outPath
    return (if ok then 0 else 1)
  let scr := dcfg.screenOpt.getD .missionTranscript
  let initSt := DesktopState.forScreen scr rcfg.darkTheme rcfg.scale120
  if dcfg.selfTest then
    return (← runSelfTest rcfg initSt)
  try
    let rt0 ← Runtime.openWindowRuntime rcfg "orb-desktop" initSt
    let rt ← Runtime.runWindow { rt0 with focus := initSt.initialFocusState } desktopReducer renderDesktopFrame
    Runtime.shutdownRuntime rt
    return 0
  catch e =>
    IO.eprintln s!"orb-desktop-native: cannot run the window: {e}"
    return 1

end OrbDesktop

/-- Top-level C `main` entry point when linking `OrbDesktop/Main.lean` as the executable root. -/
def main (args : List String) : IO UInt32 :=
  OrbDesktop.main args
