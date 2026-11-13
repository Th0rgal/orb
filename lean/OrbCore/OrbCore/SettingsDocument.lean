/-
Versioned non-secret settings wire contract. Exporters project into this schema;
importers validate the entire document before showing a diff or writing state.
No opaque settings objects, user records, provider credentials or mission data.
-/
import OrbBin.Json

namespace OrbCore.SettingsDocument

open OrbBin.Json

inductive Scalar where
  | text | flag | count | nullableText | nullableCount | nullableFlag
  deriving BEq

private def validScalar (kind : Scalar) (value : JVal) : Bool :=
  match kind, value with
  | .text, .str _ | .nullableText, .str _ => true
  | .flag, .bool _ | .nullableFlag, .bool _ => true
  | .count, .num n | .nullableCount, .num n =>
    (n.toNat?).any (· ≤ 9223372036854775807)
  | .nullableText, .null | .nullableCount, .null | .nullableFlag, .null => true
  | _, _ => false

private def objectKeys (value : JVal) (required allowed : Array String) : Except String Unit := do
  let .obj pairs := value | throw "settings_object_required"
  let keys := pairs.map Prod.fst
  if keys.toList.eraseDups.length != keys.size then throw "settings_duplicate_field"
  if keys.any (!allowed.contains ·) then throw "settings_unknown_field"
  if required.any (!keys.contains ·) then throw "settings_missing_field"

private def flatObject (value : JVal) (fields : Array (String × Scalar))
    (required : Array String) : Except String Unit := do
  objectKeys value required (fields.map Prod.fst)
  for (key, kind) in fields do
    if let some v := value.field? key then
      unless validScalar kind v do throw "settings_invalid_field_type"

private def nonempty (value : JVal) (key : String) : Except String Unit := do
  unless (value.fieldStr? key).any (!·.trimAscii.isEmpty) do throw "settings_empty_identifier"

/-- No timestamps, instance IDs or user IDs: the same settings serialize identically
    on both instances. Routing entry order is meaningful and must remain intact. -/
partial def canonical (value : JVal) : JVal :=
  match value with
  | .obj fields => .obj ((fields.map fun (key, v) => (key, canonical v)).qsort (fun a b => a.1 < b.1))
  | .arr values => .arr (values.map canonical)
  | other => other

def render (value : JVal) : String := renderPretty (canonical value) ++ "\n"

def globalFields : Array (String × Scalar) := #[
  ("library_remote", .nullableText), ("library_revision", .nullableText),
  ("max_parallel_missions", .nullableCount), ("max_concurrent_tasks", .nullableCount),
  ("google_max_concurrency", .nullableCount), ("auto_cleanup_enabled", .nullableFlag),
  ("auto_cleanup_days", .nullableCount), ("auto_cleanup_stopped_days", .nullableCount),
  ("auto_cleanup_orphans_enabled", .nullableFlag)]

def monitorFields : Array (String × Scalar) := #[
  ("stall_minutes", .count), ("proxy_window_seconds", .count),
  ("proxy_5xx_count", .count), ("proxy_4xx_count", .count),
  ("vm_expiry_grace_seconds", .count), ("long_build_minutes", .count)]

private def provider (value : JVal) : Except String Unit := do
  flatObject value #[("id", .text), ("enabled", .flag)] #["id", "enabled"]
  nonempty value "id"

private def rows (value : JVal) (identity : String)
    (validate : JVal → Except String Unit) : Except String Unit := do
  let .arr values := value | throw "settings_array_required"
  if values.size > 4096 then throw "settings_too_many_rows"
  let mut seen : Array String := #[]
  for item in values do
    validate item
    let raw := (item.fieldStr? identity).getD ""
    let key := if identity == "username" then raw.toLower else raw
    if seen.contains key then throw "settings_duplicate_identifier"
    seen := seen.push key

private def routingChain (value : JVal) : Except String Unit := do
  objectKeys value #["id", "name", "entries", "is_default", "strip_thinking"]
    #["id", "name", "entries", "is_default", "strip_thinking"]
  nonempty value "id"
  unless (value.fieldStr? "name").isSome && (value.fieldBool? "is_default").isSome &&
      (value.fieldBool? "strip_thinking").isSome do throw "settings_invalid_chain"
  let some entries := value.fieldArr? "entries" | throw "settings_array_required"
  if entries.isEmpty || entries.size > 4096 then throw "settings_invalid_entries"
  for entry in entries do
    -- Intentionally matches ProxyModelRouting.chainResponse's safe projection.
    flatObject entry #[("provider_id", .text), ("model_id", .text)] #["provider_id", "model_id"]
    nonempty entry "provider_id"
    nonempty entry "model_id"

private def userPreferences (value : JVal) : Except String Unit := do
  objectKeys value #["username", "inference", "managed", "daily_spend_cap_cents"]
    #["username", "inference", "managed", "daily_spend_cap_cents"]
  nonempty value "username"
  unless validScalar .nullableCount (value.fieldOrNull "daily_spend_cap_cents") do
    throw "settings_invalid_user_cap"
  rows (value.fieldOrNull "inference") "id" provider
  rows (value.fieldOrNull "managed") "id" provider

/-- Reject unknown fields at every depth, including future fields. Extending this
    allowlist requires deciding explicitly whether the new field is secret. -/
def validate (value : JVal) : Except String Unit := do
  let sections := #["version", "global", "routing_chains", "inference_providers",
    "managed_providers", "user_preferences", "fleet", "monitor"]
  objectKeys value sections sections
  unless value.fieldNat? "version" == some 1 do throw "settings_unsupported_version"
  flatObject (value.fieldOrNull "global") globalFields #[]
  -- URLs with embedded credentials must never be serialized as settings.
  if let some remote := (value.fieldOrNull "global").fieldStr? "library_remote" then
    if remote.contains '?' || remote.contains '#' ||
        ((remote.splitOn "://").drop 1).any (fun rest => ((rest.splitOn "/").head!).contains '@') then
      throw "settings_library_remote_contains_credentials"
  rows (value.fieldOrNull "routing_chains") "id" routingChain
  let chains := (value.fieldArr? "routing_chains").getD #[]
  if (chains.filter (fun chain => chain.fieldBool? "is_default" == some true)).size > 1 then
    throw "settings_multiple_default_chains"
  rows (value.fieldOrNull "inference_providers") "id" provider
  rows (value.fieldOrNull "managed_providers") "id" provider
  rows (value.fieldOrNull "user_preferences") "username" userPreferences
  let fleetFields := #[("enabled", Scalar.flag), ("boat_enabled", .flag),
    ("daily_cap_cents", .count), ("max_concurrent", .count)]
  flatObject (value.fieldOrNull "fleet") fleetFields (fleetFields.map Prod.fst)
  flatObject (value.fieldOrNull "monitor") monitorFields #[]

/-- A printable diff contains only validated, non-secret sections. Invalid input
    produces a fixed error code, never a rendering of the rejected content. -/
def diff (before after : JVal) : Except String String := do
  validate before
  validate after
  let mut lines : Array String := #[]
  for field in #["global", "routing_chains", "inference_providers", "managed_providers",
      "user_preferences", "fleet", "monitor"] do
    let old := renderCompact (canonical (before.fieldOrNull field))
    let new := renderCompact (canonical (after.fieldOrNull field))
    if old != new then
      lines := lines.push s!"- {field}: {old}"
      lines := lines.push s!"+ {field}: {new}"
  return if lines.isEmpty then "No settings changes.\n" else String.intercalate "\n" lines.toList ++ "\n"

end OrbCore.SettingsDocument
