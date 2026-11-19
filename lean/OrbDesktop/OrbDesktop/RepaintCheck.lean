import LeanUI.Vulkan

namespace OrbDesktop
open LeanUI

/-- Differential fixtures for invalidations that the stream benchmark does not force. -/
def verifyRepaintEdges : IO Unit := do
  let ctx : Vulkan.VulkanContext := { width := 16, height := 12 }
  let page : Text.AtlasPageBuffer := { atlas := { width := 2, height := 1 }, rgba := ⟨#[255,255,255,255, 0,0,0,0]⟩ }
  let atlas : Text.GlyphAtlasCache := { pages := #[page] }
  let scene (x clipX : Int) : Scene := #[.clipPush ⟨clipX,2,4,4⟩,
    .quad ⟨x,0,8,8⟩ 0xAA33FFFF 0 0 0, .clipPop,
    .glyph ⟨0,0,1,1⟩ ⟨14,10,1,1⟩ 0xFFFFFFFF false]
  let base ← Vulkan.renderFrame ctx 0 atlas (scene 0 2)
  let check (a : Text.GlyphAtlasCache) (s : Scene) (expectPartial : Bool) := do
    let got ← Vulkan.renderFrameDamage base 0 a ⟨0,0,1,1⟩ s
    let ref ← Vulkan.renderFrame ctx 0 a s
    if got.framebuffer != ref.framebuffer || (got.partialFrames > 0) != expectPartial then
      throw <| IO.userError "clip/atlas repaint differs from full repaint or unexpected fallback"
    return got.lastDamagePixels
  let area ← check atlas (scene 4 2) true
  if area != 16 then throw <| IO.userError s!"expected clipped 4×4 repaint, got {area} pixels"
  discard <| check atlas (scene 0 6) false
  let withByte (i : Nat) : Text.GlyphAtlasCache := { atlas with pages := #[{ page with rgba := page.rgba.set! i 0 }] }
  discard <| check (withByte 3) (scene 4 2) false
  let unused := { page with rgba := page.rgba.set! 7 255 }
  discard <| check { atlas with pages := #[unused] } (scene 4 2) true

end OrbDesktop
