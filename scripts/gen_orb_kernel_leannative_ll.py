#!/usr/bin/env python3
"""Generate freestanding LeanNative textual LLVM IR for Orb's verified scalar kernel.

Pipeline (Option B+):
  1. Elaborates Orb.Kernel + LeanSys.Spec + generated probe_* wrappers into a
     single LNIR wire module via `lean-native emit-lnir --wire`.
  2. Compiles the LNIR module through LeanNative's verified optimization pipeline
     (`lean-native-core compile-llvm --arch x86_64` and `--arch arm64`) to emit
     deterministic LLVM 18 textual IR for both 64-bit host/mobile architectures.
  3. Performs IR-level symbol hygiene (zero `objcopy` / `ld -r` binary surgery):
     - Quarantines unused runtime imports (`@malloc`, `@free`, `@lean_native_*`)
       into internal trap stubs so zero external symbols (`U`) exist.
     - Internalizes all LeanNative helper and `@probe_*` definitions (`define internal`).
     - Strips non-portable `"target-cpu"` / `"target-features"` attributes so a
       single `.ll` compiles cleanly across Linux, macOS, iOS, and Android NDK.
     - Emits `define dso_local` C-ABI entrypoints (`zeroext i8`, `i32`, `i64`)
       for every symbol in `shared/orb-spec/kernel_abi.json` (`EXPORTS`), so
       LLVM inlines `@probe_*` directly into each exported C-ABI symbol at `-O3`.
  4. Records source + artifact SHA-256 provenance in
     `shared/orb-spec/cabi/orb_kernel_leannative.sha256`.

Run without flags to regenerate the committed `.ll` files and stamp, or with
`--check` (no `lean` or `lean-native` required!) to verify provenance, symbol
hygiene (`0` undefined symbols, exact `EXPORTS` `T` set), and differential C-ABI
equivalence against `shared/orb-spec/cabi/orb_kernel_unboxed.c`.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "shared/orb-spec/kernel_abi.json"
CABI_DIR = ROOT / "shared/orb-spec/cabi"
UNBOXED_C = CABI_DIR / "orb_kernel_unboxed.c"
OUT_X86_64 = CABI_DIR / "orb_kernel_leannative_x86_64.ll"
OUT_AARCH64 = CABI_DIR / "orb_kernel_leannative_aarch64.ll"
STAMP_JSON = CABI_DIR / "orb_kernel_leannative.sha256"

BITS = {"uint8_t": 8, "uint32_t": 32, "uint64_t": 64}
LLVM_TYPE = {"uint8_t": "i8", "uint32_t": "i32", "uint64_t": "i64"}
LLVM_PARAM = {"uint8_t": "i8 zeroext", "uint32_t": "i32", "uint64_t": "i64"}
LLVM_RET = {"uint8_t": "zeroext i8", "uint32_t": "i32", "uint64_t": "i64"}
CTYPES_MAP = {
    "uint8_t": ctypes.c_uint8,
    "uint32_t": ctypes.c_uint32,
    "uint64_t": ctypes.c_uint64,
}
MASKS = {"uint8_t": 0xFF, "uint32_t": 0xFFFF_FFFF, "uint64_t": 0xFFFF_FFFF_FFFF_FFFF}

# Branchless 0/1 bit-arithmetic formulations for the 8 high-branch-count steppers whose
# multi-way Bool join trees otherwise cause exponential SymExpr tree expansion in SymbolicTV.
# Every override below is formally proved bit-exact equal to its `Orb.Kernel.*` export across
# all 64-bit inputs via `bv_decide` (checked during `generate_ir_files` before LNIR emission).
BRANCHLESS_PRELUDE = """
@[inline] def blNz32 (x : UInt32) : UInt32 := ((x ||| (0 - x)) >>> 31)
@[inline] def blEz32 (x : UInt32) : UInt32 := blNz32 x ^^^ 1
@[inline] def blEq8  (a b : UInt8) : UInt32 := blEz32 (a ^^^ b).toUInt32
@[inline] def blEq32 (a b : UInt32) : UInt32 := blEz32 (a ^^^ b)
@[inline] def blNz64 (x : UInt64) : UInt32 := ((x ||| (0 - x)) >>> 63).toUInt32
@[inline] def blEz64 (x : UInt64) : UInt32 := blNz64 x ^^^ 1
@[inline] def blEq64 (a b : UInt64) : UInt32 := blEz64 (a ^^^ b)
@[inline] def blLt32 (a b : UInt32) : UInt32 :=
  let d := a - b
  ((a ^^^ ((a ^^^ b) ||| (d ^^^ b))) >>> 31)
@[inline] def blLe32 (a b : UInt32) : UInt32 := blLt32 b a ^^^ 1
@[inline] def blLt8  (a b : UInt8)  : UInt32 := blLt32 a.toUInt32 b.toUInt32
@[inline] def blLe8  (a b : UInt8)  : UInt32 := blLe32 a.toUInt32 b.toUInt32
@[inline] def blLt64 (a b : UInt64) : UInt32 :=
  let d := a - b
  (((a ^^^ ((a ^^^ b) ||| (d ^^^ b))) >>> 63)).toUInt32
@[inline] def blLe64 (a b : UInt64) : UInt32 := blLt64 b a ^^^ 1
@[inline] def blSel32 (c : UInt32) (t f : UInt32) : UInt32 :=
  let m : UInt32 := 0 - c
  (t &&& m) ||| (f &&& ((0xFFFFFFFF : UInt32) ^^^ m))
@[inline] def blSel64 (c : UInt32) (t f : UInt64) : UInt64 :=
  let m : UInt64 := 0 - c.toUInt64
  (t &&& m) ||| (f &&& ((0xFFFFFFFFFFFFFFFF : UInt64) ^^^ m))
@[inline] def blSatAdd32 (a b : UInt32) : UInt32 :=
  let s : UInt64 := a.toUInt64 + b.toUInt64
  blSel32 (blLe64 s 0xFFFFFFFF) s.toUInt32 0xFFFFFFFF
@[inline] def blI64Flip (x : UInt64) : UInt64 := x + (0x8000000000000000 : UInt64)
@[inline] def blI64Lt (a b : UInt64) : UInt32 := blLt64 (blI64Flip a) (blI64Flip b)
@[inline] def blI64Le (a b : UInt64) : UInt32 := blLe64 (blI64Flip a) (blI64Flip b)
@[inline] def blI64Max (a b : UInt64) : UInt64 := blSel64 (blI64Lt a b) b a
@[inline] def blI64Min (a b : UInt64) : UInt64 := blSel64 (blI64Le a b) a b
@[inline] def blInScrollDom (x : UInt64) : UInt32 := blLe64 x 0x3FFFFFFF ||| blLe64 (0xFFFFFFFFC0000000 : UInt64) x
@[inline] def blI64SatAdd (a b : UInt64) : UInt64 :=
  let s := a + b
  let aNeg := (a >>> 63).toUInt32
  let bNeg := (b >>> 63).toUInt32
  let sNeg := (s >>> 63).toUInt32
  let posOv := (aNeg ^^^ 1) &&& (bNeg ^^^ 1) &&& sNeg
  let negOv := aNeg &&& bNeg &&& (sNeg ^^^ 1)
  blSel64 posOv (0x7FFFFFFFFFFFFFFF : UInt64) (blSel64 negOv (0x8000000000000000 : UInt64) s)
@[inline] def blI64SatSub (a b : UInt64) : UInt64 :=
  let d := a - b
  let aNeg := (a >>> 63).toUInt32
  let bNeg := (b >>> 63).toUInt32
  let dNeg := (d >>> 63).toUInt32
  let posOv := (aNeg ^^^ 1) &&& bNeg &&& dNeg
  let negOv := aNeg &&& (bNeg ^^^ 1) &&& (dNeg ^^^ 1)
  blSel64 posOv (0x7FFFFFFFFFFFFFFF : UInt64) (blSel64 negOv (0x8000000000000000 : UInt64) d)
@[inline] def blScrollMaxTop (h c : UInt64) : UInt64 := blI64Max 0 (blI64SatSub h c)
@[inline] def blScrollClampTop (h c t : UInt64) : UInt64 := blI64Max 0 (blI64Min t (blScrollMaxTop h c))
@[inline] def blScrollGap (h c t : UInt64) : UInt64 := blI64SatSub (blI64SatSub h t) c
@[inline] def blFallbackTopU32 (curTop : UInt64) : UInt32 :=
  let nn := blI64Max 0 curTop
  blSel32 (blLe64 nn 0xFFFFFFFF) nn.toUInt32 0xFFFFFFFF
@[inline] def blSpanFits (ptr len : UInt64) (is32 : UInt8) : UInt32 :=
  let fit32 := blLe64 ptr 0xFFFFFFFF &&& blLe64 len 0xFFFFFFFF &&& blLe64 (ptr + len) (0x100000000 : UInt64)
  let fit64 := blEz64 ptr ||| blEz64 len ||| blLe64 (ptr - 1) ((0xFFFFFFFFFFFFFFFF : UInt64) - len)
  blSel32 (blEq8 is32 1) fit32 fit64
@[inline] def blVerifySliceIo (inPtr inLen outPtr outCap writtenLen : UInt64) (is32 : UInt8) : UInt32 :=
  let wOk := blLe8 is32 1
  let nonNull := (blEz64 inLen ||| blNz64 inPtr) &&& (blEz64 outCap ||| blNz64 outPtr)
  let spanOk := blSpanFits inPtr inLen is32 &&& blSpanFits outPtr outCap is32
  let disj := blEz64 inLen ||| blEz64 outCap |||
    (blLe64 inLen outPtr &&& blLe64 inPtr (outPtr - inLen)) |||
    (blLe64 outCap inPtr &&& blLe64 outPtr (inPtr - outCap))
  let capOk := blLe64 writtenLen outCap
  blSel32 (wOk ^^^ 1) 6
    (blSel32 (nonNull ^^^ 1) 7
      (blSel32 (spanOk ^^^ 1) 8
        (blSel32 (disj ^^^ 1) 9
          (blSel32 (capOk ^^^ 1) 5 0))))
@[inline] def blScrollStep (opKind pinned intent resized : UInt8) (curTop h c arg : UInt64) : UInt64 :=
  let pin := blEq8 pinned 1
  let keepPin := pin <<< 9
  let keepTop := blFallbackTopU32 curTop
  let inDom := blInScrollDom curTop &&& blInScrollDom h &&& blInScrollDom c &&& blInScrollDom arg
  let maxT := blScrollMaxTop h c
  let clampArg := blScrollClampTop h c arg
  let layoutT := blSel64 pin maxT (blScrollClampTop h c (blI64SatAdd curTop arg))
  let nextTop := blSel64 (blEq8 opKind 0) layoutT (blSel64 (blEq8 opKind 1 ||| blEq8 opKind 2) clampArg maxT)
  let gapT := blScrollGap h c clampArg
  let userPin := blSel32 (blI64Lt clampArg curTop) 0 (blSel32 (blI64Lt gapT 24) 1 pin)
  let evUnpin := (blEq8 resized 1 ^^^ 1) &&& pin &&& blI64Lt clampArg curTop &&& blI64Le 24 gapT
  let evPin := blSel32 evUnpin 0 pin
  let isUser := blEq8 opKind 1 ||| (blEq8 opKind 2 &&& blEq8 intent 1)
  let nextPin := blSel32 (blEq8 opKind 0) pin (blSel32 isUser userPin (blSel32 (blEq8 opKind 2) evPin 1))
  let okWord := ((257 : UInt32) ||| (nextPin <<< 9)).toUInt64 ||| (nextTop.toUInt32.toUInt64 <<< 32)
  let domErr := ((3 : UInt32) ||| keepPin).toUInt64 ||| (keepTop.toUInt64 <<< 32)
  let opErr := ((2 : UInt32) ||| keepPin).toUInt64 ||| (keepTop.toUInt64 <<< 32)
  blSel64 (blLe8 opKind 3) (blSel64 inDom okWord domErr) opErr
""".strip()

BRANCHLESS_PROBES: dict[str, str] = {
    "orb_hierarchy_merge_step": """@[export probe_orb_hierarchy_merge_step] def probe_orb_hierarchy_merge_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 : UInt64) : UInt64 :=
  let curSup := blEq8 a4.toUInt8 1
  let incSup := blEq8 a11.toUInt8 1
  let nextSup := curSup ||| incSup
  let curArch := blEq8 a3.toUInt8 1
  let incArch := blEq8 a9.toUInt8 1
  let incUnarch := blEq8 a10.toUInt8 1
  let validPres := blLe8 a6.toUInt8 2
  let isPart := blEq8 a5.toUInt8 1
  let epochFresh := (isPart &&& blLt64 a0 a1) ||| ((isPart ^^^ 1) &&& blLe64 a0 a1)
  let unarchEpochOk := blLt64 a2 a1
  let unarchAllowed := (nextSup ^^^ 1) &&& incUnarch &&& (incArch ^^^ 1) &&& unarchEpochOk
  let updArch := incArch ||| ((unarchAllowed ^^^ 1) &&& curArch)
  let validEpoch := validPres &&& epochFresh
  let nextArch := nextSup ||| (validEpoch &&& updArch) ||| ((validEpoch ^^^ 1) &&& curArch)
  let supBlocks := curSup &&& (incSup ^^^ 1)
  let archBlocks := curArch &&& (nextSup ^^^ 1) &&& (incArch ^^^ 1) &&& (unarchAllowed ^^^ 1)
  let admit := validEpoch &&& (supBlocks ^^^ 1) &&& (archBlocks ^^^ 1)
  let fullParent := blSel32 (blEq8 a6.toUInt8 1) a8.toUInt32 0
  let partParent := blSel32 (blEq8 a6.toUInt8 0) a7.toUInt32 fullParent
  let nextParent := blSel32 admit (blSel32 isPart partParent fullParent) a7.toUInt32
  let lo32 := blSel32 admit 257 2 ||| (nextArch <<< 9) ||| (nextSup <<< 10) ||| ((admit &&& unarchAllowed &&& curArch) <<< 11)
  lo32.toUInt64 ||| (nextParent.toUInt64 <<< 32)""",
    "orb_provider_attempt_step": """@[export probe_orb_provider_attempt_step] def probe_orb_provider_attempt_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) : UInt64 :=
  let pinnedAccountId := a0.toUInt32; let candidateAccountId := a1.toUInt32
  let attemptsUsed := a2.toUInt32; let retryBudget := a3.toUInt32
  let firstByteCommitted := a4.toUInt8; let failureKind := a5.toUInt8
  let fb1 := blEq8 firstByteCommitted 1
  let nextFirstByte := fb1 ||| blEq8 failureKind 3
  let lockBit := nextFirstByte <<< 9
  let pinOk := (blEz32 candidateAccountId ^^^ 1) &&& (blEz32 pinnedAccountId ||| blEq32 candidateAccountId pinnedAccountId)
  let cooldownOk := (blEq8 failureKind 2 ^^^ 1) &&& blLe64 a7 a6
  let clockOk := blLt64 a6 a8 &&& blEq8 a9.toUInt8 1
  let isRetry := blEq8 failureKind 1 ||| blEq8 failureKind 2
  let budgetOk := blSel32 isRetry (blLt32 attemptsUsed retryBudget) (blLe32 attemptsUsed retryBudget)
  let fbRetry := fb1 &&& isRetry
  let canDispatch := (fbRetry ^^^ 1) &&& pinOk &&& cooldownOk &&& clockOk &&& budgetOk
  let nextAttempts := blSel32 (canDispatch &&& isRetry) (blSatAdd32 attemptsUsed 1) attemptsUsed
  let code :=
    blSel32 fbRetry 3
      (blSel32 (pinOk ^^^ 1) 4
        (blSel32 (cooldownOk ^^^ 1) 5
          (blSel32 (clockOk ^^^ 1) 6
            (blSel32 (budgetOk ^^^ 1) 7 257))))
  (code ||| lockBit).toUInt64 ||| (nextAttempts.toUInt64 <<< 32)""",
    "orb_resource_ledger_step": """@[export probe_orb_resource_ledger_step] def probe_orb_resource_ledger_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 : UInt64) : UInt64 :=
  let opKind := a0.toUInt8
  let reservedSlots := a1.toUInt32; let activeSlots := a2.toUInt32; let maxSlots := a3.toUInt32
  let activeFits := blLe32 activeSlots maxSlots
  let remSlots := blSel32 activeFits (maxSlots - activeSlots) 0
  let reservedFits := blLe32 reservedSlots remSlots
  let budgetValid := blLe64 a4 a6
  let stateValid := activeFits &&& reservedFits &&& budgetValid
  let remBudget := blSel64 budgetValid (a6 - a4) 0
  let spendFits := stateValid &&& blLe64 a5 remBudget
  let hasFreeSlot := blLt32 reservedSlots remSlots
  let hasReserved := blLt32 0 reservedSlots
  let hasActive := blLt32 0 activeSlots
  let ttlLive := blLt64 a7 a8
  let ttlExpired := ttlLive ^^^ 1
  let canReserve := blEq8 opKind 0 &&& spendFits &&& hasFreeSlot &&& ttlLive
  let canActivate := blEq8 opKind 1 &&& stateValid &&& hasReserved &&& ttlLive
  let canRelease := blEq8 opKind 2 &&& stateValid &&& hasActive
  let canReap := blEq8 opKind 3 &&& stateValid &&& hasReserved &&& ttlExpired
  let nextReserved :=
    blSel32 canReserve (reservedSlots + 1)
      (blSel32 (canActivate ||| canReap) (reservedSlots - 1) reservedSlots)
  let nextActive :=
    blSel32 canActivate (activeSlots + 1)
      (blSel32 canRelease (activeSlots - 1) activeSlots)
  let admit := canReserve ||| canActivate ||| canRelease ||| canReap
  let okLo := blSel32 admit ((257 : UInt32) ||| ((opKind.toUInt32 &&& (0xFF : UInt32)) <<< 1)) 2
  let lo32 := blSel32 stateValid okLo 0
  let hi32 := (nextReserved &&& (0xFFFF : UInt32)) ||| ((nextActive &&& (0xFFFF : UInt32)) <<< 16)
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)""",
    "orb_scroll_policy_correct": """@[export probe_orb_scroll_policy_correct] def probe_orb_scroll_policy_correct (a0 a1 a2 a3 a4 : UInt64) : UInt64 :=
  blScrollClampTop a0 a1 (blI64SatAdd a2 (blI64SatSub (blI64SatSub a3 a2) a4))""",
    "orb_scroll_policy_step": """@[export probe_orb_scroll_policy_step] def probe_orb_scroll_policy_step (a0 a1 a2 a3 a4 a5 a6 a7 : UInt64) : UInt64 :=
  blScrollStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4 a5 a6 a7""",
    "orb_wire_scroll_slice_step": """@[export probe_orb_wire_scroll_slice_step] def probe_orb_wire_scroll_slice_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) : UInt64 :=
  let st := blVerifySliceIo a0 a1 a2 a3 32 a4.toUInt8
  let keepPin := (blEq8 a6.toUInt8 1) <<< 9
  let keepTop := blFallbackTopU32 a9
  let errW := (st ||| keepPin).toUInt64 ||| (keepTop.toUInt64 <<< 32)
  let okW := blScrollStep a5.toUInt8 a6.toUInt8 a7.toUInt8 a8.toUInt8 a9 a10 a11 a12
  blSel64 (blEz32 st) okW errW""",
    "orb_wire_stream_slice_step": """@[export probe_orb_wire_stream_slice_step] def probe_orb_wire_stream_slice_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 : UInt64) : UInt64 :=
  let st := blVerifySliceIo a0 a1 a2 a3 32 a4.toUInt8
  let prevLen := a5.toUInt32; let prevCommit := a6.toUInt32; let prevCheckpoint := a7.toUInt32
  let newLen := a8.toUInt32; let rawCommit := a9.toUInt32; let maxTail := a10.toUInt32
  let valid := blLt32 0 maxTail &&& blLe32 prevCommit prevCheckpoint &&& blLe32 prevCheckpoint prevLen &&& blLe32 prevLen newLen
  let clampedRaw := blSel32 (blLe32 rawCommit newLen) rawCommit newLen
  let nextCommit := blSel32 (blLe32 prevCommit clampedRaw) clampedRaw prevCommit
  let baseCp := blSel32 (blLe32 prevCheckpoint nextCommit) nextCommit prevCheckpoint
  let capFloor := blSel32 (blLe32 maxTail newLen) (newLen - maxTail) 0
  let nextCp := blSel32 (blLe32 baseCp capFloor) capFloor baseCp
  let cpForcedBit := (blLt32 nextCommit nextCp) <<< 9
  let stepOk := ((257 : UInt32) ||| cpForcedBit).toUInt64 ||| (nextCp.toUInt64 <<< 32)
  let stepErr := (3 : UInt64) ||| (prevCheckpoint.toUInt64 <<< 32)
  let sliceErr := st.toUInt64 ||| (prevCheckpoint.toUInt64 <<< 32)
  blSel64 (blEz32 st) (blSel64 valid stepOk stepErr) sliceErr""",
    "orb_wire_transcript_slice_step": """@[export probe_orb_wire_transcript_slice_step] def probe_orb_wire_transcript_slice_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 : UInt64) : UInt64 :=
  let _ := a10
  let st := blVerifySliceIo a0 a1 a2 a3 32 a4.toUInt8
  let lastSeq := a5; let incSeq := a6; let entryCount := a7.toUInt32
  let thinkOpen := a8.toUInt8; let act := a9.toUInt8
  let keepThink := (blEq8 thinkOpen 1) <<< 9
  let isDup := blLe64 incSeq lastSeq
  let isContig := (isDup ^^^ 1) &&& blEq64 (incSeq - lastSeq) 1
  let isOpenThink := blEq8 act 4
  let isAppend := blEq8 act 5 ||| blEq8 act 6 ||| blEq8 act 7 ||| blEq8 act 9 ||| blEq8 act 10
  let isMeta := blEq8 act 2 ||| blEq8 act 3 ||| blEq8 act 8
  let appendLo := blSel32 (blEq8 thinkOpen 1) 1281 257
  let contigLo :=
    blSel32 isOpenThink 769
      (blSel32 isAppend appendLo
        (blSel32 isMeta ((260 : UInt32) ||| keepThink) ((4 : UInt32) ||| keepThink)))
  let foldLo := blSel32 isDup ((2 : UInt32) ||| keepThink) (blSel32 isContig contigLo ((2051 : UInt32) ||| keepThink))
  let foldHi := blSel32 (isContig &&& isAppend) (blSatAdd32 entryCount 1) entryCount
  let foldW := foldLo.toUInt64 ||| (foldHi.toUInt64 <<< 32)
  let sliceErr := (st ||| keepThink).toUInt64 ||| (entryCount.toUInt64 <<< 32)
  blSel64 (blEz32 st) foldW sliceErr""",
}

BRANCHLESS_EQUIV_PROOFS = """
set_option maxHeartbeats 1600000
set_option linter.unusedSimpArgs false

theorem eq_hierarchy_merge (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 : UInt64) :
    probe_orb_hierarchy_merge_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 =
    Orb.Kernel.hierarchyMergeStep a0 a1 a2 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt8 a7.toUInt32 a8.toUInt32 a9.toUInt8 a10.toUInt8 a11.toUInt8 := by
  simp only [bne, blNz32, blEz32, blEq8, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32, probe_orb_hierarchy_merge_step, Orb.Kernel.hierarchyMergeStep]
  bv_decide

theorem eq_provider_attempt (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) :
    probe_orb_provider_attempt_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 =
    Orb.Kernel.providerAttemptStep a0.toUInt32 a1.toUInt32 a2.toUInt32 a3.toUInt32 a4.toUInt8 a5.toUInt8 a6 a7 a8 a9.toUInt8 := by
  simp only [bne, blNz32, blEz32, blEq8, blEq32, blLt32, blLe32, blLt64, blLe64, blSel32, blSatAdd32, probe_orb_provider_attempt_step, Orb.Kernel.providerAttemptStep, Orb.Kernel.satAdd32]
  bv_decide

theorem eq_resource_ledger (a0 a1 a2 a3 a4 a5 a6 a7 a8 : UInt64) :
    probe_orb_resource_ledger_step a0 a1 a2 a3 a4 a5 a6 a7 a8 =
    Orb.Kernel.resourceLedgerStep a0.toUInt8 a1.toUInt32 a2.toUInt32 a3.toUInt32 a4 a5 a6 a7 a8 := by
  simp only [bne, blNz32, blEz32, blEq8, blLt32, blLe32, blLt64, blLe64, blSel32, blSel64, probe_orb_resource_ledger_step, Orb.Kernel.resourceLedgerStep]
  bv_decide

theorem eq_scroll_correct (h c top ad y0 : UInt64) :
    probe_orb_scroll_policy_correct h c top ad y0 = Orb.Kernel.scrollPolicyCorrect h c top ad y0 := by
  simp only [blLt64, blLe64, blSel64, blI64Flip, blI64Lt, blI64Le, blI64Max, blI64Min, blI64SatAdd, blI64SatSub, blScrollMaxTop, blScrollClampTop, probe_orb_scroll_policy_correct,
    Orb.Kernel.scrollPolicyCorrect, Orb.Kernel.scrollPolicyClampTopI64, Orb.Kernel.scrollPolicyMaxTopI64,
    Orb.Kernel.scrollI64Max, Orb.Kernel.scrollI64Min, Orb.Kernel.scrollI64Lt, Orb.Kernel.scrollI64Le, Orb.Kernel.scrollI64SignFlip,
    Orb.Kernel.scrollI64SatAdd, Orb.Kernel.scrollI64SatSub]
  bv_decide

theorem eq_scroll_step (a0 a1 a2 a3 a4 a5 a6 a7 : UInt64) :
    probe_orb_scroll_policy_step a0 a1 a2 a3 a4 a5 a6 a7 =
    Orb.Kernel.scrollPolicyStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4 a5 a6 a7 := by
  simp only [bne, blNz32, blEz32, blEq8, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32, blSel64,
    blI64Flip, blI64Lt, blI64Le, blI64Max, blI64Min, blInScrollDom, blI64SatAdd, blI64SatSub,
    blScrollMaxTop, blScrollClampTop, blScrollGap, blFallbackTopU32, blScrollStep, probe_orb_scroll_policy_step,
    Orb.Kernel.scrollPolicyStep, Orb.Kernel.scrollPolicyNextPinned, Orb.Kernel.scrollPolicyNextTop,
    Orb.Kernel.scrollPolicyFallbackTopU32, Orb.Kernel.inScrollDomainI64, Orb.Kernel.scrollPolicyGap,
    Orb.Kernel.scrollPolicyClampTopI64, Orb.Kernel.scrollPolicyMaxTopI64,
    Orb.Kernel.scrollI64Max, Orb.Kernel.scrollI64Min, Orb.Kernel.scrollI64Lt, Orb.Kernel.scrollI64Le,
    Orb.Kernel.scrollI64SignFlip, Orb.Kernel.scrollI64SatAdd, Orb.Kernel.scrollI64SatSub]
  bv_decide

theorem eq_wire_scroll_slice (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) :
    probe_orb_wire_scroll_slice_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 =
    Orb.Kernel.wireScrollSliceStep a0 a1 a2 a3 a4.toUInt8 a5.toUInt8 a6.toUInt8 a7.toUInt8 a8.toUInt8 a9 a10 a11 a12 := by
  unfold probe_orb_wire_scroll_slice_step Orb.Kernel.wireScrollSliceStep
  rw [← eq_scroll_step]
  unfold probe_orb_scroll_policy_step
  generalize blScrollStep a5.toUInt8 a6.toUInt8 a7.toUInt8 a8.toUInt8 a9 a10 a11 a12 = okWord
  simp only [bne, blNz32, blEz32, blEq8, blNz64, blEz64, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32, blSel64,
    blI64Flip, blI64Lt, blI64Max, blFallbackTopU32, blSpanFits, blVerifySliceIo,
    Orb.Kernel.wireVerifySliceIo, Orb.Kernel.wireSliceSpanFits, Orb.Kernel.scrollPolicyFallbackTopU32,
    Orb.Kernel.scrollI64Max, Orb.Kernel.scrollI64Lt, Orb.Kernel.scrollI64SignFlip]
  bv_decide

theorem eq_wire_stream_slice (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 : UInt64) :
    probe_orb_wire_stream_slice_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 =
    Orb.Kernel.wireStreamSliceStep a0 a1 a2 a3 a4.toUInt8 a5.toUInt32 a6.toUInt32 a7.toUInt32 a8.toUInt32 a9.toUInt32 a10.toUInt32 := by
  simp only [bne, blNz32, blEz32, blEq8, blNz64, blEz64, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32, blSel64,
    blSpanFits, blVerifySliceIo, probe_orb_wire_stream_slice_step,
    Orb.Kernel.wireStreamSliceStep, Orb.Kernel.streamBoundedCommitStep, Orb.Kernel.wireVerifySliceIo, Orb.Kernel.wireSliceSpanFits]
  bv_decide

theorem eq_wire_transcript_slice (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 : UInt64) :
    probe_orb_wire_transcript_slice_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 =
    Orb.Kernel.wireTranscriptSliceStep a0 a1 a2 a3 a4.toUInt8 a5 a6 a7.toUInt32 a8.toUInt8 a9.toUInt8 a10.toUInt8 := by
  simp only [bne, blNz32, blEz32, blEq8, blNz64, blEz64, blEq64, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32, blSel64,
    blSatAdd32, blSpanFits, blVerifySliceIo, probe_orb_wire_transcript_slice_step,
    Orb.Kernel.wireTranscriptSliceStep, Orb.Kernel.transcriptFoldStep, Orb.Kernel.satAdd32,
    Orb.Kernel.wireVerifySliceIo, Orb.Kernel.wireSliceSpanFits]
  bv_decide
""".strip()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest() -> list[dict]:
    return json.loads(MANIFEST.read_text())["functions"]


def export_map(path: Path, namespace: str) -> dict[str, str]:
    text = path.read_text()
    return {
        symbol: f"{namespace}.{decl}"
        for symbol, decl in re.findall(
            r"@\[[^\]]*\bexport\s+(\w+)[^\]]*\]\s*def\s+(\w+)", text
        )
    }


def sanitize_and_append_cabi(raw_ir: str, arch_label: str, functions: list[dict]) -> str:
    lines_out: list[str] = [
        f"; Generated by scripts/gen_orb_kernel_leannative_ll.py ({arch_label}). Do not edit.",
    ]
    manifest_names = {fn["name"] for fn in functions}

    quarantined_Runtime = {
        "declare void @lean_native_evm_sload(ptr, ptr, ptr)": (
            "define internal void @lean_native_evm_sload(ptr %a, ptr %b, ptr %c) #0 {\n"
            "  call void @llvm.trap()\n"
            "  unreachable\n"
            "}"
        ),
        "declare void @lean_native_evm_sstore(ptr, ptr, ptr)": (
            "define internal void @lean_native_evm_sstore(ptr %a, ptr %b, ptr %c) #0 {\n"
            "  call void @llvm.trap()\n"
            "  unreachable\n"
            "}"
        ),
        "declare i64 @lean_native_trm_matryoshka_parity_u64(i64)": (
            "define internal i64 @lean_native_trm_matryoshka_parity_u64(i64 %a) #0 {\n"
            "  call void @llvm.trap()\n"
            "  unreachable\n"
            "}"
        ),
        "declare noalias ptr @malloc(i64 noundef)": (
            "define internal noalias ptr @malloc(i64 noundef %n) #0 {\n"
            "  call void @llvm.trap()\n"
            "  unreachable\n"
            "}"
        ),
        "declare void @free(ptr noundef)": (
            "define internal void @free(ptr noundef %p) #0 {\n"
            "  call void @llvm.trap()\n"
            "  unreachable\n"
            "}"
        ),
    }

    for line in raw_ir.splitlines():
        stripped = line.strip()
        if stripped.startswith("; ModuleID ="):
            lines_out.append(f"; ModuleID = 'orb_kernel_leannative_{arch_label}'")
            continue
        if stripped.startswith("source_filename ="):
            lines_out.append(f'source_filename = "orb_kernel_leannative_{arch_label}.ll"')
            continue
        if stripped in quarantined_Runtime:
            lines_out.append(quarantined_Runtime[stripped])
            continue
        if stripped.startswith("declare void @llvm.memcpy.p0.p0.i64("):
            # Rewrite the single unused clone call site below so zero libc memcpy symbol can be emitted.
            lines_out.append(
                "define internal void @__orb_unreachable_memcpy(ptr %d, ptr %s, i64 %n) #0 {\n"
                "  call void @llvm.trap()\n"
                "  unreachable\n"
                "}"
            )
            continue
        if "call void @llvm.memcpy.p0.p0.i64(" in line:
            lines_out.append("  call void @llvm.trap()")
            continue
        if stripped.startswith("define "):
            # Internalize every raw helper, probe_*, and lean_native_abi_* symbol, and
            # rename any prelude helper whose identifier collides with a manifest C-ABI export.
            rewritten = re.sub(
                r"^define\s+(?:internal\s+)?(?:weak_odr\s+)?(?:dso_local\s+)?",
                "define internal ",
                line,
            )
            rewritten = re.sub(
                r"@([A-Za-z0-9_.$]+)\(",
                lambda m: (
                    f"@__leannative_prelude_{m.group(1)}("
                    if m.group(1) in manifest_names
                    else m.group(0)
                ),
                rewritten,
            )
            lines_out.append(rewritten)
            continue
        if "call " in line and "@" in line:
            line = re.sub(
                r"@([A-Za-z0-9_.$]+)\(",
                lambda m: (
                    f"@__leannative_prelude_{m.group(1)}("
                    if m.group(1) in manifest_names
                    else m.group(0)
                ),
                line,
            )
        if stripped.startswith("attributes #"):
            cleaned = re.sub(r'\s*"target-cpu"="[^"]*"', "", line)
            cleaned = re.sub(r'\s*"target-features"="[^"]*"', "", cleaned)
            lines_out.append(cleaned)
            continue
        lines_out.append(line)

    lines_out.append("")
    lines_out.append("; --- Orb Authoritative Freestanding C-ABI Exports ---")
    for fn in functions:
        name = fn["name"]
        ret_c = fn["ret"]
        ret_ll = LLVM_RET[ret_c]
        ret_ty = LLVM_TYPE[ret_c]
        params = fn["params"]
        sig_params = ", ".join(
            f"{LLVM_PARAM[p['type']]} %a{i}" for i, p in enumerate(params)
        )
        lines_out.append(f"define dso_local {ret_ll} @{name}({sig_params}) #0 {{")
        lines_out.append("entry:")
        call_args: list[str] = []
        for i, p in enumerate(params):
            pty = p["type"]
            if pty == "uint64_t":
                call_args.append(f"i64 %a{i}")
            else:
                src_ty = LLVM_TYPE[pty]
                lines_out.append(f"  %ext{i} = zext {src_ty} %a{i} to i64")
                call_args.append(f"i64 %ext{i}")
        if name == "lp_orb_x2dspec_Orb_Kernel_accessStep___redArg":
            call_args.append("i64 0")
            probe_sym = "probe_orb_access_step"
        else:
            probe_sym = f"probe_{name}"
        lines_out.append(
            f"  %raw = call i64 @{probe_sym}({', '.join(call_args)})"
        )
        if ret_c == "uint64_t":
            lines_out.append("  ret i64 %raw")
        else:
            lines_out.append(f"  %res = trunc i64 %raw to {ret_ty}")
            lines_out.append(f"  ret {ret_ty} %res")
        lines_out.append("}")
        lines_out.append("")

    return "\n".join(lines_out).rstrip() + "\n"


def default_lean_bin_dir() -> Path:
    if os.environ.get("ORB_LEAN_BIN_DIR"):
        return Path(os.environ["ORB_LEAN_BIN_DIR"]).resolve()
    lean_exe = shutil.which("lean")
    if lean_exe:
        prefix = subprocess.check_output(
            [lean_exe, "--print-prefix"], text=True
        ).strip()
        return Path(prefix) / "bin"
    fallback = Path("/var/lib/sandboxed-node/work/caches/elan/toolchains/leanprover--lean4---v4.35.0/bin")
    return fallback


def downgrade_llvm20_textual_ir(line: str) -> str:
    """Strip LLVM 19+/20+ textual IR poison-refinement flags/attributes not recognized
    by LLVM 18/19 parsers (`ubuntu-latest` clang 18, Android NDK r28 clang 19).
    Dropping optional poison-refinement flags (`trunc nuw/nsw`, `icmp samesign`,
    `getelementptr nusw/nuw`, `uwtable(sync)`, `nocreateundeforpoison`) is strictly
    semantics-preserving for all well-defined inputs."""
    line = re.sub(r"\btrunc\s+(?:nuw\s+|nsw\s+)+", "trunc ", line)
    line = re.sub(r"\bicmp\s+samesign\s+", "icmp ", line)
    line = re.sub(r"\bgetelementptr\s+inbounds\s+(?:nuw\s+|nusw\s+)+", "getelementptr inbounds ", line)
    line = re.sub(r"\bgetelementptr\s+(?:nuw\s+|nusw\s+)+", "getelementptr ", line)
    line = re.sub(r"\buwtable\(sync\)", "uwtable", line)
    line = re.sub(r"\s+nocreateundeforpoison\b", "", line)
    line = re.sub(r"-Fn32", "", line)
    line = re.sub(r"\s*captures\([^)]*\)", "", line)
    line = re.sub(r"\s*dead_on_unwind", "", line)
    line = re.sub(r"\brange\([^)]*\)\s*", "", line)
    return line


def canonicalize_llvm_ir(ir_text: str, arch_label: str) -> str:
    """Run target-canonical LLVM IR simplification (`clang -O2 -S -emit-llvm`) and
    strip host-specific `target-cpu` / `target-features` / `!llvm.ident` metadata
    so committed `.ll` files stay compact (~480 KB) and compile in ~1s on CI/mobile."""
    ndk_home = os.environ.get("ANDROID_NDK_HOME")
    ndk_clang = (
        sorted(Path(ndk_home).glob("toolchains/llvm/prebuilt/*/bin/clang"))
        if ndk_home
        else []
    )
    clang = str(ndk_clang[0]) if ndk_clang else shutil.which("clang")
    if not clang:
        return ir_text
    target = (
        "aarch64-unknown-linux-gnu"
        if arch_label == "aarch64"
        else "x86_64-unknown-linux-gnu"
    )
    with tempfile.TemporaryDirectory(prefix="orb-ll-canon-") as td:
        in_ll = Path(td) / f"in_{arch_label}.ll"
        out_ll = Path(td) / f"out_{arch_label}.ll"
        in_ll.write_text(ir_text)
        subprocess.run(
            [
                clang,
                f"--target={target}",
                "-Wno-override-module",
                "-O2",
                "-S",
                "-emit-llvm",
                str(in_ll),
                "-o",
                str(out_ll),
            ],
            check=True,
        )
        out_lines = [
            f"; Generated by scripts/gen_orb_kernel_leannative_ll.py ({arch_label}). Do not edit."
        ]
        for line in out_ll.read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith("; ModuleID ="):
                out_lines.append(f"; ModuleID = 'orb_kernel_leannative_{arch_label}'")
                continue
            if stripped.startswith("source_filename ="):
                out_lines.append(
                    f'source_filename = "orb_kernel_leannative_{arch_label}.ll"'
                )
                continue
            if stripped.startswith("attributes #"):
                cleaned = re.sub(r'\s*"target-cpu"="[^"]*"', "", line)
                cleaned = re.sub(r'\s*"target-features"="[^"]*"', "", cleaned)
                out_lines.append(downgrade_llvm20_textual_ir(cleaned))
                continue
            if stripped.startswith("!llvm.ident =") or re.match(
                r"^!\d+\s*=\s*!\{!\"[^\"]*clang version", stripped
            ):
                continue
            out_lines.append(downgrade_llvm20_textual_ir(line))
        return "\n".join(out_lines).rstrip() + "\n"


def generate_ir_files(
    turbo_root: Path,
    lean_sys_root: Path,
    lean_bin_dir: Path,
    lean_native_core: Path,
) -> None:
    functions = load_manifest()
    sources = [
        (ROOT / "lean/Orb/Kernel.lean", "Orb.Kernel"),
        (lean_sys_root / "LeanSys/Spec.lean", "LeanSys.Spec"),
    ]
    exports: dict[str, str] = {}
    for path, namespace in sources:
        exports.update(export_map(path, namespace))
    public = [
        item for item in functions if item["name"].startswith(("orb_", "leansys_"))
    ]
    missing = sorted({item["name"] for item in public} - exports.keys())
    if missing:
        raise RuntimeError(f"unresolved Lean exports for Wrappers.lean: {missing}")

    lean_native_bin = turbo_root / "lean/.lake/build/bin/lean-native"
    if not lean_native_bin.is_file() and (turbo_root / ".lake/build/bin/lean-native").is_file():
        lean_native_bin = turbo_root / ".lake/build/bin/lean-native"
    if not lean_native_bin.is_file() and shutil.which("lean-native"):
        lean_native_bin = Path(shutil.which("lean-native") or "").resolve()
    if not lean_native_bin.is_file():
        raise FileNotFoundError(f"missing elaborating lean-native binary: {lean_native_bin}")
    if not lean_native_core.is_file():
        raise FileNotFoundError(f"missing lean-native-core binary: {lean_native_core}")

    with tempfile.TemporaryDirectory(prefix="orb-leannative-ll-") as tmp:
        stage = Path(tmp)
        env = {**os.environ, "LEAN_PATH": str(stage), "LEAN_NATIVE_TELEMETRY": "off"}
        for path, namespace in sources:
            olean = stage / (namespace.replace(".", "/") + ".olean")
            olean.parent.mkdir(parents=True, exist_ok=True)
            base = ROOT / "lean" if namespace.startswith("Orb") else lean_sys_root
            subprocess.run(
                [
                    str(lean_bin_dir / "lean"),
                    "-DwarningAsError=true",
                    str(path.relative_to(base)),
                    "-o",
                    str(olean),
                ],
                cwd=base,
                env=env,
                check=True,
            )

        from concurrent.futures import ThreadPoolExecutor

        # Verify formal bit-exact equivalence (`bv_decide`) for all branchless probe overrides
        # against `Orb.Kernel.*` before emitting any LNIR.
        equiv_lean = stage / "BranchlessEquivCheck.lean"
        equiv_lean.write_text(
            "import Orb.Kernel\nimport Std.Tactic.BVDecide\n\n"
            + BRANCHLESS_PRELUDE
            + "\n\n"
            + "\n\n".join(BRANCHLESS_PROBES.values())
            + "\n\n"
            + BRANCHLESS_EQUIV_PROOFS
            + "\n"
        )
        subprocess.run(
            [str(lean_bin_dir / "lean"), "-DwarningAsError=true", str(equiv_lean)],
            cwd=stage,
            env=env,
            check=True,
        )

        probe_lines: list[tuple[bool, str]] = []
        for item in public:
            if item["name"] in BRANCHLESS_PROBES:
                probe_lines.append((True, BRANCHLESS_PROBES[item["name"]]))
                continue
            params = " ".join(f"(a{i} : UInt64)" for i in range(len(item["params"])))
            args = " ".join(
                f"a{i}"
                if param["type"] == "uint64_t"
                else f"a{i}.toUInt{BITS[param['type']]}"
                for i, param in enumerate(item["params"])
            )
            call = f"({exports[item['name']]} {args})"
            if item["ret"] != "uint64_t":
                call += ".toUInt64"
            probe = "probe_" + item["name"]
            probe_lines.append((False, f"@[export {probe}] def {probe} {params} : UInt64 := {call}"))

        # Emit LNIR in independent 8-probe shards so normalizeAndInlineLocalDefs stays O(1)
        # per shard and runs concurrently across cores, then splice deterministic LNIR_WIRE_V1
        # D_decl streams into a single module.lnir with fixed moduleName "Orb.Kernel.LeanNative".
        shard_size = 8
        shards = [
            probe_lines[idx : idx + shard_size]
            for idx in range(0, len(probe_lines), shard_size)
        ]

        def emit_shard(shard_idx_and_lines: tuple[int, list[tuple[bool, str]]]) -> tuple[int, int, str]:
            shard_idx, entries = shard_idx_and_lines
            needs_bl = any(flag for flag, _ in entries)
            lines = [text for _, text in entries]
            shard_lean = stage / f"Wrappers_{shard_idx:02d}.lean"
            shard_lnir = stage / f"module_{shard_idx:02d}.lnir"
            header = "import Orb.Kernel\nimport LeanSys.Spec\n"
            if needs_bl:
                header += BRANCHLESS_PRELUDE + "\n"
            shard_lean.write_text(header + "\n".join(lines) + "\n")
            subprocess.run(
                [
                    str(lean_native_bin),
                    "emit-lnir",
                    "--wire",
                    str(shard_lean),
                    "-o",
                    str(shard_lnir),
                ],
                cwd=stage,
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            wire = shard_lnir.read_text().strip()
            parts = wire.split("|", 3)
            if len(parts) != 4 or parts[0] != "LNIR_WIRE_V1":
                raise RuntimeError(f"unexpected LNIR wire header in {shard_lnir.name}")
            return shard_idx, int(parts[2]), parts[3]

        with ThreadPoolExecutor(max_workers=min(4, len(shards))) as pool:
            shard_results = sorted(pool.map(emit_shard, enumerate(shards)))

        # Deduplicate `D_decl|<sym_hex>|...` blocks across shards while preserving first-seen order.
        seen_decl_names: set[str] = set()
        deduped_decl_blocks: list[str] = []
        for _, _, decl_stream in shard_results:
            for block in re.split(r"(?=\bD_decl\|)", decl_stream):
                block = block.strip("|")
                if not block:
                    continue
                if not block.startswith("D_decl|"):
                    raise RuntimeError(f"unexpected LNIR decl chunk prefix: {block[:40]}")
                sym_hex = block.split("|", 2)[1]
                if sym_hex in seen_decl_names:
                    continue
                seen_decl_names.add(sym_hex)
                deduped_decl_blocks.append(block)

        total_decls = len(deduped_decl_blocks)
        if total_decls < len(public):
            raise RuntimeError(
                f"expected >= {len(public)} LNIR decls, got {total_decls}"
            )
        mod_hex = "Orb.Kernel.LeanNative".encode("utf-8").hex()
        merged_wire = "|".join(
            ["LNIR_WIRE_V1", mod_hex, str(total_decls)] + deduped_decl_blocks
        )
        module_lnir = stage / "module.lnir"
        module_lnir.write_text(merged_wire + "\n")

        for arch_flag, arch_label, out_path in (
            ("x86_64", "x86_64", OUT_X86_64),
            ("arm64", "aarch64", OUT_AARCH64),
        ):
            raw_ll = stage / f"raw_{arch_label}.ll"
            subprocess.run(
                [
                    str(lean_native_core),
                    "compile-llvm",
                    "--arch",
                    arch_flag,
                    "--input",
                    str(module_lnir),
                    "-o",
                    str(raw_ll),
                ],
                cwd=stage,
                env=env,
                check=True,
            )
            cleaned = sanitize_and_append_cabi(raw_ll.read_text(), arch_label, functions)
            compacted = canonicalize_llvm_ir(cleaned, arch_label)
            out_path.write_text(compacted)
            print(f"wrote {out_path.relative_to(ROOT)}")

    stamp = compute_stamp_payload()
    STAMP_JSON.write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    print(f"wrote {STAMP_JSON.relative_to(ROOT)}")


def compute_stamp_payload() -> dict[str, str]:
    return {
        "schema": "orb.kernel.leannative.ll.v1",
        "kernel_lean_sha256": sha256_file(ROOT / "lean/Orb/Kernel.lean"),
        "kernel_abi_json_sha256": sha256_file(MANIFEST),
        "unboxed_c_sha256": sha256_file(UNBOXED_C),
        "leannative_x86_64_ll_sha256": sha256_file(OUT_X86_64),
        "leannative_aarch64_ll_sha256": sha256_file(OUT_AARCH64),
    }


def verify_object_symbols(obj_path: Path, expected_names: set[str], macos: bool = False) -> None:
    nm_bin = shutil.which("llvm-nm") or shutil.which("nm")
    if not nm_bin:
        raise RuntimeError("neither llvm-nm nor nm found in PATH")
    out = subprocess.check_output([nm_bin, "-g", "-P", str(obj_path)], text=True)
    seen: set[str] = set()
    for line in out.splitlines():
        if not line.strip() or line.endswith((":", "]:", "):")):
            continue
        fields = line.split()
        if len(fields) < 2:
            raise AssertionError(f"unrecognized nm row: {line}")
        sym = fields[0][1:] if macos and fields[0].startswith("_") else fields[0]
        kind = fields[1]
        if kind != "T" or sym not in expected_names or sym in seen:
            raise AssertionError(
                f"{obj_path.name}: unexpected, undefined, or duplicate global symbol: {line}"
            )
        seen.add(sym)
    missing = sorted(expected_names - seen)
    if missing:
        raise AssertionError(f"{obj_path.name}: missing exported symbols: {missing[:10]}")


def sample_vectors(functions: list[dict]) -> list[tuple[dict, list[int]]]:
    boundary = [0, 1, 2, 3, 7, 45, 100, 200, 255, 256, 429, 503, 1024, 65535, 0xFFFF_FFFF]
    pairs: list[tuple[dict, list[int]]] = []
    for idx, fn in enumerate(functions):
        params = fn["params"]
        for v in range(6):
            args = []
            for p_idx, p in enumerate(params):
                raw = boundary[(idx + v * 3 + p_idx * 5) % len(boundary)]
                args.append(raw & MASKS[p["type"]])
            pairs.append((fn, args))
    return pairs


def check_ir_files() -> int:
    for required in (OUT_X86_64, OUT_AARCH64, STAMP_JSON, UNBOXED_C):
        if not required.is_file():
            print(f"missing required file: {required.relative_to(ROOT)}", file=sys.stderr)
            return 1

    actual_stamp = json.loads(STAMP_JSON.read_text())
    expected_stamp = compute_stamp_payload()
    if actual_stamp != expected_stamp:
        print(
            "stale shared/orb-spec/cabi/orb_kernel_leannative.sha256 "
            "(run scripts/gen_orb_kernel_leannative_ll.py)",
            file=sys.stderr,
        )
        return 1

    clang = shutil.which("clang")
    if not clang:
        print("clang is required to verify LeanNative textual LLVM IR", file=sys.stderr)
        return 1

    functions = load_manifest()
    expected_names = {fn["name"] for fn in functions}
    host_machine = platform.machine().lower()
    host_is_arm = host_machine in ("aarch64", "arm64")
    host_is_macos = sys.platform == "darwin"

    with tempfile.TemporaryDirectory(prefix="orb-leannative-check-") as tmp:
        tmp_dir = Path(tmp)
        x86_obj = tmp_dir / "orb_kernel_x86_64.o"
        arm_obj = tmp_dir / "orb_kernel_aarch64.o"
        subprocess.run(
            [
                clang,
                "--target=x86_64-unknown-linux-gnu",
                "-Wno-override-module",
                "-O3",
                "-fPIC",
                "-c",
                str(OUT_X86_64),
                "-o",
                str(x86_obj),
            ],
            check=True,
        )
        verify_object_symbols(x86_obj, expected_names, macos=False)

        subprocess.run(
            [
                clang,
                "--target=aarch64-unknown-linux-gnu",
                "-Wno-override-module",
                "-O3",
                "-fPIC",
                "-c",
                str(OUT_AARCH64),
                "-o",
                str(arm_obj),
            ],
            check=True,
        )
        verify_object_symbols(arm_obj, expected_names, macos=False)

        host_ll = OUT_AARCH64 if host_is_arm else OUT_X86_64
        host_ll_so = tmp_dir / "leannative_host.so"
        stock_so = tmp_dir / "stock_host.so"
        subprocess.run(
            [
                clang,
                "-Wno-override-module",
                "-O3",
                "-fPIC",
                "-shared",
                str(host_ll),
                "-o",
                str(host_ll_so),
            ],
            check=True,
        )
        subprocess.run(
            [
                clang,
                "-O3",
                "-fPIC",
                "-shared",
                f"-I{CABI_DIR}",
                str(UNBOXED_C),
                "-o",
                str(stock_so),
            ],
            check=True,
        )
        if host_is_macos:
            host_obj = tmp_dir / "host_native.o"
            subprocess.run(
                [clang, "-Wno-override-module", "-O3", "-fPIC", "-c", str(host_ll), "-o", str(host_obj)],
                check=True,
            )
            verify_object_symbols(host_obj, expected_names, macos=True)

        native_lib = ctypes.CDLL(str(host_ll_so))
        stock_lib = ctypes.CDLL(str(stock_so))
        for fn, args in sample_vectors(functions):
            name = fn["name"]
            argtypes = [CTYPES_MAP[p["type"]] for p in fn["params"]]
            restype = CTYPES_MAP[fn["ret"]]
            nf = getattr(native_lib, name)
            sf = getattr(stock_lib, name)
            nf.argtypes = sf.argtypes = argtypes
            nf.restype = sf.restype = restype
            nv = int(nf(*args))
            sv = int(sf(*args))
            if nv != sv:
                raise AssertionError(f"differential mismatch on {name}({args}): leannative={nv} stock={sv}")

    print(
        f"verified {OUT_X86_64.relative_to(ROOT)} & {OUT_AARCH64.relative_to(ROOT)} "
        f"({len(expected_names)} C-ABI exports, 0 undefined symbols, 0 differential mismatches)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed .ll files, symbol hygiene, and differential equivalence against stock C",
    )
    parser.add_argument(
        "--turbo-root",
        type=Path,
        default=Path(
            os.environ.get(
                "TURBO_LEAN_ROOT",
                str(ROOT.parent / "turbo-lean"),
            )
        ),
    )
    parser.add_argument(
        "--lean-sys-root",
        type=Path,
        default=Path(
            os.environ.get(
                "LEAN_SYS_ROOT",
                str(ROOT.parent / "lean-sys"),
            )
        ),
    )
    parser.add_argument(
        "--lean-bin-dir",
        type=Path,
        default=None,
    )
    parser.add_argument(
        "--lean-native-core",
        type=Path,
        default=None,
    )
    args = parser.parse_args(argv)
    if args.check:
        return check_ir_files()
    lean_bin_dir = (args.lean_bin_dir or default_lean_bin_dir()).resolve()
    turbo_root_resolved = args.turbo_root.resolve()
    if args.lean_native_core is not None:
        lean_native_core_resolved = args.lean_native_core.resolve()
    elif os.environ.get("LEAN_NATIVE_CORE_BIN"):
        lean_native_core_resolved = Path(os.environ["LEAN_NATIVE_CORE_BIN"]).resolve()
    elif (turbo_root_resolved / "lean/.lake/build/bin/lean-native-core").is_file():
        lean_native_core_resolved = (
            turbo_root_resolved / "lean/.lake/build/bin/lean-native-core"
        ).resolve()
    else:
        lean_native_core_resolved = Path(
            shutil.which("lean-native-core") or "/usr/local/bin/lean-native-core"
        ).resolve()
    generate_ir_files(
        turbo_root_resolved,
        args.lean_sys_root.resolve(),
        lean_bin_dir,
        lean_native_core_resolved,
    )
    return check_ir_files()


if __name__ == "__main__":
    raise SystemExit(main())
