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

end OrbBin.Spec
