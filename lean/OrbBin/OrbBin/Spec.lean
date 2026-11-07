/-
  OrbBin.Spec: Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for Wave 1 Companion Binaries (`fido-agent-proxy`, `orb-privd`, `orb-sudo`, `lean-mesh`,
  `palomactl`, `sandboxed-mcp`, `workspace-mcp`, `desktop-mcp`, `automation-manager-mcp`).

  Every unboxed scalar gate is proved equivalent (`MetaGateSpec`, `ScopedAuthority`,
  `ConservedResource`) to an independent domain model over typed protocol ADTs and
  natural-number resource invariants rather than mirroring the gate's boolean formula.
-/
namespace OrbBin.Spec

/-- Universal 4-property Meta-Gate specification bundle (`sound`, `complete`,
    `posWitness`, `negWitness`, `nonVacuous`, `tight`). -/
structure MetaGateSpec (Input : Type) (Safe : Input → Prop) where
  gate       : Input → Bool
  sound      : ∀ x, gate x = true → Safe x
  complete   : ∀ x, Safe x → gate x = true
  posWitness : Input
  negWitness : Input
  nonVacuous : gate posWitness = true
  tight      : gate negWitness = false

theorem MetaGateSpec.rejects_unsafe {Input : Type} {Safe : Input → Prop}
    (M : MetaGateSpec Input Safe) (x : Input) (h_bad : ¬ Safe x) :
    M.gate x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => h_bad (M.sound x h_ok))

/-- Layer-I `ScopedAuthority` meta-specification: admitted operations respect key/token scope. -/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Prop
  sound      : ∀ x, admit x = true → scopeValid x

/-- Layer-I `ConservedResource` meta-specification: admitted frames respect byte & slot budgets. -/
structure ConservedResource (Input : Type) where
  admit        : Input → Bool
  withinBudget : Input → Prop
  conserved    : ∀ x, admit x = true → withinBudget x

/-- Total bounded wire-frame parser specification (`0` panics, bounded output). -/
structure TotalSliceParserSpec (Out : Type) where
  maxCap     : Nat
  parse      : ByteArray → Option Out
  byteLen    : Out → Nat
  bounded    : ∀ raw out, parse raw = some out → byteLen out ≤ maxCap
  posRaw     : ByteArray
  negRaw     : ByteArray
  nonVacuous : (parse posRaw).isSome = true
  tight      : (parse negRaw).isNone = true

private theorem u8_eq_of_toNat (a : UInt8) (n : Nat) (hn : n < 256) (h : a.toNat = n) :
    a = UInt8.ofNat n := by
  apply UInt8.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt8.ofNat n).toBitVec.toNat = n := by
    change n % 256 = n
    omega
  change a.toNat = _
  omega

private theorem bit_gate_eq_zero {c : Bool} (hf : ((if c then (1 : UInt8) else 0) == 1) = false) :
    (if c then (1 : UInt8) else 0) = 0 := by
  cases c <;> simp_all

/-! ### 1. SSH Agent Frame & FIDO SK Sign Gate (`fido-agent-proxy`) -/

/-- Draft-miller-ssh-agent §4.5 message classification (`13 = SSH_AGENTC_SIGN_REQUEST`). -/
inductive SshAgentAction where
  | signRequest
  | nonSignMessage (code : Nat)
  deriving Repr, DecidableEq

def SshAgentAction.classify (msgType : Nat) : SshAgentAction :=
  if msgType = 13 then .signRequest else .nonSignMessage msgType

def maxSshAgentPayloadBytes : Nat := 256 * 1024

structure SshSignCheck where
  frameLen     : UInt32
  msgType      : UInt8
  isSkKey      : UInt8
  fidoApproved : UInt8
  hasUpstream  : UInt8
  deriving Repr, DecidableEq

/-- Independent SSH agent FIDO policy domain model:
    payload size lies in `[1, 256 KiB]`, an upstream SSH agent socket is present,
    and whenever `SshAgentAction.classify` is `.signRequest` on an `sk-ssh-*` key (`isSkKey = 1`),
    explicit FIDO Touch approval (`fidoApproved = 1`) is present. -/
def SshSignDomainSafe (c : SshSignCheck) : Prop :=
  1 ≤ c.frameLen.toNat ∧
  c.frameLen.toNat ≤ maxSshAgentPayloadBytes ∧
  c.hasUpstream.toNat = 1 ∧
  (SshAgentAction.classify c.msgType.toNat = .signRequest →
    c.isSkKey.toNat = 1 →
    c.fidoApproved.toNat = 1)

@[inline, export orb_bin_verify_ssh_sign_forward]
def verifySshSignForward
    (frameLen : UInt32) (msgType isSkKey fidoApproved hasUpstream : UInt8) : UInt8 :=
  if 1 ≤ frameLen && frameLen ≤ 262144 &&
     hasUpstream == 1 &&
     (!(msgType == 13 && isSkKey == 1) || fidoApproved == 1) then 1 else 0

def sshSignMetaGate : MetaGateSpec SshSignCheck SshSignDomainSafe where
  gate c := verifySshSignForward c.frameLen c.msgType c.isSkKey c.fidoApproved c.hasUpstream == 1
  sound c h := by
    rcases c with ⟨fL, mT, isSk, fido, up⟩
    change (verifySshSignForward fL mT isSk fido up == 1) = true at h
    dsimp [SshSignDomainSafe]
    unfold verifySshSignForward at h
    have hc :
        (1 ≤ fL && fL ≤ 262144 &&
         up == 1 &&
         (!(mT == 13 && isSk == 1) || fido == 1)) = true := by
      cases hb :
          (1 ≤ fL && fL ≤ 262144 &&
           up == 1 &&
           (!(mT == 13 && isSk == 1) || fido == 1))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true',
      decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨hf1, hf2⟩, hup⟩, hpol⟩
    refine ⟨UInt32.le_iff_toNat_le.mp hf1, UInt32.le_iff_toNat_le.mp hf2, by subst hup; rfl, ?_⟩
    intro hAct hSk
    have hm13 : mT.toNat = 13 := by
      unfold SshAgentAction.classify at hAct
      split at hAct
      · assumption
      · contradiction
    have hmEq : mT = 13 := u8_eq_of_toNat mT 13 (by omega) hm13
    have hSkEq : isSk = 1 := u8_eq_of_toNat isSk 1 (by omega) hSk
    rcases hpol with hNot | hFido
    · simp [hmEq, hSkEq] at hNot
    · subst hFido; rfl
  complete c h := by
    rcases c with ⟨fL, mT, isSk, fido, up⟩
    change (verifySshSignForward fL mT isSk fido up == 1) = true
    dsimp [SshSignDomainSafe] at h
    rcases h with ⟨hf1, hf2, hup, hpol⟩
    unfold verifySshSignForward
    have hfGe : 1 ≤ fL := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ fL.toNat; omega
    have hfLe : fL ≤ 262144 := by
      apply UInt32.le_iff_toNat_le.mpr; change fL.toNat ≤ 262144
      unfold maxSshAgentPayloadBytes at hf2; omega
    have hupEq : (up == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat up 1 (by omega) hup
    cases hsk : (mT == 13 && isSk == 1)
    · simp [hfGe, hfLe, hupEq]
    · simp only [Bool.and_eq_true, beq_iff_eq] at hsk
      rcases hsk with ⟨hmEq, hSkEq⟩
      have hAct : SshAgentAction.classify mT.toNat = .signRequest := by
        subst hmEq; rfl
      have hFidoN : fido.toNat = 1 := hpol hAct (by subst hSkEq; rfl)
      have hFidoEq : (fido == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat fido 1 (by omega) hFidoN
      simp [hfGe, hfLe, hupEq, hFidoEq]
  posWitness := { frameLen := 128, msgType := 13, isSkKey := 1, fidoApproved := 1, hasUpstream := 1 }
  negWitness := { frameLen := 128, msgType := 13, isSkKey := 1, fidoApproved := 0, hasUpstream := 1 }
  nonVacuous := by decide
  tight := by decide

def sshSignScopedAuthority : ScopedAuthority SshSignCheck where
  admit := sshSignMetaGate.gate
  scopeValid := SshSignDomainSafe
  sound := sshSignMetaGate.sound

theorem ssh_sign_rejects_unapproved_sk (frameLen : UInt32) (hasUpstream : UInt8) :
    verifySshSignForward frameLen 13 1 0 hasUpstream = 0 := by
  have hbad : ¬ SshSignDomainSafe ⟨frameLen, 13, 1, 0, hasUpstream⟩ := by
    rintro ⟨_, _, _, hpol⟩
    have hf := hpol rfl rfl
    contradiction
  have hf := sshSignMetaGate.rejects_unsafe ⟨frameLen, 13, 1, 0, hasUpstream⟩ hbad
  unfold sshSignMetaGate at hf; dsimp at hf
  unfold verifySshSignForward at hf ⊢
  exact bit_gate_eq_zero hf

/-- Parse a 4-byte big-endian SSH agent frame header + payload (`1 ≤ len ≤ 262144`). -/
def parseSshAgentFrame (raw : ByteArray) : Option ByteArray :=
  if raw.size < 5 then none
  else
    let b0 := (raw.get! 0).toUInt32
    let b1 := (raw.get! 1).toUInt32
    let b2 := (raw.get! 2).toUInt32
    let b3 := (raw.get! 3).toUInt32
    let frameLen := ((b0 <<< 24) ||| (b1 <<< 16) ||| (b2 <<< 8) ||| b3).toNat
    if 1 ≤ frameLen && frameLen ≤ 262144 && 4 + frameLen ≤ raw.size then
      let sub := raw.extract 4 (4 + frameLen)
      if sub.size ≤ 262144 then some sub else none
    else
      none

def sshAgentFrameParserSpec : TotalSliceParserSpec ByteArray where
  maxCap := 262144
  parse := parseSshAgentFrame
  byteLen := ByteArray.size
  bounded raw out h := by
    unfold parseSshAgentFrame at h
    dsimp only at h
    split at h
    · contradiction
    · split at h
      · split at h
        · rename_i hle
          injection h with heq
          subst heq
          exact hle
        · contradiction
      · contradiction
  posRaw := ByteArray.mk #[0, 0, 0, 1, 11]
  negRaw := ByteArray.mk #[0, 4, 0, 1, 11]
  nonVacuous := by decide
  tight := by decide

/-! ### 2. Scoped MCP Credential Persistence & Secret Delivery Gate (`sandboxed-mcp`) -/

inductive TokenNamespace where
  | ownerOrForeign
  | scopedMcp1
  deriving Repr, DecidableEq

def TokenNamespace.ofFlag (b : Nat) : TokenNamespace :=
  if b = 1 then .scopedMcp1 else .ownerOrForeign

structure McpSecretPersistenceCheck where
  hasMcp1Prefix  : UInt8
  dirIsPrivate   : UInt8
  dirNotSymlink  : UInt8
  fileModeIs0600 : UInt8
  safeEnvName    : UInt8
  deriving Repr, DecidableEq

/-- Independent filesystem & credential-scope domain specification:
    only `.scopedMcp1` tokens may be persisted, inside a private (`0700`) non-symlink
    directory, into an owner-only (`0600`) file with a validated POSIX environment identifier. -/
def McpSecretPersistenceDomainSafe (c : McpSecretPersistenceCheck) : Prop :=
  TokenNamespace.ofFlag c.hasMcp1Prefix.toNat = .scopedMcp1 ∧
  c.dirIsPrivate.toNat = 1 ∧
  c.dirNotSymlink.toNat = 1 ∧
  c.fileModeIs0600.toNat = 1 ∧
  c.safeEnvName.toNat = 1

@[inline, export orb_bin_verify_mcp_secret_persistence]
def verifyMcpSecretPersistence
    (hasMcp1Prefix dirIsPrivate dirNotSymlink fileModeIs0600 safeEnvName : UInt8) : UInt8 :=
  if hasMcp1Prefix == 1 && dirIsPrivate == 1 && dirNotSymlink == 1 &&
     fileModeIs0600 == 1 && safeEnvName == 1 then 1 else 0

def mcpSecretPersistenceMetaGate :
    MetaGateSpec McpSecretPersistenceCheck McpSecretPersistenceDomainSafe where
  gate c := verifyMcpSecretPersistence c.hasMcp1Prefix c.dirIsPrivate c.dirNotSymlink
              c.fileModeIs0600 c.safeEnvName == 1
  sound c h := by
    rcases c with ⟨p, dp, ns, fm, se⟩
    change (verifyMcpSecretPersistence p dp ns fm se == 1) = true at h
    dsimp [McpSecretPersistenceDomainSafe]
    unfold verifyMcpSecretPersistence at h
    cases hc : (p == 1 && dp == 1 && ns == 1 && fm == 1 && se == 1)
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨⟨hp, hdp⟩, hns⟩, hfm⟩, hse⟩
      subst hp; subst hdp
      subst hns; subst hfm
      subst hse
      exact ⟨rfl, rfl, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨p, dp, ns, fm, se⟩
    change (verifyMcpSecretPersistence p dp ns fm se == 1) = true
    dsimp [McpSecretPersistenceDomainSafe] at h
    rcases h with ⟨hp, hdp, hns, hfm, hse⟩
    have hpN : p.toNat = 1 := by
      unfold TokenNamespace.ofFlag at hp
      split at hp
      · assumption
      · contradiction
    have hpB : (p == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat p 1 (by omega) hpN
    have hdpB : (dp == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat dp 1 (by omega) hdp
    have hnsB : (ns == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ns 1 (by omega) hns
    have hfmB : (fm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat fm 1 (by omega) hfm
    have hseB : (se == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat se 1 (by omega) hse
    unfold verifyMcpSecretPersistence
    simp [hpB, hdpB, hnsB, hfmB, hseB]
  posWitness := { hasMcp1Prefix := 1, dirIsPrivate := 1, dirNotSymlink := 1, fileModeIs0600 := 1, safeEnvName := 1 }
  negWitness := { hasMcp1Prefix := 0, dirIsPrivate := 1, dirNotSymlink := 1, fileModeIs0600 := 1, safeEnvName := 1 }
  nonVacuous := by decide
  tight := by decide

theorem mcp_secret_rejects_owner_token (dp ns fm se : UInt8) :
    verifyMcpSecretPersistence 0 dp ns fm se = 0 := by
  have hbad : ¬ McpSecretPersistenceDomainSafe ⟨0, dp, ns, fm, se⟩ := by
    rintro ⟨hp, _, _, _, _⟩
    contradiction
  have hf := mcpSecretPersistenceMetaGate.rejects_unsafe ⟨0, dp, ns, fm, se⟩ hbad
  unfold mcpSecretPersistenceMetaGate at hf; dsimp at hf
  unfold verifyMcpSecretPersistence at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 3. Bounded Stdio JSON-RPC 2.0 Frame Gate (`sandboxed-mcp` & companion MCP servers) -/

def maxStdioJsonRpcBytes : Nat := 1024 * 1024
def maxConcurrentJsonRpcSlots : Nat := 64

structure StdioJsonRpcFrameCheck where
  lineBytes    : UInt64
  nonEmptyTrim : UInt8
  inFlight     : UInt32
  maxInFlight  : UInt32
  deriving Repr, DecidableEq

/-- Independent `ConservedResource` domain specification over `Nat` byte & concurrency budgets:
    frame size is in `[1, 1 MiB]`, trimmed JSON payload is non-empty, configured concurrency cap
    is in `[1, 64]`, and admitting one more request (`inFlight + 1`) stays within `maxInFlight`. -/
def StdioJsonRpcDomainSafe (c : StdioJsonRpcFrameCheck) : Prop :=
  1 ≤ c.lineBytes.toNat ∧
  c.lineBytes.toNat ≤ maxStdioJsonRpcBytes ∧
  c.nonEmptyTrim.toNat = 1 ∧
  1 ≤ c.maxInFlight.toNat ∧
  c.maxInFlight.toNat ≤ maxConcurrentJsonRpcSlots ∧
  c.inFlight.toNat + 1 ≤ c.maxInFlight.toNat

@[inline, export orb_bin_verify_stdio_jsonrpc_frame]
def verifyStdioJsonRpcFrame
    (lineBytes : UInt64) (nonEmptyTrim : UInt8) (inFlight maxInFlight : UInt32) : UInt8 :=
  if 1 ≤ lineBytes && lineBytes ≤ 1048576 &&
     nonEmptyTrim == 1 &&
     1 ≤ maxInFlight && maxInFlight ≤ 64 &&
     inFlight < maxInFlight then 1 else 0

def stdioJsonRpcFrameMetaGate :
    MetaGateSpec StdioJsonRpcFrameCheck StdioJsonRpcDomainSafe where
  gate c := verifyStdioJsonRpcFrame c.lineBytes c.nonEmptyTrim c.inFlight c.maxInFlight == 1
  sound c h := by
    rcases c with ⟨lB, neT, inF, maxF⟩
    change (verifyStdioJsonRpcFrame lB neT inF maxF == 1) = true at h
    dsimp [StdioJsonRpcDomainSafe]
    unfold verifyStdioJsonRpcFrame at h
    cases hc :
        (1 ≤ lB && lB ≤ 1048576 &&
         neT == 1 &&
         1 ≤ maxF && maxF ≤ 64 &&
         inF < maxF)
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨⟨⟨hl1, hl2⟩, hne⟩, hm1⟩, hm2⟩, hlt⟩
      have hltN : inF.toNat < maxF.toNat := UInt32.lt_iff_toNat_lt.mp hlt
      refine ⟨UInt64.le_iff_toNat_le.mp hl1, UInt64.le_iff_toNat_le.mp hl2,
        by subst hne; rfl, UInt32.le_iff_toNat_le.mp hm1, UInt32.le_iff_toNat_le.mp hm2, ?_⟩
      omega
  complete c h := by
    rcases c with ⟨lB, neT, inF, maxF⟩
    change (verifyStdioJsonRpcFrame lB neT inF maxF == 1) = true
    dsimp [StdioJsonRpcDomainSafe] at h
    rcases h with ⟨hl1, hl2, hne, hm1, hm2, hslot⟩
    unfold verifyStdioJsonRpcFrame
    have hlGe : 1 ≤ lB := by apply UInt64.le_iff_toNat_le.mpr; change 1 ≤ lB.toNat; omega
    have hlLe : lB ≤ 1048576 := by
      apply UInt64.le_iff_toNat_le.mpr; change lB.toNat ≤ 1048576
      unfold maxStdioJsonRpcBytes at hl2; omega
    have hneEq : (neT == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat neT 1 (by omega) hne
    have hmGe : 1 ≤ maxF := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ maxF.toNat; omega
    have hmLe : maxF ≤ 64 := by
      apply UInt32.le_iff_toNat_le.mpr; change maxF.toNat ≤ 64
      unfold maxConcurrentJsonRpcSlots at hm2; omega
    have hLt : inF < maxF := by
      apply UInt32.lt_iff_toNat_lt.mpr; omega
    simp [hlGe, hlLe, hneEq, hmGe, hmLe, hLt]
  posWitness := { lineBytes := 256, nonEmptyTrim := 1, inFlight := 0, maxInFlight := 8 }
  negWitness := { lineBytes := 1048577, nonEmptyTrim := 1, inFlight := 0, maxInFlight := 8 }
  nonVacuous := by decide
  tight := by decide

def stdioJsonRpcConserved : ConservedResource StdioJsonRpcFrameCheck where
  admit := stdioJsonRpcFrameMetaGate.gate
  withinBudget c := c.lineBytes.toNat ≤ maxStdioJsonRpcBytes ∧ c.inFlight.toNat + 1 ≤ c.maxInFlight.toNat
  conserved c h := by
    rcases stdioJsonRpcFrameMetaGate.sound c h with ⟨_, hl2, _, _, _, hslot⟩
    exact ⟨hl2, hslot⟩

theorem stdio_jsonrpc_rejects_saturated_pool (lB : UInt64) (neT : UInt8) (cap : UInt32) :
    verifyStdioJsonRpcFrame lB neT cap cap = 0 := by
  have hbad : ¬ StdioJsonRpcDomainSafe ⟨lB, neT, cap, cap⟩ := by
    rintro ⟨_, _, _, _, _, hslot⟩
    change cap.toNat + 1 ≤ cap.toNat at hslot
    omega
  have hf := stdioJsonRpcFrameMetaGate.rejects_unsafe ⟨lB, neT, cap, cap⟩ hbad
  unfold stdioJsonRpcFrameMetaGate at hf; dsimp at hf
  unfold verifyStdioJsonRpcFrame at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 4. Control MCP Receipt Settlement vs Action Outcome (`SM-22`) -/

/-- Durable action outcome, distinct from whether `wait_actions` may wake. -/
inductive McpActionOutcomeKind where
  | pending
  | accepted
  | rejected
  | uncertainReconciliationRequired
  deriving Repr, DecidableEq

def McpActionOutcomeKind.toWire : McpActionOutcomeKind → String
  | .pending => "pending"
  | .accepted => "accepted"
  | .rejected => "rejected"
  | .uncertainReconciliationRequired => "reconciliation_required"

structure McpActionOutcomeCheck where
  receiptStatus    : UInt8
  acceptedTag      : UInt8
  stateTag         : UInt8
  transportDropped : UInt8
  hasResult        : UInt8
  deriving Repr, DecidableEq

/-- Receipt status independent of the packed gate: queued and running/dispatching are not yet settled. -/
def receiptIsOpen (status : Nat) : Bool :=
  status == 0 || status == 1

/-- `accepted:"unknown"`, `state:"reconciliation_required"`, or a dropped mutation transport. -/
def receiptNeedsReconcile (status accepted state drop : Nat) : Bool :=
  drop == 1 || accepted == 3 || state == 4 || status == 4

/-- Independent durable outcome. Success is only an explicit completed result without rejection or
    reconciliation; reconciliation is never success and is distinct from a rejected result. -/
def classifyMcpActionOutcome (c : McpActionOutcomeCheck) : McpActionOutcomeKind :=
  if receiptNeedsReconcile c.receiptStatus.toNat c.acceptedTag.toNat c.stateTag.toNat c.transportDropped.toNat then
    .uncertainReconciliationRequired
  else if receiptIsOpen c.receiptStatus.toNat then
    .pending
  else if c.receiptStatus.toNat == 2 && c.hasResult.toNat == 1 &&
          decide (c.acceptedTag.toNat ≤ 1) && c.stateTag.toNat != 3 then
    .accepted
  else
    .rejected

/-- A canonical observation whose durable outcome is `Accepted`: the wait may wake, a fresh retry
    is forbidden, and reconciliation evidence is absent. -/
def McpActionOutcomeDomainSafe (c : McpActionOutcomeCheck) : Prop :=
  c.receiptStatus.toNat ≤ 5 ∧ c.acceptedTag.toNat ≤ 3 ∧ c.stateTag.toNat ≤ 4 ∧
  c.transportDropped.toNat ≤ 1 ∧ c.hasResult.toNat ≤ 1 ∧
  classifyMcpActionOutcome c = .accepted

@[inline, export orb_bin_verify_mcp_action_outcome]
def verifyMcpActionOutcome
    (receiptStatus acceptedTag stateTag transportDropped hasResult : UInt8) : UInt32 :=
  let canonical : Bool :=
    receiptStatus ≤ 5 && acceptedTag ≤ 3 && stateTag ≤ 4 &&
    transportDropped ≤ 1 && hasResult ≤ 1
  let reconciliation : Bool :=
    transportDropped == 1 || acceptedTag == 3 || stateTag == 4 || receiptStatus == 4
  let pending : Bool := receiptStatus == 0 || receiptStatus == 1
  let acceptedOk : Bool :=
    receiptStatus == 2 && hasResult == 1 && acceptedTag ≤ 1 && stateTag != 3
  let outcome : UInt32 :=
    if !canonical then 2
    else if reconciliation then 3
    else if pending then 0
    else if acceptedOk then 1
    else 2
  let settled : UInt32 :=
    if canonical && (reconciliation || !pending) then 256 else 0
  let success : UInt32 := if outcome == 1 then 65536 else 0
  let freshRetry : UInt32 :=
    if canonical && outcome == 2 && transportDropped == 0 && acceptedTag != 3 then 16777216 else 0
  outcome ||| settled ||| success ||| freshRetry

private theorem u8_le_of_toNat_le (a b : UInt8) (h : a.toNat ≤ b.toNat) : a ≤ b :=
  UInt8.le_iff_toNat_le.mpr h

private def mcpWord (rs acc st drop res : UInt8) : UInt32 :=
  verifyMcpActionOutcome rs acc st drop res

private theorem mcpWord_noncanonical (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = false) :
    mcpWord rs acc st drop res = 2 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc]

private theorem mcpWord_reconcile (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = true)
    (hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) = true) :
    mcpWord rs acc st drop res = 259 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc, hrec]; decide

private theorem mcpWord_pending (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = true)
    (hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) = false)
    (hpend : (rs == 0 || rs == 1) = true) :
    mcpWord rs acc st drop res = 0 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc, hrec, hpend]

private theorem mcpWord_rejected (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = true)
    (hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) = false)
    (hpend : (rs == 0 || rs == 1) = false)
    (hok : (rs == 2 && res == 1 && decide (acc ≤ 1) && st != 3) = false)
    (hd0 : (drop == 0 && acc != 3) = true) :
    mcpWord rs acc st drop res = 16777474 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc, hrec, hpend, hok, hd0]; decide

private theorem mcpWord_rejected_no_retry (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = true)
    (hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) = false)
    (hpend : (rs == 0 || rs == 1) = false)
    (hok : (rs == 2 && res == 1 && decide (acc ≤ 1) && st != 3) = false)
    (hd0 : (drop == 0 && acc != 3) = false) :
    mcpWord rs acc st drop res = 258 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc, hrec, hpend, hok, hd0]; decide

private theorem mcpWord_accepted (rs acc st drop res : UInt8)
    (hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) &&
      decide (drop ≤ 1) && decide (res ≤ 1)) = true)
    (hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) = false)
    (hpend : (rs == 0 || rs == 1) = false)
    (hok : (rs == 2 && res == 1 && decide (acc ≤ 1) && st != 3) = true) :
    mcpWord rs acc st drop res = 65793 := by
  unfold mcpWord verifyMcpActionOutcome
  simp [hc, hrec, hpend, hok]; decide

def mcpActionOutcomeMetaGate : MetaGateSpec McpActionOutcomeCheck McpActionOutcomeDomainSafe where
  gate c :=
    let w := mcpWord c.receiptStatus c.acceptedTag c.stateTag c.transportDropped c.hasResult
    (w &&& 255) == 1 && ((w >>> 8) &&& 1) == 1 && ((w >>> 16) &&& 1) == 1 && ((w >>> 24) &&& 1) == 0
  sound c h := by
    rcases c with ⟨rs, acc, st, drop, res⟩
    change ((mcpWord rs acc st drop res &&& 255) == 1 &&
      ((mcpWord rs acc st drop res >>> 8) &&& 1) == 1 &&
      ((mcpWord rs acc st drop res >>> 16) &&& 1) == 1 &&
      ((mcpWord rs acc st drop res >>> 24) &&& 1) == 0) = true at h
    dsimp [McpActionOutcomeDomainSafe]
    cases hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) && decide (drop ≤ 1) && decide (res ≤ 1))
    · rw [mcpWord_noncanonical rs acc st drop res hc] at h
      exact absurd h (by decide)
    · cases hrec : (drop == 1 || acc == 3 || st == 4 || rs == 4) with
      | true =>
        rw [mcpWord_reconcile rs acc st drop res hc hrec] at h
        exact absurd h (by decide)
      | false =>
        cases hpend : (rs == 0 || rs == 1) with
        | true =>
          rw [mcpWord_pending rs acc st drop res hc hrec hpend] at h
          exact absurd h (by decide)
        | false =>
          cases hok : (rs == 2 && res == 1 && decide (acc ≤ 1) && st != 3) with
          | false =>
            cases hd0 : (drop == 0 && acc != 3) with
            | false =>
              rw [mcpWord_rejected_no_retry rs acc st drop res hc hrec hpend hok hd0] at h
              exact absurd h (by decide)
            | true =>
              rw [mcpWord_rejected rs acc st drop res hc hrec hpend hok hd0] at h
              exact absurd h (by decide)
          | true =>
            rw [mcpWord_accepted rs acc st drop res hc hrec hpend hok] at h
            simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
            rcases hc with ⟨⟨⟨⟨hrs, hacc⟩, hst⟩, hdrop⟩, hres⟩
            refine ⟨UInt8.le_iff_toNat_le.mp hrs, UInt8.le_iff_toNat_le.mp hacc,
              UInt8.le_iff_toNat_le.mp hst, UInt8.le_iff_toNat_le.mp hdrop,
              UInt8.le_iff_toNat_le.mp hres, ?_⟩
            simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at hrec hpend
            simp only [Bool.and_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hok
            rcases hrec with ⟨⟨⟨hdN, haN⟩, hsN⟩, _⟩
            rcases hpend with ⟨_, _⟩
            rcases hok with ⟨⟨⟨hr2, hres1⟩, hacc1⟩, hst3⟩
            unfold classifyMcpActionOutcome receiptNeedsReconcile receiptIsOpen
            subst hr2; subst hres1
            have hdNat : drop.toNat ≠ 1 := fun e => hdN (u8_eq_of_toNat drop 1 (by decide) e)
            have haNat : acc.toNat ≠ 3 := fun e => haN (u8_eq_of_toNat acc 3 (by decide) e)
            have hsNat : st.toNat ≠ 4 := fun e => hsN (u8_eq_of_toNat st 4 (by decide) e)
            have hst3Nat : st.toNat ≠ 3 := fun e => hst3 (u8_eq_of_toNat st 3 (by decide) e)
            have haccNat : acc.toNat ≤ 1 := UInt8.le_iff_toNat_le.mp hacc1
            simp [beq_iff_eq, bne_iff_ne, hdNat, haNat, hsNat, hst3Nat, haccNat]
  complete c h := by
    rcases c with ⟨rs, acc, st, drop, res⟩
    dsimp [McpActionOutcomeDomainSafe] at h
    rcases h with ⟨hrs, hacc, hst, hdrop, hres, hkind⟩
    change ((mcpWord rs acc st drop res &&& 255) == 1 &&
      ((mcpWord rs acc st drop res >>> 8) &&& 1) == 1 &&
      ((mcpWord rs acc st drop res >>> 16) &&& 1) == 1 &&
      ((mcpWord rs acc st drop res >>> 24) &&& 1) == 0) = true
    have hrsB : rs ≤ 5 := u8_le_of_toNat_le rs 5 (by change rs.toNat ≤ 5; omega)
    have haccB : acc ≤ 3 := u8_le_of_toNat_le acc 3 (by change acc.toNat ≤ 3; omega)
    have hstB : st ≤ 4 := u8_le_of_toNat_le st 4 (by change st.toNat ≤ 4; omega)
    have hdropB : drop ≤ 1 := u8_le_of_toNat_le drop 1 (by change drop.toNat ≤ 1; omega)
    have hresB : res ≤ 1 := u8_le_of_toNat_le res 1 (by change res.toNat ≤ 1; omega)
    have hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) && decide (drop ≤ 1) && decide (res ≤ 1)) = true := by
      simp [hrsB, haccB, hstB, hdropB, hresB]
    unfold classifyMcpActionOutcome receiptNeedsReconcile receiptIsOpen at hkind
    cases hrecN : (drop.toNat == 1 || acc.toNat == 3 || st.toNat == 4 || rs.toNat == 4)
    · rw [hrecN] at hkind; dsimp at hkind
      cases hpendN : (rs.toNat == 0 || rs.toNat == 1)
      · rw [hpendN] at hkind; dsimp at hkind
        cases hokN : (rs.toNat == 2 && res.toNat == 1 && decide (acc.toNat ≤ 1) && st.toNat != 3)
        · rw [hokN] at hkind; contradiction
        · simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at hrecN hpendN
          simp only [Bool.and_eq_true, beq_iff_eq, bne_iff_ne, decide_eq_true_eq] at hokN
          rcases hrecN with ⟨⟨⟨hdN, haN⟩, hsN⟩, hr4⟩
          rcases hpendN with ⟨hr0, hr1⟩
          rcases hokN with ⟨⟨⟨hr2, hres1⟩, hacc1⟩, hst3⟩
          have hrecB : (drop == 1 || acc == 3 || st == 4 || rs == 4) = false := by
            simp [beq_eq_false_iff_ne, ne_eq]
            exact ⟨⟨⟨fun e => hdN (congrArg UInt8.toNat e), fun e => haN (congrArg UInt8.toNat e)⟩,
              fun e => hsN (congrArg UInt8.toNat e)⟩, fun e => hr4 (congrArg UInt8.toNat e)⟩
          have hpendB : (rs == 0 || rs == 1) = false := by
            simp [beq_eq_false_iff_ne, ne_eq]
            exact ⟨fun e => hr0 (congrArg UInt8.toNat e), fun e => hr1 (congrArg UInt8.toNat e)⟩
          have hacc1B : acc ≤ 1 := u8_le_of_toNat_le acc 1 (by change acc.toNat ≤ 1; omega)
          have hokB : (rs == 2 && res == 1 && decide (acc ≤ 1) && st != 3) = true := by
            have hr2E : rs = 2 := u8_eq_of_toNat rs 2 (by decide) hr2
            have hres1E : res = 1 := u8_eq_of_toNat res 1 (by decide) hres1
            have hst3B : (st != 3) = true := bne_iff_ne.mpr (fun e => hst3 (congrArg UInt8.toNat e))
            simp [hr2E, hres1E, hacc1B, hst3B]
          rw [mcpWord_accepted rs acc st drop res hc hrecB hpendB hokB]
          decide
      · rw [hpendN] at hkind; contradiction
    · rw [hrecN] at hkind; contradiction
  posWitness := { receiptStatus := 2, acceptedTag := 1, stateTag := 2, transportDropped := 0, hasResult := 1 }
  negWitness := { receiptStatus := 2, acceptedTag := 3, stateTag := 4, transportDropped := 0, hasResult := 1 }
  nonVacuous := by decide
  tight := by decide

theorem mcp_outcome_reconciliation_not_accepted
    (rs acc st drop res : UInt8)
    (h : drop == 1 || acc == 3 || st == 4 || rs == 4) :
    (verifyMcpActionOutcome rs acc st drop res &&& 255) ≠ 1 := by
  change (mcpWord rs acc st drop res &&& 255) ≠ 1
  cases hc : (decide (rs ≤ 5) && decide (acc ≤ 3) && decide (st ≤ 4) && decide (drop ≤ 1) && decide (res ≤ 1))
  · rw [mcpWord_noncanonical rs acc st drop res hc]; decide
  · rw [mcpWord_reconcile rs acc st drop res hc h]; decide

/-! ### 5. Generation-Fenced External Stdio MCP Lifecycle (`SM-22`) -/

/-- External MCP child connection state. -/
inductive McpConnState where
  | disconnected
  | connecting
  | connected
  | errored
  deriving Repr, DecidableEq

def McpConnState.toNat : McpConnState → Nat
  | .disconnected => 0
  | .connecting => 1
  | .connected => 2
  | .errored => 3

structure McpStdioLifecycleCheck where
  connState   : UInt8
  activeGen   : UInt64
  eventGen    : UInt64
  toolsListOk : UInt8
  childExited : UInt8
  deriving Repr, DecidableEq

/-- Generation fence: an event older than the active generation, or from another generation, is ignored. -/
def stdioEventIgnored (active event : Nat) : Bool :=
  decide (event < active) || event != active

/-- Next connection after one lifecycle event. Stale generations keep the current state. A matching
    child exit leaves `Connecting`/`Connected`. A failed tools/list while `Connecting` becomes `Error`. -/
def stepMcpStdio (c : McpStdioLifecycleCheck) : McpConnState :=
  if stdioEventIgnored c.activeGen.toNat c.eventGen.toNat then
    match c.connState.toNat with
    | 1 => .connecting
    | 2 => .connected
    | 3 => .errored
    | _ => .disconnected
  else if c.childExited.toNat == 1 && (c.connState.toNat == 1 || c.connState.toNat == 2) then
    .disconnected
  else if c.connState.toNat == 1 && c.toolsListOk.toNat == 0 && c.childExited.toNat == 0 then
    .errored
  else
    match c.connState.toNat with
    | 1 => .connecting
    | 2 => .connected
    | 3 => .errored
    | _ => .disconnected

/-- The child must be reaped exactly when the active generation exits or its refresh handshake fails. -/
def stdioMustReap (c : McpStdioLifecycleCheck) : Bool :=
  !stdioEventIgnored c.activeGen.toNat c.eventGen.toNat &&
    ((c.childExited.toNat == 1 && (c.connState.toNat == 1 || c.connState.toNat == 2)) ||
      (c.connState.toNat == 1 && c.toolsListOk.toNat == 0 && c.childExited.toNat == 0))

/-- Canonical observations whose next state is not `Connected`: either the generation is stale, or
    the active generation has exited or failed its tools/list handshake and must be reaped. -/
def McpStdioLifecycleDomainSafe (c : McpStdioLifecycleCheck) : Prop :=
  c.connState.toNat ≤ 3 ∧ c.toolsListOk.toNat ≤ 1 ∧ c.childExited.toNat ≤ 1 ∧
  (stepMcpStdio c).toNat ≠ McpConnState.connected.toNat ∧
  (stdioMustReap c = true ∨ stdioEventIgnored c.activeGen.toNat c.eventGen.toNat = true)

@[inline, export orb_bin_verify_mcp_stdio_step]
def verifyMcpStdioLifecycleStep
    (connState : UInt8) (activeGen eventGen : UInt64) (toolsListOk childExited : UInt8) : UInt32 :=
  let canonical : Bool := connState ≤ 3 && toolsListOk ≤ 1 && childExited ≤ 1
  let current : Bool := eventGen == activeGen
  let stale : Bool := eventGen < activeGen
  let exitNow : Bool := current && childExited == 1 && (connState == 1 || connState == 2)
  let refreshFail : Bool := current && connState == 1 && toolsListOk == 0 && childExited == 0
  let nextState : UInt32 :=
    if !canonical then 3
    else if stale || !current then connState.toUInt32
    else if exitNow then 0
    else if refreshFail then 3
    else connState.toUInt32
  let reap : UInt32 := if canonical && (exitNow || refreshFail) then 256 else 0
  let ignore : UInt32 := if canonical && (stale || !current) then 65536 else 0
  nextState ||| reap ||| ignore

private def stdioWord (cs : UInt8) (ag eg : UInt64) (ok ex : UInt8) : UInt32 :=
  verifyMcpStdioLifecycleStep cs ag eg ok ex

private theorem stdioWord_noncanonical (cs : UInt8) (ag eg : UInt64) (ok ex : UInt8)
    (hc : (decide (cs ≤ 3) && decide (ok ≤ 1) && decide (ex ≤ 1)) = false) :
    stdioWord cs ag eg ok ex = 3 := by
  unfold stdioWord verifyMcpStdioLifecycleStep; simp [hc]

private def stdioOfNat : Nat → UInt8
  | 0 => 0 | 1 => 1 | 2 => 2 | 3 => 3 | _ => 0

private theorem stdio_ofNat_eq (cs : UInt8) (h : cs.toNat ≤ 3) : stdioOfNat cs.toNat = cs := by
  have hEq : cs = UInt8.ofNat cs.toNat := u8_eq_of_toNat cs cs.toNat cs.toNat_lt rfl
  cases hN : cs.toNat
  · rw [hN] at hEq; exact hEq.symm
  · rename_i n; cases n
    · rw [hN] at hEq; exact hEq.symm
    · rename_i n; cases n
      · rw [hN] at hEq; exact hEq.symm
      · rename_i n; cases n
        · rw [hN] at hEq; exact hEq.symm
        · omega

private theorem stdioWord_stale (cs : UInt8) (ag eg : UInt64) (ok ex : UInt8)
    (hcs : cs.toNat ≤ 3) (hok : ok.toNat ≤ 1) (hex : ex.toNat ≤ 1)
    (hstale : (eg == ag) = false) :
    stdioWord cs ag eg ok ex = cs.toUInt32 ||| 65536 := by
  have hc : (decide (cs ≤ 3) && decide (ok ≤ 1) && decide (ex ≤ 1)) = true := by
    simp [u8_le_of_toNat_le cs 3 (by change cs.toNat ≤ 3; exact hcs),
      u8_le_of_toNat_le ok 1 (by change ok.toNat ≤ 1; exact hok),
      u8_le_of_toNat_le ex 1 (by change ex.toNat ≤ 1; exact hex)]
  unfold stdioWord verifyMcpStdioLifecycleStep
  simp [hc, hstale]

private theorem stdioWord_current_table
    (cs : UInt8) (ag : UInt64) (ok ex : UInt8)
    (hcs : cs.toNat ≤ 3) (hok : ok.toNat ≤ 1) (hex : ex.toNat ≤ 1) :
    stdioWord cs ag ag ok ex =
      if ex == 1 && (cs == 1 || cs == 2) then 256
      else if cs == 1 && ok == 0 && ex == 0 then 259
      else cs.toUInt32 := by
  have hc : (decide (cs ≤ 3) && decide (ok ≤ 1) && decide (ex ≤ 1)) = true := by
    simp [u8_le_of_toNat_le cs 3 (by change cs.toNat ≤ 3; exact hcs),
      u8_le_of_toNat_le ok 1 (by change ok.toNat ≤ 1; exact hok),
      u8_le_of_toNat_le ex 1 (by change ex.toNat ≤ 1; exact hex)]
  have hlt : decide (ag < ag) = false := by
    simp [UInt64.lt_irrefl]
  unfold stdioWord verifyMcpStdioLifecycleStep
  simp only [hc, hlt, beq_self_eq_true, Bool.not_true, Bool.true_and, Bool.false_or]
  have hcsE := stdio_ofNat_eq cs hcs
  have hokE := stdio_ofNat_eq ok (by omega)
  have hexE := stdio_ofNat_eq ex (by omega)
  rcases (by omega : cs.toNat = 0 ∨ cs.toNat = 1 ∨ cs.toNat = 2 ∨ cs.toNat = 3) with h0 | h1 | h2 | h3 <;>
  rcases (by omega : ok.toNat = 0 ∨ ok.toNat = 1) with hk0 | hk1 <;>
  rcases (by omega : ex.toNat = 0 ∨ ex.toNat = 1) with hx0 | hx1
  all_goals
    (try rw [h0] at hcsE)
    (try rw [h1] at hcsE)
    (try rw [h2] at hcsE)
    (try rw [h3] at hcsE)
    (try rw [hk0] at hokE)
    (try rw [hk1] at hokE)
    (try rw [hx0] at hexE)
    (try rw [hx1] at hexE)
    subst hcsE hokE hexE
    decide

def mcpStdioLifecycleMetaGate : MetaGateSpec McpStdioLifecycleCheck McpStdioLifecycleDomainSafe where
  gate c :=
    let w := stdioWord c.connState c.activeGen c.eventGen c.toolsListOk c.childExited
    (w &&& 255) != 2 && (((w >>> 8) &&& 1) == 1 || ((w >>> 16) &&& 1) == 1)
  sound c h := by
    rcases c with ⟨cs, ag, eg, ok, ex⟩
    change ((stdioWord cs ag eg ok ex &&& 255) != 2 &&
      (((stdioWord cs ag eg ok ex >>> 8) &&& 1) == 1 ||
        ((stdioWord cs ag eg ok ex >>> 16) &&& 1) == 1)) = true at h
    dsimp [McpStdioLifecycleDomainSafe]
    cases hcanon : (decide (cs ≤ 3) && decide (ok ≤ 1) && decide (ex ≤ 1))
    · rw [stdioWord_noncanonical cs ag eg ok ex hcanon] at h
      exact absurd h (by decide)
    · simp only [Bool.and_eq_true, decide_eq_true_eq] at hcanon
      rcases hcanon with ⟨⟨hcsB, hokB⟩, hexB⟩
      have hcs : cs.toNat ≤ 3 := UInt8.le_iff_toNat_le.mp hcsB
      have hok : ok.toNat ≤ 1 := UInt8.le_iff_toNat_le.mp hokB
      have hex : ex.toNat ≤ 1 := UInt8.le_iff_toNat_le.mp hexB
      refine ⟨hcs, hok, hex, ?_⟩
      unfold stepMcpStdio stdioMustReap
      cases hcur : (eg == ag)
      · rw [stdioWord_stale cs ag eg ok ex hcs hok hex hcur] at h
        have hne : eg.toNat ≠ ag.toNat := fun e => beq_eq_false_iff_ne.mp hcur
          (UInt64.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq e))
        have hign : stdioEventIgnored ag.toNat eg.toNat = true := by
          unfold stdioEventIgnored
          exact Bool.or_eq_true_iff.mpr (Or.inr (bne_iff_ne.mpr hne))
        rw [hign]
        simp only [ite_true, or_true, and_true]
        have hcsE := stdio_ofNat_eq cs hcs
        rcases (by omega : cs.toNat = 0 ∨ cs.toNat = 1 ∨ cs.toNat = 2 ∨ cs.toNat = 3) with h0 | h1 | h2 | h3
        · rw [h0] at hcsE; subst hcsE; decide
        · rw [h1] at hcsE; subst hcsE; decide
        · rw [h2] at hcsE; subst hcsE; exact absurd h (by decide)
        · rw [h3] at hcsE; subst hcsE; decide
      · have heq : eg = ag := beq_iff_eq.mp hcur
        rw [heq, stdioWord_current_table cs ag ok ex hcs hok hex] at h
        rw [heq]
        have hign : stdioEventIgnored ag.toNat ag.toNat = false := by
          unfold stdioEventIgnored
          simp [Nat.lt_irrefl]
        rw [hign]
        simp only [Bool.not_false, Bool.true_and]
        have hcsE := stdio_ofNat_eq cs hcs
        have hokE := stdio_ofNat_eq ok (by omega)
        have hexE := stdio_ofNat_eq ex (by omega)
        revert h
        rcases (by omega : cs.toNat = 0 ∨ cs.toNat = 1 ∨ cs.toNat = 2 ∨ cs.toNat = 3) with h0 | h1 | h2 | h3 <;>
        rcases (by omega : ok.toNat = 0 ∨ ok.toNat = 1) with hk0 | hk1 <;>
        rcases (by omega : ex.toNat = 0 ∨ ex.toNat = 1) with hx0 | hx1
        all_goals
          (try rw [h0] at hcsE)
          (try rw [h1] at hcsE)
          (try rw [h2] at hcsE)
          (try rw [h3] at hcsE)
          (try rw [hk0] at hokE)
          (try rw [hk1] at hokE)
          (try rw [hx0] at hexE)
          (try rw [hx1] at hexE)
          subst hcsE hokE hexE
          decide
  complete c h := by
    rcases c with ⟨cs, ag, eg, ok, ex⟩
    dsimp [McpStdioLifecycleDomainSafe] at h
    rcases h with ⟨hcs, hok, hex, hrest⟩
    change ((stdioWord cs ag eg ok ex &&& 255) != 2 &&
      (((stdioWord cs ag eg ok ex >>> 8) &&& 1) == 1 ||
        ((stdioWord cs ag eg ok ex >>> 16) &&& 1) == 1)) = true
    unfold stepMcpStdio stdioMustReap at hrest
    cases hcur : (eg == ag)
    · rw [stdioWord_stale cs ag eg ok ex hcs hok hex hcur]
      have hne : eg.toNat ≠ ag.toNat := fun e => beq_eq_false_iff_ne.mp hcur
        (UInt64.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq e))
      have hign : stdioEventIgnored ag.toNat eg.toNat = true := by
        unfold stdioEventIgnored
        exact Bool.or_eq_true_iff.mpr (Or.inr (bne_iff_ne.mpr hne))
      rw [hign] at hrest
      simp only [ite_true, or_true, and_true] at hrest
      have hcsE := stdio_ofNat_eq cs hcs
      revert hrest
      rcases (by omega : cs.toNat = 0 ∨ cs.toNat = 1 ∨ cs.toNat = 2 ∨ cs.toNat = 3) with h0 | h1 | h2 | h3
      · rw [h0] at hcsE; subst hcsE; decide
      · rw [h1] at hcsE; subst hcsE; decide
      · rw [h2] at hcsE; subst hcsE; decide
      · rw [h3] at hcsE; subst hcsE; decide
    · have heq : eg = ag := beq_iff_eq.mp hcur
      rw [heq] at hrest
      have hign : stdioEventIgnored ag.toNat ag.toNat = false := by
        unfold stdioEventIgnored
        simp [Nat.lt_irrefl]
      rw [hign] at hrest
      simp only [Bool.not_false, Bool.true_and] at hrest
      rw [heq, stdioWord_current_table cs ag ok ex hcs hok hex]
      have hcsE := stdio_ofNat_eq cs hcs
      have hokE := stdio_ofNat_eq ok (by omega)
      have hexE := stdio_ofNat_eq ex (by omega)
      revert hrest
      rcases (by omega : cs.toNat = 0 ∨ cs.toNat = 1 ∨ cs.toNat = 2 ∨ cs.toNat = 3) with h0 | h1 | h2 | h3 <;>
      rcases (by omega : ok.toNat = 0 ∨ ok.toNat = 1) with hk0 | hk1 <;>
      rcases (by omega : ex.toNat = 0 ∨ ex.toNat = 1) with hx0 | hx1
      all_goals
        (try rw [h0] at hcsE)
        (try rw [h1] at hcsE)
        (try rw [h2] at hcsE)
        (try rw [h3] at hcsE)
        (try rw [hk0] at hokE)
        (try rw [hk1] at hokE)
        (try rw [hx0] at hexE)
        (try rw [hx1] at hexE)
        subst hcsE hokE hexE
        decide
  posWitness := { connState := 2, activeGen := 7, eventGen := 7, toolsListOk := 1, childExited := 1 }
  negWitness := { connState := 2, activeGen := 8, eventGen := 7, toolsListOk := 1, childExited := 0 }
  nonVacuous := by decide
  tight := by decide

/-! ### 6. Privilege Lease TOCTOU Execute Gate (`G-ORB-7`) -/

structure PrivdToctouCheck where
  principalKind : UInt8
  bunkerState   : UInt8
  targetLease   : UInt32 × UInt32 × UInt64 × UInt64
  ticks         : UInt64 × UInt64
  digests       : UInt64 × UInt64
  grantPresent  : UInt8
  allowExec     : UInt8
  deriving Repr, DecidableEq

/-- Independent observe→gate→execute model: the live target, lease epoch, and command digest still
    equal the observed evidence, the lease is unexpired outside bunker, and Core presented a
    nonempty grant with `allow_exec`. -/
def PrivdToctouDomainSafe (c : PrivdToctouCheck) : Prop :=
  1 ≤ c.principalKind.toNat ∧ c.principalKind.toNat ≤ 3 ∧
  c.bunkerState.toNat = 0 ∧
  c.targetLease.1.toNat ≠ 0 ∧ c.targetLease.1.toNat = c.targetLease.2.1.toNat ∧
  c.targetLease.2.2.1.toNat ≠ 0 ∧ c.targetLease.2.2.1.toNat = c.targetLease.2.2.2.toNat ∧
  c.ticks.1.toNat < c.ticks.2.toNat ∧
  c.digests.1.toNat ≠ 0 ∧ c.digests.1.toNat = c.digests.2.toNat ∧
  c.grantPresent.toNat = 1 ∧ c.allowExec.toNat = 1

@[inline, export orb_bin_verify_privd_toctou_step]
def verifyPrivdToctouStep
    (principalKind bunkerState : UInt8)
    (observedTargetId execTargetId : UInt32)
    (observedLeaseEpoch liveLeaseEpoch nowTick expiryTick observedDigest execDigest : UInt64)
    (grantPresent allowExec : UInt8) : UInt32 :=
  if bunkerState != 0 then 513
  else if !(principalKind ≥ 1 && principalKind ≤ 3) then 514
  else if !(nowTick < expiryTick) then 515
  else if !(observedLeaseEpoch != 0 && observedLeaseEpoch == liveLeaseEpoch) then 516
  else if !(observedTargetId != 0 && observedTargetId == execTargetId) then 517
  else if !(observedDigest != 0 && observedDigest == execDigest) then 518
  else if !(grantPresent == 1 && allowExec == 1) then 519
  else 257

def privdToctouMetaGate : MetaGateSpec PrivdToctouCheck PrivdToctouDomainSafe where
  gate c :=
    verifyPrivdToctouStep c.principalKind c.bunkerState c.targetLease.1 c.targetLease.2.1
      c.targetLease.2.2.1 c.targetLease.2.2.2 c.ticks.1 c.ticks.2 c.digests.1 c.digests.2
      c.grantPresent c.allowExec == 257
  sound c h := by
    rcases c with ⟨pk, bk, ⟨tgt, execT, obsL, liveL⟩, ⟨nowT, expT⟩, ⟨obsD, execD⟩, gp, ae⟩
    change (verifyPrivdToctouStep pk bk tgt execT obsL liveL nowT expT obsD execD gp ae == 257) = true at h
    dsimp [PrivdToctouDomainSafe]
    unfold verifyPrivdToctouStep at h
    cases hbk : (bk != 0)
    · cases hpk : (pk ≥ 1 && pk ≤ 3)
      · simp [hbk, hpk] at h
      · cases hexp : decide (nowT < expT)
        · simp [hbk, hpk, decide_eq_false_iff_not.mp hexp] at h
        · cases hlease : (obsL != 0 && obsL == liveL)
          · simp [hbk, hpk, decide_eq_true_eq.mp hexp, hlease] at h
          · cases htgt : (tgt != 0 && tgt == execT)
            · simp [hbk, hpk, decide_eq_true_eq.mp hexp, hlease, htgt] at h
            · cases hdig : (obsD != 0 && obsD == execD)
              · simp [hbk, hpk, decide_eq_true_eq.mp hexp, hlease, htgt, hdig] at h
              · cases hgrant : (gp == 1 && ae == 1)
                · simp [hbk, hpk, decide_eq_true_eq.mp hexp, hlease, htgt, hdig, hgrant] at h
                · simp only [bne_eq_false_iff_eq] at hbk
                  simp only [Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne, beq_iff_eq] at hpk hlease htgt hdig hgrant
                  rcases hgrant with ⟨hgp1, hae1⟩
                  have hexpN : nowT.toNat < expT.toNat := UInt64.lt_iff_toNat_lt.mp (decide_eq_true_eq.mp hexp)
                  refine ⟨UInt8.le_iff_toNat_le.mp hpk.1, UInt8.le_iff_toNat_le.mp hpk.2,
                    by subst hbk; rfl,
                    fun e => htgt.1 (by apply UInt32.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact e),
                    congrArg UInt32.toNat htgt.2,
                    fun e => hlease.1 (by apply UInt64.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact e),
                    congrArg UInt64.toNat hlease.2,
                    hexpN,
                    fun e => hdig.1 (by apply UInt64.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact e),
                    congrArg UInt64.toNat hdig.2,
                    by subst hgp1; rfl,
                    by subst hae1; rfl⟩
    · simp [hbk] at h
  complete c h := by
    rcases c with ⟨pk, bk, ⟨tgt, execT, obsL, liveL⟩, ⟨nowT, expT⟩, ⟨obsD, execD⟩, gp, ae⟩
    dsimp [PrivdToctouDomainSafe] at h
    rcases h with ⟨hpk1, hpk3, hbk, htgt0, htgteq, hlease0, hleaseeq, hexp, hdig0, hdigeq, hgp, hae⟩
    change (verifyPrivdToctouStep pk bk tgt execT obsL liveL nowT expT obsD execD gp ae == 257) = true
    have hbkB : (bk != 0) = false := bne_eq_false_iff_eq.mpr (u8_eq_of_toNat bk 0 (by omega) hbk)
    have hpk1B : 1 ≤ pk := u8_le_of_toNat_le 1 pk (by change 1 ≤ pk.toNat; omega)
    have hpk3B : pk ≤ 3 := u8_le_of_toNat_le pk 3 (by change pk.toNat ≤ 3; omega)
    have hpkB : (decide (pk ≥ 1) && decide (pk ≤ 3)) = true := by
      simp [hpk1B, hpk3B]
    have hexpB : nowT < expT := UInt64.lt_iff_toNat_lt.mpr hexp
    have hleaseB : (obsL != 0 && obsL == liveL) = true := by
      simp [bne_iff_ne, beq_iff_eq]
      exact ⟨fun e => hlease0 (congrArg UInt64.toNat e),
        by apply UInt64.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact hleaseeq⟩
    have htgtB : (tgt != 0 && tgt == execT) = true := by
      simp [bne_iff_ne, beq_iff_eq]
      exact ⟨fun e => htgt0 (congrArg UInt32.toNat e),
        by apply UInt32.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact htgteq⟩
    have hdigB : (obsD != 0 && obsD == execD) = true := by
      simp [bne_iff_ne, beq_iff_eq]
      exact ⟨fun e => hdig0 (congrArg UInt64.toNat e),
        by apply UInt64.eq_of_toBitVec_eq; apply BitVec.eq_of_toNat_eq; exact hdigeq⟩
    have hgrantB : (gp == 1 && ae == 1) = true := by
      simp [u8_eq_of_toNat gp 1 (by omega) hgp, u8_eq_of_toNat ae 1 (by omega) hae]
    unfold verifyPrivdToctouStep
    simp [hbkB, hpkB, hexpB, hleaseB, htgtB, hdigB, hgrantB]
  posWitness := {
    principalKind := 2, bunkerState := 0, targetLease := (9, 9, 4, 4), ticks := (10, 20),
    digests := (11, 11), grantPresent := 1, allowExec := 1 }
  negWitness := {
    principalKind := 2, bunkerState := 0, targetLease := (9, 9, 4, 4), ticks := (10, 20),
    digests := (11, 12), grantPresent := 1, allowExec := 1 }
  nonVacuous := by decide
  tight := by decide

def privdToctouScopedAuthority : ScopedAuthority PrivdToctouCheck where
  admit := privdToctouMetaGate.gate
  scopeValid c := c.grantPresent.toNat = 1 ∧ c.allowExec.toNat = 1 ∧ c.bunkerState.toNat = 0
  sound c h := by
    rcases privdToctouMetaGate.sound c h with ⟨_, _, hbk, _, _, _, _, _, _, _, hgp, hae⟩
    exact ⟨hgp, hae, hbk⟩

theorem privd_toctou_rejects_digest_swap (pk bk : UInt8) (t1 t2 : UInt32) (l1 l2 n e d g : UInt64) (gp ae : UInt8)
    (hswap : d ≠ g) :
    verifyPrivdToctouStep pk bk t1 t2 l1 l2 n e d g gp ae ≠ 257 := by
  have hbad : ¬ PrivdToctouDomainSafe
      ⟨pk, bk, (t1, t2, l1, l2), (n, e), (d, g), gp, ae⟩ := by
    intro hsafe
    rcases hsafe with ⟨_, _, _, _, _, _, _, _, _, hdigeq, _, _⟩
    apply hswap
    apply UInt64.eq_of_toBitVec_eq
    apply BitVec.eq_of_toNat_eq
    exact hdigeq
  have hf := privdToctouMetaGate.rejects_unsafe
    ⟨pk, bk, (t1, t2, l1, l2), (n, e), (d, g), gp, ae⟩ hbad
  unfold privdToctouMetaGate at hf
  simpa [beq_eq_false_iff_ne] using hf

end OrbBin.Spec
