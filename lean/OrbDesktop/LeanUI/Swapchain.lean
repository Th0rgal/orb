import LeanUI.Defs
import LeanUI.Kernel
/-!
# LeanUI.Swapchain — Executable Vulkan 1.3 Swapchain & Synchronization State Machine

Core formal state machine (`0 import Lean`, `0 sorryAx`) shared directly between the
production Vulkan runtime (`LeanUI.VulkanSwapchain`) and the formal verification shards
(`LeanUI.Spec.SwapchainSpec` and `LeanUI.Spec.MutantSuite`).

Models `MAX_FRAMES_IN_FLIGHT = 2` CPU/GPU frame slots orthogonally to `imageCount ≥ 2`
WSI swapchain images (e.g. `MAILBOX` triple buffering), enforcing:
- Serial WSI acquire/present ownership (`acquiredCount ≤ 1`)
- Cross-slot `MAILBOX` re-acquire fence waits (`imageFence[imgIdx]`)
- No-deadlock fence reset ordering (reset strictly after acquire succeeds)
- Disjoint per-slot `imageAvailable` vs per-image `renderFinished` semaphores
- Resize-in-flight / zero-extent suspension and `StickyFence` teardown absorbing state
-/
namespace LeanUI.Swapchain

/-- Number of concurrent CPU/GPU frame slots (`MAX_FRAMES_IN_FLIGHT`). -/
def maxFramesInFlight : Nat := 2

/-- Outcome of `vkAcquireNextImageKHR` / `vkQueuePresentKHR`. -/
inductive WsiResult where
  | success
  | suboptimal
  | outOfDate
  | surfaceLost
  | deviceLost
  deriving DecidableEq, Repr, Inhabited

/-- Lifecycle phase of a Vulkan swapchain. -/
inductive SwapchainPhase where
  | uninitialized
  | ready (extentW extentH : Nat) (imageCount : Nat)
  | suspendedZeroExtent
  | needsRecreate (extentW extentH : Nat)
  | deviceLostFallbackShm
  | destroyed
  deriving DecidableEq, Repr, Inhabited

/-- CPU/GPU execution state for one of the 2 in-flight frame slots,
retired exclusively by `vkWaitForFences(inFlightFence[slot])`. -/
inductive FrameSlotState where
  | idle
  | submitted (imgIdx : Nat)
  deriving DecidableEq, Repr, Inhabited

/-- WSI ownership state of one swapchain image (independent of `maxFramesInFlight`). -/
inductive WsiImageState where
  | withPresentEngine
  | acquired (slot : Fin 2)
  deriving DecidableEq, Repr, Inhabited

/-- Fence state for each in-flight frame slot (`signaled` means `vkWaitForFences` will not deadlock). -/
inductive FenceState where
  | signaled
  | unsignaled
  deriving DecidableEq, Repr, Inhabited

/-- Complete observable state of the Vulkan swapchain and synchronization primitives. -/
structure SwapchainState where
  phase : SwapchainPhase := .uninitialized
  curSlot : Fin 2 := ⟨0, by decide⟩
  frameSlots : Fin 2 → FrameSlotState := fun _ => .idle
  fences : Fin 2 → FenceState := fun _ => .signaled
  /-- Length equals `imageCount` when `phase = .ready _ _ imageCount`. -/
  images : List WsiImageState := []
  /-- Last frame slot whose GPU submission touched image `i` and has not yet been retired. -/
  imageFence : List (Option (Fin 2)) := []
  /-- Whether `vkDeviceWaitIdle` was executed before resource destruction. -/
  waitIdleDone : Bool := false
  acquireCount : Nat := 0
  submitCount : Nat := 0
  presentCount : Nat := 0
  recreateCount : Nat := 0
  deriving Inhabited

namespace SwapchainState

/-- Semaphore index for `imageAvailable`: owned by `frameSlot : Fin 2`. -/
@[inline] def imageAvailableSemIndex (slot : Fin 2) : Nat := slot.val

/-- Semaphore index for `renderFinished`: owned by `swapchainImageIndex` (NOT `frameSlot`). -/
@[inline] def renderFinishedSemIndex (imgIdx : Nat) : Nat := imgIdx

/-- Step function for counting acquired WSI images. -/
def acquiredInc (n : Nat) : WsiImageState → Nat
  | .withPresentEngine => n
  | .acquired _ => n + 1

/-- Count how many swapchain images are currently acquired from WSI. -/
def acquiredCount (s : SwapchainState) : Nat :=
  s.images.foldl acquiredInc 0

/-- Whether `s` is in `ready` phase with matching non-zero extent `(bw, bh)` and valid `imageCount ≥ 2`. -/
def isReadyForExtent (s : SwapchainState) (bw bh : Nat) : Bool :=
  match s.phase with
  | .ready w h n => w == bw && h == bh && w > 0 && h > 0 && n ≥ 2
  | _ => false

/-- Initialize or recreate the swapchain for `(w, h)` with `imageCount` images.
Zero extent transitions to `suspendedZeroExtent`; destroyed/deviceLost states are absorbing. -/
def initOrRecreate (s : SwapchainState) (w h imageCount : Nat) : SwapchainState :=
  match s.phase with
  | .destroyed | .deviceLostFallbackShm => s
  | _ =>
    if w == 0 || h == 0 then
      { s with
        phase := .suspendedZeroExtent
        frameSlots := fun _ => .idle
        fences := fun _ => .signaled
        images := []
        imageFence := []
        waitIdleDone := true }
    else if imageCount < 2 then
      { s with
        phase := .needsRecreate w h
        frameSlots := fun _ => .idle
        fences := fun _ => .signaled
        images := []
        imageFence := []
        waitIdleDone := true }
    else
      let isRecreate := match s.phase with | .uninitialized => false | _ => true
      { s with
        phase := .ready w h imageCount
        frameSlots := fun _ => .idle
        fences := fun _ => .signaled
        images := List.replicate imageCount .withPresentEngine
        imageFence := List.replicate imageCount none
        waitIdleDone := true
        recreateCount := if isRecreate then s.recreateCount + 1 else s.recreateCount }

/-- Notify the state machine of a new window/buffer extent `(bw, bh)`. -/
def onExtentChanged (s : SwapchainState) (bw bh : Nat) : SwapchainState :=
  match s.phase with
  | .destroyed | .deviceLostFallbackShm => s
  | .ready w h _ =>
    if bw == 0 || bh == 0 then
      { s with
        phase := .suspendedZeroExtent
        frameSlots := fun _ => .idle
        fences := fun _ => .signaled
        images := []
        imageFence := []
        waitIdleDone := true }
    else if w != bw || h != bh then
      { s with phase := .needsRecreate bw bh }
    else s
  | .suspendedZeroExtent =>
    if bw > 0 && bh > 0 then { s with phase := .needsRecreate bw bh } else s
  | .needsRecreate _ _ =>
    if bw == 0 || bh == 0 then { s with phase := .suspendedZeroExtent }
    else { s with phase := .needsRecreate bw bh }
  | .uninitialized =>
    if bw == 0 || bh == 0 then { s with phase := .suspendedZeroExtent } else s

/-- Retire `slot` via `vkWaitForFences(inFlightFence[slot])`, clearing any `imageFence` pointing to `slot`. -/
def waitSlotFence (s : SwapchainState) (slot : Fin 2) : SwapchainState :=
  match s.phase with
  | .destroyed | .deviceLostFallbackShm => s
  | _ =>
    { s with
      frameSlots := fun k => if k == slot then .idle else s.frameSlots k
      fences := fun k => if k == slot then .signaled else s.fences k
      imageFence := s.imageFence.map fun f => if f == some slot then none else f }

/-- Cross-slot `MAILBOX` re-acquire guard: if `imageFence[imgIdx] = some prevSlot` with
`prevSlot ≠ curSlot`, retire `prevSlot` via `vkWaitForFences` before submitting work to `imgIdx`. -/
def guardImageFence (s : SwapchainState) (imgIdx : Nat) : SwapchainState :=
  match s.imageFence[imgIdx]? with
  | some (some prevSlot) =>
    if prevSlot != s.curSlot then s.waitSlotFence prevSlot else s
  | _ => s

/-- Step `vkAcquireNextImageKHR` for `s.curSlot`, leaving `fences[curSlot]` signaled on failure
so `OUT_OF_DATE` / `SURFACE_LOST` can never deadlock the next `vkWaitForFences`. -/
def onAcquire (s : SwapchainState) (res : WsiResult) (imgIdx : Nat) : SwapchainState :=
  match s.phase with
  | .ready w h n =>
    if s.acquiredCount != 0 then s
    else
      match res with
      | .success | .suboptimal =>
        if imgIdx < n then
          let s1 := { s with
            images := s.images.set imgIdx (.acquired s.curSlot)
            acquireCount := s.acquireCount + 1 }
          s1.guardImageFence imgIdx
        else s
      | .outOfDate | .surfaceLost =>
        { s with phase := .needsRecreate w h }
      | .deviceLost =>
        { s with
          phase := .deviceLostFallbackShm
          frameSlots := fun _ => .idle
          fences := fun _ => .signaled
          images := []
          imageFence := [] }
  | _ => s

/-- Can `submitAndPresent` legally execute for `imgIdx` on `s.curSlot`?
Requires: ready phase, matching non-zero extent, `images[imgIdx] == acquired curSlot`,
`frameSlots[curSlot] == idle`, and `imageFence[imgIdx]` is either `none` or `some curSlot`. -/
def canSubmit (s : SwapchainState) (bw bh imgIdx : Nat) : Bool :=
  s.isReadyForExtent bw bh &&
  s.images[imgIdx]? == some (.acquired s.curSlot) &&
  s.frameSlots s.curSlot == .idle &&
  match s.imageFence[imgIdx]? with
  | some none => true
  | some (some owner) => owner == s.curSlot
  | none => false

/-- Execute `vkResetFences` + `vkQueueSubmit2` + `vkQueuePresentKHR` atomically in the model.
Advances `curSlot := (curSlot + 1) % 2` and hands `imgIdx` back to `.withPresentEngine`. -/
def onSubmitAndPresent (s : SwapchainState) (bw bh imgIdx : Nat) (presentRes : WsiResult) :
    SwapchainState :=
  if !s.canSubmit bw bh imgIdx then s
  else
    let slot := s.curSlot
    let nextSlot : Fin 2 := ⟨(slot.val + 1) % 2, Nat.mod_lt _ (by decide)⟩
    let submitted : SwapchainState := {
      s with
      curSlot := nextSlot
      frameSlots := fun k => if k == slot then .submitted imgIdx else s.frameSlots k
      fences := fun k => if k == slot then .unsignaled else s.fences k
      images := s.images.set imgIdx .withPresentEngine
      imageFence := s.imageFence.set imgIdx (some slot)
      submitCount := s.submitCount + 1
      presentCount := s.presentCount + 1
    }
    match s.phase, presentRes with
    | .ready w h _, .outOfDate | .ready w h _, .suboptimal | .ready w h _, .surfaceLost =>
      { submitted with phase := .needsRecreate w h }
    | _, .deviceLost =>
      { submitted with
        phase := .deviceLostFallbackShm
        frameSlots := fun _ => .idle
        fences := fun _ => .signaled
        images := []
        imageFence := [] }
    | _, .success => submitted
    | _, _ => submitted

/-- Quiescence-gated frame entry: when `needsRedraw damage = false`, state is strictly unchanged. -/
def stepDamageGate (s : SwapchainState) (damage : Damage) (onDirty : SwapchainState → SwapchainState) :
    SwapchainState :=
  if needsRedraw damage then onDirty s else s

/-- Transition permanently to `deviceLostFallbackShm` on unrecoverable device loss. -/
def onDeviceLost (s : SwapchainState) : SwapchainState :=
  match s.phase with
  | .destroyed => s
  | _ =>
    { s with
      phase := .deviceLostFallbackShm
      frameSlots := fun _ => .idle
      fences := fun _ => .signaled
      images := []
      imageFence := [] }

/-- Teardown: executes `vkDeviceWaitIdle` first and transitions to the absorbing `.destroyed` state. -/
def destroy (s : SwapchainState) : SwapchainState :=
  { s with
    phase := .destroyed
    frameSlots := fun _ => .idle
    fences := fun _ => .signaled
    images := []
    imageFence := []
    waitIdleDone := true }

end SwapchainState
end LeanUI.Swapchain
