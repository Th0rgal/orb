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
