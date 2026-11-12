import OrbCore.ManagedProvider

/-!
  Harvest one file from a managed VM through the provider command API.

  The provider's own file API is text-only and serves a fixed directory, and the
  relay truncates tool output, so the file is read in bounded base64 chunks and
  reassembled in Core. Core never trusts the guest's claim about the content:
  it re-hashes what it received and compares it with the digest the guest
  reported before the first chunk, which also detects a file that changed
  mid-read. The path is confined twice: lexically before any command is built,
  and on the guest after symlink resolution.
-/

namespace OrbCore.ManagedHarvest

open OrbCore.ManagedProvider OrbBin.Json

/-- The managed worker's work directory, as installed by `orb-node-provision.sh`. -/
def workRoot : String := "/var/lib/orb-node/work"

/-- The node's single-upload limit; a harvested file is delivered as one upload. -/
def defaultMaxBytes : Nat := 20 * 1024 * 1024

structure Config where
  root : String := workRoot
  maxBytes : Nat := defaultMaxBytes
  /-- Raw bytes per command. A multiple of three, so every chunk but the last
      encodes without padding (96 000 base64 characters by default). -/
  chunkBytes : Nat := 72000
  /-- The work directory belongs to the node user; provider commands run as the
      image's login user. Empty in tests that run the commands locally. -/
  privilege : String := "sudo -n "
  timeoutSecs : UInt32 := 60

structure Harvested where
  bytes : ByteArray
  sha256 : String
  /-- The symlink-resolved path the guest actually read. -/
  sourcePath : String
  chunks : Nat

/-- Lexical confinement. A relative path is taken from the work directory; an
    absolute one must already be inside it. `..` is refused outright instead of
    normalised, so the guest-side check is the only place symlinks matter. -/
def confinedPath (root raw : String) : Except String String := do
  let path := raw.trimAscii.toString
  if path.isEmpty then throw "harvest_path_missing"
  if path.utf8ByteSize > 1024 || path.any (fun c => c.toNat < 32 || c.toNat == 127 || c == '\\') then
    throw "harvest_path_invalid"
  let full := if path.startsWith "/" then path else root ++ "/" ++ path
  if !full.startsWith (root ++ "/") then throw "harvest_outside_work_dir"
  let segments := (full.drop (root.length + 1)).toString.splitOn "/"
  if segments.any (fun s => s == ".." || s == ".") then throw "harvest_path_invalid"
  if segments.all (·.isEmpty) then throw "harvest_not_regular_file"
  return full

/-- A plain file name for the delivered copy. -/
def deliveryName (sourcePath : String) : String :=
  let base := (sourcePath.splitOn "/").getLast?.getD ""
  let safe := String.ofList (base.toList.filter (fun c => c.toNat ≥ 32 && c.toNat != 127 && c != '/' && c != '\\'))
  if safe.isEmpty || safe == "." || safe == ".." || safe.utf8ByteSize > 200 then "harvest.bin" else safe

private def quote (s : String) : String :=
  "'" ++ String.intercalate "'\"'\"'" (s.splitOn "'") ++ "'"

/-- Resolve symlinks on the guest, confine the result, and report size, digest
    and resolved path. Refusals are printed as a stable token with exit 0 so a
    provider that drops the exit code still reports them faithfully. -/
def statCommand (cfg : Config) (path : String) : String :=
  let script := String.intercalate "\n" [
    "set -eu",
    s!"root=$(realpath -e -- {quote cfg.root} 2>/dev/null) || \{ echo harvest_work_dir_missing; exit 0; }",
    s!"p=$(realpath -e -- {quote path} 2>/dev/null) || \{ echo harvest_not_found; exit 0; }",
    "case \"$p\" in \"$root\"/*) ;; *) echo harvest_outside_work_dir; exit 0;; esac",
    "[ -f \"$p\" ] || { echo harvest_not_regular_file; exit 0; }",
    "size=$(stat -c %s -- \"$p\")",
    "sum=$(sha256sum -- \"$p\" | cut -c1-64)",
    "printf 'ok\\n%s\\n%s\\n%s\\n' \"$size\" \"$sum\" \"$p\""
  ]
  s!"{cfg.privilege}sh -c {quote script}"

def chunkCommand (cfg : Config) (resolved : String) (index : Nat) : String :=
  let script := s!"dd if={quote resolved} bs={cfg.chunkBytes} skip={index} count=1 status=none | base64 -w0"
  s!"{cfg.privilege}sh -c {quote script}"

private def exitCode? (body : JVal) : Option Int :=
  (body.fieldInt? "exitCode").orElse (fun _ => body.fieldInt? "exit_code")
    |>.orElse (fun _ => body.fieldInt? "code")

/-- Provider command replies differ in where they put standard output. -/
private def stdout? (body : JVal) : Option String :=
  let direct (j : JVal) := (j.fieldStr? "stdout").orElse (fun _ => j.fieldStr? "output")
  (direct body).orElse (fun _ => (body.field? "result").bind direct)

private def run (provider : Provider) (providerId command : String) (cfg : Config) :
    IO (Except String String) := do
  match ← provider.exec providerId command cfg.timeoutSecs with
  | .error _ => return .error "harvest_provider_command_failed"
  | .ok body =>
    if (exitCode? body).any (· != 0) then return .error "harvest_guest_command_failed"
    let some out := stdout? body | return .error "harvest_provider_output_missing"
    return .ok out

private def isHexDigest (s : String) : Bool :=
  s.length == 64 && s.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

/-- Read `rawPath` from the machine. Fails closed on any size, chunk or digest
    disagreement; nothing partial is returned. -/
def fetch (provider : Provider) (providerId rawPath : String) (cfg : Config := {}) :
    IO (Except String Harvested) := do
  if cfg.chunkBytes == 0 || cfg.chunkBytes % 3 != 0 then return .error "harvest_config_invalid"
  let path ← match confinedPath cfg.root rawPath with
    | .ok p => pure p
    | .error e => return .error e
  let report ← match ← run provider providerId (statCommand cfg path) cfg with
    | .ok out => pure out
    | .error e => return .error e
  let lines : List String :=
    ((report.splitOn "\n").map (fun l => l.trimAscii.toString)).filter (fun l => !l.isEmpty)
  match lines with
  | ["ok", sizeText, digest, resolved] =>
    let some size := sizeText.toNat? | return .error "harvest_guest_report_invalid"
    if !isHexDigest digest then return .error "harvest_guest_report_invalid"
    -- The guest already confined the resolved path; refuse a reply that did not.
    if !resolved.startsWith "/" || resolved.any (fun (c : Char) => c.toNat < 32) then
      return .error "harvest_guest_report_invalid"
    if size > cfg.maxBytes then return .error s!"harvest_too_large:{size}:{cfg.maxBytes}"
    let chunks := (size + cfg.chunkBytes - 1) / cfg.chunkBytes
    let mut bytes := ByteArray.emptyWithCapacity size
    for index in [0:chunks] do
      let encoded ← match ← run provider providerId (chunkCommand cfg resolved index) cfg with
        | .ok out => pure out
        | .error e => return .error e
      let compact := String.ofList (encoded.toList.filter (fun c => !c.isWhitespace))
      let some chunk := OrbBin.PosixExt.base64Decode? compact
        | return .error "harvest_chunk_encoding_invalid"
      let expected := min cfg.chunkBytes (size - index * cfg.chunkBytes)
      if chunk.size != expected then return .error "harvest_file_changed"
      bytes := bytes ++ chunk
    let actual := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes bytes)
    if bytes.size != size || actual != digest then return .error "harvest_checksum_mismatch"
    return .ok { bytes, sha256 := actual, sourcePath := resolved, chunks }
  | [token] =>
    if token.startsWith "harvest_" then return .error token
    return .error "harvest_guest_report_invalid"
  | _ => return .error "harvest_guest_report_invalid"

end OrbCore.ManagedHarvest
