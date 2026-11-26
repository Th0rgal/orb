import OrbDesktop.EmbeddedSidebar

def main : IO Unit := do
  OrbDesktop.embeddedPaletteSelfTest
  IO.println "embedded-palette lean test: ok"
