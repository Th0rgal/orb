namespace Orb.ProjectAppearance

private def colors : List (String × Nat) :=
  [("blue", 0x8aaed4), ("green", 0x94b89a), ("amber", 0xc5aa70),
   ("rose", 0xcb929f), ("purple", 0xad9acb)]

private def hex (rgb : Nat) : String :=
  "#" ++ String.ofList (Nat.toDigits 16 rgb)

/-- Core stores a palette name. Older desktop snapshots contain the CSS color. -/
def rgb? (raw : String) : Option Nat :=
  let clean := raw.trimAscii.toString.toLower
  (colors.find? fun (name, rgb) => clean == name || clean == hex rgb).map Prod.snd

def css (raw : String) : String := ((rgb? raw).map hex).getD ""

#guard css "Blue" == "#8aaed4" && css "#AD9ACB" == "#ad9acb" && css "unknown" == ""

end Orb.ProjectAppearance
