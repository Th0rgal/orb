/-
  OrbNetLeaf.Spec: Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for AEAD envelope framing (`AES-256-GCM`, `ChaCha20-Poly1305`, `AES-128-GCM`),
  RFC 9001 QUIC Header Protection mask generation (`AES-128-ECB`, `ChaCha20`),
  role-separated Ed25519/X25519 key-material & signature discipline,
  outbound HTTPS/H2/H3 request framing, and PTY window geometry bounds.

  Every unboxed scalar gate is proved equivalent to an independent domain model
  over typed protocol ADTs and natural-number resource invariants (`ConservedResource`,
  `ScopedAuthority`, `MetaGateSpec`) rather than mirroring the gate's boolean formula.
-/

namespace OrbNetLeaf.Spec

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

/-- Layer-I `ConservedResource` meta-specification: admitted inputs stay within capacity budgets. -/
structure ConservedResource (Input : Type) where
  admit        : Input → Bool
  withinBudget : Input → Prop
  conserved    : ∀ x, admit x = true → withinBudget x

/-- Layer-I `ScopedAuthority` meta-specification: admitted operations stay within key/peer role scope. -/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Prop
  sound      : ∀ x, admit x = true → scopeValid x

private theorem u8_le_one_cases (b : UInt8) (h : b ≤ 1) : b.toNat = 0 ∨ b.toNat = 1 := by
  have hb : b.toNat ≤ 1 := UInt8.le_iff_toNat_le.mp h
  omega

private theorem u8_eq_of_toNat (a : UInt8) (n : Nat) (hn : n < 256) (h : a.toNat = n) :
    a = UInt8.ofNat n := by
  apply UInt8.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt8.ofNat n).toBitVec.toNat = n := by
    change n % 256 = n
    omega
  change a.toNat = _
  omega

private theorem u64_eq_of_toNat (a : UInt64) (n : Nat) (hn : n < 18446744073709551616) (h : a.toNat = n) :
    a = UInt64.ofNat n := by
  apply UInt64.eq_of_toBitVec_eq
  apply BitVec.eq_of_toNat_eq
  have hm : (UInt64.ofNat n).toBitVec.toNat = n := by
    change n % 18446744073709551616 = n
    omega
  change a.toNat = _
  omega

private theorem bit_gate_eq_zero {c : Bool} (hf : ((if c then (1 : UInt8) else 0) == 1) = false) :
    (if c then (1 : UInt8) else 0) = 0 := by
  cases c <;> simp_all

/-! ## Spec Block 1: `AeadEnvelopeSpec` (`AES-256-GCM` / `ChaCha20-Poly1305` / `AES-128-GCM`) -/

/-- Domain cipher catalog with RFC 5116 / RFC 8439 / RFC 9001 key, nonce, and authentication tag sizes. -/
inductive CipherSuite where
  | aes256Gcm
  | chacha20Poly1305
  | aes128Gcm
  deriving Repr, DecidableEq

def CipherSuite.decode? : Nat → Option CipherSuite
  | 0 => some .aes256Gcm
  | 1 => some .chacha20Poly1305
  | 2 => some .aes128Gcm
  | _ => none

def CipherSuite.keyBytes : CipherSuite → Nat
  | .aes256Gcm => 32
  | .chacha20Poly1305 => 32
  | .aes128Gcm => 16

def CipherSuite.nonceBytes : CipherSuite → Nat
  | .aes256Gcm => 12
  | .chacha20Poly1305 => 12
  | .aes128Gcm => 12

def CipherSuite.tagBytes : CipherSuite → Nat
  | .aes256Gcm => 16
  | .chacha20Poly1305 => 16
  | .aes128Gcm => 16

inductive AeadDirection where
  | openMsg
  | sealMsg
  deriving Repr, DecidableEq

def AeadDirection.decode? : Nat → Option AeadDirection
  | 0 => some .openMsg
  | 1 => some .sealMsg
  | _ => none

def maxAeadAadBytes : Nat := 16 * 1024 * 1024
def maxAeadWireBytes : Nat := 64 * 1024 * 1024

/-- Independent RFC 5116 / RFC 9001 AEAD envelope domain specification over `Nat` lengths. -/
structure AeadEnvelopeInput where
  flags : UInt8 × UInt8
  lens  : UInt64 × UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

def AeadEnvelopeDomainSafe (x : AeadEnvelopeInput) : Prop :=
  ∃ (suite : CipherSuite) (dir : AeadDirection) (ptBytes : Nat),
    CipherSuite.decode? x.flags.1.toNat = some suite ∧
    AeadDirection.decode? x.flags.2.toNat = some dir ∧
    x.lens.1.toNat = suite.keyBytes ∧
    x.lens.2.1.toNat = suite.nonceBytes ∧
    x.lens.2.2.1.toNat ≤ maxAeadAadBytes ∧
    ptBytes + suite.tagBytes ≤ maxAeadWireBytes ∧
    match dir with
    | .sealMsg => x.lens.2.2.2.toNat = ptBytes
    | .openMsg => x.lens.2.2.2.toNat = ptBytes + suite.tagBytes

/-- Direct unboxed C-ABI gate for AEAD seal/open envelope lengths (`0=AES-256-GCM`, `1=ChaCha20-Poly1305`, `2=AES-128-GCM`). -/
@[inline, export orb_net_verify_aead_envelope]
def verifyAeadEnvelope (alg enc : UInt8) (keyLen nonceLen aadLen bufLen : UInt64) : UInt8 :=
  if (if alg ≤ 1 then keyLen == 32 else if alg == 2 then keyLen == 16 else false) &&
     enc ≤ 1 && nonceLen == 12 && aadLen ≤ 16777216 &&
     (if enc == 1 then bufLen ≤ 67108848 else bufLen ≥ 16 && bufLen ≤ 67108864) then 1 else 0

def aeadEnvelopeMetaSpec : MetaGateSpec AeadEnvelopeInput AeadEnvelopeDomainSafe where
  gate x :=
    verifyAeadEnvelope x.flags.1 x.flags.2 x.lens.1 x.lens.2.1 x.lens.2.2.1 x.lens.2.2.2 == 1
  sound x h := by
    rcases x with ⟨⟨alg, enc⟩, ⟨kL, nL, aL, bL⟩⟩
    change (verifyAeadEnvelope alg enc kL nL aL bL == 1) = true at h
    dsimp [AeadEnvelopeDomainSafe]
    unfold verifyAeadEnvelope at h
    have hcond :
        ((if alg ≤ 1 then kL == 32 else if alg == 2 then kL == 16 else false) &&
         enc ≤ 1 && nL == 12 && aL ≤ 16777216 &&
         (if enc == 1 then bL ≤ 67108848 else bL ≥ 16 && bL ≤ 67108864)) = true := by
      cases hc :
          ((if alg ≤ 1 then kL == 32 else if alg == 2 then kL == 16 else false) &&
           enc ≤ 1 && nL == 12 && aL ≤ 16777216 &&
           (if enc == 1 then bL ≤ 67108848 else bL ≥ 16 && bL ≤ 67108864))
      · rw [hc] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hcond
    rcases hcond with ⟨⟨⟨⟨hkey, henc⟩, hn⟩, ha⟩, hbuf⟩
    have hnN : nL.toNat = 12 := by subst hn; rfl
    have haN : aL.toNat ≤ maxAeadAadBytes := UInt64.le_iff_toNat_le.mp ha
    by_cases halg1 : alg ≤ 1
    · simp only [halg1, ↓reduceIte, beq_iff_eq] at hkey
      have hkN : kL.toNat = 32 := by subst hkey; rfl
      rcases u8_le_one_cases alg halg1 with halg0 | halgOne <;>
        rcases u8_le_one_cases enc henc with henc0 | henc1
      · have hencNe : enc ≠ 1 := fun he => by subst he; contradiction
        simp only [hencNe, ↓reduceIte, Bool.and_eq_true, decide_eq_true_eq] at hbuf
        have hbGe : 16 ≤ bL.toNat := UInt64.le_iff_toNat_le.mp hbuf.1
        have hbLe : bL.toNat ≤ 67108864 := UInt64.le_iff_toNat_le.mp hbuf.2
        refine ⟨.aes256Gcm, .openMsg, bL.toNat - 16, ?_, ?_, hkN, hnN, haN, ?_, ?_⟩
        · simp [CipherSuite.decode?, halg0]
        · simp [AeadDirection.decode?, henc0]
        · change (bL.toNat - 16) + 16 ≤ 67108864; omega
        · change bL.toNat = (bL.toNat - 16) + 16; omega
      · have hencEq : enc = 1 := u8_eq_of_toNat enc 1 (by omega) henc1
        simp only [hencEq, ↓reduceIte, decide_eq_true_eq] at hbuf
        have hbLe : bL.toNat ≤ 67108848 := UInt64.le_iff_toNat_le.mp hbuf
        refine ⟨.aes256Gcm, .sealMsg, bL.toNat, ?_, ?_, hkN, hnN, haN, ?_, rfl⟩
        · simp [CipherSuite.decode?, halg0]
        · simp [AeadDirection.decode?, henc1]
        · change bL.toNat + 16 ≤ 67108864; omega
      · have hencNe : enc ≠ 1 := fun he => by subst he; contradiction
        simp only [hencNe, ↓reduceIte, Bool.and_eq_true, decide_eq_true_eq] at hbuf
        have hbGe : 16 ≤ bL.toNat := UInt64.le_iff_toNat_le.mp hbuf.1
        have hbLe : bL.toNat ≤ 67108864 := UInt64.le_iff_toNat_le.mp hbuf.2
        refine ⟨.chacha20Poly1305, .openMsg, bL.toNat - 16, ?_, ?_, hkN, hnN, haN, ?_, ?_⟩
        · simp [CipherSuite.decode?, halgOne]
        · simp [AeadDirection.decode?, henc0]
        · change (bL.toNat - 16) + 16 ≤ 67108864; omega
        · change bL.toNat = (bL.toNat - 16) + 16; omega
      · have hencEq : enc = 1 := u8_eq_of_toNat enc 1 (by omega) henc1
        simp only [hencEq, ↓reduceIte, decide_eq_true_eq] at hbuf
        have hbLe : bL.toNat ≤ 67108848 := UInt64.le_iff_toNat_le.mp hbuf
        refine ⟨.chacha20Poly1305, .sealMsg, bL.toNat, ?_, ?_, hkN, hnN, haN, ?_, rfl⟩
        · simp [CipherSuite.decode?, halgOne]
        · simp [AeadDirection.decode?, henc1]
        · change bL.toNat + 16 ≤ 67108864; omega
    · simp only [halg1, ↓reduceIte] at hkey
      by_cases halg2 : alg = 2
      · simp only [halg2, ↓reduceIte, beq_iff_eq] at hkey
        have halgN : alg.toNat = 2 := by subst halg2; rfl
        have hkN : kL.toNat = 16 := by subst hkey; rfl
        rcases u8_le_one_cases enc henc with henc0 | henc1
        · have hencNe : enc ≠ 1 := fun he => by subst he; contradiction
          simp only [hencNe, ↓reduceIte, Bool.and_eq_true, decide_eq_true_eq] at hbuf
          have hbGe : 16 ≤ bL.toNat := UInt64.le_iff_toNat_le.mp hbuf.1
          have hbLe : bL.toNat ≤ 67108864 := UInt64.le_iff_toNat_le.mp hbuf.2
          refine ⟨.aes128Gcm, .openMsg, bL.toNat - 16, ?_, ?_, hkN, hnN, haN, ?_, ?_⟩
          · simp [CipherSuite.decode?, halgN]
          · simp [AeadDirection.decode?, henc0]
          · change (bL.toNat - 16) + 16 ≤ 67108864; omega
          · change bL.toNat = (bL.toNat - 16) + 16; omega
        · have hencEq : enc = 1 := u8_eq_of_toNat enc 1 (by omega) henc1
          simp only [hencEq, ↓reduceIte, decide_eq_true_eq] at hbuf
          have hbLe : bL.toNat ≤ 67108848 := UInt64.le_iff_toNat_le.mp hbuf
          refine ⟨.aes128Gcm, .sealMsg, bL.toNat, ?_, ?_, hkN, hnN, haN, ?_, rfl⟩
          · simp [CipherSuite.decode?, halgN]
          · simp [AeadDirection.decode?, henc1]
          · change bL.toNat + 16 ≤ 67108864; omega
      · simp [halg2] at hkey
  complete x h := by
    rcases x with ⟨⟨alg, enc⟩, ⟨kL, nL, aL, bL⟩⟩
    change (verifyAeadEnvelope alg enc kL nL aL bL == 1) = true
    dsimp [AeadEnvelopeDomainSafe] at h
    rcases h with ⟨suite, dir, ptBytes, hSuite, hDir, hk, hn, ha, hWire, hBuf⟩
    unfold verifyAeadEnvelope
    have hKeyOk : if alg ≤ 1 then kL = 32 else alg = 2 ∧ kL = 16 := by
      cases suite with
      | aes256Gcm =>
        have halg0 : alg.toNat = 0 := by
          cases hs : alg.toNat with
          | zero => rfl
          | succ m => rcases m with _ | _ | _ <;> simp [CipherSuite.decode?, hs] at hSuite
        have halgLe : alg ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change alg.toNat ≤ 1; omega
        have hkEq : kL = 32 := u64_eq_of_toNat kL 32 (by omega) (by simpa [CipherSuite.keyBytes] using hk)
        simp [halgLe, hkEq]
      | chacha20Poly1305 =>
        have halg1 : alg.toNat = 1 := by
          cases hs : alg.toNat with
          | zero => simp [CipherSuite.decode?, hs] at hSuite
          | succ m => rcases m with _ | _ | _ <;> simp [CipherSuite.decode?, hs] at hSuite; rfl
        have halgLe : alg ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change alg.toNat ≤ 1; omega
        have hkEq : kL = 32 := u64_eq_of_toNat kL 32 (by omega) (by simpa [CipherSuite.keyBytes] using hk)
        simp [halgLe, hkEq]
      | aes128Gcm =>
        have halg2 : alg.toNat = 2 := by
          cases hs : alg.toNat with
          | zero => simp [CipherSuite.decode?, hs] at hSuite
          | succ m => rcases m with _ | _ | _ <;> simp [CipherSuite.decode?, hs] at hSuite; rfl
        have halgEq2 : alg = 2 := u8_eq_of_toNat alg 2 (by omega) halg2
        have hkEq : kL = 16 := u64_eq_of_toNat kL 16 (by omega) (by simpa [CipherSuite.keyBytes] using hk)
        simp [halgEq2, hkEq]
    have henc : enc ≤ 1 := by
      apply UInt8.le_iff_toNat_le.mpr; change enc.toNat ≤ 1
      cases hd : enc.toNat with
      | zero => omega
      | succ m =>
        cases m with
        | zero => omega
        | succ _ => simp [AeadDirection.decode?, hd] at hDir
    have hn12 : nL.toNat = 12 := by cases suite <;> simpa [CipherSuite.nonceBytes] using hn
    have hnEq : (nL == 12) = true := by
      rw [beq_iff_eq]; exact u64_eq_of_toNat nL 12 (by omega) hn12
    have haLe : aL ≤ 16777216 := by
      apply UInt64.le_iff_toNat_le.mpr; change aL.toNat ≤ 16777216
      unfold maxAeadAadBytes at ha; omega
    have htag : suite.tagBytes = 16 := by cases suite <;> rfl
    cases dir with
    | sealMsg =>
      have henc1 : enc.toNat = 1 := by
        cases hd : enc.toNat with
        | zero => simp [AeadDirection.decode?, hd] at hDir
        | succ m =>
          cases m with
          | zero => rfl
          | succ _ => simp [AeadDirection.decode?, hd] at hDir
      have hencEq : (enc == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat enc 1 (by omega) henc1
      have hbLe : bL ≤ 67108848 := by
        apply UInt64.le_iff_toNat_le.mpr; change bL.toNat ≤ 67108848
        unfold maxAeadWireBytes at hWire; dsimp at hBuf; omega
      simp [hKeyOk, henc, hnEq, haLe, hencEq, hbLe]
    | openMsg =>
      have henc0 : enc.toNat = 0 := by
        cases hd : enc.toNat with
        | zero => rfl
        | succ m =>
          cases m with
          | zero => simp [AeadDirection.decode?, hd] at hDir
          | succ _ => simp [AeadDirection.decode?, hd] at hDir
      have hencEq : (enc == 1) = false := by
        apply Bool.eq_false_iff.mpr
        intro he
        rw [beq_iff_eq] at he
        subst he
        contradiction
      have hbGe : bL ≥ 16 := by
        apply UInt64.le_iff_toNat_le.mpr; change 16 ≤ bL.toNat
        dsimp at hBuf; omega
      have hbLe : bL ≤ 67108864 := by
        apply UInt64.le_iff_toNat_le.mpr; change bL.toNat ≤ 67108864
        unfold maxAeadWireBytes at hWire; dsimp at hBuf; omega
      simp [hKeyOk, henc, hnEq, haLe, hencEq, hbGe, hbLe]
  posWitness := { flags := (2, 1), lens := (16, 12, 24, 1200) }
  negWitness := { flags := (0, 0), lens := (32, 12, 0, 15) }
  nonVacuous := by decide
  tight := by decide

def aeadConservedResource : ConservedResource AeadEnvelopeInput where
  admit := aeadEnvelopeMetaSpec.gate
  withinBudget x := x.lens.2.2.1.toNat ≤ maxAeadAadBytes ∧ x.lens.2.2.2.toNat ≤ maxAeadWireBytes
  conserved x h := by
    rcases aeadEnvelopeMetaSpec.sound x h with ⟨suite, dir, ptBytes, _, _, _, _, ha, hw, hb⟩
    have htag : suite.tagBytes = 16 := by cases suite <;> rfl
    refine ⟨ha, ?_⟩
    cases dir <;> dsimp at hb <;> omega

theorem aead_open_requires_tag_floor (alg : UInt8) (kL nL aL bL : UInt64)
    (h_short : bL.toNat < 16) :
    verifyAeadEnvelope alg 0 kL nL aL bL = 0 := by
  have hbad : ¬ AeadEnvelopeDomainSafe ⟨(alg, 0), (kL, nL, aL, bL)⟩ := by
    rintro ⟨suite, dir, ptBytes, _, hDir, _, _, _, _, hBuf⟩
    have htag : suite.tagBytes = 16 := by cases suite <;> rfl
    cases dir with
    | openMsg => dsimp at hBuf; omega
    | sealMsg => simp [AeadDirection.decode?] at hDir
  have hf := aeadEnvelopeMetaSpec.rejects_unsafe ⟨(alg, 0), (kL, nL, aL, bL)⟩ hbad
  unfold aeadEnvelopeMetaSpec at hf; dsimp at hf
  unfold verifyAeadEnvelope at hf ⊢
  exact bit_gate_eq_zero hf

/-! ## Spec Block 2: `QuicHeaderProtectionSpec` (RFC 9001 §5.4 5-Byte Mask Domain Gate) -/

/-- RFC 9001 §5.4 QUIC Header Protection cipher catalog (`AES-128-ECB` vs `ChaCha20`). -/
inductive HpCipherSuite where
  | aes128Ecb
  | chacha20
  deriving Repr, DecidableEq

def HpCipherSuite.decode? : Nat → Option HpCipherSuite
  | 0 => some .aes128Ecb
  | 1 => some .chacha20
  | _ => none

def HpCipherSuite.hpKeyBytes : HpCipherSuite → Nat
  | .aes128Ecb => 16
  | .chacha20  => 32

def quicHpSampleBytes : Nat := 16

structure QuicHpMaskInput where
  hpAlg : UInt8
  lens  : UInt64 × UInt64
  deriving Repr, DecidableEq

/-- Independent RFC 9001 §5.4 QUIC Header Protection domain specification. -/
def QuicHpMaskDomainSafe (x : QuicHpMaskInput) : Prop :=
  ∃ hpSuite : HpCipherSuite,
    HpCipherSuite.decode? x.hpAlg.toNat = some hpSuite ∧
    x.lens.1.toNat = hpSuite.hpKeyBytes ∧
    x.lens.2.toNat = quicHpSampleBytes

@[inline, export orb_net_verify_quic_hp_mask]
def verifyQuicHpMask (hpAlg : UInt8) (hpKeyLen sampleLen : UInt64) : UInt8 :=
  if sampleLen == 16 &&
     (if hpAlg == 0 then hpKeyLen == 16 else if hpAlg == 1 then hpKeyLen == 32 else false)
  then 1 else 0

def quicHpMaskMetaSpec : MetaGateSpec QuicHpMaskInput QuicHpMaskDomainSafe where
  gate x := verifyQuicHpMask x.hpAlg x.lens.1 x.lens.2 == 1
  sound x h := by
    rcases x with ⟨alg, ⟨kL, sL⟩⟩
    change (verifyQuicHpMask alg kL sL == 1) = true at h
    dsimp [QuicHpMaskDomainSafe]
    unfold verifyQuicHpMask at h
    have hc :
        (sL == 16 && (if alg == 0 then kL == 16 else if alg == 1 then kL == 32 else false)) = true := by
      cases hb : (sL == 16 && (if alg == 0 then kL == 16 else if alg == 1 then kL == 32 else false))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    rcases hc with ⟨hs, hk⟩
    have hsN : sL.toNat = quicHpSampleBytes := by subst hs; rfl
    by_cases h0 : alg = 0
    · simp only [h0, ↓reduceIte, beq_iff_eq] at hk
      have halg0 : alg.toNat = 0 := by subst h0; rfl
      have hkN : kL.toNat = 16 := by subst hk; rfl
      exact ⟨.aes128Ecb, by simp [HpCipherSuite.decode?, halg0], hkN, hsN⟩
    · simp only [h0, ↓reduceIte] at hk
      by_cases h1 : alg = 1
      · simp only [h1, ↓reduceIte, beq_iff_eq] at hk
        have halg1 : alg.toNat = 1 := by subst h1; rfl
        have hkN : kL.toNat = 32 := by subst hk; rfl
        exact ⟨.chacha20, by simp [HpCipherSuite.decode?, halg1], hkN, hsN⟩
      · simp [h1] at hk
  complete x h := by
    rcases x with ⟨alg, ⟨kL, sL⟩⟩
    change (verifyQuicHpMask alg kL sL == 1) = true
    dsimp [QuicHpMaskDomainSafe] at h
    rcases h with ⟨hpSuite, hSuite, hk, hs⟩
    unfold verifyQuicHpMask
    have hsEq : (sL == 16) = true := by
      rw [beq_iff_eq]; exact u64_eq_of_toNat sL 16 (by omega) (by simpa [quicHpSampleBytes] using hs)
    cases hpSuite with
    | aes128Ecb =>
      have halg0 : alg = 0 := by
        refine u8_eq_of_toNat alg 0 (by omega) ?_
        cases ha : alg.toNat with
        | zero => rfl
        | succ m => rcases m with _ | _ <;> simp [HpCipherSuite.decode?, ha] at hSuite
      have hkEq : (kL == 16) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat kL 16 (by omega) (by simpa [HpCipherSuite.hpKeyBytes] using hk)
      subst halg0; simp [hsEq, hkEq]
    | chacha20 =>
      have halg1 : alg = 1 := by
        refine u8_eq_of_toNat alg 1 (by omega) ?_
        cases ha : alg.toNat with
        | zero => simp [HpCipherSuite.decode?, ha] at hSuite
        | succ m => rcases m with _ | _ <;> simp [HpCipherSuite.decode?, ha] at hSuite; rfl
      have hkEq : (kL == 32) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat kL 32 (by omega) (by simpa [HpCipherSuite.hpKeyBytes] using hk)
      subst halg1; simp [hsEq, hkEq]
  posWitness := { hpAlg := 0, lens := (16, 16) }
  negWitness := { hpAlg := 0, lens := (16, 15) }
  nonVacuous := by decide
  tight := by decide

theorem quic_hp_mask_requires_16b_sample (alg : UInt8) (kL sL : UInt64)
    (h_short : sL.toNat ≠ 16) :
    verifyQuicHpMask alg kL sL = 0 := by
  have hbad : ¬ QuicHpMaskDomainSafe ⟨alg, (kL, sL)⟩ := by
    rintro ⟨_, _, _, hs⟩
    dsimp [quicHpSampleBytes] at hs
    exact h_short hs
  have hf := quicHpMaskMetaSpec.rejects_unsafe ⟨alg, (kL, sL)⟩ hbad
  unfold quicHpMaskMetaSpec at hf; dsimp at hf
  unfold verifyQuicHpMask at hf ⊢
  exact bit_gate_eq_zero hf

/-! ## Spec Block 3: `Ed25519X25519GateSpec` (Role-Separated Signature & ECDH Discipline) -/

/-- Role-separated asymmetric cryptographic operations (`op = 3` X25519 pubkey vs `op = 4` X25519 ECDH). -/
inductive AsymRole where
  | ed25519DerivePub
  | ed25519Sign
  | ed25519Verify
  | x25519DerivePub
  | x25519SharedSecret
  deriving Repr, DecidableEq

def AsymRole.decode? : Nat → Option AsymRole
  | 0 => some .ed25519DerivePub
  | 1 => some .ed25519Sign
  | 2 => some .ed25519Verify
  | 3 => some .x25519DerivePub
  | 4 => some .x25519SharedSecret
  | _ => none

def AsymRole.primaryKeyBytes : AsymRole → Nat
  | _ => 32

def AsymRole.secondaryMaterialBytes : AsymRole → Nat
  | .ed25519DerivePub   => 0
  | .ed25519Sign        => 0
  | .ed25519Verify      => 64
  | .x25519DerivePub    => 0
  | .x25519SharedSecret => 32

def AsymRole.maxMessageBytes : AsymRole → Nat
  | .ed25519DerivePub   => 0
  | .ed25519Sign        => 16 * 1024 * 1024
  | .ed25519Verify      => 16 * 1024 * 1024
  | .x25519DerivePub    => 0
  | .x25519SharedSecret => 0

structure AsymOpInput where
  op   : UInt8
  lens : UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

/-- Independent RFC 8032 / RFC 7748 role-separated key & message domain specification. -/
def AsymOpDomainSafe (x : AsymOpInput) : Prop :=
  ∃ role : AsymRole,
    AsymRole.decode? x.op.toNat = some role ∧
    x.lens.1.toNat = role.primaryKeyBytes ∧
    x.lens.2.1.toNat = role.secondaryMaterialBytes ∧
    x.lens.2.2.toNat ≤ role.maxMessageBytes

/-- Direct unboxed C-ABI gate for role-separated Ed25519 / X25519 operations (`0..4`). -/
@[inline, export orb_net_verify_asym_op]
def verifyAsymOp (op : UInt8) (k1Len k2Len msgLen : UInt64) : UInt8 :=
  if (if op == 0 then k1Len == 32 && k2Len == 0 && msgLen == 0
      else if op == 1 then k1Len == 32 && k2Len == 0 && msgLen ≤ 16777216
      else if op == 2 then k1Len == 32 && k2Len == 64 && msgLen ≤ 16777216
      else if op == 3 then k1Len == 32 && k2Len == 0 && msgLen == 0
      else if op == 4 then k1Len == 32 && k2Len == 32 && msgLen == 0
      else false) then 1 else 0

def asymOpMetaSpec : MetaGateSpec AsymOpInput AsymOpDomainSafe where
  gate x := verifyAsymOp x.op x.lens.1 x.lens.2.1 x.lens.2.2 == 1
  sound x h := by
    rcases x with ⟨op, ⟨k1, k2, mL⟩⟩
    change (verifyAsymOp op k1 k2 mL == 1) = true at h
    dsimp [AsymOpDomainSafe]
    unfold verifyAsymOp at h
    cases h0 : (op == 0)
    · rw [h0] at h; simp only [Bool.false_eq_true, ↓reduceIte] at h
      cases h1 : (op == 1)
      · rw [h1] at h; simp only [Bool.false_eq_true, ↓reduceIte] at h
        cases h2 : (op == 2)
        · rw [h2] at h; simp only [Bool.false_eq_true, ↓reduceIte] at h
          cases h3 : (op == 3)
          · rw [h3] at h; simp only [Bool.false_eq_true, ↓reduceIte] at h
            cases h4 : (op == 4)
            · rw [h4] at h; contradiction
            · rw [h4] at h; simp only [↓reduceIte] at h
              have hop : op.toNat = 4 := by rw [beq_iff_eq] at h4; subst h4; rfl
              cases hc : (k1 == 32 && k2 == 32 && mL == 0)
              · rw [hc] at h; contradiction
              · simp only [Bool.and_eq_true, beq_iff_eq] at hc
                rcases hc with ⟨⟨hk1, hk2⟩, hm⟩
                subst hk1; subst hk2
                subst hm
                exact ⟨.x25519SharedSecret, by simp [AsymRole.decode?, hop], rfl, rfl, Nat.zero_le _⟩
          · rw [h3] at h; simp only [↓reduceIte] at h
            have hop : op.toNat = 3 := by rw [beq_iff_eq] at h3; subst h3; rfl
            cases hc : (k1 == 32 && k2 == 0 && mL == 0)
            · rw [hc] at h; contradiction
            · simp only [Bool.and_eq_true, beq_iff_eq] at hc
              rcases hc with ⟨⟨hk1, hk2⟩, hm⟩
              subst hk1; subst hk2
              subst hm
              exact ⟨.x25519DerivePub, by simp [AsymRole.decode?, hop], rfl, rfl, Nat.zero_le _⟩
        · rw [h2] at h; simp only [↓reduceIte] at h
          have hop : op.toNat = 2 := by rw [beq_iff_eq] at h2; subst h2; rfl
          cases hc : (k1 == 32 && k2 == 64 && decide (mL ≤ 16777216))
          · rw [hc] at h; contradiction
          · simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
            rcases hc with ⟨⟨hk1, hk2⟩, hm⟩; subst hk1; subst hk2
            exact ⟨.ed25519Verify, by simp [AsymRole.decode?, hop], rfl, rfl, UInt64.le_iff_toNat_le.mp hm⟩
      · rw [h1] at h; simp only [↓reduceIte] at h
        have hop : op.toNat = 1 := by rw [beq_iff_eq] at h1; subst h1; rfl
        cases hc : (k1 == 32 && k2 == 0 && decide (mL ≤ 16777216))
        · rw [hc] at h; contradiction
        · simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
          rcases hc with ⟨⟨hk1, hk2⟩, hm⟩; subst hk1; subst hk2
          exact ⟨.ed25519Sign, by simp [AsymRole.decode?, hop], rfl, rfl, UInt64.le_iff_toNat_le.mp hm⟩
    · rw [h0] at h; simp only [↓reduceIte] at h
      have hop : op.toNat = 0 := by rw [beq_iff_eq] at h0; subst h0; rfl
      cases hc : (k1 == 32 && k2 == 0 && mL == 0)
      · rw [hc] at h; contradiction
      · simp only [Bool.and_eq_true, beq_iff_eq] at hc
        rcases hc with ⟨⟨hk1, hk2⟩, hm⟩
        subst hk1; subst hk2
        subst hm
        exact ⟨.ed25519DerivePub, by simp [AsymRole.decode?, hop], rfl, rfl, Nat.zero_le _⟩
  complete x h := by
    rcases x with ⟨op, ⟨k1, k2, mL⟩⟩
    change (verifyAsymOp op k1 k2 mL == 1) = true
    dsimp [AsymOpDomainSafe] at h
    rcases h with ⟨role, hRole, hk1, hk2, hm⟩
    have hk1B : (k1 == 32) = true := by
      rw [beq_iff_eq]; exact u64_eq_of_toNat k1 32 (by omega) (by simpa [AsymRole.primaryKeyBytes] using hk1)
    unfold verifyAsymOp
    cases role with
    | ed25519DerivePub =>
      have hop : op = 0 := by
        refine u8_eq_of_toNat op 0 (by omega) ?_
        cases ho : op.toNat with
        | zero => rfl
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [AsymRole.decode?, ho] at hRole
      have hk2B : (k2 == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat k2 0 (by omega) (by simpa [AsymRole.secondaryMaterialBytes] using hk2)
      have hm0 : mL.toNat = 0 := Nat.eq_zero_of_le_zero (by simpa [AsymRole.maxMessageBytes] using hm)
      have hmB : (mL == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat mL 0 (by omega) hm0
      subst hop; simp [hk1B, hk2B, hmB]
    | ed25519Sign =>
      have hop : op = 1 := by
        refine u8_eq_of_toNat op 1 (by omega) ?_
        cases ho : op.toNat with
        | zero => simp [AsymRole.decode?, ho] at hRole
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [AsymRole.decode?, ho] at hRole; rfl
      have hk2B : (k2 == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat k2 0 (by omega) (by simpa [AsymRole.secondaryMaterialBytes] using hk2)
      have hmLe : mL ≤ 16777216 := by
        apply UInt64.le_iff_toNat_le.mpr; change mL.toNat ≤ 16777216
        simpa [AsymRole.maxMessageBytes] using hm
      subst hop; simp [hk1B, hk2B, hmLe]
    | ed25519Verify =>
      have hop : op = 2 := by
        refine u8_eq_of_toNat op 2 (by omega) ?_
        cases ho : op.toNat with
        | zero => simp [AsymRole.decode?, ho] at hRole
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [AsymRole.decode?, ho] at hRole; rfl
      have hk2B : (k2 == 64) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat k2 64 (by omega) (by simpa [AsymRole.secondaryMaterialBytes] using hk2)
      have hmLe : mL ≤ 16777216 := by
        apply UInt64.le_iff_toNat_le.mpr; change mL.toNat ≤ 16777216
        simpa [AsymRole.maxMessageBytes] using hm
      subst hop; simp [hk1B, hk2B, hmLe]
    | x25519DerivePub =>
      have hop : op = 3 := by
        refine u8_eq_of_toNat op 3 (by omega) ?_
        cases ho : op.toNat with
        | zero => simp [AsymRole.decode?, ho] at hRole
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [AsymRole.decode?, ho] at hRole; rfl
      have hk2B : (k2 == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat k2 0 (by omega) (by simpa [AsymRole.secondaryMaterialBytes] using hk2)
      have hm0 : mL.toNat = 0 := Nat.eq_zero_of_le_zero (by simpa [AsymRole.maxMessageBytes] using hm)
      have hmB : (mL == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat mL 0 (by omega) hm0
      subst hop; simp [hk1B, hk2B, hmB]
    | x25519SharedSecret =>
      have hop : op = 4 := by
        refine u8_eq_of_toNat op 4 (by omega) ?_
        cases ho : op.toNat with
        | zero => simp [AsymRole.decode?, ho] at hRole
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [AsymRole.decode?, ho] at hRole; rfl
      have hk2B : (k2 == 32) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat k2 32 (by omega) (by simpa [AsymRole.secondaryMaterialBytes] using hk2)
      have hm0 : mL.toNat = 0 := Nat.eq_zero_of_le_zero (by simpa [AsymRole.maxMessageBytes] using hm)
      have hmB : (mL == 0) = true := by
        rw [beq_iff_eq]; exact u64_eq_of_toNat mL 0 (by omega) hm0
      subst hop; simp [hk1B, hk2B, hmB]
  posWitness := { op := 4, lens := (32, 32, 0) }
  negWitness := { op := 4, lens := (32, 0, 0) }
  nonVacuous := by decide
  tight := by decide

def asymScopedAuthority : ScopedAuthority AsymOpInput where
  admit := asymOpMetaSpec.gate
  scopeValid := AsymOpDomainSafe
  sound := asymOpMetaSpec.sound

theorem x25519_shared_secret_rejects_empty_peer (k1 msgLen : UInt64) :
    verifyAsymOp 4 k1 0 msgLen = 0 := by
  have hbad : ¬ AsymOpDomainSafe ⟨4, (k1, 0, msgLen)⟩ := by
    rintro ⟨role, hRole, _, hk2, _⟩
    cases role <;> simp [AsymRole.decode?, AsymRole.secondaryMaterialBytes] at hRole hk2
  have hf := asymOpMetaSpec.rejects_unsafe ⟨4, (k1, 0, msgLen)⟩ hbad
  unfold asymOpMetaSpec at hf; dsimp at hf
  unfold verifyAsymOp at hf ⊢
  exact bit_gate_eq_zero hf

/-! ## Spec Block 4: `OutboundRequestBoundsSpec` & `PtyWindowBoundsSpec` -/

def dnsHostnameLengthValid (n : Nat) : Prop := 1 ≤ n ∧ n ≤ 253
def tcpPortNumberValid (p : Nat) : Prop := 1 ≤ p ∧ p ≤ 65535
def maxHttpTransferBytes : Nat := 64 * 1024 * 1024

structure OutboundRequestInput where
  flags : UInt8 × UInt8
  port  : UInt32
  lens  : UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

/-- Independent outbound transport domain specification (`ScopedAuthority` + `ConservedResource`). -/
def OutboundRequestDomainSafe (x : OutboundRequestInput) : Prop :=
  x.flags.1.toNat = 1 ∧
  (x.flags.2.toNat = 0 ∨ x.flags.2.toNat = 1) ∧
  tcpPortNumberValid x.port.toNat ∧
  dnsHostnameLengthValid x.lens.1.toNat ∧
  x.lens.2.1.toNat ≤ maxHttpTransferBytes ∧
  1 ≤ x.lens.2.2.toNat ∧ x.lens.2.2.toNat ≤ maxHttpTransferBytes

@[inline, export orb_net_verify_outbound_request]
def verifyOutboundRequest
    (noHostCrLf verifyPeer : UInt8) (port : UInt32)
    (hostLen reqBytes maxRespBytes : UInt64) : UInt8 :=
  if noHostCrLf == 1 && verifyPeer ≤ 1 &&
     port ≥ 1 && port ≤ 65535 &&
     hostLen ≥ 1 && hostLen ≤ 253 &&
     reqBytes ≤ 67108864 &&
     maxRespBytes ≥ 1 && maxRespBytes ≤ 67108864 then 1 else 0

def outboundRequestMetaSpec : MetaGateSpec OutboundRequestInput OutboundRequestDomainSafe where
  gate x :=
    verifyOutboundRequest x.flags.1 x.flags.2 x.port
      x.lens.1 x.lens.2.1 x.lens.2.2 == 1
  sound x h := by
    rcases x with ⟨⟨noCrLf, vp⟩, port, ⟨hL, reqB, respB⟩⟩
    change (verifyOutboundRequest noCrLf vp port hL reqB respB == 1) = true at h
    dsimp [OutboundRequestDomainSafe]
    unfold verifyOutboundRequest at h
    have hc :
        (noCrLf == 1 && vp ≤ 1 &&
         port ≥ 1 && port ≤ 65535 &&
         hL ≥ 1 && hL ≤ 253 &&
         reqB ≤ 67108864 &&
         respB ≥ 1 && respB ≤ 67108864) = true := by
      cases hb :
          (noCrLf == 1 && vp ≤ 1 &&
           port ≥ 1 && port ≤ 65535 &&
           hL ≥ 1 && hL ≤ 253 &&
           reqB ≤ 67108864 &&
           respB ≥ 1 && respB ≤ 67108864)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨⟨hCr, hVp⟩, hp1⟩, hp2⟩, hh1⟩, hh2⟩, hreq⟩, hresp1⟩, hresp2⟩
    refine ⟨by subst hCr; rfl, u8_le_one_cases vp hVp, ?_, ?_, ?_, ?_, ?_⟩
    · exact ⟨UInt32.le_iff_toNat_le.mp hp1, UInt32.le_iff_toNat_le.mp hp2⟩
    · exact ⟨UInt64.le_iff_toNat_le.mp hh1, UInt64.le_iff_toNat_le.mp hh2⟩
    · exact UInt64.le_iff_toNat_le.mp hreq
    · exact UInt64.le_iff_toNat_le.mp hresp1
    · exact UInt64.le_iff_toNat_le.mp hresp2
  complete x h := by
    rcases x with ⟨⟨noCrLf, vp⟩, port, ⟨hL, reqB, respB⟩⟩
    change (verifyOutboundRequest noCrLf vp port hL reqB respB == 1) = true
    dsimp [OutboundRequestDomainSafe] at h
    rcases h with ⟨hCr, hVp, ⟨hp1, hp2⟩, ⟨hh1, hh2⟩, hreq, hresp1, hresp2⟩
    unfold verifyOutboundRequest
    have hCrEq : (noCrLf == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat noCrLf 1 (by omega) hCr
    have hVpLe : vp ≤ 1 := by
      apply UInt8.le_iff_toNat_le.mpr; change vp.toNat ≤ 1
      rcases hVp with h0 | h1 <;> omega
    have hpGe : port ≥ 1 := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ port.toNat; omega
    have hpLe : port ≤ 65535 := by apply UInt32.le_iff_toNat_le.mpr; change port.toNat ≤ 65535; omega
    have hhGe : hL ≥ 1 := by apply UInt64.le_iff_toNat_le.mpr; change 1 ≤ hL.toNat; omega
    have hhLe : hL ≤ 253 := by apply UInt64.le_iff_toNat_le.mpr; change hL.toNat ≤ 253; omega
    have hreqLe : reqB ≤ 67108864 := by
      apply UInt64.le_iff_toNat_le.mpr; change reqB.toNat ≤ 67108864
      unfold maxHttpTransferBytes at hreq; omega
    have hrespGe : respB ≥ 1 := by apply UInt64.le_iff_toNat_le.mpr; change 1 ≤ respB.toNat; omega
    have hrespLe : respB ≤ 67108864 := by
      apply UInt64.le_iff_toNat_le.mpr; change respB.toNat ≤ 67108864
      unfold maxHttpTransferBytes at hresp2; omega
    simp [hCrEq, hVpLe, hpGe, hpLe, hhGe, hhLe, hreqLe, hrespGe, hrespLe]
  posWitness := { flags := (1, 1), port := 443, lens := (14, 256, 1048576) }
  negWitness := { flags := (0, 1), port := 443, lens := (14, 256, 1048576) }
  nonVacuous := by decide
  tight := by decide

def outboundScopedAuthority : ScopedAuthority OutboundRequestInput where
  admit := outboundRequestMetaSpec.gate
  scopeValid x :=
    x.flags.1.toNat = 1 ∧
    (x.flags.2.toNat = 0 ∨ x.flags.2.toNat = 1) ∧
    tcpPortNumberValid x.port.toNat ∧
    dnsHostnameLengthValid x.lens.1.toNat
  sound x h := by
    have hs := outboundRequestMetaSpec.sound x h
    exact ⟨hs.1, hs.2.1, hs.2.2.1, hs.2.2.2.1⟩

def outboundConservedResource : ConservedResource OutboundRequestInput where
  admit := outboundRequestMetaSpec.gate
  withinBudget x :=
    x.lens.2.1.toNat ≤ maxHttpTransferBytes ∧
    1 ≤ x.lens.2.2.toNat ∧ x.lens.2.2.toNat ≤ maxHttpTransferBytes
  conserved x h := by
    have hs := outboundRequestMetaSpec.sound x h
    exact ⟨hs.2.2.2.2.1, hs.2.2.2.2.2.1, hs.2.2.2.2.2.2⟩

theorem outbound_request_rejects_crlf_host
    (vp : UInt8) (port : UInt32) (hL reqB respB : UInt64) :
    verifyOutboundRequest 0 vp port hL reqB respB = 0 := by
  have hbad : ¬ OutboundRequestDomainSafe ⟨(0, vp), port, (hL, reqB, respB)⟩ := by
    rintro ⟨hCr, _⟩
    cases hCr
  have hf := outboundRequestMetaSpec.rejects_unsafe ⟨(0, vp), port, (hL, reqB, respB)⟩ hbad
  unfold outboundRequestMetaSpec at hf; dsimp at hf
  unfold verifyOutboundRequest at hf ⊢
  exact bit_gate_eq_zero hf

/-- PTY terminal grid domain specification: positive cell area `rows * cols > 0`
    with each axis bounded by `1024` cells (`ConservedResource`). -/
structure PtyWindowInput where
  rows : UInt32
  cols : UInt32
  deriving Repr, DecidableEq

def PtyGridDomainSafe (w : PtyWindowInput) : Prop :=
  0 < w.rows.toNat * w.cols.toNat ∧ w.rows.toNat ≤ 1024 ∧ w.cols.toNat ≤ 1024

@[inline, export orb_net_verify_pty_window]
def verifyPtyWindow (rows cols : UInt32) : UInt8 :=
  if rows ≥ 1 && rows ≤ 1024 && cols ≥ 1 && cols ≤ 1024 then 1 else 0

def ptyWindowMetaSpec : MetaGateSpec PtyWindowInput PtyGridDomainSafe where
  gate w := verifyPtyWindow w.rows w.cols == 1
  sound w h := by
    rcases w with ⟨r, c⟩
    change (verifyPtyWindow r c == 1) = true at h
    dsimp [PtyGridDomainSafe]
    unfold verifyPtyWindow at h
    have hc : (r ≥ 1 && r ≤ 1024 && c ≥ 1 && c ≤ 1024) = true := by
      cases hb : (r ≥ 1 && r ≤ 1024 && c ≥ 1 && c ≤ 1024)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨hr1, hr2⟩, hc1⟩, hc2⟩
    have hrN1 : 1 ≤ r.toNat := UInt32.le_iff_toNat_le.mp hr1
    have hrN2 : r.toNat ≤ 1024 := UInt32.le_iff_toNat_le.mp hr2
    have hcN1 : 1 ≤ c.toNat := UInt32.le_iff_toNat_le.mp hc1
    have hcN2 : c.toNat ≤ 1024 := UInt32.le_iff_toNat_le.mp hc2
    exact ⟨Nat.mul_pos (by omega) (by omega), hrN2, hcN2⟩
  complete w h := by
    rcases w with ⟨r, c⟩
    change (verifyPtyWindow r c == 1) = true
    dsimp [PtyGridDomainSafe] at h
    rcases h with ⟨hArea, hr2, hc2⟩
    have hrPos : 1 ≤ r.toNat := by
      cases hr : r.toNat with
      | zero => simp [hr] at hArea
      | succ _ => omega
    have hcPos : 1 ≤ c.toNat := by
      cases hc : c.toNat with
      | zero => simp [hc] at hArea
      | succ _ => omega
    unfold verifyPtyWindow
    have hrGe : r ≥ 1 := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ r.toNat; omega
    have hrLe : r ≤ 1024 := by apply UInt32.le_iff_toNat_le.mpr; change r.toNat ≤ 1024; omega
    have hcGe : c ≥ 1 := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ c.toNat; omega
    have hcLe : c ≤ 1024 := by apply UInt32.le_iff_toNat_le.mpr; change c.toNat ≤ 1024; omega
    simp [hrGe, hrLe, hcGe, hcLe]
  posWitness := { rows := 24, cols := 80 }
  negWitness := { rows := 0, cols := 80 }
  nonVacuous := by decide
  tight := by decide

def ptyConservedResource : ConservedResource PtyWindowInput where
  admit := ptyWindowMetaSpec.gate
  withinBudget := PtyGridDomainSafe
  conserved := ptyWindowMetaSpec.sound

theorem pty_window_rejects_zero_area (w : PtyWindowInput)
    (h_zero : w.rows.toNat * w.cols.toNat = 0) :
    verifyPtyWindow w.rows w.cols = 0 := by
  have hbad : ¬ PtyGridDomainSafe w := fun ⟨hPos, _, _⟩ => by omega
  have hf := ptyWindowMetaSpec.rejects_unsafe w hbad
  unfold ptyWindowMetaSpec at hf; dsimp at hf
  unfold verifyPtyWindow at hf ⊢
  exact bit_gate_eq_zero hf

end OrbNetLeaf.Spec
