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
import OrbDesktop.Voice
import OrbDesktop.Core
import OrbDesktop.EmbeddedSidebar
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
  headlessGoldenAllPrims : Option System.FilePath := none
  gpuReadbackAllPrims : Option System.FilePath := none
  screenOpt : Option ScreenId := none
  benchIterations : Option Nat := none
  benchWsiIterations : Option Nat := none
  verifyRepaint : Bool := false
  selfTest : Bool := false
  deriving Repr, Inhabited

/-- Parse `OrbDesktop` CLI arguments, delegating shared runtime flags to `Runtime.parseRuntimeArgs`. -/
def parseDesktopArgs (args : List String) : DesktopCliConfig :=
  let baseRuntime := Runtime.parseRuntimeArgs args
  let rec loop (rem : List String) (cfg : DesktopCliConfig) : DesktopCliConfig :=
    match rem with
    | [] => cfg
    | "--self-test" :: rest =>
      loop rest { cfg with selfTest := true }
    | "--headless-golden-all" :: dir :: rest =>
      loop rest { cfg with headlessGoldenAllDir := some dir }
    | "--headless-golden-all-prims" :: path :: rest =>
      loop rest { cfg with headlessGoldenAllPrims := some path }
    | "--gpu-readback-all-prims" :: path :: rest =>
      loop rest { cfg with gpuReadbackAllPrims := some path }
    | "--screen" :: scrStr :: rest =>
      loop rest { cfg with screenOpt := ScreenId.parse? scrStr }
    | "--bench" :: nStr :: rest =>
      loop rest { cfg with benchIterations := some (max 1 (nStr.toNat?.getD 20)) }
    | "--bench-wsi" :: nStr :: rest =>
      loop rest { cfg with benchWsiIterations := some (max 1 (nStr.toNat?.getD 20)) }
    | "--verify-repaint" :: rest => loop rest { cfg with verifyRepaint := true }
    | _ :: rest =>
      loop rest cfg
  loop args { runtimeCfg := baseRuntime }

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
    let cacheable := text.utf8ByteSize ≤ Text.maxShapeCacheBytes
    let cacheKey : Text.ResolvedRunKey := ⟨font.facePtr, scale120, style.sizeSub, text⟩
    if cacheable then
      if let some hit := ac.resolvedMap.get? cacheKey then
        return (ac, [{ hit with style := style }])
    let (ac', shaped) ← Text.shapeWithFallback ac font devSize64 text
    let mut curAc := ac'
    let mut glyphs : Array ShapedGlyph := #[]
    let scDen : Int := scaleDen
    let scNum : Int := if scale120 == 0 then 120 else scale120
    let mut penDev64 : Int := 0
    for (face, sg) in shaped do
      let glyphDev64 := penDev64 + sg.xOffset64
      let fraction := glyphDev64 % 64
      let subpx := (fraction.toNat / 16).toUInt32
      let (ac', entry) ← Text.getOrRasterizeGlyph curAc face sg.glyphId devSize64 subpx
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
        atlasPage := entry.page
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
      let map' := curAc.resolvedMap.insert cacheKey run
      if entries.size > Text.maxResolvedRuns then
        let map'' := match entries[0]? with
          | some evicted =>
            let evKey : Text.ResolvedRunKey := ⟨evicted.face, evicted.scale, evicted.style.sizeSub, evicted.text⟩
            if evKey == cacheKey then map' else map'.erase evKey
          | none => map'
        curAc := { curAc with resolved := entries.extract 1 entries.size, resolvedMap := map'' }
      else
        curAc := { curAc with resolved := entries, resolvedMap := map' }
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
      | .vectorIcon paths color badgeBg strokeTenths =>
        let size := scaleSubPx scale120 (if badgeBg.isSome then pxToSub 10 else style.minWidth)
        -- The stroke radius participates in the atlas key: two icons with the same
        -- paths but different weights must rasterize into distinct entries.
        let key : GlyphKey :=
          { font := 0xFFFF, glyph := mixHash (hash paths) (hash strokeTenths) |>.toNat,
            sizeSub := size, subpx := 0 }
        let (ac', entry) :=
          match curAc.cache.lookup Text.hashGlyphKey key with
          | some entry => ({ curAc with hits := curAc.hits + 1 }, entry)
          | none => curAc.insertRasterized key (Text.rasterizeIcon paths size strokeTenths)
        curAc := ac'
        pure (WidgetPayload.iconMask entry.page entry.uv color badgeBg)
      | .text lineHeightSub runs caret =>
        let mut shapedRuns : Array InlineRun := #[]
        for r in runs do
          let isSynth := !r.glyphs.isEmpty && r.glyphs.all (fun g => g.sizePx.1 == 0 && g.sizePx.2 == 0)
          if isSynth then
            let txt := String.ofList (r.glyphs.map (fun g => Char.ofNat g.glyphId))
            let face := if r.style.monospace then mono else if r.style.weight >= 700 then bold else if r.style.weight >= 600 then semibold else if r.style.weight >= 500 then medium else font
            let (ac', rs) ← shapeDesktopRuns curAc face scale120 r.style txt
            curAc := ac'
            -- HarfBuzz clusters are UTF-8 byte offsets within this shaped run.
            -- Editor navigation and IME both address the draft in Unicode scalars.
            let scalarAtByte := if r.editorStart.isSome && face.facePtr != 0 then
                (txt.toList.mapIdx fun i c => List.replicate c.utf8Size i).flatten.toArray else #[]
            for sr in rs do
              let glyphs := match r.editorStart with
                | none => sr.glyphs
                | some start => sr.glyphs.map fun g =>
                  { g with cluster := start + scalarAtByte[g.cluster]?.getD g.cluster }
              shapedRuns := shapedRuns.push { sr with
                glyphs, editorStart := r.editorStart
                allowBreakAfter := r.allowBreakAfter, hardBreakAfter := r.hardBreakAfter }
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
        pure (WidgetPayload.text lineHeightSub shapedRuns.toList caret)
      | other => pure other
    let mut shapedChildren : Array WidgetNode := #[]
    for c in children do
      let (ac', c') ← shapeWidgetTree curAc font mono bold medium semibold scale120 c
      curAc := ac'
      shapedChildren := shapedChildren.push c'
    return (curAc, .mk wid focusable hitTestable style newPayload shapedChildren.toList)

private partial def scrollRegionsOf (b : ComputedBox) : List Runtime.ScrollRegion :=
  match b.id, b.scrollLimitXY with
  | some id, some (_, limitY) =>
    let lines := (b.children.head?.map (·.lines)).getD []
    [{ id, bounds := b.contentRectSub, limitY, offsetY := (b.scrollOffset.getD (0, 0)).2, textLines := lines }]
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
      streamText (transcriptTextWidth (availW - st.sidebarWidth))

  let shapedRuns : ShapedScreenRuns := {
    headerTitleRuns := hdrRuns
    codeSampleRuns := codeRuns
    streamRuns := streamRuns
    diffDelRuns := delRuns
    diffAddRuns := addRuns
  }

  let widgetRootRaw := buildDesktopScreen st availW availH shapedRuns liveWindow (st.hoverTarget rt.hoveredEntity)
  let (ac6, widgetRoot) ← shapeWidgetTree ac5 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc widgetRootRaw
  let layoutRoot := widgetRoot.toLayoutNode
  let t1 ← IO.monoNanosNow
  let rootBox := layoutNode sc rt.focus.owner pal.focusRing 0 0 availW availH layoutRoot
  let t2 ← IO.monoNanosNow
  -- This backend diffs paint commands; it does not consume per-node fingerprints.
  let sceneOut := buildSceneFromLayout sc rt.focus theme widgetRoot rootBox (recordNodes := false) (focusVisible := rt.focusVisible)
  if profile then IO.eprintln s!"u7-view-ns {t1-t0} {t2-t1} {(← IO.monoNanosNow)-t2}"
  let winClipRect := rt.viewportDeviceRect
  let winRad := scaleSubPx sc (pxToSub 12)
  let winRadii : Nat × Nat × Nat × Nat := (winRad, winRad, winRad, winRad)
  let clipOverlay (prims : Scene) : Scene :=
    if liveWindow then #[.clipPushRounded winClipRect winRadii] ++ prims ++ #[.clipPop] else prims
  if let some menu := st.missionMenu then
    let w := min availW (pxToSub (if menu.page == .picker .model then 440 else 228))
    let count := min (max 1 ((availH - pxToSub 10) / pxToSub 26)) (missionMenuRows st menu).length
    let h := min availH (pxToSub (10 + 26 * count))
    let left := max 0 (min menu.x (availW - w : Nat))
    let top := max 0 (min menu.y (availH - h : Nat))
    let raw := buildMissionMenu st menu w count
    let (ac7, widget) ← shapeWidgetTree ac6 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc raw
    let box := layoutNode sc rt.focus.owner pal.focusRing left top w h widget.toLayoutNode
    let overlay := buildSceneFromLayout sc rt.focus theme widget box (recordNodes := false) (focusVisible := rt.focusVisible)
    let outside : Rect := { x := 0, y := 0, w := availW, h := availH }
    return ((ac7.finishUploads, if liveWindow then 0 else pal.canvas, sceneOut.prims ++ clipOverlay overlay.prims,
      (719, outside) :: overlay.hitRegionsSub, overlay.focusableOrder), [])
  if let .searchPalette spec := st.modal then
    let overRaw := buildSearchModalOverlay theme availW availH spec st.searchFilterTab
      st.searchProjectFilter st.searchTimeFilter st.searchSortOrder (!st.liveData) st.searchBuffer
    let (ac7, overWidget) ← shapeWidgetTree ac6 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc overRaw
    let overBox := layoutNode sc none pal.focusRing 0 0 availW availH overWidget.toLayoutNode
    let overScene := buildSceneFromLayout sc rt.focus theme overWidget overBox (recordNodes := false) (focusVisible := rt.focusVisible)
    let clearColor := if liveWindow then 0x00000000 else pal.canvas
    let outside : Rect := { x := 0, y := 0, w := availW, h := availH }
    let modalPrims :=
      let inner := sceneOut.prims ++ #[.backdropBlur (scaleSubPx sc (pxToSub 6))] ++ overScene.prims
      if liveWindow then
        #[.layerPush 255] ++ inner ++ #[.clipPushRounded winClipRect winRadii, .layerPop, .clipPop]
      else inner
    return ((ac7.finishUploads, clearColor, modalPrims,
      (searchBackdropId, outside) :: overScene.hitRegionsSub, overScene.focusableOrder), [])
  if !st.writeError.isEmpty then
    let w := min availW (pxToSub 440)
    let h := pxToSub 40
    let notice := buildToastWidget theme w { id := 904, kind := .warning, title := st.writeError, dismissButtonId := some 914 }
    let (ac7, widget) ← shapeWidgetTree ac6 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc notice
    let box := layoutNode sc rt.focus.owner pal.focusRing (availW - w - pxToSub 8 : Nat)
      (availH - chromeComposerHeightSub - h - pxToSub 8 : Nat) w h widget.toLayoutNode
    let overlay := buildSceneFromLayout sc rt.focus theme widget box (recordNodes := false) (focusVisible := rt.focusVisible)
    return ((ac7.finishUploads, if liveWindow then 0 else pal.canvas, sceneOut.prims ++ clipOverlay overlay.prims,
      sceneOut.hitRegionsSub ++ overlay.hitRegionsSub, sceneOut.focusableOrder ++ overlay.focusableOrder), scrollRegionsOf rootBox)
  else
    let clearColor := if liveWindow then 0x00000000 else pal.canvas
    return ((ac6.finishUploads, clearColor, sceneOut.prims, sceneOut.hitRegionsSub, sceneOut.focusableOrder),
      scrollRegionsOf rootBox)

def renderDesktopFrame (rt : Runtime.RuntimeState DesktopState) : IO Runtime.FrameView :=
  Prod.fst <$> renderDesktopView rt

/-- `stepDesktopEvent` for the window `rt` currently has. -/
def desktopReducer (rt : Runtime.RuntimeState DesktopState) :
    DesktopState → Event → DesktopState × Damage :=
  let regions := rt.scrollRegions
  let scale := rt.wayland.scale120
  let viewport := rt.viewportDeviceRect
  fun st ev => Id.run do
    if let .key key mods state := ev then
      if state != .released then
        if let .searchPalette spec := st.modal then
          if rt.focus.owner == some spec.inputWidgetId then
            if let some buf := st.searchBuffer.editKey? key mods then
              let spec' := { spec with query := buf.displayText, selectedIdx := 0 }
              return ({ st with searchBuffer := buf, modal := .searchPalette spec' }, if buf == st.searchBuffer then none else some viewport)
        else if !st.liveData && st.screen == .settingsGeneral && rt.focus.owner == some settingsApiUrlId then
          if let some buf := st.settingsApiUrl.editKey? key mods then
            return ({ st with settingsApiUrl := buf }, if buf == st.settingsApiUrl then none else some viewport)
        else if rt.focus.owner == some 1 && (!st.liveData || (st.hasLiveConnection && st.writeRequest.isNone)) then
          if let some menu := st.missionMenu then
            if menu.page == .rename || menu.page == .draftDirectory then
              if let some draft := menu.draft.editKey? key mods then
                return ({ st with missionMenu := some { menu with draft } }, if draft == menu.draft then none else some viewport)
          else if st.cloudCanCreate || st.cloudAllows "send" then
            if let some draft := st.cloudDraft.editKey? key mods then
              return ({ st with cloudDraft := draft, cloudAttempt := if draft.text == st.cloudDraft.text then st.cloudAttempt else "" }, some viewport)
          else if !st.liveData || st.openMission.isSome || st.screen == .controlEmpty || st.screen == .controlPopulated then
            let rows := if key == 0xff52 || key == 0xff54 then
                match regions.find? (·.id == Widgets.composerViewportId) with
                | some r => editorRows r.textLines st.composer.text.length
                | none => []
              else []
            if let some composer := st.composer.editKey? key mods rows then
              return ({ st with composer }, if composer == st.composer then none else some viewport)
    if !st.liveData && st.screen == .settingsGeneral && rt.focus.owner == some settingsApiUrlId then
      match ev with
      | .text text =>
        let buf := st.settingsApiUrl.insertText text
        return ({ st with settingsApiUrl := buf }, if buf == st.settingsApiUrl then none else some viewport)
      | .imeBatch db da text preedit _ _ =>
        let buf := st.settingsApiUrl.applyImeBatch db da text preedit
        return ({ st with settingsApiUrl := buf }, if buf == st.settingsApiUrl then none else some viewport)
      | .preedit text _ _ =>
        let buf := st.settingsApiUrl.setPreedit text
        return ({ st with settingsApiUrl := buf }, if buf == st.settingsApiUrl then none else some viewport)
      | .composerReturn _ =>
        return (st, none)
      | _ => pure ()
    if let .pointerMove x y := ev then
      return (st, st.sidebarHoverDamage rt.hitRegions scale rt.hoveredEntity (hitTest rt.hitRegions x y))
    if let .pointerLeave := ev then
      return (st, st.sidebarHoverDamage rt.hitRegions scale rt.hoveredEntity none)
    if let .activate id := ev then
      if st.hasLiveConnection && st.missionMenu.isNone && st.writeRequest.isNone then
        if id == draftDirectoryPickerId && st.openMission.isNone then
          let some (_, r) := rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id) | return (st, none)
          let draft : Widgets.ComposerBuffer := { text := st.draftDirectory, cursorOffset := st.draftDirectory.length }
          let menu : MissionMenu := { mission := "", x := r.x, y := r.bottom, trigger := id, page := .draftDirectory, draft, browsePath := st.draftDirectory }
          return ({ st with missionMenu := some menu }, some viewport)
        if id == 714 || (id == draftProjectPickerId && st.openMission.isNone) then
          let some (_, r) := rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id) | return (st, none)
          return ({ st with missionMenu := some { mission := st.openMission.getD "", x := r.x, y := r.bottom, trigger := id, page := if id == draftProjectPickerId then .draftProject else .settings } }, some viewport)
        if let some field := settingTrigger id then
          let some (_, r) := rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id) | return (st, none)
          let st := if field == .machine then { st with launchMachines := none, launchMachinesFailed := false } else st
          return ({ st with missionMenu := some {
            mission := st.openMission.getD "", x := r.x, y := r.bottom, trigger := id,
            page := .picker field } }, some viewport)
    let menuTarget : Option (EntityId × Int × Int) := match ev with
      | .pointerButton x y 0x111 true => (hitTest rt.hitRegions x y).map fun id => (id, x, y)
      | .key key mods .pressed =>
        if key == 0xff67 || (key == 0xffc7 && mods == 1) then do
          let id ← rt.focus.owner
          let (_, bounds) ← rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id)
          pure (id, bounds.x, bounds.bottom)
        else none
      | _ => none
    if let some (id, x, y) := menuTarget then
      if st.hasLiveConnection && st.missionMenu.isNone && st.writeRequest.isNone then
        let some row := st.sidebarRows.find? (·.widgetId == id) | return (st, none)
        let previous := st
        let st := contextSelection st row.rowId
        let group := st.multiRows.length > 1 && st.multiRows.contains row.rowId
        let mixed := group && st.multiRows.any fun r => !r.startsWith "mission:"
        if row.kind != "mission" && !mixed then return (st, if previous.multiRows == st.multiRows then none else some viewport)
        let mid := (row.rowId.drop 8).toString
        let targets := if group then
            st.multiRows.filterMap fun r => if r.startsWith "mission:" then some (r.drop 8).toString else none
          else [mid]
        return ({ st with missionMenu := some { mission := mid, x, y, trigger := id, targets, mixed } }, some viewport)
    if let .scrollTo regionId targetY := ev then
      if st.missionMenu.isNone && st.modal == .none then
        let some r := regions.find? (·.id == regionId) | return (st, none)
        return applyScrollRegionTo scale r.id r.bounds r.limitY r.offsetY targetY st
    if let .scroll x y _ dy := ev then
      if st.missionMenu.isNone && st.modal == .none then
        let some r := regions.find? (fun r => r.bounds.contains x y) | return (st, none)
        let h := r.bounds.h.toNat
        let content := r.limitY + h
        let damage := some (roundRectOut scale r.bounds)
        if r.id == Widgets.composerViewportId then
          let current := st.composer.wheelTop.getD r.offsetY
          let top := scrollStep content h current dy
          if top == current then return (st, none)
          return ({ st with composer := { st.composer with wheelTop := some top } }, damage)
        if r.id == rosterViewportId then
          let top := scrollStep content h (min r.limitY st.rosterTopSub) dy
          if top == st.rosterTopSub then return (st, none)
          return ({ st with rosterTopSub := top }, damage)
        if r.id == fleetViewportId && (st.screen == .machinesFleet || st.screen == .inference) then
          let top := scrollStep content h (min r.limitY st.fleetTopSub) dy
          if top == st.fleetTopSub then return (st, none)
          return ({ st with fleetTopSub := top }, damage)
        if r.id == transcriptViewportId && (st.screen == .missionTranscript || st.screen == .missionSplitDiff) then
          if st.liveData then
            let some st' := stepTranscriptScroll st content h dy | return (st, none)
            return (st', damage)
          else
            let current := if !st.scrolledManually then { pinned := false, topSub := 0 } else st.scroll.onLayout content h
            let next := current.onUserScroll content h dy
            if next == current && st.scrolledManually then return (st, none)
            return ({ st with scroll := next, scrolledManually := true }, damage)
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

/-- Synthetic translucent all-primitives parity fixture (rendered on `clearColor = 0x00000000`)
exercising every GPU/CPU primitive kind `0..7`: solid & translucent `.quad`/`.rrect` with
asymmetric borders, compute `.shadow`, monochrome & premultiplied color `.glyph` across
`pageIdx = 0` and `pageIdx = 1`, `.mask` on `pageIdx = 1`, `.image`, angled `.linear` gradients
(`0°`, `45°`, `90°`, `180°`), nested `clipPushRounded`, nested `layerPush`/`layerPop`, and
`.backdropBlur`. -/
def buildAllPrimitivesFixture : Nat × Nat × Color × Text.GlyphAtlasCache × Scene := Id.run do
  let w := 512
  let h := 384
  -- Build a 2-page atlas: page 0 holds an R8 monochrome glyph (16×16); page 1 holds a
  -- premultiplied color glyph (16×16) and a coverage mask (16×16).
  let mut monoPix := ByteArray.emptyWithCapacity (16 * 16)
  for y in [:16] do
    for x in [:16] do
      let cov : UInt8 := if x >= 2 && x < 14 && y >= 2 && y < 14 && (x == 3 || y == 3 || x == 12 || y == 8) then 255 else if x >= 1 && x < 15 && y >= 1 && y < 15 then 96 else 0
      monoPix := monoPix.push cov
  let rgMono : Text.RasterizedGlyph := {
    width := 16, height := 16, bearingX := 0, bearingY := 14, format := 1, isColor := false, pixels := monoPix
  }
  -- Premultiplied BGRA color glyph (FreeType FT_PIXEL_MODE_BGRA format)
  let mut colorPix := ByteArray.emptyWithCapacity (16 * 16 * 4)
  for y in [:16] do
    for x in [:16] do
      let dx := (x : Int) - 8
      let dy := (y : Int) - 8
      let d2 := dx * dx + dy * dy
      let (b, g, r, a) : UInt8 × UInt8 × UInt8 × UInt8 :=
        if d2 <= 25 then (40, 180, 230, 255)
        else if d2 <= 49 then (20, 90, 115, 128)
        else (0, 0, 0, 0)
      colorPix := colorPix.push b |>.push g |>.push r |>.push a
  let rgColor : Text.RasterizedGlyph := {
    width := 16, height := 16, bearingX := 0, bearingY := 14, format := 4, isColor := true, pixels := colorPix
  }
  let p0 := (Text.AtlasPageBuffer.create 1024 1024).blitGlyph ⟨4, 4, 16, 16⟩ rgMono
  let p1 := ((Text.AtlasPageBuffer.create 1024 1024).blitGlyph ⟨8, 8, 16, 16⟩ rgColor).blitGlyph ⟨32, 8, 16, 16⟩ rgMono
  let atlas : Text.GlyphAtlasCache := {
    pageWidth := 1024, pageHeight := 1024, pad := 1
    pages := #[p0, p1]
    gpuDirtyRects := #[(0, ⟨4, 4, 16, 16⟩), (1, ⟨8, 8, 16, 16⟩), (1, ⟨32, 8, 16, 16⟩)]
  }
  let scene : Scene := #[
    -- Translucent base panel with rounded corners
    .quad ⟨16, 16, 480, 352⟩ 0x161B22E0 14 1 0x30363DFF,
    -- Asymmetric rrect with per-corner radii and per-side borders
    .rrect ⟨32, 32, 180, 90⟩ 0x1F2937CC (16, 4, 20, 8) (2, 4, 1, 3) 0x58A6FFFF,
    -- Angled CSS linear gradients (0°, 45°, 90°, 180°)
    .linear ⟨228, 32, 60, 40⟩ 0xE05252FF 0x3B82F6FF 0 6,
    .linear ⟨296, 32, 60, 40⟩ 0x22C55EFF 0xA855F7FF 45 8,
    .linear ⟨364, 32, 60, 40⟩ 0xF59E0BFF 0x06B6D4FF 90 10,
    .linear ⟨432, 32, 52, 40⟩ 0xEC4899CC 0x14B8A6CC 180 4,
    -- Compute-blurred drop shadow + card
    .shadow ⟨48, 148, 160, 96⟩ 0x00000099 12 10,
    .quad ⟨48, 148, 160, 96⟩ 0x252D38FF 12 1 0x4B5563FF,
    -- Monochrome glyph (page 0), color glyph (page 1), mask (page 1), and rounded image placeholder
    .glyph ⟨4, 4, 16, 16⟩ ⟨64, 168, 16, 16⟩ 0xF3F4F6FF false 0,
    .glyph ⟨8, 8, 16, 16⟩ ⟨92, 168, 16, 16⟩ 0xFFFFFFCC true 1,
    .mask 1 ⟨32, 8, 16, 16⟩ ⟨120, 168, 16, 16⟩ 0x58A6FFEE,
    .image 0 ⟨0, 0, 0, 0⟩ ⟨148, 168, 44, 32⟩ 8,
    -- Backdrop blur region followed by nested rounded clip + nested opacity layer
    .backdropBlur 3,
    .clipPushRounded ⟨232, 136, 240, 210⟩ (18, 18, 18, 18),
    .quad ⟨220, 124, 264, 234⟩ 0x1E293BD8 0 0 0,
    .layerPush 176,
    .quad ⟨252, 156, 120, 72⟩ 0x38BDF8FF 10 2 0xFFFFFFFF,
    .layerPush 160,
    .quad ⟨296, 196, 140, 96⟩ 0xF472B6FF 12 0 0,
    .glyph ⟨8, 8, 16, 16⟩ ⟨312, 212, 16, 16⟩ 0xFFFFFFFF true 1,
    .layerPop,
    .layerPop,
    .clipPop
  ]
  return (w, h, 0x00000000, atlas, scene)

/-- Render all 36 canonical screens via headless offscreen Vulkan readback (`--gpu-readback`). -/
def renderAll36GpuReadback (width height : Nat) (gpuMode : Vulkan.GpuModeRequest)
    (outDir : System.FilePath) (screenOpt : Option ScreenId) : IO UInt32 := do
  IO.FS.createDirAll outDir
  let enableVal := (← IO.getEnv "ORB_LEANUI_VK_VALIDATION") == some "1"
  let effMode ← Vulkan.resolveGpuMode gpuMode
  let rbInit ← match ← Vk.createOffscreenReadback enableVal with
    | .error e =>
      IO.eprintln s!"gpu-readback: failed to create Vulkan offscreen context: {e}"
      return 1
    | .ok ctx => pure ctx
  let rbRef ← IO.mkRef rbInit
  try
    let screens := match screenOpt with | some s => [s] | none => ScreenId.all
    let themes : List Bool := [true, false]
    let scales : List Nat := [120, 240]
    let mut count : Nat := 0
    for scr in screens do
      for isDark in themes do
        for sc in scales do
          let cfg : Runtime.RuntimeConfig := {
            headless := true, width, height, scale120 := sc, darkTheme := isDark, maxFrames := 1
          }
          let initSt := DesktopState.forScreen scr isDark sc
          let rt0Raw ← Runtime.initRuntime cfg initSt
          let rt0 := { rt0Raw with focus := initSt.initialFocusState }
          let (atlas, clearColor, scene, _, _) ← renderDesktopFrame rt0
          let (bw, bh) := rt0.wayland.deviceBufferSize
          let curRb ← rbRef.get
          let pixels ←
            if effMode == .present then
              let (cpuFb, _) := Vulkan.rasterizeScene bw bh clearColor atlas scene
              match ← Vk.renderOffscreenPresent curRb bw bh cpuFb with
              | .error e =>
                Runtime.shutdownRuntime rt0
                IO.eprintln s!"gpu-readback(present) failed: {e}"
                return 1
              | .ok (rb', px) => rbRef.set rb'; pure px
            else
              match ← Vk.renderOffscreenInstanced curRb bw bh clearColor atlas scene true with
              | .error e =>
                Runtime.shutdownRuntime rt0
                IO.eprintln s!"gpu-readback(instanced) failed: {e}"
                return 1
              | .ok (rb', px) => rbRef.set rb'; pure px
          Runtime.shutdownRuntime rt0
          let fpath := outDir / scr.goldenFileName isDark sc
          IO.FS.writeBinFile fpath (Vulkan.encodeRGBA8ToPNG bw bh pixels)
          count := count + 1
    let finalRb ← rbRef.get
    IO.println s!"Rendered {count} GPU readback PNGs ({finalRb.dev.deviceName}) to {outDir}"
    return 0
  finally
    Vk.destroyOffscreenReadback (← rbRef.get)

/-- Render the synthetic translucent all-primitives fixture on CPU or GPU readback. -/
def renderAllPrimsFixture (useGpu : Bool) (gpuMode : Vulkan.GpuModeRequest)
    (outPath : System.FilePath) : IO UInt32 := do
  let (w, h, clearColor, atlas, scene) := buildAllPrimitivesFixture
  if let some parent := outPath.parent then IO.FS.createDirAll parent
  if !useGpu then
    let (fb, _) := Vulkan.rasterizeScene w h clearColor atlas scene
    IO.FS.writeBinFile outPath (Vulkan.encodeRGBA8ToPNG w h fb)
    IO.println s!"Rendered CPU all-primitives fixture to {outPath}"
    return 0
  let effMode ← Vulkan.resolveGpuMode gpuMode
  let enableVal := (← IO.getEnv "ORB_LEANUI_VK_VALIDATION") == some "1"
  let rbInit ← match ← Vk.createOffscreenReadback enableVal with
    | .error e => IO.eprintln s!"gpu-readback-all-prims failed: {e}"; return 1
    | .ok ctx => pure ctx
  let rbRef ← IO.mkRef rbInit
  try
    let curRb ← rbRef.get
    let res ←
      if effMode == .present then
        let (cpuFb, _) := Vulkan.rasterizeScene w h clearColor atlas scene
        Vk.renderOffscreenPresent curRb w h cpuFb
      else
        Vk.renderOffscreenInstanced curRb w h clearColor atlas scene true
    match res with
    | .error e => IO.eprintln s!"gpu-readback-all-prims render failed: {e}"; return 1
    | .ok (rb', px) =>
      rbRef.set rb'
      IO.FS.writeBinFile outPath (Vulkan.encodeRGBA8ToPNG w h px)
      IO.println s!"Rendered GPU ({rb'.dev.deviceName}) all-primitives fixture to {outPath}"
      return 0
  finally
    Vk.destroyOffscreenReadback (← rbRef.get)

/-- Read private anonymous heap (`RssAnon` in KiB) from `/proc/self/status` on Linux. -/
private def readRssAnonKiB : IO Nat := do
  try
    let content ← IO.FS.readFile "/proc/self/status"
    for line in content.splitOn "\n" do
      if line.startsWith "RssAnon:" then
        let parts := (line.drop 8).toString.splitOn " " |>.filter (· != "")
        if let some numStr := parts.head? then
          return numStr.toNat?.getD 0
    return 0
  catch _ => return 0

/-- Format microseconds as milliseconds with two zero-padded decimals (`10050` -> `10.05`). -/
def fmtMs (us : Nat) : String :=
  let frac := (us % 1000) / 10
  s!"{us / 1000}.{if frac < 10 then "0" else ""}{frac}"

/-- Live-compositor WSI benchmark (`--bench-wsi <iterations>`): opens a real Wayland window on
`$WAYLAND_DISPLAY`, waits for initial `xdg_surface.configure`, drives `iterations` streamed frames
through the active backend (`vkInstanced`, `vkPresent`, or `cpuShm` fallback), checks quiescence,
and prints structured JSON metrics. -/
def runWsiBench (cfg : Runtime.RuntimeConfig) (iterations : Nat) : IO UInt32 := do
  let iters := max 1 iterations
  let initSt := DesktopState.forScreen .missionTranscript cfg.darkTheme cfg.scale120
  let t0 ← IO.monoNanosNow
  let rt0 ← Runtime.openWindowRuntime cfg "orb-desktop-bench-wsi" initSt
  let rtRef ← IO.mkRef { rt0 with focus := initSt.initialFocusState }
  try
    let mut rt ← rtRef.get
    -- Wait for initial xdg_surface.configure (up to ~5s)
    let mut waitSteps := 0
    while !rt.wayland.configured && waitSteps < 500 do
      Wayland.waitEvents rt.wayland
      let (wl, evs) ← Wayland.pumpEvents rt.wayland
      rt := { rt with wayland := wl }
      for ev in evs do rt := rt.stepEvent (desktopReducer rt) ev
      rtRef.set rt
      waitSteps := waitSteps + 1
    if !rt.wayland.configured then
      IO.eprintln "bench-wsi: compositor never sent xdg_surface.configure"
      return 1
    -- Initial frame
    let rendered0 := rt.framesRendered
    rt ← Runtime.stepFrameWithRegions rt desktopReducer renderDesktopView
    if rt.framesRendered != rendered0 && rt.vulkan.backend == .cpuShm then
      let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer
      rt := { rt with wayland := wl, presentCount := rt.presentCount + 1 }
    rtRef.set rt
    let coldUs := ((← IO.monoNanosNow) - t0) / 1000

    let mut frameTimesUs : Array Nat := #[]
    for idx in [:iters] do
      let (nextSt, streamDmg) :=
        applyStreamFrame rt.wayland.scale120 rt.viewportDeviceRect rt.app
          [s!" wsi frame {idx}", " gpu swapchain benchmark"]
      let dmg := match streamDmg with
        | none => rt.damage
        | some d => Damage.add rt.damage d
      rt := { rt with app := nextSt, damage := dmg, wayland := { rt.wayland with configurePendingCommit := true } }
      let f0 ← IO.monoNanosNow
      let prevR := rt.framesRendered
      rt ← Runtime.stepFrameWithRegions rt desktopReducer renderDesktopView
      if rt.framesRendered != prevR && rt.vulkan.backend == .cpuShm then
        let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer
        rt := { rt with wayland := wl, presentCount := rt.presentCount + 1 }
      rtRef.set rt
      let f1 ← IO.monoNanosNow
      frameTimesUs := frameTimesUs.push ((f1 - f0) / 1000)

    -- Quiescence check: no damage -> 0 extra redraws
    let beforeQuiescent := rt.framesRendered
    rt ← Runtime.stepFrameWithRegions rt desktopReducer renderDesktopView
    rtRef.set rt
    let quiescentRedraws := rt.framesRendered - beforeQuiescent
    let rssAnonKiB ← readRssAnonKiB
    let sorted := frameTimesUs.qsort (· < ·)
    let p50Us := sorted[sorted.size / 2]?.getD 0
    let p99Us := sorted[min ((sorted.size * 99) / 100) (sorted.size - 1)]?.getD 0
    let backendStr := match rt.vulkan.backend with
      | .cpuShm => "cpuShm"
      | .vkPresent => "vkPresent"
      | .vkInstanced => "vkInstanced"
    let escJson (s : String) : String :=
      s.replace "\\" "\\\\" |>.replace "\"" "\\\"" |>.replace "\n" "\\n" |>.replace "\r" "\\r"
    let fallbackStr := escJson (rt.vulkan.fallbackReason.getD "")
    let icdStr := escJson rt.vulkan.icdName
    let errors : Nat := if quiescentRedraws == 0 && rt.presentCount >= iters then 0 else 1
    IO.println s!"\{\"backend\": \"{backendStr}\", \"icd_name\": \"{icdStr}\", \"present_mode\": {rt.vulkan.presentMode}, \"fallback_reason\": \"{fallbackStr}\", \"cold_ms\": {fmtMs coldUs}, \"frame_p50_ms\": {fmtMs p50Us}, \"frame_p99_ms\": {fmtMs p99Us}, \"frames_rendered\": {rt.framesRendered}, \"present_count\": {rt.presentCount}, \"quiescent_redraws\": {quiescentRedraws}, \"recreates\": {rt.vulkan.swapchainRecreates}, \"gpu_allocated_bytes\": {rt.vulkan.gpuAllocatedBytes}, \"rss_anon_kib\": {rssAnonKiB}, \"width\": {rt.vulkan.width}, \"height\": {rt.vulkan.height}, \"error_count\": {errors}}"
    return (if errors == 0 then 0 else 1)
  finally
    Runtime.shutdownRuntime (← rtRef.get)

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
    widgetId := c.widgetId, rowId := "mission:" ++ c.missionId, kind := "mission", title := c.title }
  let initial := { DesktopState.liveUnavailable with sidebarRows := rows, missionCards := cards, connectionBinding := "test" }
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
  let click := fun pressed => Event.pointerButton (row.x + row.w/2) (row.y + row.h/2) 0x110 pressed
  let press := scrolled.stepEvent (desktopReducer scrolled) (click true)
  let released := press.stepEvent (desktopReducer press) (click false)
  let selected := released.app
  let menu := (released.stepEvent (desktopReducer released) (.key 0xffc7 1 .pressed)).app.missionMenu
  if menu.map (·.mission) != some last.missionId then return false
  let forward := released.stepEvent (desktopReducer released) (.key 0xff09 0 .pressed)
  let backward := forward.stepEvent (desktopReducer forward) (.key 0xfe20 1 .pressed)
  if backward.focus.owner != released.focus.owner then return false
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
    atBottom.hitRegions.any (·.1 == 2)

/-- Native U8 window-effects & badge parity self-test: checks live surface alphas (frosted sidebar
    78% dark / 72% light, 100% solid main pane), 12px rounded window corners (including backdrop-blur
    search modal via rounded-clipped `layerPop`), 60-step 4-quadrant active spinner + paused/Bot
    badges, 0-pixel-diff pure `--leanui` vs hybrid `EmbeddedSidebar` parity, and Vulkan 1.3 GPU
    readback parity when an ICD is available. -/
def windowEffectsSelfTest : IO Unit := do
  let check (cond : Bool) (msg : String) : IO Unit := do
    unless cond do throw (IO.userError msg)
  let pxAt (fb : ByteArray) (w x y : Nat) : UInt8 × UInt8 × UInt8 × UInt8 :=
    let i := (y * w + x) * 4
    (fb.get! i, fb.get! (i + 1), fb.get! (i + 2), fb.get! (i + 3))
  let shapeStub (ac : Text.GlyphAtlasCache) (sc : Nat) (n : WidgetNode) : IO (Text.GlyphAtlasCache × WidgetNode) :=
    let f : Text.FontHandle := { fontId := 1, facePtr := 0, pattern := "stub" }
    shapeWidgetTree ac f f f f f sc n
  let rows : List ChromeSidebarRow :=
    [ { widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", shortcut := "⌘N" }
    , { widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox", shortcut := "⌘I", badge := 3 }
    , { widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }
    , { widgetId := 130, rowId := "project:orb", kind := "project", depth := 0, title := "Orb" }
    , { widgetId := 1001, rowId := "mission:m-active", kind := "mission", depth := 1, title := "Active", status := "active" }
    , { widgetId := 1002, rowId := "mission:m-paused", kind := "mission", depth := 1, title := "Paused", status := "paused" }
    , { widgetId := 1003, rowId := "mission:m-done", kind := "mission", depth := 1, title := "Done", status := "completed" }
    , { widgetId := 1004, rowId := "mission:m-fail", kind := "mission", depth := 1, title := "Failed", status := "failed" }
    , { widgetId := 1005, rowId := "mission:m-wait", kind := "mission", depth := 1, title := "Waiting", status := "awaiting_user" }
    , { widgetId := 103, rowId := "nav:settings", kind := "footer", title := "Settings" }
    ]
  let mkState (isDark : Bool) (sc phase : Nat) : DesktopState :=
    { DesktopState.liveUnavailable isDark sc with
      sidebarRows := rows, expandedProjects := ["orb"]
      badgePhase := phase, screen := .controlEmpty }
  let buildScene (st : DesktopState) (logW logH : Nat) (withModal : Bool) : IO (Nat × Nat × Text.GlyphAtlasCache × Scene) := do
    let sc := st.scale120
    let bw := bufferSize sc logW
    let bh := bufferSize sc logH
    let availW := pxToSub logW
    let availH := pxToSub logH
    let theme := Theme.withWindowEffects st.theme
    let (ac1, tree) ← shapeStub ({ pageWidth := 1024, pageHeight := 1024, pad := 1 }) sc (buildDesktopScreen st availW availH {} true)
    let box := layoutNode sc none theme.palette.focusRing 0 0 availW availH tree.toLayoutNode
    let out := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
    if !withModal then return (bw, bh, ac1.finishUploads, out.prims)
    let overRaw := buildSearchModalOverlay theme availW availH { inputWidgetId := 700, query := "u8", items := [] } "All" "All projects" "Any time" "relevance" false {}
    let (ac2, overTree) ← shapeStub ac1 sc overRaw
    let overBox := layoutNode sc none theme.palette.focusRing 0 0 availW availH overTree.toLayoutNode
    let overOut := buildSceneFromLayout sc {} theme overTree overBox (recordNodes := false)
    let winRect : Rect := ⟨0, 0, Int.ofNat bw, Int.ofNat bh⟩
    let winRad := scaleSubPx sc (pxToSub 12)
    let inner := out.prims ++ #[.backdropBlur (scaleSubPx sc (pxToSub 6))] ++ overOut.prims
    return (bw, bh, ac2.finishUploads, #[.layerPush 255] ++ inner ++ #[.clipPushRounded winRect (winRad, winRad, winRad, winRad), .layerPop, .clipPop])
  -- 1. Surface alphas, premultiplication, 12px corners (normal & backdrop-blur modal), dark/light × 1x/2x
  for isDark in [true, false] do
    let expSb : UInt8 := if isDark then 199 else 184
    for sc in [120, 240] do
      let f := sc / 120
      let (bw, bh, ac, prims) ← buildScene (mkState isDark sc 0) 640 420 false
      let (fb, _) := Vulkan.rasterizeScene bw bh 0 ac prims
      for (cx, cy) in [(0, 0), (bw - 1, 0), (0, bh - 1), (bw - 1, bh - 1)] do
        check (pxAt fb bw cx cy == (0, 0, 0, 0)) s!"corner ({cx},{cy}) not transparent (dark={isDark} sc={sc})"
      let mut hasAA := false
      for k in [1 : 12 * f] do
        let (_, _, _, a) := pxAt fb bw k k
        if a > 0 && a < expSb then hasAA := true
      check hasAA s!"missing AA corner transition (dark={isDark} sc={sc})"
      let (sr, sg, sb, sa) := pxAt fb bw (10 * f) (350 * f)
      check (sa == expSb && sr <= sa && sg <= sa && sb <= sa) s!"sidebar alpha/premul mismatch (dark={isDark} sc={sc}): ({sr},{sg},{sb},{sa})"
      let (_, _, _, hdrA) := pxAt fb bw (420 * f) (10 * f)
      let (_, _, _, mainA) := pxAt fb bw (420 * f) (220 * f)
      check (hdrA == 255 && mainA == 255) s!"main pane must be 100% solid (dark={isDark} sc={sc}): hdr={hdrA} main={mainA}"
    let (bw, bh, acM, primsM) ← buildScene (mkState isDark 120 0) 640 420 true
    let (fbM, _) := Vulkan.rasterizeScene bw bh 0 acM primsM
    for (cx, cy) in [(0, 0), (bw - 1, 0), (0, bh - 1), (bw - 1, bh - 1)] do
      check (pxAt fbM bw cx cy == (0, 0, 0, 0)) s!"modal blur corner ({cx},{cy}) leaked (dark={isDark})"
  -- 2. Active 4-quadrant rotation, stationary paused bars, and awaiting_user Bot fallback
  let rasterLead (status : String) (phase : Nat) : IO ByteArray := do
    let (ac, n) ← shapeStub ({ pageWidth := 1024, pageHeight := 1024, pad := 1 }) 120 (liveMissionLead orbDarkTheme status phase)
    let box := layoutNode 120 none orbDarkTheme.palette.focusRing 0 0 (pxToSub 16) (pxToSub 16) n.toLayoutNode
    let out := buildSceneFromLayout 120 {} orbDarkTheme n box (recordNodes := false)
    return (Vulkan.rasterizeScene 16 16 0 ac.finishUploads out.prims).1
  let q0 ← rasterLead "active" 0
  let q15 ← rasterLead "active" 15
  let q30 ← rasterLead "active" 30
  let q45 ← rasterLead "active" 45
  check (q0 != q15 && q15 != q30 && q30 != q45 && q45 != q0 && q0 != q30) "active spinner must rotate through all 4 quadrants"
  let pb0 ← rasterLead "paused" 0
  let pb30 ← rasterLead "paused" 30
  check (pb0 == pb30) "paused badge must be stationary"
  let (_, _, _, lbA) := pxAt pb0 16 5 8
  let (_, _, _, midA) := pxAt pb0 16 8 8
  let (_, _, _, rbA) := pxAt pb0 16 10 8
  check (lbA > 128 && midA == 0 && rbA > 128) s!"paused badge bars mismatch: l={lbA} m={midA} r={rbA}"
  let waitFb ← rasterLead "awaiting_user" 0
  let (acBot, nBot) ← shapeStub ({ pageWidth := 1024, pageHeight := 1024, pad := 1 }) 120 (chromeIcon "mission" orbDarkTheme.palette.textMuted)
  let bBot := layoutNode 120 none orbDarkTheme.palette.focusRing 0 0 (pxToSub 16) (pxToSub 16) nBot.toLayoutNode
  let (botFb, _) := Vulkan.rasterizeScene 16 16 0 acBot.finishUploads (buildSceneFromLayout 120 {} orbDarkTheme nBot bBot (recordNodes := false)).prims
  check (waitFb == botFb) "awaiting_user badge must render Bot icon"
  -- 3. Pure --leanui vs hybrid EmbeddedSidebar pixel-exact parity (0 diff pixels across sidebar & badges)
  for isDark in [true, false] do
    let (bw, bh, acP, primsP) ← buildScene (mkState isDark 120 18) 640 420 false
    let (fbP, _) := Vulkan.rasterizeScene bw bh 0 acP primsP
    let lStr := if isDark then "0" else "1"
    let req := String.intercalate "\n"
      [ s!"219\t420\t1\t{lStr}\t0\t18"
      , "101\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t0\t0\t"
      , "102\tnav:inbox\tnav\tInbox\t0\t\t⌘I\t3\t0\t0\t"
      , "108\tsection:projects\tsection\tProjects\t0\t\t\t0\t0\t0\t"
      , "130\tproject:orb\tproject\tOrb\t0\t\t\t0\t0\t1\t"
      , "1001\tmission:m-active\tmission\tActive\t1\tactive\t\t0\t0\t0\t"
      , "1002\tmission:m-paused\tmission\tPaused\t1\tpaused\t\t0\t0\t0\t"
      , "1003\tmission:m-done\tmission\tDone\t1\tcompleted\t\t0\t0\t0\t"
      , "1004\tmission:m-fail\tmission\tFailed\t1\tfailed\t\t0\t0\t0\t"
      , "1005\tmission:m-wait\tmission\tWaiting\t1\tawaiting_user\t\t0\t0\t0\t"
      , "103\tnav:settings\tfooter\tSettings\t0\t\t\t0\t0\t0\t"
      ]
    let aRef ← IO.mkRef ({ pageWidth := 1024, pageHeight := 1024, pad := 1 } : Text.GlyphAtlasCache)
    let cRef ← IO.mkRef ({ enabled := false } : EmbeddedSidebarCache)
    let fr ← prepareSidebarFrame req aRef cRef shapeStub 0
    let (fbH, _) := Vulkan.rasterizeScene 219 420 0 (← aRef.get) fr.scene.prims
    let mut diffs := 0
    for y in [120 : 360] do
      for x in [14 : 210] do
        if pxAt fbP bw x y != pxAt fbH 219 x y then diffs := diffs + 1
    check (diffs == 0) s!"pure vs hybrid sidebar mismatch (dark={isDark}): {diffs} pixels"
  -- 4. Vulkan 1.3 GPU readback parity on base shell & backdrop-blur modal (when ICD available)
  if let .ok rb0 ← Vk.createOffscreenReadback false true then
    let rbRef ← IO.mkRef rb0
    try
      for withModal in [false, true] do
        let (bw, bh, ac, prims) ← buildScene (mkState true 120 24) 640 420 withModal
        let (cpuFb, _) := Vulkan.rasterizeScene bw bh 0 ac prims
        match ← Vk.renderOffscreenInstanced (← rbRef.get) bw bh 0 ac prims true with
        | .error e => throw (IO.userError s!"GPU readback failed (modal={withModal}): {e}")
        | .ok (rb', gpuFb) =>
          rbRef.set rb'
          let mut maxD := 0
          for i in [:min cpuFb.size gpuFb.size] do
            let x := (cpuFb.get! i).toNat
            let y := (gpuFb.get! i).toNat
            let d := if x >= y then x - y else y - x
            if d > maxD then maxD := d
          check (maxD <= 2) s!"CPU vs GPU window-effects delta={maxD} > 2 (modal={withModal})"
          for (cx, cy) in [(0, 0), (bw - 1, 0), (0, bh - 1), (bw - 1, bh - 1)] do
            check (pxAt gpuFb bw cx cy == (0, 0, 0, 0)) s!"GPU corner ({cx},{cy}) not transparent (modal={withModal})"
    finally
      Vk.destroyOffscreenReadback (← rbRef.get)

/-- `--self-test`: check live viewports, embedded palette, window effects, and quiescent rendering. -/
def runSelfTest (cfg : Runtime.RuntimeConfig) (initSt : DesktopState) : IO UInt32 := do
  unless liveViewportRegression do
    IO.eprintln "orb-desktop self-test: live viewport regression"
    return 1
  try
    embeddedPaletteSelfTest
  catch e =>
    IO.eprintln s!"orb-desktop self-test: embedded palette regression: {e}"
    return 1
  try
    embeddedSidebarCacheSelfTest
  catch e =>
    IO.eprintln s!"orb-desktop self-test: embedded sidebar cache regression: {e}"
    return 1
  try
    windowEffectsSelfTest
  catch e =>
    IO.eprintln s!"orb-desktop self-test: window effects regression: {e}"
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
private def runningBadgeDamage (rt : Runtime.RuntimeState DesktopState) : Damage :=
  rt.app.sidebarRows.foldl (fun damage row =>
    if row.kind != "mission" || liveBadgeKind row.status != "loader" then damage else
      match rt.hitRegions.find? (·.1 == row.widgetId) with
      | none => damage
      | some (_, rect) => Damage.add damage (roundRect rt.wayland.scale120 rect)) none

def main (args : List String) : IO UInt32 := do
  if let ["--gtk-sidebar-host", path] := args then
    return ← runEmbeddedSidebar path shapeWidgetTree
  if let ["--bench-embedded", n] := args then
    return ← runEmbeddedSidebarBench (n.toNat?.getD 200) shapeWidgetTree
  let dcfg := parseDesktopArgs args
  let rcfg := dcfg.runtimeCfg
  if let some iters := dcfg.benchIterations then
    return (← runDesktopBench rcfg iters dcfg.verifyRepaint)
  if let some wsiIters := dcfg.benchWsiIterations then
    return (← runWsiBench rcfg wsiIters)
  if let some path := dcfg.headlessGoldenAllPrims then
    return (← renderAllPrimsFixture false .disabled path)
  if let some path := dcfg.gpuReadbackAllPrims then
    return (← renderAllPrimsFixture true rcfg.gpuMode path)
  if let some rbDir := rcfg.gpuReadbackDir then
    return (← renderAll36GpuReadback rcfg.width rcfg.height rcfg.gpuMode rbDir dcfg.screenOpt)
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
  let initSt := if dcfg.screenOpt.isNone && !dcfg.selfTest then
    { DesktopState.liveUnavailable rcfg.darkTheme rcfg.scale120 with initialRosterPending := true }
  else DesktopState.forScreen scr rcfg.darkTheme rcfg.scale120
  if dcfg.selfTest then
    return (← runSelfTest rcfg initSt)
  try
    let animations ← try
      let pref ← IO.Process.output { cmd := "gsettings", args := #["get", "org.gnome.desktop.interface", "enable-animations"] }
      pure (pref.stdout.trimAscii != "false")
    catch _ => pure true
    let rt0 ← Runtime.openWindowRuntime rcfg "orb-desktop" initSt
    let capability ← IO.mkRef ({} : VoiceCapability)
    let voiceSlot ← IO.mkRef (none : Option VoiceSession)
    let slot ← IO.mkRef (none : Option LiveSubscription)
    let traceInbox := (← IO.getEnv "ORB_TRACE_INBOX_IDS") == some "1"
    let rt ← Runtime.withProducerWake fun wakeFd notify => do
      withLiveSources rcfg.darkTheme notify fun readSources => do
        let probe ← IO.asTask (prio := .dedicated) do
          capability.set (← probeVoice)
          notify
        try
          Runtime.runWindow { rt0 with focus := initSt.initialFocusState } desktopReducer renderDesktopView
            (fun rt => do
              let vp := rt.viewportDeviceRect
              let (st, damage) ← readLiveFrame slot rt.wayland.scale120 vp rt.app notify
              if traceInbox && st.inboxAvailable &&
                  (!rt.app.inboxAvailable || st.inboxItems != rt.app.inboxItems || st.inboxEnabled != rt.app.inboxEnabled) then
                let ids := if st.inboxEnabled then st.inboxItems.map (·.mission) else []
                IO.eprintln ("Inbox badge IDs: " ++ String.intercalate "," ids)
              let phase := liveSpinnerPhase (← IO.monoMsNow)
              let spin := animations && phase != st.badgePhase
              let damage := if spin then (runningBadgeDamage rt).elim damage (Damage.add damage) else damage
              let st := if spin then { st with badgePhase := phase } else st
              let updated ← readSources st
              let next := updated.getD st
              let voiced ← pollVoice voiceSlot capability next notify
              return (voiced, if updated.isSome || voiced.voiceAvailable != next.voiceAvailable ||
                voiced.voicePhase != next.voicePhase then some vp else damage))
            (·.liveData) desktopFocusChange (some wakeFd) (·.writeRequest.isSome)
            (fun rt => animations && (runningBadgeDamage rt).isSome) desktopFocusTraps
        finally
          discard (IO.wait probe)
          closeVoice voiceSlot
          closeLiveSubscription slot
    Runtime.shutdownRuntime rt
    return 0
  catch e =>
    IO.eprintln s!"orb-desktop-native: cannot run the window: {e}"
    return 1

end OrbDesktop

/-- Top-level C `main` entry point when linking `OrbDesktop/Main.lean` as the executable root. -/
def main (args : List String) : IO UInt32 :=
  OrbDesktop.main args
