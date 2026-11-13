import OrbCore.ManagedProviderRegistry

namespace OrbCore.ManagedProviderTests

open OrbCore.ManagedProvider OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed provider contract: {label}")

/-- Deterministic provider contract replay; never opens sockets or rents machines. -/
def run : IO Unit := do
  let diagnostic := transportDiagnostic "private-test-key" "TLS refused private-test-key\nforged log\rline"
  check (diagnostic == "TLS refused [redacted]\\nforged log\\rline" &&
    (transportDiagnostic "key" (String.ofList (List.replicate 2000 'x'))).length == 1024)
    "bounded redacted transport cause without log injection"
  let some entry := declaration? "boat" | throw (IO.userError "Boat missing from registry")
  check (entry.name == "boat" && entry.secretName == "BOAT_API_KEY" &&
    entry.readinessDeadlineSecs == 360 && entry.bootstrapMode == .execSystemd &&
    entry.supportsSnapshots && entry.supportsStopResume && entry.supportsExtend &&
    entry.sizes.size == 4) "provider-owned capabilities and sizes"
  check ((declaration? "unknown").isNone && (declaration? "hetzner").isNone &&
    !(quote "hetzner" "small" 60).isOk) "unimplemented registry entries fail closed"
  for profile in entry.sizes do
    for ttl in [5:721] do
      let actual := (quote "boat" profile.name ttl.toUInt64).toOption
      let expected := (profile.milliCentsPerHour.toNat * ttl + 59999) / 60000
      check (actual == some expected.toUInt64) "registry lease quote matches catalog price"
  let unsupported := JVal.obj (catalogFields "hetzner")
  check (unsupported.fieldBool? "implemented" == some false &&
    unsupported.fieldBool? "supports_snapshots" == some false &&
    unsupported.fieldBool? "supports_free_stop" == some false) "no synthetic capabilities"
  let catalog := JVal.obj (catalogFields "boat")
  let some sizes := catalog.fieldArr? "sizes" | throw (IO.userError "missing size catalog")
  check (sizes.size == 4 && sizes[0]!.fieldNat? "cpu" == some 2 &&
    (sizes[0]!.field? "usd_per_hour").map renderCompact == some "0.01800") "catalog resources and exact hourly USD"
  let requests ← IO.mkRef (#[] : Array Request)
  let replies ← IO.mkRef (#[] : Array (Nat × JVal))
  let transport : Transport := fun req => do
    requests.modify (·.push req)
    let rest ← replies.get
    match rest[0]? with
    | none => return .error { code := "unexpected_mock_request" }
    | some response =>
      replies.set (rest.extract 1 rest.size)
      return .ok response
  let sleeps ← IO.mkRef (#[] : Array UInt32)
  let provider := boat transport (fun ms => sleeps.modify (·.push ms))
  check ((provider.quoteCents "small" 60).toOption == some 2 &&
    (provider.quoteCents "default" 60).toOption == some 4 &&
    (provider.quoteCents "large" 60).toOption == some 8 &&
    (provider.quoteCents "xlarge" 720).toOption == some 240 &&
    !(provider.quoteCents "xlarge" 0xffffffffffffffff).isOk &&
    !(provider.quoteCents "unknown" 60).isOk) "provider-owned bounded lease quotes"
  let spec : SpawnSpec := {
    name := "orb-managed-test"
    size := "small"
    ttlSeconds := 300
    idempotencyKey := "spawn-test"
    fromSnapshot := "warm snapshot"
  }
  let machine := JVal.obj #[("sandbox", .obj #[("id", .str "sb-1"), ("state", .str "busy")])]
  replies.set #[(201, machine)]
  let .ok created ← provider.spawn spec | throw (IO.userError "spawn failed")
  check (created.providerId == "sb-1" && provider.isReady created.state) "nested sandbox / busy state"
  let sent := (← requests.get)[0]!
  let body := sent.body.getD .null
  check (sent.path == "/sandboxes" && sent.idempotencyKey == spec.idempotencyKey &&
    body.fieldStr? "type" == some "small" && body.fieldUInt64? "ttlSeconds" == some 300 &&
    body.fieldBool? "noEnv" == some true && body.fieldStr? "from" == some "warm snapshot" &&
    (body.field? "size").isNone && (body.field? "ttl_minutes").isNone) "credential-free Boat spawn wire contract"
  check ((boatSpawnBody { spec with fromSnapshot := "provider-default" }).field? "from").isNone "provider default omits from"
  replies.set #[(403, .obj #[("message", .str "do not return upstream secrets")])]
  check (!(← provider.spawn spec).isOk) "provider failure is not a synthetic machine"
  replies.set #[(201, .obj #[])]
  check (!(← provider.spawn spec).isOk) "missing machine identity rejected"
  let before := (← requests.get).size
  check (!(← provider.spawn { spec with idempotencyKey := "" }).isOk &&
    (← requests.get).size == before) "creation requires a stable idempotency key before I/O"

  requests.set #[]
  replies.set #[(200, .obj #[("sandboxes", .arr #[.obj #[("id", .str "a")]]),
    ("nextCursor", .str "a/b &c")]), (200, .obj #[("sandboxes", .arr #[.obj #[("id", .str "b")]])])]
  let .ok machines ← provider.list | throw (IO.userError "paged list failed")
  check (machines.size == 2 && (← requests.get)[1]!.path == "/sandboxes?limit=200&cursor=a%2Fb%20%26c") "paged list and encoded cursor"
  replies.set #[(200, .obj #[("sandboxes", .arr #[]), ("nextCursor", .str "repeat")]),
    (200, .obj #[("sandboxes", .arr #[]), ("nextCursor", .str "repeat")])]
  check (!(← provider.list).isOk) "repeated cursor does not return partial fleet"
  replies.set #[(200, .obj #[])]
  check (!(← provider.list).isOk) "malformed fleet is not an empty observation"

  requests.set #[]
  replies.set #[(200, machine)]
  check (← provider.resume "old/id" spec).isOk "resume succeeded"
  check ((← requests.get)[0]!.path == "/sandboxes/old%2Fid/fork" &&
    ((← requests.get)[0]!.body.getD .null |>.field? "from").isNone) "resume forks archived sandbox without a snapshot override"
  replies.set #[(200, machine)]
  check (← provider.fork "sb-1" spec).isOk "fork succeeded"
  replies.set #[(200, .null)]
  check (← provider.extend "sb-1" 900).isOk "extend succeeded"
  let last := (← requests.get).back!
  check (last.method == "PATCH" && (last.body.getD .null).fieldUInt64? "ttlSeconds" == some 900) "provider TTL extension"

  requests.set #[]
  for status in #[409, 403, 503] do
    requests.set #[]
    replies.set #[(status, .obj #[]), (200, .null)]
    let .error failure ← provider.destroy "sb-1" | throw (IO.userError "failed DELETE reported success")
    check (failure.status == status && (← requests.get).size == 1 &&
      (← requests.get)[0]!.method == "DELETE" && (← sleeps.get).isEmpty)
      "failed DELETE preserves error without STOP fallback"
  replies.set #[(204, .null)]
  check (← provider.destroy "sb-1").isOk "successful DELETE confirms destruction"
  replies.set #[(400, .obj #[("code", .str "stop_failed")]), (200, .null)]
  check (← provider.stop "sb-1").isOk "explicit stop retains retry behavior"
  check ((← sleeps.get) == #[3000]) "bounded stop retry"
  replies.set #[(404, .null)]
  check (← provider.destroy "missing").isOk "destroy missing is idempotent"
  replies.set #[(403, .null), (403, .null)]
  check (!(← provider.destroy "denied").isOk) "destroy errors are preserved"
  replies.set (Array.replicate 5 (400, .obj #[("code", .str "stop_failed")]))
  sleeps.set #[]
  check (!(← provider.stop "starting").isOk && (← sleeps.get) == #[3000, 6000, 9000, 12000]) "stop retries terminate"
  check (provider.isStopped "archiving" && !provider.isReady "starting" && !provider.isStopped "mystery") "Boat state mapping"

  requests.set #[]
  replies.set #[(201, .null), (200, .obj #[("snapshot", .obj #[("name", .str "warm / 1"),
    ("status", .str "ready"), ("sizeBytes", .nat 1024)])]),
    (200, .obj #[("snapshots", .arr #[.obj #[("name", .str "warm / 1"), ("status", .str "ready")]])]),
    (204, .null)]
  check (← provider.saveSnapshot "sb-1" "warm / 1").isOk "snapshot saved"
  let .ok snapshot ← provider.getSnapshot "warm / 1" | throw (IO.userError "snapshot get failed")
  let .ok snapshots ← provider.listSnapshots | throw (IO.userError "snapshot list failed")
  check (snapshot.name == "warm / 1" && snapshot.status == "ready" && snapshot.sizeBytes == some 1024 && snapshots.size == 1) "snapshot round trip"
  check (← provider.deleteSnapshot "warm / 1").isOk "snapshot deleted"
  let sent ← requests.get
  check (sent[0]!.path == "/saved-snapshots" &&
    (sent[0]!.body.getD .null).fieldStr? "sandboxId" == some "sb-1" &&
    sent[1]!.path == "/saved-snapshots/warm%20%2F%201" &&
    sent[3]!.method == "DELETE") "named snapshot wire contract"
  replies.set #[(503, .null)]
  check (!(← provider.saveSnapshot "sb-1" "failed").isOk) "failed snapshot is not recorded ready"

end OrbCore.ManagedProviderTests
