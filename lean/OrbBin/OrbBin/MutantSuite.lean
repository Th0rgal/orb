/-
  OrbBin.MutantSuite: Realistic Semantic Mutants Killed by `OrbBin.Spec` (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Spec

namespace OrbBin.MutantSuite

open OrbBin.Spec

/-- Mutant 1 (`fido-agent-proxy`): Weakens the FIDO Touch approval check on
    `sk-ssh-ed25519@openssh.com` `SSH_AGENTC_SIGN_REQUEST` (`msgType == 13 && isSkKey == 1`)
    from `fidoApproved == 1` to `fidoApproved ≤ 1` (admitting unapproved `0`). -/
@[inline]
def m1_fido_allowUnapprovedSkSign
    (frameLen : UInt32) (msgType isSkKey fidoApproved hasUpstream : UInt8) : UInt8 :=
  let frameOk := 1 ≤ frameLen && frameLen ≤ 262144
  let upstreamOk := hasUpstream == 1
  let signOk :=
    if msgType == 13 && isSkKey == 1 then fidoApproved ≤ 1
    else true
  if frameOk && upstreamOk && signOk then 1 else 0

theorem kill_m1_fido_allowUnapprovedSkSign :
    m1_fido_allowUnapprovedSkSign 128 13 1 0 1 ≠
      verifySshSignForward 128 13 1 0 1 ∧
    m1_fido_allowUnapprovedSkSign 128 13 1 1 1 =
      verifySshSignForward 128 13 1 1 1 := by
  decide

/-- Mutant 2 (`sandboxed-mcp`): Weakens `hasMcp1Prefix == 1` to `hasMcp1Prefix ≤ 1`,
    persisting an unscoped owner login token (`hasMcp1Prefix == 0`) into the renewable credential file. -/
@[inline]
def m2_mcp_persistOwnerToken
    (hasMcp1Prefix dirIsPrivate dirNotSymlink fileModeIs0600 safeEnvName : UInt8) : UInt8 :=
  if hasMcp1Prefix ≤ 1 && dirIsPrivate == 1 && dirNotSymlink == 1 &&
     fileModeIs0600 == 1 && safeEnvName == 1 then 1 else 0

theorem kill_m2_mcp_persistOwnerToken :
    m2_mcp_persistOwnerToken 0 1 1 1 1 ≠
      verifyMcpSecretPersistence 0 1 1 1 1 ∧
    m2_mcp_persistOwnerToken 1 1 1 1 1 =
      verifyMcpSecretPersistence 1 1 1 1 1 := by
  decide

/-- Mutant 3 (`sandboxed-mcp` stdio JSON-RPC): Admits an unbounded `> 1 MiB` JSON-RPC line
    instead of draining and returning `-32600` (`MAX_STDIO_FRAME_BYTES = 1048576`). -/
@[inline]
def m3_jsonrpc_acceptOversizeFrame
    (lineBytes : UInt64) (nonEmptyTrim : UInt8) (inFlight maxInFlight : UInt32) : UInt8 :=
  if 1 ≤ lineBytes && nonEmptyTrim == 1 &&
     1 ≤ maxInFlight && maxInFlight ≤ 64 && inFlight < maxInFlight then 1 else 0

theorem kill_m3_jsonrpc_acceptOversizeFrame :
    m3_jsonrpc_acceptOversizeFrame 1048577 1 0 8 ≠
      verifyStdioJsonRpcFrame 1048577 1 0 8 ∧
    m3_jsonrpc_acceptOversizeFrame 128 1 0 8 =
      verifyStdioJsonRpcFrame 128 1 0 8 := by
  decide

/-- Mutant 4 (`sandboxed-mcp`): Bounds `stateTag ≤ 4` for canonicality, yet omits `stateTag == 4`
    from the reconciliation check, treating settled `reconciliation_required` as `Accepted` (`1`)
    whenever a `result` field is present. -/
@[inline]
def m4_mcp_reconciliationAsAccepted
    (receiptStatus acceptedTag stateTag transportDropped hasResult : UInt8) : UInt32 :=
  let canonical := receiptStatus ≤ 5 && acceptedTag ≤ 3 && stateTag ≤ 4 &&
                   transportDropped ≤ 1 && hasResult ≤ 1
  let pending := receiptStatus == 0 || receiptStatus == 1 || stateTag == 0 || stateTag == 1
  if !canonical then 2
  else
    let outcome : UInt32 :=
      if transportDropped == 1 || acceptedTag == 3 then 3
      else if pending then 0
      else if receiptStatus == 3 || stateTag == 3 then 2
      else if hasResult == 1 then 1
      else 2
    let settled : UInt32 := if !pending || transportDropped == 1 then 256 else 0
    let success : UInt32 := if outcome == 1 then 65536 else 0
    outcome ||| settled ||| success

theorem kill_m4_mcp_reconciliationAsAccepted :
    m4_mcp_reconciliationAsAccepted 2 1 4 0 1 ≠
      verifyMcpActionOutcome 2 1 4 0 1 ∧
    m4_mcp_reconciliationAsAccepted 2 1 2 0 1 =
      verifyMcpActionOutcome 2 1 2 0 1 := by
  decide

/-- Mutant 5 (`McpStdioRegistry`): Leaves a `Connected` (`2`) server in `Connected` when its active
    generation (`eventGen == activeGen`) child exits. -/
@[inline]
def m5_mcp_stdio_keepConnectedOnActiveExit
    (connState : UInt8) (activeGen eventGen : UInt64) (toolsListOk childExited : UInt8) : UInt32 :=
  if eventGen != activeGen then connState.toUInt32 ||| 65536
  else if connState == 1 && toolsListOk == 0 && childExited == 0 then 3 ||| 256
  else connState.toUInt32

theorem kill_m5_mcp_stdio_keepConnectedOnActiveExit :
    m5_mcp_stdio_keepConnectedOnActiveExit 2 5 5 1 1 ≠
      verifyMcpStdioLifecycleStep 2 5 5 1 1 ∧
    m5_mcp_stdio_keepConnectedOnActiveExit 2 5 4 1 1 =
      verifyMcpStdioLifecycleStep 2 5 4 1 1 := by
  decide

/-- Mutant 6 (`McpStdioRegistry`): Transitions `Connecting -> Error` on `tools/list` failure
    without setting `mustReapChild` (`bit 8`), leaking the spawned stdio child. -/
@[inline]
def m6_mcp_stdio_omitReapOnRefreshFailure
    (connState : UInt8) (activeGen eventGen : UInt64) (toolsListOk childExited : UInt8) : UInt32 :=
  if eventGen != activeGen then connState.toUInt32 ||| 65536
  else if childExited == 1 && (connState == 1 || connState == 2) then 256
  else if connState == 1 && toolsListOk == 0 then 3
  else connState.toUInt32

theorem kill_m6_mcp_stdio_omitReapOnRefreshFailure :
    m6_mcp_stdio_omitReapOnRefreshFailure 1 3 3 0 0 ≠
      verifyMcpStdioLifecycleStep 1 3 3 0 0 ∧
    m6_mcp_stdio_omitReapOnRefreshFailure 2 3 2 0 0 =
      verifyMcpStdioLifecycleStep 2 3 2 0 0 := by
  decide

/-- Mutant 7 (`orb-privd`): Checks only non-zero digests (`observedDigest != 0 && execDigest != 0`)
    and `grantPresent ≤ 1`, admitting execution after a command-digest swap or missing `grant_id`. -/
@[inline]
def m7_privd_ignoreDigestAndGrant
    (principalKind bunkerState : UInt8)
    (observedTargetId execTargetId : UInt32)
    (observedLeaseEpoch liveLeaseEpoch nowTick expiryTick observedDigest execDigest : UInt64)
    (grantPresent allowExec : UInt8) : UInt32 :=
  if bunkerState != 0 then 513
  else if !(principalKind ≥ 1 && principalKind ≤ 3) then 514
  else if !(nowTick < expiryTick) then 515
  else if !(observedLeaseEpoch != 0 && observedLeaseEpoch == liveLeaseEpoch) then 516
  else if !(observedTargetId != 0 && observedTargetId == execTargetId) then 517
  else if !(observedDigest != 0 && execDigest != 0) then 518
  else if !(grantPresent ≤ 1 && allowExec == 1) then 519
  else 257

theorem kill_m7_privd_ignoreDigestAndGrant :
    m7_privd_ignoreDigestAndGrant 2 0 9 9 4 4 10 20 11 99 0 1 ≠
      verifyPrivdToctouStep 2 0 9 9 4 4 10 20 11 99 0 1 ∧
    m7_privd_ignoreDigestAndGrant 2 0 9 9 4 4 10 20 11 11 1 1 =
      verifyPrivdToctouStep 2 0 9 9 4 4 10 20 11 11 1 1 := by
  decide

end OrbBin.MutantSuite
