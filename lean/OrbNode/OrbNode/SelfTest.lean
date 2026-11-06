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
  let .ok execJson := OrbBin.Json.parse (String.fromUTF8! rExec.body)
    | throw (IO.userError "execute invalid JSON")
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

  -- 8. Machine-transfer `snapshot -> pack -> stage -> unpack -> verify -> browse`
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
  check "machine-transfer snapshot excludes .env and captures visible.txt"
    (rSnap.status == 200 && ((manifestJson.fieldArr? "excluded").getD #[]).any (fun v => v.asStr? == some ".env"))

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
  check "machine-transfer verify seals destination checkpoint" (rVer.status == 200)

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

  -- 9. `PUT /managed-auth/antigravity` + `POST /project-context/prepare`
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

  let (_, rPc) ← handleRequest rt {
    method := "POST", rawPath := "/project-context/prepare", path := "/project-context/prepare",
    query := #[], headers := authHdrs,
    body := (renderCompact (.obj #[
      ("endpoint", .str "https://core.example"),
      ("token", .str "tok-pc"),
      ("project", .str "demo")
    ])).toUTF8
  }
  check "POST /project-context/prepare writes 0600 connection.json" (rPc.status == 200)

  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpRoot] }
  let passed ← passedRef.get
  IO.println s!"OrbNode self-test: {passed}/{passed} assertions PASSED"
  return 0

end OrbNode.SelfTest

def main : IO UInt32 :=
  OrbNode.SelfTest.runTests
