import OrbCore.ManagedProviderRegistry

namespace OrbCore.ManagedProviderColabTests

open OrbCore.ManagedProvider OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"Colab provider contract: {label}")

private def accountsBody (usable total : Nat) : JVal := .obj #[("accounts", .arr
  ((Array.range total).map fun i => .obj #[("email", .str s!"a{i}@example.com"), ("usable", .bool (decide (i < usable)))]))]

private def acceleratorsBody (eligible : Array String) : JVal := .obj #[("accounts", .arr #[.obj #[
  ("account", .str "a0@example.com"),
  ("available", .arr (eligible.map fun name => .obj #[("accelerator", .str name), ("eligible", .bool true)]))]])]

/-- Mock control API and worker that behave like `colab-api`: GET and POST only,
    401 before routing, name validation, 404 for a gone runtime, 502 before the
    tunnel is published, and a worker that requires the per-runtime token. -/
def run : IO Unit := do
  let apiRequests ← IO.mkRef (#[] : Array Request)
  let workerRequests ← IO.mkRef (#[] : Array (String × String × Request))
  let accounts ← IO.mkRef (accountsBody 2 2)
  let notebooks ← IO.mkRef (#[] : Array JVal)
  let eligible ← IO.mkRef #["T4", "L4"]
  let tunnelUp ← IO.mkRef true
  let clock ← IO.mkRef (0 : Nat)
  let cache ← IO.mkRef none
  let notebookId := "rt-1~a0@example.com"
  let api : Transport := fun req => do
    apiRequests.modify (·.push req)
    if req.method != "GET" && req.method != "POST" then return .ok (400, .obj #[("error", .str "bad request")])
    let body := req.body.getD .null
    if req.method == "GET" && req.path == "/accounts" then return .ok (200, ← accounts.get)
    if req.method == "GET" && req.path == "/accelerators" then return .ok (200, acceleratorsBody (← eligible.get))
    if req.method == "GET" && req.path == "/notebooks" then return .ok (200, .obj #[("notebooks", .arr (← notebooks.get))])
    if req.method == "POST" && req.path == "/notebooks" then
      let name := (body.fieldStr? "name").getD ""
      if !colabValidName name || (body.fieldArr? "accelerator").isNone then
        return .ok (400, .obj #[("error", .str "bad notebook name")])
      let item := JVal.obj #[("id", .str notebookId), ("name", .str name), ("accelerator", .str "T4"),
        ("worker_url", .null), ("job_errors", .arr #[])]
      notebooks.set #[.obj #[("id", .str notebookId), ("name", .str name), ("connected", .bool false)]]
      return .ok (201, item)
    -- The ID contains `~` and `@`; an unencoded path would not match.
    if req.path == "/notebooks/rt-1~a0%40example.com" && req.method == "GET" then
      if (← notebooks.get).isEmpty then return .ok (404, .obj #[("error", .str "HTTP 404")])
      if !(← tunnelUp.get) then return .ok (502, .obj #[("error", .str "no connection info")])
      return .ok (200, .obj #[("id", .str notebookId), ("name", .str "orb-managed-dev-t"),
        ("worker_url", .str "https://unit-test.trycloudflare.com/"), ("worker_token", .str "per-runtime-token")])
    if req.path == "/notebooks/rt-1~a0%40example.com/delete" && req.method == "POST" then
      notebooks.set #[]
      return .ok (200, .obj #[("deleted", .str notebookId)])
    return .ok (404, .obj #[("error", .str "HTTP 404")])
  let worker : String → String → Transport := fun url token req => do
    workerRequests.modify (·.push (url, token, req))
    if token != "per-runtime-token" then return .ok (401, .obj #[("error", .str "unauthorized")])
    let body := req.body.getD .null
    if req.method == "POST" && req.path == "/exec" then
      let some cmd := body.fieldStr? "cmd" | return .ok (400, .obj #[("error", .str "missing cmd")])
      if (cmd.splitOn "sleep-forever").length > 1 then
        return .ok (200, .obj #[("exit_code", .null), ("timed_out", .bool true), ("output", .str "")])
      return .ok (200, .obj #[("exit_code", .nat 0), ("timed_out", .bool false), ("output", .str "")])
    return .ok (404, .null)
  let provider := colab api worker cache clock.get

  let some entry := declaration? "colab" | throw (IO.userError "colab missing from registry")
  check (entry.secretName == "COLAB_API_TOKEN" && entry.defaultApiBase == "http://127.0.0.1:8790/v1" &&
    entry.bootstrapMode == .execSupervised && !entry.supportsSnapshots && !entry.supportsStopResume &&
    entry.sizes.map (·.name) == #["colab-auto", "t4", "l4", "a100", "h100", "v5e1", "v6e1"]) "declaration"
  check ((quote "colab" "t4" 60).toOption == some 10 && (quote "colab" "l4" 60).toOption == some 23 &&
    (quote "colab" "a100" 60).toOption == some 68 && (quote "colab" "h100" 60).toOption == some 120 &&
    (quote "colab" "v5e1" 60).toOption == some 48 && (quote "colab" "colab-auto" 720).toOption == some 270 &&
    !(quote "colab" "small" 60).isOk && !(quote "colab" "t4" 721).isOk) "shadow prices at half the Vast.ai rate"

  let spec : SpawnSpec := { name := "orb-managed-dev-t", size := "t4", ttlSeconds := 600, idempotencyKey := "k1" }
  let before := (← apiRequests.get).size
  check (!(← provider.spawn { spec with name := "bad name!" }).isOk && !(← provider.spawn { spec with idempotencyKey := "" }).isOk &&
    !(← provider.spawn { spec with fromSnapshot := "warm" }).isOk && !(← provider.spawn { spec with size := "small" }).isOk &&
    (← apiRequests.get).size == before) "invalid name, missing key, snapshot or unknown size refused before I/O"
  let .ok created ← provider.spawn spec | throw (IO.userError "spawn failed")
  let sent := ((← apiRequests.get).back!.body.getD .null)
  check (created.providerId == notebookId && !provider.isReady created.state &&
    (sent.fieldArr? "accelerator").map (·.size) == some 1 && sent.fieldBool? "worker" == some true &&
    sent.fieldNat? "assign_timeout_secs" == some 180 && (← apiRequests.get).back!.timeoutMs == 270000)
    "create by name with the accelerator list; no tunnel yet is not ready"
  let .ok auto := colabSpawnBody { spec with size := "colab-auto" } | throw (IO.userError "auto body")
  check ((auto.fieldArr? "accelerator").map (·.filterMap JVal.asStr?) == some #["H100", "A100", "L4", "T4"]) "auto order, GPUs only"

  tunnelUp.set false
  check (!(← provider.get notebookId).isOk && !(← provider.exec notebookId "true" 30).isOk) "no tunnel yet: neither ready nor executable"
  tunnelUp.set true
  let .ok ready ← provider.get notebookId | throw (IO.userError "get failed")
  let .ok listed ← provider.list | throw (IO.userError "list failed")
  check (provider.isReady ready.state && listed.size == 1 && !listed.any (fun m => provider.isReady m.state)) "ready follows the published tunnel"

  let .ok ran ← provider.exec notebookId "echo ok" 90 | throw (IO.userError "exec failed")
  let (url, token, execReq) := (← workerRequests.get).back!
  let execBody := execReq.body.getD .null
  check (ran.fieldInt? "exit_code" == some 0 && url == "https://unit-test.trycloudflare.com" && token == "per-runtime-token" &&
    execReq.path == "/exec" && execBody.fieldNat? "timeout" == some 90 &&
    ((execBody.fieldStr? "cmd").map (·.endsWith "echo ok")) == some true) "exec on the worker with the per-runtime token"
  check (!(← provider.exec notebookId "sleep-forever" 5).isOk) "a timed-out command is a failure"
  check ((← provider.writeFile notebookId "/home/user/.orb/enroll.env" "A='1'\n").isOk &&
    !(← provider.writeFile notebookId "relative/path" "x").isOk) "file write"
  let (_, _, fileReq) := (← workerRequests.get).back!
  let fileCmd := ((fileReq.body.getD .null).fieldStr? "cmd").getD ""
  check (fileReq.method == "POST" && fileReq.path == "/exec" && (fileCmd.splitOn "QT0nMScK").length == 2 &&
    (fileCmd.splitOn "chmod 600 '/home/user/.orb/enroll.env'.tmp").length == 2 &&
    (fileCmd.splitOn "A='1'").length == 1) "files outside /content go through exec as base64, mode 0600, never as raw text"

  check ((← provider.extend notebookId 600).isOk && !(← provider.stop notebookId).isOk &&
    !(← provider.saveSnapshot notebookId "warm").isOk && (← provider.listSnapshots).toOption == some #[])
    "no provider lease to extend; stop and snapshots are unsupported, not faked"
  check ((← provider.destroy notebookId).isOk && (← apiRequests.get).back!.method == "POST" &&
    !(← provider.get notebookId).isOk && (← provider.destroy notebookId).isOk) "delete is a POST; a gone runtime answers 404"

  -- Availability from accounts, running notebooks and eligible accelerators; 30 s cache.
  let observe (s : SpawnSpec) : IO Availability := do
    let .ok value ← provider.availability s | throw (IO.userError "availability failed")
    return value
  apiRequests.set #[]
  check ((← observe spec).status == .available && (← apiRequests.get).size == 3) "available"
  check ((← observe spec).status == .available && (← apiRequests.get).size == 3) "cached within 30 s"
  check ((← observe { spec with size := "h100" }).status == .saturated) "requested accelerator not eligible"
  clock.set 30001
  accounts.set (accountsBody 1 2)
  check ((← observe spec).status == .degraded) "an unusable account degrades"
  clock.set 70000
  accounts.set (accountsBody 0 2)
  check ((← observe spec).status == .saturated) "no usable account"
  clock.set 110000
  accounts.set (accountsBody 1 1)
  notebooks.set #[.obj #[("id", .str "busy~a0@example.com"), ("connected", .bool true)]]
  check ((← observe spec).status == .saturated) "every usable account already runs a notebook"
  clock.set 150000
  notebooks.set #[]
  eligible.set #[]
  check ((← observe spec).status == .saturated) "no eligible accelerator"
  clock.set 190000
  accounts.set (.obj #[])
  check ((← observe spec).status == .unknown) "an uninterpretable account list is unknown"

end OrbCore.ManagedProviderColabTests
