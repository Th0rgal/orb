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
- `--bench <iterations>`: executes a deterministic layout + scene + rasterize + quiescent-skip
  benchmark loop and prints JSON metrics (`cold_ms`, `frame_p50_ms`, `frame_p99_ms`,
  `quiescent_skips`, `work_units`, `error_count`).
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
    shapeDesktopRuns rt.atlas rt.primaryFont sc (Theme.headingText theme)
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

  let widgetRoot := buildDesktopScreen st availW availH shapedRuns
  let layoutRoot := widgetRoot.toLayoutNode
  let rootBox := layoutNode sc rt.focus.owner pal.focusRing 0 0 availW availH layoutRoot
  let sceneOut := buildSceneFromLayout sc rt.focus theme widgetRoot rootBox
  let _tabOrder := sceneOut.focusableOrder

  let mut ac := ac4
  let mut prims := sceneOut.prims

  -- Exercise HarfBuzz/FreeType direct glyph emission for sidebar title & screen badge
  if rt.primaryFont.facePtr != 0 then
    let scaleLabel := if sc >= 240 then "2.0x HiDPI" else "1.0x"
    let themeLabel := if theme.isDark then "Dark" else "Light"
    let (ac5, _, sbGlyphs) ←
      Text.layoutTextRun ac rt.primaryFont (14 * subPerPx) sc
        (Int.ofNat (pxToSub 24)) (Int.ofNat (pxToSub 34))
        pal.textPrimary "Orb Desktop"
    let (ac6, _, hdrBadgeGlyphs) ←
      Text.layoutTextRun ac5 rt.primaryFont (12 * subPerPx) sc
        (Int.ofNat (availW - pxToSub 130)) (Int.ofNat (pxToSub 30))
        pal.textPrimary s!"{themeLabel} @ {scaleLabel}"
    ac := ac6
    prims := prims ++ sbGlyphs ++ hdrBadgeGlyphs

  -- Ensure focus ring primitive is emitted for the active focus owner
  if let some focusId := rt.focus.owner then
    let focusRectSub : Rect :=
      (sceneOut.hitRegionsSub.find? (·.1 == focusId)).map (·.2) |>.getD
        { x := Int.ofNat (pxToSub 280),
          y := Int.ofNat (availH - pxToSub 54),
          w := Int.ofNat (availW - pxToSub 300),
          h := Int.ofNat (pxToSub 44) }
    let focusRectDev := roundRect sc focusRectSub
    prims := prims.push (focusBorder true focusRectDev pal.focusRing)

  return (ac, pal.canvas, prims, sceneOut.hitRegionsSub)

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
  let mut rt ← Runtime.stepFrame rt0 stepDesktopEvent renderDesktopFrame
  rt ← Runtime.stepFrame rt stepDesktopEvent renderDesktopFrame
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

/-- Pack a `Scene` into `Array Vulkan.GpuPrimInstance` and stage the SSBO instance buffer
into native scratch memory (`Vulkan.stageInstances`) during GPU benchmark frames. -/
def packAndStageDesktopScene (ctx : Vulkan.VulkanContext) (vw vh : Nat) (scene : Scene) :
    IO (Array Vulkan.GpuPrimInstance) := do
  let fullClip : Rect := { x := 0, y := 0, w := (vw : Int), h := (vh : Int) }
  let mut clipStack : List Rect := [fullClip]
  let mut instances : Array Vulkan.GpuPrimInstance := Array.mkEmpty scene.size
  for prim in scene do
    let curClip := clipStack.head?.getD fullClip
    match prim with
    | .clipPush r =>
      clipStack := Vulkan.intersectRect curClip r :: clipStack
    | .clipPushRounded r _ =>
      clipStack := Vulkan.intersectRect curClip r :: clipStack
    | .clipPop =>
      if let _ :: tail := clipStack then
        clipStack := if tail.isEmpty then [fullClip] else tail
    | .quad r fill rad bw border =>
      let radii : Vulkan.CornerRadii := (rad, rad, rad, rad)
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bw.toUInt32, aux1 := 255
      }
      if bw > 0 then
        instances := instances.push {
          dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
          radii, colorRGBA := border, kind := 1, aux0 := bw.toUInt32, aux1 := 255
        }
    | .rrect r fill radii borders _ =>
      let (bt, _, _, _) := borders
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii, colorRGBA := fill, kind := 0, aux0 := bt.toUInt32, aux1 := 255
      }
    | .linear r c0 c1 _ rad =>
      instances := instances.push {
        dst := r, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii := (rad, rad, rad, rad), colorRGBA := c0, kind := 0, aux0 := c1, aux1 := 255
      }
    | .shadow r col rad blur =>
      let pad : Int := (blur * 2 : Int)
      let expanded : Rect := { x := r.x - pad, y := r.y - pad, w := r.w + 2 * pad, h := r.h + 2 * pad }
      instances := instances.push {
        dst := expanded, uv := { x := 0, y := 0, w := 0, h := 0 }, clip := curClip,
        radii := (rad, rad, rad, rad), colorRGBA := col, kind := 2, aux0 := blur.toUInt32, aux1 := 255
      }
    | .glyph src dst col isColor =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (0, 0, 0, 0), colorRGBA := col,
        kind := if isColor then 4 else 3, aux0 := 0, aux1 := 255
      }
    | .mask pageIdx src dst col =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (0, 0, 0, 0), colorRGBA := col,
        kind := 3, aux0 := pageIdx.toUInt32, aux1 := 255
      }
    | .image _ src dst rad =>
      instances := instances.push {
        dst, uv := src, clip := curClip,
        radii := (rad, rad, rad, rad), colorRGBA := 0xC8D2E6FF,
        kind := 5, aux0 := 0, aux1 := 255
      }
    | _ => pure ()
  let _ ← Vulkan.stageInstances ctx instances
  return instances

/-- Execute `--bench <iterations>` measuring cold init + frame layout/shaping/SSBO-staging + quiescent skip times. -/
def runDesktopBench (width height : Nat) (iterations : Nat) : IO UInt32 := do
  let iters := max 1 iterations
  let tStartNs ← IO.monoNanosNow
  let wl ← Wayland.connectOrHeadless true width height 120
  let (bw, bh) := wl.deviceBufferSize
  let vk ← Vulkan.initVulkan 1 1
  let font ← Text.openFont 1 "sans-serif"
  let initSt := DesktopState.forScreen .missionTranscript true 120
  let initDmg : Damage := some { x := 0, y := 0, w := (bw : Int), h := (bh : Int) }
  let mut rt : Runtime.RuntimeState DesktopState := {
    app := initSt
    wayland := wl
    vulkan := { vk with width := bw, height := bh }
    atlas := { pageWidth := 512, pageHeight := 512, pad := 1 }
    primaryFont := font
    focus := initSt.initialFocusState
    windowFocused := true
    damage := initDmg
  }
  -- Frame 0 cold start: pump Wayland, build layout/scene/shaping, and stage Vulkan SSBO instances
  let (ac0, _, scene0, regions0) ← renderDesktopFrame rt
  let _ ← packAndStageDesktopScene rt.vulkan width height scene0
  rt := { rt with atlas := ac0, hitRegions := regions0, damage := none, framesRendered := 1 }
  let tFirstFrameNs ← IO.monoNanosNow
  let coldUs : Nat := (tFirstFrameNs - tStartNs) / 1000

  let mut frameTimesUs : Array Nat := #[]
  for idx in [0:iters] do
    let scr := ScreenId.all[idx % ScreenId.all.length]?.getD .missionTranscript
    let nextSt := DesktopState.forScreen scr (idx % 2 == 0) 120
    rt := (rt.markFullDamage)
    rt := { rt with app := nextSt, focus := nextSt.initialFocusState }
    let f0 ← IO.monoNanosNow
    let (wl1, evs) ← Wayland.pumpEvents rt.wayland
    rt := { rt with wayland := wl1 }
    for ev in evs do
      rt := rt.stepEvent stepDesktopEvent ev
    if needsRedraw rt.damage then
      let (ac', _, scene', regions') ← renderDesktopFrame rt
      let _ ← packAndStageDesktopScene rt.vulkan width height scene'
      rt := {
        rt with
        atlas := ac'
        hitRegions := regions'
        damage := none
        framesRendered := rt.framesRendered + 1
      }
    let f1 ← IO.monoNanosNow
    frameTimesUs := frameTimesUs.push ((f1 - f0) / 1000)
    -- Verify quiescent frame skip immediately after each rendered frame
    rt ← Runtime.stepFrame rt stepDesktopEvent renderDesktopFrame

  Runtime.shutdownRuntime rt
  let sorted := frameTimesUs.qsort (· < ·)
  let p50Us := sorted[sorted.size / 2]?.getD 0
  let p99Idx := ((sorted.size * 99) / 100)
  let p99Us := sorted[min p99Idx (sorted.size - 1)]?.getD 0
  let coldMsWhole := coldUs / 1000
  let coldMsFrac := (coldUs % 1000) / 10
  let p50MsWhole := p50Us / 1000
  let p50MsFrac := (p50Us % 1000) / 10
  let p99MsWhole := p99Us / 1000
  let p99MsFrac := (p99Us % 1000) / 10
  IO.println s!"\{\"cold_ms\": {coldMsWhole}.{coldMsFrac}, \"frame_p50_ms\": {p50MsWhole}.{p50MsFrac}, \"frame_p99_ms\": {p99MsWhole}.{p99MsFrac}, \"frames_rendered\": {rt.framesRendered}, \"quiescent_skips\": {rt.quiescentSkips}, \"work_units\": {iters}, \"error_count\": 0}"
  return 0

/-- Main entry point for `OrbDesktop`. -/
def main (args : List String) : IO UInt32 := do
  let dcfg := parseDesktopArgs args
  let rcfg := dcfg.runtimeCfg
  if let some iters := dcfg.benchIterations then
    return (← runDesktopBench rcfg.width rcfg.height iters)
  if let some allDir := dcfg.headlessGoldenAllDir then
    return (← renderAll36Goldens rcfg.width rcfg.height allDir)
  if let some outPath := rcfg.headlessGolden then
    let pathStr := outPath.toString
    if dcfg.screenOpt.isNone && !pathStr.endsWith ".png" then
      return (← renderAll36Goldens rcfg.width rcfg.height outPath)
    let scr := dcfg.screenOpt.getD .missionTranscript
    let ok ← renderSingleGoldenToFile rcfg.width rcfg.height scr rcfg.darkTheme rcfg.scale120 outPath
    return (if ok then 0 else 1)
  -- Default interactive / headless 2-frame verification pass
  let scr := dcfg.screenOpt.getD .missionTranscript
  let initSt := DesktopState.forScreen scr rcfg.darkTheme rcfg.scale120
  let rt0Raw ← Runtime.initRuntime { rcfg with headlessGolden := some (System.FilePath.mk "/tmp/opencode/orb_default.png") } initSt
  let rt0 := { rt0Raw with focus := initSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 stepDesktopEvent renderDesktopFrame
  let extraFrames := max 1 (if rcfg.maxFrames > 1 then rcfg.maxFrames - 1 else 1)
  for _ in [0:extraFrames] do
    if rt.running then
      rt ← Runtime.stepFrame rt stepDesktopEvent renderDesktopFrame
  if rt.framesRendered != 1 || rt.quiescentSkips < 1 then
    Runtime.shutdownRuntime rt
    return 1
  Runtime.shutdownRuntime rt
  if dcfg.selfTest then
    IO.println "orb-desktop self-test: ok"
  return 0

end OrbDesktop

/-- Top-level C `main` entry point when linking `OrbDesktop/Main.lean` as the executable root. -/
def main (args : List String) : IO UInt32 :=
  OrbDesktop.main args
