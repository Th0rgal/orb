import LeanUI.Scene
/-!
# SceneDamageSpec — U7 stable-node invalidation
-/
namespace LeanUI.Spec

open LeanUI

private def oldBox : Rect := { x := 10, y := 20, w := 40, h := 30 }
private def newBox : Rect := { x := 50, y := 20, w := 40, h := 30 }
private def rec (r : Rect) (fp : UInt64) : SceneNodeRecord :=
  { id := 7, effectBoundsDev := r, fingerprint := fp }

/-- Identical records are quiescent. -/
example : diffSceneNodes #[rec oldBox 1] #[rec oldBox 1] = {} := by
  decide

/-- Moving a node damages both its old and new paint bounds. -/
example :
    let d := (diffSceneNodes #[rec oldBox 1] #[rec newBox 2]).damage
    d.covers 10 20 = true ∧ d.covers 50 20 = true := by
  decide

/-- Removal and insertion remain visible changes. -/
example :
    (diffSceneNodes #[rec oldBox 1] #[]).changed = [7] ∧
    (diffSceneNodes #[] #[rec newBox 2]).changed = [7] := by
  decide

end LeanUI.Spec
