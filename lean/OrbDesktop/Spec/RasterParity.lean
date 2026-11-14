import LeanUI.Vulkan
import LeanUI.Scene

/-! Executable regressions for Wave 3's backdrop filtering and whitespace paint.
These check independent tiny images and a zero-ink positioned glyph; goldens
exercise the complete text shaping and scene paths at 1x and 2x. -/
namespace OrbDesktop.Spec
open LeanUI LeanUI.Vulkan

private def impulse : ByteArray := ByteArray.mk #[0, 0, 0, 255, 90, 90, 90, 255, 0, 0, 0, 255]
#guard (blurAxis impulse 3 1 1 true).data == #[30, 30, 30, 255, 30, 30, 30, 255, 30, 30, 30, 255]
#guard (blurAxis impulse 1 3 1 false).data == #[30, 30, 30, 255, 30, 30, 30, 255, 30, 30, 30, 255]
#guard (blurBackdrop (ByteArray.mk #[19, 31, 42, 255]) 1 1 6).data == #[19, 31, 42, 255]
#guard (blurBackdrop impulse 3 1 0).data == impulse.data
#guard (blurBackdrop ByteArray.empty 0 0 6).size == 0

private def spaceLine : WrappedLine := {
  widthSub := 4 * subPerPx
  heightSub := 18 * subPerPx
  glyphs := [{ glyph := { glyphId := 3, cluster := 0, xAdvance := 4 * subPerPx },
               relX := 0, relY := 0, color := 0xFFFFFFFF }]
}
#guard (emitWrappedLineGlyphs 120 0 0 [spaceLine]).isEmpty
#guard (emitWrappedLineGlyphs 240 0 0 [spaceLine]).isEmpty
end OrbDesktop.Spec
