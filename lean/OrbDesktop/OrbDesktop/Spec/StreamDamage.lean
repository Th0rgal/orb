import OrbDesktop.State
import LeanUI.Kernel
import LeanUI.Text
import LeanUI.Wayland
/-!
# OrbDesktop.Spec.StreamDamage — U7 stream/frame damage, icon bounds & dirty-present contract

A burst of streamed deltas is queued without repainting. The display boundary flushes the
`Orb.Stream.Coalescer` once and damages only the transcript band; an idle boundary is a no-op.
Also pins U7 bounded vector-icon lane dimensions, `Orb.Stream.committedLen` fence-safe prefix
advancement, and `Wayland.computeShmDamageStep` double-buffer dirty-rect tracking.
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

/-- U7: joining committed chunks preserves their exact display order. -/
example :
    streamedText { initial with stream := { initial.stream with shown := ["left", "-", "right"] } } = "left-right" := by
  decide

/-- U7: vector-icon lane rasterisation bounds both width (`≤ maxIconRasterDim`) and visible height. -/
example :
    Text.boundIconRasterSize 542 8 = (542, 8) ∧
    Text.boundIconRasterSize 1400 16 = (Text.maxIconRasterDim, 16) ∧
    Text.boundIconRasterSize 136 40 = (136, 40) := by
  decide

/-- U7: `Orb.Stream.commitOf` never commits inside an open Mermaid fence and commits once
closed and followed by a blank line. -/
example :
    Orb.Stream.commitOf
      [Orb.Stream.ln false true (some (true, 3)), Orb.Stream.ln false false,
       Orb.Stream.ln true false, Orb.Stream.ln false false] = 0 ∧
    Orb.Stream.commitOf
      [Orb.Stream.ln false true (some (true, 3)), Orb.Stream.ln false false,
       Orb.Stream.ln false true (some (true, 3)), Orb.Stream.ln true false,
       Orb.Stream.ln false false] = 4 := by
  decide

-- U7: `Orb.Stream.committedLen` on concrete Mermaid fence strings matches the scanner contract.
#guard
  let openFence := "```mermaid\nflowchart LR\n\nA --> B"
  let closedFence := "```mermaid\nflowchart LR\nA --> B\n```\n\nnext"
  Orb.Stream.committedLen openFence == 0 &&
  Orb.Stream.committedLen closedFence > 0 &&
  Orb.Stream.committedLen closedFence < closedFence.utf8ByteSize

/-- U7: Wayland `wl_shm` double-buffer dirty-rect tracking copies only the union of the last two
frames' dirty rects on steady-state frames and reports only the current frame's dirty rect. -/
example :
    let vp : Rect := ⟨0, 0, 1470, 923⟩
    let r1 : Rect := ⟨220, 400, 748, 40⟩
    let r2 : Rect := ⟨220, 440, 748, 40⟩
    let (c1, d1, a1, b1) := Wayland.computeShmDamageStep vp false (some vp) (some vp) (some r1)
    let (c2, d2, a2, b2) := Wayland.computeShmDamageStep vp true a1 b1 (some r2)
    let (c3, d3, _, _) := Wayland.computeShmDamageStep vp false a2 b2 (some r1)
    c1 = vp ∧ d1 = r1 ∧ c2 = vp ∧ d2 = r2 ∧
      c3 = ⟨220, 400, 748, 80⟩ ∧ d3 = r1 := by
  decide

end OrbDesktop.Spec
