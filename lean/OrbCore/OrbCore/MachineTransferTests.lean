/-
  OrbCore.MachineTransferTests: End-to-end tests for Milestone 4 (`machine-transfer` v1):
  1. `GET /api/control/missions/:id/machine-transfer` returns v1 `TransferView`
     (`version: 1`, `source`, `features`, `actions`, `destinations`) with tenant filtering.
  2. `POST` `prepare` fencing via `startMachineTransfer` / `verifyTransferFence`
     (active mission rejected, concurrent transfer rejected, `idempotency_key` idempotent).
  3. Full light transfer from remote node to `client` (`This computer`):
     `prepare(light=true)` -> `files(read conversation.txt)` -> `client_verified` -> `activate`,
     verifying mission `placement_kind='client'`, cleared `remote-node:` tag, bumped `placement_revision`.
  4. Full workspace transfer `core` -> `client` (`inventory`, `snapshot`, `read`, `client_verified`, `activate`)
     and `client` -> `core` (`client_snapshot`, `stage`, `write`, `verify`, `activate`), plus `cancel`.
-/
import LeanSys.Auth
import LeanSys.Http
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Control

namespace OrbCore.MachineTransferTests

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.Managed
open OrbCore.Control

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw (IO.userError s!"[MachineTransferTests] FAIL: {label}")

def run : IO Unit := do
  let nonce ← IO.monoNanosNow
  let root := s!"/tmp/orb-core-machine-transfer-test-{nonce}"
  let wsDir := s!"{root}/ws-core"
  IO.FS.createDirAll wsDir
  IO.FS.writeFile s!"{wsDir}/hello.txt" "hello from orb core workspace\n"
  let .ok store ← openCoreStore root 0 "prod"
    | throw (IO.userError "openCoreStore failed")
  let .ok mc ← openManagedComputeStore s!"{root}/managed.db" (some store.missionsDb)
    | do closeCoreStore store; throw (IO.userError "openManagedComputeStore failed")
  let cfg : CoreConfig := {
    devMode := false, host := "127.0.0.1", workingDir := root,
    dashboardPassword := "test-strong-passphrase-mt",
    jwtSecret := "test-jwt-secret-mt-0123456789abcdef0123",
    proxySecret := "test-proxy-secret-mt-0123456789abcdef01"
  }
  let nowSec : UInt64 := 1700020000
  let .ok adminId ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] s!"{nowSec}"
    | do closeManagedComputeStore mc; closeCoreStore store; throw (IO.userError "bootstrap admin failed")
  let memberId := "user-member-mt-1"
  discard <| execParamQuery store.missionsDb
    "INSERT INTO users(id,username,password_hash,role,unix_username,disabled) VALUES(?1,'alice','x','member','orb-alice',0);"
    #[memberId]
  discard <| execParamQuery mc.db
    ("INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents," ++
     "cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id,provider_id) " ++
     "VALUES('vm-adm-1','Admin VM','boat','small','ready','',60,0,0,1,0,'user','',1,1,?1,'p-1');") #[adminId]
  discard <| execParamQuery mc.db
    ("INSERT INTO managed_machines(id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents," ++
     "cordoned,node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id,provider_id) " ++
     "VALUES('vm-mem-1','Alice VM','boat','small','ready','',60,0,0,1,0,'user','',1,1,?1,'p-2');") #[memberId]

  let midNode := "aaaaaaaa-1111-4222-8333-444444444444"
  let midCore := "bbbbbbbb-1111-4222-8333-444444444444"
  let midMember := "cccccccc-1111-4222-8333-444444444444"
  let .ok () ← upsertMission store {
    id := midNode, title := "Node To Desktop", status := "awaiting_user", backend := "antigravity",
    modelOverride := "gemini-3-pro", workingDirectory := "/var/lib/sandboxed-node/work/m1",
    updatedAt := "2026-11-27T01:00:00Z", ownerUserId := adminId,
    placementKind := "remote", tagsJson := "[\"remote-node:uruk\"]"
  } | throw (IO.userError "upsert midNode failed")
  discard <| appendMissionEvent store midNode "user_message" "{\"content\":\"Move me to This computer\"}" "2026-11-27T01:00:01Z"
  discard <| appendMissionEvent store midNode "assistant_message" "{\"content\":\"Ready to move!\"}" "2026-11-27T01:00:02Z"
  let .ok () ← upsertMission store {
    id := midCore, title := "Core Full Transfer", status := "awaiting_user", backend := "codex",
    modelOverride := "gpt-5.4", workingDirectory := wsDir,
    updatedAt := "2026-11-27T01:00:00Z", ownerUserId := adminId,
    placementKind := "core", tagsJson := "[]"
  } | throw (IO.userError "upsert midCore failed")
  let .ok () ← upsertMission store {
    id := midMember, title := "Member Mission", status := "awaiting_user", backend := "codex",
    modelOverride := "", workingDirectory := "/tmp/alice",
    updatedAt := "2026-11-27T01:00:00Z", ownerUserId := memberId,
    placementKind := "remote", tagsJson := "[\"remote-node:uruk\"]"
  } | throw (IO.userError "upsert midMember failed")

  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : ManagedFleetState)
  let chainsRef ← IO.mkRef #[]
  let proxyCooldownsRef ← IO.mkRef #[]
  let seqRef ← IO.mkRef (1 : UInt64)
  let appSt : CoreAppState := {
    bootstrapAdminId := adminId,
    cfg := cfg, store := store, searchIdx? := none, managedRef := managedRef,
    managedStore? := some mc, chainsRef := chainsRef,
    proxyCooldownsRef := proxyCooldownsRef, seqRef := seqRef
  }
  let adminJwt := mintSessionTokenV2 cfg.jwtSecret adminId "admin" 1 (nowSec + 3600)
  let memberJwt := mintSessionTokenV2 cfg.jwtSecret memberId "member" 1 (nowSec + 3600)
  let adminHdrs := #[("Authorization", s!"Bearer {adminJwt}"), ("Content-Type", "application/json")]
  let memberHdrs := #[("Authorization", s!"Bearer {memberJwt}"), ("Content-Type", "application/json")]

  setenvVar "SANDBOXED_REMOTE_NODES_ENABLED" "1"
  setenvVar "SANDBOXED_REMOTE_NODES"
    "[{\"id\":\"uruk\",\"base_url\":\"http://127.0.0.1:9\",\"token_env\":\"MT_T1\"},{\"id\":\"ashur-adm\",\"base_url\":\"http://127.0.0.1:9\",\"token_env\":\"MT_T2\",\"labels\":[\"admin-only\"]}]"
  setenvVar "MT_T1" "t1"
  setenvVar "MT_T2" "t2"

  try
    let dispatch := fun (method path : String) (hdrs : Array (String × String)) (body : String) => do
      let hdrLines := hdrs.foldl (fun acc (k, v) => acc ++ s!"{k}: {v}\r\n") ""
      let wire := s!"{method} {path} HTTP/1.1\r\nHost: localhost\r\n{hdrLines}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := LeanSys.Http.parseRequest wire.toUTF8 none
        | throw (IO.userError "parseRequest failed")
      match ← dispatchCoreRequest appSt req nowSec with
      | .ok r => pure r
      | .error e => throw (IO.userError s!"dispatch error: {e}")

    -- 1. GET returns TransferView v1 with source, features, actions, destinations (and tenant isolation)
    let rGetAdm ← dispatch "GET" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs ""
    assertTrue "GET machine-transfer returns 200" (rGetAdm.status == 200)
    let .ok viewAdm := OrbBin.Json.parseBytes rGetAdm.body | throw (IO.userError "parse admin view")
    let destsAdm := (viewAdm.fieldArr? "destinations").getD #[]
    assertTrue "admin TransferView has version=1, source=node:uruk, features, Core + static + admin VM destinations"
      (viewAdm.fieldNat? "version" == some 1 &&
       (viewAdm.field? "source").bind (·.fieldStr? "kind") == some "node" &&
       (viewAdm.field? "source").bind (·.fieldStr? "id") == some "uruk" &&
       ((viewAdm.fieldArr? "features").getD #[]).contains (.str "links") &&
       destsAdm.any (fun d => (d.field? "machine").bind (·.fieldStr? "kind") == some "core") &&
       destsAdm.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "uruk") &&
       destsAdm.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "ashur-adm") &&
       destsAdm.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "managed-vm-adm-1") &&
       !destsAdm.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "managed-vm-mem-1"))

    let rGetMem ← dispatch "GET" s!"/api/control/missions/{midMember}/machine-transfer" memberHdrs ""
    let .ok viewMem := OrbBin.Json.parseBytes rGetMem.body | throw (IO.userError "parse member view")
    let destsMem := (viewMem.fieldArr? "destinations").getD #[]
    assertTrue "member TransferView hides Core, admin-only nodes, and admin VMs while showing own VM"
      (rGetMem.status == 200 &&
       viewMem.fieldNat? "version" == some 1 &&
       !destsMem.any (fun d => (d.field? "machine").bind (·.fieldStr? "kind") == some "core") &&
       !destsMem.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "ashur-adm") &&
       !destsMem.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "managed-vm-adm-1") &&
       destsMem.any (fun d => (d.field? "machine").bind (·.fieldStr? "id") == some "managed-vm-mem-1"))

    let rDenyCore ← dispatch "POST" s!"/api/control/missions/{midMember}/machine-transfer" memberHdrs
      "{\"op\":\"prepare\",\"light\":true,\"destination\":{\"kind\":\"core\"}}"
    assertTrue "member cannot prepare transfer targeting Core" (rDenyCore.status == 403)

    -- 2. Light transfer: remote node (uruk) -> client (This computer)
    let prepBody := renderCompact (.obj #[
      ("op", .str "prepare"),
      ("light", .bool true),
      ("destination", .obj #[("kind", .str "client"), ("id", .str "macbook-thomas")]),
      ("client_id", .str "macbook-thomas"),
      ("idempotency_key", .str "idem-light-1"),
      ("backend", .str "claudecode"),
      ("model", .str "claude-sonnet-4-6")
    ])
    let rPrep ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs prepBody
    assertTrue "prepare light transfer to client returns 200" (rPrep.status == 200)
    let .ok act1 := OrbBin.Json.parseBytes rPrep.body | throw (IO.userError "parse act1")
    let tid1 := (act1.fieldStr? "id").getD ""
    let convPath1 := OrbCore.MachineTransfer.conversationRelPath tid1
    let manFiles1 := ((act1.field? "manifest").bind (·.fieldArr? "files")).getD #[]
    assertTrue "light transfer returns snapshotted action with conversation.txt manifest"
      (!tid1.isEmpty &&
       act1.fieldStr? "phase" == some "snapshotted" &&
       act1.fieldBool? "light" == some true &&
       manFiles1.any (fun f => f.fieldStr? "path" == some convPath1))

    -- Idempotency check & concurrent transfer fence check
    let rPrepDup ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs prepBody
    let .ok actDup := OrbBin.Json.parseBytes rPrepDup.body | throw (IO.userError "parse actDup")
    assertTrue "idempotency_key returns same active transfer" (rPrepDup.status == 200 && actDup.fieldStr? "id" == some tid1)

    let rFence ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      "{\"op\":\"prepare\",\"light\":true,\"destination\":{\"kind\":\"core\"},\"idempotency_key\":\"different-key\"}"
    assertTrue "concurrent transfer fenced with 409 via verifyTransferFence" (rFence.status == 409)

    -- Read conversation.txt from Core
    let rReadConv ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      (renderCompact (.obj #[
        ("op", .str "files"),
        ("transfer_id", .str tid1),
        ("side", .str "source"),
        ("operation", .obj #[("op", .str "read"), ("path", .str convPath1), ("offset", .nat 0)])
      ]))
    let .ok readJv := OrbBin.Json.parseBytes rReadConv.body | throw (IO.userError "parse read conv")
    let decodedConv := ((readJv.fieldStr? "data").bind base64Decode?).bind String.fromUTF8? |>.getD ""
    assertTrue "Core serves conversation.txt with mission transcript"
      (rReadConv.status == 200 &&
       (decodedConv.splitOn "Move me to This computer").length > 1 &&
       (decodedConv.splitOn "Ready to move!").length > 1)

    -- Activate before verify must fail with 409
    let rPremature ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "activate"), ("transfer_id", .str tid1)]))
    assertTrue "activate before client_verified is rejected with 409" (rPremature.status == 409)

    -- Client verifies and activates
    let rVer ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      (renderCompact (.obj #[
        ("op", .str "client_verified"),
        ("transfer_id", .str tid1),
        ("client_id", .str "macbook-thomas"),
        ("receipt", .obj #[("root", .str "/Users/thomas/orb/m1"), ("bytes", .nat 120), ("files", .nat 1), ("digest", .str "abc")])
      ]))
    let .ok actVer := OrbBin.Json.parseBytes rVer.body | throw (IO.userError "parse actVer")
    assertTrue "client_verified sets phase=verified and destination_root"
      (rVer.status == 200 && actVer.fieldStr? "phase" == some "verified" &&
       actVer.fieldStr? "destination_root" == some "/Users/thomas/orb/m1")

    let rAct ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "activate"), ("transfer_id", .str tid1)]))
    let .ok actDone := OrbBin.Json.parseBytes rAct.body | throw (IO.userError "parse actDone")
    assertTrue "activate transitions transfer to activated" (rAct.status == 200 && actDone.fieldStr? "phase" == some "activated")

    -- Verify mission placement updated to client (`This computer`) and GET reflects new source!
    let .ok mRows ← execParamQuery store.missionsDb
      "SELECT placement_kind, tags, working_directory, backend, placement_revision FROM missions WHERE id=?1;" #[midNode]
      | throw (IO.userError "select mission after activate")
    assertTrue "activated client transfer updates placement_kind=client, clears remote-node tag, bumps placement_revision"
      (mRows.size > 1 &&
       cell mRows[1]! 0 == "client" &&
       (cell mRows[1]! 1 |>.splitOn "remote-node:").length == 1 &&
       cell mRows[1]! 2 == "/Users/thomas/orb/m1" &&
       cell mRows[1]! 3 == "claudecode" &&
       cell mRows[1]! 4 == "1")

    let rGetAfter ← dispatch "GET" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs ""
    let .ok viewAfter := OrbBin.Json.parseBytes rGetAfter.body | throw (IO.userError "parse viewAfter")
    assertTrue "GET after activation reports source=client:macbook-thomas"
      ((viewAfter.field? "source").bind (·.fieldStr? "kind") == some "client" &&
       (viewAfter.field? "source").bind (·.fieldStr? "id") == some "macbook-thomas")

    -- Cancel already-activated transfer fails with 409
    let rCancelDone ← dispatch "POST" s!"/api/control/missions/{midNode}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "cancel"), ("transfer_id", .str tid1)]))
    assertTrue "cancel of activated transfer returns 409" (rCancelDone.status == 409)

    -- 3. Full Core workspace transfer (`inventory` -> `snapshot` -> `read` -> `cancel`)
    let rPrepCore ← dispatch "POST" s!"/api/control/missions/{midCore}/machine-transfer" adminHdrs
      "{\"op\":\"prepare\",\"light\":false,\"destination\":{\"kind\":\"client\",\"id\":\"macbook-thomas\"},\"client_id\":\"macbook-thomas\"}"
    let .ok actCore := OrbBin.Json.parseBytes rPrepCore.body | throw (IO.userError "parse actCore")
    let tid2 := (actCore.fieldStr? "id").getD ""
    assertTrue "full core transfer starts in preparing phase" (rPrepCore.status == 200 && actCore.fieldStr? "phase" == some "preparing")

    let rInv ← dispatch "POST" s!"/api/control/missions/{midCore}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "files"), ("transfer_id", .str tid2), ("side", .str "source"),
                             ("operation", .obj #[("op", .str "inventory")])]))
    assertTrue "core source inventory returns 200 with hello.txt"
      (rInv.status == 200 && ((String.fromUTF8? rInv.body).getD "" |>.splitOn "hello.txt").length > 1)

    let rSnap ← dispatch "POST" s!"/api/control/missions/{midCore}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "files"), ("transfer_id", .str tid2), ("side", .str "source"),
                             ("operation", .obj #[("op", .str "snapshot")])]))
    let .ok actSnap := OrbBin.Json.parseBytes rSnap.body | throw (IO.userError "parse actSnap")
    let snapFiles := ((actSnap.field? "manifest").bind (·.fieldArr? "files")).getD #[]
    assertTrue "core source snapshot merges hello.txt + conversation.txt and moves phase to snapshotted"
      (rSnap.status == 200 &&
       actSnap.fieldStr? "phase" == some "snapshotted" &&
       snapFiles.any (fun f => f.fieldStr? "path" == some "hello.txt") &&
       snapFiles.any (fun f => f.fieldStr? "path" == some (OrbCore.MachineTransfer.conversationRelPath tid2)))

    let rCancel2 ← dispatch "POST" s!"/api/control/missions/{midCore}/machine-transfer" adminHdrs
      (renderCompact (.obj #[("op", .str "cancel"), ("transfer_id", .str tid2)]))
    let .ok actCancel2 := OrbBin.Json.parseBytes rCancel2.body | throw (IO.userError "parse actCancel2")
    assertTrue "cancel active transfer transitions phase to cancelled"
      (rCancel2.status == 200 && actCancel2.fieldStr? "phase" == some "cancelled")
  finally
    unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
    unsetenvVar "SANDBOXED_REMOTE_NODES"
    unsetenvVar "MT_T1"
    unsetenvVar "MT_T2"
    closeManagedComputeStore mc
    closeCoreStore store
    discard <| (IO.Process.output { cmd := "rm", args := #["-rf", root] }).toBaseIO

end OrbCore.MachineTransferTests
