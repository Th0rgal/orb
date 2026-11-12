/-
  OrbBin.Sqlite: Shared parameterized SQLite leaf interface (`0 import Lean`, `0 sorryAx`)
  backed by `lean/OrbBin/c/orb_bin_sqlite.c` (`dlopen("libsqlite3...")`, WAL mode, positional `?1..?N` bindings).
  Shared by `OrbCore` (`sandboxed-sh`) and `OrbLocald` (`orb-locald` UI cache & drafts).
-/
import Std.Sync.Mutex

namespace OrbBin.Sqlite

@[extern "orb_sqlite_open"]
opaque sqliteOpenRaw (path : @& String) : IO UInt64

@[extern "orb_sqlite_close"]
opaque sqliteCloseRaw (handle : UInt64) : IO Unit

@[extern "orb_sqlite_exec"]
opaque sqliteExecRaw (handle : UInt64) (sql : @& String) : IO (Except String Unit)

@[extern "orb_sqlite_query_rows"]
opaque sqliteQueryRowsRaw (handle : UInt64) (sql : @& String) (params : @& Array String) : IO (Except String (Array (Array String)))

/-- Typed SQLite handle opened in WAL mode with an exclusive `Std.Mutex` serializing C `sqlite3*` access. -/
structure SqliteDb where
  handle : UInt64
  path   : String
  mu     : Std.Mutex Unit

private def isIgnorableDuplicateColErr (msg : String) : Bool :=
  (msg.toLower.splitOn "duplicate column name").length > 1

/-- Execute additive `ALTER TABLE ... ADD COLUMN` statements, tolerating already-present columns
    while failing closed on persistent schema, corruption, or read-only errors. -/
def applyAdditiveAlters (h : UInt64) (alters : Array String) : IO (Except String Unit) := do
  for stmt in alters do
    match ← sqliteExecRaw h stmt with
    | .ok () => pure ()
    | .error e =>
      if !isIgnorableDuplicateColErr e then
        return .error e
  return .ok ()

/-- Open a persistent SQLite database file and verify write durability (`BEGIN IMMEDIATE; ROLLBACK;`).
    Never accepts `:memory:` or `mode=memory` URIs unless `allowMemory == true`, and never falls back
    to an in-memory store on persistent open/migration failure. -/
def openSqliteDb (path : String) (ddl : String) (alters : Array String := #[]) (allowMemory : Bool := false) : IO (Except String SqliteDb) := do
  let norm := path.trimAscii.toString
  if norm.isEmpty then
    return .error "sqlite_empty_path_rejected"
  if !allowMemory && (norm == ":memory:" || (norm.toLower.splitOn "mode=memory").length > 1) then
    return .error s!"sqlite_memory_fallback_forbidden:{path}"
  let h ← sqliteOpenRaw path
  if h == 0 then
    return .error s!"sqlite_open_failed:{path}"
  match ← sqliteExecRaw h ddl with
  | .error e =>
    sqliteCloseRaw h
    return .error e
  | .ok () =>
    match ← applyAdditiveAlters h alters with
    | .error ae =>
      sqliteCloseRaw h
      return .error ae
    | .ok () =>
      match ← sqliteExecRaw h "BEGIN IMMEDIATE; ROLLBACK;" with
      | .error we =>
        sqliteCloseRaw h
        return .error s!"sqlite_write_probe_failed:{we}"
      | .ok () =>
        let mu ← Std.Mutex.new ()
        return .ok { handle := h, path := path, mu := mu }

end OrbBin.Sqlite
