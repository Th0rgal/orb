import OrbCore.TurnOutcomeTests
open OrbCore.Store OrbCore.R7Core OrbCore.MemoryAndCloud OrbBin.Sqlite OrbBin.PosixExt
def main (args : List String) : IO Unit := do
  let root := s!"/tmp/r24-focused-{← newUuidV4}"
  IO.FS.createDirAll s!"{root}/.sandboxed-sh"
  try
    let .ok store ← openCoreStore s!"{root}/.sandboxed-sh" | throw (IO.userError "open failed")
    try
      let .ok _ ← execParamQuery store.missionsDb
          "INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,created_at,updated_at) VALUES('m-tools','test','active','claudecode','','','managed','[]','t0','t0');" #[]
        | throw (IO.userError "fixture failed")
      let claims : McpSessionClaims := { sessionId := "turn-outcome", missionId := "m-tools", role := "coordinator", expiresAt := 4100000000 }
      if args == ["invalid"] then
        OrbCore.TurnOutcomeTests.r24_invalid_send_settles store root claims
        return
      if args == ["note-failure"] then
        OrbCore.TurnOutcomeTests.r24_note_write_failure_is_not_success store root claims
        return
      OrbCore.TurnOutcomeTests.r24_concurrent_same_key_mutates_once store root claims
      OrbCore.TurnOutcomeTests.r24_receipt_insert_failure_blocks_mutation store root claims
      OrbCore.TurnOutcomeTests.r24_same_key_retry_returns_stored_receipt store root claims
      OrbCore.TurnOutcomeTests.r24_invalid_send_settles store root claims
      OrbCore.TurnOutcomeTests.r24_note_write_failure_is_not_success store root claims
      OrbCore.TurnOutcomeTests.r24_settlement_write_failure store root claims
      OrbCore.TurnOutcomeTests.r24_exception_and_restart store claims
      OrbCore.TurnOutcomeTests.r24_failed_remote_cancel_survives_ledger_rewrite store root claims
      OrbCore.TurnOutcomeTests.r24_cancel_write_failure store root claims
      let localReply ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "cancel_mission"
        (.obj #[("mission_id", .str "m-tools"), ("idempotency_key", .str "r24-local-cancel")]) 4000000000
      OrbCore.TurnOutcomeTests.r24_cancel_without_remote_job_is_success
        (((OrbBin.Json.parse localReply).toOption.getD .null).fieldOrNull "result")
      IO.println "R24 focused SQLite/dispatcher tests passed"
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root
