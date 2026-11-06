/-
  OrbNode.SelfTest: End-to-End Verification Suite for Wave 2 `sandboxed-node` (`OrbNode`).
-/
import OrbBin.Json
import OrbNode.Spec
import OrbNode.MutantSuite
import OrbNode.Posix
import OrbNode.Lease
import OrbNode.Store
import OrbNode.Runner
import OrbNode.Server
import OrbNode.Main

open OrbBin.Json
open OrbNode.Spec
open OrbNode.MutantSuite
open OrbNode.Lease
open OrbNode.Store
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
  let submitLease := signLeaseToken "sec-primary-123" {
    missionId := "11111111-1111-4111-8111-111111111111"
    nodeId := "test-node"
    scope := .jobSubmit
    expiresAt := nowEp + 600
  }
  match verifyLeaseToken submitLease "sec-primary-123" none "test-node" .jobSubmit nowEp none with
  | .ok cl => check "lease verify mission_id" (cl.missionId == "11111111-1111-4111-8111-111111111111")
  | .error e => throw (IO.userError s!"unexpected lease verify error: {e}")

  -- 3. Reload unit confinement
  check "reload unit accepts default" (validateReloadUnit "sandboxed-node")
  check "reload unit rejects arbitrary unit" (!validateReloadUnit "sshd")

  -- 4. Bounded newline-cut log slicer
  let multiLine := "alpha\nbeta\ngamma\n".toUTF8
  let sl := sliceJobLogBytes multiLine 0 9
  check "log slice cuts at newline before mid-line EOF" (sl.data == "alpha\n" && sl.nextOffset == 6)

  -- 5. Durable Store + Crash Recovery + HTTP Handler E2E
  let randN ← IO.rand 100000 999999
  let tmpRoot := s!"/tmp/orb-node-selftest-{randN}-{nowEp}"
  IO.FS.createDirAll tmpRoot
  let .ok l0 ← openLedger tmpRoot
    | throw (IO.userError "openLedger l0 failed")
  let crashRec : JobRecord := {
    jobId := "22222222-2222-4222-8222-222222222222"
    missionId := "11111111-1111-4111-8111-111111111111"
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

  let cfg : NodeConfig := {
    nodeId := "test-node"
    token := "sec-primary-123"
    tokenPrevious? := some "sec-old-456"
    workDir := tmpRoot
    capacityTotal := 2
    minFreeDiskBytes := 0
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

  -- POST /execute -> 200
  let execLease := signLeaseToken "sec-primary-123" {
    missionId := "11111111-1111-4111-8111-111111111111"
    nodeId := "test-node"
    scope := .missionExecute
    expiresAt := nowEp + 600
  }
  let execBody := renderCompact (.obj #[
    ("mission_id", .str "11111111-1111-4111-8111-111111111111"),
    ("node_id", .str "test-node"),
    ("lease_token", .str execLease),
    ("command", .str "printf 'exec-ok'")
  ])
  let (rt4, rExec) ← handleRequest rt {
    method := "POST", rawPath := "/execute", path := "/execute",
    query := #[], headers := authHdrs, body := execBody.toUTF8
  }
  rt := rt4
  let .ok execJson := OrbBin.Json.parse (String.fromUTF8! rExec.body)
    | throw (IO.userError "execute invalid JSON")
  check "POST /execute runs command cleanly"
    (rExec.status == 200 && execJson.fieldStr? "stdout" == some "exec-ok")

  -- POST /jobs (lean_build with bundle + artifact SHA-256) -> 202 -> poll to succeeded + GET /jobs/:id/log
  let jobId := "33333333-3333-4333-8333-333333333333"
  let jobBody := renderCompact (.obj #[
    ("job_id", .str jobId),
    ("mission_id", .str "11111111-1111-4111-8111-111111111111"),
    ("lease_token", .str submitLease),
    ("payload", .obj #[
      ("kind", .str "lean_build"),
      ("source", .obj #[
        ("repo", .str "local"),
        ("commit", .str "deadbeef"),
        ("bundle", .obj #[
          ("manifest_sha256", .str "00"),
          ("files", .arr #[.obj #[
            ("path", .str "hello.txt"),
            ("sha256", .str "00"),
            ("data_base64", .str (base64UrlEncodeUnpadded "artifact-payload\n".toUTF8))
          ]])
        ])
      ]),
      ("command", .arr #[.str "sh", .str "-c", .str "cp hello.txt built.out && echo build-log-line"]),
      ("artifacts", .arr #[.str "built.out"])
    ])
  ])
  let (rt5, rSub) ← handleRequest rt {
    method := "POST", rawPath := "/jobs", path := "/jobs",
    query := #[], headers := authHdrs, body := jobBody.toUTF8
  }
  rt := rt5
  check "POST /jobs returns 202" (rSub.status == 202)

  for _ in [0:30] do
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
  check "lean_build job succeeded with 1 SHA-256 artifact"
    (jobJson.fieldStr? "state" == some "succeeded" &&
     ((jobJson.fieldArr? "artifacts").map Array.size == some 1))

  let (_, rLog) ← handleRequest rt {
    method := "GET", rawPath := s!"/jobs/{jobId}/log?offset=0", path := s!"/jobs/{jobId}/log",
    query := #[("offset", "0")], headers := authHdrs, body := ByteArray.empty
  }
  let .ok logJson := OrbBin.Json.parse (String.fromUTF8! rLog.body)
    | throw (IO.userError "GET /jobs/:id/log invalid JSON")
  check "GET /jobs/:id/log streams build-log-line"
    (rLog.status == 200 && logJson.fieldStr? "data" == some "build-log-line\n")

  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpRoot] }
  let passed ← passedRef.get
  IO.println s!"OrbNode self-test: {passed}/{passed} assertions PASSED"
  return 0

end OrbNode.SelfTest

def main : IO UInt32 :=
  OrbNode.SelfTest.runTests
