/-
  OrbNode.AutoUpdateTests: Unit & live HTTP self-tests for Core-driven idle auto-update,
  `.prev` backup + atomic swap, automatic crash/timeout rollback & quarantine, and
  declarative harness CLI bundle resync.
-/
import LeanSys.Auth
import OrbBin.Json
import OrbBin.PosixExt
import OrbNode.Posix
import OrbNode.AutoUpdate

namespace OrbNode.AutoUpdateTests

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbNode.AutoUpdate

private def mkDummyElf64 (arch : String) (payload : String) : ByteArray :=
  let header : Array UInt8 := #[
    0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00,
    if arch == "aarch64" then 0xb7 else 0x3e, 0x00
  ]
  ByteArray.mk header ++ payload.toUTF8

private def readAllReq (cfd : UInt32) : IO String := do
  let mut acc := ByteArray.empty
  for _ in [0:20] do
    let chunk ← OrbNode.Posix.fdRead cfd 65536
    if chunk.isEmpty then break
    acc := acc ++ chunk
    let s := (String.fromUTF8? acc).getD ""
    if (s.splitOn "\r\n\r\n").length > 1 then
      let parts := s.splitOn "\r\n\r\n"
      let hdr := parts[0]!
      let bodyStr := String.intercalate "\r\n\r\n" parts.tail!
      let cl :=
        ((hdr.splitOn "\r\n").findSome? fun ln =>
          let low := ln.toLower
          if low.startsWith "content-length:" then (low.drop 15).trimAscii.toString.toNat? else none).getD 0
      if bodyStr.toUTF8.size >= cl then break
  return (String.fromUTF8? acc).getD ""

private def writeHttpResp (cfd : UInt32) (status : Nat) (ctype : String) (body : ByteArray) : IO Unit := do
  let hdr := s!"HTTP/1.1 {status} OK\r\nContent-Type: {ctype}\r\nContent-Length: {body.size}\r\nConnection: close\r\n\r\n"
  let _ ← OrbNode.Posix.fdWriteAll cfd (hdr.toUTF8 ++ body)

def run (check : String → Bool → IO Unit) (tmpRoot : String) : IO Unit := do
  let shaA := bytesToHexLower (sha256Bytes "binary-A".toUTF8)
  let shaB := bytesToHexLower (sha256Bytes "binary-B".toUTF8)
  let emptySt : AutoUpdateState := {}

  -- 1. Pure eligibility gate checks
  check "auto-update gate admits idle uncordoned node with different target sha256"
    (shouldApplyBinaryUpdate true 0 0 false shaA shaB emptySt)
  check "auto-update gate blocks when running_jobs > 0"
    (!shouldApplyBinaryUpdate true 1 0 false shaA shaB emptySt)
  check "auto-update gate blocks when queued_jobs > 0"
    (!shouldApplyBinaryUpdate true 0 1 false shaA shaB emptySt)
  check "auto-update gate blocks when cordoned"
    (!shouldApplyBinaryUpdate true 0 0 true shaA shaB emptySt)
  check "auto-update gate no-ops when current_sha256 == target_sha256"
    (!shouldApplyBinaryUpdate true 0 0 false shaA shaA emptySt)
  check "auto-update gate blocks quarantined target sha256"
    (!shouldApplyBinaryUpdate true 0 0 false shaA shaB { emptySt with quarantinedSha256? := some shaB })
  check "auto-update gate allows new target sha256 after different sha was quarantined"
    (shouldApplyBinaryUpdate true 0 0 false shaA shaB { emptySt with quarantinedSha256? := some shaA })

  -- 2. Pure startup rollback window & crash detection
  let pendingSample : PendingUpdate := {
    targetSha256 := shaB
    prevSha256 := shaA
    binaryPath := "/tmp/bin"
    prevBinaryPath := "/tmp/bin.prev"
    startedAt := 1000
    startupWindowSecs := 90
    bootAttempts := 1
  }
  check "startup rollback detects crash before first heartbeat (bootAttempts >= 1)"
    (shouldRollbackStartup pendingSample 1010 false true == some "startup_crash_before_heartbeat")
  check "startup rollback detects first-heartbeat timeout after startup window"
    (shouldRollbackStartup { pendingSample with bootAttempts := 0 } 1090 false false == some "startup_heartbeat_timeout")
  check "startup rollback stays quiet inside startup window"
    (shouldRollbackStartup { pendingSample with bootAttempts := 0 } 1050 false false == none)
  check "startup rollback never triggers once first heartbeat confirmed"
    (shouldRollbackStartup pendingSample 2000 true true == none)

  -- 3. ELF arch validator
  let elfX64 := mkDummyElf64 "x86_64" "v2-node-payload"
  let elfArm := mkDummyElf64 "aarch64" "v2-arm-payload"
  check "verifyLinuxElfArch accepts x86_64 ELF for x86_64 and rejects aarch64"
    (verifyLinuxElfArch elfX64 "x86_64" && !verifyLinuxElfArch elfArm "x86_64" && verifyLinuxElfArch elfArm "aarch64")

  -- 4. CLI drift detection
  let cliManifest : CliBundleManifest := {
    profile := "default"
    version := "bundle-v1"
    harnesses := #[
      { name := "claude", bin := "claude", version := "2.1.322" },
      { name := "opencode", bin := "opencode", version := "1.19.3" },
      { name := "agy", bin := "agy", version := "1.5.0" }
    ]
  }
  let drifted := findDriftedCliHarnesses cliManifest #[
    ("claude", "2.1.322 (Claude Code)"),
    ("opencode", "1.18.0"),
    ("agy", "")
  ]
  check "findDriftedCliHarnesses detects missing and drifted CLIs while matching semver"
    (drifted.size == 2 && drifted.any (·.name == "opencode") && drifted.any (·.name == "agy"))

  -- 5. Live mock Core test: download, sha256 verification, atomic swap keeping .prev,
  --    heartbeat confirmation, crash/timeout rollback + quarantine + rollback report, and CLI resync!
  let testDir := s!"{tmpRoot}/auto-update-e2e"
  let stateDir := s!"{testDir}/state"
  let binPath := s!"{testDir}/bin/sandboxed-node"
  IO.FS.createDirAll s!"{testDir}/bin"
  IO.FS.createDirAll stateDir
  let hostArch ← detectHostArch
  let oldBinBytes := mkDummyElf64 hostArch "v1-old-sandboxed-node"
  let newBinBytes := mkDummyElf64 hostArch "v2-new-sandboxed-node"
  let oldSha := bytesToHexLower (sha256Bytes oldBinBytes)
  let newSha := bytesToHexLower (sha256Bytes newBinBytes)
  IO.FS.writeBinFile binPath oldBinBytes
  let _ ← chmod binPath 0o755
  let cliScriptBytes := "#!/bin/sh\necho \"9.9.9\"\n".toUTF8
  let cliSha := bytesToHexLower (sha256Bytes cliScriptBytes)

  let mockPort : UInt16 := 19537
  let lfd ← OrbNode.Posix.tcpListen "127.0.0.1" mockPort
  let stopRef ← IO.mkRef false
  let serveBadBinRef ← IO.mkRef true
  let targetShaRef ← IO.mkRef newSha
  let lastHbReportRef ← IO.mkRef (none : Option JVal)
  let srvTask ← IO.asTask (prio := Task.Priority.dedicated) do
    while !(← stopRef.get) do
      let cfd ← OrbNode.Posix.tcpAccept lfd 100
      if cfd != 0xFFFFFFFF then
        try
          let rawReq ← readAllReq cfd
          let firstLine := (rawReq.splitOn "\r\n").headD ""
          let path := ((firstLine.splitOn " ")[1]?).getD "/"
          if path.startsWith "/api/node-releases/heartbeat" then
            let bodyPart :=
              match rawReq.splitOn "\r\n\r\n" with
              | _ :: rest => String.intercalate "\r\n\r\n" rest
              | [] => "{}"
            if let .ok jv := OrbBin.Json.parse bodyPart then
              lastHbReportRef.set (some jv)
            let curTarget ← targetShaRef.get
            let respJson := JVal.obj #[
              ("ok", .bool true),
              ("cordoned", .bool false),
              ("release_manifest", .obj #[
                ("version", .nat 1),
                ("build_sha", .str "deadbeef"),
                ("startup_window_secs", .uint64 30),
                ("binaries", .obj #[
                  ("sandboxed-node", .obj #[
                    ("sha256", .str curTarget),
                    ("url", .str "/api/node-releases/binaries/sandboxed-node"),
                    ("size_bytes", .uint64 newBinBytes.size.toUInt64),
                    ("arch", .str hostArch)
                  ])
                ]),
                ("cli_bundle", .obj #[
                  ("profile", .str "test"),
                  ("version", .str "cli-v9"),
                  ("harnesses", .obj #[
                    ("agy", .obj #[
                      ("bin", .str "agy"),
                      ("version", .str "9.9.9"),
                      ("url", .str "/api/test-cli/agy"),
                      ("sha256", .str cliSha),
                      ("format", .str "raw")
                    ])
                  ])
                ])
              ])
            ]
            writeHttpResp cfd 200 "application/json" (renderCompact respJson).toUTF8
          else if path.startsWith "/api/node-releases/binaries/sandboxed-node" then
            let bad ← serveBadBinRef.get
            if bad then
              writeHttpResp cfd 200 "application/octet-stream" (mkDummyElf64 hostArch "corrupted-bytes")
            else
              writeHttpResp cfd 200 "application/octet-stream" newBinBytes
          else if path.startsWith "/api/test-cli/agy" then
            writeHttpResp cfd 200 "application/octet-stream" cliScriptBytes
          else
            writeHttpResp cfd 404 "text/plain" "not found".toUTF8
        finally
          OrbNode.Posix.fdClose cfd
  try
    setenvVar "SANDBOXED_NODE_UPDATE_BIN_PATH" binPath
    let coreUrl := s!"http://127.0.0.1:{mockPort}"

    -- 5a. Corrupted download must be rejected on sha256 mismatch and leave binary untouched
    let badRes ← runAutoUpdateTick stateDir coreUrl "test-node" "tok-1" oldSha none true 0 0 false
    let afterBadBytes ← IO.FS.readBinFile binPath
    let stAfterBad ← loadAutoUpdateState stateDir
    check "sha256 mismatch rejects download and preserves existing binary"
      (!badRes && afterBadBytes == oldBinBytes && stAfterBad.pending?.isNone && stAfterBad.lastError?.isSome)

    -- 5b. Valid download atomically swaps binary, preserves .prev backup, and records pending_update
    serveBadBinRef.set false
    let okSwap ← runAutoUpdateTick stateDir coreUrl "test-node" "tok-1" oldSha none true 0 0 false
    let swappedBytes ← IO.FS.readBinFile binPath
    let prevBytes ← IO.FS.readBinFile (binPath ++ ".prev")
    let stAfterSwap ← loadAutoUpdateState stateDir
    check "idle pull downloads, verifies sha256, swaps binary atomically, and keeps .prev backup"
      (okSwap && swappedBytes == newBinBytes && prevBytes == oldBinBytes &&
       stAfterSwap.pending?.map (·.targetSha256) == some newSha)

    -- 5c. Startup crash rollback: first boot sets bootAttempts=1, second boot before first heartbeat restores .prev!
    let act1 ← handleStartupUpdateCheck stateDir
    let act2 ← handleStartupUpdateCheck stateDir
    let restoredBytes ← IO.FS.readBinFile binPath
    let stAfterRollback ← loadAutoUpdateState stateDir
    check "crash before first heartbeat automatically restores .prev and quarantines failed sha256"
      (act1 == .normal && act2 == .rolledBack "startup_crash_before_heartbeat" &&
       restoredBytes == oldBinBytes &&
       stAfterRollback.pending?.isNone &&
       stAfterRollback.quarantinedSha256? == some newSha &&
       stAfterRollback.lastRollbackReason? == some "startup_crash_before_heartbeat")

    -- 5d. Next heartbeat reports rollback reason to Core and does NOT re-download quarantined sha256;
    --     simultaneously resyncs the drifted `agy` CLI bundle!
    let noLoop ← runAutoUpdateTick stateDir coreUrl "test-node" "tok-1" oldSha none true 0 0 false
    let reported? ← lastHbReportRef.get
    let reportedReason := reported?.bind (·.field? "auto_update") |>.bind (·.fieldStr? "rollback_reason")
    let agyLink := System.FilePath.mk (managedToolsBinDir stateDir) / "agy"
    let agyExists ← agyLink.pathExists
    let localVers ← collectLocalCliVersions stateDir true
    let agyVer := (localVers.find? (fun (k, _) => k == "agy")).map Prod.snd |>.getD ""
    check "post-rollback heartbeat reports rollback_reason, skips quarantined sha, and resyncs drifted CLI bundle"
      (!noLoop && reportedReason == some "startup_crash_before_heartbeat" && agyExists && agyVer == "9.9.9")

    -- 5e. First heartbeat confirmation commits a pending update
    let stNow ← loadAutoUpdateState stateDir
    saveAutoUpdateState stateDir {
      stNow with
      pending? := some {
        targetSha256 := newSha, prevSha256 := oldSha, binaryPath := binPath,
        prevBinaryPath := binPath ++ ".prev", startedAt := 1000, startupWindowSecs := 90, bootAttempts := 1
      }
    }
    confirmFirstHeartbeat stateDir
    let stConfirmed ← loadAutoUpdateState stateDir
    check "confirmFirstHeartbeat clears pending update and records lastUpdateAt"
      (stConfirmed.pending?.isNone && stConfirmed.lastUpdateAt?.isSome)
  finally
    unsetenvVar "SANDBOXED_NODE_UPDATE_BIN_PATH"
    stopRef.set true
    let _ ← IO.wait srvTask
    OrbNode.Posix.fdClose lfd

end OrbNode.AutoUpdateTests
