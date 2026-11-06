/-
  OrbNetLeaf.Crypto: Verified AEAD (`AES-256-GCM`, `ChaCha20-Poly1305`, `AES-128-GCM`),
  RFC 9001 QUIC Header Protection (`AES-128-ECB`, `ChaCha20`) & 1-RTT packet seal/open,
  `Ed25519` signing/verification, `X25519` ECDH, and CSPRNG primitives over
  `orb_net_leaf.c`, strictly gated by `OrbNetLeaf.Spec`.
-/
import LeanSys.Spec
import LeanSys.Posix
import LeanSys.Quic
import OrbNetLeaf.Spec

namespace OrbNetLeaf.Crypto

open LeanSys.Spec
open LeanSys.Posix
open LeanSys.Quic
open OrbNetLeaf.Spec

@[extern "orb_net_leaf_rand_bytes"]
private opaque rawRandBytes (n : USize) : IO ByteArray

@[extern "orb_net_leaf_aead"]
private opaque rawAead
    (alg enc : UInt8)
    (key nonce aad buf : @& ByteArray) : IO ByteArray

@[extern "orb_net_leaf_quic_hp_mask"]
private opaque rawQuicHpMask
    (hpAlg : UInt8)
    (hpKey sample16 : @& ByteArray) : IO ByteArray

@[extern "orb_net_leaf_ed_x25519"]
private opaque rawEdX25519
    (op : UInt8)
    (k1 k2 msg : @& ByteArray) : IO ByteArray

inductive AeadAlg where
  | aes256Gcm
  | chacha20Poly1305
  | aes128Gcm
  deriving Repr, DecidableEq, BEq, Inhabited

@[inline]
def AeadAlg.code : AeadAlg → UInt8
  | .aes256Gcm => 0
  | .chacha20Poly1305 => 1
  | .aes128Gcm => 2

inductive QuicHpAlg where
  | aes128Ecb
  | chacha20
  deriving Repr, DecidableEq, BEq, Inhabited

@[inline]
def QuicHpAlg.code : QuicHpAlg → UInt8
  | .aes128Ecb => 0
  | .chacha20 => 1

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

/-- RFC 9001 §5.3: Derive per-packet 12-byte QUIC AEAD nonce by XORing `iv12` with big-endian `pktNum`. -/
def deriveQuicPacketNonce (iv12 : ByteArray) (pktNum : UInt64) : Option ByteArray :=
  if iv12.size != 12 then none
  else Id.run do
    let mut nonce := ByteArray.emptyWithCapacity 12
    for i in [0:4] do
      nonce := nonce.push (iv12.get! i)
    for i in [0:8] do
      let shift := ((7 - i) * 8).toUInt64
      let pnByte := ((pktNum >>> shift) &&& 0xFF).toUInt8
      nonce := nonce.push ((iv12.get! (4 + i)) ^^^ pnByte)
    return some nonce

/-- RFC 9001 §5.4: Compute 5-byte QUIC header protection mask gated by `verifyQuicHpMask`. -/
def quicHpMask (hpAlg : QuicHpAlg) (hpKey sample16 : ByteArray) : IO (Except String ByteArray) := do
  if verifyQuicHpMask hpAlg.code hpKey.size.toUInt64 sample16.size.toUInt64 != 1 then
    return .error "quicHpMask rejected by verifyQuicHpMask"
  let mask ← rawQuicHpMask hpAlg.code hpKey sample16
  if mask.size == 5 then
    return .ok mask
  else
    return .error "QUIC header protection mask generation failed"

/-- RFC 9000 Appendix A.3: Reconstruct full 62-bit packet number from an `8/16/24/32`-bit
    truncated wire packet number relative to `largestRxPn?`. -/
def reconstructQuicPacketNumber (largestRxPn? : Option UInt64) (truncPn : UInt64) (pnBits : Nat) : UInt64 :=
  match largestRxPn? with
  | none => truncPn
  | some largestPn =>
    let expectedPn := largestPn + 1
    let pnWin : UInt64 := (1 : UInt64) <<< pnBits.toUInt64
    let pnHwin : UInt64 := pnWin >>> 1
    let pnMask : UInt64 := pnWin - 1
    let maxSpace : UInt64 := (1 : UInt64) <<< 62
    let candPn : UInt64 := (expectedPn &&& (~~~pnMask)) ||| (truncPn &&& pnMask)
    if expectedPn ≥ pnHwin && candPn ≤ expectedPn - pnHwin && candPn < maxSpace - pnWin then
      candPn + pnWin
    else if candPn > expectedPn + pnHwin && candPn ≥ pnWin then
      candPn - pnWin
    else
      candPn

/-- RFC 9001 §5.3 + §5.4: Seal and header-protect an outbound 1-RTT `QuicShortPacket` with explicit
    packet-number length `pnLen ∈ {1, 2, 3, 4}` (automatically zero-padding payload with RFC 9000 `PADDING`
    frames if `pnLen < 4` and `pnLen + payload.size < 4` per RFC 9001 §5.4.2). -/
def sealQuicShortPacketWithPnLen
    (aeadAlg : AeadAlg) (hpAlg : QuicHpAlg)
    (aeadKey iv12 hpKey : ByteArray)
    (pkt : QuicShortPacket) (pnLen : Nat := 4) : IO (Except String ByteArray) := do
  if pnLen < 1 || pnLen > 4 || pkt.pktNum > maxVarInt then
    return .error "invalid QUIC packet number or pnLen"
  let minPayload := if pnLen < 4 then 4 - pnLen else 0
  let paddedPayload := Id.run do
    if pkt.payload.size >= minPayload then
      return pkt.payload
    let mut p := pkt.payload
    for _ in [0:(minPayload - pkt.payload.size)] do
      p := p.push 0x00
    return p
  let b0 : UInt8 := 0x40 ||| (if pkt.keyPhase then 0x04 else 0x00) ||| (pnLen - 1).toUInt8
  let hdrLen := 9 + pnLen
  let clearHdr := Id.run do
    let mut h := ByteArray.emptyWithCapacity hdrLen
    h := h.push b0
    for i in [0:8] do
      let sh := ((7 - i) * 8).toUInt64
      h := h.push ((pkt.dcid >>> sh) &&& 0xFF).toUInt8
    for i in [0:pnLen] do
      let sh := ((pnLen - 1 - i) * 8).toUInt64
      h := h.push ((pkt.pktNum >>> sh) &&& 0xFF).toUInt8
    return h
  let some nonce := deriveQuicPacketNonce iv12 pkt.pktNum
    | return .error "invalid 12-byte QUIC IV"
  let ctTag ← match ← aeadSeal aeadAlg aeadKey nonce clearHdr paddedPayload with
    | .ok c => pure c
    | .error e => return .error e
  let raw := clearHdr ++ ctTag
  if verifySliceBounds 13 16 raw.size.toUInt64 != 1 then
    return .error "QUIC ciphertext shorter than 16-byte HP sample"
  let sample16 := raw.extract 13 29
  let mask5 ← match ← quicHpMask hpAlg hpKey sample16 with
    | .ok m => pure m
    | .error e => return .error e
  let mut wire := ByteArray.emptyWithCapacity raw.size
  wire := wire.push ((clearHdr.get! 0) ^^^ ((mask5.get! 0) &&& 0x1F))
  for i in [1:9] do
    wire := wire.push (clearHdr.get! i)
  for i in [0:pnLen] do
    wire := wire.push ((clearHdr.get! (9 + i)) ^^^ (mask5.get! (1 + i)))
  for i in [0:ctTag.size] do
    wire := wire.push (ctTag.get! i)
  return .ok wire

/-- RFC 9001 §5.3 + §5.4: Seal and header-protect an outbound 1-RTT `QuicShortPacket` (`pnLen = 4`). -/
def sealQuicShortPacket
    (aeadAlg : AeadAlg) (hpAlg : QuicHpAlg)
    (aeadKey iv12 hpKey : ByteArray)
    (pkt : QuicShortPacket) : IO (Except String ByteArray) :=
  sealQuicShortPacketWithPnLen aeadAlg hpAlg aeadKey iv12 hpKey pkt 4

/-- RFC 9001 §5.4 + §5.3 & RFC 9000 §17.3 / Appendix A.3: Remove header protection, support all `1..4`-byte
    packet-number encodings, reconstruct full 62-bit packet number, and AEAD-open an inbound 1-RTT short-header
    QUIC datagram (`≥ 29` bytes = `9`B prefix + `4`B sample offset + `16`B sample). -/
def openQuicShortPacketEx
    (aeadAlg : AeadAlg) (hpAlg : QuicHpAlg)
    (aeadKey iv12 hpKey : ByteArray)
    (wire : ByteArray) (largestRxPn? : Option UInt64 := none) :
    IO (Except String QuicShortPacket) := do
  if verifySliceBounds 13 16 wire.size.toUInt64 != 1 then
    return .error "truncated QUIC 1-RTT datagram (< 29 bytes)"
  let sample16 := wire.extract 13 29
  let mask5 ← match ← quicHpMask hpAlg hpKey sample16 with
    | .ok m => pure m
    | .error e => return .error e
  let b0 := (wire.get! 0) ^^^ ((mask5.get! 0) &&& 0x1F)
  if (b0 &&& 0x80) != 0 || (b0 &&& 0x40) == 0 || (b0 &&& 0x18) != 0 then
    return .error "malformed QUIC 1-RTT short header or nonzero reserved bits"
  let pnLen := (b0 &&& 0x03).toNat + 1
  let hdrLen := 9 + pnLen
  if verifySliceBounds hdrLen.toUInt64 16 wire.size.toUInt64 != 1 then
    return .error "truncated QUIC 1-RTT ciphertext/tag"
  let mut clearHdr := ByteArray.emptyWithCapacity hdrLen
  clearHdr := clearHdr.push b0
  let mut dcid : UInt64 := 0
  for i in [1:9] do
    let wb := wire.get! i
    clearHdr := clearHdr.push wb
    dcid := (dcid <<< 8) ||| wb.toUInt64
  let mut truncPn : UInt64 := 0
  for i in [0:pnLen] do
    let pb := (wire.get! (9 + i)) ^^^ (mask5.get! (1 + i))
    clearHdr := clearHdr.push pb
    truncPn := (truncPn <<< 8) ||| pb.toUInt64
  let fullPn := reconstructQuicPacketNumber largestRxPn? truncPn (pnLen * 8)
  if fullPn > maxVarInt then
    return .error "reconstructed QUIC packet number exceeds 62-bit RFC 9000 space"
  let some nonce := deriveQuicPacketNonce iv12 fullPn
    | return .error "invalid 12-byte QUIC IV"
  let ctTag := wire.extract hdrLen wire.size
  match ← aeadOpen aeadAlg aeadKey nonce clearHdr ctTag with
  | .ok pt =>
    return .ok {
      dcid := dcid
      pktNum := fullPn
      keyPhase := (b0 &&& 0x04) != 0
      payload := pt
    }
  | .error e => return .error e

/-- Backwards-compatible wrapper reconstructing relative to `some largestRxPktNum` (or `none` when `0` and first packet). -/
def openQuicShortPacket
    (aeadAlg : AeadAlg) (hpAlg : QuicHpAlg)
    (aeadKey iv12 hpKey : ByteArray)
    (wire : ByteArray) (largestRxPktNum : UInt64 := 0) :
    IO (Except String QuicShortPacket) :=
  openQuicShortPacketEx aeadAlg hpAlg aeadKey iv12 hpKey wire (some largestRxPktNum)

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

/-- Derive 32-byte X25519 public key from 32-byte secret scalar (`op = 3, peer = empty`). -/
def x25519PublicKey (secret32 : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 3 secret32.size.toUInt64 0 0 != 1 then
    return .error "x25519PublicKey rejected by verifyAsymOp"
  let pub ← rawEdX25519 3 secret32 ByteArray.empty ByteArray.empty
  if pub.size == 32 then return .ok pub
  else return .error "X25519 public-key derivation failed"

/-- Compute 32-byte X25519 shared secret between `secret32` and `peerPub32` (`op = 4`). -/
def x25519SharedSecret (secret32 peerPub32 : ByteArray) : IO (Except String ByteArray) := do
  if verifyAsymOp 4 secret32.size.toUInt64 peerPub32.size.toUInt64 0 != 1 then
    return .error "x25519SharedSecret rejected by verifyAsymOp"
  let shared ← rawEdX25519 4 secret32 peerPub32 ByteArray.empty
  if shared.size == 32 then return .ok shared
  else return .error "X25519 key agreement failed"

end OrbNetLeaf.Crypto
