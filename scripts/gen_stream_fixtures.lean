import Orb.Stream
open Orb.Stream
-- Prints shared/orb-spec/fixtures/stream-commit.json: every expected commit point is
-- computed by the Lean definitions (scripts/gen_stream_fixtures.py).
def docs : List String := [
  "Intro paragraph.\n\nSecond paragraph\ncontinues here.\n\n## Heading\n\n- a\n- b\n\nDone.",
  "Before code.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter code.\n\n",
  "~~~\nnot closed by backticks\n\n```\n\nstill inside tilde\n~~~\n\nout",
  "````md\n```\ninner\n```\n\n````\n\nafter four-tick fence",
  "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n> quote\n> more\n\n1. one\n2. two\n\n",
  "  ```\n  indented fence\n\n  ```\n\t\ntail",
  "```mermaid\ngraph TD; A-->B;\n\nstill streaming",
  "no blank lines at all\njust\nlines",
  "\n\n\nleading blanks"
]
def main : IO Unit := do
  let mut rows : Array String := #[]
  for d in docs do
    let lines := (d.splitOn "\n").map classify
    let commits := (List.range (lines.length + 1)).map fun k => commitOf (lines.take k)
    rows := rows.push s!"    \{\"doc\": {d.quote}, \"commits\": {commits}}"
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/Orb/Stream.lean by scripts/gen_stream_fixtures.py; do not edit. For each doc (split on newlines), commits[k] is the committed line count after its first k lines: the end of the last blank line outside every code fence (block-parser backtick toggle and pipe-table normalizer marker).\","
  IO.println "  \"cases\": ["
  IO.println (",\n".intercalate rows.toList)
  IO.println "  ]"
  IO.println "}"
