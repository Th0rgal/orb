import OrbNode.Runner

open OrbNode OrbNode.Runner OrbNode.Store

/-- Focused replay of SelfTest's post-spawn ledger failure, with the same
    command, injected error, observation delay and dead-process predicate. -/
def main : IO UInt32 := do
  let nonce ← OrbBin.PosixExt.newUuidV4
  let root := s!"/tmp/orb-node-cleanup-{nonce}"
  IO.FS.createDirAll root
  try
    let .ok ledger ← openLedger root | throw (IO.userError "openLedger failed")
    let jid := "ffffffff-ffff-4fff-8fff-fffffffffff0"
    let record : JobRecord := {
      jobId := jid, missionId := "11111111-1111-4111-8111-111111111111"
      payloadJson := "{\"kind\":\"raw_command\",\"command\":\"sleep 30\",\"long_running\":true}"
      state := .queued, createdAt := "2026-11-07T00:07:00Z"
      operationId := jid, nodeBootEpoch := ledger.nodeBootEpoch, phaseCode := 1
    }
    let rt : NodeRuntime := {
      cfg := { nodeId := "test-node", token := "fixture-only", workDir := root }
      ledger := { ledger with jobs := ledger.jobs.insert jid record, order := ledger.order.push jid }
    }
    let prep : PreparedJobSpec := {
      jid := jid, prog := "/bin/sleep", args := #["30"], envKv := #[], cwd := root
      logPath := s!"{root}/fail-spawn.log", artifacts := #[], timeoutSecs? := none
      forced := false, sideLane := false, coordLane := false
      isolatedCheckout := none, systemdScope? := none, scratchDir? := none
      machineName? := none, workspaceId := ""
    }
    let after ← commitPreparedJob rt jid (.ok prep) none (some "simulated_sqlite_lock")
    let mode := (← IO.getEnv "ORB_TEST_READY_MODE").getD ""
    if #["fail", "eof", "timeout", "eintr"].contains mode then
      let some failed := after.ledger.jobs.get? jid | throw (IO.userError "missing setup failure")
      IO.println s!"setup-failure: mode={mode} pid={failed.pid} state={repr failed.state} error={repr failed.error?} live={after.liveProcs.size}"
      return if failed.state == .failed && failed.pid == 0 && failed.error?.isSome &&
        after.liveProcs.isEmpty then 0 else 1
    IO.sleep 60
    let some fl := after.ledger.jobs.get? jid | throw (IO.userError "missing failed record")
    let poll ← OrbNode.Posix.pollPid fl.pid
    let sample ← sampleProcLiveness fl.pid
    let stat ← (IO.FS.readFile s!"/proc/{fl.pid}/stat").toBaseIO
    let statText := match stat with | .ok s => s | .error e => toString e
    IO.println s!"cleanup: pid={fl.pid} ticks={fl.startTicks} phase={fl.procPhase} poll={poll} dead={sample.procMissing}/{sample.isZombie} actualTicks={sample.actualTicks} boot={sample.bootId} state={repr fl.state} error={repr fl.error?} stat={statText}"
    let ok := fl.state == .failed &&
      fl.error?.any (·.startsWith "post_spawn_ledger_update_failed:") &&
      (sample.procMissing == 1 || sample.isZombie == 1)
    -- Cleanup follows the observation and never changes its result.
    if sample.procMissing == 0 && sample.isZombie == 0 then
      discard <| terminateVerifiedPgrp 1 fl.pid sample.actualTicks none sample.bootId
    discard <| OrbNode.Posix.pollPid fl.pid
    return if ok then 0 else 1
  finally
    IO.FS.removeDirAll root
