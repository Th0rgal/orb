import Orb.Scroll
open Orb.Scroll
-- Prints shared/orb-spec/fixtures/scroll-policy.json: every case's expected
-- result is computed by the Lean definitions (scripts/gen_scroll_fixtures.py).
def st (s : State) : String := s!"\{\"pinned\": {s.pinned}, \"top\": {s.top}}"
def main : IO Unit := do
  let mut rows : Array String := #[]
  let heights : List Int := [500, 900, 2000, 5000]
  let clients : List Int := [400, 800, 1200]
  let tops : List Int := [0, 300, 1100, 4600]
  let shifts : List Int := [-700, -126, 0, 40, 126, 3000]
  for p in [true, false] do
    for h in heights do
      for c in clients do
        for t in tops do
          let s : State := { pinned := p, top := t }
          for d in shifts do
            rows := rows.push s!"    \{\"op\": \"layout\", \"state\": {st s}, \"height\": {h}, \"client\": {c}, \"shift\": {d}, \"expected\": {st (layout s h c d)}}"
          for t' in [0, 250, 1090, 1580, 4700] do
            rows := rows.push s!"    \{\"op\": \"userScroll\", \"state\": {st s}, \"height\": {h}, \"client\": {c}, \"to\": {t'}, \"expected\": {st (userScroll s h c t')}}"
          rows := rows.push s!"    \{\"op\": \"jump\", \"state\": {st s}, \"height\": {h}, \"client\": {c}, \"expected\": {st (jump s h c)}}"
          for a in [0, 700, 2600] do
            for y0 in [0, 8, 300] do
              rows := rows.push s!"    \{\"op\": \"correct\", \"height\": {h}, \"client\": {c}, \"top\": {t}, \"anchorDoc\": {a}, \"y0\": {y0}, \"expected\": {correct h c t a y0}}"
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/Orb/Scroll.lean by scripts/gen_scroll_fixtures.py; do not edit. Conversation scroll policy: layout (pinned -> bottom, else anchor kept, clamped), userScroll (up unpins, within `near` of the bottom pins), jump, and the idempotent anchor correction.\","
  IO.println "  \"cases\": ["
  IO.println (",\n".intercalate rows.toList)
  IO.println "  ]"
  IO.println "}"
