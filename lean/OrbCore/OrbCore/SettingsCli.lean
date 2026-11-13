import OrbCore.SettingsTransfer

namespace OrbCore.SettingsCli

open OrbBin.Json OrbBin.PosixExt

structure Options where
  command : String
  input : Option String := none
  output : Option String := none
  root : String
  prodRoot : String := "/root/.sandboxed-sh"
  devRoot : String := "/var/lib/sandboxed-sh-dev"
  yes : Bool := false

private def parseRest (opts : Options) : List String → Except String Options
  | [] => .ok opts
  | "--yes" :: rest =>
    if opts.yes || opts.command == "export" then .error "settings_invalid_arguments"
    else parseRest { opts with yes := true } rest
  | "--data-root" :: value :: rest =>
    if (opts.command != "import" && opts.command != "export") || value.isEmpty || value.startsWith "-" then
      .error "settings_invalid_arguments"
    else parseRest { opts with root := value } rest
  | "--output" :: value :: rest =>
    if opts.command != "export" || opts.output.isSome || value.isEmpty || value.startsWith "-" then .error "settings_invalid_arguments"
    else parseRest { opts with output := some value } rest
  | "--prod-root" :: value :: rest =>
    if (opts.command != "refresh-dev" && opts.command != "promote-dev") || value.isEmpty || value.startsWith "-" then .error "settings_invalid_arguments"
    else parseRest { opts with prodRoot := value } rest
  | "--dev-root" :: value :: rest =>
    if (opts.command != "refresh-dev" && opts.command != "promote-dev") || value.isEmpty || value.startsWith "-" then .error "settings_invalid_arguments"
    else parseRest { opts with devRoot := value } rest
  | value :: rest =>
    if opts.command != "import" || opts.input.isSome || value.startsWith "-" then .error "settings_invalid_arguments"
    else parseRest { opts with input := some value } rest

def parse (args : List String) (defaultRoot : String) : Except String Options := do
  let command :: rest := args | throw "settings_usage"
  unless #["export", "import", "refresh-dev", "promote-dev"].contains command do throw "settings_usage"
  let opts ← parseRest { command, root := defaultRoot } rest
  if command == "import" && opts.input.isNone then throw "settings_usage"
  return opts

private def readDocument (file : String) : IO (Except String JVal) := do
  try
    let st ← statPath file
    if !st.isReg || st.isSymlink then return .error "settings_document_not_regular_file"
    let bytes ← IO.FS.withFile file .read fun handle => handle.read 1048577
    if bytes.size > 1048576 then return .error "settings_document_too_large"
    let .ok doc := OrbBin.Json.parseBytes bytes | return .error "settings_document_invalid_json"
    if let .error e := SettingsDocument.validate doc then return .error e
    return .ok doc
  catch _ => return .error "settings_document_unreadable"

private def execute (opts : Options) : IO (Except String Unit) := do
  if ← LocalOperator.isMission then return .error "operator_required"
  let (source, target) :=
    if opts.command == "refresh-dev" then (opts.prodRoot, opts.devRoot)
    else if opts.command == "promote-dev" then (opts.devRoot, opts.prodRoot)
    else (opts.root, opts.root)
  if let .error e ← LocalOperator.authorize target then return .error e
  if let .error e ← LocalOperator.authorize source then return .error e
  if opts.command == "refresh-dev" || opts.command == "promote-dev" then
    let src ← statIdentity source true
    let dst ← statIdentity target true
    if src.dev == dst.dev && src.ino == dst.ino then return .error "settings_instances_must_differ"
  if opts.command == "export" then
    let .ok doc ← SettingsTransfer.exportDocument source | return .error "settings_export_failed"
    let rendered := SettingsDocument.render doc
    match opts.output with
    | none => IO.print rendered
    | some file =>
      if let .error _ ← writeAtomicPrivate0600 file rendered.toUTF8 then return .error "settings_export_write_failed"
    return .ok ()
  let desired ← if opts.command == "import" then readDocument (opts.input.getD "")
    else SettingsTransfer.exportDocument source
  let .ok doc := desired | return .error (match desired with | .error e => e | _ => "settings_export_failed")
  let preview ← SettingsTransfer.preview target doc
  let .ok (before, delta) := preview
    | return .error (match preview with | .error e => e | _ => "settings_preview_failed")
  IO.eprint delta
  if !opts.yes then
    IO.eprintln "Not applied. Repeat with --yes to confirm this direction and apply the printed diff."
    return .ok ()
  match ← SettingsTransfer.importDocument target doc before with
  | .error e => return .error e
  | .ok () =>
    IO.println "Settings applied."
    return .ok ()

def run (args : List String) (defaultRoot : String) : IO UInt32 := do
  let .ok opts := parse args defaultRoot
    | do IO.eprintln "usage: orb-core settings export [--data-root DIR] [--output FILE] | import FILE [--data-root DIR] [--yes] | refresh-dev|promote-dev [--prod-root DIR] [--dev-root DIR] [--yes]"; return 2
  try
    match ← execute opts with
    | .ok () => return 0
    | .error e => IO.eprintln s!"[orb-core settings] {e}"; return 1
  catch _ => IO.eprintln "[orb-core settings] settings_operation_failed"; return 1

end OrbCore.SettingsCli
