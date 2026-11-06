/-
  OrbClient.Reducers: Pure State Reducers for Client Sync Cursors, Inbox Unread Counts & Stream Checkpoints.
-/
import OrbClient.Spec
import Std.Tactic.BVDecide

namespace OrbClient.Reducers

open OrbClient.Spec

structure SyncCursorState where
  epoch : UInt64 := 0
  seq   : UInt64 := 0
  deriving Repr, DecidableEq

/-- Advance `SyncCursorState` iff `verifyClientSyncCursor` admits `(incomingEpoch, incomingSeq)`. -/
@[inline]
def stepSyncCursor
    (cur : SyncCursorState)
    (incomingEpoch incomingSeq : UInt64)
    (frameValid authOk : UInt8) : Bool × SyncCursorState :=
  if verifyClientSyncCursor cur.epoch incomingEpoch cur.seq incomingSeq frameValid authOk == 1 then
    (true, { epoch := incomingEpoch, seq := incomingSeq })
  else
    (false, cur)

/-- Encode an `OrbWire` client patch envelope (`"ORBP"`, schema `1..255`, payload `1..65535`). -/
def encodeOrbClientPatch? (schema : UInt16) (payload : ByteArray) : Option ByteArray :=
  if schema < 1 || schema > 255 || payload.size < 1 || payload.size > 65535 then
    none
  else
    let len16 : UInt16 := UInt16.ofNat payload.size
    let hiS : UInt8 := ((schema >>> 8) &&& 0xFF).toUInt8
    let loS : UInt8 := (schema &&& 0xFF).toUInt8
    let hiL : UInt8 := ((len16 >>> 8) &&& 0xFF).toUInt8
    let loL : UInt8 := (len16 &&& 0xFF).toUInt8
    let hdr := ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, hiS, loS, hiL, loL]
    some (hdr ++ payload)

private theorem u16_rebuild_two_bytes (w : UInt16) :
    ((((w >>> 8) &&& 0xFF).toUInt8).toUInt16 <<< 8) ||| ((w &&& 0xFF).toUInt8).toUInt16 = w := by
  apply UInt16.eq_of_toBitVec_eq
  change (BitVec.zeroExtend 16 (BitVec.truncate 8 ((w.toBitVec >>> 8) &&& 0xFF#16)) <<< 8) |||
    BitVec.zeroExtend 16 (BitVec.truncate 8 (w.toBitVec &&& 0xFF#16)) = w.toBitVec
  bv_decide

private theorem nat_rebuild_from_u16 (w : UInt16) :
    ((((w >>> 8) &&& 0xFF).toUInt8).toNat <<< 8) ||| ((w &&& 0xFF).toUInt8).toNat = w.toNat := by
  let bHi := ((w >>> 8) &&& 0xFF).toUInt8
  let bLo := (w &&& 0xFF).toUInt8
  have h16 := congrArg UInt16.toNat (u16_rebuild_two_bytes w)
  have hlhs : ((bHi.toUInt16 <<< 8) ||| bLo.toUInt16).toNat = (bHi.toNat <<< 8) ||| bLo.toNat := by
    change (((bHi.toNat <<< 8) % 65536) ||| bLo.toNat) = (bHi.toNat <<< 8) ||| bLo.toNat
    have hbHi : bHi.toNat < 256 := bHi.toBitVec.isLt
    have hlt : bHi.toNat <<< 8 < 65536 := by
      rw [Nat.shiftLeft_eq]
      omega
    rw [Nat.mod_eq_of_lt hlt]
  exact hlhs.symm.trans h16

private theorem hdr_get_bang (hdr payload : ByteArray) (i : Nat) (hi : i < hdr.size) :
    (hdr ++ payload).get! i = hdr.data[i] := by
  change (hdr ++ payload).data[i]! = hdr.data[i]
  rw [ByteArray.data_append]
  have hi_data : i < hdr.data.size := hi
  have hin : i < (hdr.data ++ payload.data).size := by
    rw [Array.size_append]
    omega
  rw [getElem!_pos (hdr.data ++ payload.data) i hin]
  exact Array.getElem_append_left hi_data

private theorem hdr_extract_payload (hdr payload : ByteArray) (hsz : hdr.size = 8) :
    (hdr ++ payload).extract 8 (8 + payload.size) = payload := by
  have hsz_data : hdr.data.size = 8 := hsz
  apply ByteArray.ext
  apply Array.ext
  · simp [ByteArray.data_extract, Array.size_extract, ByteArray.data_append, hsz_data]
  · intro i hi1 hi2
    simp only [ByteArray.data_extract, Array.getElem_extract, ByteArray.data_append]
    rw [Array.getElem_append_right (by omega)]
    congr 1
    omega

/-- Exact `(schema, payload)` roundtrip theorem for `encodeOrbClientPatch?` / `parseOrbClientPatch`. -/
theorem parse_encode_orb_client_patch_roundtrip
    (schema : UInt16) (payload raw : ByteArray)
    (henc : encodeOrbClientPatch? schema payload = some raw) :
    parseOrbClientPatch raw = some { schema := schema, payload := payload } := by
  unfold encodeOrbClientPatch? at henc
  split at henc
  · contradiction
  · rename_i h_ok
    have hs1 : 1 ≤ schema := by
      have hnl : ¬ (schema < 1) := fun hc => h_ok (by simp [hc])
      exact UInt16.not_lt.mp hnl
    have hs2 : schema ≤ 255 := by
      have hnl : ¬ (255 < schema) := fun hc => h_ok (by simp [gt_iff_lt, hc])
      exact UInt16.not_lt.mp hnl
    have hp1 : 1 ≤ payload.size := by
      have : ¬ (payload.size < 1) := fun hc => h_ok (by simp [hc])
      omega
    have hp2 : payload.size ≤ 65535 := by
      have : ¬ (payload.size > 65535) := fun hc => h_ok (by simp [hc])
      omega
    injection henc with h_raw
    let len16 : UInt16 := UInt16.ofNat payload.size
    have hlen16 : len16.toNat = payload.size := by
      change payload.size % 65536 = payload.size
      omega
    let hiS : UInt8 := ((schema >>> 8) &&& 0xFF).toUInt8
    let loS : UInt8 := (schema &&& 0xFF).toUInt8
    let hiL : UInt8 := ((len16 >>> 8) &&& 0xFF).toUInt8
    let loL : UInt8 := (len16 &&& 0xFF).toUInt8
    let hdr : ByteArray := ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, hiS, loS, hiL, loL]
    have hhdr_sz : hdr.size = 8 := rfl
    have h_raw_hdr : hdr ++ payload = raw := h_raw
    rw [← h_raw_hdr]
    unfold parseOrbClientPatch
    have hsize : (hdr ++ payload).size = 8 + payload.size := by
      rw [ByteArray.size_append, hhdr_sz]
    have hg0 : (hdr ++ payload).get! 0 = 0x4F := hdr_get_bang hdr payload 0 (by rw [hhdr_sz]; omega)
    have hg1 : (hdr ++ payload).get! 1 = 0x52 := hdr_get_bang hdr payload 1 (by rw [hhdr_sz]; omega)
    have hg2 : (hdr ++ payload).get! 2 = 0x42 := hdr_get_bang hdr payload 2 (by rw [hhdr_sz]; omega)
    have hg3 : (hdr ++ payload).get! 3 = 0x50 := hdr_get_bang hdr payload 3 (by rw [hhdr_sz]; omega)
    have hg4 : (hdr ++ payload).get! 4 = hiS := hdr_get_bang hdr payload 4 (by rw [hhdr_sz]; omega)
    have hg5 : (hdr ++ payload).get! 5 = loS := hdr_get_bang hdr payload 5 (by rw [hhdr_sz]; omega)
    have hg6 : (hdr ++ payload).get! 6 = hiL := hdr_get_bang hdr payload 6 (by rw [hhdr_sz]; omega)
    have hg7 : (hdr ++ payload).get! 7 = loL := hdr_get_bang hdr payload 7 (by rw [hhdr_sz]; omega)
    have hnotlt : ¬ (8 + payload.size < 9) := by omega
    have hschema_eq : (hiS.toUInt16 <<< 8) ||| loS.toUInt16 = schema := u16_rebuild_two_bytes schema
    have hpay_eq : (hiL.toNat <<< 8) ||| loL.toNat = payload.size :=
      (nat_rebuild_from_u16 len16).trans hlen16
    have hex : (hdr ++ payload).extract 8 (8 + payload.size) = payload :=
      hdr_extract_payload hdr payload hhdr_sz
    simp only [hsize, hnotlt, ↓reduceIte, hg0, hg1, hg2, hg3, bne_self_eq_false, Bool.or_self,
      hg4, hg5, hg6, hg7, hschema_eq, hpay_eq, hs1, hs2, hp1, hp2,
      beq_self_eq_true, decide_true, Bool.and_self, hex]
    rfl

end OrbClient.Reducers
