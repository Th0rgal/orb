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
import OrbDesktop.RepaintCheck
import OrbDesktop.State
import OrbDesktop.Core
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
  verifyRepaint : Bool := false
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
    | "--verify-repaint" :: rest => loop rest { cfg with verifyRepaint := true }
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
    -- Cache short labels, not the growing stream. UVs remain valid through
    -- append-only shelf allocation; resetAll discards all resolved runs.
    let cacheable := text.utf8ByteSize ≤ 128
    if cacheable then
      if let some hit := ac.resolved.find? (fun e => e.face == font.facePtr && e.scale == scale120 && e.text == text && e.style == style) then
        return (ac, [hit.run])
    let (ac', shaped) ← Text.shapeTextCached ac font devSize64 text ""
    let mut curAc := ac'
    let mut glyphs : Array ShapedGlyph := #[]
    let scDen : Int := scaleDen
    let scNum : Int := if scale120 == 0 then 120 else scale120
    let mut penDev64 : Int := 0
    for sg in shaped do
      let glyphDev64 := penDev64 + sg.xOffset64
      let fraction := glyphDev64 % 64
      let subpx := (fraction.toNat / 16).toUInt32
      let (ac', entry) ← Text.getOrRasterizeGlyph curAc font sg.glyphId devSize64 subpx
      curAc := ac'
      let advSubNat : SubPx := ((max 0 sg.xAdvance64 * scDen) / scNum).toNat
      -- The glyph bitmap already contains its fractional horizontal phase.
      -- Position its origin on the corresponding whole device pixel.
      let xOffSub : Int := ((sg.xOffset64 - fraction) * scDen) / scNum
      let yOffSub : Int := (sg.yOffset64 * scDen) / scNum
      let g : ShapedGlyph := {
        glyphId := sg.glyphId.toNat
        cluster := sg.cluster.toNat
        xAdvance := advSubNat
        yAdvance := 0
        xOffset := xOffSub
        yOffset := yOffSub
        atlasSrc := entry.uv
        sizePx := (entry.uv.w.toNat, entry.uv.h.toNat)
        bearingPx := (entry.bearingX, entry.bearingY)
        isColor := entry.isColor
      }
      glyphs := glyphs.push g
      penDev64 := penDev64 + sg.xAdvance64
    let run : InlineRun := {
      glyphs := glyphs.toList
      style := style
      allowBreakAfter := true
      hardBreakAfter := false
    }
    if cacheable then
      let entries := curAc.resolved.push ⟨font.facePtr, scale120, text, style, run⟩
      curAc := { curAc with resolved := if entries.size > 128 then entries.extract 1 entries.size else entries }
    return (curAc, [run])
  else
    return (ac, [overlaySynthRun style text])

/-- Shape words independently so the layout engine can break between them. Keep
spaces and explicit empty lines; split oversized tokens only between clusters. -/
def shapeStreamRuns (atlas : Text.GlyphAtlasCache) (font : Text.FontHandle) (scale : Nat)
    (style : TextStyle) (text : String) (width : Nat) : IO (Text.GlyphAtlasCache × List InlineRun) := do
  let mut ac := atlas
  let mut runs : Array InlineRun := #[]
  let lines := (text.splitOn "\n").toArray
  for i in [:lines.size] do
    let start := runs.size
    let words := (lines[i]!.splitOn " ").toArray
    for j in [:words.size] do
      let token := words[j]! ++ (if j+1 < words.size then " " else "")
      let (next, shaped) ← shapeDesktopRuns ac font scale style token
      ac := next
      for run in shaped do
        if width == 0 || run.advance ≤ width then runs := runs.push run
        else
          let mut part := #[]
          let mut advance := 0
          let mut cluster := none
          for g in run.glyphs do
            if !part.isEmpty && cluster != some g.cluster && advance + g.xAdvance > width then
              runs := runs.push { run with glyphs := part.toList }
              part := #[]
              advance := 0
            part := part.push g
            advance := advance + g.xAdvance
            cluster := some g.cluster
          if !part.isEmpty then runs := runs.push { run with glyphs := part.toList }
    if i+1 < lines.size then
      if runs.size == start then runs := runs.push { style, glyphs := [], hardBreakAfter := true }
      else runs := runs.modify (runs.size-1) fun r => { r with hardBreakAfter := true }
  return (ac, runs.toList)

/-- Recursively shape any synthetic `.text` runs in `WidgetNode` into real HarfBuzz/FreeType
glyph runs so every label, badge, table cell, composer text, modal, and toast renders with `Inter`. -/
partial def shapeWidgetTree (ac : Text.GlyphAtlasCache) (font mono bold medium semibold : Text.FontHandle) (scale120 : Nat)
    (node : WidgetNode) : IO (Text.GlyphAtlasCache × WidgetNode) := do
  match node with
  | .mk wid focusable hitTestable style payload children =>
    let mut curAc := ac
    let newPayload ←
      match payload with
      | .vectorIcon paths color =>
        let size := scaleSubPx scale120 style.minWidth
        let key : GlyphKey := { font := 0xFFFF, glyph := hash paths |>.toNat, sizeSub := size, subpx := 0 }
        let (ac', entry) :=
          match curAc.cache.lookup Text.hashGlyphKey key with
          | some entry => ({ curAc with hits := curAc.hits + 1 }, entry)
          | none => curAc.insertRasterized key (Text.rasterizeIcon paths size)
        curAc := ac'
        pure (WidgetPayload.iconMask entry.page entry.uv color)
      | .text lineHeightSub runs =>
        let mut shapedRuns : Array InlineRun := #[]
        for r in runs do
          let isSynth := !r.glyphs.isEmpty && r.glyphs.all (fun g => g.sizePx.1 == 0 && g.sizePx.2 == 0)
          if isSynth then
            let txt := String.ofList (r.glyphs.map (fun g => Char.ofNat g.glyphId))
            let (ac', rs) ← shapeDesktopRuns curAc (if r.style.monospace then mono else if r.style.weight >= 700 then bold else if r.style.weight >= 600 then semibold else if r.style.weight >= 500 then medium else font) scale120 r.style txt
            curAc := ac'
            let rsAdjusted := rs.map (fun sr =>
              { sr with allowBreakAfter := r.allowBreakAfter, hardBreakAfter := r.hardBreakAfter })
            for sr in rsAdjusted do
              shapedRuns := shapedRuns.push sr
          else
            shapedRuns := shapedRuns.push r
        -- A fixed-width clipped label is a CSS single-line ellipsis label.
        if style.clip && style.maxWidth > 0 then
          let total := shapedRuns.foldl (fun n r => n + r.glyphs.foldl (fun n g => n + g.xAdvance) 0) 0
          if total > style.maxWidth && !shapedRuns.isEmpty then
            let r := shapedRuns[0]!
            let (ac', dots) ← shapeDesktopRuns curAc font scale120 r.style "…"
            curAc := ac'
            let dotW := dots.foldl (fun n r => n + r.glyphs.foldl (fun n g => n + g.xAdvance) 0) 0
            let mut used := 0
            let mut glyphs : Array ShapedGlyph := #[]
            for g in r.glyphs do
              if used + g.xAdvance + dotW > style.maxWidth then break
              used := used + g.xAdvance
              glyphs := glyphs.push g
            shapedRuns := #[( { r with glyphs := glyphs.toList, allowBreakAfter := false } )]
            for dot in dots do
              shapedRuns := shapedRuns.push dot
        pure (WidgetPayload.text lineHeightSub shapedRuns.toList)
      | other => pure other
    let mut shapedChildren : Array WidgetNode := #[]
    for c in children do
      let (ac', c') ← shapeWidgetTree curAc font mono bold medium semibold scale120 c
      curAc := ac'
      shapedChildren := shapedChildren.push c'
    return (curAc, .mk wid focusable hitTestable style newPayload shapedChildren.toList)

private partial def scrollRegionsOf (b : ComputedBox) : List Runtime.ScrollRegion :=
  match b.id, b.scrollLimitXY with
  | some id, some (_, lim) => [⟨id, b.contentRectSub, lim⟩]
  | _, _ => b.children.flatMap scrollRegionsOf

/-- Render one frame of `DesktopState` via `OrbDesktop.buildDesktopScreen`, `Layout.layoutNode`,
`Scene.buildSceneFromLayout`, and HarfBuzz/FreeType glyph shaping (`shapeDesktopRuns` + `Text.layoutTextRun`). -/
def renderDesktopView (rt : Runtime.RuntimeState DesktopState) :
    IO (Runtime.FrameView × List Runtime.ScrollRegion) := do
  let st := rt.app
  let liveWindow := !rt.wayland.headless
  let theme := if liveWindow then Theme.withWindowEffects st.theme else st.theme
  let pal := theme.palette
  let sc := rt.wayland.scale120
  let (availW, availH) := rt.wayland.logicalSubSize
  let profile := (← IO.getEnv "ORB_U7_PROFILE") == some "1"
  let t0 ← IO.monoNanosNow

  let (ac1, hdrRuns) ←
    shapeDesktopRuns rt.atlas.beginUploads rt.primaryFont sc (chromeTitleStyle theme)
      st.headerTitle
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
  let streamText := if st.stream.renders > 1 then streamedText st else ""
  let (ac5, streamRuns) ←
    shapeStreamRuns ac4 rt.primaryFont sc
      { (Theme.bodyText theme) with color := pal.textPrimary }
      streamText (transcriptTextWidth (availW - chromeSidebarWidthSub))

  let shapedRuns : ShapedScreenRuns := {
    headerTitleRuns := hdrRuns
    codeSampleRuns := codeRuns
    streamRuns := streamRuns
    diffDelRuns := delRuns
    diffAddRuns := addRuns
  }

  let widgetRootRaw := buildDesktopScreen st availW availH shapedRuns liveWindow
  let (ac6, widgetRoot) ← shapeWidgetTree ac5 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc widgetRootRaw
  let layoutRoot := widgetRoot.toLayoutNode
  let t1 ← IO.monoNanosNow
  let rootBox := layoutNode sc rt.focus.owner pal.focusRing 0 0 availW availH layoutRoot
  let t2 ← IO.monoNanosNow
  -- This backend diffs paint commands; it does not consume per-node fingerprints.
  let sceneOut := buildSceneFromLayout sc rt.focus theme widgetRoot rootBox (recordNodes := false)
  if profile then IO.eprintln s!"u7-view-ns {t1-t0} {t2-t1} {(← IO.monoNanosNow)-t2}"
  if st.screen == .searchDialog then
    let overRaw := buildSearchModalOverlay theme availW availH
    let (ac7, overWidget) ← shapeWidgetTree ac6 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc overRaw
    let overBox := layoutNode sc none pal.focusRing 0 0 availW availH overWidget.toLayoutNode
    let overScene := buildSceneFromLayout sc rt.focus theme overWidget overBox (recordNodes := false)
    let clearColor := if liveWindow then 0x00000000 else pal.canvas
    return ((ac7.finishUploads, clearColor, sceneOut.prims ++ #[.backdropBlur (scaleSubPx sc (pxToSub 6))] ++ overScene.prims, sceneOut.hitRegionsSub ++ overScene.hitRegionsSub, sceneOut.focusableOrder ++ overScene.focusableOrder), [])
  else
    let clearColor := if liveWindow then 0x00000000 else pal.canvas
    return ((ac6.finishUploads, clearColor, sceneOut.prims, sceneOut.hitRegionsSub, sceneOut.focusableOrder),
      if st.liveData then scrollRegionsOf rootBox else [])

def renderDesktopFrame (rt : Runtime.RuntimeState DesktopState) : IO Runtime.FrameView :=
  Prod.fst <$> renderDesktopView rt

/-- `stepDesktopEvent` for the window `rt` currently has. -/
def desktopReducer (rt : Runtime.RuntimeState DesktopState) :
    DesktopState → Event → DesktopState × Damage :=
  let regions := rt.scrollRegions
  let scale := rt.wayland.scale120
  let viewport := rt.viewportDeviceRect
  fun st ev => Id.run do
    if let .scroll x y _ dy := ev then
      if st.liveData then
        let some r := regions.find? (fun r => r.bounds.contains x y) | return (st, none)
        let h := r.bounds.h.toNat
        let content := r.limitY + h
        let damage := some (roundRectOut scale r.bounds)
        if r.id == rosterViewportId then
          let top := scrollStep content h (min r.limitY st.rosterTopSub) dy
          if top == st.rosterTopSub then return (st, none)
          return ({ st with rosterTopSub := top }, damage)
        if r.id == transcriptViewportId && st.screen == .missionTranscript then
          let current := st.scroll.onLayout content h
          let next := current.onUserScroll content h dy
          if next == current then return (st, none)
          return ({ st with scroll := next }, damage)
    return stepDesktopEvent scale viewport st ev

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

/-- Execute `--bench <iterations>`. The cold pass records startup, then a transcript is opened from
an already-running control screen. Each measured update queues several stream deltas and flushes
once into the transcript damage band, exercising changed-node rasterisation and the
`Orb.Stream.Coalescer` frame boundary. `first_frame_crc32` ties the run to the transcript golden. -/
def runDesktopBench (cfg : Runtime.RuntimeConfig) (iterations : Nat) (verifyRepaint := false) : IO UInt32 := do
  if verifyRepaint then
    verifyRepaintEdges
    verifyDesktopEdges renderDesktopFrame shapeDesktopRuns
  let iters := max 1 iterations
  let tStartNs ← IO.monoNanosNow
  let firstSt := DesktopState.forScreen .missionTranscript cfg.darkTheme cfg.scale120
  let rt0Raw ← Runtime.initRuntime { cfg with headless := true } firstSt
  let tInit ← IO.monoNanosNow
  let rt0 := { rt0Raw with focus := firstSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  let coldUs : Nat := ((← IO.monoNanosNow) - tStartNs) / 1000
  let profile := (← IO.getEnv "ORB_U7_PROFILE") == some "1"
  if profile then IO.eprintln s!"u7-startup-ns init={tInit-tStartNs} firstFrame={(← IO.monoNanosNow)-tInit}"
  let firstCrc := Vulkan.crc32 rt.vulkan.framebuffer
  let fullScenePrims := rt.vulkan.lastDrawnPrims

  let openSt := DesktopState.forScreen .controlEmpty cfg.darkTheme cfg.scale120
  let openRt0Raw ← Runtime.initRuntime { cfg with headless := true } openSt
  let openRt0 := { openRt0Raw with focus := openSt.initialFocusState }
  let mut openRt ← Runtime.stepFrame openRt0 (desktopReducer openRt0) renderDesktopFrame
  let openStartNs ← IO.monoNanosNow
  openRt := { openRt.markFullDamage with app := firstSt, focus := firstSt.initialFocusState }
  openRt ← Runtime.stepFrame openRt (desktopReducer openRt) renderDesktopFrame
  let transcriptOpenUs : Nat := ((← IO.monoNanosNow) - openStartNs) / 1000
  Runtime.shutdownRuntime openRt

  let mut frameTimesUs : Array Nat := #[]
  let mut partialDrawnPrims : Nat := 0
  let mut allUpdatesCulled : Bool := true
  for idx in [0:iters] do
    let (nextSt, streamDamage) :=
      applyStreamFrame cfg.scale120 rt.viewportDeviceRect rt.app
        [s!" streamed fragment {idx}", " with stable transcript identity"]
    let nextDamage := match streamDamage with
      | none => rt.damage
      | some d => Damage.add rt.damage d
    rt := { rt with app := nextSt, damage := nextDamage }
    let f0 ← IO.monoNanosNow
    let reference ← if verifyRepaint then do
      let ref ← Runtime.stepFrame rt.markFullDamage (desktopReducer rt) renderDesktopFrame
      pure (some (ref.vulkan.framebuffer, ref.vulkan.lastDrawnPrims))
      else pure none
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
    if let some (fb, fullPrims) := reference then
      if fb != rt.vulkan.framebuffer then throw <| IO.userError s!"stream frame {idx} differs from full repaint"
      if rt.vulkan.lastDrawnPrims >= fullPrims then throw <| IO.userError s!"stream frame {idx} did not cull unchanged primitives"
    let f1 ← IO.monoNanosNow
    if profile then IO.eprintln s!"u7-update {idx} ns={f1-f0} pixels={rt.vulkan.lastDamagePixels} primitives={rt.vulkan.lastDrawnPrims}"
    frameTimesUs := frameTimesUs.push ((f1 - f0) / 1000)
    partialDrawnPrims := rt.vulkan.lastDrawnPrims
    allUpdatesCulled := allUpdatesCulled && rt.vulkan.lastDrawnPrims > 0 && rt.vulkan.lastDamagePixels < rt.vulkan.width * rt.vulkan.height
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  let (bw, bh) := (rt.vulkan.width, rt.vulkan.height)
  let fbBytes := rt.vulkan.framebuffer.size
  let partialFrames := rt.vulkan.partialFrames
  Runtime.shutdownRuntime rt
  let sorted := frameTimesUs.qsort (· < ·)
  let p50Us := sorted[sorted.size / 2]?.getD 0
  let p99Us := sorted[min ((sorted.size * 99) / 100) (sorted.size - 1)]?.getD 0
  let errors : Nat :=
    if rt.framesRendered == iters + 1 && rt.quiescentSkips == iters && partialFrames == iters &&
        fbBytes == bw * bh * 4 && allUpdatesCulled then 0 else 1
  IO.println s!"\{\"cold_ms\": {fmtMs coldUs}, \"startup_ms\": {fmtMs coldUs}, \"transcript_open_ms\": {fmtMs transcriptOpenUs}, \"frame_p50_ms\": {fmtMs p50Us}, \"frame_p99_ms\": {fmtMs p99Us}, \"frames_rendered\": {rt.framesRendered}, \"quiescent_skips\": {rt.quiescentSkips}, \"partial_frames\": {partialFrames}, \"full_scene_prims\": {fullScenePrims}, \"partial_drawn_prims\": {partialDrawnPrims}, \"work_units\": {iters}, \"error_count\": {errors}, \"width\": {bw}, \"height\": {bh}, \"scale120\": {cfg.scale120}, \"first_frame_crc32\": {firstCrc.toNat}}"
  return (if errors == 0 then 0 else 1)

/-- Exercise wheel routing and click selection against the hit map of the painted layout. -/
def liveViewportRegression : Bool := Id.run do
  let cards := (List.range 32).map fun i => { (default : MissionSummaryCard) with
    widgetId := 1001 + i, missionId := s!"m{i}", title := s!"Mission {i}" }
  let rows := cards.map fun c => { (default : ChromeSidebarRow) with
    widgetId := c.widgetId, rowId := c.missionId, kind := "mission", title := c.title }
  let initial := { DesktopState.liveUnavailable with sidebarRows := rows, missionCards := cards }
  let w := pxToSub 800
  let h := pxToSub 320
  -- Give the last line a distinct atlas rectangle so we check its paint position.
  let marker : Rect := ⟨777, 1, 1, 1⟩
  let lines : List InlineRun := (List.range 48).map fun i =>
    { style := Theme.bodyText initial.theme, hardBreakAfter := i != 47,
      glyphs := [{ glyphId := 1, xAdvance := pxToSub 8, sizePx := (1, 1), atlasSrc := if i == 47 then marker else ⟨0, 0, 1, 1⟩ }] }
  let frame (st : DesktopState) := Id.run do
    let widget := buildDesktopScreen st w h { streamRuns := lines }
    let box := layoutNode 120 none 0 0 0 w h widget.toLayoutNode
    let scene := buildSceneFromLayout 120 {} st.theme widget box (recordNodes := false)
    let rt : Runtime.RuntimeState DesktopState :=
      { app := st, scrollRegions := scrollRegionsOf box, hitRegions := scene.hitRegionsSub }
    return (rt, scene.prims)
  let wheel (rt : Runtime.RuntimeState DesktopState) (id : Nat) (dy : Int) : Option DesktopState := do
    let r ← rt.scrollRegions.find? (fun (r : Runtime.ScrollRegion) => r.id == id)
    return (rt.stepEvent (desktopReducer rt) (.scroll (r.bounds.x+1) (r.bounds.y+1) 0 dy)).app
  let last := cards.getLast!
  let (start, _) := frame initial
  if start.hitRegions.any (·.1 == last.widgetId) then return false
  let some down := wheel start rosterViewportId 999999 | return false
  let (scrolled, _) := frame down
  let some (_, row) := scrolled.hitRegions.find? (fun (p : EntityId × Rect) => p.1 == last.widgetId) | return false
  let click := fun pressed => Event.pointerButton (row.x + row.w/2) (row.y + row.h/2) 1 pressed
  let press := scrolled.stepEvent (desktopReducer scrolled) (click true)
  let selected := (press.stepEvent (desktopReducer press) (click false)).app
  if selected.openMission != some last.missionId then return false
  let some top := wheel (frame selected).1 transcriptViewportId (-999999) | return false
  let (atTop, before) := frame top
  let some bottom := wheel atTop transcriptViewportId 999999 | return false
  let (atBottom, after) := frame bottom
  let some pane := atBottom.scrollRegions.find? (fun (r : Runtime.ScrollRegion) => r.id == transcriptViewportId) | return false
  let visible (p : Prim) := match p with
    | .glyph src dst .. => src == marker && (roundRectOut 120 pane.bounds).contains dst.x dst.y
    | _ => false
  return !before.any visible && after.any visible && bottom.rosterTopSub == down.rosterTopSub &&
    !atBottom.hitRegions.any (·.1 == 2)

/-- `--self-test`: check live viewports and quiescent rendering. -/
def runSelfTest (cfg : Runtime.RuntimeConfig) (initSt : DesktopState) : IO UInt32 := do
  unless liveViewportRegression do
    IO.eprintln "orb-desktop self-test: live viewport regression"
    return 1
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
    return (← runDesktopBench rcfg iters dcfg.verifyRepaint)
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
  let initSt ← if dcfg.screenOpt.isNone && !dcfg.selfTest then
    (loadLiveState).map (·.getD (DesktopState.liveUnavailable rcfg.darkTheme rcfg.scale120))
  else pure (DesktopState.forScreen scr rcfg.darkTheme rcfg.scale120)
  if dcfg.selfTest then
    return (← runSelfTest rcfg initSt)
  try
    let rt0 ← Runtime.openWindowRuntime rcfg "orb-desktop" initSt
    let slot ← IO.mkRef (none : Option LiveSubscription)
    let rt ← try
      Runtime.runWindow { rt0 with focus := initSt.initialFocusState } desktopReducer renderDesktopView
        (fun rt => readLiveFrame slot rt.wayland.scale120 rt.viewportDeviceRect rt.app) DesktopState.hasLiveConnection
    finally closeLiveSubscription slot
    Runtime.shutdownRuntime rt
    return 0
  catch e =>
    IO.eprintln s!"orb-desktop-native: cannot run the window: {e}"
    return 1

end OrbDesktop

/-- Top-level C `main` entry point when linking `OrbDesktop/Main.lean` as the executable root. -/
def main (args : List String) : IO UInt32 :=
  OrbDesktop.main args
