import OrbCore.ResourcesAndSystem

namespace OrbCore.LocalOriginTests

open OrbBin.Sqlite OrbCore.Store

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"local origin: {label}")

/-- The mission table as it exists in databases created before `workspace_id`
    had a default (prod on 16 Nov 2026): the column is `NOT NULL` without one. -/
private def legacyMissionsDdl : String :=
  "CREATE TABLE IF NOT EXISTS missions (id TEXT PRIMARY KEY NOT NULL, status TEXT NOT NULL DEFAULT 'active', " ++
  "title TEXT, workspace_id TEXT NOT NULL, backend TEXT NOT NULL DEFAULT 'opencode', model_override TEXT, " ++
  "model_effort TEXT, working_directory TEXT, project TEXT, folder TEXT NOT NULL DEFAULT '', " ++
  "placement_revision INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, origin TEXT, " ++
  "resumable INTEGER NOT NULL DEFAULT 0, tags TEXT, history_json TEXT NOT NULL DEFAULT '[]', " ++
  "authority_mode TEXT NOT NULL DEFAULT 'writer', placement_kind TEXT NOT NULL DEFAULT 'managed', " ++
  "owner_user_id TEXT NOT NULL DEFAULT '', state_revision INTEGER NOT NULL DEFAULT 1);"

def run (root : String) : IO Unit := do
  IO.FS.createDirAll root
  let .ok db ← openSqliteDb s!"{root}/local-origin-legacy.db" legacyMissionsDdl
    | throw (IO.userError "local origin: legacy db open failed")
  let mid := "624d42f0-3f2f-47ab-8c56-58d252049855"
  let params := #[mid, "Local mission", "active", "opencode", "orbrouter/builtin/smart", "", "/home/u/.orb/workspaces/now",
    "now", "", "2026-11-16T16:10:00Z", "2026-11-16T16:10:00Z", "[\"pr-writer\",\"placement:client\"]", "[]", "admin"]
  let r ← execParamQuery db OrbCore.ResourcesAndSystem.localOriginMissionUpsertSql params
  check r.isOk s!"upsert into the legacy mission table fails: {match r with | .error e => e | .ok _ => ""}"
  let .ok rows ← execParamQuery db "SELECT project, placement_kind, workspace_id FROM missions WHERE id=?1;" #[mid]
    | throw (IO.userError "local origin: read back failed")
  check (rows.size == 2) "a local mission is stored as a mission row"
  check ((rows[1]!)[0]? == some "now" && (rows[1]!)[1]? == some "client") "the stored row keeps its project and client placement"
  -- A second sync of the same mission updates, never duplicates.
  let r2 ← execParamQuery db OrbCore.ResourcesAndSystem.localOriginMissionUpsertSql (params.set! 2 "completed")
  check r2.isOk "a repeated sync of the same mission succeeds"
  let .ok rows2 ← execParamQuery db "SELECT status FROM missions WHERE id=?1;" #[mid]
    | throw (IO.userError "local origin: second read back failed")
  check (rows2.size == 2 && (rows2[1]!)[0]? == some "completed") "a repeated sync updates the status"
  IO.println "PASS local_origin_upsert_on_legacy_schema"

end OrbCore.LocalOriginTests
