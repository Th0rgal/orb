/-
  OrbNetLeaf.MutantSuite: 3-mutant kill suite (`0 import Lean`, `0 sorryAx`)
  verifying that `OrbNetLeaf.Spec` gates strictly kill realistic cryptographic
  and network-framing boundary mutants.
-/
import OrbNetLeaf.Spec

namespace OrbNetLeaf.MutantSuite

open OrbNetLeaf.Spec

/-- Mutant 1 (`verifyAeadEnvelope`): Omits the 16-byte authentication tag floor
    on AEAD decryption (`enc == 0`), allowing truncated ciphertext underflow. -/
@[inline]
def m01_aeadOpenTruncatedTag (alg enc : UInt8) (keyLen nonceLen aadLen bufLen : UInt64) : UInt8 :=
  let algOk := alg ≤ 1 && enc ≤ 1
  let keyNonceOk := keyLen == 32 && nonceLen == 12 && aadLen ≤ 16777216
  let bufOk :=
    if enc == 1 then bufLen ≤ 67108848
    else bufLen ≤ 67108864
  if algOk && keyNonceOk && bufOk then 1 else 0

theorem kill_m01_aeadOpenTruncatedTag :
    m01_aeadOpenTruncatedTag 0 0 32 12 0 12 ≠
      verifyAeadEnvelope 0 0 32 12 0 12 := by
  decide

/-- Mutant 2 (`verifyAsymOp`): Accepts 32-byte signature length instead of 64-byte
    RFC 8032 signature length on `Ed25519` verify (`op == 2`). -/
@[inline]
def m02_ed25519VerifyHalfSig (op : UInt8) (k1Len k2Len msgLen : UInt64) : UInt8 :=
  let ok :=
    if op == 0 then k1Len == 32 && k2Len == 0 && msgLen == 0
    else if op == 1 then k1Len == 32 && k2Len == 0 && msgLen ≤ 16777216
    else if op == 2 then k1Len == 32 && k2Len ≥ 32 && msgLen ≤ 16777216
    else if op == 3 then k1Len == 32 && (k2Len == 0 || k2Len == 32) && msgLen == 0
    else false
  if ok then 1 else 0

theorem kill_m02_ed25519VerifyHalfSig :
    m02_ed25519VerifyHalfSig 2 32 32 128 ≠
      verifyAsymOp 2 32 32 128 := by
  decide

/-- Mutant 3 (`verifyOutboundRequest`): Weakens the SNI / `Host:` CR/LF injection
    guard from `noHostCrLf == 1` to `noHostCrLf ≤ 1` (admitting `0`). -/
@[inline, export orb_net_mut_m03]
def m03_outboundHostCrLfBypass
    (noHostCrLf verifyPeer : UInt8) (port : UInt32)
    (hostLen reqBytes maxRespBytes : UInt64) : UInt8 :=
  if noHostCrLf ≤ 1 && verifyPeer ≤ 1 &&
     port ≥ 1 && port ≤ 65535 &&
     hostLen ≥ 1 && hostLen ≤ 253 &&
     reqBytes ≤ 67108864 &&
     maxRespBytes ≥ 1 && maxRespBytes ≤ 67108864 then 1 else 0

theorem kill_m03_outboundHostCrLfBypass :
    m03_outboundHostCrLfBypass 0 1 443 16 128 4096 ≠
      verifyOutboundRequest 0 1 443 16 128 4096 := by
  decide

end OrbNetLeaf.MutantSuite
