/-
  OrbCore.Spec: Two-Layer Non-Tautological Specifications for Wave 4 + Phase R7 Core Gateway
  (`sandboxed-sh`): Startup Secret/Dev-Mode Posture, Console WS Auth, Machine-Transfer
  Single-Active Fence, Upstream Proxy Failover, Deploy Unit Confinement, Proactive Provider Pacing,
  Remote Replay Supersession Lineage Fence, Inbox CAS, Project Context CAS, Board Track Admission,
  and Guarded Deploy Re-check.
-/
namespace OrbCore.Spec

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
    (M : MetaGateSpec Input Safe)
    (x : Input)
    (h_bad : ¬ Safe x) :
    M.gate x = false :=
  Bool.eq_false_iff.mpr (fun h_ok => h_bad (M.sound x h_ok))

/-- Layer-I `ScopedAuthority` meta-specification: admitted startup/WS/deploy ops stay within scope. -/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Prop
  sound      : ∀ x, admit x = true → scopeValid x

/-- Layer-I `StickyFence` meta-specification: admitted transfers have zero active contention fences. -/
structure StickyFence (Input : Type) where
  admit      : Input → Bool
  fenceClear : Input → Prop
  enforced   : ∀ x, admit x = true → fenceClear x

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

private theorem u64_eq_of_toNat_eq (a b : UInt64) (h : a.toNat = b.toNat) : a = b :=
  UInt64.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

private theorem bit_gate_eq_zero {c : Bool} (hf : ((if c then (1 : UInt8) else 0) == 1) = false) :
    (if c then (1 : UInt8) else 0) = 0 := by
  cases c <;> simp_all

/-! ### 1. Fail-Closed Core Startup Secret & Loopback Dev-Mode Gate -/

inductive StartupPosture where
  | productionHardened
  | developmentConstrained
  deriving Repr, DecidableEq

def StartupPosture.decode? : Nat → Option StartupPosture
  | 0 => some .productionHardened
  | 1 => some .developmentConstrained
  | _ => none

def minProdJwtSecretBytes : Nat := 32
def maxProdJwtSecretBytes : Nat := 4096

structure CoreStartupCheck where
  mode     : UInt8 × UInt8
  override : UInt8 × UInt8
  lens     : UInt32 × UInt8
  deriving Repr, DecidableEq

/-- Independent startup security posture domain model:
    all boolean flags are canonical (`0` or `1`), and there exists a `StartupPosture` such that:
    - in `.productionHardened`, the JWT secret has `32..4096` bytes, is not a known placeholder,
      and an admin password is configured;
    - in `.developmentConstrained`, either the bind host is loopback or explicit remote dev-auth
      override was set. -/
def CoreStartupDomainSafe (c : CoreStartupCheck) : Prop :=
  (c.mode.2.toNat = 0 ∨ c.mode.2.toNat = 1) ∧
  (c.override.1.toNat = 0 ∨ c.override.1.toNat = 1) ∧
  (c.override.2.toNat = 0 ∨ c.override.2.toNat = 1) ∧
  (c.lens.2.toNat = 0 ∨ c.lens.2.toNat = 1) ∧
  ∃ posture : StartupPosture,
    StartupPosture.decode? c.mode.1.toNat = some posture ∧
    match posture with
    | .productionHardened =>
      minProdJwtSecretBytes ≤ c.lens.1.toNat ∧
      c.lens.1.toNat ≤ maxProdJwtSecretBytes ∧
      c.override.2.toNat = 0 ∧
      c.lens.2.toNat = 1
    | .developmentConstrained =>
      c.mode.2.toNat = 1 ∨ c.override.1.toNat = 1

@[inline, export orb_core_verify_startup_config]
def verifyCoreStartupConfig
    (devMode isLoopbackHost allowInsecureRemoteDevAuth isPlaceholderSecret : UInt8)
    (jwtSecretLen : UInt32) (passwordConfigured : UInt8) : UInt8 :=
  if devMode ≤ 1 && isLoopbackHost ≤ 1 && allowInsecureRemoteDevAuth ≤ 1 &&
     isPlaceholderSecret ≤ 1 && passwordConfigured ≤ 1 &&
     ((devMode == 0 && jwtSecretLen ≥ 32 && jwtSecretLen ≤ 4096 &&
       isPlaceholderSecret == 0 && passwordConfigured == 1) ||
      (devMode == 1 && (isLoopbackHost == 1 || allowInsecureRemoteDevAuth == 1))) then 1 else 0

def coreStartupMetaGate : MetaGateSpec CoreStartupCheck CoreStartupDomainSafe where
  gate c :=
    verifyCoreStartupConfig c.mode.1 c.mode.2 c.override.1 c.override.2 c.lens.1 c.lens.2 == 1
  sound c h := by
    rcases c with ⟨⟨dm, lb⟩, ⟨ov, ph⟩, ⟨jl, pw⟩⟩
    change (verifyCoreStartupConfig dm lb ov ph jl pw == 1) = true at h
    dsimp [CoreStartupDomainSafe]
    unfold verifyCoreStartupConfig at h
    have hc :
        (dm ≤ 1 && lb ≤ 1 && ov ≤ 1 && ph ≤ 1 && pw ≤ 1 &&
         ((dm == 0 && jl ≥ 32 && jl ≤ 4096 && ph == 0 && pw == 1) ||
          (dm == 1 && (lb == 1 || ov == 1)))) = true := by
      cases hb :
          (dm ≤ 1 && lb ≤ 1 && ov ≤ 1 && ph ≤ 1 && pw ≤ 1 &&
           ((dm == 0 && jl ≥ 32 && jl ≤ 4096 && ph == 0 && pw == 1) ||
            (dm == 1 && (lb == 1 || ov == 1))))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨_, hlb⟩, hov⟩, hph⟩, hpw⟩, hbranch⟩
    refine ⟨u8_le_one_cases lb hlb, u8_le_one_cases ov hov,
      u8_le_one_cases ph hph, u8_le_one_cases pw hpw, ?_⟩
    rcases hbranch with ⟨⟨⟨⟨hdm0, hjl1⟩, hjl2⟩, hph0⟩, hpw1⟩ | ⟨hdm1, hdev⟩
    · refine ⟨.productionHardened, by subst hdm0; rfl,
        UInt32.le_iff_toNat_le.mp hjl1, UInt32.le_iff_toNat_le.mp hjl2,
        by subst hph0; rfl, by subst hpw1; rfl⟩
    · refine ⟨.developmentConstrained, by subst hdm1; rfl, ?_⟩
      rcases hdev with hlb1 | hov1
      · exact Or.inl (by subst hlb1; rfl)
      · exact Or.inr (by subst hov1; rfl)
  complete c h := by
    rcases c with ⟨⟨dm, lb⟩, ⟨ov, ph⟩, ⟨jl, pw⟩⟩
    change (verifyCoreStartupConfig dm lb ov ph jl pw == 1) = true
    dsimp [CoreStartupDomainSafe] at h
    rcases h with ⟨hlb, hov, hph, hpw, posture, hpost, hpbody⟩
    unfold verifyCoreStartupConfig
    have hlbLe : lb ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change lb.toNat ≤ 1; omega
    have hovLe : ov ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change ov.toNat ≤ 1; omega
    have hphLe : ph ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change ph.toNat ≤ 1; omega
    have hpwLe : pw ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change pw.toNat ≤ 1; omega
    cases posture with
    | productionHardened =>
      have hdm0 : dm = 0 := by
        refine u8_eq_of_toNat dm 0 (by omega) ?_
        cases hd : dm.toNat with
        | zero => rfl
        | succ n => rcases n with _ | _ <;> simp [StartupPosture.decode?, hd] at hpost
      rcases hpbody with ⟨hjl1, hjl2, hph0, hpw1⟩
      have hjlGe : jl ≥ 32 := by
        apply UInt32.le_iff_toNat_le.mpr; change 32 ≤ jl.toNat
        unfold minProdJwtSecretBytes at hjl1; omega
      have hjlLe : jl ≤ 4096 := by
        apply UInt32.le_iff_toNat_le.mpr; change jl.toNat ≤ 4096
        unfold maxProdJwtSecretBytes at hjl2; omega
      have hphB : (ph == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ph 0 (by omega) hph0
      have hpwB : (pw == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat pw 1 (by omega) hpw1
      subst hdm0; simp [hlbLe, hovLe, hphLe, hpwLe, hjlGe, hjlLe, hphB, hpwB]
    | developmentConstrained =>
      have hdm1 : dm = 1 := by
        refine u8_eq_of_toNat dm 1 (by omega) ?_
        cases hd : dm.toNat with
        | zero => simp [StartupPosture.decode?, hd] at hpost
        | succ n => rcases n with _ | _ <;> simp [StartupPosture.decode?, hd] at hpost; rfl
      subst hdm1
      rcases hpbody with hlb1 | hov1
      · have hlbB : (lb == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat lb 1 (by omega) hlb1
        simp [hlbLe, hovLe, hphLe, hpwLe, hlbB]
      · have hovB : (ov == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ov 1 (by omega) hov1
        simp [hlbLe, hovLe, hphLe, hpwLe, hovB]
  posWitness := { mode := (0, 0), override := (0, 0), lens := (64, 1) }
  negWitness := { mode := (1, 0), override := (0, 1), lens := (12, 0) }
  nonVacuous := by decide
  tight := by decide

theorem core_startup_rejects_remote_dev_without_override (ph : UInt8) (jl : UInt32) (pw : UInt8) :
    verifyCoreStartupConfig 1 0 0 ph jl pw = 0 := by
  have hbad : ¬ CoreStartupDomainSafe ⟨(1, 0), (0, ph), (jl, pw)⟩ := by
    rintro ⟨_, _, _, _, posture, hpost, hpbody⟩
    cases posture <;> simp [StartupPosture.decode?] at hpost hpbody
  have hf := coreStartupMetaGate.rejects_unsafe ⟨(1, 0), (0, ph), (jl, pw)⟩ hbad
  unfold coreStartupMetaGate at hf; dsimp at hf
  unfold verifyCoreStartupConfig at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 2. `:80/api/console/ws` JWT Subprotocol & Bearer Authentication Gate -/

inductive WsAuthChannel where
  | secWebsocketProtocolJwt
  | authorizationBearer
  deriving Repr, DecidableEq

structure ConsoleWsAuthCheck where
  auth   : UInt8 × UInt8
  bearer : UInt8 × UInt8
  exp    : UInt64 × UInt64
  deriving Repr, DecidableEq

/-- Independent WebSocket upgrade authentication domain model (`ScopedAuthority`):
    all boolean flags are canonical (`0` or `1`), no invalid credential is supplied on either
    channel (`hasJwtSubproto = 1 → jwtVerified = 1` and `hasBearerHeader = 1 → bearerVerified = 1`),
    credential expiry lies strictly in the future (`now + 1 ≤ exp`), and there exists a
    verified `WsAuthChannel` (either `Sec-WebSocket-Protocol` JWT or `Authorization: Bearer`). -/
def ConsoleWsAuthDomainSafe (c : ConsoleWsAuthCheck) : Prop :=
  (c.auth.1.toNat = 0 ∨ c.auth.1.toNat = 1) ∧
  (c.auth.2.toNat = 0 ∨ c.auth.2.toNat = 1) ∧
  (c.bearer.1.toNat = 0 ∨ c.bearer.1.toNat = 1) ∧
  (c.bearer.2.toNat = 0 ∨ c.bearer.2.toNat = 1) ∧
  (c.auth.1.toNat = 1 → c.auth.2.toNat = 1) ∧
  (c.bearer.1.toNat = 1 → c.bearer.2.toNat = 1) ∧
  c.exp.1.toNat + 1 ≤ c.exp.2.toNat ∧
  ∃ ch : WsAuthChannel,
    match ch with
    | .secWebsocketProtocolJwt => c.auth.1.toNat = 1 ∧ c.auth.2.toNat = 1
    | .authorizationBearer     => c.bearer.1.toNat = 1 ∧ c.bearer.2.toNat = 1

@[inline, export orb_core_verify_console_ws_auth]
def verifyConsoleWsAuth
    (hasJwtSubproto jwtVerified hasBearerHeader bearerVerified : UInt8)
    (nowEpochSec expEpochSec : UInt64) : UInt8 :=
  if hasJwtSubproto ≤ 1 && jwtVerified ≤ 1 && hasBearerHeader ≤ 1 && bearerVerified ≤ 1 &&
     (hasJwtSubproto == 0 || jwtVerified == 1) &&
     (hasBearerHeader == 0 || bearerVerified == 1) &&
     nowEpochSec < expEpochSec &&
     ((hasJwtSubproto == 1 && jwtVerified == 1) ||
      (hasBearerHeader == 1 && bearerVerified == 1)) then 1 else 0

def consoleWsAuthMetaGate : MetaGateSpec ConsoleWsAuthCheck ConsoleWsAuthDomainSafe where
  gate c :=
    verifyConsoleWsAuth c.auth.1 c.auth.2 c.bearer.1 c.bearer.2 c.exp.1 c.exp.2 == 1
  sound c h := by
    rcases c with ⟨⟨hj, jv⟩, ⟨hb, bv⟩, ⟨nowS, expS⟩⟩
    change (verifyConsoleWsAuth hj jv hb bv nowS expS == 1) = true at h
    dsimp [ConsoleWsAuthDomainSafe]
    unfold verifyConsoleWsAuth at h
    have hc :
        (hj ≤ 1 && jv ≤ 1 && hb ≤ 1 && bv ≤ 1 &&
         (hj == 0 || jv == 1) && (hb == 0 || bv == 1) &&
         nowS < expS && ((hj == 1 && jv == 1) || (hb == 1 && bv == 1))) = true := by
      cases hcond :
          (hj ≤ 1 && jv ≤ 1 && hb ≤ 1 && bv ≤ 1 &&
           (hj == 0 || jv == 1) && (hb == 0 || bv == 1) &&
           nowS < expS && ((hj == 1 && jv == 1) || (hb == 1 && bv == 1)))
      · rw [hcond] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨hhj1, hjv1⟩, hhb1⟩, hbv1⟩, hjImp⟩, hbImp⟩, hlt⟩, hch⟩
    have hltN : nowS.toNat < expS.toNat := UInt64.lt_iff_toNat_lt.mp hlt
    have hjOk : hj.toNat = 1 → jv.toNat = 1 := by
      intro h1; rcases hjImp with h0 | hv
      · subst h0; simp at h1
      · subst hv; rfl
    have hbOk : hb.toNat = 1 → bv.toNat = 1 := by
      intro h1; rcases hbImp with h0 | hv
      · subst h0; simp at h1
      · subst hv; rfl
    refine ⟨u8_le_one_cases hj hhj1, u8_le_one_cases jv hjv1,
            u8_le_one_cases hb hhb1, u8_le_one_cases bv hbv1,
            hjOk, hbOk, by omega, ?_⟩
    rcases hch with ⟨hhj, hjv⟩ | ⟨hhb, hbv⟩
    · exact ⟨.secWebsocketProtocolJwt, by subst hhj; rfl, by subst hjv; rfl⟩
    · exact ⟨.authorizationBearer, by subst hhb; rfl, by subst hbv; rfl⟩
  complete c h := by
    rcases c with ⟨⟨hj, jv⟩, ⟨hb, bv⟩, ⟨nowS, expS⟩⟩
    change (verifyConsoleWsAuth hj jv hb bv nowS expS == 1) = true
    dsimp [ConsoleWsAuthDomainSafe] at h
    rcases h with ⟨hhj1, hjv1, hhb1, hbv1, hjImp, hbImp, hlt, ch, hch⟩
    unfold verifyConsoleWsAuth
    have hhjLe : hj ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change hj.toNat ≤ 1; omega
    have hjvLe : jv ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change jv.toNat ≤ 1; omega
    have hhbLe : hb ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change hb.toNat ≤ 1; omega
    have hbvLe : bv ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change bv.toNat ≤ 1; omega
    have hjDisj : (hj == 0 || jv == 1) = true := by
      rcases hhj1 with h0 | h1
      · have hB : (hj == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hj 0 (by omega) h0
        simp [hB]
      · have hv1 := hjImp h1
        have hB : (jv == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat jv 1 (by omega) hv1
        simp [hB]
    have hbDisj : (hb == 0 || bv == 1) = true := by
      rcases hhb1 with h0 | h1
      · have hB : (hb == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hb 0 (by omega) h0
        simp [hB]
      · have hv1 := hbImp h1
        have hB : (bv == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bv 1 (by omega) hv1
        simp [hB]
    have hltB : nowS < expS := by apply UInt64.lt_iff_toNat_lt.mpr; omega
    cases ch with
    | secWebsocketProtocolJwt =>
      rcases hch with ⟨hhj, hjv⟩
      have hhjB : (hj == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hj 1 (by omega) hhj
      have hjvB : (jv == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat jv 1 (by omega) hjv
      simp [hhjLe, hjvLe, hhbLe, hbvLe, hbDisj, hltB, hhjB, hjvB]
    | authorizationBearer =>
      rcases hch with ⟨hhb, hbv⟩
      have hhbB : (hb == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hb 1 (by omega) hhb
      have hbvB : (bv == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bv 1 (by omega) hbv
      simp [hhjLe, hjvLe, hhbLe, hbvLe, hjDisj, hltB, hhbB, hbvB]
  posWitness := { auth := (1, 1), bearer := (0, 0), exp := (1700000000, 1700003600) }
  negWitness := { auth := (1, 1), bearer := (1, 0), exp := (1700000000, 1700003600) }
  nonVacuous := by decide
  tight := by decide

/-! ### 3. Machine-Transfer Single-Active Fence & Optimistic Revision Gate -/

def u64MaxNat : Nat := 18446744073709551615

structure TransferFenceCheck where
  fences        : UInt8 × UInt8 × UInt8
  revs          : UInt64 × UInt64
  statusMovable : UInt8
  deriving Repr, DecidableEq

/-- Independent `StickyFence` domain model over additive contention sum & optimistic CAS headroom:
    total active contention (`activeTransfer + nonTerminalRun + workspaceContended`) equals `0`,
    the mission state is movable (`statusMovable = 1`), stored & expected generations match,
    and incrementing generation (`stored + 1 ≤ u64MaxNat`) cannot wrap `UInt64`. -/
def TransferFenceDomainSafe (c : TransferFenceCheck) : Prop :=
  c.fences.1.toNat + c.fences.2.1.toNat + c.fences.2.2.toNat = 0 ∧
  c.statusMovable.toNat = 1 ∧
  c.revs.1.toNat = c.revs.2.toNat ∧
  c.revs.1.toNat + 1 ≤ u64MaxNat

@[inline, export orb_core_verify_transfer_fence]
def verifyTransferFence
    (activeTransferExists nonTerminalRunExists workspaceContended statusMovable : UInt8)
    (storedGeneration expectedGeneration : UInt64) : UInt8 :=
  if activeTransferExists == 0 && nonTerminalRunExists == 0 && workspaceContended == 0 &&
     statusMovable == 1 && storedGeneration == expectedGeneration &&
     storedGeneration < 0xFFFFFFFFFFFFFFFF then 1 else 0

def transferFenceMetaGate : MetaGateSpec TransferFenceCheck TransferFenceDomainSafe where
  gate c :=
    verifyTransferFence c.fences.1 c.fences.2.1 c.fences.2.2 c.statusMovable c.revs.1 c.revs.2 == 1
  sound c h := by
    rcases c with ⟨⟨atf, ntr, wc⟩, ⟨sg, eg⟩, sm⟩
    change (verifyTransferFence atf ntr wc sm sg eg == 1) = true at h
    dsimp [TransferFenceDomainSafe]
    unfold verifyTransferFence at h
    have hc :
        (atf == 0 && ntr == 0 && wc == 0 && sm == 1 && sg == eg && sg < 0xFFFFFFFFFFFFFFFF) = true := by
      cases hb : (atf == 0 && ntr == 0 && wc == 0 && sm == 1 && sg == eg && sg < 0xFFFFFFFFFFFFFFFF)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hat, hnt⟩, hwc⟩, hsm⟩, hrev⟩, hlt⟩
    have hltN : sg.toNat < u64MaxNat := UInt64.lt_iff_toNat_lt.mp hlt
    subst hat; subst hnt
    subst hwc; subst hsm
    subst hrev
    exact ⟨rfl, rfl, rfl, by omega⟩
  complete c h := by
    rcases c with ⟨⟨atf, ntr, wc⟩, ⟨sg, eg⟩, sm⟩
    change (verifyTransferFence atf ntr wc sm sg eg == 1) = true
    dsimp [TransferFenceDomainSafe] at h
    rcases h with ⟨hsum, hsm, hrev, hlt⟩
    unfold verifyTransferFence
    have hatB : (atf == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat atf 0 (by omega) (by omega)
    have hntB : (ntr == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ntr 0 (by omega) (by omega)
    have hwcB : (wc == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wc 0 (by omega) (by omega)
    have hsmB : (sm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat sm 1 (by omega) hsm
    have hrevB : (sg == eg) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq sg eg hrev
    have hltB : sg < 0xFFFFFFFFFFFFFFFF := by
      apply UInt64.lt_iff_toNat_lt.mpr
      change sg.toNat < 18446744073709551615
      unfold u64MaxNat at hlt; omega
    simp [hatB, hntB, hwcB, hsmB, hrevB, hltB]
  posWitness := { fences := (0, 0, 0), revs := (4, 4), statusMovable := 1 }
  negWitness := { fences := (1, 0, 0), revs := (4, 4), statusMovable := 1 }
  nonVacuous := by decide
  tight := by decide

def transferStickyFence : StickyFence TransferFenceCheck where
  admit := transferFenceMetaGate.gate
  fenceClear c := c.fences.1.toNat = 0 ∧ c.fences.2.1.toNat = 0 ∧ c.fences.2.2.toNat = 0
  enforced c h := by
    rcases transferFenceMetaGate.sound c h with ⟨hsum, _, _, _⟩
    omega

/-! ### 4. `/v1/*` Model-Routing & Provider Failover Step Gate -/

inductive UpstreamFailureClass where
  | outOfCredit402
  | rateLimited429
  | serverError5xx (code : Nat)
  /-- The target cannot serve this request (unknown model, wrong endpoint, dead login,
      rejected parameters): the next target of the same chain may. -/
  | unservable4xx (code : Nat)
  deriving Repr, DecidableEq

def UpstreamFailureClass.classifyRetryable? (code : Nat) : Option UpstreamFailureClass :=
  if code = 402 then some .outOfCredit402
  else if code = 429 then some .rateLimited429
  else if 500 ≤ code ∧ code ≤ 599 then some (.serverError5xx code)
  else if 400 ≤ code ∧ code ≤ 499 then some (.unservable4xx code)
  else none

structure ProxyFailoverCheck where
  chain            : UInt8 × UInt8
  upstreamStatus   : UInt32
  headersCommitted : UInt8
  deriving Repr, DecidableEq

/-- Independent provider-failover domain specification:
    the fallback chain has `1..16` candidates, at least one unvisited fallback candidate remains
    (`attemptIdx + 1 < chainLen` in `Nat`, overflow-free), downstream response headers have not yet
    been committed (`headersCommitted = 0`), and `UpstreamFailureClass.classifyRetryable?` succeeds
    (any upstream `400..599`: nothing has reached the client, so another target of the chain the
    caller named may serve the request, as the Rust proxy did). -/
def ProxyFailoverDomainSafe (c : ProxyFailoverCheck) : Prop :=
  1 ≤ c.chain.2.toNat ∧
  c.chain.2.toNat ≤ 16 ∧
  c.chain.1.toNat + 1 < c.chain.2.toNat ∧
  c.headersCommitted.toNat = 0 ∧
  (UpstreamFailureClass.classifyRetryable? c.upstreamStatus.toNat).isSome = true

@[inline, export orb_core_verify_proxy_failover]
def verifyProxyFailoverStep
    (attemptIdx chainLen : UInt8) (upstreamStatus : UInt32) (headersCommitted : UInt8) : UInt8 :=
  if chainLen ≥ 1 && chainLen ≤ 16 &&
     attemptIdx < 16 && attemptIdx + 1 < chainLen &&
     headersCommitted == 0 &&
     (upstreamStatus ≥ 400 && upstreamStatus ≤ 599) then 1 else 0

def proxyFailoverMetaGate : MetaGateSpec ProxyFailoverCheck ProxyFailoverDomainSafe where
  gate c :=
    verifyProxyFailoverStep c.chain.1 c.chain.2 c.upstreamStatus c.headersCommitted == 1
  sound c h := by
    rcases c with ⟨⟨att, clen⟩, st, hcFlag⟩
    change (verifyProxyFailoverStep att clen st hcFlag == 1) = true at h
    dsimp [ProxyFailoverDomainSafe]
    unfold verifyProxyFailoverStep at h
    have hc :
        (clen ≥ 1 && clen ≤ 16 && att < 16 && att + 1 < clen && hcFlag == 0 &&
         (st ≥ 400 && st ≤ 599)) = true := by
      cases hb :
          (clen ≥ 1 && clen ≤ 16 && att < 16 && att + 1 < clen && hcFlag == 0 &&
           (st ≥ 400 && st ≤ 599))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hcl1, hcl2⟩, hatt16⟩, hatt⟩, hcomm⟩, ⟨h400, h599⟩⟩
    have hclN1 : 1 ≤ clen.toNat := UInt8.le_iff_toNat_le.mp hcl1
    have hclN2 : clen.toNat ≤ 16 := UInt8.le_iff_toNat_le.mp hcl2
    have hattN16 : att.toNat < 16 := UInt8.lt_iff_toNat_lt.mp hatt16
    have hattMod : (att.toNat + 1) % 256 < clen.toNat := UInt8.lt_iff_toNat_lt.mp hatt
    have hattNat : att.toNat + 1 < clen.toNat := by omega
    refine ⟨hclN1, hclN2, hattNat, by subst hcomm; rfl, ?_⟩
    have hs1 : 400 ≤ st.toNat := UInt32.le_iff_toNat_le.mp h400
    have hs2 : st.toNat ≤ 599 := UInt32.le_iff_toNat_le.mp h599
    unfold UpstreamFailureClass.classifyRetryable?
    split
    · rfl
    · split
      · rfl
      · split
        · rfl
        · split
          · rfl
          · exfalso; omega
  complete c h := by
    rcases c with ⟨⟨att, clen⟩, st, hcFlag⟩
    change (verifyProxyFailoverStep att clen st hcFlag == 1) = true
    dsimp [ProxyFailoverDomainSafe] at h
    rcases h with ⟨hcl1, hcl2, hatt, hcomm, hst⟩
    unfold verifyProxyFailoverStep
    have hclGe : clen ≥ 1 := by apply UInt8.le_iff_toNat_le.mpr; change 1 ≤ clen.toNat; omega
    have hclLe : clen ≤ 16 := by apply UInt8.le_iff_toNat_le.mpr; change clen.toNat ≤ 16; omega
    have hatt16 : att < 16 := by apply UInt8.lt_iff_toNat_lt.mpr; change att.toNat < 16; omega
    have hattB : att + 1 < clen := by
      apply UInt8.lt_iff_toNat_lt.mpr
      change (att.toNat + 1) % 256 < clen.toNat
      omega
    have hcommB : (hcFlag == 0) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat hcFlag 0 (by omega) hcomm
    have hb : 400 ≤ st.toNat ∧ st.toNat ≤ 599 := by
      unfold UpstreamFailureClass.classifyRetryable? at hst
      split at hst
      · omega
      · split at hst
        · omega
        · split at hst
          · omega
          · split at hst
            · omega
            · contradiction
    have h400 : st ≥ 400 := by apply UInt32.le_iff_toNat_le.mpr; change 400 ≤ st.toNat; exact hb.1
    have h599 : st ≤ 599 := by apply UInt32.le_iff_toNat_le.mpr; change st.toNat ≤ 599; exact hb.2
    simp [hclGe, hclLe, hatt16, hattB, hcommB, h400, h599]
  posWitness := { chain := (0, 3), upstreamStatus := 402, headersCommitted := 0 }
  negWitness := { chain := (0, 3), upstreamStatus := 402, headersCommitted := 1 }
  nonVacuous := by decide
  tight := by decide

/-! ### 5. `sandboxed-sh deploy --service <unit>` Allowlist Gate -/

inductive ManagedSystemdUnit where
  | sandboxedSh
  | sandboxedNode
  | orbPrivd
  deriving Repr, DecidableEq

def ManagedSystemdUnit.decode? : Nat → Option ManagedSystemdUnit
  | 1 => some .sandboxedSh
  | 2 => some .sandboxedNode
  | 3 => some .orbPrivd
  | _ => none

/-- Accepted alias length bounds for each `ManagedSystemdUnit` (e.g. `"orb-core"` = 8 ..
    `"sandboxed-sh-prod.service"` = 25). -/
def ManagedSystemdUnit.minAliasBytes : ManagedSystemdUnit → Nat
  | .sandboxedSh   => 8  -- "orb-core"
  | .sandboxedNode => 8  -- "orb-node"
  | .orbPrivd      => 9  -- "orb-privd"

def ManagedSystemdUnit.maxAliasBytes : ManagedSystemdUnit → Nat
  | .sandboxedSh   => 25 -- "sandboxed-sh-prod.service"
  | .sandboxedNode => 22 -- "sandboxed-node.service"
  | .orbPrivd      => 17 -- "orb-privd.service"

structure DeployUnitCheck where
  unitCode         : UInt8
  hasPathTraversal : UInt8
  unitLen          : UInt32
  deriving Repr, DecidableEq

/-- Independent `ScopedAuthority` allowlist model for `sandboxed-sh deploy --service`:
    there exists a `ManagedSystemdUnit` matching `unitCode`, zero path-traversal characters
    (`/` or `..`) are present, and `unitLen` falls within that unit's exact alias bounds. -/
def DeployUnitDomainSafe (c : DeployUnitCheck) : Prop :=
  c.hasPathTraversal.toNat = 0 ∧
  ∃ u : ManagedSystemdUnit,
    ManagedSystemdUnit.decode? c.unitCode.toNat = some u ∧
    u.minAliasBytes ≤ c.unitLen.toNat ∧
    c.unitLen.toNat ≤ u.maxAliasBytes

@[inline, export orb_core_verify_deploy_unit]
def verifyDeployUnitName (unitCode hasPathTraversal : UInt8) (unitLen : UInt32) : UInt8 :=
  if hasPathTraversal == 0 &&
     ((unitCode == 1 && unitLen ≥ 8 && unitLen ≤ 25) ||
      (unitCode == 2 && unitLen ≥ 8 && unitLen ≤ 22) ||
      (unitCode == 3 && unitLen ≥ 9 && unitLen ≤ 17)) then 1 else 0

def deployUnitMetaGate : MetaGateSpec DeployUnitCheck DeployUnitDomainSafe where
  gate c := verifyDeployUnitName c.unitCode c.hasPathTraversal c.unitLen == 1
  sound c h := by
    rcases c with ⟨uc, pt, uL⟩
    change (verifyDeployUnitName uc pt uL == 1) = true at h
    dsimp [DeployUnitDomainSafe]
    unfold verifyDeployUnitName at h
    have hc :
        (pt == 0 &&
         ((uc == 1 && uL ≥ 8 && uL ≤ 25) ||
          (uc == 2 && uL ≥ 8 && uL ≤ 22) ||
          (uc == 3 && uL ≥ 9 && uL ≤ 17))) = true := by
      cases hb :
          (pt == 0 &&
           ((uc == 1 && uL ≥ 8 && uL ≤ 25) ||
            (uc == 2 && uL ≥ 8 && uL ≤ 22) ||
            (uc == 3 && uL ≥ 9 && uL ≤ 17)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨hpt, (⟨⟨h1, hl1⟩, hl2⟩ | ⟨⟨h2, hl1⟩, hl2⟩) | ⟨⟨h3, hl1⟩, hl2⟩⟩
    · subst hpt; subst h1
      exact ⟨rfl, .sandboxedSh, rfl, UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2⟩
    · subst hpt; subst h2
      exact ⟨rfl, .sandboxedNode, rfl, UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2⟩
    · subst hpt; subst h3
      exact ⟨rfl, .orbPrivd, rfl, UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2⟩
  complete c h := by
    rcases c with ⟨uc, pt, uL⟩
    change (verifyDeployUnitName uc pt uL == 1) = true
    dsimp [DeployUnitDomainSafe] at h
    rcases h with ⟨hpt, u, hdec, hl1, hl2⟩
    unfold verifyDeployUnitName
    have hptB : (pt == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat pt 0 (by omega) hpt
    cases hu : uc.toNat with
    | zero => simp [ManagedSystemdUnit.decode?, hu] at hdec
    | succ n =>
      rcases n with _ | _ | _ | _
      · simp [ManagedSystemdUnit.decode?, hu] at hdec
        subst hdec
        have hucB : (uc == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat uc 1 (by omega) hu
        have hge : uL ≥ 8 := UInt32.le_iff_toNat_le.mpr hl1
        have hle : uL ≤ 25 := UInt32.le_iff_toNat_le.mpr hl2
        simp [hptB, hucB, hge, hle]
      · simp [ManagedSystemdUnit.decode?, hu] at hdec
        subst hdec
        have hucB : (uc == 2) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat uc 2 (by omega) hu
        have hge : uL ≥ 8 := UInt32.le_iff_toNat_le.mpr hl1
        have hle : uL ≤ 22 := UInt32.le_iff_toNat_le.mpr hl2
        simp [hptB, hucB, hge, hle]
      · simp [ManagedSystemdUnit.decode?, hu] at hdec
        subst hdec
        have hucB : (uc == 3) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat uc 3 (by omega) hu
        have hge : uL ≥ 9 := UInt32.le_iff_toNat_le.mpr hl1
        have hle : uL ≤ 17 := UInt32.le_iff_toNat_le.mpr hl2
        simp [hptB, hucB, hge, hle]
      · simp [ManagedSystemdUnit.decode?, hu] at hdec
  posWitness := { unitCode := 1, hasPathTraversal := 0, unitLen := 12 }
  negWitness := { unitCode := 1, hasPathTraversal := 0, unitLen := 3 }
  nonVacuous := by decide
  tight := by decide

def deployUnitScopedAuthority : ScopedAuthority DeployUnitCheck where
  admit := deployUnitMetaGate.gate
  scopeValid c := (ManagedSystemdUnit.decode? c.unitCode.toNat).isSome = true ∧ c.hasPathTraversal.toNat = 0
  sound c h := by
    rcases deployUnitMetaGate.sound c h with ⟨hpt, u, hdec, _, _⟩
    exact ⟨by simp [hdec], hpt⟩

/-! ### 6. Proactive Provider Rate-Limit & Concurrency Pacing Gate -/

def maxConfiguredRpmCap : Nat := 100000
def maxConfiguredConcCap : Nat := 1024

inductive PacingCapPolicy where
  | uncapped
  | bounded (limit : Nat)
  deriving Repr, DecidableEq

def PacingCapPolicy.decode? (raw maxAllowed : Nat) : Option PacingCapPolicy :=
  if raw = 0 then some .uncapped
  else if 1 ≤ raw ∧ raw ≤ maxAllowed then some (.bounded raw)
  else none

def PacingCapPolicy.admitsNext (p : PacingCapPolicy) (used : Nat) : Prop :=
  match p with
  | .uncapped      => True
  | .bounded limit => used + 1 ≤ limit

structure ProviderPacingCheck where
  accountCaps : UInt32 × UInt32
  modelCaps   : UInt32 × UInt32
  accountLoad : UInt32 × UInt32
  modelLoad   : UInt32 × UInt32
  deriving Repr, DecidableEq

/-- Independent provider pacing admission domain model over typed `PacingCapPolicy` budgets:
    account and per-model RPM (`0` or `1..100000`) and concurrency (`0` or `1..1024`) caps decode
    to valid `PacingCapPolicy` values, and every bounded dimension has strict headroom (`used + 1 ≤ limit`)
    for the next request. -/
def ProviderPacingDomainSafe (c : ProviderPacingCheck) : Prop :=
  ∃ ar ac mr mc : PacingCapPolicy,
    PacingCapPolicy.decode? c.accountCaps.1.toNat maxConfiguredRpmCap = some ar ∧
    PacingCapPolicy.decode? c.accountCaps.2.toNat maxConfiguredConcCap = some ac ∧
    PacingCapPolicy.decode? c.modelCaps.1.toNat maxConfiguredRpmCap = some mr ∧
    PacingCapPolicy.decode? c.modelCaps.2.toNat maxConfiguredConcCap = some mc ∧
    ar.admitsNext c.accountLoad.1.toNat ∧
    ac.admitsNext c.accountLoad.2.toNat ∧
    mr.admitsNext c.modelLoad.1.toNat ∧
    mc.admitsNext c.modelLoad.2.toNat

@[inline]
def singleCapAdmitted (cap maxCap used : UInt32) : Bool :=
  cap == 0 || (cap ≥ 1 && cap ≤ maxCap && used < cap)

private theorem singleCapAdmitted_sound (cap maxCap used : UInt32)
    (h : singleCapAdmitted cap maxCap used = true) :
    ∃ p : PacingCapPolicy,
      PacingCapPolicy.decode? cap.toNat maxCap.toNat = some p ∧
      p.admitsNext used.toNat := by
  unfold singleCapAdmitted at h
  simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at h
  rcases h with h0 | ⟨⟨hge, hle⟩, hlt⟩
  · subst h0
    exact ⟨.uncapped, rfl, trivial⟩
  · have hc1 : 1 ≤ cap.toNat := UInt32.le_iff_toNat_le.mp hge
    have hc2 : cap.toNat ≤ maxCap.toNat := UInt32.le_iff_toNat_le.mp hle
    have hu : used.toNat < cap.toNat := UInt32.lt_iff_toNat_lt.mp hlt
    have hne0 : cap.toNat ≠ 0 := by omega
    refine ⟨.bounded cap.toNat, ?_, ?_⟩
    · simp [PacingCapPolicy.decode?, hne0, hc1, hc2]
    · dsimp [PacingCapPolicy.admitsNext]
      omega

private theorem singleCapAdmitted_complete (cap maxCap used : UInt32)
    (p : PacingCapPolicy)
    (hdec : PacingCapPolicy.decode? cap.toNat maxCap.toNat = some p)
    (hadm : p.admitsNext used.toNat) :
    singleCapAdmitted cap maxCap used = true := by
  unfold singleCapAdmitted
  unfold PacingCapPolicy.decode? at hdec
  split at hdec
  · rename_i hz
    have hc0 : (cap == 0) = true := by
      rw [beq_iff_eq]
      apply UInt32.eq_of_toBitVec_eq
      apply BitVec.eq_of_toNat_eq
      change cap.toNat = 0
      exact hz
    simp [hc0]
  · split at hdec
    · rename_i hbnd
      injection hdec with hp
      subst hp
      dsimp [PacingCapPolicy.admitsNext] at hadm
      have hge : cap ≥ 1 := UInt32.le_iff_toNat_le.mpr hbnd.1
      have hle : cap ≤ maxCap := UInt32.le_iff_toNat_le.mpr hbnd.2
      have hlt : used < cap := by
        apply UInt32.lt_iff_toNat_lt.mpr
        omega
      simp [hge, hle, hlt]
    · contradiction

@[inline, export orb_core_verify_provider_pacing]
def verifyProviderPacingAdmission
    (acctRpmCap acctConcCap modelRpmCap modelConcCap : UInt32)
    (acctRpmUsed acctInflight modelRpmUsed modelInflight : UInt32) : UInt8 :=
  if singleCapAdmitted acctRpmCap 100000 acctRpmUsed &&
     singleCapAdmitted acctConcCap 1024 acctInflight &&
     singleCapAdmitted modelRpmCap 100000 modelRpmUsed &&
     singleCapAdmitted modelConcCap 1024 modelInflight then 1 else 0

def providerPacingMetaGate : MetaGateSpec ProviderPacingCheck ProviderPacingDomainSafe where
  gate c :=
    verifyProviderPacingAdmission
      c.accountCaps.1 c.accountCaps.2 c.modelCaps.1 c.modelCaps.2
      c.accountLoad.1 c.accountLoad.2 c.modelLoad.1 c.modelLoad.2 == 1
  sound c h := by
    rcases c with ⟨⟨arC, acC⟩, ⟨mrC, mcC⟩, ⟨arU, acU⟩, ⟨mrU, mcU⟩⟩
    change (verifyProviderPacingAdmission arC acC mrC mcC arU acU mrU mcU == 1) = true at h
    dsimp [ProviderPacingDomainSafe]
    unfold verifyProviderPacingAdmission at h
    have hc :
        (singleCapAdmitted arC 100000 arU &&
         singleCapAdmitted acC 1024 acU &&
         singleCapAdmitted mrC 100000 mrU &&
         singleCapAdmitted mcC 1024 mcU) = true := by
      cases hb :
          (singleCapAdmitted arC 100000 arU &&
           singleCapAdmitted acC 1024 acU &&
           singleCapAdmitted mrC 100000 mrU &&
           singleCapAdmitted mcC 1024 mcU)
      · rw [hb] at h
        contradiction
      · rfl
    simp only [Bool.and_eq_true] at hc
    rcases hc with ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩
    rcases singleCapAdmitted_sound arC 100000 arU h1 with ⟨ar, har1, har2⟩
    rcases singleCapAdmitted_sound acC 1024 acU h2 with ⟨ac, hac1, hac2⟩
    rcases singleCapAdmitted_sound mrC 100000 mrU h3 with ⟨mr, hmr1, hmr2⟩
    rcases singleCapAdmitted_sound mcC 1024 mcU h4 with ⟨mc, hmc1, hmc2⟩
    exact ⟨ar, ac, mr, mc, har1, hac1, hmr1, hmc1, har2, hac2, hmr2, hmc2⟩
  complete c h := by
    rcases c with ⟨⟨arC, acC⟩, ⟨mrC, mcC⟩, ⟨arU, acU⟩, ⟨mrU, mcU⟩⟩
    change (verifyProviderPacingAdmission arC acC mrC mcC arU acU mrU mcU == 1) = true
    dsimp [ProviderPacingDomainSafe] at h
    rcases h with ⟨ar, ac, mr, mc, har1, hac1, hmr1, hmc1, har2, hac2, hmr2, hmc2⟩
    unfold verifyProviderPacingAdmission
    have b1 : singleCapAdmitted arC 100000 arU = true := singleCapAdmitted_complete arC 100000 arU ar har1 har2
    have b2 : singleCapAdmitted acC 1024 acU = true := singleCapAdmitted_complete acC 1024 acU ac hac1 hac2
    have b3 : singleCapAdmitted mrC 100000 mrU = true := singleCapAdmitted_complete mrC 100000 mrU mr hmr1 hmr2
    have b4 : singleCapAdmitted mcC 1024 mcU = true := singleCapAdmitted_complete mcC 1024 mcU mc hmc1 hmc2
    simp [b1, b2, b3, b4]
  posWitness := {
    accountCaps := (300, 0)
    modelCaps   := (60, 2)
    accountLoad := (42, 1)
    modelLoad   := (10, 1)
  }
  negWitness := {
    accountCaps := (300, 0)
    modelCaps   := (0, 2)
    accountLoad := (2, 2)
    modelLoad   := (2, 2)
  }
  nonVacuous := by decide
  tight := by decide

/-! ### 7. Remote Replay Supersession & Aborted-Pre-Dispatch Lineage Fence -/

/-- Independent domain ADT classifying why a `RemoteWait` entry remains unsuperseded:
    - `.exactFailedJob`: `placementJobHash` still equals the originally armed `failedJobHash`.
    - `.abortedPreDispatchChain`: an earlier scheduled replay bound a tentative `placementJobHash`
      that terminated pre-dispatch (`latestRunTerminal == 1`, `latestRunDispatchFailed == 1`) with
      matching `latestRunJobHash == placementJobHash` before any remote runner accepted execution.
    Any manual/user resume or live run breaks both lineages and permanently supersedes the wait. -/
inductive ReplayLineageKind where
  | exactFailedJob
  | abortedPreDispatchChain
  deriving Repr, DecidableEq

structure RemoteReplaySupersessionCheck where
  flags     : UInt8 × UInt8
  runFlags  : UInt8 × UInt8
  placement : UInt64 × UInt64
  latestJob : UInt64
  deriving Repr, DecidableEq

def RemoteReplaySupersessionDomainSafe (c : RemoteReplaySupersessionCheck) : Prop :=
  c.flags.1.toNat = 1 ∧
  c.flags.2.toNat = 1 ∧
  (c.runFlags.1.toNat = 0 ∨ c.runFlags.1.toNat = 1) ∧
  (c.runFlags.2.toNat = 0 ∨ c.runFlags.2.toNat = 1) ∧
  c.placement.1.toNat > 0 ∧
  c.placement.2.toNat > 0 ∧
  ∃ kind : ReplayLineageKind,
    match kind with
    | .exactFailedJob =>
      c.placement.1.toNat = c.placement.2.toNat
    | .abortedPreDispatchChain =>
      c.runFlags.1.toNat = 1 ∧
      c.runFlags.2.toNat = 1 ∧
      c.latestJob.toNat > 0 ∧
      c.latestJob.toNat = c.placement.1.toNat

@[inline, export orb_core_verify_remote_replay_supersession]
def verifyRemoteReplaySupersession
    (waitArmed nodeMatches latestRunTerminal latestRunDispatchFailed : UInt8)
    (placementJobHash failedJobHash latestRunJobHash : UInt64) : UInt8 :=
  if waitArmed == 1 && nodeMatches == 1 &&
     latestRunTerminal ≤ 1 && latestRunDispatchFailed ≤ 1 &&
     placementJobHash > 0 && failedJobHash > 0 &&
     (placementJobHash == failedJobHash ||
      (latestRunTerminal == 1 && latestRunDispatchFailed == 1 &&
       latestRunJobHash > 0 && latestRunJobHash == placementJobHash)) then 1 else 0

def remoteReplaySupersessionMetaGate :
    MetaGateSpec RemoteReplaySupersessionCheck RemoteReplaySupersessionDomainSafe where
  gate c :=
    verifyRemoteReplaySupersession
      c.flags.1 c.flags.2 c.runFlags.1 c.runFlags.2
      c.placement.1 c.placement.2 c.latestJob == 1
  sound c h := by
    rcases c with ⟨⟨wa, nm⟩, ⟨rt, df⟩, ⟨pj, fj⟩, lj⟩
    change (verifyRemoteReplaySupersession wa nm rt df pj fj lj == 1) = true at h
    dsimp [RemoteReplaySupersessionDomainSafe]
    unfold verifyRemoteReplaySupersession at h
    have hc :
        (wa == 1 && nm == 1 &&
         rt ≤ 1 && df ≤ 1 &&
         pj > 0 && fj > 0 &&
         (pj == fj ||
          (rt == 1 && df == 1 && lj > 0 && lj == pj))) = true := by
      cases hb :
          (wa == 1 && nm == 1 &&
           rt ≤ 1 && df ≤ 1 &&
           pj > 0 && fj > 0 &&
           (pj == fj ||
            (rt == 1 && df == 1 && lj > 0 && lj == pj)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨hwa, hnm⟩, hrt⟩, hdf⟩, hpj⟩, hfj⟩, hlin⟩
    subst hwa; subst hnm
    have hpjN : pj.toNat > 0 := UInt64.lt_iff_toNat_lt.mp hpj
    have hfjN : fj.toNat > 0 := UInt64.lt_iff_toNat_lt.mp hfj
    refine ⟨rfl, rfl, u8_le_one_cases rt hrt, u8_le_one_cases df hdf, hpjN, hfjN, ?_⟩
    rcases hlin with heq | ⟨⟨⟨hrt1, hdf1⟩, hlj⟩, hljp⟩
    · exact ⟨.exactFailedJob, by subst heq; rfl⟩
    · subst hrt1; subst hdf1; subst hljp
      exact ⟨.abortedPreDispatchChain, rfl, rfl, UInt64.lt_iff_toNat_lt.mp hlj, rfl⟩
  complete c h := by
    rcases c with ⟨⟨wa, nm⟩, ⟨rt, df⟩, ⟨pj, fj⟩, lj⟩
    change (verifyRemoteReplaySupersession wa nm rt df pj fj lj == 1) = true
    dsimp [RemoteReplaySupersessionDomainSafe] at h
    rcases h with ⟨hwa, hnm, hrt, hdf, hpj, hfj, kind, hkind⟩
    unfold verifyRemoteReplaySupersession
    have hwaB : (wa == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat wa 1 (by omega) hwa
    have hnmB : (nm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat nm 1 (by omega) hnm
    have hrtL : rt ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change rt.toNat ≤ 1; omega
    have hdfL : df ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change df.toNat ≤ 1; omega
    have hpjB : pj > 0 := UInt64.lt_iff_toNat_lt.mpr hpj
    have hfjB : fj > 0 := UInt64.lt_iff_toNat_lt.mpr hfj
    cases kind with
    | exactFailedJob =>
      have hpjf : (pj == fj) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq pj fj hkind
      simp [hwaB, hnmB, hrtL, hdfL, hpjB, hfjB, hpjf]
    | abortedPreDispatchChain =>
      rcases hkind with ⟨hrt1, hdf1, hlj, hljp⟩
      have hrtB : (rt == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat rt 1 (by omega) hrt1
      have hdfB : (df == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat df 1 (by omega) hdf1
      have hljB : lj > 0 := UInt64.lt_iff_toNat_lt.mpr hlj
      have hljpB : (lj == pj) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq lj pj hljp
      simp [hwaB, hnmB, hrtL, hdfL, hpjB, hfjB, hrtB, hdfB, hljB, hljpB]
  posWitness :=
    { flags := (1, 1)
      runFlags := (1, 1)
      placement := (2002, 1001)
      latestJob := 2002 }
  negWitness :=
    { flags := (1, 1)
      runFlags := (1, 0)
      placement := (3003, 1001)
      latestJob := 3003 }
  nonVacuous := by decide
  tight := by decide

def remoteReplaySupersessionFence : StickyFence RemoteReplaySupersessionCheck where
  admit := remoteReplaySupersessionMetaGate.gate
  fenceClear c :=
    c.flags.1.toNat = 1 ∧
    c.flags.2.toNat = 1 ∧
    (c.placement.1.toNat = c.placement.2.toNat ∨
     (c.runFlags.1.toNat = 1 ∧ c.runFlags.2.toNat = 1 ∧ c.latestJob.toNat = c.placement.1.toNat))
  enforced c h := by
    rcases remoteReplaySupersessionMetaGate.sound c h with
      ⟨hwa, hnm, _, _, _, _, kind, hkind⟩
    refine ⟨hwa, hnm, ?_⟩
    cases kind with
    | exactFailedJob => exact Or.inl hkind
    | abortedPreDispatchChain =>
      rcases hkind with ⟨hrt, hdf, _, hljp⟩
      exact Or.inr ⟨hrt, hdf, hljp⟩

/-! ### 8. Inbox single-owner CAS (`SM-18`) -/

inductive InboxEntryKind where
  | preferences
  | seen
  deriving Repr, DecidableEq

def InboxEntryKind.decode? : Nat → Option InboxEntryKind
  | 1 => some .preferences
  | 2 => some .seen
  | _ => none

structure InboxCasCheck where
  flags    : UInt8 × UInt8 × UInt8 × UInt8 × UInt8
  versions : UInt64 × UInt64
  replay   : UInt8
  deriving Repr, DecidableEq

/-- Independent inbox CAS domain model:
    `pathKind` decodes to preferences or seen, every required field flag is exactly `1`,
    the presented version matches the stored version, and the replay bit is canonical (`0` or `1`). -/
def InboxCasDomainSafe (c : InboxCasCheck) : Prop :=
  c.flags.2.1.toNat = 1 ∧
  c.flags.2.2.1.toNat = 1 ∧
  c.flags.2.2.2.1.toNat = 1 ∧
  c.flags.2.2.2.2.toNat = 1 ∧
  (c.replay.toNat = 0 ∨ c.replay.toNat = 1) ∧
  c.versions.1.toNat = c.versions.2.toNat ∧
  (InboxEntryKind.decode? c.flags.1.toNat).isSome = true

@[inline, export orb_core_verify_inbox_cas]
def verifyInboxCas
    (pathKind clientOk seqOk expectedOk bodyOk : UInt8)
    (storedVer expectedVer : UInt64)
    (sameMutation : UInt8) : UInt8 :=
  if pathKind ≥ 1 && pathKind ≤ 2 && clientOk == 1 && seqOk == 1 && expectedOk == 1 &&
     bodyOk == 1 && storedVer == expectedVer && sameMutation ≤ 1 then 1 else 0

def inboxCasMetaGate : MetaGateSpec InboxCasCheck InboxCasDomainSafe where
  gate c :=
    verifyInboxCas c.flags.1 c.flags.2.1 c.flags.2.2.1 c.flags.2.2.2.1 c.flags.2.2.2.2
      c.versions.1 c.versions.2 c.replay == 1
  sound c h := by
    rcases c with ⟨⟨pk, cl, sq, ex, bd⟩, ⟨sv, ev⟩, rp⟩
    change (verifyInboxCas pk cl sq ex bd sv ev rp == 1) = true at h
    dsimp [InboxCasDomainSafe]
    unfold verifyInboxCas at h
    have hc :
        (pk ≥ 1 && pk ≤ 2 && cl == 1 && sq == 1 && ex == 1 && bd == 1 &&
         sv == ev && rp ≤ 1) = true := by
      cases hb : (pk ≥ 1 && pk ≤ 2 && cl == 1 && sq == 1 && ex == 1 && bd == 1 && sv == ev && rp ≤ 1)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨hpk1, hpk2⟩, hcl⟩, hsq⟩, hex⟩, hbd⟩, hrev⟩, hrp⟩
    subst hcl
    subst hsq
    subst hex
    subst hbd
    subst hrev
    have hpkN1 : 1 ≤ pk.toNat := UInt8.le_iff_toNat_le.mp hpk1
    have hpkN2 : pk.toNat ≤ 2 := UInt8.le_iff_toNat_le.mp hpk2
    refine ⟨rfl, rfl, rfl, rfl, u8_le_one_cases rp hrp, rfl, ?_⟩
    cases hk : pk.toNat with
    | zero => omega
    | succ n =>
      rcases n with _ | _ | n2
      · simp [InboxEntryKind.decode?]
      · simp [InboxEntryKind.decode?]
      · omega
  complete c h := by
    rcases c with ⟨⟨pk, cl, sq, ex, bd⟩, ⟨sv, ev⟩, rp⟩
    change (verifyInboxCas pk cl sq ex bd sv ev rp == 1) = true
    dsimp [InboxCasDomainSafe] at h
    rcases h with ⟨hcl, hsq, hex, hbd, hrp, hrev, hkind⟩
    unfold verifyInboxCas
    have hclB : (cl == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat cl 1 (by omega) hcl
    have hsqB : (sq == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat sq 1 (by omega) hsq
    have hexB : (ex == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ex 1 (by omega) hex
    have hbdB : (bd == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bd 1 (by omega) hbd
    have hrevB : (sv == ev) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq sv ev hrev
    have hrpB : rp ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change rp.toNat ≤ 1; omega
    cases hk : pk.toNat with
    | zero => simp [InboxEntryKind.decode?, hk] at hkind
    | succ n =>
      rcases n with _ | _ | n2
      · have hpk1 : pk ≥ 1 := by apply UInt8.le_iff_toNat_le.mpr; change 1 ≤ pk.toNat; omega
        have hpk2 : pk ≤ 2 := by apply UInt8.le_iff_toNat_le.mpr; change pk.toNat ≤ 2; omega
        simp [hpk1, hpk2, hclB, hsqB, hexB, hbdB, hrevB, hrpB]
      · have hpk1 : pk ≥ 1 := by apply UInt8.le_iff_toNat_le.mpr; change 1 ≤ pk.toNat; omega
        have hpk2 : pk ≤ 2 := by apply UInt8.le_iff_toNat_le.mpr; change pk.toNat ≤ 2; omega
        simp [hpk1, hpk2, hclB, hsqB, hexB, hbdB, hrevB, hrpB]
      · simp [InboxEntryKind.decode?, hk] at hkind
  posWitness := { flags := (1, 1, 1, 1, 1), versions := (4, 4), replay := 0 }
  negWitness := { flags := (1, 1, 1, 1, 1), versions := (4, 5), replay := 0 }
  nonVacuous := by decide
  tight := by decide

theorem inbox_cas_rejects_version_mismatch
    (pk cl sq ex bd : UInt8) (sv ev : UInt64) (rp : UInt8)
    (hne : sv.toNat ≠ ev.toNat) :
    verifyInboxCas pk cl sq ex bd sv ev rp = 0 := by
  have hbad : ¬ InboxCasDomainSafe ⟨(pk, cl, sq, ex, bd), (sv, ev), rp⟩ := by
    rintro ⟨_, _, _, _, _, hrev, _⟩
    exact hne hrev
  have hf := inboxCasMetaGate.rejects_unsafe ⟨(pk, cl, sq, ex, bd), (sv, ev), rp⟩ hbad
  unfold inboxCasMetaGate at hf
  dsimp at hf
  unfold verifyInboxCas at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 9. Project-context operation CAS (`SM-18`) -/

structure ContextOpCheck where
  guards : UInt8 × UInt8 × UInt8 × UInt8 × UInt8
  revs   : UInt64 × UInt64
  cas    : UInt8 × UInt8
  deriving Repr, DecidableEq

/-- Independent context-op CAS domain model:
    path, size, entry-count, project, and blob guards are all exactly `1`,
    `basePresent` and `entryPresent` are canonical bits (`0 | 1`), and per-entry CAS matches
    (`basePresent = 0` requires `entryPresent = 0`; `basePresent = 1` requires `entryPresent = 1`
    and `entryRev = baseRev`). -/
def ContextOpDomainSafe (c : ContextOpCheck) : Prop :=
  c.guards.1.toNat = 1 ∧
  c.guards.2.1.toNat = 1 ∧
  c.guards.2.2.1.toNat = 1 ∧
  c.guards.2.2.2.1.toNat = 1 ∧
  c.guards.2.2.2.2.toNat = 1 ∧
  (c.cas.1.toNat = 0 ∨ c.cas.1.toNat = 1) ∧
  (c.cas.2.toNat = 0 ∨ c.cas.2.toNat = 1) ∧
  ((c.cas.1.toNat = 0 ∧ c.cas.2.toNat = 0) ∨
   (c.cas.1.toNat = 1 ∧ c.cas.2.toNat = 1 ∧ c.revs.1.toNat = c.revs.2.toNat))

@[inline, export orb_core_verify_context_op]
def verifyContextOpCas
    (pathOk sizeOk countOk projectOk blobOk : UInt8)
    (entryRev baseRev : UInt64)
    (basePresent entryPresent : UInt8) : UInt8 :=
  if pathOk == 1 && sizeOk == 1 && countOk == 1 && projectOk == 1 && blobOk == 1 &&
     basePresent ≤ 1 && entryPresent ≤ 1 &&
     ((basePresent == 0 && entryPresent == 0) ||
      (basePresent == 1 && entryPresent == 1 && entryRev == baseRev)) then 1 else 0

def contextOpMetaGate : MetaGateSpec ContextOpCheck ContextOpDomainSafe where
  gate c :=
    verifyContextOpCas c.guards.1 c.guards.2.1 c.guards.2.2.1 c.guards.2.2.2.1 c.guards.2.2.2.2
      c.revs.1 c.revs.2 c.cas.1 c.cas.2 == 1
  sound c h := by
    rcases c with ⟨⟨po, so, co, pr, bo⟩, ⟨hr, br⟩, ⟨bp, ep⟩⟩
    change (verifyContextOpCas po so co pr bo hr br bp ep == 1) = true at h
    dsimp [ContextOpDomainSafe]
    unfold verifyContextOpCas at h
    have hc :
        (po == 1 && so == 1 && co == 1 && pr == 1 && bo == 1 &&
         bp ≤ 1 && ep ≤ 1 &&
         ((bp == 0 && ep == 0) || (bp == 1 && ep == 1 && hr == br))) = true := by
      cases hb :
          (po == 1 && so == 1 && co == 1 && pr == 1 && bo == 1 &&
           bp ≤ 1 && ep ≤ 1 &&
           ((bp == 0 && ep == 0) || (bp == 1 && ep == 1 && hr == br)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨hpo, hso⟩, hco⟩, hpr⟩, hbo⟩, hbp⟩, hep⟩, hmatch⟩
    subst hpo
    subst hso
    subst hco
    subst hpr
    subst hbo
    refine ⟨rfl, rfl, rfl, rfl, rfl, u8_le_one_cases bp hbp, u8_le_one_cases ep hep, ?_⟩
    rcases hmatch with ⟨hbz, hez⟩ | ⟨⟨hb1, he1⟩, heq⟩
    · subst hbz
      subst hez
      exact Or.inl ⟨rfl, rfl⟩
    · subst hb1
      subst he1
      subst heq
      exact Or.inr ⟨rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨po, so, co, pr, bo⟩, ⟨hr, br⟩, ⟨bp, ep⟩⟩
    change (verifyContextOpCas po so co pr bo hr br bp ep == 1) = true
    dsimp [ContextOpDomainSafe] at h
    rcases h with ⟨hpo, hso, hco, hpr, hbo, hbp, hep, hmatch⟩
    unfold verifyContextOpCas
    have hpoB : (po == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat po 1 (by omega) hpo
    have hsoB : (so == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat so 1 (by omega) hso
    have hcoB : (co == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat co 1 (by omega) hco
    have hprB : (pr == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat pr 1 (by omega) hpr
    have hboB : (bo == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bo 1 (by omega) hbo
    have hbpB : bp ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change bp.toNat ≤ 1; omega
    have hepB : ep ≤ 1 := by apply UInt8.le_iff_toNat_le.mpr; change ep.toNat ≤ 1; omega
    rcases hmatch with ⟨hbz, hez⟩ | ⟨hb1, he1, heq⟩
    · have hbzB : (bp == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bp 0 (by omega) hbz
      have hezB : (ep == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ep 0 (by omega) hez
      simp [hpoB, hsoB, hcoB, hprB, hboB, hbpB, hepB, hbzB, hezB]
    · have hb1B : (bp == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat bp 1 (by omega) hb1
      have he1B : (ep == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat ep 1 (by omega) he1
      have heqB : (hr == br) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq hr br heq
      simp [hpoB, hsoB, hcoB, hprB, hboB, hbpB, hepB, hb1B, he1B, heqB]
  posWitness := { guards := (1, 1, 1, 1, 1), revs := (7, 7), cas := (1, 1) }
  negWitness := { guards := (1, 1, 1, 1, 1), revs := (7, 3), cas := (1, 1) }
  nonVacuous := by decide
  tight := by decide

theorem context_op_rejects_stale_base
    (po so co pr bo ep : UInt8) (hr br : UInt64)
    (hne : hr.toNat ≠ br.toNat) :
    verifyContextOpCas po so co pr bo hr br 1 ep = 0 := by
  have hbad : ¬ ContextOpDomainSafe ⟨(po, so, co, pr, bo), (hr, br), (1, ep)⟩ := by
    rintro ⟨_, _, _, _, _, _, _, hmatch⟩
    rcases hmatch with ⟨hbz, _⟩ | ⟨_, _, heq⟩
    · cases hbz
    · exact hne heq
  have hf := contextOpMetaGate.rejects_unsafe ⟨(po, so, co, pr, bo), (hr, br), (1, ep)⟩ hbad
  unfold contextOpMetaGate at hf
  dsimp at hf
  unfold verifyContextOpCas at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 10. Board track admission (`SM-13`) -/

structure BoardTrackCheck where
  flags : UInt8 × UInt8 × UInt8 × UInt8 × UInt8
  deriving Repr, DecidableEq

/-- Independent board-track domain model:
    the track exists, its status is canonical, slot and retry kernel bits are `1`,
    and there is no duplicate open task. -/
def BoardTrackDomainSafe (c : BoardTrackCheck) : Prop :=
  c.flags.1.toNat = 1 ∧
  c.flags.2.1.toNat = 1 ∧
  c.flags.2.2.1.toNat = 1 ∧
  c.flags.2.2.2.1.toNat = 1 ∧
  c.flags.2.2.2.2.toNat = 0

@[inline, export orb_core_verify_board_track]
def verifyBoardTrack
    (trackExists statusOk slotsOk retryOk duplicateOpen : UInt8) : UInt8 :=
  if trackExists == 1 && statusOk == 1 && slotsOk == 1 && retryOk == 1 && duplicateOpen == 0 then 1 else 0

def boardTrackMetaGate : MetaGateSpec BoardTrackCheck BoardTrackDomainSafe where
  gate c :=
    verifyBoardTrack c.flags.1 c.flags.2.1 c.flags.2.2.1 c.flags.2.2.2.1 c.flags.2.2.2.2 == 1
  sound c h := by
    rcases c with ⟨⟨te, st, sl, rt, du⟩⟩
    change (verifyBoardTrack te st sl rt du == 1) = true at h
    dsimp [BoardTrackDomainSafe]
    unfold verifyBoardTrack at h
    have hc :
        (te == 1 && st == 1 && sl == 1 && rt == 1 && du == 0) = true := by
      cases hb : (te == 1 && st == 1 && sl == 1 && rt == 1 && du == 0)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨hte, hst⟩, hsl⟩, hrt⟩, hdu⟩
    subst hte
    subst hst
    subst hsl
    subst hrt
    subst hdu
    exact ⟨rfl, rfl, rfl, rfl, rfl⟩
  complete c h := by
    rcases c with ⟨⟨te, st, sl, rt, du⟩⟩
    change (verifyBoardTrack te st sl rt du == 1) = true
    dsimp [BoardTrackDomainSafe] at h
    rcases h with ⟨hte, hst, hsl, hrt, hdu⟩
    unfold verifyBoardTrack
    have hteB : (te == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat te 1 (by omega) hte
    have hstB : (st == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat st 1 (by omega) hst
    have hslB : (sl == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat sl 1 (by omega) hsl
    have hrtB : (rt == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat rt 1 (by omega) hrt
    have hduB : (du == 0) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat du 0 (by omega) hdu
    simp [hteB, hstB, hslB, hrtB, hduB]
  posWitness := { flags := (1, 1, 1, 1, 0) }
  negWitness := { flags := (1, 1, 1, 1, 1) }
  nonVacuous := by decide
  tight := by decide

theorem board_track_rejects_duplicate_open
    (te st sl rt : UInt8) :
    verifyBoardTrack te st sl rt 1 = 0 := by
  have hbad : ¬ BoardTrackDomainSafe ⟨(te, st, sl, rt, 1)⟩ := by
    rintro ⟨_, _, _, _, hdu⟩
    cases hdu
  have hf := boardTrackMetaGate.rejects_unsafe ⟨(te, st, sl, rt, 1)⟩ hbad
  unfold boardTrackMetaGate at hf
  dsimp at hf
  unfold verifyBoardTrack at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 11. Deploy observe → gate → re-check (`SM-22` / `G-ORB-7`) -/

structure DeployRecheckCheck where
  flags   : UInt8 × UInt8 × UInt8
  targets : UInt32 × UInt32
  leases  : UInt64 × UInt64
  tail    : (UInt64 × UInt64) × (UInt64 × UInt64)
  deriving Repr, DecidableEq

/-- Independent deploy re-check domain model:
    the initial deploy gate passed, the principal is in `1..3`, bunker is clear,
    the live target, lease, and digest still match the observation, and the lease has not expired. -/
def DeployRecheckDomainSafe (c : DeployRecheckCheck) : Prop :=
  c.flags.1.toNat = 1 ∧
  1 ≤ c.flags.2.1.toNat ∧
  c.flags.2.1.toNat ≤ 3 ∧
  c.flags.2.2.toNat = 0 ∧
  c.targets.1.toNat ≠ 0 ∧
  c.targets.1.toNat = c.targets.2.toNat ∧
  c.leases.1.toNat ≠ 0 ∧
  c.leases.1.toNat = c.leases.2.toNat ∧
  c.tail.1.1.toNat < c.tail.1.2.toNat ∧
  c.tail.2.1.toNat ≠ 0 ∧
  c.tail.2.1.toNat = c.tail.2.2.toNat

private theorem u32_eq_of_toNat_eq (a b : UInt32) (h : a.toNat = b.toNat) : a = b :=
  UInt32.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

@[inline, export orb_core_verify_deploy_recheck]
def verifyDeployRecheck
    (gateOk principalKind bunkerState : UInt8)
    (observedTarget execTarget : UInt32)
    (observedLease liveLease nowTick expiryTick observedDigest execDigest : UInt64) : UInt32 :=
  if gateOk != 1 then 512
  else if bunkerState != 0 then 513
  else if !(principalKind ≥ 1 && principalKind ≤ 3) then 514
  else if !(nowTick < expiryTick) then 515
  else if !(observedLease != 0 && observedLease == liveLease) then 516
  else if !(observedTarget != 0 && observedTarget == execTarget) then 517
  else if !(observedDigest != 0 && observedDigest == execDigest) then 518
  else 257

def deployRecheckMetaGate : MetaGateSpec DeployRecheckCheck DeployRecheckDomainSafe where
  gate c :=
    verifyDeployRecheck c.flags.1 c.flags.2.1 c.flags.2.2
      c.targets.1 c.targets.2 c.leases.1 c.leases.2
      c.tail.1.1 c.tail.1.2 c.tail.2.1 c.tail.2.2 == 257
  sound c h := by
    rcases c with ⟨⟨g, pk, bk⟩, ⟨ot, et⟩, ⟨ol, ll⟩, ⟨⟨nw, ex⟩, ⟨od, ed⟩⟩⟩
    change (verifyDeployRecheck g pk bk ot et ol ll nw ex od ed == 257) = true at h
    dsimp [DeployRecheckDomainSafe]
    unfold verifyDeployRecheck at h
    have hc :
        (g == 1 && bk == 0 && pk ≥ 1 && pk ≤ 3 && nw < ex &&
         ol != 0 && ol == ll && ot != 0 && ot == et && od != 0 && od == ed) = true := by
      split at h
      · contradiction
      · rename_i hgNot
        split at h
        · contradiction
        · rename_i hbkNot
          split at h
          · contradiction
          · rename_i hpkNot
            split at h
            · contradiction
            · rename_i hclkNot
              split at h
              · contradiction
              · rename_i hlsNot
                split at h
                · contradiction
                · rename_i htgNot
                  split at h
                  · contradiction
                  · rename_i hdgNot
                    simp only [bne_iff_ne, Decidable.not_not, Bool.not_eq_true] at hgNot hbkNot hpkNot hclkNot hlsNot htgNot hdgNot
                    subst hgNot; subst hbkNot
                    have hpkB : (pk ≥ 1 && pk ≤ 3) = true := by
                      cases hpk0 : (pk ≥ 1 && pk ≤ 3)
                      · rw [hpk0] at hpkNot; contradiction
                      · rfl
                    have hclkB : decide (nw < ex) = true := by
                      cases hclk0 : decide (nw < ex)
                      · rw [hclk0] at hclkNot; contradiction
                      · rfl
                    have hlsB : (ol != 0 && ol == ll) = true := by
                      cases hls0 : (ol != 0 && ol == ll)
                      · rw [hls0] at hlsNot; contradiction
                      · rfl
                    have htgB : (ot != 0 && ot == et) = true := by
                      cases htg0 : (ot != 0 && ot == et)
                      · rw [htg0] at htgNot; contradiction
                      · rfl
                    have hdgB : (od != 0 && od == ed) = true := by
                      cases hdg0 : (od != 0 && od == ed)
                      · rw [hdg0] at hdgNot; contradiction
                      · rfl
                    simp only [Bool.and_eq_true] at hpkB hlsB htgB hdgB ⊢
                    refine ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨by decide, by decide⟩, hpkB.1⟩, hpkB.2⟩, hclkB⟩,
                      hlsB.1⟩, hlsB.2⟩, htgB.1⟩, htgB.2⟩, hdgB.1⟩, hdgB.2⟩
    simp only [Bool.and_eq_true, bne_iff_ne, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨hg, hbk⟩, hpk1⟩, hpk2⟩, hclk⟩, hol⟩, heql⟩, hot⟩, heqt⟩, hod⟩, heqd⟩
    subst hg
    subst hbk
    subst heql
    subst heqt
    subst heqd
    exact ⟨rfl,
      UInt8.le_iff_toNat_le.mp hpk1, UInt8.le_iff_toNat_le.mp hpk2,
      rfl,
      fun hz => hot (u32_eq_of_toNat_eq ot 0 hz), rfl,
      fun hz => hol (u64_eq_of_toNat_eq ol 0 hz), rfl,
      UInt64.lt_iff_toNat_lt.mp hclk,
      fun hz => hod (u64_eq_of_toNat_eq od 0 hz), rfl⟩
  complete c h := by
    rcases c with ⟨⟨g, pk, bk⟩, ⟨ot, et⟩, ⟨ol, ll⟩, ⟨⟨nw, ex⟩, ⟨od, ed⟩⟩⟩
    change (verifyDeployRecheck g pk bk ot et ol ll nw ex od ed == 257) = true
    dsimp [DeployRecheckDomainSafe] at h
    rcases h with ⟨hg, hpk1, hpk2, hbk, hot, heqt, hol, heql, hclk, hod, heqd⟩
    unfold verifyDeployRecheck
    have hgEq : g = 1 := u8_eq_of_toNat g 1 (by omega) hg
    have hbkEq : bk = 0 := u8_eq_of_toNat bk 0 (by omega) hbk
    subst hgEq; subst hbkEq
    have hpkB : (pk ≥ 1 && pk ≤ 3) = true := by
      have a : pk ≥ 1 := by apply UInt8.le_iff_toNat_le.mpr; change 1 ≤ pk.toNat; omega
      have b : pk ≤ 3 := by apply UInt8.le_iff_toNat_le.mpr; change pk.toNat ≤ 3; omega
      simp [a, b]
    have hclkLt : nw < ex := UInt64.lt_iff_toNat_lt.mpr hclk
    have hlsB : (ol != 0 && ol == ll) = true := by
      have holB : (ol != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hol (by rw [hz]; rfl)
      have heqB : (ol == ll) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq ol ll heql
      simp [holB, heqB]
    have htgB : (ot != 0 && ot == et) = true := by
      have hotB : (ot != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hot (by rw [hz]; rfl)
      have heqB : (ot == et) = true := by rw [beq_iff_eq]; exact u32_eq_of_toNat_eq ot et heqt
      simp [hotB, heqB]
    have hdgB : (od != 0 && od == ed) = true := by
      have hodB : (od != 0) = true := by
        rw [bne_iff_ne]
        intro hz
        exact hod (by rw [hz]; rfl)
      have heqB : (od == ed) = true := by rw [beq_iff_eq]; exact u64_eq_of_toNat_eq od ed heqd
      simp [hodB, heqB]
    simp [hpkB, hclkLt, hlsB, htgB, hdgB]
  posWitness := {
    flags := (1, 2, 0)
    targets := (9, 9)
    leases := (4, 4)
    tail := ((10, 20), (8, 8))
  }
  negWitness := {
    flags := (1, 2, 0)
    targets := (9, 9)
    leases := (4, 5)
    tail := ((10, 20), (8, 8))
  }
  nonVacuous := by decide
  tight := by decide

theorem deploy_recheck_rejects_lease_drift
    (g pk bk : UInt8) (ot et : UInt32) (ol ll nw ex od ed : UInt64)
    (hne : ol.toNat ≠ ll.toNat) :
    (verifyDeployRecheck g pk bk ot et ol ll nw ex od ed == 257) = false := by
  have hbad : ¬ DeployRecheckDomainSafe ⟨(g, pk, bk), (ot, et), (ol, ll), ((nw, ex), (od, ed))⟩ := by
    rintro ⟨_, _, _, _, _, _, _, heql, _, _, _⟩
    exact hne heql
  exact deployRecheckMetaGate.rejects_unsafe ⟨(g, pk, bk), (ot, et), (ol, ll), ((nw, ex), (od, ed))⟩ hbad

/-! ### 12. Per-User Skill Library Scope Gate (`docs/specs/per-user-skill-library.md`) -/

/-- Library reads require the same owner, or a separately verified explicit admin grant.
    Core catalogs always select the requester; mission delivery uses the stored owner. -/
@[inline, export orb_core_library_scope_gate]
def orbLibraryScopeGate (sameOwner isAdminWithExplicitAccess : UInt8) : UInt8 :=
  if sameOwner == 1 || isAdminWithExplicitAccess == 1 then 1 else 0

/-- Library access is ownership or an explicit grant, never an implicit admin role.
    ID comparison and grant verification remain in Core's trusted extraction boundary. -/
def libraryScopeMetaGate : MetaGateSpec (UInt8 × UInt8)
    (fun claim => claim.1 = 1 ∨ claim.2 = 1) where
  gate claim := orbLibraryScopeGate claim.1 claim.2 == 1
  sound claim h := by
    by_cases same : claim.1 = 1
    · exact Or.inl same
    · right
      by_cases grant : claim.2 = 1
      · exact grant
      · simp [orbLibraryScopeGate, same, grant] at h
  complete claim h := by
    rcases h with same | grant
    · simp [orbLibraryScopeGate, same]
    · simp [orbLibraryScopeGate, grant]
  posWitness := (1, 0)
  negWitness := (0, 0)
  nonVacuous := by decide
  tight := by decide

theorem library_scope_ordinary (requester owner : String) :
    orbLibraryScopeGate (if requester == owner then 1 else 0) 0 = 1 ↔ requester = owner := by
  by_cases same : requester = owner
  · simp [orbLibraryScopeGate, same]
  · simp [orbLibraryScopeGate, same]

theorem library_scope_stable (sameOwner grant : UInt8) :
    orbLibraryScopeGate (orbLibraryScopeGate sameOwner grant) 0 =
      orbLibraryScopeGate sameOwner grant := by
  by_cases authorized : sameOwner == 1 || grant == 1 <;>
    simp [orbLibraryScopeGate, authorized]

theorem library_scope_no_owner_substitution (member owner : String) (different : member ≠ owner) :
    orbLibraryScopeGate (if member == owner then 1 else 0) 0 = 0 := by
  simp [orbLibraryScopeGate, different]

theorem library_scope_explicit (sameOwner : UInt8) :
    orbLibraryScopeGate sameOwner 1 = 1 := by
  simp [orbLibraryScopeGate]

end OrbCore.Spec
