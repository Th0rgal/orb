import OrbCore.SettingsDocument

namespace OrbCore.SettingsDocumentTests

open OrbBin.Json OrbCore.SettingsDocument

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"settings document: {label}")

def fixture : JVal := .obj #[
  ("version", .num "1"), ("global", .obj #[("library_remote", .str "git@github.com:Th0rgal/orb-library.git")]),
  ("routing_chains", .arr #[.obj #[("id", .str "smart"), ("name", .str "Smart"),
    ("entries", .arr #[.obj #[("provider_id", .str "openai"), ("model_id", .str "gpt-6")]]),
    ("is_default", .bool true), ("strip_thinking", .bool false)]]),
  ("inference_providers", .arr #[.obj #[("id", .str "openai"), ("enabled", .bool true)]]),
  ("managed_providers", .arr #[]),
  ("user_preferences", .arr #[.obj #[("username", .str "admin"), ("inference", .arr #[]),
    ("managed", .arr #[]), ("daily_spend_cap_cents", .null)]]),
  ("fleet", .obj #[("enabled", .bool false), ("boat_enabled", .bool false),
    ("daily_cap_cents", .num "200"), ("max_concurrent", .num "2")]),
  ("monitor", .obj #[("stall_minutes", .num "30")])]

def run : IO Unit := do
  check (validate fixture |>.isOk) "complete document is accepted"
  let .ok reparsed := OrbBin.Json.parse (render fixture)
    | throw (IO.userError "settings document round trip parse failed")
  check (render reparsed == render fixture) "canonical byte-identical round trip"
  let .ok unchanged := diff fixture reparsed | throw (IO.userError "settings document no-change diff failed")
  check (unchanged == "No settings changes.\n") "no timestamp or object-order diff"
  for forbidden in #["users", "missions", "transcripts", "secrets", "machines", "provider_keys"] do
    check (!(validate (fixture.setField forbidden (.str "secret-marker"))).isOk)
      "operational data cannot enter a settings document"
  let hidden := fixture.setField "global" (.obj #[("dashboard_password_hash", .str "secret-marker")])
  check (!(diff fixture hidden).isOk) "diff never prints rejected secret content"
  let providers := .arr #[.obj #[("id", .str "boat"), ("enabled", .bool true), ("api_key", .str "secret-marker")]]
  check (!(validate (fixture.setField "managed_providers" providers)).isOk) "provider credentials rejected"
  let chain := ((fixture.fieldArr? "routing_chains").getD #[])[0]!
  let inlineKey := chain.setField "entries" (.arr #[.obj #[
    ("provider_id", .str "openai"), ("model_id", .str "gpt-6"), ("api_key", .str "secret-marker")]])
  check (!(validate (fixture.setField "routing_chains" (.arr #[inlineKey]))).isOk) "inline routing keys rejected"
  let prefs := ((fixture.fieldArr? "user_preferences").getD #[])[0]!
  check (!(validate (fixture.setField "user_preferences" (.arr #[prefs.setField "user_id" (.str "other")]))).isOk)
    "users are referenced only by existing username"
  check (!(validate (fixture.setField "user_preferences" (.arr #[prefs, prefs.setField "username" (.str "ADMIN")]))).isOk)
    "case-insensitive usernames cannot alias the same target"
  check (!(validate (fixture.setField "version" (.num "2"))).isOk) "unknown schema version rejected"
  check (!(validate (fixture.setField "fleet" ((fixture.fieldOrNull "fleet").setField "spent_today_cents" (.num "0")))).isOk)
    "spending counters never transfer"
  check (!(validate (fixture.setField "fleet" ((fixture.fieldOrNull "fleet").setField "daily_cap_cents" (.num "18446744073709551616")))).isOk)
    "caps cannot overflow SQLite integers"
  check (!(validate (fixture.setField "routing_chains" (.arr #[chain, chain]))).isOk) "duplicate identifiers rejected"
  check (!(validate (fixture.setField "global" (.obj #[("library_remote", .str "https://user:secret-marker@github.com/repo")]))).isOk)
    "credential-bearing library remote rejected"
  if let .obj fields := fixture then
    check (!(validate (.obj (fields.push ("version", .num "1")))).isOk) "duplicate object fields rejected"
  let changed := fixture.setField "monitor" (.obj #[("stall_minutes", .num "15")])
  let .ok delta := diff fixture changed | throw (IO.userError "settings document diff failed")
  check (delta.startsWith "- monitor:" && (delta.splitOn "+ monitor:").length == 2)
    "confirmation diff includes old and new non-secret values"

end OrbCore.SettingsDocumentTests
