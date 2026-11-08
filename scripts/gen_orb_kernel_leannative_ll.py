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
@[inline] def blEz8  (a : UInt8) : UInt32 := blEz32 a.toUInt32
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
    "orb_followup_queue_step": """@[export probe_orb_followup_queue_step] def probe_orb_followup_queue_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) : UInt64 :=
  let op := a0.toUInt8; let serverRev := a1.toUInt32; let incoming := a2.toUInt32; let expected := a3.toUInt32
  let clientMsg := a4; let tracked := a5; let delivered := a6; let posted := a7; let turn := a8
  let optimistic := a9.toUInt8; let listed := a10.toUInt8; let matched := a11.toUInt8; let already := a12.toUInt8
  let shaped := blLe8 op 3 &&& blLe8 optimistic 1 &&& blLe8 listed 1 &&& blLe8 matched 1 &&& blLe8 already 1 &&& blNz32 serverRev
  let hasClient := blNz64 clientMsg; let notDelivered := blEz8 already; let unlisted := blEz8 listed
  let idMatch := hasClient &&& notDelivered &&& blEq64 delivered clientMsg
  let contentRetire := hasClient &&& notDelivered &&& blEz64 delivered &&& blEq8 matched 1 &&& blLt64 posted turn
  let turnRetires := blEq8 op 3 &&& (idMatch ||| contentRetire)
  let pollRetires := blEz8 op &&& blLe32 serverRev incoming &&& hasClient &&& notDelivered &&& unlisted &&& blEz8 optimistic &&& blLt64 posted turn
  let retired := shaped &&& (turnRetires ||| pollRetires)
  let dup := blEq8 op 2 &&& hasClient &&& (blEq64 clientMsg tracked ||| (notDelivered ^^^ 1))
  let admit0 := blLe32 serverRev incoming
  let admit1 := blEq32 expected serverRev &&& blLt32 serverRev 0xFFFFFFFF
  let admit2 := hasClient &&& (dup ^^^ 1)
  let admitOp := blSel32 (blEz8 op) admit0 (blSel32 (blEq8 op 1) admit1 (blSel32 (blEq8 op 2) admit2 turnRetires))
  let admit := shaped &&& admitOp
  let nextRev := blSel32 (admit ^^^ 1) serverRev (blSel32 (blEz8 op) incoming (blSel32 (blEq8 op 1) (serverRev + 1) serverRev))
  let live0 := blSel32 (blLt32 incoming serverRev) hasClient (hasClient &&& unlisted)
  let live2 := hasClient &&& (admit ||| blEq64 clientMsg tracked)
  let liveOp := blSel32 (blEz8 op) live0 (blSel32 (blEq8 op 2) live2 (hasClient &&& unlisted))
  let live := shaped &&& notDelivered &&& (retired ^^^ 1) &&& liveOp
  let reasonOp :=
    blSel32 admit 1
      (blSel32 (blEz8 op) 2
        (blSel32 (blEq8 op 1) (blSel32 (blEq32 expected serverRev ^^^ 1) 2 5)
          (blSel32 (blEq8 op 2) (blSel32 dup 3 0) (blSel32 notDelivered 4 3))))
  let reason := blSel32 shaped reasonOp 0
  let lo32 := reason ||| (admit <<< 8) ||| (live <<< 9) ||| (retired <<< 10)
  lo32.toUInt64 ||| (nextRev.toUInt64 <<< 32)""",
    "orb_transport_epoch_step": """@[export probe_orb_transport_epoch_step] def probe_orb_transport_epoch_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) : UInt64 :=
  let mode := a0.toUInt8; let eventKind := a1.toUInt8; let sticky := a3.toUInt8
  let epClass := a4.toUInt8; let prevEp := a5.toUInt8; let hasSeq := a6.toUInt8
  let streak := a7.toUInt32; let threshold := a8.toUInt32; let status := a9.toUInt32; let since := a10.toUInt32
  let shaped := blLe8 mode 2 &&& blLe8 eventKind 4 &&& blLe8 a2.toUInt8 1 &&& blLe8 sticky 1 &&& blLe8 epClass 3 &&& blLe8 prevEp 3 &&& blLe8 hasSeq 1 &&& blNz32 threshold
  let epochReset := blEq8 eventKind 4 ||| (blEq8 epClass prevEp ^^^ 1)
  let perm := (epochReset ^^^ 1) &&& blEq8 eventKind 2 &&& (blEq32 status 404 ||| blEq32 status 501)
  let transient := (epochReset ^^^ 1) &&& (blEq8 eventKind 1 ||| (blEq8 eventKind 2 &&& (perm ^^^ 1)))
  let bumped := blSel32 (blLt32 streak 255) (streak + 1) 255
  let clamped := blSel32 (blLe32 threshold 255) threshold 255
  let keptSticky := blEq8 sticky 1
  let nextSticky := blSel32 shaped (blSel32 epochReset 0 (blSel32 perm 1 keptSticky)) keptSticky
  let keptStreak := blSel32 (blLe32 streak 255) streak 255
  let permStreak := blSel32 (blLe32 clamped bumped) bumped clamped
  let nextStreak :=
    blSel32 shaped
      (blSel32 (blEq8 eventKind 0 ||| epochReset) 0
        (blSel32 perm permStreak (blSel32 transient bumped keptStreak)))
      keptStreak
  let resetMode := blSel32 (blEq8 mode 1 ||| blEq8 eventKind 4) 2 0
  let transientMode := blSel32 (blLe32 threshold bumped) 1 0
  let cooldownMode := blSel32 (blEq8 mode 1 &&& blLe64 a12 a11) 2 mode.toUInt32
  let nextMode :=
    blSel32 shaped
      (blSel32 epochReset resetMode
        (blSel32 nextSticky 1
          (blSel32 (blEq8 eventKind 0) 0
            (blSel32 transient transientMode (blSel32 (blEq8 eventKind 3) cooldownMode mode.toUInt32)))))
      mode.toUInt32
  let reprobe := shaped &&& ((blEq8 mode 1 &&& blEq32 nextMode 2) ||| blEq8 eventKind 4) &&& (nextSticky ^^^ 1)
  let seqPresent := shaped &&& blEq8 hasSeq 1
  let outSeq := blSel32 seqPresent since 0
  let lo32 :=
    blSel32 shaped
      (nextMode ||| (256 : UInt32) ||| (nextSticky <<< 9) ||| ((shaped &&& blEq32 nextMode 1) <<< 10) ||| (reprobe <<< 11) ||| (seqPresent <<< 12) ||| (nextStreak <<< 16))
      255
  lo32.toUInt64 ||| (outSeq.toUInt64 <<< 32)""",
    "orb_stream_open_tail_cap_step": """@[export probe_orb_stream_open_tail_cap_step] def probe_orb_stream_open_tail_cap_step (a0 a1 a2 a3 a4 a5 a6 : UInt64) : UInt64 :=
  let prevLen := a0.toUInt32; let prevCommit := a1.toUInt32; let prevCp := a2.toUInt32
  let newLen := a3.toUInt32; let raw := a4.toUInt32; let maxTail := a5.toUInt32
  let valid := blLt32 0 maxTail &&& blLe32 prevCommit prevCp &&& blLe32 prevCp prevLen &&& blLe32 prevLen newLen
  let clamped := blSel32 (blLe32 raw newLen) raw newLen
  let nextCommit := blSel32 (blLe32 prevCommit clamped) clamped prevCommit
  let baseCp := blSel32 (blLe32 prevCp nextCommit) nextCommit prevCp
  let capFloor := blSel32 (blLe32 maxTail newLen) (newLen - maxTail) 0
  let nextCp := blSel32 (blLe32 baseCp capFloor) capFloor baseCp
  let forced := blLt32 nextCommit nextCp
  let baseLo := blSel32 valid ((257 : UInt32) ||| (forced <<< 9)) 0
  let baseHi := blSel32 valid nextCp prevCp
  let admit := blLe8 a6.toUInt8 1 &&& ((baseLo >>> 8) &&& 1)
  let lo32 := blSel32 admit (baseLo ||| ((blEq8 a6.toUInt8 1 &&& forced) <<< 10)) 0
  let hi32 := blSel32 admit baseHi prevCp
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)""",
    "orb_stream_commit_step": """@[export probe_orb_stream_commit_step] def probe_orb_stream_commit_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 : UInt64) : UInt64 :=
  let tick := a0.toUInt8; let openKind := a1.toUInt8; let openCount := a2.toUInt32
  let lineBlank := a3.toUInt8; let lineTick := a4.toUInt8; let markerKind := a5.toUInt8
  let markerCount := a6.toUInt32; let pos := a7.toUInt32; let commit := a8.toUInt32
  let tick1 := blEq8 tick 1
  let nextTick := blSel32 (blEq8 lineTick 1) (tick1 ^^^ 1) tick1
  let markerLong := blLe32 3 markerCount
  let markerValid := (blEq8 markerKind 1 ||| blEq8 markerKind 2) &&& markerLong
  let openNext := blSel32 markerValid markerKind.toUInt32 0
  let closeMatch := blEq8 markerKind openKind &&& blLe32 openCount markerCount &&& markerLong
  let closeNext := blSel32 closeMatch 0 openKind.toUInt32
  let nextFenceKind := blSel32 (blEz8 openKind) openNext closeNext
  let nextPos := blSatAdd32 pos 1
  let commits := blEq8 lineBlank 1 &&& blEz32 nextTick &&& blEz32 nextFenceKind
  let nextCommit := blSel32 commits nextPos commit
  let fence1 := blEq32 nextFenceKind 1
  let nextFenceBits := blSel32 fence1 256 (blSel32 (blEq32 nextFenceKind 2) 512 0)
  let lo32 := nextTick ||| nextFenceBits ||| (commits <<< 16)
  lo32.toUInt64 ||| (nextCommit.toUInt64 <<< 32)""",
    "orb_provider_pool_step": """@[export probe_orb_provider_pool_step] def probe_orb_provider_pool_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) : UInt64 :=
  let hasBound := blEq8 a0.toUInt8 1; let boundId := a1.toUInt32; let candId := a2.toUInt32
  let isRej := blEq8 a3.toUInt8 1; let fb := blEq8 a4.toUInt8 1; let isFailover := blEq8 a5.toUInt8 1
  let attempts := a6.toUInt32; let maxAtt := a7.toUInt32
  let lockBit := fb <<< 16
  let c1 := fb &&& isFailover
  let c2 := isFailover &&& ((blLe32 1 maxAtt &&& blLt32 attempts maxAtt) ^^^ 1)
  let c3 := hasBound &&& (blEq32 candId boundId ^^^ 1)
  let c4 := isRej &&& blLt64 a8 a9
  let c5 := blEz32 candId
  let okLo := blSel32 hasBound 1 2 + 256 + lockBit
  let lo32 := blSel32 c1 (3 + lockBit) (blSel32 c2 (4 + lockBit) (blSel32 (c3 ||| c4 ||| c5) lockBit okLo))
  let hi32 := blSel32 (c1 ||| c2 ||| c3 ||| c4 ||| c5) 0 candId
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)""",
    "orb_node_gc_step": """@[export probe_orb_node_gc_step] def probe_orb_node_gc_step (a0 a1 a2 a3 a4 a5 a6 : UInt64) : UInt64 :=
  let underFloor := blLt64 a0 a1
  let emerg := blLt64 a0 a2
  let deficit := a1 - a0
  let agedCovers := blLe64 deficit a3
  let rem1 := blSel64 agedCovers 0 (deficit - a3)
  let coldCovers := blLe64 rem1 a5
  let rem2 := blSel64 coldCovers 0 (rem1 - a5)
  let freshCovers := blLe64 rem2 a4
  let rem3 := blSel64 freshCovers 0 (rem2 - a4)
  let unrec := blLt64 a6 rem3
  let evictCold := blNz64 rem1
  let hasRem2 := blNz64 rem2
  let sweepFresh := hasRem2 ||| emerg
  let hasRem3 := blNz64 rem3
  let evictHot := hasRem3 &&& ((unrec ^^^ 1) ||| (emerg &&& blNz64 a6))
  let act := blSel32 (unrec &&& (evictHot ^^^ 1)) 5 (blSel32 evictHot 4 (blSel32 sweepFresh 3 (blSel32 evictCold 2 1)))
  let lo32 := act ||| (256 : UInt32) ||| (evictCold <<< 9) ||| (sweepFresh <<< 10) ||| (evictHot <<< 11) ||| (unrec <<< 12)
  let grace := blSel32 sweepFresh 0 6
  let underWord := lo32.toUInt64 ||| (grace.toUInt64 <<< 32)
  blSel64 underFloor underWord ((72 : UInt64) <<< 32)""",
    "orb_http_rate_limit_classify_step": """@[export probe_orb_http_rate_reason] def probe_orb_http_rate_reason (st quotaHint authHint : UInt32) : UInt32 :=
  let r429 := blSel32 quotaHint 2 1
  let is401_403 := blEq32 st 401 ||| (blEq32 st 403 &&& authHint)
  let is529_503 := blEq32 st 529 ||| blEq32 st 503
  let is5xx := blLe32 500 st &&& blLt32 st 600
  blSel32 (blEq32 st 429) r429
    (blSel32 (blEq32 st 402) 2
      (blSel32 is401_403 3
        (blSel32 is529_503 4 (blSel32 is5xx 5 0))))

@[export probe_orb_http_rate_limit_classify_step] def probe_orb_http_rate_limit_classify_step (a0 a1 a2 a3 a4 : UInt64) : UInt64 :=
  let reason := probe_orb_http_rate_reason a0.toUInt32 (blEq8 a1.toUInt8 1) (blEq8 a2.toUInt8 1)
  let cap := blSel64 (blEz64 a4) 3600 a4
  let dflt := blSel64 (blEq32 reason 2) 300 15
  let raw := blSel64 (blEz64 a3) dflt a3
  let cl64 := blSel64 (blLe64 raw cap) raw cap
  let cl32 := blSel32 (blLe64 cl64 0xFFFFFFFF) cl64.toUInt32 0xFFFFFFFF
  let retryBit := (blEq32 reason 1 ||| blEq32 reason 4 ||| blEq32 reason 5) <<< 9
  let lo32 := reason ||| (256 : UInt32) ||| retryBit
  let w := lo32.toUInt64 ||| (cl32.toUInt64 <<< 32)
  blSel64 (blEz32 reason) 0 w""",
    "orb_effect_outbox_step": """@[export probe_orb_effect_outbox_step] def probe_orb_effect_outbox_step (a0 a1 a2 a3 a4 a5 : UInt64) : UInt64 :=
  let phase := a0.toUInt8; let deliv := a1.toUInt8; let op := a2.toUInt8
  let phase32 := phase.toUInt32; let op32 := op.toUInt32
  let fenceOk := blEq8 a3.toUInt8 1 &&& blEq64 a4 a5 &&& blNz64 a4
  let phaseOk := blLe8 phase 5; let opOk := blLe8 op 5
  let ok := fenceOk &&& phaseOk &&& opOk
  let p0 := blSel32 (blEq8 phase 3 ||| blEq8 phase 5) 0 phase32
  let p1 := blSel32 (blEz8 phase) 1 phase32
  let p2 := blSel32 (blEq8 phase 1) 2 phase32
  let p3 := blSel32 (blEq8 phase 1) 3 phase32
  let p4 := blSel32 (blEq8 phase 1) 4 phase32
  let p5 := blSel32 (blEq8 phase 4) 5 phase32
  let opPhase :=
    blSel32 (blEz8 op) p0
      (blSel32 (blEq32 op32 1) p1
        (blSel32 (blEq32 op32 2) p2
          (blSel32 (blEq32 op32 3) p3
            (blSel32 (blEq32 op32 4) p4 (blSel32 (blEq32 op32 5) p5 phase32)))))
  let nextPhase := blSel32 ok opPhase phase32
  let moved := blEq32 nextPhase phase32 ^^^ 1
  let delivMoved := blSel32 (blEq32 nextPhase 2) 1 (blSel32 (blEz32 nextPhase ||| blEq32 nextPhase 3) 0 deliv.toUInt32)
  let delivNext := blSel32 moved delivMoved deliv.toUInt32
  let freshRetry := (blEq32 op32 1 ||| blEq32 op32 2) &&& blEq8 phase 4
  let lo32 :=
    blSel32 (fenceOk ^^^ 1) 4
      (blSel32 ((phaseOk &&& opOk) ^^^ 1) 0
        (blSel32 freshRetry 3
          (blSel32 moved ((257 : UInt32) ||| (nextPhase <<< 16)) 2)))
  lo32.toUInt64 ||| (delivNext.toUInt64 <<< 32)""",
    "orb_fleet_place_argmin_step": """@[export probe_orb_fleet_place_argmin_step] def probe_orb_fleet_place_argmin_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 : UInt64) : UInt64 :=
  let aq := blEz8 a0.toUInt8 ^^^ 1
  let bq := blEz8 a3.toUInt8 ^^^ 1
  let as_ := blEz8 a1.toUInt8 ^^^ 1
  let bs_ := blEz8 a4.toUInt8 ^^^ 1
  let ac := blSel64 (blEz32 a8.toUInt32) 1 a8.toUInt32.toUInt64
  let bc := blSel64 (blEz32 a11.toUInt32) 1 a11.toUInt32.toUInt64
  let lhs := a7.toUInt32.toUInt64 * bc
  let rhs := a10.toUInt32.toUInt64 * ac
  let ad := blEz8 a2.toUInt8 ^^^ 1
  let bd := blEz8 a5.toUInt8 ^^^ 1
  let idLt := blEq8 a6.toUInt8 1
  let diskCmp := blSel32 (blLt32 a12.toUInt32 a9.toUInt32) 1 (blSel32 (blLt32 a9.toUInt32 a12.toUInt32) 0 idLt)
  let memCmp := blSel32 (blLt64 a14 a13) 1 (blSel32 (blLt64 a13 a14) 0 diskCmp)
  let softCmp := blSel32 (blLt32 ad bd) 1 (blSel32 (blLt32 bd ad) 0 memCmp)
  let loadCmp := blSel32 (blLt64 lhs rhs) 1 (blSel32 (blLt64 rhs lhs) 0 softCmp)
  let specCmp := blSel32 (blLt32 as_ bs_) 1 (blSel32 (blLt32 bs_ as_) 0 loadCmp)
  (blSel32 (blLt32 aq bq) 1 (blSel32 (blLt32 bq aq) 0 specCmp)).toUInt64""",
    "orb_proxy_exhaustion_step": """@[export probe_orb_proxy_exhaustion_step] def probe_orb_proxy_exhaustion_step (a0 a1 a2 a3 a4 a5 : UInt64) : UInt64 :=
  let rl := a0.toUInt32; let pay := a1.toUInt32; let auth := a2.toUInt32
  let srv := a3.toUInt32; let tv := a4.toUInt32; let ctx := a5.toUInt8
  let rl0 := blEz32 rl; let pay0 := blEz32 pay; let auth0 := blEz32 auth; let srv0 := blEz32 srv
  let noAttempt := rl0 &&& pay0 &&& auth0 &&& srv0
  let attempted := rl.toUInt64 + pay.toUInt64 + auth.toUInt64 + srv.toUInt64
  let isTv := blEq64 tv.toUInt64 attempted
  let isCtx := blEq8 ctx 1 &&& rl0 &&& pay0
  let isPay := (pay0 ^^^ 1) &&& rl0 &&& srv0
  let isAuth := (auth0 ^^^ 1) &&& pay0 &&& rl0 &&& srv0
  let isSrv := (srv0 ^^^ 1) &&& rl0
  (blSel32 noAttempt 1
    (blSel32 isTv 2
      (blSel32 isCtx 3
        (blSel32 isPay 4
          (blSel32 isAuth 5
            (blSel32 isSrv 6 7)))))).toUInt64""",
    "orb_sidebar_drag_step": """@[export probe_orb_sidebar_drag_step] def probe_orb_sidebar_drag_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 : UInt64) : UInt64 :=
  let phase := a0.toUInt8; let ev := a1.toUInt8; let rowMov := a2.toUInt8
  let tCol := a3.toUInt8; let tAdm := a4.toUInt8
  let distSq := a5.toUInt32; let elMs := a6.toUInt32; let spMs := a7.toUInt32
  let hovOrd := a8.toUInt32; let spOrd := a9.toUInt32
  let topDist := a10.toUInt32; let botDist := a11.toUInt32
  let badDom := (blLe8 phase 3 &&& blLe8 ev 5) ^^^ 1
  let isCancel := blEq8 ev 5
  let isDown := blEq8 ev 0
  let isIdle := blEq8 phase 0
  let isHold := blEq8 ev 1
  let isMove := blEq8 ev 2
  let isSpring := blEq8 ev 3
  let holdArm := blEq8 phase 1 &&& blLe32 260 elMs &&& blLt32 distSq 36
  let holdLo := blSel32 holdArm ((2 : UInt32) ||| ((1 : UInt32) <<< 8)) phase.toUInt32
  let holdHi := blSel32 holdArm 0 spOrd
  let entersDrag := (blEq8 phase 1 ||| blEq8 phase 2) &&& blLe32 36 distSq
  let activeDrag := blEq8 phase 3 ||| entersDrag
  let stayArmed := blEq8 phase 2 &&& blLt32 distSq 36
  let movePhase := blSel32 activeDrag 3 (blSel32 stayArmed 2 1)
  let moveEff := blSel32 entersDrag 2 0
  let topIn := blLt32 topDist 36
  let botIn := (topIn ^^^ 1) &&& blLt32 botDist 36
  let upCalc := (((36 - topDist).toUInt64 * 10 + 35) / 36).toUInt32
  let dnCalc := (((36 - botDist).toUInt64 * 10 + 35) / 36).toUInt32
  let upPx := blSel32 topIn upCalc 0
  let dnPx := blSel32 botIn dnCalc 0
  let rawPx := blSel32 (blLt32 0 upPx) upPx dnPx
  let clampPx := blSel32 (blLt32 10 rawPx) 10 rawPx
  let dirBits := blSel32 (topIn &&& blLt32 0 upCalc) ((1 : UInt32) <<< 17)
    (blSel32 (botIn &&& blLt32 0 dnCalc) ((1 : UInt32) <<< 18) 0)
  let stepPx := blSel32 activeDrag clampPx 0
  let stepDir := blSel32 activeDrag dirBits 0
  let moveLo := movePhase ||| (moveEff <<< 8) ||| stepDir ||| (stepPx <<< 24)
  let moveHi := blSel32 (activeDrag &&& blEq8 tCol 1 &&& blNz32 hovOrd) hovOrd 0
  let spMatch := blEq8 phase 3 &&& blEq8 tCol 1 &&& blNz32 hovOrd &&& blEq32 hovOrd spOrd
  let spReady := blLe32 450 spMs
  let spLo := blSel32 (spMatch &&& spReady) ((3 : UInt32) ||| ((3 : UInt32) <<< 8)) phase.toUInt32
  let spHi := blSel32 (spMatch &&& (spReady ^^^ 1)) spOrd 0
  let upDrop := blNz32 hovOrd &&& blEq8 tAdm 1
  let upLo := blSel32 (blEq8 phase 1) 0
    (blSel32 (blEq8 phase 2) (((5 : UInt32) <<< 8) ||| ((1 : UInt32) <<< 16))
      (blSel32 upDrop (((4 : UInt32) <<< 8) ||| ((1 : UInt32) <<< 16))
        (((6 : UInt32) <<< 8) ||| ((1 : UInt32) <<< 16))))
  let lo32 :=
    blSel32 badDom ((6 : UInt32) <<< 8)
      (blSel32 isCancel (blSel32 isIdle 0 ((6 : UInt32) <<< 8))
        (blSel32 isDown (blSel32 (blEq8 rowMov 1) 1 0)
          (blSel32 isIdle 0
            (blSel32 isHold holdLo
              (blSel32 isMove moveLo
                (blSel32 isSpring spLo upLo))))))
  let hi32 :=
    blSel32 (badDom ||| isCancel ||| isDown ||| isIdle) 0
      (blSel32 isHold holdHi
        (blSel32 isMove moveHi
          (blSel32 isSpring spHi 0)))
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)""",
    "orb_rtt_ewma_step": """@[export probe_orb_rtt_ewma_step] def probe_orb_rtt_ewma_step (a0 a1 a2 : UInt64) : UInt64 :=
  let srttMs := a0 &&& 0xFFFFFFFF; let rttVarMs := a1 &&& 0xFFFFFFFF; let sampleMs := a2 &&& 0xFFFFFFFF
  let sample64 := blSel64 (blEz64 sampleMs) 1 (blSel64 (blLt64 60000 sampleMs) 60000 sampleMs)
  let halfSample := sample64 >>> 1
  let initVar := blSel64 (blLt64 halfSample 50) 50 halfSample
  let coldWord := sample64 ||| (initVar <<< 32)
  let srtt64 := blSel64 (blLt64 60000 srttMs) 60000 srttMs
  let var64 := blSel64 (blLt64 60000 rttVarMs) 60000 rttVarMs
  let diff64 := blSel64 (blLe64 sample64 srtt64) (srtt64 - sample64) (sample64 - srtt64)
  let rawVar := (3 * var64 + diff64) >>> 2
  let nextVar := blSel64 (blLt64 rawVar 10) 10 (blSel64 (blLt64 60000 rawVar) 60000 rawVar)
  let rawSrtt := (7 * srtt64 + sample64) >>> 3
  let nextSrtt := blSel64 (blLt64 rawSrtt 1) 1 (blSel64 (blLt64 60000 rawSrtt) 60000 rawSrtt)
  let warmWord := nextSrtt ||| (nextVar <<< 32)
  blSel64 (blEz64 srttMs) coldWord warmWord""",
    "orb_client_link_budget_step": """@[export probe_orb_client_link_budget_step] def probe_orb_client_link_budget_step (a0 a1 a2 a3 a4 : UInt64) : UInt64 :=
  let srtt64_in := a0 &&& 0xFFFFFFFF; let var64_in := a1 &&& 0xFFFFFFFF; let fails := a2 &&& 0xFFFFFFFF
  let constrained := a3 &&& 0xFF; let p0 := a4 &&& 0xFFFFFFFF
  let degraded := blLt64 1200 srtt64_in ||| blLt64 0 fails ||| blNz64 constrained
  let moderate := (degraded ^^^ 1) &&& blLt64 400 srtt64_in
  let p1Cap := blSel64 degraded 2 (blSel64 moderate 3 6)
  let p2Cap := blSel64 (blLt64 0 p0 ||| degraded) 0 (blSel64 moderate 1 4)
  let srtt64 := blSel64 (blLt64 60000 srtt64_in) 60000 srtt64_in
  let var64 := blSel64 (blLt64 60000 var64_in) 60000 var64_in
  let failSteps := blSel64 (blLe64 4 fails) 4 fails
  let baseConn := blSel64 (blEz64 srtt64) 10000 (srtt64 + 4 * var64 + 4000)
  let rawConn := baseConn + 2000 * failSteps
  let connMs := blSel64 (blLt64 rawConn 8000) 8000 (blSel64 (blLt64 30000 rawConn) 30000 rawConn)
  let rawPong := blSel64 (blEz64 srtt64) 8000 (srtt64 + 4 * var64 + 3000)
  let pongMs := blSel64 (blLt64 rawPong 8000) 8000 (blSel64 (blLt64 25000 rawPong) 25000 rawPong)
  let rawWake := blSel64 (blEz64 srtt64) 6000 (srtt64 + 2 * var64 + 2500)
  let wakeMs := blSel64 (blLt64 rawWake 6000) 6000 (blSel64 (blLt64 15000 rawWake) 15000 rawWake)
  let lo64 := p1Cap ||| (p2Cap <<< 8) ||| (connMs <<< 16)
  let hi64 := pongMs ||| (wakeMs <<< 16)
  lo64 ||| (hi64 <<< 32)""",
    "orb_multiuser_rbac_step": """@[export probe_orb_multiuser_rbac_step] def probe_orb_multiuser_rbac_step (a0 a1 a2 a3 a4 a5 a6 : UInt64) : UInt64 :=
  let authed := a0 &&& 0xFF; let dis := a1 &&& 0xFF; let ep := a2 &&& 0xFF
  let role := a3 &&& 0xFF; let op := a4 &&& 0xFF; let own := a5 &&& 0xFF; let part := a6 &&& 0xFF
  let ok200 : UInt64 := (1 : UInt64) ||| ((200 : UInt64) <<< 1)
  let e401  : UInt64 := ((401 : UInt64) <<< 1) ||| ((1 : UInt64) <<< 17)
  let eDis  : UInt64 := ((403 : UInt64) <<< 1) ||| ((2 : UInt64) <<< 17)
  let eAdm  : UInt64 := ((403 : UInt64) <<< 1) ||| ((3 : UInt64) <<< 17)
  let e404  : UInt64 := ((404 : UInt64) <<< 1) ||| ((4 : UInt64) <<< 17)
  let eOwn  : UInt64 := ((403 : UInt64) <<< 1) ||| ((5 : UInt64) <<< 17)
  let eInv  : UInt64 := ((403 : UInt64) <<< 1) ||| ((6 : UInt64) <<< 17)
  let badAuth := (blEq64 authed 1 ^^^ 1) ||| (blEq64 ep 1 ^^^ 1)
  let isDis := blNz64 dis
  let badRole := blLt64 1 role
  let rOp1 := blSel64 (blEq64 role 1) ok200 eAdm
  let rOp2 := blSel64 (blEq64 own 1 ||| blEq64 part 1) ok200 e404
  let rOp3 := blSel64 (blEq64 own 1) ok200 (blSel64 (blEq64 part 1) eOwn e404)
  let rOp4 := blSel64 (blEq64 own 1) ok200 e404
  let byOp := blSel64 (blEz64 op) ok200
    (blSel64 (blEq64 op 1) rOp1
      (blSel64 (blEq64 op 2) rOp2
        (blSel64 (blEq64 op 3) rOp3
          (blSel64 (blEq64 op 4) rOp4 eInv))))
  blSel64 badAuth e401 (blSel64 isDis eDis (blSel64 badRole eInv byOp))""",
    "orb_placement_role_admit": """@[export probe_orb_placement_role_admit] def probe_orb_placement_role_admit (a0 a1 a2 a3 : UInt64) : UInt64 :=
  let role := a0 &&& 0xFF; let tgt := a1 &&& 0xFF; let admOnly := a2 &&& 0xFF; let validUnix := a3 &&& 0xFF
  let inDom := blLe64 tgt 4
  let memDed := (blEq64 tgt 2 ||| blEq64 tgt 3) &&& blEz64 admOnly &&& blEq64 validUnix 1
  let memOk := blEq64 tgt 4 ||| memDed
  let ok := inDom &&& (blEq64 role 1 ||| (blEz64 role &&& memOk))
  blSel64 ok 1 0""",
    "orb_user_spend_cap_step": """@[export probe_orb_user_spend_cap_step] def probe_orb_user_spend_cap_step (a0 a1 a2 a3 a4 a5 a6 : UInt64) : UInt64 :=
  let gAct := a0 &&& 0xFF; let gSpent := a1 &&& 0xFFFFFFFF; let gCap := a2 &&& 0xFFFFFFFF
  let uAct := a3 &&& 0xFF; let uSpent := a4 &&& 0xFFFFFFFF; let uCap := a5 &&& 0xFFFFFFFF
  let delta := a6 &&& 0xFFFFFFFF
  let maxL : UInt64 := 0x3FFFFFFF
  let curG := blSel64 (blLe64 gSpent maxL) gSpent maxL
  let curU := blSel64 (blLe64 uSpent maxL) uSpent maxL
  let rawG := gSpent + delta
  let rawU := uSpent + delta
  let ov := blLt64 maxL rawG ||| blLt64 maxL rawU
  let gEx := blNz64 gAct &&& blLt64 gCap rawG
  let uEx := blNz64 uAct &&& blLt64 uCap rawU
  let denyBase := (curG <<< 4) ||| (curU <<< 34)
  let okWord := (1 : UInt64) ||| (rawG <<< 4) ||| (rawU <<< 34)
  blSel64 gEx (((1 : UInt64) <<< 1) ||| denyBase)
    (blSel64 uEx (((2 : UInt64) <<< 1) ||| denyBase)
      (blSel64 ov (((3 : UInt64) <<< 1) ||| denyBase) okWord))""",
    "orb_privd_user_exec_step": """@[export probe_orb_privd_user_exec_step] def probe_orb_privd_user_exec_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) : UInt64 :=
  let peer := a0 &&& 0xFF; let lease := a1 &&& 0xFF; let admOnly := a2 &&& 0xFF
  let role := a3 &&& 0xFF; let uValid := a4 &&& 0xFF
  let uid := a5 &&& 0xFFFFFFFF; let gid := a6 &&& 0xFFFFFFFF
  let gidDisj := a7 &&& 0xFF; let homeOk := a8 &&& 0xFF; let elanOk := a9 &&& 0xFF
  let badUidGid := blLt64 uid 2000 ||| blLe64 65534 uid ||| blLt64 gid 2000 ||| blLe64 65534 gid
  blSel64 (blEq64 peer 1 ^^^ 1) ((1 : UInt64) <<< 8)
    (blSel64 (blEq64 lease 1 ^^^ 1) ((2 : UInt64) <<< 8)
      (blSel64 (blLt64 1 role) ((3 : UInt64) <<< 8)
        (blSel64 (blEz64 role &&& blNz64 admOnly) ((4 : UInt64) <<< 8)
          (blSel64 (blEq64 uValid 1 ^^^ 1) ((5 : UInt64) <<< 8)
            (blSel64 badUidGid ((6 : UInt64) <<< 8)
              (blSel64 (blEq64 gidDisj 1 ^^^ 1) ((7 : UInt64) <<< 8)
                (blSel64 (blEq64 homeOk 1 ^^^ 1) ((8 : UInt64) <<< 8)
                  (blSel64 (blEq64 elanOk 1 ^^^ 1) ((9 : UInt64) <<< 8) 1))))))))""",
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

theorem eq_followup_queue (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) :
    probe_orb_followup_queue_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 =
    Orb.Kernel.followupQueueStep a0.toUInt8 a1.toUInt32 a2.toUInt32 a3.toUInt32 a4 a5 a6 a7 a8 a9.toUInt8 a10.toUInt8 a11.toUInt8 a12.toUInt8 := by
  simp only [bne, blNz32, blEz32, blEq8, blEz8, blEq32, blNz64, blEz64, blEq64, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32,
    probe_orb_followup_queue_step, Orb.Kernel.followupQueueStep]
  bv_decide

theorem eq_transport_epoch (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 : UInt64) :
    probe_orb_transport_epoch_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 =
    Orb.Kernel.transportEpochStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt8 a7.toUInt32 a8.toUInt32 a9.toUInt32 a10.toUInt32 a11 a12 := by
  simp only [bne, blNz32, blEz32, blEq8, blEq32, blLt32, blLe32, blLe8, blLt64, blLe64, blSel32,
    probe_orb_transport_epoch_step, Orb.Kernel.transportEpochStep]
  bv_decide

theorem eq_stream_open_tail_cap (a0 a1 a2 a3 a4 a5 a6 : UInt64) :
    probe_orb_stream_open_tail_cap_step a0 a1 a2 a3 a4 a5 a6 =
    Orb.Kernel.streamOpenTailCapStep a0.toUInt32 a1.toUInt32 a2.toUInt32 a3.toUInt32 a4.toUInt32 a5.toUInt32 a6.toUInt8 := by
  simp only [bne, blNz32, blEz32, blEq8, blLt32, blLe32, blLe8, blSel32,
    probe_orb_stream_open_tail_cap_step, Orb.Kernel.streamOpenTailCapStep, Orb.Kernel.streamBoundedCommitStep]
  bv_decide

theorem eq_stream_commit (a0 a1 a2 a3 a4 a5 a6 a7 a8 : UInt64) :
    probe_orb_stream_commit_step a0 a1 a2 a3 a4 a5 a6 a7 a8 =
    Orb.Kernel.streamCommitStep a0.toUInt8 a1.toUInt8 a2.toUInt32 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt32 a7.toUInt32 a8.toUInt32 := by
  unfold probe_orb_stream_commit_step blSatAdd32
  have hpos : blLe64 (a7.toUInt32.toUInt64 + (1 : UInt32).toUInt64) 0xFFFFFFFF =
      if a7.toUInt32.toUInt64 + (1 : UInt32).toUInt64 ≤ 0xFFFFFFFF then 1 else 0 := by
    simp only [blLe64, blLt64]; bv_decide
  simp only [hpos, bne, blNz32, blEz32, blEq8, blEz8, blEq32, blLt32, blLe32, blSel32,
    Orb.Kernel.streamCommitStep, Orb.Kernel.streamNextFenceKind, Orb.Kernel.streamNextFenceCount, Orb.Kernel.satAdd32]
  bv_decide

theorem eq_provider_pool (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) :
    probe_orb_provider_pool_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 =
    Orb.Kernel.providerPoolStep a0.toUInt8 a1.toUInt32 a2.toUInt32 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt32 a7.toUInt32 a8 a9 := by
  simp only [bne, blNz32, blEz32, blEq8, blEq32, blLt32, blLe32, blLt64, blSel32,
    probe_orb_provider_pool_step, Orb.Kernel.providerPoolStep]
  bv_decide

theorem eq_node_gc (a0 a1 a2 a3 a4 a5 a6 : UInt64) :
    probe_orb_node_gc_step a0 a1 a2 a3 a4 a5 a6 = Orb.Kernel.nodeGcStep a0 a1 a2 a3 a4 a5 a6 := by
  unfold probe_orb_node_gc_step
  have hrem1 : blNz64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) =
      if (blLe64 (a1 - a0) a3 = 0) && (a1 - a0 - a3 ≠ 0) then 1 else 0 := by
    simp only [blNz64, blLe64, blLt64, blSel64]; bv_decide
  have hrem2 : blNz64 (blSel64 (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5) 0
      (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5)) =
      if (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5 = 0) &&
        (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5 ≠ 0) then 1 else 0 := by
    simp only [blNz64, blLe64, blLt64, blSel64]; bv_decide
  have hrem3 : blNz64 (blSel64
      (blLe64 (blSel64 (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5) 0
        (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5)) a4) 0
      (blSel64 (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5) 0
        (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5) - a4)) =
      if (blLe64 (blSel64 (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5) 0
          (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5)) a4 = 0) &&
        (blSel64 (blLe64 (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3)) a5) 0
          (blSel64 (blLe64 (a1 - a0) a3) 0 (a1 - a0 - a3) - a5) - a4 ≠ 0) then 1 else 0 := by
    simp only [blNz64, blLe64, blLt64, blSel64]; bv_decide
  simp only [hrem1, hrem2, hrem3, bne, blLt64, blLe64, blNz64, blSel32, blSel64, Orb.Kernel.nodeGcStep]
  bv_decide

theorem eq_http_rate_reason (st quotaHint authHint : UInt32)
    (hq : quotaHint = 0 ∨ quotaHint = 1) (ha : authHint = 0 ∨ authHint = 1) :
    probe_orb_http_rate_reason st quotaHint authHint =
    let r429 : UInt32 := if quotaHint = 1 then 2 else 1
    let is401_403 := st = 401 || (st = 403 && authHint = 1)
    let is529_503 := st = 529 || st = 503
    let is5xx := 500 ≤ st && st < 600
    if st = 429 then r429
    else if st = 402 then 2
    else if is401_403 then 3
    else if is529_503 then 4
    else if is5xx then 5
    else 0 := by
  cases hq <;> cases ha <;>
    simp only [*, probe_orb_http_rate_reason, blEq32, blEz32, blNz32, blLe32, blLt32, blSel32] <;>
    bv_decide

theorem eq_http_rate_limit (a0 a1 a2 a3 a4 : UInt64) :
    probe_orb_http_rate_limit_classify_step a0 a1 a2 a3 a4 =
    Orb.Kernel.httpRateLimitClassifyStep a0.toUInt32 a1.toUInt8 a2.toUInt8 a3 a4 := by
  unfold probe_orb_http_rate_limit_classify_step
  have hcap : blEz64 a4 = if a4 = 0 then 1 else 0 := by simp only [blEz64, blNz64]; bv_decide
  have hraw : blEz64 a3 = if a3 = 0 then 1 else 0 := by simp only [blEz64, blNz64]; bv_decide
  have hquota : blEq8 a1.toUInt8 1 = if a1.toUInt8 = 1 then 1 else 0 := by
    simp only [blEq8, blEz32, blNz32]; bv_decide
  have hauth : blEq8 a2.toUInt8 1 = if a2.toUInt8 = 1 then 1 else 0 := by
    simp only [blEq8, blEz32, blNz32]; bv_decide
  have hq01 : (if a1.toUInt8 = 1 then (1 : UInt32) else 0) = 0 ∨ (if a1.toUInt8 = 1 then (1 : UInt32) else 0) = 1 := by
    by_cases h : a1.toUInt8 = 1 <;> simp [h]
  have ha01 : (if a2.toUInt8 = 1 then (1 : UInt32) else 0) = 0 ∨ (if a2.toUInt8 = 1 then (1 : UInt32) else 0) = 1 := by
    by_cases h : a2.toUInt8 = 1 <;> simp [h]
  rw [hquota, hauth, eq_http_rate_reason _ _ _ hq01 ha01]
  simp only [hcap, hraw, bne, blEq32, blEz32, blNz32, blLt64, blLe64, blSel32, blSel64,
    Orb.Kernel.httpRateLimitClassifyStep]
  bv_decide

theorem eq_effect_outbox (a0 a1 a2 a3 a4 a5 : UInt64) :
    probe_orb_effect_outbox_step a0 a1 a2 a3 a4 a5 =
    Orb.Kernel.effectOutboxStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4 a5 := by
  unfold probe_orb_effect_outbox_step
  have hphase : blLe8 a0.toUInt8 5 = if a0.toUInt8.toUInt32 ≤ (5 : UInt8).toUInt32 then 1 else 0 := by
    simp only [blLe8, blLe32, blLt32]; bv_decide
  have hop : blLe8 a2.toUInt8 5 = if a2.toUInt8.toUInt32 ≤ (5 : UInt8).toUInt32 then 1 else 0 := by
    simp only [blLe8, blLe32, blLt32]; bv_decide
  have heq : blEq64 a4 a5 = if a4 = a5 then 1 else 0 := by
    simp only [blEq64, blEz64, blNz64]; bv_decide
  simp only [hphase, hop, heq, bne, blNz32, blEz32, blEq8, blEz8, blEq32, blNz64, blSel32,
    Orb.Kernel.effectOutboxStep]
  bv_decide

theorem eq_fleet_place_argmin_core (aq bq as_ bs_ ad bd idLt : UInt32) (a9 a12 : UInt32) (lhs rhs a13 a14 : UInt64)
    (haq : aq = 0 ∨ aq = 1) (hbq : bq = 0 ∨ bq = 1)
    (has : as_ = 0 ∨ as_ = 1) (hbs : bs_ = 0 ∨ bs_ = 1)
    (had : ad = 0 ∨ ad = 1) (hbd : bd = 0 ∨ bd = 1)
    (hid : idLt = 0 ∨ idLt = 1) :
    (let diskCmp := blSel32 (blLt32 a12 a9) 1 (blSel32 (blLt32 a9 a12) 0 idLt)
     let memCmp := blSel32 (blLt64 a14 a13) 1 (blSel32 (blLt64 a13 a14) 0 diskCmp)
     let softCmp := blSel32 (blLt32 ad bd) 1 (blSel32 (blLt32 bd ad) 0 memCmp)
     let loadCmp := blSel32 (blLt64 lhs rhs) 1 (blSel32 (blLt64 rhs lhs) 0 softCmp)
     let specCmp := blSel32 (blLt32 as_ bs_) 1 (blSel32 (blLt32 bs_ as_) 0 loadCmp)
     (blSel32 (blLt32 aq bq) 1 (blSel32 (blLt32 bq aq) 0 specCmp)).toUInt64) =
    (if aq < bq then (1 : UInt8)
     else if bq < aq then 0
     else if as_ < bs_ then 1
     else if bs_ < as_ then 0
     else if lhs < rhs then 1
     else if rhs < lhs then 0
     else if ad < bd then 1
     else if bd < ad then 0
     else if a14 < a13 then 1
     else if a13 < a14 then 0
     else if a12 < a9 then 1
     else if a9 < a12 then 0
     else if idLt = 1 then 1
     else 0).toUInt64 := by
  have hml1 : blLt64 a14 a13 = if a14 < a13 then 1 else 0 := by simp only [blLt64]; bv_decide
  have hml2 : blLt64 a13 a14 = if a13 < a14 then 1 else 0 := by simp only [blLt64]; bv_decide
  have hll1 : blLt64 lhs rhs = if lhs < rhs then 1 else 0 := by simp only [blLt64]; bv_decide
  have hll2 : blLt64 rhs lhs = if rhs < lhs then 1 else 0 := by simp only [blLt64]; bv_decide
  have hdl1 : blLt32 a12 a9 = if a12 < a9 then 1 else 0 := by simp only [blLt32]; bv_decide
  have hdl2 : blLt32 a9 a12 = if a9 < a12 then 1 else 0 := by simp only [blLt32]; bv_decide
  simp only [hml1, hml2, hll1, hll2, hdl1, hdl2]
  rcases haq with rfl | rfl <;> rcases hbq with rfl | rfl <;>
  rcases has with rfl | rfl <;> rcases hbs with rfl | rfl <;>
  rcases had with rfl | rfl <;> rcases hbd with rfl | rfl <;>
  rcases hid with rfl | rfl <;>
  by_cases hl1 : lhs < rhs <;> by_cases hl2 : rhs < lhs <;>
  by_cases hm1 : a14 < a13 <;> by_cases hm2 : a13 < a14 <;>
  by_cases hd1 : a12 < a9 <;> by_cases hd2 : a9 < a12 <;>
  simp only [*, blLt32, blSel32] <;> decide

theorem eq_fleet_place_argmin (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 : UInt64) :
    probe_orb_fleet_place_argmin_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 =
    (Orb.Kernel.fleetPlaceArgminStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt8
      a7.toUInt32 a8.toUInt32 a9.toUInt32 a10.toUInt32 a11.toUInt32 a12.toUInt32 a13 a14).toUInt64 := by
  unfold probe_orb_fleet_place_argmin_step Orb.Kernel.fleetPlaceArgminStep
  have hnz8 : ∀ (x : UInt8), (blEz8 x ^^^ 1) = if x == 0 then 0 else 1 := by
    intro x; simp only [blEz8, blEz32, blNz32]; bv_decide
  have h01 : ∀ (x : UInt8), (if x == 0 then (0 : UInt32) else 1) = 0 ∨ (if x == 0 then (0 : UInt32) else 1) = 1 := by
    intro x; by_cases h : x == 0 <;> simp [h]
  have hid : blEq8 a6.toUInt8 1 = if a6.toUInt8 == 1 then 1 else 0 := by
    simp only [blEq8, blEz32, blNz32]; bv_decide
  have hid01 : (if a6.toUInt8 == 1 then (1 : UInt32) else 0) = 0 ∨ (if a6.toUInt8 == 1 then (1 : UInt32) else 0) = 1 := by
    by_cases h : a6.toUInt8 == 1 <;> simp [h]
  have hac : blSel64 (blEz32 a8.toUInt32) 1 a8.toUInt32.toUInt64 = if a8.toUInt32 == 0 then 1 else a8.toUInt32.toUInt64 := by
    simp only [blSel64, blEz32, blNz32]; bv_decide
  have hbc : blSel64 (blEz32 a11.toUInt32) 1 a11.toUInt32.toUInt64 = if a11.toUInt32 == 0 then 1 else a11.toUInt32.toUInt64 := by
    simp only [blSel64, blEz32, blNz32]; bv_decide
  have hu8lt : ∀ (x y : UInt8), ((if x == 0 then (0 : UInt32) else 1) < (if y == 0 then 0 else 1)) ↔
      ((if x == 0 then (0 : UInt8) else 1) < (if y == 0 then 0 else 1)) := by
    intro x y; by_cases hx : x == 0 <;> by_cases hy : y == 0 <;> simp [hx, hy]
  simp only [hnz8, hid, hac, hbc]
  rw [eq_fleet_place_argmin_core _ _ _ _ _ _ _ _ _ _ _ _ _
    (h01 _) (h01 _) (h01 _) (h01 _) (h01 _) (h01 _) hid01]
  simp only [hu8lt]
  by_cases h6 : a6.toUInt8 == 1 <;> simp [h6]

theorem eq_proxy_exhaustion (a0 a1 a2 a3 a4 a5 : UInt64) :
    probe_orb_proxy_exhaustion_step a0 a1 a2 a3 a4 a5 =
    (Orb.Kernel.proxyExhaustionStep a0.toUInt32 a1.toUInt32 a2.toUInt32 a3.toUInt32 a4.toUInt32 a5.toUInt8).toUInt64 := by
  simp only [bne, blNz32, blEz32, blEq8, blNz64, blEz64, blEq64, blSel32,
    probe_orb_proxy_exhaustion_step, Orb.Kernel.proxyExhaustionStep]
  bv_decide
theorem eq_sidebar_drag_step (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 : UInt64) :
    probe_orb_sidebar_drag_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 =
    Orb.Kernel.sidebarDragStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4.toUInt8 a5.toUInt32 a6.toUInt32 a7.toUInt32 a8.toUInt32 a9.toUInt32 a10.toUInt32 a11.toUInt32 := by
  simp only [bne, blNz32, blEz32, blEq8, blEq32, blLt32, blLe32, blLt8, blLe8, blSel32,
    probe_orb_sidebar_drag_step, Orb.Kernel.sidebarDragStep,
    Orb.Kernel.sidebarScrollStepPx, Orb.Kernel.sidebarScrollDirBits]
  bv_decide

theorem eq_rtt_ewma (a0 a1 a2 : UInt64) :
    probe_orb_rtt_ewma_step a0 a1 a2 =
    Orb.Kernel.rttEwmaStep a0.toUInt32 a1.toUInt32 a2.toUInt32 := by
  simp only [bne, blNz64, blEz64, blLt64, blLe64, blSel64,
    probe_orb_rtt_ewma_step, Orb.Kernel.rttEwmaStep]
  bv_decide

theorem eq_client_link_budget (a0 a1 a2 a3 a4 : UInt64) :
    probe_orb_client_link_budget_step a0 a1 a2 a3 a4 =
    Orb.Kernel.clientLinkBudgetStep a0.toUInt32 a1.toUInt32 a2.toUInt32 a3.toUInt8 a4.toUInt32 := by
  simp only [bne, blNz64, blEz64, blLt64, blLe64, blSel64,
    probe_orb_client_link_budget_step, Orb.Kernel.clientLinkBudgetStep]
  bv_decide

theorem eq_multiuser_rbac (a0 a1 a2 a3 a4 a5 a6 : UInt64) :
    probe_orb_multiuser_rbac_step a0 a1 a2 a3 a4 a5 a6 =
    (Orb.Kernel.multiuserRbacStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4.toUInt8 a5.toUInt8 a6.toUInt8).toUInt64 := by
  simp only [bne, blNz64, blEz64, blEq64, blLt64, blSel64,
    probe_orb_multiuser_rbac_step, Orb.Kernel.multiuserRbacStep]
  bv_decide

theorem eq_placement_role_admit (a0 a1 a2 a3 : UInt64) :
    probe_orb_placement_role_admit a0 a1 a2 a3 =
    (Orb.Kernel.placementRoleAdmit a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8).toUInt64 := by
  simp only [blNz64, blEz64, blEq64, blLt64, blLe64, blSel64,
    probe_orb_placement_role_admit, Orb.Kernel.placementRoleAdmit]
  bv_decide

theorem eq_user_spend_cap (a0 a1 a2 a3 a4 a5 a6 : UInt64) :
    probe_orb_user_spend_cap_step a0 a1 a2 a3 a4 a5 a6 =
    Orb.Kernel.userSpendCapStep a0.toUInt8 a1.toUInt32 a2.toUInt32 a3.toUInt8 a4.toUInt32 a5.toUInt32 a6.toUInt32 := by
  simp only [bne, blNz64, blLt64, blLe64, blSel64,
    probe_orb_user_spend_cap_step, Orb.Kernel.userSpendCapStep]
  bv_decide

theorem eq_privd_user_exec (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 : UInt64) :
    probe_orb_privd_user_exec_step a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 =
    (Orb.Kernel.privdUserExecStep a0.toUInt8 a1.toUInt8 a2.toUInt8 a3.toUInt8 a4.toUInt8
      a5.toUInt32 a6.toUInt32 a7.toUInt8 a8.toUInt8 a9.toUInt8).toUInt64 := by
  simp only [bne, blNz64, blEz64, blEq64, blLt64, blLe64, blSel64,
    probe_orb_privd_user_exec_step, Orb.Kernel.privdUserExecStep]
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
