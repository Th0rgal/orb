/-
  Orb.Stream: the streaming reply contract (`0 import Lean`, `0 sorryAx`).

  A reply arrives as thousands of small text deltas. Two pure pieces keep its
  cost per delta bounded instead of growing with the reply:

  1. The coalescer. Deltas collect in `pending`; a display frame (`tick`) moves
     them to `shown` and renders once. Nothing is lost or reordered, there is at
     most one render per frame however many deltas arrived, an idle frame renders
     nothing, and after a frame nothing is pending.
  2. The committed Markdown prefix. A line scanner marks the end of the last
     blank line outside every code fence. The block parser starts fresh there, so
     the blocks before it never change while the reply grows: they are parsed
     once and only the open tail is re-parsed. The commit point never moves back
     as lines are appended, never lies inside a fence, and resuming the scan at
     it gives the same answer as scanning from the start.

  Mirrored by `OrbStreamText` (iOS, `ios_dashboard/SandboxedDashboard/Orb/OrbStreamText.swift`)
  and checked against `shared/orb-spec/fixtures/stream-commit.json`, generated from
  these definitions by `python3 scripts/gen_stream_fixtures.py` (`--check` in CI).
-/

namespace Orb.Stream

/-! ## 1. Delta coalescing -/

structure Coalescer (α : Type) where
  shown : List α
  pending : List α
  renders : Nat
  deriving Repr, DecidableEq

inductive Ev (α : Type) where
  | delta (d : List α)
  | tick
  deriving Repr

def Coalescer.empty {α : Type} : Coalescer α := { shown := [], pending := [], renders := 0 }

def push {α : Type} (s : Coalescer α) (d : List α) : Coalescer α := { s with pending := s.pending ++ d }

def frame {α : Type} (s : Coalescer α) : Coalescer α :=
  match s.pending with
  | [] => s
  | _ :: _ => { shown := s.shown ++ s.pending, pending := [], renders := s.renders + 1 }

def step {α : Type} (s : Coalescer α) : Ev α → Coalescer α
  | .delta d => push s d
  | .tick => frame s

def run {α : Type} (s : Coalescer α) (evs : List (Ev α)) : Coalescer α := evs.foldl step s

def received {α : Type} : List (Ev α) → List α
  | [] => []
  | .delta d :: rest => d ++ received rest
  | .tick :: rest => received rest

def ticks {α : Type} : List (Ev α) → Nat
  | [] => 0
  | .delta _ :: rest => ticks rest
  | .tick :: rest => ticks rest + 1

theorem frame_conserves {α : Type} (s : Coalescer α) : (frame s).shown ++ (frame s).pending = s.shown ++ s.pending := by
  unfold frame; split <;> simp_all

theorem step_conserves {α : Type} (s : Coalescer α) (e : Ev α) :
    (step s e).shown ++ (step s e).pending = s.shown ++ s.pending ++ received [e] := by
  cases e with
  | delta d => simp [step, push, received]
  | tick => simp [step, received, frame_conserves]

/-- Nothing is lost or reordered: shown text followed by pending text is every delta, in order. -/
theorem run_conserves {α : Type} (s : Coalescer α) (evs : List (Ev α)) :
    (run s evs).shown ++ (run s evs).pending = s.shown ++ s.pending ++ received evs := by
  induction evs generalizing s with
  | nil => simp [run, received]
  | cons e rest ih =>
    simp only [run, List.foldl_cons] at *
    rw [ih, step_conserves]
    cases e <;> simp [received]

/-- At most one render per display frame, however many deltas arrived. -/
theorem run_renders_le_ticks {α : Type} (s : Coalescer α) (evs : List (Ev α)) :
    (run s evs).renders ≤ s.renders + ticks evs := by
  induction evs generalizing s with
  | nil => simp [run, ticks]
  | cons e rest ih =>
    simp only [run, List.foldl_cons] at *
    cases e with
    | delta d => have := ih (push s d); simp [step, push, ticks] at *; omega
    | tick =>
      have := ih (frame s)
      have hf : (frame s).renders ≤ s.renders + 1 := by unfold frame; split <;> simp
      simp [step, ticks] at *; omega

/-- An idle frame (nothing pending) renders nothing. -/
theorem idle_frame_no_render {α : Type} (s : Coalescer α) (h : s.pending = []) : frame s = s := by
  simp [frame, h]

/-- Bounded latency: after any frame, nothing is pending. -/
theorem frame_drains {α : Type} (s : Coalescer α) : (frame s).pending = [] := by
  unfold frame; split <;> simp_all

/-- Non-vacuity: a burst of three deltas in one frame renders once and shows all of it. -/
example : run (Coalescer.empty) [.delta [1], .delta [2, 3], .delta [4], .tick] =
    { shown := [1, 2, 3, 4], pending := [], renders := 1 } := by decide

/-! ## 2. The committed Markdown prefix -/

/-- What the scanner needs from a line (whitespace trimmed at both ends):
    `blank` (empty), `tick` (starts with three backticks: the block parser's fence
    toggle) and `marker`, the pipe-table normalizer's fence marker (a run of at
    least three backticks or tildes; `true` for backticks, with its length). -/
structure Line where
  blank : Bool
  tick : Bool
  marker : Option (Bool × Nat)
  deriving Repr, DecidableEq

structure Scan where
  /-- Inside a block-parser code fence. -/
  tick : Bool
  /-- The normalizer's open fence, if any. -/
  fence : Option (Bool × Nat)
  /-- Lines scanned. -/
  pos : Nat
  /-- Lines committed: everything before this line index is final. -/
  commit : Nat
  deriving Repr, DecidableEq

def Scan.init : Scan := { tick := false, fence := none, pos := 0, commit := 0 }

/-- The normalizer closes a fence on a marker of the same character, at least as long. -/
def nextFence (open_ : Option (Bool × Nat)) (m : Option (Bool × Nat)) : Option (Bool × Nat) :=
  match open_, m with
  | some (c, n), some (c', n') => if c' = c ∧ n ≤ n' then none else some (c, n)
  | some f, none => some f
  | none, m => m

def isSpace (c : Char) : Bool := c == ' ' || c == '\t'

/-- Classifies a raw line (no newline) the way `parseBlocks` and the pipe-table
    normalizer read it: leading spaces and tabs dropped (ASCII; the Swift mirror uses
    the parser's own trimming). -/
def classify (raw : String) : Line :=
  let cs := raw.toList.dropWhile isSpace
  let marker := match cs with
    | c :: _ =>
      let n := (cs.takeWhile (· == c)).length
      if (c == '`' || c == '~') && 3 ≤ n then some (c == '`', n) else none
    | [] => none
  { blank := cs.all isSpace, tick := cs.take 3 == ['`', '`', '`'], marker }

def nextTick (s : Scan) (l : Line) : Bool := if l.tick then !s.tick else s.tick

/-- The line commits: it is blank and, after it, both fences are closed. -/
def commits (s : Scan) (l : Line) : Bool := l.blank && !nextTick s l && (nextFence s.fence l.marker).isNone

def scanLine (s : Scan) (l : Line) : Scan :=
  { tick := nextTick s l, fence := nextFence s.fence l.marker, pos := s.pos + 1,
    commit := if commits s l then s.pos + 1 else s.commit }

def scan (s : Scan) (ls : List Line) : Scan := ls.foldl scanLine s

def commitOf (ls : List Line) : Nat := (scan Scan.init ls).commit

theorem scanLine_pos (s : Scan) (l : Line) : (scanLine s l).pos = s.pos + 1 := rfl

theorem scan_pos (s : Scan) (ls : List Line) : (scan s ls).pos = s.pos + ls.length := by
  induction ls generalizing s with
  | nil => simp [scan]
  | cons l rest ih =>
    simp only [scan, List.foldl_cons] at *
    rw [ih, scanLine_pos]
    simp; omega

theorem scanLine_commit_mono (s : Scan) (l : Line) (h : s.commit ≤ s.pos) :
    s.commit ≤ (scanLine s l).commit ∧ (scanLine s l).commit ≤ (scanLine s l).pos := by
  by_cases hc : commits s l <;> simp [scanLine, hc] <;> omega

theorem scan_commit_mono (s : Scan) (ls : List Line) (h : s.commit ≤ s.pos) :
    s.commit ≤ (scan s ls).commit ∧ (scan s ls).commit ≤ (scan s ls).pos := by
  induction ls generalizing s with
  | nil => simp [scan]; omega
  | cons l rest ih =>
    simp only [scan, List.foldl_cons] at *
    have h1 := scanLine_commit_mono s l h
    have h2 := ih (scanLine s l) h1.2
    omega

/-- Bounded: the commit point never passes the end of what was scanned. -/
theorem commit_le_length (ls : List Line) : commitOf ls ≤ ls.length := by
  have := (scan_commit_mono Scan.init ls (by simp [Scan.init])).2
  rw [scan_pos] at this; simpa [commitOf, Scan.init] using this

/-- Stable: appending lines (the reply growing) never moves the commit point back,
    so blocks parsed before it stay valid. -/
theorem commit_monotone (xs ys : List Line) : commitOf xs ≤ commitOf (xs ++ ys) := by
  unfold commitOf scan
  rw [List.foldl_append]
  have h := (scan_commit_mono Scan.init xs (by simp [Scan.init])).2
  exact (scan_commit_mono (scan Scan.init xs) ys h).1

/-- The scanner state shifted by `n` lines. -/
def Scan.shift (s : Scan) (n : Nat) : Scan := { s with pos := s.pos + n, commit := s.commit + n }

theorem scanLine_shift (s : Scan) (n : Nat) (l : Line) : scanLine (s.shift n) l = (scanLine s l).shift n := by
  have e1 : commits (s.shift n) l = commits s l := rfl
  have e2 : nextTick (s.shift n) l = nextTick s l := rfl
  unfold scanLine; rw [e1, e2]
  cases commits s l <;> simp [Scan.shift] <;> omega

theorem scan_shift (s : Scan) (n : Nat) (ls : List Line) : scan (s.shift n) ls = (scan s ls).shift n := by
  induction ls generalizing s with
  | nil => rfl
  | cons l rest ih => simp only [scan, List.foldl_cons] at *; rw [scanLine_shift, ih]

/-- The scanner invariant: the commit point is behind the scan, and when it is at the
    scan's end both fences are closed (a commit happens only outside every fence). -/
def Scan.ok (s : Scan) : Prop := s.commit ≤ s.pos ∧ (s.commit = s.pos → s.tick = false ∧ s.fence = none)

theorem scanLine_ok (s : Scan) (l : Line) (h : s.ok) : (scanLine s l).ok := by
  by_cases hm : commits s l
  · simp [commits] at hm; simp [Scan.ok, scanLine, commits, hm]
  · simp [Scan.ok, scanLine, hm] at h ⊢; omega

theorem scan_ok (s : Scan) (ls : List Line) (h : s.ok) : (scan s ls).ok := by
  induction ls generalizing s with
  | nil => exact h
  | cons l rest ih => exact ih (scanLine s l) (scanLine_ok s l h)

/-- Resumable: scanning on from a commit point in a fresh state is the same as scanning
    from the start. This is what lets the parser start over at the commit point. -/
theorem resume_at_commit (xs ys : List Line) (h : commitOf xs = xs.length) :
    scan Scan.init (xs ++ ys) = (scan Scan.init ys).shift xs.length := by
  have hok := scan_ok Scan.init xs (by simp [Scan.ok, Scan.init])
  have closed : scan Scan.init xs = Scan.init.shift xs.length := by
    have hpos : (scan Scan.init xs).pos = xs.length := by simpa [Scan.init] using scan_pos Scan.init xs
    simp only [commitOf] at h
    have hc := hok.2 (by rw [h, hpos])
    generalize scan Scan.init xs = t at h hpos hc ⊢
    obtain ⟨tk, fe, ps, cm⟩ := t
    simp_all [Scan.shift, Scan.init]
  unfold scan; rw [List.foldl_append]
  unfold scan at closed; rw [closed]
  exact scan_shift Scan.init xs.length ys

def ln (blank tick : Bool) (marker : Option (Bool × Nat) := none) : Line := { blank, tick, marker }

/-- Non-vacuity: a paragraph, a blank line, then text: lines 0-1 are committed. -/
example : commitOf [ln false false, ln true false, ln false false] = 2 := by decide

/-- Tightness: a blank line inside an open code fence commits nothing. -/
example : commitOf [ln false true (some (true, 3)), ln true false, ln false false] = 0 := by decide

/-- A blank line inside a tilde fence (the normalizer's fence) commits nothing either. -/
example : commitOf [ln false false (some (false, 3)), ln true false, ln false false] = 0 := by decide

/-! ## 3. Cost: bytes re-parsed over a stream

Each update of a reply of `len` bytes, committed up to `commit`, parses the newly
committed chunk once and re-parses only the open tail. The total is the final committed
length plus the sum of the tails: linear when tails are bounded (`∀ u ∈ us, u.len - u.commit ≤ t`),
where a full re-parse per update costs the sum of all lengths (quadratic in the number of deltas).
Note: Without a bounded-tail assumption or host tail cap, a giant unclosed code fence holds
`commit` fixed while `u.len - u.commit` grows with the fence body. -/

structure Upd where
  len : Nat
  commit : Nat
  deriving Repr, DecidableEq

/-- Commit points only move forward and never pass the text (`commit_monotone`, `commit_le_length`). -/
def Mono : Nat → List Upd → Prop
  | _, [] => True
  | prev, u :: us => prev ≤ u.commit ∧ u.commit ≤ u.len ∧ Mono u.commit us

/-- Bytes parsed by the incremental parser: the new chunk, then the tail. -/
def incCost : Nat → List Upd → Nat
  | _, [] => 0
  | prev, u :: us => (u.commit - prev) + (u.len - u.commit) + incCost u.commit us

/-- Bytes parsed by a full re-parse per update. -/
def fullCost : List Upd → Nat
  | [] => 0
  | u :: us => u.len + fullCost us

def tails : List Upd → Nat
  | [] => 0
  | u :: us => (u.len - u.commit) + tails us

def lastCommit : Nat → List Upd → Nat
  | prev, [] => prev
  | _, u :: us => lastCommit u.commit us

theorem lastCommit_ge (prev : Nat) (us : List Upd) (h : Mono prev us) : prev ≤ lastCommit prev us := by
  induction us generalizing prev with
  | nil => simp [lastCommit]
  | cons u us ih =>
    have := ih u.commit h.2.2
    have := h.1
    simp only [lastCommit]; omega

/-- The cost identity: the committed text is parsed once, plus every tail. -/
theorem incCost_eq (prev : Nat) (us : List Upd) (h : Mono prev us) :
    incCost prev us + prev = lastCommit prev us + tails us := by
  induction us generalizing prev with
  | nil => simp [incCost, lastCommit, tails]
  | cons u us ih =>
    have := ih u.commit h.2.2
    have := h.1
    simp only [incCost, lastCommit, tails]; omega

/-- Linear: with tails of at most `t` bytes, `n` updates of a reply ending at `last` bytes
    re-parse at most `last + n * t` bytes. -/
theorem incCost_linear (us : List Upd) (h : Mono 0 us) (t last : Nat)
    (ht : ∀ u ∈ us, u.len - u.commit ≤ t) (hl : lastCommit 0 us ≤ last) :
    incCost 0 us ≤ last + us.length * t := by
  have e := incCost_eq 0 us h
  have : tails us ≤ us.length * t := by
    clear e h hl
    induction us with
    | nil => simp [tails]
    | cons u us ih =>
      have h1 := ht u (by simp)
      have h2 := ih (fun v hv => ht v (by simp [hv]))
      simp only [tails, List.length_cons, Nat.succ_mul]; omega
  omega

/-- Never worse than re-parsing everything on every update. -/
theorem incCost_le_full (prev : Nat) (us : List Upd) (h : Mono prev us) : incCost prev us ≤ fullCost us := by
  induction us generalizing prev with
  | nil => simp [incCost, fullCost]
  | cons u us ih =>
    have := ih u.commit h.2.2
    have := h.2.1
    simp only [incCost, fullCost]
    -- Each later update's length is at least its commit, which is at least this commit.
    have hf : incCost u.commit us + u.commit ≤ fullCost us + u.commit := by omega
    omega

/-- Tightness: three updates of a two-paragraph reply cost 13 bytes incrementally, 18 in full. -/
example : incCost 0 [⟨4, 0⟩, ⟨6, 5⟩, ⟨8, 5⟩] = 13 ∧ fullCost [⟨4, 0⟩, ⟨6, 5⟩, ⟨8, 5⟩] = 18 := by decide

/-! ## 4. The parse cache: keyed by text, bounded, evicts only its oldest entry

Entries are most recent first. A lookup compares the text itself (no hash collisions); an
insert moves its key to the front and drops at most one entry, the oldest. The old policy,
clearing everything once full, re-parsed the whole transcript after each long reply. -/

structure Cache (V : Type) where
  entries : List (String × V)
  deriving Repr

def lookup {V : Type} (c : Cache V) (k : String) : Option V := (c.entries.find? (·.1 == k)).map (·.2)

def insert {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V) : Cache V :=
  { entries := ((k, v) :: c.entries.filter (·.1 != k)).take cap }

/-- Bounded. -/
theorem insert_size {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V) :
    (insert cap c k v).entries.length ≤ cap := by
  simp [insert, List.length_take]; omega

/-- What was inserted is found, under exactly that text. -/
theorem insert_lookup {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V) (h : 0 < cap) :
    lookup (insert cap c k v) k = some v := by
  obtain ⟨n, rfl⟩ : ∃ n, cap = n + 1 := ⟨cap - 1, by omega⟩
  simp [lookup, insert, List.take_succ_cons]

/-- Keyed by the text: a hit is an entry stored under an equal text. -/
theorem lookup_mem {V : Type} (c : Cache V) (k : String) (v : V) (h : lookup c k = some v) :
    (k, v) ∈ c.entries := by
  simp only [lookup, Option.map_eq_some_iff] at h
  obtain ⟨e, he, rfl⟩ := h
  have hk := List.find?_some he
  have hm := List.mem_of_find?_eq_some he
  simp at hk; rw [← hk]; exact hm

/-- Eviction only drops a suffix (the oldest entries) of the recency order. -/
theorem insert_evicts_oldest {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V) :
    ∃ dropped, (k, v) :: c.entries.filter (·.1 != k) = (insert cap c k v).entries ++ dropped := by
  exact ⟨_, (List.take_append_drop cap _).symm⟩

/-- Never wholesale: an insert into a cache within capacity drops at most one entry. -/
theorem insert_drops_at_most_one {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V)
    (h : c.entries.length ≤ cap) : ((k, v) :: c.entries.filter (·.1 != k)).length - cap ≤ 1 := by
  have := List.length_filter_le (·.1 != k) c.entries
  simp only [List.length_cons]; omega

/-- The old policy: clear everything once over capacity. -/
def clearWhenFull {V : Type} (cap : Nat) (c : Cache V) (k : String) (v : V) : Cache V :=
  if c.entries.length ≥ cap then { entries := [(k, v)] } else { entries := (k, v) :: c.entries }

/-- Tightness: with three entries and capacity 3, the old policy keeps one; the LRU keeps three. -/
example : (clearWhenFull 3 ⟨[("a", 1), ("b", 2), ("c", 3)]⟩ "d" 4).entries.length = 1 ∧
    (insert 3 ⟨[("a", 1), ("b", 2), ("c", 3)]⟩ "d" 4).entries.length = 3 := by decide

/-! ## 5. Committed bytes of a streamed string (fixture generation)

Only newline-terminated lines can commit: the last line is still growing. -/

def committedLen (s : String) : Nat :=
  let lines := (s.splitOn "\n").dropLast
  let k := commitOf (lines.map classify)
  ((lines.take k).map (fun l => l.utf8ByteSize + 1)).sum

/-! ## 6. Bounded-Tail Checkpointed Stream Scanner (Closing `G-ORB-6`)

When an unclosed Markdown code fence grows beyond `maxOpenTailBytes` (`0 < maxOpenTailBytes`),
`commitOf` holds `commit` fixed while `len - commit` grows linearly, causing quadratic re-parse
work unless a bounded-tail checkpoint advances the re-parse cursor. `BoundedStreamState` tracks
both the true Markdown `commit` offset and a monotone `checkpoint` cursor (`commit ≤ checkpoint ≤ len`)
such that whenever `len - checkpoint > maxOpenTailBytes`, `checkpoint` advances to
`len - maxOpenTailBytes`. Re-parsing from `checkpoint` yields `boundedCost`, which satisfies the
unconditional $O(N)$ bound `boundedCost_linear` WITHOUT any external `ht` tail-size assumption,
and produces identical final `(len, commit, checkpoint)` state across arbitrary chunk splits
(`boundedStream_chunk_split_invariant`). -/

structure BoundedStreamState where
  len        : Nat
  commit     : Nat
  checkpoint : Nat
  deriving Repr, DecidableEq

def BoundedStreamState.init : BoundedStreamState :=
  { len := 0, commit := 0, checkpoint := 0 }

def BoundedStreamState.WellFormed (cap : Nat) (s : BoundedStreamState) : Prop :=
  s.commit ≤ s.checkpoint ∧ s.checkpoint ≤ s.len ∧ s.len - s.checkpoint ≤ cap

/-- Advance `BoundedStreamState` on a monotone update `u` under open-tail cap `cap`:
    updates `commit' = max s.commit (min u.commit nextLen)` and advances `checkpoint'` to at least
    `nextLen - cap` whenever the unclosed fence tail exceeds `cap`. -/
def stepBoundedStream (cap : Nat) (s : BoundedStreamState) (u : Upd) : BoundedStreamState :=
  let nextLen := max s.len u.len
  let nextCommit := max s.commit (min u.commit nextLen)
  let baseCheckpoint := max s.checkpoint nextCommit
  let nextCheckpoint := max baseCheckpoint (nextLen - cap)
  { len := nextLen, commit := nextCommit, checkpoint := nextCheckpoint }

def foldBoundedStream (cap : Nat) (s : BoundedStreamState) (us : List Upd) : BoundedStreamState :=
  us.foldl (stepBoundedStream cap) s

/-- Incremental bytes parsed per update using the bounded-tail checkpoint cursor:
    newly checkpointed bytes `(s'.checkpoint - s.checkpoint)` plus the bounded open tail
    `(s'.len - s'.checkpoint)`. -/
def boundedCost (cap : Nat) : BoundedStreamState → List Upd → Nat
  | _, [] => 0
  | s, u :: us =>
    let s' := stepBoundedStream cap s u
    (s'.checkpoint - s.checkpoint) + (s'.len - s'.checkpoint) + boundedCost cap s' us

def boundedTails (cap : Nat) : BoundedStreamState → List Upd → Nat
  | _, [] => 0
  | s, u :: us =>
    let s' := stepBoundedStream cap s u
    (s'.len - s'.checkpoint) + boundedTails cap s' us

theorem stepBoundedStream_wellFormed (cap : Nat) (s : BoundedStreamState) (u : Upd)
    (hs : s.WellFormed cap) :
    s.len ≤ (stepBoundedStream cap s u).len ∧
    s.commit ≤ (stepBoundedStream cap s u).commit ∧
    s.checkpoint ≤ (stepBoundedStream cap s u).checkpoint ∧
    (stepBoundedStream cap s u).WellFormed cap := by
  rcases hs with ⟨hc1, hc2, hc3⟩
  dsimp [stepBoundedStream, BoundedStreamState.WellFormed]
  omega

theorem foldBoundedStream_checkpoint_le_len (cap : Nat) (s : BoundedStreamState) (us : List Upd)
    (hs : s.WellFormed cap) :
    s.checkpoint ≤ (foldBoundedStream cap s us).checkpoint ∧
    (foldBoundedStream cap s us).WellFormed cap := by
  induction us generalizing s with
  | nil => exact ⟨Nat.le_refl _, hs⟩
  | cons u us ih =>
    have hstep := stepBoundedStream_wellFormed cap s u hs
    have hrest := ih (stepBoundedStream cap s u) hstep.2.2.2
    simp only [foldBoundedStream, List.foldl_cons] at hrest ⊢
    exact ⟨Nat.le_trans hstep.2.2.1 hrest.1, hrest.2⟩

theorem boundedCost_eq (cap : Nat) (s : BoundedStreamState) (us : List Upd)
    (hs : s.WellFormed cap) :
    boundedCost cap s us + s.checkpoint =
      (foldBoundedStream cap s us).checkpoint + boundedTails cap s us := by
  induction us generalizing s with
  | nil => simp [boundedCost, foldBoundedStream, boundedTails]
  | cons u us ih =>
    have hstep := stepBoundedStream_wellFormed cap s u hs
    have hih := ih (stepBoundedStream cap s u) hstep.2.2.2
    simp only [boundedCost, foldBoundedStream, List.foldl_cons, boundedTails] at hih ⊢
    omega

theorem boundedTails_le (cap : Nat) (s : BoundedStreamState) (us : List Upd)
    (hs : s.WellFormed cap) :
    boundedTails cap s us ≤ us.length * cap := by
  induction us generalizing s with
  | nil => simp [boundedTails]
  | cons u us ih =>
    have hstep := stepBoundedStream_wellFormed cap s u hs
    have hih := ih (stepBoundedStream cap s u) hstep.2.2.2
    have htail : (stepBoundedStream cap s u).len - (stepBoundedStream cap s u).checkpoint ≤ cap :=
      hstep.2.2.2.2.2
    simp only [boundedTails, List.length_cons, Nat.succ_mul]
    omega

/-- Unconditional $O(N)$ linear re-parse bound (`G-ORB-6` remediation):
    Without ANY external `ht` tail-size hypothesis on `us` (even when `u.commit = 0` throughout
    a giant unclosed code fence), `boundedCost` over `us` is bounded by `last + us.length * cap`. -/
theorem boundedCost_linear (cap : Nat) (us : List Upd) (last : Nat)
    (hl : (foldBoundedStream cap BoundedStreamState.init us).len ≤ last) :
    boundedCost cap BoundedStreamState.init us ≤ last + us.length * cap := by
  have hinit : BoundedStreamState.init.WellFormed cap := by
    simp [BoundedStreamState.init, BoundedStreamState.WellFormed]
  have heq := boundedCost_eq cap BoundedStreamState.init us hinit
  have hwf := (foldBoundedStream_checkpoint_le_len cap BoundedStreamState.init us hinit).2
  have htails := boundedTails_le cap BoundedStreamState.init us hinit
  have hcp : (foldBoundedStream cap BoundedStreamState.init us).checkpoint ≤ last :=
    Nat.le_trans hwf.2.1 hl
  have h0 : BoundedStreamState.init.checkpoint = 0 := rfl
  rw [h0, Nat.add_zero] at heq
  omega

/-- Chunk-split associativity (`foldBoundedStream` over `xs ++ ys` equals sequential chunk folds):
    splitting a streamed update trace across arbitrary chunk boundaries yields the exact same
    `(len, commit, checkpoint)` state. -/
theorem boundedStream_chunk_split_invariant (cap : Nat) (s : BoundedStreamState) (xs ys : List Upd) :
    foldBoundedStream cap s (xs ++ ys) = foldBoundedStream cap (foldBoundedStream cap s xs) ys := by
  simp [foldBoundedStream, List.foldl_append]

/-- Chunk-delta equivalence: feeding two cumulative monotone updates `[u1, u2]` (`u1.len ≤ u2.len`,
    `u1.commit ≤ u2.commit ≤ u2.len`) from `BoundedStreamState.init` produces the exact same
    bounded checkpoint state as delivering `u2` in a single coalesced frame `[u2]`. -/
theorem boundedStream_coalesced_eq_split (cap : Nat) (u1 u2 : Upd)
    (hlen : u1.len ≤ u2.len) (hcom : u1.commit ≤ u2.commit) (hwf2 : u2.commit ≤ u2.len) :
    foldBoundedStream cap BoundedStreamState.init [u1, u2] =
      foldBoundedStream cap BoundedStreamState.init [u2] := by
  simp only [foldBoundedStream, List.foldl_cons, List.foldl_nil,
    BoundedStreamState.init, stepBoundedStream]
  congr 1 <;> omega

end Orb.Stream
