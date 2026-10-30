/-
Bounded loop, heap-object RC reuse/aliasing, and conditional tuple-projection
conformance corpus for Phase P1 (`scripts/run_shared_kernel_conformance.py`).

Every `@[export probe_lar_*]` entry point has pure `UInt64 → ... → UInt64`
signature so the exact same `.lean` file executes across:
  1. `stock_lean` (`lean --run`),
  2. `stock_extracted_c` (`lean -c` + `leanc -O2`), and
  3. `lnir` (`lean-native emit-lnir --wire` + `lean-native-core eval-lnir --batch-json`
     and `--opt`, asserting `live_objects == 0` on every case).
-/

inductive RcPacket where
  | pair : (UInt64 × UInt64) → (UInt64 × UInt64) → RcPacket
  | empty : RcPacket

@[inline] def foldPacket (pkt : RcPacket) : UInt64 :=
  match pkt with
  | .pair p q => ((p.1 * 1315423911) + p.2) ^^^ ((q.1 * 2654435761) + q.2)
  | .empty => 0x9E3779B97F4A7C15

@[inline] def stepPacket (pkt : RcPacket) (delta : UInt64) : RcPacket :=
  match pkt with
  | .pair p q => .pair (p.1 + delta, p.2 ^^^ delta) (q.1 + (delta <<< 1), q.2 + 17)
  | .empty => .empty

@[inline] def loopRound (acc idx stride : UInt64) : UInt64 :=
  let mixed := acc ^^^ ((idx + 1) * stride + 0x517CC1B727220A95)
  (mixed * (1099511628211 : UInt64)) + (mixed >>> 29) + idx

@[inline] def selectU64 (cond : UInt64) (t e : UInt64) : UInt64 :=
  let mask := (0 : UInt64) - (cond &&& 1)
  (t &&& mask) ||| (e &&& (mask ^^^ 0xFFFFFFFFFFFFFFFF))

@[inline] def ltBit (k limit : UInt64) : UInt64 :=
  ((k - limit) >>> 63)

/-- 1. Bounded 8-step loop accumulator with data-dependent trip count (`0..=7`). -/
@[export probe_lar_bounded_loop8]
def probe_lar_bounded_loop8 (trip seed stride : UInt64) : UInt64 :=
  let limit := trip &&& 7
  let a0 := selectU64 (ltBit 0 limit) (loopRound seed 0 stride) seed
  let a1 := selectU64 (ltBit 1 limit) (loopRound a0 1 stride) a0
  let a2 := selectU64 (ltBit 2 limit) (loopRound a1 2 stride) a1
  let a3 := selectU64 (ltBit 3 limit) (loopRound a2 3 stride) a2
  let a4 := selectU64 (ltBit 4 limit) (loopRound a3 4 stride) a3
  let a5 := selectU64 (ltBit 5 limit) (loopRound a4 5 stride) a4
  let a6 := selectU64 (ltBit 6 limit) (loopRound a5 6 stride) a5
  let a7 := selectU64 (ltBit 7 limit) (loopRound a6 7 stride) a6
  a7

/-- 2. Bounded 4-step state-tuple loop carrying `(acc, shadow)` across iterations. -/
@[inline] def stepPairLoop (st : UInt64 × UInt64) (idx mask limit : UInt64) : UInt64 × UInt64 :=
  let active := ltBit idx limit
  let bit := (mask >>> idx) &&& 1
  let candL := selectU64 bit (loopRound st.1 idx 131) (st.1 ^^^ (idx * 257))
  let candR := selectU64 bit (st.2 + st.1 + idx) (loopRound st.2 idx 521)
  (selectU64 active candL st.1, selectU64 active candR st.2)

@[export probe_lar_tuple_loop8]
def probe_lar_tuple_loop8 (trip seed mask : UInt64) : UInt64 :=
  let limit := trip &&& 3
  let s0 : UInt64 × UInt64 := (seed, seed ^^^ 0xA5A5A5A5A5A5A5A5)
  let s1 := stepPairLoop s0 0 mask limit
  let s2 := stepPairLoop s1 1 mask limit
  let s3 := stepPairLoop s2 2 mask limit
  let s4 := stepPairLoop s3 3 mask limit
  s4.1 ^^^ (s4.2 * 3)

/-- 3. Exclusive linear RC reuse chain (`isShared == false` in-place reset/reuse). -/
@[export probe_lar_rc_exclusive_reuse]
def probe_lar_rc_exclusive_reuse (seed delta : UInt64) : UInt64 :=
  let p0 := if seed == 0 then RcPacket.empty else RcPacket.pair (seed, seed + 5) (delta, delta + 11)
  let p1 := stepPacket p0 (delta + 1)
  let p2 := stepPacket p1 (delta ^^^ 7)
  foldPacket p2

/-- 4. Shared RC alias fan-out (`incRef` on `base`, preventing destructive overwrite of `base`). -/
@[export probe_lar_rc_shared_alias]
def probe_lar_rc_shared_alias (seed delta : UInt64) : UInt64 :=
  let base := RcPacket.pair (seed, seed ^^^ 0x9E3779B97F4A7C15) (delta + 3, seed + delta)
  let b1 := stepPacket base (delta + 5)
  let b2 := stepPacket base (delta + 19)
  foldPacket base + (foldPacket b1 ^^^ foldPacket b2)

/-- 5. Branch-dependent RC drop vs. alias survival (`decRef` on dead branch allocation). -/
@[export probe_lar_rc_branch_drop]
def probe_lar_rc_branch_drop (selector seed delta : UInt64) : UInt64 :=
  let live := RcPacket.pair (seed + 1, delta + 2) (seed ^^^ delta, seed + 29)
  let dead := RcPacket.pair (seed * 7, delta * 11) (seed + 41, delta + 43)
  let vChosen :=
    if (selector &&& 1) == 0 then
      foldPacket (stepPacket live delta)
    else
      foldPacket (stepPacket dead (delta + 9))
  let bonus := if (selector &&& 2) == 0 then foldPacket live else 0
  vChosen ^^^ bonus

/-- 6. Nested `ite` tuple projection (`projTuple` / `mkTuple`). -/
@[export probe_lar_ite_tuple_proj]
def probe_lar_ite_tuple_proj (flags a b c : UInt64) : UInt64 :=
  let t1 : UInt64 × UInt64 :=
    if (flags &&& 1) == 1 then (a + c, b ^^^ c) else (b + 13, a ^^^ 29)
  let t2 : UInt64 × UInt64 :=
    if (flags &&& 2) == 2 then (t1.1 * 5 + 1, t1.2 ^^^ a)
    else (t1.2 + 7, t1.1 * 3 + b)
  let t3 : UInt64 × UInt64 :=
    if (flags &&& 4) == 4 then (t2.1 + t1.2, t2.2 ^^^ t1.1)
    else (t1.1 + t2.2, t1.2 ^^^ t2.1)
  (t3.1 + (t3.2 <<< 1)) ^^^ (t2.1 * 7 + t2.2)

/-- 7. Combined loop + shared/exclusive RC packet stepping across 2 rounds. -/
@[export probe_lar_loop_rc_hybrid]
def probe_lar_loop_rc_hybrid (flags seed delta : UInt64) : UInt64 :=
  let init := RcPacket.pair (seed, delta) (seed + delta, seed ^^^ delta)
  let next1 := stepPacket init (delta + 1)
  let snap1 := if (flags &&& 1) == 1 then foldPacket init ^^^ foldPacket next1 else foldPacket next1
  let next2 := stepPacket next1 (delta + 2)
  let snap2 := if (flags &&& 2) == 2 then foldPacket next1 ^^^ foldPacket next2 else foldPacket next2
  foldPacket next2 + (snap1 ^^^ snap2)
