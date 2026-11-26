import OrbDesktop.Chrome
import Orb.ProjectAppearance
import LeanUI.Runtime

namespace OrbDesktop
open LeanUI
open LeanUI.Widgets

/-- Reserved hit-region ID for the embedded palette modal card bounds (used for outside-click dismissal). -/
def paletteCardHitId : Nat := 900000

/-- Display-only palette item received from the GTK host (canonical ranking lives in `orb-locald`). -/
structure PaletteRow where
  widgetId : Nat
  itemId   : String
  kind     : String
  title    : String
  subtitle : String
  status   : String
  shortcut : String
  color    : String := ""
  deriving Repr, Inhabited, BEq

/-- Parsed `"P\t..."` palette paint request from the GTK hybrid overlay host. -/
structure PaletteRequest where
  width       : Nat
  height      : Nat
  scale       : Nat
  light       : Bool
  selectedIdx : Nat
  query       : String
  items       : List PaletteRow
  selectedAll : Bool := false
  deriving Repr, Inhabited, BEq

/-- Parse one tab-separated palette item line (`index\tid\tkind\ttitle\tsubtitle\tstatus\tshortcut[\tcolor]`). -/
def parsePaletteItem? (line : String) : Option PaletteRow := do
  let (index, itemId, kind, title, subtitle, status, shortcut, color) ←
    match line.splitOn "\t" with
    | [index, itemId, kind, title, subtitle, status, shortcut, color] =>
      some (index, itemId, kind, title, subtitle, status, shortcut, color)
    | [index, itemId, kind, title, subtitle, status, shortcut] =>
      some (index, itemId, kind, title, subtitle, status, shortcut, "")
    | _ => none
  let widgetId ← index.toNat?
  guard (widgetId < paletteCardHitId)
  return { widgetId, itemId, kind, title, subtitle, status, shortcut, color }

/-- Parse a `"P\t<w>\t<h>\t<scale>\t<light>\t<selectedIdx>\t<query>\n<items>"` request.
    Enforces `1 <= width, height <= 16384` and `1 <= scale <= 8`.
    Returns `none` for legacy sidebar requests or invalid bounds. -/
def parsePaletteRequest? (request : String) : Option PaletteRequest := do
  let header :: lines := request.splitOn "\n" | none
  let "P" :: w :: h :: scaleS :: light :: sel :: q :: qRest := header.splitOn "\t" | none
  let width ← w.toNat?
  let height ← h.toNat?
  let scale ← scaleS.toNat?
  let selectedIdx ← sel.toNat?
  guard (light == "0" || light == "1")
  guard (1 <= width && width <= 16384)
  guard (1 <= height && height <= 16384)
  guard (1 <= scale && scale <= 8)
  return {
    width
    height
    scale
    light := light == "1"
    selectedIdx
    query := String.intercalate " " (q :: qRest)
    items := lines.filterMap parsePaletteItem?
  }

private def paletteIconName (row : PaletteRow) : String :=
  match row.kind, row.itemId with
  | "mission", _ => "mission"
  | "project", _ => "project-folder"
  | "settings", "settings:notifications" => "s:notifs"
  | "settings", rid => if rid.startsWith "settings:" then "s:" ++ (rid.drop 9).toString else "nav:settings"
  | _, "nav:new-agent" => "nav:new"
  | _, "nav:providers" => "nav:inference"
  | _, "nav:cloud-agent" => "nav:cloud"
  | "nav", rid => rid
  | _, _ => "search"

/-- Resolve the icon color for a palette item, applying project appearance colors when present. -/
def paletteIconColor (pal : Palette) (row : PaletteRow) : Color :=
  if row.kind == "mission" then
    match liveBadgeKind row.status with
    | "loader" => pal.accent
    | "alert" => pal.warning
    | "check" => pal.success
    | _ => pal.textMuted
  else if row.kind == "project" then
    match Orb.ProjectAppearance.rgb? row.color with
    | some rgb => (rgb * 256 + 255).toUInt32
    | none => pal.textSecondary
  else pal.textMuted

/-- Build the native LeanUI Search / Quick-Jump Palette overlay widget tree for `req`. -/
def buildPaletteChrome (req : PaletteRequest) : Theme × WidgetNode :=
  let theme := if req.light then orbLightTheme else orbDarkTheme
  let pal := theme.palette
  let vpW : SubPx := pxToSub (max 1 req.width)
  let vpH : SubPx := pxToSub (max 1 req.height)
  let cardW : SubPx := min (pxToSub 560) (if req.width > 48 then pxToSub (req.width - 48) else vpW)
  let innerW : SubPx := if cardW > pxToSub 16 then cardW - pxToSub 16 else cardW
  let topPad : SubPx := min (pxToSub 84) (vpH / 7)
  let availListPx : Nat := req.height - 210
  let maxVisible : Nat := max 1 (min 10 (availListPx / 44))
  let clampedSel : Nat :=
    if req.items.isEmpty then 0 else min req.selectedIdx (req.items.length - 1)
  let scrollStart : Nat :=
    if clampedSel >= maxVisible then clampedSel + 1 - maxVisible else 0
  let visibleItems := (req.items.drop scrollStart).take maxVisible

  let small := Theme.mutedText theme
  let faintSmall : TextStyle := { small with color := pal.textFaint }
  let queryW : SubPx := if innerW > pxToSub 90 then innerW - pxToSub 90 else pxToSub 40
  let queryStyle : TextStyle := {
    (chromeText theme (if req.query.isEmpty then pal.textMuted else pal.textPrimary)) with
    sizeSub := pxToSub 14, lineHeightSub := pxToSub 20
  }
  let caret : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withFixedSize (pxToSub 2) (pxToSub 16))
      pal.textPrimary (CornerRadii.uniform (pxToSub 1)) BorderStyle.none []
  let queryContent : List WidgetNode :=
    if req.query.isEmpty then
      [caret, chromeLabel (pxToSub 20) [overlaySynthRun queryStyle "Search missions, projects, or commands…"]]
    else if req.selectedAll then
      [WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 2) 0))
        pal.accentMuted (CornerRadii.uniform (pxToSub 3)) BorderStyle.none
        [chromeLabel (pxToSub 20) [overlaySynthRun queryStyle req.query]]]
    else
      [chromeLabel (pxToSub 20) [overlaySynthRun queryStyle req.query], caret]
  let queryBox : WidgetNode :=
    WidgetNode.box
      { (BoxStyle.row (pxToSub 2) |>.withAlign .center |>.withFixedSize queryW (pxToSub 24)) with clip := true }
      queryContent
  let escBadge : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 34) (pxToSub 22))
      pal.surface (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [chromeLabel small.lineHeightSub [overlaySynthRun faintSmall "Esc"]]
  let searchBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 14) 0)
        |>.withFixedSize cardW (pxToSub 46))
      [chromeIcon "search" pal.textMuted 15, queryBox, escBadge]

  let divider : WidgetNode :=
    WidgetNode.box (BoxStyle.row 0 |>.withFixedSize cardW (pxToSub 1) |>.withBg pal.borderSubtle) []

  let rowH : SubPx := pxToSub 42
  let listNodes : List WidgetNode :=
    if visibleItems.isEmpty then
      let emptyMsg :=
        if req.query.isEmpty then "Type to search missions, projects, or pages"
        else s!"No matches for \"{req.query}\""
      [WidgetNode.box
        (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize innerW (pxToSub 68))
        [chromeLabel (pxToSub 18) [overlaySynthRun (chromeText theme pal.textMuted) emptyMsg]]]
    else
      visibleItems.mapIdx fun i row =>
        let isSelected := scrollStart + i == clampedSel
        let rowBg := if isSelected then pal.rowActive else 0x00000000
        let hasShortcut := !row.shortcut.isEmpty
        let badgeW : SubPx := if hasShortcut then pxToSub 50 else if isSelected then pxToSub 22 else 0
        let textW : SubPx := if innerW > pxToSub 48 + badgeW then innerW - pxToSub 48 - badgeW else pxToSub 40
        let titleStyle : TextStyle := {
          (chromeText theme (if isSelected then pal.textStrong else pal.textPrimary)) with
          weight := if isSelected then 500 else 400, lineHeightSub := pxToSub 18
        }
        let titleNode : WidgetNode :=
          WidgetNode.text
            { (BoxStyle.row 0 |>.withFixedSize textW (pxToSub 18)) with clip := true }
            (pxToSub 18) [overlaySynthRun titleStyle row.title]
        let textChildren : List WidgetNode :=
          if row.subtitle.isEmpty then [titleNode]
          else
            let subNode : WidgetNode :=
              WidgetNode.text
                { (BoxStyle.row 0 |>.withFixedSize textW (pxToSub 15)) with clip := true }
                (pxToSub 15) [overlaySynthRun small row.subtitle]
            [titleNode, subNode]
        let textCol : WidgetNode :=
          WidgetNode.box
            (BoxStyle.col (pxToSub 1) |>.withJustify .center |>.withFixedSize textW (if row.subtitle.isEmpty then pxToSub 20 else pxToSub 34))
            textChildren
        let trailing : List WidgetNode :=
          if hasShortcut then
            [WidgetNode.rrect
              (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 42) (pxToSub 20))
              pal.surface (CornerRadii.uniform theme.radiusSm)
              (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
              [chromeLabel small.lineHeightSub [overlaySynthRun faintSmall row.shortcut]]]
          else if isSelected then
            [chromeLabel small.lineHeightSub [overlaySynthRun faintSmall "↵"]]
          else []
        WidgetNode.focusable row.widgetId <|
          WidgetNode.rrect
            (BoxStyle.row (pxToSub 10)
              |>.withAlign .center
              |>.withPadding (Edges.xy (pxToSub 10) 0)
              |>.withFixedSize innerW rowH)
            rowBg (CornerRadii.uniform (pxToSub 6)) BorderStyle.none
            ([chromeIcon (paletteIconName row) (paletteIconColor pal row) 15, textCol] ++ trailing)
            (some row.widgetId)

  let listContentH : SubPx :=
    if visibleItems.isEmpty then pxToSub 68
    else visibleItems.length * rowH + (visibleItems.length - 1) * pxToSub 2
  let listBox : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 2)
        |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 6))
        |>.withFixedSize cardW (listContentH + pxToSub 12))
      listNodes

  let countLabel :=
    if req.items.isEmpty then ""
    else if req.items.length == 1 then "1 result"
    else s!"{req.items.length} results"
  let footer : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 14) 0)
        |>.withFixedSize cardW (pxToSub 28))
      0x00000000 CornerRadii.zero
      { widths := Edges.trbl theme.borderWidth 0 0 0, color := pal.borderSubtle }
      [chromeLabel small.lineHeightSub [overlaySynthRun faintSmall "↑↓ Navigate   ↵ Open   Esc Close"],
       chromeLabel small.lineHeightSub [overlaySynthRun faintSmall countLabel]]

  let cardH : SubPx := pxToSub 46 + pxToSub 1 + listContentH + pxToSub 12 + pxToSub 28 + pxToSub 2
  let sh : ShadowStyle := {
    offsetX := 0, offsetY := Int.ofNat (pxToSub 10), blur := pxToSub 24, spread := 0, color := pal.shadowColor
  }
  let cardBg : Color := if req.light then 0xF6F6F4E2 else 0x1E1E1ED8
  let card : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withFixedSize cardW cardH
        |>.withBg cardBg
        |>.withRadius theme.radiusLg
        |>.withBorder theme.borderWidth pal.border
        |>.withShadow sh)
      [searchBar, divider, listBox, footer]
      (some paletteCardHitId)
  let scrim : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withAlign .center
        |>.withPadding (Edges.trbl topPad 0 0 0)
        |>.withFixedSize vpW vpH
        |>.withBg (if req.light then 0x00000024 else 0x00000048))
      [card]
  (theme, scrim)

/-- Format palette hit regions as newline-separated `"<idx> <x> <y> <w> <h>"` logical pixel lines. -/
def formatPaletteHits (scene : SceneOutput) : String :=
  let hits := scene.hitRegionsSub.filterMap fun (id, r) =>
    let p := roundRect 120 r
    if p.w > 0 && p.h > 0 then some s!"{id} {p.x} {p.y} {p.w} {p.h}" else none
  String.intercalate "\n" hits

/-- Headless Vulkan 1.3 device used to rasterize palette frames on the GPU. Created on the first
    palette paint; a failure disables it for the process and the CPU rasterizer takes over. -/
structure PaletteGpu where
  ctx : Option Vk.VkOffscreenReadback := none
  disabled : Bool := false
  /-- Accept a software ICD (lavapipe). Off in production, like the sidebar surface: a CPU
      Vulkan driver is slower than LeanUI's own CPU rasterizer. -/
  allowSoftware : Bool := false

/-- Rasterize `scene` on the GPU (`vkInstanced` offscreen + readback). `none` means use the CPU. -/
def paletteGpuRaster (gpuRef : IO.Ref PaletteGpu) (w h : Nat) (atlas : Text.GlyphAtlasCache)
    (scene : Scene) : IO (Option ByteArray) := do
  let gpu ← gpuRef.get
  if gpu.disabled then return none
  let ctx? ← match gpu.ctx with
    | some c => pure (some c)
    | none =>
      match ← (try Vk.createOffscreenReadback (allowSoftwareIcd := gpu.allowSoftware) catch e => pure (.error (toString e))) with
      | .ok c => pure (some c)
      | .error e =>
        IO.eprintln s!"orb-desktop: palette GPU unavailable, using CPU raster: {e}"
        pure none
  let some ctx := ctx? | gpuRef.set { gpu with disabled := true }; return none
  -- The palette device is not the sidebar's presenting device, so upload the atlas in full.
  match ← (try Vk.renderOffscreenInstanced ctx w h 0 atlas scene true catch e => pure (.error (toString e))) with
  | .ok (ctx', px) =>
    gpuRef.set { gpu with ctx := some ctx' }
    return some px
  | .error e =>
    IO.eprintln s!"orb-desktop: palette GPU frame failed, using CPU raster: {e}"
    try Vk.destroyOffscreenReadback ctx catch _ => pure ()
    gpuRef.set { gpu with ctx := none, disabled := true }
    return none

/-- The palette's static layer: scrim, card shadow and card background. Its blurred shadow is
    most of a CPU palette frame, yet it only changes with the window, theme or card height. -/
structure PaletteRasterCache where
  width : Nat := 0
  height : Nat := 0
  chromePrims : Scene := #[]
  chromeFb : ByteArray := ByteArray.empty
  /-- The framebuffer last returned was composed over this exact chrome, from `content`. -/
  composed : Bool := false
  content : Scene := #[]
  /-- Rectangle of the last frame that differs from the frame before it; `none` when unknown
      (the whole frame must be handed over). -/
  lastRegion : Option Rect := none
  chromeRenders : Nat := 0
  chromeResizes : Nat := 0
  contentRenders : Nat := 0

/-- The palette tree without the card's contents (same layout: the card has a fixed size). -/
partial def paletteChromeOnly : WidgetNode → WidgetNode
  | .mk id f h style payload children =>
    if id == some paletteCardHitId then .mk id f h style payload []
    else .mk id f h style payload (children.map paletteChromeOnly)

private def unionBounds (prims : Array Prim) : Option Rect :=
  prims.foldl (fun acc p => match p.bounds, acc with
    | none, _ => acc
    | some r, none => some r
    | some r, some a =>
      let x := min a.x r.x
      let y := min a.y r.y
      some ⟨x, y, max a.right r.right - x, max a.bottom r.bottom - y⟩) none

/-- Clip pushes still open after `prims`, innermost first (pops of earlier pushes stay as `none`). -/
private def openClips (prims : Array Prim) : List (Option Prim) :=
  prims.foldl (fun st p => match p with
    | .clipPush _ | .clipPushRounded _ _ => some p :: st
    | .clipPop => match st with | some _ :: rest => rest | rest => none :: rest
    | _ => st) []

/-- Region that differs between two content scenes: the bounds of everything between their common
    prefix and suffix. Prims whose clipping differs lie inside those ranges, so their bounds are
    covered; the unchanged suffix is safe when both ranges leave the same clips open. `none` when
    they do not, or when a range contains layering. -/
def contentDamage (old new : Scene) : Option (Option Rect) := Id.run do
  let n := min old.size new.size
  let mut pre := 0
  while pre < n && old[pre]? == new[pre]? do pre := pre + 1
  let mut suf := 0
  while suf < n - pre && old[old.size - 1 - suf]? == new[new.size - 1 - suf]? do suf := suf + 1
  let a := old.extract pre (old.size - suf)
  let b := new.extract pre (new.size - suf)
  if openClips a != openClips b then return none
  if (a ++ b).any fun p => match p with | .layerPush _ | .layerPop | .backdropBlur _ => true | _ => false then
    return none
  return some (unionBounds (a ++ b))

/-- The rect of a painted chrome prim whose height is `dh` larger in `b` than in `a`, everything
    else being equal; `some none` when the prims are identical; `none` otherwise. -/
private def grownRect (dh : Int) (a b : Prim) : Option (Option Rect) :=
  if a == b then some none else
  let grow (r : Rect) : Rect := { r with h := r.h + dh }
  match a, b with
  | .quad r f rad bw bc, .quad .. => if Prim.quad (grow r) f rad bw bc == b then some (some r) else none
  | .rrect r f radii bws bc, .rrect .. => if Prim.rrect (grow r) f radii bws bc == b then some (some r) else none
  | .shadow r c rad blur, .shadow .. => if Prim.shadow (grow r) c rad blur == b then some (some r) else none
  | _, _ => none

private def firstShadow (scene : Scene) : Option (Rect × Nat × Nat) :=
  scene.findSome? fun p => match p with
    | .shadow r _ rad blur => some (r, blur, rad)
    | _ => none

/-- Derive, in place, the chrome of a taller or shorter card from the cached chrome without
    re-blurring its shadow. Every grown prim is identical row by row farther than the shadow
    support (two blur radii plus the corner radius) from its top and bottom edges, so that middle
    band is resized and the rows below it shifted; below the ink and beside the shadow every row is
    plain scrim. Requires every other chrome prim to cover the whole viewport. Returns the frame and
    the rectangle that changed, or `none` unless the new chrome is the old one with only those
    heights changed. -/
def resizeChrome (w h : Nat) (oldChrome newChrome : Scene) (fb0 : ByteArray) : Option (ByteArray × Rect) := Id.run do
  let some (oldS, blur, rad) := firstShadow oldChrome | return none
  let some (newS, _, _) := firstShadow newChrome | return none
  let dh := newS.h - oldS.h
  if dh == 0 || oldChrome.size != newChrome.size || fb0.size != w * h * 4 then return none
  let mut grown : Array Rect := #[]
  for (a, b) in oldChrome.zip newChrome do
    match grownRect dh a b with
    | none => return none
    | some none =>
      match a.bounds with
      | some r => if !(r.x ≤ 0 && r.y ≤ 0 && r.right ≥ w && r.bottom ≥ h) then return none
      | none => return none
    | some (some r) => grown := grown.push r
  if grown.isEmpty then return none
  let m : Int := 2 * Int.ofNat blur + Int.ofNat rad + 4
  let ad : Int := if dh < 0 then -dh else dh
  let bandTop := grown.foldl (fun a r => max a r.y) 0 + m
  let oldBandBottom := grown.foldl (fun a r => min a r.bottom) (h : Int) - m
  let newBandBottom := oldBandBottom + dh
  let oldInk := grown.foldl (fun a r => max a r.bottom) 0 + m
  -- Rows at or below the old ink are plain scrim; the shrink path repeats one of them.
  let limit := min (h : Int) (max oldInk (oldInk + dh))
  let x0 := max 0 (grown.foldl (fun a r => min a r.x) (w : Int) - m)
  let x1 := min (w : Int) (grown.foldl (fun a r => max a r.right) 0 + m)
  if bandTop < 0 || bandTop ≥ min oldBandBottom newBandBottom || oldInk ≥ h || x1 ≤ x0 then return none
  let rowW := (x1 - x0).toNat * 4
  let off (y : Nat) : Nat := (y * w + x0.toNat) * 4
  let mid := fb0.extract (off bandTop.toNat) (off bandTop.toNat + rowW)
  let mut fb := fb0
  if dh > 0 then
    -- Grow: move rows down from the bottom up, then repeat the band row in the gap.
    let mut y := limit.toNat
    while y > newBandBottom.toNat do
      y := y - 1
      let src := (y - dh.toNat)
      fb := (fb.extract (off src) (off src + rowW)).copySlice 0 fb (off y) rowW
    for gy in [oldBandBottom.toNat : newBandBottom.toNat] do
      fb := mid.copySlice 0 fb (off gy) rowW
  else
    -- Shrink: move rows up from the top down; past the old ink they are the scrim row.
    let scrim := fb.extract (off oldInk.toNat) (off oldInk.toNat + rowW)
    for y in [newBandBottom.toNat : limit.toNat] do
      let src := y + ad.toNat
      let row := if src ≥ oldInk.toNat then scrim else fb.extract (off src) (off src + rowW)
      fb := row.copySlice 0 fb (off y) rowW
  let top := min oldBandBottom newBandBottom
  return some (fb, ⟨x0, top, x1 - x0, limit - top⟩)

private def unionRects (a b : Option Rect) : Option Rect :=
  match a, b with
  | none, r | r, none => r
  | some a, some b =>
    let x := min a.x b.x
    let y := min a.y b.y
    some ⟨x, y, max a.right b.right - x, max a.bottom b.bottom - y⟩

/-- CPU palette raster over a cached chrome layer. Starting from the previous frame when it was
    composed by this cache, only the region whose chrome or content changed is restored to chrome
    and repainted with the content prims, in scene order, so the result equals a full raster. -/
def paletteCpuRaster (cacheRef : IO.Ref PaletteRasterCache) (w h : Nat) (atlas : Text.GlyphAtlasCache)
    (chrome full : Scene) (previous : ByteArray)
    (renderChrome : Scene → IO ByteArray := fun sc => pure (Vulkan.rasterizeScene w h 0 atlas sc).1) :
    IO ByteArray := do
  let n := chrome.size
  -- Chrome must be a strict prefix of the scene; otherwise paint the whole frame.
  if full.size < n || full.extract 0 n != chrome then
    cacheRef.modify ({ · with composed := false, lastRegion := none })
    return (Vulkan.rasterizeScene w h 0 atlas full).1
  let content := full.extract n full.size
  -- Take the chrome out of the cache so an in-place resize does not copy it.
  let c0 ← cacheRef.modifyGet fun c => (c, { c with chromeFb := ByteArray.empty })
  let sameSize := c0.width == w && c0.height == h && c0.chromeFb.size == w * h * 4
  let prevOk := c0.composed && sameSize && previous.size == w * h * 4
  -- `some r`: chrome unchanged outside `r` (`r = none`: unchanged); `none`: repaint everything.
  let (c, chromeChange) ←
    if sameSize && c0.chromePrims == chrome then pure (c0, some none)
    else match (if sameSize then resizeChrome w h c0.chromePrims chrome c0.chromeFb else none) with
      | some (fb, r) => pure ({ c0 with chromePrims := chrome, chromeFb := fb, chromeResizes := c0.chromeResizes + 1 }, some (some r))
      | none =>
        let fb ← renderChrome chrome
        pure ({ c0 with width := w, height := h, chromePrims := chrome, chromeFb := fb, chromeRenders := c0.chromeRenders + 1 }, none)
  let contentChange : Option Rect :=
    match contentDamage c0.content content with
    | some r => r
    | none => unionBounds (c0.content ++ content)
  let (base, region?) := match chromeChange, prevOk with
    | some chromeR, true => (previous, unionRects chromeR contentChange)
    | _, _ => (c.chromeFb, unionBounds content)
  let vp : Rect := ⟨0, 0, w, h⟩
  let profile := (← IO.getEnv "ORB_PAL_PROFILE") == some "1"
  let t0 ← IO.monoNanosNow
  let mut fb := base
  let mut changed : Option Rect := none
  if let some r := region? then
    let d := intersectRect vp r
    changed := some d
    if !d.isEmpty then
      let x := d.x.toNat
      let rowBytes := d.w.toNat * 4
      for y in [d.y.toNat : d.bottom.toNat] do
        let off := (y * w + x) * 4
        fb := c.chromeFb.copySlice off fb off rowBytes
      let t1 ← IO.monoNanosNow
      fb := (Vulkan.rasterizeSceneInto w h 0 atlas (some fb) none
        (#[Prim.clipPush d] ++ content ++ #[Prim.clipPop])).1
      if profile then
        IO.eprintln s!"pal-raster prev={prevOk} chrome={match chromeChange with | some none => "same" | some _ => "resized" | none => "full"} d={d.w}x{d.h} restore_us={(t1 - t0) / 1000} raster_us={((← IO.monoNanosNow) - t1) / 1000}"
  -- Only a frame painted over the previous one has a known changed region.
  let lastRegion := match chromeChange, prevOk with
    | some _, true => some (changed.getD ⟨0, 0, 0, 0⟩)
    | _, _ => none
  cacheRef.set { c with composed := true, content, lastRegion, contentRenders := c.contentRenders + 1 }
  return fb

/-- Render one palette request through the LeanUI layout and scene pipeline, rasterized on the
    GPU when `gpu?` is available and by the CPU rasterizer otherwise (over the cached chrome
    layer when `raster?` is given). -/
def renderPaletteFrame (req : PaletteRequest) (ac0 : Text.GlyphAtlasCache) (fb0 : Vulkan.VulkanContext)
    (shape : Text.GlyphAtlasCache → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode))
    (gpu? : Option (IO.Ref PaletteGpu) := none) (raster? : Option (IO.Ref PaletteRasterCache) := none) :
    IO (String × Text.GlyphAtlasCache × Vulkan.VulkanContext) := do
  let sc := 120 * req.scale
  let (theme, root) := buildPaletteChrome req
  let (ac, tree) ← shape ac0.beginUploads sc root
  let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub req.width) (pxToSub req.height) tree.toLayoutNode
  let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
  let ac := ac.finishUploads
  let devW := req.width * req.scale
  let devH := req.height * req.scale
  if let some r := raster? then
    -- The static chrome (scrim, blurred shadow, card) goes to the GPU when one is available, the
    -- changing content is composited over it incrementally on the CPU.
    let renderChrome (prims : Scene) : IO ByteArray := do
      let gpuPx ← match gpu? with
        | some g => paletteGpuRaster g devW devH ac prims
        | none => pure none
      match gpuPx with
      | some px => if px.size == devW * devH * 4 then pure px else pure (Vulkan.rasterizeScene devW devH 0 ac prims).1
      | none => pure (Vulkan.rasterizeScene devW devH 0 ac prims).1
    let chromeTree := paletteChromeOnly tree
    let chromeBox := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub req.width) (pxToSub req.height) chromeTree.toLayoutNode
    let chrome := (buildSceneFromLayout sc {} theme chromeTree chromeBox (recordNodes := false)).prims
    -- Move the previous frame out of `fb0` so it is uniquely owned and painted in place.
    let previous := fb0.framebuffer
    let fb0 := { fb0 with framebuffer := ByteArray.empty, previousPaint := none }
    let px ← paletteCpuRaster r devW devH ac chrome scene.prims previous renderChrome
    return (formatPaletteHits scene, ac, { fb0 with width := devW, height := devH, framebuffer := px })
  let gpuPx ← match gpu? with
    | some g => paletteGpuRaster g devW devH ac scene.prims
    | none => pure none
  if let some px := gpuPx then
    if px.size == devW * devH * 4 then
      return (formatPaletteHits scene, ac, { fb0 with width := devW, height := devH, framebuffer := px, previousPaint := none })
  let next ← Vulkan.renderFrameDamage { fb0 with width := devW, height := devH }
    0 ac ⟨0, 0, 1, 1⟩ scene.prims
  return (formatPaletteHits scene, ac, next)

/-- Display-only columns. The GTK host keeps the original row identities and RPC targets. -/
private def projectedRow (line : String) : Option (ChromeSidebarRow × Bool) := do
  let [index, rid, kind, title, depth, status, shortcut, badge, selected, expanded, color] := line.splitOn "\t" | none
  let (key, role) := match rid, kind with
    | "nav:new-agent", _ => ("nav:new", kind)
    | "nav:providers", _ => ("nav:inference", kind)
    | "nav:cloud-agent", _ => ("nav:cloud", kind)
    | "nav:settings-back", _ => ("s:back", kind)
    | "settings:notifications", _ => ("s:notifs", "nav")
    | _, "settings-section" => ("s:" ++ (rid.drop 9).toString, "nav")
    | _, "project" => ("project:" ++ (rid.drop 5).toString, kind)
    | _, "archive" => ("section:archives", "section")
    | _, "note" => (rid, "empty")
    | _, _ => (rid, kind)
  let row : ChromeSidebarRow := {
    widgetId := ← index.toNat?, rowId := key, kind := role, title, depth := depth.toNat?.getD 0
    status, shortcut, badge := badge.toNat?.getD 0, selected := selected == "1"
    iconColor := (Orb.ProjectAppearance.rgb? color).map fun rgb => (rgb * 256 + 255).toUInt32 }
  return (row, expanded == "1")

private partial def scrollLimit (box : ComputedBox) : Nat :=
  if box.id == some rosterViewportId then (box.scrollLimitXY.map Prod.snd).getD 0
  else box.children.foldl (fun n b => max n (scrollLimit b)) 0

/-- How long the auto-hide sidebar scrollbar stays fully visible after the last scroll. -/
def scrollbarHoldMs : Nat := 600
/-- Length of the fade-out that follows the hold. -/
def scrollbarFadeMs : Nat := 180
/-- Frame pitch requested from the host while the thumb is fading. -/
def scrollbarFadeFrameMs : Nat := 16

/-- Auto-hide overlay scrollbar policy (macOS/Cursor style): hidden until the roster scrolls,
    fully visible for `scrollbarHoldMs` after the last movement, then a linear fade.
    Returns `(opacity 0..255, ms until the host must paint again; 0 = idle)`. -/
def scrollbarFade (sinceScrollMs : Option Nat) : Nat × Nat :=
  match sinceScrollMs with
  | none => (0, 0)
  | some t =>
    if t < scrollbarHoldMs then (255, scrollbarHoldMs - t)
    else if t < scrollbarHoldMs + scrollbarFadeMs then
      (255 * (scrollbarHoldMs + scrollbarFadeMs - t) / scrollbarFadeMs, scrollbarFadeFrameMs)
    else (0, 0)

/-- Set the roster viewport's scroll offset and thumb opacity without rebuilding its rows.
    Rows are focusable leaves of the roster, so the walk stops at them. -/
partial def withRosterScroll (offsetY : SubPx) (opacity : Nat) : WidgetNode → WidgetNode
  | node@(.mk id focusable hit style payload children) =>
    if id == some rosterViewportId then
      match payload with
      | .scrollClip sc =>
        .mk id focusable hit style
          (.scrollClip { sc with offsetY, showScrollbar := opacity > 0, scrollbarOpacity := opacity }) children
      | _ => node
    else if focusable then node
    else .mk id focusable hit style payload (children.map (withRosterScroll offsetY opacity))

/-- Shaping function supplied by the host binary (HarfBuzz/FreeType in production). -/
abbrev ShapeFn := Text.GlyphAtlasCache → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode)

/-- Shaped rows from the previous frame keyed by widget id, with the unshaped source they came from. -/
abbrev RowShapeMemo := Std.HashMap WidgetId (WidgetNode × WidgetNode)

/-- Shape `node`, reusing a previous frame's shaped row whenever its unshaped subtree is
    structurally identical (`BEq`). Only focusable rows are memoized; container shells above
    them are shaped without children and reassembled. Every row visited is written to the new
    memo, so rows that disappear are dropped. Counts `(reused, reshaped)` rows. -/
partial def shapeWithRowMemo (shape : ShapeFn) (old : RowShapeMemo) (sc : Nat) :
    WidgetNode → StateT (Text.GlyphAtlasCache × RowShapeMemo × Nat × Nat) IO WidgetNode
  | node@(.mk id focusable hit style payload children) => do
    if focusable then
      if let some wid := id then
        if let some (src, shaped) := old.get? wid then
          if src == node then
            modify fun (ac, memo, hits, misses) => (ac, memo.insert wid (src, shaped), hits + 1, misses)
            return shaped
        let (ac, memo, hits, misses) ← get
        let (ac', shaped) ← shape ac sc node
        set (ac', memo.insert wid (node, shaped), hits, misses + 1)
        return shaped
    let (ac, memo, hits, misses) ← get
    let (ac', shell) ← shape ac sc (.mk id focusable hit style payload [])
    set (ac', memo, hits, misses)
    let kids ← children.mapM (shapeWithRowMemo shape old sc)
    match shell with
    | .mk i f h st p _ => return .mk i f h st p kids

/-- Frame-to-frame state of the embedded sidebar renderer. GTK resends the whole row model on
    every paint; scroll-only and spinner-phase frames reuse the parsed rows, the shaped tree,
    and every unchanged shaped row instead of re-parsing and re-shaping them. -/
structure EmbeddedSidebarCache where
  /-- Disable to measure or fall back to the uncached pipeline. -/
  enabled : Bool := true
  /-- Raw row lines (everything after the header) and their parse. -/
  body : List String := []
  rows : List ChromeSidebarRow := []
  expanded : List ChromeSidebarRow := []
  /-- Inputs that, with `body` and the spinner phase, determine the tree up to scroll:
      `(w, h, scale, light)`. -/
  treeKey : Nat × Nat × Nat × Bool := (0, 0, 0, false)
  /-- Shaped trees for `treeKey` and `body` by spinner phase (at most 12, the spinner period),
      valid for `atlasGen` at `scale`. Scroll and spinner frames after the first cycle reuse one. -/
  shapedPhases : List (Nat × WidgetNode) := []
  atlasGen : UInt64 := 0
  memoScale : Nat := 0
  rowMemo : RowShapeMemo := {}
  /-- Last roster offset and the monotonic time it last changed (auto-hide scrollbar). -/
  lastOffset : Nat := 0
  lastScrollMs : Option Nat := none
  /-- Counters for tests and `--bench-embedded`. -/
  parses : Nat := 0
  treeReuses : Nat := 0
  rowReuses : Nat := 0
  rowShapes : Nat := 0
  deriving Inhabited

/-- One prepared embedded-sidebar frame: everything up to the rasterizer / `renderAndPresentGpu`. -/
structure SidebarFrame where
  theme : Theme
  scene : SceneOutput
  hitPayload : String
  devW : Nat
  devH : Nat
  wlDisplay : USize
  wlSurface : USize
  deriving Inhabited

/-- Parse the sidebar request and build its scene, consulting and updating `cacheRef`.
    `nowMs` drives the auto-hide scrollbar; callers pass `IO.monoMsNow`. -/
def prepareSidebarFrame (request : String) (atlas : IO.Ref Text.GlyphAtlasCache)
    (cacheRef : IO.Ref EmbeddedSidebarCache) (shape : ShapeFn) (nowMs : Nat) : IO SidebarFrame := do
  let header :: body := request.splitOn "\n" | throw (IO.userError "missing sidebar allocation")
  let (w, h, scale, light, offset, phase, wlDisplay, wlSurface) ←
    match header.splitOn "\t" with
    | [w, h, scale, light, offset, phase] => pure (w, h, scale, light, offset, phase, (0 : USize), (0 : USize))
    | [w, h, scale, light, offset, phase, wd, ws] =>
      pure (w, h, scale, light, offset, phase,
        (wd.toNat?.getD 0).toUSize, (ws.toNat?.getD 0).toUSize)
    | _ => throw (IO.userError "invalid sidebar allocation")
  let width := w.toNat?.getD 0
  let height := h.toNat?.getD 0
  let factor := scale.toNat?.getD 1
  let sc := 120 * factor
  let offsetPx := offset.toNat?.getD 0
  let isLight := light == "1"
  let phaseN := phase.toNat?.getD 0
  let c0 ← cacheRef.get
  -- A disabled cache still tracks scroll history (the scrollbar fade) but never reuses work.
  let c0 := if c0.enabled then c0 else { c0 with parses := 0, shapedPhases := [], rowMemo := {} }
  -- Rows are display-only and re-sent verbatim; parse them only when they change.
  let bodySame := c0.enabled && c0.parses > 0 && c0.body == body
  let (c1, rows, expanded) :=
    if bodySame then (c0, c0.rows, c0.expanded)
    else
      let projected := body.filterMap projectedRow
      let rows := projected.map Prod.fst
      let expanded := (projected.filter Prod.snd).map Prod.fst
      ({ c0 with body, rows, expanded, parses := c0.parses + 1 }, rows, expanded)
  -- Auto-hide scrollbar: any change of roster offset (wheel, kinetic, clamp) counts as scrolling.
  let lastScrollMs := if offsetPx != c1.lastOffset then some nowMs else c1.lastScrollMs
  let (opacity, wakeMs) := scrollbarFade (lastScrollMs.map (nowMs - ·))
  let theme := Theme.withWindowEffects (if isLight then orbLightTheme else orbDarkTheme)
  let key := (width, height, factor, isLight)
  let ac0 := (← atlas.get).beginUploads
  let sameAtlas := c1.atlasGen == ac0.generation && c1.memoScale == sc
  let treesValid := c1.enabled && sameAtlas && bodySame && c1.treeKey == key
  let cachedTree := if treesValid then c1.shapedPhases.lookup phaseN else none
  let (ac, tree, c2) ← do
    if let some cached := cachedTree then
      -- Same rows, geometry and spinner phase: identical tree up to the viewport offset.
      pure (ac0, cached, { c1 with treeReuses := c1.treeReuses + 1 })
    else
      let st := { DesktopState.liveUnavailable with
        theme, sidebarRows := rows
        screen := if rows.any (·.rowId == "s:back") then .settingsGeneral else .controlEmpty
        rosterTopSub := 0, badgePhase := phaseN
        archivesOpen := expanded.any (·.rowId == "section:archives")
        expandedProjects := expanded.filterMap (fun r => if r.kind == "project" then some (r.rowId.drop 8).toString else none)
        expandedMissions := expanded.map (·.rowId) }
      let root := buildSidebarChrome st (pxToSub height) (width := pxToSub width) (embedded := true)
      if !c1.enabled then
        let (ac, tree) ← shape ac0 sc root
        pure (ac, tree, c1)
      else
        -- A new row model may drop widget ids; start a fresh memo then so it never grows.
        let old := if sameAtlas then c1.rowMemo else {}
        let (tree, (ac, memo, reused, reshaped)) ← (shapeWithRowMemo shape old sc root).run (ac0, {}, 0, 0)
        -- An atlas reset mid-frame invalidates every UV reused above: reshape from scratch.
        let (ac, tree, memo, reused, reshaped) ←
          if ac.generation != ac0.generation then do
            let (t, (ac', memo', n', m')) ← (shapeWithRowMemo shape {} sc root).run (ac, {}, 0, 0)
            pure (ac', t, memo', n', m')
          else pure (ac, tree, memo, reused, reshaped)
        let phases := if treesValid && ac.generation == ac0.generation then (c1.shapedPhases.take 11) else []
        pure (ac, tree, { c1 with
          treeKey := key, shapedPhases := (phaseN, tree) :: phases, atlasGen := ac.generation, memoScale := sc, rowMemo := memo
          rowReuses := c1.rowReuses + reused, rowShapes := c1.rowShapes + reshaped })
  let tree := withRosterScroll (pxToSub offsetPx) opacity tree
  let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub width) (pxToSub height) tree.toLayoutNode
  let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
  atlas.set ac.finishUploads
  cacheRef.set { c2 with lastOffset := offsetPx, lastScrollMs }
  let hits := scene.hitRegionsSub.filterMap fun (id, r) =>
    if id == rosterViewportId then none else
      let p := roundRect 120 r
      some s!"{id} {p.x} {p.y} {p.w} {p.h}"
  -- First line: `<scroll limit px> <ms until the next paint is needed>` (GTK reads both).
  let limitLine := s!"{scrollLimit box / subPerPx} {wakeMs}"
  return { theme, scene, hitPayload := String.intercalate "\n" (limitLine :: hits)
           devW := width * factor, devH := height * factor, wlDisplay, wlSurface }

/-- A palette frame that hands over only `d`: the hit payload is prefixed with
    `"\x01<stride> <x> <y> <w> <h>\n"` and the pixels are the RGBA rows of `d`. -/
def paletteRegionFrame (stride : Nat) (hits : String) (fb : ByteArray) (d : Rect) : String × ByteArray := Id.run do
  let x := d.x.toNat
  let w := d.w.toNat
  let mut out := ByteArray.emptyWithCapacity (w * d.h.toNat * 4)
  for y in [d.y.toNat : d.bottom.toNat] do
    out := fb.copySlice ((y * stride + x) * 4) out out.size (w * 4)
  return (s!"\x01{stride} {x} {d.y.toNat} {w} {d.h.toNat}\n" ++ hits, out)

/-- Present `prims` on the Wayland surface `wlSurface` through the Vulkan session kept in
    `gpuRef`, created (or replaced) when the surface changes. `none` when the GPU cannot serve
    this surface and the caller must paint on the CPU; otherwise whether a frame was presented
    (`false`: the swapchain skipped or is being recreated, retry). -/
def presentEmbeddedGpu (gpuRef : IO.Ref (USize × Vulkan.VulkanContext)) (atlas : IO.Ref Text.GlyphAtlasCache)
    (devW devH : Nat) (wlDisplay wlSurface : USize) (clearColor : Color) (prims : Scene) : IO (Option Bool) := do
  let (curSurf, curCtx) ← gpuRef.modifyGet fun p => (p, (0, {}))
  let vkCtx ←
    if curSurf == wlSurface && curCtx.gpuSession.isSome then
      pure { curCtx with width := devW, height := devH }
    else
      if curCtx.gpuSession.isSome then Vulkan.shutdownVulkan curCtx
      Vulkan.initVulkanSurface devW devH wlDisplay wlSurface
  if vkCtx.backend == .cpuShm || vkCtx.gpuSession.isNone then
    if vkCtx.gpuSession.isSome then Vulkan.shutdownVulkan vkCtx
    return none
  let (vkCtx', ac', handled, didPresent) ←
    Vulkan.renderAndPresentGpu vkCtx clearColor (← atlas.get) prims none (pure ()) (pure ())
  atlas.set ac'
  if !handled then
    if vkCtx'.gpuSession.isSome then Vulkan.shutdownVulkan vkCtx'
    return none
  gpuRef.set (wlSurface, vkCtx')
  return some didPresent

/-- Shut down the Vulkan session in `gpuRef` when it presents to `wlSurface` (any surface when
    `wlSurface = 0`). Returns whether a session was released. -/
def detachEmbeddedGpu (gpuRef : IO.Ref (USize × Vulkan.VulkanContext)) (wlSurface : USize) : IO Bool := do
  let (cur, ctx) ← gpuRef.get
  if wlSurface != 0 && cur != wlSurface then return false
  gpuRef.set (0, {})
  if ctx.gpuSession.isSome then Vulkan.shutdownVulkan ctx
  return true

/-- Shape, lay out and lower one palette request (no rasterization). -/
def buildPaletteScene (req : PaletteRequest) (ac0 : Text.GlyphAtlasCache) (shape : ShapeFn) :
    IO (Text.GlyphAtlasCache × SceneOutput) := do
  let sc := 120 * req.scale
  let (theme, root) := buildPaletteChrome req
  let (ac, tree) ← shape ac0.beginUploads sc root
  let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub req.width) (pxToSub req.height) tree.toLayoutNode
  return (ac.finishUploads, buildSceneFromLayout sc {} theme tree box (recordNodes := false))

/-- Clear color for embedded sidebar surfaces (both Vulkan subsurface and CPU fallback).
    `buildSidebarChrome` paints a full-bleed `pal.sidebar` root rect, so clearing to transparent
    avoids double-compositing the frosted sidebar alpha (e.g. 0.78 over 0.78 -> 0.95). -/
def sidebarClearColor : Color := 0

/-- Dispatch one embedded paint request, routing `"P\t"` exclusively to the palette pipeline
    and `"D\t"` to GPU surface teardown so malformed headers never fall through or clobber state. -/
def dispatchEmbeddedRequest (request : String)
    (atlas : IO.Ref Text.GlyphAtlasCache)
    (framebuffer : IO.Ref Vulkan.VulkanContext)
    (paletteFramebuffer : IO.Ref Vulkan.VulkanContext)
    (sidebarCache : IO.Ref EmbeddedSidebarCache)
    (shape : ShapeFn)
    (gpuSurface? : Option (IO.Ref (USize × Vulkan.VulkanContext)) := none)
    (paletteGpu? : Option (IO.Ref PaletteGpu) := none)
    (paletteRaster? : Option (IO.Ref PaletteRasterCache) := none)
    (paletteSurface? : Option (IO.Ref (USize × Vulkan.VulkanContext)) := none)
    (paletteAtlas? : Option (IO.Ref Text.GlyphAtlasCache) := none) :
    IO (String × ByteArray) := do
  if request.startsWith "D\t" then
    -- Release the session presenting to that surface: the palette's, else the sidebar's.
    let surf := ((request.drop 2).toString.toNat?.getD 0).toUSize
    let palette ← match paletteSurface? with
      | some r => if surf != 0 then detachEmbeddedGpu r surf else pure false
      | none => pure false
    if !palette then
      if let some gpuRef := gpuSurface? then discard <| detachEmbeddedGpu gpuRef 0
    return ("GPU_DETACHED", ByteArray.empty)
  -- `S\n`: the query text in the palette search input is selected via Cmd/Ctrl+A.
  let selectedAll := request.startsWith "S\n"
  let request := if selectedAll then (request.drop 2).toString else request
  -- `G\t<display>\t<surface>\n`: the palette host offers a Wayland subsurface for Vulkan.
  let (gpuTarget, request) :=
    if request.startsWith "G\t" then
      match request.splitOn "\n" with
      | first :: rest =>
        match first.splitOn "\t" with
        | [_, d, w] => (some ((d.toNat?.getD 0).toUSize, (w.toNat?.getD 0).toUSize), String.intercalate "\n" rest)
        | _ => (none, String.intercalate "\n" rest)
      | [] => (none, request)
    else (none, request)
  -- `F`: the host's surface is new, so it needs a whole frame rather than the changed region.
  let freshSurface := request.startsWith "FP\t"
  let request := if freshSurface then (request.drop 1).toString else request
  if request.startsWith "P\t" then
    let some palReq := parsePaletteRequest? request
      | throw (IO.userError "invalid palette allocation")
    let palReq := { palReq with selectedAll }
    let atlas := paletteAtlas?.getD atlas
    if let (some (wd, ws), some surfRef) := (gpuTarget, paletteSurface?) then
      if wd != 0 && ws != 0 then
        -- The palette on its own Vulkan subsurface, above the window: no CPU raster or copy.
        let t0 ← IO.monoNanosNow
        let (ac, scene) ← buildPaletteScene palReq (← atlas.get) shape
        atlas.set ac
        let t1 ← IO.monoNanosNow
        let presented ← presentEmbeddedGpu surfRef atlas (palReq.width * palReq.scale) (palReq.height * palReq.scale)
            wd ws 0 scene.prims
        if (← IO.getEnv "ORB_PAL_PROFILE") == some "1" then
          IO.eprintln s!"pal-gpu scene_us={(t1 - t0) / 1000} present_us={((← IO.monoNanosNow) - t1) / 1000} prims={scene.prims.size}"
        match presented with
        | none => return ("GPU_FALLBACK", ByteArray.empty)
        | some false => return ("GPU_SKIP", ByteArray.empty)
        | some true => return ("GPU_OK\n" ++ formatPaletteHits scene, ByteArray.empty)
    let palCtx ← paletteFramebuffer.modifyGet fun c => (c, { c with framebuffer := ByteArray.empty, previousPaint := none })
    if let some r := paletteRaster? then r.modify ({ · with lastRegion := none })
    let (hits, ac, next) ← renderPaletteFrame palReq (← atlas.get) palCtx shape paletteGpu? paletteRaster?
    paletteFramebuffer.set next
    atlas.set ac
    let region ← match paletteRaster? with
      | some r => pure (← r.get).lastRegion
      | none => pure none
    match region, freshSurface with
    | some d, false => return paletteRegionFrame next.width hits next.framebuffer d
    | _, _ => return (hits, next.framebuffer)
  let frame ← prepareSidebarFrame request atlas sidebarCache shape (← IO.monoMsNow)
  let { scene, hitPayload, devW, devH, wlDisplay, wlSurface, .. } := frame
  if wlDisplay != 0 && wlSurface != 0 then
    if let some gpuRef := gpuSurface? then
      match ← presentEmbeddedGpu gpuRef atlas devW devH wlDisplay wlSurface sidebarClearColor scene.prims with
      | none => return ("GPU_FALLBACK", ByteArray.empty)
      | some false => return ("GPU_SKIP", ByteArray.empty)
      | some true => return ("GPU_OK\n" ++ hitPayload, ByteArray.empty)
  let ctx ← framebuffer.modifyGet fun c => (c, { c with framebuffer := ByteArray.empty, previousPaint := none })
  let next ← Vulkan.renderFrameDamage { ctx with width := devW, height := devH }
    sidebarClearColor (← atlas.get) ⟨0, 0, 1, 1⟩ scene.prims
  framebuffer.set next
  return (hitPayload, next.framebuffer)

/-- Paint the same widget tree used by the Wayland shell at the GTK allocation and device scale.
    Input regions are returned from this exact layout. There is no Core connection in the renderer. -/
def runEmbeddedSidebar (modulePath : String)
    (shape : Text.GlyphAtlasCache → Text.FontHandle → Text.FontHandle → Text.FontHandle →
      Text.FontHandle → Text.FontHandle → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode)) : IO UInt32 := do
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  let atlas ← IO.mkRef rt.atlas
  let framebuffer ← IO.mkRef rt.vulkan
  let paletteFramebuffer ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
  let gpuSurface ← IO.mkRef ((0 : USize), ({} : Vulkan.VulkanContext))
  let sidebarCache ← IO.mkRef ({} : EmbeddedSidebarCache)
  -- Same policy as the sidebar surface: `ORB_LEANUI_GPU=0` keeps the palette on the CPU
  -- rasterizer and `ORB_LEANUI_GPU=lavapipe` admits a software ICD.
  let gpuMode ← Vulkan.resolveGpuMode .auto
  let paletteGpu ← IO.mkRef ({ disabled := gpuMode == .disabled, allowSoftware := gpuMode == .lavapipe } : PaletteGpu)
  let paletteRaster ← IO.mkRef ({} : PaletteRasterCache)
  -- The palette's own subsurface session and glyph atlas: two Vulkan devices must not share
  -- one atlas's pending GPU uploads.
  let paletteSurface ← IO.mkRef ((0 : USize), ({} : Vulkan.VulkanContext))
  let paletteAtlas ← IO.mkRef rt.atlas
  try
    FFI.sidebarHost modulePath fun request =>
      dispatchEmbeddedRequest request atlas framebuffer paletteFramebuffer sidebarCache (fun a sc node =>
        shape a rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc node) (some gpuSurface)
        (some paletteGpu) (some paletteRaster) (some paletteSurface) (some paletteAtlas)
  finally
    discard <| detachEmbeddedGpu gpuSurface 0
    discard <| detachEmbeddedGpu paletteSurface 0
    if let some pctx := (← paletteGpu.get).ctx then Vk.destroyOffscreenReadback pctx
    Runtime.shutdownRuntime rt

private def paletteIdentityShape (ac : Text.GlyphAtlasCache) (_sc : Nat) (node : WidgetNode) :
    IO (Text.GlyphAtlasCache × WidgetNode) :=
  pure (ac, node)

private def paletteHasNonZeroPixel (fb : ByteArray) : Bool := Id.run do
  for i in [:fb.size] do
    if fb.get! i != 0 then return true
  return false

private def paletteParseHitLine (line : String) : Option (Nat × Int × Int × Int × Int) := do
  let [idS, xS, yS, wS, hS] := line.splitOn " " | none
  let id ← idS.toNat?
  let x ← xS.toInt?
  let y ← yS.toInt?
  let w ← wS.toInt?
  let h ← hS.toInt?
  return (id, x, y, w, h)

/-- End-to-end embedded palette self-test (wired into `OrbDesktop --self-test` and standalone test). -/
def embeddedPaletteSelfTest : IO Unit := do
  -- 1. Legacy sidebar requests must NOT be parsed as palette requests.
  let sidebarReq := "220\t700\t1\t0\t0\t0\n1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t"
  unless (parsePaletteRequest? sidebarReq).isNone do
    throw (IO.userError "legacy sidebar request misclassified as palette request")

  -- 2. Bounds enforcement on width, height, scale, and widgetId.
  for bad in [
    "P\t0\t600\t1\t0\t0\t",
    "P\t800\t0\t1\t0\t0\t",
    "P\t16385\t600\t1\t0\t0\t",
    "P\t800\t16385\t1\t0\t0\t",
    "P\t800\t600\t0\t0\t0\t",
    "P\t800\t600\t9\t0\t0\t",
    "P\t800\t600\tbad\t0\t0\t",
    "P\t220\t700\t1\t0\t0"
  ] do
    unless (parsePaletteRequest? bad).isNone do
      throw (IO.userError s!"invalid palette header accepted: {bad}")
  unless (parsePaletteRequest? "P\t1\t1\t1\t0\t0\t").isSome &&
      (parsePaletteRequest? "P\t16384\t16384\t8\t1\t0\tq").isSome do
    throw (IO.userError "valid boundary palette header rejected")
  unless (parsePaletteItem? s!"{paletteCardHitId}\tm:bad\tmission\tBad\t\t\t\t").isNone &&
      (parsePaletteItem? s!"{paletteCardHitId + 1}\tm:bad\tmission\tBad\t\t\t\t").isNone &&
      (parsePaletteItem? s!"{paletteCardHitId - 1}\tm:ok\tmission\tOk\t\t\t\t").isSome do
    throw (IO.userError "palette item widgetId bound check failed")

  -- 3. Populated palette request parsing with project colors.
  let populatedReq := String.intercalate "\n" [
    "P\t900\t620\t1\t0\t1\tcop",
    "0\tm:aaa\tmission\tCopper\torchard · awaiting_user\tawaiting_user\t\t",
    "1\tnav:machines\tnav\tMachines\tFleet nodes & managed VMs\t\t⌘3\t",
    "2\tproj:orchard\tproject\tOrchard\tProject · orchard\t\t\tblue",
    "3\tproj:plain\tproject\tPlain\tProject · plain\t\t\t",
    "4\tsettings:models\tsettings\tModels\tSettings · Models\t\t\t"
  ]
  let some parsed := parsePaletteRequest? populatedReq
    | throw (IO.userError "failed to parse populated palette request")
  unless parsed.width == 900 && parsed.height == 620 && parsed.scale == 1 &&
      !parsed.light && parsed.selectedIdx == 1 && parsed.query == "cop" && parsed.items.length == 5 do
    throw (IO.userError s!"unexpected parsed palette request: {repr parsed}")
  let pal := orbDarkTheme.palette
  let some blueProj := parsed.items.find? (·.itemId == "proj:orchard")
    | throw (IO.userError "missing proj:orchard")
  let some plainProj := parsed.items.find? (·.itemId == "proj:plain")
    | throw (IO.userError "missing proj:plain")
  unless paletteIconColor pal blueProj == (0x8aaed4 * 256 + 255).toUInt32 &&
      paletteIconColor pal plainProj == pal.textSecondary do
    throw (IO.userError "project palette icon color mismatch")

  -- 4. Full render pipeline: dark/light, populated/empty, HiDPI scale=2 invariance,
  --    monotone availListPx across height=210..211, scrolled selection, OOB clamp, and malformed "P\t" routing.
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  try
    let atlasRef ← IO.mkRef rt.atlas
    let sbFbRef ← IO.mkRef { rt.vulkan with framebuffer := ByteArray.mk #[1, 2, 3, 4] }
    let palFbRef ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
    let sbCache ← IO.mkRef ({} : EmbeddedSidebarCache)

    -- 4a. Malformed "P\t" (even with 6 tab fields matching sidebar!) must fail without touching sidebar framebuffer.
    let mut threwMalformed := false
    try
      discard <| dispatchEmbeddedRequest "P\t220\t700\t1\t0\t0" atlasRef sbFbRef palFbRef sbCache paletteIdentityShape
    catch _ =>
      threwMalformed := true
    let sbAfter := (← sbFbRef.get).framebuffer
    unless threwMalformed && sbAfter == ByteArray.mk #[1, 2, 3, 4] do
      throw (IO.userError "malformed P\\t request fell through or clobbered sidebar framebuffer")

    -- 4a2. GPU detach ("D\t...") returns GPU_DETACHED cleanly without touching sidebar framebuffer.
    let gpuRef ← IO.mkRef ((0 : USize), ({} : Vulkan.VulkanContext))
    let (detRes, detPx) ← dispatchEmbeddedRequest "D\t12345" atlasRef sbFbRef palFbRef sbCache paletteIdentityShape (some gpuRef)
    unless detRes == "GPU_DETACHED" && detPx.isEmpty && (← sbFbRef.get).framebuffer == ByteArray.mk #[1, 2, 3, 4] do
      throw (IO.userError s!"unexpected GPU detach response: {detRes}")
    -- 4a2b. "D\t<surface>" releases only the session presenting to that surface.
    let palSurf ← IO.mkRef ((42 : USize), ({} : Vulkan.VulkanContext))
    let sideSurf ← IO.mkRef ((7 : USize), ({} : Vulkan.VulkanContext))
    discard <| dispatchEmbeddedRequest "D\t42" atlasRef sbFbRef palFbRef sbCache paletteIdentityShape
      (some sideSurf) none none (some palSurf)
    unless (← palSurf.get).1 == 0 && (← sideSurf.get).1 == 7 do
      throw (IO.userError "palette detach released the wrong Vulkan session")
    -- 4a2c. A palette request offering no usable surface ("G\t0\t0") paints on the CPU as before.
    let palFbA ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
    let palFbB ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
    let plainReq := "P\t320\t240\t1\t0\t0\tm\n0\tm:a\tmission\tA\tp\trunning\t\t"
    let (hitsA, pxA) ← dispatchEmbeddedRequest plainReq atlasRef sbFbRef palFbA sbCache paletteIdentityShape
    let (hitsB, pxB) ← dispatchEmbeddedRequest ("G\t0\t0\n" ++ plainReq) atlasRef sbFbRef palFbB sbCache paletteIdentityShape
      none none none (some palSurf)
    unless hitsA == hitsB && pxA == pxB && pxA.size == 320 * 240 * 4 do
      throw (IO.userError "palette request with an unusable GPU surface changed the CPU frame")
    -- 4a3. 8-field sidebar header with wlDisplay=0, wlSurface=0 falls through to CPU buffer.
    let (sb8Hits, sb8Px) ← dispatchEmbeddedRequest
      "220\t200\t1\t0\t0\t0\t0\t0\n1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t"
      atlasRef sbFbRef palFbRef sbCache paletteIdentityShape (some gpuRef)
    unless sb8Px.size == 220 * 200 * 4 && !sb8Hits.isEmpty do
      throw (IO.userError s!"8-field CPU fallback failed: px={sb8Px.size}")
    -- 4a4. Sidebar clear color must stay transparent so GPU and CPU paths preserve the frosted
    --      sidebar alpha (199 dark / 184 light) without double-compositing `pal.sidebar`.
    unless sidebarClearColor == 0 do
      throw (IO.userError s!"sidebarClearColor must be 0, got {sidebarClearColor}")
    for (lightFlag, expectedAlpha) in [(0, (199 : UInt8)), (1, (184 : UInt8))] do
      let (_, px) ← dispatchEmbeddedRequest
        s!"220\t200\t1\t{lightFlag}\t0\t0\n1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t"
        atlasRef sbFbRef palFbRef sbCache paletteIdentityShape (some gpuRef)
      let alpha := px.get! 3
      unless alpha == expectedAlpha do
        throw (IO.userError s!"sidebar background alpha mismatch (light={lightFlag}): got {alpha}, expected {expectedAlpha}")

    let mut ac ← atlasRef.get
    let mut fb := rt.vulkan
    for light in [false, true] do
      for empty in [false, true] do
        let reqStr :=
          if empty then
            s!"P\t800\t560\t1\t{if light then 1 else 0}\t0\tzzz_no_match\n"
          else
            String.intercalate "\n" [
              s!"P\t800\t560\t1\t{if light then 1 else 0}\t1\torc",
              "0\tm:aaa\tmission\tCopper\torchard · running\trunning\t\t",
              "1\tnav:machines\tnav\tMachines\tFleet nodes & managed VMs\t\t⌘3\t",
              "2\tproj:orchard\tproject\tOrchard\tProject · orchard\t\t\tgreen"
            ]
        let some req := parsePaletteRequest? reqStr
          | throw (IO.userError "failed to parse palette variant")
        let (hitsStr, nextAc, nextFb) ← renderPaletteFrame req ac fb paletteIdentityShape
        ac := nextAc
        fb := nextFb
        let expectedBytes := req.width * req.height * 4
        unless fb.framebuffer.size == expectedBytes do
          throw (IO.userError s!"framebuffer size mismatch: {fb.framebuffer.size} vs {expectedBytes}")
        unless paletteHasNonZeroPixel fb.framebuffer do
          throw (IO.userError s!"blank framebuffer for light={light} empty={empty}")
        let parsedHits := (hitsStr.splitOn "\n").filterMap paletteParseHitLine
        let some (_, cx, cy, cw, ch) := parsedHits.find? (·.1 == paletteCardHitId)
          | throw (IO.userError s!"missing palette card hit region in: {hitsStr}")
        unless cw > 200 && ch > 100 && cx >= 0 && cy >= 0 do
          throw (IO.userError s!"invalid palette card bounds: {cx},{cy} {cw}x{ch}")
        if empty then
          unless parsedHits.length == 1 do
            throw (IO.userError s!"expected only card hit region for empty palette, got {parsedHits.length}")
        else
          for idx in [0, 1, 2] do
            let some (_, rx, ry, rw, rh) := parsedHits.find? (·.1 == idx)
              | throw (IO.userError s!"missing hit region for item {idx} in: {hitsStr}")
            unless rw > 100 && rh >= 36 && rx >= cx && rx + rw <= cx + cw && ry >= cy && ry + rh <= cy + ch do
              throw (IO.userError s!"item {idx} bounds outside card: {rx},{ry} {rw}x{rh}")

    -- 4b. HiDPI scale=2: framebuffer scales 2x in each axis while logical hit regions remain invariant.
    let hidpiItems := [
      "0\tm:aaa\tmission\tCopper\torchard · running\trunning\t\t",
      "1\tproj:orchard\tproject\tOrchard\tProject · orchard\t\t\tamber"
    ]
    let some req1x := parsePaletteRequest? (String.intercalate "\n" ("P\t600\t420\t1\t0\t0\torc" :: hidpiItems))
      | throw (IO.userError "failed to parse 1x hidpi request")
    let some req2x := parsePaletteRequest? (String.intercalate "\n" ("P\t600\t420\t2\t0\t0\torc" :: hidpiItems))
      | throw (IO.userError "failed to parse 2x hidpi request")
    let (hits1x, ac1, fb1) ← renderPaletteFrame req1x ac fb paletteIdentityShape
    let (hits2x, ac2, fb2) ← renderPaletteFrame req2x ac1 fb1 paletteIdentityShape
    ac := ac2
    fb := fb2
    unless fb1.framebuffer.size == 600 * 420 * 4 &&
        fb2.framebuffer.size == (600 * 2) * (420 * 2) * 4 &&
        paletteHasNonZeroPixel fb2.framebuffer do
      throw (IO.userError s!"HiDPI scale=2 framebuffer mismatch: 1x={fb1.framebuffer.size} 2x={fb2.framebuffer.size}")
    unless hits1x == hits2x do
      throw (IO.userError s!"HiDPI logical hit regions diverged:\n1x:\n{hits1x}\n2x:\n{hits2x}")

    -- 4c. Monotone availListPx: visible item count must never drop as height increases (esp. 210 -> 211).
    let manyLines := (List.range 16).map fun i =>
      s!"{i}\tm:id{i}\tmission\tMission {i}\tproj · completed\tcompleted\t\t"
    let mut prevCount := 0
    for h in [180, 210, 211, 260, 340, 520] do
      let some hReq := parsePaletteRequest? (String.intercalate "\n" (s!"P\t600\t{h}\t1\t0\t0\tm" :: manyLines))
        | throw (IO.userError s!"failed to parse monotone height={h} request")
      let (hHits, acN, fbN) ← renderPaletteFrame hReq ac fb paletteIdentityShape
      ac := acN
      fb := fbN
      let itemHits := ((hHits.splitOn "\n").filterMap paletteParseHitLine).filter (·.1 != paletteCardHitId)
      unless itemHits.length >= prevCount do
        throw (IO.userError s!"non-monotone visible palette rows at height={h}: {itemHits.length} < {prevCount}")
      prevCount := itemHits.length

    -- 4d. Scrolled selection windowing preserves true item widget IDs (> maxVisible).
    let scrolledReqStr := String.intercalate "\n" ("P\t800\t520\t1\t0\t14\tmission" :: manyLines)
    let some scrolledReq := parsePaletteRequest? scrolledReqStr
      | throw (IO.userError "failed to parse scrolled palette request")
    let (hitsStr, acS, nextFb) ← renderPaletteFrame scrolledReq ac fb paletteIdentityShape
    let parsedHits := (hitsStr.splitOn "\n").filterMap paletteParseHitLine
    unless paletteHasNonZeroPixel nextFb.framebuffer && parsedHits.any (·.1 == 14) do
      throw (IO.userError s!"scrolled selection id 14 missing from hits: {hitsStr}")

    -- 4e. Out-of-range selectedIdx clamps safely instead of hiding visible items.
    let oobReqStr := "P\t800\t520\t1\t0\t99\tcop\n0\tm:aaa\tmission\tCopper\torchard · running\trunning\t\t"
    let some oobReq := parsePaletteRequest? oobReqStr
      | throw (IO.userError "failed to parse oob palette request")
    let (oobHitsStr, _, oobFb) ← renderPaletteFrame oobReq acS nextFb paletteIdentityShape
    let oobHits := (oobHitsStr.splitOn "\n").filterMap paletteParseHitLine
    unless paletteHasNonZeroPixel oobFb.framebuffer && oobHits.any (·.1 == 0) do
      throw (IO.userError s!"oob selectedIdx dropped visible item 0: {oobHitsStr}")

    -- 4f. The cached-chrome CPU raster is byte-identical to a full raster across selection moves,
    --     typing (result count and card height change), a theme switch, no results and a resize.
    let rc ← IO.mkRef ({} : PaletteRasterCache)
    let mut incFb := { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
    let mut acI := acS
    let seq : List (Nat × Nat × Bool × Nat × String) :=
      [(800, 700, false, 0, "m"), (800, 700, false, 1, "m"), (800, 700, false, 2, "m"), (800, 700, false, 2, "mi"),
       (800, 700, false, 0, "mis"), (800, 700, false, 1, "mi"), (800, 700, true, 0, "mis"), (800, 700, true, 3, "mis"),
       (800, 700, true, 0, "zz"), (640, 620, true, 1, "m"), (640, 620, true, 1, "mis"), (640, 620, false, 1, "m")]
    for (w, h, light, sel, q) in seq do
      let n := if q == "zz" then 0 else 16 - q.length * 4
      let reqStr := String.intercalate "\n" (s!"P\t{w}\t{h}\t1\t{if light then 1 else 0}\t{sel}\t{q}" ::
        (manyLines.take n))
      let some req := parsePaletteRequest? reqStr | throw (IO.userError "palette raster request")
      let (_, acA, incNext) ← renderPaletteFrame req acI incFb paletteIdentityShape none (some rc)
      acI := acA
      incFb := incNext
      let (theme, root) := buildPaletteChrome req
      let box := layoutNode 120 none theme.palette.focusRing 0 0 (pxToSub w) (pxToSub h) root.toLayoutNode
      let scene := buildSceneFromLayout 120 {} theme root box (recordNodes := false)
      let (fullFb, _) := Vulkan.rasterizeScene w h 0 acI scene.prims
      unless incNext.framebuffer == fullFb do
        throw (IO.userError s!"cached palette raster diverged at {w}x{h} light={light} sel={sel} q={q}")
    -- 4g. Region handoff: a host that applies whole frames, or only the announced rectangle, and
    --     starts from a blank surface after a reopen (`F`), always holds the full raster.
    let palRaster ← IO.mkRef ({} : PaletteRasterCache)
    let palFb2 ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
    let mut mirror := ByteArray.empty
    let mut regionFrames := 0
    let steps : List (Bool × Nat × String) :=
      [(true, 0, "m"), (false, 1, "m"), (false, 2, "m"), (false, 2, "mi"), (true, 2, "mi"), (false, 3, "mis"), (false, 0, "m")]
    for (reopen, sel, q) in steps do
      let reqStr := String.intercalate "\n" (s!"P\t800\t700\t1\t0\t{sel}\t{q}" :: manyLines.take (16 - q.length * 4))
      if reopen then mirror := ByteArray.mk (Array.replicate (800 * 700 * 4) 0)
      let (hits, px) ← dispatchEmbeddedRequest ((if reopen then "F" else "") ++ reqStr) atlasRef sbFbRef palFb2 sbCache
        paletteIdentityShape none none (some palRaster)
      if hits.startsWith "\x01" then
        regionFrames := regionFrames + 1
        let some header := (hits.drop 1).toString.splitOn "\n" |>.head? | throw (IO.userError "region header")
        let [stS, xS, yS, wS, hS] := header.splitOn " " | throw (IO.userError s!"region header {header}")
        let (some stride, some x, some y, some w, some h) := (stS.toNat?, xS.toNat?, yS.toNat?, wS.toNat?, hS.toNat?)
          | throw (IO.userError s!"region header {header}")
        unless stride == 800 && px.size == w * h * 4 && !reopen do throw (IO.userError "bad region frame")
        for row in [:h] do
          mirror := px.copySlice (row * w * 4) mirror (((y + row) * stride + x) * 4) (w * 4)
      else
        unless px.size == 800 * 700 * 4 do throw (IO.userError "palette frame is neither whole nor a region")
        mirror := px
      let some req := parsePaletteRequest? reqStr | throw (IO.userError "palette handoff request")
      let (theme, root) := buildPaletteChrome req
      let box := layoutNode 120 none theme.palette.focusRing 0 0 (pxToSub 800) (pxToSub 700) root.toLayoutNode
      let scene := buildSceneFromLayout 120 {} theme root box (recordNodes := false)
      unless mirror == (Vulkan.rasterizeScene 800 700 0 (← atlasRef.get) scene.prims).1 do
        throw (IO.userError s!"host surface diverged after sel={sel} q={q} reopen={reopen}")
    unless regionFrames ≥ 3 do throw (IO.userError s!"palette never handed over a region ({regionFrames})")

    let st ← rc.get
    unless st.contentRenders == seq.length && st.chromeRenders ≤ 5 && st.chromeResizes ≥ 2 do
      throw (IO.userError s!"palette chrome cache unused: chrome={st.chromeRenders} resizes={st.chromeResizes} content={st.contentRenders}")
  finally
    Runtime.shutdownRuntime rt

/-- A GTK-shaped sidebar row model: nav rows, `projects` projects with `missions` missions each
    (one running per project, so the spinner animates), and the Settings footer. -/
def sampleSidebarRows (projects missions : Nat) (titleSuffix : String := "") (onlyMission : Option Nat := none) : String := Id.run do
  let mut lines : Array String := #[
    "1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t",
    "1001\tnav:inbox\tnav\tInbox\t0\t\t⌘I\t4\t0\t0\t",
    "1002\tnav:cloud-agent\tnav\tCloud agent\t0\t\t⌘2\t0\t0\t0\t",
    "1003\tnav:machines\tnav\tMachines\t0\t\t⌘3\t0\t0\t0\t",
    "1004\tnav:providers\tnav\tInference\t0\t\t⌘4\t0\t0\t0\t"]
  let mut id := 1005
  for p in [:projects] do
    lines := lines.push s!"{id}\tproj:{p}\tproject\tProject {p}\t0\t\t\t0\t0\t1\tblue"
    id := id + 1
    for m in [:missions] do
      let status := if m == 0 then "running" else if m == 1 then "awaiting_user" else "completed"
      let suffix := match onlyMission with
        | some k => if k == p * missions + m then titleSuffix else ""
        | none => titleSuffix
      lines := lines.push s!"{id}\tm:{p}-{m}\tmission\tMission {p}.{m} refactor the sidebar{suffix}\t1\t{status}\t\t0\t0\t0\t"
      id := id + 1
  lines := lines.push s!"{id}\tnav:settings\tfooter\tSettings\t0\t\t\t0\t0\t0\t"
  return String.intercalate "\n" lines.toList ++ "\n"

private def sidebarRequest (w h scale : Nat) (light : Bool) (offset phase : Nat) (rows : String) : String :=
  s!"{w}\t{h}\t{scale}\t{if light then 1 else 0}\t{offset}\t{phase}\n{rows}"

private def hasScrollThumb (scene : SceneOutput) : Bool :=
  scene.prims.any fun p => match p with
    | .quad r fill _ _ _ => r.w <= 8 && fill &&& 0xFFFFFF00 == 0xFFFFFF00 && fill &&& 0xFF != 0 && fill &&& 0xFF <= 0x38
    | _ => false

/-- Cached sidebar frames must be identical to uncached ones, reuse parsed rows and shaped rows on
    scroll/spinner frames, drop the memo on an atlas reset, and fade the scrollbar on schedule. -/
def embeddedSidebarCacheSelfTest : IO Unit := do
  -- 1. Fade policy.
  unless scrollbarFade none == (0, 0) && scrollbarFade (some 0) == (255, scrollbarHoldMs) &&
      scrollbarFade (some (scrollbarHoldMs - 1)) == (255, 1) &&
      scrollbarFade (some scrollbarHoldMs) == (255, scrollbarFadeFrameMs) &&
      (scrollbarFade (some (scrollbarHoldMs + scrollbarFadeMs / 2))).1 == 127 &&
      scrollbarFade (some (scrollbarHoldMs + scrollbarFadeMs)) == (0, 0) do
    throw (IO.userError "scrollbar fade policy mismatch")
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  try
    let rows := sampleSidebarRows 6 5
    let atlasA ← IO.mkRef rt.atlas
    let atlasB ← IO.mkRef rt.atlas
    let cached ← IO.mkRef ({} : EmbeddedSidebarCache)
    let plain ← IO.mkRef ({ enabled := false } : EmbeddedSidebarCache)
    let shape : ShapeFn := fun ac _ n => pure (ac, n)
    -- (offset, phase, nowMs, rows): first paint, scroll, scroll, spinner tick, idle, faded, row edit.
    let steps : List (Nat × Nat × Nat × String) :=
      [(0, 0, 1000, rows), (24, 0, 1016, rows), (60, 0, 1032, rows), (60, 1, 1100, rows),
       (60, 1, 1640, rows), (60, 2, 1900, rows), (60, 2, 1910, sampleSidebarRows 6 5 " (renamed)")]
    let mut frames : Array (SidebarFrame × EmbeddedSidebarCache) := #[]
    for (offset, phase, now, body) in steps do
      let req := sidebarRequest 260 420 1 false offset phase body
      let fa ← prepareSidebarFrame req atlasA cached shape now
      let fb ← prepareSidebarFrame req atlasB plain shape now
      unless fa.scene.prims == fb.scene.prims && fa.hitPayload == fb.hitPayload do
        throw (IO.userError s!"cached sidebar frame diverged at offset={offset} phase={phase} now={now}")
      frames := frames.push (fa, ← cached.get)
    let c (i : Nat) : EmbeddedSidebarCache := (frames[i]!).2
    let f (i : Nat) : SidebarFrame := (frames[i]!).1
    let firstLine (i : Nat) : String := ((f i).hitPayload.splitOn "\n").head!
    -- 2. Parse once per distinct row model; scroll-only frames reuse the whole shaped tree.
    unless (c 3).parses == 1 && (c 6).parses == 2 && (c 2).treeReuses == 2 do
      throw (IO.userError s!"unexpected sidebar reuse: parses={(c 3).parses}/{(c 6).parses} tree={(c 2).treeReuses}")
    -- 2b. A new row model at the same phase and geometry must never reuse a cached tree.
    unless (c 6).treeReuses == (c 5).treeReuses do
      throw (IO.userError "sidebar reused a shaped tree after the row model changed")
    -- 3. A spinner tick reshapes only the six running rows.
    unless (c 3).rowShapes - (c 2).rowShapes == 6 && (c 3).rowReuses > (c 2).rowReuses + 30 do
      throw (IO.userError s!"spinner frame reshaped {(c 3).rowShapes - (c 2).rowShapes} rows")
    -- 4. Auto-hide scrollbar: hidden at rest, shown while scrolling, gone after the fade.
    unless !hasScrollThumb (f 0).scene && hasScrollThumb (f 1).scene && hasScrollThumb (f 4).scene &&
        !hasScrollThumb (f 5).scene do
      throw (IO.userError "auto-hide scrollbar visibility mismatch")
    unless (firstLine 0).endsWith " 0" && (firstLine 2).endsWith s!" {scrollbarHoldMs}" &&
        (firstLine 4).endsWith s!" {scrollbarFadeFrameMs}" && (firstLine 5).endsWith " 0" do
      throw (IO.userError s!"scrollbar wake schedule mismatch: {firstLine 0} | {firstLine 2} | {firstLine 4} | {firstLine 5}")
    -- 5. An atlas reset invalidates every memoized row.
    let before ← cached.get
    atlasA.modify (·.resetAll)
    discard <| prepareSidebarFrame (sidebarRequest 260 420 1 false 60 3 rows) atlasA cached shape 2000
    let after ← cached.get
    unless after.rowReuses == before.rowReuses && after.treeReuses == before.treeReuses do
      throw (IO.userError "atlas reset did not invalidate the sidebar memo")
  finally
    Runtime.shutdownRuntime rt

private def benchStats (samples : Array Nat) : String :=
  let sorted := samples.qsort (· < ·)
  let ms (ns : Nat) : String :=
    let us := ns / 1000
    s!"{us / 1000}.{toString (1000 + us % 1000) |>.drop 1}"
  let pick (q : Nat) := sorted[min (sorted.size - 1) (sorted.size * q / 100)]!
  let mean := if sorted.isEmpty then 0 else sorted.foldl (· + ·) 0 / sorted.size
  s!"\"p50_ms\": {ms (pick 50)}, \"p99_ms\": {ms (pick 99)}, \"mean_ms\": {ms mean}"

/-- `--bench-embedded N`: CPU time per embedded sidebar frame before `renderAndPresentGpu`
    (parse, build, shape, layout, scene), uncached vs cached, for scroll-only, spinner-phase and
    row-edit frames, plus full palette frames (layout, scene and CPU raster) in both themes. -/
def runEmbeddedSidebarBench (iters : Nat)
    (shape : Text.GlyphAtlasCache → Text.FontHandle → Text.FontHandle → Text.FontHandle →
      Text.FontHandle → Text.FontHandle → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode)) : IO UInt32 := do
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  let shapeFn : ShapeFn := fun a sc node =>
    shape a rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc node
  let atlas ← IO.mkRef rt.atlas
  let rows := sampleSidebarRows 8 6
  let mut out : Array String := #[]
  try
    for enabled in [false, true] do
      for scenario in ["scroll", "spinner", "row_edit"] do
        let cache ← IO.mkRef ({ enabled } : EmbeddedSidebarCache)
        -- Warm up over one spinner period (1.2 s at runtime) before measuring steady state.
        for ph in [:12] do
          discard <| prepareSidebarFrame (sidebarRequest 280 900 2 false 0 ph rows) atlas cache shapeFn 0
        let mut samples : Array Nat := #[]
        for i in [:iters] do
          let (offset, phase, body) := match scenario with
            | "scroll" => (i * 3 % 400, 0, rows)
            | "spinner" => (0, i % 12, rows)
            -- One mission's title or status changes, as a live update does.
            | _ => (0, 0, sampleSidebarRows 8 6 s!" #{i}{if enabled then "c" else "u"}" (some (i % 48)))
          let req := sidebarRequest 280 900 2 false offset phase body
          let t0 ← IO.monoNanosNow
          let frame ← prepareSidebarFrame req atlas cache shapeFn (i * 16)
          let t1 ← IO.monoNanosNow
          if frame.scene.prims.isEmpty then throw (IO.userError "empty sidebar bench frame")
          samples := samples.push (t1 - t0)
        out := out.push s!"  \"sidebar_{scenario}_{if enabled then "cached" else "uncached"}\": \{{benchStats samples}}"
    -- Stage split of one steady-state spinner frame (what the cached path still pays).
    let some st0 := (sidebarRequest 280 900 2 false 0 0 rows).splitOn "\n" |>.tail?.map fun body =>
        (body.filterMap projectedRow).map Prod.fst
      | throw (IO.userError "bench rows")
    let sc := 240
    let theme := Theme.withWindowEffects orbDarkTheme
    let st := { DesktopState.liveUnavailable with theme, sidebarRows := st0, badgePhase := 3 }
    let mut stages : Array (String × Array Nat) := #[("build", #[]), ("memo_shape", #[]), ("layout", #[]), ("scene", #[])]
    let warm := buildSidebarChrome st (pxToSub 900) (width := pxToSub 280) (embedded := true)
    let (_, (_, memo, _, _)) ← (shapeWithRowMemo shapeFn {} sc warm).run (← atlas.get, {}, 0, 0)
    for i in [:iters] do
      let t0 ← IO.monoNanosNow
      let root := buildSidebarChrome { st with badgePhase := i % 12 } (pxToSub 900) (width := pxToSub 280) (embedded := true)
      let t1 ← IO.monoNanosNow
      let (tree, _) ← (shapeWithRowMemo shapeFn memo sc root).run (← atlas.get, memo, 0, 0)
      let t2 ← IO.monoNanosNow
      let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub 280) (pxToSub 900) tree.toLayoutNode
      let t3 ← IO.monoNanosNow
      let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
      if scene.prims.isEmpty then throw (IO.userError "empty stage scene")
      let t4 ← IO.monoNanosNow
      stages := #[("build", stages[0]!.2.push (t1 - t0)), ("memo_shape", stages[1]!.2.push (t2 - t1)),
        ("layout", stages[2]!.2.push (t3 - t2)), ("scene", stages[3]!.2.push (t4 - t3))]
    for (name, xs) in stages do
      out := out.push s!"  \"stage_{name}\": \{{benchStats xs}}"
    let palette := String.intercalate "\n" ("P\t1200\t800\t2\t{L}\t1\tmis" :: (List.range 12).map fun i =>
      s!"{i}\tm:{i}\tmission\tMission {i}\tproject · running\trunning\t\t")
    for light in [false, true] do
      let some req := parsePaletteRequest? (palette.replace "{L}" (if light then "1" else "0"))
        | throw (IO.userError "bench palette request rejected")
      let mut fb := { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
      let mut samples : Array Nat := #[]
      for _ in [:min iters 20] do
        let t0 ← IO.monoNanosNow
        let (_, ac, next) ← renderPaletteFrame req (← atlas.get) { fb with framebuffer := ByteArray.empty, previousPaint := none } shapeFn
        let t1 ← IO.monoNanosNow
        atlas.set ac
        fb := next
        samples := samples.push (t1 - t0)
      out := out.push s!"  \"palette_{if light then "light" else "dark"}_2x_cpu\": \{{benchStats samples}}"
      let gpuRef ← IO.mkRef ({ allowSoftware := true } : PaletteGpu)
      let mut gsamples : Array Nat := #[]
      let mut gpuFb := ByteArray.empty
      for _ in [:min iters 5] do
        let t0 ← IO.monoNanosNow
        let (_, ac, next) ← renderPaletteFrame req (← atlas.get) { rt.vulkan with framebuffer := ByteArray.empty, previousPaint := none } shapeFn (some gpuRef)
        let t1 ← IO.monoNanosNow
        atlas.set ac
        gpuFb := next.framebuffer
        gsamples := gsamples.push (t1 - t0)
      let g ← gpuRef.get
      if let some c := g.ctx then Vk.destroyOffscreenReadback c
      let delta := Id.run do
        let mut d := 0
        if gpuFb.size == fb.framebuffer.size then
          for i in [:gpuFb.size] do
            let a := (gpuFb.get! i).toNat
            let b := (fb.framebuffer.get! i).toNat
            d := max d (if a > b then a - b else b - a)
        else d := 256
        return d
      out := out.push s!"  \"palette_{if light then "light" else "dark"}_2x_gpu\": \{{benchStats gsamples}, \"gpu\": {!g.disabled}, \"max_channel_delta_vs_cpu\": {delta}}"
    -- Steady state, as GTK drives it: the previous paint is kept, so only damage is redrawn.
    for light in [false, true] do
      for scenario in ["select", "type"] do
        let reqAt (i : Nat) : Option PaletteRequest :=
          let n := if scenario == "type" then 12 - i % 9 else 12
          let q := if scenario == "type" then String.ofList (List.replicate (1 + i % 9) 'm') else "mis"
          let sel := if scenario == "select" then i % 12 else 0
          parsePaletteRequest? (String.intercalate "\n" (s!"P\t1200\t800\t2\t{if light then 1 else 0}\t{sel}\t{q}" ::
            (List.range n).map fun k => s!"{k}\tm:{k}\tmission\tMission {k}\tproject · running\trunning\t\t"))
        let some r0 := reqAt 0 | throw (IO.userError "palette steady request")
        let (_, ac0, fb0) ← renderPaletteFrame r0 (← atlas.get) { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty } shapeFn
        atlas.set ac0
        let rc ← IO.mkRef ({} : PaletteRasterCache)
        let to0 ← IO.monoNanosNow
        let (_, ac1, fb1) ← renderPaletteFrame r0 (← atlas.get) fb0 shapeFn none (some rc)
        let to1 ← IO.monoNanosNow
        atlas.set ac1
        if scenario == "select" then
          -- Opening: the chrome is rendered once, by the CPU or (here, lavapipe) the GPU.
          let gref ← IO.mkRef ({ allowSoftware := true } : PaletteGpu)
          let rcG ← IO.mkRef ({} : PaletteRasterCache)
          let tg0 ← IO.monoNanosNow
          let (_, acG, fbG) ← renderPaletteFrame r0 (← atlas.get) { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty } shapeFn (some gref) (some rcG)
          let tg1 ← IO.monoNanosNow
          atlas.set acG
          let g ← gref.get
          if let some c := g.ctx then Vk.destroyOffscreenReadback c
          let a := fbG.framebuffer
          let b := fb1.framebuffer
          let delta := Id.run do
            let mut d := 0
            if a.size != b.size then return 256
            for i in [:a.size] do
              let x := (a.get! i).toNat
              let y := (b.get! i).toNat
              d := max d (if x > y then x - y else y - x)
            return d
          out := out.push s!"  \"palette_{if light then "light" else "dark"}_2x_open\": \{\"cpu_chrome_ms\": {(to1 - to0) / 1000000}, \"gpu_chrome_ms\": {(tg1 - tg0) / 1000000}, \"gpu\": {!g.disabled}, \"gpu_device\": \"lavapipe\", \"max_channel_delta_vs_cpu\": {delta}}"
        let mut fb := fb1
        let mut samples : Array Nat := #[]
        for i in [1:iters + 1] do
          let some r := reqAt i | throw (IO.userError "palette steady request")
          let t0 ← IO.monoNanosNow
          let (_, ac, next) ← renderPaletteFrame r (← atlas.get) fb shapeFn none (some rc)
          let t1 ← IO.monoNanosNow
          atlas.set ac
          fb := next
          samples := samples.push (t1 - t0)
        -- Exactness with real glyphs: the cached raster must equal a full raster of the same scene.
        let some rl := reqAt iters | throw (IO.userError "palette steady request")
        let (theme, root) := buildPaletteChrome rl
        let (acE, treeE) ← shapeFn (← atlas.get).beginUploads 240 root
        let acE := acE.finishUploads
        let boxE := layoutNode 240 none theme.palette.focusRing 0 0 (pxToSub rl.width) (pxToSub rl.height) treeE.toLayoutNode
        let sceneE := buildSceneFromLayout 240 {} theme treeE boxE (recordNodes := false)
        let exact := fb.framebuffer == (Vulkan.rasterizeScene 2400 1600 0 acE sceneE.prims).1
        -- Stage split of one more step.
        let some rn := reqAt (iters + 1) | throw (IO.userError "palette steady request")
        let t0 ← IO.monoNanosNow
        let (themeN, rootN) := buildPaletteChrome rn
        let (acN, treeN) ← shapeFn (← atlas.get).beginUploads 240 rootN
        let acN := acN.finishUploads
        let t1 ← IO.monoNanosNow
        let boxN := layoutNode 240 none themeN.palette.focusRing 0 0 (pxToSub rn.width) (pxToSub rn.height) treeN.toLayoutNode
        let sceneN := buildSceneFromLayout 240 {} themeN treeN boxN (recordNodes := false)
        if sceneN.prims.isEmpty then throw (IO.userError "palette stage scene")
        let t2 ← IO.monoNanosNow
        let chromeTree := paletteChromeOnly treeN
        let chromeBox := layoutNode 240 none themeN.palette.focusRing 0 0 (pxToSub rn.width) (pxToSub rn.height) chromeTree.toLayoutNode
        let chrome := (buildSceneFromLayout 240 {} themeN chromeTree chromeBox (recordNodes := false)).prims
        if chrome.isEmpty then throw (IO.userError "palette stage chrome")
        let t3 ← IO.monoNanosNow
        let px ← paletteCpuRaster rc 2400 1600 acN chrome sceneN.prims fb.framebuffer
        if px.isEmpty then throw (IO.userError "palette stage raster")
        let t4 ← IO.monoNanosNow
        let us (a b : Nat) := (b - a) / 1000
        let st ← rc.get
        out := out.push s!"  \"palette_{if light then "light" else "dark"}_2x_{scenario}_stages_us\": \{\"shape\": {us t0 t1}, \"layout_scene\": {us t1 t2}, \"chrome_scene\": {us t2 t3}, \"raster\": {us t3 t4}, \"byte_exact_vs_full\": {exact}}"
        out := out.push s!"  \"palette_{if light then "light" else "dark"}_2x_{scenario}_step\": \{{benchStats samples}, \"chrome_renders\": {st.chromeRenders}, \"chrome_resizes\": {st.chromeResizes}, \"content_renders\": {st.contentRenders}}"
    if (← IO.getEnv "ORB_BENCH_RASTER_SPLIT") == some "1" then
      let some req := parsePaletteRequest? (palette.replace "{L}" "0") | throw (IO.userError "palette")
      let (theme, root) := buildPaletteChrome req
      let (ac, tree) ← shapeFn (← atlas.get).beginUploads 240 root
      let ac := ac.finishUploads
      let box := layoutNode 240 none theme.palette.focusRing 0 0 (pxToSub req.width) (pxToSub req.height) tree.toLayoutNode
      let scene := buildSceneFromLayout 240 {} theme tree box (recordNodes := false)
      let kinds : List (String × (Prim → Bool)) := [
        ("all", fun _ => true),
        ("no_shadow", fun p => match p with | .shadow .. => false | _ => true),
        ("no_glyph", fun p => match p with | .glyph .. => false | _ => true),
        ("no_quad", fun p => match p with | .quad .. => false | _ => true)]
      for (name, keep) in kinds do
        let prims := scene.prims.filter keep
        let t0 ← IO.monoNanosNow
        let (px, _) := Vulkan.rasterizeScene 2400 1600 0 ac prims
        if px.size == 0 then throw (IO.userError "raster")
        let t1 ← IO.monoNanosNow
        out := out.push s!"  \"palette_raster_{name}\": \{\"ms\": {(t1 - t0) / 1000000}, \"prims\": {prims.size}}"
      let quads := scene.prims.filterMap fun p => match p with
        | .quad r _ rad bw _ => some s!"{r.w}x{r.h}/r{rad}/b{bw}" | _ => none
      out := out.push s!"  \"palette_quads\": \"{quads}\""
    IO.println ("{\n" ++ String.intercalate ",\n" out.toList ++ "\n}")
    return 0
  finally
    Runtime.shutdownRuntime rt

end OrbDesktop
