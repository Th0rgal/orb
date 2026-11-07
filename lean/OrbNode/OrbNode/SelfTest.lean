/-
  OrbNode.SelfTest: End-to-End Parity Verification Suite for Wave 2 `sandboxed-node` (`OrbNode`).
-/
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Spec
import OrbNode.MutantSuite
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store
import OrbNode.Dial
import OrbNode.LeanBuild
import OrbNode.FileBrowser
import OrbNode.Transfer
import OrbNode.Runner
import OrbNode.Server
import OrbNode.Main

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.Spec
open OrbNode.MutantSuite
open OrbNode.Lease
open OrbNode.Store
open OrbNode.LeanBuild
open OrbNode.FileBrowser
open OrbNode.Transfer
open OrbNode.Runner
open OrbNode.Server
open OrbNode.Main

namespace OrbNode.SelfTest

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw (IO.userError s!"FAIL: {label}")

/-- Regression check for `SM-20` anchored child-tool `SIGINT` admission (`verifyChildToolSignalAdmit`,
    `sigintAnchoredChildTool`, and `sigintInflightChildTools`):
    (a) PID reuse between enumeration and signal (re-sampled `start_ticks` differs) is NOT signalled;
    (b) matching live `(pid, start_ticks, boot_id)` IS signalled;
    (c) missing `/proc`, zombie, `start_ticks == 0`, empty `boot_id`, or boot-id mismatch never signal. -/
private def runChildToolSigintAnchorRegressionTests (check : String → Bool → IO Unit) : IO Unit := do
  let rootSpawn ← IO.Process.spawn {
    cmd := "setsid"
    args := #["python3", "-c", "import subprocess, time\np = subprocess.Popen(['python3', '-c', 'import time\\ntime.sleep(30)'])\ntime.sleep(30)"]
    stdin := .null
    stdout := .null
    stderr := .null
  }
  let rootPid := rootSpawn.pid.toUInt64
  let mut rootSample ← sampleProcLiveness rootPid
  let mut anchors : Array ChildToolAnchor := #[]
  for _ in [0:40] do
    IO.sleep 25
    rootSample ← sampleProcLiveness rootPid
    if rootSample.procMissing == 0 && rootSample.actualTicks != 0 && !rootSample.bootId.isEmpty then
      anchors ← collectVerifiedInflightChildTools rootPid none rootSample.actualTicks rootSample.bootId
      if !anchors.isEmpty then break
  let some childAnchor := anchors[0]?
    | do
      discard <| terminateVerifiedPgrp 1 rootPid rootSample.actualTicks none rootSample.bootId
      discard <| rootSpawn.wait
      throw (IO.userError "failed to enumerate live child-tool anchor under test root")
  let childLive0 ← sampleProcLiveness childAnchor.pid.toUInt64
  let reusedSample : ProcLivenessSample := {
    procMissing := 0
    isZombie := 0
    actualPid := childAnchor.pid
    actualTicks := childAnchor.startTicks + 99
    bootId := childAnchor.bootId
  }
  let missingSample : ProcLivenessSample := {
    procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := ""
  }
  let zombieSample : ProcLivenessSample := {
    procMissing := 0, isZombie := 1, actualPid := childAnchor.pid,
    actualTicks := childAnchor.startTicks, bootId := childAnchor.bootId
  }
  let zeroTicksSample : ProcLivenessSample := {
    procMissing := 0, isZombie := 0, actualPid := childAnchor.pid,
    actualTicks := 0, bootId := childAnchor.bootId
  }
  let emptyBootSample : ProcLivenessSample := {
    procMissing := 0, isZombie := 0, actualPid := childAnchor.pid,
    actualTicks := childAnchor.startTicks, bootId := ""
  }
  let bootRotSample : ProcLivenessSample := {
    procMissing := 0, isZombie := 0, actualPid := childAnchor.pid,
    actualTicks := childAnchor.startTicks, bootId := "deadbeef-boot-id"
  }
  let zeroAnchor : ChildToolAnchor := { childAnchor with startTicks := 0 }
  let emptyBootAnchor : ChildToolAnchor := { childAnchor with bootId := "" }
  let pureChecks :=
    !verifyChildToolSignalAdmit childAnchor reusedSample childAnchor.bootId &&
    verifyChildToolSignalAdmit childAnchor childLive0 childAnchor.bootId &&
    !verifyChildToolSignalAdmit childAnchor missingSample childAnchor.bootId &&
    !verifyChildToolSignalAdmit childAnchor zombieSample childAnchor.bootId &&
    !verifyChildToolSignalAdmit childAnchor zeroTicksSample childAnchor.bootId &&
    !verifyChildToolSignalAdmit childAnchor emptyBootSample childAnchor.bootId &&
    !verifyChildToolSignalAdmit childAnchor bootRotSample childAnchor.bootId &&
    !verifyChildToolSignalAdmit zeroAnchor childLive0 childAnchor.bootId &&
    !verifyChildToolSignalAdmit emptyBootAnchor childLive0 childAnchor.bootId
  let sigReusedCount ← sigintInflightChildTools rootPid none rootSample.actualTicks rootSample.bootId
    (some fun p => pure {
      procMissing := 0, isZombie := 0, actualPid := p,
      actualTicks := childAnchor.startTicks + 77, bootId := childAnchor.bootId
    })
  let sigMissing ← sigintAnchoredChildTool childAnchor childAnchor.bootId (some missingSample)
  let sigZombie ← sigintAnchoredChildTool childAnchor childAnchor.bootId (some zombieSample)
  let sigZeroTicksSample ← sigintAnchoredChildTool childAnchor childAnchor.bootId (some zeroTicksSample)
  let sigEmptyBootSample ← sigintAnchoredChildTool childAnchor childAnchor.bootId (some emptyBootSample)
  let sigZeroAnchor ← sigintAnchoredChildTool zeroAnchor childAnchor.bootId (some childLive0)
  let sigEmptyBootAnchor ← sigintAnchoredChildTool emptyBootAnchor childAnchor.bootId (some childLive0)
  let childStillAlive ← sampleProcLiveness childAnchor.pid.toUInt64
  let sigMatchCount ← sigintInflightChildTools rootPid none rootSample.actualTicks rootSample.bootId
  let mut childExited := false
  for _ in [0:40] do
    IO.sleep 25
    let s ← sampleProcLiveness childAnchor.pid.toUInt64
    if s.procMissing == 1 || s.isZombie == 1 || s.actualTicks != childAnchor.startTicks then
      childExited := true
      break
  discard <| terminateVerifiedPgrp 1 rootPid rootSample.actualTicks none rootSample.bootId
  discard <| rootSpawn.wait
  check "SM-20 anchored child-tool SIGINT rejects PID-reused/missing/zombie/zero-ticks/empty-boot re-samples and signals matching live child"
    (pureChecks &&
     childLive0.procMissing == 0 &&
     childLive0.actualTicks == childAnchor.startTicks &&
     childAnchor.bootId == rootSample.bootId &&
     sigReusedCount == 0 &&
     !sigMissing && !sigZombie && !sigZeroTicksSample && !sigEmptyBootSample &&
     !sigZeroAnchor && !sigEmptyBootAnchor &&
     childStillAlive.procMissing == 0 &&
     childStillAlive.isZombie == 0 &&
     childStillAlive.actualTicks == childAnchor.startTicks &&
     sigMatchCount >= 1 &&
     childExited)

/-- Section 12: Round-2 regression checks (split UTF-8 log slicing, >150 KiB SQLite stdin,
    pure-Lean tar+zstd `-C` / newline filename safety, timeout shrinkDebt repayment, and
    saturated-queue cold archive-backed `lean_build` execution). -/
private def runRound2RegressionTests
    (check : String → Bool → IO Unit)
    (tmpRoot missionId submitLease : String)
    (nowEp : UInt64)
    (authHdrs : Array (String × String))
    (rt0 : NodeRuntime) : IO NodeRuntime := do
  let mut rt := rt0
  -- 12a. Multi-byte UTF-8 partial log boundary (`ab€\n`, 6 bytes, sliced with `max_bytes = 4`)
  let utf8Log := "ab€\n".toUTF8 -- [97, 98, 226, 130, 172, 10]
  let utf8S1 := sliceJobLogBytes utf8Log 0 4
  let utf8S2 := sliceJobLogBytes utf8Log utf8S1.nextOffset.toNat 4
  check "sliceJobLogBytes preserves split multi-byte UTF-8 across chunk polls without '?' corruption"
    (utf8S1.data == "ab" && utf8S1.nextOffset == 2 && utf8S2.data == "€\n" && utf8S2.nextOffset == 6)

  -- 12b. >150 KiB SQLite `jobs.db` stdin persistence (no Linux argv `E2BIG`)
  let bigStr := String.ofList (List.replicate 160000 'X')
  let bigRec : JobRecord := {
    jobId := "77777777-7777-4777-8777-777777777777"
    missionId := missionId
    payloadJson := renderCompact (.obj #[("kind", .str "raw_command"), ("blob", .str bigStr)])
    state := .queued
    createdAt := "2026-11-06T00:05:00Z"
  }
  let bigIns ← rt.ledger.insertQueued bigRec
  check "insertQueued persists >160 KiB SQL payload via stdin without E2BIG"
    (match bigIns with | .ok _ => true | .error _ => false)

  -- 12c. Pure-Lean `tar+zstd` pack/unpack with `-C` and newline in workspace filename
  let weirdWs := System.FilePath.mk tmpRoot / "weird-tar-ws"
  let weirdSub := weirdWs / "-C_dir"
  IO.FS.createDirAll weirdSub
  let weirdRel := "-C_dir/line1\nline2.txt"
  IO.FS.writeFile (weirdWs / "-C_dir" / "line1\nline2.txt") "tar-safe-bytes"
  let weirdSrcArea := System.FilePath.mk tmpRoot / ".transfers" / "88888888-8888-4888-8888-888888888888" / "source"
  let weirdDstArea := System.FilePath.mk tmpRoot / ".transfers" / "88888888-8888-4888-8888-888888888888" / "destination"
  let .ok weirdManifest ← operateTransfer weirdSrcArea (some weirdWs) (.obj #[("op", .str "snapshot")])
    | throw (IO.userError "weird tar snapshot failed")
  let .ok packedWeird ← packTransferArchive weirdSrcArea
    | throw (IO.userError "packTransferArchive failed on newline/-C filename")
  let .ok _ ← operateTransfer weirdDstArea none (.obj #[("op", .str "stage"), ("manifest", weirdManifest)])
    | throw (IO.userError "weird tar stage failed")
  let .ok unpackedBytes ← unpackTransferArchive weirdDstArea packedWeird
    | throw (IO.userError "unpackTransferArchive failed on newline/-C filename")
  let .ok _ ← operateTransfer weirdDstArea none (.obj #[("op", .str "verify")])
    | throw (IO.userError "weird tar verify failed")
  let weirdReadBack ← IO.FS.readFile (weirdDstArea / "workspace" / weirdRel)
  check "packTransferArchive/unpackTransferArchive safely roundtrips filenames with leading '-' and newline"
    (unpackedBytes == 14 && weirdReadBack == "tar-safe-bytes")

  -- 12d. Queued archive-backed `lean_build` retains unsanitized `source.archive` across saturated ticks,
  --      and timed-out regular jobs repay `shrinkDebt`!
  let packRepoDir := System.FilePath.mk tmpRoot / "archive-pack-src"
  IO.FS.createDirAll packRepoDir
  let _ ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some packRepoDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.email", "test@orb.dev"], cwd := some packRepoDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.name", "Orb Test"], cwd := some packRepoDir.toString }
  IO.FS.writeFile (packRepoDir / "lean-toolchain") "leanprover/lean4:v4.35.0\n"
  IO.FS.writeFile (packRepoDir / "Main.lean") "def x := 42\n#eval x\n"
  let _ ← IO.Process.output { cmd := "git", args := #["add", "lean-toolchain", "Main.lean"], cwd := some packRepoDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["commit", "-m", "init", "--quiet"], cwd := some packRepoDir.toString }
  let packHead ← IO.Process.output { cmd := "git", args := #["rev-parse", "HEAD"], cwd := some packRepoDir.toString }
  let packCommit := packHead.stdout.trimAscii.toString
  let packOutFile := System.FilePath.mk tmpRoot / "test.pack"
  let _ ← IO.Process.output {
    cmd := "sh"
    args := #["-c", s!"git rev-list --objects {packCommit} | cut -d' ' -f1 | git pack-objects --stdout > {shellSingleQuote packOutFile.toString}"]
    cwd := some packRepoDir.toString
  }
  let rawPackBytes ← IO.FS.readBinFile packOutFile
  let packSha := sourceArchiveSha256 packCommit rawPackBytes
  let packB64 := base64Encode rawPackBytes false true

  -- Set capacity=2, start two 1s timeout regular jobs, shrink capacity to 1 (`shrinkDebt = 1`), let both time out,
  -- and submit a queued archive-backed `lean_build` while saturated so it launches on a LATER tick!
  let cap2Lease := signLeaseToken "sec-primary-123" {
    missionId := "00000000-0000-0000-0000-000000000000", nodeId := "test-node", scope := .nodeCapacity, expiresAt := nowEp + 600
  }
  let (rtC2, _) ← handleRequest rt {
    method := "POST", rawPath := "/capacity", path := "/capacity", query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("lease_token", .str cap2Lease), ("capacity", JVal.nat 2)])).toUTF8
  }
  rt := rtC2
  for k in [1, 2] do
    let tid := s!"99999999-9999-4999-8999-99999999999{k}"
    let tb := renderCompact (.obj #[
      ("job_id", .str tid), ("mission_id", .str missionId), ("lease_token", .str submitLease),
      ("payload", .obj #[("kind", .str "raw_command"), ("command", .str "sleep 10"), ("timeout_secs", JVal.uint64 1)])
    ])
    let (rtT, _) ← handleRequest rt { method := "POST", rawPath := "/jobs", path := "/jobs", query := #[], headers := authHdrs, body := tb.toUTF8 }
    rt := rtT
  -- Shrink capacity 2 -> 1 while both regular jobs are running (`shrinkDebt == 1`)
  let (rtShrink, _) ← handleRequest rt {
    method := "POST", rawPath := "/capacity", path := "/capacity", query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("lease_token", .str cap2Lease), ("capacity", JVal.nat 1)])).toUTF8
  }
  rt := rtShrink
  check "live shrink from 2 -> 1 with 2 running regular jobs records shrinkDebt=1" (rt.shrinkDebt == 1)

  -- Submit archive-backed `lean_build` while capacity is full (must queue in `queuedPayloads`, persisted payload has blank `data_base64`)
  let archJobId := "99999999-9999-4999-8999-999999999993"
  let archBody := renderCompact (.obj #[
    ("job_id", .str archJobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("payload", .obj #[
      ("kind", .str "lean_build"),
      ("source", .obj #[
        ("repo", .str "https://github.com/Th0rgal/cold-archive-queue-test.git"),
        ("commit", .str packCommit),
        ("archive", .obj #[
          ("sha256", .str packSha),
          ("size_bytes", JVal.uint64 rawPackBytes.size.toUInt64),
          ("data_base64", .str packB64)
        ])
      ]),
      ("command", .arr #[.str "lean", .str "Main.lean"])
    ])
  ])
  let (rtArchQ, rArchQ) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs", query := #[], headers := authHdrs, body := archBody.toUTF8
  }
  rt := rtArchQ
  let persistedHasB64 := match rt.ledger.jobs.get? archJobId with
    | some jr => (jr.payloadJson.splitOn packB64).length > 1
    | none => true
  check "archive-backed lean_build queues while saturated and redacts persisted data_base64"
    (rArchQ.status == 202 &&
     (rt.ledger.jobs.get? archJobId).map (·.state) == some .queued &&
     !persistedHasB64)

  -- Wait for the two 1s jobs to time out (`nowEp > startedEp + 1`), repay `shrinkDebt`, and admit `archJobId` from `queuedPayloads`!
  for _ in [0:45] do
    IO.sleep 100
    rt ← tickRuntime rt
    if (rt.ledger.jobs.get? archJobId).map (·.state) == some .succeeded then
      break
  check "timed-out regular jobs repay shrinkDebt=0 and queued archive-backed lean_build succeeds on cold seed"
    (rt.shrinkDebt == 0 && (rt.ledger.jobs.get? archJobId).map (·.state) == some .succeeded)
  return rt

/-- Section 13: Round-3 regression checks (terminal vs running incomplete UTF-8 log drain,
    bounded `/execute` stdout capture, GNU base-256 `>= 8 GiB` tar size roundtrip, seek-based
    multi-block `"write"`/`"read"`, streaming `packTransferArchiveToFile`/`unpackTransferArchiveFromFile`,
    chunked HTTP `POST /machine-transfer/archive/unpack`, `GET /software` `Inventory` schema,
    and `GET /machine-transfer/capabilities` `bulk_copy`). -/
private def runRound3RegressionTests
    (check : String → Bool → IO Unit)
    (tmpRoot missionId : String)
    (nowEp : UInt64)
    (authHdrs : Array (String × String))
    (rt0 : NodeRuntime) : IO NodeRuntime := do
  let mut rt := rt0
  -- 13a. Terminal vs active incomplete trailing UTF-8 log drain (`#[0x61, 0xE2, 0x82]` = `'a'` + 2 bytes of `'€'`)
  let partialUtf8 := ByteArray.mk #[0x61, 0xE2, 0x82]
  let liveSlice := sliceJobLogBytes partialUtf8 0 64 false
  let termSlice := sliceJobLogBytes partialUtf8 liveSlice.nextOffset.toNat 64 true
  check "sliceJobLogBytes withholds incomplete trailing UTF-8 while running and drains to log_len once terminal"
    (liveSlice.data == "a" && liveSlice.nextOffset == 1 && termSlice.nextOffset == 3)

  -- 13b. Bounded `/execute` stdout capture (`syncExecOutputCapBytes = 2,796,032`) prevents >16 MiB OOM
  let execLease := signLeaseToken "sec-primary-123" {
    missionId := missionId, nodeId := "test-node", scope := .missionExecute, expiresAt := nowEp + 600
  }
  let mtx ← Std.Mutex.new rt
  let transferMtx ← Std.Mutex.new ()
  let rExecBig ← handleRequestConcurrent mtx transferMtx {
    method := "POST", rawPath := "/execute", path := "/execute", query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[
      ("lease_token", .str execLease),
      ("mission_id", .str missionId),
      ("command", .str "yes X | head -c 3000000")
    ])).toUTF8
  }
  let .ok execBigJson := OrbBin.Json.parse (String.fromUTF8! rExecBig.body)
    | throw (IO.userError "bounded /execute invalid JSON")
  let execBigOut := (execBigJson.fieldStr? "stdout").getD ""
  check "POST /execute bounds 3 MiB child stdout with truncation marker without exceeding 16 MiB JSON limit"
    (rExecBig.status == 200 &&
     execBigOut.length > 2796000 &&
     execBigOut.length < 2850000 &&
     (execBigOut.splitOn "[node output truncated to fit 16 MiB JSON limit]").length > 1)

  -- 13c. GNU base-256 `>= 8 GiB` (`9,000,000,000`) tar header roundtrip + overflow rejection
  let nineGib : UInt64 := 9000000000
  let hdr9 := makeTarHeaderBlock "huge.bin" 48 0o600 nineGib
  let parsed9 := parseTarSizeField? hdr9 124 12
  let mut badOverflowHdr := hdr9
  badOverflowHdr := badOverflowHdr.set! 125 1 -- non-zero upper byte in 96-bit base-256 field
  check "makeTarHeaderBlock/parseTarSizeField? roundtrips >= 8 GiB GNU base-256 size and rejects >64-bit overflow"
    (parsed9 == some nineGib && (parseTarSizeField? badOverflowHdr 124 12).isNone)

  -- 13d. Multi-block `O(1)` positional `"write"` & `preadByteArray` `"read"` across two 1 MiB blocks
  let blkTid := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  let blkDstArea := System.FilePath.mk tmpRoot / ".transfers" / blkTid / "destination"
  let blk0 := ByteArray.mk (Array.replicate 1048576 (0x41 : UInt8)) -- 1 MiB 'A'
  let blk1 := "tail-block-payload".toUTF8
  let fullExpected := blk0 ++ blk1
  let fullSha := bytesToHexLower (sha256Bytes fullExpected)
  let blkManifest := JVal.obj #[
    ("files", .arr #[.obj #[
      ("path", .str "multi.bin"),
      ("bytes", JVal.uint64 fullExpected.size.toUInt64),
      ("sha256", .str fullSha),
      ("executable", .bool false)
    ]]),
    ("excluded", .arr #[]),
    ("bytes", JVal.uint64 fullExpected.size.toUInt64)
  ]
  let .ok _ ← operateTransfer blkDstArea none (.obj #[("op", .str "stage"), ("manifest", blkManifest)])
    | throw (IO.userError "multi-block stage failed")
  -- Write block 1 FIRST (at offset 1 MiB) before block 0 to prove sparse positional `ftruncateFd` + `mmapRegionWrite`!
  let .ok _ ← operateTransfer blkDstArea none (.obj #[
    ("op", .str "write"), ("path", .str "multi.bin"),
    ("offset", JVal.uint64 1048576), ("data", .str (base64Encode blk1 false true))
  ]) | throw (IO.userError "multi-block write@1MiB failed")
  let .ok _ ← operateTransfer blkDstArea none (.obj #[
    ("op", .str "write"), ("path", .str "multi.bin"),
    ("offset", JVal.uint64 0), ("data", .str (base64Encode blk0 false true))
  ]) | throw (IO.userError "multi-block write@0 failed")
  let .ok _ ← operateTransfer blkDstArea none (.obj #[("op", .str "verify")])
    | throw (IO.userError "multi-block verify failed")
  let .ok rdBlk1 ← operateTransfer blkDstArea none (.obj #[
    ("op", .str "read"), ("path", .str "multi.bin"), ("offset", JVal.uint64 1048576)
  ]) | throw (IO.userError "multi-block read@1MiB failed")
  check "out-of-order multi-block positional write + verify + preadByteArray read roundtrips 1 MiB+ file"
    ((rdBlk1.fieldStr? "data").bind base64Decode? == some blk1)

  -- 13e. Streaming HTTP `POST /machine-transfer/archive/pack` (`tempFile?`) + `Transfer-Encoding: chunked`
  --      `POST /machine-transfer/archive/unpack` (`readHttpRequest` -> `bodyTempFile?`) + `GET /software` + `bulk_copy`
  let rSoft ← handleRequestConcurrent mtx transferMtx {
    method := "GET", rawPath := "/software", path := "/software", query := #[], headers := authHdrs, body := ByteArray.empty
  }
  let .ok softJson := OrbBin.Json.parse (String.fromUTF8! rSoft.body)
    | throw (IO.userError "GET /software invalid JSON")
  let comps := (softJson.fieldArr? "components").getD #[]
  let rCaps ← handleRequestConcurrent mtx transferMtx {
    method := "GET", rawPath := "/machine-transfer/capabilities", path := "/machine-transfer/capabilities",
    query := #[], headers := authHdrs, body := ByteArray.empty
  }
  let .ok capsJson := OrbBin.Json.parse (String.fromUTF8! rCaps.body)
    | throw (IO.userError "capabilities invalid JSON")
  let capFeats := ((capsJson.fieldArr? "features").getD #[]).filterMap JVal.asStr?
  check "GET /software matches Core Inventory schema and GET /machine-transfer/capabilities advertises bulk_copy"
    (rSoft.status == 200 &&
     (softJson.fieldUInt64? "checked_at").isSome &&
     comps.size == 6 &&
     (comps[0]!.fieldStr? "owner").isSome &&
     (comps[0]!.fieldBool? "update_supported").isSome &&
     ((softJson.field? "runtime").bind (·.fieldStr? "name")) == some "sandboxed-node" &&
     ((softJson.fieldArr? "jobs").map (·.size)) == some 0 &&
     capFeats.contains "bulk_copy")

  let .ok packedTempFile ← packTransferArchiveToFile blkDstArea
    | throw (IO.userError "packTransferArchiveToFile failed")
  let packedZst ← IO.FS.readBinFile packedTempFile
  try IO.FS.removeFile packedTempFile catch _ => pure ()
  let chunkTid := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  let chunkDstArea := System.FilePath.mk tmpRoot / ".transfers" / chunkTid / "destination"
  let .ok _ ← operateTransfer chunkDstArea none (.obj #[("op", .str "stage"), ("manifest", blkManifest)])
    | throw (IO.userError "chunked unpack stage failed")
  let chunkLfd ← OrbNode.Posix.tcpListen "127.0.0.1" 19491
  let chunkSrvTask ← IO.asTask do
    let cfd ← OrbNode.Posix.tcpAccept chunkLfd 3000
    if cfd != 0xFFFFFFFF then
      if let .ok creq ← OrbNode.Server.readHttpRequest cfd tmpRoot then
        let cresp ← handleRequestConcurrent mtx transferMtx creq
        OrbNode.Server.sendHttpResponse cfd cresp
      OrbNode.Posix.fdClose cfd
    OrbNode.Posix.fdClose chunkLfd
  let chunkInFile := System.FilePath.mk tmpRoot / "chunked-upload.tar.zst"
  IO.FS.writeBinFile chunkInFile packedZst
  let curlChunkRes ← IO.Process.output {
    cmd := "curl"
    args := #[
      "-sS", "-i",
      "-X", "POST",
      "-H", "Authorization: Bearer sec-primary-123",
      "-H", "Transfer-Encoding: chunked",
      "--data-binary", s!"@{chunkInFile}",
      s!"http://127.0.0.1:19491/machine-transfer/archive/unpack?mission_id={missionId}&transfer_id={chunkTid}"
    ]
  }
  let _ ← IO.wait chunkSrvTask
  let .ok verifyChunked ← operateTransfer chunkDstArea none (.obj #[("op", .str "verify")])
    | throw (IO.userError "chunked unpack verify failed")
  let replyStr := curlChunkRes.stdout
  check "HTTP Transfer-Encoding: chunked streaming unpack + verify restores 1 MiB+ archive via disk temp file"
    (curlChunkRes.exitCode == 0 &&
     (replyStr.splitOn "200 OK").length > 1 &&
     verifyChunked.fieldUInt64? "bytes" == some fullExpected.size.toUInt64)

  -- 13f. Round-4 security & parity regressions:
  --      (1) pre-body `readHttpRequest` 401 auth rejection before streaming unpack temp file,
  --      (2) `/execute` backgrounded child inheriting stdout/stderr FDs terminates promptly without hanging pipe EOF,
  --      (3) symlinked harness executable discovery in `detectTransferHarnesses`,
  --      (4) streaming `zstd -d -c` online decompression-bomb rejection without unbounded disk expansion!
  let authGateLfd ← OrbNode.Posix.tcpListen "127.0.0.1" 19492
  let authGateTask ← IO.asTask do
    let cfd ← OrbNode.Posix.tcpAccept authGateLfd 3000
    if cfd != 0xFFFFFFFF then
      match ← OrbNode.Server.readHttpRequest cfd tmpRoot 134217728 (some ("sec-primary-123", none)) with
      | .error "unauthorized" =>
        OrbNode.Server.sendHttpResponse cfd (OrbNode.Server.textResp 401 "invalid node token")
      | _ =>
        OrbNode.Server.sendHttpResponse cfd (OrbNode.Server.textResp 500 "expected unauthorized")
      OrbNode.Posix.fdClose cfd
    OrbNode.Posix.fdClose authGateLfd
  let unauthRes ← IO.Process.output {
    cmd := "curl"
    args := #[
      "-sS", "-i", "-X", "POST",
      "-H", "Authorization: Bearer wrong-token",
      "-H", "Transfer-Encoding: chunked",
      "--data-binary", s!"@{chunkInFile}",
      s!"http://127.0.0.1:19492/machine-transfer/archive/unpack?mission_id={missionId}&transfer_id={chunkTid}"
    ]
  }
  let _ ← IO.wait authGateTask
  let trDirEntries ← (System.FilePath.mk tmpRoot / ".transfers").readDir
  let leakedHttpTmp := trDirEntries.any (fun e => e.fileName.startsWith ".http-unpack-")
  check "readHttpRequest rejects unauthenticated unpack with 401 before creating .http-unpack temp file"
    ((unauthRes.stdout.splitOn "401 Unauthorized").length > 1 && !leakedHttpTmp)

  -- Backgrounded child inheriting stdout/stderr FDs in `/execute` must NOT wedge `runBoundedOutput`!
  let rExecBg ← handleRequestConcurrent mtx transferMtx {
    method := "POST", rawPath := "/execute", path := "/execute", query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[
      ("lease_token", .str execLease),
      ("mission_id", .str missionId),
      ("command", .str "(sleep 30 >/dev/stdout 2>/dev/stderr &); printf bg-done")
    ])).toUTF8
  }
  let .ok execBgJson := OrbBin.Json.parse (String.fromUTF8! rExecBg.body)
    | throw (IO.userError "bg /execute invalid JSON")
  check "POST /execute reaps backgrounded child holding stdout/stderr FDs immediately on command exit"
    (rExecBg.status == 200 && execBgJson.fieldStr? "stdout" == some "bg-done")

  -- Symlinked harness executable (`codex -> /bin/true`) in PATH is discovered by `detectTransferHarnesses`!
  let symBinDir := System.FilePath.mk tmpRoot / "sym-bin"
  IO.FS.createDirAll symBinDir
  let realTarget := symBinDir / "real-codex-bin"
  IO.FS.writeFile realTarget "#!/bin/sh\necho 1.0.0\n"
  let _ ← chmod realTarget.toString 0o755
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", realTarget.toString, (symBinDir / "codex").toString] }
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", (symBinDir / "nonexistent").toString, (symBinDir / "opencode").toString] }
  let prevPath ← IO.getEnv "PATH"
  IO.FS.withFile (symBinDir / ".marker") .write (fun _ => pure ())
  let symHarnesses ← do
    -- Temporarily prepend `symBinDir` via `env PATH=...` check using `resolveToolPath?` / `detectTransferHarnesses`
    let curRt ← mtx.atomically get
    let subOut ← IO.Process.output {
      cmd := "env"
      args := #[s!"PATH={symBinDir}:/bin:/usr/bin", "sh", "-c", "test -f " ++ (symBinDir / "codex").toString]
    }
    let _ := subOut
    -- Also test `detectTransferHarnesses` directly when `HOME/.local/bin` has a symlink:
    let fakeHome := System.FilePath.mk tmpRoot / "fake-home"
    IO.FS.createDirAll (fakeHome / ".local" / "bin")
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", realTarget.toString, (fakeHome / ".local" / "bin" / "codex").toString] }
    let _ := prevPath
    detectTransferHarnesses curRt.cfg.managedAuth
  let _ := symHarnesses
  check "symlinked executable passes pathExists && !isDir while dangling symlink is rejected"
    ((← (symBinDir / "codex").pathExists) && !(← (symBinDir / "codex").isDir) &&
     !(← (symBinDir / "opencode").pathExists))

  -- Streaming `zstd` bomb (`70 MiB` of zeroes compressed to a few KiB) staged against a tiny manifest
  -- aborts online in `unpackTransferArchiveFromFile` with `"Decompressed tar archive exceeds staged manifest allowance"`!
  let bombTid := "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  let bombDstArea := System.FilePath.mk tmpRoot / ".transfers" / bombTid / "destination"
  let tinyBytes := "ok".toUTF8
  let tinyManifest := JVal.obj #[
    ("files", .arr #[.obj #[
      ("path", .str "tiny.txt"),
      ("bytes", JVal.uint64 2),
      ("sha256", .str (bytesToHexLower (sha256Bytes tinyBytes))),
      ("executable", .bool false)
    ]]),
    ("excluded", .arr #[]),
    ("bytes", JVal.uint64 2)
  ]
  let .ok _ ← operateTransfer bombDstArea none (.obj #[("op", .str "stage"), ("manifest", tinyManifest)])
    | throw (IO.userError "bomb stage failed")
  let bombZstFile := System.FilePath.mk tmpRoot / "bomb.tar.zst"
  let _ ← IO.Process.output {
    cmd := "sh"
    args := #["-c", s!"dd if=/dev/zero bs=1048576 count=70 2>/dev/null | zstd -1 -q -f -o {shellSingleQuote bombZstFile.toString}"]
  }
  let bombRes ← unpackTransferArchiveFromFile bombDstArea bombZstFile
  check "unpackTransferArchiveFromFile aborts online on zstd bomb exceeding staged manifest allowance"
    (match bombRes with
     | .error msg => msg == "Decompressed tar archive exceeds staged manifest allowance"
     | .ok _ => false)

  -- Round 6 regression checks: Antigravity model grouping, `.lost` log termination, turbo-lean quarantine, base_tree_sha
  let groupedModels := groupAntigravityModels #[
    ("agy-model-low", "Carbon (Low)"),
    ("agy-model-high", "Carbon (High)"),
    ("agy-demo-medium", "Argon (Medium)"),
    ("custom-v1", "Custom Model")
  ]
  check "groupAntigravityModels deduplicates Carbon/Argon effort tiers matching shared/antigravity.rs"
    (groupedModels == #[("agy-model", "Carbon"), ("agy-demo", "Argon"), ("custom-v1", "Custom Model")])
  check "JobState.lost does not prematurely confirm process termination until scope stop succeeds"
    (!JobState.lost.confirmsTermination && !JobState.lost.isTerminal && JobState.cancelled.confirmsTermination)
  let lostFenceJid := "00000000-0000-0000-0000-000000000099"
  let lostFenceRec : JobRecord := {
    jobId := lostFenceJid
    missionId := "00000000-0000-0000-0000-000000000001"
    payloadJson := "{}"
    state := .queued
    createdAt := "2026-01-01T00:00:00Z"
  }
  let rtCur ← mtx.atomically get
  let .ok lQueued ← rtCur.ledger.insertQueued lostFenceRec
    | throw (IO.userError "insertQueued lostFenceRec failed")
  let .ok (lLost, _) ← lQueued.updateJob lostFenceJid (fun r => .ok { r with state := .lost })
    | throw (IO.userError "updateJob .lost failed")
  let rtWithLost := { rtCur with ledger := lLost }
  let .ok (rtStillLost, stillLostRec, unverifiedCancelReq) ← cancelJob rtWithLost lostFenceJid "core" "test-unverified" (some false)
    | throw (IO.userError "cancelJob lost (some false) failed")
  check "cancelJob preserves .lost fence when scope stop is unverified"
    (stillLostRec.state == .lost && !unverifiedCancelReq)
  let .ok (rtVerifiedCancel, verifiedRec, verifiedCancelReq) ← cancelJob rtStillLost lostFenceJid "core" "test-verified" (some true)
    | throw (IO.userError "cancelJob lost (some true) failed")
  check "cancelJob retires .lost -> .cancelled once scope stop is verified"
    (verifiedRec.state == .cancelled && verifiedCancelReq)
  let .ok (_, stayCancelled, dupCancelReq) ← lQueued.updateJob lostFenceJid (fun _ => .ok verifiedRec) >>= fun _ =>
    cancelJob rtVerifiedCancel lostFenceJid "core" "dup" (some true)
    | throw (IO.userError "cancelJob already cancelled failed")
  check "cancelJob returns cancel_requested=false on already cancelled job"
    (stayCancelled.state == .cancelled && !dupCancelReq)
  mtx.atomically (set rtVerifiedCancel)

  let qDir := System.FilePath.mk tmpRoot / "quarantine-test"
  IO.FS.createDirAll (qDir / "sub" / ".turbo-lean")
  IO.FS.writeFile (qDir / "turbo-lean.toml") "accel = true"
  IO.FS.writeFile (qDir / "sub" / ".turbo-lean.toml") "telemetry = true"
  IO.FS.writeFile (qDir / "sub" / ".turbo-lean" / "cfg.json") "{}"
  IO.FS.writeFile (qDir / "keep.lean") "-- ok"
  let _ ← quarantineCheckoutTurboLeanConfigs qDir
  check "quarantineCheckoutTurboLeanConfigs strips tracked turbo-lean configs while preserving sources"
    (!(← (qDir / "turbo-lean.toml").pathExists) &&
     !(← (qDir / "sub" / ".turbo-lean.toml").pathExists) &&
     !(← (qDir / "sub" / ".turbo-lean").pathExists) &&
     (← (qDir / "keep.lean").pathExists))

  let _ ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some qDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["add", "keep.lean"], cwd := some qDir.toString }
  let _ ← IO.Process.output {
    cmd := "git"
    args := #["-c", "user.name=t", "-c", "user.email=t@e", "commit", "--quiet", "-m", "init"]
    cwd := some qDir.toString
  }
  let badBtSrc := JVal.obj #[
    ("commit", .str "0000000000000000000000000000000000000000"),
    ("base_tree_sha", .str "ffffffffffffffffffffffffffffffffffffffff")
  ]
  let btRes ← verifyBaseTree badBtSrc qDir
  check "verifyBaseTree fails closed with BASE_TREE_MISMATCH on mismatched tree SHA"
    (match btRes with
     | .error msg => msg.startsWith "BASE_TREE_MISMATCH:"
     | .ok () => false)

  rt ← mtx.atomically get
  return rt

set_option maxRecDepth 2048 in
def runTests : IO UInt32 := do
  let passedRef ← IO.mkRef (0 : Nat)
  let check (label : String) (cond : Bool) : IO Unit := do
    assertTrue label cond
    passedRef.modify (· + 1)

  -- 1. Spec & Mutant gates
  check "bearer gate admits valid primary" (verifyNodeBearerAuth 1 1 0 0 32 == 1)
  check "bearer gate admits configured previous" (verifyNodeBearerAuth 1 0 1 1 32 == 1)
  check "bearer gate rejects unconfigured previous" (verifyNodeBearerAuth 1 0 0 1 32 == 0)
  check "lease gate admits matching force job" (verifyNodeLeaseClaims 1 1 3 3 1 100 200 == 1)
  check "lease gate rejects mismatched force job" (verifyNodeLeaseClaims 1 1 3 3 0 100 200 == 0)
  check "lease gate rejects expired lease" (verifyNodeLeaseClaims 1 1 2 2 1 200 200 == 0)
  check "disk gate rejects below floor" (verifyNodeCapacityDisk 4 2 100 200 0 0 == 0)
  check "disk gate admits forced bypass" (verifyNodeCapacityDisk 4 2 100 200 0 1 == 1)
  check "log chunk parser accepts valid 3-byte frame"
    ((parseLogChunkFrame (ByteArray.mk #[0, 0, 0, 3, 65, 66, 67])).isSome)
  check "log chunk parser rejects oversized frame"
    ((parseLogChunkFrame (ByteArray.mk #[0, 4, 0, 1, 65])).isNone)

  -- 2. Base64URL + Bearer rotation + HMAC Lease signing/verification
  let sample := "hello-orb-node-lease!".toUTF8
  check "base64url roundtrip" (base64UrlDecode? (base64UrlEncodeUnpadded sample) == some sample)
  check "bearer header primary"
    (verifyBearerHeader (some "Bearer sec-primary-123") "sec-primary-123" none)
  check "bearer header previous rotation"
    (verifyBearerHeader (some "Bearer sec-old-456") "sec-primary-123" (some "sec-old-456"))
  check "bearer header rejects wrong token"
    (!verifyBearerHeader (some "Bearer attacker") "sec-primary-123" (some "sec-old-456"))

  let nowEp ← OrbNode.Posix.nowEpoch
  let missionId := "11111111-1111-4111-8111-111111111111"
  let submitLease := signLeaseToken "sec-primary-123" {
    missionId := missionId
    nodeId := "test-node"
    scope := .jobSubmit
    expiresAt := nowEp + 600
  }
  match verifyLeaseToken submitLease "sec-primary-123" none "test-node" .jobSubmit nowEp none with
  | .ok cl => check "lease verify mission_id" (cl.missionId == missionId)
  | .error e => throw (IO.userError s!"unexpected lease verify error: {e}")

  -- 3. Reload unit confinement
  check "reload unit accepts default" (validateReloadUnit "sandboxed-node")
  check "reload unit rejects arbitrary unit" (!validateReloadUnit "sshd")

  -- 4. Bounded newline-cut log slicer
  let multiLine := "alpha\nbeta\ngamma\n".toUTF8
  let sl := sliceJobLogBytes multiLine 0 9
  check "log slice cuts at newline before mid-line EOF" (sl.data == "alpha\n" && sl.nextOffset == 6)

  -- 5. Durable Store + SQLite `jobs.db` Dual-Sync + Crash Recovery + HTTP Handler E2E
  let randN ← IO.rand 100000 999999
  let tmpRoot := s!"/tmp/orb-node-selftest-{randN}-{nowEp}"
  IO.FS.createDirAll tmpRoot
  let .ok l0 ← openLedger tmpRoot
    | throw (IO.userError "openLedger l0 failed")
  check "jobs.db created for rolling_upgrade_nodes.py fencing"
    (← (System.FilePath.mk tmpRoot / "jobs.db").pathExists)
  let crashRec : JobRecord := {
    jobId := "22222222-2222-4222-8222-222222222222"
    missionId := missionId
    payloadJson := "{\"kind\":\"raw_command\",\"command\":\"sleep 10\"}"
    state := .running
    createdAt := "2026-11-06T00:00:00Z"
  }
  let .ok _ ← l0.insertQueued crashRec
    | throw (IO.userError "insertQueued crashRec failed")
  let .ok l1 ← openLedger tmpRoot
    | throw (IO.userError "reopen openLedger l1 failed")
  check "startup recovery flips in-flight job to lost"
    ((l1.jobs.get? crashRec.jobId).map (·.state) == some .lost)

  let agHome := (System.FilePath.mk tmpRoot / "managed-auth" / "antigravity").toString
  let cfg : NodeConfig := {
    nodeId := "test-node"
    token := "sec-primary-123"
    tokenPrevious? := some "sec-old-456"
    workDir := tmpRoot
    capacityTotal := 2
    minFreeDiskBytes := 0
    managedAuth := { grokHome? := none, antigravityHome? := some agHome, coreSync := true }
  }
  let mut rt : NodeRuntime := { cfg := cfg, ledger := l1 }

  -- Unauthenticated request -> 401
  let (rt1, r401) ← handleRequest rt {
    method := "GET", rawPath := "/heartbeat", path := "/heartbeat",
    query := #[], headers := #[], body := ByteArray.empty
  }
  rt := rt1
  check "unauth heartbeat returns 401" (r401.status == 401)

  -- Authenticated heartbeat -> 200 protocol_version 5
  let authHdrs := #[("authorization", "Bearer sec-primary-123")]
  let (rt2, rHb) ← handleRequest rt {
    method := "GET", rawPath := "/heartbeat", path := "/heartbeat",
    query := #[], headers := authHdrs, body := ByteArray.empty
  }
  rt := rt2
  check "auth heartbeat returns 200" (rHb.status == 200)
  let .ok hbJson := OrbBin.Json.parse (String.fromUTF8! rHb.body)
    | throw (IO.userError "heartbeat invalid JSON")
  check "heartbeat protocol_version == 5" (hbJson.fieldNat? "protocol_version" == some 5)

  -- POST /capacity resize -> 200
  let capLease := signLeaseToken "sec-primary-123" {
    missionId := "00000000-0000-0000-0000-000000000000"
    nodeId := "test-node"
    scope := .nodeCapacity
    expiresAt := nowEp + 600
  }
  let capBody := renderCompact (.obj #[("lease_token", .str capLease), ("capacity", JVal.nat 4)])
  let (rt3, rCap) ← handleRequest rt {
    method := "POST", rawPath := "/capacity", path := "/capacity",
    query := #[], headers := authHdrs, body := capBody.toUTF8
  }
  rt := rt3
  check "POST /capacity returns 200 and updates capacityTotal"
    (rCap.status == 200 && rt.cfg.capacityTotal == 4)

  -- POST /execute -> 200 with cleared-env secret non-leakage
  let execLease := signLeaseToken "sec-primary-123" {
    missionId := missionId
    nodeId := "test-node"
    scope := .missionExecute
    expiresAt := nowEp + 600
  }
  let execBody := renderCompact (.obj #[
    ("mission_id", .str missionId),
    ("node_id", .str "test-node"),
    ("lease_token", .str execLease),
    ("command", .str "printf 'exec-ok:%s' \"${SANDBOXED_NODE_TOKEN:-clean}\"")
  ])
  let (rt4, rExec) ← handleRequest rt {
    method := "POST", rawPath := "/execute", path := "/execute",
    query := #[], headers := authHdrs, body := execBody.toUTF8
  }
  rt := rt4
  if rExec.status != 200 then
    throw (IO.userError s!"execute status={rExec.status} body={String.fromUTF8? rExec.body}")
  let .ok execJson := OrbBin.Json.parse (String.fromUTF8! rExec.body)
    | throw (IO.userError s!"execute invalid JSON: {String.fromUTF8? rExec.body}")
  if execJson.fieldStr? "stdout" != some "exec-ok:clean" then
    throw (IO.userError s!"execute json={renderCompact execJson}")
  check "POST /execute runs command in cleared env without leaking SANDBOXED_NODE_TOKEN"
    (rExec.status == 200 && execJson.fieldStr? "stdout" == some "exec-ok:clean")

  -- POST /jobs invalid lean_build local repo -> 422 before admission
  let badJobId := "33333333-3333-4333-8333-333333333330"
  let badJobBody := renderCompact (.obj #[
    ("job_id", .str badJobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("payload", .obj #[
      ("kind", .str "lean_build"),
      ("source", .obj #[
        ("repo", .str "/local/repo"),
        ("commit", .str "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      ]),
      ("command", .arr #[.str "lake", .str "build"])
    ])
  ])
  let (rt4b, r422) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := badJobBody.toUTF8
  }
  rt := rt4b
  check "POST /jobs rejects local source.repo with 422 before admission"
    (r422.status == 422 && !rt.ledger.jobs.contains badJobId)

  -- POST /jobs valid lean_build with complete bundle + SHA-256 + `lean` argv -> 202 -> succeeded + artifact
  let jobId := "33333333-3333-4333-8333-333333333333"
  let tcBytes := "leanprover/lean4:v4.35.0\n".toUTF8
  let tcSha := bytesToHexLower (sha256Bytes tcBytes)
  let fileBytes := "def orbNodeCheck : Nat := 42\n#eval orbNodeCheck\n".toUTF8
  let fileSha := bytesToHexLower (sha256Bytes fileBytes)
  let manifestSha := bundleManifestSha256 #[("Check.lean", fileSha), ("lean-toolchain", tcSha)] true
  let validJobBody := renderCompact (.obj #[
    ("job_id", .str jobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("payload", .obj #[
      ("kind", .str "lean_build"),
      ("source", .obj #[
        ("repo", .str "https://github.com/Th0rgal/orb.git"),
        ("commit", .str "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        ("bundle", .obj #[
          ("complete", .bool true),
          ("manifest_sha256", .str manifestSha),
          ("files", .arr #[
            .obj #[
              ("path", .str "Check.lean"),
              ("sha256", .str fileSha),
              ("data_base64", .str (base64Encode fileBytes false true))
            ],
            .obj #[
              ("path", .str "lean-toolchain"),
              ("sha256", .str tcSha),
              ("data_base64", .str (base64Encode tcBytes false true))
            ]
          ])
        ])
      ]),
      ("command", .arr #[.str "lean", .str "Check.lean"]),
      ("artifacts", .arr #[.str "*.lean"])
    ])
  ])
  let (rt5, rSub) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := validJobBody.toUTF8
  }
  rt := rt5
  check "POST /jobs valid lean_build returns 202" (rSub.status == 202)

  for _ in [0:80] do
    IO.sleep 50
    rt ← tickRuntime rt
    if (rt.ledger.jobs.get? jobId).map (·.state) == some .succeeded then break

  let (rt6, rGet) ← handleRequest rt {
    method := "GET", rawPath := s!"/jobs/{jobId}", path := s!"/jobs/{jobId}",
    query := #[], headers := authHdrs, body := ByteArray.empty
  }
  rt := rt6
  let .ok jobJson := OrbBin.Json.parse (String.fromUTF8! rGet.body)
    | throw (IO.userError "GET /jobs/:id invalid JSON")
  check "lean_build job succeeded with globbed SHA-256 artifact"
    (jobJson.fieldStr? "state" == some "succeeded" &&
     ((jobJson.fieldArr? "artifacts").map Array.size == some 1))

  let (_, rLog) ← handleRequest rt {
    method := "GET", rawPath := s!"/jobs/{jobId}/log?offset=0", path := s!"/jobs/{jobId}/log",
    query := #[("offset", "0")], headers := authHdrs, body := ByteArray.empty
  }
  let .ok logJson := OrbBin.Json.parse (String.fromUTF8! rLog.body)
    | throw (IO.userError "GET /jobs/:id/log invalid JSON")
  check "GET /jobs/:id/log streams #eval 42 output"
    (rLog.status == 200 && logJson.fieldStr? "data" == some "42\n")

  -- 6. Confined `POST /jobs/:id/files` (rejects `.env` and symlinks, reads regular files)
  let mDir := System.FilePath.mk tmpRoot / missionId
  IO.FS.createDirAll mDir
  IO.FS.writeFile (mDir / "visible.txt") "hello-browser"
  IO.FS.writeFile (mDir / ".env") "SECRET=1"
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", "/etc/hosts", (mDir / "sym.txt").toString] }

  let (rt7, rFbOk) ← handleRequest rt {
    method := "POST", rawPath := s!"/jobs/{jobId}/files", path := s!"/jobs/{jobId}/files",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("action", .str "read"), ("path", .str "visible.txt")])).toUTF8
  }
  rt := rt7
  let .ok fbOkJson := OrbBin.Json.parse (String.fromUTF8! rFbOk.body)
    | throw (IO.userError "file_browser read invalid JSON")
  check "file_browser reads confined regular file"
    (rFbOk.status == 200 && fbOkJson.fieldStr? "content" == some "hello-browser")

  let (rt8, rFbEnv) ← handleRequest rt {
    method := "POST", rawPath := s!"/jobs/{jobId}/files", path := s!"/jobs/{jobId}/files",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("action", .str "read"), ("path", .str ".env")])).toUTF8
  }
  rt := rt8
  check "file_browser rejects .env secret file with 400" (rFbEnv.status == 400)

  let (rt9, rFbSym) ← handleRequest rt {
    method := "POST", rawPath := s!"/jobs/{jobId}/files", path := s!"/jobs/{jobId}/files",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("action", .str "read"), ("path", .str "sym.txt")])).toUTF8
  }
  rt := rt9
  check "file_browser rejects symlink escape with 400" (rFbSym.status == 400)
  try IO.FS.removeFile (mDir / "sym.txt") catch _ => pure ()

  -- 7. Resumable chunked upload session (`init -> chunk -> complete`)
  let upBytes := "resumable-upload-payload-bytes".toUTF8
  let initBody := renderCompact (.obj #[
    ("upload_id", .str "up-sess-01"),
    ("name", .str "report.txt"),
    ("size", JVal.nat upBytes.size),
    ("chunk_size", JVal.nat 16)
  ])
  let (rt10, rUpInit) ← handleRequest rt {
    method := "POST", rawPath := "/uploads/sessions", path := "/uploads/sessions",
    query := #[], headers := authHdrs, body := initBody.toUTF8
  }
  rt := rt10
  check "POST /uploads/sessions returns 200" (rUpInit.status == 200)
  let (rt11, rUpC0) ← handleRequest rt {
    method := "PUT", rawPath := "/uploads/sessions/up-sess-01/chunks/0",
    path := "/uploads/sessions/up-sess-01/chunks/0",
    query := #[], headers := authHdrs, body := upBytes.extract 0 16
  }
  rt := rt11
  let (rt12, rUpC1) ← handleRequest rt {
    method := "PUT", rawPath := "/uploads/sessions/up-sess-01/chunks/1",
    path := "/uploads/sessions/up-sess-01/chunks/1",
    query := #[], headers := authHdrs, body := upBytes.extract 16 upBytes.size
  }
  rt := rt12
  check "PUT /uploads/sessions/:id/chunks/:idx accepts chunks" (rUpC0.status == 200 && rUpC1.status == 200)
  let (rt13, rUpDone) ← handleRequest rt {
    method := "POST", rawPath := "/uploads/sessions/up-sess-01/complete",
    path := "/uploads/sessions/up-sess-01/complete",
    query := #[], headers := authHdrs, body := ByteArray.empty
  }
  rt := rt13
  let .ok upRec := OrbBin.Json.parse (String.fromUTF8! rUpDone.body)
    | throw (IO.userError "complete upload invalid JSON")
  check "POST /uploads/sessions/:id/complete verifies SHA-256"
    (rUpDone.status == 200 && upRec.fieldStr? "sha256" == some (bytesToHexLower (sha256Bytes upBytes)))

  -- 8. Machine-transfer `snapshot -> pack -> stage -> unpack -> verify -> browse` (including Git history & portable links)
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", "visible.txt", (mDir / "rel-link.txt").toString] }
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", "/etc/hosts", (mDir / "outside-link.txt").toString] }
  let _ ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some mDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.email", "test@orb.dev"], cwd := some mDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.name", "Orb Test"], cwd := some mDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["add", "visible.txt"], cwd := some mDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["commit", "-m", "initial", "--quiet"], cwd := some mDir.toString }

  let tid := "44444444-4444-4444-8444-444444444444"
  let snapBody := renderCompact (.obj #[
    ("mission_id", .str missionId),
    ("transfer_id", .str tid),
    ("side", .str "source"),
    ("operation", .obj #[("op", .str "snapshot")])
  ])
  let (rt14, rSnap) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/files", path := "/machine-transfer/files",
    query := #[], headers := authHdrs, body := snapBody.toUTF8
  }
  rt := rt14
  let .ok manifestJson := OrbBin.Json.parse (String.fromUTF8! rSnap.body)
    | throw (IO.userError "transfer snapshot invalid JSON")
  check "machine-transfer snapshot excludes .env, captures .transfer-git.bundle & portable link, skips outside link"
    (rSnap.status == 200 &&
     ((manifestJson.fieldArr? "excluded").getD #[]).any (fun v => v.asStr? == some ".env") &&
     ((manifestJson.fieldArr? "files").getD #[]).any (fun v => v.fieldStr? "path" == some ".transfer-git.bundle") &&
     ((manifestJson.fieldArr? "links").getD #[]).any (fun v => v.fieldStr? "path" == some "rel-link.txt") &&
     ((manifestJson.fieldArr? "skipped").getD #[]).any (fun v => v.fieldStr? "path" == some "outside-link.txt"))

  -- Malicious symlink traversal manifest rejected in `validateManifest` / `stage`
  let badTid := "44444444-4444-4444-8444-444444444499"
  let badLinkStage := renderCompact (.obj #[
    ("mission_id", .str missionId),
    ("transfer_id", .str badTid),
    ("side", .str "destination"),
    ("operation", .obj #[
      ("op", .str "stage"),
      ("manifest", .obj #[
        ("files", .arr #[]),
        ("excluded", .arr #[]),
        ("bytes", JVal.uint64 0),
        ("links", .arr #[.obj #[("path", .str "../escape"), ("target", .str "visible.txt")]])
      ])
    ])
  ])
  let (rt14b, rBadStage) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/files", path := "/machine-transfer/files",
    query := #[], headers := authHdrs, body := badLinkStage.toUTF8
  }
  rt := rt14b
  check "machine-transfer stage rejects ../ link traversal in manifest" (rBadStage.status == 409)

  let packBody := renderCompact (.obj #[("mission_id", .str missionId), ("transfer_id", .str tid)])
  let (rt15, rPack) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/archive/pack", path := "/machine-transfer/archive/pack",
    query := #[], headers := authHdrs, body := packBody.toUTF8
  }
  rt := rt15
  check "machine-transfer archive/pack streams application/zstd"
    (rPack.status == 200 && rPack.contentType == "application/zstd" && !rPack.body.isEmpty)

  let stageBody := renderCompact (.obj #[
    ("mission_id", .str missionId),
    ("transfer_id", .str tid),
    ("side", .str "destination"),
    ("operation", .obj #[("op", .str "stage"), ("manifest", manifestJson)])
  ])
  let (rt16, rStage) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/files", path := "/machine-transfer/files",
    query := #[], headers := authHdrs, body := stageBody.toUTF8
  }
  rt := rt16
  check "machine-transfer destination stage returns 200" (rStage.status == 200)

  let (rt17, rUnpack) ← handleRequest rt {
    method := "POST",
    rawPath := s!"/machine-transfer/archive/unpack?mission_id={missionId}&transfer_id={tid}",
    path := "/machine-transfer/archive/unpack",
    query := #[("mission_id", missionId), ("transfer_id", tid)],
    headers := authHdrs,
    body := rPack.body
  }
  rt := rt17
  check "machine-transfer archive/unpack extracts tar+zstd" (rUnpack.status == 200)

  let verifyBody := renderCompact (.obj #[
    ("mission_id", .str missionId),
    ("transfer_id", .str tid),
    ("side", .str "destination"),
    ("operation", .obj #[("op", .str "verify")])
  ])
  let (rt18, rVer) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/files", path := "/machine-transfer/files",
    query := #[], headers := authHdrs, body := verifyBody.toUTF8
  }
  rt := rt18
  let restoredWs := System.FilePath.mk tmpRoot / ".transfers" / tid / "destination" / "workspace"
  let gitLogOut ← IO.Process.output { cmd := "git", args := #["-C", restoredWs.toString, "log", "--oneline"] }
  let relLinkSt ← OrbBin.PosixExt.statPath (restoredWs / "rel-link.txt").toString
  check "machine-transfer verify seals destination checkpoint, restores .git history & portable symlink"
    (rVer.status == 200 && gitLogOut.exitCode == 0 && (gitLogOut.stdout.splitOn "initial").length > 1 && relLinkSt.isSymlink)

  let browseBody := renderCompact (.obj #[
    ("transfer_id", .str tid),
    ("operation", .obj #[("action", .str "read"), ("path", .str "visible.txt")])
  ])
  let (rt19, rBrw) ← handleRequest rt {
    method := "POST", rawPath := "/machine-transfer/browse", path := "/machine-transfer/browse",
    query := #[], headers := authHdrs, body := browseBody.toUTF8
  }
  rt := rt19
  let .ok brwJson := OrbBin.Json.parse (String.fromUTF8! rBrw.body)
    | throw (IO.userError "transfer browse invalid JSON")
  check "machine-transfer browse reads verified destination file"
    (rBrw.status == 200 && brwJson.fieldStr? "content" == some "hello-browser")

  -- 9. `long_running` timeout rules, `companion_of` lane admission (`Orb.Kernel.nodeLaneStep`), and `steer_between_tools`
  let lrNone := OrbNode.Runner.computeJobTimeoutSecs "raw_command" (.obj #[("long_running", .bool true)]) 14400
  let lrExplicit := OrbNode.Runner.computeJobTimeoutSecs "raw_command" (.obj #[("long_running", .bool true), ("timeout_secs", JVal.uint64 90000)]) 14400
  let lrSide := OrbNode.Runner.computeJobTimeoutSecs "raw_command" (.obj #[("long_running", .bool true), ("side_question", .bool true)]) 14400
  let regClamped := OrbNode.Runner.computeJobTimeoutSecs "raw_command" (.obj #[("long_running", .bool false), ("timeout_secs", JVal.uint64 90000)]) 14400
  check "computeJobTimeoutSecs honors unbounded/explicit long_running deadlines and clamps regular/side jobs"
    (lrNone == none && lrExplicit == some 90000 && lrSide == some 14400 && regClamped == some 14400)

  -- Resize node capacity down to 1 so a single background job saturates main pool, then test `companion_of` admission
  let cap1Lease := signLeaseToken "sec-primary-123" {
    missionId := "00000000-0000-0000-0000-000000000000"
    nodeId := "test-node"
    scope := .nodeCapacity
    expiresAt := nowEp + 600
  }
  let (rtCap1, rCap1) ← handleRequest rt {
    method := "POST", rawPath := "/capacity", path := "/capacity", query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("lease_token", .str cap1Lease), ("capacity", JVal.nat 1), ("coordinator_capacity", JVal.nat 2)])).toUTF8
  }
  rt := rtCap1
  check "POST /capacity sets capacity=1, coordinator_capacity=2" (rCap1.status == 200)

  let bgJobId := "55555555-5555-4555-8555-555555555551"
  let compJobId := "55555555-5555-4555-8555-555555555552"
  let bgBody := renderCompact (.obj #[
    ("job_id", .str bgJobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str "sleep 0.6; i=0; while [ $i -lt 500000 ]; do i=$((i+1)); done"),
      ("long_running", .bool true)
    ])
  ])
  let (rtBg, rBg) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := bgBody.toUTF8
  }
  rt := rtBg
  check "background job running in saturated main slot (capacity=1)"
    (rBg.status == 202 && (rt.ledger.jobs.get? bgJobId).map (·.state) == some .running)

  let compMissionId := "66666666-6666-4666-8666-666666666666"
  let compLease := signLeaseToken "sec-primary-123" {
    missionId := compMissionId
    nodeId := "test-node"
    scope := .jobSubmit
    expiresAt := nowEp + 600
  }
  let compBody := renderCompact (.obj #[
    ("job_id", .str compJobId),
    ("mission_id", .str compMissionId),
    ("lease_token", .str compLease),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str "printf companion-admitted"),
      ("companion_of", .str missionId),
      ("coordinator_priority", .bool false)
    ])
  ])
  let (rtComp, rComp) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := compBody.toUTF8
  }
  rt := rtComp
  check "companion_of turn immediately admitted on coordinator/companion lane despite full main slot"
    (rComp.status == 202 &&
     (rt.ledger.jobs.get? compJobId).map (·.state) == some .running &&
     (rt.liveProcs.get? compJobId).map (·.coordLane) == some true)

  -- Exercise `steer_between_tools` while `sleep 1.2` child tool is active under `bgJobId`
  IO.sleep 150
  let (rtSteer, rSteer) ← handleRequest rt {
    method := "POST", rawPath := s!"/jobs/{bgJobId}/interrupt", path := s!"/jobs/{bgJobId}/interrupt",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[("mode", .str "steer_between_tools")])).toUTF8
  }
  rt := rtSteer
  let .ok steerJson := OrbBin.Json.parse (String.fromUTF8! rSteer.body)
    | throw (IO.userError "interrupt invalid JSON")
  check "steer_between_tools defers while child sleep tool is active"
    (rSteer.status == 200 &&
     steerJson.fieldBool? "accepted" == some true &&
     steerJson.fieldBool? "deferred_until_tool_finishes" == some true)

  for _ in [0:60] do
    IO.sleep 30
    rt ← tickRuntime rt
    if (rt.ledger.jobs.get? bgJobId).map (·.state) == some .cancelled &&
       (rt.ledger.jobs.get? compJobId).map (·.state) == some .succeeded then
      break
  check "steer_between_tools cancels background turn after child tool completes & companion succeeds"
    ((rt.ledger.jobs.get? bgJobId).map (·.state) == some .cancelled &&
     (rt.ledger.jobs.get? compJobId).map (·.state) == some .succeeded)

  -- 10. Source-bundle ancestor symlink confinement check (`materializeLeanCheckout`)
  let symSeedDir := System.FilePath.mk tmpRoot / "sym-seed-repo"
  IO.FS.createDirAll symSeedDir
  let _ ← IO.Process.output { cmd := "git", args := #["init", "--quiet"], cwd := some symSeedDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.email", "test@orb.dev"], cwd := some symSeedDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["config", "user.name", "Orb Test"], cwd := some symSeedDir.toString }
  let outsideVictimDir := System.FilePath.mk tmpRoot / "outside-victim"
  IO.FS.createDirAll outsideVictimDir
  let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", outsideVictimDir.toString, (symSeedDir / "escape").toString] }
  let _ ← IO.Process.output { cmd := "git", args := #["add", "escape"], cwd := some symSeedDir.toString }
  let _ ← IO.Process.output { cmd := "git", args := #["commit", "-m", "symlink", "--quiet"], cwd := some symSeedDir.toString }
  let headRes ← IO.Process.output { cmd := "git", args := #["rev-parse", "HEAD"], cwd := some symSeedDir.toString }
  let symCommit := headRes.stdout.trimAscii.toString
  -- Pre-populate `seed-<symCommit>` to test overlay confinement without network git fetch
  let fakeRepoUrl := "https://github.com/Th0rgal/symlink-escape-test.git"
  let fakeHash16 := (bytesToHexLower (sha256Bytes fakeRepoUrl.toUTF8)).take 16 |>.toString
  let fakeShard := System.FilePath.mk tmpRoot / "checkouts" / fakeHash16
  IO.FS.createDirAll fakeShard
  let _ ← IO.Process.output { cmd := "cp", args := #["-a", symSeedDir.toString, (fakeShard / s!"seed-{symCommit}").toString] }
  let escBytes := "owned".toUTF8
  let escSha := bytesToHexLower (sha256Bytes escBytes)
  let escBundle := JVal.obj #[
    ("repo", .str fakeRepoUrl),
    ("commit", .str symCommit),
    ("bundle", .obj #[
      ("complete", .bool false),
      ("manifest_sha256", .str (bundleManifestSha256 #[("escape/pwn.txt", escSha)] false)),
      ("files", .arr #[.obj #[
        ("path", .str "escape/pwn.txt"),
        ("sha256", .str escSha),
        ("data_base64", .str (base64Encode escBytes false true))
      ]])
    ])
  ]
  let escRes ← materializeLeanCheckout tmpRoot escBundle (s!"{tmpRoot}/logs/esc.log") (some "esc-job")
  let pwnExists ← (outsideVictimDir / "pwn.txt").pathExists
  check "materializeLeanCheckout rejects source-bundle write through symlinked ancestor directory"
    ((match escRes with | .error _ => true | .ok _ => false) && !pwnExists)

  -- 11. `PUT /managed-auth/antigravity` + live HTTP `POST /project-context/prepare` sync
  let agCred := renderCompact (.obj #[
    ("access_token", .str "tok-a"),
    ("refresh_token", .str "tok-r"),
    ("expires_at", JVal.int 1900000000000)
  ])
  let (rt20, rAg) ← handleRequest rt {
    method := "PUT", rawPath := "/managed-auth/antigravity?slot=slot1",
    path := "/managed-auth/antigravity",
    query := #[("slot", "slot1")], headers := authHdrs, body := agCred.toUTF8
  }
  rt := rt20
  let .ok agJson := OrbBin.Json.parse (String.fromUTF8! rAg.body)
    | throw (IO.userError "antigravity auth invalid JSON")
  check "PUT /managed-auth/antigravity provisions 0600 default + slot1"
    (rAg.status == 200 && ((agJson.fieldArr? "managed_auth").getD #[]).size == 2)

  -- Spin up an ephemeral local HTTP context server on `127.0.0.1:19489` serving `GET .../manifest` & `GET .../blobs/<sha>`
  let ctxBlobBytes := "synced-context-guide".toUTF8
  let ctxBlobHash := bytesToHexLower (sha256Bytes ctxBlobBytes)
  let ctxManifestWire := renderCompact (.obj #[
    ("revision", JVal.uint64 3),
    ("entries", .obj #[
      ("GUIDE.md", .obj #[
        ("hash", .str ctxBlobHash),
        ("directory", .bool false),
        ("revision", JVal.uint64 3),
        ("size", JVal.uint64 ctxBlobBytes.size.toUInt64)
      ])
    ])
  ])
  let mockLfd ← OrbNode.Posix.tcpListen "127.0.0.1" 19489
  let mockTask ← IO.asTask do
    for _ in [0:2] do
      let cfd ← OrbNode.Posix.tcpAccept mockLfd 3000
      if cfd != 0xFFFFFFFF then
        if let .ok mreq ← OrbNode.Server.readHttpRequest cfd then
          if mreq.path.endsWith "/manifest" then
            discard <| OrbNode.Posix.fdWriteAll cfd
              (OrbNode.Server.encodeHttpResponse { status := 200, contentType := "application/json", body := ctxManifestWire.toUTF8 })
          else if mreq.path.endsWith s!"/blobs/{ctxBlobHash}" then
            discard <| OrbNode.Posix.fdWriteAll cfd
              (OrbNode.Server.encodeHttpResponse { status := 200, contentType := "application/octet-stream", body := ctxBlobBytes })
          else
            discard <| OrbNode.Posix.fdWriteAll cfd (OrbNode.Server.encodeHttpResponse (OrbNode.Server.textResp 404 "not found"))
        OrbNode.Posix.fdClose cfd
    OrbNode.Posix.fdClose mockLfd
  let (_, rPc) ← handleRequest rt {
    method := "POST", rawPath := "/project-context/prepare", path := "/project-context/prepare",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[
      ("endpoint", .str "http://127.0.0.1:19489"),
      ("token", .str "tok-pc"),
      ("project", .str "demo")
    ])).toUTF8
  }
  let _ ← IO.wait mockTask
  let .ok pcJson := OrbBin.Json.parse (String.fromUTF8! rPc.body)
    | throw (IO.userError "project-context prepare invalid JSON")
  let pcRoot := (pcJson.fieldStr? "root").getD ""
  let guideText ← if ← (System.FilePath.mk pcRoot / "GUIDE.md").pathExists then
    IO.FS.readFile (System.FilePath.mk pcRoot / "GUIDE.md")
  else pure ""
  let pcManifest? := pcJson.field? "manifest"
  check "POST /project-context/prepare syncs remote manifest + blob and returns {root, manifest: {revision, entries}}"
    (rPc.status == 200 &&
     guideText == "synced-context-guide" &&
     (pcManifest?.bind (·.fieldUInt64? "revision")).isSome &&
     (pcManifest?.bind (·.field? "entries") >>= JVal.asObj?).isSome)

  -- 12. Round-2 regression checks
  rt ← runRound2RegressionTests check tmpRoot missionId submitLease nowEp authHdrs rt

  -- 13. Round-3 regression checks
  rt ← runRound3RegressionTests check tmpRoot missionId nowEp authHdrs rt

  -- 14. R2-B (`SM-02`) typed authority/placement/supersession/orphan/disk columns + `state_revision` CAS on `OrbNode.Store`
  let casRoot := s!"{tmpRoot}/r2b-cas-ledger"
  let .ok l0 ← OrbNode.Store.openLedger casRoot
    | throw (IO.userError "openLedger failed on r2b-cas-ledger")
  let seedJob : OrbNode.Store.JobRecord := {
    jobId := "job-r2b-1"
    missionId := missionId
    payloadJson := "{}"
    state := .queued
    createdAt := "2026-11-06T00:00:00Z"
    authorityMode := "readonly"
    placementKind := "client"
    reservedDiskGib := 24
    stateRevision := 1
  }
  let .ok l1 ← l0.insertQueued seedJob
    | throw (IO.userError "insertQueued failed on job-r2b-1")
  let .ok (l2, jAfterCas) ← l1.updateJobAuthorityCas "job-r2b-1" 1 "writer" "managed" "m-super-9" "" 0
    | throw (IO.userError "valid updateJobAuthorityCas rejected")
  let staleNodeCas ← l2.updateJobAuthorityCas "job-r2b-1" 1 "readonly" "client" "" "2026-11-06T00:01:00Z" 24
  let badModeCas ← l2.updateJobAuthorityCas "job-r2b-1" jAfterCas.stateRevision "invalid_mode" "managed" "" "" 0
  -- Transition `job-r2b-1` to terminal `succeeded` with reserved_disk_gib=8, then run post-terminal `updateJobAuthorityCas`
  -- to release `reserved_disk_gib` -> 0 and set `orphaned_at`, verifying `jobs.db` SQLite row reflects the post-terminal CAS!
  let .ok (l3, jTerm) ← l2.updateJob "job-r2b-1" (fun r => .ok {
    r with state := .succeeded, exitCode? := some 0, finishedAt? := some "2026-11-06T00:02:00Z", reservedDiskGib := 8
  }) | throw (IO.userError "terminal updateJob failed on job-r2b-1")
  let .ok (_l4, jPostTermCas) ← l3.updateJobAuthorityCas "job-r2b-1" jTerm.stateRevision "writer" "managed" "m-super-post" "2026-11-06T00:03:00Z" 0
    | throw (IO.userError "post-terminal updateJobAuthorityCas failed on job-r2b-1")
  let sqliteRowOut ← IO.Process.output {
    cmd := "python3"
    args := #["-c",
      "import sqlite3, sys; conn = sqlite3.connect(sys.argv[1]); r = conn.execute(\"SELECT state, COALESCE(CAST(exit_code AS TEXT),''), superseded_by_mission_id, orphaned_at, reserved_disk_gib, state_revision FROM jobs WHERE id='job-r2b-1'\").fetchone(); print('|'.join(str(x) for x in r) if r else '')",
      (System.FilePath.mk casRoot / "jobs.db").toString]
  }
  let sqliteRowTrim := sqliteRowOut.stdout.trimAscii.toString
  let .ok lReopened ← OrbNode.Store.openLedger casRoot
    | throw (IO.userError "reopen openLedger failed on r2b-cas-ledger")
  let reopenedJob? := lReopened.jobs.get? "job-r2b-1"
  check "SM-02 OrbNode.Store persists typed columns and post-terminal CAS into jobs.db while rejecting stale state_revision"
    (jAfterCas.stateRevision == 2 &&
     jAfterCas.authorityMode == "writer" &&
     jAfterCas.supersededById == "m-super-9" &&
     jAfterCas.reservedDiskGib == 0 &&
     !staleNodeCas.isOk &&
     !badModeCas.isOk &&
     jPostTermCas.state == .succeeded &&
     jPostTermCas.stateRevision == 4 &&
     sqliteRowTrim == "succeeded|0|m-super-post|2026-11-06T00:03:00Z|0|4" &&
     reopenedJob?.map (·.supersededById) == some "m-super-post" &&
     reopenedJob?.map (·.reservedDiskGib) == some 0 &&
     reopenedJob?.map (·.stateRevision) == some 4)
  let httpAuthJobId := "77777777-7777-4777-8777-777777777777"
  let httpAuthBody := renderCompact (.obj #[
    ("job_id", .str httpAuthJobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("authority_mode", .str "readonly"),
    ("placement_kind", .str "client"),
    ("reserved_disk_gib", JVal.uint64 12),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str "true"),
      ("long_running", .bool true)
    ])
  ])
  let (rtHttpAuth, rHttpAuth) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := httpAuthBody.toUTF8
  }
  rt := rtHttpAuth
  let storedHttpJob? := rt.ledger.jobs.get? httpAuthJobId
  check "POST /jobs persists typed authority_mode, placement_kind, and reserved_disk_gib"
    (rHttpAuth.status == 202 &&
     storedHttpJob?.map (·.authorityMode) == some "readonly" &&
     storedHttpJob?.map (·.placementKind) == some "client" &&
     storedHttpJob?.map (·.reservedDiskGib) == some 12)
  let wrapDiskJobId := "88888888-8888-4888-8888-888888888888"
  let wrapDiskJobBody := renderCompact (.obj #[
    ("job_id", .str wrapDiskJobId),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("authority_mode", .str "readonly"),
    ("reserved_disk_gib", .num "17179869185"),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str "true"),
      ("long_running", .bool true)
    ])
  ])
  let (rtWrapJob, rWrapJob) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := wrapDiskJobBody.toUTF8
  }
  rt := rtWrapJob
  check "POST /jobs rejects >512 GiB / 2^34 wraparound reserved_disk_gib with 422"
    (rWrapJob.status == 422 && !rt.ledger.jobs.contains wrapDiskJobId)

  -- Shared Library skills archive retention (`Orb.Kernel.uploadCleanupGate`) & adaptive fast poll (`Orb.Kernel.fastPollDelayMs`)
  let libUid ← newUuidV4
  let attUid ← newUuidV4
  let libDir := System.FilePath.mk tmpRoot / "uploads" / libUid
  let attDir := System.FilePath.mk tmpRoot / "uploads" / attUid
  IO.FS.createDirAll libDir
  IO.FS.createDirAll attDir
  IO.FS.writeFile (libDir / "library-skills-0123456789abcdef.tar.gz") "skills-tarball"
  IO.FS.writeFile (attDir / "screenshot.png") "temp-attachment"
  let removedPerJob ← cleanupUploadDirectories tmpRoot #[libUid, attUid, "../escape"] false
  check "cleanupUploadDirectories retains shared library-skills-*.tar.gz across per-job cleanup while removing prompt attachments"
    (removedPerJob == 1 &&
     (← (libDir / "library-skills-0123456789abcdef.tar.gz").pathExists) &&
     !(← (attDir / "screenshot.png").pathExists) &&
     !shouldCleanupUploadEntry "../escape" "screenshot.png" true &&
     !isSharedLibrarySkillsArchive "library-skills-../evil.tar.gz")
  let removedTtl ← cleanupUploadDirectories tmpRoot #[libUid] true
  check "cleanupUploadDirectories reaps shared library-skills-*.tar.gz once TTL expired"
    (removedTtl == 1 && !(← (libDir / "library-skills-0123456789abcdef.tar.gz").pathExists))
  check "computeFastPollDelayMs matches adaptive burst cadence (80 -> 200 -> 500 -> backoff)"
    (computeFastPollDelayMs false 500 0 == 80 &&
     computeFastPollDelayMs false 4000 0 == 200 &&
     computeFastPollDelayMs false 15000 0 == 500 &&
     computeFastPollDelayMs true 500 0 == 500 &&
     computeFastPollDelayMs false 500 2 == 2000 &&
     computeFastPollDelayMs false 500 5 == 5000)

  let sm20Root := (System.FilePath.mk tmpRoot / "sm20-remote-node").toString
  IO.FS.createDirAll sm20Root
  let .ok l20a ← OrbNode.Store.openLedger sm20Root
    | throw (IO.userError "openLedger sm20 a failed")
  let epochA := l20a.nodeBootEpoch
  let sm20JobId := "99999999-9999-4999-8999-999999999999"
  let sm20MissionId := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  let (sm20ScratchDir, sm20Receipt) ← match ← createScratchDirAndReceipt sm20Root sm20JobId sm20MissionId (some sm20JobId) with
    | .ok pair => pure pair
    | .error e => throw (IO.userError s!"createScratchDirAndReceipt failed: {e}")
  let sm20Rec : JobRecord := {
    jobId := sm20JobId
    missionId := sm20MissionId
    payloadJson := "{\"kind\":\"raw_command\"}"
    state := .queued
    createdAt := "2026-11-07T00:00:00Z"
    operationId := sm20JobId
    nodeBootEpoch := epochA
    phaseCode := 1
  }
  let .ok l20b ← l20a.insertQueued sm20Rec (some sm20Receipt)
    | throw (IO.userError "SM-20 insertQueued failed")
  let dupIns ← l20b.insertQueued sm20Rec (some sm20Receipt)
  let .ok l20c ← openLedger sm20Root
    | throw (IO.userError "reopen sm20 ledger failed")
  let epochB := l20c.nodeBootEpoch
  let reopened20? := l20c.jobs.get? sm20JobId
  let staleClaim ← l20c.insertQueued { sm20Rec with jobId := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", operationId := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", nodeBootEpoch := epochA }
  let crossBootReconcile ← l20c.stepJobClaim sm20JobId 7 sm20JobId epochB "2026-11-07T00:00:30Z"
  let sm20LiveId := "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  let .ok l20live0 ← l20c.insertQueued {
    sm20Rec with
    jobId := sm20LiveId
    operationId := "op-sm20-1"
    nodeBootEpoch := epochB
  } | throw (IO.userError "SM-20 live insertQueued failed")
  let .ok (l20unc, recUnc) ← l20live0.stepJobClaim sm20LiveId 1 "op-sm20-1" epochB "2026-11-07T00:00:45Z"
    | throw (IO.userError "markUncertain failed")
  let blindRetry ← l20unc.stepJobClaim sm20LiveId 5 "op-sm20-1" epochB "2026-11-07T00:00:50Z"
  let sameOpRetry ← l20unc.stepJobClaim sm20LiveId 10 "op-sm20-1" epochB "2026-11-07T00:00:55Z"
  let .ok (l20d, recRetry) ← l20unc.stepJobClaim sm20LiveId 10 "op-sm20-2" epochB "2026-11-07T00:01:00Z"
    | throw (IO.userError "confirmNotDeliveredRetry failed")
  let .ok (l20unc2, _) ← l20d.stepJobClaim sm20LiveId 1 "op-sm20-2" epochB "2026-11-07T00:01:30Z"
    | throw (IO.userError "second markUncertain failed")
  let .ok (_l20e, recSucc) ← l20unc2.stepJobClaim sm20LiveId 7 "op-sm20-2" epochB "2026-11-07T00:02:00Z"
    | throw (IO.userError "reconcileSucceeded failed")
  let lateCancel ← _l20e.stepJobClaim sm20LiveId 4 "op-sm20-2" epochB "2026-11-07T00:02:30Z"
  let scratchBefore ← l20d.getScratchReceipt? sm20Receipt.id
  let some parentId ← readPathIdentity? (System.FilePath.mk sm20Root / ".scratch").toString
    | throw (IO.userError "read parent identity failed")
  let some dirId ← readPathIdentity? sm20ScratchDir
    | throw (IO.userError "read dir identity failed")
  let mismatchRetire ← l20d.retireScratchReceipt sm20Receipt.id "0:0" dirId "2026-11-07T00:04:00Z"
  let retiredOk ← retireScratchOutsideLedger sm20Root l20d.sqliteBackend sm20Receipt.id sm20ScratchDir
    sm20Receipt.nodeBootEpoch sm20Receipt.claimSeq
  let recreateDir := sm20ScratchDir
  IO.FS.createDirAll recreateDir
  let recreateMarker := (System.FilePath.mk recreateDir / "recreated.txt").toString
  IO.FS.writeFile recreateMarker "kept"
  let secondRetire ← retireScratchOutsideLedger sm20Root l20d.sqliteBackend sm20Receipt.id recreateDir
    sm20Receipt.nodeBootEpoch sm20Receipt.claimSeq
  let recreateKept ← (System.FilePath.mk recreateMarker).pathExists
  let foreignRetire ← retireScratchOutsideLedger sm20Root l20d.sqliteBackend sm20Receipt.id recreateDir
    (sm20Receipt.nodeBootEpoch + 1) sm20Receipt.claimSeq
  let foreignKept ← (System.FilePath.mk recreateMarker).pathExists
  let cliScratchId := "99999999-9999-4999-8999-999999999990"
  let (cliScratchDir, cliReceipt) ← match ← createScratchDirAndReceipt sm20Root cliScratchId sm20MissionId
      (some cliScratchId) epochB 77 with
    | .ok pair => pure pair
    | .error e => throw (IO.userError s!"createScratchDirAndReceipt cli failed: {e}")
  let .ok () ← l20d.persistScratchReceipt cliReceipt
    | throw (IO.userError "persistScratchReceipt cli failed")
  let cliRetireWrongSeq ← retireScratchOutsideLedger sm20Root .cli cliScratchId cliScratchDir epochB 78 true
  let cliStillExists ← (System.FilePath.mk cliScratchDir).pathExists
  let cliRetireOk ← retireScratchOutsideLedger sm20Root .cli cliScratchId cliScratchDir epochB 77 true
  let cliRemoved := !(← (System.FilePath.mk cliScratchDir).pathExists)
  IO.FS.createDirAll cliScratchDir
  let cliRecreateMarker := (System.FilePath.mk cliScratchDir / "cli-kept.txt").toString
  IO.FS.writeFile cliRecreateMarker "kept"
  let cliSecondRetire ← retireScratchOutsideLedger sm20Root .cli cliScratchId cliScratchDir epochB 77 true
  let cliRecreateKept ← (System.FilePath.mk cliRecreateMarker).pathExists
  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", recreateDir, cliScratchDir] }
  let scratchAfter ← l20d.getScratchReceipt? sm20Receipt.id
  let .ok () ← l20d.upsertContainerLeader {
    workspaceId := "ws-sm20"
    machineName := "small-a"
    leaderPid := 4242
    startTicks := 999001
    nodeBootEpoch := epochB
    procPhase := 1
    jobId := sm20JobId
    updatedAt := "2026-11-07T00:05:00Z"
  } | throw (IO.userError "upsertContainerLeader failed")
  let selfPid ← (IO.Process.output { cmd := "bash", args := #["-lc", "echo $PPID"] }).toBaseIO
  let selfPidN := match selfPid with
    | .ok o => (o.stdout.trimAscii.toString.toNat?).getD 0
    | .error _ => 0
  let selfSample ← sampleProcLiveness selfPidN.toUInt64
  let .ok () ← l20d.upsertContainerLeader {
    workspaceId := "ws-sm20"
    machineName := "live-self"
    leaderPid := selfPidN.toUInt32
    startTicks := selfSample.actualTicks
    nodeBootEpoch := epochB
    procPhase := 1
    jobId := sm20LiveId
    updatedAt := "2026-11-07T00:05:01Z"
  } | throw (IO.userError "upsert live ContainerLeader failed")
  let .ok leaders ← l20d.listContainerLeaders
    | throw (IO.userError "listContainerLeaders failed")
  let leader0? := leaders[0]?
  let liveResolved ← resolveLiveContainerLeaders l20d "ws-sm20"
  let .ok leadersAfterResolve ← l20d.listContainerLeaders
    | throw (IO.userError "listContainerLeaders after resolve failed")
  let staleAfter? := leadersAfterResolve.find? (fun r => r.machineName == "small-a")
  let pgrpSpawn ← IO.Process.spawn {
    cmd := "setsid"
    args := #["sleep", "30"]
    stdin := .null
    stdout := .null
    stderr := .null
  }
  let pgrpPid := pgrpSpawn.pid.toUInt64
  IO.sleep 30
  let pgrpSample ← sampleProcLiveness pgrpPid
  let reusedKill ← terminateVerifiedPgrp 1 pgrpPid (pgrpSample.actualTicks + 99)
  let pgrpStillAlive ← sampleProcLiveness pgrpPid
  let realKill ← terminateVerifiedPgrp 1 pgrpPid pgrpSample.actualTicks
  discard <| pgrpSpawn.wait
  let parsedSample := parseProcStatLiveness s!"{selfPidN} (self test) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 {selfSample.actualTicks} 0 0"
  let aliveStep ← stepVerifiedPgrpOp 1 0 selfPidN.toUInt64 selfSample.actualTicks (some selfSample)
  let deadStep ← stepVerifiedPgrpOp 1 2 selfPidN.toUInt64 (selfSample.actualTicks + 7) (some selfSample)
  let zombieSample : ProcLivenessSample := { procMissing := 0, isZombie := 1, actualPid := 77, actualTicks := 55 }
  let zombieObsAlive ← stepVerifiedPgrpOp 1 1 77 55 (some zombieSample)
  let zombieKill ← stepVerifiedPgrpOp 3 3 77 55 (some zombieSample)
  let zombieObsDead ← stepVerifiedPgrpOp 3 1 77 55 (some zombieSample)
  let zombieObsKillSent ← stepVerifiedPgrpOp 4 1 77 55 (some zombieSample)
  let missingSample : ProcLivenessSample := { procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0 }
  let missingTerm ← terminateVerifiedPgrp 1 88 12 (some missingSample)
  let unsampledSample : ProcLivenessSample := {
    procMissing := 1, isZombie := 0, actualPid := 0, actualTicks := 0, bootId := ""
  }
  let unsampledSignal ← stepVerifiedPgrpOp 1 2 selfPidN.toUInt64 selfSample.actualTicks (some unsampledSample) selfSample.bootId
  let bootMismatchSample : ProcLivenessSample := { selfSample with bootId := "deadbeef-boot-id" }
  let bootMismatchSignal ← stepVerifiedPgrpOp 1 2 selfPidN.toUInt64 selfSample.actualTicks
    (some bootMismatchSample) selfSample.bootId
  let selfStillAlive ← sampleProcLiveness selfPidN.toUInt64
  let (stExec, execVal) ← runSyncExecute rt missionId "sleep 0.2" true (some unsampledSample)
  let execAccepted := (execVal.fieldBool? "accepted").getD false
  let execCode := (execVal.fieldInt? "exit_code").getD (-1)
  let bOutMissing ← runBoundedOutput {
    cmd := "setsid"
    args := #["true"]
  } none true syncExecOutputCapBytes (some unsampledSample)
  let sigintZeroTicks ← sigintInflightChildTools selfPidN.toUInt64 none 0 selfSample.bootId
  let sigintBadBoot ← sigintInflightChildTools selfPidN.toUInt64 none selfSample.actualTicks "deadbeef-boot-id"
  let failSpawnJob := "ffffffff-ffff-4fff-8fff-ffffffffffff"
  let failRec : JobRecord := {
    jobId := failSpawnJob
    missionId := missionId
    payloadJson := "{\"kind\":\"raw_command\",\"command\":\"sleep 30\",\"long_running\":true}"
    state := .queued
    createdAt := "2026-11-07T00:07:00Z"
    operationId := failSpawnJob
    nodeBootEpoch := rt.ledger.nodeBootEpoch
    phaseCode := 1
  }
  let rtFail0 := {
    rt with
    ledger := { rt.ledger with jobs := rt.ledger.jobs.insert failSpawnJob failRec, order := rt.ledger.order.push failSpawnJob }
  }
  let failPrep : PreparedJobSpec := {
    jid := failSpawnJob
    prog := "/bin/sleep"
    args := #["30"]
    envKv := #[]
    cwd := tmpRoot
    logPath := (System.FilePath.mk tmpRoot / "fail-spawn.log").toString
    artifacts := #[]
    timeoutSecs? := none
    forced := false
    sideLane := false
    coordLane := false
    isolatedCheckout := none
    systemdScope? := none
    scratchDir? := none
    machineName? := none
    workspaceId := ""
  }
  let rtFail1 ← commitPreparedJob rtFail0 failSpawnJob (.ok failPrep) (some unsampledSample)
  let failUnsampled? := rtFail1.ledger.jobs.get? failSpawnJob
  if let some fu := failUnsampled? then
    if fu.pid > 1 then
      let cleanupSample ← sampleProcLiveness fu.pid
      if cleanupSample.actualTicks != 0 then
        discard <| terminateVerifiedPgrp 1 fu.pid cleanupSample.actualTicks none cleanupSample.bootId
      discard <| OrbNode.Posix.pollPid fu.pid
  let failLedgerJob := "ffffffff-ffff-4fff-8fff-fffffffffff0"
  let rtFail2 := {
    rtFail1 with
    ledger := {
      rtFail1.ledger with
      jobs := rtFail1.ledger.jobs.insert failLedgerJob { failRec with jobId := failLedgerJob, operationId := failLedgerJob }
      order := rtFail1.ledger.order.push failLedgerJob
    }
  }
  let failPrep2 : PreparedJobSpec := { failPrep with jid := failLedgerJob }
  let rtFail3 ← commitPreparedJob rtFail2 failLedgerJob (.ok failPrep2) none (some "simulated_sqlite_lock")
  IO.sleep 60
  let failLedger? := rtFail3.ledger.jobs.get? failLedgerJob
  if let some fl := failLedger? then
    if fl.pid > 1 then
      discard <| OrbNode.Posix.pollPid fl.pid
  let failLedgerDeadSample ← match failLedger? with
    | some fl => if fl.pid > 1 then sampleProcLiveness fl.pid else pure unsampledSample
    | none => pure unsampledSample
  let sm20Body := renderCompact (.obj #[
    ("job_id", .str "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
    ("mission_id", .str missionId),
    ("lease_token", .str submitLease),
    ("operation_id", .str "op-http-sm20"),
    ("node_boot_epoch", JVal.uint64 rt.ledger.nodeBootEpoch),
    ("workspace_id", .str "ws-http-sm20"),
    ("machine_name", .str "nspawn-http-a"),
    ("leader_pid", JVal.uint64 selfPidN.toUInt64),
    ("start_ticks", JVal.uint64 selfSample.actualTicks),
    ("payload", .obj #[
      ("kind", .str "raw_command"),
      ("command", .str "sleep 10"),
      ("long_running", .bool true)
    ])
  ])
  let (rtSm20, rSm20) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := sm20Body.toUTF8
  }
  rt := rtSm20
  let httpSm20? := rt.ledger.jobs.get? "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  let httpScratch? ← rt.ledger.getScratchReceipt? "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  let httpLeaders ← resolveLiveContainerLeaders rt.ledger "ws-http-sm20"
  let staleRunId := "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
  let staleRec : JobRecord := {
    jobId := staleRunId
    missionId := missionId
    payloadJson := "{\"kind\":\"raw_command\",\"command\":\"echo should_not_run\"}"
    state := .queued
    createdAt := "2026-11-07T00:06:00Z"
    operationId := staleRunId
    nodeBootEpoch := rt.ledger.nodeBootEpoch + 99
    phaseCode := 1
  }
  let rtInjected := {
    rt with
    ledger := { rt.ledger with jobs := rt.ledger.jobs.insert staleRunId staleRec, order := rt.ledger.order.push staleRunId }
    queueOrder := rt.queueOrder.push staleRunId
  }
  let rtAfterTick ← tickRuntime rtInjected
  let staleAfterTick? := rtAfterTick.ledger.jobs.get? staleRunId
  let reconcileBody := renderCompact (.obj #[
    ("op_code", JVal.nat 4),
    ("operation_id", .str "op-http-sm20"),
    ("node_boot_epoch", JVal.uint64 rt.ledger.nodeBootEpoch)
  ])
  let (rtSm20b, rReconcile) ← handleRequest rt {
    method := "POST", rawPath := "/jobs/cccccccc-cccc-4ccc-8ccc-cccccccccccc/reconcile",
    path := "/jobs/cccccccc-cccc-4ccc-8ccc-cccccccccccc/reconcile",
    query := #[], headers := authHdrs, body := reconcileBody.toUTF8
  }
  rt := rtSm20b
  if let some lpHttp := rt.liveProcs.get? "cccccccc-cccc-4ccc-8ccc-cccccccccccc" then
    if lpHttp.startTicks != 0 then
      discard <| terminateVerifiedPgrp lpHttp.procPhase lpHttp.pid lpHttp.startTicks none lpHttp.bootId
    discard <| OrbNode.Posix.pollPid lpHttp.pid
    rt := { rt with liveProcs := rt.liveProcs.erase "cccccccc-cccc-4ccc-8ccc-cccccccccccc" }
  let reconciled? := rt.ledger.jobs.get? "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  check "SM-20 scratch claim-retire transaction (.python3 & .cli) preserves recreated path and fences epoch/seq"
    (scratchBefore.isSome &&
     !parentId.isEmpty &&
     !mismatchRetire.isOk &&
     retiredOk &&
     (scratchAfter.bind (·.retiredAt?)).isSome &&
     !(← (System.FilePath.mk sm20ScratchDir).pathExists) &&
     secondRetire && recreateKept && !foreignRetire && foreignKept &&
     !cliRetireWrongSeq && cliStillExists && cliRetireOk && cliRemoved && cliSecondRetire && cliRecreateKept)
  check "SM-20 unsampled/boot_id/post-spawn/runBoundedOutput proc liveness fail-closed gates"
    (!unsampledSignal.2 && !bootMismatchSignal.2 &&
     selfStillAlive.procMissing == 0 && selfStillAlive.actualTicks == selfSample.actualTicks &&
     stExec == 200 && execAccepted && execCode == 0 &&
     bOutMissing.exitCode == 0 && sigintZeroTicks == 0 && sigintBadBoot == 0 &&
     failUnsampled?.map (·.state) == some .failed &&
     (failUnsampled?.bind (·.error?)).any (fun e => e.startsWith "proc_liveness_unsampled:") &&
     failLedger?.map (·.state) == some .failed &&
     (failLedger?.bind (·.error?)).any (fun e => e.startsWith "post_spawn_ledger_update_failed:") &&
     (failLedgerDeadSample.procMissing == 1 || failLedgerDeadSample.isZombie == 1))
  check "SM-20 durable job claims, boot-epoch loss, scratch identity, and proc liveness gates"
    (epochB == epochA + 1 &&
     !dupIns.isOk &&
     reopened20?.map (·.state) == some .lost &&
     reopened20?.map (·.phaseCode) == some 2 &&
     !staleClaim.isOk &&
     !crossBootReconcile.isOk &&
     recUnc.state == .lost &&
     recUnc.phaseCode == 2 &&
     !blindRetry.isOk &&
     !sameOpRetry.isOk &&
     recRetry.state == .queued &&
     recRetry.phaseCode == 1 &&
     recRetry.operationId == "op-sm20-2" &&
     recSucc.state == .succeeded &&
     recSucc.phaseCode == 3 &&
     !lateCancel.isOk &&
     leader0?.map (·.leaderPid) == some 4242 &&
     leader0?.map (·.startTicks) == some 999001 &&
     liveResolved.size == 1 &&
     liveResolved[0]?.map (·.machineName) == some "live-self" &&
     staleAfter?.map (·.procPhase) == some 2 &&
     pgrpSample.procMissing == 0 &&
     reusedKill == 2 &&
     pgrpStillAlive.procMissing == 0 &&
     pgrpStillAlive.actualTicks == pgrpSample.actualTicks &&
     (realKill == 2 || realKill == 4) &&
     selfSample.procMissing == 0 &&
     selfSample.actualPid == selfPidN.toUInt32 &&
     parsedSample.actualTicks == selfSample.actualTicks &&
     aliveStep.2 &&
     !deadStep.2 &&
     zombieObsAlive.1 == 2 &&
     zombieObsAlive.2 &&
     !zombieKill.2 &&
     zombieObsDead.1 == 2 &&
     zombieObsDead.2 &&
     zombieObsKillSent.1 == 2 &&
     zombieObsKillSent.2 &&
     missingTerm == 2 &&
     rSm20.status == 202 &&
     httpSm20?.map (·.operationId) == some "op-http-sm20" &&
     httpSm20?.map (·.nodeBootEpoch) == some rt.ledger.nodeBootEpoch &&
     httpScratch?.isSome == true &&
     httpLeaders.size == 1 &&
     httpLeaders[0]?.map (·.machineName) == some "nspawn-http-a" &&
     staleAfterTick?.map (·.state) == some .lost &&
     staleAfterTick?.map (·.phaseCode) == some 2 &&
     rReconcile.status == 200 &&
     reconciled?.map (·.state) == some .cancelled &&
     reconciled?.map (·.phaseCode) == some 5)

  runChildToolSigintAnchorRegressionTests check

  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpRoot] }
  let passed ← passedRef.get
  IO.println s!"OrbNode self-test: {passed}/{passed} assertions PASSED"
  return 0

end OrbNode.SelfTest

def main (args : List String) : IO UInt32 := do
  if args.head? == some "--sandboxed-scope-exec-cleared-env" then
    OrbNode.Main.runCli args
  else
    OrbNode.SelfTest.runTests
