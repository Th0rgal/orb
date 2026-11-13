/-
  OrbClient.SelfTest: End-to-End Verification Suite for Wave 3 `OrbClient`.
-/
import OrbClient.Spec
import OrbClient.MutantSuite
import OrbClient.Reducers

namespace OrbClient.SelfTest

open OrbClient.Spec
open OrbClient.MutantSuite
open OrbClient.Reducers

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw (IO.userError s!"FAIL: {label}")

def runTests : IO UInt32 := do
  let passedRef ← IO.mkRef (0 : Nat)
  let check (label : String) (cond : Bool) : IO Unit := do
    assertTrue label cond
    passedRef.modify (· + 1)

  -- 1. Sync cursor gate
  check "sync cursor admits strictly newer seq" (verifyClientSyncCursor 2 2 10 11 1 1 == 1)
  check "sync cursor admits higher epoch with seq 0" (verifyClientSyncCursor 2 3 99 0 1 1 == 1)
  check "sync cursor rejects duplicate seq" (verifyClientSyncCursor 2 2 10 10 1 1 == 0)
  check "sync cursor rejects lower epoch" (verifyClientSyncCursor 3 2 0 50 1 1 == 0)
  check "sync cursor rejects unauthenticated frame" (verifyClientSyncCursor 2 2 10 11 1 0 == 0)

  -- 2. Transcript replay invariance
  let liveOut := projectTranscript { counts := (20, 5), metaFlags := (1, 0) }
  let replayOut := projectTranscript { counts := (20, 5), metaFlags := (1, 1) }
  check "transcript live == replay" (liveOut == replayOut && liveOut.visibleEntries == 25)
  check "transcript stability predicate holds"
    (stableTranscriptProj { counts := (20, 5), metaFlags := (1, 0) } liveOut)

  -- 3. Bundle budget gate
  check "bundle budget admits clean 950KB bundle" (verifyBundleBudget 972800 1177600 1 0 == 1)
  check "bundle budget rejects eager heavy vendor" (verifyBundleBudget 500000 1177600 1 1 == 0)
  check "bundle budget rejects over-budget bundle" (verifyBundleBudget 1200000 1177600 1 0 == 0)
  check "bundle budget rejects missing single appEntry" (verifyBundleBudget 500000 1177600 0 0 == 0)

  -- 4. Patch parser roundtrip (including verified schema preservation)
  let samplePayload := "{\"op\":\"patch\",\"seq\":42}".toUTF8
  match encodeOrbClientPatch? 7 samplePayload with
  | none => throw (IO.userError "encodeOrbClientPatch? returned none")
  | some frame =>
    check "patch frame roundtrip preserves schema and payload"
      (parseOrbClientPatch frame == some { schema := 7, payload := samplePayload })
  check "patch parser rejects bad magic"
    ((parseOrbClientPatch (ByteArray.mk #[0x4F, 0x52, 0x42, 0x00, 0x00, 0x01, 0x00, 0x01, 0x41])).isNone)
  check "patch parser rejects trailing bytes"
    ((parseOrbClientPatch (ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x01, 0x41, 0x42])).isNone)

  -- 5. Reducer state progression
  let s0 : SyncCursorState := {}
  let (ok1, s1) := stepSyncCursor s0 1 1 1 1
  let (ok2, s2) := stepSyncCursor s1 1 1 1 1
  let (ok3, s3) := stepSyncCursor s2 1 2 1 1
  check "stepSyncCursor advances monotonically and drops duplicate"
    (ok1 && !ok2 && ok3 && s3.epoch == 1 && s3.seq == 2)

  -- 6. DesktopState integration with OrbClient.Reducers.stepDesktopSyncCursor
  let ds0 := OrbDesktop.DesktopState.forScreen .missionTranscript true 120
  let (dok1, ds1) := stepDesktopSyncCursor ds0 1 43 1 1
  let (dok2, ds2) := stepDesktopSyncCursor ds1 1 43 1 1
  check "stepDesktopSyncCursor advances DesktopState.syncCursor and drops duplicate"
    (dok1 && !dok2 && ds2.syncCursor.epoch == 1 && ds2.syncCursor.seq == 43)

  let passed ← passedRef.get
  IO.println s!"OrbClient self-test: {passed}/{passed} assertions PASSED"
  return 0

end OrbClient.SelfTest

def main : IO UInt32 :=
  OrbClient.SelfTest.runTests
