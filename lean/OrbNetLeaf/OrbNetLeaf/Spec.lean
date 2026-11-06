/-
  OrbNetLeaf.Spec: Composable Spec Blocks (`0 import Lean`, `0 sorryAx`) for
  AEAD envelope framing, Ed25519/X25519 key-material & signature admission,
  PTY window geometry bounds, and WebPKI outbound HTTPS/H2/H3 request framing.
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

/-! ## Spec Block 1: `AeadEnvelopeSpec` (`AES-256-GCM` / `ChaCha20-Poly1305`) -/

/-- Direct unboxed C-ABI gate for AEAD seal/open envelope lengths:
    - `alg ≤ 1` (`0` = AES-256-GCM, `1` = ChaCha20-Poly1305)
    - `enc ≤ 1` (`1` = seal, `0` = open)
    - `keyLen == 32`, `nonceLen == 12`, `aadLen ≤ 16777216` (`16 MiB`)
    - `enc == 1`: `bufLen ≤ 67108848` (`64 MiB - 16`)
    - `enc == 0`: `16 ≤ bufLen ≤ 67108864` (`64 MiB`, includes 16-byte tag). -/
@[inline, export orb_net_verify_aead_envelope]
def verifyAeadEnvelope (alg enc : UInt8) (keyLen nonceLen aadLen bufLen : UInt64) : UInt8 :=
  if alg ≤ 1 && enc ≤ 1 && keyLen == 32 && nonceLen == 12 && aadLen ≤ 16777216 &&
     (if enc == 1 then bufLen ≤ 67108848 else bufLen ≥ 16 && bufLen ≤ 67108864) then 1 else 0

structure AeadEnvelopeInput where
  flags : UInt8 × UInt8
  lens  : UInt64 × UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

@[inline]
def aeadEnvelopeSafe (x : AeadEnvelopeInput) : Bool :=
  x.flags.1 ≤ 1 && x.flags.2 ≤ 1 && x.lens.1 == 32 && x.lens.2.1 == 12 && x.lens.2.2.1 ≤ 16777216 &&
  (if x.flags.2 == 1 then x.lens.2.2.2 ≤ 67108848 else x.lens.2.2.2 ≥ 16 && x.lens.2.2.2 ≤ 67108864)

def aeadEnvelopeMetaSpec : MetaGateSpec AeadEnvelopeInput (fun x => aeadEnvelopeSafe x = true) where
  gate x :=
    verifyAeadEnvelope x.flags.1 x.flags.2 x.lens.1 x.lens.2.1 x.lens.2.2.1 x.lens.2.2.2 == 1
  sound x h := by
    unfold verifyAeadEnvelope at h
    unfold aeadEnvelopeSafe
    split at h <;> simp_all
  complete x h := by
    unfold aeadEnvelopeSafe at h
    unfold verifyAeadEnvelope
    split <;> simp_all
  posWitness := { flags := (0, 1), lens := (32, 12, 64, 1024) }
  negWitness := { flags := (0, 0), lens := (32, 12, 0, 15) }
  nonVacuous := by decide
  tight := by decide

theorem aead_envelope_rejects_short_tag_or_bad_key (x : AeadEnvelopeInput)
    (h_bad : aeadEnvelopeSafe x = false) :
    (verifyAeadEnvelope x.flags.1 x.flags.2
      x.lens.1 x.lens.2.1 x.lens.2.2.1 x.lens.2.2.2 == 1) = false :=
  aeadEnvelopeMetaSpec.rejects_unsafe x (by simp [h_bad])

/-! ## Spec Block 2: `Ed25519X25519GateSpec` (Signature & ECDH Key Discipline) -/

/-- Direct unboxed C-ABI gate for Ed25519 / X25519 operations:
    - `op == 0` (Ed25519 pubkey from seed): `k1Len == 32`, `k2Len == 0`, `msgLen == 0`
    - `op == 1` (Ed25519 sign): `k1Len == 32`, `k2Len == 0`, `msgLen ≤ 16777216`
    - `op == 2` (Ed25519 verify): `k1Len == 32`, `k2Len == 64`, `msgLen ≤ 16777216`
    - `op == 3` (X25519 pub/DH): `k1Len == 32`, `(k2Len == 0 || k2Len == 32)`, `msgLen == 0`. -/
@[inline, export orb_net_verify_asym_op]
def verifyAsymOp (op : UInt8) (k1Len k2Len msgLen : UInt64) : UInt8 :=
  if (if op == 0 then k1Len == 32 && k2Len == 0 && msgLen == 0
      else if op == 1 then k1Len == 32 && k2Len == 0 && msgLen ≤ 16777216
      else if op == 2 then k1Len == 32 && k2Len == 64 && msgLen ≤ 16777216
      else if op == 3 then k1Len == 32 && (k2Len == 0 || k2Len == 32) && msgLen == 0
      else false) then 1 else 0

structure AsymOpInput where
  op   : UInt8
  lens : UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

@[inline]
def asymOpSafe (x : AsymOpInput) : Bool :=
  if x.op == 0 then x.lens.1 == 32 && x.lens.2.1 == 0 && x.lens.2.2 == 0
  else if x.op == 1 then x.lens.1 == 32 && x.lens.2.1 == 0 && x.lens.2.2 ≤ 16777216
  else if x.op == 2 then x.lens.1 == 32 && x.lens.2.1 == 64 && x.lens.2.2 ≤ 16777216
  else if x.op == 3 then x.lens.1 == 32 && (x.lens.2.1 == 0 || x.lens.2.1 == 32) && x.lens.2.2 == 0
  else false

def asymOpMetaSpec : MetaGateSpec AsymOpInput (fun x => asymOpSafe x = true) where
  gate x := verifyAsymOp x.op x.lens.1 x.lens.2.1 x.lens.2.2 == 1
  sound x h := by
    unfold verifyAsymOp at h
    unfold asymOpSafe
    split at h <;> simp_all
  complete x h := by
    unfold asymOpSafe at h
    unfold verifyAsymOp
    split <;> simp_all
  posWitness := { op := 2, lens := (32, 64, 512) }
  negWitness := { op := 2, lens := (32, 63, 512) }
  nonVacuous := by decide
  tight := by decide

theorem asym_op_rejects_malformed_lengths (x : AsymOpInput)
    (h_bad : asymOpSafe x = false) :
    (verifyAsymOp x.op x.lens.1 x.lens.2.1 x.lens.2.2 == 1) = false :=
  asymOpMetaSpec.rejects_unsafe x (by simp [h_bad])

/-! ## Spec Block 3: `OutboundRequestBoundsSpec` & `PtyWindowBoundsSpec` -/

/-- Direct unboxed C-ABI gate for outbound HTTPS / HTTP/2 / HTTP/3 request framing:
    - Non-empty hostname `1 ≤ hostLen ≤ 253`, `noHostCrLf == 1`
    - Valid port `1 ≤ port ≤ 65535`
    - Bounded request & response budgets (`1 ≤ maxRespBytes ≤ 67108864`, `reqBytes ≤ 67108864`)
    - Explicit TLS verification mode (`verifyPeer ≤ 1`). -/
@[inline, export orb_net_verify_outbound_request]
def verifyOutboundRequest
    (noHostCrLf verifyPeer : UInt8) (port : UInt32)
    (hostLen reqBytes maxRespBytes : UInt64) : UInt8 :=
  if noHostCrLf == 1 && verifyPeer ≤ 1 &&
     port ≥ 1 && port ≤ 65535 &&
     hostLen ≥ 1 && hostLen ≤ 253 &&
     reqBytes ≤ 67108864 &&
     maxRespBytes ≥ 1 && maxRespBytes ≤ 67108864 then 1 else 0

structure OutboundRequestInput where
  flags : UInt8 × UInt8
  port  : UInt32
  lens  : UInt64 × UInt64 × UInt64
  deriving Repr, DecidableEq

@[inline]
def outboundRequestSafe (x : OutboundRequestInput) : Bool :=
  x.flags.1 == 1 && x.flags.2 ≤ 1 &&
  x.port ≥ 1 && x.port ≤ 65535 &&
  x.lens.1 ≥ 1 && x.lens.1 ≤ 253 &&
  x.lens.2.1 ≤ 67108864 &&
  x.lens.2.2 ≥ 1 && x.lens.2.2 ≤ 67108864

def outboundRequestMetaSpec :
    MetaGateSpec OutboundRequestInput (fun x => outboundRequestSafe x = true) where
  gate x :=
    verifyOutboundRequest x.flags.1 x.flags.2 x.port
      x.lens.1 x.lens.2.1 x.lens.2.2 == 1
  sound x h := by
    unfold verifyOutboundRequest at h
    unfold outboundRequestSafe
    split at h <;> simp_all
  complete x h := by
    unfold outboundRequestSafe at h
    unfold verifyOutboundRequest
    split <;> simp_all
  posWitness := { flags := (1, 1), port := 443, lens := (14, 256, 1048576) }
  negWitness := { flags := (0, 1), port := 443, lens := (14, 256, 1048576) }
  nonVacuous := by decide
  tight := by decide

theorem outbound_request_rejects_crlf_or_unbounded_resp (x : OutboundRequestInput)
    (h_bad : outboundRequestSafe x = false) :
    (verifyOutboundRequest x.flags.1 x.flags.2 x.port
      x.lens.1 x.lens.2.1 x.lens.2.2 == 1) = false :=
  outboundRequestMetaSpec.rejects_unsafe x (by simp [h_bad])

/-- Direct unboxed C-ABI gate for PTY window geometry (`1 ≤ rows, cols ≤ 1024`). -/
@[inline, export orb_net_verify_pty_window]
def verifyPtyWindow (rows cols : UInt32) : UInt8 :=
  if rows ≥ 1 && rows ≤ 1024 && cols ≥ 1 && cols ≤ 1024 then 1 else 0

theorem pty_window_rejects_zero_dims (cols : UInt32) :
    verifyPtyWindow 0 cols = 0 := by
  rfl

end OrbNetLeaf.Spec
