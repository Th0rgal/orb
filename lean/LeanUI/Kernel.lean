import LeanUI.Defs
/-!
# LeanUI.Kernel — pure layout, rounding, damage, hit-test, focus and atlas kernels

Signatures here are frozen for the campaign; `LeanUI/Spec/*` states contracts over them.
-/
namespace LeanUI

/-! ## Flex main-axis distribution -/

/-- Cumulative share of `free` owed to the first `acc` grow units out of `total`. -/
@[inline] def cumShare (free total acc : Nat) : Nat :=
  if total = 0 then 0 else free * acc / total

/-- Split `free` across grow weights. Each child gets the difference of consecutive
cumulative shares, so rounding never loses or invents a sub-unit. -/
def distribute (free total : Nat) : Nat → List Nat → List Nat
  | _, [] => []
  | acc, g :: gs => (cumShare free total (acc + g) - cumShare free total acc)
      :: distribute free total (acc + g) gs

@[inline] def clampNat (lo hi v : Nat) : Nat := max lo (min hi v)

/-- Main sizes for one flex line of `avail` sub-units (single pass, clamp after grow). -/
def flexMain (avail : Nat) (items : List FlexItem) : List Nat :=
  let bases := items.map (·.basis)
  let grows := items.map (·.grow)
  let free := avail - bases.sum
  let extra := distribute free grows.sum 0 grows
  (items.zip extra).map fun (it, e) => clampNat it.minMain it.maxMain (it.basis + e)

/-- Shrink sizes for one overflowing flex line: distributes deficit `(bases.sum - avail)` across `weights`, clamped to `minMain`. -/
def flexApplyShrink : List FlexItem → List Nat → List Nat
  | [], _ => []
  | _, [] => []
  | it :: its, c :: cs => clampNat it.minMain it.maxMain (it.basis - c) :: flexApplyShrink its cs

def flexShrink (avail : Nat) (items : List FlexItem) (weights : List Nat) : List Nat :=
  let bases := items.map (·.basis)
  let deficit := bases.sum - avail
  let cut := distribute deficit weights.sum 0 weights
  flexApplyShrink items cut

/-- Freeze items whose grow share hits `maxMain`, then redistribute the remaining space across the unfrozen items. -/
def flexFreezeBase : List FlexItem → List Bool → List Nat
  | [], _ => []
  | _, [] => []
  | it :: its, f :: fs => (if f then it.maxMain else it.basis) :: flexFreezeBase its fs

def flexFreezeGrow : List FlexItem → List Bool → List Nat
  | [], _ => []
  | _, [] => []
  | it :: its, f :: fs => (if f then 0 else it.grow) :: flexFreezeGrow its fs

def flexApplyRedistribute : List FlexItem → List Bool → List Nat → List Nat
  | [], _, _ => []
  | _, [], _ => []
  | _, _, [] => []
  | it :: its, f :: fs, e :: es =>
    clampNat it.minMain it.maxMain ((if f then it.maxMain else it.basis) + e) ::
      flexApplyRedistribute its fs es

def flexRedistribute (avail : Nat) (items : List FlexItem) (frozen : List Bool) : List Nat :=
  let bases1 := flexFreezeBase items frozen
  let grows1 := flexFreezeGrow items frozen
  let free1 := avail - bases1.sum
  let extra1 := distribute free1 grows1.sum 0 grows1
  flexApplyRedistribute items frozen extra1

def flexMainClamped (avail : Nat) (items : List FlexItem) : List Nat :=
  let bases := items.map (·.basis)
  let grows := items.map (·.grow)
  let free0 := avail - bases.sum
  let extra0 := distribute free0 grows.sum 0 grows
  let frozen := (items.zip extra0).map fun (it, e) => it.maxMain ≤ it.basis + e
  flexRedistribute avail items frozen

/-! ## Device-pixel rounding -/

/-- Round a logical `Sub` coordinate to the nearest device pixel at `scale120` (ties up). -/
@[inline] def roundDev (scale120 : Nat) (v : Int) : Int :=
  (v * scale120 + (subPerPx * scaleDen / 2 : Nat)) / (subPerPx * scaleDen : Nat)

/-- Round a rect by its edges (not its size), so shared edges stay shared. -/
@[inline] def roundRect (scale120 : Nat) (r : Rect) : Rect :=
  let x0 := roundDev scale120 r.x
  let y0 := roundDev scale120 r.y
  { x := x0, y := y0, w := roundDev scale120 r.right - x0, h := roundDev scale120 r.bottom - y0 }

/-- Largest device pixel boundary at or below a logical coordinate. -/
@[inline] def floorDev (scale120 : Nat) (v : Int) : Int :=
  (v * scale120) / (subPerPx * scaleDen : Nat)

/-- Smallest device pixel boundary at or above a logical coordinate. -/
@[inline] def ceilDev (scale120 : Nat) (v : Int) : Int :=
  -((-(v * scale120)) / (subPerPx * scaleDen : Nat))

/-- Round a rect outward, for damage: every partly covered device pixel is included. -/
@[inline] def roundRectOut (scale120 : Nat) (r : Rect) : Rect :=
  let x0 := floorDev scale120 r.x
  let y0 := floorDev scale120 r.y
  { x := x0, y := y0, w := ceilDev scale120 r.right - x0, h := ceilDev scale120 r.bottom - y0 }

/-! ## Damage -/

/-- Bounding box of two rects. -/
@[inline] def Rect.union (a b : Rect) : Rect :=
  let x0 := min a.x b.x
  let y0 := min a.y b.y
  { x := x0, y := y0, w := max a.right b.right - x0, h := max a.bottom b.bottom - y0 }

/-- Add a dirty rect; empty rects never create damage. -/
@[inline] def Damage.add (d : Damage) (r : Rect) : Damage :=
  if r.isEmpty then d else
    match d with
    | none => some r
    | some a => some (a.union r)

@[inline] def Damage.covers (d : Damage) (px py : Int) : Bool :=
  match d with
  | none => false
  | some a => a.contains px py

/-- A frame is submitted iff there is damage. -/
@[inline] def needsRedraw (d : Damage) : Bool := d.isSome

/-! ## Hit testing -/

/-- Topmost region containing the point; `regions` is in paint order (last is on top). -/
def hitTest (regions : List (EntityId × Rect)) (px py : Int) : Option EntityId :=
  regions.foldl (fun acc (id, r) => if r.contains px py then some id else acc) none

/-! ## Focus -/

namespace FocusState

/-- May `id` take focus given the current modal traps? -/
@[inline] def admits (s : FocusState) (id : EntityId) : Bool :=
  match s.traps with
  | [] => true
  | t :: _ => t.contains id

/-- Request focus; refused (state unchanged) when a modal trap excludes `id`. -/
@[inline] def request (s : FocusState) (id : EntityId) : FocusState :=
  if s.admits id then { s with owner := some id } else s

@[inline] def blur (s : FocusState) : FocusState := { s with owner := none }

/-- Open a modal: focus is dropped unless the owner is inside the new trap. -/
@[inline] def pushTrap (s : FocusState) (ids : List EntityId) : FocusState :=
  { owner := s.owner.filter ids.contains, traps := ids :: s.traps }

/-- Close the innermost modal; focus is dropped (the caller restores it explicitly). -/
@[inline] def popTrap (s : FocusState) : FocusState :=
  { owner := none, traps := s.traps.drop 1 }

/-- The confinement invariant: the owner, if any, is admitted by the top trap. -/
def Confined (s : FocusState) : Prop :=
  ∀ id, s.owner = some id → s.admits id = true

end FocusState

/-! ## Glyph atlas shelf allocator -/

namespace Atlas

/-- Texel rectangle a shelf would hand out for a `w`-wide glyph. -/
@[inline] def slot (s : Shelf) (w h : Nat) : Rect :=
  { x := s.used, y := s.y, w := w, h := h }

/-- First shelf that fits `w × h`, returning the slot and the updated shelf list. -/
def fitShelf (width w h : Nat) : List Shelf → Option (Rect × List Shelf)
  | [] => none
  | s :: rest =>
    if h ≤ s.h ∧ s.used + w ≤ width then
      some (slot s w h, { s with used := s.used + w } :: rest)
    else
      (fitShelf width w h rest).map fun (r, rest') => (r, s :: rest')

/-- Allocate `w × h` texels. `none` means the atlas is full and the state is unchanged. -/
def alloc (a : Atlas) (w h : Nat) : Option (Rect × Atlas) :=
  if w = 0 ∨ h = 0 ∨ w > a.width then none else
    match fitShelf a.width w h a.shelves with
    | some (r, shelves) => some (r, { a with shelves := shelves })
    | none =>
      if a.nextY + h ≤ a.height then
        let s : Shelf := { y := a.nextY, h := h, used := w }
        some ({ x := 0, y := a.nextY, w := w, h := h },
              { a with shelves := a.shelves ++ [s], nextY := a.nextY + h })
      else none

/-- Clear all shelves while preserving atlas dimensions. -/
@[inline] def reset (a : Atlas) : Atlas :=
  { width := a.width, height := a.height, shelves := [], nextY := 0 }

/-- Allocate a `w × h` glyph surrounded by `pad` guard texels on the right and bottom.
Returns the inner `w × h` glyph rect and the updated atlas; the `pad` border is reserved in the shelf. -/
def allocPadded (a : Atlas) (pad w h : Nat) : Option (Rect × Atlas) :=
  if w = 0 ∨ h = 0 then none else
    (a.alloc (w + pad) (h + pad)).map fun (r, a') =>
      ({ x := r.x, y := r.y, w := w, h := h }, a')

/-- Allocate across a page list: places in the first page with room, or appends a fresh `pw × ph` page. -/
def allocPages (pw ph w h : Nat) : List Atlas → Option (Nat × Rect × List Atlas)
  | [] =>
    match ({ width := pw, height := ph } : Atlas).alloc w h with
    | some (r, a') => some (0, r, [a'])
    | none => none
  | a :: rest =>
    match a.alloc w h with
    | some (r, a') => some (0, r, a' :: rest)
    | none =>
      (allocPages pw ph w h rest).map fun (idx, r, rest') => (idx + 1, r, a :: rest')

end Atlas

/-! ## Hash-keyed cache -/

/-- Cache keyed by a finite hash; values are only sound under `CollisionFreeOn`. -/
structure HashCache (β : Type) where
  entries : List (UInt64 × β) := []

namespace HashCache
variable {α β : Type}

@[inline] def insert (c : HashCache β) (hash : α → UInt64) (k : α) (v : β) : HashCache β :=
  { entries := (hash k, v) :: c.entries }

@[inline] def lookup (c : HashCache β) (hash : α → UInt64) (k : α) : Option β :=
  (c.entries.find? (·.1 == hash k)).map (·.2)

end HashCache

@[inline] def scrollLimit (content viewport : Nat) : Nat := content - viewport

@[inline] def scrollStep (content viewport offset : Nat) (delta : Int) : Nat :=
  (max 0 (min (scrollLimit content viewport : Int) ((offset : Int) + delta))).toNat

@[inline] def resizeSub (logicalPixels : Nat) : Nat := logicalPixels * subPerPx

@[inline] def bufferSize (scale120 logicalPixels : Nat) : Nat :=
  (logicalPixels * scale120 + scaleDen - 1) / scaleDen

@[inline] def focusBorder (focused : Bool) (rect : Rect) (color : Color) : Prim :=
  .quad rect 0 0 (if focused then 1 else 0) color

@[inline] def focusBorderDamage (before after : Bool) (rect : Rect) : Damage :=
  if before == after then none else Damage.add none rect

end LeanUI
