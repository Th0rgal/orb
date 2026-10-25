import Orb.Stream
open Orb.Stream
-- Prints shared/orb-spec/fixtures/stream-cost.json: every expected counter is computed by the
-- Lean definitions (scripts/gen_stream_cost_fixtures.py).
def longReply (sections : Nat) : String := Id.run do
  let mut body := "STREAM_LONG_OK: here is the full report."
  for k in List.range sections do
    body := body ++ s!"\n\n## Section {k}\n\nThe pass rewrote `Module{k}.lean`, kept every **invariant**, and re-ran the suite.\n\n"
      ++ s!"- step {k}.1 checked\n- step {k}.2 proved\n\n| Case | Before | After |\n| --- | ---: | ---: |\n| {k} | {k * 3} ms | {k} ms |\n\n"
      ++ s!"```lean\ntheorem pass{k} : {k} + 0 = {k} := by simp\n```"
  return body ++ "\n\nSTREAM_LONG_END"

def docs : List String := [
  "Intro paragraph.\n\nSecond paragraph\ncontinues here.\n\n## Heading\n\n- a\n- b\n\nDone.",
  "Before code.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter code.\n\n",
  "~~~\nnot closed by backticks\n\n```\n\nstill inside tilde\n~~~\n\nout",
  longReply 22
]

/-- The updates of `doc` streamed `stride` characters at a time (ASCII: characters are bytes). -/
def updates (doc : String) (stride : Nat) : List Upd :=
  let n := doc.length
  let steps := (n + stride - 1) / stride
  (List.range steps).map fun i =>
    let p := String.ofList (doc.toList.take (min n ((i + 1) * stride)))
    { len := p.utf8ByteSize, commit := committedLen p }

/-- Cache operations: `get k` (a hit moves k to the front) or `put k`. -/
inductive Op | get (k : String) | put (k : String)

def runCache (cap : Nat) (ops : List Op) : Cache Nat × List Bool := Id.run do
  let mut c : Cache Nat := ⟨[]⟩
  let mut hits : List Bool := []
  for op in ops do
    match op with
    | .get k =>
      match lookup c k with
      | some v => c := insert cap c k v; hits := hits ++ [true]
      | none => hits := hits ++ [false]
    | .put k => c := insert cap c k 0
  return (c, hits)

def opJson : Op → String
  | .get k => s!"\{\"op\": \"get\", \"key\": {k.quote}}"
  | .put k => s!"\{\"op\": \"put\", \"key\": {k.quote}}"

def evJson : Ev Char → String
  | .delta d => s!"\{\"delta\": {(String.ofList d).quote}}"
  | .tick => "{\"tick\": true}"

def main : IO Unit := do
  let mut streams : Array String := #[]
  for d in docs do
    for stride in [4, 64] do
      let us := updates d stride
      streams := streams.push s!"    \{\"doc\": {d.quote}, \"stride\": {stride}, \"updates\": {us.length}, \"reparsedBytes\": {incCost 0 us}, \"fullBytes\": {fullCost us}, \"committedBytes\": {lastCommit 0 us}, \"tailBytes\": {tails us}}"
  let ops := [Op.put "a", .put "b", .get "a", .put "c", .put "d", .get "b", .get "a", .put "a", .put "e", .get "c", .get "d"]
  let (c, hits) := runCache 3 ops
  let evs : List (Ev Char) := [.delta "Hel".toList, .delta "lo".toList, .tick, .tick, .delta " wo".toList, .delta "r".toList, .delta "ld".toList, .tick, .delta "!".toList]
  let r := run Coalescer.empty evs
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/Orb/Stream.lean by scripts/gen_stream_cost_fixtures.py; do not edit. streams: bytes the incremental parser parses (new committed chunk + open tail per update) vs a full re-parse, for a doc streamed `stride` characters at a time (ASCII). cache: a text-keyed LRU of capacity 3 (get hits move to the front; put moves to the front; evicts only the oldest). renders: the per-frame coalescer.\","
  IO.println "  \"streams\": ["
  IO.println (",\n".intercalate streams.toList)
  IO.println "  ],"
  IO.println s!"  \"cache\": \{\"capacity\": 3, \"ops\": [{", ".intercalate (ops.map opJson)}], \"hits\": {hits}, \"keys\": [{", ".intercalate (c.entries.map (·.1.quote))}]},"
  IO.println s!"  \"renders\": \{\"events\": [{", ".intercalate (evs.map evJson)}], \"renders\": {r.renders}, \"shown\": {(String.ofList r.shown).quote}, \"pending\": {(String.ofList r.pending).quote}}"
  IO.println "}"
