/-
  lean.ci managed provider (`https://api.lean.ci/v1`), named `leanci` only.
  Wire contract read from `lfglabs-dev/lean.ci` `crates/leanci-ctrl/src/vms.rs`:
  `POST /vms` (202, `{vm}`), `GET /vms`, `GET|DELETE /vms/:id`, `POST /vms/:id/exec`
  (argv array, `as_root`), `PUT /vms/:id/files` (`content_b64`), `POST /vms/:id/snapshots`,
  `GET /vms/snapshots`, `DELETE /vms/snapshots/:id`, `GET /vms/capabilities`.
  No stop/resume and no live TTL extension exist at the provider.
-/
import OrbCore.ManagedProvider
import OrbBin.PosixExt

namespace OrbCore.ManagedProvider

open OrbBin.Json OrbBin.HttpClient

structure LeanciProfile where
  size : Size
  aliases : Array String := #[]
  runnerLabel : String
  /-- Sent as `memory_mib` when the size differs from the label's default RAM. -/
  memoryMiB : Option UInt64 := none

/-- Sizes and prices decided by Thomas (plan, lean.ci item 3). Disk is the root
    filesystem a guest reports. Only `small` has been measured (2026-11-13, dev):
    98 GB, of which about 14 GB is free on a fresh VM, the rest being the image
    and toolchains; `/workspace` is on the same filesystem. The larger sizes still
    carry the planned figures. -/
def leanciProfiles : Array LeanciProfile := #[
  { size := { name := "small", cpu := 2, ramGb := 8, diskGb := 98, milliCentsPerHour := 1800 },
    runnerLabel := "lean-2vcpu-ubuntu-2604" },
  { size := { name := "default", cpu := 4, ramGb := 16, diskGb := 75, milliCentsPerHour := 3600 },
    aliases := #["medium"], runnerLabel := "lean-4vcpu-ubuntu-2604" },
  { size := { name := "large", cpu := 8, ramGb := 32, diskGb := 100, milliCentsPerHour := 7200 },
    runnerLabel := "lean-8vcpu-ubuntu-2604" },
  { size := { name := "xlarge", cpu := 16, ramGb := 64, diskGb := 150, milliCentsPerHour := 20000 },
    runnerLabel := "lean-16vcpu-ubuntu-2604" },
  { size := { name := "lean-24vcpu", cpu := 24, ramGb := 96, diskGb := 175, milliCentsPerHour := 30000 },
    runnerLabel := "lean-24vcpu-ubuntu-2604" },
  { size := { name := "2xlarge", cpu := 32, ramGb := 96, diskGb := 200, milliCentsPerHour := 40000 },
    runnerLabel := "lean-32vcpu-ubuntu-2604", memoryMiB := some 98304 }
]

def leanciProfile? (size : String) : Option LeanciProfile :=
  leanciProfiles.find? (fun p => p.size.name == size || p.aliases.contains size || p.runnerLabel == size)

/-- Orb caps leases at 720 minutes although lean.ci accepts up to 86,400 s. -/
def leanciQuoteCents (size : String) (ttlMinutes : UInt64) : Result UInt64 := do
  if ttlMinutes < 5 || ttlMinutes > 720 then throw { code := "provider_invalid_ttl" }
  let some profile := leanciProfile? size | throw { code := "provider_invalid_size" }
  return (profile.size.milliCentsPerHour * ttlMinutes + 59999) / 60000

def leanciMaxBootableMemoryMiB : UInt64 := 107520

def leanciValidMemoryMiB (value : UInt64) : Bool :=
  4096 ≤ value && value ≤ leanciMaxBootableMemoryMiB && value % 1024 == 0

private def isUuid (s : String) : Bool :=
  s.length == 36 && s.toList.all (fun c => c == '-' || c.isDigit || ('a' ≤ c && c ≤ 'f'))

def leanciSpawnBody (spec : SpawnSpec) : Result JVal := do
  let some profile := leanciProfile? spec.size | throw { code := "provider_invalid_size" }
  if spec.ttlSeconds < 60 || spec.ttlSeconds > 86400 then throw { code := "provider_invalid_ttl" }
  let memory := spec.memoryMiB.orElse (fun _ => profile.memoryMiB)
  if let some value := memory then
    if !leanciValidMemoryMiB value then throw { code := "provider_invalid_memory" }
  let mut fields : Array (String × JVal) := #[
    ("name", .str spec.name), ("runner_label", .str profile.runnerLabel),
    ("ttl_secs", JVal.uint64 spec.ttlSeconds)]
  if let some value := memory then fields := fields.push ("memory_mib", JVal.uint64 value)
  if !spec.repo.isEmpty then fields := fields.push ("repo", .str spec.repo)
  -- Core's two base-image names mean a fresh VM. Anything else must be a
  -- snapshot ID: booting fresh when a restore was asked for would be silent data loss.
  if isUuid spec.fromSnapshot then fields := fields.push ("snapshot_id", .str spec.fromSnapshot)
  else if !(#["", "orb-node-base", "provider-default"].contains spec.fromSnapshot) then
    throw { code := "provider_snapshot_id_required" }
  return .obj fields

private def leanciMachine (body : JVal) : Result Machine := do
  let vm := (body.field? "vm").getD body
  let id := (vm.fieldStr? "id").getD ""
  if id.trimAscii.toString.isEmpty then throw { code := "provider_missing_machine_id" }
  return { providerId := id, name := (vm.fieldStr? "name").getD "", state := (vm.fieldStr? "status").getD "unknown" }

private def vmPath (id : String) : String := "/vms/" ++ urlEncodeComponent id

private def leanciSnapshot (item : JVal) : Option (String × Snapshot) := do
  let id ← item.fieldStr? "id"
  let label := ((item.fieldStr? "label").filter (!·.isEmpty)).getD id
  some (id, { name := label, status := (item.fieldStr? "status").getD "unknown", sizeBytes := item.fieldUInt64? "size_bytes" })

private def leanciSnapshots (transport : Transport) : IO (Result (Array (String × Snapshot))) := do
  match ← call transport { method := "GET", path := "/vms/snapshots" } with
  | .error e => return .error e
  | .ok body =>
    let some items := body.fieldArr? "snapshots" | return .error { code := "provider_invalid_snapshot_list" }
    let parsed := items.filterMap leanciSnapshot
    -- A malformed entry is an error, never a silently shorter list.
    if parsed.size != items.size then return .error { code := "provider_invalid_snapshot_list" }
    return .ok parsed

/-- Capacity for one request, from `GET /vms/capabilities`. Pool exhaustion and a
    profile that cannot boot now are `saturated`; a reply this client cannot
    interpret is `unknown`, which admission rejects. -/
def leanciAvailabilityOf (spec : SpawnSpec) (body : JVal) : Availability :=
  let pool := (body.field? "pool").getD .null
  let effective := (body.field? "effective").getD .null
  match pool.fieldUInt64? "online_engines", effective.fieldUInt64? "schedulable_vcpus" with
  | some engines, some vcpus =>
    if engines == 0 then { status := .saturated, reason := "no_online_engines" }
    else if vcpus == 0 then { status := .saturated, reason := "no_schedulable_vcpus" }
    else match leanciProfile? spec.size with
      | none => { status := .unknown, reason := "provider_invalid_size" }
      | some profile =>
        let bootable := (effective.field? "largest_bootable_vm").getD .null
        let memory := (spec.memoryMiB.orElse (fun _ => profile.memoryMiB)).getD (profile.size.ramGb.toUInt64 * 1024)
        let entry := ((body.fieldArr? "profiles").getD #[]).find? (·.fieldStr? "runner_label" == some profile.runnerLabel)
        let memoryCeiling := min leanciMaxBootableMemoryMiB
          (((body.fieldUInt64? "largest_bootable_memory_mib").orElse
            (fun _ => effective.fieldUInt64? "largest_bootable_memory_mib")).getD leanciMaxBootableMemoryMiB)
        match entry with
        | some item =>
          let raw := (item.fieldStr? "blocking_reason").getD ""
          let reason := if #["no_online_engines", "quota_vcpus", "pool_vcpus", "pool_memory"].contains raw then raw else "profile_not_bootable"
          if memory > memoryCeiling then { status := .saturated, reason := "largest_bootable_memory_mib" }
          else if profile.size.cpu.toUInt64 > vcpus then { status := .saturated, reason := "pool_vcpus" }
          else if let some poolMemory := effective.fieldUInt64? "schedulable_memory_mib" then
            if memory > poolMemory then { status := .saturated, reason := "pool_memory" }
            else match item.fieldUInt64? "max_launchable_now" with
              | some 0 => { status := .saturated, reason }
              | some _ =>
                let defaultMemory := (item.fieldUInt64? "default_memory_mib").getD (profile.size.ramGb.toUInt64 * 1024)
                if memory ≤ defaultMemory then { status := .available }
                else match bootable.fieldUInt64? "vcpus", bootable.fieldUInt64? "memory_mib" with
                  | some cpu, some ram =>
                    if profile.size.cpu.toUInt64 ≤ cpu && memory ≤ ram then { status := .available }
                    else { status := .unknown, reason := "custom_memory_capacity_unknown" }
                  | _, _ => { status := .unknown, reason := "custom_memory_capacity_unknown" }
              | none => { status := .unknown, reason := "capabilities_incomplete" }
          else { status := .unknown, reason := "capabilities_incomplete" }
        | none => { status := .unknown, reason := "capabilities_incomplete" }
  | _, _ => { status := .unknown, reason := "capabilities_incomplete" }

def leanciCatalogProfiles (body : JVal) : Array LeanciProfile :=
  leanciProfiles.filter fun profile =>
    (leanciAvailabilityOf { name := "", size := profile.size.name, ttlSeconds := 300, idempotencyKey := "" } body).status == .available

abbrev LeanciCapabilityCache := IO.Ref (Array (String × Nat × JVal))

initialize leanciCapabilityCache : LeanciCapabilityCache ← IO.mkRef #[]

private def capabilitiesQuery (spec : SpawnSpec) : String :=
  if isUuid spec.fromSnapshot then "?snapshot_id=" ++ urlEncodeComponent spec.fromSnapshot
  else if !spec.repo.isEmpty then "?repo=" ++ urlEncodeComponent spec.repo
  else ""

/-- 20 s cache keyed by the warm-image query. Only successful replies are cached. -/
def leanciCapabilities (transport : Transport) (cache : LeanciCapabilityCache)
    (nowMs : IO Nat) (spec : SpawnSpec) : IO (Result JVal) := do
  let query := capabilitiesQuery spec
  let now ← nowMs
  if let some (_, _, body) := (← cache.get).find? (fun (key, stamp, _) => key == query && now < stamp + 20000) then
    return .ok body
  match ← call transport { method := "GET", path := "/vms/capabilities" ++ query } with
  | .error e => return .error e
  | .ok body =>
    cache.modify fun entries => (entries.filter (fun (key, stamp, _) => key != query && now < stamp + 20000)).push (query, now, body)
    return .ok body

private def unsupported {α : Type} : IO (Result α) :=
  pure (.error { code := "provider_operation_unsupported" })

def leanci (transport : Transport) (cache : LeanciCapabilityCache := leanciCapabilityCache)
    (nowMs : IO Nat := IO.monoMsNow) : Provider := {
  name := "leanci"
  readinessDeadlineSecs := 480
  isReady := fun s => s == "running"
  isStopped := fun s => #["stopped", "failed", "reaped", "deleted", "error"].contains s
  quoteCents := leanciQuoteCents
  availability := fun spec => do
    match ← leanciCapabilities transport cache nowMs spec with
    | .error e => return .error e
    | .ok body => return .ok (leanciAvailabilityOf spec body)
  spawn := fun spec => do
    if spec.idempotencyKey.isEmpty then return .error { code := "provider_idempotency_key_required" }
    -- Core names snapshots by label; the API restores by ID. Resolve to a ready
    -- snapshot or refuse: a label that matches nothing must not boot a fresh VM.
    let spec ← if isUuid spec.fromSnapshot || #["", "orb-node-base", "provider-default"].contains spec.fromSnapshot
      then pure spec
      else match ← leanciSnapshots transport with
        | .error e => return .error e
        | .ok items =>
          match items.find? (fun (_, snap) => snap.name == spec.fromSnapshot && snap.status == "ready") with
          | some (id, _) => pure { spec with fromSnapshot := id }
          | none => return .error { status := 404, code := "provider_snapshot_missing" }
    match leanciSpawnBody spec with
    | .error e => return .error e
    | .ok body =>
      let request : Request := {
        method := "POST"
        path := "/vms"
        body := some body
        idempotencyKey := spec.idempotencyKey
        timeoutMs := 120000
      }
      match ← call transport request with
      | .error e => return .error e
      | .ok reply => return leanciMachine reply
  get := fun id => do
    match ← call transport { method := "GET", path := vmPath id } with
    | .error e => return .error e
    | .ok body => return leanciMachine body
  list := do
    match ← call transport { method := "GET", path := "/vms" } with
    | .error e => return .error e
    | .ok body =>
      let some items := body.fieldArr? "vms" | return .error { code := "provider_invalid_machine_list" }
      let mut out := #[]
      for item in items do
        match leanciMachine item with
        | .error e => return .error e
        | .ok machine => out := out.push machine
      return .ok out
  destroy := fun id => do
    match ← callUnit transport { method := "DELETE", path := vmPath id } with
    | .error e => if e.status == 404 then return .ok () else return .error e
    | .ok () => return .ok ()
  stop := fun _ => unsupported
  resume := fun _ _ => unsupported
  fork := fun _ _ => unsupported
  extend := fun _ _ => unsupported
  saveSnapshot := fun id name => do
    -- The server rejects other labels with 400; refuse before the 10-minute call.
    if name.isEmpty || name.length > 63 || !name.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.') then
      return .error { code := "provider_invalid_snapshot_label" }
    callUnit transport {
      method := "POST"
      path := vmPath id ++ "/snapshots"
      body := some (.obj #[("label", .str name)])
      timeoutMs := 630000
    }
  getSnapshot := fun name => do
    match ← leanciSnapshots transport with
    | .error e => return .error e
    | .ok items =>
      -- Labels are not unique and failed saves stay listed: prefer a ready one.
      let named := items.filter (fun (id, snap) => snap.name == name || id == name)
      match (named.find? (·.2.status == "ready")).orElse (fun _ => named[0]?) with
      | some (_, snap) => return .ok snap
      | none => return .error { status := 404, code := "provider_snapshot_missing" }
  listSnapshots := do return (← leanciSnapshots transport).map (·.map Prod.snd)
  deleteSnapshot := fun name => do
    match ← leanciSnapshots transport with
    | .error e => return .error e
    | .ok items =>
      -- Every entry carrying the label goes, including failed saves. A 409
      -- (still saving, or a VM is booting from it) is reported, not hidden.
      for (id, snap) in items do
        if snap.name == name || id == name then
          if let .error e ← callUnit transport { method := "DELETE", path := "/vms/snapshots/" ++ urlEncodeComponent id } then
            if e.status != 404 then return .error e
      return .ok ()
  -- `PUT /vms/:id/files` with base64 content; private by default (0600).
  writeFile := fun id path content => callUnit transport {
    method := "PUT"
    path := vmPath id ++ "/files"
    timeoutMs := 130000
    body := some (.obj #[("path", .str path),
      ("content_b64", .str (OrbBin.PosixExt.base64Encode content.toUTF8)), ("mode", .nat 0o600)])
  }
  -- Exec runs as root, so `sudo` in the shared bootstrap command is a no-op shim
  -- when the image does not ship it. A reply without an exit code that is not
  -- `ok` (timeout, guest unreachable) is a failure, never a silent success.
  exec := fun id command timeoutSecs => do
    let timeout := max 1 (min timeoutSecs 600)
    let script := sudoShim ++ command
    -- The server rejects an argument over 4096 bytes and waits max(t+30, 120) s
    -- for the guest; wait longer than that so its answer is not lost.
    if script.utf8ByteSize > 4096 then return .error { code := "provider_exec_command_too_long" }
    let request : Request := {
      method := "POST"
      path := vmPath id ++ "/exec"
      body := some (.obj #[("command", .arr #[.str "bash", .str "-c", .str script]),
        ("timeout_secs", .nat timeout.toNat), ("as_root", .bool true)])
      timeoutMs := (max (timeout + 30) 120 + 10) * 1000
    }
    match ← call transport request with
    | .error e => return .error e
    | .ok reply =>
      if reply.fieldBool? "ok" != some true && (reply.fieldInt? "exit_code").isNone then
        return .error { code := "provider_exec_failed" }
      return .ok reply
}

def leanciDeclaration : Declaration := {
  name := "leanci"
  displayName := "lean.ci"
  secretName := "LEANCI_API_KEY"
  apiBaseEnv := "LEANCI_API_URL"
  defaultApiBase := "https://api.lean.ci/v1"
  sizes := leanciProfiles.map (·.size)
  readinessDeadlineSecs := 480
  bootstrapMode := .execSystemd
  supportsStopResume := false
  supportsSnapshots := true
  supportsExtend := false
  quoteCents := leanciQuoteCents
  create := fun transport => leanci transport
}

end OrbCore.ManagedProvider
