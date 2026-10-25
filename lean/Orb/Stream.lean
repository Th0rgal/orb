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

end Orb.Stream
