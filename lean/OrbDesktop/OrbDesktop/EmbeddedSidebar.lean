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
  let card : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withFixedSize cardW cardH
        |>.withBg pal.elevatedSurface
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
        |>.withBg (if req.light then 0x00000038 else 0x00000072))
      [card]
  (theme, scrim)

/-- Format palette hit regions as newline-separated `"<idx> <x> <y> <w> <h>"` logical pixel lines. -/
def formatPaletteHits (scene : SceneOutput) : String :=
  let hits := scene.hitRegionsSub.filterMap fun (id, r) =>
    let p := roundRect 120 r
    if p.w > 0 && p.h > 0 then some s!"{id} {p.x} {p.y} {p.w} {p.h}" else none
  String.intercalate "\n" hits

/-- Render one palette request through the LeanUI layout, scene, and damage-rasterizer pipeline. -/
def renderPaletteFrame (req : PaletteRequest) (ac0 : Text.GlyphAtlasCache) (fb0 : Vulkan.VulkanContext)
    (shape : Text.GlyphAtlasCache → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode)) :
    IO (String × Text.GlyphAtlasCache × Vulkan.VulkanContext) := do
  let sc := 120 * req.scale
  let (theme, root) := buildPaletteChrome req
  let (ac, tree) ← shape ac0.beginUploads sc root
  let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub req.width) (pxToSub req.height) tree.toLayoutNode
  let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
  let ac := ac.finishUploads
  let next ← Vulkan.renderFrameDamage { fb0 with width := req.width * req.scale, height := req.height * req.scale }
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

/-- Dispatch one embedded paint request, routing `"P\t"` exclusively to the palette pipeline
    and `"D\t"` to GPU surface teardown so malformed headers never fall through or clobber state. -/
def dispatchEmbeddedRequest (request : String)
    (atlas : IO.Ref Text.GlyphAtlasCache)
    (framebuffer : IO.Ref Vulkan.VulkanContext)
    (paletteFramebuffer : IO.Ref Vulkan.VulkanContext)
    (shape : Text.GlyphAtlasCache → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode))
    (gpuSurface? : Option (IO.Ref (USize × Vulkan.VulkanContext)) := none) :
    IO (String × ByteArray) := do
  if request.startsWith "D\t" then
    if let some gpuRef := gpuSurface? then
      let (_, oldCtx) ← gpuRef.modifyGet fun p => (p, (0, {}))
      if oldCtx.gpuSession.isSome then
        Vulkan.shutdownVulkan oldCtx
    return ("GPU_DETACHED", ByteArray.empty)
  if request.startsWith "P\t" then
    let some palReq := parsePaletteRequest? request
      | throw (IO.userError "invalid palette allocation")
    let palCtx ← paletteFramebuffer.modifyGet fun c => (c, { c with framebuffer := ByteArray.empty, previousPaint := none })
    let (hits, ac, next) ← renderPaletteFrame palReq (← atlas.get) palCtx shape
    paletteFramebuffer.set next
    atlas.set ac
    return (hits, next.framebuffer)
  let header :: lines := request.splitOn "\n" | throw (IO.userError "missing sidebar allocation")
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
  let projected := lines.filterMap projectedRow
  let rows := projected.map Prod.fst
  let expanded := (projected.filter Prod.snd).map Prod.fst
  let theme := Theme.withWindowEffects (if light == "1" then orbLightTheme else orbDarkTheme)
  let st := { DesktopState.liveUnavailable with
    theme, sidebarRows := rows
    screen := if rows.any (·.rowId == "s:back") then .settingsGeneral else .controlEmpty
    rosterTopSub := pxToSub (offset.toNat?.getD 0), badgePhase := phase.toNat?.getD 0
    archivesOpen := expanded.any (·.rowId == "section:archives")
    expandedProjects := expanded.filterMap (fun r => if r.kind == "project" then some (r.rowId.drop 8).toString else none)
    expandedMissions := expanded.map (·.rowId) }
  let root := buildSidebarChrome st (pxToSub height) (width := pxToSub width) (embedded := true)
  let (ac, tree) ← shape (← atlas.get).beginUploads sc root
  let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub width) (pxToSub height) tree.toLayoutNode
  let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
  let ac := ac.finishUploads
  let hits := scene.hitRegionsSub.filterMap fun (id, r) =>
    if id == rosterViewportId then none else
      let p := roundRect 120 r
      some s!"{id} {p.x} {p.y} {p.w} {p.h}"
  let hitPayload := String.intercalate "\n" (toString (scrollLimit box / subPerPx) :: hits)
  let devW := width * factor
  let devH := height * factor
  if wlDisplay != 0 && wlSurface != 0 then
    if let some gpuRef := gpuSurface? then
      let (curSurf, curCtx) ← gpuRef.modifyGet fun p => (p, (0, {}))
      let vkCtx ←
        if curSurf == wlSurface && curCtx.gpuSession.isSome then
          pure { curCtx with width := devW, height := devH }
        else
          if curCtx.gpuSession.isSome then Vulkan.shutdownVulkan curCtx
          Vulkan.initVulkanSurface devW devH wlDisplay wlSurface
      if vkCtx.backend == .cpuShm || vkCtx.gpuSession.isNone then
        if vkCtx.gpuSession.isSome then Vulkan.shutdownVulkan vkCtx
        atlas.set ac
        return ("GPU_FALLBACK", ByteArray.empty)
      let (vkCtx', ac', handled, didPresent) ←
        Vulkan.renderAndPresentGpu vkCtx theme.palette.sidebar ac scene.prims none (pure ()) (pure ())
      atlas.set ac'
      if !handled then
        if vkCtx'.gpuSession.isSome then Vulkan.shutdownVulkan vkCtx'
        return ("GPU_FALLBACK", ByteArray.empty)
      gpuRef.set (wlSurface, vkCtx')
      if !didPresent then
        return ("GPU_SKIP", ByteArray.empty)
      return ("GPU_OK\n" ++ hitPayload, ByteArray.empty)
  let ctx ← framebuffer.modifyGet fun c => (c, { c with framebuffer := ByteArray.empty, previousPaint := none })
  let next ← Vulkan.renderFrameDamage { ctx with width := devW, height := devH }
    0 ac ⟨0, 0, 1, 1⟩ scene.prims
  framebuffer.set next
  atlas.set ac
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
  try
    FFI.sidebarHost modulePath fun request =>
      dispatchEmbeddedRequest request atlas framebuffer paletteFramebuffer (fun a sc node =>
        shape a rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc node) (some gpuSurface)
  finally
    let (_, gctx) ← gpuSurface.modifyGet fun p => (p, (0, {}))
    if gctx.gpuSession.isSome then Vulkan.shutdownVulkan gctx
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

    -- 4a. Malformed "P\t" (even with 6 tab fields matching sidebar!) must fail without touching sidebar framebuffer.
    let mut threwMalformed := false
    try
      discard <| dispatchEmbeddedRequest "P\t220\t700\t1\t0\t0" atlasRef sbFbRef palFbRef paletteIdentityShape
    catch _ =>
      threwMalformed := true
    let sbAfter := (← sbFbRef.get).framebuffer
    unless threwMalformed && sbAfter == ByteArray.mk #[1, 2, 3, 4] do
      throw (IO.userError "malformed P\\t request fell through or clobbered sidebar framebuffer")

    -- 4a2. GPU detach ("D\t...") returns GPU_DETACHED cleanly without touching sidebar framebuffer.
    let gpuRef ← IO.mkRef ((0 : USize), ({} : Vulkan.VulkanContext))
    let (detRes, detPx) ← dispatchEmbeddedRequest "D\t12345" atlasRef sbFbRef palFbRef paletteIdentityShape (some gpuRef)
    unless detRes == "GPU_DETACHED" && detPx.isEmpty && (← sbFbRef.get).framebuffer == ByteArray.mk #[1, 2, 3, 4] do
      throw (IO.userError s!"unexpected GPU detach response: {detRes}")
    -- 4a3. 8-field sidebar header with wlDisplay=0, wlSurface=0 falls through to CPU buffer.
    let (sb8Hits, sb8Px) ← dispatchEmbeddedRequest
      "220\t200\t1\t0\t0\t0\t0\t0\n1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t"
      atlasRef sbFbRef palFbRef paletteIdentityShape (some gpuRef)
    unless sb8Px.size == 220 * 200 * 4 && !sb8Hits.isEmpty do
      throw (IO.userError s!"8-field CPU fallback failed: px={sb8Px.size}")

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
  finally
    Runtime.shutdownRuntime rt

end OrbDesktop
