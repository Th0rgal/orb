/-
  OrbCore.Spec: Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for Wave 4 Core Gateway (`sandboxed-sh`): Startup Secret/Dev-Mode Posture, Console WS Auth,
  Machine-Transfer Single-Active Fence, Upstream Proxy Failover, and Deploy Unit Confinement.

  Every unboxed scalar gate is proved equivalent (`MetaGateSpec`, `ScopedAuthority`,
  `StickyFence`) to an independent domain model over typed protocol ADTs, finite unit catalogs,
  and natural-number budgets rather than mirroring the gate's boolean formula.
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
  | rateLimited429
  | serverError5xx (code : Nat)
  deriving Repr, DecidableEq

def UpstreamFailureClass.classifyRetryable? (code : Nat) : Option UpstreamFailureClass :=
  if code = 429 then some .rateLimited429
  else if 500 ≤ code ∧ code ≤ 599 then some (.serverError5xx code)
  else none

structure ProxyFailoverCheck where
  chain            : UInt8 × UInt8
  upstreamStatus   : UInt32
  headersCommitted : UInt8
  deriving Repr, DecidableEq

/-- Independent provider-failover domain specification:
    the fallback chain has `1..16` candidates, at least one unvisited fallback candidate remains
    (`attemptIdx + 1 < chainLen` in `Nat`, overflow-free), downstream response headers have not yet
    been committed (`headersCommitted = 0`), and `UpstreamFailureClass.classifyRetryable?` succeeds. -/
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
     (upstreamStatus == 429 || (upstreamStatus ≥ 500 && upstreamStatus ≤ 599)) then 1 else 0

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
         (st == 429 || (st ≥ 500 && st ≤ 599))) = true := by
      cases hb :
          (clen ≥ 1 && clen ≤ 16 && att < 16 && att + 1 < clen && hcFlag == 0 &&
           (st == 429 || (st ≥ 500 && st ≤ 599)))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨⟨hcl1, hcl2⟩, hatt16⟩, hatt⟩, hcomm⟩, hst⟩
    have hclN1 : 1 ≤ clen.toNat := UInt8.le_iff_toNat_le.mp hcl1
    have hclN2 : clen.toNat ≤ 16 := UInt8.le_iff_toNat_le.mp hcl2
    have hattN16 : att.toNat < 16 := UInt8.lt_iff_toNat_lt.mp hatt16
    have hattMod : (att.toNat + 1) % 256 < clen.toNat := UInt8.lt_iff_toNat_lt.mp hatt
    have hattNat : att.toNat + 1 < clen.toNat := by omega
    refine ⟨hclN1, hclN2, hattNat, by subst hcomm; rfl, ?_⟩
    unfold UpstreamFailureClass.classifyRetryable?
    rcases hst with h429 | ⟨h500, h599⟩
    · subst h429; rfl
    · have hs1 : 500 ≤ st.toNat := UInt32.le_iff_toNat_le.mp h500
      have hs2 : st.toNat ≤ 599 := UInt32.le_iff_toNat_le.mp h599
      have hne429 : st.toNat ≠ 429 := by omega
      simp [hne429, hs1, hs2]
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
    unfold UpstreamFailureClass.classifyRetryable? at hst
    split at hst
    · rename_i h429
      have hstEq : (st == 429) = true := by
        rw [beq_iff_eq]
        apply UInt32.eq_of_toBitVec_eq
        apply BitVec.eq_of_toNat_eq
        change st.toNat = 429
        exact h429
      simp [hclGe, hclLe, hatt16, hattB, hcommB, hstEq]
    · split at hst
      · rename_i h5xx
        have h500 : st ≥ 500 := UInt32.le_iff_toNat_le.mpr h5xx.1
        have h599 : st ≤ 599 := UInt32.le_iff_toNat_le.mpr h5xx.2
        simp [hclGe, hclLe, hatt16, hattB, hcommB, h500, h599]
      · contradiction
  posWitness := { chain := (0, 3), upstreamStatus := 503, headersCommitted := 0 }
  negWitness := { chain := (0, 3), upstreamStatus := 503, headersCommitted := 1 }
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
    `"sandboxed-node.service"` = 22). -/
def ManagedSystemdUnit.minAliasBytes : ManagedSystemdUnit → Nat
  | .sandboxedSh   => 8  -- "orb-core"
  | .sandboxedNode => 8  -- "orb-node"
  | .orbPrivd      => 9  -- "orb-privd"

def ManagedSystemdUnit.maxAliasBytes : ManagedSystemdUnit → Nat
  | .sandboxedSh   => 20 -- "sandboxed-sh.service"
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
     ((unitCode == 1 && unitLen ≥ 8 && unitLen ≤ 20) ||
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
         ((uc == 1 && uL ≥ 8 && uL ≤ 20) ||
          (uc == 2 && uL ≥ 8 && uL ≤ 22) ||
          (uc == 3 && uL ≥ 9 && uL ≤ 17))) = true := by
      cases hb :
          (pt == 0 &&
           ((uc == 1 && uL ≥ 8 && uL ≤ 20) ||
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
        have hle : uL ≤ 20 := UInt32.le_iff_toNat_le.mpr hl2
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

end OrbCore.Spec
