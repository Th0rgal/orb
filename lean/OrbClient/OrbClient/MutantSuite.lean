/-
  OrbClient.MutantSuite: 4 Realistic Semantic Mutants Killed by Proof (`0 import Lean`, `0 sorryAx`).
-/
import OrbClient.Spec

namespace OrbClient.MutantSuite

open OrbClient.Spec

/-- Mutant 01: Accepts duplicate sequence (`localSeq <= incomingSeq`) on same epoch,
    re-applying already committed SSE/WS delta frames. -/
def m01_syncCursorAcceptsDuplicateSeq
    (localEpoch : UInt64)
    (incomingEpoch : UInt64)
    (localSeq : UInt64)
    (incomingSeq : UInt64)
    (frameValid : UInt8)
    (authOk : UInt8) : UInt8 :=
  if frameValid == 1 &&
     authOk == 1 &&
     incomingEpoch > 0 &&
     (localEpoch < incomingEpoch || (localEpoch == incomingEpoch && localSeq ≤ incomingSeq)) then 1
  else 0

theorem kill_m01_sync_cursor_duplicate_seq :
    m01_syncCursorAcceptsDuplicateSeq 3 3 42 42 1 1 ≠
      verifyClientSyncCursor 3 3 42 42 1 1 := by
  decide

/-- Mutant 02: Allows replay mode (`isReplayFromLog == 1`) to synthesize an extra visible
    entry, breaking live-vs-replay transcript equivalence. -/
def m02_replayInflatesTranscript (inp : TranscriptProjInput) : TranscriptProjOut :=
  let bonus : UInt32 := if inp.metaFlags.2 == 1 then 1 else 0
  let total := inp.counts.1 + inp.counts.2 + bonus
  let thinking : UInt8 := if inp.metaFlags.1 == 1 then 1 else 0
  { visibleEntries := total, thinkingActive := thinking }

theorem kill_m02_replay_inflates_transcript :
    m02_replayInflatesTranscript { counts := (10, 2), metaFlags := (0, 1) } ≠
      projectTranscript { counts := (10, 2), metaFlags := (0, 1) } := by
  decide

/-- Mutant 03: Subtracts `hasEagerHeavyVendor` instead of requiring `hasEagerHeavyVendor == 0`,
    admitting bundles with eager heavy vendors (`katex`/`mermaid`/`pdfjs-dist`/`cytoscape`). -/
def m03_bundleIgnoresEagerVendor
    (eagerBytes : UInt64)
    (budgetBytes : UInt64)
    (singleAppEntry : UInt8)
    (hasEagerHeavyVendor : UInt8) : UInt8 :=
  if singleAppEntry == 1 &&
     hasEagerHeavyVendor ≤ 1 &&
     budgetBytes > 0 &&
     eagerBytes ≤ budgetBytes then 1
  else 0

theorem kill_m03_bundle_ignores_eager_vendor :
    m03_bundleIgnoresEagerVendor 900000 1177600 1 1 ≠
      verifyBundleBudget 900000 1177600 1 1 := by
  decide

/-- Mutant 04: Drops the wire `schema` byte and hardcodes `schema := 1` on decode,
    allowing schema-2 frames to masquerade as schema-1 frames. -/
def m04_patchParserHardcodesSchema1 (raw : ByteArray) : Option OrbClientPatchFrame :=
  match parseOrbClientPatch raw with
  | some f => some { f with schema := 1 }
  | none => none

theorem kill_m04_patch_parser_hardcodes_schema1 :
    m04_patchParserHardcodesSchema1
        (ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x02, 0x00, 0x02, 0x7B, 0x7D]) ≠
      parseOrbClientPatch
        (ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x02, 0x00, 0x02, 0x7B, 0x7D]) := by
  decide

end OrbClient.MutantSuite
