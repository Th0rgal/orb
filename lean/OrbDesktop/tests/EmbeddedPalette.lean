import OrbDesktop.EmbeddedSidebar

open OrbDesktop LeanUI

private def identityShape (ac : Text.GlyphAtlasCache) (_sc : Nat) (node : WidgetNode) :
    IO (Text.GlyphAtlasCache × WidgetNode) :=
  pure (ac, node)

private def hasNonZeroPixel (fb : ByteArray) : Bool := Id.run do
  for i in [:fb.size] do
    if fb.get! i != 0 then return true
  return false

private def parseHitLine (line : String) : Option (Nat × Int × Int × Int × Int) := do
  let [idS, xS, yS, wS, hS] := line.splitOn " " | none
  let id ← idS.toNat?
  let x ← xS.toInt?
  let y ← yS.toInt?
  let w ← wS.toInt?
  let h ← hS.toInt?
  return (id, x, y, w, h)

def main : IO Unit := do
  -- 1. Legacy sidebar requests must NOT be parsed as palette requests (100% backward compatible).
  let sidebarReq := "220\t700\t1\t0\t0\t0\n1000\tnav:new-agent\tnav\tNew Agent\t0\t\t⌘N\t0\t1\t0\t"
  unless (parsePaletteRequest? sidebarReq).isNone do
    throw (IO.userError "legacy sidebar request misclassified as palette request")

  -- 2. Populated palette request parsing (including tabs/spaces in query and multiple kinds).
  let populatedReq := String.intercalate "\n" [
    "P\t900\t620\t1\t0\t1\tcop",
    "0\tm:aaa\tmission\tCopper\torchard · awaiting_user\tawaiting_user\t",
    "1\tnav:machines\tnav\tMachines\tFleet nodes & managed VMs\t\t⌘3",
    "2\tproj:orchard\tproject\tOrchard\tProject · orchard\t\t",
    "3\tsettings:models\tsettings\tModels\tSettings · Models\t\t"
  ]
  let some parsed := parsePaletteRequest? populatedReq
    | throw (IO.userError "failed to parse populated palette request")
  unless parsed.width == 900 && parsed.height == 620 && parsed.scale == 1 &&
      !parsed.light && parsed.selectedIdx == 1 && parsed.query == "cop" && parsed.items.length == 4 do
    throw (IO.userError s!"unexpected parsed palette request: {repr parsed}")

  -- 3. Render both dark & light themes and both populated & empty results through the full pipeline.
  let rt ← Runtime.initRuntime { headless := true, width := 1, height := 1 } ()
  try
    let mut ac := rt.atlas
    let mut fb := rt.vulkan
    for light in [false, true] do
      for empty in [false, true] do
        let reqStr :=
          if empty then
            s!"P\t800\t560\t1\t{if light then 1 else 0}\t0\tzzz_no_match\n"
          else
            String.intercalate "\n" [
              s!"P\t800\t560\t1\t{if light then 1 else 0}\t1\torc",
              "0\tm:aaa\tmission\tCopper\torchard · running\trunning\t",
              "1\tnav:machines\tnav\tMachines\tFleet nodes & managed VMs\t\t⌘3",
              "2\tproj:orchard\tproject\tOrchard\tProject · orchard\t\t"
            ]
        let some req := parsePaletteRequest? reqStr
          | throw (IO.userError "failed to parse palette variant")
        let (hitsStr, nextAc, nextFb) ← renderPaletteFrame req ac fb identityShape
        ac := nextAc
        fb := nextFb
        let expectedBytes := req.width * req.height * 4
        unless fb.framebuffer.size == expectedBytes do
          throw (IO.userError s!"framebuffer size mismatch: {fb.framebuffer.size} vs {expectedBytes}")
        unless hasNonZeroPixel fb.framebuffer do
          throw (IO.userError s!"blank framebuffer for light={light} empty={empty}")
        let parsedHits := (hitsStr.splitOn "\n").filterMap parseHitLine
        let card? := parsedHits.find? (·.1 == paletteCardHitId)
        let some (_, cx, cy, cw, ch) := card?
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

    -- 4. Verify scrolled selection windowing preserves true item widget IDs (> maxVisible).
    let manyLines := (List.range 16).map fun i =>
      s!"{i}\tm:id{i}\tmission\tMission {i}\tproj · completed\tcompleted\t"
    let scrolledReqStr := String.intercalate "\n" ("P\t800\t520\t1\t0\t14\tmission" :: manyLines)
    let some scrolledReq := parsePaletteRequest? scrolledReqStr
      | throw (IO.userError "failed to parse scrolled palette request")
    let (hitsStr, _, nextFb) ← renderPaletteFrame scrolledReq ac fb identityShape
    let parsedHits := (hitsStr.splitOn "\n").filterMap parseHitLine
    unless hasNonZeroPixel nextFb.framebuffer && parsedHits.any (·.1 == 14) do
      throw (IO.userError s!"scrolled selection id 14 missing from hits: {hitsStr}")

    -- 5. Out-of-range selectedIdx must clamp safely instead of hiding visible items.
    let oobReqStr := "P\t800\t520\t1\t0\t99\tcop\n0\tm:aaa\tmission\tCopper\torchard · running\trunning\t"
    let some oobReq := parsePaletteRequest? oobReqStr
      | throw (IO.userError "failed to parse oob palette request")
    let (oobHitsStr, _, oobFb) ← renderPaletteFrame oobReq ac nextFb identityShape
    let oobHits := (oobHitsStr.splitOn "\n").filterMap parseHitLine
    unless hasNonZeroPixel oobFb.framebuffer && oobHits.any (·.1 == 0) do
      throw (IO.userError s!"oob selectedIdx dropped visible item 0: {oobHitsStr}")
    IO.println "embedded-palette lean test: ok"
  finally
    Runtime.shutdownRuntime rt
