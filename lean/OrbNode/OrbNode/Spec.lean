/-
  OrbNode.Spec: Two-Layer Non-Tautological Specifications (`0 import Lean`, `0 sorryAx`)
  for Wave 2 Worker Daemon (`sandboxed-node` / `orb-node`).

  Every unboxed scalar gate is proved equivalent (`MetaGateSpec`, `ScopedAuthority`,
  `ConservedResource`) to an independent domain model over typed protocol ADTs and
  natural-number resource invariants rather than mirroring the gate's boolean formula.
-/
namespace OrbNode.Spec

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

/-- Layer-I `ScopedAuthority` meta-specification: admitted credentials/leases respect role & job scope. -/
structure ScopedAuthority (Input : Type) where
  admit      : Input → Bool
  scopeValid : Input → Prop
  sound      : ∀ x, admit x = true → scopeValid x

/-- Layer-I `ConservedResource` meta-specification: admitted capacity/disk operations respect bounds. -/
structure ConservedResource (Input : Type) where
  admit        : Input → Bool
  withinBudget : Input → Prop
  conserved    : ∀ x, admit x = true → withinBudget x

/-- Total bounded wire-slice parser specification (`0` panics, bounded output). -/
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

/-! ### 1. Node Bearer Token & 1-Step Rotation Gate (`Authorization: Bearer <token>`) -/

inductive BearerEpochMatch where
  | activeSecret
  | previousRotatedSecret
  deriving Repr, DecidableEq

def maxBearerTokenBytes : Nat := 4096

structure NodeBearerCheck where
  flags        : UInt8 × UInt8
  prev         : UInt8 × UInt8
  candidateLen : UInt32
  deriving Repr, DecidableEq

/-- Independent bearer authentication & rotation domain specification:
    an `Authorization: Bearer ` header is present with token length in `[1, 4096]`,
    and there exists an authenticated `BearerEpochMatch` (either matching the active secret
    or matching an explicitly configured previous rotation secret). -/
def NodeBearerDomainSafe (c : NodeBearerCheck) : Prop :=
  c.flags.1.toNat = 1 ∧
  1 ≤ c.candidateLen.toNat ∧
  c.candidateLen.toNat ≤ maxBearerTokenBytes ∧
  ∃ epoch : BearerEpochMatch,
    match epoch with
    | .activeSecret => c.flags.2.toNat = 1
    | .previousRotatedSecret => c.prev.1.toNat = 1 ∧ c.prev.2.toNat = 1

@[inline, export orb_node_verify_bearer_auth]
def verifyNodeBearerAuth
    (hasBearerPrefix : UInt8)
    (curMatches : UInt8)
    (hasPrevConfigured : UInt8)
    (prevMatches : UInt8)
    (candidateLen : UInt32) : UInt8 :=
  if hasBearerPrefix == 1 &&
     1 ≤ candidateLen && candidateLen ≤ 4096 &&
     (curMatches == 1 || (hasPrevConfigured == 1 && prevMatches == 1)) then 1 else 0

def nodeBearerMetaGate : MetaGateSpec NodeBearerCheck NodeBearerDomainSafe where
  gate c :=
    verifyNodeBearerAuth c.flags.1 c.flags.2 c.prev.1 c.prev.2 c.candidateLen == 1
  sound c h := by
    rcases c with ⟨⟨pfx, cur⟩, ⟨hasPrev, prevM⟩, cLen⟩
    change (verifyNodeBearerAuth pfx cur hasPrev prevM cLen == 1) = true at h
    dsimp [NodeBearerDomainSafe]
    unfold verifyNodeBearerAuth at h
    cases hc :
        (pfx == 1 &&
         1 ≤ cLen && cLen ≤ 4096 &&
         (cur == 1 || (hasPrev == 1 && prevM == 1)))
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨hpfx, hl1⟩, hl2⟩, hrot⟩
      refine ⟨by subst hpfx; rfl, UInt32.le_iff_toNat_le.mp hl1, UInt32.le_iff_toNat_le.mp hl2, ?_⟩
      rcases hrot with hcur | ⟨hhp, hpm⟩
      · exact ⟨.activeSecret, by subst hcur; rfl⟩
      · exact ⟨.previousRotatedSecret, by subst hhp; rfl, by subst hpm; rfl⟩
  complete c h := by
    rcases c with ⟨⟨pfx, cur⟩, ⟨hasPrev, prevM⟩, cLen⟩
    change (verifyNodeBearerAuth pfx cur hasPrev prevM cLen == 1) = true
    dsimp [NodeBearerDomainSafe] at h
    rcases h with ⟨hpfx, hl1, hl2, epoch, hep⟩
    unfold verifyNodeBearerAuth
    have hpfxB : (pfx == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat pfx 1 (by omega) hpfx
    have hlGe : 1 ≤ cLen := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ cLen.toNat; omega
    have hlLe : cLen ≤ 4096 := by
      apply UInt32.le_iff_toNat_le.mpr; change cLen.toNat ≤ 4096
      unfold maxBearerTokenBytes at hl2; omega
    cases epoch with
    | activeSecret =>
      have hcurB : (cur == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat cur 1 (by omega) hep
      simp [hpfxB, hlGe, hlLe, hcurB]
    | previousRotatedSecret =>
      rcases hep with ⟨hhp, hpm⟩
      have hhpB : (hasPrev == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat hasPrev 1 (by omega) hhp
      have hpmB : (prevM == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat prevM 1 (by omega) hpm
      simp [hpfxB, hlGe, hlLe, hhpB, hpmB]
  posWitness := { flags := (1, 0), prev := (1, 1), candidateLen := 64 }
  negWitness := { flags := (1, 0), prev := (0, 1), candidateLen := 64 }
  nonVacuous := by decide
  tight := by decide

theorem node_bearer_rejects_unconfigured_prev (prevMatches : UInt8) (cLen : UInt32) :
    verifyNodeBearerAuth 1 0 0 prevMatches cLen = 0 := by
  have hbad : ¬ NodeBearerDomainSafe ⟨(1, 0), (0, prevMatches), cLen⟩ := by
    rintro ⟨_, _, _, epoch, hep⟩
    cases epoch <;> simp at hep
  have hf := nodeBearerMetaGate.rejects_unsafe ⟨(1, 0), (0, prevMatches), cLen⟩ hbad
  unfold nodeBearerMetaGate at hf; dsimp at hf
  unfold verifyNodeBearerAuth at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 2. HMAC Lease Claims Scope, Node & Expiry Gate (`LeaseClaims`) -/

inductive LeaseScope where
  | execute
  | submit
  | force
  | capacity
  deriving Repr, DecidableEq

def LeaseScope.decode? : Nat → Option LeaseScope
  | 1 => some .execute
  | 2 => some .submit
  | 3 => some .force
  | 4 => some .capacity
  | _ => none

def LeaseScope.requiresJobPin : LeaseScope → Bool
  | .force => true
  | _      => false

structure NodeLeaseCheck where
  sigAndNode : UInt8 × UInt8
  scopes     : UInt8 × UInt8 × UInt8
  times      : UInt64 × UInt64
  deriving Repr, DecidableEq

/-- Independent HMAC lease capability specification (`ScopedAuthority`):
    HMAC signature and target node identity match, both claimed and expected scopes decode to the
    same `LeaseScope`, the lease lifetime has strictly positive remaining duration (`now + 1 ≤ exp`),
    and `.force` scope requires exact `job_id` pinning (`jobIdMatches = 1`). -/
def NodeLeaseDomainSafe (c : NodeLeaseCheck) : Prop :=
  ∃ scope : LeaseScope,
    c.sigAndNode.1.toNat = 1 ∧
    c.sigAndNode.2.toNat = 1 ∧
    LeaseScope.decode? c.scopes.1.toNat = some scope ∧
    LeaseScope.decode? c.scopes.2.1.toNat = some scope ∧
    c.times.1.toNat + 1 ≤ c.times.2.toNat ∧
    (scope.requiresJobPin = true → c.scopes.2.2.toNat = 1)

@[inline, export orb_node_verify_lease_claims]
def verifyNodeLeaseClaims
    (hmacValid : UInt8)
    (nodeMatches : UInt8)
    (scopeCode : UInt8)
    (expectedScope : UInt8)
    (jobIdMatches : UInt8)
    (nowSecs : UInt64)
    (expiresAt : UInt64) : UInt8 :=
  if hmacValid == 1 &&
     nodeMatches == 1 &&
     1 ≤ scopeCode && scopeCode ≤ 4 &&
     scopeCode == expectedScope &&
     nowSecs < expiresAt &&
     (scopeCode != 3 || jobIdMatches == 1) then 1 else 0

def nodeLeaseMetaGate : MetaGateSpec NodeLeaseCheck NodeLeaseDomainSafe where
  gate c :=
    verifyNodeLeaseClaims
      c.sigAndNode.1 c.sigAndNode.2
      c.scopes.1 c.scopes.2.1 c.scopes.2.2
      c.times.1 c.times.2 == 1
  sound c h := by
    rcases c with ⟨⟨hm, nd⟩, ⟨sc, esc, jm⟩, ⟨nowS, expS⟩⟩
    change (verifyNodeLeaseClaims hm nd sc esc jm nowS expS == 1) = true at h
    dsimp [NodeLeaseDomainSafe]
    unfold verifyNodeLeaseClaims at h
    cases hc :
        (hm == 1 &&
         nd == 1 &&
         1 ≤ sc && sc ≤ 4 &&
         sc == esc &&
         nowS < expS &&
         (sc != 3 || jm == 1))
    · rw [hc] at h; contradiction
    · simp only [Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne,
        decide_eq_true_eq, beq_iff_eq] at hc
      rcases hc with ⟨⟨⟨⟨⟨⟨hhm, hnd⟩, hsc1⟩, hsc2⟩, hscEq⟩, hlt⟩, hpin⟩
      have hscN1 : 1 ≤ sc.toNat := UInt8.le_iff_toNat_le.mp hsc1
      have hscN2 : sc.toNat ≤ 4 := UInt8.le_iff_toNat_le.mp hsc2
      have hltN : nowS.toNat < expS.toNat := UInt64.lt_iff_toNat_lt.mp hlt
      subst hscEq
      have hcases : sc.toNat = 1 ∨ sc.toNat = 2 ∨ sc.toNat = 3 ∨ sc.toNat = 4 := by omega
      rcases hcases with h1 | h2 | h3 | h4
      · refine ⟨.execute, by subst hhm; rfl, by subst hnd; rfl, ?_, ?_, by omega, ?_⟩
        · simp [LeaseScope.decode?, h1]
        · simp [LeaseScope.decode?, h1]
        · intro hp; simp [LeaseScope.requiresJobPin] at hp
      · refine ⟨.submit, by subst hhm; rfl, by subst hnd; rfl, ?_, ?_, by omega, ?_⟩
        · simp [LeaseScope.decode?, h2]
        · simp [LeaseScope.decode?, h2]
        · intro hp; simp [LeaseScope.requiresJobPin] at hp
      · refine ⟨.force, by subst hhm; rfl, by subst hnd; rfl, ?_, ?_, by omega, ?_⟩
        · simp [LeaseScope.decode?, h3]
        · simp [LeaseScope.decode?, h3]
        · intro _
          have hsc3 : sc = 3 := u8_eq_of_toNat sc 3 (by omega) h3
          rcases hpin with hne | hjm
          · exact False.elim (hne hsc3)
          · subst hjm; rfl
      · refine ⟨.capacity, by subst hhm; rfl, by subst hnd; rfl, ?_, ?_, by omega, ?_⟩
        · simp [LeaseScope.decode?, h4]
        · simp [LeaseScope.decode?, h4]
        · intro hp; simp [LeaseScope.requiresJobPin] at hp
  complete c h := by
    rcases c with ⟨⟨hm, nd⟩, ⟨sc, esc, jm⟩, ⟨nowS, expS⟩⟩
    change (verifyNodeLeaseClaims hm nd sc esc jm nowS expS == 1) = true
    dsimp [NodeLeaseDomainSafe] at h
    rcases h with ⟨scope, hhm, hnd, hscD, hescD, hexp, hpin⟩
    unfold verifyNodeLeaseClaims
    have hhmB : (hm == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat hm 1 (by omega) hhm
    have hndB : (nd == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat nd 1 (by omega) hnd
    have hltB : nowS < expS := by apply UInt64.lt_iff_toNat_lt.mpr; omega
    cases scope with
    | execute =>
      have hsc1 : sc = 1 := by
        refine u8_eq_of_toNat sc 1 (by omega) ?_
        cases hs : sc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hscD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hscD; rfl
      have hesc1 : esc = 1 := by
        refine u8_eq_of_toNat esc 1 (by omega) ?_
        cases hs : esc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hescD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hescD; rfl
      subst hsc1; subst hesc1; simp [hhmB, hndB, hltB]
    | submit =>
      have hsc2 : sc = 2 := by
        refine u8_eq_of_toNat sc 2 (by omega) ?_
        cases hs : sc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hscD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hscD; rfl
      have hesc2 : esc = 2 := by
        refine u8_eq_of_toNat esc 2 (by omega) ?_
        cases hs : esc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hescD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hescD; rfl
      subst hsc2; subst hesc2; simp [hhmB, hndB, hltB]
    | force =>
      have hsc3 : sc = 3 := by
        refine u8_eq_of_toNat sc 3 (by omega) ?_
        cases hs : sc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hscD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hscD; rfl
      have hesc3 : esc = 3 := by
        refine u8_eq_of_toNat esc 3 (by omega) ?_
        cases hs : esc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hescD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hescD; rfl
      have hjm1 : (jm == 1) = true := by
        rw [beq_iff_eq]; exact u8_eq_of_toNat jm 1 (by omega) (hpin rfl)
      subst hsc3; subst hesc3; simp [hhmB, hndB, hltB, hjm1]
    | capacity =>
      have hsc4 : sc = 4 := by
        refine u8_eq_of_toNat sc 4 (by omega) ?_
        cases hs : sc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hscD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hscD; rfl
      have hesc4 : esc = 4 := by
        refine u8_eq_of_toNat esc 4 (by omega) ?_
        cases hs : esc.toNat with
        | zero => simp [LeaseScope.decode?, hs] at hescD
        | succ n => rcases n with _ | _ | _ | _ | _ <;> simp [LeaseScope.decode?, hs] at hescD; rfl
      subst hsc4; subst hesc4; simp [hhmB, hndB, hltB]
  posWitness := { sigAndNode := (1, 1), scopes := (3, 3, 1), times := (1000, 1600) }
  negWitness := { sigAndNode := (1, 1), scopes := (3, 3, 0), times := (1000, 1600) }
  nonVacuous := by decide
  tight := by decide

def nodeLeaseScopedAuthority : ScopedAuthority NodeLeaseCheck where
  admit := nodeLeaseMetaGate.gate
  scopeValid := NodeLeaseDomainSafe
  sound := nodeLeaseMetaGate.sound

theorem node_lease_force_requires_job_pin (hm nd : UInt8) (nowS expS : UInt64) :
    verifyNodeLeaseClaims hm nd 3 3 0 nowS expS = 0 := by
  have hbad : ¬ NodeLeaseDomainSafe ⟨(hm, nd), (3, 3, 0), (nowS, expS)⟩ := by
    rintro ⟨scope, _, _, hscD, _, _, hpin⟩
    cases scope <;> simp [LeaseScope.decode?, LeaseScope.requiresJobPin] at hscD hpin
  have hf := nodeLeaseMetaGate.rejects_unsafe ⟨(hm, nd), (3, 3, 0), (nowS, expS)⟩ hbad
  unfold nodeLeaseMetaGate at hf; dsimp at hf
  unfold verifyNodeLeaseClaims at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 3. Live Capacity Resize & Disk Floor Gate (`POST /capacity` & `POST /jobs`) -/

def maxWorkerSlots : Nat := 256
def maxCoordinatorSlots : Nat := 16

structure NodeCapacityDiskCheck where
  caps  : UInt32 × UInt32
  disk  : UInt64 × UInt64
  flags : UInt8 × UInt8
  deriving Repr, DecidableEq

/-- Independent `ConservedResource` domain specification over worker/coordinator slot bounds
    and disk reserve floor: worker slots lie in `[1, 256]`, coordinator slots lie in `[1, 16]`,
    and standard job admission (`isResize ≠ 1 ∧ isForced ≠ 1`) preserves `floorBytes ≤ freeBytes`. -/
def NodeCapacityDiskDomainSafe (c : NodeCapacityDiskCheck) : Prop :=
  1 ≤ c.caps.1.toNat ∧ c.caps.1.toNat ≤ maxWorkerSlots ∧
  1 ≤ c.caps.2.toNat ∧ c.caps.2.toNat ≤ maxCoordinatorSlots ∧
  (c.flags.1.toNat ≠ 1 → c.flags.2.toNat ≠ 1 → c.disk.2.toNat ≤ c.disk.1.toNat)

@[inline, export orb_node_verify_capacity_disk]
def verifyNodeCapacityDisk
    (capacity : UInt32)
    (coordCapacity : UInt32)
    (freeBytes : UInt64)
    (floorBytes : UInt64)
    (isResize : UInt8)
    (isForced : UInt8) : UInt8 :=
  if 1 ≤ capacity && capacity ≤ 256 &&
     1 ≤ coordCapacity && coordCapacity ≤ 16 &&
     (isResize == 1 || isForced == 1 || floorBytes ≤ freeBytes) then 1 else 0

def nodeCapacityDiskMetaGate : MetaGateSpec NodeCapacityDiskCheck NodeCapacityDiskDomainSafe where
  gate c :=
    verifyNodeCapacityDisk
      c.caps.1 c.caps.2
      c.disk.1 c.disk.2
      c.flags.1 c.flags.2 == 1
  sound c h := by
    rcases c with ⟨⟨cap, ccap⟩, ⟨freeB, floorB⟩, ⟨isR, isF⟩⟩
    change (verifyNodeCapacityDisk cap ccap freeB floorB isR isF == 1) = true at h
    dsimp [NodeCapacityDiskDomainSafe]
    unfold verifyNodeCapacityDisk at h
    have hc :
        (1 ≤ cap && cap ≤ 256 &&
         1 ≤ ccap && ccap ≤ 16 &&
         (isR == 1 || isF == 1 || floorB ≤ freeB)) = true := by
      cases hb :
          (1 ≤ cap && cap ≤ 256 &&
           1 ≤ ccap && ccap ≤ 16 &&
           (isR == 1 || isF == 1 || floorB ≤ freeB))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨⟨hc1, hc2⟩, hcc1⟩, hcc2⟩, hdisk⟩
    refine ⟨UInt32.le_iff_toNat_le.mp hc1, UInt32.le_iff_toNat_le.mp hc2,
      UInt32.le_iff_toNat_le.mp hcc1, UInt32.le_iff_toNat_le.mp hcc2, ?_⟩
    intro hNotR hNotF
    rcases hdisk with hres | hfl
    · rcases hres with hr | hforce
      · subst hr; exact False.elim (hNotR rfl)
      · subst hforce; exact False.elim (hNotF rfl)
    · exact UInt64.le_iff_toNat_le.mp hfl
  complete c h := by
    rcases c with ⟨⟨cap, ccap⟩, ⟨freeB, floorB⟩, ⟨isR, isF⟩⟩
    change (verifyNodeCapacityDisk cap ccap freeB floorB isR isF == 1) = true
    dsimp [NodeCapacityDiskDomainSafe] at h
    rcases h with ⟨hc1, hc2, hcc1, hcc2, hdisk⟩
    unfold verifyNodeCapacityDisk
    have hcGe : 1 ≤ cap := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ cap.toNat; omega
    have hcLe : cap ≤ 256 := by
      apply UInt32.le_iff_toNat_le.mpr; change cap.toNat ≤ 256
      unfold maxWorkerSlots at hc2; omega
    have hccGe : 1 ≤ ccap := by apply UInt32.le_iff_toNat_le.mpr; change 1 ≤ ccap.toNat; omega
    have hccLe : ccap ≤ 16 := by
      apply UInt32.le_iff_toNat_le.mpr; change ccap.toNat ≤ 16
      unfold maxCoordinatorSlots at hcc2; omega
    cases hr : (isR == 1)
    · cases hf : (isF == 1)
      · have hnr : isR.toNat ≠ 1 := fun he => by
          have := u8_eq_of_toNat isR 1 (by omega) he
          subst this; contradiction
        have hnf : isF.toNat ≠ 1 := fun he => by
          have := u8_eq_of_toNat isF 1 (by omega) he
          subst this; contradiction
        have hfl : floorB ≤ freeB :=
          UInt64.le_iff_toNat_le.mpr (hdisk hnr hnf)
        simp [hcGe, hcLe, hccGe, hccLe, hfl]
      · simp [hcGe, hcLe, hccGe, hccLe]
    · simp [hcGe, hcLe, hccGe, hccLe]
  posWitness := { caps := (8, 2), disk := (20000000000, 10000000000), flags := (0, 0) }
  negWitness := { caps := (8, 2), disk := (5000000000, 10000000000), flags := (0, 0) }
  nonVacuous := by decide
  tight := by decide

def nodeCapacityConserved : ConservedResource NodeCapacityDiskCheck where
  admit := nodeCapacityDiskMetaGate.gate
  withinBudget c := c.caps.1.toNat ≤ maxWorkerSlots ∧ c.caps.2.toNat ≤ maxCoordinatorSlots
  conserved c h := by
    rcases nodeCapacityDiskMetaGate.sound c h with ⟨_, hc2, _, hcc2, _⟩
    exact ⟨hc2, hcc2⟩

theorem node_capacity_disk_rejects_pressure
    (cap ccap : UInt32) (freeB floorB : UInt64)
    (h_low : freeB.toNat < floorB.toNat) :
    verifyNodeCapacityDisk cap ccap freeB floorB 0 0 = 0 := by
  have hbad : ¬ NodeCapacityDiskDomainSafe ⟨(cap, ccap), (freeB, floorB), (0, 0)⟩ := by
    rintro ⟨_, _, _, _, hdisk⟩
    dsimp at hdisk
    have hfl := hdisk (by decide) (by decide)
    omega
  have hf := nodeCapacityDiskMetaGate.rejects_unsafe ⟨(cap, ccap), (freeB, floorB), (0, 0)⟩ hbad
  unfold nodeCapacityDiskMetaGate at hf; dsimp at hf
  unfold verifyNodeCapacityDisk at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 4. Bounded Log Chunk Frame Parser (`GET /jobs/:id/log`, `<= 256 KiB`) -/

/-- Parse a 4-byte big-endian chunk length header + log slice (`1 ≤ len ≤ 262144`). -/
def parseLogChunkFrame (raw : ByteArray) : Option ByteArray :=
  if raw.size < 5 then none
  else
    let b0 := (raw.get! 0).toUInt32
    let b1 := (raw.get! 1).toUInt32
    let b2 := (raw.get! 2).toUInt32
    let b3 := (raw.get! 3).toUInt32
    let chunkLen := ((b0 <<< 24) ||| (b1 <<< 16) ||| (b2 <<< 8) ||| b3).toNat
    if 1 ≤ chunkLen && chunkLen ≤ 262144 && 4 + chunkLen ≤ raw.size then
      let sub := raw.extract 4 (4 + chunkLen)
      if sub.size ≤ 262144 then some sub else none
    else
      none

def logChunkFrameParserSpec : TotalSliceParserSpec ByteArray where
  maxCap := 262144
  parse := parseLogChunkFrame
  byteLen := ByteArray.size
  bounded raw out h := by
    unfold parseLogChunkFrame at h
    split at h
    · contradiction
    · dsimp at h
      split at h
      · split at h
        · injection h with h_eq
          subst h_eq
          assumption
        · contradiction
      · contradiction
  posRaw := ByteArray.mk #[0, 0, 0, 3, 111, 107, 10]
  negRaw := ByteArray.mk #[0, 4, 0, 1, 111]
  nonVacuous := by decide
  tight := by decide

theorem log_chunk_frame_bounded
    (raw out : ByteArray)
    (h : parseLogChunkFrame raw = some out) :
    out.size ≤ 262144 :=
  logChunkFrameParserSpec.bounded raw out h

/-! ### 5. Flock-Ordered Durable Upload Finalizer (`SM-22`, `R1-04`) -/

inductive UploadFinalizePhase where
  | staging
  | destDurable
  | metaReceiptDurable
  | chunksUnlinked
  deriving Repr, DecidableEq

/-- Decode a finalize phase code: `0` staging, `1` dest durable, `2` meta receipt durable, `3` chunks unlinked. -/
def UploadFinalizePhase.decode? : Nat → Option UploadFinalizePhase
  | 0 => some .staging
  | 1 => some .destDurable
  | 2 => some .metaReceiptDurable
  | 3 => some .chunksUnlinked
  | _ => none

structure UploadFinalizeCheck where
  flags : UInt8 × UInt8 × UInt8
  phase : UInt8
  deriving Repr, DecidableEq

/-- Independent durable-upload resource specification (`ConservedResource`):
    chunks may be unlinked only while the exclusive session lock is held, the destination
    bytes are durable, and the `meta.json` receipt is durable. Every earlier phase conserves
    the chunk set. -/
def UploadFinalizeDomainSafe (c : UploadFinalizeCheck) : Prop :=
  ∃ phase : UploadFinalizePhase,
    UploadFinalizePhase.decode? c.phase.toNat = some phase ∧
    (phase = .chunksUnlinked →
      c.flags.1.toNat = 1 ∧ c.flags.2.1.toNat = 1 ∧ c.flags.2.2.toNat = 1)

@[inline, export orb_node_verify_upload_finalize]
def verifyUploadFinalizeOrder
    (sessionLockHeld : UInt8)
    (destDurable : UInt8)
    (metaReceiptDurable : UInt8)
    (phaseCode : UInt8) : UInt8 :=
  if phaseCode ≤ 2 ||
     (phaseCode == 3 && sessionLockHeld == 1 && destDurable == 1 && metaReceiptDurable == 1) then 1 else 0

def uploadFinalizeMetaGate : MetaGateSpec UploadFinalizeCheck UploadFinalizeDomainSafe where
  gate c :=
    verifyUploadFinalizeOrder c.flags.1 c.flags.2.1 c.flags.2.2 c.phase == 1
  sound c h := by
    rcases c with ⟨⟨lk, dest, metaDur⟩, ph⟩
    change (verifyUploadFinalizeOrder lk dest metaDur ph == 1) = true at h
    dsimp [UploadFinalizeDomainSafe]
    unfold verifyUploadFinalizeOrder at h
    have hc : (ph ≤ 2 || (ph == 3 && lk == 1 && dest == 1 && metaDur == 1)) = true := by
      cases hb : (ph ≤ 2 || (ph == 3 && lk == 1 && dest == 1 && metaDur == 1))
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with hle | ⟨⟨⟨hph, hlk⟩, hdest⟩, hmeta⟩
    · have hpn : ph.toNat ≤ 2 := UInt8.le_iff_toNat_le.mp hle
      have hcases : ph.toNat = 0 ∨ ph.toNat = 1 ∨ ph.toNat = 2 := by omega
      rcases hcases with h0 | h1 | h2
      · exact ⟨.staging, by simp [UploadFinalizePhase.decode?, h0], by intro hp; cases hp⟩
      · exact ⟨.destDurable, by simp [UploadFinalizePhase.decode?, h1], by intro hp; cases hp⟩
      · exact ⟨.metaReceiptDurable, by simp [UploadFinalizePhase.decode?, h2], by intro hp; cases hp⟩
    · subst hph
      refine ⟨.chunksUnlinked, by simp [UploadFinalizePhase.decode?], fun _ => ?_⟩
      refine ⟨?_, ?_, ?_⟩
      · subst hlk
        rfl
      · subst hdest
        rfl
      · subst hmeta
        rfl
  complete c h := by
    rcases c with ⟨⟨lk, dest, metaDur⟩, ph⟩
    change (verifyUploadFinalizeOrder lk dest metaDur ph == 1) = true
    dsimp [UploadFinalizeDomainSafe] at h
    rcases h with ⟨phase, hdec, hunlink⟩
    unfold verifyUploadFinalizeOrder
    unfold UploadFinalizePhase.decode? at hdec
    split at hdec
    · injection hdec with hp; subst hp
      have hp0 : ph = 0 := u8_eq_of_toNat ph 0 (by omega) ‹_›
      subst hp0; simp
    · injection hdec with hp; subst hp
      have hp1 : ph = 1 := u8_eq_of_toNat ph 1 (by omega) ‹_›
      subst hp1; simp
    · injection hdec with hp; subst hp
      have hp2 : ph = 2 := u8_eq_of_toNat ph 2 (by omega) ‹_›
      subst hp2; simp
    · injection hdec with hp; subst hp
      have hp3 : ph = 3 := u8_eq_of_toNat ph 3 (by omega) ‹_›
      rcases hunlink rfl with ⟨hlk, hdest, hmeta⟩
      have hlkB : (lk == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat lk 1 (by omega) hlk
      have hdestB : (dest == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat dest 1 (by omega) hdest
      have hmetaB : (metaDur == 1) = true := by rw [beq_iff_eq]; exact u8_eq_of_toNat metaDur 1 (by omega) hmeta
      subst hp3; simp [hlkB, hdestB, hmetaB]
    · contradiction
  posWitness := { flags := (1, 1, 1), phase := 3 }
  negWitness := { flags := (1, 1, 0), phase := 3 }
  nonVacuous := by decide
  tight := by decide

def uploadFinalizeConserved : ConservedResource UploadFinalizeCheck where
  admit := uploadFinalizeMetaGate.gate
  withinBudget c :=
    c.phase.toNat ≠ 3 ∨ (c.flags.1.toNat = 1 ∧ c.flags.2.1.toNat = 1 ∧ c.flags.2.2.toNat = 1)
  conserved c h := by
    rcases uploadFinalizeMetaGate.sound c h with ⟨phase, hdec, hunlink⟩
    cases phase with
    | staging =>
      left
      intro hp
      simp [UploadFinalizePhase.decode?, hp] at hdec
    | destDurable =>
      left
      intro hp
      simp [UploadFinalizePhase.decode?, hp] at hdec
    | metaReceiptDurable =>
      left
      intro hp
      simp [UploadFinalizePhase.decode?, hp] at hdec
    | chunksUnlinked =>
      right
      exact hunlink rfl

theorem upload_finalize_rejects_unlink_before_receipt
    (sessionLockHeld destDurable : UInt8) :
    verifyUploadFinalizeOrder sessionLockHeld destDurable 0 3 = 0 := by
  have hbad : ¬ UploadFinalizeDomainSafe ⟨(sessionLockHeld, destDurable, 0), 3⟩ := by
    rintro ⟨phase, hdec, hunlink⟩
    cases phase <;> simp [UploadFinalizePhase.decode?] at hdec hunlink
  have hf := uploadFinalizeMetaGate.rejects_unsafe ⟨(sessionLockHeld, destDurable, 0), 3⟩ hbad
  unfold uploadFinalizeMetaGate at hf; dsimp at hf
  unfold verifyUploadFinalizeOrder at hf ⊢
  exact bit_gate_eq_zero hf

/-! ### 6. CAS Workspace Build Admission (`SM-22`, `R1-05`) -/

structure WorkspaceBuildAdmitCheck where
  activeBuilds : UInt32
  gens         : UInt64 × UInt64
  validId      : UInt8
  deriving Repr, DecidableEq

/-- Independent single-flight workspace-build specification (`ConservedResource`):
    a build is admitted only for a valid workspace id, only when no build is already active,
    and only for the non-wrapping successor generation `currentGen + 1`. -/
def WorkspaceBuildAdmitDomainSafe (c : WorkspaceBuildAdmitCheck) : Prop :=
  c.activeBuilds.toNat = 0 ∧
  c.gens.2.toNat + 1 = c.gens.1.toNat ∧
  c.validId.toNat = 1

@[inline, export orb_node_verify_workspace_build_admit]
def verifyWorkspaceBuildAdmit
    (activeBuildsForWorkspace : UInt32)
    (presentedGen : UInt64)
    (currentGen : UInt64)
    (validWorkspaceId : UInt8) : UInt8 :=
  if activeBuildsForWorkspace == 0 &&
     currentGen < 0xFFFFFFFFFFFFFFFF &&
     presentedGen == currentGen + 1 &&
     validWorkspaceId == 1 then 1 else 0

def workspaceBuildAdmitMetaGate : MetaGateSpec WorkspaceBuildAdmitCheck WorkspaceBuildAdmitDomainSafe where
  gate c :=
    verifyWorkspaceBuildAdmit c.activeBuilds c.gens.1 c.gens.2 c.validId == 1
  sound c h := by
    rcases c with ⟨active, ⟨pres, cur⟩, valid⟩
    change (verifyWorkspaceBuildAdmit active pres cur valid == 1) = true at h
    dsimp [WorkspaceBuildAdmitDomainSafe]
    unfold verifyWorkspaceBuildAdmit at h
    have hc : (active == 0 && cur < 0xFFFFFFFFFFFFFFFF && pres == cur + 1 && valid == 1) = true := by
      cases hb : (active == 0 && cur < 0xFFFFFFFFFFFFFFFF && pres == cur + 1 && valid == 1)
      · rw [hb] at h; contradiction
      · rfl
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
    rcases hc with ⟨⟨⟨hact, hcurLt⟩, hgen⟩, hvalid⟩
    refine ⟨?_, ?_, ?_⟩
    · have h0 : active = 0 := hact
      change active.toNat = 0
      rw [h0]; rfl
    · have hlt : cur.toNat < 18446744073709551615 := UInt64.lt_iff_toNat_lt.mp hcurLt
      have hsucc : pres = cur + 1 := hgen
      have hnat : pres.toNat = cur.toNat + 1 := by
        have hwrap : (cur + 1).toNat = cur.toNat + 1 := by
          change (cur.toNat + 1) % 18446744073709551616 = cur.toNat + 1
          exact Nat.mod_eq_of_lt (by omega)
        rw [hsucc, hwrap]
      omega
    · subst hvalid; rfl
  complete c h := by
    rcases c with ⟨active, ⟨pres, cur⟩, valid⟩
    change (verifyWorkspaceBuildAdmit active pres cur valid == 1) = true
    dsimp [WorkspaceBuildAdmitDomainSafe] at h
    rcases h with ⟨hact, hgen, hvalid⟩
    unfold verifyWorkspaceBuildAdmit
    have hactB : (active == 0) = true := by
      rw [beq_iff_eq]
      apply UInt32.eq_of_toBitVec_eq
      apply BitVec.eq_of_toNat_eq
      change active.toNat = 0
      exact hact
    have hpresLt : pres.toNat < 18446744073709551616 := UInt64.toNat_lt pres
    have hcurLt : cur < 0xFFFFFFFFFFFFFFFF := by
      apply UInt64.lt_iff_toNat_lt.mpr
      change cur.toNat < 18446744073709551615
      omega
    have hpres : pres = cur + 1 := by
      apply UInt64.eq_of_toBitVec_eq
      apply BitVec.eq_of_toNat_eq
      have hwrap : (cur + 1).toNat = cur.toNat + 1 := by
        change (cur.toNat + 1) % 18446744073709551616 = cur.toNat + 1
        exact Nat.mod_eq_of_lt (by omega)
      change pres.toNat = (cur + 1).toNat
      rw [hwrap]
      omega
    have hvalidB : (valid == 1) = true := by
      rw [beq_iff_eq]; exact u8_eq_of_toNat valid 1 (by omega) hvalid
    simp [hactB, hcurLt, hpres, hvalidB]
  posWitness := { activeBuilds := 0, gens := (1, 0), validId := 1 }
  negWitness := { activeBuilds := 1, gens := (1, 0), validId := 1 }
  nonVacuous := by decide
  tight := by decide

def workspaceBuildConserved : ConservedResource WorkspaceBuildAdmitCheck where
  admit := workspaceBuildAdmitMetaGate.gate
  withinBudget c := c.activeBuilds.toNat = 0
  conserved c h := (workspaceBuildAdmitMetaGate.sound c h).1

theorem workspace_build_rejects_active
    (activeBuilds : UInt32)
    (presentedGen currentGen : UInt64) (validWorkspaceId : UInt8)
    (h_busy : activeBuilds.toNat ≠ 0) :
    verifyWorkspaceBuildAdmit activeBuilds presentedGen currentGen validWorkspaceId = 0 := by
  have hbad : ¬ WorkspaceBuildAdmitDomainSafe ⟨activeBuilds, (presentedGen, currentGen), validWorkspaceId⟩ := by
    rintro ⟨hact, _, _⟩
    exact h_busy hact
  have hf :=
    workspaceBuildAdmitMetaGate.rejects_unsafe
      ⟨activeBuilds, (presentedGen, currentGen), validWorkspaceId⟩ hbad
  unfold workspaceBuildAdmitMetaGate at hf; dsimp at hf
  unfold verifyWorkspaceBuildAdmit at hf ⊢
  exact bit_gate_eq_zero hf

end OrbNode.Spec
