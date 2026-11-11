/-
  OrbCore.R7Core: Phase R7-Core obligations for SM-18 (inbox CAS + project context),
  SM-13 (project tracks + board attempts), and SM-22 / G-ORB-7 (deploy observe -> gate -> execute).
-/
import LeanSys
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Spec
import OrbCore.Store
import OrbCore.Managed
import OrbBin.PrivdShared

namespace OrbCore.R7Core

open LeanSys.Auth
open LeanSys.Posix
open Orb.Kernel
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Spec
open OrbCore.Store
open OrbCore.Managed

def contextFileLimit : Nat := 10 * 1024 * 1024
def contextConfirmedFileLimit : UInt64 := 2 * 1024 * 1024 * 1024
def contextProjectLimit : UInt64 := 100 * 1024 * 1024
def contextEntryLimit : Nat := 5000
def defaultParallelMissions : Nat := 4
def reservedBossSlots : Nat := 1

private def cell (row : Array String) (i : Nat) : String :=
  (row[i]?).getD ""

private def cellNat (row : Array String) (i : Nat) : Nat :=
  (cell row i).toNat?.getD 0

def validContextPath (path : String) : Except String Unit := do
  if path.isEmpty || path.length > 1024 || path.contains '\\' then
    throw "invalid context path"
  if path.any (fun c => c.toNat < 32 || c.toNat == 127) then
    throw "invalid context path"
  let segs := path.splitOn "/"
  if segs.any (fun seg => seg.isEmpty || seg == "." || seg == "..") then
    throw "context path must be canonical and relative"
  for name in segs do
    if name.startsWith "." ||
       name == "node_modules" || name == "target" || name == "vendor" ||
       name.endsWith "~" ||
       name == "id_rsa" || name == "id_ed25519" ||
       name == "credentials.json" || name == "auth.json" ||
       name.endsWith ".pem" || name.endsWith ".key" then
      throw s!"excluded context path: {path}"

def validRawProjectSlug (slug : String) : Bool :=
  (validContextPath slug).isOk && !slug.contains '/' && !slug.contains ':'

def validProjectSlug (slug : String) : Bool :=
  match slug.splitOn ":" with
  | [raw] => validRawProjectSlug raw
  | [uid, raw] =>
    !uid.isEmpty && uid.length ≤ 64 &&
    uid.all (fun c => c.isAlphanum || c == '_' || c == '-') &&
    validRawProjectSlug raw
  | _ => false

/-- Scope a user's raw project slug (`"lean-campaign"`) to an isolated storage key in `projects.db`
    and `project-context/<scoped>/blobs` so two users can own identically named projects without
    colliding or disclosing existence (`409` probing). Bootstrap admin retains unsuffixed slugs for
    in-place compatibility with pre-existing single-user databases. -/
def scopeProjectSlug (callerUserId bootstrapAdminId rawSlug : String) : Option String :=
  if !validRawProjectSlug rawSlug then none
  else if callerUserId.isEmpty || callerUserId == bootstrapAdminId then some rawSlug
  else some s!"{callerUserId}:{rawSlug}"

def unscopeProjectSlugForOwner (callerUserId bootstrapAdminId storedSlug : String) : Option String :=
  if callerUserId.isEmpty || callerUserId == bootstrapAdminId then
    if !storedSlug.contains ':' then some storedSlug else none
  else
    let pfx := callerUserId ++ ":"
    if storedSlug.startsWith pfx then some (storedSlug.drop pfx.length).toString else none

private def hexNib? (c : Char) : Option UInt8 :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat).toUInt8
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10).toUInt8
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10).toUInt8
  else none

def percentDecodeStrict (s : String) : Option String := Id.run do
  let chars := s.toList.toArray
  let mut out := ByteArray.emptyWithCapacity chars.size
  let mut i := 0
  while i < chars.size do
    let c := chars[i]!
    if c == '%' then
      if i + 2 < chars.size then
        match hexNib? chars[i + 1]!, hexNib? chars[i + 2]! with
        | some hi, some lo =>
          out := out.push ((hi <<< 4) ||| lo)
          i := i + 3
        | _, _ => return none
      else return none
    else
      out := out ++ c.toString.toUTF8
      i := i + 1
  return String.fromUTF8? out

def inboxVersionKey (path : String) : Option String :=
  if path == "preferences" then some "preferences"
  else if path.startsWith "seen/" then
    match percentDecodeStrict (path.drop 5).toString with
    | some id => if id.isEmpty then none else some s!"seen:{id}"
    | none => none
  else none

structure InboxCasInput where
  pathKind     : UInt8
  clientOk     : UInt8
  seqOk        : UInt8
  expectedOk   : UInt8
  bodyOk       : UInt8
  storedVer    : UInt64
  expectedVer  : UInt64
  sameMutation : UInt8
  deriving Repr, DecidableEq

def inboxCasAdmitted (c : InboxCasInput) : Bool :=
  verifyInboxCas c.pathKind c.clientOk c.seqOk c.expectedOk c.bodyOk c.storedVer c.expectedVer c.sameMutation == 1

structure ContextOpInput where
  pathOk       : UInt8
  sizeOk       : UInt8
  countOk      : UInt8
  projectOk    : UInt8
  blobOk       : UInt8
  entryRev     : UInt64
  baseRev      : UInt64
  basePresent  : UInt8
  entryPresent : UInt8
  deriving Repr, DecidableEq

def contextOpAdmitted (c : ContextOpInput) : Bool :=
  verifyContextOpCas c.pathOk c.sizeOk c.countOk c.projectOk c.blobOk
    c.entryRev c.baseRev c.basePresent c.entryPresent == 1

structure BoardTrackInput where
  trackExists   : UInt8
  statusOk      : UInt8
  slotsOk       : UInt8
  retryOk       : UInt8
  duplicateOpen : UInt8
  deriving Repr, DecidableEq

def boardTrackAdmitted (c : BoardTrackInput) : Bool :=
  verifyBoardTrack c.trackExists c.statusOk c.slotsOk c.retryOk c.duplicateOpen == 1

structure DeployRecheckInput where
  gateOk         : UInt8
  principalKind  : UInt8
  bunkerState    : UInt8
  observedTarget : UInt32
  execTarget     : UInt32
  observedLease  : UInt64
  liveLease      : UInt64
  nowTick        : UInt64
  expiryTick     : UInt64
  observedDigest : UInt64
  execDigest     : UInt64
  deriving Repr, DecidableEq

def verifyDeployRecheckInput (c : DeployRecheckInput) : UInt32 :=
  let specWord :=
    verifyDeployRecheck c.gateOk c.principalKind c.bunkerState
      c.observedTarget c.execTarget c.observedLease c.liveLease
      c.nowTick c.expiryTick c.observedDigest c.execDigest
  let kernelWord :=
    authToctouExecuteStep c.principalKind c.bunkerState
      c.observedTarget c.execTarget c.observedLease c.liveLease
      c.nowTick c.expiryTick c.observedDigest c.execDigest
  if c.gateOk != 1 then 512
  else if specWord != 257 then specWord
  else kernelWord

def deployRecheckAdmitted (c : DeployRecheckInput) : Bool :=
  verifyDeployRecheckInput c == 257

structure DeployObservation where
  unitName       : String
  isProd         : Bool
  serviceMatches : Bool
  callingOnSelf  : Bool
  debounceOk     : Bool
  forceFlag      : Bool
  biometric      : Bool
  bunkerState    : UInt8
  liveWriters    : UInt32
  principalKind  : UInt8
  targetId       : UInt32
  leaseEpoch     : UInt64
  expiryTick     : UInt64
  digest         : UInt64
  nowTick        : UInt64
  deriving Repr, DecidableEq

structure DeployReceipt where
  unitName        : String
  observedDigest  : UInt64
  execDigest      : UInt64
  verdictCode     : UInt32
  verdict         : String
  dryRun          : Bool
  restart         : Bool
  deriving Repr, DecidableEq

def observeDeploy (o : DeployObservation) : DeployObservation := o

private def coreUnitAliasSameTier (a b : String) : Bool :=
  a == b ||
  ((a == "sandboxed-sh.service" || a == "sandboxed-sh-prod.service" || a == "orb-core.service") &&
   (b == "sandboxed-sh.service" || b == "sandboxed-sh-prod.service" || b == "orb-core.service")) ||
  ((a == "sandboxed-sh-dev.service" || a == "orb-core-dev.service") &&
   (b == "sandboxed-sh-dev.service" || b == "orb-core-dev.service"))

/-- This process is the systemd instance of `unitName` when invocation, unit env, or cgroup agree. -/
def callingOnSelfUnit (unitName : String) (operatorCli : Bool := false) : IO Bool := do
  if operatorCli then return false
  let inv ← IO.getEnv "INVOCATION_ID"
  let envUnit ← IO.getEnv "SYSTEMD_UNIT"
  let override ← IO.getEnv "ORB_SERVICE_UNIT"
  let named := (envUnit.getD "").trimAscii.toString
  let forced := (override.getD "").trimAscii.toString
  if inv.isSome && (coreUnitAliasSameTier named unitName || coreUnitAliasSameTier forced unitName) then
    return true
  let cg ← (IO.FS.readFile "/proc/self/cgroup" |>.toBaseIO)
  match cg with
  | .error _ => return false
  | .ok raw =>
    let hit := raw.splitOn "/" |>.any (fun seg =>
      let clean := (seg.splitOn "\n").headD "" |>.trimAscii.toString
      coreUnitAliasSameTier clean unitName)
    return hit

/-- Debounce uses wall-clock `coreEpochSec`, not a monotonic process clock. -/
def deployDebounceOk (st : CoreStore) (unitName : String) (nowEpoch : UInt64) : IO Bool := do
  match ← lastAdmittedDeployEpoch? st unitName with
  | none => pure true
  | some prev => pure (nowEpoch >= prev + 30)

/-- Live writer count fails closed: a store error is not "zero writers". -/
def liveWriterCount (st : CoreStore) : IO UInt32 := do
  match ← countLiveWriters st with
  | .ok n => pure n
  | .error _ => pure 1

def gateDeploy (o : DeployObservation) : UInt8 :=
  let dGate := deployGateStep
    (if o.isProd then 1 else 0)
    (if o.serviceMatches then 1 else 0)
    (if o.callingOnSelf then 1 else 0)
    (if o.debounceOk then 1 else 0)
    (if o.forceFlag then 1 else 0)
    (if o.biometric then 1 else 0)
    o.bunkerState
    o.liveWriters
  let toctou := authToctouExecuteStep o.principalKind o.bunkerState
    o.targetId o.targetId o.leaseEpoch o.leaseEpoch
    o.nowTick o.expiryTick o.digest o.digest
  if dGate == 1 && toctou == 257 then 1 else 0

def recheckDeploy (observed live : DeployObservation) (gateOk : UInt8) : UInt32 :=
  verifyDeployRecheckInput {
    gateOk := gateOk
    principalKind := live.principalKind
    bunkerState := live.bunkerState
    observedTarget := observed.targetId
    execTarget := live.targetId
    observedLease := observed.leaseEpoch
    liveLease := live.leaseEpoch
    nowTick := live.nowTick
    expiryTick := live.expiryTick
    observedDigest := observed.digest
    execDigest := live.digest
  }

def deployVerdictName (gated : UInt8) (verdictCode : UInt32) (dryRun : Bool) : String :=
  if gated != 1 then "gate_denied"
  else if verdictCode != 257 then "reconciliation_required"
  else if dryRun then "dry_run_admitted"
  else "admitted"

def executeDeploy (observed live : DeployObservation) (dryRun : Bool) : DeployReceipt :=
  let gated := gateDeploy observed
  let verdictCode := recheckDeploy observed live gated
  let verdict := deployVerdictName gated verdictCode dryRun
  { unitName := live.unitName
    observedDigest := observed.digest
    execDigest := live.digest
    verdictCode := verdictCode
    verdict := verdict
    dryRun := dryRun
    restart := gated == 1 && verdictCode == 257 && !dryRun }

def readInboxStateJson (st : CoreStore) (userId? : Option String := none) : IO (Except String String) := do
  let rows ← st.askDb.mu.atomically <|
    match userId? with
    | none =>
      sqliteQueryRowsRaw st.askDb.handle
        "SELECT entry_key,kind,payload_json,stamp,version FROM inbox_state ORDER BY entry_key;" #[]
    | some uid =>
      sqliteQueryRowsRaw st.askDb.handle
        "SELECT entry_key,kind,payload_json,stamp,version FROM user_inbox_state WHERE user_id=?1 ORDER BY entry_key;" #[uid]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    let mut fields : Array String := #[]
    let mut vers : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let key := cell r 0
      let kind := cell r 1
      let payload := cell r 2
      let stamp := cell r 3
      let ver := cell r 4
      vers := vers.push s!"{jsonEscape key}:{ver}"
      if kind == "preferences" && !payload.isEmpty then
        fields := fields.push s!"{jsonEscape key}:{payload}"
      else if kind == "seen" then
        fields := fields.push s!"{jsonEscape key}:{stamp}"
    let body := String.intercalate "," fields.toList
    let vbody := String.intercalate "," vers.toList
    return .ok s!"\{{body}{if body.isEmpty || vbody.isEmpty then "" else ","}\"_versions\":\{{vbody}}}"

structure InboxPut where
  key          : String
  kind         : String
  payload      : String
  stamp        : Int
  clientId     : String
  mutationSeq  : Nat
  expected     : Nat
  deriving Repr

def parseInboxPut (path : String) (jv : JVal) : Except String InboxPut := do
  let some key := inboxVersionKey path | throw "unknown_inbox_path"
  let clientId := (jv.fieldStr? "clientId").getD ""
  if clientId.isEmpty then throw "missing_client"
  let some seq := jv.fieldNat? "mutationSeq" | throw "bad_seq"
  if seq == 0 then throw "bad_seq"
  let some expected := jv.fieldNat? "expectedVersion" | throw "bad_expected"
  if key == "preferences" then
    let some a := jv.fieldBool? "aiSummary" | throw "bad_preferences"
    let some i := jv.fieldBool? "includeAutonomous" | throw "bad_preferences"
    let some m := jv.fieldStr? "model" | throw "bad_preferences"
    let mut fields : Array (String × JVal) := #[
      ("aiSummary", .bool a), ("includeAutonomous", .bool i), ("model", .str m)]
    if let some en := jv.fieldBool? "inboxEnabled" then
      fields := fields.push ("inboxEnabled", .bool en)
    if let some mode := jv.fieldStr? "summaryMode" then
      fields := fields.push ("summaryMode", .str mode)
    return {
      key, kind := "preferences", payload := renderCompact (.obj fields), stamp := 0,
      clientId, mutationSeq := seq, expected
    }
  else
    let some stampI := jv.fieldInt? "stamp" | throw "bad_stamp"
    if stampI == 0 then throw "bad_stamp"
    return { key, kind := "seen", payload := "", stamp := stampI, clientId, mutationSeq := seq, expected }

private def snapshotInboxVersionsSql
    (h : UInt64) (ensureKey? : Option (String × Nat)) (userId? : Option String := none) : IO String := do
  let snap ←
    match userId? with
    | none => sqliteQueryRowsRaw h "SELECT entry_key,version FROM inbox_state ORDER BY entry_key;" #[]
    | some uid => sqliteQueryRowsRaw h "SELECT entry_key,version FROM user_inbox_state WHERE user_id=?1 ORDER BY entry_key;" #[uid]
  match snap with
  | .ok srs =>
    let mut xs : Array String := #[]
    let mut seenTarget := false
    for i in [1:srs.size] do
      let k := cell srs[i]! 0
      let v := cell srs[i]! 1
      if let some (tk, _) := ensureKey? then
        if k == tk then seenTarget := true
      xs := xs.push s!"{jsonEscape k}:{v}"
    if let some (tk, tv) := ensureKey? then
      if !seenTarget then
        xs := xs.push s!"{jsonEscape tk}:{tv}"
    return String.intercalate "," xs.toList
  | .error _ =>
    match ensureKey? with
    | some (tk, tv) => return s!"{jsonEscape tk}:{tv}"
    | none => return ""

def putInboxState (st : CoreStore) (p : InboxPut) (userId? : Option String := none) : IO (Nat × String) := do
  st.askDb.mu.atomically do
    if let .error e ← sqliteExecRaw st.askDb.handle "BEGIN IMMEDIATE;" then
      return (500, s!"\{\"error\":{jsonEscape e}}")
    let q ←
      match userId? with
      | none =>
        sqliteQueryRowsRaw st.askDb.handle
          "SELECT version,client_id,mutation_seq FROM inbox_state WHERE entry_key=?1;" #[p.key]
      | some uid =>
        sqliteQueryRowsRaw st.askDb.handle
          "SELECT version,client_id,mutation_seq FROM user_inbox_state WHERE user_id=?1 AND entry_key=?2;" #[uid, p.key]
    match q with
    | .error e =>
      discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
      return (500, s!"\{\"error\":{jsonEscape e}}")
    | .ok rs =>
      let stored := if rs.size > 1 then cellNat rs[1]! 0 else 0
      let prevClient := if rs.size > 1 then cell rs[1]! 1 else ""
      let prevSeq := if rs.size > 1 then cellNat rs[1]! 2 else 0
      let same := prevClient == p.clientId && prevSeq == p.mutationSeq && prevSeq != 0
      let pathKind : UInt8 := if p.kind == "preferences" then 1 else 2
      let gate := verifyInboxCas pathKind 1 1 1 1 stored.toUInt64 p.expected.toUInt64 (if same then 1 else 0)
      if same then
        let vers ← snapshotInboxVersionsSql st.askDb.handle (some (p.key, stored)) userId?
        if let .error e ← sqliteExecRaw st.askDb.handle "COMMIT;" then
          discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
          return (500, s!"\{\"error\":{jsonEscape e}}")
        return (200, s!"\{\"ok\":true,\"replayed\":true,\"_versions\":\{{vers}}}")
      else if gate != 1 || stored != p.expected then
        let vers ← snapshotInboxVersionsSql st.askDb.handle (some (p.key, stored)) userId?
        discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
        return (409, s!"\{\"_versions\":\{{vers}}}")
      else
        let next := stored + 1
        let valJson :=
          if !p.payload.isEmpty then p.payload
          else s!"\{\"kind\":{jsonEscape p.kind},\"stamp\":{p.stamp},\"version\":{next},\"client_id\":{jsonEscape p.clientId},\"mutation_seq\":{p.mutationSeq}}"
        let wr ←
          match userId? with
          | none =>
            if rs.size > 1 then
              sqliteQueryRowsRaw st.askDb.handle
                ("UPDATE inbox_state SET kind=?2,payload_json=?3,value_json=?4,stamp=CAST(?5 AS INTEGER),version=CAST(?6 AS INTEGER),client_id=?7,mutation_seq=CAST(?8 AS INTEGER) " ++
                 "WHERE entry_key=?1 AND COALESCE(version,0)=CAST(?9 AS INTEGER);")
                #[p.key, p.kind, p.payload, valJson, s!"{p.stamp}", s!"{next}", p.clientId, s!"{p.mutationSeq}", s!"{stored}"]
            else
              sqliteQueryRowsRaw st.askDb.handle
                ("INSERT INTO inbox_state(user_id,entry_key,value_json,kind,payload_json,stamp,version,client_id,mutation_seq) " ++
                 "VALUES('default',?1,?2,?3,?4,CAST(?5 AS INTEGER),CAST(?6 AS INTEGER),?7,CAST(?8 AS INTEGER));")
                #[p.key, valJson, p.kind, p.payload, s!"{p.stamp}", s!"{next}", p.clientId, s!"{p.mutationSeq}"]
          | some uid =>
            sqliteQueryRowsRaw st.askDb.handle
              ("INSERT INTO user_inbox_state(user_id,entry_key,kind,payload_json,stamp,version,client_id,mutation_seq,updated_at) " ++
               "VALUES(?1,?2,?3,?4,CAST(?5 AS INTEGER),CAST(?6 AS INTEGER),?7,CAST(?8 AS INTEGER),'') " ++
               "ON CONFLICT(user_id,entry_key) DO UPDATE SET kind=excluded.kind,payload_json=excluded.payload_json," ++
               "stamp=excluded.stamp,version=excluded.version,client_id=excluded.client_id,mutation_seq=excluded.mutation_seq " ++
               "WHERE COALESCE(user_inbox_state.version,0)=CAST(?9 AS INTEGER);")
              #[uid, p.key, p.kind, p.payload, s!"{p.stamp}", s!"{next}", p.clientId, s!"{p.mutationSeq}", s!"{stored}"]
        match wr with
        | .error e =>
          discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
          return (500, s!"\{\"error\":{jsonEscape e}}")
        | .ok _ =>
          let ch ← sqliteQueryRowsRaw st.askDb.handle "SELECT changes();" #[]
          let n := match ch with | .ok crs => cellNat (crs[1]?.getD #[]) 0 | .error _ => 0
          if n == 0 then
            let vers ← snapshotInboxVersionsSql st.askDb.handle (some (p.key, stored)) userId?
            discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
            return (409, s!"\{\"_versions\":\{{vers}}}")
          let vers ← snapshotInboxVersionsSql st.askDb.handle (some (p.key, next)) userId?
          if let .error e ← sqliteExecRaw st.askDb.handle "COMMIT;" then
            discard <| sqliteExecRaw st.askDb.handle "ROLLBACK;"
            return (500, s!"\{\"error\":{jsonEscape e}}")
          return (200, s!"\{\"ok\":true,\"_versions\":\{{vers}}}")

def contextBlobDir (root project : String) : System.FilePath :=
  System.FilePath.mk root / "project-context" / project / "blobs"

def isSha256Hex (h : String) : Bool :=
  h.length == 64 && h.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

def putContextBlob (root project : String) (bytes : ByteArray) (confirmedLarge : Bool) : IO (Except String String) := do
  if !validProjectSlug project then return .error "invalid project"
  let maxB := if confirmedLarge then contextConfirmedFileLimit else contextFileLimit.toUInt64
  if bytes.size.toUInt64 > maxB then return .error "oversize"
  let hash := bytesToHexLower (sha256Bytes bytes)
  let dir := contextBlobDir root project
  if let .error e ← ensurePrivateDir0700 dir then return .error e
  let dest := dir / hash
  if !(← dest.pathExists) then
    let nonce ← newUuidV4
    let tmp := dir / s!".{hash}.tmp-{nonce}"
    try
      IO.FS.writeBinFile tmp bytes
      IO.FS.rename tmp dest
    catch e =>
      try IO.FS.removeFile tmp catch _ => pure ()
      return .error s!"blob_write_failed:{e}"
  return .ok hash

def readContextBlob (root project hash : String) : IO (Except String ByteArray) := do
  if !isSha256Hex hash.toLower then return .error "invalid content hash"
  let p1 := contextBlobDir root project / hash.toLower
  let p2 := System.FilePath.mk root / "project-context-state" / project / "blobs" / hash.toLower
  let p ← if ← p1.pathExists then pure p1 else pure p2
  if !(← p.pathExists) then return .error "blob not found"
  let .ok bytes ← IO.FS.readBinFile p |>.toBaseIO | return .error "failed reading context blob"
  if bytesToHexLower (sha256Bytes bytes) != hash.toLower then return .error "checksum"
  return .ok bytes

def contextManifestJson (st : CoreStore) (project : String) : IO (Except String String) := do
  if !validProjectSlug project then return .error "invalid project"
  let head ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle "SELECT revision FROM context_heads WHERE project_slug=?1;" #[project]
  let rows ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT path,content_hash,directory,revision,size FROM context_entries WHERE project_slug=?1 AND deleted=0 ORDER BY path;"
      #[project]
  match head, rows with
  | .error e, _ => return .error e
  | _, .error e => return .error e
  | .ok hrs, .ok rs =>
    let rev := if hrs.size > 1 then cell hrs[1]! 0 else "0"
    let mut ents : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let h := cell r 1
      let hashJson := if h.isEmpty then "null" else jsonEscape h
      let dir := if cell r 2 == "1" then "true" else "false"
      ents := ents.push s!"{jsonEscape (cell r 0)}:\{\"hash\":{hashJson},\"directory\":{dir},\"revision\":{cell r 3},\"size\":{cell r 4}}"
    return .ok s!"\{\"revision\":{rev},\"entries\":\{{String.intercalate "," ents.toList}}}"

def contextConflictsJson (st : CoreStore) (project : String) : IO (Except String String) := do
  let rows ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT id,path,base_revision,base_present,content_hash,directory,delete_flag,source FROM context_conflicts WHERE project_slug=?1 ORDER BY id;" #[project]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    let mut xs : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let id := cell r 0
      let baseJson := if cell r 3 == "1" then cell r 2 else "null"
      let h := cell r 4
      let hashJson := if h.isEmpty then "null" else jsonEscape h
      let dir := if cell r 5 == "1" then "true" else "false"
      let del := if cell r 6 == "1" then "true" else "false"
      let op :=
        s!"\{\"id\":{jsonEscape id},\"path\":{jsonEscape (cell r 1)},\"base\":{baseJson},\"hash\":{hashJson}," ++
        s!"\"directory\":{dir},\"delete\":{del},\"source\":{jsonEscape (cell r 7)}}"
      xs := xs.push s!"{jsonEscape id}:{op}"
    return .ok s!"\{{String.intercalate "," xs.toList}}"

def contextHistoryJson (st : CoreStore) (project : String) : IO (Except String String) := do
  if !validProjectSlug project then return .error "invalid project"
  let rows ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT path,content_hash,directory,revision,size,deleted,source FROM context_history WHERE project_slug=?1 ORDER BY revision ASC;"
      #[project]
  match rows with
  | .error e => return .error e
  | .ok rs =>
    let mut xs : Array String := #[]
    for i in [1:rs.size] do
      let r := rs[i]!
      let entry :=
        if cell r 5 == "1" then "null"
        else
          let h := cell r 1
          let hashJson := if h.isEmpty then "null" else jsonEscape h
          let dir := if cell r 2 == "1" then "true" else "false"
          s!"\{\"hash\":{hashJson},\"directory\":{dir},\"revision\":{cell r 3},\"size\":{cell r 4}}"
      xs := xs.push
        s!"\{\"revision\":{cell r 3},\"path\":{jsonEscape (cell r 0)},\"entry\":{entry},\"source\":{jsonEscape (cell r 6)}}"
    return .ok ("[" ++ String.intercalate "," xs.toList ++ "]")

def contextStreamEvent (st : CoreStore) (project : String) : IO (Except String String) := do
  match ← contextManifestJson st project with
  | .error e => return .error e
  | .ok body => return .ok s!"data: {body}\n\n"

def applyContextOperation (st : CoreStore) (root project : String) (jv : JVal) (nowAt : String)
    (resolveConflictId? : Option String := none) :
    IO (Except String (Nat × String)) := do
  if !validProjectSlug project then return .ok (400, "{\"error\":\"invalid project\"}")
  let some opId := jv.fieldStr? "id" | return .ok (400, "{\"error\":\"missing_id\"}")
  let some path := jv.fieldStr? "path" | return .ok (400, "{\"error\":\"invalid context path\"}")
  if let .error e := validContextPath path then
    return .ok (400, s!"\{\"error\":{jsonEscape e}}")
  let delete := (jv.fieldBool? "delete").getD false
  let directory := (jv.fieldBool? "directory").getD false
  let confirmed := (jv.fieldBool? "confirmed_large").getD false
  let hash? := jv.fieldStr? "hash"
  let basePresent : UInt8 := if (jv.field? "base").isSome && (jv.field? "base") != some .null then 1 else 0
  let baseRev := (jv.fieldUInt64? "base").getD 0
  let source := (jv.fieldStr? "source").getD ""
  let mut blobOk : UInt8 := 1
  let mut size : UInt64 := 0
  if !delete && !directory then
    match hash? with
    | none => blobOk := 0
    | some h =>
      if !isSha256Hex h.toLower then blobOk := 0
      else
        match ← readContextBlob root project h.toLower with
        | .error _ => blobOk := 0
        | .ok bytes =>
          size := bytes.size.toUInt64
          let limit := if confirmed then contextConfirmedFileLimit else contextFileLimit.toUInt64
          if size > limit then blobOk := 0
  withImmediateTx st.projectsDb do
    let replay ← execParamQueryUnlocked st.projectsDb
      "SELECT conflict,revision FROM context_receipts WHERE op_id=?1 AND project_slug=?2;" #[opId, project]
    let .ok rrs := replay | return .error "context_replay_query_failed"
    if rrs.size > 1 then
      let cflag := if cell rrs[1]! 0 == "1" then "true" else "false"
      return .ok (200, s!"\{\"conflict\":{cflag},\"revision\":{cell rrs[1]! 1}}")
    let cur ← execParamQueryUnlocked st.projectsDb
      "SELECT revision,content_hash,directory,deleted,size FROM context_entries WHERE project_slug=?1 AND path=?2;"
      #[project, path]
    let head ← execParamQueryUnlocked st.projectsDb
      "SELECT revision FROM context_heads WHERE project_slug=?1;" #[project]
    let count ← execParamQueryUnlocked st.projectsDb
      "SELECT COUNT(*) FROM context_entries WHERE project_slug=?1 AND deleted=0;" #[project]
    let total ← execParamQueryUnlocked st.projectsDb
      "SELECT COALESCE(SUM(size),0) FROM context_entries WHERE project_slug=?1 AND deleted=0;" #[project]
    let .ok crs := cur | return .error "context_entry_query_failed"
    let .ok hrs := head | return .error "context_head_query_failed"
    let .ok nrs := count | return .error "context_count_query_failed"
    let .ok trs := total | return .error "context_size_query_failed"
    let rowPresent := crs.size > 1
    let deletedRow := rowPresent && cell crs[1]! 3 == "1"
    let entryPresent : UInt8 := if rowPresent && !deletedRow then 1 else 0
    let entryRev := if entryPresent == 1 then cellNat crs[1]! 0 else 0
    let headRev := if hrs.size > 1 then cellNat hrs[1]! 0 else 0
    let nent := if nrs.size > 1 then cellNat nrs[1]! 0 else 0
    let tot := if trs.size > 1 then cellNat trs[1]! 0 else 0
    let sameContent :=
      entryPresent == 1 &&
      ((delete && cell crs[1]! 3 == "1") ||
       (!delete && cell crs[1]! 1 == (hash?.getD "").toLower &&
        ((directory && cell crs[1]! 2 == "1") || (!directory && cell crs[1]! 2 != "1"))))
    let casConflict :=
      (basePresent == 0 && entryPresent == 1 && !sameContent) ||
      (basePresent == 1 && (entryPresent == 0 || entryRev.toUInt64 != baseRev))
    let adding := entryPresent == 0 && !delete
    let countOk : UInt8 := if adding && nent >= contextEntryLimit then 0 else 1
    let prevSize := if entryPresent == 1 && cell crs[1]! 2 != "1" then cellNat crs[1]! 4 else 0
    let nextBytes := if delete || directory then 0 else size.toNat
    let projSize := tot - prevSize + nextBytes
    let overProject := projSize.toUInt64 > contextProjectLimit
    let sizeOk : UInt8 := if overProject || blobOk == 0 then 0 else 1
    let gate := verifyContextOpCas 1 sizeOk countOk 1 blobOk entryRev.toUInt64 baseRev basePresent entryPresent
    if casConflict || (basePresent == 1 && gate != 1 && blobOk == 1 && sizeOk == 1 && countOk == 1) then
      let conf ← execParamQueryUnlocked st.projectsDb
        ("INSERT OR IGNORE INTO context_conflicts" ++
         "(id,project_slug,path,base_revision,base_present,content_hash,directory,delete_flag,source,created_at) " ++
         "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);")
        #[opId, project, path, s!"{baseRev}", s!"{basePresent}", (hash?.getD "").toLower,
          if directory then "1" else "0", if delete then "1" else "0", source, nowAt]
      if let .error e := conf then return .error e
      let rc ← execParamQueryUnlocked st.projectsDb
        "INSERT OR IGNORE INTO context_receipts(op_id,project_slug,conflict,revision) VALUES(?1,?2,1,?3);"
        #[opId, project, s!"{entryRev}"]
      if let .error e := rc then return .error e
      return .ok (200, s!"\{\"conflict\":true,\"revision\":{entryRev}}")
    if sameContent && basePresent == 0 then
      if let some cid := resolveConflictId? then
        let cc ← execParamQueryUnlocked st.projectsDb
          "SELECT 1 FROM context_conflicts WHERE project_slug=?1 AND id=?2;" #[project, cid]
        match cc with
        | .error e => return .error e
        | .ok crs2 =>
          if crs2.size <= 1 then return .ok (404, "{\"error\":\"conflict_not_found\"}")
        let dc ← execParamQueryUnlocked st.projectsDb
          "DELETE FROM context_conflicts WHERE project_slug=?1 AND id=?2;" #[project, cid]
        if let .error e := dc then return .error e
      let rc ← execParamQueryUnlocked st.projectsDb
        "INSERT OR IGNORE INTO context_receipts(op_id,project_slug,conflict,revision) VALUES(?1,?2,0,?3);"
        #[opId, project, s!"{entryRev}"]
      if let .error e := rc then return .error e
      return .ok (200, s!"\{\"conflict\":false,\"revision\":{entryRev}}")
    if blobOk == 0 || countOk == 0 || sizeOk == 0 || gate != 1 then
      let code := if overProject || (blobOk == 0 && size > contextFileLimit.toUInt64) || countOk == 0 then 413 else 400
      return .ok (code, "{\"error\":\"context_rejected\"}")
    if let some cid := resolveConflictId? then
      let cc ← execParamQueryUnlocked st.projectsDb
        "SELECT 1 FROM context_conflicts WHERE project_slug=?1 AND id=?2;" #[project, cid]
      match cc with
      | .error e => return .error e
      | .ok crs2 =>
        if crs2.size <= 1 then return .ok (404, "{\"error\":\"conflict_not_found\"}")
    let nextRev := headRev + 1
    let hashStr := (hash?.getD "").toLower
    let dirFlag := if directory then "1" else "0"
    let delFlag := if delete then "1" else "0"
    let wr ← execParamQueryUnlocked st.projectsDb
      ("INSERT INTO context_entries(project_slug,path,content_hash,directory,revision,size,deleted,source) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) " ++
       "ON CONFLICT(project_slug,path) DO UPDATE SET content_hash=excluded.content_hash,directory=excluded.directory," ++
       "revision=excluded.revision,size=excluded.size,deleted=excluded.deleted,source=excluded.source;")
      #[project, path, if delete then "" else hashStr, dirFlag, s!"{nextRev}", s!"{size}", delFlag, source]
    if let .error e := wr then return .error e
    let histWr ← execParamQueryUnlocked st.projectsDb
      ("INSERT INTO context_history(project_slug,revision,path,content_hash,directory,size,deleted,source) " ++
       "VALUES(?1,?2,?3,?4,?5,?6,?7,?8);")
      #[project, s!"{nextRev}", path, if delete then "" else hashStr, dirFlag, s!"{size}", delFlag, source]
    if let .error e := histWr then return .error e
    if let some cid := resolveConflictId? then
      let dc ← execParamQueryUnlocked st.projectsDb
        "DELETE FROM context_conflicts WHERE project_slug=?1 AND id=?2;" #[project, cid]
      if let .error e := dc then return .error e
    let hw ← execParamQueryUnlocked st.projectsDb
      "INSERT INTO context_heads(project_slug,revision) VALUES(?1,?2) ON CONFLICT(project_slug) DO UPDATE SET revision=excluded.revision;"
      #[project, s!"{nextRev}"]
    if let .error e := hw then return .error e
    let rw ← execParamQueryUnlocked st.projectsDb
      "INSERT INTO context_receipts(op_id,project_slug,conflict,revision) VALUES(?1,?2,0,?3);"
      #[opId, project, s!"{nextRev}"]
    if let .error e := rw then return .error e
    return .ok (200, s!"\{\"conflict\":false,\"revision\":{nextRev}}")

def trackStatusOk (s : String) : Bool :=
  s == "open" || s == "satisfied" || s == "blocked" || s == "cancelled"

def putProjectTrack (st : CoreStore) (slug track desired status nowAt : String) (expectedRev? : Option Nat) :
    IO (Nat × String) := do
  if !validProjectSlug slug || track.isEmpty || !trackStatusOk status then
    return (400, "{\"error\":\"invalid_track\"}")
  if let .error e := validContextPath track then
    return (400, s!"\{\"error\":{jsonEscape e}}")
  let effNow := if nowAt.isEmpty then "1970-01-01T00:00:00Z" else nowAt
  st.projectsDb.mu.atomically do
    if let .error e ← sqliteExecRaw st.projectsDb.handle "BEGIN IMMEDIATE;" then
      return (500, s!"\{\"error\":{jsonEscape e}}")
    discard <| sqliteQueryRowsRaw st.projectsDb.handle
      ("INSERT OR IGNORE INTO projects(slug, id, name, title, root_path, status, created_at, updated_at) " ++
       "VALUES(?1, ?1, ?1, ?1, '', 'active', ?2, ?2);")
      #[slug, effNow]
    let q ← sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT COALESCE(state_revision,0),status FROM project_tracks WHERE project_slug=?1 AND track=?2;" #[slug, track]
    match q with
    | .error e =>
      discard <| sqliteExecRaw st.projectsDb.handle "ROLLBACK;"
      return (500, s!"\{\"error\":{jsonEscape e}}")
    | .ok rs =>
      let cur := if rs.size > 1 then cellNat rs[1]! 0 else 0
      if let some exp := expectedRev? then
        if exp != cur then
          discard <| sqliteExecRaw st.projectsDb.handle "ROLLBACK;"
          return (409, s!"\{\"error\":\"stale_track\",\"state_revision\":{cur}}")
      let next := if cur == 0 then 1 else cur + 1
      let wr ←
        if rs.size > 1 then
          sqliteQueryRowsRaw st.projectsDb.handle
            ("UPDATE project_tracks SET desired_condition=?3,status=?4,updated_at=?5,state_revision=CAST(?6 AS INTEGER) " ++
             "WHERE project_slug=?1 AND track=?2 AND COALESCE(state_revision,0)=CAST(?7 AS INTEGER);")
            #[slug, track, desired, status, effNow, s!"{next}", s!"{cur}"]
        else
          sqliteQueryRowsRaw st.projectsDb.handle
            ("INSERT INTO project_tracks(id,slug,project_slug,track,title,desired_condition,status,created_at,updated_at,state_revision) " ++
             "VALUES(?1,?2,?2,?3,?3,?4,?5,?6,?6,CAST(?7 AS INTEGER));")
            #[s!"{slug}:{track}", slug, track, desired, status, effNow, s!"{next}"]
      match wr with
      | .error e =>
        discard <| sqliteExecRaw st.projectsDb.handle "ROLLBACK;"
        return (500, s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        let ch ← sqliteQueryRowsRaw st.projectsDb.handle "SELECT changes();" #[]
        let n := match ch with | .ok crs => cellNat (crs[1]?.getD #[]) 0 | .error _ => 0
        if n == 0 then
          discard <| sqliteExecRaw st.projectsDb.handle "ROLLBACK;"
          return (409, s!"\{\"error\":\"stale_track\",\"state_revision\":{cur}}")
        if let .error e ← sqliteExecRaw st.projectsDb.handle "COMMIT;" then
          return (500, s!"\{\"error\":{jsonEscape e}}")
        return (200, s!"\{\"project_slug\":{jsonEscape slug},\"track\":{jsonEscape track},\"status\":{jsonEscape status},\"state_revision\":{next}}")

def countOpenBoardSlots (st : CoreStore) (slug : String) : IO (Except String Nat) := do
  let rows ← execParamQuery st.missionsDb
    "SELECT COUNT(*) FROM mission_board_tasks WHERE project_slug=?1 AND status='open';" #[slug]
  match rows with
  | .error e => return .error e
  | .ok rs => return .ok (if rs.size > 1 then cellNat rs[1]! 0 else 0)

def parallelCap (st : CoreStore) (slug : String) : IO Nat := do
  let rows ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT parallel_missions FROM project_grant WHERE slug=?1;" #[slug]
  match rows with
  | .ok rs =>
    if rs.size > 1 then
      let n := cellNat rs[1]! 0
      if n > 0 then return n else return defaultParallelMissions
    else return defaultParallelMissions
  | .error _ => return defaultParallelMissions

private def insertBoardTaskTx (st : CoreStore) (missionId slug track taskKey : String)
    (attempt maxAttempts : Nat) (ext merged suppressed : UInt8) :
    IO (Except String (Prod Nat String)) := do
  match ← execParamQueryUnlocked st.missionsDb "SELECT id FROM missions WHERE id=?1;" #[missionId] with
  | .error _ => return .error "board_mission_query_failed"
  | .ok ers =>
    if ers.size <= 1 then return .ok (404, "{\"error\":\"mission_not_found\"}")
    match ← execParamQueryUnlocked st.missionsDb "SELECT COUNT(*) FROM mission_board_tasks WHERE project_slug=?1 AND status='open';" #[slug] with
    | .error _ => return .error "board_slots_query_failed"
    | .ok rrs =>
      match ← execParamQueryUnlocked st.projectsDb "SELECT parallel_missions FROM project_grant WHERE slug=?1;" #[slug] with
      | .error _ => return .error "board_cap_query_failed"
      | .ok capRows =>
        let cap :=
          if capRows.size > 1 then
            let n := cellNat capRows[1]! 0
            if n > 0 then n else defaultParallelMissions
          else defaultParallelMissions
        match ← execParamQueryUnlocked st.projectsDb "SELECT status FROM project_tracks WHERE project_slug=?1 AND track=?2;" #[slug, track] with
        | .error _ => return .error "board_track_query_failed"
        | .ok trackRows =>
          if trackRows.size <= 1 then return .ok (409, "{\"error\":\"unknown_track\"}")
          let trackSt := cell trackRows[1]! 0
          let statusOkBit : UInt8 := if trackStatusOk trackSt && trackSt != "cancelled" then 1 else 0
          let running := if rrs.size > 1 then cellNat rrs[1]! 0 else 0
          let slots := verifyBoardSlots cap.toUInt32 reservedBossSlots.toUInt32 running.toUInt32
          let retry := verifyBoardRetry attempt.toUInt32 maxAttempts.toUInt32 ext merged suppressed
          match ← execParamQueryUnlocked st.missionsDb "SELECT status FROM mission_board_tasks WHERE task_key=?1;" #[taskKey] with
          | .error _ => return .error "board_dup_query_failed"
          | .ok drs =>
            let duplicate : UInt8 := if drs.size > 1 && cell drs[1]! 0 == "open" then 1 else 0
            let gate := verifyBoardTrack 1 statusOkBit slots retry duplicate
            if duplicate == 1 then return .ok (409, "{\"error\":\"duplicate_task\"}")
            if slots != 1 then return .ok (409, "{\"error\":\"board_slots_full\"}")
            if retry != 1 then return .ok (409, "{\"error\":\"board_retry_suppressed\"}")
            if statusOkBit != 1 || gate != 1 then return .ok (409, "{\"error\":\"board_rejected\"}")
            let sql := "INSERT INTO mission_board_tasks(task_key,project_slug,track,mission_id,attempt_seq,status) VALUES(?1,?2,?3,?4,?5,'open') ON CONFLICT(task_key) DO UPDATE SET project_slug=excluded.project_slug,track=excluded.track,mission_id=excluded.mission_id,attempt_seq=excluded.attempt_seq,status='open' WHERE mission_board_tasks.status!='open';"
            match ← execParamQueryUnlocked st.missionsDb sql #[taskKey, slug, track, missionId, s!"{attempt}"] with
            | .error e => return .error e
            | .ok _ =>
              match ← execParamQueryUnlocked st.missionsDb "SELECT changes();" #[] with
              | .error _ => return .error "board_changes_query_failed"
              | .ok crs =>
                let n := cellNat (crs[1]?.getD #[]) 0
                if n != 1 then return .ok (409, "{\"error\":\"duplicate_task\"}")
                return .ok (200, s!"\{\"task_key\":{jsonEscape taskKey},\"project_slug\":{jsonEscape slug},\"track\":{jsonEscape track},\"mission_id\":{jsonEscape missionId},\"attempt_seq\":{attempt},\"status\":\"open\"}")

def postBoardTask (st : CoreStore) (missionId : String) (jv : JVal) : IO (Nat × String) := do
  let slug := (jv.fieldStr? "project_slug").getD ""
  let track := (jv.fieldStr? "track").getD ""
  let taskKey := (jv.fieldStr? "task_key").getD ""
  let attempt := (jv.fieldNat? "attempt_seq").getD 0
  let maxAttempts := (jv.fieldNat? "max_attempts").getD 3
  let ext : UInt8 := if (jv.fieldBool? "requires_external_recovery").getD false then 1 else 0
  let merged : UInt8 := if (jv.fieldBool? "preflight_merged").getD false then 1 else 0
  let suppressed : UInt8 := if (jv.fieldBool? "retry_suppressed").getD false then 1 else 0
  if !validProjectSlug slug || track.isEmpty || taskKey.isEmpty then
    return (400, "{\"error\":\"invalid_board_task\"}")
  let tx ← withImmediateTx st.projectsDb do
    withImmediateTx st.missionsDb
      (insertBoardTaskTx st missionId slug track taskKey attempt maxAttempts ext merged suppressed)
  match tx with
  | .error e => return (500, s!"\{\"error\":{jsonEscape e}}")
  | .ok pair => return pair

def projectBoardJson (st : CoreStore) (slug : String) : IO (Except String String) := do
  let tracks ← st.projectsDb.mu.atomically <|
    sqliteQueryRowsRaw st.projectsDb.handle
      "SELECT track,desired_condition,status,state_revision FROM project_tracks WHERE project_slug=?1 ORDER BY track;" #[slug]
  let tasks ← st.missionsDb.mu.atomically <|
    sqliteQueryRowsRaw st.missionsDb.handle
      "SELECT task_key,track,mission_id,attempt_seq,status FROM mission_board_tasks WHERE project_slug=?1 ORDER BY task_key;" #[slug]
  match tracks, tasks with
  | .error e, _ => return .error e
  | _, .error e => return .error e
  | .ok trs, .ok krs =>
    let mut titems : Array String := #[]
    for i in [1:trs.size] do
      let r := trs[i]!
      let track := cell r 0
      let mut attempts : Array String := #[]
      for j in [1:krs.size] do
        let k := krs[j]!
        if cell k 1 == track then
          attempts := attempts.push s!"\{\"task_key\":{jsonEscape (cell k 0)},\"mission_id\":{jsonEscape (cell k 2)},\"attempt_seq\":{cell k 3},\"status\":{jsonEscape (cell k 4)}}"
      titems := titems.push (
        s!"\{\"track\":{jsonEscape track},\"desired_condition\":{jsonEscape (cell r 1)},\"status\":{jsonEscape (cell r 2)}," ++
        s!"\"state_revision\":{cell r 3},\"attempts\":[{String.intercalate "," attempts.toList}]}")
    return .ok ("[" ++ String.intercalate "," titems.toList ++ "]")

def fnv64 (s : String) : UInt64 := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for b in s.toUTF8.toList do
    h := (h ^^^ b.toUInt64) * 1099511628211
  return if h == 0 then 1 else h

def scopeRankOfName? : String → Option UInt8
  | "ops_read" => some 0
  | "service_deploy" => some 1
  | "root_exec" | "host_admin" => some 2
  | _ => none

def normalizeHostName (h : String) : String :=
  let low := h.trimAscii.toString.toLower
  if low == "local" || low == "localhost" || low == "local-node" || low == "self" then "self"
  else h.trimAscii.toString

/-- Fill a deploy observation from the store, not from the request body.
    `operatorCli` is the local `sandboxed-sh deploy` entry (principal kind 3). -/
def observeDeployLive (st : CoreStore) (unitName : String) (forceFlag dryRun operatorCli : Bool)
    (lease? : Option PrivilegeLeaseRecord) (nowEpoch : UInt64) (memBunker : UInt8 := 0) : IO DeployObservation := do
  let persistedBunker ← readPersistedBunkerState st
  let bunker : UInt8 := if memBunker > persistedBunker then memBunker else persistedBunker
  let writers ← liveWriterCount st
  let self ← callingOnSelfUnit unitName operatorCli
  let debounce ← deployDebounceOk st unitName nowEpoch
  let isProd := deployUnitIsProd unitName
  let scopeOk : Bool :=
    match lease? with
    | none => false
    | some l =>
      l.biometricSigned && !l.revoked && nowEpoch < l.expiresAtEpoch &&
      (l.scope == "service_deploy" || l.scope == "root_exec" || l.scope == "host_admin") &&
      (normalizeHostName l.targetHost == "self" || normalizeHostName l.targetHost == "all")
  let unitsOk ←
    match lease? with
    | some l =>
      let units : Array String :=
        match OrbBin.Json.parse l.allowedUnitsJson with
        | .ok (.arr us) => us.filterMap JVal.asStr?
        | _ => #[]
      match ← OrbBin.PrivdShared.checkScopeRestrictions l.scope units
          #["systemctl", "restart", unitName] none #[] l.requireForceCmd with
      | .ok _ => pure true
      | .error _ => pure false
    | none => pure false
  let principal : UInt8 :=
    if operatorCli then
      if lease?.isSome then 3 else 0
    else match lease? with
      | some l => (scopeRankOfName? l.scope).map (· + 1) |>.getD 0
      | none => 0
  let live : Bool := scopeOk && unitsOk
  let expEp : UInt64 := (lease?.map (·.expiresAtEpoch)).getD 0
  let storedEp : UInt64 := (lease?.map (·.leaseEpoch)).getD 0
  let leaseEp : UInt64 :=
    if !live then 0
    else if storedEp != 0 then storedEp
    else expEp
  let digest := fnv64 s!"{unitName}:{dryRun}:{forceFlag}:{isProd}:{principal}"
  pure {
    unitName := unitName
    isProd := isProd
    serviceMatches := true
    callingOnSelf := self
    debounceOk := debounce
    forceFlag := forceFlag
    biometric := live
    bunkerState := bunker
    liveWriters := writers
    principalKind := principal
    targetId := 1
    leaseEpoch := leaseEp
    expiryTick := expEp
    digest := digest
    nowTick := nowEpoch
  }

def persistDeployReceipt (st : CoreStore) (r : DeployReceipt) (nowAt : String) : IO (Except String Unit) := do
  let wr ← execParamQuery st.missionsDb
    "INSERT INTO deploy_receipts(unit_name,observed_digest,exec_digest,verdict,dry_run,created_at) VALUES(?1,?2,?3,?4,?5,?6);"
    #[r.unitName, s!"{r.observedDigest}", s!"{r.execDigest}", r.verdict, if r.dryRun then "1" else "0", nowAt]
  match wr with
  | .error e => return .error e
  | .ok _ => return .ok ()

def runGuardedDeploy
    (st : CoreStore)
    (observed : DeployObservation)
    (reobserveLive : IO DeployObservation)
    (dryRun : Bool)
    (nowAt : String)
    (restartFn? : Option (String → IO (Except String Unit)) := none) :
    IO (Except String DeployReceipt) := do
  let obs := observeDeploy observed
  let live ← reobserveLive
  let receipt := executeDeploy obs live dryRun
  if receipt.restart then
    let intent : DeployReceipt := { receipt with verdict := "executing", restart := false }
    match ← persistDeployReceipt st intent nowAt with
    | .error e => return .error e
    | .ok () =>
      let execRes ← match restartFn? with
        | some f => f receipt.unitName
        | none =>
          let sysCtlCmd ← if ← System.FilePath.pathExists "/bin/systemctl" then pure "/bin/systemctl" else pure "/usr/bin/systemctl"
          let res ← IO.Process.output { cmd := sysCtlCmd, args := #["restart", receipt.unitName] }
          pure (if res.exitCode == 0 then .ok () else .error s!"systemctl restart failed: {res.stderr}")
      match execRes with
      | .error e =>
        let failed : DeployReceipt := { receipt with verdict := "exec_failed", restart := false }
        match ← persistDeployReceipt st failed nowAt with
        | .error pe => return .error s!"{e};receipt:{pe}"
        | .ok () => return .error e
      | .ok () =>
        match ← persistDeployReceipt st receipt nowAt with
        | .error e => return .error e
        | .ok () => return .ok receipt
  else
    match ← persistDeployReceipt st receipt nowAt with
    | .error e => return .error e
    | .ok () => return .ok receipt

def isContextBlobPostPath (rawTarget : String) : Bool :=
  let clean := ((rawTarget.splitOn "?").headD "").trimAscii.toString
  clean.startsWith "/api/projects/" && clean.endsWith "/context/blobs"

def maxCoreHeaderCount : Nat := 96

def coreMaxBodyForRoute (method rawTarget : String) (confirmedLarge : Bool := false) : Nat :=
  let clean := ((rawTarget.splitOn "?").headD "").trimAscii.toString
  if method == "POST" && isContextBlobPostPath rawTarget then
    if confirmedLarge then contextConfirmedFileLimit.toNat else contextFileLimit
  else if clean.startsWith "/api/managed-machines/relay/" || clean.startsWith "/api/uploads" ||
          (method == "PUT" && clean.startsWith "/api/projects/" && clean.endsWith "/file") ||
          clean.startsWith "/api/fs/" then
    67108864 -- 64 MiB
  else if clean.startsWith "/v1/" || clean.startsWith "/api/mcp/" then
    33554432 -- 32 MiB
  else
    LeanSys.Http.maxHttpBodyBytes

private def validateCoreHeaders (hdrLines : List String) (maxBody : Nat) :
    Except String (Array (String × String) × Option Nat × Option String) := Id.run do
  let mut headers : Array (String × String) := #[]
  let mut seenContentLen : Option Nat := none
  let mut seenAuthorization := false
  let mut authBearer : Option String := none
  for ln in hdrLines do
    if !ln.isEmpty then
      let lnBytes := ln.toUTF8
      let b0 := if lnBytes.size > 0 then lnBytes.get! 0 else 0
      if b0 == 32 || b0 == 9 then
        return .error "obs_fold_header_rejected"
      if LeanSys.Http.hasHttpFieldControlByte ln then
        return .error "invalid_header_value"
      match ln.splitOn ":" with
      | [] | [_] =>
        return .error "malformed_header_line"
      | k :: rest =>
        if !LeanSys.Http.isHttpToken k then
          return .error "invalid_header_name"
        let kTrim := k.trimAscii.toString
        let vTrim := (String.intercalate ":" rest).trimAscii.toString
        headers := headers.push (kTrim, vTrim)
        if headers.size > maxCoreHeaderCount then
          return .error "too_many_headers"
        if LeanSys.Http.asciiEqIgnoreCase kTrim "transfer-encoding" then
          return .error "unsupported_transfer_encoding"
        else if LeanSys.Http.asciiEqIgnoreCase kTrim "content-length" then
          match LeanSys.Http.parseStrictContentLength? vTrim with
          | none =>
            return .error "invalid_content_length"
          | some parsedLen =>
            if parsedLen > maxBody then
              return .error "payload_too_large"
            if seenContentLen.isSome then
              return .error "conflicting_content_length"
            seenContentLen := some parsedLen
        else if LeanSys.Http.asciiEqIgnoreCase kTrim "authorization" then
          if seenAuthorization then
            return .error "duplicate_authorization"
          seenAuthorization := true
          if vTrim.startsWith "Bearer " then
            authBearer := some (vTrim.drop 7).trimAscii.toString
  return .ok (headers, seenContentLen, authBearer)

private def isConfirmedLargeBlob (rawTarget : String) (headers : Array (String × String)) : Bool :=
  let qs := match rawTarget.splitOn "?" with | _ :: rest => String.intercalate "?" rest | [] => ""
  let qConfirmed := (qs.splitOn "&").any (· == "confirmed_large=true")
  let hConfirmed := headers.any (fun (k, v) => LeanSys.Http.asciiEqIgnoreCase k "x-orb-confirmed-large" && v == "1")
  qConfirmed || hConfirmed

def parseCoreHttpRequest (raw : ByteArray) : Except String LeanSys.Http.HttpRequest := do
  let some bodyStart := LeanSys.Http.findHeaderEnd? raw
    | .error "missing_header_terminator"
  if bodyStart - 4 > LeanSys.Http.maxHttpHeaderBytes then
    .error "headers_too_large"
  let rootSlice := ByteSlice.ofByteArray raw
  let some headSlice := ByteSlice.subSlice? rootSlice 0 (bodyStart - 4)
    | .error "invalid_header_slice"
  let some headStr := String.fromUTF8? headSlice.toByteArray
    | .error "invalid_utf8_headers"
  match headStr.splitOn "\r\n" with
  | [] => .error "empty_request_line"
  | reqLine :: hdrLines =>
    let parts := reqLine.trimAscii.toString.splitOn " "
    let (method, path, proto) ← match parts with
      | [m, p, v] => .ok (m.trimAscii.toString, p.trimAscii.toString, v.trimAscii.toString)
      | _ => .error "malformed_request_line"
    if proto != "HTTP/1.1" && proto != "HTTP/1.0" then
      .error "unsupported_http_version"
    else if path.isEmpty || !path.startsWith "/" then
      .error "malformed_request_target"
    else if method != "GET" && method != "POST" && method != "HEAD" && method != "PUT" &&
            method != "DELETE" && method != "PATCH" && method != "OPTIONS" then
      .error s!"unsupported_method:{method}"
    else
      let isBlobPost := method == "POST" && isContextBlobPostPath path
      let outerMax := coreMaxBodyForRoute method path true
      let (headers, cl?, authBearer) ← validateCoreHeaders hdrLines outerMax
      let confirmed := isBlobPost && isConfirmedLargeBlob path headers
      let limit := coreMaxBodyForRoute method path confirmed
      let declContentLen := cl?.getD 0
      if declContentLen > limit then
        .error "payload_too_large"
      else if raw.size - bodyStart != declContentLen then
        .error "content_length_mismatch"
      else
        let some bodySlice := ByteSlice.subSlice? rootSlice bodyStart declContentLen
          | .error "invalid_body_slice"
        .ok {
          method := method
          path := path
          version := proto
          headers := headers
          contentLength := declContentLen
          authBearer := authBearer
          bodySlice := bodySlice
        }

def readCoreHttpRequestBuffered
    (fd : Fd)
    (initialBuf : ByteArray := ByteArray.empty)
    (timeoutMs : UInt32 := 5000) : IO (Except String (LeanSys.Http.HttpRequest × ByteArray)) := do
  let tStart ← IO.monoNanosNow
  let budgetMs : Nat := Nat.max 50 timeoutMs.toNat
  let mut buf := initialBuf
  while (LeanSys.Http.findHeaderEnd? buf).isNone do
    if buf.size > LeanSys.Http.maxHttpHeaderBytes + 4 then
      return .error "headers_too_large"
    let now ← IO.monoNanosNow
    let elapsedMs := (now - tStart) / 1000000
    if elapsedMs >= budgetMs then
      return .error (if buf.isEmpty then "empty_socket_read" else "request_timeout")
    let remMs : UInt32 := (budgetMs - elapsedMs).toUInt32
    match ← pollReadable fd remMs with
    | .error .eagain =>
      return .error (if buf.isEmpty then "empty_socket_read" else "request_timeout")
    | .error _ =>
      return .error "socket_poll_error"
    | .ok () =>
      let chunk ← readStreamChunk fd 16384
      if chunk.isEmpty then
        return .error (if buf.isEmpty then "empty_socket_read" else "missing_header_terminator")
      buf := if buf.isEmpty then chunk else buf ++ chunk
  let some bodyStart := LeanSys.Http.findHeaderEnd? buf
    | return .error "missing_header_terminator"
  if bodyStart - 4 > LeanSys.Http.maxHttpHeaderBytes then
    return .error "headers_too_large"
  let some headStr := String.fromUTF8? (buf.extract 0 (bodyStart - 4))
    | return .error "invalid_utf8_headers"
  let lines := headStr.splitOn "\r\n"
  let reqParts := ((lines.headD "").trimAscii.toString).splitOn " "
  let (reqMethod, rawPath) := match reqParts with
    | [m, p, _] => (m.trimAscii.toString, p.trimAscii.toString)
    | _ => ("", "")
  let isBlobPost := reqMethod == "POST" && isContextBlobPostPath rawPath
  let maxCap := coreMaxBodyForRoute reqMethod rawPath true
  let expectedBody ← match validateCoreHeaders (lines.drop 1) maxCap with
    | .error e => return .error e
    | .ok (hdrs, cl?, _) =>
      let cl := cl?.getD 0
      let confirmed := isBlobPost && isConfirmedLargeBlob rawPath hdrs
      let limit := coreMaxBodyForRoute reqMethod rawPath confirmed
      if cl > limit then return .error "payload_too_large"
      pure cl
  while buf.size - bodyStart < expectedBody do
    let now ← IO.monoNanosNow
    let elapsedMs := (now - tStart) / 1000000
    if elapsedMs >= budgetMs then
      return .error "request_timeout"
    let remMs : UInt32 := (budgetMs - elapsedMs).toUInt32
    match ← pollReadable fd remMs with
    | .error .eagain =>
      return .error "request_timeout"
    | .error _ =>
      return .error "socket_poll_error"
    | .ok () =>
      let missing := expectedBody - (buf.size - bodyStart)
      let chunk ← readStreamChunk fd (Nat.min missing 65536)
      if chunk.isEmpty then
        return .error "content_length_mismatch"
      buf := buf ++ chunk
  let totalReqBytes := bodyStart + expectedBody
  let exact := if totalReqBytes < buf.size then buf.extract 0 totalReqBytes else buf
  let leftover := if totalReqBytes < buf.size then buf.extract totalReqBytes buf.size else ByteArray.empty
  match parseCoreHttpRequest exact with
  | .error e => return .error e
  | .ok req => return .ok (req, leftover)

def readCoreHttpRequestFromFd (fd : Fd) (timeoutMs : UInt32 := 5000) : IO (Except String LeanSys.Http.HttpRequest) := do
  match ← readCoreHttpRequestBuffered fd ByteArray.empty timeoutMs with
  | .error e => return .error e
  | .ok (req, _) => return .ok req

def splitContextSuffix (rest : String) : String × String :=
  if rest == "manifest" || rest == "blobs" || rest == "operations" || rest == "conflicts" ||
     rest == "history" || rest == "stream" then
    (rest, "")
  else if rest.startsWith "blobs/" then
    ("blobs", (rest.drop 6).toString)
  else if rest.startsWith "conflicts/" then
    ("conflicts", (rest.drop 10).toString)
  else
    ("", rest)

end OrbCore.R7Core
