/-
  OrbClient.Reducers: Pure State Reducers for Client Sync Cursors, Inbox Unread Counts & Stream Checkpoints.
-/
import OrbClient.Spec

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
    let hiS : UInt8 := ((schema >>> 8) &&& 0xFF).toUInt8
    let loS : UInt8 := (schema &&& 0xFF).toUInt8
    let hiL : UInt8 := ((payload.size >>> 8) &&& 0xFF).toUInt8
    let loL : UInt8 := (payload.size &&& 0xFF).toUInt8
    let hdr := ByteArray.mk #[0x4F, 0x52, 0x42, 0x50, hiS, loS, hiL, loL]
    some (hdr ++ payload)

end OrbClient.Reducers
