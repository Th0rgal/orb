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
  benchLongIterations : Option Nat := none
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
    | "--leanui" :: rest =>
      loop rest cfg
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
    | "--bench-long" :: nStr :: rest =>
      loop rest { cfg with benchLongIterations := some (max 1 (nStr.toNat?.getD 60)) }
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
    return (ac, [{ overlaySynthRun style text with isSynthetic := false }])

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
glyph runs so every label, badge, table cell, composer text, modal, and toast renders with `Inter`.
When `skipWidgetId` matches a node's `wid` (e.g. an already-shaped `CachedLiveTranscript` subtree),
that subtree is returned unchanged in O(1) so zero-bitmap glyphs like spaces are never re-shaped. -/
private partial def shapeWidgetTreeWithSkip (ac : Text.GlyphAtlasCache) (font mono bold medium semibold : Text.FontHandle)
    (scale120 : Nat) (skipWidgetId : Option WidgetId) (node : WidgetNode) : IO (Text.GlyphAtlasCache × WidgetNode) := do
  match node with
  | .mk wid focusable hitTestable style payload children =>
    if skipWidgetId.isSome && wid == skipWidgetId then
      return (ac, node)
    let mut curAc := ac
    let newPayload ←
      match payload with
      | .vectorIcon paths color badgeBg strokeTenths =>
        let w0 := scaleSubPx scale120 (if badgeBg.isSome then pxToSub 10 else style.minWidth)
        let h0 :=
          if badgeBg.isSome then w0
          else if style.minHeight > 0 then scaleSubPx scale120 style.minHeight
          else w0
        let (ac', entry) := curAc.getOrRasterizeIcon paths w0 h0 strokeTenths
        curAc := ac'
        pure (WidgetPayload.iconMask entry.page entry.uv color badgeBg)
      | .text lineHeightSub runs caret =>
        let mut shapedRuns : Array InlineRun := #[]
        for r in runs do
          if r.isSynthetic && !r.glyphs.isEmpty then
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
      let (ac', c') ← shapeWidgetTreeWithSkip curAc font mono bold medium semibold scale120 skipWidgetId c
      curAc := ac'
      shapedChildren := shapedChildren.push c'
    return (curAc, .mk wid focusable hitTestable style newPayload shapedChildren.toList)

/-- Recursively shape any synthetic `.text` runs in `WidgetNode` into real HarfBuzz/FreeType
glyph runs so every label, badge, table cell, composer text, modal, and toast renders with `Inter`. -/
def shapeWidgetTree (ac : Text.GlyphAtlasCache) (font mono bold medium semibold : Text.FontHandle) (scale120 : Nat)
    (node : WidgetNode) : IO (Text.GlyphAtlasCache × WidgetNode) :=
  shapeWidgetTreeWithSkip ac font mono bold medium semibold scale120 none node

private partial def scrollRegionsOf : WidgetNode → ComputedBox → List Runtime.ScrollRegion
  | .mk _ _ _ _ payload wChildren, b =>
    match payload, b.id, b.scrollLimitXY with
    | .scrollClip sc, some id, some (_, limitY) =>
      let lines := (b.children.head?.map (·.lines)).getD []
      let hasScrollbar := sc.showScrollbar && sc.scrollbarOpacity > 0
      [{ id, bounds := b.contentRectSub, limitY, offsetY := (b.scrollOffset.getD (0, 0)).2, textLines := lines, hasScrollbar }]
    | _, _, _ =>
      (wChildren.zip b.children).flatMap fun (wc, bc) => scrollRegionsOf wc bc

/-- Regions of the visible running (`loader`) mission rows. An overlay that takes over input keeps
    them beneath its full-window backdrop region: `hitTest` never returns them, and the spinner tick
    still finds the rows it has to repaint. -/
private def runningRowRegions (st : DesktopState) (regions : List (EntityId × Rect)) : List (EntityId × Rect) :=
  regions.filter fun (id, _) => st.sidebarRows.any fun row =>
    row.widgetId == id && row.kind == "mission" && liveBadgeKind row.status == "loader"

/-- Collect every focusable `WidgetId` inside `node` in document order so virtualized
offscreen spacers preserve exact `focusableOrder` parity with `Scene.subtreeFocusOrder`. -/
private partial def collectWidgetFocusIds (node : WidgetNode) : List WidgetId :=
  match node with
  | .mk wid focusable _ _ _ children =>
    let self := match wid with
      | some id => if focusable then [id] else []
      | none => []
    self ++ children.flatMap collectWidgetFocusIds

/-- Mask backticks and tildes on interior lines of `` ```mermaid ... ``` `` blocks (1:1 ASCII byte
replacement, preserving exact UTF-8 byte offsets) so `Orb.Stream.committedLen` stays strictly in
phase with `OrbDesktop.splitMermaidFences` even when a Mermaid diagram contains `>= 4` backticks. -/
def maskMermaidInteriorForCommit (s : String) : String := Id.run do
  let mut out : Array String := #[]
  let mut inMermaid := false
  for line in s.splitOn "\n" do
    let t := mermaidTrim line
    if !inMermaid && t.startsWith "```mermaid" then
      inMermaid := true
      out := out.push line
    else if inMermaid && t == "```" then
      inMermaid := false
      out := out.push line
    else if inMermaid then
      out := out.push ((line.replace "`" "_").replace "~" "_")
    else
      out := out.push line
  return String.intercalate "\n" out.toList

/-- True when `s` ends with BOTH `splitMermaidFences` and `liveProseLines` fences closed, so
committing `s` can never split a Mermaid diagram or a fenced code block. -/
def transcriptCommitSafe (s : String) : Bool := Id.run do
  let mut inMermaid := false
  let mut inCodeFence := false
  for line in s.splitOn "\n" do
    let t := mermaidTrim line
    if !inMermaid && t.startsWith "```mermaid" then
      inMermaid := true
      inCodeFence := false
    else if inMermaid && t == "```" then
      inMermaid := false
      inCodeFence := false
    else if !inMermaid && t.startsWith "```" then
      inCodeFence := !inCodeFence
  return !inMermaid && !inCodeFence

private structure CachedRowEntry where
  node : WidgetNode
  height : SubPx
  focusIds : List WidgetId := []
  deriving Inhabited

private structure CachedTurnEntry where
  nextBand : Nat
  rows : Array CachedRowEntry
  deriving Inhabited

private structure CachedStreamPrefix where
  baseBand : Nat := liveDiagramBandBase
  committedText : String := ""
  committedBytes : Nat := 0
  midBand : Nat := liveDiagramBandBase
  rows : Array CachedRowEntry := #[]
  deriving Inhabited

private structure CachedPlainStream where
  width : SubPx := 0
  color : Color := 0
  stableText : String := ""
  stableRuns : List InlineRun := []
  fullText : String := ""
  fullRuns : List InlineRun := []
  deriving Inhabited

private structure TranscriptRenderCache where
  sessionId : UInt64 := 0
  atlasGen : UInt64 := 0
  isDark : Bool := true
  scale120 : Nat := 120
  colW : SubPx := 0
  width : SubPx := 0
  turns : Std.HashMap (String × Nat) CachedTurnEntry := {}
  turnKeys : Array (String × Nat) := #[]
  lineCache : Std.HashMap (Bool × String) (Option CachedRowEntry) := {}
  lineKeys : Array (Bool × String) := #[]
  streamPrefix : CachedStreamPrefix := {}
  plainStream : CachedPlainStream := {}
  deriving Inhabited

initialize transcriptRenderCacheRef : IO.Ref TranscriptRenderCache ← IO.mkRef {}

private def utf8Slice (bytes : ByteArray) (lo hi : Nat) : String :=
  if hi ≤ lo || lo ≥ bytes.size then ""
  else (String.fromUTF8? (bytes.extract lo (min hi bytes.size))).getD ""

/-- Split a single-line string into `(stablePrefixEndingWithSpace, trailingWord)` so that
`shapeStreamRuns (stable ++ tail) == shapeStreamRuns stable ++ shapeStreamRuns tail`. -/
private def splitLastSpace (s : String) : String × String :=
  let bytes := s.toUTF8
  let rec findSpace : Nat → Option Nat
    | 0 => none
    | n + 1 => if bytes.get! n == ' '.toNat.toUInt8 then some (n + 1) else findSpace n
  match findSpace bytes.size with
  | some cut => (utf8Slice bytes 0 cut, utf8Slice bytes cut bytes.size)
  | none => ("", s)

/-- Shape and measure a list of raw transcript rows once so cached rows need neither
`shapeWidgetTree` nor `measureNode` on subsequent frames. -/
private def shapeAndMeasureRows (ac : Text.GlyphAtlasCache)
    (font mono bold medium semibold : Text.FontHandle) (sc : Nat) (colW : SubPx)
    (rawRows : List WidgetNode) : IO (Text.GlyphAtlasCache × Array CachedRowEntry) := do
  let mut curAc := ac
  let mut out : Array CachedRowEntry := #[]
  for row in rawRows do
    let (ac', shaped) ← shapeWidgetTree curAc font mono bold medium semibold sc row
    curAc := ac'
    let (_, h) := measureNode colW shaped.toLayoutNode
    out := out.push { node := shaped, height := h, focusIds := collectWidgetFocusIds shaped }
  return (curAc, out)

/-- Shape a multi-line non-Mermaid open stream tail using a bounded per-line cache so even
long unclosed code fences shape only changed lines in O(1) per frame. -/
private def shapeOpenTailLinesCached (cache : TranscriptRenderCache) (ac : Text.GlyphAtlasCache)
    (font mono bold medium semibold : Text.FontHandle) (sc : Nat) (theme : Theme)
    (colW width : SubPx) (tailStr : String) :
    IO (TranscriptRenderCache × Text.GlyphAtlasCache × Array CachedRowEntry) := do
  let mut curCache := cache
  let mut curAc := ac
  let mut out : Array CachedRowEntry := #[]
  let mut inFence := false
  for line in tailStr.splitOn "\n" do
    let t := mermaidTrim line
    if t.startsWith "```" then
      inFence := !inFence
    else
      let lKey := (inFence, line)
      match curCache.lineCache.get? lKey with
      | some (some cachedRow) =>
        out := out.push cachedRow
      | some none =>
        pure ()
      | none =>
        let rawOpt : Option WidgetNode :=
          if inFence then some (liveCodeRow theme colW width line)
          else liveProseLine theme colW width line
        let entryOpt ← match rawOpt with
          | none => pure none
          | some raw =>
            let (ac', shaped) ← shapeWidgetTree curAc font mono bold medium semibold sc raw
            curAc := ac'
            let (_, h) := measureNode colW shaped.toLayoutNode
            pure (some { node := shaped, height := h, focusIds := collectWidgetFocusIds shaped })
        let mut lc' := curCache.lineCache.insert lKey entryOpt
        let mut lk' := curCache.lineKeys.push lKey
        if lk'.size > 512 then
          if let some oldKey := lk'[0]? then
            if oldKey != lKey then lc' := lc'.erase oldKey
          lk' := lk'.extract 1 lk'.size
        curCache := { curCache with lineCache := lc', lineKeys := lk' }
        if let some entry := entryOpt then
          out := out.push entry
  return (curCache, curAc, out)

/-- Compute the transcript pane logical width in `SubPx`, matching `Screens.buildDesktopScreen`. -/
@[inline] private def transcriptPaneWidth (st : DesktopState) (availW : SubPx) : SubPx :=
  let mainW : SubPx := availW - st.sidebarWidth
  if st.screen == .missionSplitDiff then pxToSub 688
  else if st.screen == .missionTranscript && st.sidePanelOpen then
    mainW - min (pxToSub 480) (mainW / 2)
  else mainW

/-- Build a virtualized offscreen spacer that preserves exact vertical height AND attaches
zero-size non-hit-testable focusable placeholders so `rt.focusableOrder` stays scroll-invariant. -/
private def buildVirtualizedSpacer (colW spH : SubPx) (focusIds : Array WidgetId) : WidgetNode :=
  let placeholders : List WidgetNode := focusIds.toList.map fun id =>
    WidgetNode.mk (some id) true false (BoxStyle.row 0 |>.withFixedSize 0 0) .container []
  WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW spH) placeholders

/-- Build and cache a live transcript's shaped rows using `Orb.Stream.committedLen` for
the growing streaming reply and exact-height spacer virtualization for offscreen rows. -/
private def buildCachedLiveTranscript (rt : Runtime.RuntimeState DesktopState)
    (ac : Text.GlyphAtlasCache) (theme : Theme) (st : DesktopState)
    (availW availH : SubPx) (hoverRow : Option WidgetId) :
    IO (Text.GlyphAtlasCache × CachedLiveTranscript) := do
  let sc := rt.wayland.scale120
  let transcriptW : SubPx := transcriptPaneWidth st availW
  let colW : SubPx := min (pxToSub 748) (transcriptW - pxToSub 48)
  let width : SubPx := transcriptTextWidth transcriptW
  let bodyH : SubPx := availH - chromeHeaderHeightSub - chromeComposerHeightSub
  let mut cache ← transcriptRenderCacheRef.get
  if cache.sessionId != rt.sessionId || cache.atlasGen != ac.generation ||
      cache.isDark != theme.isDark || cache.scale120 != sc ||
      cache.colW != colW || cache.width != width then
    cache := { sessionId := rt.sessionId, atlasGen := ac.generation,
               isDark := theme.isDark, scale120 := sc, colW, width }
  let mut curAc := ac
  let mut allRows : Array CachedRowEntry := #[]
  -- 1. Optional history banner (depends on hover / loading state)
  if st.showsHistoryBanner then
    let pal := theme.palette
    let label :=
      if st.historyLoading then "Loading older turns…"
      else if st.historyLoadError then "Could not load older turns · Retry"
      else "Load older turns"
    let hovered := !st.historyLoading && hoverRow == some loadOlderTurnsId
    let bg := if hovered then pal.plusBg else pal.elevatedSurface
    let txtColor := if st.historyLoading then pal.textMuted else pal.textSecondary
    let pillW : SubPx := min colW (pxToSub (if st.historyLoadError then 250 else 170))
    let pill := WidgetNode.rrect
      (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center
        |>.withPadding (Edges.xy (pxToSub 12) 0) |>.withFixedSize pillW transcriptHistoryBannerHeightSub)
      bg (CornerRadii.uniform (pxToSub 8)) (BorderStyle.uniform theme.borderWidth pal.border)
      [screenTextLine theme (pillW - pxToSub 24) (pxToSub 18) (pxToSub 12) (pxToSub 18) txtColor label 500]
      (if st.historyLoading then none else some loadOlderTurnsId)
    let item := if st.historyLoading then pill else WidgetNode.focusable loadOlderTurnsId pill
    let bannerRaw := WidgetNode.box
      (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize colW transcriptHistoryBannerHeightSub)
      [item]
    let (ac', bannerShaped) ← shapeWidgetTree curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc bannerRaw
    curAc := ac'
    allRows := allRows.push {
      node := bannerShaped, height := transcriptHistoryBannerHeightSub,
      focusIds := collectWidgetFocusIds bannerShaped }
  -- 2. Completed live turns (O(1) cache hit per unchanged turn)
  let mut band := liveDiagramBandBase
  for turn in st.liveTurns do
    let tKey := (turn, band)
    match cache.turns.get? tKey with
    | some entry =>
      for r in entry.rows do allRows := allRows.push r
      band := entry.nextBand
    | none =>
      let (rawRows, nextBand) := buildOneLiveTurn theme colW width band turn
      let (ac', shapedRows) ← shapeAndMeasureRows curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc colW rawRows
      curAc := ac'
      let entry : CachedTurnEntry := { nextBand, rows := shapedRows }
      let mut turns' := cache.turns.insert tKey entry
      let mut keys' := cache.turnKeys.push tKey
      if keys'.size > 512 then
        if let some oldKey := keys'[0]? then
          if oldKey != tKey then turns' := turns'.erase oldKey
        keys' := keys'.extract 1 keys'.size
      cache := { cache with turns := turns', turnKeys := keys' }
      for r in shapedRows do allRows := allRows.push r
      band := nextBand
  -- 3. Growing streaming reply using `Orb.Stream.committedLen` + bounded line cache
  let currentText := streamedText st
  let streamActive := st.stream.renders > 1 && !currentText.isEmpty
  let hasMermaid := (splitMermaidFences currentText).any (·.1)
  if hasMermaid || streamActive then
    if hasMermaid || currentText.contains "\n" then
      let bytes := currentText.toUTF8
      let prev := cache.streamPrefix
      let canResume := prev.baseBand == band && prev.committedBytes > 0 &&
        prev.committedBytes ≤ bytes.size && currentText.startsWith prev.committedText
      let mut sp : CachedStreamPrefix :=
        if canResume then prev
        else { baseBand := band, committedText := "", committedBytes := 0, midBand := band, rows := #[] }
      let suffix := utf8Slice bytes sp.committedBytes bytes.size
      let deltaCommit := Orb.Stream.committedLen (maskMermaidInteriorForCommit suffix)
      let newCommit := sp.committedBytes + deltaCommit
      if deltaCommit > 0 then
        let newlyCommitted := utf8Slice bytes sp.committedBytes newCommit
        -- Verify both `splitMermaidFences` and post-Mermaid `liveProseLines` fences are closed.
        if transcriptCommitSafe newlyCommitted then
          let (deltaRaw, nextMid) := buildOneLiveTurn theme colW width sp.midBand newlyCommitted
          let (ac', deltaShaped) ← shapeAndMeasureRows curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc colW deltaRaw
          curAc := ac'
          sp := { sp with
            committedText := utf8Slice bytes 0 newCommit
            committedBytes := newCommit
            midBand := nextMid
            rows := sp.rows ++ deltaShaped }
      cache := { cache with streamPrefix := sp }
      for r in sp.rows do allRows := allRows.push r
      let tailStr := utf8Slice bytes sp.committedBytes bytes.size
      if !tailStr.isEmpty then
        if hasMermaid then
          -- Mirror `buildOneLiveTurn` segmentation on `tailStr` so unclosed `` ```mermaid ``
          -- snippets inside an outer code fence split identically to uncached full repaints,
          -- while still caching unchanged prose/code lines via `lineCache`.
          let mut tailBand := sp.midBand
          for (isFence, seg) in splitMermaidFences tailStr do
            if isFence then
              match parseMermaidFlowchart seg with
              | some spec0 =>
                let spec := { spec0 with nodes := spec0.nodes.mapIdx fun i n =>
                  { n with widgetId := some (tailBand + i) } }
                let (ac', diagShaped) ← shapeAndMeasureRows curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc colW
                  [buildMermaidDiagramWidget theme colW spec]
                curAc := ac'
                for r in diagShaped do allRows := allRows.push r
                tailBand := tailBand + liveDiagramStride
              | none =>
                let (cache', ac', segShaped) ← shapeOpenTailLinesCached cache curAc
                  rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc theme colW width seg
                cache := cache'
                curAc := ac'
                for r in segShaped do allRows := allRows.push r
            else
              let (cache', ac', segShaped) ← shapeOpenTailLinesCached cache curAc
                rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc theme colW width seg
              cache := cache'
              curAc := ac'
              for r in segShaped do allRows := allRows.push r
        else
          let (cache', ac', tailShaped) ← shapeOpenTailLinesCached cache curAc
            rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc theme colW width tailStr
          cache := cache'
          curAc := ac'
          for r in tailShaped do allRows := allRows.push r
    else if needsMarkdownLite currentText then
      -- Match `Screens.lean` single-line markdown-lite path (`liveProseLine`, not `liveProseLines`).
      if cache.streamPrefix.committedBytes > 0 || !cache.streamPrefix.rows.isEmpty then
        cache := { cache with streamPrefix := {} }
      if let some raw := liveProseLine theme colW width currentText then
        let (ac', shapedRows) ← shapeAndMeasureRows curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc colW [raw]
        curAc := ac'
        for r in shapedRows do allRows := allRows.push r
    else
      -- Plain single-line stream text fast path
      if cache.streamPrefix.committedBytes > 0 || !cache.streamPrefix.rows.isEmpty then
        cache := { cache with streamPrefix := {} }
      let (ac', sRuns) ← shapeStreamRuns curAc rt.primaryFont sc
        { (Theme.bodyText theme) with color := theme.palette.textPrimary } currentText width
      curAc := ac'
      let (_, _, height) := wrapInlineRuns width theme.typo.lineBase sRuns
      let rowH := height + pxToSub 12
      let rowNode := WidgetNode.box
        (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 6)) |>.withFixedSize colW rowH)
        [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize width height) theme.typo.lineBase sRuns (some 900)]
      allRows := allRows.push { node := rowNode, height := rowH, focusIds := [] }
  else
    if cache.streamPrefix.committedBytes > 0 || !cache.streamPrefix.rows.isEmpty then
      cache := { cache with streamPrefix := {} }
  -- 4. Optional status row
  if let some c := st.selectedCard then
    let statusRaw := screenTextLine theme colW (pxToSub 21) (pxToSub 12) (pxToSub 21)
      theme.palette.textMuted (conversationStatusLabel c.status)
    let (ac', statusShaped) ← shapeWidgetTree curAc rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc statusRaw
    curAc := ac'
    allRows := allRows.push { node := statusShaped, height := pxToSub 21, focusIds := [] }
  transcriptRenderCacheRef.set cache
  -- 5. Exact total height + viewport spacer virtualization (bit-exact visible coordinates & focus order)
  let gap := transcriptColumnGapSub
  let mut rowsH : SubPx := 0
  for r in allRows do rowsH := rowsH + r.height
  let gapsH : SubPx := if allRows.size > 1 then (allRows.size - 1) * gap else 0
  let contentH : SubPx := pxToSub 3 + rowsH + gapsH
  let offset := (st.scroll.onLayout contentH bodyH).topSub
  let overscan := pxToSub 200
  let visTop := if offset > overscan then offset - overscan else 0
  let visBot := offset + bodyH + overscan
  let mut y : SubPx := pxToSub 3
  let mut prefixCount : Nat := 0
  let mut prefixRowsH : SubPx := 0
  let mut prefixFocusIds : Array WidgetId := #[]
  let mut visibleNodes : Array WidgetNode := #[]
  let mut suffixCount : Nat := 0
  let mut suffixRowsH : SubPx := 0
  let mut suffixFocusIds : Array WidgetId := #[]
  let mut inVisible := false
  for r in allRows do
    let yEnd := y + r.height
    if !inVisible && yEnd < visTop then
      prefixCount := prefixCount + 1
      prefixRowsH := prefixRowsH + r.height
      for fid in r.focusIds do prefixFocusIds := prefixFocusIds.push fid
    else if y > visBot then
      suffixCount := suffixCount + 1
      suffixRowsH := suffixRowsH + r.height
      for fid in r.focusIds do suffixFocusIds := suffixFocusIds.push fid
    else
      inVisible := true
      visibleNodes := visibleNodes.push r.node
    y := yEnd + gap
  let mut outRows : Array WidgetNode := #[]
  if prefixCount > 0 then
    let spH := prefixRowsH + (prefixCount - 1) * gap
    outRows := outRows.push (buildVirtualizedSpacer colW spH prefixFocusIds)
  for n in visibleNodes do outRows := outRows.push n
  if suffixCount > 0 then
    let spH := suffixRowsH + (suffixCount - 1) * gap
    outRows := outRows.push (buildVirtualizedSpacer colW spH suffixFocusIds)
  return (curAc, { rows := outRows.toList, contentH })

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
  let hoverRow := st.hoverTarget rt.hoveredEntity

  let (ac1, hdrRuns) ←
    shapeDesktopRuns rt.atlas.beginUploads rt.primaryFont sc (chromeTitleStyle theme)
      st.headerTitle
  let needDiffRuns := st.screen == .missionSplitDiff || (st.screen == .missionTranscript && st.sidePanelOpen)
  let (ac2, delRuns) ←
    if needDiffRuns then
      shapeDesktopRuns ac1 rt.primaryFont sc
        { (Theme.codeText theme) with color := pal.diffDelText }
        "- webkit_web_view_load_uri(wv, orb_dev_url);"
    else pure (ac1, [])
  let (ac3, addRuns) ←
    if needDiffRuns then
      shapeDesktopRuns ac2 rt.primaryFont sc
        { (Theme.codeText theme) with color := pal.diffAddText }
        "+ buildDesktopScreen st availW availH shapedRuns"
    else pure (ac2, [])
  let useLiveCache := st.liveData && !rt.forceFullRepaint &&
    (st.screen == .missionTranscript || st.screen == .missionSplitDiff)
  let (ac5, streamRuns, cachedLive?) ←
    if useLiveCache then
      let (ac', cached) ← buildCachedLiveTranscript rt ac3 theme st availW availH hoverRow
      pure (ac', [], some cached)
    else
      let streamText := if st.stream.renders > 1 then streamedText st else ""
      let streamW := transcriptTextWidth (transcriptPaneWidth st availW)
      let plainStyle := { (Theme.bodyText theme) with color := pal.textPrimary }
      if streamText.isEmpty then
        pure (ac3, [], none)
      else if (splitMermaidFences streamText).any (·.1) || streamText.contains "\n" || needsMarkdownLite streamText then
        -- Non-plain stream text takes the markdown/mermaid path in `Screens.lean`, which only
        -- checks `!_runs.streamRuns.isEmpty`. Pass a lightweight non-empty marker instead of
        -- shaping the entire string and discarding the result.
        pure (ac3, [{ style := plainStyle, glyphs := [] }], none)
      else if !rt.forceFullRepaint then
        let cache ← transcriptRenderCacheRef.get
        let ps := cache.plainStream
        let sameCtx := cache.sessionId == rt.sessionId && cache.atlasGen == ac3.generation &&
          cache.isDark == theme.isDark && cache.scale120 == sc &&
          ps.width == streamW && ps.color == pal.textPrimary
        if sameCtx && !ps.fullText.isEmpty && streamText == ps.fullText then
          pure (ac3, ps.fullRuns, none)
        else if sameCtx && !ps.stableText.isEmpty && streamText.startsWith ps.stableText then
          let bytes := streamText.toUTF8
          let suffix := utf8Slice bytes ps.stableText.utf8ByteSize bytes.size
          let (deltaStable, tailWord) := splitLastSpace suffix
          let (acA, deltaRuns) ←
            if deltaStable.isEmpty then pure (ac3, [])
            else shapeStreamRuns ac3 rt.primaryFont sc plainStyle deltaStable streamW
          let (acB, tailRuns) ←
            if tailWord.isEmpty then pure (acA, [])
            else shapeStreamRuns acA rt.primaryFont sc plainStyle tailWord streamW
          let nextStableRuns := ps.stableRuns ++ deltaRuns
          let nextStableText := ps.stableText ++ deltaStable
          let combined := nextStableRuns ++ tailRuns
          transcriptRenderCacheRef.set { cache with
            plainStream := { width := streamW, color := pal.textPrimary,
                             stableText := nextStableText, stableRuns := nextStableRuns,
                             fullText := streamText, fullRuns := combined } }
          pure (acB, combined, none)
        else
          let (stable, tailWord) := splitLastSpace streamText
          let (acA, stableRuns) ←
            if stable.isEmpty then pure (ac3, [])
            else shapeStreamRuns ac3 rt.primaryFont sc plainStyle stable streamW
          let (acB, tailRuns) ←
            if tailWord.isEmpty then pure (acA, [])
            else shapeStreamRuns acA rt.primaryFont sc plainStyle tailWord streamW
          let runs := stableRuns ++ tailRuns
          let nextPs : CachedPlainStream :=
            { width := streamW, color := pal.textPrimary,
              stableText := stable, stableRuns, fullText := streamText, fullRuns := runs }
          let nextCache :=
            if cache.sessionId == rt.sessionId && cache.atlasGen == acB.generation &&
                cache.isDark == theme.isDark && cache.scale120 == sc then
              { cache with plainStream := nextPs }
            else
              { sessionId := rt.sessionId, atlasGen := acB.generation, isDark := theme.isDark, scale120 := sc,
                plainStream := nextPs }
          transcriptRenderCacheRef.set nextCache
          pure (acB, runs, none)
      else
        let (ac', runs) ← shapeStreamRuns ac3 rt.primaryFont sc plainStyle streamText streamW
        pure (ac', runs, none)

  let shapedRuns : ShapedScreenRuns := {
    headerTitleRuns := hdrRuns
    streamRuns := streamRuns
    diffDelRuns := delRuns
    diffAddRuns := addRuns
    cachedLiveTranscript := cachedLive?
  }

  let widgetRootRaw := buildDesktopScreen st availW availH shapedRuns liveWindow hoverRow
  let skipId : Option WidgetId := if cachedLive?.isSome then some transcriptViewportId else none
  let (ac6, widgetRoot) ← shapeWidgetTreeWithSkip ac5 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc skipId widgetRootRaw
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
      runningRowRegions st sceneOut.hitRegionsSub ++ (719, outside) :: overlay.hitRegionsSub, overlay.focusableOrder), [])
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
        #[.clipPushRounded winClipRect winRadii, .layerPush 255] ++ inner ++ #[.layerPop, .clipPop]
      else inner
    return ((ac7.finishUploads, clearColor, modalPrims,
      runningRowRegions st sceneOut.hitRegionsSub ++ (searchBackdropId, outside) :: overScene.hitRegionsSub,
      overScene.focusableOrder), [])
  if !st.writeError.isEmpty then
    let w := min availW (pxToSub 440)
    let h := pxToSub 40
    let notice := buildToastWidget theme w { id := 904, kind := .warning, title := st.writeError, dismissButtonId := some 914 }
    let (ac7, widget) ← shapeWidgetTree ac6 rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc notice
    let box := layoutNode sc rt.focus.owner pal.focusRing (availW - w - pxToSub 8 : Nat)
      (availH - chromeComposerHeightSub - h - pxToSub 8 : Nat) w h widget.toLayoutNode
    let overlay := buildSceneFromLayout sc rt.focus theme widget box (recordNodes := false) (focusVisible := rt.focusVisible)
    return ((ac7.finishUploads, if liveWindow then 0 else pal.canvas, sceneOut.prims ++ clipOverlay overlay.prims,
      sceneOut.hitRegionsSub ++ overlay.hitRegionsSub, sceneOut.focusableOrder ++ overlay.focusableOrder), scrollRegionsOf widgetRoot rootBox)
  else
    let clearColor := if liveWindow then 0x00000000 else pal.canvas
    return ((ac6.finishUploads, clearColor, sceneOut.prims, sceneOut.hitRegionsSub, sceneOut.focusableOrder),
      scrollRegionsOf widgetRoot rootBox)

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
            if let some res := stepSearchEditKey viewport st spec key mods then
              return res
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
              let dmg : Damage :=
                if composer == st.composer then none
                else if st.screen == .missionTranscript || st.screen == .missionSplitDiff then
                  some (composerDamageRect scale viewport st.sidebarWidth)
                else some viewport
              return ({ st with composer }, dmg)
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
          return ({ st.clearAllPreedit with missionMenu := some menu }, some viewport)
        if id == 714 || (id == draftProjectPickerId && st.openMission.isNone) then
          let some (_, r) := rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id) | return (st, none)
          return ({ st.clearAllPreedit with missionMenu := some { mission := st.openMission.getD "", x := r.x, y := r.bottom, trigger := id, page := if id == draftProjectPickerId then .draftProject else .settings } }, some viewport)
        if let some field := settingTrigger id then
          let some (_, r) := rt.hitRegions.find? (fun (entry : EntityId × Rect) => entry.1 == id) | return (st, none)
          let st := if field == .machine then { st with launchMachines := none, launchMachinesFailed := false } else st
          return ({ st.clearAllPreedit with missionMenu := some {
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
        return ({ st.clearAllPreedit with missionMenu := some { mission := mid, x, y, trigger := id, targets, mixed } }, some viewport)
    if let .key key mods state := ev then
      if state != .released && mods == 0 && (key == 0xff55 || key == 0xff56) &&
          st.missionMenu.isNone && st.modal == .none &&
          st.composer.imePreeditText.isEmpty &&
          (st.screen == .missionTranscript || st.screen == .missionSplitDiff) then
        if let some r := regions.find? (·.id == transcriptViewportId) then
          let h := r.bounds.h.toNat
          let content := r.limitY + h
          let stepSub : Int := Int.ofNat (max (pxToSub 120) (h * 4 / 5))
          let dy : Int := if key == 0xff55 then -stepSub else stepSub
          let damage := some (roundRectOut scale r.bounds)
          if st.liveData then
            let some st' := stepTranscriptScroll st content h dy | return (st, none)
            return (st', damage)
          else
            let current := if !st.scrolledManually then { pinned := false, topSub := 0 } else st.scroll.onLayout content h
            let next := current.onUserScroll content h dy
            if next == current && st.scrolledManually then return (st, none)
            return ({ st with scroll := next, scrolledManually := true }, damage)
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
      let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer rt.vulkan.lastUploadedDirtyRect
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
        let presentDirty : Option Rect :=
          if rt.vulkan.lastDamagePixels == 0 then some ⟨0, 0, 0, 0⟩
          else rt.vulkan.lastUploadedDirtyRect
        let wl ← Wayland.present rt.wayland rt.vulkan.framebuffer presentDirty
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
    allUpdatesCulled := allUpdatesCulled && rt.vulkan.lastDrawnPrims < fullScenePrims && rt.vulkan.lastDamagePixels < rt.vulkan.width * rt.vulkan.height
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  let (bw, bh) := (rt.vulkan.width, rt.vulkan.height)
  let fbBytes := rt.vulkan.framebuffer.size
  let partialFrames := rt.vulkan.partialFrames
  let framesRendered := rt.framesRendered
  let quiescentSkips := rt.quiescentSkips
  let iconHits := rt.atlas.iconRasterHits
  let iconMisses := rt.atlas.iconRasterMisses
  let maxIconPx := rt.atlas.maxIconRasterPixels
  Runtime.shutdownRuntime rt

  -- Measure transcript open sequentially after releasing `rt` so peak RSS reflects a single runtime.
  let openSt := DesktopState.forScreen .controlEmpty cfg.darkTheme cfg.scale120
  let openRt0Raw ← Runtime.initRuntime { cfg with headless := true } openSt
  let openRt0 := { openRt0Raw with focus := openSt.initialFocusState }
  let mut openRt ← Runtime.stepFrame openRt0 (desktopReducer openRt0) renderDesktopFrame
  let openStartNs ← IO.monoNanosNow
  openRt := { openRt.markFullDamage with app := firstSt, focus := firstSt.initialFocusState }
  openRt ← Runtime.stepFrame openRt (desktopReducer openRt) renderDesktopFrame
  let transcriptOpenUs : Nat := ((← IO.monoNanosNow) - openStartNs) / 1000
  Runtime.shutdownRuntime openRt

  let sorted := frameTimesUs.qsort (· < ·)
  let p50Us := sorted[sorted.size / 2]?.getD 0
  let p95Us := sorted[min ((sorted.size * 95) / 100) (sorted.size - 1)]?.getD 0
  let p99Us := sorted[min ((sorted.size * 99) / 100) (sorted.size - 1)]?.getD 0
  let errors : Nat :=
    if framesRendered == iters + 1 && quiescentSkips == iters && partialFrames == iters &&
        fbBytes == bw * bh * 4 && allUpdatesCulled then 0 else 1
  IO.println s!"\{\"cold_ms\": {fmtMs coldUs}, \"startup_ms\": {fmtMs coldUs}, \"transcript_open_ms\": {fmtMs transcriptOpenUs}, \"frame_p50_ms\": {fmtMs p50Us}, \"frame_p95_ms\": {fmtMs p95Us}, \"frame_p99_ms\": {fmtMs p99Us}, \"frames_rendered\": {framesRendered}, \"quiescent_skips\": {quiescentSkips}, \"partial_frames\": {partialFrames}, \"full_scene_prims\": {fullScenePrims}, \"partial_drawn_prims\": {partialDrawnPrims}, \"icon_raster_hits\": {iconHits}, \"icon_raster_misses\": {iconMisses}, \"max_icon_raster_pixels\": {maxIconPx}, \"work_units\": {iters}, \"error_count\": {errors}, \"width\": {bw}, \"height\": {bh}, \"scale120\": {cfg.scale120}, \"first_frame_crc32\": {firstCrc.toNat}}"
  return (if errors == 0 then 0 else 1)

/-- Build a realistic 120-turn live transcript containing Markdown prose, bullet lists,
fenced code blocks, and Mermaid flowcharts with decision diamonds and non-adjacent routing lanes. -/
private def buildLongTranscriptTurns (count : Nat := 120) : List String :=
  (List.range count).map fun i =>
    if i % 10 == 9 then
      s!"## Turn {i + 1}: Architecture & Routing Check\n\n" ++
      s!"Verified **damage-only** redraws and `Orb.Stream` prefix commit for batch {i + 1}.\n" ++
      "```mermaid\n" ++
      "flowchart LR\n" ++
      "  A[Ingest Delta] --> B{Coalesce?}\n" ++
      "  B -->|yes| C[Commit Prefix]\n" ++
      "  C --> D[Partial Paint]\n" ++
      "  D -->|retry| A\n" ++
      "```\n" ++
      "- Non-adjacent return lane (`D -> A`) stays cached in the icon atlas.\n"
    else if i % 4 == 0 then
      s!"### Step {i + 1}: Module Audit\n" ++
      s!"Inspected `module_{i + 1}.lean` and verified **O(1)** lookup on atlas hits.\n" ++
      "```lean\n" ++
      s!"def check_{i + 1} (n : Nat) : Nat := n + {i + 1}\n" ++
      "```\n"
    else
      s!"Turn {i + 1}: Verified incremental layout, *bounded* vector-icon lane rasterisation, and [spec](https://orb.dev/u7/{i + 1}).\n" ++
      s!"- Damage rect stays confined to changed nodes for turn {i + 1}."

/-- Execute `--bench-long <iterations>`: measures startup, transcript-open, and 60 fps streaming
frame budget while a long 120-turn transcript (with Markdown, code blocks, and Mermaid routing
lanes) receives coalesced multi-delta bursts into a growing Markdown + Mermaid reply. -/
def runLongTranscriptBench (cfg : Runtime.RuntimeConfig) (iterations : Nat) (verifyRepaint := false) : IO UInt32 := do
  let iters := max 1 iterations
  let turns := buildLongTranscriptTurns 120
  let mkLongState : DesktopState :=
    { DesktopState.liveUnavailable cfg.darkTheme cfg.scale120 with
      screen := .missionTranscript
      connectionBinding := "u7-bench"
      openMission := some "m-u7-long"
      missionCards := [{ (default : MissionSummaryCard) with
        widgetId := 211, missionId := "m-u7-long", title := "U7 Long Transcript (120 turns)", status := "running" }]
      liveTurns := turns
      scroll := { pinned := true, topSub := 0 }
      stream := { shown := ["Initial long-transcript baseline."], pending := [], renders := 1 }
      sidebarRows := defaultSidebarRows .missionTranscript }
  let tStartNs ← IO.monoNanosNow
  let firstSt := mkLongState
  let rt0Raw ← Runtime.initRuntime { cfg with headless := true } firstSt
  let rt0 := { rt0Raw with focus := firstSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  let coldUs : Nat := ((← IO.monoNanosNow) - tStartNs) / 1000
  let fullScenePrims := rt.vulkan.lastDrawnPrims

  let mut frameTimesUs : Array Nat := #[]
  let mut partialDrawnPrims : Nat := 0
  let mut allUpdatesCulled : Bool := true
  let mut totalDeltas : Nat := 0
  let rendersBefore := rt.app.stream.renders
  for idx in [0:iters] do
    let deltas : List String :=
      if idx % 15 == 14 then
        [ s!"\n\n### Stream Section {idx + 1}\n"
        , "```mermaid\nflowchart LR\n  S[Stream] --> Q{Valid?}\n"
        , "  Q --> R[Render]\n  R -->|loop| S\n```\n\n"
        , s!"Paragraph after diagram {idx + 1} with **bold** and `code`." ]
      else if idx % 5 == 4 then
        [ s!"\n\nParagraph {idx + 1}: "
        , "coalesced burst token A, "
        , "token B with `Orb.Stream.committedLen`, "
        , "and trailing punctuation.\n" ]
      else
        [ s!" delta_{idx}_a"
        , s!" delta_{idx}_b"
        , s!" delta_{idx}_c"
        , " with stable prefix." ]
    totalDeltas := totalDeltas + deltas.length
    let (nextSt, streamDamage) :=
      applyStreamFrame cfg.scale120 rt.viewportDeviceRect rt.app deltas
    let nextDamage := match streamDamage with
      | none => rt.damage
      | some d => Damage.add rt.damage d
    rt := { rt with app := nextSt, damage := nextDamage }
    let f0 ← IO.monoNanosNow
    -- Spot-check bit-exact pixel & focus-order parity against uncached full repaint on key frames
    let checkFull := verifyRepaint && (idx < 3 || idx % 15 == 14 || idx + 1 == iters)
    let reference ← if checkFull then do
      let ref ← Runtime.stepFrame rt.markFullDamage (desktopReducer rt) renderDesktopFrame
      pure (some (ref.vulkan.framebuffer, ref.vulkan.lastDrawnPrims, ref.focusableOrder))
      else pure none
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
    if let some (fb, fullPrims, fullFocusOrder) := reference then
      if fb != rt.vulkan.framebuffer then
        throw <| IO.userError s!"long stream frame {idx} differs from uncached full repaint"
      if rt.focusableOrder != fullFocusOrder then
        throw <| IO.userError s!"long stream frame {idx} focusableOrder diverged from uncached full repaint"
      if rt.vulkan.lastDrawnPrims >= fullPrims then
        throw <| IO.userError s!"long stream frame {idx} did not cull unchanged primitives ({rt.vulkan.lastDrawnPrims} >= {fullPrims})"
    let f1 ← IO.monoNanosNow
    frameTimesUs := frameTimesUs.push ((f1 - f0) / 1000)
    partialDrawnPrims := rt.vulkan.lastDrawnPrims
    allUpdatesCulled := allUpdatesCulled && rt.vulkan.lastDamagePixels < rt.vulkan.width * rt.vulkan.height
    -- Quiescent frame must skip rendering completely (0 redraws)
    rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  let (bw, bh) := (rt.vulkan.width, rt.vulkan.height)
  let fbBytes := rt.vulkan.framebuffer.size
  let partialFrames := rt.vulkan.partialFrames
  let framesRendered := rt.framesRendered
  let quiescentSkips := rt.quiescentSkips
  let streamRenders := rt.app.stream.renders - rendersBefore
  let iconHits := rt.atlas.iconRasterHits
  let iconMisses := rt.atlas.iconRasterMisses
  let maxIconPx := rt.atlas.maxIconRasterPixels
  Runtime.shutdownRuntime rt

  -- Measure opening the 120-turn transcript sequentially after releasing `rt` to keep peak RSS bounded
  let openSt := DesktopState.forScreen .controlEmpty cfg.darkTheme cfg.scale120
  let openRt0Raw ← Runtime.initRuntime { cfg with headless := true } openSt
  let openRt0 := { openRt0Raw with focus := openSt.initialFocusState }
  let mut openRt ← Runtime.stepFrame openRt0 (desktopReducer openRt0) renderDesktopFrame
  let openStartNs ← IO.monoNanosNow
  openRt := { openRt.markFullDamage with app := firstSt, focus := firstSt.initialFocusState }
  openRt ← Runtime.stepFrame openRt (desktopReducer openRt) renderDesktopFrame
  let transcriptOpenUs : Nat := ((← IO.monoNanosNow) - openStartNs) / 1000
  Runtime.shutdownRuntime openRt

  let sorted := frameTimesUs.qsort (· < ·)
  let p50Us := sorted[sorted.size / 2]?.getD 0
  let p95Us := sorted[min ((sorted.size * 95) / 100) (sorted.size - 1)]?.getD 0
  let p99Us := sorted[min ((sorted.size * 99) / 100) (sorted.size - 1)]?.getD 0
  let maxAllowedIconPx := Text.maxIconRasterDim * Text.maxIconRasterDim
  let errors : Nat :=
    if framesRendered == iters + 1 && quiescentSkips == iters && partialFrames == iters &&
        streamRenders == iters && totalDeltas > iters &&
        maxIconPx ≤ maxAllowedIconPx &&
        fbBytes == bw * bh * 4 && allUpdatesCulled then 0 else 1
  IO.println s!"\{\"mode\": \"long_transcript\", \"turns\": {turns.length}, \"cold_ms\": {fmtMs coldUs}, \"startup_ms\": {fmtMs coldUs}, \"transcript_open_ms\": {fmtMs transcriptOpenUs}, \"frame_p50_ms\": {fmtMs p50Us}, \"frame_p95_ms\": {fmtMs p95Us}, \"frame_p99_ms\": {fmtMs p99Us}, \"frames_rendered\": {framesRendered}, \"quiescent_skips\": {quiescentSkips}, \"partial_frames\": {partialFrames}, \"stream_coalesced_deltas\": {totalDeltas}, \"stream_renders\": {streamRenders}, \"icon_raster_hits\": {iconHits}, \"icon_raster_misses\": {iconMisses}, \"max_icon_raster_pixels\": {maxIconPx}, \"full_scene_prims\": {fullScenePrims}, \"partial_drawn_prims\": {partialDrawnPrims}, \"work_units\": {iters}, \"error_count\": {errors}, \"width\": {bw}, \"height\": {bh}, \"scale120\": {cfg.scale120}}"
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
      { app := st, scrollRegions := scrollRegionsOf widget box, hitRegions := scene.hitRegionsSub }
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
    78% dark / 72% light, 100% solid main pane), 12px rounded window corners (including the
    backdrop-blur search modal, clipped once where its layer is composited), 60-step 4-quadrant active spinner + paused/Bot
    badges, 0-pixel-diff pure `--leanui` vs hybrid `EmbeddedSidebar` parity, and Vulkan 1.3 GPU
    readback parity when an ICD is available (`ORB_REQUIRE_WINDOW_EFFECTS_GPU=1` makes a missing
    device a failure, so CI cannot skip it). -/
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
    let spec : SearchDialogSpec := { inputWidgetId := 700, query := "u8", items := [] }
    let st := if withModal then { st with modal := .searchPalette spec } else st
    let (ac1, tree) ← shapeStub ({ pageWidth := 1024, pageHeight := 1024, pad := 1 }) sc (buildDesktopScreen st availW availH {} true)
    let box := layoutNode sc none theme.palette.focusRing 0 0 availW availH tree.toLayoutNode
    let out := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
    if !withModal then return (bw, bh, ac1.finishUploads, out.prims)
    let overRaw := buildSearchModalOverlay theme availW availH spec "All" "All projects" "Any time" "relevance" false {}
    let (ac2, overTree) ← shapeStub ac1 sc overRaw
    let overBox := layoutNode sc none theme.palette.focusRing 0 0 availW availH overTree.toLayoutNode
    let overOut := buildSceneFromLayout sc {} theme overTree overBox (recordNodes := false)
    let winRect : Rect := ⟨0, 0, Int.ofNat bw, Int.ofNat bh⟩
    let winRad := scaleSubPx sc (pxToSub 12)
    let inner := out.prims ++ #[.backdropBlur (scaleSubPx sc (pxToSub 6))] ++ overOut.prims
    return (bw, bh, ac2.finishUploads, #[.clipPushRounded winRect (winRad, winRad, winRad, winRad), .layerPush 255] ++ inner ++ #[.layerPop, .clipPop])
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
    -- The blur must not drag the transparent window corners into the solid main pane.
    for (cx, cy) in [(bw - 14, 14), (bw - 20, 6), (bw - 6, 20), (bw - 14, bh - 15), (bw - 6, bh - 21)] do
      let (_, _, _, a) := pxAt fbM bw cx cy
      check (a == 255) s!"modal blur thinned the main pane at ({cx},{cy}): alpha={a} (dark={isDark})"
  -- A rounded clip around an opacity layer attenuates its edge once, not once per nesting level.
  let raster (scene : Scene) : Array UInt8 :=
    (Vulkan.rasterizeScene 64 64 0 { pageWidth := 1024, pageHeight := 1024, pad := 1 } scene).1.data
  let clip : Prim := .clipPushRounded ⟨8, 8, 48, 48⟩ (12, 12, 12, 12)
  let fill : Prim := .rrect ⟨0, 0, 64, 64⟩ 0xFFFFFFFF (0, 0, 0, 0) (0, 0, 0, 0) 0
  let flat := raster #[clip, fill, .clipPop]
  check (flat.any fun a => a > 0 && a < 255) "rounded clip fixture has no anti-aliased edge"
  check (raster #[clip, .layerPush 255, fill, .layerPop, .clipPop] == flat)
    "a rounded clip around a layer must clip it once, exactly like the same fill without the layer"
  -- Clip commands inside a layer neither outlive it nor widen its render area, on both renderers.
  let area : Rect := ⟨8, 8, 48, 48⟩
  let leaked : Scene := #[clip, .layerPush 255, .clipPush ⟨8, 8, 4, 4⟩, .layerPop, fill, .clipPop]
  let escaped : Scene := #[.clipPush area, .layerPush 255, .clipPop, fill, .layerPop, .clipPop]
  let scissors (scene : Scene) : List Rect :=
    (Vk.lowerScene 64 64 scene).ops.toList.filterMap fun op =>
      match op with
      | .drawBatch _ _ scissor => some scissor
      | _ => none
  check (raster leaked == flat) "a clip left open inside a layer outlived its layerPop on CPU"
  check (scissors leaked == [area]) s!"a clip left open inside a layer outlived its layerPop on GPU: {repr (scissors leaked)}"
  check (scissors escaped == [area]) s!"an unmatched clipPop widened the layer scissor on GPU: {repr (scissors escaped)}"
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
  else if (← IO.getEnv "ORB_REQUIRE_WINDOW_EFFECTS_GPU") == some "1" then
    throw (IO.userError "no Vulkan device for the GPU window-effects readback")

/-- U7 cache-vs-uncached regression checks covering Finding 2 (offscreen `focusableOrder`),
Finding 3 (single-line opening fence + 4-backtick Mermaid guard), and Finding 4
(`.missionSplitDiff` / `sidePanelOpen` hover & stream width parity). -/
private def u7CacheParitySelfTest (cfg : Runtime.RuntimeConfig) : IO Unit := do
  let checkParity (label : String) (st : DesktopState) (hover? : Option EntityId := none) : IO Unit := do
    let rt0 ← Runtime.initRuntime { cfg with headless := true, width := 1280, height := 800 } st
    try
      let rtBase := { rt0 with focus := st.initialFocusState, hoveredEntity := hover? }
      let rtCached ← Runtime.stepFrame rtBase (desktopReducer rtBase) renderDesktopFrame
      let rtUncached ← Runtime.stepFrame rtBase.markFullDamage (desktopReducer rtBase) renderDesktopFrame
      unless rtCached.vulkan.framebuffer == rtUncached.vulkan.framebuffer do
        throw <| IO.userError s!"u7 cache parity ({label}): framebuffer differs from uncached full repaint"
      unless rtCached.focusableOrder == rtUncached.focusableOrder do
        throw <| IO.userError s!"u7 cache parity ({label}): focusableOrder differs ({repr rtCached.focusableOrder} vs {repr rtUncached.focusableOrder})"
    finally
      Runtime.shutdownRuntime rt0
  let baseLive : DesktopState :=
    { DesktopState.liveUnavailable cfg.darkTheme cfg.scale120 with
      screen := .missionTranscript
      connectionBinding := "u7-parity"
      openMission := some "m-u7-p"
      sidebarRows := defaultSidebarRows .missionTranscript }
  -- 1. Single-line opening fence `"```lean"` (no newline yet)
  checkParity "single-line-fence"
    { baseLive with stream := { shown := ["```lean"], pending := [], renders := 2 } }
  -- 2. Four-backtick line inside a Mermaid fence followed by a blank line and a subsequent code fence
  let trickyMermaid := "```mermaid\nflowchart LR\n  A --> B\n````\n\n  B --> C\n```"
  if transcriptCommitSafe "```mermaid\nflowchart LR\n  A --> B\n````\n\n" then
    throw <| IO.userError "u7 cache parity: transcriptCommitSafe accepted 4-backtick closer"
  checkParity "mermaid-4tick-fence"
    { baseLive with stream := { shown := [trickyMermaid], pending := [], renders := 2 } }
  -- Incremental multi-block stream: 4-backtick Mermaid block followed by a fenced code block with blank line
  let rtInc0 ← Runtime.initRuntime { cfg with headless := true, width := 1280, height := 800 } baseLive
  try
    let mut rtInc := { rtInc0 with focus := baseLive.initialFocusState }
    for chunk in [ "```mermaid\nflowchart LR\n  A --> B\n````\n\n"
                 , "  B --> C\n```\n\n```lean\ndef foo := 1\n\n"
                 , "def bar := 2\n```\n\nDone" ] do
      let (nextSt, dmg) := applyStreamFrame cfg.scale120 rtInc.viewportDeviceRect rtInc.app [chunk]
      let rtNext := { rtInc with app := nextSt, damage := dmg.elim rtInc.damage (Damage.add rtInc.damage) }
      let rtFull ← Runtime.stepFrame rtNext.markFullDamage (desktopReducer rtNext) renderDesktopFrame
      rtInc ← Runtime.stepFrame rtNext (desktopReducer rtNext) renderDesktopFrame
      unless rtInc.vulkan.framebuffer == rtFull.vulkan.framebuffer do
        throw <| IO.userError s!"u7 cache parity (incremental 4-tick mermaid + lean fence): framebuffer mismatch"
      unless rtInc.focusableOrder == rtFull.focusableOrder do
        throw <| IO.userError s!"u7 cache parity (incremental 4-tick mermaid + lean fence): focusableOrder mismatch"
  finally
    Runtime.shutdownRuntime rtInc0
  -- 3. Long transcript with history banner + offscreen Mermaid nodes scrolled to bottom
  checkParity "virtualized-focus-order"
    { baseLive with
      historyHasMore := true
      liveTurns := buildLongTranscriptTurns 40
      scroll := { pinned := true, topSub := 0 } }
  -- 4. Split-diff hover on history banner & sidePanelOpen plain stream width
  checkParity "split-diff-hover-banner"
    { baseLive with
      screen := .missionSplitDiff
      historyHasMore := true
      liveTurns := ["Turn one"]
      stream := { shown := ["plain split stream text"], pending := [], renders := 2 } }
    (some loadOlderTurnsId)
  checkParity "side-panel-plain-stream"
    { baseLive with
      sidePanelOpen := true
      liveData := false
      stream := { shown := ["word1 word2 word3 word4 word5 word6 word7 word8 word9 word10"], pending := [], renders := 2 } }

  -- 5. Space-only runs in cached live turns and pre-shaped plain streams (must never be double-shaped)
  checkParity "cached-space-only-runs"
    { baseLive with
      liveTurns :=
        [ "**bold** `code` and **a** *b*"
        , "```lean\ndef f :=\n  \n  1\n```" ] }
  checkParity "plain-stream-leading-double-spaces"
    { baseLive with
      stream := { shown := ["  Hello  world"], pending := [], renders := 2 } }
  checkParity "plain-stream-nonlive-spaces"
    { baseLive with
      liveData := false
      stream := { shown := ["  Hello  world   "], pending := [], renders := 2 } }
  -- 6. Open outer code fence containing an unclosed ```mermaid snippet after an earlier committed Mermaid diagram
  let rtSeg0 ← Runtime.initRuntime { cfg with headless := true, width := 1280, height := 800 } baseLive
  try
    let mut rtSeg := { rtSeg0 with focus := baseLive.initialFocusState }
    for chunk in [ "```mermaid\nflowchart LR\n  A --> B\n```\n\n"
                 , "```markdown\n```mermaid\nflowchart LR\n  C --> D" ] do
      let (nextSt, dmg) := applyStreamFrame cfg.scale120 rtSeg.viewportDeviceRect rtSeg.app [chunk]
      let rtNext := { rtSeg with app := nextSt, damage := dmg.elim rtSeg.damage (Damage.add rtSeg.damage) }
      let rtFull ← Runtime.stepFrame rtNext.markFullDamage (desktopReducer rtNext) renderDesktopFrame
      rtSeg ← Runtime.stepFrame rtNext (desktopReducer rtNext) renderDesktopFrame
      unless rtSeg.vulkan.framebuffer == rtFull.vulkan.framebuffer do
        throw <| IO.userError "u7 cache parity (committed mermaid + unclosed nested mermaid): framebuffer mismatch"
      unless rtSeg.focusableOrder == rtFull.focusableOrder do
        throw <| IO.userError "u7 cache parity (committed mermaid + unclosed nested mermaid): focusableOrder mismatch"
  finally
    Runtime.shutdownRuntime rtSeg0

/-- `--self-test`: check live viewports, embedded palette, window effects, U7 cache parity, and quiescent rendering. -/
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
  try
    u7CacheParitySelfTest cfg
  catch e =>
    IO.eprintln s!"orb-desktop self-test: U7 cache parity regression: {e}"
    return 1
  let rt0Raw ← Runtime.initRuntime { cfg with headless := true } initSt
  let rt0 := { rt0Raw with focus := initSt.initialFocusState }
  let mut rt ← Runtime.stepFrame rt0 (desktopReducer rt0) renderDesktopFrame
  rt ← Runtime.stepFrame rt (desktopReducer rt) renderDesktopFrame
  -- An overlay owns the pointer, yet a running row beneath it keeps its spinner region.
  let running : DesktopState := { DesktopState.liveUnavailable cfg.darkTheme cfg.scale120 with
    expandedProjects := ["orb"], screen := .controlEmpty
    sidebarRows :=
      [ { widgetId := 130, rowId := "project:orb", kind := "project", depth := 0, title := "Orb" }
      , { widgetId := 1001, rowId := "mission:m-active", kind := "mission", depth := 1, title := "Active", status := "active" } ] }
  let mut overlayFault : Option String := none
  for (name, over, backdrop) in
      [ ("mission menu", { running with missionMenu := some { mission := "", x := 0, y := 0 } }, 719)
      , ("search modal", { running with modal := .searchPalette defaultSearchDialogSpec }, searchBackdropId) ] do
    let ((_, _, _, regions, _), _) ← renderDesktopView { rt with app := over }
    match (runningRowRegions over regions).head? with
    | none => overlayFault := some s!"{name} hides the running row from the spinner tick"
    | some (_, row) =>
      if hitTest regions row.x row.y != some backdrop then
        overlayFault := some s!"{name} lets the pointer reach the row beneath it"
  Runtime.shutdownRuntime rt
  if let some fault := overlayFault then
    IO.eprintln s!"orb-desktop self-test: {fault}"
    return 1
  if rt.framesRendered != 1 || rt.quiescentSkips < 1 then
    IO.eprintln s!"orb-desktop self-test: frames={rt.framesRendered}, skips={rt.quiescentSkips}"
    return 1
  IO.println "orb-desktop self-test: ok"
  return 0

/-- Device-pixel damage covering every visible running (`loader`) mission row, or `none` when no
    spinner is on screen, so a spinner tick repaints only those rows. -/
private def runningBadgeDamage (rt : Runtime.RuntimeState DesktopState) : Damage :=
  (runningRowRegions rt.app rt.hitRegions).foldl
    (fun damage (_, rect) => Damage.add damage (roundRect rt.wayland.scale120 rect)) none

/-- Main entry point for `OrbDesktop`. -/
def main (args : List String) : IO UInt32 := do
  if let ["--gtk-sidebar-host", path] := args then
    return ← runEmbeddedSidebar path shapeWidgetTree
  if let ["--bench-embedded", n] := args then
    return ← runEmbeddedSidebarBench (n.toNat?.getD 200) shapeWidgetTree
  let dcfg := parseDesktopArgs args
  let rcfg := dcfg.runtimeCfg
  if let some iters := dcfg.benchIterations then
    return (← runDesktopBench rcfg iters dcfg.verifyRepaint)
  if let some longIters := dcfg.benchLongIterations then
    return (← runLongTranscriptBench rcfg longIters dcfg.verifyRepaint)
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
                (logicalSubSize? := some rt.wayland.logicalSubSize)
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
            (fun rt => animations && (runningBadgeDamage rt).isSome) desktopFocusTraps desktopImeSessionKey
            DesktopState.clearAllPreeditChecked
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
