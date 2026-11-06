/-
  OrbNetLeaf.Crypto: Verified AEAD (`AES-256-GCM`, `ChaCha20-Poly1305`),
  `Ed25519` signing/verification, role-separated `X25519` ECDH, and CSPRNG primitives
  over `orb_net_leaf.c`, strictly gated by `OrbNetLeaf.Spec`.
-/
import LeanSys.Spec
import OrbNetLeaf.Spec

namespace OrbNetLeaf.Crypto

open LeanSys.Spec
open OrbNetLeaf.Spec

@[extern "orb_net_leaf_rand_bytes"]
private opaque rawRandBytes (n : USize) : IO ByteArray

@[extern "orb_net_leaf_aead"]
private opaque rawAead
    (alg enc : UInt8)
    (key nonce aad buf : @& ByteArray) : IO ByteArray

@[extern "orb_net_leaf_ed_x25519"]
private opaque rawEdX25519
    (op : UInt8)
    (k1 k2 msg : @& ByteArray) : IO ByteArray

inductive AeadAlg where
  | aes256Gcm
  | chacha20Poly1305
  deriving Repr, DecidableEq, BEq, Inhabited

@[inline]
def AeadAlg.code : AeadAlg → UInt8
  | .aes256Gcm => 0
  | .chacha20Poly1305 => 1

/-- Generate `n` cryptographically secure random bytes (`1 ≤ n ≤ 16 MiB` or empty for `n = 0`). -/
def randBytes (n : Nat) : IO (Except String ByteArray) := do
  if n == 0 then
    return .ok ByteArray.empty
  if n > 16777216 then
    return .error s!"randBytes length {n} exceeds 16 MiB cap"
  let out ← rawRandBytes (USize.ofNat n)
  if out.size == n then
    return .ok out
  else
    return .error "OpenSSL RAND_bytes failed"

/-- Authenticated encryption (`pt -> ct || tag16`) gated by `verifyAeadEnvelope`. -/
def aeadSeal
    (alg : AeadAlg) (key nonce aad plaintext : ByteArray) :
    IO (Except String ByteArray) := do
  if verifyAeadEnvelope alg.code 1
      key.size.toUInt64 nonce.size.toUInt64
      aad.size.toUInt64 plaintext.size.toUInt64 != 1 then
    return .error "aeadSeal rejected by verifyAeadEnvelope"
  let out ← rawAead alg.code 1 key nonce aad plaintext
  if out.size == plaintext.size + 16 then
    return .ok out
  else
    return .error "AEAD seal failed"

/-- Authenticated decryption (`ct || tag16 -> pt`) gated by `verifyAeadEnvelope`. -/
def aeadOpen
    (alg : AeadAlg) (key nonce aad ciphertextAndTag : ByteArray) :
    IO (Except String ByteArray) := do
  if verifyAeadEnvelope alg.code 0
      key.size.toUInt64 nonce.size.toUInt64
      aad.size.toUInt64 ciphertextAndTag.size.toUInt64 != 1 then
    return .error "aeadOpen rejected by verifyAeadEnvelope"
  if ciphertextAndTag.size == 16 then
    -- Empty plaintext case: `orb_net_leaf_aead` returns a 1-byte `{1}` marker on valid tag
    -- verification and `0`-byte empty `ByteArray` on authentication failure.
    let out ← rawAead alg.code 0 key nonce aad ciphertextAndTag
    if out.size == 1 && verifySliceBounds 0 1 out.size.toUInt64 == 1 && out.get! 0 == 1 then
      return .ok ByteArray.empty
    else
      return .error "AEAD authentication tag mismatch"
  let out ← rawAead alg.code 0 key nonce aad ciphertextAndTag
  if out.size + 16 == ciphertextAndTag.size then
    return .ok out
  else
    return .error "AEAD authentication tag mismatch"

/-- Derive 32-byte Ed25519 public key from 32-byte private seed (`op = 0`). -/
def ed25519PublicKey (seed32 : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 0 seed32.size.toUInt64 0 0 != 1 then
    return .error "ed25519PublicKey rejected by verifyAsymOp"
  let pk ← rawEdX25519 0 seed32 ByteArray.empty ByteArray.empty
  if pk.size == 32 then return .ok pk
  else return .error "Ed25519 public-key derivation failed"

/-- Sign `msg` with 32-byte Ed25519 seed, returning 64-byte RFC 8032 signature (`op = 1`). -/
def ed25519Sign (seed32 msg : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 1 seed32.size.toUInt64 0 msg.size.toUInt64 != 1 then
    return .error "ed25519Sign rejected by verifyAsymOp"
  let sig ← rawEdX25519 1 seed32 ByteArray.empty msg
  if sig.size == 64 then return .ok sig
  else return .error "Ed25519 signing failed"

/-- Verify 64-byte Ed25519 signature `sig64` over `msg` under `pub32` (`op = 2`). -/
def ed25519Verify (pub32 sig64 msg : ByteArray) : IO Bool := do
  if verifyAsymOp 2 pub32.size.toUInt64 sig64.size.toUInt64 msg.size.toUInt64 != 1 then
    return false
  let res ← rawEdX25519 2 pub32 sig64 msg
  return res.size == 1 && verifySliceBounds 0 1 res.size.toUInt64 == 1 && res.get! 0 == 1

/-- Derive 32-byte X25519 public key from 32-byte secret scalar (`op = 3`). -/
def x25519PublicKey (secret32 : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 3 secret32.size.toUInt64 0 0 != 1 then
    return .error "x25519PublicKey rejected by verifyAsymOp"
  let pub ← rawEdX25519 3 secret32 ByteArray.empty ByteArray.empty
  if pub.size == 32 then return .ok pub
  else return .error "X25519 public-key derivation failed"

/-- Compute 32-byte X25519 shared secret between `secret32` and 32-byte `peerPub32` (`op = 4`).
    Role-separated from `x25519PublicKey` (`op = 3`) so an empty peer key is rejected fail-closed. -/
def x25519SharedSecret (secret32 peerPub32 : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 4 secret32.size.toUInt64 peerPub32.size.toUInt64 0 != 1 then
    return .error "x25519SharedSecret rejected by verifyAsymOp (requires 32-byte peer public key)"
  let shared ← rawEdX25519 4 secret32 peerPub32 ByteArray.empty
  if shared.size == 32 then return .ok shared
  else return .error "X25519 key agreement failed"

end OrbNetLeaf.Crypto
