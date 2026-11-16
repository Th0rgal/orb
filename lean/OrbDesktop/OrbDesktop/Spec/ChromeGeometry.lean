import OrbDesktop.Screens
/-!
# OrbDesktop.Spec.ChromeGeometry — the shell has the geometry of the SolidJS desktop

Lays out `03_mission_transcript` at the reference size (1470 x 923 logical pixels) and compares
the device rectangles with the ones measured in the SolidJS DOM (`getBoundingClientRect` of
`aside.sidebar`, `header.titlebar`, `.dock`, `.composer`, `.plus`, `.send`, `button.row`,
`.gear-btn`). See `docs/ui/leanui-parity.md`.
-/
namespace OrbDesktop.Spec

open LeanUI OrbDesktop

private def geomState : DesktopState := DesktopState.forScreen .missionTranscript

private def laid (scale120 : Nat) : ComputedBox × SceneOutput :=
  renderWidgetTree scale120 (pxToSub 1470) (pxToSub 923) geomState.initialFocusState
    geomState.theme (buildDesktopScreen geomState (pxToSub 1470) (pxToSub 923))

/-- Device rectangle of the box reached from the root by child indices. -/
private def boxAt (scale120 : Nat) (path : List Nat) : Option Rect :=
  (path.foldl (fun (b : Option ComputedBox) i => b.bind (·.children[i]?)) (some (laid scale120).1)).map
    (·.rectDev)

/-- Device rectangle of the widget `id`. -/
private def widget (scale120 : Nat) (id : Nat) : Option Rect :=
  ((laid scale120).2.hitRegionsDev.find? (·.1 == id)).map (·.2)

-- Shell: 220 px sidebar, 35 px title row, 104 px composer dock.
#guard boxAt 120 [0] == some { x := 0, y := 0, w := 220, h := 923 }
#guard boxAt 120 [1, 0] == some { x := 220, y := 0, w := 1250, h := 35 }
#guard boxAt 120 [1, 1] == some { x := 220, y := 35, w := 1250, h := 784 }
#guard boxAt 120 [1, 2] == some { x := 220, y := 819, w := 1250, h := 104 }

-- The dock is the band a composer edit repaints.
#guard boxAt 120 [1, 2] == some (composerDamageRect 120 { x := 0, y := 0, w := 1470, h := 923 })
#guard boxAt 240 [1, 2] == some (composerDamageRect 240 { x := 0, y := 0, w := 2940, h := 1846 })

-- Composer: a 748 x 42 pill centred in the dock, with the round attach and send buttons.
#guard widget 120 1 == some { x := 471, y := 829, w := 748, h := 42 }
#guard widget 120 3 == some { x := 483, y := 838, w := 24, h := 24 }
#guard widget 120 2 == some { x := 1185, y := 838, w := 24, h := 24 }
#guard widget 240 1 == some { x := 942, y := 1658, w := 1496, h := 84 }

-- Sidebar: 30 px rows on a 31 px pitch below the title row, a section label 14 px below the
-- navigation, the tree 4 px below the label, and the settings button in the footer.
#guard widget 120 101 == some { x := 6, y := 35, w := 207, h := 30 }
#guard widget 120 102 == some { x := 6, y := 66, w := 207, h := 30 }
#guard widget 120 104 == some { x := 6, y := 132, w := 207, h := 30 }
#guard widget 120 105 == some { x := 6, y := 163, w := 207, h := 30 }
#guard widget 120 103 == some { x := 6, y := 885, w := 207, h := 32 }

end OrbDesktop.Spec
