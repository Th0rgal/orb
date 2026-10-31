import Orb.Transcript
open Orb.Transcript
-- Prints shared/orb-spec/fixtures/transcript-gates.json: every expected value is
-- computed by the Lean definitions (scripts/gen_transcript_fixtures.py).

def fmtCand (c : CandidateKey) : String :=
  s!"\{\"tag\": {c.tag}, \"item\": {c.item}}"

def fmtKey (k : TurnKey) : String :=
  s!"\{\"tag\": {k.tag}, \"item\": {k.item}, \"gen\": {k.gen}}"

def fmtList (xs : List String) : String :=
  "[" ++ ", ".intercalate xs ++ "]"

def keyBatches : List (List CandidateKey) := [
  [],
  [{ tag := 0, item := 1 }, { tag := 1, item := 2 }, { tag := 0, item := 3 }],
  [{ tag := 1, item := 0 }, { tag := 1, item := 0 }, { tag := 1, item := 0 }],
  [{ tag := 0, item := 7 }, { tag := 1, item := 7 }, { tag := 0, item := 7 }, { tag := 2, item := 0 }, { tag := 1, item := 7 }],
  [{ tag := 3, item := 42 }, { tag := 3, item := 42 }, { tag := 0, item := 1 }, { tag := 3, item := 42 }]
]

def latexCases : List (String × LatexSpan) := [
  ("simple_inline", { len := 5, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := true }),
  ("max_bound_exact", { len := 8192, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := false }),
  ("over_max_bound", { len := 8193, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := true }),
  ("empty_span", { len := 0, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := false }),
  ("currency_pair_prose", { len := 6, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := true, internalSpace := true, hasMathOp := false }),
  ("digit_start_with_operator", { len := 7, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := true, internalSpace := true, hasMathOp := true }),
  ("digit_only_token", { len := 2, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := true, internalSpace := false, hasMathOp := false }),
  ("closing_followed_by_digit", { len := 6, prevBlocked := false, nextDigit := true, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := true, hasMathOp := false }),
  ("escaped_or_alnum_prefix", { len := 3, prevBlocked := true, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := true }),
  ("leading_whitespace", { len := 4, prevBlocked := false, nextDigit := false, leadSpace := true, trailSpace := false, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := true }),
  ("trailing_whitespace", { len := 4, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := true, hasNewline := false, firstDigit := false, internalSpace := false, hasMathOp := true }),
  ("multiline_span", { len := 8, prevBlocked := false, nextDigit := false, leadSpace := false, trailSpace := false, hasNewline := true, firstDigit := false, internalSpace := false, hasMathOp := true })
]

def main : IO Unit := do
  let mut rows : Array String := #[]
  for cs in keyBatches do
    let out := allocTurnKeys cs
    rows := rows.push s!"    \{\"op\": \"allocTurnKeys\", \"candidates\": {fmtList (cs.map fmtCand)}, \"expected\": {fmtList (out.map fmtKey)}}"
  for (label, sp) in latexCases do
    let ok := latexSpanAdmitted sp
    rows := rows.push s!"    \{\"op\": \"latexSpanAdmitted\", \"name\": \"{label}\", \"len\": {sp.len}, \"prevBlocked\": {sp.prevBlocked}, \"nextDigit\": {sp.nextDigit}, \"leadSpace\": {sp.leadSpace}, \"trailSpace\": {sp.trailSpace}, \"hasNewline\": {sp.hasNewline}, \"firstDigit\": {sp.firstDigit}, \"internalSpace\": {sp.internalSpace}, \"hasMathOp\": {sp.hasMathOp}, \"expected\": {ok}}"
  for total in [0, 10, 24, 25, 80, 481] do
    for steps in [0, 1, 2, 5, 20] do
      let vis := visibleTurnCount total 24 steps 24
      let hid := hiddenTurnCount total 24 steps 24
      rows := rows.push s!"    \{\"op\": \"windowBudget\", \"total\": {total}, \"baseLimit\": 24, \"expandedSteps\": {steps}, \"stepSize\": 24, \"expectedVisible\": {vis}, \"expectedHidden\": {hid}}"
  for cap in [0, 4, 8] do
    for active in [0, 3, 4, 7, 8, 9] do
      let res := admitMount active cap
      rows := rows.push s!"    \{\"op\": \"admitMount\", \"active\": {active}, \"cap\": {cap}, \"expectedAdmitted\": {res.1}, \"expectedNextActive\": {res.2}}"
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/Orb/Transcript.lean by scripts/gen_transcript_fixtures.py; do not edit. Cross-client transcript gates: injective turn-key allocation, Pandoc inline LaTeX delimiter admission, turn-window conservation, and active media/diagram mount budgets.\","
  IO.println "  \"cases\": ["
  IO.println (",\n".intercalate rows.toList)
  IO.println "  ]"
  IO.println "}"
