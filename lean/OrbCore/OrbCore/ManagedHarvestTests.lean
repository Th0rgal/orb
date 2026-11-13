import OrbCore.McpGateway
import OrbCore.ManagedHarvest
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedHarvestTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.ManagedProvider OrbCore.ManagedHarvest
open OrbCore.MemoryAndCloud

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed harvest: {label}")

private def expectError (result : Except String Harvested) (expected label : String) : IO Unit := do
  match result with
  | .error e => check (e == expected) s!"{label}: expected {expected}, got {e}"
  | .ok _ => throw (IO.userError s!"managed harvest: {label}: unexpectedly succeeded")

private def sample (size : Nat) : ByteArray := Id.run do
  let mut bytes := ByteArray.emptyWithCapacity size
  for i in [0:size] do
    bytes := bytes.push (UInt8.ofNat ((i * 7 + i / 251) % 256))
  return bytes

private def digest (bytes : ByteArray) : String :=
  LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes bytes)

/-- A provider whose command API is this host's shell: the guest scripts run
    for real against a temporary work directory. -/
private def shellProvider (template : Provider) (calls : IO.Ref (Array String))
    (rewrite : String → String → String := fun _ out => out) : Provider := { template with
  exec := fun _ command _ => do
    calls.modify (·.push command)
    let out ← IO.Process.output { cmd := "sh", args := #["-c", command] }
    return .ok (.obj #[("stdout", .str (rewrite command out.stdout)), ("exitCode", JVal.nat out.exitCode.toNat)])
}

private def same (result : Except String String) (expected : Except String String) : Bool :=
  match result, expected with
  | .ok a, .ok b => a == b
  | .error a, .error b => a == b
  | _, _ => false

private def pathTests : IO Unit := do
  let root := "/var/lib/orb-node/work"
  check (same (confinedPath root "out/a.tar") (.ok s!"{root}/out/a.tar")) "relative path joins the work directory"
  check (same (confinedPath root s!"{root}/out/a b'.tar") (.ok s!"{root}/out/a b'.tar")) "absolute path inside is kept"
  for (raw, expected) in #[
      ("", "harvest_path_missing"), ("   ", "harvest_path_missing"),
      ("/etc/shadow", "harvest_outside_work_dir"), ("/var/lib/orb-node/workx/a", "harvest_outside_work_dir"),
      ("/var/lib/orb-node/work", "harvest_outside_work_dir"),
      ("../../etc/shadow", "harvest_path_invalid"), ("out/../../x", "harvest_path_invalid"),
      (s!"{root}/./a", "harvest_path_invalid"), ("a\nb", "harvest_path_invalid"), ("a\\b", "harvest_path_invalid"),
      (s!"{root}//", "harvest_not_regular_file")] do
    check (same (confinedPath root raw) (.error expected)) s!"path {raw.quote} is refused as {expected}"
  check (deliveryName "/w/out/bundle.tar.gz" == "bundle.tar.gz") "delivery name is the base name"
  check (deliveryName "/w/out/.." == "harvest.bin") "dot names fall back"

private def fetchTests (root : String) (template : Provider) : IO Unit := do
  let work := s!"{root}/harvest-work"
  let outside := s!"{root}/harvest-outside"
  IO.FS.createDirAll s!"{work}/out"
  IO.FS.createDirAll outside
  let payload := sample 10000
  IO.FS.writeBinFile s!"{work}/out/it's a bundle.bin" payload
  IO.FS.writeBinFile s!"{work}/out/empty" ByteArray.empty
  IO.FS.writeBinFile s!"{work}/out/exact" (sample 6000)
  IO.FS.writeBinFile s!"{outside}/secret" (sample 64)
  let linked ← IO.Process.output { cmd := "ln", args := #["-s", s!"{outside}/secret", s!"{work}/out/escape"] }
  check (linked.exitCode == 0) "symlink fixture"
  let calls ← IO.mkRef (#[] : Array String)
  let cfg : Config := { root := work, chunkBytes := 3000, privilege := "" }
  let provider := shellProvider template calls
  -- Binary content spanning several chunks, with a quote and a space in the name.
  match ← fetch provider "vm" "out/it's a bundle.bin" cfg with
  | .error e => throw (IO.userError s!"managed harvest: round trip failed: {e}")
  | .ok got =>
    check (got.bytes == payload && got.sha256 == digest payload) "round trip is byte-identical"
    check (got.chunks == 4 && (← calls.get).size == 5) "one stat and four chunk commands"
    check (got.sourcePath.endsWith "/out/it's a bundle.bin") "resolved path is reported"
  match ← fetch provider "vm" s!"{work}/out/exact" cfg with
  | .ok got => check (got.bytes == sample 6000 && got.chunks == 2) "exact chunk multiple"
  | .error e => throw (IO.userError s!"managed harvest: exact multiple failed: {e}")
  match ← fetch provider "vm" "out/empty" cfg with
  | .ok got => check (got.bytes.size == 0 && got.chunks == 0) "empty file"
  | .error e => throw (IO.userError s!"managed harvest: empty file failed: {e}")
  -- Guest-side confinement and file-type checks.
  expectError (← fetch provider "vm" "out/escape" cfg) "harvest_outside_work_dir" "symlink out of the work directory"
  expectError (← fetch provider "vm" "out/missing" cfg) "harvest_not_found" "missing file"
  expectError (← fetch provider "vm" "out" cfg) "harvest_not_regular_file" "directory"
  -- Lexical refusals and the size cap issue no chunk command.
  calls.set #[]
  expectError (← fetch provider "vm" "/etc/hostname" cfg) "harvest_outside_work_dir" "outside path"
  check ((← calls.get).isEmpty) "a refused path runs nothing on the guest"
  expectError (← fetch provider "vm" "out/exact" { cfg with maxBytes := 5999 })
    "harvest_too_large:6000:5999" "size cap"
  check ((← calls.get).size == 1) "an oversized file is refused after the stat alone"
  expectError (← fetch provider "vm" "out/exact" { cfg with chunkBytes := 1000 }) "harvest_config_invalid" "chunk size"
  -- Core re-hashes: same-length substitution, truncation and garbage all fail closed.
  let secondChunk := chunkCommand cfg (← IO.FS.realPath s!"{work}/out/exact").toString 1
  let swapped := shellProvider template calls (fun command out =>
    if command == secondChunk then OrbBin.PosixExt.base64Encode (sample 3000) else out)
  expectError (← fetch swapped "vm" "out/exact" cfg) "harvest_checksum_mismatch" "substituted chunk"
  let truncated := shellProvider template calls (fun command out =>
    if command == secondChunk then OrbBin.PosixExt.base64Encode (sample 2997) else out)
  expectError (← fetch truncated "vm" "out/exact" cfg) "harvest_file_changed" "short chunk"
  let garbage := shellProvider template calls (fun command out =>
    if command == secondChunk then "not base64!" else out)
  expectError (← fetch garbage "vm" "out/exact" cfg) "harvest_chunk_encoding_invalid" "undecodable chunk"
  let lying := shellProvider template calls (fun command out =>
    if command == statCommand cfg s!"{work}/out/exact" then "ok\n6000\nnot-a-digest\n/x\n" else out)
  expectError (← fetch lying "vm" "out/exact" cfg) "harvest_guest_report_invalid" "malformed report"
  let failing : Provider := { template with exec := fun _ _ _ => pure (.error { code := "boom" }) }
  expectError (← fetch failing "vm" "out/exact" cfg) "harvest_provider_command_failed" "provider failure"
  let nonzero : Provider := { template with
    exec := fun _ _ _ => pure (.ok (.obj #[("stdout", .str ""), ("exitCode", JVal.nat 1)])) }
  expectError (← fetch nonzero "vm" "out/exact" cfg) "harvest_guest_command_failed" "guest failure"

/-- The real dispatcher with the production command shapes: lineage decides
    access, and the reply names the delivered file without carrying its bytes. -/
private def gatewayTests (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/harvest-core"
    | throw (IO.userError "harvest core open failed")
  try
    let .ok mc ← openManagedComputeStore s!"{root}/harvest-managed.db"
      | throw (IO.userError "harvest managed open failed")
    try
      let .ok _ ← execParamQuery store.missionsDb
          "INSERT INTO users(id,username,password_hash,role) VALUES('alice','alice','synthetic-hash','member');" #[]
        | throw (IO.userError "harvest user fixture failed")
      let now : UInt64 := 1000
      let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 100000 }
      let workspace := s!"{root}/harvest-workspace"
      for (id, parent, dir) in #[("owner", "", ""), ("child", "owner", workspace), ("stranger", "", workspace)] do
        let .ok _ ← execParamQuery store.missionsDb
            "INSERT INTO missions(id,parent_mission_id,owner_user_id,project,working_directory) VALUES(?1,?2,'alice','p',?3);"
            #[id, parent, dir]
          | throw (IO.userError "harvest mission fixture failed")
      let seed (id : String) (ready : Bool) : IO Unit := do
        let .ok _ ← provisionManagedMachine mc fleet {
            id, sandboxName := s!"orb-managed-{id}", provider := "boat", ownerMission := "owner",
            ownerUserId := "alice", ownerKind := "mission", ttlMinutes := 5, spentCents := 5
          } now | throw (IO.userError "harvest machine fixture failed")
        let .ok _ ← bindManagedProviderId mc id s!"remote-{id}" 1
          | throw (IO.userError "harvest bind fixture failed")
        if ready then
          let .ok _ ← recordAuthenticatedManagedPoll mc id 1 now
            | throw (IO.userError "harvest ready fixture failed")
      seed "harvest-vm" true
      seed "booting-vm" false
      let payload := sample 150000
      let source := s!"{workRoot}/out/bundle.tar.zst"
      let execIds ← IO.mkRef (#[] : Array String)
      let provider : Provider := { OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat" with
        exec := fun providerId command _ => do
          execIds.modify (·.push providerId)
          if command == statCommand {} source then
            return .ok (.obj #[("result", .obj #[("stdout", .str s!"ok\n{payload.size}\n{digest payload}\n{source}\n")])])
          for index in [0:3] do
            if command == chunkCommand {} source index then
              let chunk := payload.extract (index * 72000) (min payload.size ((index + 1) * 72000))
              return .ok (.obj #[("stdout", .str (OrbBin.PosixExt.base64Encode chunk ++ "\n")), ("exitCode", JVal.nat 0)])
          return .ok (.obj #[("stdout", .str "harvest_not_found\n"), ("exitCode", JVal.nat 0)])
      }
      let call (mission machineId path : String) : IO (String × JVal) := do
        let claims : McpSessionClaims := {
          sessionId := "mission-session", missionId := mission, role := "executor", expiresAt := 2000
        }
        let raw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mc) none none fleet root claims
          "harvest_managed_file" (.obj #[("machine_id", .str machineId), ("path", .str path)]) now none
          (some (provider, { coreUrl := "https://unused.invalid", script := "" }))
        let .ok parsed := OrbBin.Json.parse raw | throw (IO.userError "harvest gateway JSON")
        return (raw, parsed)
      let errorOf (reply : JVal) : Option String × Option String :=
        let err := (reply.field? "error").getD .null
        (err.fieldStr? "code", err.fieldStr? "message")
      -- A descendant of the owning mission receives the file in its own workspace.
      let (raw, reply) ← call "child" "managed-harvest-vm" "out/bundle.tar.zst"
      check (reply.fieldBool? "ok" == some true) s!"lineage harvest succeeds: {raw}"
      let result := (reply.field? "result").getD reply
      let some path := result.fieldStr? "path" | throw (IO.userError s!"managed harvest: no path in {raw}")
      check (path.startsWith s!"{workspace}/harvest/" && path.endsWith "/bundle.tar.zst") "lands in the caller workspace"
      check ((← IO.FS.readBinFile path) == payload) "delivered bytes are identical"
      check (result.fieldStr? "sha256" == some (digest payload) && result.fieldNat? "bytes" == some payload.size &&
        result.fieldNat? "chunks" == some 3 && result.fieldStr? "node" == some "local") "receipt names digest and size"
      check (raw.length < 2000) "the reply does not carry the content"
      check ((← execIds.get).all (· == "remote-harvest-vm")) "commands address the provider id"
      -- Outside the lineage the machine does not exist, and nothing runs on it.
      execIds.set #[]
      let (_, denied) ← call "stranger" "harvest-vm" "out/bundle.tar.zst"
      check (errorOf denied == (some "not_found", some "Managed machine not found")) "foreign mission is refused"
      let (_, unknown) ← call "child" "managed-missing" "out/bundle.tar.zst"
      check ((errorOf unknown).1 == some "not_found") "unknown machine"
      let (_, booting) ← call "child" "booting-vm" "out/bundle.tar.zst"
      check (errorOf booting == (some "harvest_rejected", some "managed_machine_not_running")) "machine must be running"
      let (_, escaped) ← call "child" "harvest-vm" "/home/user/.orb/enroll.env"
      check (errorOf escaped == (some "harvest_rejected", some "harvest_outside_work_dir")) "path outside the work directory"
      check ((← execIds.get).isEmpty) "refusals run nothing on the guest"
      let (_, absent) ← call "child" "harvest-vm" "out/absent"
      check (errorOf absent == (some "harvest_rejected", some "harvest_not_found")) "guest refusal is relayed"
      -- A mission placed by `auto` is delivered to the node its job ran on, never
      -- to a node literally called `auto`, and a failed delivery says where and why.
      let .ok _ ← execParamQuery store.missionsDb
          "UPDATE missions SET tags='[\"remote-node:auto\"]' WHERE id='child';" #[]
        | throw (IO.userError "harvest tag fixture failed")
      let .ok _ ← execParamQuery store.missionsDb
          ("CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', " ++
           "node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
           "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');") #[]
        | throw (IO.userError "harvest job table fixture failed")
      let .ok _ ← execParamQuery store.missionsDb
          "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,updated_at) VALUES('j-child','child','ghost-node','running','2026-01-01T00:00:00Z');" #[]
        | throw (IO.userError "harvest job fixture failed")
      let (_, undelivered) ← call "child" "harvest-vm" "out/bundle.tar.zst"
      check (errorOf undelivered == (some "harvest_rejected", some "harvest_delivery_failed:unreachable:ghost-node"))
        s!"delivery targets the job's node and reports the failure: {(errorOf undelivered).2}"
      -- The default machine list is the live machines only.
      let .ok _ ← execParamQuery mc.db
          "UPDATE managed_machines SET status='destroyed', phase_code=3, created_at_sec=1, expires_at_sec=1 WHERE id='booting-vm';" #[]
        | throw (IO.userError "harvest destroyed fixture failed")
      let listed (verbose : Bool) : IO (Array String) := do
        let claims : McpSessionClaims := { sessionId := "mission-session", missionId := "child", role := "executor", expiresAt := 2000 }
        let raw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mc) none none fleet root claims
          "list_managed_machines" (.obj #[("verbose", .bool verbose)]) now none
          (some (provider, { coreUrl := "https://unused.invalid", script := "" }))
        let reply := (OrbBin.Json.parse raw).toOption.getD .null
        return ((((reply.field? "result").getD .null).fieldArr? "machines").getD #[]).filterMap (·.fieldStr? "id")
      check ((← listed false) == #["harvest-vm"]) s!"destroyed machines are not listed by default: {← listed false}"
      check ((← listed true).size == 2) "a machine destroyed within a day is shown in verbose"
    finally
      closeManagedComputeStore mc
  finally
    closeCoreStore store

def run (root : String) : IO Unit := do
  pathTests
  let .ok mc ← openManagedComputeStore s!"{root}/harvest-fetch.db"
    | throw (IO.userError "harvest fetch store open failed")
  try
    fetchTests root (OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat")
  finally
    closeManagedComputeStore mc
  gatewayTests root

end OrbCore.ManagedHarvestTests
