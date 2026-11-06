import OrbClient.Spec
import OrbClient.Reducers

open OrbClient.Spec
open OrbClient.Reducers

-- Generates `shared/orb-spec/fixtures/client-core.json`: every expected value is
-- computed directly by the verified `OrbClient` Lean definitions (`lean/OrbClient`).

private def bytesToHex (bs : ByteArray) : String := Id.run do
  let hexDigits : Array Char := #['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f']
  let mut out := ""
  for i in [0 : bs.size] do
    let b := bs.get! i
    out := out.push hexDigits[(b >>> 4).toNat]!
    out := out.push hexDigits[(b &&& 0x0F).toNat]!
  return out

private def syncCursorCases : List (String × UInt64 × UInt64 × UInt64 × UInt64 × UInt8 × UInt8) := [
  ("strictly_newer_seq", 2, 2, 10, 11, 1, 1),
  ("epoch_bump_zero_seq", 2, 3, 99, 0, 1, 1),
  ("duplicate_seq_rejected", 2, 2, 10, 10, 1, 1),
  ("stale_seq_rejected", 2, 2, 10, 9, 1, 1),
  ("lower_epoch_rejected", 3, 2, 0, 50, 1, 1),
  ("zero_incoming_epoch_rejected", 0, 0, 0, 1, 1, 1),
  ("invalid_frame_rejected", 2, 2, 10, 11, 0, 1),
  ("unauthenticated_rejected", 2, 2, 10, 11, 1, 0),
  ("initial_cursor_first_frame", 0, 1, 0, 0, 1, 1)
]

private def transcriptProjCases : List (String × UInt32 × UInt32 × UInt8 × UInt8) := [
  ("live_idle", 0, 0, 0, 0),
  ("replay_idle", 0, 0, 0, 1),
  ("live_thinking", 20, 5, 1, 0),
  ("replay_thinking", 20, 5, 1, 1),
  ("live_settled_tools", 48, 12, 0, 0),
  ("replay_settled_tools", 48, 12, 0, 1)
]

private def bundleBudgetCases : List (String × UInt64 × UInt64 × UInt8 × UInt8) := [
  ("clean_950kb_admitted", 972800, 1177600, 1, 0),
  ("exact_budget_boundary_admitted", 1177600, 1177600, 1, 0),
  ("over_budget_by_1b_rejected", 1177601, 1177600, 1, 0),
  ("eager_heavy_vendor_rejected", 500000, 1177600, 1, 1),
  ("missing_single_app_entry_rejected", 500000, 1177600, 0, 0),
  ("zero_budget_rejected", 0, 0, 1, 0)
]

private def patchDecodeCases : List (String × ByteArray) := [
  ("valid_json_patch_s1", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x02, 0x7B, 0x7D]),
  ("valid_max_schema_255", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0xFF, 0x00, 0x03, 0x6F, 0x72, 0x62]),
  ("bad_magic_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x58, 0x00, 0x01, 0x00, 0x02, 0x7B, 0x7D]),
  ("schema_zero_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x00, 0x00, 0x01, 0x41]),
  ("schema_256_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x01, 0x00, 0x00, 0x01, 0x41]),
  ("zero_len_payload_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x00]),
  ("truncated_frame_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x04, 0x41, 0x42]),
  ("trailing_bytes_rejected", ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, 0x00, 0x01, 0x00, 0x01, 0x41, 0x42])
]

def main : IO Unit := do
  let mut rows : Array String := #[]
  for (name, le, ie, ls, isq, fv, ao) in syncCursorCases do
    let ok := verifyClientSyncCursor le ie ls isq fv ao == 1
    let (stepped, nextSt) := stepSyncCursor { epoch := le, seq := ls } ie isq fv ao
    rows := rows.push
      s!"    \{\"op\": \"syncCursor\", \"name\": \"{name}\", \"localEpoch\": {le}, \"incomingEpoch\": {ie}, \"localSeq\": {ls}, \"incomingSeq\": {isq}, \"frameValid\": {fv == 1}, \"authOk\": {ao == 1}, \"expectedAdmitted\": {ok}, \"expectedStepped\": {stepped}, \"expectedEpoch\": {nextSt.epoch}, \"expectedSeq\": {nextSt.seq}}"
  for (name, userTurns, toolTurns, thinkingFlag, replayFlag) in transcriptProjCases do
    let out := projectTranscript { counts := (userTurns, toolTurns), metaFlags := (thinkingFlag, replayFlag) }
    rows := rows.push
      s!"    \{\"op\": \"projectTranscript\", \"name\": \"{name}\", \"userTurns\": {userTurns}, \"toolTurns\": {toolTurns}, \"thinkingOpen\": {thinkingFlag == 1}, \"isReplay\": {replayFlag == 1}, \"expectedVisibleEntries\": {out.visibleEntries}, \"expectedThinkingActive\": {out.thinkingActive == 1}}"
  for (name, eagerB, budgetB, singleEntry, heavyVendor) in bundleBudgetCases do
    let ok := verifyBundleBudget eagerB budgetB singleEntry heavyVendor == 1
    rows := rows.push
      s!"    \{\"op\": \"bundleBudget\", \"name\": \"{name}\", \"eagerBytes\": {eagerB}, \"budgetBytes\": {budgetB}, \"singleAppEntry\": {singleEntry == 1}, \"hasEagerHeavyVendor\": {heavyVendor == 1}, \"expectedAdmitted\": {ok}}"
  for (name, raw) in patchDecodeCases do
    let hexIn := bytesToHex raw
    match parseOrbClientPatch raw with
    | some pay =>
      rows := rows.push
        s!"    \{\"op\": \"parsePatch\", \"name\": \"{name}\", \"rawHex\": \"{hexIn}\", \"expectedPayloadHex\": \"{bytesToHex pay}\"}"
    | none =>
      rows := rows.push
        s!"    \{\"op\": \"parsePatch\", \"name\": \"{name}\", \"rawHex\": \"{hexIn}\", \"expectedPayloadHex\": null}"
  IO.println "{"
  IO.println "  \"description\": \"Generated from lean/OrbClient by scripts/gen_client_core_fixtures.lean; do not edit. Verified client sync-cursor epoch/sequence gates, replay-invariant transcript projection, startup bundle budget conservation, and bounded ORBP binary patch framing.\","
  IO.println "  \"cases\": ["
  IO.println (",\n".intercalate rows.toList)
  IO.println "  ]"
  IO.println "}"
