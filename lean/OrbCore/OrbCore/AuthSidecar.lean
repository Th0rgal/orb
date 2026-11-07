/-
  OrbCore.AuthSidecar: Nonce-Bound CLIProxy OAuth Login, Generation-Fenced Credential Rotation &
  `CoalescedAtomicWriter` (`SM-21`, `R4-D`, `0 import Lean`, `0 sorryAx`).

  - `CliProxyLoginSession` binds each CLIProxy login attempt to `<authRoot>/attempts/<attemptNonce>/`
    (`(attemptNonce, provider, startedAtEpoch, expiresAtEpoch)`) so concurrent logins (`attemptA` vs
    `attemptB`) never cross-attribute credentials via ambient `CLI_PROXY_AUTH_DIR` set-diffing.
  - OAuth refresh/rotation steps exclusively through `Orb.HarnessCloud.stepAuthRefreshSlice`
    (`Valid (0) -> RefreshClaimed (1) -> PendingFsync (2) -> Valid (0)` with monotone
    `authGeneration + 1`, `Revoked (3)` sticky). `drainPendingRotations` deletes or marks applied ONLY
    records whose `appliedGen <= committedGen`, so a concurrent `recordPendingRotation(gen = 2)`
    staged during a `gen = 1` drain survives (`R1-02`).
  - `CoalescedAtomicWriter` performs `write temp -> fsync fd -> atomic rename -> fsync parent` under
    exclusive `flock` (`withDirLock`) and advances `flushedSeq` / clears `dirty = false` ONLY after
    `fsync` and `rename` succeed (`commitFsyncAndDrain`, `opCode = 2`, requires `fsyncCompleted == 1`
    and `flockHeld == 1`). A failed `fsync` or `rename` keeps `dirty = true` and preserves `dirtySeq` (`R1-03`).
-/
import Std.Sync.Mutex
import Orb.HarnessCloud
import LeanSys.Posix

namespace OrbCore.AuthSidecar

open Orb.HarnessCloud
open LeanSys.Posix

/-- Reject single path segments (such as `provider`) that contain `/`, `\`, `..`, or NUL. -/
def hasSegmentTraversal (s : String) : Bool := Id.run do
  let bytes := s.toUTF8
  for i in [0:bytes.size] do
    let b := bytes.get! i
    if b == 47 || b == 92 || b == 0 then
      return true
  return (s.splitOn "..").length > 1

/-- Reject multi-segment filesystem paths that contain NUL, `\`, or `..` parent traversal. -/
def hasParentTraversal (s : String) : Bool := Id.run do
  let bytes := s.toUTF8
  for i in [0:bytes.size] do
    let b := bytes.get! i
    if b == 92 || b == 0 then
      return true
  let segs := s.splitOn "/"
  return segs.any (fun seg => seg == "..")

/-- `fsync` the parent directory of `path` so an atomic `rename` or create inside it is durable. -/
def fsyncParentDir (path : String) : IO (SysResult Unit) := do
  let parent := ((System.FilePath.mk path).parent.map (·.toString)).getD "."
  match ← withFd parent 0 (fun fd => writeAll fd ByteArray.empty true) with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- Crash-safely stage and atomically rename a file (`write temp -> fsync fd -> atomic rename -> fsync parent`). -/
private def writeFileAtomicFsync (dstPath : String) (payload : ByteArray) : IO (SysResult Unit) := do
  let nonce ← IO.monoNanosNow
  let tmpPath := s!"{dstPath}.{nonce}.tmp"
  match ← withFd tmpPath 4 (fun fd => writeAll fd payload true) (exclusive := 2) with
  | .error e =>
    discard <| unlinkFile tmpPath
    return .error e
  | .ok _ =>
    match ← atomicRename tmpPath dstPath with
    | .error e =>
      discard <| unlinkFile tmpPath
      return .error e
    | .ok () =>
      fsyncParentDir dstPath

/-! ### Nonce-Bound CLIProxy OAuth Login (`SM-21`) -/

/-- Nonce-bound CLIProxy OAuth login session (`SM-21`). -/
structure CliProxyLoginSession where
  attemptNonce    : UInt64
  provider        : String
  startedAtEpoch  : UInt64
  expiresAtEpoch  : UInt64
  authRoot        : String
  deriving Repr, DecidableEq, Inhabited

/-- `<authRoot>/attempts/<attemptNonce>` isolated directory path for `sess`. -/
def CliProxyLoginSession.attemptDir (sess : CliProxyLoginSession) : String :=
  s!"{sess.authRoot}/attempts/{sess.attemptNonce}"

/-- Credential file path staged inside the nonce-bound attempt directory. -/
def CliProxyLoginSession.credentialPath (sess : CliProxyLoginSession) (provider : String) : String :=
  s!"{sess.attemptDir}/credentials/{provider}.json"

/-- Pure validation for a nonce-bound CLIProxy login session. -/
def validateCliProxyLoginParams
    (authRoot provider : String)
    (attemptNonce startedAtEpoch expiresAtEpoch : UInt64) :
    Except String CliProxyLoginSession := do
  if attemptNonce == 0 then
    throw "zero_attempt_nonce"
  if authRoot.trimAscii.toString.isEmpty || hasParentTraversal authRoot then
    throw "invalid_auth_root"
  if provider.trimAscii.toString.isEmpty || hasSegmentTraversal provider then
    throw "invalid_provider"
  if !(startedAtEpoch < expiresAtEpoch) then
    throw "login_expiry_not_in_future"
  return {
    attemptNonce := attemptNonce
    provider := provider
    startedAtEpoch := startedAtEpoch
    expiresAtEpoch := expiresAtEpoch
    authRoot := authRoot
  }

/-- Outcome of atomic CLIProxy login session table reservation before touching disk (`SM-21`). -/
inductive CliProxySessionAdmission where
  | admittedNew
  | refreshedSameProvider (previous : CliProxyLoginSession)
  | duplicateNonceProviderConflict
  | capacityExceeded
  deriving Repr, DecidableEq

/-- Atomically prune expired sessions at `nowEpoch` and enforce global uniqueness of active
    `cand.attemptNonce` across ALL unexpired sessions (`maxCap` capacity):
    - Active session with `s.attemptNonce == cand.attemptNonce` and `s.provider != cand.provider`
      is rejected (`.duplicateNonceProviderConflict`, HTTP 409) without mutating active sessions.
    - Active session with `(cand.attemptNonce, cand.provider)` refreshes in-place
      (`.refreshedSameProvider prev`) without pre-evicting the slot or freeing room for a 64th session.
    - Otherwise admits `cand` iff `live.size < maxCap`, else `.capacityExceeded` (HTTP 429). -/
def admitOrRefreshCliProxySession
    (xs : Array CliProxyLoginSession)
    (cand : CliProxyLoginSession)
    (nowEpoch : UInt64)
    (maxCap : Nat) :
    CliProxySessionAdmission × Array CliProxyLoginSession :=
  let live := xs.filter (fun s => nowEpoch < s.expiresAtEpoch)
  match live.find? (fun s => s.attemptNonce == cand.attemptNonce) with
  | some prev =>
    if prev.provider != cand.provider then
      (.duplicateNonceProviderConflict, live)
    else
      let updated := live.map (fun s =>
        if s.attemptNonce == cand.attemptNonce then cand else s)
      (.refreshedSameProvider prev, updated)
  | none =>
    if live.size ≥ maxCap then
      (.capacityExceeded, live)
    else
      (.admittedNew, live.push cand)

/-- Begin a CLIProxy login attempt bound to `<authRoot>/attempts/<attemptNonce>/credentials/`.
    Rejects a zero nonce, path traversal, and an expiry not strictly after `startedAtEpoch`. -/
def beginCliProxyLogin
    (authRoot provider : String)
    (attemptNonce startedAtEpoch expiresAtEpoch : UInt64) :
    IO (Except String CliProxyLoginSession) := do
  match validateCliProxyLoginParams authRoot provider attemptNonce startedAtEpoch expiresAtEpoch with
  | .error e => return .error e
  | .ok sess =>
    match ← (IO.FS.createDirAll (sess.attemptDir ++ "/credentials")).toBaseIO with
    | .error ioErr => return .error s!"attempt_dir_create_failed:{ioErr}"
    | .ok () => return .ok sess

/-- Stage discovered credentials strictly inside `<authRoot>/attempts/<attemptNonce>/credentials/<provider>.json`.
    Rejects mismatched `presentedNonce`, mismatched `provider`, empty/non-JSON payloads, or expired attempts
    with zero ambient `CLI_PROXY_AUTH_DIR` writes. -/
def stageCliProxyCredential
    (sess : CliProxyLoginSession)
    (presentedNonce : UInt64)
    (provider : String)
    (credentialJson : String)
    (nowEpoch : UInt64) : IO (Except String String) := do
  if sess.attemptNonce == 0 || presentedNonce != sess.attemptNonce then
    return .error "nonce_mismatch"
  if provider != sess.provider || hasSegmentTraversal provider then
    return .error "provider_mismatch"
  if !(nowEpoch < sess.expiresAtEpoch) then
    return .error "login_attempt_expired"
  let trimmed := credentialJson.trimAscii.toString
  if trimmed.isEmpty || !trimmed.startsWith "{" || !trimmed.endsWith "}" then
    return .error "invalid_credential_payload"
  let path := sess.credentialPath provider
  match ← writeFileAtomicFsync path credentialJson.toUTF8 with
  | .error e => return .error s!"stage_write_failed:{repr e}"
  | .ok () => return .ok path

/-- Read back staged credentials ONLY when `presentedNonce == sess.attemptNonce` and `provider == sess.provider`.
    A concurrent login carrying a different nonce can never observe or attribute this attempt's credentials. -/
def readStagedCliProxyCredential
    (sess : CliProxyLoginSession)
    (presentedNonce : UInt64)
    (provider : String) : IO (Except String String) := do
  if sess.attemptNonce == 0 || presentedNonce != sess.attemptNonce then
    return .error "nonce_mismatch"
  if provider != sess.provider || hasSegmentTraversal provider then
    return .error "provider_mismatch"
  let path := sess.credentialPath provider
  match ← (IO.FS.readFile path).toBaseIO with
  | .error _ => return .error "credential_missing"
  | .ok raw => return .ok raw

/-- Atomically promote a validated nonce-bound credential from `<authRoot>/attempts/<attemptNonce>/`
    into `<authRoot>/promoted/<provider>.json` under an exclusive `flock` on `<authRoot>/promote.lock`.
    Unlinks the staged attempt file after durable atomic promotion so it cannot be replayed. -/
def promoteCliProxyCredential
    (sess : CliProxyLoginSession)
    (presentedNonce : UInt64)
    (provider : String)
    (nowEpoch : UInt64) : IO (Except String String) := do
  if sess.attemptNonce == 0 || presentedNonce != sess.attemptNonce then
    return .error "nonce_mismatch"
  if provider != sess.provider || hasSegmentTraversal provider then
    return .error "provider_mismatch"
  if !(nowEpoch < sess.expiresAtEpoch) then
    return .error "login_attempt_expired"
  let src := sess.credentialPath provider
  match ← (IO.FS.readFile src).toBaseIO with
  | .error _ => return .error "credential_missing"
  | .ok raw =>
    let trimmed := raw.trimAscii.toString
    if trimmed.isEmpty || !trimmed.startsWith "{" || !trimmed.endsWith "}" then
      return .error "invalid_credential_payload"
    let promotedDir := s!"{sess.authRoot}/promoted"
    match ← (IO.FS.createDirAll promotedDir).toBaseIO with
    | .error ioErr => return .error s!"promote_dir_create_failed:{ioErr}"
    | .ok () =>
      let lockPath := s!"{sess.authRoot}/promote.lock"
      let dst := s!"{promotedDir}/{provider}.json"
      let res ← withDirLock lockPath false fun _ => do
        match ← writeFileAtomicFsync dst raw.toUTF8 with
        | .error e => pure (.error e)
        | .ok () =>
          discard <| unlinkFile src
          pure (.ok ())
      match res with
      | .error e => return .error s!"promote_write_failed:{repr e}"
      | .ok () => return .ok dst

/-! ### Generation-Fenced OAuth Rotation (`R1-02`) -/

/-- One pending credential rotation staged for generation `appliedGen`. -/
structure PendingRotation where
  appliedGen : UInt64
  recordPath : String
  applied    : Bool := false
  deriving Repr, DecidableEq, Inhabited

/-- Durable OAuth credential rotation state. `phaseCode` mirrors `AuthRefreshPhase`
    (`0 = valid`, `1 = refreshClaimed`, `2 = pendingFsync`, `3 = revoked`). -/
structure AuthRotationState where
  phaseCode             : UInt8 := 0
  dirtyPending          : UInt8 := 0
  durableAuthGeneration : UInt64 := 1
  activeLoginNonce      : UInt64 := 0
  tokenExpiryEpoch      : UInt64 := 0
  leaseDeadlineEpoch    : UInt64 := 0
  pendingRotations      : Array PendingRotation := #[]
  deriving Repr, DecidableEq, Inhabited

/-- Step `st` through `Orb.HarnessCloud.stepAuthRefreshSlice`.
    On `commitFsyncAndDrain` (`opCode = 2`), enforces BOTH `nowEpoch < ev.newExpiryEpoch` (via kernel)
    AND `st.leaseDeadlineEpoch == 0 || ev.nowEpoch < st.leaseDeadlineEpoch` (`nowEpoch < leaseDeadline`),
    returning `some committedGen` ONLY when the transition is admitted. -/
def stepAuthRotation (st : AuthRotationState) (ev : AuthRefreshSliceEvent) :
    AuthRotationState × List AuthRefreshEffect × Option UInt64 :=
  if ev.opCode == AuthRefreshOp.encode .commitFsyncAndDrain &&
     st.leaseDeadlineEpoch != 0 && !(ev.nowEpoch < st.leaseDeadlineEpoch) then
    (st, [], none)
  else
    let sliceIn : AuthRefreshSliceState := {
      phaseCode := st.phaseCode
      dirtyPending := st.dirtyPending
      durableAuthGeneration := st.durableAuthGeneration
      activeLoginNonce := st.activeLoginNonce
      tokenExpiryEpoch := st.tokenExpiryEpoch
    }
    let (sliceOut, effs) := stepAuthRefreshSlice sliceIn ev
    let committedGen? :=
      if sliceOut.phaseCode != sliceIn.phaseCode && ev.opCode == AuthRefreshOp.encode .commitFsyncAndDrain then
        some sliceOut.durableAuthGeneration
      else
        none
    ({ st with
       phaseCode := sliceOut.phaseCode
       dirtyPending := sliceOut.dirtyPending
       durableAuthGeneration := sliceOut.durableAuthGeneration
       activeLoginNonce := sliceOut.activeLoginNonce
       tokenExpiryEpoch := sliceOut.tokenExpiryEpoch }, effs, committedGen?)

/-- Claim an OAuth refresh (`Valid (0) -> RefreshClaimed (1)`) with consecutive `durableAuthGeneration + 1`,
    binding `attemptNonce` and optional `leaseDeadlineEpoch`. -/
def claimAuthRefresh
    (st : AuthRotationState)
    (attemptNonce : UInt64)
    (nowEpoch : UInt64)
    (leaseDeadlineEpoch : UInt64 := 0) :
    Except String (AuthRotationState × List AuthRefreshEffect) :=
  if st.durableAuthGeneration == 0 || st.durableAuthGeneration == 0xFFFFFFFFFFFFFFFF then
    .error "generation_exhausted_or_zero"
  else if leaseDeadlineEpoch != 0 && !(nowEpoch < leaseDeadlineEpoch) then
    .error "refresh_lease_expired"
  else
    let candGen := st.durableAuthGeneration + 1
    let ev : AuthRefreshSliceEvent := {
      opCode := AuthRefreshOp.encode .claimRefresh
      fsyncCompleted := 0
      flockHeld := 1
      candidateGeneration := candGen
      reqLoginNonce := attemptNonce
      nowEpoch := nowEpoch
      newExpiryEpoch := 0
    }
    let (st', effs, _) := stepAuthRotation { st with leaseDeadlineEpoch := leaseDeadlineEpoch } ev
    if effs.isEmpty then
      .error "claim_refresh_rejected"
    else
      .ok (st', effs)

/-- Stage a rotated credential (`RefreshClaimed (1) -> PendingFsync (2)`), requiring `presentedNonce`
    to match `st.activeLoginNonce` and `candidateGen == st.durableAuthGeneration`. -/
def stageAuthRotation
    (st : AuthRotationState)
    (candidateGen presentedNonce nowEpoch : UInt64)
    (recordPath : String) :
    Except String (AuthRotationState × List AuthRefreshEffect) :=
  if recordPath.trimAscii.toString.isEmpty || hasParentTraversal recordPath then
    .error "invalid_rotation_path"
  else
    let ev : AuthRefreshSliceEvent := {
      opCode := AuthRefreshOp.encode .stageRotatedSecret
      fsyncCompleted := 0
      flockHeld := 1
      candidateGeneration := candidateGen
      reqLoginNonce := presentedNonce
      nowEpoch := nowEpoch
      newExpiryEpoch := 0
    }
    let (st1, effs, _) := stepAuthRotation st ev
    if effs.isEmpty then
      .error "stage_rotation_rejected"
    else
      let entry : PendingRotation := { appliedGen := st1.durableAuthGeneration, recordPath := recordPath, applied := false }
      let nextPending :=
        if st1.pendingRotations.any (fun r => r.appliedGen == entry.appliedGen && r.recordPath == entry.recordPath) then
          st1.pendingRotations
        else
          st1.pendingRotations.push entry
      .ok ({ st1 with pendingRotations := nextPending }, effs)

/-- Transiently abort an in-flight refresh (`RefreshClaimed (1) | PendingFsync (2) -> Valid (0)`),
    retaining `dirtyPending` for retry/backoff without advancing or rewinding `durableAuthGeneration`. -/
def abortAuthRefreshTransient
    (st : AuthRotationState)
    (candidateGen nowEpoch : UInt64) :
    Except String (AuthRotationState × List AuthRefreshEffect) :=
  let ev : AuthRefreshSliceEvent := {
    opCode := AuthRefreshOp.encode .abortRefreshTransient
    fsyncCompleted := 0
    flockHeld := 0
    candidateGeneration := candidateGen
    reqLoginNonce := 0
    nowEpoch := nowEpoch
    newExpiryEpoch := 0
  }
  let (st', effs, _) := stepAuthRotation st ev
  if effs.isEmpty then .error "abort_refresh_rejected" else .ok ({ st' with leaseDeadlineEpoch := 0 }, effs)

/-- Permanently mark a credential `Revoked (3)` (`Valid | RefreshClaimed | PendingFsync -> Revoked`).
    `Revoked` is sticky in `verifyAuthRefreshAdmit`: all subsequent refresh/stage/commit/revoke ops fail closed. -/
def revokeAuthCredential
    (st : AuthRotationState)
    (candidateGen nowEpoch : UInt64) :
    Except String (AuthRotationState × List AuthRefreshEffect) :=
  let ev : AuthRefreshSliceEvent := {
    opCode := AuthRefreshOp.encode .revokeCredential
    fsyncCompleted := 0
    flockHeld := 0
    candidateGeneration := candidateGen
    reqLoginNonce := 0
    nowEpoch := nowEpoch
    newExpiryEpoch := 0
  }
  let (st', effs, _) := stepAuthRotation st ev
  if effs.isEmpty then .error "revoke_rejected" else .ok ({ st' with leaseDeadlineEpoch := 0 }, effs)

/-- Record a pending rotation entry for `appliedGen` (`>= st.durableAuthGeneration`, including a concurrent
    next-generation `appliedGen > committedGen` staged while an earlier generation is draining, `R1-02`).
    Rejects zero or stale (`appliedGen < st.durableAuthGeneration`) generations. -/
def recordPendingRotation (st : AuthRotationState) (appliedGen : UInt64) (recordPath : String) :
    Except String AuthRotationState :=
  if appliedGen == 0 || appliedGen < st.durableAuthGeneration then
    .error "rotation_generation_stale"
  else if recordPath.trimAscii.toString.isEmpty || hasParentTraversal recordPath then
    .error "invalid_rotation_path"
  else
    let entry : PendingRotation := { appliedGen := appliedGen, recordPath := recordPath, applied := false }
    .ok { st with pendingRotations := st.pendingRotations.push entry }

/-- Drain applied rotations up to and including `committedGen` (`R1-02`).
    Unlinks on disk and drops from `pendingRotations` ONLY records with `appliedGen <= committedGen`;
    any rotation recorded concurrently for `appliedGen > committedGen` (e.g. `gen = 2` while draining `gen = 1`)
    survives untouched both in memory and on disk! -/
def drainPendingRotations (st : AuthRotationState) (committedGen : UInt64) :
    IO (AuthRotationState × Array String) := do
  let mut kept : Array PendingRotation := #[]
  let mut drained : Array String := #[]
  for rec in st.pendingRotations do
    if rec.appliedGen ≤ committedGen then
      discard <| unlinkFile rec.recordPath
      drained := drained.push rec.recordPath
    else
      kept := kept.push rec
  return ({ st with pendingRotations := kept }, drained)

/-! ### `CoalescedAtomicWriter` (`R1-03`) -/

/-- Coalesced crash-safe writer state (`write temp -> fsync fd -> atomic rename -> fsync parent`).
    `dirty` is cleared (`false`) and `flushedSeq` advances ONLY after both `fsync` and `rename`
    succeed (`R1-03`). -/
structure CoalescedAtomicWriter where
  targetPath : String
  lockPath   : String := ""
  dirty      : Bool := false
  dirtySeq   : UInt64 := 0
  flushedSeq : UInt64 := 0
  payload    : ByteArray := ByteArray.empty
  deriving Inhabited

/-- Create a fresh `CoalescedAtomicWriter` for `targetPath` (defaulting `lockPath` to `<targetPath>.lock`). -/
def CoalescedAtomicWriter.new (targetPath : String) (lockPath : String := "") : CoalescedAtomicWriter :=
  { targetPath := targetPath
    lockPath := if lockPath.isEmpty then s!"{targetPath}.lock" else lockPath }

/-- Stage `payload` at sequence `seq`. If `seq <= w.dirtySeq`, advances `dirtySeq` monotonically when `seq == 0`
    is omitted via `stageNext`, or ignores stale out-of-order sequences (`seq <= w.dirtySeq`). -/
def CoalescedAtomicWriter.stage (w : CoalescedAtomicWriter) (seq : UInt64) (payload : ByteArray) :
    CoalescedAtomicWriter :=
  if w.dirtySeq < seq then
    { w with dirty := true, dirtySeq := seq, payload := payload }
  else
    w

/-- Coalesce a new `payload` onto `w`, monotonically advancing `dirtySeq := w.dirtySeq + 1` and setting `dirty = true`. -/
def CoalescedAtomicWriter.stageNext (w : CoalescedAtomicWriter) (payload : ByteArray) :
    CoalescedAtomicWriter :=
  let nextSeq := if w.dirtySeq < 0xFFFFFFFFFFFFFFFF then w.dirtySeq + 1 else w.dirtySeq
  { w with dirty := true, dirtySeq := nextSeq, payload := payload }

/-- Flush the latest coalesced payload under exclusive `flock` (`write temp -> fsync fd -> atomic rename -> fsync parent`)
    with optional fault injection hooks (`simulateFsyncFail`, `simulateRenameFail`) for deterministic testing (`R1-03`).
    - When `w.dirty == false`, returns `.ok w` immediately.
    - When `fsyncConfirmed == false`, `simulateFsyncFail == true`, or `simulateRenameFail == true` (or when any
      underlying syscall fails), returns `.error` and preserves `w` with `dirty = true`, `dirtySeq = w.dirtySeq`,
      and `flushedSeq = w.flushedSeq`.
    - ONLY after `writeAll(..., doSync := true)` + `atomicRename` + `fsyncParentDir` all succeed does it return
      `{ w with dirty := false, flushedSeq := w.dirtySeq, payload := ByteArray.empty }`. -/
def CoalescedAtomicWriter.flushWithFaults
    (w : CoalescedAtomicWriter)
    (fsyncConfirmed : Bool := true)
    (simulateFsyncFail : Bool := false)
    (simulateRenameFail : Bool := false) :
    IO (SysResult CoalescedAtomicWriter) := do
  if !w.dirty then
    return .ok w
  if !fsyncConfirmed || simulateFsyncFail then
    return .error .eio
  let effLock := if w.lockPath.isEmpty then s!"{w.targetPath}.lock" else w.lockPath
  withDirLock effLock false fun _ => do
    let nonce ← IO.monoNanosNow
    let tmpPath := s!"{w.targetPath}.{nonce}.tmp"
    match ← withFd tmpPath 4 (fun fd => writeAll fd w.payload true) (exclusive := 2) with
    | .error e =>
      discard <| unlinkFile tmpPath
      pure (.error e)
    | .ok _ =>
      if simulateRenameFail then
        discard <| unlinkFile tmpPath
        pure (.error .eio)
      else
        match ← atomicRename tmpPath w.targetPath with
        | .error e =>
          discard <| unlinkFile tmpPath
          pure (.error e)
        | .ok () =>
          match ← fsyncParentDir w.targetPath with
          | .error e => pure (.error e)
          | .ok () =>
            pure (.ok { w with dirty := false, flushedSeq := w.dirtySeq, payload := ByteArray.empty })

/-- Crash-safely commit the dirty payload (`write temp -> fsync fd -> atomic rename -> fsync parent` under `flock`). -/
def CoalescedAtomicWriter.commit (w : CoalescedAtomicWriter) (fsyncConfirmed : Bool := true) :
    IO (SysResult CoalescedAtomicWriter) :=
  w.flushWithFaults fsyncConfirmed false false

/-- Live rotation ledger: sequence-compared staging so a concurrent `stageNext` is never
    overwritten by an older commit, and generation-fenced drain runs under the same `flock`. -/
structure AuthRotationLedger where
  writer   : CoalescedAtomicWriter
  rotation : AuthRotationState
  deriving Inhabited

abbrev AuthRotationHandle := Std.Mutex AuthRotationLedger

def newAuthRotationHandle (targetPath : String) (rotation : AuthRotationState := {})
    (lockPath : String := "") : IO AuthRotationHandle :=
  Std.Mutex.new { writer := CoalescedAtomicWriter.new targetPath lockPath, rotation := rotation }

/-- Stage `payload` at `seq` only when `seq` is strictly newer than `writer.dirtySeq`.
    A lost or older generation does not clobber a newer staged payload. -/
def stageRotationSeq (h : AuthRotationHandle) (seq : UInt64) (payload : ByteArray) : IO CoalescedAtomicWriter :=
  h.atomically do
    let led ← get
    let w' := led.writer.stage seq payload
    set { led with writer := w' }
    return w'

/-- Snapshot `(writer, rotation)` atomically from `AuthRotationHandle`. -/
def snapshotRotationLedger (h : AuthRotationHandle) : IO AuthRotationLedger :=
  h.atomically do
    get

/-- Claim an OAuth refresh (`Valid (0) -> RefreshClaimed (1)`) on the live `AuthRotationHandle`. -/
def claimAuthRefreshLive
    (h : AuthRotationHandle)
    (attemptNonce nowEpoch : UInt64)
    (leaseDeadlineEpoch : UInt64 := 0) :
    IO (Except String AuthRotationState) :=
  h.atomically do
    let led ← get
    match claimAuthRefresh led.rotation attemptNonce nowEpoch leaseDeadlineEpoch with
    | .error e => return .error e
    | .ok (st', _) =>
      set { led with rotation := st' }
      return .ok st'

/-- Stage a rotated secret (`RefreshClaimed (1) -> PendingFsync (2)`), crash-safely write `recordPath`
    via `writeFileAtomicFsync`, and monotonically coalesce `payload` via `stageNext` (or explicit `seq`)
    on the live `AuthRotationHandle`.
    Admission (`phase`, generation, nonce, path) is decided under the ledger mutex BEFORE any disk
    write or `CoalescedAtomicWriter` mutation. A rejected call leaves both disk and writer untouched. -/
def stageAuthRotationLive
    (h : AuthRotationHandle)
    (candidateGen presentedNonce nowEpoch : UInt64)
    (recordPath : String)
    (payload? : Option ByteArray := none)
    (seq? : Option UInt64 := none)
    (recordBytes? : Option ByteArray := none) :
    IO (Except String (AuthRotationState × CoalescedAtomicWriter)) := do
  let effLock ← h.atomically do
    let led ← get
    pure (if led.writer.lockPath.isEmpty then s!"{led.writer.targetPath}.lock" else led.writer.lockPath)
  let res ← withDirLock effLock false fun _ => do
    let inner : IO (Except String (AuthRotationState × CoalescedAtomicWriter)) :=
      h.atomically (m := IO) do
        let led ← get
        match stageAuthRotation led.rotation candidateGen presentedNonce nowEpoch recordPath with
        | .error e => return .error e
        | .ok (st', _) =>
          let diskBytes? ←
            match recordBytes?.orElse (fun _ => payload?) with
            | some rBytes => pure (some rBytes)
            | none =>
              if ← (System.FilePath.mk recordPath).pathExists then
                pure none
              else
                pure (some s!"\{\"gen\":{candidateGen}}".toUTF8)
          match diskBytes? with
          | some rBytes =>
            if let some parent := (System.FilePath.mk recordPath).parent then
              discard <| (IO.FS.createDirAll parent).toBaseIO
            match ← writeFileAtomicFsync recordPath rBytes with
            | .error e =>
              return .error s!"stage_write_failed:{repr e}"
            | .ok () => pure ()
          | none => pure ()
          let w' :=
            match payload? with
            | none => led.writer
            | some bytes =>
              match seq? with
              | some s => led.writer.stage s bytes
              | none => led.writer.stageNext bytes
          set ({ writer := w', rotation := st' } : AuthRotationLedger)
          return .ok (st', w')
    return (.ok (← inner))
  match res with
  | .error e => return .error s!"stage_lock_failed:{repr e}"
  | .ok out => return out

/-- Coalesce a new payload monotonically (`dirtySeq + 1`) on `AuthRotationHandle`. -/
def stageRotationNext (h : AuthRotationHandle) (payload : ByteArray) : IO CoalescedAtomicWriter :=
  h.atomically do
    let led ← get
    let w' := led.writer.stageNext payload
    set { led with writer := w' }
    return w'

/-- Transiently abort an in-flight refresh on `AuthRotationHandle`. -/
def abortAuthRefreshLive (h : AuthRotationHandle) (candidateGen nowEpoch : UInt64) :
    IO (Except String AuthRotationState) :=
  h.atomically do
    let led ← get
    match abortAuthRefreshTransient led.rotation candidateGen nowEpoch with
    | .error e => return .error e
    | .ok (st', _) =>
      set { led with rotation := st' }
      return .ok st'

/-- Permanently revoke the credential (`Revoked (3)`) on `AuthRotationHandle`. -/
def revokeAuthCredentialLive (h : AuthRotationHandle) (candidateGen nowEpoch : UInt64) :
    IO (Except String AuthRotationState) :=
  h.atomically do
    let led ← get
    match revokeAuthCredential led.rotation candidateGen nowEpoch with
    | .error e => return .error e
    | .ok (st', _) =>
      set { led with rotation := st' }
      return .ok st'

/-- Record a pending rotation while holding both `withDirLock` and the ledger mutex (`R1-02`).
    Admission (`appliedGen != 0 && appliedGen >= durableAuthGeneration` and safe `recordPath`) is checked
    FIRST; only when admitted does it crash-safely write `recordBytes?` via `writeFileAtomicFsync` and
    optionally coalesce onto `CoalescedAtomicWriter`. A rejected stale/zero generation leaves disk and
    `CoalescedAtomicWriter` completely untouched. -/
def recordPendingRotationLive
    (h : AuthRotationHandle)
    (appliedGen : UInt64)
    (recordPath : String)
    (recordBytes? : Option ByteArray := none)
    (coalesceWriter : Bool := false)
    (seq? : Option UInt64 := none) :
    IO (Except String AuthRotationState) := do
  let effLock ← h.atomically do
    let led ← get
    pure (if led.writer.lockPath.isEmpty then s!"{led.writer.targetPath}.lock" else led.writer.lockPath)
  let res ← withDirLock effLock false fun _ => do
    let inner : IO (Except String AuthRotationState) :=
      h.atomically (m := IO) do
        let led ← get
        match recordPendingRotation led.rotation appliedGen recordPath with
        | .error e => return .error e
        | .ok st' =>
          match recordBytes? with
          | some rBytes =>
            if let some parent := (System.FilePath.mk recordPath).parent then
              discard <| (IO.FS.createDirAll parent).toBaseIO
            match ← writeFileAtomicFsync recordPath rBytes with
            | .error e =>
              return .error s!"record_pending_write_failed:{repr e}"
            | .ok () => pure ()
          | none => pure ()
          let w' :=
            if coalesceWriter then
              match recordBytes? with
              | none => led.writer
              | some bytes =>
                match seq? with
                | some s => led.writer.stage s bytes
                | none => led.writer.stageNext bytes
            else
              led.writer
          set ({ writer := w', rotation := st' } : AuthRotationLedger)
          return .ok st'
    return (.ok (← inner))
  match res with
  | .error e => return .error s!"record_pending_lock_failed:{repr e}"
  | .ok out => return out

/-- Complete `PendingFsync (2) -> Valid (0)` under one exclusive `flock` covering dirty-clear,
    `stepAuthRotation`, and generation-fenced unlink (`R1-02`, `R1-03`):
    1. Snapshot the live ledger under the mutex. If `seenDirtySeq != writer.dirtySeq`, a concurrent
       `stageNext` landed and this commit is refused without clearing `dirty`.
    2. Hold `withDirLock` across flush, kernel commit, and `drainPendingRotations` unlinks.
    3. Under one `h.atomically` critical section, re-check `dirtySeq` after `fsync` and, only when it
       still matches, `atomicRename`, clear `dirty`, `stepAuthRotation`, and `drainPendingRotations`
       with no gap. A newer sequence unlinks the temp file, keeps `dirty = true`, and returns
       `concurrent_stage_generation_mismatch` (never a silent success).
    4. Unlink only `appliedGen <= committedGen`. `fsync` / `rename` failure leaves `dirty = true`. -/
def commitAndDrainRotation
    (st : AuthRotationState)
    (w : CoalescedAtomicWriter)
    (candidateGen nowEpoch newExpiryEpoch : UInt64)
    (simulateFsyncFail : Bool := false)
    (simulateRenameFail : Bool := false)
    (live? : Option AuthRotationHandle := none) :
    IO (Except String (AuthRotationState × CoalescedAtomicWriter × Array String × List AuthRefreshEffect)) := do
  if st.phaseCode != AuthRefreshPhase.encode .pendingFsync then
    return .error "not_in_pending_fsync"
  if candidateGen != st.durableAuthGeneration then
    return .error "stale_or_mismatched_generation"
  if st.leaseDeadlineEpoch != 0 && !(nowEpoch < st.leaseDeadlineEpoch) then
    return .error "refresh_lease_expired"
  if !(nowEpoch < newExpiryEpoch) then
    return .error "token_expiry_not_in_future"
  let snap ← match live? with
    | some h => h.atomically do
        let led ← get
        pure led
    | none => pure { writer := w, rotation := st }
  if snap.writer.dirtySeq != w.dirtySeq || snap.rotation.durableAuthGeneration != st.durableAuthGeneration then
    return .error "concurrent_stage_generation_mismatch"
  let seenSeq := snap.writer.dirtySeq
  let effLock := if snap.writer.lockPath.isEmpty then s!"{snap.writer.targetPath}.lock" else snap.writer.lockPath
  let locked ← withDirLock effLock false fun _ => do
    if snap.writer.dirty && simulateFsyncFail then
      return .error .eio
    let ev : AuthRefreshSliceEvent := {
      opCode := AuthRefreshOp.encode .commitFsyncAndDrain
      fsyncCompleted := 1
      flockHeld := 1
      candidateGeneration := candidateGen
      reqLoginNonce := 0
      nowEpoch := nowEpoch
      newExpiryEpoch := newExpiryEpoch
    }
    match live? with
    | none =>
      let flushed : SysResult CoalescedAtomicWriter ←
        if !snap.writer.dirty then
          pure (.ok snap.writer)
        else do
          let nonce ← IO.monoNanosNow
          let tmpPath := s!"{snap.writer.targetPath}.{nonce}.tmp"
          match ← withFd tmpPath 4 (fun fd => writeAll fd snap.writer.payload true) (exclusive := 2) with
          | .error e =>
            discard <| unlinkFile tmpPath
            pure (.error e)
          | .ok _ =>
            if simulateRenameFail then
              discard <| unlinkFile tmpPath
              pure (.error .eio)
            else
              match ← atomicRename tmpPath snap.writer.targetPath with
              | .error e =>
                discard <| unlinkFile tmpPath
                pure (.error e)
              | .ok () =>
                match ← fsyncParentDir snap.writer.targetPath with
                | .error e => pure (.error e)
                | .ok () =>
                  pure (.ok { snap.writer with dirty := false, flushedSeq := snap.writer.dirtySeq, payload := ByteArray.empty })
      match flushed with
      | .error e => pure (.error e)
      | .ok wFlushed =>
        let (stStep, effs, committedGen?) := stepAuthRotation snap.rotation ev
        match committedGen? with
        | none => pure (.error .einval)
        | some cGen =>
          let (stDrained, drainedPaths) ← drainPendingRotations { stStep with leaseDeadlineEpoch := 0 } cGen
          pure (.ok (stDrained, wFlushed, drainedPaths, effs))
    | some h =>
      let tmpPath? : SysResult (Option String) ←
        if !snap.writer.dirty then
          pure (.ok none)
        else do
          let nonce ← IO.monoNanosNow
          let tmpPath := s!"{snap.writer.targetPath}.{nonce}.tmp"
          match ← withFd tmpPath 4 (fun fd => writeAll fd snap.writer.payload true) (exclusive := 2) with
          | .error e =>
            discard <| unlinkFile tmpPath
            pure (.error e)
          | .ok _ =>
            if simulateRenameFail then
              discard <| unlinkFile tmpPath
              pure (.error .eio)
            else
              pure (.ok (some tmpPath))
      match tmpPath? with
      | .error e => pure (.error e)
      | .ok stagedTmp? =>
        h.atomically (m := IO) do
          let led ← get
          let cleanupTmp : IO Unit :=
            match stagedTmp? with
            | some tp => do discard <| unlinkFile tp
            | none => pure ()
          if led.writer.dirtySeq != seenSeq || led.rotation.durableAuthGeneration != st.durableAuthGeneration then
            cleanupTmp
            return (Except.error .eagain
              : SysResult (AuthRotationState × CoalescedAtomicWriter × Array String × List AuthRefreshEffect))
          else
            let (stStep, effs, committedGen?) := stepAuthRotation led.rotation ev
            match committedGen? with
            | none =>
              cleanupTmp
              return (Except.error .einval
                : SysResult (AuthRotationState × CoalescedAtomicWriter × Array String × List AuthRefreshEffect))
            | some cGen =>
              let wRes : SysResult CoalescedAtomicWriter ←
                match stagedTmp? with
                | none => pure (.ok led.writer)
                | some tp => do
                  match ← atomicRename tp snap.writer.targetPath with
                  | .error e =>
                    discard <| unlinkFile tp
                    pure (.error e)
                  | .ok () =>
                    match ← fsyncParentDir snap.writer.targetPath with
                    | .error e => pure (.error e)
                    | .ok () =>
                      pure (.ok { snap.writer with dirty := false, flushedSeq := snap.writer.dirtySeq, payload := ByteArray.empty })
              match wRes with
              | .error e =>
                return (Except.error e
                  : SysResult (AuthRotationState × CoalescedAtomicWriter × Array String × List AuthRefreshEffect))
              | .ok wOut =>
                let (stDrained, drainedPaths) ← drainPendingRotations { stStep with leaseDeadlineEpoch := 0 } cGen
                set ({ writer := wOut, rotation := stDrained } : AuthRotationLedger)
                return (Except.ok (stDrained, wOut, drainedPaths, effs)
                  : SysResult (AuthRotationState × CoalescedAtomicWriter × Array String × List AuthRefreshEffect))
  match locked with
  | .error .eagain =>
    return .error "concurrent_stage_generation_mismatch"
  | .error e =>
    return .error s!"commit_fsync_or_rename_failed:{repr e}"
  | .ok packed =>
    return .ok packed

end OrbCore.AuthSidecar
