import OrbDesktop.Chrome
import Orb.ProjectAppearance
import LeanUI.Runtime

namespace OrbDesktop
open LeanUI

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
  try
    FFI.sidebarHost modulePath fun request => do
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
