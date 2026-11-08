/-
  OrbNode.Lease: Constant-Time Bearer Auth, 1-Step Rotation, and Base64URL + HMAC-SHA256
  `LeaseClaims` Verification (`LeanSys.Auth` + `OrbNode.Spec`).
-/
import LeanSys.Auth
import OrbBin.Json
import OrbNode.Spec

namespace OrbNode.Lease

open LeanSys.Auth
open OrbBin.Json
open OrbNode.Spec

/-- Scoped lease operation codes matching `OrbNode.Spec.verifyNodeLeaseClaims`. -/
inductive LeaseScope where
  | missionExecute
  | jobSubmit
  | jobForce
  | nodeCapacity
  deriving Repr, DecidableEq, BEq

def LeaseScope.code : LeaseScope → UInt8
  | .missionExecute => 1
  | .jobSubmit      => 2
  | .jobForce       => 3
  | .nodeCapacity   => 4

def LeaseScope.ofString? : String → Option LeaseScope
  | "mission:execute" => some .missionExecute
  | "job:submit"      => some .jobSubmit
  | "job:force"       => some .jobForce
  | "node:capacity"   => some .nodeCapacity
  | _                 => none

def LeaseScope.asString : LeaseScope → String
  | .missionExecute => "mission:execute"
  | .jobSubmit      => "job:submit"
  | .jobForce       => "job:force"
  | .nodeCapacity   => "node:capacity"

structure LeaseClaims where
  missionId    : String
  nodeId       : String
  scope        : LeaseScope
  expiresAt    : UInt64
  jobId?       : Option String := none
  ownerUserId  : String := ""
  callerRole   : String := "admin"
  unixUsername : Option String := none
  deriving Repr, DecidableEq, BEq

/-! ### RFC 4648 §5 Unpadded Base64URL Encode / Decode -/

private def b64UrlAlphabet : ByteArray :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toUTF8

def base64UrlEncodeUnpadded (src : ByteArray) : String := Id.run do
  let mut out := ByteArray.emptyWithCapacity ((src.size * 4 + 2) / 3)
  let full := (src.size / 3) * 3
  let mut i := 0
  while i < full do
    let b0 := (src.get! i).toNat
    let b1 := (src.get! (i + 1)).toNat
    let b2 := (src.get! (i + 2)).toNat
    let n := (b0 <<< 16) ||| (b1 <<< 8) ||| b2
    out := out.push (b64UrlAlphabet.get! ((n >>> 18) &&& 63))
    out := out.push (b64UrlAlphabet.get! ((n >>> 12) &&& 63))
    out := out.push (b64UrlAlphabet.get! ((n >>> 6) &&& 63))
    out := out.push (b64UrlAlphabet.get! (n &&& 63))
    i := i + 3
  let rem := src.size - full
  if rem == 1 then
    let b0 := (src.get! full).toNat
    out := out.push (b64UrlAlphabet.get! ((b0 >>> 2) &&& 63))
    out := out.push (b64UrlAlphabet.get! ((b0 <<< 4) &&& 63))
  else if rem == 2 then
    let b0 := (src.get! full).toNat
    let b1 := (src.get! (full + 1)).toNat
    let n := (b0 <<< 8) ||| b1
    out := out.push (b64UrlAlphabet.get! ((n >>> 10) &&& 63))
    out := out.push (b64UrlAlphabet.get! ((n >>> 4) &&& 63))
    out := out.push (b64UrlAlphabet.get! ((n <<< 2) &&& 63))
  return String.fromUTF8! out

private def b64UrlVal? (c : UInt8) : Option UInt32 :=
  if 65 ≤ c && c ≤ 90 then some (c - 65).toUInt32
  else if 97 ≤ c && c ≤ 122 then some (c - 97 + 26).toUInt32
  else if 48 ≤ c && c ≤ 57 then some (c - 48 + 52).toUInt32
  else if c == 45 || c == 43 then some 62
  else if c == 95 || c == 47 then some 63
  else none

def base64UrlDecode? (s : String) : Option ByteArray := Id.run do
  let rawBytes := s.trimAscii.toString.toUTF8
  let mut endIdx := rawBytes.size
  while endIdx > 0 && rawBytes.get! (endIdx - 1) == 61 do
    endIdx := endIdx - 1
  let bytes := rawBytes.extract 0 endIdx
  if bytes.size % 4 == 1 then return none
  let mut out := ByteArray.emptyWithCapacity ((bytes.size * 3) / 4)
  let full := (bytes.size / 4) * 4
  let mut i := 0
  while i < full do
    let some v0 := b64UrlVal? (bytes.get! i) | return none
    let some v1 := b64UrlVal? (bytes.get! (i + 1)) | return none
    let some v2 := b64UrlVal? (bytes.get! (i + 2)) | return none
    let some v3 := b64UrlVal? (bytes.get! (i + 3)) | return none
    let n := (v0 <<< 18) ||| (v1 <<< 12) ||| (v2 <<< 6) ||| v3
    out := out.push ((n >>> 16) &&& 0xFF).toUInt8
    out := out.push ((n >>> 8) &&& 0xFF).toUInt8
    out := out.push (n &&& 0xFF).toUInt8
    i := i + 4
  let rem := bytes.size - full
  if rem == 2 then
    let some v0 := b64UrlVal? (bytes.get! full) | return none
    let some v1 := b64UrlVal? (bytes.get! (full + 1)) | return none
    let n := (v0 <<< 6) ||| v1
    out := out.push ((n >>> 4) &&& 0xFF).toUInt8
  else if rem == 3 then
    let some v0 := b64UrlVal? (bytes.get! full) | return none
    let some v1 := b64UrlVal? (bytes.get! (full + 1)) | return none
    let some v2 := b64UrlVal? (bytes.get! (full + 2)) | return none
    let n := (v0 <<< 12) ||| (v1 <<< 6) ||| v2
    out := out.push ((n >>> 10) &&& 0xFF).toUInt8
    out := out.push ((n >>> 2) &&& 0xFF).toUInt8
  return some out

/-! ### Constant-Time Bearer Header Verification (with 1-Step Rotation) -/

def verifyBearerHeader
    (authHeader? : Option String)
    (primaryToken : String)
    (previousToken? : Option String) : Bool :=
  match authHeader? with
  | none => false
  | some hdr =>
    let hasPrefix : UInt8 := if hdr.startsWith "Bearer " then 1 else 0
    let cand := if hdr.startsWith "Bearer " then (hdr.drop 7).toString else ""
    let candLen : UInt32 := cand.utf8ByteSize.toUInt32
    let curMatch : UInt8 :=
      if !primaryToken.isEmpty && ctEqString cand primaryToken then 1 else 0
    let (hasPrev, prevMatch) : UInt8 × UInt8 :=
      match previousToken? with
      | some prev =>
        if prev.isEmpty then (0, 0)
        else (1, if ctEqString cand prev then 1 else 0)
      | none => (0, 0)
    verifyNodeBearerAuth hasPrefix curMatch hasPrev prevMatch candLen == 1

/-! ### Scoped HMAC-SHA256 Lease Minting & Verification -/

def signLeaseToken (secret : String) (claims : LeaseClaims) : String :=
  let fields : Array (String × JVal) :=
    #[ ("mission_id", .str claims.missionId)
     , ("node_id", .str claims.nodeId)
     , ("scope", .str claims.scope.asString)
     , ("expires_at", JVal.uint64 claims.expiresAt) ] ++
    (match claims.jobId? with
     | some jid => #[("job_id", .str jid)]
     | none => #[]) ++
    (if claims.ownerUserId.isEmpty then #[] else #[("owner_user_id", .str claims.ownerUserId)]) ++
    (if claims.callerRole == "admin" && claims.ownerUserId.isEmpty && claims.unixUsername.isNone then #[]
     else #[("caller_role", .str claims.callerRole)]) ++
    (match claims.unixUsername with
     | some u => #[("unix_username", .str u)]
     | none => #[])
  let jsonBytes := (renderCompact (.obj fields)).toUTF8
  let b64 := base64UrlEncodeUnpadded jsonBytes
  let sigHex := hmacSha256Hex secret b64
  s!"{b64}.{sigHex}"

def verifyLeaseToken
    (token : String)
    (primarySecret : String)
    (previousSecret? : Option String)
    (expectedNodeId : String)
    (expectedScope : LeaseScope)
    (nowSecs : UInt64)
    (expectedJobId? : Option String := none) : Except String LeaseClaims := do
  let parts := token.splitOn "."
  let [b64Payload, sigHexRaw] := parts
    | throw "malformed lease token"
  let sigHex := sigHexRaw.toLower
  let primaryMac := hmacSha256Hex primarySecret b64Payload
  let prevOk := match previousSecret? with
    | some prev => !prev.isEmpty && ctEqString sigHex (hmacSha256Hex prev b64Payload)
    | none => false
  let hmacValid : UInt8 :=
    if (!primarySecret.isEmpty && ctEqString sigHex primaryMac) || prevOk then 1 else 0
  let some payloadBytes := base64UrlDecode? b64Payload
    | throw "invalid lease base64url payload"
  let some payloadStr := String.fromUTF8? payloadBytes
    | throw "lease payload is not valid UTF-8"
  let .ok jval := OrbBin.Json.parse payloadStr
    | throw "lease payload is not valid JSON"
  let some missionId := jval.fieldStr? "mission_id"
    | throw "lease missing mission_id"
  let some claimNodeId := jval.fieldStr? "node_id"
    | throw "lease missing node_id"
  let some scopeStr := jval.fieldStr? "scope"
    | throw "lease missing scope"
  let some claimScope := LeaseScope.ofString? scopeStr
    | throw s!"unknown lease scope: {scopeStr}"
  let some expiresAt := jval.fieldUInt64? "expires_at"
    | throw "lease missing expires_at"
  let jobId? := jval.fieldStr? "job_id"
  let ownerUserId := ((jval.fieldStr? "owner_user_id").getD "").trimAscii.toString
  let callerRoleRaw := ((jval.fieldStr? "caller_role").getD "admin").trimAscii.toString.toLower
  if callerRoleRaw != "admin" && callerRoleRaw != "member" then
    throw s!"invalid lease caller_role: {callerRoleRaw}"
  let unixUsername? := (jval.fieldStr? "unix_username").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let nodeMatches : UInt8 := if claimNodeId == expectedNodeId then 1 else 0
  let jobMatches : UInt8 :=
    match expectedJobId?, jobId? with
    | some want, some got => if want == got then 1 else 0
    | none, _ => 1
    | some _, none => 0
  if verifyNodeLeaseClaims
      hmacValid nodeMatches claimScope.code expectedScope.code
      jobMatches nowSecs expiresAt != 1 then
    throw "lease rejected by verifyNodeLeaseClaims"
  return {
    missionId := missionId
    nodeId := claimNodeId
    scope := claimScope
    expiresAt := expiresAt
    jobId? := jobId?
    ownerUserId := ownerUserId
    callerRole := callerRoleRaw
    unixUsername := unixUsername?
  }

end OrbNode.Lease
