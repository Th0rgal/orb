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

private def restoreEnvVar (key : String) (prev? : Option String) : IO Unit := do
  match prev? with
  | some v => setenvVar key v
  | none => unsetenvVar key

def run : IO Unit := do
  let nonce ← IO.monoNanosNow
  let root := s!"/tmp/orb-core-node-release-test-{nonce}"
  let relDir := s!"{root}/releases"
  let flatRelDir := s!"{root}/flat-releases"
  IO.FS.createDirAll s!"{relDir}/x86_64"
  IO.FS.createDirAll flatRelDir
  let nodeBytes := mkDummyElf64 "x86_64" "orb-core-test-sandboxed-node-bin"
  let flatNodeBytes := mkDummyElf64 "x86_64" "orb-core-test-flat-sandboxed-node-bin"
  let privdBytes := mkDummyElf64 "x86_64" "orb-core-test-orb-privd-bin"
  let agyBytes := mkDummyElf64 "x86_64" "orb-core-test-agy-cli-bin"
  let nodeSha := bytesToHexLower (sha256Bytes nodeBytes)
  let flatNodeSha := bytesToHexLower (sha256Bytes flatNodeBytes)
  let privdSha := bytesToHexLower (sha256Bytes privdBytes)
  let agySha := bytesToHexLower (sha256Bytes agyBytes)
  IO.FS.writeBinFile s!"{relDir}/x86_64/sandboxed-node" nodeBytes
  IO.FS.writeBinFile s!"{relDir}/x86_64/orb-privd" privdBytes
  IO.FS.writeBinFile s!"{relDir}/x86_64/agy" agyBytes
  IO.FS.writeBinFile s!"{flatRelDir}/sandboxed-node" flatNodeBytes

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

  let prevRelDir ← IO.getEnv "ORB_NODE_RELEASE_DIR"
  let prevSkipElf ← IO.getEnv "ORB_NODE_RELEASE_SKIP_ELF_CHECK"
  let prevBuildSha ← IO.getEnv "ORB_BUILD_SHA"
  let prevCliManifest ← IO.getEnv "ORB_CLI_BUNDLE_MANIFEST_PATH"
  let prevAgyVer ← IO.getEnv "ORB_CLI_BUNDLE_AGY_VERSION"
  let prevWinSecs ← IO.getEnv "ORB_NODE_UPDATE_STARTUP_WINDOW_SECS"
  let prevNodesEnabled ← IO.getEnv "SANDBOXED_REMOTE_NODES_ENABLED"
  let prevRemoteNodes ← IO.getEnv "SANDBOXED_REMOTE_NODES"
  let prevNodeTok ← IO.getEnv "TEST_URUK_NODE_TOKEN"

  setenvVar "ORB_NODE_RELEASE_DIR" relDir
  unsetenvVar "ORB_NODE_RELEASE_SKIP_ELF_CHECK"
  setenvVar "ORB_BUILD_SHA" "abcdef1234567890"
  unsetenvVar "ORB_CLI_BUNDLE_MANIFEST_PATH"
  unsetenvVar "ORB_CLI_BUNDLE_AGY_VERSION"
  unsetenvVar "ORB_NODE_UPDATE_STARTUP_WINDOW_SECS"
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

    -- 0. ORB_NODE_RELEASE_DIR is authoritative (never falls back to host /usr/local or /opt paths)
    let scopedNodeCands ← OrbCore.NodeRelease.candidateBinaryPaths "sandboxed-node" "aarch64"
    assertTrue "ORB_NODE_RELEASE_DIR scopes sandboxed-node candidates without host fallback"
      (scopedNodeCands == #[s!"{relDir}/aarch64/sandboxed-node", s!"{relDir}/sandboxed-node"])
    let scopedAgyCands ← OrbCore.NodeRelease.candidateBinaryPaths "agy" "aarch64"
    assertTrue "ORB_NODE_RELEASE_DIR scopes agy candidates without host fallback"
      (scopedAgyCands == #[s!"{relDir}/aarch64/agy", s!"{relDir}/agy"])
    let badArchCands ← OrbCore.NodeRelease.candidateBinaryPaths "sandboxed-node" "../../etc"
    assertTrue "candidateBinaryPaths rejects traversal/unknown architecture" badArchCands.isEmpty
    let badNameCands ← OrbCore.NodeRelease.candidateBinaryPaths "../etc/passwd" "x86_64"
    assertTrue "candidateBinaryPaths rejects disallowed binary name" badNameCands.isEmpty

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
    let agyEntry := cliHarnesses.bind (·.field? "agy")
    assertTrue "heartbeat response exposes sandboxed-node & orb-privd sha256 + 5-harness cli_bundle with hydrated agy URL"
      (hbJv.fieldStr? "node_id" == some "uruk-test" &&
       nodeBinSha == some nodeSha &&
       privdBinSha == some privdSha &&
       agyEntry.bind (·.fieldStr? "url") == some "/api/node-releases/binaries/agy?arch=x86_64" &&
       agyEntry.bind (·.fieldStr? "sha256") == some agySha &&
       (cliHarnesses.bind (·.field? "claude")).isSome &&
       (cliHarnesses.bind (·.field? "codex")).isSome &&
       (cliHarnesses.bind (·.field? "opencode")).isSome &&
       (cliHarnesses.bind (·.field? "pi")).isSome)

    -- 3. Rollback report persisted in node_update_status.json
    let reports ← OrbCore.NodeRelease.loadNodeUpdateReports root
    let savedReason := (reports.field? "uruk-test").bind (·.field? "auto_update") |>.bind (·.fieldStr? "rollback_reason")
    assertTrue "node rollback report persisted by node_id" (savedReason == some "startup_heartbeat_timeout")

    -- 4. Binary download serves exact bytes + X-Orb-Sha256 (sandboxed-node & agy) and rejects arch mismatch
    let rBin ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=x86_64" nodeHdrs ""
    let hdrSha := (rBin.extraHdrs.find? (fun (k, _) => k.toLower == "x-orb-sha256")).map Prod.snd
    assertTrue "binary download serves exact bytes with matching X-Orb-Sha256"
      (rBin.status == 200 && rBin.body == nodeBytes && hdrSha == some nodeSha)
    let rAgyBin ← dispatch "GET" "/api/node-releases/binaries/agy?arch=x86_64" nodeHdrs ""
    let agyHdrSha := (rAgyBin.extraHdrs.find? (fun (k, _) => k.toLower == "x-orb-sha256")).map Prod.snd
    assertTrue "agy CLI binary download serves exact bytes with matching X-Orb-Sha256"
      (rAgyBin.status == 200 && rAgyBin.body == agyBytes && agyHdrSha == some agySha)
    let rArchMiss ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=aarch64" nodeHdrs ""
    assertTrue "binary download refuses mismatched architecture with 404" (rArchMiss.status == 404)
    let rBadArch ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=../../etc" nodeHdrs ""
    assertTrue "binary download refuses traversal architecture with 404" (rBadArch.status == 404)

    -- 4b. Unscoped flat binary inside ORB_NODE_RELEASE_DIR serves matching arch and rejects mismatched ELF arch on Linux
    setenvVar "ORB_NODE_RELEASE_DIR" flatRelDir
    let rFlatOk ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=x86_64" nodeHdrs ""
    let flatHdrSha := (rFlatOk.extraHdrs.find? (fun (k, _) => k.toLower == "x-orb-sha256")).map Prod.snd
    assertTrue "flat unscoped binary serves matching x86_64 architecture"
      (rFlatOk.status == 200 && rFlatOk.body == flatNodeBytes && flatHdrSha == some flatNodeSha)
    if !System.Platform.isOSX then
      let rFlatMiss ← dispatch "GET" "/api/node-releases/binaries/sandboxed-node?arch=aarch64" nodeHdrs ""
      assertTrue "flat unscoped x86_64 ELF refuses aarch64 download with 404" (rFlatMiss.status == 404)
    setenvVar "ORB_NODE_RELEASE_DIR" relDir

    -- 5. Admin JWT can inspect manifest (x86_64 hydrated, aarch64 unpopulated without host fallback)
    let rAdmin ← dispatch "GET" "/api/node-releases/manifest?arch=x86_64" #[("Authorization", s!"Bearer {adminJwt}")] ""
    assertTrue "admin JWT can fetch release manifest" (rAdmin.status == 200)
    let rAdminArm ← dispatch "GET" "/api/node-releases/manifest?arch=aarch64" #[("Authorization", s!"Bearer {adminJwt}")] ""
    assertTrue "admin JWT aarch64 manifest returns 200" (rAdminArm.status == 200)
    let .ok armJv := OrbBin.Json.parseBytes rAdminArm.body
      | throw (IO.userError "aarch64 manifest JSON parse failed")
    let armNodeBin := (armJv.field? "binaries").bind (·.field? "sandboxed-node")
    let armAgyUrl := (((armJv.field? "cli_bundle").bind (·.field? "harnesses")).bind (·.field? "agy")).bind (·.fieldStr? "url")
    assertTrue "aarch64 manifest does not leak host binaries when ORB_NODE_RELEASE_DIR lacks aarch64"
      (armNodeBin == some .null && armAgyUrl == some "")

    -- 6. Default host fallback paths remain intact when ORB_NODE_RELEASE_DIR is unset
    unsetenvVar "ORB_NODE_RELEASE_DIR"
    let defaultCands ← OrbCore.NodeRelease.candidateBinaryPaths "sandboxed-node" "x86_64"
    assertTrue "unset ORB_NODE_RELEASE_DIR preserves build-sha and host guest fallback paths"
      (defaultCands.contains "/usr/local/share/orb/releases/abcdef1234567890/bin/x86_64/sandboxed-node" &&
       defaultCands.contains "/usr/local/lib/orb/guest/x86_64/sandboxed-node" &&
       defaultCands.contains "/usr/local/lib/orb/guest/sandboxed-node" &&
       defaultCands.contains "/usr/local/bin/sandboxed-node")
  finally
    restoreEnvVar "ORB_NODE_RELEASE_DIR" prevRelDir
    restoreEnvVar "ORB_NODE_RELEASE_SKIP_ELF_CHECK" prevSkipElf
    restoreEnvVar "ORB_BUILD_SHA" prevBuildSha
    restoreEnvVar "ORB_CLI_BUNDLE_MANIFEST_PATH" prevCliManifest
    restoreEnvVar "ORB_CLI_BUNDLE_AGY_VERSION" prevAgyVer
    restoreEnvVar "ORB_NODE_UPDATE_STARTUP_WINDOW_SECS" prevWinSecs
    restoreEnvVar "SANDBOXED_REMOTE_NODES_ENABLED" prevNodesEnabled
    restoreEnvVar "SANDBOXED_REMOTE_NODES" prevRemoteNodes
    restoreEnvVar "TEST_URUK_NODE_TOKEN" prevNodeTok
    closeCoreStore store
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", root] }).toBaseIO

end OrbCore.NodeReleaseTests
