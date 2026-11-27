/-
  OrbCore.NodeReleaseTests: Unit & route tests for Core-driven node release manifest,
  authenticated heartbeat & binary download, and rollback report persistence.
-/
import LeanSys.Auth
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Control

namespace OrbCore.NodeReleaseTests

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Control

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw (IO.userError s!"[NodeReleaseTests] FAIL: {label}")

private def mkDummyElf64 (arch : String) (payload : String) : ByteArray :=
  let header : Array UInt8 := #[
    0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00,
    if arch == "aarch64" then 0xb7 else 0x3e, 0x00
  ]
  ByteArray.mk header ++ payload.toUTF8

def run : IO Unit := do
  let nonce ← IO.monoNanosNow
  let root := s!"/tmp/orb-core-node-release-test-{nonce}"
  let relDir := s!"{root}/releases"
  IO.FS.createDirAll s!"{relDir}/x86_64"
  let nodeBytes := mkDummyElf64 "x86_64" "orb-core-test-sandboxed-node-bin"
  let privdBytes := mkDummyElf64 "x86_64" "orb-core-test-orb-privd-bin"
  let nodeSha := bytesToHexLower (sha256Bytes nodeBytes)
  let privdSha := bytesToHexLower (sha256Bytes privdBytes)
  IO.FS.writeBinFile s!"{relDir}/x86_64/sandboxed-node" nodeBytes
  IO.FS.writeBinFile s!"{relDir}/x86_64/orb-privd" privdBytes

  let .ok store ← openCoreStore root 0 "prod"
    | throw (IO.userError "openCoreStore failed")
  let cfg : CoreConfig := {
    devMode := false, host := "127.0.0.1", workingDir := root,
    dashboardPassword := "test-strong-passphrase-release",
    jwtSecret := "test-jwt-secret-release-0123456789abcdef",
    proxySecret := "test-proxy-secret-release-0123456789abcd"
  }
  let nowSec : UInt64 := 1700005000
  let .ok adminId ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] s!"{nowSec}"
    | do closeCoreStore store; throw (IO.userError "bootstrap admin failed")
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : OrbCore.Managed.ManagedFleetState)
  let chainsRef ← IO.mkRef #[]
  let proxyCooldownsRef ← IO.mkRef #[]
  let seqRef ← IO.mkRef (1 : UInt64)
  let appSt : CoreAppState := {
    cfg := cfg, store := store, searchIdx? := none, managedRef := managedRef, chainsRef := chainsRef,
    proxyCooldownsRef := proxyCooldownsRef, seqRef := seqRef
  }
  let adminJwt := mintSessionTokenV2 cfg.jwtSecret adminId "admin" 1 (nowSec + 3600)

  setenvVar "ORB_NODE_RELEASE_DIR" relDir
  setenvVar "ORB_BUILD_SHA" "abcdef1234567890"
  setenvVar "SANDBOXED_REMOTE_NODES_ENABLED" "1"
  setenvVar "SANDBOXED_REMOTE_NODES" "[{\"id\":\"uruk-test\",\"base_url\":\"http://127.0.0.1:19999\",\"token_env\":\"TEST_URUK_NODE_TOKEN\"}]"
  setenvVar "TEST_URUK_NODE_TOKEN" "static-node-secret-uruk-42"

  try
    let dispatch := fun (method path : String) (hdrs : Array (String × String)) (body : String) => do
      let hdrLines := hdrs.foldl (fun acc (k, v) => acc ++ s!"{k}: {v}\r\n") ""
      let wire := s!"{method} {path} HTTP/1.1\r\nHost: localhost\r\n{hdrLines}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := LeanSys.Http.parseRequest wire.toUTF8 none
        | throw (IO.userError "parseRequest failed")
      match ← dispatchCoreRequest appSt req nowSec with
      | .ok r => pure r
      | .error e => throw (IO.userError s!"dispatch error: {e}")

    -- 1. Unauthenticated request rejected with 401
    let r401 ← dispatch "GET" "/api/node-releases/manifest" #[] ""
    assertTrue "unauthenticated manifest returns 401" (r401.status == 401)

    -- 2. Static node token accesses manifest & heartbeat, receives target sha256 + CLI bundle
    let nodeHdrs := #[("Authorization", "Bearer static-node-secret-uruk-42")]
    let hbBody := renderCompact (.obj #[
      ("node_id", .str "uruk-test"),
      ("arch", .str "x86_64"),
      ("running_jobs", .nat 0),
      ("current_sha256", .str "0000000000000000000000000000000000000000000000000000000000000000"),
      ("cli_versions", .obj #[("agy", .str "1.0.0"), ("claude", .str "2.1.322")]),
      ("auto_update", .obj #[("status", .str "rolled_back"), ("rollback_reason", .str "startup_heartbeat_timeout")])
    ])
    let rHb ← dispatch "POST" "/api/node-releases/heartbeat" nodeHdrs hbBody
    assertTrue "node heartbeat returns 200" (rHb.status == 200)
    let .ok hbJv := OrbBin.Json.parseBytes rHb.body
      | throw (IO.userError "heartbeat JSON parse failed")
    let man := hbJv.fieldOrNull "release_manifest"
    let nodeBinSha := ((man.field? "binaries").bind (·.field? "sandboxed-node")).bind (·.fieldStr? "sha256")
    let privdBinSha := ((man.field? "binaries").bind (·.field? "orb-privd")).bind (·.fieldStr? "sha256")
    let cliHarnesses := ((man.field? "cli_bundle").bind (·.field? "harnesses"))
    assertTrue "heartbeat response exposes sandboxed-node & orb-privd sha256 + 4-harness cli_bundle"
      (hbJv.fieldStr? "node_id" == some "uruk-test" &&
       nodeBinSha == some nodeSha &&
       privdBinSha == some privdSha &&
       (cliHarnesses.bind (·.field? "agy")).isSome &&
       (cliHarnesses.bind (·.field? "claude")).isSome &&
       (cliHarnesses.bind (·.field? "codex")).isSome &&
       (cliHarnesses.bind (·.field? "opencode")).isSome)

    -- 3. Rollback report persisted in node_update_status.json
    let reports ← OrbCore.NodeRelease.loadNodeUpdateReports root
    let savedReason := (reports.field? "uruk-test").bind (·.field? "auto_update") |>.bind (·.fieldStr? "rollback_reason")
    assertTrue "node rollback report persisted by node_id" (savedReason == some "startup_heartbeat_timeout")

    -- 4. Binary download serves exact bytes + X-Orb-Sha256 and rejects arch mismatch
    let rBin ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=x86_64" nodeHdrs ""
    let hdrSha := (rBin.extraHdrs.find? (fun (k, _) => k.toLower == "x-orb-sha256")).map Prod.snd
    assertTrue "binary download serves exact bytes with matching X-Orb-Sha256"
      (rBin.status == 200 && rBin.body == nodeBytes && hdrSha == some nodeSha)
    let rArchMiss ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=aarch64" nodeHdrs ""
    assertTrue "binary download refuses mismatched architecture with 404" (rArchMiss.status == 404)

    -- 5. Admin JWT can inspect manifest too
    let rAdmin ← dispatch "GET" "/api/node-releases/manifest?arch=x86_64" #[("Authorization", s!"Bearer {adminJwt}")] ""
    assertTrue "admin JWT can fetch release manifest" (rAdmin.status == 200)
  finally
    unsetenvVar "ORB_NODE_RELEASE_DIR"
    unsetenvVar "ORB_BUILD_SHA"
    unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
    unsetenvVar "SANDBOXED_REMOTE_NODES"
    unsetenvVar "TEST_URUK_NODE_TOKEN"
    closeCoreStore store
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", root] }).toBaseIO

end OrbCore.NodeReleaseTests
