/-
  OrbBin.PosixExt: Minimal POSIX Syscall Bindings (`c/orb_bin_posix.c`), Base64 (Standard & URL-Safe),
  UUID v4 Generator & Parser, Shell Single-Quote Escaping, and Private `0700`/`0600` File Helpers.
-/
import LeanSys.Posix
import LeanSys.Auth
import OrbNetLeaf.Crypto
import OrbNetLeaf.TlsHttp
import OrbBin.Spec

namespace OrbBin.PosixExt

@[extern "orb_bin_chmod"]
opaque chmod (path : @& String) (mode : UInt32) : IO UInt32

@[extern "orb_bin_chown_group"]
opaque chownGroup (path : @& String) (groupName : @& String) : IO UInt32

@[extern "orb_bin_peercred"]
private opaque rawPeerCred (fd : Int32) : IO ByteArray

@[extern "orb_bin_lstat_info"]
opaque lstatInfo (path : @& String) : IO UInt32

@[extern "orb_bin_geteuid"]
opaque geteuid : IO UInt32

@[extern "orb_bin_getpid"]
opaque getpid : IO UInt32

@[extern "orb_bin_shutdown_wr"]
opaque shutdownWr (fd : Int32) : IO UInt32

@[extern "orb_bin_kill_sig"]
opaque killSig (pid : Int64) (sig : Int32) : IO UInt32

@[extern "orb_bin_now_epoch"]
opaque nowEpoch : IO UInt64

@[extern "orb_bin_hostname"]
opaque getHostname : IO String

@[extern "orb_bin_read_fd_chunk"]
opaque readFdChunk (fd : Int32) (maxBytes : USize) : IO ByteArray

@[extern "orb_bin_write_fd_all"]
opaque writeFdAll (fd : Int32) (bytes : @& ByteArray) : IO UInt32

@[extern "orb_bin_close_fd"]
opaque closeFdRaw (fd : Int32) : IO Unit

@[extern "orb_bin_flock_exclusive_nb"]
opaque flockExclusiveNb (path : @& String) : IO UInt32

@[extern "orb_bin_install_term_trap"]
opaque installTermTrap : IO Unit

@[extern "orb_bin_poll_term_trap"]
opaque pollTermTrap : IO UInt32

@[extern "orb_bin_spawn_pgrp"]
private opaque rawSpawnPgrp (prog : @& String) (args : @& Array String) (env : @& Array String) (pipeStdin : UInt8) : IO ByteArray

@[extern "orb_bin_waitpid_wnohang"]
opaque waitpidWnohang (pid : Int64) : IO UInt32

@[extern "orb_bin_environ_list"]
opaque environList : IO (Array String)

@[extern "orb_bin_setenv"]
opaque setenvVar (key : @& String) (val : @& String) : IO Unit

@[extern "orb_bin_unsetenv"]
opaque unsetenvVar (key : @& String) : IO Unit

structure SpawnedPgrp where
  pid       : Int64
  stdinFd   : Int32
  deriving Repr, BEq

def spawnPgrp (prog : String) (args : Array String) (env : Array String) (pipeStdin : Bool := false) : IO SpawnedPgrp := do
  let raw ← rawSpawnPgrp prog args env (if pipeStdin then 1 else 0)
  let mut pidU64 : UInt64 := 0
  for i in [0:8] do
    pidU64 := pidU64 ||| ((raw.get! i).toUInt64 <<< (i * 8).toUInt64)
  let mut fdU32 : UInt32 := 0
  for i in [0:4] do
    fdU32 := fdU32 ||| ((raw.get! (8 + i)).toUInt32 <<< (i * 8).toUInt32)
  let pid : Int64 := Int64.ofBitVec (BitVec.ofNat 64 pidU64.toNat)
  let stdinFd : Int32 := Int32.ofBitVec (BitVec.ofNat 32 fdU32.toNat)
  return { pid, stdinFd }

/-- Read current process environment as `(key, value)` pairs. -/
def currentEnvPairs : IO (Array (String × String)) := do
  let raw ← environList
  let mut out : Array (String × String) := Array.mkEmpty raw.size
  for entry in raw do
    match entry.splitOn "=" with
    | [] => pure ()
    | k :: rest => out := out.push (k, String.intercalate "=" rest)
  return out

structure PeerCred where
  uid : Option UInt32
  gid : Option UInt32
  pid : Option UInt32
  deriving Repr, BEq

private def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 > b.size then 0xFFFFFFFF
  else
    (b.get! off).toUInt32 |||
    ((b.get! (off + 1)).toUInt32 <<< 8) |||
    ((b.get! (off + 2)).toUInt32 <<< 16) |||
    ((b.get! (off + 3)).toUInt32 <<< 24)

def getPeerCred (fd : Int32) : IO PeerCred := do
  let raw ← rawPeerCred fd
  let uid := readU32LE raw 0
  let gid := readU32LE raw 4
  let pid := readU32LE raw 8
  if uid == 0xFFFFFFFF then
    return { uid := none, gid := none, pid := none }
  return { uid := some uid, gid := some gid, pid := some pid }

structure StatFlags where
  exists_     : Bool
  isDir       : Bool
  isReg       : Bool
  isSymlink   : Bool
  ownedByEuid : Bool
  mode        : UInt32
  deriving Repr, BEq

def statPath (path : String) : IO StatFlags := do
  let bits ← lstatInfo path
  if (bits &&& 1) == 0 then
    return { exists_ := false, isDir := false, isReg := false, isSymlink := false, ownedByEuid := false, mode := 0 }
  return {
    exists_     := true
    isDir       := (bits &&& 2) != 0
    isReg       := (bits &&& 4) != 0
    isSymlink   := (bits &&& 8) != 0
    ownedByEuid := (bits &&& 16) != 0
    mode        := (bits >>> 8) &&& 0o7777
  }

/-- Read an environment variable, returning `none` if unset or empty. -/
def getEnvNonEmpty (name : String) : IO (Option String) := do
  match (← IO.getEnv name) with
  | some v => if v.isEmpty then return none else return some v
  | none => return none

/-- Read the first non-empty environment variable in `names`. -/
def firstEnvNonEmpty (names : List String) : IO (Option String) := do
  for n in names do
    if let some v ← getEnvNonEmpty n then
      return some v
  return none

/-- Strip trailing `'/'` characters from a URL or path. -/
def stripTrailingSlash (s : String) : String :=
  if s.endsWith "/" then (s.dropEnd 1).toString else s

/-! ### Base64 (Standard & URL-Safe) -/

private def b64StdChars : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

private def b64UrlChars : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toList.toArray

def base64Encode (data : ByteArray) (urlSafe : Bool := false) (pad : Bool := true) : String := Id.run do
  let tbl := if urlSafe then b64UrlChars else b64StdChars
  let mut out : Array Char := Array.mkEmpty ((data.size + 2) / 3 * 4)
  let mut i : Nat := 0
  while i + 3 ≤ data.size do
    let b0 := (data.get! i).toUInt32
    let b1 := (data.get! (i + 1)).toUInt32
    let b2 := (data.get! (i + 2)).toUInt32
    let n := (b0 <<< 16) ||| (b1 <<< 8) ||| b2
    out := out.push (tbl[((n >>> 18) &&& 63).toNat]!)
    out := out.push (tbl[((n >>> 12) &&& 63).toNat]!)
    out := out.push (tbl[((n >>> 6) &&& 63).toNat]!)
    out := out.push (tbl[(n &&& 63).toNat]!)
    i := i + 3
  let rem := data.size - i
  if rem == 1 then
    let b0 := (data.get! i).toUInt32
    let n := b0 <<< 16
    out := out.push (tbl[((n >>> 18) &&& 63).toNat]!)
    out := out.push (tbl[((n >>> 12) &&& 63).toNat]!)
    if pad then
      out := out.push '='
      out := out.push '='
  else if rem == 2 then
    let b0 := (data.get! i).toUInt32
    let b1 := (data.get! (i + 1)).toUInt32
    let n := (b0 <<< 16) ||| (b1 <<< 8)
    out := out.push (tbl[((n >>> 18) &&& 63).toNat]!)
    out := out.push (tbl[((n >>> 12) &&& 63).toNat]!)
    out := out.push (tbl[((n >>> 6) &&& 63).toNat]!)
    if pad then
      out := out.push '='
  return String.ofList out.toList

private def b64CharVal? (c : Char) : Option UInt32 :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat).toUInt32
  else if 'a' ≤ c && c ≤ 'z' then some (26 + c.toNat - 'a'.toNat).toUInt32
  else if '0' ≤ c && c ≤ '9' then some (52 + c.toNat - '0'.toNat).toUInt32
  else if c == '+' || c == '-' then some 62
  else if c == '/' || c == '_' then some 63
  else none

def base64Decode? (s : String) : Option ByteArray := Id.run do
  let chars := s.trimAscii.toString.toList.filter (· != '=')
  let r := chars.length % 4
  if r == 1 then return none
  let mut vals : Array UInt32 := Array.mkEmpty chars.length
  for c in chars do
    match b64CharVal? c with
    | some v => vals := vals.push v
    | none => return none
  let mut out := ByteArray.emptyWithCapacity ((vals.size * 3) / 4)
  let mut i : Nat := 0
  while i + 4 ≤ vals.size do
    let n := (vals[i]! <<< 18) ||| (vals[i + 1]! <<< 12) ||| (vals[i + 2]! <<< 6) ||| vals[i + 3]!
    out := out.push ((n >>> 16) &&& 0xFF).toUInt8
    out := out.push ((n >>> 8) &&& 0xFF).toUInt8
    out := out.push (n &&& 0xFF).toUInt8
    i := i + 4
  let rem := vals.size - i
  if rem == 2 then
    let n := (vals[i]! <<< 18) ||| (vals[i + 1]! <<< 12)
    out := out.push ((n >>> 16) &&& 0xFF).toUInt8
  else if rem == 3 then
    let n := (vals[i]! <<< 18) ||| (vals[i + 1]! <<< 12) ||| (vals[i + 2]! <<< 6)
    out := out.push ((n >>> 16) &&& 0xFF).toUInt8
    out := out.push ((n >>> 8) &&& 0xFF).toUInt8
  return some out

/-! ### UUID v4 Validation & Generation -/

private def isHexChar (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

/-- Validate canonical 36-char hyphenated UUID (`8-4-4-4-12`) or 32-char hex UUID, returning lowercase canonical `8-4-4-4-12`. -/
def parseUuidCanonical? (s : String) : Option String := Id.run do
  let t := s.trimAscii.toString.toLower
  let cs := t.toList.toArray
  if cs.size == 36 then
    for i in [0:36] do
      if i == 8 || i == 13 || i == 18 || i == 23 then
        if cs[i]! != '-' then return none
      else
        if !isHexChar cs[i]! then return none
    return some t
  else if cs.size == 32 then
    for c in cs do
      if !isHexChar c then return none
    let s1 := String.ofList (cs.extract 0 8).toList
    let s2 := String.ofList (cs.extract 8 12).toList
    let s3 := String.ofList (cs.extract 12 16).toList
    let s4 := String.ofList (cs.extract 16 20).toList
    let s5 := String.ofList (cs.extract 20 32).toList
    return some s!"{s1}-{s2}-{s3}-{s4}-{s5}"
  else
    return none

def newUuidV4 : IO String := do
  let raw ← match (← OrbNetLeaf.Crypto.randBytes 16) with
    | .ok b => pure b
    | .error e => throw <| IO.userError s!"CSPRNG failed to generate 16 bytes for UUID v4: {e}"
  if raw.size < 16 then
    throw <| IO.userError "CSPRNG failed to generate 16 bytes for UUID v4"
  let b6 := ((raw.get! 6) &&& 0x0F) ||| 0x40
  let b8 := ((raw.get! 8) &&& 0x3F) ||| 0x80
  let mut fixed := ByteArray.emptyWithCapacity 16
  for i in [0:16] do
    if i == 6 then fixed := fixed.push b6
    else if i == 8 then fixed := fixed.push b8
    else fixed := fixed.push (raw.get! i)
  let hex := LeanSys.Auth.bytesToHexLower fixed
  let cs := hex.toList.toArray
  let s1 := String.ofList (cs.extract 0 8).toList
  let s2 := String.ofList (cs.extract 8 12).toList
  let s3 := String.ofList (cs.extract 12 16).toList
  let s4 := String.ofList (cs.extract 16 20).toList
  let s5 := String.ofList (cs.extract 20 32).toList
  return s!"{s1}-{s2}-{s3}-{s4}-{s5}"

/-! ### Polling Socket Read Helper (`pollReadable` + `readStreamChunk`) -/

inductive TimedRead where
  | eof
  | timeout
  | fatal (msg : String)
  | bytes (chunk : ByteArray)

/-- Wait up to `timeoutMs` for `fd` readability, then read up to `maxLen` bytes. -/
def readSocketTimed (fd : LeanSys.Posix.Fd) (maxLen : Nat) (timeoutMs : UInt32) : IO TimedRead := do
  match (← LeanSys.Posix.pollReadable fd timeoutMs) with
  | .error .eagain => return .timeout
  | .error e => return .fatal e.toString
  | .ok () =>
    let chunk ← LeanSys.Posix.readStreamChunk fd maxLen
    if chunk.isEmpty then return .eof
    else return .bytes chunk

/-! ### Safe Identifiers, Shell Quoting & Private `0700`/`0600` Files -/

def isSafeEnvIdent (s : String) : Bool :=
  !s.isEmpty && s.all (fun c => ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_')

def shellSingleQuote (s : String) : String :=
  "'" ++ String.intercalate "'\"'\"'" (s.splitOn "'") ++ "'"

/-- Ensure `dir` exists, is not a symlink, is owned by `geteuid()`, and has mode `0700` (`(mode & 0o077) == 0`). -/
def ensurePrivateDir0700 (dir : System.FilePath) : IO (Except String Unit) := do
  if let some parent := dir.parent then
    let ps := parent.toString
    if !ps.isEmpty && ps != "/" && ps != "." && ps != "/tmp" && ps != "/var/tmp" && ps != "/private/tmp" then
      let pst ← statPath ps
      if !pst.exists_ then
        IO.FS.createDirAll parent
        let _ ← chmod ps 0o700
      let pst2 ← statPath ps
      if pst2.isSymlink || !pst2.isDir then
        return .error "Refusing symlinked secrets parent directory"
      if pst2.ownedByEuid && (pst2.mode &&& 0o077) != 0 then
        let _ ← chmod ps 0o700
  let ds := dir.toString
  let st0 ← statPath ds
  if !st0.exists_ then
    IO.FS.createDirAll dir
  let st1 ← statPath ds
  if st1.isSymlink || !st1.isDir || !st1.ownedByEuid then
    return .error "Secrets directory is not a private owned directory"
  let rc ← chmod ds 0o700
  if rc != 0 then
    return .error s!"Failed setting 0700 on `{ds}`"
  return .ok ()

/-- Atomically write `content` into a newly-created exclusive `0600` (`O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC`)
    temporary file inside `path`'s parent directory BEFORE writing any secret bytes, then rename into `path`. -/
def writeAtomicPrivate0600 (path : System.FilePath) (content : ByteArray) : IO (Except String Unit) := do
  let parent := path.parent.getD (System.FilePath.mk ".")
  IO.FS.createDirAll parent
  let pst ← statPath parent.toString
  if pst.isSymlink || !pst.isDir then
    return .error s!"Refusing symlinked or non-directory parent `{parent}`"
  let nonce ← newUuidV4
  let fileName := path.fileName.getD "secret"
  let tmp := parent / s!".{fileName}.tmp-{nonce}"
  let ts := tmp.toString
  if let .error e ← OrbNetLeaf.TlsHttp.createExclFile0600 tmp then
    return .error e
  let tst ← statPath ts
  if !tst.exists_ || tst.isSymlink || !tst.isReg || !tst.ownedByEuid || (tst.mode &&& 0o777) != 0o600 then
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error s!"Temporary file `{ts}` failed 0600 exclusive verification"
  try
    IO.FS.writeBinFile tmp content
  catch e =>
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error s!"Failed writing `{ts}`: {e}"
  let rc ← chmod ts 0o600
  if rc != 0 then
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error s!"Failed verifying 0600 on `{ts}`"
  try
    IO.FS.rename tmp path
    return .ok ()
  catch e =>
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error s!"Failed atomic rename to `{path}`: {e}"

end OrbBin.PosixExt
