import OrbCore.Store
import OrbBin.PosixExt
import OrbNetLeaf.Crypto

namespace OrbCore.ApprovalSignature

open OrbCore.Store OrbBin.PosixExt LeanSys.Auth

private def schema (st : CoreStore) : IO (Except String Unit) := do
  let .ok _ ← execParamQuery st.missionsDb
    "CREATE TABLE IF NOT EXISTS approval_challenges (id TEXT PRIMARY KEY, method TEXT NOT NULL, path TEXT NOT NULL, body_hash TEXT NOT NULL, payload TEXT NOT NULL, expires INTEGER NOT NULL);" #[]
    | return .error "approval_store_failed"
  return .ok ()

/-- Persist before returning a challenge. The client signs these exact bytes. -/
def issue (st : CoreStore) (id method path bodyHash payload : String)
    (expires : UInt64) : IO (Except String Unit) := do
  let .ok () ← schema st | return .error "approval_store_failed"
  let .ok _ ← execParamQuery st.missionsDb
    "DELETE FROM approval_challenges WHERE expires <= ?1;" #[toString (expires - 120)]
    | return .error "approval_store_failed"
  let .ok _ ← execParamQuery st.missionsDb
    "INSERT INTO approval_challenges(id,method,path,body_hash,payload,expires) VALUES(?1,?2,?3,?4,?5,?6);"
    #[id, method, path, bodyHash, payload, toString expires]
    | return .error "approval_store_failed"
  return .ok ()

/-- Validate the enrolled key and exact request, then atomically consume the nonce.
    A restart, concurrent request or alternate signature encoding cannot replay it. -/
def consume (st : CoreStore) (id keyB64 signatureB64 method path : String)
    (body : ByteArray) (now : UInt64) : IO (Except String Unit) := do
  let .ok () ← schema st | return .error "approval_store_failed"
  let .ok rows ← execParamQuery st.missionsDb
    "SELECT method,path,body_hash,payload,expires FROM approval_challenges WHERE id=?1;" #[id]
    | return .error "approval_store_failed"
  let some row := rows[1]? | return .error "approval_challenge_invalid"
  let expires := (((row[4]?).bind String.toNat?).getD 0).toUInt64
  if now ≥ expires then return .error "approval_challenge_expired"
  if row[0]? != some method || row[1]? != some path ||
      row[2]? != some (bytesToHexLower (sha256Bytes body)) then
    return .error "approval_request_mismatch"
  let some key := base64Decode? keyB64 | return .error "approval_device_invalid"
  let some signature := base64Decode? signatureB64 | return .error "approval_signature_invalid"
  unless ← OrbNetLeaf.Crypto.verifyP256 key signature ((row[3]?).getD "").toUTF8 do
    return .error "approval_signature_invalid"
  let .ok deleted ← execParamQuery st.missionsDb
    "DELETE FROM approval_challenges WHERE id=?1 AND expires>?2 RETURNING id;" #[id, toString now]
    | return .error "approval_store_failed"
  if deleted.size != 2 then return .error "approval_challenge_invalid"
  return .ok ()

end OrbCore.ApprovalSignature
