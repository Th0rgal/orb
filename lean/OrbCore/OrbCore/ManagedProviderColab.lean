/-
  Google Colab managed provider, through the `colab-api` service on the Core host
  (`http://127.0.0.1:8790/v1`) and each runtime's worker over its tunnel.
  Wire contract read from `Th0rgal/colab-api` (`ColabApi/Server.lean`,
  `worker/colab_worker.py`): the control API speaks GET and POST only; a notebook
  is created by name (idempotent on the name), read by ID for its worker URL and
  per-runtime token, and deleted with `POST /notebooks/:id/delete`. The worker
  runs `bash -lc` in `/content` and accepts file uploads only below `/content`,
  so files elsewhere are written through `exec`.
  No snapshots, no stop/resume, and no provider-side lease: Core enforces the TTL.
-/
import OrbCore.ManagedProvider
import OrbBin.PosixExt

namespace OrbCore.ManagedProvider

open OrbBin.Json OrbBin.HttpClient

structure ColabProfile where
  size : Size
  /-- Accelerators to request, best first. -/
  accelerators : Array String

/-- Shadow prices are half the Vast.ai rate for the same accelerator class. -/
def colabProfiles : Array ColabProfile := #[
  { size := { name := "colab-auto", cpu := 8, ramGb := 30, diskGb := 100, milliCentsPerHour := 22500 },
    accelerators := #["H100", "A100", "L4", "T4"] },
  -- Measured on a fresh T4 runtime (2026-11-13, dev): 113 GB root, all free, Tesla T4.
  { size := { name := "t4", cpu := 2, ramGb := 12, diskGb := 113, milliCentsPerHour := 10000 }, accelerators := #["T4"] },
  { size := { name := "l4", cpu := 8, ramGb := 30, diskGb := 100, milliCentsPerHour := 22500 }, accelerators := #["L4"] },
  { size := { name := "a100", cpu := 12, ramGb := 80, diskGb := 150, milliCentsPerHour := 67500 }, accelerators := #["A100"] },
  { size := { name := "h100", cpu := 12, ramGb := 80, diskGb := 150, milliCentsPerHour := 120000 }, accelerators := #["H100"] },
  { size := { name := "v5e1", cpu := 8, ramGb := 32, diskGb := 100, milliCentsPerHour := 47500 }, accelerators := #["V5E1"] },
  { size := { name := "v6e1", cpu := 8, ramGb := 32, diskGb := 100, milliCentsPerHour := 67500 }, accelerators := #["V6E1"] }
]

def colabProfile? (size : String) : Option ColabProfile :=
  colabProfiles.find? (·.size.name == size)

def colabQuoteCents (size : String) (ttlMinutes : UInt64) : Result UInt64 := do
  if ttlMinutes < 5 || ttlMinutes > 720 then throw { code := "provider_invalid_ttl" }
  let some profile := colabProfile? size | throw { code := "provider_invalid_size" }
  return (profile.size.milliCentsPerHour * ttlMinutes + 59999) / 60000

/-- `colab-api` accepts only this shape for a notebook name. -/
def colabValidName (name : String) : Bool :=
  !name.isEmpty && name.length ≤ 64 && name.toList.all (fun c => c.isAlphanum || c == '_' || c == '-')

/-- Seconds the service may spend on each requested accelerator. The service
    tries candidates in turn before it answers, so the per-candidate wait is
    divided to keep the whole create call near seven minutes, inside the
    readiness deadline that started before it. -/
def colabAssignTimeoutSecs (candidates : Nat) : Nat := max 60 (min 180 (420 / max 1 candidates))

def colabSpawnBody (spec : SpawnSpec) : Result JVal := do
  let some profile := colabProfile? spec.size | throw { code := "provider_invalid_size" }
  if !colabValidName spec.name then throw { code := "provider_invalid_name" }
  -- A runtime has no saved images; a restore request must not silently start fresh.
  if !(#["", "orb-node-base", "provider-default"].contains spec.fromSnapshot) then
    throw { code := "provider_snapshots_unsupported" }
  return .obj #[("name", .str spec.name), ("accelerator", .arr (profile.accelerators.map .str)),
    ("assign_timeout_secs", .nat (colabAssignTimeoutSecs profile.accelerators.size)), ("worker", .bool true)]

private def notebookPath (id : String) : String := "/notebooks/" ++ urlEncodeComponent id

/-- A runtime accepts guest commands once its worker tunnel is published. The
    list has no tunnel URL and reports `connected` instead; a notebook record can
    be connected before its tunnel exists, so there only the URL counts. -/
private def colabMachine (item : JVal) (fromList : Bool := false) : Result Machine := do
  let id := (item.fieldStr? "id").getD ""
  if id.trimAscii.toString.isEmpty then throw { code := "provider_missing_machine_id" }
  let reachable := if fromList then item.fieldBool? "connected" == some true
    else ((item.fieldStr? "worker_url").filter (!·.isEmpty)).isSome
  return { providerId := id, name := (item.fieldStr? "name").getD "", state := if reachable then "running" else "provisioning" }

/-- The worker's address and per-runtime token come only from the notebook
    record. Anything but an HTTPS URL without whitespace is refused. -/
private def colabWorker (api : Transport) (id : String) : IO (Result (String × String)) := do
  match ← call api { method := "GET", path := notebookPath id } with
  | .error e => return .error e
  | .ok body =>
    let url := (body.fieldStr? "worker_url").getD ""
    let token := (body.fieldStr? "worker_token").getD ""
    if !url.startsWith "https://" || url.any (fun c => c.isWhitespace) || token.isEmpty then
      return .error { status := 502, code := "provider_worker_unavailable" }
    return .ok (String.ofList (url.toList.reverse.dropWhile (· == '/')).reverse, token)

private def shellQuote (s : String) : String := "'" ++ String.intercalate "'\\''" (s.splitOn "'") ++ "'"

/-- Accounts, running notebooks and eligible accelerators decide availability.
    A failed accelerator listing is tolerated, as the service omits accounts it
    cannot query; a failed account listing is not. -/
def colabAvailabilityOf (spec : SpawnSpec) (accounts : JVal) (notebooks accelerators : Option JVal) : Availability :=
  match accounts.fieldArr? "accounts" with
  | none => { status := .unknown, reason := "accounts_incomplete" }
  | some all =>
    let usable := (all.filter (·.fieldBool? "usable" == some true)).size
    let listed := (notebooks.bind (·.fieldArr? "notebooks")).map (·.size)
    let eligible := accelerators.map fun body =>
      ((body.fieldArr? "accounts").getD #[]).foldl (fun acc account =>
        acc ++ (((account.fieldArr? "available").getD #[]).filter (·.fieldBool? "eligible" == some true)).filterMap
          (·.fieldStr? "accelerator")) (#[] : Array String)
    if usable == 0 then { status := .saturated, reason := "no_usable_account" }
    else if listed.any (· ≥ usable) then { status := .saturated, reason := "all_accounts_busy" }
    else match eligible with
      | some names =>
        if names.isEmpty then { status := .saturated, reason := "no_eligible_accelerator" }
        else match colabProfile? spec.size with
          | some profile =>
            if !profile.accelerators.any names.contains then { status := .saturated, reason := "accelerator_ineligible" }
            else if usable < all.size then { status := .degraded, reason := "some_accounts_unusable" }
            else if !(#["H100", "A100", "L4", "V6E1", "V5E1"].any names.contains) then { status := .degraded, reason := "only_t4_eligible" }
            else { status := .available }
          | none =>
            if usable < all.size then { status := .degraded, reason := "some_accounts_unusable" } else { status := .available }
      | none =>
        if usable < all.size then { status := .degraded, reason := "some_accounts_unusable" }
        else { status := .available, reason := "accelerators_not_observed" }

abbrev ColabAvailabilityCache := IO.Ref (Option (Nat × JVal × Option JVal × Option JVal))

initialize colabAvailabilityCache : ColabAvailabilityCache ← IO.mkRef none

private def unsupportedColab {α : Type} : IO (Result α) :=
  pure (.error { code := "provider_operation_unsupported" })

/-- `worker` builds the transport for one runtime from its URL and token. -/
def colab (api : Transport)
    (worker : String → String → Transport := fun url token => httpTransport url token)
    (cache : ColabAvailabilityCache := colabAvailabilityCache) (nowMs : IO Nat := IO.monoMsNow)
    (sleep : UInt32 → IO Unit := fun ms => do IO.sleep ms) : Provider :=
  let execOnce (id script : String) (timeout : UInt32) : IO (Result JVal) := do
    match ← colabWorker api id with
    | .error e => return .error e
    | .ok (url, token) =>
      let request : Request := {
        method := "POST"
        path := "/exec"
        body := some (.obj #[("cmd", .str script), ("timeout", .nat timeout.toNat)])
        timeoutMs := timeout * 1000 + 30000
      }
      match ← call (worker url token) request with
      | .error e => return .error e
      | .ok reply =>
        -- A timed-out command has no exit code: that is a failure, never success.
        if (reply.fieldInt? "exit_code").isNone || reply.fieldBool? "timed_out" == some true then
          return .error { code := "provider_exec_failed" }
        return .ok reply
  -- A quick tunnel drops requests for a moment now and then. Those answers come
  -- from the tunnel edge or from a record without a tunnel yet, before the
  -- worker ran anything, so one retry after re-reading the record is safe. A
  -- lost connection (no status) is not retried: the command may have run.
  let execOn (id script : String) (timeoutSecs : UInt32) : IO (Result JVal) := do
    let timeout := max 1 (min timeoutSecs 600)
    match ← execOnce id script timeout with
    | .ok reply => return .ok reply
    | .error e =>
      if !(#[502, 503, 530].contains e.status) then return .error e
      sleep 2000
      execOnce id script timeout
  {
    name := "colab"
    readinessDeadlineSecs := 900
    isReady := fun s => s == "running"
    isStopped := fun s => #["stopped", "deleted", "error", "failed", "offline"].contains s
    quoteCents := colabQuoteCents
    availability := fun spec => do
      let now ← nowMs
      let (accounts, notebooks, accelerators) ← match ← cache.get with
        | some (stamp, a, n, x) => if now < stamp + 30000 then pure (a, n, x) else pure (JVal.null, none, none)
        | none => pure (JVal.null, none, none)
      if accounts != .null then return .ok (colabAvailabilityOf spec accounts notebooks accelerators)
      match ← call api { method := "GET", path := "/accounts" } with
      | .error e => return .error e
      | .ok accounts =>
        let notebooks := (← call api { method := "GET", path := "/notebooks" }).toOption
        -- Eligibility is only meaningful, and only answered, for usable accounts.
        let anyUsable := ((accounts.fieldArr? "accounts").getD #[]).any (·.fieldBool? "usable" == some true)
        let accelerators ← if anyUsable
          then pure (← call api { method := "GET", path := "/accelerators", timeoutMs := 60000 }).toOption
          else pure none
        cache.set (some (now, accounts, notebooks, accelerators))
        return .ok (colabAvailabilityOf spec accounts notebooks accelerators)
    spawn := fun spec => do
      if spec.idempotencyKey.isEmpty then return .error { code := "provider_idempotency_key_required" }
      match colabSpawnBody spec with
      | .error e => return .error e
      | .ok body =>
        -- The service tries each accelerator in turn before it answers.
        let candidates := ((colabProfile? spec.size).map (·.accelerators.size)).getD 1
        let request : Request := {
          method := "POST"
          path := "/notebooks"
          body := some body
          timeoutMs := ((candidates * colabAssignTimeoutSecs candidates + 90) * 1000).toUInt32
        }
        cache.set none
        match ← call api request with
        | .error e => return .error e
        | .ok reply => return colabMachine reply
    get := fun id => do
      match ← call api { method := "GET", path := notebookPath id } with
      | .error e => return .error e
      | .ok body => return colabMachine body
    list := do
      match ← call api { method := "GET", path := "/notebooks" } with
      | .error e => return .error e
      | .ok body =>
        let some items := body.fieldArr? "notebooks" | return .error { code := "provider_invalid_machine_list" }
        let mut out := #[]
        for item in items do
          match colabMachine item true with
          | .error e => return .error e
          | .ok machine => out := out.push machine
        return .ok out
    destroy := fun id => do
      cache.set none
      match ← callUnit api { method := "POST", path := notebookPath id ++ "/delete", body := some (.obj #[]), timeoutMs := 60000 } with
      | .error e => if e.status == 404 then return .ok () else return .error e
      | .ok () => return .ok ()
    stop := fun _ => unsupportedColab
    resume := fun _ _ => unsupportedColab
    fork := fun _ _ => unsupportedColab
    -- A runtime has no lease at the provider; Core's own TTL is the only one.
    extend := fun _ _ => pure (.ok ())
    saveSnapshot := fun _ _ => unsupportedColab
    getSnapshot := fun _ => unsupportedColab
    listSnapshots := pure (.ok #[])
    deleteSnapshot := fun _ => unsupportedColab
    -- The worker's upload route cannot leave `/content`, so write through exec:
    -- decode beside the target, restrict the mode, then rename into place.
    writeFile := fun id path content => do
      if !path.startsWith "/" || path.contains '\n' then return .error { code := "provider_invalid_path" }
      let target := shellQuote path
      let script := "set -e; umask 077; mkdir -p \"$(dirname " ++ target ++ ")\"; printf %s " ++
        shellQuote (OrbBin.PosixExt.base64Encode content.toUTF8) ++ " | base64 -d > " ++ target ++ ".tmp; chmod 600 " ++
        target ++ ".tmp; mv -f " ++ target ++ ".tmp " ++ target
      return (← execOn id script 60).map (fun _ => ())
    -- The worker runs as root; `sudo` in the shared bootstrap command is a shim
    -- when the runtime image does not ship it.
    exec := fun id command timeoutSecs =>
      execOn id (sudoShim ++ command) timeoutSecs
  }

def colabDeclaration : Declaration := {
  name := "colab"
  displayName := "Google Colab"
  secretName := "COLAB_API_TOKEN"
  apiBaseEnv := "COLAB_API_URL"
  defaultApiBase := "http://127.0.0.1:8790/v1"
  sizes := colabProfiles.map (·.size)
  readinessDeadlineSecs := 900
  bootstrapMode := .execSupervised
  supportsStopResume := false
  supportsSnapshots := false
  supportsExtend := true
  quoteCents := colabQuoteCents
  create := fun transport => colab transport
  -- A notebook ID is `<runtime>~<Google account email>`. The pool's accounts
  -- are the operator's; a user who rents a runtime sees only the runtime part.
  publicId := fun id => (id.splitOn "~").headD id
}

end OrbCore.ManagedProvider
