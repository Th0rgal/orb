import OrbDesktop.State
import LeanUI.Kernel
/-!
# OrbDesktop.Spec.StreamDamage — U7 stream/frame damage contract

A burst of streamed deltas is queued without repainting. The display boundary flushes the
`Orb.Stream.Coalescer` once and damages only the transcript band; an idle boundary is a no-op.
-/
namespace OrbDesktop.Spec

open LeanUI
open OrbDesktop

private def viewport : Rect := { x := 0, y := 0, w := 1470, h := 923 }
private def initial : DesktopState := DesktopState.forScreen .missionTranscript true 120

/-- U7: several deltas before one display tick are conserved and render once. -/
example :
    let (st, d) := applyStreamFrame 120 viewport initial ["a", "b", "c"]
    st.stream.shown = ["Wave 3 OrbDesktop native Wayland + Vulkan 1.3 shell ready.", "a", "b", "c"] ∧
      st.stream.pending = [] ∧ st.stream.renders = 2 ∧ d.isSome := by
  decide

/-- U7: an empty delta and a second idle tick do not request a frame. -/
example :
    let queued := [""].foldl pushStreamDelta initial
    let (st, d) := flushStreamFrame 120 viewport queued
    st.stream = initial.stream ∧ d = none := by
  decide

/-- U7: stream damage stays in the transcript and cannot touch the sidebar or composer. -/
example :
    let (_, d) := applyStreamFrame 120 viewport initial ["fragment"]
    d.covers 900 400 = true ∧ d.covers 100 400 = false ∧ d.covers 900 900 = false := by
  decide

end OrbDesktop.Spec
