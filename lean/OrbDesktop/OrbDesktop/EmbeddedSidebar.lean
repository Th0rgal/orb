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

/-- Parse one tab-separated palette item line (`index\tid\tkind\ttitle\tsubtitle\tstatus\tshortcut`). -/
def parsePaletteItem? (line : String) : Option PaletteRow := do
  let [index, itemId, kind, title, subtitle, status, shortcut] := line.splitOn "\t" | none
  let widgetId ← index.toNat?
  return { widgetId, itemId, kind, title, subtitle, status, shortcut }

/-- Parse a `"P\t<w>\t<h>\t<scale>\t<light>\t<selectedIdx>\t<query>\n<items>"` request.
    Returns `none` for legacy sidebar requests so existing callers stay 100% compatible. -/
def parsePaletteRequest? (request : String) : Option PaletteRequest := do
  let header :: lines := request.splitOn "\n" | none
  let "P" :: w :: h :: scale :: light :: sel :: qParts := header.splitOn "\t" | none
  let width ← w.toNat?
  let height ← h.toNat?
  return {
    width
    height
    scale := max 1 (scale.toNat?.getD 1)
    light := light == "1"
    selectedIdx := sel.toNat?.getD 0
    query := String.intercalate " " qParts
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

private def paletteIconColor (pal : Palette) (row : PaletteRow) : Color :=
  if row.kind == "mission" then
    match liveBadgeKind row.status with
    | "loader" => pal.accent
    | "alert" => pal.warning
    | "check" => pal.success
    | _ => pal.textMuted
  else if row.kind == "project" then pal.textSecondary
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
  let availListPx : Nat := if req.height > 210 then req.height - 210 else 126
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

/-- Paint the same widget tree used by the Wayland shell at the GTK allocation and device scale.
    Input regions are returned from this exact layout. There is no Core connection in the renderer. -/
def runEmbeddedSidebar (modulePath : String)
    (shape : Text.GlyphAtlasCache → Text.FontHandle → Text.FontHandle → Text.FontHandle →
      Text.FontHandle → Text.FontHandle → Nat → WidgetNode → IO (Text.GlyphAtlasCache × WidgetNode)) : IO UInt32 := do
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  let atlas ← IO.mkRef rt.atlas
  let framebuffer ← IO.mkRef rt.vulkan
  let paletteFramebuffer ← IO.mkRef { rt.vulkan with previousPaint := none, framebuffer := ByteArray.empty }
  try
    FFI.sidebarHost modulePath fun request => do
      if let some palReq := parsePaletteRequest? request then
        let (hits, ac, next) ← renderPaletteFrame palReq (← atlas.get) (← paletteFramebuffer.get) fun a sc node =>
          shape a rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc node
        paletteFramebuffer.set next
        atlas.set ac
        return (hits, next.framebuffer)
      let header :: lines := request.splitOn "\n" | throw (IO.userError "missing sidebar allocation")
      let [w, h, scale, light, offset, phase] := header.splitOn "\t" | throw (IO.userError "invalid sidebar allocation")
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
      let (ac, tree) ← shape (← atlas.get).beginUploads rt.primaryFont rt.monoFont rt.boldFont rt.mediumFont rt.semiboldFont sc root
      let box := layoutNode sc none theme.palette.focusRing 0 0 (pxToSub width) (pxToSub height) tree.toLayoutNode
      let scene := buildSceneFromLayout sc {} theme tree box (recordNodes := false)
      let ac := ac.finishUploads
      let ctx ← framebuffer.get
      let next ← Vulkan.renderFrameDamage { ctx with width := width * factor, height := height * factor }
        0 ac ⟨0, 0, 1, 1⟩ scene.prims
      framebuffer.set next
      atlas.set ac
      let hits := scene.hitRegionsSub.filterMap fun (id, r) =>
        if id == rosterViewportId then none else
          let p := roundRect 120 r
          some s!"{id} {p.x} {p.y} {p.w} {p.h}"
      return (String.intercalate "\n" (toString (scrollLimit box / subPerPx) :: hits), next.framebuffer)
  finally Runtime.shutdownRuntime rt

end OrbDesktop
